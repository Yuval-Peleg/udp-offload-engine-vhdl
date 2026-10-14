# Build a throwaway Vivado project, compile, and open a waveform.
#
#   vivado -source scripts/run_sim.tcl                    (defaults to rx_udp_tb)
#   vivado -source scripts/run_sim.tcl -tclargs tx_udp_tb
#
# or from an already-open Vivado Tcl Console:
#   set tb_top tx_udp_tb ; source <repo>/scripts/run_sim.tcl
#
# This is the GUI DEBUGGING flow. For regressions use non-project mode
# (xvhdl/xelab/xsim), which is faster and keeps its output in the gitignored
# reference_model/test_vectors/.

# ---- which testbench -------------------------------------------------------
if {[info exists argv] && [llength $argv] > 0} {
    set tb_top [lindex $argv 0]
} elseif {![info exists tb_top]} {
    set tb_top rx_udp_tb
}

# Derive the repo root from this script's own location -- no absolute paths,
# so the repo stays portable to any clone or mount point.
set root     [file dirname [file dirname [file normalize [info script]]]]
set proj_dir $root/.vivado_sim
set run_time 50us

# ---- part: take whatever this install actually has -------------------------
set part ""
foreach want {xc7a35tcpg236-1 xc7a100tcsg324-1 xc7z020clg400-1} {
    if {[llength [get_parts -quiet $want]] > 0} { set part $want ; break }
}
if {$part eq ""} {
    set part [lindex [get_parts] 0]
    puts "run_sim: no preferred part installed, falling back to $part"
}
puts "run_sim: part = $part, testbench = $tb_top"

# ---- project ---------------------------------------------------------------
file mkdir $proj_dir
create_project -force sim_$tb_top $proj_dir -part $part

add_files [glob $root/rtl/*.vhd]

add_files -fileset sim_1 [glob $root/testbenches/*.vhd]

# Everything as VHDL-2008 -- harmless for files that don't need it.
set_property file_type {VHDL 2008} [get_files -filter {FILE_TYPE =~ VHDL*}]

# glbl is required by the XPM/unisim Verilog primitives the FIFOs pull in.
set glbl $::env(XILINX_VIVADO)/data/verilog/src/glbl.v
if {[file exists $glbl]} {
    add_files -fileset sim_1 $glbl
}

set_property top $tb_top [get_filesets sim_1]
update_compile_order -fileset sim_1

# ---- simulate --------------------------------------------------------------
# Bounded to $run_time so the waveform opens quickly. Every testbench ends
# itself with std.env.stop, so "run all" in the Tcl console runs the rest.
launch_simulation
open_wave_config
add_wave -recursive /$tb_top
run $run_time

puts "run_sim: ran $run_time of $tb_top -- waveform should be visible."
