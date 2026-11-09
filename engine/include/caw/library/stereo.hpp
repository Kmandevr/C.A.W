// C.A.W. Library: stereo placement (pan law), shared by the mixer and components. Header-only, allocation-free.
#pragma once

#include "../detmath.hpp"

namespace caw::lib {

// Constant-power pan: pan -1 (left) .. 0 (centre) .. +1 (right) gives the left and right gains
// cos and sin of (pan + 1) * pi/4, so left^2 + right^2 == 1 and the centre is -3 dB per side.
// The mixer's track pan uses exactly this (one implementation, deterministic on every platform).
struct PanGains {
    double left = 0.0;
    double right = 0.0;
};

inline PanGains constantPowerPan(double pan) noexcept {
    const double theta = (pan + 1.0) * (kPi / 4.0);
    return {detCos(theta), detSin(theta)};
}

// Balance for a stereo signal: pan -1 keeps only the left, +1 only the right, 0 leaves both at unity.
// The side being turned down falls linearly; the other side stays at unity (no boost).
inline PanGains balanceGains(double pan) noexcept {
    const double p = pan < -1.0 ? -1.0 : pan > 1.0 ? 1.0 : pan;
    return {p > 0.0 ? 1.0 - p : 1.0, p < 0.0 ? 1.0 + p : 1.0};
}

// Stereo width by mid/side: width 0 is the mono sum (mid) on both sides, 1 leaves the signal as it is,
// 2 doubles the side. A mono signal (left == right) stays exactly as it is at every width.
inline void applyWidth(double width, double& left, double& right) noexcept {
    const double mid = 0.5 * (left + right);
    const double side = 0.5 * (left - right) * width;
    left = mid + side;
    right = mid - side;
}

}  // namespace caw::lib
