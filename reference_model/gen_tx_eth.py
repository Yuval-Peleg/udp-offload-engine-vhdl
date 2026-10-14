#!/usr/bin/env python3
"""Generate stimulus + expected-output files for the tx_eth testbench.

tx_eth receives a complete IPv4 packet from tx_ipv4 and prepends the 14-byte
Ethernet II header: destination MAC, source MAC, ethertype.

14 bytes is not a multiple of 8, so the payload lands 6 bytes out of
alignment. Every output beat is stitched from two input words, and what
decides whether a final flush beat is needed is the number of valid bytes in
the LAST input word:

    last word bytes   6 carried + N    output
    ---------------   -------------    -------------------------------
    1                 7                fits one beat (the RTL's tkeep=FE case)
    2                 8                fits one beat exactly
    3 .. 8            9 .. 14          one beat + a flush beat

So consecutive input lengths are what matter, and the sweep below covers every
residue of (packet length mod 8) several times.

Unlike tx_udp there is no padding here -- tx_udp already guaranteed the frame
will reach 60 bytes, so tx_eth only ever prepends and forwards.

    ./gen_tx_eth.py [outdir]
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import random
import sys

from uoe_model import (IPV4_HEADER_LEN, MIN_UDP_PAYLOAD_LEN,
                       bytes_to_beats, ipv4_header, model_tx_eth, udp_header,
                       write_beats, write_stimulus)

CONF_MAC = 0x02DEADBEEF01       # ours -- locally administered
DST_MAC = 0x02CAFEF00D02        # theirs
CONF_IP = 0xC0A80164
DST_IP = 0xC0A80101
SRC_PORT = 0x04D2
DST_PORT = 0x1234
SEED = 0xC0FFEE


def ip_packet(payload: bytes) -> bytes:
    """A complete IPv4/UDP packet as tx_ipv4 would have produced it."""
    declared = 8 + len(payload)
    wire = payload + b"\x00" * max(0, MIN_UDP_PAYLOAD_LEN - len(payload))
    dgram = udp_header(SRC_PORT, DST_PORT, declared, 0) + wire
    hdr = ipv4_header(CONF_IP.to_bytes(4, "big"), DST_IP.to_bytes(4, "big"),
                      0, total_len=IPV4_HEADER_LEN + declared)
    return hdr + dgram


def build_cases() -> list:
    rng = random.Random(SEED)
    cases: list = []

    def payload(n: int) -> bytes:
        return bytes(rng.randrange(256) for _ in range(n))

    # Consecutive UDP payload sizes walk the packet length one byte at a time,
    # which is what sweeps the 6-byte realignment through every residue.
    for n in range(18, 42):
        cases.append((f"udp payload {n} bytes", ip_packet(payload(n))))

    # Below the padding threshold the packet is a fixed 46 bytes whatever the
    # payload, so these all exercise the same shape -- kept as a sanity check
    # that a minimum-size frame still comes out right.
    for n in (0, 1, 8, 17):
        cases.append((f"minimum frame, udp payload {n} bytes",
                      ip_packet(payload(n))))

    for n in (100, 256, 1000):
        cases.append((f"udp payload {n} bytes", ip_packet(payload(n))))

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

    for desc, pkt in cases:
        starts.append(len(beats))
        marks[len(beats)] = desc
        beats.extend(bytes_to_beats(pkt))

        out_beats = model_tx_eth(pkt, CONF_MAC, DST_MAC)
        exp_marks[len(expected)] = desc
        expected.extend(out_beats)
        notes.append(f"{desc}: {len(pkt)} bytes in -> {len(out_beats)} beats out")

    starts_set = set(starts)

    rng = random.Random(SEED ^ 0x5A5A)
    variants = {
        "gapless": [0] * len(beats),
        "ipg": [rng.randrange(1, 12) if i in starts_set else 0
                for i in range(len(beats))],
        "random": [rng.randrange(0, 6) if rng.random() < 0.35 else 0
                   for _ in range(len(beats))],
    }

    for name, gaps in variants.items():
        suffix = "" if name == "gapless" else f"_{name}"
        path = f"{outdir}/stimulus_tx_eth_tb{suffix}.txt"
        write_stimulus(path, list(zip(beats, gaps)),
                       f"tx_eth stimulus ({name} input timing).\n"
                       f"conf_mac = 0x{CONF_MAC:012X}, dst_mac = 0x{DST_MAC:012X}\n"
                       f"Complete IPv4 packets, as tx_ipv4 would emit them.\n"
                       f"All variants share expected_axis_tx_eth_tb.txt.\n"
                       + "\n".join(notes), marks=marks)
        print(f"wrote {path}  ({sum(gaps)} idle cycles total)")

    write_beats(f"{outdir}/expected_axis_tx_eth_tb.txt", expected,
                "tx_eth expected output: Ethernet II header + the packet.\n"
                f"conf_mac = 0x{CONF_MAC:012X}, dst_mac = 0x{DST_MAC:012X}\n"
                "No padding here -- tx_udp already guaranteed the 60-byte\n"
                "minimum frame, so tx_eth only prepends and forwards.",
                marks=exp_marks)

    print(f"wrote {outdir}/expected_axis_tx_eth_tb.txt")
    print(f"{len(cases)} cases -> {len(beats)} stimulus beats, "
          f"{len(expected)} expected beats")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
