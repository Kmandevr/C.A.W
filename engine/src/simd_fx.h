// Built-in effects' two-lane helpers (stereo_pair.h's Pair): a stereo pair of state-variable filters and fastExp per lane, each lane the scalar arithmetic.
#pragma once

#include <cstdint>

#include "caw/detmath.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/filter.hpp"
#include "stereo_pair.h"

namespace caw::fxsimd {

// finiteOr0 per lane (x - x is 0 exactly when x is finite).
inline Pair finitePair(Pair x) noexcept {
#if defined(__GNUC__)
    return x - x == splat(0.0) ? x : splat(0.0);
#else
    return pairOf(finiteOr0(lane(x, 0)), finiteOr0(lane(x, 1)));
#endif
}

// lib::Svf::process for two channels set alike: its coefficients (from one lib::Svf, which designs and caches
// them) and each channel's state in one lane. Each lane's arithmetic is Svf::process's (Svf::step, then the
// high and notch outputs as it forms them), so on x86-64 the bits are the scalar filter's (the 2026-11-27 effects
// pass checked every built-in that uses it bit for bit against the scalar build); with Arm64's fused
// multiply-adds the scalar and vector forms are fused alike on the builds checked.
struct SvfLanes {
    Pair s1 = splat(0.0), s2 = splat(0.0), a1 = splat(1.0), a2 = splat(0.0), a3 = splat(0.0), k = splat(1.41421356237309505);
    void like(const lib::Svf& f) noexcept { a1 = splat(f.a1()), a2 = splat(f.a2()), a3 = splat(f.a3()), k = splat(f.k()); }
    void clear() noexcept { s1 = s2 = splat(0.0); }
    void flush() noexcept { s1 = flushPair(s1), s2 = flushPair(s2); }  // lib::Svf::flushDenormals per lane
    // low (v2), band (v1); high and notch from them as Svf::process gives them.
    void step(Pair in, Pair& low, Pair& band) noexcept {
        const Pair x = finitePair(in);
        lib::Svf::step(x, s1, s2, a1, a2, a3, splat(2.0), band, low);
        x_ = x;
    }
    Pair high(Pair low, Pair band) const noexcept { return x_ - k * band - low; }
    Pair notch(Pair band) const noexcept { return x_ - k * band; }

private:
    Pair x_ = splat(0.0);  // the last step's input (finite)
};

// lib::dbToGain per lane: fastExp's steps lane by lane (its range checks as selects, its floor as floorSmall's
// truncate-and-correct, the same Horner chain), the same bits as two calls where the compiler fuses the scalar
// and vector chains alike (x86-64 has no fusing at the engine's baseline).
inline Pair dbToGainPair(Pair db) noexcept {
#if defined(__GNUC__)
    typedef int64_t I2 __attribute__((vector_size(16)));
    Pair x = finitePair(db) * splat(0.11512925464970229);
    const auto low = !(x > splat(-708.0));
    x = x > splat(709.0) ? splat(709.0) : x;
    x = low ? splat(0.0) : x;  // any value: masked to 0 at the end
    // floorSmall(t): truncate, then one less where that rounded up (t negative with a fraction).
    const Pair t = x * splat(1.4426950408889634) + splat(0.5);
    const I2 ti = __builtin_convertvector(t, I2);
    Pair k = __builtin_convertvector(ti, Pair);
    k = k > t ? k - splat(1.0) : k;
    const Pair r = (x - k * splat(6.93147180369123816490e-01)) - k * splat(1.90821492927058770002e-10);
    Pair p = splat(1.0 / 40320.0);
    p = p * r + splat(1.0 / 5040.0);
    p = p * r + splat(1.0 / 720.0);
    p = p * r + splat(1.0 / 120.0);
    p = p * r + splat(1.0 / 24.0);
    p = p * r + splat(1.0 / 6.0);
    p = p * r + splat(0.5);
    p = p * r + splat(1.0);
    p = p * r + splat(1.0);
    typedef uint64_t U2 __attribute__((vector_size(16)));
    const U2 bits = ((U2)(__builtin_convertvector(k, I2) + 1023)) << 52;
    const Pair out = p * (Pair)bits;
    return low ? splat(0.0) : out;
#else
    return pairOf(lib::dbToGain(lane(db, 0)), lib::dbToGain(lane(db, 1)));
#endif
}

// lib::TruePeak for both channels of a stereo pair, each channel one lane: the same taps (worked out as TruePeak
// works them out), the same sums in the same order, then the larger of the two channels' estimates (the limiter's
// max(left, right)).
class TruePeakPair {
public:
    TruePeakPair() noexcept {
        for (int p = 1; p < 4; ++p) {
            double sum = 0.0, h[8];
            for (int j = 0; j < 8; ++j) {
                const double t = static_cast<double>(j) - 4.0 + 0.25 * p;
                const double sinc = t == 0.0 ? 1.0 : detSin(kPi * t) / (kPi * t);
                const double w = 0.5 + 0.5 * detCos(kPi * t / 4.5);
                h[j] = sinc * w;
                sum += h[j];
            }
            for (int j = 0; j < 8; ++j) h_[p - 1][j] = splat(h[j] / sum);
        }
    }
    double process(double left, double right) noexcept {
        pos_ = (pos_ + 1) & 7;
        x_[pos_] = finitePair(pairOf(left, right));
        Pair peak = pairAbs(x_[(pos_ - 4) & 7]);
        const Pair next = pairAbs(x_[(pos_ - 3) & 7]);
        peak = pairMax(peak, next);  // next > peak ? next : peak
        for (int p = 0; p < 3; ++p) {
            Pair y = splat(0.0);
            for (int j = 0; j < 8; ++j) y += h_[p][j] * x_[(pos_ - j) & 7];
            peak = pairMax(peak, pairAbs(y));
        }
        const double l = lane(peak, 0), r = lane(peak, 1);
        return l < r ? r : l;  // std::max(left, right)
    }
    void clear() noexcept {
        for (Pair& v : x_) v = splat(0.0);
    }

private:
    Pair h_[3][8] = {};
    Pair x_[8] = {};
    unsigned pos_ = 0;
};

}  // namespace caw::fxsimd
