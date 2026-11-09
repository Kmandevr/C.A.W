#!/usr/bin/env bash
# Packages the on-device compiler for the APK: libcaw_compiler.so (jniLibs) and the offline data
# bundle as one zip (assets), from an Android LLVM install made by build-llvm.sh.
# Usage: package-android.sh <llvm android-arm64 install> <android ndk dir> <repository root> <output dir>
set -euo pipefail
llvm="$1" ndk="$2" root="$3" out="$4"
work=$(mktemp -d)
cmake -S "$root/engine/compiler" -B "$work/compiler" -G Ninja -DCMAKE_BUILD_TYPE=MinSizeRel \
  -DCMAKE_PREFIX_PATH="$llvm" -DCMAKE_TOOLCHAIN_FILE="$ndk/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-26 -DANDROID_STL=c++_static \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH -DCMAKE_INSTALL_PREFIX="$work/compiler-install"
ninja -C "$work/compiler" install
cmake -S "$root/engine" -B "$work/sdk-build" -DCAW_AUDIO=OFF -DCAW_TOOLS=OFF -DCAW_INSTALL_SDK=ON \
  -DCMAKE_INSTALL_PREFIX="$work/sdk" > /dev/null
cmake --install "$work/sdk-build" > /dev/null
"$root/engine/compiler/bundle.sh" "$ndk" "$llvm" "$work/sdk" "$work/toolchain"
mkdir -p "$out/jniLibs/arm64-v8a" "$out/assets"
strip=$(echo "$ndk"/toolchains/llvm/prebuilt/*/bin/llvm-strip)
"$strip" --strip-unneeded -o "$out/jniLibs/arm64-v8a/libcaw_compiler.so" "$work/compiler-install/lib/libcaw_compiler.so"
version=$(ls "$llvm/lib/clang")
echo "{\"format\":\"caw.toolchain-data\",\"version\":1,\"llvm\":\"$version\",\"target\":\"aarch64-linux-android26\"}" \
  > "$work/toolchain/caw-toolchain.json"
rm -f "$out/assets/caw-toolchain.zip"
(cd "$work/toolchain" && zip -q -r -9 "$out/assets/caw-toolchain.zip" .)
ls -l "$out/jniLibs/arm64-v8a" "$out/assets"
rm -rf "$work"
