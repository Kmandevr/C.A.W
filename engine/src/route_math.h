// Float routing arithmetic shared by the mixer and graph summing inputs: saturating, never inf or NaN.
#pragma once

#include <cfloat>

namespace caw {

// One sample entering a float route: NaN becomes 0 and anything beyond float range saturates at
// +/-FLT_MAX, so a runaway source can't turn into inf (or NaN after a zero gain) and make the master
// drop the whole mix. In-range values convert exactly as a plain cast does.
inline float routeSample(double x) noexcept {
    if (!(x == x)) return 0.0f;
    if (x > static_cast<double>(FLT_MAX)) return FLT_MAX;
    if (x < -static_cast<double>(FLT_MAX)) return -FLT_MAX;
    return static_cast<float>(x);
}

// Accumulates one routed sample into a float sum with the same saturation.
inline float routeAdd(float sum, float sample) noexcept {
    const float s = sum + sample;
    if (!(s == s)) return 0.0f;
    if (s > FLT_MAX) return FLT_MAX;
    if (s < -FLT_MAX) return -FLT_MAX;
    return s;
}

}  // namespace caw
