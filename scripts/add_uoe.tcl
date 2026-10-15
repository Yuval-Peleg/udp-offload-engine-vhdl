# Add the UOE and an XXV 10G Ethernet MAC to any block design.
#
# In the Vivado Tcl console, with the project open:
#   set argv {-ip 192.168.1.128 -dclk zynq_ultra_ps_e_0/pl_clk0 \
#             -resetn zynq_ultra_ps_e_0/pl_resetn0}
#   source <UOE>/scripts/add_uoe.tcl
# or from a shell, which opens the project and saves the block design:
#   vivado -mode batch -source add_uoe.tcl -tclargs -project <x.xpr> <options>
#
#   -ip  A.B.C.D    this board's address on the network             required
#   -dclk PIN       a free-running clock in the design, e.g. 100 MHz  required
#   -resetn PIN     an active-low reset for it                      required
#   -mac XX:..      this board's MAC          (default 00:0A:35:00:00:01)
#   -port N         the UDP port it sends from (default 1234)
#   -bd NAME        the block design          (default: the open one)
#   -refclk MHz     the GT reference clock    (default 156.25)
#   -sfp N          ZCU102 only: use SFP cage N (0..3). Sets the GT location and
#                   writes the pin and clock constraints for it, uoe_sfp.xdc
#   -gt_quad Q      other boards: the GT quad, e.g. Quad_X1Y3 \  where the SFP
#   -gt_lane L      and lane, e.g. X1Y14                     /  is wired
#   -tx_disable_b 0|1  the level on uoe_sfp_tx_disable_b, the SFP's active-low
#                   transmit disable (default 1: transmitter on)
#   -axi MASTER     an AXI master for the MAC's registers, e.g.
#                   zynq_ultra_ps_e_0/M_AXI_HPM0_FPD (default: left for you)
#   -project X.xpr  open this project first (from a shell)
#
# What it adds, all named uoe_*:
#   uoe_xxv   XXV Ethernet, MAC+PCS/PMA 64-bit, 10GBASE-R (10.3125 Gb/s), with
#             AXI4-Lite registers and statistics counters; its register port
#             runs on -dclk / -resetn
#   uoe       the UOE, packaged from rtl/ into <project>/uoe_ip
#   uoe_rst   a reset in the MAC's clock, released once the MAC is ready
#   ports     uoe_gt_ref_clk (the GT reference clock), uoe_gt_rx/tx, and
#             uoe_sfp_tx_disable_b (a constant, see -tx_disable_b)
#
# Left for you: your logic on the UOE's udp_rx / udp_tx and the conf_tx_dst_*
# inputs, clocked by uoe_xxv/tx_clk_out_0 and reset by
# uoe_rst/peripheral_aresetn; without -sfp, the constraints for the GT pins,
# the reference clock and uoe_sfp_tx_disable_b, from the board's schematic;
# and, without -axi, a master for uoe_xxv/s_axi_0.

array set o {-mac 00:0A:35:00:00:01 -port 1234 -refclk 156.25 -bd "" -project ""
             -gt_quad "" -gt_lane "" -axi "" -tx_disable_b 1 -sfp ""}
foreach {k v} $argv {
    if {![info exists o($k)] && $k ni {-ip -dclk -resetn}} { error "add_uoe: unknown option $k" }
    set o($k) $v
}
foreach k {-ip -dclk -resetn} {
    if {![info exists o($k)]} { error "add_uoe: $k is required (see the top of add_uoe.tcl)" }
}

# the addresses, as the constants the UOE takes
set ip [split $o(-ip) .]
if {[llength $ip] != 4 || [lsearch -not -regexp $ip {^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$}] >= 0} {
    error "add_uoe: -ip '$o(-ip)' is not an IPv4 address"
}
if {![regexp -nocase {^([0-9a-f]{2}:){5}[0-9a-f]{2}$} $o(-mac)]} { error "add_uoe: -mac '$o(-mac)' is not a MAC address" }
if {[expr 0x[lindex [split $o(-mac) :] 0]] & 1} { error "add_uoe: -mac '$o(-mac)' is multicast (first byte odd)" }
if {![string is integer -strict $o(-port)] || $o(-port) < 0 || $o(-port) > 65535} {
    error "add_uoe: -port must be 0..65535, not '$o(-port)'"
}
if {$o(-tx_disable_b) ni {0 1}} { error "add_uoe: -tx_disable_b must be 0 or 1" }
set ip_hex   [format 0x%02X%02X%02X%02X {*}$ip]
set mac_hex  0x[string toupper [string map {: {}} $o(-mac)]]
set port_hex [format 0x%04X $o(-port)]

if {$o(-project) ne ""} { open_project $o(-project) }
if {$o(-bd) ne ""} {
    open_bd_design [get_files $o(-bd).bd]
} elseif {[current_bd_design -quiet] eq ""} {
    set bds [get_files -quiet *.bd]
    if {[llength $bds] != 1} { error "add_uoe: [llength $bds] block designs in the project; pick one with -bd" }
    open_bd_design $bds
}
# a pin of a cell, or a port of the design
proc pin {name} {
    set p [get_bd_pins -quiet /$name]
    if {$p eq ""} { set p [get_bd_ports -quiet /$name] }
    if {$p eq ""} { error "add_uoe: no pin or port '$name' in the block design" }
    return $p
}
set dclk   [pin $o(-dclk)]
set resetn [pin $o(-resetn)]

# The ZCU102's four SFP+ cages, all on GTH bank 230 (Quad_X1Y3), cage N on
# channel N, sharing the 156.25 MHz reference on MGTREFCLK0_230:
#   cage {rxp rxn txp txn tx_disable_b}
set zcu102_sfp {0 {D2 D1 E4 E3 A12}  1 {C4 C3 D6 D5 A13}
                2 {B2 B1 B6 B5 B13}  3 {A4 A3 A8 A7 C13}}
if {$o(-sfp) ne ""} {
    if {![dict exists $zcu102_sfp $o(-sfp)]} { error "add_uoe: -sfp must be 0..3" }
    if {![string match -nocase xczu9eg-ffvb1156* [get_property PART [current_project]]]} {
        error "add_uoe: -sfp is for the ZCU102 (xczu9eg-ffvb1156); use -gt_quad / -gt_lane"
    }
    if {$o(-gt_quad) ne "" || $o(-gt_lane) ne ""} { error "add_uoe: give -sfp or -gt_quad/-gt_lane, not both" }
    set o(-gt_quad) Quad_X1Y3
    set o(-gt_lane) X1Y[expr {12 + $o(-sfp)}]
} elseif {$o(-gt_quad) eq ""} {
    puts "add_uoe: WARNING no -sfp or -gt_quad given; Vivado puts the MAC on its first GT,"
    puts "add_uoe: WARNING which is probably not where your SFP is wired"
}

# 1. the UOE, packaged in a Vivado of its own (packaging needs its own project)
set repo [file normalize [get_property DIRECTORY [current_project]]/uoe_ip]
exec [file join $::env(XILINX_VIVADO) bin vivado] -mode batch -nojournal -nolog \
    -source [file dirname [file normalize [info script]]]/package_uoe.tcl \
    -tclargs [get_property PART [current_project]] $repo >@ stdout
if {$repo ni [get_property ip_repo_paths [current_project]]} {
    set_property ip_repo_paths [concat [get_property ip_repo_paths [current_project]] $repo] [current_project]
}
update_ip_catalog -rebuild

# 2. the MAC. GT_DRP_CLK must be dclk's frequency.
set mhz [expr {[get_property CONFIG.FREQ_HZ $dclk] / 1e6}]
set xxv [create_bd_cell -type ip -vlnv xilinx.com:ip:xxv_ethernet uoe_xxv]
set cfg [list CONFIG.CORE {Ethernet MAC+PCS/PMA 64-bit} CONFIG.LINE_RATE 10 CONFIG.BASE_R_KR BASE-R \
              CONFIG.INCLUDE_AXI4_INTERFACE 1 CONFIG.INCLUDE_STATISTICS_COUNTERS 1 \
              CONFIG.GT_REF_CLK_FREQ $o(-refclk) CONFIG.GT_DRP_CLK [format %.2f $mhz]]
if {$o(-gt_quad) ne ""} { lappend cfg CONFIG.GT_GROUP_SELECT $o(-gt_quad) }
if {$o(-gt_lane) ne ""} { lappend cfg CONFIG.LANE1_GT_LOC $o(-gt_lane) }
set_property -dict $cfg $xxv

set ref [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 uoe_gt_ref_clk]
set_property CONFIG.FREQ_HZ [expr {round($o(-refclk) * 1e6)}] $ref
connect_bd_intf_net $ref [get_bd_intf_pins uoe_xxv/gt_ref_clk]
foreach {pin port dir} {gt_rxp_in_0 uoe_gt_rxp I  gt_rxn_in_0 uoe_gt_rxn I
                        gt_txp_out_0 uoe_gt_txp O gt_txn_out_0 uoe_gt_txn O} {
    connect_bd_net [create_bd_port -dir $dir $port] [get_bd_pins uoe_xxv/$pin]
}

# its remaining control pins, as constants: {name width value pins}. tx_axis_tuser
# would make the MAC corrupt the frame's FCS; the UOE only sends valid frames,
# so it has no tuser and the pin is tied off here. Everything else
# (enables, FCS, frame lengths, IPG) is an AXI4-Lite register, at its reset
# value unless software changes it. One constant per purpose, shared by every
# pin that needs it.
foreach {name w v pins} {
    uoe_xxv_unused_off         1  0 {ctl_tx_send_idle_0 ctl_tx_send_lfi_0 ctl_tx_send_rfi_0
                                     rx_reset_0 tx_reset_0 pm_tick_0 tx_axis_tuser_0}
    uoe_xxv_no_custom_preamble 56 0 {tx_preamblein_0}
    uoe_gt_outclk_sel          3  5 {rxoutclksel_in_0 txoutclksel_in_0}
} {
    set c [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant $name]
    set_property -dict [list CONFIG.CONST_WIDTH $w CONFIG.CONST_VAL $v] $c
    set to {}
    foreach p $pins { lappend to uoe_xxv/$p }
    connect_bd_net [get_bd_pins $c/dout] [get_bd_pins $to]
}
set c [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant \
    [expr {$o(-tx_disable_b) ? "uoe_sfp_tx_on" : "uoe_sfp_tx_off"}]]
set_property -dict [list CONFIG.CONST_WIDTH 1 CONFIG.CONST_VAL $o(-tx_disable_b)] $c
connect_bd_net [get_bd_pins $c/dout] [create_bd_port -dir O uoe_sfp_tx_disable_b]

# its resets are active high
set inv [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic uoe_rst_inv]
set_property -dict {CONFIG.C_OPERATION not CONFIG.C_SIZE 1} $inv
connect_bd_net $resetn [get_bd_pins uoe_rst_inv/Op1]
connect_bd_net [get_bd_pins uoe_rst_inv/Res] [get_bd_pins uoe_xxv/sys_reset] \
    [get_bd_pins uoe_xxv/gtwiz_reset_rx_datapath_0] [get_bd_pins uoe_xxv/gtwiz_reset_tx_datapath_0] \
    [get_bd_pins uoe_xxv/qpllreset_in_0]
connect_bd_net $dclk [get_bd_pins uoe_xxv/dclk] [get_bd_pins uoe_xxv/s_axi_aclk_0]
connect_bd_net $resetn [get_bd_pins uoe_xxv/s_axi_aresetn_0]
if {$o(-axi) ne ""} {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list Clk_master Auto Clk_slave Auto \
        Clk_xbar Auto Master /$o(-axi) Slave /uoe_xxv/s_axi_0 ddr_seg Auto \
        intc_ip {New AXI SmartConnect} master_apm 0] [get_bd_intf_pins uoe_xxv/s_axi_0]
}

# everything on the network side runs on the MAC's transmit clock
set clk [get_bd_pins uoe_xxv/tx_clk_out_0]
connect_bd_net $clk [get_bd_pins uoe_xxv/rx_core_clk_0]

# 3. a reset in that clock, held until the MAC's transmit side is out of
#    reset (the UOE's rstn must not be released before its clock is stable)
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset uoe_rst
set rdy [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic uoe_tx_ready]
set_property -dict {CONFIG.C_OPERATION not CONFIG.C_SIZE 1} $rdy
connect_bd_net [get_bd_pins uoe_xxv/user_tx_reset_0] [get_bd_pins uoe_tx_ready/Op1]
connect_bd_net [get_bd_pins uoe_tx_ready/Res] [get_bd_pins uoe_rst/dcm_locked]
connect_bd_net $clk [get_bd_pins uoe_rst/slowest_sync_clk]
connect_bd_net $resetn [get_bd_pins uoe_rst/ext_reset_in]

# 4. the UOE, on the MAC, with its own address
create_bd_cell -type ip -vlnv uoe:uoe:uoe:1.0 uoe
foreach {pin w v} [list conf_mac 48 $mac_hex conf_ip 32 $ip_hex conf_port 16 $port_hex] {
    set c [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant uoe_$pin]
    set_property -dict [list CONFIG.CONST_WIDTH $w CONFIG.CONST_VAL $v] $c
    connect_bd_net [get_bd_pins $c/dout] [get_bd_pins uoe/$pin]
}
connect_bd_net $clk [get_bd_pins uoe/clk]
connect_bd_net [get_bd_pins uoe_rst/peripheral_aresetn] [get_bd_pins uoe/rstn]
connect_bd_intf_net [get_bd_intf_pins uoe_xxv/axis_rx_0] [get_bd_intf_pins uoe/mac_rx]
connect_bd_intf_net [get_bd_intf_pins uoe/mac_tx] [get_bd_intf_pins uoe_xxv/axis_tx_0]

regenerate_bd_layout
save_bd_design

# 5. with -sfp, the board's constraints for that cage
if {$o(-sfp) ne ""} {
    lassign [dict get $zcu102_sfp $o(-sfp)] rxp rxn txp txn txdis
    set xdc [file normalize [get_property DIRECTORY [current_project]]/uoe_sfp.xdc]
    set f [open $xdc w]
    puts $f "# written by add_uoe.tcl -sfp $o(-sfp): ZCU102 SFP cage $o(-sfp)"
    foreach {port loc} [list uoe_gt_rxp $rxp uoe_gt_rxn $rxn uoe_gt_txp $txp uoe_gt_txn $txn \
                             uoe_gt_ref_clk_clk_p C8 uoe_gt_ref_clk_clk_n C7] {
        puts $f "set_property PACKAGE_PIN $loc \[get_ports $port\]"
    }
    puts $f "create_clock -period [format %.3f [expr {1000.0 / $o(-refclk)}]] -name uoe_gt_ref_clk \[get_ports uoe_gt_ref_clk_clk_p\]"
    puts $f "set_property PACKAGE_PIN $txdis \[get_ports uoe_sfp_tx_disable_b\]"
    puts $f "set_property IOSTANDARD LVCMOS33 \[get_ports uoe_sfp_tx_disable_b\]"
    close $f
    if {[get_files -quiet $xdc] eq ""} { add_files -fileset constrs_1 $xdc }
    puts "add_uoe: SFP cage $o(-sfp): $o(-gt_quad) / $o(-gt_lane), constraints in $xdc"
}
puts "add_uoe: added, the board is $o(-ip) / [string toupper $o(-mac)]. Your logic goes on uoe/udp_rx and"
puts "add_uoe: uoe/udp_tx, on uoe_xxv/tx_clk_out_0 and uoe_rst/peripheral_aresetn."
if {$o(-sfp) eq ""} { puts "add_uoe: The GT pins, reference clock and uoe_sfp_tx_disable_b go in your constraints." }
