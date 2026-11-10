// C.A.W. Library: oscillators (band-limited saw, square, pulse, a sine-triangle-saw-square morph) and seeded noise, header-only.
#pragma once

#include <bit>
#include <cmath>
#include <cstdint>

#include "../detmath.hpp"

namespace caw::lib {

// A MIDI note number with fraction (69 = A4) to Hz, equal temperament at A4 = 440 Hz.
inline double noteHz(double pitch) noexcept { return 440.0 * detPow(2.0, (finiteOr0(pitch) - 69.0) / 12.0); }

// The phase (cycles) wrapped into 0..1. A phase in 0..2 (an oscillator's step past the end) takes a branch
// instead of floor, with the same result (+ 0.0 makes -0 read 0, as phase - floor(phase) does).
inline double wrap01(double phase) noexcept {
    if (phase >= 0.0 && phase < 2.0) return phase >= 1.0 ? phase - 1.0 : phase + 0.0;
    return phase - std::floor(phase);
}

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

// ---------- Block oscillators (float, for unison stacks and other many-oscillator sounds) ----------
//
// The same four shapes and morph as morphWave(), worked out for a block of frames at once in float with
// branch-free polyBLEP, so a compiler runs several frames per instruction (SIMD: GCC and Clang vectorize
// these loops on x86-64 and Arm64): several times cheaper per oscillator than morphWave() per sample, and
// the same sound (float rounding aside).

namespace block_detail {
// No branches: every value is worked out and then chosen, comparisons of values known to be >= 0 compare
// their bits as integers (the same order), and whole parts are truncations; so compilers vectorize the loops
// these sit in (a float comparison could raise an FP exception, which keeps GCC from if-converting it).
inline float pick(bool c, float a, float b) noexcept {  // c ? a : b, as a bit mask
    const uint32_t m = 0u - static_cast<uint32_t>(c);
    return std::bit_cast<float>((std::bit_cast<uint32_t>(a) & m) | (std::bit_cast<uint32_t>(b) & ~m));
}
inline bool below(float a, float b) noexcept { return std::bit_cast<int32_t>(a) < std::bit_cast<int32_t>(b); }  // a, b >= 0
inline float whole(float t) noexcept { return static_cast<float>(static_cast<int32_t>(t)); }  // floor, for t >= 0
// polyBLEP (as polyBlep()) for a step d cycles away (d -0.5..0.5, negative before it): its residual is
// -(1 - |d|/dt)^2 just after the step and +(1 - |d|/dt)^2 just before, 0 beyond dt. idt = 1 / dt.
inline float blep(float d, float idt) noexcept {
    const float x = std::fabs(d) * idt;
    const float m = pick(below(x, 1.0f), 1.0f - x, 0.0f);
    return -std::copysign(m * m, d);
}
inline float wrapOnce(float t) noexcept { return t - whole(t); }  // t 0..2
// sin(2 pi t) for t in 0..1, within 1e-7.
inline float sine(float t) noexcept {
    const float x = t - whole(t + 0.5f);                                // -0.5 .. 0.5
    const float y = std::copysign(0.25f - std::fabs(std::fabs(x) - 0.25f), x);  // folded to -0.25 .. 0.25
    const float r = y * 6.28318530717958648f, r2 = r * r;
    float p = -2.50521084e-8f;  // -1/11!
    p = p * r2 + 2.75573192e-6f;
    p = p * r2 - 1.98412698e-4f;
    p = p * r2 + 8.33333333e-3f;
    p = p * r2 - 1.66666667e-1f;
    return r + r * r2 * p;
}
inline float triangle(float t) noexcept { return 1.0f - 4.0f * std::fabs(wrapOnce(t + 0.25f) - 0.5f); }
// The saw's step is at 0 (1), the square's rise there too and its fall at 0.5.
inline float saw(float t, float idt) noexcept { return 2.0f * t - 1.0f - blep(t - whole(t + 0.5f), idt); }
inline float square(float t, float idt) noexcept {
    const float half = whole(t + 0.5f);  // 0 in the first half, 1 in the second
    return 1.0f - 2.0f * half + blep(t - half, idt) - blep(t - 0.5f, idt);
}
template <int Shape>
inline float shape(float t, float idt) noexcept {
    if constexpr (Shape == 0) return sine(t);
    else if constexpr (Shape == 1) return triangle(t);
    else if constexpr (Shape == 2) return saw(t, idt);
    else return square(t, idt);
}
template <int A, bool Blend>
inline void addMorph(float* sumL, float* sumR, uint32_t frames, float t0, float dt, float mix, float gainL,
                     float gainR) noexcept {
    const float idt = 1.0f / dt;
    for (uint32_t i = 0; i < frames; ++i) {
        float t = t0 + static_cast<float>(static_cast<int32_t>(i)) * dt;
        t -= whole(t);
        const float a = shape<A>(t, idt);
        float x = a;
        if constexpr (Blend && A < 3) x = a + (shape<A + 1>(t, idt) - a) * mix;
        sumL[i] += x * gainL;
        sumR[i] += x * gainR;
    }
}
template <int A, bool Blend>
inline void addStack(float* sumL, float* sumR, uint32_t frames, double* phases, const double* dts, uint32_t copies,
                     float mix, const float* gainsL, const float* gainsR) noexcept {
    for (uint32_t u = 0; u < copies; ++u) {
        const double dt = dts[u];
        if (!(dt > 0.0 && dt < 0.5)) continue;
        addMorph<A, Blend>(sumL, sumR, frames, static_cast<float>(phases[u]), static_cast<float>(dt), mix, gainsL[u], gainsR[u]);
        phases[u] = wrap01(phases[u] + static_cast<double>(frames) * dt);
    }
}
}  // namespace block_detail

// Adds `frames` frames of a stack of `copies` oscillators, each morphWave(phases[u], dts[u], shape), to sumL
// and sumR, scaled by gainsL[u] and gainsR[u], and moves each phase (cycles, 0..1) on: a unison stack, or any
// bank of oscillators sharing a shape. dts: 0 < dt < 0.5 cycles per sample (others are skipped). Keep blocks
// short (up to a few hundred frames: each copy's phase within the block is worked out in float).
inline void addMorphStack(float* sumL, float* sumR, uint32_t frames, double* phases, const double* dts, uint32_t copies,
                          double shape, const float* gainsL, const float* gainsR) noexcept {
    using namespace block_detail;
    const double pos = (shape < 0.0 ? 0.0 : (shape > 1.0 ? 1.0 : shape)) * 3.0;
    const int k = pos >= 3.0 ? 3 : static_cast<int>(pos);
    const float mix = static_cast<float>(pos - k);
    switch (k == 3 || mix == 0.0f ? k + 4 : k) {
        case 0: addStack<0, true>(sumL, sumR, frames, phases, dts, copies, mix, gainsL, gainsR); break;
        case 1: addStack<1, true>(sumL, sumR, frames, phases, dts, copies, mix, gainsL, gainsR); break;
        case 2: addStack<2, true>(sumL, sumR, frames, phases, dts, copies, mix, gainsL, gainsR); break;
        case 4: addStack<0, false>(sumL, sumR, frames, phases, dts, copies, mix, gainsL, gainsR); break;
        case 5: addStack<1, false>(sumL, sumR, frames, phases, dts, copies, mix, gainsL, gainsR); break;
        case 6: addStack<2, false>(sumL, sumR, frames, phases, dts, copies, mix, gainsL, gainsR); break;
        default: addStack<3, false>(sumL, sumR, frames, phases, dts, copies, mix, gainsL, gainsR); break;
    }
}
// One oscillator of addMorphStack.
inline void addMorphBlock(float* sumL, float* sumR, uint32_t frames, double& phase, double dt, double shape,
                          float gainL, float gainR) noexcept {
    addMorphStack(sumL, sumR, frames, &phase, &dt, 1, shape, &gainL, &gainR);
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
