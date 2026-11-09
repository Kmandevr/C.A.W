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

}  // namespace caw::lib
