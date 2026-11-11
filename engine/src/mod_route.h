// The one modulation route rule (#161): a source's 0..1 value, amount and polarity, a curve, and a knob moved in its normalized travel.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "caw/detmath.hpp"
#include "params.h"

namespace caw {

// A route (the Flagship's and the FX rack's `modN_*` slots, and a project modulation link) moves its target by
// `amount` (-1..1) of the target's normalized travel: the source's 0..1 value `u`, or with `bipolar` 2u - 1. Several
// routes into one knob add up; the sum is applied to the base value's normalized position and clamped, and the base
// value itself (what the host stores, automates and undoes) is never changed.
inline double modRouteOffset(double u, double amount, bool bipolar) noexcept {
    return amount * (bipolar ? 2.0 * u - 1.0 : u);
}

// A project link's response curve (-1..1, 0 straight): above 0 the source rises slowly first (u^(1 + 3c)), below 0
// quickly first (1 - (1 - u)^(1 + 3|c|)). The source is held to 0..1 first. Deterministic (detPow).
inline double modCurve(double u, double curve) noexcept {
    const double x = std::isfinite(u) ? std::clamp(u, 0.0, 1.0) : 0.0;
    if (!(curve != 0.0) || !std::isfinite(curve)) return x;
    const double c = std::clamp(curve, -1.0, 1.0);
    const double e = 1.0 + 3.0 * std::fabs(c);
    if (c > 0.0) return x <= 0.0 ? 0.0 : detPow(x, e);
    const double y = 1.0 - x;
    return 1.0 - (y <= 0.0 ? 0.0 : detPow(y, e));
}

// The plain value of parameter `p` at base value `base` moved by `offset` of its normalized travel.
inline double modulatedValue(const ParameterDescriptor& p, double base, double offset) noexcept {
    const double n = std::clamp(normalizeParameter(p, base) + offset, 0.0, 1.0);
    return constrainParameter(p, denormalizeParameter(p, n));
}

// A seeded 0..1 value for cycle `cycle` of a random source (the racks' and the project modulators' S&H and smooth
// random): a pure function of (seed, cycle), so every render and device gives the same values.
inline double modUnitHash(uint32_t seed, uint64_t cycle) noexcept {
    const uint32_t h = hash32(seed ^ hash32(static_cast<uint32_t>(cycle) ^ static_cast<uint32_t>(cycle >> 32) * 0x9e3779b9u));
    return static_cast<double>(h) / 4294967296.0;
}

// The LFO shapes the FX rack and the project LFO share, by their choice index: Sine, Triangle, Saw up, Saw down,
// Square, Sample & hold, Smooth random (6), at phase p (0..1) of cycle `cycle`; -1..1. Shape 7 (Custom) is the
// caller's (its points are parameters); this returns 0 for it.
inline double modLfoShape(int shape, double p, uint64_t cycle, uint32_t seed) noexcept {
    switch (shape) {
        case 0: return std::sin(2.0 * 3.14159265358979323846 * p);
        case 1: return p < 0.25 ? 4.0 * p : (p < 0.75 ? 2.0 - 4.0 * p : 4.0 * p - 4.0);
        case 2: return 2.0 * p - 1.0;
        case 3: return 1.0 - 2.0 * p;
        case 4: return p < 0.5 ? 1.0 : -1.0;
        case 5: return 2.0 * modUnitHash(seed, cycle) - 1.0;
        case 6: {
            const double a = modUnitHash(seed, cycle), b = modUnitHash(seed, cycle + 1);
            const double t = p * p * (3.0 - 2.0 * p);
            return 2.0 * (a + (b - a) * t) - 1.0;
        }
        default: return 0.0;
    }
}

}  // namespace caw
