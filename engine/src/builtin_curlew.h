// Curlew (org.caw.curlew, 1.1.3): the winds instrument (flute, clarinet, saxophone, trumpet, trombone, French horn), its registration, presets and sizes.
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
namespace curlew {

inline constexpr std::string_view kCurlewId = "org.caw.curlew";

// A merged device (fx_merged.h) whose `variant` ("Instrument") is Flute, Clarinet, Saxophone, Trumpet, Trombone or French horn.
std::span<const fx::MergedDevice> mergedCurlewDevices();
void registerCurlew(ModuleRegistry& registry);
const std::vector<BuiltinPreset>* curlewPresets(std::string_view id);
size_t curlewBytes(uint32_t variant, double sampleRate) noexcept;
struct Winds;
// The model inside a curlew processor (any variant), for tests; nullptr for another component.
Winds* curlewModelOf(ModuleProcessor& p) noexcept;

}  // namespace curlew
}  // namespace caw
