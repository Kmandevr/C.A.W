// The modelled instruments' small DSP parts (Timber's, 1.1.0): delay lines, first-order allpasses and their phase delays, one-poles, biquads, noise and the 4-wide SIMD types.
#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>

#include "caw/detmath.hpp"

#if (defined(__GNUC__) || defined(__clang__)) && defined(__SSE__)
#include <xmmintrin.h>
#endif

namespace caw::timber {

inline constexpr double kPi = 3.14159265358979323846;
inline constexpr double kTwoPi = 6.28318530717958647692;

inline double clampd(double v, double lo, double hi) noexcept {
    if (!(v == v)) return lo;
    return v < lo ? lo : (v > hi ? hi : v);
}
// A value under 1e-20 to exact zero (a denormal guard). Written on |v| so it compiles to a mask, not a branch on the
// sign (a branch the predictor misses half the time on a ringing state).
inline float flushf(float v) noexcept { return std::fabs(v) < 1e-20f ? 0.0f : v; }
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

// Four lanes' masks and the lane-wise operations a four-voice loop needs (each lane computes exactly what one voice
// alone would: the same IEEE operations, so packing voices together changes no bits). A mask lane is all ones or 0.
#if defined(__GNUC__) || defined(__clang__)
typedef int32_t I4 __attribute__((vector_size(16)));
inline I4 i4(int32_t x) noexcept { return I4{x, x, x, x}; }
inline F4 div4(F4 a, F4 b) noexcept { return a / b; }
inline I4 lt4(F4 a, F4 b) noexcept { return a < b; }
inline I4 and4(I4 a, I4 b) noexcept { return a & b; }
inline I4 or4(I4 a, I4 b) noexcept { return a | b; }
inline I4 not4(I4 a) noexcept { return ~a; }
inline I4 eq4(I4 a, I4 b) noexcept { return ~(a ^ b); }  // of masks: both set or both clear
inline F4 sel4(I4 m, F4 a, F4 b) noexcept { return reinterpret_cast<F4>((reinterpret_cast<I4>(a) & m) | (reinterpret_cast<I4>(b) & ~m)); }
inline F4 abs4(F4 a) noexcept { return reinterpret_cast<F4>(reinterpret_cast<I4>(a) & i4(0x7fffffff)); }
#else
struct I4 {
    int32_t v[4];
    int32_t& operator[](int i) noexcept { return v[i]; }
    int32_t operator[](int i) const noexcept { return v[i]; }
};
inline I4 i4(int32_t x) noexcept { return {{x, x, x, x}}; }
inline F4 div4(F4 a, F4 b) noexcept { return {{a.v[0] / b.v[0], a.v[1] / b.v[1], a.v[2] / b.v[2], a.v[3] / b.v[3]}}; }
inline I4 lt4(F4 a, F4 b) noexcept {
    return {{a.v[0] < b.v[0] ? -1 : 0, a.v[1] < b.v[1] ? -1 : 0, a.v[2] < b.v[2] ? -1 : 0, a.v[3] < b.v[3] ? -1 : 0}};
}
inline I4 and4(I4 a, I4 b) noexcept { return {{a.v[0] & b.v[0], a.v[1] & b.v[1], a.v[2] & b.v[2], a.v[3] & b.v[3]}}; }
inline I4 or4(I4 a, I4 b) noexcept { return {{a.v[0] | b.v[0], a.v[1] | b.v[1], a.v[2] | b.v[2], a.v[3] | b.v[3]}}; }
inline I4 not4(I4 a) noexcept { return {{~a.v[0], ~a.v[1], ~a.v[2], ~a.v[3]}}; }
inline I4 eq4(I4 a, I4 b) noexcept { return {{~(a.v[0] ^ b.v[0]), ~(a.v[1] ^ b.v[1]), ~(a.v[2] ^ b.v[2]), ~(a.v[3] ^ b.v[3])}}; }
inline F4 sel4(I4 m, F4 a, F4 b) noexcept {
    return {{m.v[0] ? a.v[0] : b.v[0], m.v[1] ? a.v[1] : b.v[1], m.v[2] ? a.v[2] : b.v[2], m.v[3] ? a.v[3] : b.v[3]}};
}
inline F4 abs4(F4 a) noexcept { return {{std::fabs(a.v[0]), std::fabs(a.v[1]), std::fabs(a.v[2]), std::fabs(a.v[3])}}; }
#endif
inline I4 gt4(F4 a, F4 b) noexcept { return lt4(b, a); }
// std::min, std::max and std::clamp lane by lane (the same picks: b only when b < a, and so on).
inline F4 min4(F4 a, F4 b) noexcept { return sel4(lt4(b, a), b, a); }
inline F4 max4(F4 a, F4 b) noexcept { return sel4(lt4(a, b), b, a); }
inline F4 clamp4(F4 x, F4 lo, F4 hi) noexcept { return sel4(lt4(x, lo), lo, sel4(lt4(hi, x), hi, x)); }
inline bool any4(I4 m) noexcept { return (m[0] | m[1] | m[2] | m[3]) != 0; }
// The square root lane by lane (SSE's sqrtps on x86, as exact as sqrtss; elsewhere each lane's std::sqrt).
inline F4 sqrt4(F4 a) noexcept {
#if (defined(__GNUC__) || defined(__clang__)) && defined(__SSE__)
    return _mm_sqrt_ps(a);
#else
    F4 r;
    for (int k = 0; k < 4; ++k) r[k] = std::sqrt(a[k]);
    return r;
#endif
}

// A cheap soft clip: the [3/2] Pade form of tanh, x (27 + x^2) / (27 + 9 x^2), held to +-1 past |x| = 3.
inline float softClip(float x) noexcept {
    x = x < -3.0f ? -3.0f : (x > 3.0f ? 3.0f : x);
    const float s = x * x;
    return x * (27.0f + s) / (27.0f + 9.0f * s);
}

// atan(x) from exactly rounded operations only (+, -, *, / and sqrt), so every platform's library gives the same
// bits (each libm rounds atan, sin and cos its own way: the Windows renders of Starling's strings differed by -91 dB).
// |x| over 1 through pi/2 - atan(1/x), two halvings (atan x = 2 atan(x / (1 + sqrt(1 + x^2)))) to |x| <= tan(pi/16),
// then its series to the 25th power (the next term under 1e-18).
inline double detAtan(double x) noexcept {
    const bool neg = x < 0.0;
    if (neg) x = -x;
    const bool inv = x > 1.0;
    if (inv) x = 1.0 / x;
    double y = x / (1.0 + std::sqrt(1.0 + x * x));
    y = y / (1.0 + std::sqrt(1.0 + y * y));
    const double y2 = y * y;
    double sum = 0.0;
    for (int k = 12; k >= 0; --k) sum = ((k & 1) ? -1.0 : 1.0) / (2 * k + 1) + y2 * sum;
    double r = 4.0 * y * sum;
    if (inv) r = 1.5707963267948966 - r;
    return neg ? -r : r;
}
// The phase delay, in samples at `w` radians a sample, of the first-order allpass (a + z^-1) / (1 + a z^-1).
inline double allpassDelay(double a, double w) noexcept {
    return 1.0 - 2.0 / w * detAtan(a * detSin(w) / (1.0 + a * detCos(w)));
}
// The coefficient of that allpass whose phase delay at `w` is `d` samples (0 < d < 2): exact at w, not only at DC.
inline double allpassFor(double d, double w) noexcept {
    const double theta = 0.5 * w * (1.0 - d);
    const double den = detSin(w - theta);
    return den == 0.0 ? 0.0 : detSin(theta) / den;
}
// The phase delay at `w` of the one-pole low-pass b / (1 - p z^-1).
inline double onePoleDelay(double p, double w) noexcept {
    return detAtan(p * detSin(w) / (1.0 - p * detCos(w))) / w;
}
// |b / (1 - p e^-jw)| / b.
inline double onePoleMag(double p, double w) noexcept {
    return 1.0 / std::sqrt(1.0 - 2.0 * p * detCos(w) + p * p);
}
// The pole p of a one-pole low-pass whose gain at `w` is `r` (0 < r < 1) times its gain at DC.
inline double onePoleForRatio(double r, double w) noexcept {
    r = clampd(r, 1e-4, 0.999999);
    const double r2 = r * r, c = detCos(w);
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
        const double al = detSin(w) / (2.0 * q), c = detCos(w);
        norm(1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A);
    }
    // RBJ shelves of `db` with corner `hz` and quality `q` (0.707: no overshoot): below it, or above it.
    void lowShelf(double hz, double q, double db, double sr) noexcept {
        const double w = kTwoPi * clampd(hz, 10.0, 0.45 * sr) / sr, A = detPow(10.0, db / 40.0);
        const double al = detSin(w) / (2.0 * q), c = detCos(w), r = 2.0 * std::sqrt(A) * al;
        norm(A * ((A + 1) - (A - 1) * c + r), 2 * A * ((A - 1) - (A + 1) * c), A * ((A + 1) - (A - 1) * c - r),
             (A + 1) + (A - 1) * c + r, -2 * ((A - 1) + (A + 1) * c), (A + 1) + (A - 1) * c - r);
    }
    void highShelf(double hz, double q, double db, double sr) noexcept {
        const double w = kTwoPi * clampd(hz, 10.0, 0.45 * sr) / sr, A = detPow(10.0, db / 40.0);
        const double al = detSin(w) / (2.0 * q), c = detCos(w), r = 2.0 * std::sqrt(A) * al;
        norm(A * ((A + 1) + (A - 1) * c + r), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - r),
             (A + 1) - (A - 1) * c + r, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - r);
    }
    // A band-pass of unit peak gain at `hz` (a resonance).
    void band(double hz, double q, double sr) noexcept {
        const double w = kTwoPi * clampd(hz, 10.0, 0.45 * sr) / sr;
        const double al = detSin(w) / (2.0 * q), c = detCos(w);
        norm(al, 0, -al, 1 + al, -2 * c, 1 - al);
    }
    void lowpass(double hz, double q, double sr) noexcept {
        const double w = kTwoPi * clampd(hz, 10.0, 0.45 * sr) / sr;
        const double al = detSin(w) / (2.0 * q), c = detCos(w);
        norm((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al);
    }
    void highpass(double hz, double q, double sr) noexcept {
        const double w = kTwoPi * clampd(hz, 10.0, 0.45 * sr) / sr;
        const double al = detSin(w) / (2.0 * q), c = detCos(w);
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
        c = static_cast<float>(r * detCos(w)), s = static_cast<float>(r * detSin(w));
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

}  // namespace caw::timber
