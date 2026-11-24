// Woodpecker (org.caw.woodpecker, 1.1.3): the tuned percussion instrument (marimba, xylophone, glockenspiel, vibraphone, tubular bells, timpani), its registration, presets and sizes.
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
namespace woodpecker {

struct Bars;  // woodpecker_bars.h

inline constexpr std::string_view kWoodpeckerId = "org.caw.woodpecker";

// Woodpecker is a merged device (fx_merged.h) whose `variant` ("Instrument") picks the instrument.
std::span<const fx::MergedDevice> mergedWoodpeckerDevices();
void registerWoodpecker(ModuleRegistry& registry);
// Woodpecker's presets (each names its `variant`); null for another id.
const std::vector<BuiltinPreset>* woodpeckerPresets(std::string_view id);
// Bytes per instance of instrument `variant` at `sampleRate` (the shared recordings not counted).
size_t woodpeckerBytes(uint32_t variant, double sampleRate) noexcept;
// The model inside an instance of instrument `variant` (the tests' access; null for another class).
Bars* woodpeckerModel(ModuleProcessor& p, uint32_t variant) noexcept;

}  // namespace woodpecker
}  // namespace caw
