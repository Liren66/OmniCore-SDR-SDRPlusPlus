#!/bin/bash
# Windows x64 package of OmniCore-SDR-SDRPlusPlus from an MSYS2 UCRT64 build (see readme.md).
# Usage (UCRT64 shell): packaging/windows/package.sh <build dir> <output dir>
set -euo pipefail
BUILD=$(realpath "$1")
OUT=$(realpath -m "$2")
SRC=$(cd "$(dirname "$0")/../.." && pwd)
VERSION=$(sed -n 's/^#define VERSION_STR "\(.*\)"/\1/p' "$SRC/core/src/version.h")
NAME="OmniCore-SDR-SDRPlusPlus-$VERSION-windows-x64"
PKG="$OUT/$NAME"

rm -rf "$PKG" "$OUT/$NAME.zip"
mkdir -p "$PKG/modules"
cp -r "$SRC/root/res" "$PKG/"
cp "$BUILD/sdrpp.exe" "$BUILD/core/libsdrpp_core.dll" "$PKG/"
cp "$BUILD/omnicore.dll" "$PKG/"
if [ -f "$BUILD/libusbK.dll" ]; then cp "$BUILD/libusbK.dll" "$PKG/"; fi

# Every module the build made
find "$BUILD/source_modules" "$BUILD/sink_modules" "$BUILD/decoder_modules" "$BUILD/misc_modules" \
    -maxdepth 2 -name '*.dll' ! -name 'omnicore.dll' -exec cp {} "$PKG/modules/" \;

# MSYS2 runtime DLLs the program and its modules use
for f in "$PKG"/*.exe "$PKG"/*.dll "$PKG"/modules/*.dll; do
    ntldd -R "$f" 2>/dev/null | sed -n 's/.*=> \(.*\.dll\) .*/\1/p'
done | sed 's#[\\]#/#g' | grep -Fi "$(cygpath -am /ucrt64/bin)/" | sort -u | while read -r dll; do
    cp -n "$(cygpath -u "$dll")" "$PKG/"
done

# Check nothing is left unresolved
missing=0
for f in "$PKG"/*.exe "$PKG"/*.dll "$PKG"/modules/*.dll; do
    if (cd "$PKG" && PATH="$PKG:/c/Windows/System32" /ucrt64/bin/ntldd "$f" | grep -q "not found"); then
        echo "unresolved imports in $f:"; (cd "$PKG" && PATH="$PKG:/c/Windows/System32" /ucrt64/bin/ntldd "$f" | grep "not found"); missing=1
    fi
done
[ $missing -eq 0 ]

strip -s "$PKG"/sdrpp.exe "$PKG"/libsdrpp_core.dll "$PKG"/omnicore.dll "$PKG"/modules/*.dll 2>/dev/null || true
cp "$SRC/license" "$PKG/LICENSE.txt"
cp "$SRC/readme.md" "$PKG/README.md"
cp "$SRC/source_modules/omnicore_source/omnicore-host/LICENSE" "$PKG/LICENSE-OmniCore-Host.txt"
cat > "$PKG/NOTICE.txt" <<NOTE
OmniCore-SDR-SDRPlusPlus $VERSION - an independent fork of SDR++ (https://github.com/AlexandreRouma/SDRPlusPlus)
with the OmniCore SDR source. Source: https://github.com/Liren66/OmniCore-SDR-SDRPlusPlus (see the release tag for this build).
SDR++ is GPL-3.0 (LICENSE.txt). OmniCore Host (omnicore.dll) is GPL-3.0-or-later (LICENSE-OmniCore-Host.txt),
source https://github.com/Liren66/OmniCore-SDR-Host. libusbK.dll is from https://github.com/mcuee/libusbk (V3.1.0.0).
Runtime DLLs are from MSYS2 UCRT64 packages (FFTW, VOLK, GLFW, zstd, RtAudio, librtlsdr, libhackrf, libusb, GCC runtime);
their sources are available from https://packages.msys2.org.
NOTE
(cd "$OUT" && zip -qr9 "$NAME.zip" "$NAME")
echo "$OUT/$NAME.zip"
