#!/usr/bin/env bash
# Package the UOE as a Vivado IP (runs scripts/package_uoe.tcl).
#
#   ./scripts/package_uoe.sh --part <part> [--out <ip folder>]
#
#   --part  the FPGA part of the project it is for, e.g. xczu9eg-ffvb1156-2-e
#   --out   where to write it (default ip/ next to rtl/); the IP lands in
#           <ip folder>/uoe
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { sed -n '2,9s/^# \{0,1\}//p' "$0" >&2; exit 1; }

part="" out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --part) part="${2:-}"; shift 2 ;;
        --out)  out="${2:-}";  shift 2 ;;
        *)      usage ;;
    esac
done
[ -n "$part" ] || usage

# shellcheck disable=SC1091
source "$ROOT/scripts/vivado_env.sh"
command -v vivado >/dev/null 2>&1 || { echo "Vivado not found. Set VIVADO_ROOT=<dir containing bin/vivado>." >&2; exit 1; }

args=("$part"); [ -z "$out" ] || args+=("$(realpath -m "$out")")
exec vivado -mode batch -nojournal -nolog -source "$ROOT/scripts/package_uoe.tcl" -tclargs "${args[@]}"
