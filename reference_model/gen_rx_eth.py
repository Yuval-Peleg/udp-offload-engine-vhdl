#!/usr/bin/env python3
"""Generate stimulus + expected-output files for the rx_eth testbench.

Same shape as gen_rx_udp.py and gen_rx_ipv4.py.

  written here                     read/written by the testbench
  -------------------------------  ------------------------------------------
  stimulus_rx_eth_tb.txt           -> STIMULUS_FILE (default, gapless)
  stimulus_rx_eth_tb_ipg.txt       -> STIMULUS_FILE via -generic_top
  stimulus_rx_eth_tb_random.txt    -> STIMULUS_FILE via -generic_top
  expected_axis_rx_eth_tb.txt         vs AXIS_FILE
  expected_sideband_rx_eth_tb.txt     vs SIDEBAND_FILE

    ./gen_rx_eth.py [outdir]

What this block has to get right
--------------------------------
The Ethernet II header is 14 bytes and the bus is 8, so the payload starts
6 bytes into input word 1 and every output beat is stitched from two input
words -- the same realignment as rx_ipv4, but carrying 2 bytes instead of 4.

Because the carry is 2 bytes, what decides whether a final flush beat is
needed is the number of valid bytes in the LAST input word:

    last word bytes   2 carried + N    output
    ---------------   -------------    ---------------------------------
    1 .. 6            3 .. 8           fits one beat, no flush
    7                 9                one beat + 1 flushed byte
    8                 10               one beat + 2 flushed bytes

So the frame lengths worth sweeping are consecutive ones -- every value of
(frame_len mod 8) exercises a different path. The sweep below covers each
residue several times.

rx_eth forwards everything from byte 14 to the end of the frame, padding
included. Ethernet II carries no length field, so the block genuinely cannot
tell payload from padding; trimming is rx_ipv4's job via Total Length.
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

import random
import sys

from uoe_model import (Beat, ETHERTYPE_ARP, bytes_to_beats, eth_frame,
                       model_rx_eth, model_rx_eth_sideband, write_beats,
                       write_sideband, write_stimulus)

CONF_MAC = 0x02DEADBEEF01       # locally-administered, must match the testbench
OTHER_MAC = 0x02CAFEF00D02      # a destination we must NOT accept
BROADCAST = 0xFFFFFFFFFFFF
SEED = 0xC0FFEE
ETH_MIN_FRAME = 60              # without FCS; the MAC pads up to this


def mac(value: int) -> bytes:
    return value.to_bytes(6, "big")


def build_cases() -> list[tuple[str, bytes]]:
    """Each case is (description, raw Ethernet frame as it reaches rx_eth)."""
    rng = random.Random(SEED)
    cases: list[tuple[str, bytes]] = []

    def payload(n: int) -> bytes:
        return bytes(rng.randrange(256) for _ in range(n))

    # src_mac VARIES per frame on purpose. With a constant source address the
    # sideband check would pass even against a DUT that latches once and never
    # updates again, so a changing value is what makes that test mean anything.
    src = iter(mac(0x020000000001 + 0x010101 * i) for i in range(64))

    def accept(desc: str, n: int, **kw) -> None:
        cases.append((desc, eth_frame(mac(CONF_MAC), next(src), payload(n),
                                      pad_to=ETH_MIN_FRAME, **kw)))

    # ---- the realignment sweep --------------------------------------------
    # 46..61 walks frame lengths 60..75, covering every (frame_len mod 8)
    # residue twice -- including the two that need a flush beat.
    for n in range(46, 62):
        accept(f"payload {n} bytes", n)

    # A few larger frames, well past the padding threshold.
    for n in (100, 101, 102, 500, 501):
        accept(f"payload {n} bytes", n)

    # ---- padding must still be forwarded ----------------------------------
    # A 20-byte payload arrives as a 60-byte frame. rx_eth cannot tell payload
    # from padding, so all 46 bytes after the header must come out. Trimming
    # belongs to rx_ipv4.
    accept("short payload, MAC-padded to 60", 20)

    # ---- rejected: not for us, or not IPv4 --------------------------------
    def reject(desc: str, dst: int, **kw) -> None:
        cases.append((desc, eth_frame(mac(dst), next(src), payload(46),
                                      pad_to=ETH_MIN_FRAME, **kw)))

    reject("destination is another host", OTHER_MAC)
    reject("broadcast frame", BROADCAST)
    reject("ARP, not IPv4", CONF_MAC, ethertype=ETHERTYPE_ARP)
    reject("IPv6, not IPv4", CONF_MAC, ethertype=0x86DD)
    reject("VLAN tagged (802.1Q)", CONF_MAC, ethertype=0x8100)

    # ---- frames that END inside the header --------------------------------
    # A compliant MAC never emits these -- the 60-byte minimum is 8 words --
    # but a truncated or error-terminated frame would. If the header state
    # advances or enters payload without looking at tlast, the parser is left
    # mid-header and swallows the frame that follows. Each is paired with a
    # good frame so the damage, if any, is attributed rather than cascading.
    cases.append(("truncated: frame ends on header word 0",
                  eth_frame(mac(CONF_MAC), next(src), b"")[:8]))
    accept("survivor after word-0 truncation", 46)

    cases.append(("truncated: frame ends on header word 1",
                  eth_frame(mac(CONF_MAC), next(src), b"")[:16]))
    accept("survivor after word-1 truncation", 46)

    # ---- one more accepted frame last -------------------------------------
    # A stale src_mac left behind by any of the five rejects above shows up
    # here as a sideband mismatch.
    accept("final accepted frame", 46)

    return cases


def main() -> int:
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    cases = build_cases()

    beats: list[Beat] = []      # flat stimulus beats
    starts: list[int] = []      # index where each frame begins
    expected: list[Beat] = []
    sideband: list[int] = []    # one src_mac per OUTPUT packet
    notes: list[str] = []
    marks: dict = {}            # stimulus beat index -> description, for the waveform
    exp_marks: dict = {}        # expected beat index -> description, for compare_beats
    sb_marks: dict = {}         # sideband index      -> description, for compare_beats

    for desc, frame in cases:
        starts.append(len(beats))
        marks[len(beats)] = desc
        beats.extend(bytes_to_beats(frame))
        out_beats = model_rx_eth(frame, CONF_MAC)
        sm = model_rx_eth_sideband(frame, CONF_MAC)
        if out_beats:
            assert sm is not None, f"{desc}: emits output but no src_mac"
            # tag before extending, so the index is where this packet starts
            exp_marks[len(expected)] = desc
            sb_marks[len(sideband)] = desc
            sideband.append(sm)
        expected.extend(out_beats)
        notes.append(f"{desc}: {len(frame)} wire bytes in -> {len(out_beats)} beats out")
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
        # idle only between frames: ordinary sparse traffic
        "ipg": [rng.randrange(1, 12) if i in starts_set else 0
                for i in range(len(beats))],
        # bubbles anywhere, including mid-frame: an upstream stall in the
        # MAC -> FIFO -> circular_buffer_filter chain looks like this
        "random": [rng.randrange(0, 6) if rng.random() < 0.35 else 0
                   for _ in range(len(beats))],
    }

    # "gapless" gets the unsuffixed name so it matches the testbench's default
    # STIMULUS_FILE generic and runs with no -generic_top override.
    for name, gaps in variants.items():
        suffix = "" if name == "gapless" else f"_{name}"
        path = f"{outdir}/stimulus_rx_eth_tb{suffix}.txt"
        write_stimulus(path, list(zip(beats, gaps)),
                       f"rx_eth stimulus ({name} input timing).\n"
                       f"conf_mac = 0x{CONF_MAC:012X}\n"
                       f"5th column = idle cycles to insert BEFORE this beat.\n"
                       f"All variants share expected_axis_rx_eth_tb.txt.\n"
                       + "\n".join(notes), marks=marks)
        print(f"wrote {path}  ({sum(gaps)} idle cycles total)")

    write_beats(f"{outdir}/expected_axis_rx_eth_tb.txt", expected,
                "rx_eth expected output: everything after the 14-byte header,\n"
                "valid beats only. MAC padding is forwarded too -- Ethernet II\n"
                "has no length field, so trimming is rx_ipv4's job.\n"
                f"conf_mac = 0x{CONF_MAC:012X}\n"
                "Shared by every stimulus variant -- input timing must not "
                "change the output.", marks=exp_marks)

    write_sideband(f"{outdir}/expected_sideband_rx_eth_tb.txt", sideband, 12,
                   "rx_eth src_mac, one value per OUTPUT packet.\n"
                   "Sample src_mac on the cycle m_axis_tlast is high.",
                   marks=sb_marks)

    print(f"wrote {outdir}/expected_axis_rx_eth_tb.txt")
    print(f"wrote {outdir}/expected_sideband_rx_eth_tb.txt "
          f"({len(sideband)} packets)")
    print(f"{len(cases)} cases -> {len(beats)} stimulus beats, "
          f"{len(expected)} expected beats")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
