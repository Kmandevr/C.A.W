// The migration table of part B (Drive, Bit distortion): old effect ids to their merged devices.
#include "fx_migrate.h"

// The merged devices live in builtin_fx_merged_drive.cpp.

namespace caw::fx {

// The old classes' own descriptors (defined next to each class).
const ModuleDescriptor& distortionDescriptor();   // builtin_components.cpp
const ModuleDescriptor& saturatorDescriptor();    // builtin_effects_saturator.cpp
const ModuleDescriptor& clipperDescriptor();      // builtin_fx_drive.cpp
const ModuleDescriptor& phaseDistDescriptor();    // builtin_fx_drive.cpp
const ModuleDescriptor& bitcrushDescriptor();     // builtin_fx_creative_bitcrush.cpp

namespace {

// Every variant wraps its old class unchanged: every parameter keeps its id and value (the saturator's "mode" too),
// no value is added, and the state (none) carries over.
const LegacyEffect kEffects[] = {
    {"org.caw.distortion", "org.caw.drive", 0, {}, {}, true, &distortionDescriptor},
    {"org.caw.saturator", "org.caw.drive", 1, {}, {}, true, &saturatorDescriptor},
    {"org.caw.clipper", "org.caw.drive", 2, {}, {}, true, &clipperDescriptor},
    {"org.caw.phasedist", "org.caw.drive", 3, {}, {}, true, &phaseDistDescriptor},
    {"org.caw.bitcrush", "org.caw.bits", 0, {}, {}, true, &bitcrushDescriptor},
};

}  // namespace

std::span<const LegacyEffect> legacyDriveEffects() { return kEffects; }

}  // namespace caw::fx
