#!/usr/bin/env python3
"""Generate stimulus + expected files for the axis_priority_handler testbench.

The block merges two AXI-Stream inputs onto one output, giving s0 priority and
never switching mid-packet. Testing it has the same shape as testing uoe's
mac_tx: nothing in the design fixes how the two streams interleave, so
comparing against one merged expected file would be testing the arbiter's
SCHEDULE, which is not specified behaviour.

What IS specified, and what this checks:

  * every packet arrives whole and unmodified
  * within one stream, packets keep their order
  * no packet is ever interleaved with another

The first byte of every payload tags its source -- 0xA0 for s0, 0xB0 for s1 --
so split_by_tag.py can separate the capture and compare each stream in order.
The tag is what turns "the output is a jumble" into "these two streams are each
intact"; without it an interleaved packet would look like corruption with no
way to tell which stream lost its place.

Two stimulus files are written, one per input port.

    ./gen_axis_priority_handler.py [outdir]
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import random
import sys

from uoe_model import bytes_to_beats, write_beats, write_stimulus

SEED = 0xA1B2

TAG_S0 = 0xA0
TAG_S1 = 0xB0


def stream_cases(tag: int, label: str, sizes, rng) -> list:
    """(description, payload) with the source tag in byte 0."""
    out = []
    for n in sizes:
        body = bytes([tag]) + bytes(rng.randrange(256) for _ in range(n - 1))
        out.append((f"{label} {n} bytes", body))
    return out


def main() -> int:
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    rng = random.Random(SEED)

    # Sizes chosen for the arbiter, not for any protocol: one beat (the case
    # that can strand the FSM in `transmitting`), partial final beats, and long
    # packets that hold the arbiter across the other stream becoming ready.
    # The LAST s0 packet is a single beat on purpose. s0 runs dry long before
    # s1 does, so if the arbiter latches onto s0 for a packet that already
    # finished, it waits for a tlast that never comes and s1 is blocked for the
    # rest of the run.
    # s1 carries single-beat packets too. A single s1 beat offered while
    # m_axis_tready is low must stay on the output until accepted, even if s0
    # turns valid meanwhile; the checker's "tdata changed while stalled"
    # catches it. Both streams open with a run of single-beat packets so the
    # two overlap in time; otherwise s0 runs dry before the race can happen.
    singles = [rng.randrange(1, 9) for _ in range(40)]
    s0 = stream_cases(TAG_S0, "s0 arp-like",
                      singles[:20] + [8, 60, 60, 16, 60, 128, 60, 8], rng)
    s1 = stream_cases(TAG_S1, "s1 tx-like",
                      singles[20:] + [60, 200, 1000, 60, 400, 60, 9000, 60], rng)

    for port, cases, other in (("s0", s0, "s1"), ("s1", s1, "s0")):
        beats: list = []
        marks: dict = {}
        expected: list = []
        exp_marks: dict = {}
        notes: list = []
        for desc, pl in cases:
            marks[len(beats)] = desc
            exp_marks[len(expected)] = desc
            b = bytes_to_beats(pl)
            beats.extend(b)
            expected.extend(b)
            notes.append(f"{desc}: {len(b)} beats")

        rng2 = random.Random(SEED ^ (0 if port == "s0" else 0x5A5A))
        starts = set(marks)
        variants = {
            "gapless": [0] * len(beats),
            "ipg": [rng2.randrange(1, 20) if i in starts else 0
                    for i in range(len(beats))],
            "random": [rng2.randrange(0, 8) if rng2.random() < 0.3 else 0
                       for _ in range(len(beats))],
        }
        for name, gaps in variants.items():
            suffix = "" if name == "gapless" else f"_{name}"
            # s0 is the block's primary stimulus, so it takes the plain name
            # run_tests.sh builds; s1 is the extra one it passes only when the
            # file exists.
            tag = "" if port == "s0" else "_s1"
            path = f"{outdir}/stimulus_axis_priority_handler_tb{tag}{suffix}.txt"
            write_stimulus(path, list(zip(beats, gaps)),
                           f"axis_priority_handler {port} stimulus "
                           f"({name} input timing).\n"
                           f"Byte 0 of every payload is 0x{TAG_S0 if port=='s0' else TAG_S1:02X}, "
                           f"which is how the capture is split from {other}.\n"
                           + "\n".join(notes), marks=marks)

        write_beats(f"{outdir}/expected_axis_axis_priority_handler_tb_{port}.txt",
                    expected,
                    f"axis_priority_handler expected output, {port} packets only.\n"
                    "The two streams are compared separately: the arbiter decides\n"
                    "how they interleave and nothing specifies that order, but\n"
                    "within one stream order and bytes must match exactly.",
                    marks=exp_marks)

        print(f"wrote {port}: {len(beats)} stimulus beats, {len(expected)} expected")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
