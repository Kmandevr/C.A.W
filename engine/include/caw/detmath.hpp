// Deterministic maths (public SDK): JavaScript number semantics for bit ops and our own sin/exp/log, so every platform gives identical bits.
#pragma once

#include <bit>
#include <cmath>
#include <cstdint>

namespace caw {

// JavaScript ToUint32: NaN and infinities give 0, otherwise truncate and wrap modulo 2^32.
inline uint32_t toUint32(double d) {
    // Fast path for the common case (bytebeat values well inside int32): truncation then wrap, the same bits as below.
    if (d > -2147483648.0 && d < 2147483648.0) return static_cast<uint32_t>(static_cast<int32_t>(d));
    if (!std::isfinite(d)) return 0;
    d = std::trunc(d);
    if (d >= 0.0 && d < 4294967296.0) return static_cast<uint32_t>(d);
    d = std::fmod(d, 4294967296.0);
    if (d < 0.0) d += 4294967296.0;
    return static_cast<uint32_t>(d);
}

inline int32_t toInt32(double d) { return static_cast<int32_t>(toUint32(d)); }

inline bool truthy(double d) { return d != 0.0 && !std::isnan(d); }

// Division and modulo by zero give 0 (JavaScript would give Infinity or NaN).
inline double jsDiv(double a, double b) { return b == 0.0 ? 0.0 : a / b; }
inline double jsMod(double a, double b) {
    if (b == 0.0 || !std::isfinite(a)) return 0.0;
    if (!std::isfinite(b)) return a;
    // Fast path for whole numbers (step % 4, t % 256): integer remainder, exactly what fmod gives, including the
    // sign of a zero result.
    if (a > -9007199254740992.0 && a < 9007199254740992.0 && b > -9007199254740992.0 && b < 9007199254740992.0) {
        const int64_t ia = static_cast<int64_t>(a), ib = static_cast<int64_t>(b);
        if (static_cast<double>(ia) == a && static_cast<double>(ib) == b) {
            const double r = static_cast<double>(ia % ib);
            return r == 0.0 ? std::copysign(0.0, a) : r;
        }
    }
    return std::fmod(a, b);
}

// Lowbias32 integer hash (Chris Wellons, public domain).
inline uint32_t hash32(uint32_t x) {
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

constexpr double kPi = 3.14159265358979323846;
constexpr double kTwoPi = 6.28318530717958647692;

// Built from IEEE basic operations only (no platform maths library), so every platform gives identical
// bits when compiled without fused multiply-add contraction or fast-math (the flags CAW::SDK gives components;
// the engine itself builds with fast-math subsets and gives the same sound, not the same bits).
namespace detail {

// sin(r) for |r| <= pi/2 by its Taylor series to r^19 (error below 1e-15).
inline double sinPoly(double r) {
    const double r2 = r * r;
    double p = -1.0 / 121645100408832000.0;  // -1/19!
    p = p * r2 + 1.0 / 355687428096000.0;     // 1/17!
    p = p * r2 - 1.0 / 1307674368000.0;       // -1/15!
    p = p * r2 + 1.0 / 6227020800.0;          // 1/13!
    p = p * r2 - 1.0 / 39916800.0;            // -1/11!
    p = p * r2 + 1.0 / 362880.0;              // 1/9!
    p = p * r2 - 1.0 / 5040.0;                // -1/7!
    p = p * r2 + 1.0 / 120.0;                 // 1/5!
    p = p * r2 - 1.0 / 6.0;                   // -1/3!
    return r + r * r2 * p;
}

constexpr double kTwoPiHi = 6.28318530717958623200;  // 2*pi split for exact range reduction
constexpr double kTwoPiLo = 2.44929359829470635e-16;
constexpr double kLn2Hi = 6.93147180369123816490e-01;
constexpr double kLn2Lo = 1.90821492927058770002e-10;
constexpr double kLn2 = 0.69314718055994530942;
constexpr double kHalfPi = 1.57079632679489661923;

// (x - k * hi) - k * lo, in that order: Cody-Waite range reduction, exact for |x| up to about 1e15 to within the
// rounding of k * hi. The engine's own code builds with -fassociative-math (engine/CMakeLists.txt), which would fold
// it into x - k * (hi + lo), where hi + lo rounds to hi and lo is lost (twice the error at every |x|, and exp off by
// 1e-13). So Clang is told not to reassociate here (instruction flags, kept through inlining and link-time
// optimisation), and GCC's optimiser sees the partial result only through an empty asm that leaves it in its register
// (no instruction is emitted). A fused multiply-add (Arm64) may still compute x - k * hi with one rounding: more
// exact, never less. MSVC never reassociates under /fp:precise.
inline double reduce(double x, double k, double hi, double lo) {
#if defined(__clang__)
#pragma clang fp reassociate(off)
    return (x - k * hi) - k * lo;
#else
    double t = x - k * hi;
#if defined(__GNUC__) && (defined(__x86_64__) || defined(__SSE2_MATH__))
    __asm__("" : "+x"(t));
#elif defined(__GNUC__) && (defined(__aarch64__) || (defined(__arm__) && defined(__ARM_FP)))
    __asm__("" : "+w"(t));
#elif defined(__GNUC__)
    __asm__("" : "+m"(t));
#endif
    return t - k * lo;
#endif
}

}  // namespace detail

inline double detSin(double x) {
    if (!std::isfinite(x)) return 0.0;
    const double k = std::floor(x / kTwoPi + 0.5);
    double r = detail::reduce(x, k, detail::kTwoPiHi, detail::kTwoPiLo);  // now in [-pi, pi]
    if (r > detail::kHalfPi) r = kPi - r;
    else if (r < -detail::kHalfPi) r = -kPi - r;
    return detail::sinPoly(r);
}

inline double detCos(double x) { return detSin(x + detail::kHalfPi); }

inline double detTan(double x) {
    const double c = detCos(x);
    return c == 0.0 ? 0.0 : detSin(x) / c;
}

inline double detExp(double x) {
    if (std::isnan(x)) return 0.0;
    if (x > 709.0) x = 709.0;
    if (x < -745.0) return 0.0;
    const double k = std::floor(x / detail::kLn2 + 0.5);
    const double r = detail::reduce(x, k, detail::kLn2Hi, detail::kLn2Lo);  // |r| <= 0.35
    double p = 1.0 / 6227020800.0;                    // 1/13!
    p = p * r + 1.0 / 479001600.0;
    p = p * r + 1.0 / 39916800.0;
    p = p * r + 1.0 / 3628800.0;
    p = p * r + 1.0 / 362880.0;
    p = p * r + 1.0 / 40320.0;
    p = p * r + 1.0 / 5040.0;
    p = p * r + 1.0 / 720.0;
    p = p * r + 1.0 / 120.0;
    p = p * r + 1.0 / 24.0;
    p = p * r + 1.0 / 6.0;
    p = p * r + 0.5;
    p = p * r + 1.0;
    p = p * r + 1.0;
    // p * 2^k, with 2^k built from its bits while it is a normal number: the same correctly rounded product
    // ldexp gives (a power-of-two scale), without the library call.
    if (k >= -1022.0 && k <= 1023.0)
        return p * std::bit_cast<double>(static_cast<uint64_t>(static_cast<int64_t>(k) + 1023) << 52);
    return std::ldexp(p, static_cast<int>(k));
}

// log(x) for x > 0; 0 for x <= 0 (the language's NaN-free rule).
inline double detLog(double x) {
    if (!(x > 0.0) || !std::isfinite(x)) return 0.0;
    int e = 0;
    double m = std::frexp(x, &e);  // m in [0.5, 1)
    if (m < 0.70710678118654752440) {
        m *= 2.0;
        e -= 1;
    }
    const double s = (m - 1.0) / (m + 1.0);  // |s| <= 0.172
    const double s2 = s * s;
    double p = 1.0 / 23.0;
    for (int d = 21; d >= 3; d -= 2) p = p * s2 + 1.0 / d;
    p = p * s2 + 1.0;
    return static_cast<double>(e) * detail::kLn2 + 2.0 * s * p;
}

inline double detPow(double x, double y) {
    if (std::isnan(x) || std::isnan(y)) return 0.0;
    if (y == 0.0) return 1.0;
    if (y == std::trunc(y) && std::fabs(y) <= 1024.0) {
        // Exact square-and-multiply for whole exponents.
        long n = static_cast<long>(std::fabs(y));
        double base = x, acc = 1.0;
        while (n > 0) {
            if (n & 1) acc *= base;
            base *= base;
            n >>= 1;
        }
        if (y < 0.0) return acc == 0.0 ? 0.0 : 1.0 / acc;
        return acc;
    }
    if (x <= 0.0) return 0.0;
    return detExp(y * detLog(x));
}

inline double detTanh(double x) {
    if (std::isnan(x)) return 0.0;
    if (x > 20.0) return 1.0;
    if (x < -20.0) return -1.0;
    const double e = detExp(2.0 * x);
    return (e - 1.0) / (e + 1.0);
}

// Bit tools on 32-bit values.
inline uint32_t bitReverse(uint32_t x) {
    x = ((x >> 1) & 0x55555555U) | ((x & 0x55555555U) << 1);
    x = ((x >> 2) & 0x33333333U) | ((x & 0x33333333U) << 2);
    x = ((x >> 4) & 0x0F0F0F0FU) | ((x & 0x0F0F0F0FU) << 4);
    x = ((x >> 8) & 0x00FF00FFU) | ((x & 0x00FF00FFU) << 8);
    return (x >> 16) | (x << 16);
}

inline uint32_t byteSwap(uint32_t x) {
    return (x >> 24) | ((x >> 8) & 0xFF00U) | ((x << 8) & 0xFF0000U) | (x << 24);
}

// NaN and infinities become 0 before anything reaches the speakers.
inline double finiteOr0(double d) { return std::isfinite(d) ? d : 0.0; }

// x, with -0 made +0. In its bits, not as x + 0.0: the engine builds with -fno-signed-zeros, which lets the compiler
// fold x + 0.0 to x and leave the -0 (an integer compare and select, which no floating-point flag touches).
inline double positiveZero(double x) noexcept {
    const uint64_t bits = std::bit_cast<uint64_t>(x);
    return std::bit_cast<double>(bits == (uint64_t{1} << 63) ? uint64_t{0} : bits);
}

}  // namespace caw
