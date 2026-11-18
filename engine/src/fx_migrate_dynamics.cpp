// The migration table of part A (Compressor, Limiter, Transient): old effect ids to their merged devices.
#include "fx_migrate.h"

// The merged devices live in builtin_fx_merged_dynamics.cpp. org.caw.compressor, org.caw.limiter and
// org.caw.transient are the merged ids themselves (their old effect is variant 0): nothing to migrate.

namespace caw::fx {

const ModuleDescriptor& legacyGateDescriptor();      // builtin_effects_dynamics.cpp
const ModuleDescriptor& legacyDynamicsDescriptor();  // builtin_fx_dynamics.cpp
const ModuleDescriptor& legacyDuckerDescriptor();    // builtin_ducker.cpp

namespace {

// Each variant wraps its old class unchanged: every parameter keeps its id and value, no value is added, and the
// state (none) carries over.
const LegacyEffect kEffects[] = {
    {"org.caw.dynamics", "org.caw.compressor", 1, {}, {}, true, &legacyDynamicsDescriptor},
    {"org.caw.gate", "org.caw.compressor", 2, {}, {}, true, &legacyGateDescriptor},
    {"org.caw.ducker", "org.caw.compressor", 3, {}, {}, true, &legacyDuckerDescriptor},
};

}  // namespace

std::span<const LegacyEffect> legacyDynamicsEffects() { return kEffects; }

}  // namespace caw::fx
