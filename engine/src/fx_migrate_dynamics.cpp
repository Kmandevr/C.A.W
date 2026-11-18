// The migration table of part A (Compressor, Limiter, Transient): old effect ids to their merged devices (empty until part A is built).
#include "fx_migrate.h"

// The old ids, and where their merged devices live: builtin_fx_merged_dynamics.cpp.

namespace caw::fx {

std::span<const LegacyEffect> legacyDynamicsEffects() { return {}; }

}  // namespace caw::fx
