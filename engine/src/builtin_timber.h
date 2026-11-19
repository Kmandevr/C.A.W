// Timber (org.caw.timber, 1.1.0): the modelled acoustic instrument's registration, its models (variants), presets and sizes.
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
namespace timber {

inline constexpr std::string_view kTimberId = "org.caw.timber";

// Timber is a merged device (fx_merged.h) whose `variant` (named "Model") picks the model that runs: each model is its
// own class with its own descriptor (the shared knobs, its own, then `variant`), so only one model's voices exist.
std::span<const fx::MergedDevice> mergedTimberDevices();
// Builds the shared tables (the piano's excitations, the organ's sine, the pluck noise) and makes sure Timber is
// registered. registerBuiltinInstruments calls it.
void registerTimber(ModuleRegistry& registry);
// Timber's presets (each names its `variant`); null for another id.
const std::vector<BuiltinPreset>* timberPresets(std::string_view id);
// Bytes per instance of model `variant` at `sampleRate` (its class and what it allocates; the shared tables not counted).
size_t timberBytes(uint32_t variant, double sampleRate) noexcept;
// Bytes of the shared read-only tables (once per process).
size_t timberTableBytes() noexcept;

}  // namespace timber
}  // namespace caw
