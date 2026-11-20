// Timber's Simulated piano (1.1.2): the keyboard curves shared by the build-time table generator and the engine (inharmonicity B, the hammer table's zones and velocity layers).
#pragma once

#include "caw/detmath.hpp"

namespace caw::timber::piano_curves {

// The inharmonicity coefficient along the keyboard (f_n = n f0 sqrt(1 + B n^2)), as Rigaud, David and Daudet's
// two-asymptote model (DAFx-11, "A parametric model of piano tuning", eq. 4-5; read 2026-11-20):
// B(m) = exp(sB m + yB) + exp(sT m + yT), m the MIDI note. The treble asymptote is theirs (sT = 9.26e-2,
// yT = -13.64, fitted over five pianos, C4-C8). The bass asymptote (sB = -0.091, yB = -6.19) is our L1 fit to the
// partials 2-15 measured on the Salamander Grand (a Yamaha C5, CC-BY 3.0, A. Holm; the numbers only, its audio is
// not shipped) at A0..A3, velocity layer 8 (2026-11-20). One curve, never a coefficient per partial.
inline double inharmonicity(double key) noexcept {
    return detExp(-0.091 * key - 6.19) + detExp(9.26e-2 * key - 13.64);
}

// The hammer tables' grid: 22 key zones spread evenly over A0..C8, 6 hammer speeds (m/s, at the hammer's crown).
inline constexpr int kZones = 22, kLayers = 6;
inline constexpr double kLayerSpeed[kLayers] = {0.5, 0.9, 1.6, 2.6, 4.0, 6.0};
inline double zoneKey(int z) noexcept { return 21.0 + 87.0 * z / (kZones - 1); }
// The force pulse's length in table frames (48 kHz): 8 ms holds the longest contact (a soft bass strike).
inline constexpr int kPulseFrames = 384;
inline constexpr double kPulseRate = 48000.0;

}  // namespace caw::timber::piano_curves
