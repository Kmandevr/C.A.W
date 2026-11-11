// The internal test signal (org.caw.test.osc), a C++ instrument tests play in place of .caw source signals.
#pragma once

#include <string_view>

#include "module_registry.h"

namespace caw {

// "org.caw.test.osc": one event input ("notes"), one stereo output, no state. Registered in every Engine with
// ModuleRegistry::addInternal, so it plays by id in a project (a layer's `instrument`) and in the component test
// suite, but caw_engine_components and builtinComponents() never list it. Parameters (no smoothing: a value
// takes effect on the next block), in this order:
//   shape       0 Sine, 1 Saw (2*phase-1, rising), 2 Square (+1 for the first half cycle), 3 Noise (xorshift32,
//               uniform -1..1, seeded), 4 DC (outputs `level`), 5 Impulse (1 on the first frame, then every
//               `period` seconds), 6 Sweep (sine, exponential from the pitch to `sweep_to` over `sweep_time`,
//               then held)
//   mode        0 Free: one signal from the first block after activate/reset, ignoring notes;
//               1 Notes: one signal per held note (64 voices), pitch from the note, level times its velocity,
//               cut on its off (no release); quiet() while no note sounds
//   freq        Hz, 0..100000, default 440 (Free mode)
//   note        -1..127, default -1; >= 0 sets the Free-mode pitch as a MIDI note instead (69 = 440 Hz)
//   level       -1000..1000, default 1
//   left, right channel gains, -1000..1000, default 1
//   phase       start phase in cycles 0..1, default 0 (a voice's start)
//   seed        noise seed 0..2^31-1, default 1 (a note's voice uses seed + its host note id)
//   sweep_to    Hz, default 20000;  sweep_time  seconds, default 1;  period  impulse spacing, seconds, default 0
// Sine and sweep use detSin, so every platform gives the same bits.
constexpr std::string_view kTestSignalId = "org.caw.test.osc";

void registerTestSignal(ModuleRegistry& registry);

}  // namespace caw
