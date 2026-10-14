#!/usr/bin/env bash
# Open a waveform for one block and one timing variant.
#
#   ./scripts/run_wave.sh                          rx_udp, random variant
#   ./scripts/run_wave.sh -b rx_ipv4 -t gapless    any block, any variant
#
# Non-project mode, same sources as run_tests.sh, just elaborated with debug
# info on. Lighter than scripts/run_sim.tcl, which builds a full Vivado
# project over every file in rtl/.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VECTORS="$ROOT/reference_model/test_vectors"
PYDIR="$ROOT/reference_model"

# shellcheck disable=SC1091
source "$ROOT/scripts/vivado_env.sh"
if ! command -v xelab >/dev/null 2>&1; then
    echo "Vivado not found. Run ./scripts/setup_vivado_libs.sh first." >&2
    exit 1
fi

BLOCK="rx_udp"
VARIANT="random"
while getopts ":b:t:h" opt; do
    case "$opt" in
        b) BLOCK="$OPTARG" ;;
        t) VARIANT="$OPTARG" ;;
        h) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "usage: $0 [-b block] [-t gapless|ipg|random]" >&2; exit 2 ;;
    esac
done

case "$VARIANT" in
    gapless) STIM="stimulus_${BLOCK}_tb.txt" ;;
    ipg)     STIM="stimulus_${BLOCK}_tb_ipg.txt" ;;
    random)  STIM="stimulus_${BLOCK}_tb_random.txt" ;;
    *) echo "unknown variant '$VARIANT' (gapless | ipg | random)" >&2; exit 1 ;;
esac

TB="$ROOT/testbenches/${BLOCK}_tb.vhd"
RTL="$ROOT/rtl/${BLOCK}.vhd"
GEN="$PYDIR/gen_${BLOCK}.py"
for f in "$TB" "$RTL" "$GEN"; do
    [ -f "$f" ] || { echo "no such block '$BLOCK' -- missing $f" >&2; exit 1; }
done

# The same tables as the regression, so the waveform reproduces the run that
# failed rather than some other timing.
# shellcheck disable=SC1091
source "$ROOT/scripts/test_tables.sh"

[ -f "$VECTORS/$STIM" ] || python3 "$GEN" "$VECTORS" >/dev/null
cd "$VECTORS" || exit 1

echo "== analysing =================================================="
xvhdl --2008 --work work "${VC_SRCS[@]}" "$RTL" "$TB" > .wave.log 2>&1 || {
    grep -iE "error" .wave.log | head -20; exit 1; }

xelab_extra=()
tops=("work.${BLOCK}_tb")
if [ -n "${NEEDS_XPM[$BLOCK]:-}" ]; then
    # Located from the toolchain, never hardcoded -- no absolute paths in the
    # repo. vivado_env.sh only fixes PATH, so derive the install root from the
    # tool we just found rather than expecting it to export one.
    GLBL_V="$(dirname "$(dirname "$(command -v xvhdl)")")/data/verilog/src/glbl.v"
    [ -f "$GLBL_V" ] && xvlog "$GLBL_V" >> .wave.log 2>&1
    xelab_extra+=(-L xpm -L unisims_ver)
    tops+=("work.glbl")
fi

# A block with no latched outputs has no sideband monitor and no SIDEBAND_FILE
# generic; the tx blocks are all like that. Passing it anyway is a hard xelab
# error ("Parameter/Generic ... not found in design"), not a warning.
gen_args=(-generic_top "STIMULUS_FILE=$STIM"
          -generic_top "AXIS_FILE=wave_axis_${BLOCK}_$VARIANT.txt")
if [ -f "$VECTORS/expected_sideband_${BLOCK}_tb.txt" ]; then
    gen_args+=(-generic_top "SIDEBAND_FILE=wave_sideband_${BLOCK}_$VARIANT.txt")
fi
if grep -q 'READY_PERCENT' "$TB"; then
    gen_args+=(-generic_top "READY_PERCENT=${STALL[$VARIANT]}")
fi
# a two-input block takes a second stimulus file, named like run_tests.sh's
STIM_S1="${STIM/_tb/_tb_s1}"
if [ -f "$VECTORS/$STIM_S1" ]; then
    gen_args+=(-generic_top "STIMULUS_S1=$STIM_S1")
fi

echo "== elaborating (debug on) ====================================="
# --debug typical is what makes signals visible in the waveform; run_tests.sh
# uses --debug off because it only needs the output files, and it is faster.
xelab --debug typical -s snap_wave \
      "${xelab_extra[@]}" "${gen_args[@]}" "${tops[@]}" >> .wave.log 2>&1 || {
    grep -iE "error" .wave.log | head -20; exit 1; }

# Only the block name is substituted by the shell here; the body below is a
# quoted heredoc so Tcl's own $variables survive.
cat > .wave.tcl <<TCL
set tb ${BLOCK}_tb
TCL

cat >> .wave.tcl <<'TCL'
log_wave -recursive *

# Add a signal only if this block actually has it -- the wave list is shared by
# every block, but e.g. src_port exists on rx_udp and src_ip on rx_ipv4.
#
# "catch { add_wave ... }" does NOT work for this: add_wave prints
# "ERROR: [Wavedata 42-471] Nothing was found for the following items"
# to the console itself without raising a Tcl error, so catch has nothing to
# suppress and the message reaches the GUI anyway. get_objects -quiet is the
# only form that is genuinely silent on a miss.
proc wave_if {path args} {
    if {[llength [get_objects -quiet $path]] > 0} {
        eval add_wave $args [list $path]
    }
}

# A focused view first; everything else is still logged and can be dragged in
# from the Scope/Objects panes.
wave_if /$tb/case_name
wave_if /$tb/case_index -radix unsigned
wave_if /$tb/DUT/state
wave_if /$tb/DUT/header_word_count -radix unsigned
wave_if /$tb/DUT/total_len_buffer -radix hex
wave_if /$tb/s_axis
wave_if /$tb/s_tready
wave_if /$tb/m_axis
wave_if /$tb/m_tready
wave_if /$tb/src_port -radix hex
wave_if /$tb/src_ip -radix hex

# tx only: the internal packet FIFO's handshake, the first place to look when
# a tx block misbehaves under backpressure.
wave_if /$tb/DUT/m_axis_fifo_tvalid
wave_if /$tb/DUT/m_axis_packet_tvalid

run all
TCL

echo "== opening the GUI ============================================"
echo "   block: $BLOCK   variant: $VARIANT   stimulus: $STIM"
exec xsim snap_wave -gui -tclbatch .wave.tcl
