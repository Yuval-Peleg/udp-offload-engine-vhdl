#!/usr/bin/env python3
"""Generate stimulus + expected-output files for the tx_udp testbench.

Same shape as the rx generators. What tx_udp has to get right:

  * it buffers the whole payload to learn its length, then emits an 8-byte
    UDP header in front of it. An 8-byte header is one whole bus word, so
    unlike every other block here there is NO realignment -- payload words
    pass through untouched.

  * padding. The final Ethernet frame must reach 60 bytes, which after the
    14 + 20 + 8 bytes of header means at least 18 bytes of UDP payload.
    tx_udp pads up to that, and the pad is deliberately NOT counted in the
    length field: the field describes real data while the wire carries more.

The padding boundary is where the interesting cases are. The RTL has three
separate paths through it -- pad starts mid-word, pad starts on the next word,
and the single-byte case data_len = 17 which it special-cases by name -- so
the sweep below covers every payload length from 1 to 20 rather than sampling
(0 is not a drivable AXI-Stream packet).

    ./gen_tx_udp.py [outdir]
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import random
import sys

from uoe_model import (bytes_to_beats, model_tx_udp, write_beats,
                       write_stimulus)

CONF_PORT = 0x04D2      # our source port -- must match the testbench
DST_PORT = 0x1234       # where we are sending -- must match the testbench
SEED = 0xC0FFEE


def build_cases() -> list:
    """Each case is (description, raw payload as the user hands it to tx_udp)."""
    rng = random.Random(SEED)
    cases: list = []

    def payload(n: int) -> bytes:
        return bytes(rng.randrange(256) for _ in range(n))

    # 0..20 walks the whole padding boundary. 17 is the RTL's named special
    # case (exactly one byte of padding, finishing in the same word); 18 is the
    # first length needing none; 16 is the last that starts padding on a fresh
    # word because the data filled the previous one exactly.
    for n in range(0, 21):
        cases.append((f"payload {n} bytes", payload(n)))

    # Past the padding threshold, what matters is where the payload ends
    # relative to the 8-byte bus: these sit either side of three word boundaries.
    for n in (23, 24, 25, 31, 32, 33, 39, 40, 41):
        cases.append((f"payload {n} bytes", payload(n)))

    # Larger, multi-beat packets well past the padding logic.
    for n in (100, 256, 1000):
        cases.append((f"payload {n} bytes", payload(n)))

    # Back-to-back small packets: the length FIFO and the packet FIFO have to
    # stay in step. If they ever disagree, a packet takes the length of its
    # neighbour and everything after it is wrong.
    for n in (1, 2, 1, 19, 1):
        cases.append((f"back-to-back {n} bytes", payload(n)))

    return cases


def main() -> int:
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    cases = build_cases()

    beats: list = []
    starts: list = []
    expected: list = []
    notes: list = []
    marks: dict = {}
    exp_marks: dict = {}

    for desc, pl in cases:
        starts.append(len(beats))
        marks[len(beats)] = desc

        in_beats = bytes_to_beats(pl)
        if not in_beats:
            # A zero-length payload cannot be driven as an AXIS packet at all
            # -- there is no beat to carry tlast. Leave it off the wire; the
            # header notes still list it as skipped.
            notes.append(f"{desc}: not drivable (no beats), skipped")
            starts.pop()
            del marks[len(beats)]
            continue

        beats.extend(in_beats)
        out_beats = model_tx_udp(pl, CONF_PORT, DST_PORT)
        exp_marks[len(expected)] = desc
        expected.extend(out_beats)
        notes.append(f"{desc}: {len(pl)} bytes in -> {len(out_beats)} beats out")

    starts_set = set(starts)

    rng = random.Random(SEED ^ 0x5A5A)
    variants = {
        # the user's application feeding us as fast as it can
        "gapless": [0] * len(beats),
        # idle between packets: an application that sends a burst then thinks
        "ipg": [rng.randrange(1, 12) if i in starts_set else 0
                for i in range(len(beats))],
        # bubbles anywhere: an application that cannot sustain line rate
        "random": [rng.randrange(0, 6) if rng.random() < 0.35 else 0
                   for _ in range(len(beats))],
    }

    for name, gaps in variants.items():
        suffix = "" if name == "gapless" else f"_{name}"
        path = f"{outdir}/stimulus_tx_udp_tb{suffix}.txt"
        write_stimulus(path, list(zip(beats, gaps)),
                       f"tx_udp stimulus ({name} input timing).\n"
                       f"conf_port = 0x{CONF_PORT:04X}, dst_port = 0x{DST_PORT:04X}\n"
                       f"Payload only -- tx_udp builds the header itself.\n"
                       f"All variants share expected_axis_tx_udp_tb.txt.\n"
                       + "\n".join(notes), marks=marks)
        print(f"wrote {path}  ({sum(gaps)} idle cycles total)")

    write_beats(f"{outdir}/expected_axis_tx_udp_tb.txt", expected,
                "tx_udp expected output: UDP header + payload, padded to "
                "18 payload bytes.\n"
                f"conf_port = 0x{CONF_PORT:04X}, dst_port = 0x{DST_PORT:04X}\n"
                "The length field counts real payload only, never the padding.\n"
                "Shared by every stimulus variant -- neither input timing nor "
                "output backpressure may change the bytes.", marks=exp_marks)

    print(f"wrote {outdir}/expected_axis_tx_udp_tb.txt")
    print(f"{len(cases)} cases -> {len(beats)} stimulus beats, "
          f"{len(expected)} expected beats")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
