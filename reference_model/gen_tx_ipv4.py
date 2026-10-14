#!/usr/bin/env python3
"""Generate stimulus + expected-output files for the tx_ipv4 testbench.

tx_ipv4 receives a complete UDP datagram from tx_udp and prepends a 20-byte
IPv4 header. Three things make it the most delicate of the tx blocks:

  * the header is 20 bytes, so the payload lands 4 bytes out of alignment.
    Every output beat is stitched from two input words, and a packet can need
    one extra beat at the end that has no input word behind it at all.

  * Total Length is built from the UDP length field inside the payload, not
    from what actually arrives. tx_udp pads without counting the pad, so the
    two genuinely differ, and the block clamps to MIN_UDP_LEN = 26 to work out
    how many bytes are really on the wire.

  * the header checksum. RFC 1071 with the end-around carry, which must be
    folded until no carry is left.

The Identification field increments once per packet, so a case that emitted
nothing would knock every later packet's checksum out. That makes this file's
expected output sensitive to packet COUNT in a way the others are not.

    ./gen_tx_ipv4.py [outdir]
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import random
import sys

from uoe_model import (MIN_UDP_PAYLOAD_LEN, bytes_to_beats,
                       model_tx_ipv4, udp_header, write_beats, write_stimulus)

CONF_IP = 0xC0A80164        # 192.168.1.100 -- our address
DST_IP = 0xC0A80101         # 192.168.1.1   -- theirs
SRC_PORT = 0x04D2
DST_PORT = 0x1234
SEED = 0xC0FFEE


def datagram(payload: bytes) -> bytes:
    """A UDP datagram exactly as tx_udp would have produced it: length field
    counts real payload, wire is padded up to the 18-byte minimum."""
    declared = 8 + len(payload)
    wire = payload + b"\x00" * max(0, MIN_UDP_PAYLOAD_LEN - len(payload))
    return udp_header(SRC_PORT, DST_PORT, declared, 0) + wire


def build_cases() -> list:
    rng = random.Random(SEED)
    cases: list = []

    def payload(n: int) -> bytes:
        return bytes(rng.randrange(256) for _ in range(n))

    # Around the padding clamp: below 18 the datagram is padded and the length
    # field understates the wire, at and above it they agree.
    for n in (0, 1, 4, 8, 15, 16, 17, 18, 19, 20):
        cases.append((f"udp payload {n} bytes (declared {8+n})", datagram(payload(n))))

    # The realignment sweep. A 20-byte header shifts everything by 4, so the
    # residue of (datagram length mod 8) decides whether a final beat with no
    # input word behind it is needed. These cover every residue twice.
    for n in range(18, 34):
        cases.append((f"udp payload {n} bytes", datagram(payload(n))))

    for n in (100, 256, 1000):
        cases.append((f"udp payload {n} bytes", datagram(payload(n))))

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

    for ident, (desc, dgram) in enumerate(cases):
        starts.append(len(beats))
        marks[len(beats)] = desc
        beats.extend(bytes_to_beats(dgram))

        # ident counts packets: the RTL's id field starts at 0 and increments
        # once per packet, and it is covered by the header checksum.
        out_beats = model_tx_ipv4(dgram, CONF_IP, DST_IP, ident=ident)
        exp_marks[len(expected)] = desc
        expected.extend(out_beats)
        notes.append(f"{desc}: {len(dgram)} bytes in -> {len(out_beats)} beats out")

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
        path = f"{outdir}/stimulus_tx_ipv4_tb{suffix}.txt"
        write_stimulus(path, list(zip(beats, gaps)),
                       f"tx_ipv4 stimulus ({name} input timing).\n"
                       f"conf_ip = 0x{CONF_IP:08X}, dst_ip = 0x{DST_IP:08X}\n"
                       f"Complete UDP datagrams, as tx_udp would emit them.\n"
                       f"All variants share expected_axis_tx_ipv4_tb.txt.\n"
                       + "\n".join(notes), marks=marks)
        print(f"wrote {path}  ({sum(gaps)} idle cycles total)")

    write_beats(f"{outdir}/expected_axis_tx_ipv4_tb.txt", expected,
                "tx_ipv4 expected output: IPv4 header + the datagram.\n"
                f"conf_ip = 0x{CONF_IP:08X}, dst_ip = 0x{DST_IP:08X}\n"
                "Total Length counts the DECLARED udp length, so a padded\n"
                "datagram declares less than it puts on the wire.\n"
                "The Identification field increments once per packet and is\n"
                "covered by the checksum, so a dropped packet shifts every\n"
                "later header.", marks=exp_marks)

    print(f"wrote {outdir}/expected_axis_tx_ipv4_tb.txt")
    print(f"{len(cases)} cases -> {len(beats)} stimulus beats, "
          f"{len(expected)} expected beats")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
