// The flagship synth (#171, "org.caw.synth.flagship"): three wavetable oscillators with unison, two filters, a mod matrix and effects.
#pragma once

#include <string_view>

#include "module_registry.h"

namespace caw {

// Registers "org.caw.synth.flagship" ("Flagship"). registerBuiltinInstruments calls it.
void registerFlagshipSynth(ModuleRegistry& registry);

// The index of Flagship's parameter `id` (a mod slot's destination is this + 1), or -1.
int flagshipParameterIndex(std::string_view id) noexcept;

}  // namespace caw
