// Float routing arithmetic shared by the mixer and graph summing inputs: saturating, never inf or NaN.
#pragma once

#include <bit>
#include <cfloat>
#include <cstdint>

namespace caw {

// One sample entering a float route: NaN becomes 0 and anything beyond float range saturates at
// +/-FLT_MAX, so a runaway source can't turn into inf (or NaN after a zero gain) and make the master
// drop the whole mix. In-range values convert exactly as a plain cast does.
// Written without branches (select, min, max), so loops over a block vectorize.
inline float routeSample(double x) noexcept {
    x = x == x ? x : 0.0;
    x = x < -static_cast<double>(FLT_MAX) ? -static_cast<double>(FLT_MAX) : x;
    x = x > static_cast<double>(FLT_MAX) ? static_cast<double>(FLT_MAX) : x;
    return static_cast<float>(x);
}

// Accumulates one routed sample into a float sum with the same saturation.
inline float routeAdd(float sum, float sample) noexcept {
    float s = sum + sample;
    s = s == s ? s : 0.0f;
    s = s < -FLT_MAX ? -FLT_MAX : s;
    s = s > FLT_MAX ? FLT_MAX : s;
    return s;
}

// The largest |x[i]| of a block with no NaN in it (0 for none). Non-negative floats order as their bits do, so
// this is an integer max, which vectorizes (a float max reduction does not, for the sign of zero; and SSE2 has a
// signed 32-bit compare, not an unsigned one).
inline float peakAbs(const float* x, int n) noexcept {
    int32_t top = 0;
    for (int i = 0; i < n; ++i) {
        const int32_t bits = static_cast<int32_t>(std::bit_cast<uint32_t>(x[i]) & 0x7fffffffu);
        top = bits > top ? bits : top;
    }
    return std::bit_cast<float>(top);
}

}  // namespace caw
