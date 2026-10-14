# UDP Offload Engine

A UDP/IPv4/Ethernet offload engine in VHDL, targeting a Xilinx FPGA behind the
XXV Ethernet (10G/25G) MAC.

## Layout

```
rtl/                     the hardware design -- one VHDL file per block
testbenches/             VHDL testbenches: <block>_tb.vhd per block, plus
  README.md                how the reusable AXIS components work
  axis_pkg.vhd             shared beat type and helpers
  axis_driver.vhd          plays a stimulus file onto a bus
  axis_monitor.vhd         logs valid beats to a file
  sideband_monitor.vhd     logs a latched non-AXIS output (e.g. src_port)
  axis_checker.vhd         passive AXI-Stream protocol assertions
  axis_stall.vhd           randomized tready, for backpressure testing
  uoe_tb_full.vhd          the whole chip, end to end
  uoe_reset_tb.vhd         the whole chip's reset stretcher
reference_model/         an independent Python model of the same protocols
  uoe_model.py             shared: byte packing, checksums, headers, per-block models
  gen_<block>.py           writes the test vectors for one block
  gen_uoe.py               writes the test vectors for the whole chip
  split_mac_tx.py          splits a mac_tx capture by EtherType
  split_by_tag.py          splits a two-source capture by a payload tag
  compare_beats.py         diffs what the simulation produced vs what was predicted
  test_vectors/            generated data + simulation output (all gitignored)
scripts/                 build and run helpers
  setup_vivado_libs.sh     one-time: make Vivado runnable without root
  vivado_env.sh            sourced by the others; locates the toolchain
  test_tables.sh           sourced by the test scripts; settings they share
  compile_check.sh         analyse rtl/ only
  run_tests.sh             the regression, block by block
  run_uoe_test.sh          the full-chip regression
  run_wave.sh              GUI waveform for one block and variant
  run_sim.tcl              full-project waveform run (needs all of rtl/ to compile)
  completions.bash         tab completion for the test scripts
host_test/               host-side bring-up test for the real board
  uoe_loopback_test.c      UDP loopback checker; no root, plain sockets
  udp_echo.c               software echo, to test the host side without a board
  Makefile                 builds both
  README.md                how to cable and configure it, and what can lie
```

Testbenches are built from the reusable components in `testbenches/`, so a new
one is mostly the DUT plus wiring. `testbenches/README.md` explains the
components and how to add a block.

## Integration

Designed to sit behind Vivado's **XXV Ethernet (10G/25G)** IP. `uoe.vhd` is the
top level; everything below it is one clock domain, 64-bit AXI4-Stream, bytes
packed MSB-first.

### Ports

| group | direction | notes |
|---|---|---|
| `mac_rx_*` | in | from the MAC. Carries `tuser` as the MAC's per-frame error flag |
| `mac_tx_*` | out | to the MAC, with `tready` |
| `udp_rx_*` | out | payload delivered to your logic. **No `tready`** |
| `udp_tx_*` | in | payload to transmit, with `tready` |
| `udp_rx_src_mac/src_ip/src_port/dst_port` | out | who the packet came from, and which port it was for |
| `conf_mac`, `conf_ip`, `conf_port` | in | this node's own address |
| `conf_tx_dst_mac/dst_ip/dst_port` | in | where transmitted packets go |

### Things you have to know before wiring it up

**The transmit destination comes from `conf_tx_dst_*`, per packet.**
`conf_tx_dst_mac`, `conf_tx_dst_ip` and `conf_tx_dst_port` are sampled when a
packet's first beat is accepted on `udp_tx`, and that packet keeps that
address all the way out. Hold them stable from when the first beat is offered
until it is accepted — the same rule AXI-Stream applies to `tdata` — and change
them freely at any other time, including between back-to-back packets. There
is no stall on a change. The block does **not** reply to whoever sent you a
packet, and it never issues an ARP request, so it cannot discover a peer's MAC
by itself — you must supply it.

**`udp_rx` has no `tready`.** Your logic must accept a beat every cycle while
`udp_rx_tvalid` is high. There is nothing to backpressure with.

**The receive path assumes the MAC cannot be stopped.** `mac_rx_tready` exists
but the XXV MAC's receive stream ignores it, so the design is built to keep up
or drop whole frames, never to stall the sender.

**Reset can be any length; do not let the MAC send during it.** The XPM FIFOs
inside ignore a reset shorter than 4 clocks, so `uoe.vhd` stretches every
`rstn` pulse, even a one-clock glitch, to at least 64 clocks before the blocks
see it.

**Release reset only once the clock is stable** — with the XXV MAC that means
gating on GT/MMCM lock rather than a pin.

**No IP fragmentation, in either direction.** The largest frame the receive
path can buffer is `circular_buffer_filter`'s capacity, configured as
`BRAM_DEPTH` × 8 = **16 KB**; anything larger is dropped. For jumbo frames set
MTU 9000 at both ends. On transmit, a payload that would exceed the MTU is not
split.

**Checksums.** IPv4 header checksums are computed on transmit and verified on
receive. The **UDP checksum is always transmitted as zero**, which is legal for
IPv4 and means a receiver cannot detect payload corruption from the UDP layer
alone.

**No port filtering on receive.** `rx_udp` forwards every datagram that passed
the MAC and IP checks and exposes `udp_rx_dst_port` so your fabric can route
it. `conf_port` is the *source* port used on transmit.

**Minimum frame.** Payloads shorter than 18 bytes are padded on transmit to
meet Ethernet's 60-byte minimum. The padding is not counted in the UDP length
field, so the receiver still sees the original length.

### Throughput

Measured on hardware, 10G link, loopback:

| payload | sustained | of the theoretical maximum |
|--:|--:|--:|
| 8958 (jumbo) | 9.71 Gbps | 97.5 % |
| 4096 | 9.44 Gbps | 95.4 % |
| 2048 | 8.59 Gbps | 87.6 % |

Smaller payloads are limited by packet rate rather than by this design. See
`host_test/` for the tool that produced these.

## How a test works

Nothing checks itself. The work is split three ways so that no single author's
misunderstanding can make a broken design look correct:

```
  reference_model/gen_rx_udp.py   (Python)
        |
        |--> stimulus_*.txt          what to drive IN
        '--> expected_*.txt          what should come OUT
                    |
  testbenches/rx_udp_tb.vhd  (VHDL)
        reads stimulus -> drives the block -> writes axis_*.txt, sideband_*.txt
                    |
  reference_model/compare_beats.py
        expected_*.txt  vs  axis_*.txt   ->  PASS / FAIL
```

The Python side predicts; the VHDL side records; the comparison judges. Because
the design and the model are written independently from the same specification,
a disagreement means one of them is wrong -- and finding out which is the point.

Every data file is one line per **valid AXI-Stream beat**:

```
tdata(16 hex)  tkeep(2 hex)  tlast(0|1)  tuser(0|1)  [gap]
100004D200090000 FF 0 0 0
```

`tuser` is a packet-level error flag, raised together with `tlast` to mark the
packet just delivered as invalid -- rx_udp raises it on a datagram whose
declared length ran past the end of the frame, and passes on a flag rx_ipv4
raised for the same reason one layer down.

Stimulus files add a 5th column, `gap`: idle cycles to insert before that beat.
Their `tuser` column lets a test packet arrive *already* flagged, which is how
the propagation between blocks gets exercised.
Three stimulus variants share one expected file, because input timing must not
change what comes out:

| variant | input timing | catches |
|---|---|---|
| `stimulus_rx_udp_tb.txt` | no gaps | back-to-back packet handling |
| `..._ipg.txt` | gaps between packets | idle-and-reacquire |
| `..._random.txt` | gaps anywhere, incl. mid-packet | bubble tolerance |

Bytes whose `tkeep` bit is 0 are null bytes; their `tdata` content is undefined
and is not compared.

## Running

Vivado 2022.2 links one library that Ubuntu 24.04+ no longer packages,
`libtinfo.so.5`. It is a missing *file*, not a missing privilege, so it
installs into your home directory with no root:

```bash
./scripts/setup_vivado_libs.sh          # once, ~100 KB download
```

Then, from the project root:

```bash
./scripts/compile_check.sh                  # does the RTL compile? (seconds)
./scripts/run_tests.sh                      # full regression, every block
./scripts/run_tests.sh -b rx_udp -t random  # one block, one variant
./scripts/run_tests.sh -l                   # list blocks and variants
./scripts/run_uoe_test.sh                   # the whole chip, end to end
```

The block tests each prove one hop. `run_uoe_test.sh` drives `uoe` itself and
covers the three things that exist only at the top level: the endianness
converters on the MAC ports, `circular_buffer_filter` acting on the MAC's error
flag, and `arp_handler` competing with the TX path for `mac_tx` through
`axis_priority_handler`. The transmit destination changes between back-to-back
packets, and every frame's MAC, IP and port are checked. A final `reset` row
checks the reset stretcher: a one-clock glitch must still reset the design for
64 clocks.

Two streams run at once — frames into `mac_rx`, payloads into `udp_tx` — so
`mac_tx` carries both ARP replies and UDP frames. Nothing in the design fixes
how those interleave, so `split_mac_tx.py` separates them by EtherType and each
class is compared in order. That keeps every property that is specified and
tests no arbitration schedule that is not.

Open a waveform only when a test fails and the file comparison hasn't already
told you why:

```bash
./scripts/run_wave.sh                   # rx_udp, the 'random' variant
./scripts/run_wave.sh -b tx_udp -t ipg  # any block, any variant
```

The variant sets the same input timing **and** the same output backpressure the
regression used, so what you see is the run that failed, not a different one.

That reuses the regression's sources and only elaborates with `--debug typical`,
so it works even while other blocks fail to compile. `scripts/run_sim.tcl` is
the heavier alternative — it builds a real Vivado project over all of `rtl/`,
so it needs every source to analyse first.

`scripts/vivado_env.sh` finds the install and is sourced by the other scripts;
override with `VIVADO_ROOT=<dir containing bin/xvhdl>`. It deliberately does
not use Vivado's own `settings64.sh`, because the installer bakes the original
install path into that script — so an install that has since been moved leaves
`PATH` untouched and gives no error.

## Reading a failure

`compare_beats.py` compares packet by packet and names each problem by the
`# CASE` it belongs to:

- **`DROPPED`** -- an expected packet never came out.
- **`EXTRA`** -- the design emitted a packet the model did not predict.
- **`beat k of n: ...`** -- right packet, wrong contents; the beat and field
  that differ are shown.
- **`expected n beat(s), got m`** -- right packet, wrong length.
- **`sideband ... != ...`** -- a latched output (source address, port) is wrong.

A `protocol errors=N` count above zero comes from `axis_checker` instead: the
simulator log names the rule that was broken and when.

## License

MIT, see `LICENSE`.
