#!/usr/bin/env bash
# Full-chip uoe regression: the whole design, driven the way the board will.
#
#   ./scripts/run_uoe_test.sh            all three backpressure variants + reset
#   ./scripts/run_uoe_test.sh -t ipg     one variant (skips the reset test)
#   ./scripts/run_uoe_test.sh -l         list variants
#   RTL_DIR=<dir> ./scripts/run_uoe_test.sh   run against another copy of rtl/,
#                                             e.g. a mutant, to prove the test fails
#
# Separate from run_tests.sh on purpose. That script is built around one
# stimulus file and one expected file per block; this test has two independent
# input streams (mac_rx and udp_tx) and two outputs, one of which carries two
# classes of packet that have to be split before they can be compared. Bending
# run_tests.sh into that shape would complicate the common case to serve one
# special one.
#
# Variants stall the MAC's tready, not the input timing: the RX side has no
# backpressure by design, so the only elasticity to test is on the way out.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VECTORS="$ROOT/reference_model/test_vectors"
PYDIR="$ROOT/reference_model"
RTL_DIR="${RTL_DIR:-$ROOT/rtl}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; DIM=''; BOLD=''; RESET=''
fi

# shellcheck disable=SC1091
source "$ROOT/scripts/vivado_env.sh"
command -v xelab >/dev/null 2>&1 || {
    echo "Vivado not found. Run ./scripts/setup_vivado_libs.sh first." >&2; exit 1; }

# shellcheck disable=SC1091
source "$ROOT/scripts/test_tables.sh"
VARIANTS=(gapless ipg random)
RUN_RESET=1

while getopts ":t:lh" opt; do
    case "$opt" in
        t) VARIANTS=("$OPTARG"); RUN_RESET=0 ;;
        l) echo "variants: ${VARIANTS[*]} (plus the reset test)"; exit 0 ;;
        h) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "usage: $0 [-t gapless|ipg|random]" >&2; exit 2 ;;
    esac
done

mkdir -p "$VECTORS"
LOG="$VECTORS/.uoe.log"
: > "$LOG"

echo
echo "=================================================================="
echo "  ${BOLD}uoe -- full chip${RESET}"
echo "=================================================================="

printf '  %-12s ' "generating"
if (cd "$PYDIR" && python3 gen_uoe.py "$VECTORS") >>"$LOG" 2>&1; then
    echo "${GREEN}ok${RESET}"
else
    echo "${RED}FAILED${RESET} (see $LOG)"; exit 1
fi

printf '  %-12s ' "analysing"
# rtl/*.vhd globs alphabetically, which puts uoe.vhd, the top level, after
# every block it instantiates. Rename with care.
if (cd "$VECTORS" && xvhdl --2008 --work work "${VC_SRCS[@]}" \
        "$RTL_DIR"/*.vhd "$ROOT/testbenches/uoe_tb_full.vhd" \
        "$ROOT/testbenches/uoe_reset_tb.vhd") >>"$LOG" 2>&1; then
    echo "${GREEN}ok${RESET}"
else
    echo "${RED}FAILED${RESET}"; grep -iE "^ERROR" "$LOG" | head -10; exit 1
fi

# XPM primitives need the simulation libraries and glbl as a second top level.
GLBL_V="$(dirname "$(dirname "$(command -v xvhdl)")")/data/verilog/src/glbl.v"
[ -f "$GLBL_V" ] && (cd "$VECTORS" && xvlog "$GLBL_V") >>"$LOG" 2>&1

echo
printf '  %-10s %-8s %-6s %s\n' "VARIANT" "RESULT" "PROTO" "DETAIL"
printf '  %-10s %-8s %-6s %s\n' "-------" "------" "-----" "------"

fails=0
passes=0

for variant in "${VARIANTS[@]}"; do
    pct="${STALL[$variant]:-}"
    if [ -z "$pct" ]; then
        echo "  unknown variant '$variant'" >&2; exit 1
    fi

    snap="snap_uoe_$variant"
    rxf="axis_uoe_${variant}_udp_rx.txt"
    txf="axis_uoe_${variant}_mac_tx.txt"
    sbf="sideband_uoe_${variant}.txt"
    vlog="$VECTORS/.uoe_$variant.sim.log"

    if ! (cd "$VECTORS" && xelab --debug off -s "$snap" -L xpm -L unisims_ver \
            -generic_top "READY_PERCENT=$pct" \
            -generic_top "AXIS_FILE=$rxf" \
            -generic_top "AXIS_TX_FILE=$txf" \
            -generic_top "SIDEBAND_FILE=$sbf" \
            work.uoe_tb_full work.glbl) >>"$LOG" 2>&1; then
        printf '  %-10s %s%-8s%s %-6s %s\n' "$variant" "$RED" "ERROR" "$RESET" "-" \
               "elaboration failed (see $LOG)"
        fails=$((fails+1)); continue
    fi

    # xsim exits 0 even when a severity-failure assertion fires; the printed
    # "protocol errors=N" line is the only trustworthy signal.
    (cd "$VECTORS" && xsim "$snap" -runall) > "$vlog" 2>&1
    summary="$(grep -m1 "protocol errors=" "$vlog" || true)"

    if [ -z "$summary" ]; then
        printf '  %-10s %s%-8s%s %-6s %s\n' "$variant" "$RED" "ERROR" "$RESET" "-" \
               "testbench never reached end of test (see $vlog)"
        fails=$((fails+1)); continue
    fi

    proto="$(sed -n 's/.*protocol errors=\([0-9]*\).*/\1/p' <<<"$summary")"
    problems=()

    split_out="$(cd "$VECTORS" && python3 "$PYDIR/split_mac_tx.py" "$txf" "split_uoe_$variant" 2>&1)"
    [ $? -ne 0 ] && problems+=("$(sed 's/^ *//' <<<"$split_out")")

    for cmp in \
        "expected_axis_uoe_tb_udp_rx.txt|$rxf|expected_sideband_uoe_tb.txt|$sbf|udp_rx" \
        "expected_axis_uoe_tb_mac_tx_ipv4.txt|split_uoe_${variant}_ipv4.txt|||mac_tx IPv4" \
        "expected_axis_uoe_tb_mac_tx_arp.txt|split_uoe_${variant}_arp.txt|||mac_tx ARP"
    do
        IFS='|' read -r exp act esb asb label <<<"$cmp"
        args=("$exp" "$act")
        [ -n "$esb" ] && args+=("$esb" "$asb")
        out="$(cd "$VECTORS" && python3 "$PYDIR/compare_beats.py" "${args[@]}" 2>&1)"
        if [ $? -ne 0 ]; then
            problems+=("$label: $(grep -vE '^\s*$' <<<"$out" | tail -4)")
        fi
    done

    if [ "$proto" -eq 0 ] && [ ${#problems[@]} -eq 0 ]; then
        printf '  %-10s %s%-8s%s %-6s %s\n' "$variant" "$GREEN" "PASS" "$RESET" "$proto" \
               "$(sed 's/^Note: //' <<<"$summary")"
        passes=$((passes+1))
    else
        printf '  %-10s %s%-8s%s %-6s %s\n' "$variant" "$RED" "FAIL" "$RESET" "$proto" \
               "$(sed 's/^Note: //' <<<"$summary")"
        for p in "${problems[@]}"; do
            while IFS= read -r line; do
                printf '  %-10s %-8s %-6s %s%s%s\n' "" "" "" "$DIM" "$line" "$RESET"
            done <<<"$p"
        done
        fails=$((fails+1))
    fi
done

# The reset stretcher in uoe.vhd: a 1-clock glitch, a 5-clock pulse and a
# normal reset must each hold the internal reset low for at least 64 clocks.
# It moves no data, so it is one row with no variant.
if [ "$RUN_RESET" -eq 1 ]; then
    vlog="$VECTORS/.uoe_reset.sim.log"
    if (cd "$VECTORS" && xelab --debug off -s snap_uoe_rst -L xpm -L unisims_ver \
            work.uoe_reset_tb work.glbl) >>"$LOG" 2>&1; then
        (cd "$VECTORS" && xsim snap_uoe_rst -runall) > "$vlog" 2>&1
        summary="$(grep -m1 "protocol errors=" "$vlog" || true)"
        proto="$(sed -n 's/.*protocol errors=\([0-9]*\).*/\1/p' <<<"$summary")"
    else
        proto=""
    fi
    if [ "$proto" = "0" ]; then
        printf '  %-10s %s%-8s%s %-6s %s\n' "reset" "$GREEN" "PASS" "$RESET" "0" \
               "every reset held >= 64 clocks"
        passes=$((passes+1))
    else
        printf '  %-10s %s%-8s%s %-6s %s\n' "reset" "$RED" "FAIL" "$RESET" "${proto:--}" \
               "see $vlog"
        grep -a "stretcher gave\|NEVER released" "$vlog" 2>/dev/null | sed 's/^/             /'
        fails=$((fails+1))
    fi
fi

echo
echo "=================================================================="
if [ "$fails" -eq 0 ]; then
    echo "  ${GREEN}$passes passed, 0 failed${RESET}"
else
    echo "  ${RED}$passes passed, $fails failed${RESET}"
fi
echo "  full simulator output: $VECTORS/.uoe_<variant>.sim.log"
exit $(( fails > 0 ))
