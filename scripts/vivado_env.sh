# Sourced by the other scripts -- not executed directly.
#
# Puts xvhdl/xelab/xsim on PATH, working around the two things that stop
# Vivado 2022.2 from running on a modern Ubuntu host:
#
#   1. It links libtinfo.so.5, which Ubuntu 24.04+ no longer packages.
#      scripts/setup_vivado_libs.sh drops a copy in ~/vivado-compat/lib.
#
#   2. settings64.sh is unusable if the install tree has moved. The installer
#      bakes the original install path into it *and* into the inner
#      .settings64-Vivado.sh, so a moved install sources files that do not
#      exist and silently leaves PATH untouched. Locating bin/ directly is
#      simpler and correct either way.
#
# Overrides: VIVADO_ROOT=<dir containing bin/xvhdl>, VIVADO_COMPAT_LIB=<dir>.

_compat="${VIVADO_COMPAT_LIB:-$HOME/vivado-compat}/lib"
if [ -d "$_compat" ]; then
    export LD_LIBRARY_PATH="$_compat:${LD_LIBRARY_PATH:-}"
fi
unset _compat

if ! command -v xvhdl >/dev/null 2>&1; then
    for _c in "${VIVADO_ROOT:-}" \
              "${XILINX_VIVADO:-}" \
              /opt/Xilinx/Vivado/* \
              "$HOME"/Xilinx/Vivado/* \
              /tools/Xilinx/Vivado/*; do
        if [ -n "$_c" ] && [ -x "$_c/bin/xvhdl" ]; then
            XILINX_VIVADO="$(cd "$_c" && pwd)"
            export XILINX_VIVADO
            export PATH="$XILINX_VIVADO/bin:$PATH"
            break
        fi
    done
    unset _c
fi
