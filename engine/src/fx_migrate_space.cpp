// The migration table of part E (Delay, Reverb, Pitch/Shift): old effect ids to their merged devices; Pitch/Shift's is the template.
#include "builtin_fx_creative.h"
#include "fx_migrate.h"

// The merged devices live in builtin_fx_merged_space.cpp. Delay and Reverb (part E) add theirs here.

namespace caw::fx {

namespace {

// Pitch/Shift wraps both old classes unchanged: every parameter keeps its id and value, no value is added, and the
// state (none) carries over.
const LegacyEffect kEffects[] = {
    {"org.caw.pitchshift", "org.caw.shift", 0, {}, {}, true, &pitchShiftDescriptor},
    {"org.caw.freqshift", "org.caw.shift", 1, {}, {}, true, &freqShiftDescriptor},
};

}  // namespace

std::span<const LegacyEffect> legacySpaceEffects() { return kEffects; }

}  // namespace caw::fx
