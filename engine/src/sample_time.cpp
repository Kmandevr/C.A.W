// Sample positions of steps and seconds (sample_time.h). Built with the strict floating-point flags: no fused
// multiply-adds, no reassociation, whatever CAW_FP_FLAGS the rest of the engine takes.
#include "sample_time.h"

#include <cmath>

namespace caw::sampletime {

double stepFrames(double sampleRate, double bpm) noexcept { return 60.0 * sampleRate / (bpm * 4.0); }

double ratchetStep(double at, double len, int ratchet, int sub) noexcept {
    const double part = len / ratchet;
    return at + part * sub;
}

double roundFrames(double x, double scale) noexcept { return std::floor(x * scale + 0.5); }

double roundRepeat(int64_t k, double steps, double stepFrames) noexcept {
    return std::floor(static_cast<double>(k) * (steps * stepFrames) + 0.5);
}

double clipStep(double timeline, double step, double from) noexcept { return timeline + (step - from); }

double roundBeatFrames(double beat, double rate, double tempo) noexcept {
    return std::floor(beat * 60.0 * rate / tempo + 0.5);
}

double beatOffset(double pos, double beat, double beatFrames) noexcept { return pos - beat * beatFrames; }

}  // namespace caw::sampletime
