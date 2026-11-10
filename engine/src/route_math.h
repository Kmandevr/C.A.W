// Float routing arithmetic shared by the mixer and graph summing inputs: saturating, never inf or NaN.
#pragma once

#include <cfloat>

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

}  // namespace caw
