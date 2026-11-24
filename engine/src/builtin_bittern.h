// Bittern (org.caw.bittern, 1.1.3): the pipe organ instrument, its registration, presets and sizes.
#pragma once

#include <cstddef>
#include <string_view>
#include <vector>

#include "module_registry.h"

namespace caw {
struct BuiltinPreset;  // presets.h
namespace bittern {

inline constexpr std::string_view kBitternId = "org.caw.bittern";

void registerBittern(ModuleRegistry& registry);
const std::vector<BuiltinPreset>* bitternPresets(std::string_view id);
size_t bitternTableBytes() noexcept;

}  // namespace bittern
}  // namespace caw
