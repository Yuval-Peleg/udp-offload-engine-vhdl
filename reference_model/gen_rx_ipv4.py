#!/usr/bin/env python3
"""Generate stimulus + expected-output files for the rx_ipv4 testbench.

Same shape as gen_rx_udp.py. Python owns both the stimulus and the expected
output, so the driver and the model cannot disagree about what was sent.

Names match rx_ipv4_tb.vhd's generics:

  written here                       read/written by the testbench
  ---------------------------------  ----------------------------------------
  stimulus_rx_ipv4_tb.txt            -> STIMULUS_FILE (default, gapless)
  stimulus_rx_ipv4_tb_ipg.txt        -> STIMULUS_FILE via -generic_top
  stimulus_rx_ipv4_tb_random.txt     -> STIMULUS_FILE via -generic_top
  expected_axis_rx_ipv4_tb.txt          vs AXIS_FILE
  expected_sideband_rx_ipv4_tb.txt      vs SIDEBAND_FILE

    ./gen_rx_ipv4.py [outdir]

What makes rx_ipv4 harder to get right than rx_udp
--------------------------------------------------
The IPv4 header is 20 bytes and the bus is 8 bytes wide, so the payload does
NOT start on a beat boundary -- it starts 4 bytes into header word 2. Every
output beat therefore has to be assembled from the low half of one input word
and the high half of the next. The length sweep below exists mainly to hammer
that realignment at every possible offset.

Packets are zero-padded to the 46-byte Ethernet minimum, because that is what
actually arrives once rx_eth has stripped the L2 header. Padding is wire bytes
beyond Total Length, so a correct block ignores it -- telling the declared
length and the wire length apart is the whole job of the padded cases.
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import random
import sys

from uoe_model import (Beat, ETH_MIN_PAYLOAD, bytes_to_beats, ipv4_packet,
                       model_rx_ipv4, model_rx_ipv4_sideband, write_beats,
                       write_sideband, write_stimulus)

CONF_IP = 0xC0A8_0164       # 192.168.1.100 -- must match conf_ip in the testbench
OTHER_IP = 0xC0A8_01C8      # 192.168.1.200 -- a destination we must NOT accept
SEED = 0xC0FFEE


def ip(value: int) -> bytes:
    return value.to_bytes(4, "big")


def build_cases() -> list[tuple[str, bytes]]:
    """Each case is (description, raw IPv4 packet as it arrives at rx_ipv4)."""
    rng = random.Random(SEED)
    cases: list[tuple[str, bytes]] = []

    def payload(n: int) -> bytes:
        return bytes(rng.randrange(256) for _ in range(n))

    # src_ip VARIES per packet on purpose. With a constant source address the
    # sideband check would pass even against a DUT that latches once and never
    # updates again, so a changing value is what makes that test mean anything.
    src = iter(ip(0x0A00_0001 + 0x0101 * i) for i in range(64))

    def accept(desc: str, n: int, **kw) -> None:
        cases.append((desc, ipv4_packet(next(src), ip(CONF_IP), payload(n),
                                        pad_to=ETH_MIN_PAYLOAD, **kw)))

    # ---- the realignment sweep --------------------------------------------
    # 1..17 covers every tkeep pattern and both multi-beat boundaries. The
    # larger sizes matter because packets past 26 payload bytes exceed the
    # Ethernet minimum and so arrive with NO padding behind them -- the block
    # gets exactly as many input words as the packet contains, and not one
    # more. Lengths where payload % 8 is 1..4 are the interesting ones there.
    for n in list(range(1, 18)) + [23, 24, 25, 31, 32, 33, 34, 40, 41, 64, 100]:
        accept(f"payload {n} bytes", n)

    # ---- padding must be dropped, not forwarded ---------------------------
    # A 4-byte payload declares Total Length 24 but arrives as 46 wire bytes.
    # Everything past byte 24 is Ethernet padding and must never come out.
    accept("padded: declared 24, wire 46", 4)

    # ---- DF is not ours to require ----------------------------------------
    # RFC 791: unfragmented means MF=0 and offset=0. DF is a request aimed at
    # routers and says nothing about whether this datagram is a fragment, so an
    # ordinary packet sent with DF=0 must be accepted.
    accept("DF clear, unfragmented -- must be accepted", 16, flags=0b000)

    # ---- Total Length that overruns the frame ------------------------------
    # A separator first, so the damage below is attributed to the right case.
    accept("separator before the truncation case", 16)

    # Total Length declares 200 bytes but only 46 arrive. s_axis_tlast must end
    # the packet even while the length countdown is still running; otherwise
    # the next packet would be consumed as this one's payload.
    # Expected: the bytes that actually arrived, terminated.
    cases.append(("total_len 200 declared, only 46 bytes arrive",
                  ipv4_packet(next(src), ip(CONF_IP), payload(26),
                              pad_to=ETH_MIN_PAYLOAD, total_len=200)))

    accept("packet after the truncation -- must survive", 16)

    # ---- rejected: one bad field each -------------------------------------
    # None of these may emit a single beat, and none may leave a stale src_ip
    # behind -- the accepted packet at the end of the list proves that.
    def reject(desc: str, **kw) -> None:
        cases.append((desc, ipv4_packet(next(src), ip(CONF_IP), payload(16),
                                        pad_to=ETH_MIN_PAYLOAD, **kw)))

    reject("version 6, not 4", version=6)
    reject("IHL 6 (options present, unsupported)", ihl=6)
    reject("TTL expired (0)", ttl=0)
    reject("protocol TCP, not UDP", proto=0x06)
    reject("MF set -- a fragment", flags=0b001)
    reject("MF set AND DF set", flags=0b011)
    reject("fragment offset non-zero", frag_offset=185)
    reject("header checksum corrupted", bad_checksum=True)
    reject("total length 20 -- header only", total_len=20)

    # Wrong destination: right shape, addressed to somebody else.
    cases.append(("destination is not us",
                  ipv4_packet(next(src), ip(OTHER_IP), payload(16),
                              pad_to=ETH_MIN_PAYLOAD)))

    # ---- one more accepted packet last ------------------------------------
    # A stale src_ip left behind by any of the ten rejects above shows up here
    # as a sideband mismatch.
    accept("final accepted packet", 12)

    return cases


def main() -> int:
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    cases = build_cases()

    beats: list[Beat] = []      # flat stimulus beats
    starts: list[int] = []      # index where each packet begins
    expected: list[Beat] = []
    sideband: list[int] = []    # one src_ip per OUTPUT packet
    notes: list[str] = []
    marks: dict = {}            # stimulus beat index -> description, for the waveform
    exp_marks: dict = {}        # expected beat index -> description, for compare_beats
    sb_marks: dict = {}         # sideband index  -> description, for compare_beats

    for desc, pkt in cases:
        starts.append(len(beats))
        marks[len(beats)] = desc
        beats.extend(bytes_to_beats(pkt))
        out_beats = model_rx_ipv4(pkt, CONF_IP)
        si = model_rx_ipv4_sideband(pkt, CONF_IP)
        if out_beats:
            assert si is not None, f"{desc}: emits output but no src_ip"
            # tag before extending, so the index is where this packet starts
            exp_marks[len(expected)] = desc
            sb_marks[len(sideband)] = desc
            sideband.append(si)
        expected.extend(out_beats)
        notes.append(f"{desc}: {len(pkt)} wire bytes in -> {len(out_beats)} beats out")
    starts_set = set(starts)

    # Internal consistency: one sideband sample per emitted packet.
    n_pkts_out = sum(1 for b in expected if b.tlast == 1)
    assert len(sideband) == n_pkts_out, \
        f"sideband {len(sideband)} != output packets {n_pkts_out}"

    # Three input-timing patterns over the SAME beats. Expected output is
    # identical for all three -- input timing must not change what comes out.
    rng = random.Random(SEED ^ 0x5A5A)
    variants = {
        # zero gaps: the no-backpressure stress case the RX path is designed for
        "gapless": [0] * len(beats),
        # idle only between packets: ordinary sparse traffic
        "ipg": [rng.randrange(1, 12) if i in starts_set else 0
                for i in range(len(beats))],
        # bubbles anywhere, including mid-packet: an upstream stall in the
        # MAC -> FIFO -> circular_buffer_filter -> rx_eth chain looks like this
        "random": [rng.randrange(0, 6) if rng.random() < 0.35 else 0
                   for _ in range(len(beats))],
    }

    # "gapless" gets the unsuffixed name so it matches the testbench's default
    # STIMULUS_FILE generic and runs with no -generic_top override.
    for name, gaps in variants.items():
        suffix = "" if name == "gapless" else f"_{name}"
        path = f"{outdir}/stimulus_rx_ipv4_tb{suffix}.txt"
        write_stimulus(path, list(zip(beats, gaps)),
                       f"rx_ipv4 stimulus ({name} input timing).\n"
                       f"conf_ip = 0x{CONF_IP:08X}\n"
                       f"5th column = idle cycles to insert BEFORE this beat.\n"
                       f"All variants share expected_axis_rx_ipv4_tb.txt.\n"
                       + "\n".join(notes), marks=marks)
        print(f"wrote {path}  ({sum(gaps)} idle cycles total)")

    write_beats(f"{outdir}/expected_axis_rx_ipv4_tb.txt", expected,
                "rx_ipv4 expected output: payload only, valid beats only.\n"
                f"conf_ip = 0x{CONF_IP:08X}\n"
                "Payload starts 4 bytes into header word 2, so every beat is\n"
                "assembled from two input words.\n"
                "Shared by every stimulus variant -- input timing must not "
                "change the output.", marks=exp_marks)

    write_sideband(f"{outdir}/expected_sideband_rx_ipv4_tb.txt", sideband, 8,
                   "rx_ipv4 src_ip, one value per OUTPUT packet.\n"
                   "Sample src_ip on the cycle m_axis_tlast is high.", marks=sb_marks)

    print(f"wrote {outdir}/expected_axis_rx_ipv4_tb.txt")
    print(f"wrote {outdir}/expected_sideband_rx_ipv4_tb.txt "
          f"({len(sideband)} packets)")
    print(f"{len(cases)} cases -> {len(beats)} stimulus beats, "
          f"{len(expected)} expected beats")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
