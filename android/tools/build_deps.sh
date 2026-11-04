#!/bin/bash
# Builds the native dependencies of the Android app (zstd, FFTW3 float, VOLK, libusb) for arm64-v8a with the NDK
# into $SDR_KIT_ROOT/arm64-v8a/{include,lib}, the layout CMake expects (-DSDR_KIT_ROOT=...).
#
# Usage: android/tools/build_deps.sh <source archives dir> <kit root>
#   archives: zstd-1.5.6.tar.gz, fftw-3.3.10.tar.gz, volk-3.1.2.tar.gz (release tarball with cpu_features),
#             libusb-1.0.27.tar.bz2 or a libusb source tree in LIBUSB_SRC
# Needs patchelf. Environment: ANDROID_NDK (27.2.12479018), CMAKE (the SDK's cmake 3.31.5), python3 with mako (for VOLK)
set -euo pipefail
ARCHIVES=$(realpath "$1")
KIT=$(realpath -m "$2")
ABI=arm64-v8a
API=28
JOBS=${JOBS:-$(nproc)}
: "${ANDROID_NDK:?set ANDROID_NDK}"
CMAKE=${CMAKE:-cmake}
PREFIX="$KIT/$ABI"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$PREFIX/lib" "$PREFIX/include"

TOOLCHAIN=(-DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake" -DANDROID_ABI=$ABI
           -DANDROID_PLATFORM=android-$API -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX"
           -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384)

# zstd
tar -xzf "$ARCHIVES/zstd-1.5.6.tar.gz" -C "$WORK"
"$CMAKE" -S "$WORK/zstd-1.5.6/build/cmake" -B "$WORK/zstd-build" "${TOOLCHAIN[@]}" \
    -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_STATIC=OFF -DZSTD_BUILD_SHARED=ON
"$CMAKE" --build "$WORK/zstd-build" --parallel "$JOBS" --target install

# FFTW3 (single precision, NEON)
tar -xzf "$ARCHIVES/fftw-3.3.10.tar.gz" -C "$WORK"
"$CMAKE" -S "$WORK/fftw-3.3.10" -B "$WORK/fftw-build" "${TOOLCHAIN[@]}" \
    -DENABLE_FLOAT=ON -DENABLE_THREADS=OFF -DBUILD_TESTS=OFF -DBUILD_SHARED_LIBS=ON -DENABLE_NEON=ON
"$CMAKE" --build "$WORK/fftw-build" --parallel "$JOBS" --target install

# VOLK
tar -xzf "$ARCHIVES/volk-3.1.2.tar.gz" -C "$WORK"
"$CMAKE" -S "$WORK/volk-3.1.2" -B "$WORK/volk-build" "${TOOLCHAIN[@]}" \
    -DENABLE_TESTING=OFF -DENABLE_MODTOOL=OFF -DENABLE_ORC=OFF -DENABLE_PROFILING=OFF -DENABLE_STATIC_LIBS=OFF \
    -DPYTHON_EXECUTABLE="$(command -v python3)" -DCMAKE_POLICY_VERSION_MINIMUM=3.5
"$CMAKE" --build "$WORK/volk-build" --parallel "$JOBS" --target install

# libusb (Android build list of libusb's android/jni/libusb.mk), as libusb1.0.so like the upstream SDR++ kit
if [ -z "${LIBUSB_SRC:-}" ]; then
    tar -xjf "$ARCHIVES/libusb-1.0.27.tar.bz2" -C "$WORK"
    LIBUSB_SRC="$WORK/libusb-1.0.27"
fi
L="$LIBUSB_SRC/libusb"
CC="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android$API-clang"
"$CC" -shared -fPIC -O2 -fvisibility=default -I"$LIBUSB_SRC/android" -I"$L" -I"$L/os" \
    "$L/core.c" "$L/descriptor.c" "$L/hotplug.c" "$L/io.c" "$L/sync.c" "$L/strerror.c" \
    "$L/os/linux_usbfs.c" "$L/os/events_posix.c" "$L/os/threads_posix.c" "$L/os/linux_netlink.c" \
    -llog -Wl,-soname,libusb1.0.so -Wl,-z,max-page-size=16384 -o "$PREFIX/lib/libusb1.0.so"
cp "$L/libusb.h" "$PREFIX/include/"

# Android packs and loads libraries by plain file name: give each an unversioned file and SONAME
for lib in libzstd libfftw3f libvolk; do
    cp -L "$PREFIX/lib/$lib.so" "$WORK/$lib.so"
    rm -f "$PREFIX/lib/$lib.so"
    mv "$WORK/$lib.so" "$PREFIX/lib/$lib.so"
    patchelf --set-soname "$lib.so" "$PREFIX/lib/$lib.so"
done
find "$PREFIX/lib" -name '*.so.*' -delete
"$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" --strip-unneeded "$PREFIX"/lib/*.so
for lib in "$PREFIX"/lib/*.so; do
    echo "$(basename "$lib"): $("$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf" -d "$lib" | grep -E 'SONAME|NEEDED' | tr -s ' ' | cut -d' ' -f3- | paste -sd' ')"
done
# Copy for the APK (Gradle jniLibs layout: <kit>/jniLibs/<abi>/*.so)
mkdir -p "$KIT/jniLibs/$ABI"
cp "$PREFIX"/lib/*.so "$KIT/jniLibs/$ABI/"
ls -la "$KIT/jniLibs/$ABI"
