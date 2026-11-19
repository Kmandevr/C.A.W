// The migration table of part A (Compressor, Gate, Ducker, Limiter, Transient): old effect ids, and 1.0.8-1.0.9 Compressor variants, to their devices.
#include "fx_dyn_common.h"
#include "fx_migrate.h"

// The devices live in builtin_fx_merged_dynamics.cpp. org.caw.compressor, org.caw.gate, org.caw.limiter and
// org.caw.transient are merged ids themselves (their old effect is variant 0): nothing to migrate by id.

namespace caw::fx {

const ModuleDescriptor& legacyDynamicsDescriptor();  // builtin_fx_dynamics.cpp
const ModuleDescriptor& legacyDuckerDescriptor();    // builtin_ducker.cpp

namespace {

const ParamSet kTalonMarker[] = {{dyn::kTalonLayoutParam, dyn::kTalonLayoutCurrent}};

// Each variant wraps its old class unchanged: every parameter keeps its id and value, and the state (none) carries
// over. 1.1.0: org.caw.gate is Hatch's own id again (its row went), org.caw.ducker is Tremolo/Pan's Shape.
const LegacyEffect kEffects[] = {
    {"org.caw.dynamics", "org.caw.compressor", 1, {}, kTalonMarker, true, &legacyDynamicsDescriptor},
    {"org.caw.ducker", "org.caw.tremolo", 2, {}, {}, true, &legacyDuckerDescriptor},
};

// 1.1.0's split: a Compressor entry without talon_layout is 1.0.8's or 1.0.9's, of five variants; Gate, Shape and
// Duck left it with their parameters' ids and values (the classes are unchanged). Down and Dynamics stay.
const LayoutMove kMoves[] = {
    {"org.caw.gate", 0},     // 2: Gate
    {"org.caw.tremolo", 2},  // 3: Shape
    {"org.caw.duck", 0},     // 4: Duck
};
const LayoutDevice kLayouts[] = {
    {"org.caw.compressor", dyn::kTalonLayoutParam, dyn::kTalonLayoutCurrent, 5, 2, kMoves},
};

}  // namespace

std::span<const LegacyEffect> legacyDynamicsEffects() { return kEffects; }
std::span<const LayoutDevice> layoutDevices() { return kLayouts; }

}  // namespace caw::fx
