// The migration table of part B (Drive, Bit distortion): old effect ids to their merged devices (empty until part B is built).
#include "fx_migrate.h"

// The old ids, and where their merged devices live: builtin_fx_merged_drive.cpp.

namespace caw::fx {

std::span<const LegacyEffect> legacyDriveEffects() { return {}; }

}  // namespace caw::fx
