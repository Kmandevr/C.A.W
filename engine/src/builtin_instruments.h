// Built-in C++ instruments (#157): drums, a drum kit, a bass, an acid synth and a morph synth, registered in every Engine.
#pragma once

#include "module_registry.h"

namespace caw {

// Kick ("org.caw.drum.kick"), snare ("org.caw.drum.snare"), hi-hats ("org.caw.drum.hats"), a drum kit
// mapping General MIDI keys to drum voices ("org.caw.drum.kit"), a mono bass ("org.caw.bass"), a
// 303-style acid synth ("org.caw.synth.acid") and a unison morph synth ("org.caw.synth.morph"). Their DSP
// is the Library's (caw/library/), so user code can build the same sounds. registerBuiltinComponents calls it.
void registerBuiltinInstruments(ModuleRegistry& registry);

}  // namespace caw
