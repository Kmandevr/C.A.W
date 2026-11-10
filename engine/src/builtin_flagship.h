// The flagship synth (#171, "org.caw.synth.flagship"): three wavetable oscillators with unison, two filters, a mod matrix and effects.
#pragma once

#include "module_registry.h"

namespace caw {

// Registers "org.caw.synth.flagship" ("Flagship"). registerBuiltinInstruments calls it.
void registerFlagshipSynth(ModuleRegistry& registry);

}  // namespace caw
