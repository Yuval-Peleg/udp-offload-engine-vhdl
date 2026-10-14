#!/usr/bin/env python3
"""Split a captured mac_tx stream into one file per EtherType.

uoe has two producers feeding one output port: the TX datapath and the ARP
responder, arbitrated by axis_priority_handler. Nothing in the design fixes
their relative order -- an ARP reply overtakes queued TX data by design, and
how many TX frames pass between two replies depends on arbitration timing that
is not part of the specification.

So comparing mac_tx against one expected file would be testing the arbiter's
scheduling, which is not defined behaviour. Splitting by EtherType keeps
everything that IS defined: within a class, order and bytes must match exactly,
and every packet must appear in exactly one class.

    ./split_mac_tx.py axis_uoe_tb_mac_tx.txt out_prefix

writes out_prefix_ipv4.txt and out_prefix_arp.txt. Any packet that is neither
is written to out_prefix_other.txt, which the caller should expect to be empty
-- a packet landing there is a framing bug, not a classification question.

The capture is byte-swapped (the MAC convention), so the EtherType is read
back through the same swap the generator applied.
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import sys

from uoe_model import (ETHERTYPE_ARP, ETHERTYPE_IPV4, beats_to_bytes, packets,
                       read_beats, swap_beats)


def ethertype(pkt) -> int:
    """Bytes 12:14 of the frame, read through the MAC-side byte swap."""
    data = beats_to_bytes(swap_beats(pkt[:2]))
    if len(data) < 14:
        return -1
    return int.from_bytes(data[12:14], "big")


def write(path: str, beats, label: str) -> None:
    with open(path, "w") as f:
        f.write(f"# {label}, split from the mac_tx capture by EtherType\n")
        for b in beats:
            f.write(str(b) + "\n")


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit("usage: split_mac_tx.py <capture.txt> <out_prefix>")
    src, prefix = sys.argv[1], sys.argv[2]

    buckets = {ETHERTYPE_IPV4: [], ETHERTYPE_ARP: [], -1: []}
    counts = {ETHERTYPE_IPV4: 0, ETHERTYPE_ARP: 0, -1: 0}
    truncated = 0

    for pkt in packets(read_beats(src)):
        if not pkt[-1].tlast:
            truncated += 1
        et = ethertype(pkt)
        key = et if et in buckets else -1
        buckets[key].extend(pkt)
        counts[key] += 1

    write(f"{prefix}_ipv4.txt", buckets[ETHERTYPE_IPV4], "IPv4 frames")
    write(f"{prefix}_arp.txt", buckets[ETHERTYPE_ARP], "ARP replies")
    write(f"{prefix}_other.txt", buckets[-1], "unclassified")

    print(f"  mac_tx split: {counts[ETHERTYPE_IPV4]} IPv4, "
          f"{counts[ETHERTYPE_ARP]} ARP, {counts[-1]} unclassified"
          + (f", {truncated} unterminated" if truncated else ""))

    # An unclassified packet is not a judgement call -- it means something left
    # mac_tx that is not a frame this design can produce.
    return 1 if counts[-1] or truncated else 0


if __name__ == "__main__":
    raise SystemExit(main())
