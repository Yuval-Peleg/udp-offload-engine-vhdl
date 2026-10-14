# Testbenches

Every block has a testbench here, built from a few reusable verification
components. A testbench is mostly the DUT and its wiring; the components do
the file I/O, the handshakes and the protocol checks.

## How a test fits together

```
reference_model/gen_<block>.py  ->  stimulus_*.txt, expected_*.txt
                                          |
<block>_tb.vhd:  axis_driver -> DUT -> axis_monitor  ->  axis_*.txt
                                 |  \-> axis_checker  (protocol, every cycle)
                         axis_stall (output backpressure)
                                          |
reference_model/compare_beats.py:  expected_*.txt vs axis_*.txt  ->  PASS / FAIL
```

Two independent judges look at every run:

| | `axis_checker` | `compare_beats.py` |
|---|---|---|
| runs | in simulation, every cycle | on the output files, afterwards |
| knows | the AXI-Stream rules | what the payload should be |
| catches | illegal handshakes, bad `tkeep`, X/U values, lost `tlast` | wrong data, dropped or extra packets |

Neither replaces the other. A protocol violation can leave the data intact,
and wrong data can follow every protocol rule.

## The components

All of them use `axis_beat_t` from `axis_pkg.vhd`: one record holding `tdata`
(64 bits), `tkeep` (8), `tvalid`, `tlast` and `tuser` (a packet-level error
flag, raised with `tlast`). `tready` flows the other way, so it is always a
separate signal. Bytes are packed MSB-first: byte 0 is `tdata(63 downto 56)`
and `tkeep(7)`.

| component | does | key generics |
|---|---|---|
| `axis_driver` | plays a stimulus file onto a bus; holds each beat until `tready` | `STIMULUS_FILE`, `IGNORE_TREADY` (model a source that cannot be stopped), `START_DELAY` |
| `axis_monitor` | writes every accepted beat (`tvalid` and `tready`) to a file | `AXIS_FILE`, `MAX_BEATS` (stops a runaway DUT filling the disk) |
| `sideband_monitor` | writes a non-AXIS output, e.g. `src_port`, each time `trigger` is high | `SIDEBAND_FILE`, `WIDTH` (a multiple of 4) |
| `axis_checker` | asserts the AXI-Stream rules below and counts violations | `NAME`, `MAX_PACKET_BEATS`, `CHECK_KEEP_RULES`, `KEEP_LSB_FIRST`, `CHECK_TUSER_ON_TLAST` |
| `axis_stall` | drives a random `tready` | `READY_PERCENT` (100 = never stall), `SEED1`, `SEED2` |

For a bus with no `tready` (the RX path), tie the component's `tready` to
`'1'`.

### What `axis_checker` enforces

From the AXI-Stream specification:

1. Once `tvalid` is high it stays high until `tready` is also high.
2. While stalled (`tvalid` high, `tready` low), `tdata`, `tkeep`, `tlast` and
   `tuser` do not change.
3. `tvalid` is low during reset.

Conventions of this design:

4. `tkeep` is never 0 on a valid beat.
5. `tkeep` is contiguous from bit 7 down.
6. Only the last beat of a packet may have a partial `tkeep`.
7. A packet ends within `MAX_PACKET_BEATS` beats; a lost `tlast` would
   otherwise just hang a downstream FIFO.
8. No X/U on `tvalid`; on a valid beat, none on `tlast`, `tkeep`, `tuser`, or
   on `tdata` in bytes whose `tkeep` bit is set.
9. `tuser` is only raised together with `tlast`.

`tready` itself has no stability rule: a receiver may change it at any time.

## File format

One line per beat, in hex:

```
tdata(16 hex)  tkeep(2 hex)  tlast(0|1)  tuser(0|1)  [gap]
100004D200090000 FF 0 0 0
```

Stimulus files add `gap`, the number of idle cycles to insert before that
beat. Lines starting with `#` are comments. A `# CASE <n> <text>` line names
the packet that follows; `axis_driver` puts it on `case_index` / `case_name`,
so a waveform shows which packet is being driven.

Bytes whose `tkeep` bit is 0 are null bytes. Their content is undefined and
is never compared.

## Timing variants

Each block runs three times against the same expected file, because input
timing and output backpressure must never change the output:

| variant | input gaps | output ready |
|---|---|---|
| `gapless` | none | 100 % |
| `ipg` | between packets | 70 % |
| `random` | anywhere, including mid-packet | 40 % |

## Adding a block

1. `reference_model/gen_<block>.py` writes the stimulus and expected files.
   Copy a similar generator; the protocol logic lives in `uoe_model.py`.
2. `testbenches/<block>_tb.vhd`: copy a similar testbench and change the DUT.
   Give it the generics `STIMULUS_FILE` and `AXIS_FILE`, plus
   `SIDEBAND_FILE` and `READY_PERCENT` if it uses them.
3. In `scripts/run_tests.sh`, add the block to `BLOCKS` and its sources to
   `RTL_SRCS`. If it uses an XPM primitive (FIFO or memory), also add it to
   `NEEDS_XPM` in `scripts/test_tables.sh`.

The testbench must end by printing a line containing
`protocol errors=<n>`. `xsim` exits 0 even when an assertion fails, so the
scripts read that line to decide pass or fail; a missing line counts as a
failure.

Before trusting a new check, break the DUT on purpose once and make sure the
check fails.

## Simulator notes (Vivado xsim 2022.2)

- Compile every file with `xvhdl --2008`, packages first.
- `-generic_top` only reaches the top-level entity, so a testbench passes its
  own generics down to the components.
- `report ... severity error` does not stop the simulation; that is why
  `axis_checker` counts errors and the testbench checks the count at the end.
