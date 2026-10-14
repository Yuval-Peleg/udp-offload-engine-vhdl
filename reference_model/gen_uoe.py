#!/usr/bin/env python3
"""Generate stimulus + expected files for the full-chip uoe testbench.

This is the only test that drives the design the way the board will. The
block-level tests each prove one hop; this proves they are wired together in
the right order, with the right widths, and that the things that exist ONLY
at the top level actually work:

  * the endianness converters. Everything inside uoe is MSB-first, the MAC
    ports are byte-reversed. Both stimulus and expectation are swapped here,
    in Python, rather than by instantiating the RTL's own converter in the
    testbench -- otherwise a bug in it would cancel itself out.

  * circular_buffer_filter acting on the MAC's error flag, which only the
    MAC-facing input carries.

  * the ARP responder and the TX arbiter. arp_handler hangs off the RX stream
    and answers into priority_handler's high-priority port, so ARP replies and
    UDP frames share one output. Nothing in the design fixes their relative
    order, so mac_tx is compared per EtherType (see split_mac_tx.py) -- within
    a class the order is the design's, across classes it is arbitration.

Files written:

    stimulus_uoe_tb_mac_rx.txt         Ethernet frames in    (byte-swapped)
    stimulus_uoe_tb_udp_tx.txt         payloads to transmit
    expected_axis_uoe_tb_udp_rx.txt    payloads that should be delivered
    expected_sideband_uoe_tb.txt       who each delivered payload came from
    expected_axis_uoe_tb_mac_tx_*.txt  frames that should leave (ipv4, arp)

    ./gen_uoe.py [outdir]
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import random
import sys

from uoe_model import (Beat, arp_request, bytes_to_beats, eth_frame,
                       ipv4_packet, model_arp_reply, model_uoe_rx,
                       model_uoe_rx_sideband, model_uoe_tx, swap_beats,
                       udp_packet, write_beats, write_sideband, write_stimulus)

# must match the testbench
CONF_MAC = 0xDECAFBAD0101
CONF_IP = 0xC0A80101
CONF_PORT = 0x04D2
DST_MAC = 0xCAFEF00D0202
DST_IP = 0xC0A80164
DST_PORT = 0x1234
# Second TX destination. Every field differs from the first, so a frame that
# mixes the two (A's port, B's MAC) cannot pass.
DST_MAC_B = 0x0A0B0C0D0E0F
DST_IP_B = 0xC0A801FE
DST_PORT_B = 0x5678


def tx_dst(case: int) -> tuple:
    """Destination of TX case <case> (1-based, as in '# CASE <n>').

    Must match dst_is_b in uoe_tb_full.vhd, which drives conf_tx_dst_*
    from the driver's case_index -- so it changes the moment the previous
    packet's tlast is accepted, the earliest the contract allows. A A B A A B
    gives both repeats and changes in each direction.
    """
    if case % 3 == 0:
        return DST_MAC_B, DST_IP_B, DST_PORT_B
    return DST_MAC, DST_IP, DST_PORT

PEER_MAC = 0xCAFEF00D0202
PEER_IP = 0xC0A80164

SEED = 0x0FF1CE


def mac_rx_cases() -> list:
    """(description, frame bytes, mac_error) for the receive side."""
    rng = random.Random(SEED)
    cases: list = []

    def payload(n: int) -> bytes:
        return bytes(rng.randrange(256) for _ in range(n))

    def udp_frame(n: int, dst_mac: int = CONF_MAC, dst_ip: int = CONF_IP,
                  src_ip: int = PEER_IP, src_mac: int = PEER_MAC) -> bytes:
        udp = udp_packet(DST_PORT, CONF_PORT, payload(n))
        ip = ipv4_packet(src_ip.to_bytes(4, "big"), dst_ip.to_bytes(4, "big"),
                         udp, pad_to=46)
        return eth_frame(dst_mac.to_bytes(6, "big"), src_mac.to_bytes(6, "big"), ip)

    # An ARP request first: on a real link this is what happens before any
    # traffic flows, and it exercises the responder while the TX path is idle.
    cases.append(("arp request for us", arp_request(PEER_MAC, PEER_IP, CONF_IP), 0))

    # Payload lengths walking the 6-byte and 4-byte realignments of the two
    # headers. 18 is the shortest that needs no padding.
    for n in (18, 19, 20, 23, 24, 25, 31, 32, 33):
        cases.append((f"udp payload {n} bytes", udp_frame(n), 0))

    # Rejections, one reason at a time.
    cases.append(("wrong destination MAC", udp_frame(24, dst_mac=0x001122334455), 0))
    cases.append(("wrong destination IP", udp_frame(24, dst_ip=0xC0A809FF), 0))
    cases.append(("arp for a different IP",
                  arp_request(PEER_MAC, PEER_IP, 0xC0A809FF), 0))

    # A frame the MAC itself flags. circ_fifo must swallow it whole -- this is
    # the filter's one case at chip level; its own test covers the rest.
    cases.append(("MAC error flag set", udp_frame(24), 1))

    # Prove the filter did not desync: a good frame straight after a bad one.
    cases.append(("good frame after MAC error", udp_frame(20), 0))

    # Four ARP requests with NO gap between them, each from a different peer.
    # A reply takes 8 beats and a request is 8 beats, so the next request
    # arrives while the previous reply is still going out. Each reply must
    # still carry its own peer; the differing MACs and IPs are what would make
    # a mix-up visible -- identical peers would corrupt into the same value
    # and pass.
    for i, (mac, ip) in enumerate([(0xAA0000000001, 0xC0A80181),
                                   (0xBB0000000002, 0xC0A80182),
                                   (0xCC0000000003, 0xC0A80183),
                                   (0xDD0000000004, 0xC0A80184)]):
        cases.append((f"arp back-to-back peer {i}",
                      arp_request(mac, ip, CONF_IP), 0))

    # Two accepted frames with NO gap, from different source MACs and IPs.
    # rx_eth can accept frame N+1 while rx_udp is still emitting frame N, and
    # each frame must keep its own src_mac/src_ip. The addresses have to
    # differ or a mix-up would be invisible.
    cases.append(("back-to-back accepted 1",
                  udp_frame(24, src_mac=0x111111111111, src_ip=0xC0A80191), 0))
    cases.append(("back-to-back accepted 2",
                  udp_frame(24, src_mac=0x222222222222, src_ip=0xC0A80192), 0))

    # Bigger frames, many beats each.
    for n in (100, 256, 1000):
        cases.append((f"udp payload {n} bytes", udp_frame(n), 0))

    # Large frames up to jumbo, all within circ_fifo's 16 KB. (Frames too big
    # to buffer are dropped; circular_buffer_filter's own test covers that.)
    #
    # An ARP request follows each one, to prove the receive path is still alive
    # afterwards: a reply that never comes means it wedged.
    for n, label in ((1472, "MTU"), (2006, "2 KB frame"), (2048, "over 2 KB"),
                     (4096, "4 KB"), (8958, "jumbo")):
        cases.append((f"udp payload {n} bytes ({label})", udp_frame(n), 0))
        cases.append((f"arp liveness check after {n} bytes",
                      arp_request(0xEE0000000000 + n, 0xC0A801C8, CONF_IP), 0))

    return cases


def udp_tx_cases() -> list:
    """(description, payload) for the transmit side."""
    rng = random.Random(SEED ^ 0xABCD)
    cases: list = []

    def payload(n: int) -> bytes:
        return bytes(rng.randrange(256) for _ in range(n))

    # 0..20 is the padding boundary tx_udp special-cases; the block test sweeps
    # it exhaustively, so here just the edges plus a spread of sizes.
    for n in (1, 8, 16, 17, 18, 19, 24, 32, 40, 100, 256, 1000):
        cases.append((f"tx payload {n} bytes", payload(n)))

    # A burst of short packets. They pile up in tx_udp's FIFO behind a stalled
    # MAC, so the destination changes while several are still inside -- the
    # case a live read of conf_tx_dst_* gets wrong.
    for n in (8, 64, 8, 24, 8, 8, 64, 8, 16, 8, 8, 40):
        cases.append((f"tx burst {n} bytes", payload(n)))

    return cases


def main() -> int:
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."

    # ---------------- receive side ----------------
    rx_beats: list = []
    rx_marks: dict = {}
    udp_rx_expected: list = []
    udp_rx_marks: dict = {}
    arp_expected: list = []
    arp_marks: dict = {}
    sideband: list = []
    notes: list = []

    for desc, frame, mac_error in mac_rx_cases():
        rx_marks[len(rx_beats)] = desc
        beats = bytes_to_beats(frame)
        if mac_error:
            # the MAC raises tuser with tlast to condemn the frame
            beats[-1] = Beat(beats[-1].tdata, beats[-1].tkeep, 1, 1)
        rx_beats.extend(swap_beats(beats))

        if mac_error:
            notes.append(f"{desc}: {len(frame)} bytes, MAC error -> dropped by circ_fifo")
            continue

        out = model_uoe_rx(frame, CONF_MAC, CONF_IP)
        if out:
            udp_rx_marks[len(udp_rx_expected)] = desc
            udp_rx_expected.extend(out)
            sm, si, sp, dp = model_uoe_rx_sideband(frame, CONF_MAC, CONF_IP)
            sideband.append((sm << 64) | (si << 32) | (sp << 16) | dp)
            notes.append(f"{desc}: {len(frame)} bytes -> {len(out)} udp_rx beats")

        reply = model_arp_reply(frame, CONF_MAC, CONF_IP)
        if reply is not None:
            arp_marks[len(arp_expected)] = desc
            arp_expected.extend(swap_beats(bytes_to_beats(reply)))
            notes.append(f"{desc}: {len(frame)} bytes -> ARP reply")

        if not out and reply is None:
            notes.append(f"{desc}: {len(frame)} bytes -> dropped")

    # ---------------- transmit side ----------------
    tx_beats: list = []
    tx_marks: dict = {}
    mac_tx_expected: list = []
    mac_tx_marks: dict = {}
    tx_notes: list = []

    for ident, (desc, pl) in enumerate(udp_tx_cases()):
        in_beats = bytes_to_beats(pl)
        tx_marks[len(tx_beats)] = desc
        tx_beats.extend(in_beats)

        dst_mac, dst_ip, dst_port = tx_dst(len(tx_marks))
        desc += " to B" if dst_mac == DST_MAC_B else " to A"
        frame = model_uoe_tx(pl, CONF_MAC, CONF_IP, CONF_PORT,
                             dst_mac, dst_ip, dst_port, ident=ident)
        mac_tx_marks[len(mac_tx_expected)] = desc
        mac_tx_expected.extend(swap_beats(bytes_to_beats(frame)))
        tx_notes.append(f"{desc}: {len(pl)} bytes -> {len(frame)}-byte frame")

    # ---------------- write ----------------
    rng = random.Random(SEED ^ 0x5A5A)
    # RX gaps only between packets, since the MAC delivers a frame without
    # bubbles -- and none before the back-to-back cases, which exist to remove
    # exactly that slack. The TX side is an application, so it may stall
    # anywhere.
    rx_starts = {i for i, name in rx_marks.items()
                 if not name.startswith("arp back-to-back")
                 and not name.startswith("back-to-back accepted 2")}
    rx_gaps = [rng.randrange(2, 20) if i in rx_starts else 0
               for i in range(len(rx_beats))]
    tx_gaps = [rng.randrange(0, 6) if rng.random() < 0.3 else 0
               for _ in range(len(tx_beats))]

    write_stimulus(f"{outdir}/stimulus_uoe_tb_mac_rx.txt",
                   list(zip(rx_beats, rx_gaps)),
                   "uoe mac_rx stimulus -- complete Ethernet frames, BYTE-SWAPPED\n"
                   f"conf_mac = 0x{CONF_MAC:012X}, conf_ip = 0x{CONF_IP:08X}\n"
                   "The 5th column is the gap; tuser is the MAC's error flag.\n"
                   + "\n".join(notes), marks=rx_marks)

    write_stimulus(f"{outdir}/stimulus_uoe_tb_udp_tx.txt",
                   list(zip(tx_beats, tx_gaps)),
                   "uoe udp_tx stimulus -- payloads only, uoe builds every header\n"
                   f"conf_port = 0x{CONF_PORT:04X}; destination A (dst_port = 0x{DST_PORT:04X})\n"
                   f"except every third packet, which goes to B (dst_port = 0x{DST_PORT_B:04X})\n"
                   + "\n".join(tx_notes), marks=tx_marks)

    write_beats(f"{outdir}/expected_axis_uoe_tb_udp_rx.txt", udp_rx_expected,
                "uoe udp_rx expected -- payloads delivered to the user side.\n"
                "Frames addressed elsewhere, carrying the wrong IP, or flagged\n"
                "by the MAC must not appear here at all.", marks=udp_rx_marks)

    write_beats(f"{outdir}/expected_axis_uoe_tb_mac_tx_ipv4.txt", mac_tx_expected,
                "uoe mac_tx expected, IPv4 frames only -- BYTE-SWAPPED.\n"
                "ARP replies are compared separately: the arbiter decides how\n"
                "the two classes interleave, and nothing specifies that order.",
                marks=mac_tx_marks)

    write_beats(f"{outdir}/expected_axis_uoe_tb_mac_tx_arp.txt", arp_expected,
                "uoe mac_tx expected, ARP replies only -- BYTE-SWAPPED.",
                marks=arp_marks)

    write_sideband(f"{outdir}/expected_sideband_uoe_tb.txt", sideband, nibbles=28,
                   header="src_mac(48) & src_ip(32) & src_port(16) & dst_port(16),\n"
                          "one value per packet delivered to udp_rx,\n"
                          "sampled on the FIRST beat of each packet.")

    print(f"wrote {outdir}/stimulus_uoe_tb_mac_rx.txt  "
          f"({len(rx_beats)} beats, {sum(rx_gaps)} idle cycles)")
    print(f"wrote {outdir}/stimulus_uoe_tb_udp_tx.txt  "
          f"({len(tx_beats)} beats, {sum(tx_gaps)} idle cycles)")
    print(f"udp_rx {len(udp_rx_expected)} beats, "
          f"mac_tx ipv4 {len(mac_tx_expected)} beats, arp {len(arp_expected)} beats, "
          f"{len(sideband)} sideband values")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
