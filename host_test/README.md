# Host-side bring-up test

`uoe_loopback_test.c` runs on an Ubuntu PC cabled to the dev board and checks a
UOE built with `rx_udp`'s output looped back into `tx_udp`'s input.

```bash
make            # static by default -- copy it to any x86-64 Linux
make check      # confirms no glibc dependency
./uoe_loopback_test --board-ip 192.168.1.1 --local-port 4660
```

Two programs: `uoe_loopback_test` (the test) and `udp_echo` (a fast reflector
for checking the test itself before trusting it against the board).

**Static is the default on purpose.** Anything compiled on a modern Ubuntu
wants `__libc_start_main@GLIBC_2.34` — glibc 2.34 folded libpthread into libc
and gave that symbol a new version — so a dynamic build will not start on an older release.
Nothing in the source needs 2.34; it is purely where it was compiled. `make dynamic`
exists if you know the target's glibc is at least as new, and `make check`
tells you which kind you are holding.

No root, no raw sockets — the UOE speaks ARP, IPv4 and UDP, so this is a plain
UDP socket program. That is the point: the kernel ARPs for the board by itself,
so `arp_handler` is exercised by a real stack rather than by something this
program hand-builds.

## Before you plug anything in

The board's transmit destination is **configuration** (`conf_tx_dst_*`, tied
off in a loopback build), not a reflection of whoever sent the packet:

| board signal | what it sets |
|---|---|
| `conf_tx_dst_mac` | destination MAC of every frame it sends |
| `conf_tx_dst_ip` | destination IP |
| `conf_tx_dst_port` | destination UDP port |
| `conf_port` | source UDP port it sends from |

So replies do **not** come back to an ephemeral source port. Three things must
line up or packets vanish with no error anywhere:

1. this PC's IP equals `conf_tx_dst_ip`
2. this PC's MAC equals `conf_tx_dst_mac` — the board only *answers* ARP, it
   never *asks*, so it cannot discover your MAC on its own
3. `--local-port` equals `conf_tx_dst_port`

```bash
ip addr show dev <iface>     # must match conf_tx_dst_ip
ip link show dev <iface>     # must match conf_tx_dst_mac
ip neigh show <board-ip>     # after a run: proves ARP worked
```

The receive direction is far less fussy: `rx_eth` checks the destination MAC,
`rx_ipv4` checks the destination IP, and `rx_udp` does not filter on port at
all, so `--board-port` is cosmetic.

## The loopback has no flow control — read this before believing a failure

`rx_udp` has **no `m_axis_tready` port**. `tx_udp` **has** `s_axis_tready`.
Wiring them directly discards it, so whenever `tx_udp`'s packet FIFO stops
accepting, the beats are lost silently and mid-packet.

The FIFO is 2048 words (16 KB), so a single packet of any legal size fits
easily. The risk is sustained load: there is no mechanism to slow the receive
side down, so any transient that delays transmission — `axis_priority_handler`
giving an ARP reply precedence, for instance — leaves a backlog that never
drains.

Practical consequence: **losses at high packet rates may be the loopback
wiring, not the design.** Start paced and only then push:

```bash
./uoe_loopback_test --board-ip 192.168.1.1 --local-port 4660 --gap 200
./uoe_loopback_test --board-ip 192.168.1.1 --local-port 4660          # unpaced
```

If the paced run is clean and the unpaced one loses packets, suspect the
loopback before the datapath. The fix on the board side is the same pattern as
`arp_fifo`: a FIFO in the loopback with a programmable-full flag, dropping
whole packets at the boundary rather than beats in the middle.

## Two modes

**latency** (default) — one packet in flight, every reply verified byte for
byte. Answers *is it correct?*

```bash
./uoe_loopback_test --board-ip 192.168.1.1 --local-port 4660
```

**throughput** (`--speed`) — packets streamed without waiting for replies,
drained afterwards. Answers *how fast does it go?*

You do not supply a rate. For each payload size the tool searches for the
highest rate the link sustains, and the run ends with a headline like this
(example output; the numbers depend on the link and the PC):

```
  sustained goodput
       18 byte payload (60 byte frame):  1.902 Gbps  (63.4% of the 3.000 Gbps design figure, 13.209 Mpps)
     1472 byte payload (1514 byte frame):  9.512 Gbps  (97.8% of the 9.723 Gbps design figure, 0.808 Mpps)
     8958 byte payload (9000 byte frame):  9.901 Gbps  (99.5% of the 9.953 Gbps design figure, 0.138 Mpps)
```

The search bisects rather than ramps: the failure is a cliff — the queue either
keeps up or backs up and never recovers — so bisection lands on it in about six
probes instead of twenty. It stops when the bracket is 3 % wide, which is finer
than the run-to-run variation of a UDP socket on a general-purpose kernel.
"Sustained" means no corruption, no wrong lengths, and loss at or below
`--loss-tol` (default 0.05 %). Correctness is still checked on every reply.

### Reaching line rate needs batching

One `sendto()` per packet cannot reach 10 Gbps at small payloads: an 18-byte
payload at line rate is 14.9 Mpps, i.e. 67 ns per packet, and a syscall costs
more than that on any machine. Both directions therefore use `sendmmsg()` /
`recvmmsg()` with `--batch` packets per call (default 64), and pacing is done
per batch rather than per packet so the clock is not read 14 million times a
second. Without this the small-packet end of the sweep measures syscall entry
rather than the board.

The payload pattern matters just as much. `fill_payload()` runs a byte-at-a-time
xorshift, and generating it per packet on send *and* regenerating it per packet
to verify on receive caps the whole tool at a few Gbps — a measurement of the
PC's PRNG, not of the link.

So throughput mode builds **one template per size** and rewrites only the
4-byte sequence number per packet; verification is a `memcmp` against that
template. The payload is still a pseudorandom byte pattern and still checked in
full. What is given up is per-packet uniqueness: two packets of the same size
differ only in their sequence number.

Latency mode keeps the per-sequence pattern, so a datapath that swapped
payloads between packets is still caught there — and in throughput mode the
sequence number still catches loss, duplication and reordering. With the
template, the packet rate is the same at every size, so the remaining host
limit is per packet (syscalls), not per byte.

### Two ways the host can lie, both caught

If the sender never reaches the rate it aimed for, the summary says so:

```
            ^ HOST-LIMITED: offered 4.786 Gbps, sent only 0.427. This PC was the ceiling, so the figure above is
              a FLOOR for the board, not a measurement of it.
```

That matters — without it a run where *your PC* ran out of steam would be
reported as the board sustaining that rate, which it was never asked to do.

Separately, packets the **kernel** discarded because this program did not read
them fast enough are read from `/proc/net/udp` and `/proc/net/softnet_stat`
and reported in their own `hostdrop` column. They are excluded from the search, so a slow reader here
cannot walk the rate down and credit the board with a ceiling it never hit.

A separate reader thread drains the socket continuously, so a small socket
buffer is usually survivable and no root is needed. If `hostdrop` is still
large, two host settings are the usual cause. `setsockopt` does not fail when
it cannot honour the buffer size — the kernel silently clamps to
`net.core.rmem_max`, which defaults to 208 KB on many distributions and is
about 23 jumbo replies. The banner prints what was actually granted. To raise
the limits:

```bash
sudo sysctl -w net.core.rmem_max=8388608
sudo sysctl -w net.core.netdev_max_backlog=5000
```

There are two places a reply can be lost before this program ever sees it, and
they are counted in different files:

```
NIC -> [netdev backlog: 1000] -> IP/UDP stack -> [socket buffer: 416 KB] -> recvmmsg
          netdev_max_backlog                        rmem_max
       /proc/net/softnet_stat                    /proc/net/udp
```

Both are read and folded into `hostdrop`.

**None of this is needed to use the IP.** The FPGA does not care about Linux
socket buffers, and the latency sweep -- the correctness test -- has one packet
in flight and never comes close. It matters only for `--speed` at high rates,
and for any application that receives at line rate on a PC, which is a property
of 10G UDP on a general-purpose kernel rather than anything this design does.
Untuned, the tool reports a floor and says the host was the ceiling; it does
not report a wrong answer.

```bash
./uoe_loopback_test --board-ip 192.168.1.1 --local-port 4660 --speed
./uoe_loopback_test --board-ip 192.168.1.1 --local-port 4660 --speed --jumbo
```

### The rate ceiling, and why two numbers are printed

`tx_udp.vhd`'s header derives the manageable rate as
`LINE * payload / (payload + 42)` — the 14 + 20 + 8 bytes of header this design
adds — with the frame never below 60 bytes, since shorter payloads are padded. The tool prints that as **design**, and beside it a **wire** figure that
also counts what Ethernet adds below the UOE: preamble + SFD (8), FCS (4),
interframe gap (12), and the 60-byte minimum frame.

| payload | design Gbps | wire Gbps | Mpps |
|--:|--:|--:|--:|
| 16 | 2.667 | 1.905 | 14.881 |
| 18 | 3.000 | 2.143 | 14.881 |
| 64 | 6.038 | 4.923 | 9.615 |
| 256 | 8.591 | 7.950 | 3.882 |
| 1000 | 9.597 | 9.381 | 1.173 |
| 1472 | 9.723 | 9.571 | 0.813 |
| 8958 | 9.953 | 9.927 | 0.139 |

They agree to 0.3 % at jumbo and diverge badly at the small end, because the 24
bytes of per-frame overhead matter more the shorter the frame. **The search paces against the wire
figure**, since offering more than the medium can carry measures the NIC's
transmit queue rather than the board. The summary compares what was achieved
against the **design** figure, because that is the number the RTL was written
to hit.

`--line` sets the link rate if you are not on 10G.

## What it checks

- every payload byte: in latency mode against a pattern regenerated from the
  sequence number, so `--soak` needs no memory; in throughput mode against the
  per-size template
- the returned length
- the source address of the reply
- loss, reordering and duplication, by sequence number
- round-trip time

The default size sweep walks the boundaries the RTL actually has, not round
numbers: `tx_udp` pads up to `MIN_UDP_PAYLOAD_LEN = 18` and special-cases
exactly 17, and the 20-byte IPv4 and 14-byte Ethernet headers push the payload
off 8-byte alignment, so the sweep covers sizes either side of several 8-byte
boundaries. Sizes run 0 to 1472 (the design has no fragmentation, so that is
the ceiling). `--jumbo` replaces this sweep with ten larger sizes, 18 to 8958;
`--speed` uses five, 18 to 1472.

Size 0 is expected to produce **no reply**: a zero-length payload is not a
drivable AXI-Stream packet, so the board has nothing to send. The test asserts
the silence rather than skipping the case.

## Options

```
required
  --board-ip A.B.C.D   the board's conf_ip
  --local-port N       the board's conf_tx_dst_port

what to run
  --speed              throughput mode instead of latency
  --size N             one payload size instead of the sweep
  --jumbo              sweep large sizes up to 8958 bytes (needs MTU 9000)
  --soak               repeat until interrupted

tuning
  --board-port N       port to send to               (default 1234)
  --count N            packets per size, latency     (default 16)
  --duration MS        length of each throughput probe (default 300)
  --loss-tol PCT       loss still counted as sustained (default 0.05)
  --rate PCT           pin the rate instead of searching for it
  --line GBPS          link rate for the ceilings    (default 10)
  --timeout MS         reply timeout                 (default 500)
  --batch N            packets per sendmmsg call     (default 64, max 256)
  --gap US             pause between sends, latency  (default 0)
  --verbose            report every probe, and every loss in latency mode
  --report FILE        write a diagnosis file
```

`--report` writes everything the run saw plus the host settings needed to read
it: the socket buffer sizes the kernel actually **granted** (not what was
asked for), `net.core.rmem_max`, `wmem_max`, `netdev_max_backlog`, and a
machine-readable row per size with every counter. Those host settings
are the point — the same table means different things on different machines,
and they are invisible in the terminal output.

Exit status is 0 only if every size passed. Ctrl-C stops cleanly and still
prints the totals.

## Reading the output

Latency mode reports per size: sent, received, lost, corrupt, wrong length,
reordered, and RTT min/avg/max. Throughput mode reports probes, the rate it
settled on, sustained goodput and Mpps, lost, hostdrop, txfail, corrupt, and
both ceilings, so you can see how close it got.

The summary lists every failing size with the counter that failed, so a failure
names itself rather than needing the table read back:

```
  FAIL -- 2 size(s) did not pass:
       18 bytes:  1550 lost
       64 bytes:  1170 lost
```

`--jumbo` needs MTU 9000 on the NIC **and** the board. Without it the kernel
fragments, and this design cannot reassemble.

## Testing the test

The board is the thing under test, so the test has to be trusted first.
`udp_echo` is a reflector built for that: it mimics the board's addressing
(replies go to a fixed destination, not back to the sender's port) and uses the
same batched syscalls, so it is not itself the bottleneck.

```bash
./udp_echo --port 1234 --reply-to 127.0.0.1:4660 &
./uoe_loopback_test --board-ip 127.0.0.1 --board-port 1234 --local-port 4660
./uoe_loopback_test --board-ip 127.0.0.1 --board-port 1234 --local-port 4660 --speed
```

A clean sweep proves the addressing, the pattern checking and the tool, leaving
the board as the main variable. Run it on a second PC to prove the cabling too.

`--drop-every N` makes the echo drop one packet in N, so you can watch the test
detect loss on demand: each dropped reply is reported as `lost 1`.
