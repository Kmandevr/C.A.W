// Deterministic maths: JavaScript number semantics for bit ops and our own sin/exp/log, so every platform gives identical bits.
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

double detSin(double x);
double detCos(double x);
double detTan(double x);
double detExp(double x);
double detLog(double x);
double detPow(double x, double y);
double detTanh(double x);

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

}  // namespace caw
