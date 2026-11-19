// Timber's small DSP parts (org.caw.timber, 1.1.0): delay lines, first-order allpasses and their phase delays, one-poles, biquads, noise and the shared tables.
#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>

#include "caw/detmath.hpp"

namespace caw::timber {

inline constexpr double kPi = 3.14159265358979323846;
inline constexpr double kTwoPi = 6.28318530717958647692;

inline double clampd(double v, double lo, double hi) noexcept {
    if (!(v == v)) return lo;
    return v < lo ? lo : (v > hi ? hi : v);
}
inline float flushf(float v) noexcept { return (v > -1e-20f && v < 1e-20f) ? 0.0f : v; }
// Hz of a (fractional) MIDI note at A4 = 440.
inline double noteHz(double note) noexcept { return 440.0 * detPow(2.0, (note - 69.0) / 12.0); }

// Four floats as one SIMD value where the compiler has vector extensions (GCC, Clang, clang-cl: SSE on x86-64, NEON
// on Arm64), else a plain struct with the same operators (MSVC's cl). Element access with [] either way.
#if defined(__GNUC__) || defined(__clang__)
typedef float F4 __attribute__((vector_size(16)));
inline F4 f4(float x) noexcept { return F4{x, x, x, x}; }
#else
struct F4 {
    float v[4];
    float& operator[](int i) noexcept { return v[i]; }
    float operator[](int i) const noexcept { return v[i]; }
};
inline F4 operator+(F4 a, F4 b) noexcept { return {{a.v[0] + b.v[0], a.v[1] + b.v[1], a.v[2] + b.v[2], a.v[3] + b.v[3]}}; }
inline F4 operator-(F4 a, F4 b) noexcept { return {{a.v[0] - b.v[0], a.v[1] - b.v[1], a.v[2] - b.v[2], a.v[3] - b.v[3]}}; }
inline F4 operator*(F4 a, F4 b) noexcept { return {{a.v[0] * b.v[0], a.v[1] * b.v[1], a.v[2] * b.v[2], a.v[3] * b.v[3]}}; }
inline F4 f4(float x) noexcept { return {{x, x, x, x}}; }
#endif

// The phase delay, in samples at `w` radians a sample, of the first-order allpass (a + z^-1) / (1 + a z^-1).
inline double allpassDelay(double a, double w) noexcept {
    return 1.0 - 2.0 / w * std::atan(a * std::sin(w) / (1.0 + a * std::cos(w)));
}
// The coefficient of that allpass whose phase delay at `w` is `d` samples (0 < d < 2): exact at w, not only at DC.
inline double allpassFor(double d, double w) noexcept {
    const double theta = 0.5 * w * (1.0 - d);
    const double den = std::sin(w - theta);
    return den == 0.0 ? 0.0 : std::sin(theta) / den;
}
// The phase delay at `w` of the one-pole low-pass b / (1 - p z^-1).
inline double onePoleDelay(double p, double w) noexcept {
    return std::atan(p * std::sin(w) / (1.0 - p * std::cos(w))) / w;
}
// |b / (1 - p e^-jw)| / b.
inline double onePoleMag(double p, double w) noexcept {
    return 1.0 / std::sqrt(1.0 - 2.0 * p * std::cos(w) + p * p);
}
// The pole p of a one-pole low-pass whose gain at `w` is `r` (0 < r < 1) times its gain at DC.
inline double onePoleForRatio(double r, double w) noexcept {
    r = clampd(r, 1e-4, 0.999999);
    const double r2 = r * r, c = std::cos(w);
    const double b = 1.0 - r2 * c, a = 1.0 - r2;
    const double disc = b * b - a * a;
    return disc <= 0.0 ? 0.0 : clampd((b - std::sqrt(disc)) / a, 0.0, 0.9999);
}

// A float delay line of a power-of-two length, owned elsewhere (the model's block, allocated at prepare).
struct Line {
    float* buf = nullptr;
    uint32_t mask = 0, w = 0;
    void bind(float* b, uint32_t size) noexcept { buf = b, mask = size - 1, w = 0; }
    void clear() noexcept {
        if (buf) std::memset(buf, 0, (mask + 1) * sizeof(float));
        w = 0;
    }
    float at(uint32_t d) const noexcept { return buf[(w - d) & mask]; }
    // Linear read `d` samples back (d >= 1).
    float frac(float d) const noexcept {
        const uint32_t i = static_cast<uint32_t>(d);
        const float f = d - static_cast<float>(i);
        const float a = buf[(w - i) & mask], b = buf[(w - i - 1) & mask];
        return a + (b - a) * f;
    }
    void push(float x) noexcept {
        buf[w & mask] = x;
        ++w;
    }
};

// The smallest power of two >= n.
inline uint32_t pow2At(uint32_t n) noexcept {
    uint32_t p = 1;
    while (p < n) p <<= 1;
    return p;
}

// A transposed direct form II biquad in float, with the RBJ cookbook's designs (computed at control rate).
struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    float run(float x) noexcept {
        const float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    void clear() noexcept { z1 = z2 = 0; }
    void flush() noexcept { z1 = flushf(z1), z2 = flushf(z2); }
    void norm(double b0d, double b1d, double b2d, double a0, double a1d, double a2d) noexcept {
        b0 = static_cast<float>(b0d / a0), b1 = static_cast<float>(b1d / a0), b2 = static_cast<float>(b2d / a0);
        a1 = static_cast<float>(a1d / a0), a2 = static_cast<float>(a2d / a0);
    }
    // A peak of `db` at `hz` with quality `q`.
    void peak(double hz, double q, double db, double sr) noexcept {
        const double w = kTwoPi * clampd(hz, 10.0, 0.45 * sr) / sr, A = detPow(10.0, db / 40.0);
        const double al = std::sin(w) / (2.0 * q), c = std::cos(w);
        norm(1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A);
    }
    // A band-pass of unit peak gain at `hz` (a resonance).
    void band(double hz, double q, double sr) noexcept {
        const double w = kTwoPi * clampd(hz, 10.0, 0.45 * sr) / sr;
        const double al = std::sin(w) / (2.0 * q), c = std::cos(w);
        norm(al, 0, -al, 1 + al, -2 * c, 1 - al);
    }
    void lowpass(double hz, double q, double sr) noexcept {
        const double w = kTwoPi * clampd(hz, 10.0, 0.45 * sr) / sr;
        const double al = std::sin(w) / (2.0 * q), c = std::cos(w);
        norm((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al);
    }
    void highpass(double hz, double q, double sr) noexcept {
        const double w = kTwoPi * clampd(hz, 10.0, 0.45 * sr) / sr;
        const double al = std::sin(w) / (2.0 * q), c = std::cos(w);
        norm((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al);
    }
};

// A one-pole low-pass in float: y += k (x - y).
struct Lp1 {
    float k = 1, y = 0;
    void set(double hz, double sr) noexcept { k = static_cast<float>(1.0 - detExp(-kTwoPi * clampd(hz, 1.0, 0.49 * sr) / sr)); }
    float run(float x) noexcept { return y += k * (x - y); }
    void clear() noexcept { y = 0; }
    void flush() noexcept { y = flushf(y); }
};

// A seeded linear-congruential noise, -1..1.
struct Noise {
    uint32_t s = 1;
    float next() noexcept {
        s = s * 1664525u + 1013904223u;
        return static_cast<float>(static_cast<int32_t>(s)) * (1.0f / 2147483648.0f);
    }
};

// A complex one-pole mode (z <- p z + x, p = r e^jw): a decaying sine at w, read as Im z (it starts at zero).
struct Mode {
    float c = 0, s = 0, zr = 0, zi = 0;
    void set(double hz, double t60, double sr) noexcept {
        const double w = kTwoPi * hz / sr;
        const double r = t60 > 0 ? detExp(-6.907755278982137 / (t60 * sr)) : 0.0;
        c = static_cast<float>(r * std::cos(w)), s = static_cast<float>(r * std::sin(w));
    }
    float run(float x) noexcept {
        const float r = c * zr - s * zi + x;
        const float i = s * zr + c * zi;
        zr = r, zi = i;
        return i;
    }
    void clear() noexcept { zr = zi = 0; }
    void flush() noexcept { zr = flushf(zr), zi = flushf(zi); }
};

// The shared read-only tables (built once, at registration, never on the audio thread).
struct Tables {
    // The piano's soundboard excitations: 3 characters (Grand, Upright, Felt) x 8 register zones of kExcLength
    // 16-bit frames at kExcRate. Synthesised by Timber itself (timber_tables.cpp): no recording is used.
    static constexpr int kCharacters = 3, kZones = 8, kExcLength = 14400;
    static constexpr double kExcRate = 48000.0;
    int16_t excitation[kCharacters][kZones][kExcLength];
    // A sine of kSine + 1 points (the last repeats the first): the organ's tonewheels.
    static constexpr int kSine = 2048;
    float sine[kSine + 1];
    // A seeded noise burst for the plucked strings' excitation.
    static constexpr int kPluck = 8192;
    float pluck[kPluck];
};
// Builds them on first use (registerTimber calls it, so no voice ever does).
const Tables& tables() noexcept;

}  // namespace caw::timber
