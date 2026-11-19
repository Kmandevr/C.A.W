// The migration table of part C (EQ, Filter): old effect ids to their merged devices.
#include "fx_migrate.h"

// The merged devices live in builtin_fx_merged_eqfilter.cpp. Their ids are the old parametric EQ's and multimode
// filter's (org.caw.eq, org.caw.filter), which play variant 0 unchanged, so they need no entry here.

namespace caw::fx {

const ModuleDescriptor& legacyGeqDescriptor();     // builtin_fx_filters_eq.cpp
const ModuleDescriptor& legacyEq3Descriptor();     // builtin_fx_filters_eq.cpp
const ModuleDescriptor& legacyTiltDescriptor();    // builtin_fx_filters_eq.cpp
const ModuleDescriptor& legacyLadderDescriptor();  // builtin_fx_filters.cpp
const ModuleDescriptor& legacyNlFilterDescriptor();  // builtin_fx_filters.cpp

namespace {

// Each variant wraps its old class unchanged: every parameter keeps its id and value, no value is added, and the
// state (none) carries over.
const LegacyEffect kEffects[] = {
    {"org.caw.geq", "org.caw.eq", 1, {}, {}, true, &legacyGeqDescriptor},
    {"org.caw.eq.dj", "org.caw.eq", 2, {}, {}, true, &legacyEq3Descriptor},
    {"org.caw.tilt", "org.caw.eq", 3, {}, {}, true, &legacyTiltDescriptor},
    {"org.caw.ladder", "org.caw.filter", 1, {}, {}, true, &legacyLadderDescriptor},
    {"org.caw.nlfilter", "org.caw.filter", 2, {}, {}, true, &legacyNlFilterDescriptor},
};

}  // namespace

std::span<const LegacyEffect> legacyEqFilterEffects() { return kEffects; }

}  // namespace caw::fx
