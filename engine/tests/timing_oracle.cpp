// Strict IEEE reference for sample timing (CMakeLists builds this file with the strict floating-point flags).
#include "timing_oracle.h"

#include <cmath>

namespace cawtest {

double strictStepFrames(double sampleRate, double bpm) { return 60.0 * sampleRate / (bpm * 4.0); }

int64_t strictRatchetStart(double sampleRate, double bpm, double at, double len, int ratchet, int sub) {
    const double part = len / ratchet;
    const double step = at + part * sub;
    return static_cast<int64_t>(std::floor(step * strictStepFrames(sampleRate, bpm) + 0.5));
}

}  // namespace cawtest
