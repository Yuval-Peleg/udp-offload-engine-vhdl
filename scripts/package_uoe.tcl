# Package the UOE as a Vivado IP, from the VHDL in rtl/ as it is now.
#
#   vivado -mode batch -source scripts/package_uoe.tcl -tclargs <part> [ip folder]
#
#   <part>       the FPGA part of the project it is for, e.g. xczu9eg-ffvb1156-2-e
#   [ip folder]  where to write it (default ip/ next to rtl/); the IP lands in
#                <ip folder>/uoe
#
# Then add <ip folder> to a project's IP repositories (Settings > IP >
# Repository) and the UOE is in the catalog as "UDP Offload Engine".
#
# Packaging groups the AXI4-Stream buses from the port names but makes no
# clock interface, so every bus would fall back to 100 MHz and rstn would lose
# its polarity. The clock, its four buses and its reset are declared here, and
# the IP is not saved unless every bus came out on the clock. No frequency is
# set: the clock takes its source's in the block design.
set part [lindex $argv 0]
if {$part eq ""} { error "package_uoe: give the FPGA part (see the top of package_uoe.tcl)" }
set root [file normalize [file dirname [info script]]/..]
set repo [file normalize [expr {[llength $argv] > 1 ? [lindex $argv 1] : "$root/ip"}]]
set busif {mac_rx mac_tx udp_rx udp_tx}

proc bus_param {bi name value} {
    set bp [ipx::get_bus_parameters -quiet $name -of_objects $bi]
    if {$bp eq ""} { set bp [ipx::add_bus_parameter $name $bi] }
    set_property value $value $bp
}

set work $repo/.pkg_uoe
file delete -force $work $repo/uoe
file mkdir $work
create_project -force pkg_uoe $work -part $part
set_property target_language VHDL [current_project]
add_files [glob $root/rtl/*.vhd]
set_property top uoe [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $repo/uoe -vendor uoe -library uoe \
    -taxonomy /UserIP -import_files -set_current true
set core [ipx::current_core]
set_property name uoe $core
set_property display_name "UDP Offload Engine" $core

set clk [ipx::get_bus_interfaces -quiet clk -of_objects $core]
if {$clk eq ""} { ipx::infer_bus_interface clk xilinx.com:signal:clock_rtl:1.0 $core
                  set clk [ipx::get_bus_interfaces clk -of_objects $core] }
bus_param $clk ASSOCIATED_BUSIF [join $busif :]
# packaging may have guessed a frequency; the source's is the right one
set bp [ipx::get_bus_parameters -quiet FREQ_HZ -of_objects $clk]
if {$bp ne ""} { ipx::remove_bus_parameter FREQ_HZ $clk }
bus_param $clk ASSOCIATED_RESET rstn
bus_param [ipx::get_bus_interfaces rstn -of_objects $core] POLARITY ACTIVE_LOW

set bad 0
foreach bus $busif {
    if {[ipx::get_bus_interfaces -quiet $bus -of_objects $core] eq ""} {
        puts "package_uoe: MISSING bus interface $bus"; incr bad
    } else { puts "package_uoe: ok $bus on clk" }
}
if {$bad} { error "package_uoe: $bad bus(es) missing, IP not saved" }

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::check_integrity $core
ipx::save_core $core
close_project
file delete -force $work
puts "package_uoe: saved $repo/uoe"
