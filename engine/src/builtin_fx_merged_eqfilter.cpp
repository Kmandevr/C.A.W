// Merged devices, part C (EQ, Filter): their variants (FX consolidation, 1.0.8; empty until part C is built).
#include "fx_merged.h"

// The ids this part replaces (the old ones stay registered until part F retires them):
// EQ (bands, graphic, DJ, tilt; dynamic and M/S later) replaces:
//   org.caw.eq (builtin_effects_eq.cpp), org.caw.geq, org.caw.eq.dj and org.caw.tilt (builtin_fx_filters_eq.cpp).
// Filter (models, plus auto-filter and envelope wah) replaces:
//   org.caw.filter (builtin_effects_kit.cpp), org.caw.ladder and org.caw.nlfilter (builtin_fx_filters.cpp);
//   optional ports low/high.
// Not merged: org.caw.comb, .resonator, .formant, .disperser.
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

std::span<const MergedDevice> mergedEqFilterDevices() { return {}; }

}  // namespace caw::fx
