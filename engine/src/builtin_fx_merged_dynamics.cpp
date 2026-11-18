// Merged devices, part A (Compressor, Limiter, Transient): their variants (FX consolidation, 1.0.8; empty until part A is built).
#include "fx_merged.h"

// The ids this part replaces (the old ones stay registered until part F retires them):
// Compressor (variants: the old compressor; dynamics; ducker as TWO variants per the owner: "duck", Compactor-style,
//   following a sidechain level, new DSP later, and "shape", today's drawn-shape ducker, where old projects open
//   unchanged; gate; plus the new expander and upward compression) replaces:
//   org.caw.compressor (builtin_effects_dynamics.cpp), org.caw.dynamics (builtin_fx_dynamics.cpp),
//   org.caw.ducker (builtin_ducker.cpp), org.caw.gate (builtin_effects_dynamics.cpp).
//   Keyed: keep the descriptor's real "sidechain" input on the variants that have one today.
// Limiter replaces org.caw.limiter (builtin_effects_dynamics.cpp).
// Transient replaces org.caw.transient (builtin_effects_dynamics.cpp); optional ports transient/sustain.
// Not merged: org.caw.multiband, org.caw.deesser (builtin_fx_dynamics.cpp).
//
// How to build a family (the template is Pitch/Shift, builtin_fx_merged_space.cpp and fx_migrate_space.cpp):
// - here: per variant a descriptor function (legacyVariantDescriptor of the old class's descriptor, or a table of
//   its own with variantParameter) and a factory (AsVariant<OldClass>, the class made non-final, or a new class);
//   then a Variant[] per device and the MergedDevice[] this function returns (fx_merged.h);
// - in fx_migrate_<family>.cpp: a LegacyEffect per old id (fx_migrate.h): merged id, variant, the parameters that
//   are renamed, mapped or dropped, fixed values, whether the state carries over, the old descriptor;
// - tests: old id against the migrated entry (render, latency, presets, a saved project), a variant change without
//   allocation on the audio thread, and a component_bench row (see the Pitch/Shift tests in fx_merged_test.cpp).

namespace caw::fx {

std::span<const MergedDevice> mergedDynamicsDevices() { return {}; }

}  // namespace caw::fx
