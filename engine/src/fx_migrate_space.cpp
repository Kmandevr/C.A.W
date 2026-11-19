// The migration table of part E (Delay, Reverb, Pitch/Shift): old effect ids to their merged devices, each old class kept as its variant.
#include "builtin_fx_creative.h"
#include "fx_migrate.h"

// The merged devices live in builtin_fx_merged_space.cpp.

namespace caw::fx {

// The old effects' own descriptors (builtin_effects_space.cpp, builtin_components.cpp, builtin_fx_space_reverb.cpp).
const ModuleDescriptor& delayProDescriptor();
const ModuleDescriptor& pingPongDelayDescriptor();
const ModuleDescriptor& reverbProDescriptor();
const ModuleDescriptor& shimmerReverbDescriptor();

namespace {

// Each merged device here wraps its old classes unchanged: every parameter keeps its id and value, no value is
// added, and the state carries over.
const LegacyEffect kEffects[] = {
    {"org.caw.pitchshift", "org.caw.shift", 0, {}, {}, true, &pitchShiftDescriptor},
    {"org.caw.freqshift", "org.caw.shift", 1, {}, {}, true, &freqShiftDescriptor},
    // Delay and Reverb: the same (every old class unchanged, every parameter kept).
    {"org.caw.delay.pro", "org.caw.delay", 0, {}, {}, true, &delayProDescriptor},
    {"org.caw.delay.pingpong", "org.caw.delay", 1, {}, {}, true, &pingPongDelayDescriptor},
    {"org.caw.reverb.pro", "org.caw.reverb", 0, {}, {}, true, &reverbProDescriptor},
    {"org.caw.shimmer", "org.caw.reverb", 1, {}, {}, true, &shimmerReverbDescriptor},
};

}  // namespace

std::span<const LegacyEffect> legacySpaceEffects() { return kEffects; }

}  // namespace caw::fx
