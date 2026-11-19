// 1.1.0's voice and harmonics devices: Glint (org.caw.exciter: Exciter, Bass), Soar's Harmonizer and Octaver (org.caw.shift) and Mimic (org.caw.vocoder).
#pragma once

#include <span>
#include <string_view>
#include <vector>

#include "fx_merged.h"
#include "module_registry.h"

namespace caw {
struct BuiltinPreset;  // presets.h
namespace fx {

// Glint is a merged device (fx_merged.h): Exciter (0) and Bass (1), each its own class (builtin_fx_exciter.cpp).
std::span<const MergedDevice> mergedVoiceDevices();
// Registers Mimic, org.caw.vocoder (builtin_fx_vocoder.cpp; registerBuiltinEffects calls it, before the merged devices).
void registerVoice(ModuleRegistry& registry);
// Glint's and Mimic's presets (each Glint preset names its `variant`); null for another id.
const std::vector<BuiltinPreset>* voicePresets(std::string_view id);
const std::vector<BuiltinPreset>& exciterPresets();  // builtin_fx_exciter.cpp
const std::vector<BuiltinPreset>& vocoderPresets();  // builtin_fx_vocoder.cpp
// The presets of Pitch/Shift's 1.1.0 variants (Harmonizer, Octaver; builtin_fx_shift_voices.cpp), appended after
// its old effects' by fx::mergedPresets; each names its `variant`. Empty for another id.
std::span<const BuiltinPreset> newVoiceVariantPresets(std::string_view id);

// Pitch/Shift's appended variants (builtin_fx_shift_voices.cpp): their own tables, `variant` appended.
const ModuleDescriptor& harmonizerDescriptor(std::span<const std::string_view> labels, uint32_t index);
const ModuleDescriptor& octaverDescriptor(std::span<const std::string_view> labels, uint32_t index);
ModuleProcessor* makeHarmonizerAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeOctaverAs(const ModuleDescriptor& variant) noexcept;
void warmShiftVoices() noexcept;  // builds the Harmonizer's shared window table (registerVoice calls it)

// Bytes per instance (the classes' sizes plus what they allocate at 48 kHz), for caw_bench.
size_t exciterBytes() noexcept;
size_t harmonizerBytes(double sampleRate) noexcept;
size_t octaverBytes(double sampleRate) noexcept;
size_t vocoderBytes() noexcept;

}  // namespace fx
}  // namespace caw
