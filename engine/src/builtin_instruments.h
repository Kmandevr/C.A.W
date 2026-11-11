// Built-in C++ instruments: Drums and Flagship, registered in every Engine.
#pragma once

#include "module_registry.h"

namespace caw {

// Drums ("org.caw.drums": 64 pads of layered drum synthesis and samples; the old org.caw.drum.* migrate to it) and
// Flagship ("org.caw.synth.flagship", whose presets replace the retired synths). Their DSP is the Library's
// (caw/library/), so user code can build the same sounds. registerBuiltinComponents calls it.
void registerBuiltinInstruments(ModuleRegistry& registry);

}  // namespace caw
