#!/usr/bin/env python3
"""Generate stimulus + expected files for the circular_buffer_filter testbench.

This block drops a frame on two conditions:

  * tuser asserted with tlast, meaning the MAC condemned the frame
  * the frame does not fit in the buffer, so it can never be committed

Both use the same mechanism: `wr_ptr <= commit_ptr` rolls the write pointer
back, and the reader -- bounded by commit_ptr -- never sees the frame at all.

What makes the test worth having is not that a bad frame disappears. It is that
the frame AFTER it survives. A rollback that leaves the pointers inconsistent
shows up as the next good frame being mangled, not as the bad one appearing, so
every drop case here is followed by a known-good frame.

    ./gen_circular_buffer_filter.py [outdir]
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import random
import sys

from uoe_model import (CIRC_FIFO_BEATS, Beat, bytes_to_beats, write_beats,
                       write_stimulus)

SEED = 0xC1BCF


def build_cases() -> list:
    """(description, payload bytes, mac_error) -- one entry per frame in."""
    rng = random.Random(SEED)
    cases: list = []

    def payload(n: int) -> bytes:
        return bytes(rng.randrange(256) for _ in range(n))

    # The block is payload-agnostic: it moves beats, it does not parse them.
    # So the sizes that matter are the ones that exercise tkeep and the beat
    # count, not protocol boundaries. 1..8 gives every final-beat tkeep, which
    # matters because the BRAM stores tkeep packed as a 3-bit count.
    for n in (1, 2, 3, 4, 5, 6, 7, 8, 9, 16, 17, 64, 200):
        cases.append((f"pass {n} bytes", payload(n), 0))

    # A frame the MAC condemned. It must vanish whole -- not partly.
    cases.append(("MAC error, 64 bytes", payload(64), 1))
    cases.append(("good frame after MAC error", payload(48), 0))

    # Two condemned in a row, then a good one: proves the rollback is idempotent
    # and does not leave commit_ptr trailing.
    cases.append(("MAC error, 24 bytes", payload(24), 1))
    cases.append(("MAC error, 80 bytes", payload(80), 1))
    cases.append(("good frame after two errors", payload(56), 0))

    # A single-beat frame either side of a dropped one. The rollback path and
    # the commit path meet on the same beat here, which is where an off-by-one
    # in wr_ptr would show.
    cases.append(("single beat, dropped", payload(8), 1))
    cases.append(("single beat, kept", payload(8), 0))

    # Capacity. The buffer holds CIRC_FIFO_BEATS beats; a frame of exactly that
    # many should still commit, and anything past it can never complete and
    # must be discarded by the dumping guard.
    cases.append((f"exactly {CIRC_FIFO_BEATS} beats", payload(CIRC_FIFO_BEATS * 8), 0))
    cases.append(("good frame after full-capacity frame", payload(32), 0))

    cases.append(("oversized, must be dropped", payload((CIRC_FIFO_BEATS + 50) * 8), 0))
    cases.append(("good frame after oversized", payload(40), 0))

    return cases


def main() -> int:
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    cases = build_cases()

    beats: list = []
    marks: dict = {}
    expected: list = []
    exp_marks: dict = {}
    notes: list = []

    for desc, pl, mac_error in cases:
        marks[len(beats)] = desc
        in_beats = bytes_to_beats(pl)
        if mac_error:
            last = in_beats[-1]
            in_beats[-1] = Beat(last.tdata, last.tkeep, 1, 1)
        beats.extend(in_beats)

        too_big = len(in_beats) > CIRC_FIFO_BEATS
        if mac_error:
            notes.append(f"{desc}: {len(in_beats)} beats, tuser -> dropped")
        elif too_big:
            notes.append(f"{desc}: {len(in_beats)} beats > {CIRC_FIFO_BEATS} -> dropped")
        else:
            exp_marks[len(expected)] = desc
            expected.extend(in_beats)
            notes.append(f"{desc}: {len(in_beats)} beats -> forwarded unchanged")

    rng = random.Random(SEED ^ 0x5A5A)
    starts = set(marks)
    variants = {
        # back to back, as the MAC delivers them
        "gapless": [0] * len(beats),
        # idle between frames
        "ipg": [rng.randrange(1, 12) if i in starts else 0 for i in range(len(beats))],
        # bubbles anywhere, including mid-frame
        "random": [rng.randrange(0, 6) if rng.random() < 0.3 else 0
                   for _ in range(len(beats))],
    }

    for name, gaps in variants.items():
        suffix = "" if name == "gapless" else f"_{name}"
        path = f"{outdir}/stimulus_circular_buffer_filter_tb{suffix}.txt"
        write_stimulus(path, list(zip(beats, gaps)),
                       f"circular_buffer_filter stimulus ({name} input timing).\n"
                       "The 4th column is tuser: the MAC's error flag, raised\n"
                       "with tlast to condemn the frame it ends.\n"
                       + "\n".join(notes), marks=marks)
        print(f"wrote {path}  ({sum(gaps)} idle cycles total)")

    write_beats(f"{outdir}/expected_axis_circular_buffer_filter_tb.txt", expected,
                "circular_buffer_filter expected output: every frame that was\n"
                "neither condemned by tuser nor too big to buffer, forwarded\n"
                "byte for byte. Frames that were dropped must not appear at\n"
                "all -- not truncated, not partial.\n"
                "Shared by every stimulus variant: input timing must not change\n"
                "which frames survive.", marks=exp_marks)

    print(f"wrote {outdir}/expected_axis_circular_buffer_filter_tb.txt")
    print(f"{len(cases)} frames -> {len(beats)} stimulus beats, "
          f"{len(expected)} expected beats")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
