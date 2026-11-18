// The migration table of part C (EQ, Filter): old effect ids to their merged devices (empty until part C is built).
#include "fx_migrate.h"

// The old ids, and where their merged devices live: builtin_fx_merged_eqfilter.cpp.

namespace caw::fx {

std::span<const LegacyEffect> legacyEqFilterEffects() { return {}; }

}  // namespace caw::fx
