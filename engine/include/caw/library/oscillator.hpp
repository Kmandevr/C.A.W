// C.A.W. Library: oscillators (band-limited saw, square, pulse, a sine-triangle-saw-square morph) and seeded noise, header-only.
#pragma once

#include <cmath>
#include <cstdint>

#include "../detmath.hpp"

namespace caw::lib {

// A MIDI note number with fraction (69 = A4) to Hz, equal temperament at A4 = 440 Hz.
inline double noteHz(double pitch) noexcept { return 440.0 * detPow(2.0, (finiteOr0(pitch) - 69.0) / 12.0); }

// The phase (cycles) wrapped into 0..1.
inline double wrap01(double phase) noexcept { return phase - std::floor(phase); }

// PolyBLEP: the residual that smooths a unit step at phase 0 over one sample, so a saw or square aliases
// far less than a naive one. t: phase 0..1, dt: cycles per sample (0 < dt < 0.5).
inline double polyBlep(double t, double dt) noexcept {
    if (!(dt > 0.0)) return 0.0;
    if (t < dt) {
        t /= dt;
        return t + t - t * t - 1.0;
    }
    if (t > 1.0 - dt) {
        t = (t - 1.0) / dt;
        return t * t + t + t + 1.0;
    }
    return 0.0;
}

// Each waveform takes the phase t (0..1) and the step dt (cycles per sample); all start at phase 0 as the
// .caw table shapes do: sine and triangle rising from 0, saw from -1, square at +1.
inline double sineWave(double t) noexcept { return detSin(kTwoPi * t); }
inline double triangleWave(double t) noexcept { return t < 0.25 ? 4.0 * t : (t < 0.75 ? 2.0 - 4.0 * t : 4.0 * t - 4.0); }
inline double sawWave(double t, double dt) noexcept { return 2.0 * t - 1.0 - polyBlep(t, dt); }
// A pulse that is +1 for the first `width` of the cycle (0.5: a square), -1 for the rest.
inline double pulseWave(double t, double dt, double width = 0.5) noexcept {
    const double w = width < 0.01 ? 0.01 : (width > 0.99 ? 0.99 : width);
    return (t < w ? 1.0 : -1.0) + polyBlep(t, dt) - polyBlep(wrap01(t + 1.0 - w), dt);
}
inline double squareWave(double t, double dt) noexcept { return pulseWave(t, dt, 0.5); }

// The wavetable pad's morph (the .caw table.basic, here computed instead of read from a table): `shape`
// 0..1 crossfades sine (0), triangle (1/3), saw (2/3) and square (1).
inline double morphWave(double t, double dt, double shape) noexcept {
    const double pos = (shape < 0.0 ? 0.0 : (shape > 1.0 ? 1.0 : shape)) * 3.0;
    const int k = pos >= 3.0 ? 2 : static_cast<int>(pos);
    const double mix = pos - k;
    auto wave = [&](int w) noexcept {
        switch (w) {
            case 0: return sineWave(t);
            case 1: return triangleWave(t);
            case 2: return sawWave(t, dt);
            default: return squareWave(t, dt);
        }
    };
    const double a = wave(k);
    return mix > 0.0 ? a + (wave(k + 1) - a) * mix : a;
}

// White noise in -1..1: the same seed gives the same sequence on every device (a counter through hash32).
class Noise {
public:
    explicit Noise(uint32_t seed = 1) noexcept : key_(hash32(seed ^ 0x6a09e667U)) {}
    void reset() noexcept { counter_ = 0; }
    double next() noexcept { return static_cast<double>(hash32(counter_++ ^ key_)) * (1.0 / 2147483648.0) - 1.0; }

private:
    uint32_t key_;
    uint32_t counter_ = 0;
};

}  // namespace caw::lib
