"""Shared protocol model for the UDP Offload Engine testbenches.

One module holds the protocol logic; per-block scripts stay thin, and every
header record is defined once, here.

Byte order follows the RTL: rx_udp reads the UDP source port from
s_axis_tdata(63 downto 48), so packet byte 0 lives in bits 63:56 and tkeep
bit 7 marks it valid. Everything below packs MSB-first to match.
"""

# Lets modern annotation syntax (PEP 604 unions, builtin generics) run on
# Python 3.8.
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, List

BEAT_BYTES = 8


@dataclass(frozen=True)
class Beat:
    """One AXI-Stream beat. Only valid beats (tvalid=1) are ever recorded."""

    tdata: int  # 64-bit
    tkeep: int  # 8-bit, bit 7 <-> tdata(63:56)
    tlast: int  # 0 or 1
    # Packet-level error flag, asserted WITH tlast to mark the packet just
    # delivered as invalid (rx_udp raises it on a truncated datagram). It
    # defaults to 0 so blocks that have no tuser need not mention it.
    tuser: int = 0

    def __str__(self) -> str:
        return f"{self.tdata:016X} {self.tkeep:02X} {self.tlast} {self.tuser}"


# ---------------------------------------------------------------------------
# byte <-> beat packing
# ---------------------------------------------------------------------------

def bytes_to_beats(payload: bytes) -> List[Beat]:
    """Pack bytes MSB-first into 64-bit beats, tlast on the final beat.

    A payload that is an exact multiple of 8 yields a final beat with
    tkeep=0xFF and tlast=1; the model states that case explicitly.
    """
    beats: List[Beat] = []
    for off in range(0, len(payload), BEAT_BYTES):
        chunk = payload[off:off + BEAT_BYTES]
        tdata = 0
        tkeep = 0
        for i, b in enumerate(chunk):
            tdata |= b << (56 - 8 * i)
            tkeep |= 1 << (7 - i)
        tlast = 1 if off + BEAT_BYTES >= len(payload) else 0
        beats.append(Beat(tdata, tkeep, tlast))
    return beats


def beats_to_bytes(beats: Iterable[Beat]) -> bytes:
    """Inverse of bytes_to_beats: keep only bytes whose tkeep bit is set."""
    out = bytearray()
    for b in beats:
        for i in range(BEAT_BYTES):
            if b.tkeep & (1 << (7 - i)):
                out.append((b.tdata >> (56 - 8 * i)) & 0xFF)
    return bytes(out)


def packets(beats: Iterable[Beat]):
    """Group a flat beat list into packets on tlast. An unterminated tail is
    yielded too, so the caller can report it."""
    cur: list = []
    for b in beats:
        cur.append(b)
        if b.tlast:
            yield cur
            cur = []
    if cur:
        yield cur


# ---------------------------------------------------------------------------
# checksums (RFC 1071)
# ---------------------------------------------------------------------------

def ones_complement_sum(data: bytes) -> int:
    """16-bit one's complement sum, folding carries until none remain.

    The fold loops: a single pass can leave a carry.
    """
    if len(data) % 2:
        data = data + b"\x00"
    total = 0
    for i in range(0, len(data), 2):
        total += (data[i] << 8) | data[i + 1]
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return total


def checksum16(data: bytes) -> int:
    return (~ones_complement_sum(data)) & 0xFFFF


# ---------------------------------------------------------------------------
# header construction
# ---------------------------------------------------------------------------

def udp_header(src_port: int, dst_port: int, length: int, checksum: int = 0) -> bytes:
    return (src_port.to_bytes(2, "big") + dst_port.to_bytes(2, "big")
            + length.to_bytes(2, "big") + checksum.to_bytes(2, "big"))


def udp_packet(src_port: int, dst_port: int, payload: bytes,
               checksum: int = 0, length: int | None = None) -> bytes:
    """Full UDP datagram. `length` overrides the header field for malformed tests."""
    declared = 8 + len(payload) if length is None else length
    return udp_header(src_port, dst_port, declared, checksum) + payload


IPV4_HEADER_LEN = 20
ETH_HEADER_LEN = 14         # dst MAC 6 + src MAC 6 + ethertype 2
ETH_MIN_PAYLOAD = 46        # frames shorter than this arrive zero-padded
ETHERTYPE_IPV4 = 0x0800
ETHERTYPE_ARP = 0x0806


def eth_frame(dst_mac: bytes, src_mac: bytes, payload: bytes,
              ethertype: int = ETHERTYPE_IPV4, pad_to: int = 0) -> bytes:
    """Ethernet II frame as it reaches rx_eth -- preamble and FCS already gone.

    `pad_to` appends zero bytes to reach a wire length, which is how the MAC
    meets the 60-byte minimum. rx_eth does not know where the payload ends
    (Ethernet II carries no length field), so it forwards the padding too and
    leaves trimming to rx_ipv4's Total Length. That is why the model keeps it.
    """
    frame = dst_mac + src_mac + ethertype.to_bytes(2, "big") + payload
    if len(frame) < pad_to:
        frame += b"\x00" * (pad_to - len(frame))
    return frame


def ipv4_header(src_ip: bytes, dst_ip: bytes, payload_len: int, ident: int = 0,
                ttl: int = 0x40, proto: int = 0x11, flags: int = 0b010,
                frag_offset: int = 0, version: int = 4, ihl: int = 5,
                total_len: int | None = None, bad_checksum: bool = False) -> bytes:
    """20-byte IPv4 header with a correctly folded checksum filled in.

    The defaults describe a packet rx_ipv4 should accept. Every other argument
    exists so a test can violate exactly one field at a time.
    """
    declared = IPV4_HEADER_LEN + payload_len if total_len is None else total_len
    hdr = bytearray()
    hdr += bytes([((version & 0xF) << 4) | (ihl & 0xF), 0x00])
    hdr += declared.to_bytes(2, "big")
    hdr += ident.to_bytes(2, "big")
    hdr += ((flags << 13) | frag_offset).to_bytes(2, "big")
    hdr += bytes([ttl, proto])
    hdr += b"\x00\x00"                                  # checksum placeholder
    hdr += src_ip
    hdr += dst_ip
    ck = checksum16(bytes(hdr))
    if bad_checksum:
        ck ^= 0x0001                                    # one bit off, nothing else
    hdr[10:12] = ck.to_bytes(2, "big")
    return bytes(hdr)


def ipv4_packet(src_ip: bytes, dst_ip: bytes, payload: bytes,
                pad_to: int = 0, **hdr_kw) -> bytes:
    """Full IPv4 packet as it reaches rx_ipv4 (rx_eth has stripped the L2 header).

    `pad_to` appends zero bytes to reach that wire length without touching the
    Total Length field -- which is what Ethernet padding looks like from here.
    The declared length, not the wire length, is what says where the payload
    ends, and telling those two apart is the point of the padded test cases.
    """
    pkt = ipv4_header(src_ip, dst_ip, len(payload), **hdr_kw) + payload
    if len(pkt) < pad_to:
        pkt += b"\x00" * (pad_to - len(pkt))
    return pkt


# ---------------------------------------------------------------------------
# file IO -- format is chosen to be trivial for VHDL TEXTIO hread()
#   <16 hex tdata> <2 hex tkeep> <0|1 tlast> <0|1 tuser>
# ---------------------------------------------------------------------------

def write_beats(path: str, beats: Iterable[Beat], header: str = "",
                marks: dict = None) -> None:
    """Expected-output beats, optionally tagged with which case produced them.

    `marks` maps a beat index to the description of the packet starting there.
    compare_beats.py reads the tags back so a failure can say
    "case 21 'payload 31 bytes' was dropped" instead of "beat 37 differs" --
    which points one packet PAST the culprit once the stream desynchronises.
    """
    marks = marks or {}
    with open(path, "w") as f:
        for line in header.splitlines():
            f.write(f"# {line}\n")
        f.write("# tdata(16 hex) tkeep(2 hex) tlast tuser\n")
        n = 0
        for i, b in enumerate(beats):
            if i in marks:
                n += 1
                f.write(f"# CASE {n} {marks[i]}\n")
            f.write(f"{b}\n")


def _case_label(line: str) -> str:
    """Parse '# CASE <n> <text>' into a display label, or '' if not a marker."""
    parts = line.split(None, 3)          # '#', 'CASE', '<n>', '<text>'
    if len(parts) >= 3 and parts[1] == "CASE":
        text = parts[3] if len(parts) > 3 else ""
        return f"case {parts[2]} {text!r}" if text else f"case {parts[2]}"
    return ""


def read_beats_tagged(path: str) -> List[tuple]:
    """[(Beat, case_label), ...]. Label is '' in files with no CASE markers."""
    out: List[tuple] = []
    label = ""
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                found = _case_label(line)
                if found:
                    label = found
                continue
            parts = line.split()
            if len(parts) != 4:
                raise ValueError(
                    f"{path}:{lineno}: expected 4 fields "
                    f"(tdata tkeep tlast tuser), "
                    f"got {len(parts)}: {line!r}")
            out.append((Beat(int(parts[0], 16), int(parts[1], 16),
                             int(parts[2]), int(parts[3])),
                        label))
    return out


def write_stimulus(path: str, items: Iterable[tuple], header: str = "",
                   marks: dict = None) -> None:
    """Stimulus adds a 5th column: idle cycles to insert BEFORE this beat.

    `items` is an iterable of (Beat, gap). Gap is input timing only -- it never
    affects the expected output, so the same expected file checks every gap
    pattern. If it doesn't, that's a bug.

    Column 4 is the Beat's own tuser, so a stimulus packet can arrive already
    flagged invalid by an upstream block. That is how rx_udp's propagation of
    rx_ipv4's truncation flag gets exercised.

    `marks` maps a beat index to a short description of the packet starting
    there. Each one is written as a "# CASE <n> <text>" comment line, which
    axis_driver picks up and drives onto case_index / case_name -- so a
    waveform names the packet under test instead of making you decode hex.
    Ordinary comment lines are unaffected; a file without marks still works.
    """
    marks = marks or {}
    with open(path, "w") as f:
        for line in header.splitlines():
            f.write(f"# {line}\n")
        f.write("# tdata(16 hex) tkeep(2 hex) tlast tuser gap(idle cycles before beat)\n")
        if marks:
            f.write("# '# CASE <n> <text>' names the packet that follows;\n")
            f.write("# axis_driver exposes it as case_index / case_name.\n")
        n = 0
        for i, (b, gap) in enumerate(items):
            if i in marks:
                n += 1
                f.write(f"# CASE {n} {marks[i]}\n")
            f.write(f"{b} {gap}\n")


def read_beats(path: str) -> List[Beat]:
    beats: List[Beat] = []
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) != 4:
                raise ValueError(
                    f"{path}:{lineno}: expected 4 fields "
                    f"(tdata tkeep tlast tuser), "
                    f"got {len(parts)}: {line!r}")
            beats.append(Beat(int(parts[0], 16), int(parts[1], 16),
                              int(parts[2]), int(parts[3])))
    return beats


def write_sideband(path: str, values: Iterable[int], nibbles: int,
                   header: str = "", marks: dict = None) -> None:
    """Latched non-AXIS outputs: one line per OUTPUT packet, hex.

    These are registers, not streams, so one value is recorded per emitted
    packet. Each generator's header says which beat the testbench samples on.
    `marks` tags each value with the case that produced it, same as write_beats.
    """
    marks = marks or {}
    with open(path, "w") as f:
        for line in header.splitlines():
            f.write(f"# {line}\n")
        f.write("# one line per OUTPUT packet\n")
        n = 0
        for i, v in enumerate(values):
            if i in marks:
                n += 1
                f.write(f"# CASE {n} {marks[i]}\n")
            f.write(f"{v:0{nibbles}X}\n")


def read_sideband_tagged(path: str) -> List[tuple]:
    """[(value, case_label), ...]. Label is '' in files with no CASE markers."""
    out: List[tuple] = []
    label = ""
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                found = _case_label(line)
                if found:
                    label = found
                continue
            try:
                out.append((int(line.split()[0], 16), label))
            except (ValueError, IndexError):
                raise ValueError(f"{path}:{lineno}: expected a hex value, got {line!r}")
    return out


def read_sideband(path: str) -> List[int]:
    out: List[int] = []
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                out.append(int(line.split()[0], 16))
            except (ValueError, IndexError):
                raise ValueError(f"{path}:{lineno}: expected a hex value, got {line!r}")
    return out


# ---------------------------------------------------------------------------
# per-block reference models
# ---------------------------------------------------------------------------

def model_rx_udp_sideband(pkt: bytes):
    """src_port rx_udp should have latched, or None if the packet is dropped.

    Latched for every packet that produces output. There is no port test:
    rx_udp does not filter on destination port (see model_rx_udp).
    """
    if len(pkt) < 8:
        return None
    if int.from_bytes(pkt[4:6], "big") <= 8:
        return None
    return int.from_bytes(pkt[0:2], "big")


def model_rx_udp_dst_port(pkt: bytes):
    """Destination port rx_udp should expose, or None if the packet is dropped.

    rx_udp forwards every datagram, so this is what tells downstream
    fabric which consumer a packet belongs to -- so unlike src_port it is a
    ROUTING signal, and must be valid on the FIRST output beat rather than
    sampled at tlast.
    """
    if len(pkt) < 8:
        return None
    if int.from_bytes(pkt[4:6], "big") <= 8:
        return None
    return int.from_bytes(pkt[2:4], "big")


def model_rx_udp(pkt: bytes, in_tuser: bool = False) -> List[Beat]:
    """Intended behaviour of rx_udp: forward the payload of EVERY datagram.

    Destination port is deliberately NOT filtered. rx_eth and rx_ipv4 already
    decided the frame is addressed to this node; the port says which consumer
    inside the node wants it, which is a demux decision for the fabric, not a
    parsing decision for this block. rx_udp reports dst_port instead of acting
    on it, so one rx chain can feed several consumers.

    The length guard stays, because it is a validity test rather than a filter:
    a datagram declaring 8 or fewer bytes has no payload, and forwarding it
    would emit a beat with tkeep = 0x00.

    This models the spec, written independently of the RTL, so a disagreement
    means one of the two is wrong.
    """
    if len(pkt) < 8:
        return []
    declared = int.from_bytes(pkt[4:6], "big")

    if declared <= 8:               # header only, no payload to forward
        return []

    # Trust the declared length, so any L2 padding beyond it is excluded.
    payload = pkt[8:declared]
    beats = bytes_to_beats(payload)

    # A datagram whose declared length runs past the end of the frame is
    # truncated. The bytes that did arrive are still delivered -- rx_udp is
    # cut-through and cannot un-send them -- but the last beat carries tuser
    # to tell the consumer the packet is short. Without that flag a truncated
    # packet is indistinguishable from a complete one.
    truncated = len(pkt) < declared

    # An upstream block (rx_ipv4) can hand us a frame it has already flagged.
    # rx_udp can only pass that on if the flag arrives while the packet is
    # still open: it stops consuming at the end of the declared UDP length, so
    # if that lands before the frame's final beat, the flag turns up after
    # m_axis_tlast has already gone out and is lost. Cut-through, again.
    inherited = in_tuser and _udp_ends_on_last_beat(pkt, declared)

    if beats and (truncated or inherited):
        beats[-1] = Beat(beats[-1].tdata, beats[-1].tkeep, beats[-1].tlast, 1)

    return beats


def _udp_ends_on_last_beat(pkt: bytes, declared: int) -> bool:
    """Does the UDP datagram run to the final beat of the frame it arrived in?"""
    frame_beats = -(-len(pkt) // BEAT_BYTES)
    payload_beats = -(-max(0, declared - 8) // BEAT_BYTES)
    return 1 + payload_beats >= frame_beats


# ---------------------------------------------------------------------------
# rx_ipv4
#
# Accepts only what RFC 791 allows this design to handle: version 4, IHL 5 (no
# options), unfragmented (MF = 0, offset 0), a total length longer than the
# header, TTL above 0, protocol UDP, our destination IP and a valid header
# checksum. Then the payload is extracted, realigned and length-limited. The IPv4
# header is 20 bytes, which is not a multiple of the 8-byte bus, so every
# payload beat is assembled from two input words.
# ---------------------------------------------------------------------------

def ipv4_accepted(pkt: bytes, conf_ip: int) -> bool:
    """Would rx_ipv4 forward this packet's payload?"""
    if len(pkt) < IPV4_HEADER_LEN:
        return False

    version = pkt[0] >> 4
    ihl = pkt[0] & 0x0F
    total_len = int.from_bytes(pkt[2:4], "big")
    flags = pkt[6] >> 5
    frag_offset = int.from_bytes(pkt[6:8], "big") & 0x1FFF
    ttl = pkt[8]
    proto = pkt[9]
    dst_ip = int.from_bytes(pkt[16:20], "big")

    if version != 4 or ihl != 5:
        return False
    # RFC 791: a datagram is unfragmented when MF=0 and the offset is 0. DF is
    # a request to routers and says nothing about whether THIS datagram is a
    # fragment, so it is deliberately not tested -- rx_ipv4 does not test it
    # either (it checks bit 13 = MF and bits 12..0 = offset).
    if (flags & 0b001) != 0 or frag_offset != 0:
        return False
    if total_len <= IPV4_HEADER_LEN:        # header only, nothing to forward
        return False
    if ttl == 0 or proto != 0x11:
        return False
    if dst_ip != conf_ip:
        return False
    # RFC 1071: summing a good header including its checksum field gives 0xFFFF
    if ones_complement_sum(pkt[0:IPV4_HEADER_LEN]) != 0xFFFF:
        return False
    return True


def model_rx_ipv4(pkt: bytes, conf_ip: int) -> List[Beat]:
    """Intended behaviour of rx_ipv4: forward the payload, drop everything else."""
    if not ipv4_accepted(pkt, conf_ip):
        return []
    total_len = int.from_bytes(pkt[2:4], "big")
    # Declared length bounds the payload, so Ethernet padding is excluded.
    beats = bytes_to_beats(pkt[IPV4_HEADER_LEN:total_len])

    # Total Length running past the end of the frame means the packet was
    # truncated. Same contract as rx_udp: the bytes that did arrive are
    # still delivered -- the block is cut-through and cannot un-send them
    # -- and the last beat carries tuser to say the packet is short.
    #
    # The BYTE COUNT of a flagged packet is not part of the contract: the
    # consumer must discard the packet anyway. rx_ipv4 delivers it up to 4
    # bytes short, because its realignment carry is not flushed on the
    # truncation path. compare_beats.py checks the flag, not the contents.
    if beats and len(pkt) < total_len:
        beats[-1] = Beat(beats[-1].tdata, beats[-1].tkeep, beats[-1].tlast, 1)

    return beats


def model_rx_ipv4_sideband(pkt: bytes, conf_ip: int):
    """src_ip rx_ipv4 should have latched, or None if the packet is rejected.

    The RTL latches src_ip while processing header word 1, before the
    destination-IP check in word 2 -- so a packet rejected on destination does
    update the register. That is invisible in this file, which only records a
    value per EMITTED packet, and it is the correct thing to record: a stale
    src_ip surviving into the next accepted packet is exactly the failure the
    varying-per-packet source addresses are designed to expose.
    """
    if not ipv4_accepted(pkt, conf_ip):
        return None
    return int.from_bytes(pkt[12:16], "big")


# ---------------------------------------------------------------------------
# rx_eth
#
# The Ethernet II header is 14 bytes, so the payload starts 6 bytes into input
# word 1 and every output beat is stitched from two input words -- the same
# realignment problem as rx_ipv4, with a 2-byte carry instead of 4.
#
# rx_eth accepts only frames addressed to conf_mac carrying EtherType 0x0800.
# Everything from byte 14 to the end of the frame is forwarded, INCLUDING any
# padding the MAC added: Ethernet II has no length field, so rx_eth genuinely
# cannot tell payload from padding. Trimming is rx_ipv4's job, using Total
# Length. Modelling it any other way would be modelling a block that cannot
# exist.
# ---------------------------------------------------------------------------

def eth_accepted(frame: bytes, conf_mac: int) -> bool:
    """Would rx_eth forward this frame's payload?"""
    if len(frame) < ETH_HEADER_LEN:
        return False
    dst_mac = int.from_bytes(frame[0:6], "big")
    ethertype = int.from_bytes(frame[12:14], "big")
    return dst_mac == conf_mac and ethertype == ETHERTYPE_IPV4


def model_rx_eth(frame: bytes, conf_mac: int) -> List[Beat]:
    """Intended behaviour of rx_eth: strip the 14-byte header, forward the rest."""
    if not eth_accepted(frame, conf_mac):
        return []
    return bytes_to_beats(frame[ETH_HEADER_LEN:])


def model_rx_eth_sideband(frame: bytes, conf_mac: int):
    """src_mac rx_eth should have latched, or None if the frame is rejected.

    Only accepted frames produce a value: this file records one value per
    EMITTED packet.
    """
    if not eth_accepted(frame, conf_mac):
        return None
    return int.from_bytes(frame[6:12], "big")


# ---------------------------------------------------------------------------
# tx path
#
# The TX blocks are the mirror of the RX ones: each PREPENDS its header to
# whatever arrives. Two wrinkles the RX side does not have:
#
#   * padding. Ethernet needs a 60-byte frame, which after the 14+20+8 byte
#     headers means at least 18 bytes of UDP payload. tx_udp pads up to that,
#     and the padding is deliberately NOT counted in the UDP length field --
#     so the length field describes real data while the wire carries more.
#     tx_ipv4 has to know that, which is why it clamps to MIN_UDP_LEN = 26.
#
#   * realignment runs the other way. A 20-byte IPv4 header pushes the payload
#     4 bytes out of alignment, and a 14-byte Ethernet header pushes it 6, so
#     each block ends a packet with a partial beat the RX side never produces.
# ---------------------------------------------------------------------------

MIN_UDP_PAYLOAD_LEN = 18        # tx_udp pads the payload up to this
MIN_UDP_LEN = 26                # = 8 + MIN_UDP_PAYLOAD_LEN, tx_ipv4's clamp


def model_tx_udp(payload: bytes, conf_port: int, dst_port: int) -> List[Beat]:
    """UDP header + payload, padded to MIN_UDP_PAYLOAD_LEN.

    The length field counts the REAL payload; the padding is invisible to it.
    Checksum is zero -- the block does not compute one, which is legal for
    IPv4 and is stated in its header comment.
    """
    declared = 8 + len(payload)
    wire = payload + b"\x00" * max(0, MIN_UDP_PAYLOAD_LEN - len(payload))
    return bytes_to_beats(udp_header(conf_port, dst_port, declared, 0) + wire)


def model_tx_ipv4(datagram: bytes, conf_ip: int, dst_ip: int,
                  ident: int = 0) -> List[Beat]:
    """IPv4 header + the UDP datagram handed to it.

    Total Length counts the header plus the DECLARED udp length, so a padded
    datagram declares less than it puts on the wire -- which is exactly what
    rx_ipv4 relies on to trim the padding back off at the far end.
    """
    udp_len = int.from_bytes(datagram[4:6], "big")
    total_len = IPV4_HEADER_LEN + udp_len

    hdr = ipv4_header(conf_ip.to_bytes(4, "big"), dst_ip.to_bytes(4, "big"),
                      0, ident=ident, total_len=total_len)

    # the block forwards max(udp_len, MIN_UDP_LEN) payload bytes: the clamp is
    # how it accounts for padding the length field does not mention
    on_wire = max(udp_len, MIN_UDP_LEN)
    return bytes_to_beats(hdr + datagram[:on_wire])


def model_tx_eth(packet: bytes, conf_mac: int, dst_mac: int) -> List[Beat]:
    """Ethernet II header + the IPv4 packet handed to it. No padding here --
    tx_udp already guaranteed the minimum frame size."""
    hdr = (dst_mac.to_bytes(6, "big") + conf_mac.to_bytes(6, "big")
           + ETHERTYPE_IPV4.to_bytes(2, "big"))
    return bytes_to_beats(hdr + packet)


# ---------------------------------------------------------------------------
# uoe top level
#
# The per-block models above each describe one hop. These chain them into the
# two end-to-end paths the top level actually exposes, plus the ARP responder,
# which has no block-level model because arp_handler is not on either path --
# it hangs off the RX stream and answers into the TX arbiter.
#
# One convention change at the boundary. Everything inside uoe is MSB-first
# (byte 0 in tdata(63:56)); the MAC ports are the other way round, because
# rx_endi / tx_endi byte-reverse the word AND the tkeep. So mac_rx stimulus and
# mac_tx expectations are swapped, and only there.
#
# The swap below is written out rather than reusing the RTL's converter, so a
# bug in endianness_converter shows up as a mismatch instead of cancelling
# itself out on the way in and out.
# ---------------------------------------------------------------------------

ARP_HTYPE_ETHERNET = 0x0001
ARP_OPER_REQUEST = 1
ARP_OPER_REPLY = 2
BROADCAST_MAC = 0xFFFFFFFFFFFF


def swap_beat(b: Beat) -> Beat:
    """Byte-reverse one beat's tdata and tkeep -- the MAC-side convention."""
    tdata = 0
    tkeep = 0
    for i in range(BEAT_BYTES):
        byte = (b.tdata >> (8 * i)) & 0xFF
        tdata |= byte << (56 - 8 * i)
        if b.tkeep & (1 << i):
            tkeep |= 1 << (7 - i)
    return Beat(tdata, tkeep, b.tlast, b.tuser)


def swap_beats(beats: Iterable[Beat]) -> List[Beat]:
    return [swap_beat(b) for b in beats]


# ---------------------------------------------------------------------------
# ARP
# ---------------------------------------------------------------------------

def arp_request(sender_mac: int, sender_ip: int, target_ip: int,
                dst_mac: int = BROADCAST_MAC) -> bytes:
    """A complete Ethernet frame carrying an ARP request, padded to 60 bytes.

    14 + 28 = 42 bytes of real content; the 18 bytes of padding are what make
    arp_handler's rx FSM land its last check on beat 5 of 8 rather than on the
    final beat.
    """
    eth = (dst_mac.to_bytes(6, "big") + sender_mac.to_bytes(6, "big")
           + ETHERTYPE_ARP.to_bytes(2, "big"))
    arp = (ARP_HTYPE_ETHERNET.to_bytes(2, "big")
           + ETHERTYPE_IPV4.to_bytes(2, "big")
           + bytes([6, 4])
           + ARP_OPER_REQUEST.to_bytes(2, "big")
           + sender_mac.to_bytes(6, "big")
           + sender_ip.to_bytes(4, "big")
           + bytes(6)                       # target MAC unknown in a request
           + target_ip.to_bytes(4, "big"))
    return eth + arp + bytes(60 - len(eth) - len(arp))


def arp_accepted(frame: bytes, conf_mac: int, conf_ip: int) -> bool:
    """Would arp_handler answer this frame?

    Mirrors the rx FSM's checks in order: destination MAC is ours or broadcast,
    EtherType is ARP, hardware type is Ethernet, protocol is IPv4 with the
    standard address lengths, the operation is a REQUEST, the sender hardware
    address inside the ARP body agrees with the Ethernet source MAC, and the
    target protocol address is our IP.
    """
    if len(frame) < 42:
        return False
    dst_mac = int.from_bytes(frame[0:6], "big")
    src_mac = int.from_bytes(frame[6:12], "big")
    if dst_mac not in (conf_mac, BROADCAST_MAC):
        return False
    if int.from_bytes(frame[12:14], "big") != ETHERTYPE_ARP:
        return False
    if int.from_bytes(frame[14:16], "big") != ARP_HTYPE_ETHERNET:
        return False
    if int.from_bytes(frame[16:18], "big") != ETHERTYPE_IPV4:
        return False
    if frame[18] != 6 or frame[19] != 4:
        return False
    if int.from_bytes(frame[20:22], "big") != ARP_OPER_REQUEST:
        return False
    if int.from_bytes(frame[22:28], "big") != src_mac:
        return False
    if int.from_bytes(frame[38:42], "big") != conf_ip:
        return False
    return True


def model_arp_reply(frame: bytes, conf_mac: int, conf_ip: int):
    """The 60-byte reply arp_handler builds, or None if it would not answer.

    Every field comes from registers latched during the request, so the reply
    is a pure function of it -- which is why this is checkable at all.
    """
    if not arp_accepted(frame, conf_mac, conf_ip):
        return None
    src_mac = int.from_bytes(frame[6:12], "big")
    sender_ip = int.from_bytes(frame[28:32], "big")

    eth = (src_mac.to_bytes(6, "big") + conf_mac.to_bytes(6, "big")
           + ETHERTYPE_ARP.to_bytes(2, "big"))
    arp = (ARP_HTYPE_ETHERNET.to_bytes(2, "big")
           + ETHERTYPE_IPV4.to_bytes(2, "big")
           + bytes([6, 4])
           + ARP_OPER_REPLY.to_bytes(2, "big")
           + conf_mac.to_bytes(6, "big")
           + conf_ip.to_bytes(4, "big")
           + src_mac.to_bytes(6, "big")
           + sender_ip.to_bytes(4, "big"))
    # the FSM emits 7 full words then a 4-byte word: 60 bytes exactly
    return eth + arp + bytes(60 - len(eth) - len(arp))


# ---------------------------------------------------------------------------
# end-to-end paths
# ---------------------------------------------------------------------------

def model_uoe_rx(frame: bytes, conf_mac: int, conf_ip: int) -> List[Beat]:
    """mac_rx frame -> udp_rx beats. rx_eth then rx_ipv4 then rx_udp.

    Each block is fed the BYTES its predecessor emitted, not its beats, so a
    realignment bug in one block cannot be hidden by the next one re-packing.
    """
    eth_out = beats_to_bytes(model_rx_eth(frame, conf_mac))
    if not eth_out:
        return []
    ipv4_beats = model_rx_ipv4(eth_out, conf_ip)
    if not ipv4_beats:
        return []
    flagged = ipv4_beats[-1].tuser == 1
    return model_rx_udp(beats_to_bytes(ipv4_beats), in_tuser=flagged)


def model_uoe_rx_sideband(frame: bytes, conf_mac: int, conf_ip: int):
    """(src_mac, src_ip, src_port, dst_port) for a frame that reaches udp_rx."""
    if not model_uoe_rx(frame, conf_mac, conf_ip):
        return None
    eth_out = beats_to_bytes(model_rx_eth(frame, conf_mac))
    ipv4_out = beats_to_bytes(model_rx_ipv4(eth_out, conf_ip))
    return (model_rx_eth_sideband(frame, conf_mac),
            model_rx_ipv4_sideband(eth_out, conf_ip),
            model_rx_udp_sideband(ipv4_out),
            model_rx_udp_dst_port(ipv4_out))


def model_uoe_tx(payload: bytes, conf_mac: int, conf_ip: int, conf_port: int,
                 dst_mac: int, dst_ip: int, dst_port: int,
                 ident: int = 0) -> bytes:
    """udp_tx payload -> the complete Ethernet frame that leaves mac_tx."""
    udp = beats_to_bytes(model_tx_udp(payload, conf_port, dst_port))
    ip = beats_to_bytes(model_tx_ipv4(udp, conf_ip, dst_ip, ident=ident))
    return beats_to_bytes(model_tx_eth(ip, conf_mac, dst_mac))


# ---------------------------------------------------------------------------
# receive-side buffering limits
#
# circular_buffer_filter (circ_fifo) is store-and-forward: it holds a whole
# frame, BRAM_DEPTH = 2048 beats = 16 KB, before committing it. A frame that
# does not fit can never complete, and nothing on the RX path can backpressure
# the MAC, so the filter must DROP such a frame whole. If it did not, the write
# side would stop and take rx_eth and arp_handler down with it.
# ---------------------------------------------------------------------------

CIRC_FIFO_BEATS = 2048          # circular_buffer_filter BRAM_DEPTH
