// Starling (org.caw.starling, 1.1.3): the struck and plucked strings instrument (piano, classical guitar, concert harp), its registration, presets and sizes.
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

struct Strings;  // starling_strings.h

inline constexpr std::string_view kStarlingId = "org.caw.starling";

// Starling is a merged device (fx_merged.h) whose `variant` ("Model") picks the instrument: 0 Piano, 1 Classical
// guitar, 2 Harp (the piano's index and sound unchanged since 1.1.3-alpha.1).
inline constexpr uint32_t kPiano = 0, kClassicalGuitar = 1, kHarpVariant = 2;
std::span<const fx::MergedDevice> mergedStarlingDevices();
void registerStarling(ModuleRegistry& registry);
// Starling's presets (each names its `variant`); null for another id.
const std::vector<BuiltinPreset>* starlingPresets(std::string_view id);
// Bytes per instance of model `variant` at `sampleRate` (the shared recordings not counted).
size_t starlingBytes(uint32_t variant, double sampleRate) noexcept;
// The plucked strings' model inside an instance of `variant` (the tests' access; null for the piano or another class).
Strings* starlingStringsModel(ModuleProcessor& p, uint32_t variant) noexcept;

// starling_strings.cpp (strict floating point): the guitar's (which 0) and the harp's (1) descriptor, class and size.
const ModuleDescriptor& stringsDescriptor(int which, std::span<const std::string_view> models, uint32_t index);
ModuleProcessor* makeStrings(int which, const ModuleDescriptor& d, int index) noexcept;
Strings* stringsModel(ModuleProcessor& p, int which) noexcept;
size_t stringsBytes(ModuleProcessor& p, int which) noexcept;

}  // namespace starling
}  // namespace caw
