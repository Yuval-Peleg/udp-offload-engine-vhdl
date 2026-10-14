#!/usr/bin/env python3
"""Generate stimulus + expected files for the arp_handler testbench.

The full-chip test sends only a few frames this block must ignore, so this
test covers every REJECTION path. That is most of the block: the receive FSM is
seven states of "does this field match, or dump", and a check that is too loose
answers frames it should ignore -- which on a real network means replying to
somebody else's ARP.

So the cases below violate exactly one field at a time. Each is followed by a
frame that must still be answered, because a rejection that leaves the FSM in
the wrong state shows up as the NEXT request going unanswered, not as the bad
one being answered.

    ./gen_arp_handler.py [outdir]
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import random
import sys

from uoe_model import (ETHERTYPE_IPV4, arp_request,
                       bytes_to_beats, model_arp_reply, write_beats,
                       write_stimulus)

# must match the testbench
CONF_MAC = 0xDECAFBAD0101
CONF_IP = 0xC0A80101

PEER_MAC = 0xCAFEF00D0202
PEER_IP = 0xC0A80164

SEED = 0xA4B0


def patch(frame: bytes, off: int, data: bytes) -> bytes:
    return frame[:off] + data + frame[off + len(data):]


def build_cases() -> list:
    """(description, frame bytes)."""
    cases: list = []
    good = arp_request(PEER_MAC, PEER_IP, CONF_IP)

    def answered(desc, frame):
        cases.append((desc, frame))

    # baseline: a broadcast request, which is how ARP normally arrives
    answered("broadcast request for us", good)

    # unicast to our MAC is equally valid and takes the other branch of the
    # first check
    answered("unicast request for us",
             patch(good, 0, CONF_MAC.to_bytes(6, "big")))

    # --- one field wrong at a time, each followed by a good frame ----------
    rejects = [
        ("destination MAC is someone else",
         patch(good, 0, (0x001122334455).to_bytes(6, "big"))),
        ("EtherType is IPv4, not ARP",
         patch(good, 12, ETHERTYPE_IPV4.to_bytes(2, "big"))),
        ("hardware type is not Ethernet",
         patch(good, 14, (0x0002).to_bytes(2, "big"))),
        ("protocol type is not IPv4",
         patch(good, 16, (0x86DD).to_bytes(2, "big"))),
        ("hardware address length is not 6", patch(good, 18, bytes([8]))),
        ("protocol address length is not 4", patch(good, 19, bytes([6]))),
        ("operation is a REPLY, not a request",
         patch(good, 20, (2).to_bytes(2, "big"))),
        # the sender MAC in the ARP body must agree with the Ethernet header;
        # a mismatch is a malformed or spoofed frame
        ("sender MAC in body disagrees with the header",
         patch(good, 22, (0xAABBCCDDEEFF).to_bytes(6, "big"))),
        ("target IP is not ours",
         patch(good, 38, (0xC0A809FF).to_bytes(4, "big"))),
        ("target IP differs only in the low half",
         patch(good, 38, (0xC0A80199).to_bytes(4, "big"))),
        ("target IP differs only in the high half",
         patch(good, 38, (0xC0A90101).to_bytes(4, "big"))),
    ]
    for desc, frame in rejects:
        cases.append((f"reject: {desc}", frame))
        answered(f"good request after '{desc}'", good)

    # Back to back from different peers. The reply reads its snapshot at beat 5
    # while the next request overwrites the parser's registers at its own beat
    # 5, so identical peers would corrupt into the same value and pass.
    for i in range(4):
        mac = 0xAA0000000000 + (i << 8) + i
        ip = 0xC0A80180 + i
        cases.append((f"back-to-back peer {i}", arp_request(mac, ip, CONF_IP)))
    cases.append(("good request after the burst", good))

    return cases


def main() -> int:
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    cases = build_cases()

    beats: list = []
    marks: dict = {}
    expected: list = []
    exp_marks: dict = {}
    notes: list = []

    for desc, frame in cases:
        marks[len(beats)] = desc
        beats.extend(bytes_to_beats(frame))

        reply = model_arp_reply(frame, CONF_MAC, CONF_IP)
        if reply is None:
            notes.append(f"{desc}: {len(frame)} bytes -> no reply")
        else:
            exp_marks[len(expected)] = desc
            expected.extend(bytes_to_beats(reply))
            notes.append(f"{desc}: {len(frame)} bytes -> reply")

    rng = random.Random(SEED ^ 0x5A5A)
    starts = set(marks)
    variants = {
        "gapless": [0] * len(beats),
        "ipg": [rng.randrange(1, 14) if i in starts else 0
                for i in range(len(beats))],
        "random": [rng.randrange(0, 6) if rng.random() < 0.3 else 0
                   for _ in range(len(beats))],
    }

    for name, gaps in variants.items():
        suffix = "" if name == "gapless" else f"_{name}"
        path = f"{outdir}/stimulus_arp_handler_tb{suffix}.txt"
        write_stimulus(path, list(zip(beats, gaps)),
                       f"arp_handler stimulus ({name} input timing).\n"
                       f"conf_mac = 0x{CONF_MAC:012X}, conf_ip = 0x{CONF_IP:08X}\n"
                       "Each rejection violates exactly one field, and is\n"
                       "followed by a good request that must still be answered.\n"
                       + "\n".join(notes), marks=marks)
        print(f"wrote {path}  ({sum(gaps)} idle cycles total)")

    write_beats(f"{outdir}/expected_axis_arp_handler_tb.txt", expected,
                "arp_handler expected output: one 60-byte reply per request it\n"
                "should answer, and nothing at all for the rest.\n"
                "A reply that appears for a rejected frame is as much a failure\n"
                "as a missing one -- on a real network it answers for an\n"
                "address that is not ours.", marks=exp_marks)

    print(f"wrote {outdir}/expected_axis_arp_handler_tb.txt")
    print(f"{len(cases)} frames -> {len(beats)} stimulus beats, "
          f"{len(expected)} expected beats ({len(expected)//8} replies)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
