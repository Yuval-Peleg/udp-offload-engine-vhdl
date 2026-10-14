# Sourced by run_tests.sh, run_uoe_test.sh and run_wave.sh -- not executed
# directly. One copy of the tables they share, so they cannot drift apart.
# Expects ROOT to be set to the repository root.

# Reusable AXIS verification components, shared by every testbench. Order
# matters: the package must be analysed before anything that uses it.
# See testbenches/README.md.
VC_SRCS=(
    "$ROOT/testbenches/axis_pkg.vhd"
    "$ROOT/testbenches/axis_checker.vhd"
    "$ROOT/testbenches/axis_monitor.vhd"
    "$ROOT/testbenches/sideband_monitor.vhd"
    "$ROOT/testbenches/axis_driver.vhd"
    "$ROOT/testbenches/axis_stall.vhd"
)

# Blocks built on XPM (xpm_fifo_axis in the tx blocks, xpm_memory in
# circular_buffer_filter) need two things the others do not: the XPM library,
# and Xilinx's glbl module (it drives the global set/reset the primitives
# expect). glbl.v ships with Vivado and is elaborated as a second top level.
declare -A NEEDS_XPM=( [tx_udp]=1 [tx_ipv4]=1 [tx_eth]=1 [circular_buffer_filter]=1 )

# Output backpressure per variant, as a READY_PERCENT. The same expected file
# has to survive all three, because neither input timing nor output stalling
# may change a single byte of the packet.
declare -A STALL=( [gapless]=100 [ipg]=70 [random]=40 )
