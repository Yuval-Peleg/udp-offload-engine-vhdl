#!/usr/bin/env python3
"""Compare a testbench's actual output against the model's expected output.

    ./compare_beats.py expected_rx_udp.txt actual_rx_udp.txt
    ./compare_beats.py expected_rx_udp.txt actual_rx_udp.txt \\
                       expected_sideband_rx_udp.txt actual_sideband_rx_udp.txt

The optional third and fourth arguments compare latched non-AXIS outputs
(src_port, dst_port, src_mac, src_ip) -- one value per output packet.

Comparison is per PACKET, not per beat. A straight beat-by-beat diff reports
the first index where the two streams differ, which is one packet PAST the
culprit as soon as anything is dropped or duplicated: everything after the
desynchronisation mismatches, and the real problem is buried. Splitting on
tlast and resynchronising instead lets a dropped packet be named as such.

Packet names come from '# CASE <n> <text>' markers the generators write into
the expected file. Without them the output falls back to beat indices.

Exit status is 0 on match, 1 on mismatch, so it drops straight into a
regression script.
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import sys
from typing import List

from uoe_model import (beats_to_bytes, read_beats, read_beats_tagged,
                       read_sideband, read_sideband_tagged)

MAX_REPORTED = 10


def masked_tdata(b) -> int:
    """tdata with null byte lanes cleared.

    AXI-Stream defines bytes whose tkeep bit is 0 as null bytes with undefined
    content, so those lanes must NOT be compared. rx_udp forwards
    s_axis_tdata wholesale and masks only tkeep, which leaves real input data
    sitting in the masked-off lanes -- legal, and not a mismatch.
    """
    out = 0
    for i in range(8):
        if b.tkeep & (1 << (7 - i)):
            shift = 56 - 8 * i
            out |= b.tdata & (0xFF << shift)
    return out


def beat_eq(e, a) -> bool:
    return ((masked_tdata(e), e.tkeep, e.tlast, e.tuser)
            == (masked_tdata(a), a.tkeep, a.tlast, a.tuser))


def beat_diff(e, a) -> str:
    diffs = []
    if masked_tdata(e) != masked_tdata(a):
        diffs.append(f"tdata {masked_tdata(e):016X} != {masked_tdata(a):016X} "
                     f"(kept lanes only)")
    if e.tkeep != a.tkeep:
        diffs.append(f"tkeep {e.tkeep:02X} != {a.tkeep:02X}")
    if e.tlast != a.tlast:
        diffs.append(f"tlast {e.tlast} != {a.tlast}")
    if e.tuser != a.tuser:
        diffs.append(f"tuser {e.tuser} != {a.tuser}")
    return ", ".join(diffs)


def split_packets(tagged: List[tuple]) -> List[tuple]:
    """Split a flat beat list into (beats, label, first_index) per packet.

    Packets end on tlast. Trailing beats with no tlast are returned as a final
    packet anyway -- a stream that ends without tlast is itself a defect and
    should be reported, not silently dropped here.
    """
    out, cur, label, start = [], [], "", 0
    for i, (b, lab) in enumerate(tagged):
        if not cur:
            label, start = lab, i
        cur.append(b)
        if b.tlast == 1:
            out.append((cur, label, start))
            cur = []
    if cur:
        out.append((cur, label, start))
    return out


def flagged(pkt: List) -> bool:
    """True if this packet ends with tuser -- the block declared it invalid."""
    return bool(pkt) and pkt[-1].tuser == 1


def packets_eq(pe: List, pa: List) -> bool:
    """A packet the model marks INVALID is compared on its flag, not on its
    contents.

    The contract for a truncated packet is "this is marked invalid", not "this
    contains exactly these bytes". The consumer must discard it either way, so
    demanding byte-exactness there tests something nobody depends on -- and it
    would force the RTL to carry extra logic (a sticky flag, a second tkeep
    computation) purely to make discarded bytes come out precisely.

    rx_ipv4's realignment carry is the concrete case: it delivers a flagged
    packet up to 4 bytes short of what actually arrived, and still passes.

    This does NOT weaken framing. Packet-level alignment still has to hold, so
    a block that ran past a frame boundary and swallowed the next packet is
    still caught -- by the next packet going missing, which is checked here.
    """
    if flagged(pe):
        return flagged(pa)
    return len(pe) == len(pa) and all(beat_eq(e, a) for e, a in zip(pe, pa))


def name(label: str, start: int) -> str:
    return label if label else f"packet starting at beat {start}"


def compare_axis(exp_path: str, act_path: str) -> tuple:
    """Packet-aligned comparison.

    Returns (problems, pairs) where pairs lists the (expected, actual) packet
    indices that were actually lined up with each other. The sideband
    comparison reuses that alignment -- its values are one per output packet,
    so once a packet is dropped a plain index-for-index sideband diff reports
    every later value as wrong when they are merely shifted.
    """
    exp_pkts = split_packets(read_beats_tagged(exp_path))
    act_pkts = split_packets([(b, "") for b in read_beats(act_path)])

    problems = 0
    reported = 0
    pairs: List[tuple] = []

    def report(msg: str) -> None:
        nonlocal reported
        if reported < MAX_REPORTED:
            print(msg)
            reported += 1

    ei = ai = 0
    while ei < len(exp_pkts) and ai < len(act_pkts):
        pe, label, start = exp_pkts[ei]
        pa = act_pkts[ai][0]

        if packets_eq(pe, pa):
            pairs.append((ei, ai))
            ei += 1
            ai += 1
            continue

        # Dropped: what actually came out is the NEXT expected packet, so this
        # one never appeared. Resync on the expected side and carry on, rather
        # than reporting every packet after it as wrong.
        if ei + 1 < len(exp_pkts) and packets_eq(exp_pkts[ei + 1][0], pa):
            report(f"{name(label, start)}: DROPPED -- {len(pe)} beat(s) never emitted")
            problems += 1
            ei += 1
            continue

        # Extra: an unexpected packet came out before the one we wanted.
        if ai + 1 < len(act_pkts) and packets_eq(pe, act_pkts[ai + 1][0]):
            report(f"{name(label, start)}: an EXTRA packet of {len(pa)} beat(s) "
                   f"was emitted before it")
            problems += 1
            ai += 1
            continue

        # Same packet, wrong contents.
        problems += 1
        if flagged(pe):
            report(f"{name(label, start)}: expected this packet to be flagged "
                   f"invalid (tuser on its last beat), and it was not")
            pairs.append((ei, ai))
            ei += 1
            ai += 1
            continue
        if len(pe) != len(pa):
            report(f"{name(label, start)}: expected {len(pe)} beat(s), got {len(pa)}")
        for k in range(min(len(pe), len(pa))):
            if not beat_eq(pe[k], pa[k]):
                report(f"{name(label, start)}: beat {k + 1} of {len(pe)}: "
                       f"{beat_diff(pe[k], pa[k])}")
        pairs.append((ei, ai))
        ei += 1
        ai += 1

    for k in range(ei, len(exp_pkts)):
        pe, label, start = exp_pkts[k]
        report(f"{name(label, start)}: DROPPED -- {len(pe)} beat(s) never emitted")
        problems += 1
    for k in range(ai, len(act_pkts)):
        pa = act_pkts[k][0]
        report(f"EXTRA packet of {len(pa)} beat(s) after the last expected one")
        problems += 1

    if problems > reported:
        print(f"... and {problems - reported} more packet problem(s)")
    return problems, pairs


def sideband_width(path: str) -> int:
    """Hex digits the file was written with -- src_port is 4, an IP is 8."""
    width = 4
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                width = max(width, len(line.split()[0]))
    return width


def compare_sideband(exp_path: str, act_path: str, pairs=None) -> int:
    """Compare latched non-AXIS outputs. Returns the number of problems."""
    expected = read_sideband_tagged(exp_path)
    actual = read_sideband(act_path)
    bad = 0
    width = sideband_width(exp_path)

    if pairs is None:
        pairs = [(i, i) for i in range(min(len(expected), len(actual)))]

    for ei, ai in pairs:
        if ei >= len(expected) or ai >= len(actual):
            continue
        exp_v, label = expected[ei]
        if exp_v != actual[ai]:
            bad += 1
            if bad <= MAX_REPORTED:
                who = label if label else f"sideband packet {ei}"
                print(f"{who}: sideband {exp_v:0{width}X} != {actual[ai]:0{width}X}")
    if bad > MAX_REPORTED:
        print(f"... and {bad - MAX_REPORTED} more sideband mismatches")

    if len(expected) != len(actual):
        bad += 1
        print(f"sideband count: expected {len(expected)}, got {len(actual)}")

    # A latch that never updates shows up as one repeated value -- call it out,
    # since the per-packet diffs alone don't make the pattern obvious.
    if bad and actual and len(set(actual)) == 1 and len({v for v, _ in expected}) > 1:
        print(f"  note: every actual value is {actual[0]:0{width}X} -- "
              f"the register looks like it latches once and never updates")
    return bad


def main() -> int:
    if len(sys.argv) not in (3, 5):
        print(__doc__.strip(), file=sys.stderr)
        return 2

    failures, pairs = compare_axis(sys.argv[1], sys.argv[2])

    n_sideband = 0
    if len(sys.argv) == 5:
        failures += compare_sideband(sys.argv[3], sys.argv[4], pairs)
        n_sideband = len(read_sideband(sys.argv[3]))

    actual = read_beats(sys.argv[2])
    if failures == 0:
        payload = beats_to_bytes(actual)
        extra = f", {n_sideband} sideband values" if n_sideband else ""
        print(f"PASS  {len(actual)} beats, {len(payload)} payload bytes{extra} match")
        return 0

    print(f"FAIL  {failures} problem(s)")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
