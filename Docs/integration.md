# Integrating the UOE

Designed to sit behind Vivado's **XXV Ethernet (10G/25G)** IP. `uoe.vhd` is the
top level; everything below it is one clock domain, 64-bit AXI4-Stream, bytes
packed MSB-first.

Its ports are listed in the [README](../README.md#ports).

## Things you have to know before wiring it up

- **The transmit destination comes from `conf_tx_dst_*`, per packet.**
  `conf_tx_dst_mac`, `conf_tx_dst_ip` and `conf_tx_dst_port` are sampled when a
  packet's first beat is accepted on `udp_tx`, and that packet keeps that
  address all the way out. Hold them stable from when the first beat is offered
  until it is accepted — the same rule AXI-Stream applies to `tdata` — and change
  them freely at any other time, including between back-to-back packets. There
  is no stall on a change. The block does **not** reply to whoever sent you a
  packet, and it never issues an ARP request, so it cannot discover a peer's MAC
  by itself — you must supply it.
- **`udp_rx` has no `tready`.** Your logic must accept a beat every cycle while
  `udp_rx_tvalid` is high. There is nothing to backpressure with.
- **The receive path assumes the MAC cannot be stopped.** `mac_rx_tready` exists
  but the XXV MAC's receive stream ignores it, so the design is built to keep up
  or drop whole frames, never to stall the sender.
- **Reset can be any length; do not let the MAC send during it.** The XPM FIFOs
  inside ignore a reset shorter than 4 clocks, so `uoe.vhd` stretches every
  `rstn` pulse, even a one-clock glitch, to at least 64 clocks before the blocks
  see it.
- **Release reset only once the clock is stable** — with the XXV MAC that means
  gating on GT/MMCM lock rather than a pin.
- **No IP fragmentation, in either direction.** The largest frame the receive
  path can buffer is `circular_buffer_filter`'s capacity, configured as
  `BRAM_DEPTH` × 8 = **16 KB**; anything larger is dropped. For jumbo frames set
  MTU 9000 at both ends. On transmit, a payload that would exceed the MTU is not
  split.
- **Checksums.** IPv4 header checksums are computed on transmit and verified on
  receive. The **UDP checksum is always transmitted as zero**, which is legal for
  IPv4 and means a receiver cannot detect payload corruption from the UDP layer
  alone.
- **No port filtering on receive.** `rx_udp` forwards every datagram that passed
  the MAC and IP checks and exposes `udp_rx_dst_port` so your fabric can route
  it. `conf_port` is the *source* port used on transmit.
- **Minimum frame.** Payloads shorter than 18 bytes are padded on transmit to
  meet Ethernet's 60-byte minimum. The padding is not counted in the UDP length
  field, so the receiver still sees the original length.

## Using it in a block design

Package it as an IP, for the part of the project it is for:

```bash
./scripts/package_uoe.sh --part <part> [--out <ip folder>]
```

Or let `add_uoe.sh` package it and add it, wired to an XXV MAC (10GBASE-R),
to a project's block design (with the project closed in Vivado):

```bash
./scripts/add_uoe.sh --project my_project.xpr --ip 192.168.1.128 \
    --dclk zynq_ultra_ps_e_0/pl_clk0 --resetn zynq_ultra_ps_e_0/pl_resetn0 --sfp 0
```

Or, with the project open, from the Vivado Tcl console:

```tcl
set argv {-ip 192.168.1.128 -dclk zynq_ultra_ps_e_0/pl_clk0 \
          -resetn zynq_ultra_ps_e_0/pl_resetn0 -sfp 0}
source <path to this repo>/scripts/add_uoe.tcl
```

The options are the same either way, with two dashes for the shell script and
one in the Tcl console. `--sfp N` is for the ZCU102 and also writes the GT
pin, reference clock and `TX_DISABLE` constraints; on other boards pass
`--gt_quad`/`--gt_lane` instead. `--axi` connects an AXI master to the MAC's
registers. The full list of options is at the top of `add_uoe.tcl`.

Left for you: your logic on `udp_rx`/`udp_tx` and `conf_tx_dst_*`, clocked by
`uoe_xxv/tx_clk_out_0` and reset by `uoe_rst/peripheral_aresetn`; without
`-sfp`, the GT pin, reference clock and `uoe_sfp_tx_disable_b` constraints from
your board's schematic; without `-axi`, a master for `uoe_xxv/s_axi_0`.
