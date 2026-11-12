// The exact sample a step lands on, worked out with strict IEEE double maths (timing_oracle.cpp is built strict).
#pragma once

#include <cstdint>

namespace cawtest {

// Samples per sixteenth step: 60 * rate / (bpm * 4).
double strictStepFrames(double sampleRate, double bpm);
// The first sample of repeat `sub` of a note at step `at`, `len` steps long, cut into `ratchet` repeats:
// floor((at + (len / ratchet) * sub) * stepFrames + 0.5), each operation rounded on its own.
int64_t strictRatchetStart(double sampleRate, double bpm, double at, double len, int ratchet, int sub);

}  // namespace cawtest
