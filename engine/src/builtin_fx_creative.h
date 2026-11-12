// The Creative and Pitch & Time effects (fx-creative): their registration and the pieces they share (rings, cubic reads, seeded noise, the step clock).
#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <new>
#include <vector>

#include "builtin_effects.h"
#include "caw/detmath.hpp"
#include "sample_time.h"

namespace caw::fx {

// Registers org.caw.tapestop, .reverser, .trancegate, .stutter, .bitcrush, .pitchshift, .freqshift and .ringmod
// (builtin_fx_creative_*.cpp). registerBuiltinEffects calls it.
void registerCreative(ModuleRegistry& registry);

void registerTapeStop(ModuleRegistry& registry);    // builtin_fx_creative_tapestop.cpp
void registerReverser(ModuleRegistry& registry);    // builtin_fx_creative_reverser.cpp
void registerTranceGate(ModuleRegistry& registry);  // builtin_fx_creative_trancegate.cpp
void registerStutter(ModuleRegistry& registry);     // builtin_fx_creative_stutter.cpp
void registerBitcrush(ModuleRegistry& registry);    // builtin_fx_creative_bitcrush.cpp
void registerPitchShift(ModuleRegistry& registry);  // builtin_fx_creative_pitchshift.cpp
void registerFreqShift(ModuleRegistry& registry);   // builtin_fx_creative_freqshift.cpp
void registerRingMod(ModuleRegistry& registry);     // builtin_fx_creative_ringmod.cpp

namespace creative {

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

inline double clampTo(double v, double lo, double hi) noexcept { return v < lo ? lo : (v > hi ? hi : v); }

// 4-point, 3rd-order Hermite (Catmull-Rom) through x0 at t = 0 and x1 at t = 1, x-1 and x2 the neighbours (the
// "4-point, 3rd-order Hermite" of Niemitalo, "Polynomial Interpolators for High-Quality Resampling of
// Oversampled Audio", 2001): cheap, continuous slope, no overshoot to speak of.
inline double hermite(double xm1, double x0, double x1, double x2, double t) noexcept {
    const double c1 = 0.5 * (x1 - xm1);
    const double c2 = xm1 - 2.5 * x0 + 2.0 * x1 - 0.5 * x2;
    const double c3 = 0.5 * (x2 - xm1) + 1.5 * (x0 - x1);
    return ((c3 * t + c2) * t + c1) * t + x0;
}

// A stereo ring of a power-of-two size, set aside at activate (never on the audio thread). write() puts the
// frame "now"; read*(back) reads `back` frames before now (0: the frame just written), cubic between frames from
// one frame back, linear inside the newest frame.
class Ring {
public:
    // Room for at least `frames` frames back. False if the memory isn't there.
    bool allocate(size_t frames) noexcept {
        size_t n = 16;
        while (n < frames + 4) n <<= 1;
        try {
            l_.assign(n, 0.0f);
            r_.assign(n, 0.0f);
        } catch (const std::bad_alloc&) {
            return false;
        }
        mask_ = n - 1;
        pos_ = 0;
        return true;
    }
    void clear() noexcept {
        std::fill(l_.begin(), l_.end(), 0.0f);
        std::fill(r_.begin(), r_.end(), 0.0f);
        pos_ = 0;
    }
    // The most frames back a read may reach.
    double reach() const noexcept { return static_cast<double>(mask_ - 3); }
    void write(double l, double r) noexcept {
        pos_ = (pos_ + 1) & mask_;
        l_[pos_] = static_cast<float>(l);
        r_[pos_] = static_cast<float>(r);
    }
    double read(int channel, double back) const noexcept {
        const std::vector<float>& x = channel ? r_ : l_;
        back = clampTo(back, 0.0, reach());
        const size_t whole = static_cast<size_t>(back);
        const double t = back - static_cast<double>(whole);
        const size_t i0 = (pos_ - whole) & mask_;
        if (whole == 0) return x[i0] + (x[(i0 - 1) & mask_] - x[i0]) * t;
        // Going back is going forward in t: x0 is `whole` back, x1 one further.
        return hermite(x[(i0 + 1) & mask_], x[i0], x[(i0 - 1) & mask_], x[(i0 - 2) & mask_], t);
    }
    double readLinear(int channel, double back) const noexcept {
        const std::vector<float>& x = channel ? r_ : l_;
        back = clampTo(back, 0.0, reach());
        const size_t whole = static_cast<size_t>(back);
        const double t = back - static_cast<double>(whole);
        const size_t i0 = (pos_ - whole) & mask_;
        return x[i0] + (x[(i0 - 1) & mask_] - x[i0]) * t;
    }

private:
    std::vector<float> l_, r_;
    size_t mask_ = 0, pos_ = 0;
};

// A seeded noise source: the same numbers on every platform (an LCG through hash32).
struct Noise {
    uint32_t state = 1;
    void seed(uint32_t s) noexcept { state = hash32(s * 2654435761u + 0x9e3779b9u) | 1u; }
    // Uniform in [0, 1).
    double uniform() noexcept {
        state = state * 1664525u + 1013904223u;
        return static_cast<double>(hash32(state) >> 8) / 16777216.0;
    }
    // Uniform in [-1, 1).
    double bipolar() noexcept { return 2.0 * uniform() - 1.0; }
};

// A uniform number in [0, 1) for (seed, n): the same for the same pair wherever playback starts.
inline double chanceOf(uint32_t seed, uint64_t n) noexcept {
    const uint32_t h = hash32(hash32(seed * 0x9e3779b1u + 0x7f4a7c15u) ^ static_cast<uint32_t>(n) ^
                              hash32(static_cast<uint32_t>(n >> 32) + 0x632be5abu));
    return static_cast<double>(h >> 8) / 16777216.0;
}

// A clock in steps of `stepBeats` beats: locked to the song while it plays (its position in beats), else running
// free at the song's tempo from where it was (from 0 after a reset). advance() moves one frame on; position() is
// in steps since beat 0 (or since the free start).
struct StepClock {
    double pos = 0.0, inc = 0.0;
    bool locked = false;
    void reset() noexcept { pos = 0.0, inc = 0.0, locked = false; }
    // At a control point: the song's beat (if playing) and the frame's beat increment.
    void control(bool playing, double beat, double stepBeats, double tempo, double rate) noexcept {
        const double sb = stepBeats > 1e-9 ? stepBeats : 1e-9;
        inc = tempo / (60.0 * rate) / sb;
        // The song's frame, rounded: a block split anywhere gives the same frame, so the same steps.
        if (playing) pos = sampletime::roundBeatFrames(beat, rate, tempo) * inc, locked = true;
        else locked = false;
    }
    void advance() noexcept { pos += inc; }
};

}  // namespace creative
}  // namespace caw::fx
