// C.A.W. Library: distortion (drive, hard clip, wavefold, bit crush), shared by .caw built-ins and components.
#pragma once

#include <cmath>

#include "../detmath.hpp"

namespace caw::lib {

// Warm saturation (tanh), level-matched so full scale stays full scale. amount: 1 clean .. 10 heavy.
inline double drive(double x, double amount) noexcept {
    const double a = amount < 0.01 ? 0.01 : amount;
    return detTanh(finiteOr0(x) * a) / detTanh(a);
}

// Hard clip at +/-1 after `amount` of gain, level-matched like drive (amount 1: clips only past full scale).
inline double hardClip(double x, double amount) noexcept {
    const double a = amount < 1.0 ? 1.0 : amount;
    const double y = finiteOr0(x) * a;
    return (y > 1.0 ? 1.0 : (y < -1.0 ? -1.0 : y));
}

// Wavefolder: more drive folds the wave back on itself. drive: 1..12.
inline double fold(double x, double drive) noexcept { return detSin(finiteOr0(x) * drive * (kPi / 2.0)); }

// Bit crusher: rounds to fewer bits (1..24, whole bits).
inline double crush(double x, double bits) noexcept {
    const double b = bits < 1.0 ? 1.0 : (bits > 24.0 ? 24.0 : bits);
    const double q = detPow(2.0, std::floor(b) - 1.0);
    return std::floor(finiteOr0(x) * q + 0.5) / q;
}

}  // namespace caw::lib
