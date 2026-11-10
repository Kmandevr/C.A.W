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

private:
    double amount_ = 1.0, gain_ = 1.3130352854993312;  // 1 / tanh(1)
};

}  // namespace caw::lib
