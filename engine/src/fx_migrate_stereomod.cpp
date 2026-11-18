// The migration table of part D (Utility/Stereo, Chorus/Flanger, Phaser, Tremolo/Pan): old effect ids to their merged devices (empty until part D is built).
#include "fx_migrate.h"

// The old ids, and where their merged devices live: builtin_fx_merged_stereomod.cpp.

namespace caw::fx {

std::span<const LegacyEffect> legacyStereoModEffects() { return {}; }

}  // namespace caw::fx
