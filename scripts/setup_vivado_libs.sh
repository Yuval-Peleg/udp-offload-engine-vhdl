#!/usr/bin/env bash
# Make Vivado 2022.2 runnable on a host that no longer ships libtinfo5.
#
# Vivado 2022.2 links libtinfo.so.5. Ubuntu 24.04+ no longer packages it, so
# "apt install libtinfo5" cannot work. But it is only a
# missing *file*, not a missing privilege: the library can live in your home
# directory and be picked up through LD_LIBRARY_PATH. No root needed.
#
# Everything else Vivado needs is either already present (glibc is backward
# compatible) or ships inside the Vivado install and is resolved by its own
# bin/ wrapper scripts.
#
#   ./scripts/setup_vivado_libs.sh
#
# Installs into ~/vivado-compat/lib. Override with VIVADO_COMPAT_LIB=<dir>.
# Idempotent -- safe to re-run.
set -uo pipefail

COMPAT="${VIVADO_COMPAT_LIB:-$HOME/vivado-compat}"
LIBDIR="$COMPAT/lib"

# Ubuntu focal's libtinfo5. Any distro's build of the same soname works; focal
# is what Vivado 2022.2 was validated against.
DEB_URL="https://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.2-0ubuntu2.1_amd64.deb"
DEB_SHA256="d0f055e72d86aab0696cc993af790a78506419c18dc284cf04e7a7e96e0a7d7a"

if [ -f "$LIBDIR/libtinfo.so.5" ]; then
    echo "already set up: $LIBDIR/libtinfo.so.5"
else
    mkdir -p "$COMPAT/debs" "$LIBDIR" || exit 1

    deb="$COMPAT/debs/$(basename "$DEB_URL")"
    if [ -f "$deb" ]; then
        echo "using $deb"
    else
        echo "fetching $(basename "$DEB_URL")"
        if ! curl -fsSL --max-time 60 -o "$deb" "$DEB_URL"; then
            rm -f "$deb"
            echo "Could not download $DEB_URL" >&2
            echo "Download it by hand to $deb and re-run this script." >&2
            exit 1
        fi
    fi
    if ! echo "$DEB_SHA256  $deb" | sha256sum -c --quiet; then
        echo "Checksum mismatch on $deb -- not using it." >&2
        rm -f "$deb"
        exit 1
    fi

    dpkg-deb -x "$deb" "$COMPAT/extracted" || exit 1
    find "$COMPAT/extracted" -name 'libtinfo.so.5*' -exec cp -v {} "$LIBDIR/" \; || exit 1
fi

echo
echo "checking the toolchain:"
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vivado_env.sh"

fail=0
for b in xvhdl xelab xsim xvlog; do
    printf '  %-8s ' "$b"
    if command -v "$b" >/dev/null 2>&1 && v=$("$b" --version 2>&1 | head -1); then
        echo "$v"
    else
        echo "FAILED"; fail=1
    fi
done

echo
if [ "$fail" -eq 0 ]; then
    echo "Simulation works natively. ./scripts/run_tests.sh picks $LIBDIR up"
    echo "automatically."
else
    echo "Something is still missing. Run:"
    echo "  ldd \$(command -v xvhdl 2>/dev/null || echo xvhdl) | grep 'not found'"
    echo "and fetch those the same way."
fi
exit "$fail"
