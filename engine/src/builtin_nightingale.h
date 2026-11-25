// Nightingale (org.caw.nightingale, 1.1.3): the bowed strings instrument (violin, viola, cello, bass), its registration, presets and sizes.
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
namespace nightingale {

inline constexpr std::string_view kNightingaleId = "org.caw.nightingale";

// A merged device (fx_merged.h) whose `variant` ("Instrument") is Violin, Viola, Cello or Bass.
std::span<const fx::MergedDevice> mergedNightingaleDevices();
void registerNightingale(ModuleRegistry& registry);
const std::vector<BuiltinPreset>* nightingalePresets(std::string_view id);
size_t nightingaleBytes(uint32_t variant, double sampleRate) noexcept;
struct Bowed;
// The model inside a nightingale processor (any variant), for tests; nullptr for another component.
Bowed* nightingaleModelOf(ModuleProcessor& p) noexcept;

}  // namespace nightingale
}  // namespace caw
