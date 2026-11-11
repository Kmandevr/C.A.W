// The built-in modulators (#161): LFO, envelope, envelope follower, step sequencer, random, macros and MIDI to CV, for the project's modulators list.
#pragma once

#include "module_registry.h"

namespace caw {

// Registers org.caw.mod.lfo, .envelope, .follower, .steps, .random, .macros and .midi (builtin_modulators.cpp).
// registerBuiltinComponents calls it. Each is a component with modulation outputs (ComponentChain::isModulator)
// written on caw/modulator.hpp, the SDK users write their own with.
void registerBuiltinModulators(ModuleRegistry& registry);

}  // namespace caw
