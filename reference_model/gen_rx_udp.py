#!/usr/bin/env python3
"""Generate stimulus + expected-output files for the rx_udp testbench.

Python owns the stimulus as well as the expected output, so the driver and the
model cannot disagree about what was sent.

Names match rx_udp_tb.vhd's generics:

  written here          read/written by the testbench
  --------------------  ------------------------------------------
  stimulus_rx_udp_tb.txt          -> STIMULUS_FILE (default, gapless)
  stimulus_rx_udp_tb_ipg.txt      -> STIMULUS_FILE via -generic_top
  stimulus_rx_udp_tb_random.txt   -> STIMULUS_FILE via -generic_top
  expected_axis_rx_udp_tb.txt        vs AXIS_FILE     (axis_rx_udp_tb.txt)
  expected_sideband_rx_udp_tb.txt    vs SIDEBAND_FILE (sideband_rx_udp_tb.txt)

    ./gen_rx_udp.py [outdir]
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import random
import sys

from uoe_model import (Beat, bytes_to_beats, model_rx_udp,
                       model_rx_udp_dst_port, model_rx_udp_sideband,
                       udp_packet, write_beats, write_sideband,
                       write_stimulus)

CONF_PORT = 0x04D2      # just one more dst_port: rx_udp does not filter on it
SEED = 0xC0FFEE


def build_cases() -> list[tuple]:
    """Each case is (description, raw UDP datagram as it arrives at rx_udp)."""
    rng = random.Random(SEED)
    # (description, datagram) or (description, datagram, arrives_flagged)
    cases: list[tuple] = []

    def payload(n: int) -> bytes:
        return bytes(rng.randrange(256) for _ in range(n))

    # src_port VARIES per packet on purpose. With a constant source port the
    # sideband check would pass even against a DUT that latches once and never
    # updates, so a changing value is what makes that test mean anything.
    src = iter(range(0x1000, 0x9000, 0x111))

    # Lengths 1..17 sweep every tkeep pattern plus the multi-beat boundaries.
    # 8 and 16 are the exact-multiple-of-8 cases, where tlast is easy to lose.
    for n in list(range(1, 18)) + [23, 24, 25, 31, 32, 33, 64, 100]:
        cases.append((f"payload {n} bytes",
                      udp_packet(next(src), CONF_PORT, payload(n))))

    # ---- destination port is reported, never filtered ----------------------
    # rx_udp forwards every datagram regardless of dst_port. rx_eth and
    # rx_ipv4 already established the frame is addressed to this node; which
    # consumer INSIDE the node wants it is a demux decision for the fabric.
    # These four ports must all come out, payload intact.
    for dst in (0x7777, 0x0001, 0xFFFF, CONF_PORT):
        cases.append((f"dst port 0x{dst:04X} -- forwarded, not filtered",
                      udp_packet(next(src), dst, payload(16))))

    # Rejected: header-only datagram, declared length 8 -> nothing to forward.
    cases.append(("header only (len=8)", udp_packet(0xBEEF, CONF_PORT, b"")))

    # Malformed: declared length below the 8-byte header. Must not underflow.
    cases.append(("malformed len=3",
                  udp_packet(0xBAD1, CONF_PORT, payload(16), length=3)))

    # Declared length shorter than the wire payload: the surplus is L2 padding
    # and must be dropped, not forwarded.
    cases.append(("padded: declared 12, wire 20",
                  udp_packet(next(src), CONF_PORT, payload(20), length=12)))

    # Declared length 8 (reject), followed by bytes that are THEMSELVES a valid
    # UDP header. If the length guard had no else branch, the FSM would stay in
    # `header`, re-parse the following beat as a header, and forward a packet
    # it was told to drop. With no port filter, ANY header-shaped bytes would
    # be accepted, so this case uses them on purpose. Expected output is
    # nothing at all; any beat is the bug.
    cases.append(("len=8 then a header-shaped payload",
                  udp_packet(0xAAAA, CONF_PORT, b"", length=8)
                  + udp_packet(0xBBBB, CONF_PORT, payload(8))))

    # A known-good packet between the two crafted cases, so each one's damage
    # is attributed to itself instead of cascading into the next failure.
    cases.append(("separator: ordinary packet",
                  udp_packet(next(src), CONF_PORT, payload(16))))

    # The mirror image: a length field claiming MORE than actually arrives.
    # Declares 40 bytes but delivers 8, so the FSM is still counting down when
    # s_axis_tlast goes by -- and keeps consuming the next packet as payload.
    # s_axis_tlast is the authoritative frame boundary; a lying length field
    # must not be able to desynchronise the parser. Expected output is the 8
    # bytes that did arrive, terminated.
    cases.append(("len=40 declared, only 8 payload bytes arrive",
                  udp_packet(next(src), CONF_PORT, payload(8), length=40)))

    cases.append(("separator: ordinary packet 2",
                  udp_packet(next(src), CONF_PORT, payload(16))))

    # Same truncation, but ending on a PARTIAL beat. The case above delivers
    # exactly 8 payload bytes, where a hardcoded tkeep=0xFF would happen to be
    # right. Five bytes needs tkeep=0xF8, so the early-termination path must
    # compute tkeep itself. Expected: one beat, tkeep=0xF8.
    cases.append(("len=40 declared, only 5 payload bytes arrive",
                  udp_packet(next(src), CONF_PORT, payload(5), length=40)))

    # The datagram ends ON the header beat: 8 wire bytes, tlast high, but the
    # length field claims 40. If the header state ignored s_axis_tlast, the FSM
    # would latch the length, move to payload with the frame already over, and
    # eat the next packet. Nothing should come out.
    cases.append(("len=40 declared, datagram ends on the header beat",
                  udp_packet(next(src), CONF_PORT, b"", length=40)))

    cases.append(("packet after header-beat truncation -- must survive",
                  udp_packet(next(src), CONF_PORT, payload(16))))

    # The same header-beat truncation, but with the declared length CHOSEN so
    # that rx_udp's countdown lands exactly on the end of the next packet.
    # Declared 32 -> total_len_buffer 24 -> three 8-byte beats, which is
    # precisely the following 24-byte datagram. If the countdown could run past
    # tlast it would complete normally, with tuser = 0, and hand the consumer
    # another packet's header and payload as clean data.
    # Nothing should come out for this one.
    cases.append(("len=32 chosen to swallow the next packet exactly",
                  udp_packet(next(src), CONF_PORT, b"", length=32)))

    cases.append(("victim of the exact-swallow -- must survive",
                  udp_packet(next(src), CONF_PORT, payload(16))))

    # ---- a frame rx_ipv4 already flagged as truncated ----------------------
    # These arrive with tuser on their LAST beat, which is what rx_ipv4 emits
    # when IP Total Length ran past the end of the frame. rx_udp has no way to
    # re-check the payload -- it does not verify the UDP checksum -- so it
    # distrusts the whole frame and passes the flag on.
    #
    # The datagram here fills the frame exactly, so the flag arrives while the
    # packet is still open and must come out on the output's last beat.
    cases.append(("upstream-flagged frame, datagram fills it -- flag propagates",
                  udp_packet(next(src), CONF_PORT, payload(16)), True))

    # Same, ending on a partial beat, so the flag has to survive the tkeep
    # recomputation in the countdown-complete branch.
    cases.append(("upstream-flagged frame, partial last beat",
                  udp_packet(next(src), CONF_PORT, payload(13)), True))

    # Here the declared UDP length ends BEFORE the frame does -- the remaining
    # bytes are L2 padding. rx_udp emits tlast while still in the payload
    # state, then dumps the padding, so the upstream flag lands after the
    # packet has already been declared finished and cannot be propagated.
    # Expected output is therefore NOT flagged.
    cases.append(("upstream-flagged frame, padding after the datagram -- flag arrives too late",
                  udp_packet(next(src), CONF_PORT, payload(20), length=12), True))

    # One more accepted packet last, so a stale src_port left behind by any of
    # the dropped cases above would show up as a mismatch here.
    cases.append(("final accepted packet",
                  udp_packet(next(src), CONF_PORT, payload(12))))

    return cases


def main() -> int:
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    cases = build_cases()

    beats: list[Beat] = []      # flat stimulus beats
    starts: list[int] = []      # index where each packet begins
    expected: list[Beat] = []
    # One value per OUTPUT packet: dst_port in the high half, src_port in the
    # low half. Both are latched from the same header word, so the testbench
    # samples the pair on the FIRST beat of the packet -- dst_port is a
    # routing signal and is useless to a demux if it is only right by tlast.
    sideband: list[int] = []
    notes: list[str] = []
    marks: dict = {}            # stimulus beat index -> description, for the waveform
    exp_marks: dict = {}        # expected beat index -> description, for compare_beats
    sb_marks: dict = {}         # sideband index  -> description, for compare_beats

    for case in cases:
        desc, pkt = case[0], case[1]
        in_tuser = bool(case[2]) if len(case) > 2 else False

        starts.append(len(beats))
        marks[len(beats)] = desc

        in_beats = bytes_to_beats(pkt)
        if in_tuser and in_beats:
            # arrives already flagged by rx_ipv4, on the last beat with tlast
            last = in_beats[-1]
            in_beats[-1] = Beat(last.tdata, last.tkeep, last.tlast, 1)
        beats.extend(in_beats)

        out_beats = model_rx_udp(pkt, in_tuser)
        sp = model_rx_udp_sideband(pkt)
        dp = model_rx_udp_dst_port(pkt)
        if out_beats:
            assert sp is not None, f"{desc}: emits output but no src_port"
            assert dp is not None, f"{desc}: emits output but no dst_port"
            # tag before extending, so the index is where this packet starts
            exp_marks[len(expected)] = desc
            sb_marks[len(sideband)] = desc
            sideband.append((dp << 16) | sp)
        expected.extend(out_beats)
        notes.append(f"{desc}: {len(pkt)} bytes in -> {len(out_beats)} beats out")
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
        # MAC -> FIFO -> circular_buffer_filter -> rx_eth -> rx_ipv4 chain looks like this
        "random": [rng.randrange(0, 6) if rng.random() < 0.35 else 0
                   for _ in range(len(beats))],
    }

    # "gapless" gets the unsuffixed name so it matches the testbench's default
    # STIMULUS_FILE generic and runs with no -generic_top override.
    for name, gaps in variants.items():
        suffix = "" if name == "gapless" else f"_{name}"
        path = f"{outdir}/stimulus_rx_udp_tb{suffix}.txt"
        write_stimulus(path, list(zip(beats, gaps)),
                       f"rx_udp stimulus ({name} input timing).\n"
                       f"dst_port is NOT filtered; conf_port 0x{CONF_PORT:04X} is only one of several tested.\n"
                       f"5th column = idle cycles to insert BEFORE this beat.\n"
                       f"All variants share expected_axis_rx_udp_tb.txt.\n"
                       + "\n".join(notes), marks=marks)
        print(f"wrote {path}  ({sum(gaps)} idle cycles total)")

    write_beats(f"{outdir}/expected_axis_rx_udp_tb.txt", expected,
                "rx_udp expected output: payload only, valid beats only.\n"
                f"Every datagram is forwarded whatever its dst_port.\n"
                "Shared by every stimulus variant -- input timing must not "
                "change the output.", marks=exp_marks)

    write_sideband(f"{outdir}/expected_sideband_rx_udp_tb.txt", sideband, 8,
                   "rx_udp dst_port & src_port, one value per OUTPUT packet.\n"
                   "High 16 bits dst_port, low 16 bits src_port.\n"
                   "Sampled on the FIRST beat of each packet, not on tlast:\n"
                   "dst_port routes the packet, so it must be right at beat 0.",
                   marks=sb_marks)

    print(f"wrote {outdir}/expected_axis_rx_udp_tb.txt")
    print(f"wrote {outdir}/expected_sideband_rx_udp_tb.txt "
          f"({len(sideband)} packets)")
    print(f"{len(cases)} cases -> {len(beats)} stimulus beats, "
          f"{len(expected)} expected beats")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
