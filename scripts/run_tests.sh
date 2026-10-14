#!/usr/bin/env bash
#
# THE REGRESSION. Run this every time you change RTL.
#
#   ./scripts/run_tests.sh                     every block, every variant
#   ./scripts/run_tests.sh -b rx_udp           one block, all variants
#   ./scripts/run_tests.sh -b rx_udp -t random one block, one variant
#   ./scripts/run_tests.sh -t random           every block, one variant
#   ./scripts/run_tests.sh -l                  list what is available
#   RTL_DIR=<dir> ./scripts/run_tests.sh       run against another copy of rtl/
#
# What it does, for each selected block:
#
#   1. REGENERATE  gen_<block>.py builds the test packets and writes
#                  stimulus_<block>_tb*.txt (what to drive in) and
#                  expected_*_<block>_tb.txt (what should come out).
#                  Re-run every time, so the data can never go stale.
#
#   2. ANALYSE     xvhdl compiles the reusable verification components,
#                  then the RTL, then the testbench.
#
#   3. ELABORATE   xelab builds one simulation snapshot per variant. The
#                  filenames are passed in as generics -- that is how one
#                  testbench serves three different input timings.
#
#   4. SIMULATE    xsim runs it. The testbench writes one line per valid
#                  output beat, and fails the run if axis_checker saw any
#                  AXI-Stream protocol violation.
#
#   5. COMPARE     compare_beats.py diffs actual against expected. Bytes
#                  whose tkeep bit is 0 are null bytes and are ignored.
#
# All variants of a block are compared against the SAME expected file,
# because input timing must not change what comes out.
#
# Non-project mode on purpose: faster than a Vivado project, and everything
# runs with test_vectors/ as the working directory, so the testbenches' bare
# filenames resolve without any absolute paths anywhere in the repo.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VECTORS="$ROOT/reference_model/test_vectors"
PYDIR="$ROOT/reference_model"
# Another copy of rtl/ -- a mutant, or a candidate fix -- without touching rtl/.
RTL_DIR="${RTL_DIR:-$ROOT/rtl}"

# =============================================================================
# COLOUR
#
# Off when stdout is not a terminal, or when NO_COLOR is set
# (https://no-color.org); the variables are then empty strings.
#
# A coloured word must be padded BEFORE it is coloured: printf counts the
# invisible escape bytes toward a %-8s width, which would push every later
# column out of line. result_field() does that.
# =============================================================================

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_BOLD=""; C_RESET=""
fi

# Pad a RESULT word to the column's width, then colour it. Print the result
# with a plain %s.
result_field() {
    local word="$1" colour="$2" padded
    padded=$(printf '%-8s' "$word")
    printf '%s%s%s' "$colour" "$padded" "$C_RESET"
}

# =============================================================================
# WHAT CAN BE TESTED
#
# To add a block: create reference_model/gen_<block>.py and
# testbenches/<block>_tb.vhd, then add the block to BLOCKS and RTL_SRCS
# below, and to NEEDS_XPM in scripts/test_tables.sh if it uses XPM.
# =============================================================================

BLOCKS=(rx_eth rx_ipv4 rx_udp tx_udp tx_ipv4 tx_eth circular_buffer_filter
        axis_priority_handler arp_handler)

# RTL each block's testbench needs, in analysis order. Keep these minimal, so
# one block that fails to compile does not stop the others from running.
declare -A RTL_SRCS=(
    [rx_eth]="rtl/rx_eth.vhd"
    [rx_ipv4]="rtl/rx_ipv4.vhd"
    [rx_udp]="rtl/rx_udp.vhd"
    [tx_udp]="rtl/tx_udp.vhd"
    [tx_ipv4]="rtl/tx_ipv4.vhd"
    [tx_eth]="rtl/tx_eth.vhd"
    [circular_buffer_filter]="rtl/circular_buffer_filter.vhd"
    [axis_priority_handler]="rtl/axis_priority_handler.vhd"
    [arp_handler]="rtl/arp_handler.vhd"
)

# shellcheck disable=SC1091
source "$ROOT/scripts/test_tables.sh"

VARIANTS=(gapless ipg random)

# =============================================================================
# ARGUMENTS
# =============================================================================

# used by the argument validation below
in_list() { local n="$1"; shift; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

usage() {
    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

# Every test in the repo, not just the ones this script runs. The full-chip and
# reset tests live in run_uoe_test.sh because they do not fit this script's
# one-stimulus, one-expected-file shape.
list_tests() {
    local b

    echo
    echo "  ${C_BOLD:-}block tests${C_RESET:-}   ./scripts/run_tests.sh [-b block] [-t variant]"
    for b in "${BLOCKS[@]}"; do
        printf '    %-10s %s\n' "$b" "${VARIANTS[*]}"
    done

    echo
    echo "  ${C_BOLD:-}whole chip${C_RESET:-}    ./scripts/run_uoe_test.sh [-t variant]"
    printf '    %-10s %s\n' "uoe" "${VARIANTS[*]}"
    printf '    %-10s %s\n' "" "mac_rx + udp_tx driven together; checks udp_rx and mac_tx"
    printf '    %-10s %s\n' "reset" "the reset stretcher: short pulses must still reset for 64 clocks"

    echo
    echo "  ${C_BOLD:-}waveform${C_RESET:-}      ./scripts/run_wave.sh -b <block> -t <variant>"

    echo
}

WANT_BLOCK=""
WANT_VARIANT=""

while getopts ":b:t:lh" opt; do
    case "$opt" in
        b) WANT_BLOCK="$OPTARG" ;;
        t) WANT_VARIANT="$OPTARG" ;;
        l) list_tests; exit 0 ;;
        h) usage 0 ;;
        :) echo "-$OPTARG needs a value" >&2; usage 2 ;;
        *) echo "unknown option -$OPTARG" >&2; usage 2 ;;
    esac
done
shift $((OPTIND - 1))

if [ $# -gt 0 ]; then
    echo "unexpected argument '$1' -- use -b <block> and -t <variant>" >&2
    usage 2
fi


if [ -n "$WANT_BLOCK" ] && ! in_list "$WANT_BLOCK" "${BLOCKS[@]}"; then
    echo "unknown block '$WANT_BLOCK'. Known: ${BLOCKS[*]}" >&2
    exit 2
fi
if [ -n "$WANT_VARIANT" ] && ! in_list "$WANT_VARIANT" "${VARIANTS[@]}"; then
    echo "unknown variant '$WANT_VARIANT'. Known: ${VARIANTS[*]}" >&2
    exit 2
fi

# =============================================================================
# TOOLCHAIN
# =============================================================================

# shellcheck disable=SC1091
source "$ROOT/scripts/vivado_env.sh"
if ! command -v xvhdl >/dev/null 2>&1; then
    echo "Vivado not found. Set VIVADO_ROOT=<dir containing bin/xvhdl>," >&2
    echo "and run ./scripts/setup_vivado_libs.sh if you have not already." >&2
    exit 1
fi

mkdir -p "$VECTORS"
LOG="$VECTORS/.sim.log"
: > "$LOG"

# glbl.v lives inside the Vivado install; locate it from the xvhdl we found
# rather than hardcoding a path, so this stays portable.
VIVADO_BIN="$(dirname "$(command -v xvhdl)")"
GLBL_V="$(dirname "$VIVADO_BIN")/data/verilog/src/glbl.v"
if [ -f "$GLBL_V" ]; then
    (cd "$VECTORS" && xvlog "$GLBL_V") >>"$LOG" 2>&1 || true
fi

pass=0; fail=0

# =============================================================================
# ONE BLOCK AT A TIME
# =============================================================================

for block in "${BLOCKS[@]}"; do
    [ -n "$WANT_BLOCK" ] && [ "$WANT_BLOCK" != "$block" ] && continue

    gen="$PYDIR/gen_$block.py"
    tb="$ROOT/testbenches/${block}_tb.vhd"

    echo "${C_BOLD}==================================================================${C_RESET}"
    echo "${C_BOLD}  $block${C_RESET}"
    echo "${C_BOLD}==================================================================${C_RESET}"

    for f in "$gen" "$tb"; do
        if [ ! -f "$f" ]; then
            echo "  MISSING  $f"
            fail=$((fail+1)); continue 2
        fi
    done

    # ---- STEP 1: regenerate this block's test data --------------------------
    printf '  %-12s ' "generating"
    if ! python3 "$gen" "$VECTORS" >>"$LOG" 2>&1; then
        echo "FAILED (see .sim.log)"
        fail=$((fail+1)); continue
    fi
    echo "ok"

    # ---- STEP 2: compile components + RTL + testbench -----------------------
    rtl_paths=()
    for rel in ${RTL_SRCS[$block]}; do rtl_paths+=("$RTL_DIR/${rel#rtl/}"); done

    # xpm blocks need the library on the elaborate line, plus glbl as a second
    # top-level unit -- it has no ports and is instantiated by name inside the
    # RTL, so it cannot be reached through the testbench's hierarchy.
    xelab_extra=()
    if [ -n "${NEEDS_XPM[$block]:-}" ]; then
        xelab_extra+=(-L xpm -L unisims_ver)
    fi

    printf '  %-12s ' "analysing"
    if ! (cd "$VECTORS" && xvhdl --2008 --work work \
            "${VC_SRCS[@]}" "${rtl_paths[@]}" "$tb") >>"$LOG" 2>&1; then
        echo "FAILED"
        grep -iE "error" "$LOG" | tail -10 | sed 's/^/    /'
        fail=$((fail+1)); continue
    fi
    echo "ok"
    echo

    # ---- STEPS 3-5: elaborate, simulate, compare -- once per variant --------
    printf '  %-10s %-8s %5s  %s\n' "VARIANT" "RESULT" "PROTO" "DETAIL"
    printf '  %-10s %-8s %5s  %s\n' "-------" "------" "-----" "------"

    for variant in "${VARIANTS[@]}"; do
        [ -n "$WANT_VARIANT" ] && [ "$WANT_VARIANT" != "$variant" ] && continue

        # "gapless" has no suffix so it matches the testbench's default generic
        if [ "$variant" = "gapless" ]; then
            stim="stimulus_${block}_tb.txt"
        else
            stim="stimulus_${block}_tb_${variant}.txt"
        fi
        axis="axis_${block}_tb_${variant}.txt"
        side="sideband_${block}_tb_${variant}.txt"
        snap="snap_${block}_${variant}"

        # A block with no latched outputs has no sideband monitor and no
        # SIDEBAND_FILE generic; the tx blocks are all like that.
        gen_args=(-generic_top "STIMULUS_FILE=$stim" -generic_top "AXIS_FILE=$axis")
        # A block with two input ports takes a second stimulus file. Same
        # rule as the sideband generic: pass it only if it exists.
        if [ "$variant" = "gapless" ]; then
            stim_s1="stimulus_${block}_tb_s1.txt"
        else
            stim_s1="stimulus_${block}_tb_s1_${variant}.txt"
        fi
        if [ -f "$VECTORS/$stim_s1" ]; then
            gen_args+=(-generic_top "STIMULUS_S1=$stim_s1")
            two_stream=1
        else
            two_stream=0
        fi

        if [ -f "$VECTORS/expected_sideband_${block}_tb.txt" ]; then
            gen_args+=(-generic_top "SIDEBAND_FILE=$side")
            has_sideband=1
        else
            has_sideband=0
        fi
        # Any testbench that declares READY_PERCENT gets the variant's stall.
        if grep -q 'READY_PERCENT' "$tb"; then
            gen_args+=(-generic_top "READY_PERCENT=${STALL[$variant]}")
        fi
        if [ -n "${NEEDS_XPM[$block]:-}" ]; then
            tops=("work.${block}_tb" "work.glbl")
        else
            tops=("work.${block}_tb")
        fi

        if ! (cd "$VECTORS" && xelab --debug off -s "$snap" \
                "${xelab_extra[@]}" "${gen_args[@]}" \
                "${tops[@]}") >>"$LOG" 2>&1; then
            printf '  %-10s %s %s\n' "$variant" "$(result_field ERROR "$C_RED")" "elaboration failed (see .sim.log)"
            fail=$((fail+1)); continue
        fi

        # Per-variant log, because the protocol-violation count has to be read
        # back out of it and the shared log would mix the variants together.
        vlog="$VECTORS/.sim_${block}_${variant}.log"
        (cd "$VECTORS" && xsim "$snap" -runall) >"$vlog" 2>&1
        xsim_rc=$?
        cat "$vlog" >>"$LOG"

        # xsim returns 0 even when a VHDL "severity failure" assertion fires,
        # so its exit code cannot be trusted to report a failed test. The
        # testbench prints its own end-of-test line instead; a missing line
        # means the run did not get that far, which is itself a failure.
        report=$(grep -a 'protocol errors=' "$vlog" | tail -1)
        if [ "$xsim_rc" -ne 0 ]; then
            printf '  %-10s %s %5s  %s\n' "$variant" "$(result_field ERROR "$C_RED")" "-" \
                   "simulation failed (see .sim.log)"
            fail=$((fail+1)); continue
        fi
        if [ -z "$report" ]; then
            printf '  %-10s %s %5s  %s\n' "$variant" "$(result_field ERROR "$C_RED")" "-" \
                   "testbench never reached end of test (see .sim.log)"
            fail=$((fail+1)); continue
        fi
        proto="${report##*protocol errors=}"
        proto="${proto%%[!0-9]*}"

        if [ "$two_stream" -eq 1 ]; then
            # Two inputs on one output: nothing specifies how they interleave,
            # so split by the tag in payload byte 0 and compare each stream in
            # its own order. See reference_model/split_by_tag.py.
            out=$(cd "$VECTORS" && "$PYDIR/split_by_tag.py" "$axis" \
                      "split_${block}_${variant}" A0 B0 2>&1 | tr -d '\n' | sed 's/^ *//')
            cmp_rc=$?
            for tag in a0 b0; do
                port="s0"; [ "$tag" = "b0" ] && port="s1"
                o=$(cd "$VECTORS" && "$PYDIR/compare_beats.py" \
                        "expected_axis_${block}_tb_${port}.txt" \
                        "split_${block}_${variant}_${tag}.txt" 2>&1)
                [ $? -ne 0 ] && cmp_rc=1
                out="$out | $port: $(echo "$o" | tail -1)"
            done
        else
            cmp_args=("expected_axis_${block}_tb.txt" "$axis")
            if [ "$has_sideband" -eq 1 ]; then
                cmp_args+=("expected_sideband_${block}_tb.txt" "$side")
            fi
            out=$(cd "$VECTORS" && "$PYDIR/compare_beats.py" "${cmp_args[@]}" 2>&1)
            cmp_rc=$?
        fi

        if [ "$proto" -eq 0 ] && [ "$cmp_rc" -eq 0 ]; then
            printf '  %-10s %s %5s  %s\n' "$variant" "$(result_field PASS "$C_GREEN")" "$proto" \
                   "$(echo "$out" | tail -1)"
            pass=$((pass+1))
            continue
        fi

        # Something failed. Say which of the two judges objected -- a protocol
        # violation with matching data is the case only the checker can see.
        if [ "$proto" -gt 0 ] && [ "$cmp_rc" -ne 0 ]; then
            detail="AXIS protocol violations AND data mismatch"
        elif [ "$proto" -gt 0 ]; then
            detail="AXIS protocol violations (data itself matched)"
        else
            detail="$(echo "$out" | head -1)"
        fi
        printf '  %-10s %s %5s  %s\n' "$variant" "$(result_field FAIL "$C_RED")" "$proto" "$detail"

        # When the DETAIL column already holds the comparator's first line,
        # start the indented block at line 2 so it is not printed twice.
        from_line=1
        if [ "$proto" -gt 0 ]; then
            grep -a "^Error: " "$vlog" \
                | sed 's/^Error: //' | sort | uniq -c \
                | sed 's/^ */                             /' | head -6
        else
            from_line=2
        fi
        if [ "$cmp_rc" -ne 0 ]; then
            echo "$out" | sed -n "${from_line},$((from_line + 4))p" \
                | sed 's/^/                             /'
        fi
        fail=$((fail+1))
    done
    echo
done

# =============================================================================
echo "${C_BOLD}==================================================================${C_RESET}"
if [ "$fail" -eq 0 ]; then
    echo "${C_GREEN}$pass passed, $fail failed${C_RESET}"
else
    echo "${C_GREEN}$pass passed${C_RESET}, ${C_RED}$fail failed${C_RESET}"
fi
[ "$fail" -eq 0 ] || echo "full simulator output: $LOG"
exit $(( fail > 0 ? 1 : 0 ))
