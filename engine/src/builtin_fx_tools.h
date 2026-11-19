// 1.1.0's tool devices: Meters (org.caw.meters: Analyzer, Tuner, Loudness), Lo-fi (org.caw.lofi) and Phase align (org.caw.phasealign).
#pragma once

#include <span>
#include <string_view>
#include <vector>

#include "fx_merged.h"
#include "module_registry.h"

namespace caw {
struct BuiltinPreset;  // presets.h
namespace fx {

// Meters is a merged device (fx_merged.h): one variant per mode, so only the chosen one runs.
std::span<const MergedDevice> mergedMeterDevices();  // builtin_fx_meters.cpp
// Registers org.caw.lofi and org.caw.phasealign (registerBuiltinEffects calls it, before the merged devices).
void registerTools(ModuleRegistry& registry);
// Their presets (each Meters preset names its `variant`); null for another id.
const std::vector<BuiltinPreset>* toolsPresets(std::string_view id);
const std::vector<BuiltinPreset>& meterPresets();     // builtin_fx_meters.cpp
const std::vector<BuiltinPreset>& lofiPresets();      // builtin_fx_lofi.cpp
const std::vector<BuiltinPreset>& phaseAlignPresets();  // builtin_fx_phasealign.cpp
void registerLofi(ModuleRegistry& registry);
void registerPhaseAlign(ModuleRegistry& registry);

}  // namespace fx
}  // namespace caw
