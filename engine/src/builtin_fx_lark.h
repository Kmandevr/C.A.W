// Lark (1.1.0): live pitch correction (org.caw.pitchfix, builtin_fx_lark.cpp) and the clip editor's engine (lark_editor.h): registration, presets, sizes.
#pragma once

#include <cstddef>
#include <string_view>
#include <vector>

#include "module_registry.h"

namespace caw {
struct BuiltinPreset;  // presets.h
namespace fx {

// Registers org.caw.pitchfix and builds Lark's shared window table (registerBuiltinEffects calls it).
void registerLark(ModuleRegistry& registry);
// Lark's presets; null for another id.
const std::vector<BuiltinPreset>* larkPresets(std::string_view id);
// Bytes per instance at `sampleRate` (the class plus what it allocates), for caw_bench.
size_t larkBytes(double sampleRate) noexcept;

}  // namespace fx
}  // namespace caw
