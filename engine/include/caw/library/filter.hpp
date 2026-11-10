// C.A.W. Library: filters (state-variable, one-pole, a 4-pole ladder), header-only and allocation-free.
#pragma once

#include <cmath>

#include "../detmath.hpp"
#include "fastmath.hpp"

namespace caw::lib {

// Resonance 0..1 to a filter Q: 0 is 0.707 (no peak), 0.5 about 3.7, 1 about 20 (it whistles).
inline double resonanceQ(double resonance) noexcept {
    const double r = resonance < 0.0 ? 0.0 : (resonance > 1.0 ? 1.0 : resonance);
    return 0.70710678118654752 * detPow(28.0, r);
}

// A cutoff in Hz moved by `octaves` (positive opens it), held between 10 Hz and 0.45 of the sample rate.
inline double shiftCutoff(double cutoff, double octaves, double sampleRate) noexcept {
    const double fc = finiteOr0(cutoff) * detPow(2.0, finiteOr0(octaves));
    const double top = 0.45 * sampleRate;
    return fc < 10.0 ? 10.0 : (fc > top ? top : fc);
}

struct SvfOutput {
    double low = 0, band = 0, high = 0, notch = 0;
};

// State-variable filter (topology-preserving, 12 dB/octave), the same maths as the .caw lpf/hpf/bpf/notch:
// cutoff held to 10 Hz .. 0.49 of the sample rate, q to 0.1..40. set() costs a tan; call it when the
// cutoff or q changes (every 16 frames is plenty), process() every sample.
class Svf {
public:
    void set(double cutoff, double q, double sampleRate) noexcept {
        if (cutoff == cutoff_ && q == q_ && sampleRate == rate_) return;  // unchanged: no tan
        cutoff_ = cutoff;
        q_ = q;
        rate_ = sampleRate;
        double fc = finiteOr0(cutoff);
        const double top = 0.49 * sampleRate;
        fc = fc < 10.0 ? 10.0 : (fc > top ? top : fc);
        double qq = finiteOr0(q);
        qq = qq < 0.1 ? 0.1 : (qq > 40.0 ? 40.0 : qq);
        const double g = detTan(kPi * fc / sampleRate);
        k_ = 1.0 / qq;
        a1_ = 1.0 / (1.0 + g * (g + k_));
        a2_ = g * a1_;
        a3_ = g * a2_;
    }
    SvfOutput process(double input) noexcept {
        const double x = finiteOr0(input);
        const double v3 = x - ic2_;
        const double v1 = a1_ * ic1_ + a2_ * v3;
        const double v2 = ic2_ + a2_ * ic1_ + a3_ * v3;
        ic1_ = 2.0 * v1 - ic1_;
        ic2_ = 2.0 * v2 - ic2_;
        return {v2, v1, x - k_ * v1 - v2, x - k_ * v1};
    }
    double lowpass(double x) noexcept { return process(x).low; }
    double highpass(double x) noexcept { return process(x).high; }
    double bandpass(double x) noexcept { return process(x).band; }
    void clear() noexcept { ic1_ = ic2_ = 0.0; }

private:
    double ic1_ = 0, ic2_ = 0, a1_ = 1, a2_ = 0, a3_ = 0, k_ = 1.41421356237309505;
    double cutoff_ = -1, q_ = -1, rate_ = -1;  // what set() last worked out
};

// One-pole low-pass (6 dB/octave), as the .caw lp1; high() is the input minus it.
class OnePole {
public:
    void set(double cutoff, double sampleRate) noexcept {
        if (cutoff == cutoff_ && sampleRate == rate_) return;  // unchanged: no exp
        cutoff_ = cutoff;
        rate_ = sampleRate;
        double fc = finiteOr0(cutoff);
        const double top = 0.49 * sampleRate;
        fc = fc < 1.0 ? 1.0 : (fc > top ? top : fc);
        k_ = 1.0 - detExp(-kTwoPi * fc / sampleRate);
    }
    double low(double x) noexcept { return y_ += (finiteOr0(x) - y_) * k_; }
    double high(double x) noexcept { return finiteOr0(x) - low(x); }
    void clear() noexcept { y_ = 0.0; }

private:
    double y_ = 0, k_ = 1;
    double cutoff_ = -1, rate_ = -1;  // what set() last worked out
};

// A 4-pole (24 dB/octave) low-pass ladder in zero-delay-feedback form, with a soft-clipped input stage: the
// squelchy filter of an acid line. resonance 0..1 (near 1 it rings on its own). The level drop that
// feedback causes in the passband is partly made up, as on the classic hardware.
class Ladder {
public:
    void set(double cutoff, double resonance, double sampleRate) noexcept {
        if (cutoff == cutoff_ && resonance == resonance_ && sampleRate == rate_) return;  // unchanged: no tan
        cutoff_ = cutoff;
        resonance_ = resonance;
        rate_ = sampleRate;
        double fc = finiteOr0(cutoff);
        const double top = 0.45 * sampleRate;
        fc = fc < 10.0 ? 10.0 : (fc > top ? top : fc);
        const double g = detTan(kPi * fc / sampleRate);
        G_ = g / (1.0 + g);
        const double r = resonance < 0.0 ? 0.0 : (resonance > 1.0 ? 1.0 : resonance);
        k_ = 3.95 * r;
    }
    double process(double input) noexcept { return step<false>(input); }
    // The same filter with the input stage's tanh from fastmath.hpp (within 1e-9): several times cheaper.
    double processFast(double input) noexcept { return step<true>(input); }
    void clear() noexcept { s_[0] = s_[1] = s_[2] = s_[3] = 0.0; }

private:
    template <bool Fast>
    double step(double input) noexcept {
        const double x = finiteOr0(input);
        const double b = 1.0 - G_;  // each stage: y = G * in + (1 - G) * s
        const double G2 = G_ * G_, G3 = G2 * G_, G4 = G3 * G_;
        const double S = b * (G3 * s_[0] + G2 * s_[1] + G_ * s_[2] + s_[3]);
        double u = (x * (1.0 + 0.5 * k_) - k_ * S) / (1.0 + k_ * G4);
        if constexpr (Fast) u = fastTanh(u);
        else u = detTanh(u);
        for (double& s : s_) {
            const double v = (u - s) * G_;
            const double y = v + s;
            s = y + v;
            u = y;
        }
        return u;
    }
    double s_[4] = {0, 0, 0, 0};
    double G_ = 0.5, k_ = 0;
    double cutoff_ = -1, resonance_ = -1, rate_ = -1;  // what set() last worked out
};

}  // namespace caw::lib
