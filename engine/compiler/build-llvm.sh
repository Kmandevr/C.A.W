#!/usr/bin/env bash
# Builds and installs the LLVM, Clang and LLD libraries the C.A.W compiler links (AArch64 code only).
# Usage: build-llvm.sh <host|android-arm64> <llvm-project source dir> <install dir> [android ndk dir]
set -euo pipefail
target="$1" src="$2" out="$3" ndk="${4:-}"
work="$(dirname "$out")/llvm-build-$target"
common=(
  -G Ninja -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_INSTALL_PREFIX="$out"
  -DLLVM_ENABLE_PROJECTS="clang;lld" -DLLVM_TARGETS_TO_BUILD=AArch64
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF
  -DLLVM_BUILD_TOOLS=OFF -DCLANG_BUILD_TOOLS=OFF -DLLD_BUILD_TOOLS=OFF -DLLVM_INCLUDE_UTILS=OFF
  -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_ENABLE_TERMINFO=OFF -DCLANG_ENABLE_ARCMT=OFF -DCLANG_ENABLE_STATIC_ANALYZER=OFF
  -DCLANG_PLUGIN_SUPPORT=OFF -DLLVM_ENABLE_BINDINGS=OFF -DLLVM_PARALLEL_LINK_JOBS=2
)
case "$target" in
  host)
    cmake -S "$src/llvm" -B "$work" "${common[@]}"
    ;;
  android-arm64)
    [ -n "$ndk" ] || { echo "android-arm64 needs the NDK directory" >&2; exit 2; }
    # Native table generators first: the cross build runs them on the build machine.
    cmake -S "$src/llvm" -B "$work-tblgen" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_ENABLE_PROJECTS=clang -DLLVM_TARGETS_TO_BUILD=AArch64 -DLLVM_INCLUDE_TESTS=OFF \
      -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF
    ninja -C "$work-tblgen" llvm-tblgen llvm-min-tblgen clang-tblgen
    cmake -S "$src/llvm" -B "$work" "${common[@]}" \
      -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
      -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_static \
      -DLLVM_HOST_TRIPLE=aarch64-linux-android26 -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-linux-android26 \
      -DLLVM_NATIVE_TOOL_DIR="$work-tblgen/bin" -DLLVM_ENABLE_PIC=ON
    ;;
  *) echo "unknown target $target" >&2; exit 2 ;;
esac
ninja -C "$work"
ninja -C "$work" clang-resource-headers
ninja -C "$work" install
rm -rf "$work" "$work-tblgen"
