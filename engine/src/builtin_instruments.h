// Built-in C++ instruments (#157): drums, a drum kit and Flagship, registered in every Engine.
#pragma once

#include "module_registry.h"

namespace caw {

// Kick ("org.caw.drum.kick"), snare ("org.caw.drum.snare"), hi-hats ("org.caw.drum.hats"), a drum kit mapping
// General MIDI keys to drum voices ("org.caw.drum.kit") and Flagship ("org.caw.synth.flagship"), whose presets
// replace the retired bass, acid, morph and basic synths (presets.h). Their DSP is the Library's
// (caw/library/), so user code can build the same sounds. registerBuiltinComponents calls it.
void registerBuiltinInstruments(ModuleRegistry& registry);

}  // namespace caw
