// Merged devices, part D (Utility/Stereo, Chorus/Flanger, Phaser, Tremolo/Pan): their variants (FX consolidation, 1.0.8; empty until part D is built).
#include "fx_merged.h"

// The ids this part replaces (the old ones stay registered until part F retires them):
// Utility/Stereo replaces: org.caw.stereo.width and org.caw.stereo.balance (builtin_components.cpp),
//   org.caw.imager, org.caw.haas and org.caw.channelmixer (builtin_fx_space_stereo.cpp), org.caw.utility
//   (builtin_effects_kit.cpp); optional ports mid/side. org.caw.downmix stays its own device (owner).
// Chorus/Flanger replaces: org.caw.chorus (builtin_components.cpp), org.caw.ensemble, org.caw.doubler,
//   org.caw.vibrato and org.caw.rotary (builtin_fx_space_mod.cpp), org.caw.flanger (builtin_effects_kit.cpp).
// Phaser replaces org.caw.phaser (builtin_effects_kit.cpp).
// Tremolo/Pan replaces org.caw.tremolo and org.caw.autopan (builtin_fx_space_mod.cpp).
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

std::span<const MergedDevice> mergedStereoModDevices() { return {}; }

}  // namespace caw::fx
