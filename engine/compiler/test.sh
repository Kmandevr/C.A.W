#!/usr/bin/env bash
# Builds the starter C++ component with the compiler library (through caw-compile) and checks the result.
# Usage: test.sh <caw-compile> <bundle dir> <android ndk dir> <repository root>
set -euo pipefail
cc="$1" tc="$2" ndk="$3" root="$4"
readelf=$(echo "$ndk"/toolchains/llvm/prebuilt/*/bin/llvm-readelf)
work=$(mktemp -d)
export TMPDIR="$work"
build() {  # build <output .so> <sources...>
  local out="$1"; shift
  "$cc" "$tc/bin/clang++" --target=aarch64-linux-android26 --sysroot="$tc/sysroot" \
    -resource-dir="$tc/lib/clang/$(ls "$tc/lib/clang")" -std=c++20 -O2 -fPIC -shared -static-libstdc++ \
    -ffp-contract=off -fno-fast-math -fvisibility=hidden -I"$tc/caw-sdk/include" "$@" -o "$out"
}
check() {  # check <.so>
  # Whole outputs first: grep -q stopping early would fail the pipe under pipefail.
  syms=$("$readelf" --dyn-syms --wide "$1")
  echo "$syms" | grep -q " caw_get_component_v3$" || { echo "FAIL: $1 does not export caw_get_component_v3"; exit 1; }
  needed=$("$readelf" --dynamic "$1" | grep NEEDED || true)
  echo "$needed"
  if echo "$needed" | grep -q "c++_shared"; then echo "FAIL: $1 needs libc++_shared.so"; exit 1; fi
  header=$("$readelf" --file-header "$1")
  echo "$header" | grep -q "AArch64" || { echo "FAIL: $1 is not AArch64"; exit 1; }
}

echo "== the minimal example"
build "$work/minimal.so" "$root/examples/cpp/minimal/src/minimal_component.cpp"
check "$work/minimal.so"

echo "== a component using the standard library (vector, exceptions caught at the boundary)"
cat > "$work/gain.cpp" <<'CPP'
#include <vector>
#include <caw/component.hpp>
namespace {
constexpr caw::PortDescriptor kPorts[] = {caw::stereoInput("in"), caw::stereoOutput("out")};
caw::ParameterDescriptor gain() { caw::ParameterDescriptor p; p.id = "gain"; p.defaultValue = 1; p.maximum = 2; return p; }
const caw::ParameterDescriptor kParams[] = {gain()};
const caw::ModuleDescriptor kDescriptor{"org.caw.tests.compiled-gain", 1, kPorts, 2, kParams, 1, nullptr, 0, {}};
class Gain final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double, uint32_t maxFrames) noexcept override { scratch_.assign(maxFrames, 0.0f); return true; }
    using caw::ModuleProcessor::process;
    bool process(const caw::AudioProcessBlock& b) noexcept override {
        const double g = b.parameterCount ? b.parameters[0].value : 1.0;
        for (uint32_t c = 0; c < 2; ++c)
            for (uint32_t i = 0; i < b.frames; ++i) b.output.channels[c][i] = static_cast<float>(b.input.channels[c][i] * g);
        return true;
    }
private:
    std::vector<float> scratch_;
};
}
CAW_EXPORT_COMPONENT(Gain, kDescriptor)
CPP
build "$work/gain.so" "$work/gain.cpp"
check "$work/gain.so"

echo "== a compile error comes back as a diagnostic with its line"
printf 'int main() { return undefined_name; }\n' > "$work/bad.cpp"
if out=$(build "$work/bad.so" "$work/bad.cpp" 2>&1); then echo "FAIL: a broken source built"; exit 1; fi
echo "$out" | grep -q "bad.cpp:1:21: error:" || { echo "FAIL: unexpected diagnostics: $out"; exit 1; }
echo "== code completion: results come back with the output (what cc1 prints to standard output)"
printf '#include <caw/component.hpp>\nvoid f() { caw::ParameterDescriptor p; p.\n' > "$work/complete.cpp"
col=$(( $(sed -n 2p "$work/complete.cpp" | wc -c) ))  # just after the dot (wc counts the newline too: 1-based)
out=$("$cc" "$tc/bin/clang++" --target=aarch64-linux-android26 --sysroot="$tc/sysroot" \
  -resource-dir="$tc/lib/clang/$(ls "$tc/lib/clang")" -std=c++20 -fsyntax-only -I"$tc/caw-sdk/include" \
  -Xclang "-code-completion-at=$work/complete.cpp:2:$col" "$work/complete.cpp" 2>&1 || true)
echo "$out" | grep -q "^COMPLETION: defaultValue" || { echo "FAIL: no completion of ParameterDescriptor::defaultValue: $out"; exit 1; }
echo "$out" | grep -q "^COMPLETION: minimum" || { echo "FAIL: no completion of ParameterDescriptor::minimum: $out"; exit 1; }
echo "PASS"
