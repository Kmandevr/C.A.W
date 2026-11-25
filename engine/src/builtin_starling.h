// Starling (org.caw.starling, 1.1.3): the struck and plucked strings instrument (the piano first), its registration, presets and sizes.
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>
#include <vector>

#include "fx_merged.h"
#include "module_registry.h"

namespace caw {
struct BuiltinPreset;  // presets.h
namespace starling {

inline constexpr std::string_view kStarlingId = "org.caw.starling";

// Starling is a merged device (fx_merged.h) whose `variant` ("Model") picks the instrument: Piano for now.
std::span<const fx::MergedDevice> mergedStarlingDevices();
void registerStarling(ModuleRegistry& registry);
// Starling's presets (each names its `variant`); null for another id.
const std::vector<BuiltinPreset>* starlingPresets(std::string_view id);
// Bytes per instance of model `variant` at `sampleRate` (the shared recordings not counted).
size_t starlingBytes(uint32_t variant, double sampleRate) noexcept;

}  // namespace starling
}  // namespace caw
