#!/bin/bash
# Builds OmniCore-SDR-SDRPlusPlus and its .deb on Debian / Ubuntu (tested on Ubuntu 24.04 x86-64).
# Build dependencies:
#   sudo apt install build-essential cmake pkg-config libfftw3-dev libglfw3-dev libvolk-dev libzstd-dev \
#        librtaudio-dev libusb-1.0-0-dev libairspy-dev libairspyhf-dev libhackrf-dev librtlsdr-dev \
#        libiio-dev libad9361-dev libcodec2-dev
# Usage: packaging/linux/build_deb.sh [output dir]
set -euo pipefail
SRC=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(realpath -m "${1:-$SRC/release}")
BUILD="$SRC/build/linux"
VERSION=$(sed -n 's/^#define VERSION_STR "\(.*\)"/\1/p' "$SRC/core/src/version.h")
ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-linux}")
NAME="OmniCore-SDR-SDRPlusPlus-$VERSION-ubuntu-$CODENAME-$ARCH"

if [ ! -f "$SRC/source_modules/omnicore_source/omnicore-host/include/omnicore/och.h" ]; then
    echo "OmniCore Host submodule missing: git submodule update --init" >&2
    exit 1
fi

cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
    -DOPT_BUILD_M17_DECODER=ON -DOPT_BUILD_DISCORD_PRESENCE=OFF
cmake --build "$BUILD" --parallel "$(nproc)"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
DESTDIR="$STAGE/pkg" cmake --install "$BUILD" >/dev/null
PKG="$STAGE/pkg"

# Runtime dependencies: the packages providing the shared libraries the installed binaries link directly (NEEDED)
elfs=$(find "$PKG" -type f -exec sh -c 'file -b "$1" | grep -q ELF && echo "$1"' _ {} \;)
needed=$(for f in $elfs; do objdump -p "$f" | awk '/NEEDED/ {print $2}'; done | sort -u)
deps=$(for n in $needed; do
        [ -n "$(find "$PKG" -name "$n" -print -quit)" ] && continue   # one of ours
        path=$(ldconfig -p | awk -v n="$n" '$1 == n && /x86-64|AArch64|64bit/ {print $NF; exit}')
        [ -z "$path" ] && path=$(ldconfig -p | awk -v n="$n" '$1 == n {print $NF; exit}')
        [ -z "$path" ] && { echo "unresolved: $n" >&2; continue; }
        dpkg -S "$(readlink -f "$path")" 2>/dev/null || dpkg -S "$path"
    done | cut -d: -f1 | sort -u | grep -v '^libc6$' | paste -sd, | sed 's/,/, /g')

mkdir -p "$PKG/DEBIAN"
cat > "$PKG/DEBIAN/control" <<EOF
Package: omnicore-sdr-sdrplusplus
Version: $VERSION
Architecture: $ARCH
Maintainer: Liren66 <https://github.com/Liren66>
Homepage: https://github.com/Liren66/OmniCore-SDR-SDRPlusPlus
Depends: libc6, $deps
Provides: sdrpp
Conflicts: sdrpp
Replaces: sdrpp
Section: hamradio
Priority: optional
Description: SDR++ with the OmniCore SDR source
 OmniCore-SDR-SDRPlusPlus is an independent fork of SDR++ (bloat-free SDR receiver)
 with a native OmniCore SDR (AD9361) source through OmniCore Host.
EOF
cat > "$PKG/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
ldconfig
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules || true
    udevadm trigger --subsystem-match=usb --attr-match=idVendor=1a86 || true
fi
EOF
cat > "$PKG/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
ldconfig
EOF
chmod 755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"

mkdir -p "$PKG/usr/share/doc/omnicore-sdr-sdrplusplus"
cp "$SRC/license" "$PKG/usr/share/doc/omnicore-sdr-sdrplusplus/copyright"
cp "$SRC/source_modules/omnicore_source/omnicore-host/LICENSE" "$PKG/usr/share/doc/omnicore-sdr-sdrplusplus/LICENSE-OmniCore-Host"

mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$PKG" "$OUT/$NAME.deb" >/dev/null
echo "$OUT/$NAME.deb"
dpkg-deb -I "$OUT/$NAME.deb" | sed -n 's/^ Depends:/Depends:/p'
