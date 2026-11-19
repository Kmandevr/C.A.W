// Flock (org.caw.flock, 1.1.0): the granular instrument's registration, presets, sizes and project-state hook.
#pragma once

#include <cstddef>
#include <string_view>
#include <vector>

#include "module_registry.h"

namespace caw {
struct BuiltinPreset;  // presets.h
struct ComponentSpec;
namespace flock {

inline constexpr std::string_view kFlockId = "org.caw.flock";
inline constexpr uint32_t kVoiceCap = 16;
inline constexpr uint32_t kMaxStateBytes = 16384;

// Registers Flock and builds the grain windows (so no voice ever builds them).
void registerFlock(ModuleRegistry& registry);
// Flock's presets; null for another id.
const std::vector<BuiltinPreset>* presets(std::string_view id);
// Bytes per instance (the class; the shared sources not counted).
size_t instanceBytes() noexcept;
// A kept Flock whose project state (its sample) changed loads it (component_chain's project update).
void applyProjectState(ModuleProcessor& processor, const ComponentSpec& spec);

}  // namespace flock
}  // namespace caw
