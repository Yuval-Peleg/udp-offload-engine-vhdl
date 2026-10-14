#!/usr/bin/env python3
"""Split a captured stream into one file per source tag.

axis_priority_handler merges two inputs onto one output, and nothing in the
design fixes how they interleave -- an s0 packet overtaking queued s1 data is
the block working. So a single expected file would be testing the arbiter's
schedule, which is not specified behaviour.

Splitting on the first byte of each packet keeps everything that IS specified:
within a stream, order and bytes must match exactly, and every packet must
land in exactly one class. A packet that was interleaved with another shows up
as a byte mismatch in whichever class it was filed under, which is why the tag
is in the payload rather than tracked out of band.

    ./split_by_tag.py axis_axis_priority_handler_tb.txt out_prefix A0 B0

writes out_prefix_a0.txt, out_prefix_b0.txt and out_prefix_other.txt. The last
should be empty -- a packet landing there carries a first byte that neither
stream ever sent, which is a framing bug rather than a classification question.
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import sys

from uoe_model import packets, read_beats


def first_byte(pkt) -> int:
    """Byte 0 of the packet: tdata(63:56) of its first beat, if kept."""
    b = pkt[0]
    if not (b.tkeep & 0x80):
        return -1
    return (b.tdata >> 56) & 0xFF


def write(path: str, beats, label: str) -> None:
    with open(path, "w") as f:
        f.write(f"# {label}, split from the capture by the tag in byte 0\n")
        for b in beats:
            f.write(str(b) + "\n")


def main() -> int:
    if len(sys.argv) != 5:
        sys.exit("usage: split_by_tag.py <capture.txt> <out_prefix> <tagA hex> <tagB hex>")
    src, prefix = sys.argv[1], sys.argv[2]
    tag_a, tag_b = int(sys.argv[3], 16), int(sys.argv[4], 16)

    buckets = {tag_a: [], tag_b: [], -1: []}
    counts = {tag_a: 0, tag_b: 0, -1: 0}
    truncated = 0

    for pkt in packets(read_beats(src)):
        if not pkt[-1].tlast:
            truncated += 1
        t = first_byte(pkt)
        key = t if t in buckets else -1
        buckets[key].extend(pkt)
        counts[key] += 1

    write(f"{prefix}_{tag_a:02x}.txt", buckets[tag_a], f"tag {tag_a:02X}")
    write(f"{prefix}_{tag_b:02x}.txt", buckets[tag_b], f"tag {tag_b:02X}")
    write(f"{prefix}_other.txt", buckets[-1], "unclassified")

    print(f"  split: {counts[tag_a]} tagged {tag_a:02X}, "
          f"{counts[tag_b]} tagged {tag_b:02X}, {counts[-1]} unclassified"
          + (f", {truncated} unterminated" if truncated else ""))

    return 1 if counts[-1] or truncated else 0


if __name__ == "__main__":
    raise SystemExit(main())
