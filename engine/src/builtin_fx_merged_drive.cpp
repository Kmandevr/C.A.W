// Merged devices, part B (Drive, Bit distortion): their variants (FX consolidation, 1.0.8; empty until part B is built).
#include "fx_merged.h"

// The ids this part replaces (the old ones stay registered until part F retires them):
// Drive (variants: tape, tube, fold, clip, phase...) replaces:
//   org.caw.distortion (builtin_components.cpp), org.caw.saturator (builtin_effects_saturator.cpp; it has a "mode"
//   parameter, hence the reserved name `variant`), org.caw.clipper and org.caw.phasedist (builtin_fx_drive.cpp).
// Bit distortion (crush, rate, bitwise) replaces org.caw.bitcrush (builtin_fx_creative_bitcrush.cpp).
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

std::span<const MergedDevice> mergedDriveDevices() { return {}; }

}  // namespace caw::fx
