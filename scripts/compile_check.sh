#!/usr/bin/env bash
# Analyse every file in rtl/ with Vivado's VHDL analyser. No testbench, no
# elaboration -- this only answers "does the RTL compile".
#
# Run from anywhere:
#   ./scripts/compile_check.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/rtl"
WORKDIR="${TMPDIR:-/tmp}/uoe_compile_check"

# shellcheck disable=SC1091
source "$ROOT/scripts/vivado_env.sh"
if ! command -v xvhdl >/dev/null 2>&1; then
    echo "Vivado not found. Set VIVADO_ROOT=<dir containing bin/xvhdl>," >&2
    echo "and run ./scripts/setup_vivado_libs.sh if you have not already." >&2
    exit 1
fi

rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"; cd "$WORKDIR" || exit 1

# Leaf blocks first: direct entity instantiation needs the entity analysed
# before the file that instantiates it.
ORDER=(
    endianness_converter
    circular_buffer_filter
    axis_priority_handler
    arp_handler
    rx_eth
    rx_ipv4
    rx_udp
    tx_eth
    tx_ipv4
    tx_udp
    uoe
)

fail=0
for name in "${ORDER[@]}"; do
    f="$SRC/$name.vhd"
    [ -f "$f" ] || { printf '%-26s SKIP (not found)\n' "$name"; continue; }

    printf '%-26s ' "$name"
    if out=$(xvhdl --2008 --work work "$f" 2>&1); then
        printf 'OK\n'
    else
        printf 'FAIL\n'
        echo "$out" | grep -E "ERROR|error" | head -4 | sed 's/^/    /'
        fail=1
    fi
done

echo
if [ "$fail" -eq 0 ]; then
    echo "All sources analysed cleanly."
else
    echo "Analysis failed -- see errors above."
fi
exit "$fail"
