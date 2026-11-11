// The racks (fx-racks): built-in containers that hold other built-in effects in one device (FX rack, multiband rack).
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "module_registry.h"
#include "project.h"

namespace caw {

inline constexpr std::string_view kFxRackId = "org.caw.rack.fx";
inline constexpr std::string_view kMultibandRackId = "org.caw.rack.multiband";

// Whether `id` names a rack (racks never go inside racks).
inline bool isRackId(std::string_view id) noexcept { return id.substr(0, 13) == "org.caw.rack."; }

// A child's identity in its slot's `<slot>_fx` parameter: the 32-bit FNV-1a hash of the component id held to 24 bits
// (exact as a double), never 0 (0 is an empty slot). The app computes the same (app/lib/model/racks.dart).
uint32_t rackChildHash(std::string_view id) noexcept;

// A container component (engine-internal, not part of the SDK). ComponentChain calls configure() right after
// creating it, before it reads descriptor(): the rack creates its children from the `<slot>_fx` values in `params`
// and its descriptor grows by their parameters. Control thread only.
class RackContainer {
public:
    virtual ~RackContainer() = default;
    // False (and `error`) when a slot names something that can't go in a rack; `lenient` empties such a slot instead.
    virtual bool configure(const ModuleRegistry& registry, const std::vector<std::pair<std::string, double>>& params,
                           bool lenient, std::string& error) = 0;
    // Child `child`'s latest display block (slots counted from 0 in slot order); 0 when the slot is empty. Any thread
    // but the audio thread.
    virtual uint32_t readChildDisplay(uint32_t child, float* out, uint32_t max) const noexcept = 0;
};

// What a rack's children are, from its spec's values ("" for a component that is not a rack): two specs with the same
// structure keep the running chain; a different one rebuilds it.
std::string rackStructure(const ComponentSpec& spec);

struct BuiltinPreset;
// The racks' factory presets (builtin_fx_racks_presets.cpp; presets.cpp lists them).
const std::vector<BuiltinPreset>& rackPresets(std::string_view componentId);

namespace fx {
void registerRacks(ModuleRegistry& registry);  // builtin_fx_racks.cpp
}  // namespace fx

}  // namespace caw
