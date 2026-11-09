// Built-in stereo components (the C.A.W. Library, #121), registered in every Engine like a loaded component.
#pragma once

#include "module_registry.h"

namespace caw {

// Balance ("org.caw.stereo.balance": pan -1..1), width ("org.caw.stereo.width": width 0..2) and
// distortion ("org.caw.distortion": shape Drive/Hard clip/Fold/Crush, drive 1..20, bits 1..24, mix, output).
// They are part of the engine, so they need no trust choice; they can't be unloaded.
void registerBuiltinComponents(ModuleRegistry& registry);

}  // namespace caw
