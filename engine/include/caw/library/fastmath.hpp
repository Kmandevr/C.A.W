// C.A.W. Library: cheaper per-sample maths (exp, tanh, sine of a phase, a level-matched saturator), header-only.
#pragma once

#include <bit>
#include <cstdint>

#include "../detmath.hpp"

// detmath.hpp's functions are accurate to the last bit or two, which costs time in a per-sample path. These
// are built the same way (IEEE basic operations only, so every platform still gives identical bits with
// CAW's flags: no fused multiply-add contraction, no fast-math) but carry only about 1e-9 of accuracy:
// far below anything audible (-180 dB), and several times cheaper. Use them where the sound, not the last
// bit, is what matters (C.A.W. 2026-11-10, "Sound need only be perceptually the same").
namespace caw::lib {

namespace fast_detail {
// floor(x) for |x| < 2^31 without a library call.
inline double floorSmall(double x) noexcept {
    const double t = static_cast<double>(static_cast<int64_t>(x));
    return t > x ? t - 1.0 : t;
}
}  // namespace fast_detail

// e^x with a relative error below 3e-10; 0 for NaN and below -708, held at e^709 above 709.
inline double fastExp(double x) noexcept {
    if (!(x > -708.0)) return 0.0;
    if (x > 709.0) x = 709.0;
    const double k = fast_detail::floorSmall(x * 1.4426950408889634 + 0.5);
    const double r = (x - k * 6.93147180369123816490e-01) - k * 1.90821492927058770002e-10;  // |r| <= 0.35
    double p = 1.0 / 40320.0;  // e^r to r^8
    p = p * r + 1.0 / 5040.0;
    p = p * r + 1.0 / 720.0;
    p = p * r + 1.0 / 120.0;
    p = p * r + 1.0 / 24.0;
    p = p * r + 1.0 / 6.0;
    p = p * r + 0.5;
    p = p * r + 1.0;
    p = p * r + 1.0;
    return p * std::bit_cast<double>(static_cast<uint64_t>(static_cast<int64_t>(k) + 1023) << 52);
}

// ln(x) within 1e-15 (relative to 1, for x near 1, absolute elsewhere); -746 (below ln of the smallest double) for
// x <= 0 or NaN, ln(DBL_MAX) for +inf. Basic operations only: the exponent from the bits, the mantissa folded into
// [sqrt(1/2), sqrt(2)), then ln(m) = 2 atanh(s), s = (m - 1) / (m + 1), as its odd series (|s| <= 0.172).
inline double fastLog(double x) noexcept {
    if (!(x > 0.0)) return -746.0;
    if (x > 1.7976931348623157e308) return 709.782712893384;
    uint64_t bits = std::bit_cast<uint64_t>(x);
    int64_t e = static_cast<int64_t>((bits >> 52) & 0x7ff);
    if (e == 0) {  // subnormal: scale into the normal range first
        bits = std::bit_cast<uint64_t>(x * 18014398509481984.0);  // 2^54
        e = static_cast<int64_t>((bits >> 52) & 0x7ff) - 54;
    }
    double m = std::bit_cast<double>((bits & 0x000fffffffffffffULL) | 0x3ff0000000000000ULL);  // 1 .. 2
    e -= 1023;
    if (m > 1.4142135623730951) {
        m *= 0.5;
        ++e;
    }
    const double s = (m - 1.0) / (m + 1.0), s2 = s * s;
    double p = 1.0 / 17.0;
    p = p * s2 + 1.0 / 15.0;
    p = p * s2 + 1.0 / 13.0;
    p = p * s2 + 1.0 / 11.0;
    p = p * s2 + 1.0 / 9.0;
    p = p * s2 + 1.0 / 7.0;
    p = p * s2 + 1.0 / 5.0;
    p = p * s2 + 1.0 / 3.0;
    const double k = static_cast<double>(e);
    return k * 6.93147180369123816490e-01 + (2.0 * s + 2.0 * s * s2 * p) + k * 1.90821492927058770002e-10;
}

// Decibels to a gain and back (20 log10), on fastExp and fastLog. A gain of 0 (or less, or NaN) is `floorDb`.
inline double dbToGain(double db) noexcept { return fastExp(finiteOr0(db) * 0.11512925464970229); }  // ln(10) / 20
inline double gainToDb(double gain, double floorDb = -120.0) noexcept {
    if (!(gain > 0.0)) return floorDb;
    const double db = fastLog(gain) * 8.6858896380650366;  // 20 / ln(10)
    return db < floorDb ? floorDb : db;
}

// tanh(x) within 1e-9; NaN gives 0.
inline double fastTanh(double x) noexcept {
    if (!(x == x)) return 0.0;
    const double a = x < 0.0 ? -x : x;
    if (a > 19.0) return x < 0.0 ? -1.0 : 1.0;
    const double e = fastExp(-2.0 * a);
    const double t = (1.0 - e) / (1.0 + e);
    return x < 0.0 ? -t : t;
}

// tanh(x) within 5e-9 (absolute; 1e-9 relative near 0), for audio-rate curves: about half fastTanh's cost, with no
// exponential and no branch (so it vectorizes). |x| is held at 10 (tanh(10) is 1 - 4.1e-9), then x P(x^2) / Q(x^2),
// a rational fit of degree 5 over 5 in x^2 (C.A.W. 2026-11-12, fitted by weighted least squares, worst fit error
// 1.3e-10 on 0..10). NaN gives 0. Not fastTanh's bits: use it where the sound, not the bits, is what matters.
// tanhApprox's x P(x^2) / Q(x^2) on an x already held to -10..10: for a double or a GCC/Clang two-wide vector, so
// the scalar and vector forms share one copy of the fit.
template <class T>
inline T tanhApproxRational(T x) noexcept {
    const T s = x * x;
    T p = s * 3.217632110003212e-11 + 1.0357852250132971e-07;
    p = p * s + 4.092017186705684e-05;
    p = p * s + 0.0043728758223902315;
    p = p * s + 0.14059264090233234;
    p = p * s + 0.9999999993415611;
    T q = s * 2.6742358055163463e-09 + 2.4792909092118756e-06;
    q = q * s + 0.0004906653531677001;
    q = q * s + 0.02901487015638532;
    q = q * s + 0.4739259712575389;
    q = q * s + 1.0;
    return x * p / q;
}
inline double tanhApprox(double x) noexcept {
    x = x == x ? x : 0.0;
    x = x > 10.0 ? 10.0 : (x < -10.0 ? -10.0 : x);
    return tanhApproxRational(x);
}

// sin(2 pi t) for a phase t in cycles (any |t| below 2^31), within 1e-9; NaN gives 0.
inline double fastSinCycles(double t) noexcept {
    if (!(t > -2147483648.0 && t < 2147483648.0)) return 0.0;
    double x = t - fast_detail::floorSmall(t + 0.5);  // -0.5 .. 0.5
    if (x > 0.25) x = 0.5 - x;  // sin is symmetric about a quarter cycle
    else if (x < -0.25) x = -0.5 - x;
    const double r = x * kTwoPi, r2 = r * r;  // |r| <= pi/2: the series to r^13
    double p = 1.0 / 6227020800.0;
    p = p * r2 - 1.0 / 39916800.0;
    p = p * r2 + 1.0 / 362880.0;
    p = p * r2 - 1.0 / 5040.0;
    p = p * r2 + 1.0 / 120.0;
    p = p * r2 - 1.0 / 6.0;
    return r + r * r2 * p;
}

// tan(x) for |x| < pi/2 as two fastSinCycles, within 1e-8 relative while cos(x) >= 0.03 (a filter's tan(pi fc / sr)
// up to fc = 0.49 sr): cheaper than detTan for coefficients worked out at control rate. 0 where cos(x) is 0.
inline double tanApprox(double x) noexcept {
    const double t = x * 0.15915494309189535;  // 1 / (2 pi)
    const double c = fastSinCycles(t + 0.25);
    return c == 0.0 ? 0.0 : fastSinCycles(t) / c;
}

// The Library's drive() with its level-matching worked out once: set() costs a tanh (call it when the
// amount changes), process() a fastTanh. The same curve as drive(x, amount) within 1e-9.
class Saturator {
public:
    void set(double amount) noexcept {
        const double a = amount < 0.01 ? 0.01 : amount;
        if (a == amount_) return;
        amount_ = a;
        gain_ = 1.0 / detTanh(a);
    }
    double process(double x) const noexcept { return fastTanh(finiteOr0(x) * amount_) * gain_; }
    // process() on two values at once, the same bits: on GCC and Clang as a two-wide vector (SSE2, NEON), each
    // lane process()'s operations in its order (fastTanh, its fastExp and floorSmall through a 32-bit truncation,
    // exact for these magnitudes), elsewhere two calls.
    void process2(const double* in, double* out) const noexcept {
#if defined(__GNUC__)
        typedef double D2 __attribute__((vector_size(16)));
        typedef int64_t I2 __attribute__((vector_size(16)));
        typedef int32_t W2 __attribute__((vector_size(8)));
        const D2 zero = {0.0, 0.0}, one = {1.0, 1.0};
        D2 x = {in[0], in[1]};
        x = x - x == zero ? x : zero;  // finiteOr0
        x = x * amount_;
        const D2 a = x < zero ? -x : x;
        const I2 big = a > 19.0;
        const D2 y = -2.0 * (big ? D2{19.0, 19.0} : a);  // fastExp(-2a), where a <= 19: x above -708, below 709
        const D2 q = y * 1.4426950408889634 + 0.5;
        const D2 t = __builtin_convertvector(__builtin_convertvector(q, W2), D2);  // floorSmall: |q| < 2^31
        const D2 k = t > q ? t - 1.0 : t;
        const D2 r = (y - k * 6.93147180369123816490e-01) - k * 1.90821492927058770002e-10;
        D2 p = D2{1.0 / 40320.0, 1.0 / 40320.0};
        p = p * r + 1.0 / 5040.0;
        p = p * r + 1.0 / 720.0;
        p = p * r + 1.0 / 120.0;
        p = p * r + 1.0 / 24.0;
        p = p * r + 1.0 / 6.0;
        p = p * r + 0.5;
        p = p * r + 1.0;
        p = p * r + 1.0;
        const I2 scale = (__builtin_convertvector(k, I2) + 1023) << 52;
        D2 e;
        __builtin_memcpy(&e, &scale, sizeof e);
        e = p * e;
        const D2 th = (one - e) / (one + e);
        D2 v = big ? one : th;
        v = x < zero ? -v : v;
        v = v * gain_;
        out[0] = v[0];
        out[1] = v[1];
#else
        out[0] = process(in[0]);
        out[1] = process(in[1]);
#endif
    }

    // process() and process2() with tanhApprox: the same curve within 5e-9 x the level-matching gain, about half
    // the cost (two at a time as a two-wide vector on GCC and Clang). Where the compiler fuses multiply-adds
    // (Arm64, x86 with FMA) a vector lane and processApprox() can differ by a few ulps (about -300 dBFS), so a
    // different block split may change the lowest bits: the same sound, not the same bits.
    double processApprox(double x) const noexcept { return tanhApprox(finiteOr0(x) * amount_) * gain_; }
    void process2Approx(const double* in, double* out) const noexcept {
#if defined(__GNUC__)
        typedef double D2 __attribute__((vector_size(16)));
        const D2 zero = {0.0, 0.0}, lim = {10.0, 10.0};
        D2 x = {in[0], in[1]};
        x = x - x == zero ? x : zero;  // finiteOr0 (NaN and infinities give 0)
        x = x * amount_;
        x = x > lim ? lim : (x < -lim ? -lim : x);
        const D2 v = tanhApproxRational(x) * gain_;
        out[0] = v[0];
        out[1] = v[1];
#else
        out[0] = processApprox(in[0]);
        out[1] = processApprox(in[1]);
#endif
    }

    // processApprox() on n floats in place, in float arithmetic four at a time (a four-wide vector on GCC and
    // Clang: SSE on x86-64, NEON on Arm64; a plain loop of the same steps elsewhere): the same clamp and rational
    // fit with float coefficients, within about 1e-6 x the level-matching gain of processApprox() (float's
    // rounding, below -115 dBFS; Flagship's voice drive, #197). A tail of fewer than four runs padded to four,
    // so a value's result does not depend on where a block splits.
    void processApproxFloat(float* x, uint32_t n) const noexcept {
        const float amount = static_cast<float>(amount_), gain = static_cast<float>(gain_);
        uint32_t i = 0;
        for (; i + 4 <= n; i += 4) approxFloat4(x + i, amount, gain);
        if (i < n) {
            float t[4] = {0.0f, 0.0f, 0.0f, 0.0f};
            for (uint32_t k = 0; i + k < n; ++k) t[k] = x[i + k];
            approxFloat4(t, amount, gain);
            for (uint32_t k = 0; i + k < n; ++k) x[i + k] = t[k];
        }
    }

private:
    // tanhApproxRational's fit in float (x already held to -10..10).
    template <class T>
    static T tanhApproxRationalFloat(T x) noexcept {
        const T s = x * x;
        T p = s * 3.217632110003212e-11f + 1.0357852250132971e-07f;
        p = p * s + 4.092017186705684e-05f;
        p = p * s + 0.0043728758223902315f;
        p = p * s + 0.14059264090233234f;
        p = p * s + 0.9999999993415611f;
        T q = s * 2.6742358055163463e-09f + 2.4792909092118756e-06f;
        q = q * s + 0.0004906653531677001f;
        q = q * s + 0.02901487015638532f;
        q = q * s + 0.4739259712575389f;
        q = q * s + 1.0f;
        return x * p / q;
    }
    static void approxFloat4(float* x, float amount, float gain) noexcept {
#if defined(__GNUC__)
        typedef float F4 __attribute__((vector_size(16)));
        const F4 zero = {0.0f, 0.0f, 0.0f, 0.0f}, lim = {10.0f, 10.0f, 10.0f, 10.0f};
        F4 v;
        __builtin_memcpy(&v, x, sizeof v);
        v = v - v == zero ? v : zero;  // finiteOr0 (NaN and infinities give 0)
        v = v * amount;
        v = v > lim ? lim : (v < -lim ? -lim : v);
        v = tanhApproxRationalFloat(v) * gain;
        __builtin_memcpy(x, &v, sizeof v);
#else
        for (int k = 0; k < 4; ++k) {
            float v = x[k];
            v = v - v == 0.0f ? v : 0.0f;
            v = v * amount;
            v = v > 10.0f ? 10.0f : (v < -10.0f ? -10.0f : v);
            x[k] = tanhApproxRationalFloat(v) * gain;
        }
#endif
    }

    double amount_ = 1.0, gain_ = 1.3130352854993312;  // 1 / tanh(1)
};

}  // namespace caw::lib
