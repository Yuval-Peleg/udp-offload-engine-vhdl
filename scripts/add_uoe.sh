#!/usr/bin/env bash
# Add the UOE and an XXV 10G MAC to a project's block design
# (runs scripts/add_uoe.tcl, which lists every option).
#
#   ./scripts/add_uoe.sh --project <x.xpr> --ip A.B.C.D \
#       --dclk <pin> --resetn <pin> [--sfp N] [other options]
#
# Every option of add_uoe.tcl works here with two dashes: --mac, --port, --bd,
# --refclk, --sfp, --gt_quad, --gt_lane, --tx_disable_b, --axi.
# The project should be closed in any open Vivado while this runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { sed -n '2,10s/^# \{0,1\}//p' "$0" >&2; exit 1; }

args=() project=""
while [ $# -gt 0 ]; do
    case "$1" in
        --project) project="${2:-}"; shift 2 ;;
        --?*)      [ $# -ge 2 ] || usage; args+=("-${1#--}" "$2"); shift 2 ;;
        *)         usage ;;
    esac
done
[ -n "$project" ] || usage

# shellcheck disable=SC1091
source "$ROOT/scripts/vivado_env.sh"
command -v vivado >/dev/null 2>&1 || { echo "Vivado not found. Set VIVADO_ROOT=<dir containing bin/vivado>." >&2; exit 1; }

exec vivado -mode batch -nojournal -nolog -source "$ROOT/scripts/add_uoe.tcl" \
    -tclargs -project "$(realpath "$project")" "${args[@]}"
