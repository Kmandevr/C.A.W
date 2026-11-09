#!/usr/bin/env bash
# Assembles the data the on-device compiler reads: Clang's headers, the NDK sysroot for arm64 (API 26),
# the runtime libraries and the C.A.W SDK headers. No executables: the compiler is a library.
# Usage: bundle.sh <android ndk dir> <llvm install dir> <caw sdk install dir> <output dir>
set -euo pipefail
ndk="$1" llvm="$2" sdk="$3" out="$4"
api=26
prebuilt=$(echo "$ndk"/toolchains/llvm/prebuilt/*)
sysroot="$prebuilt/sysroot"
ver=$(ls "$llvm/lib/clang")
ndkver=$(ls "$prebuilt/lib/clang")
rm -rf "$out"
mkdir -p "$out/bin" "$out/lib/clang/$ver/lib/linux/aarch64" "$out/sysroot/usr/lib/aarch64-linux-android/$api" "$out/caw-sdk"

# Clang's own headers (stddef.h, arm_neon.h, ...), from the compiler that reads them.
cp -R "$llvm/lib/clang/$ver/include" "$out/lib/clang/$ver/"
# Runtime pieces from the NDK: compiler builtins and the unwinder for arm64 only.
cp "$prebuilt/lib/clang/$ndkver/lib/linux/libclang_rt.builtins-aarch64-android.a" "$out/lib/clang/$ver/lib/linux/"
cp "$prebuilt/lib/clang/$ndkver/lib/linux/aarch64/libunwind.a" "$out/lib/clang/$ver/lib/linux/aarch64/"

# Sysroot: headers (minus other architectures' asm headers), then arm64 libraries.
cp -R "$sysroot/usr/include" "$out/sysroot/usr/"
for arch in arm-linux-androideabi i686-linux-android x86_64-linux-android riscv64-linux-android; do
  rm -rf "$out/sysroot/usr/include/$arch"
done
lib="$sysroot/usr/lib/aarch64-linux-android"
cp "$lib"/libc++_static.a "$lib"/libc++abi.a "$out/sysroot/usr/lib/aarch64-linux-android/"
for f in crtbegin_so.o crtend_so.o libc.so libm.so libdl.so liblog.so; do
  cp "$lib/$api/$f" "$out/sysroot/usr/lib/aarch64-linux-android/$api/"
done

# The C.A.W SDK headers components include.
cp -R "$sdk/include" "$out/caw-sdk/"

mkdir -p "$out/licenses"
[ -f "$ndk/NOTICE" ] && cp "$ndk/NOTICE" "$out/licenses/NDK-NOTICE.txt"
du -sh "$out" "$out"/* "$out/sysroot/usr/include" | sort -k2
