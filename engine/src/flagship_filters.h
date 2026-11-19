// Flagship's (Raven's) 1.1.0 filter models: a diode-ladder-style low-pass, a Sallen-Key low-pass and a phaser (TPT, header-only).
#pragma once

#include <cmath>
#include <cstdint>

#include "caw/detmath.hpp"
#include "caw/library/fastmath.hpp"

// Original code (C.A.W. is Apache-2.0): zero-delay-feedback (topology-preserving transform) filters after the
// method in V. Zavalishin, "The Art of VA Filter Design" (2012). No other synth's code was used. Each one works
// out its coefficients once per control period (set(), a tan) and runs a few tens of operations a sample; its state
// is bounded (a saturator in every loop) and flushed below 1e-20, so it never runs away or goes subnormal.

namespace caw::flagship {

inline double flushTiny(double v) noexcept { return v < 1e-20 && v > -1e-20 ? 0.0 : v; }
// A cheap soft clip: x - 4 x^3 / 27 on x held to +-1.5 (1 there, with a flat top): no division, four operations, so
// a filter's serial chain stays short.
inline double softClip(double x) noexcept {
    x = x > 1.5 ? 1.5 : (x < -1.5 ? -1.5 : x);
    return x - 0.14814814814814814 * x * x * x;
}
// f's process() on a stereo pair, the two sides' filters `l` and `r` in one loop: their chains are independent, so
// the CPU overlaps them (each filter's chain is a long run of dependent operations a sample).
template <class F>
void processPair(F& l, F& r, float* L, float* R, uint32_t n) noexcept {
    for (uint32_t i = 0; i < n; ++i) {
        const double a = l.process(static_cast<double>(L[i]));
        const double b = r.process(static_cast<double>(R[i]));
        L[i] = static_cast<float>(a);
        R[i] = static_cast<float>(b);
    }
}
inline double tanFor(double cutoff, double sampleRate) noexcept {
    double fc = finiteOr0(cutoff);
    const double top = 0.45 * sampleRate;
    fc = fc < 10.0 ? 10.0 : (fc > top ? top : fc);
    return lib::tanApprox(kPi * fc / sampleRate);
}

// A diode-ladder-style 24 dB low-pass: four one-pole stages whose feedback is solved without a sample's delay (the
// linear ladder's instantaneous response), the loop's input through an asymmetric soft clip and the first stage's
// output through a second one (cheap cubic clips), as a diode ladder's coupled first stage squashes earlier than the rest. A character
// model, not a circuit's: it rings thinner than the transistor ladder and its bass drops as the resonance rises.
// Resonance 0..1 is feedback 0..3.9 (self-oscillation at full).
class DiodeLp {
public:
    void set(double cutoff, double resonance, double sampleRate) noexcept {
        const double g = tanFor(cutoff, sampleRate);
        G_ = g / (1.0 + g);
        const double r = resonance < 0.0 ? 0.0 : (resonance > 1.0 ? 1.0 : resonance);
        k_ = 3.9 * r;
        const double G2 = G_ * G_;
        G4_ = G2 * G2;
        norm_ = 1.0 / (1.0 + k_ * G4_);
        gain_ = 1.0 + 0.5 * k_;  // the passband's level kept up as the feedback rises
    }
    double process(double x) noexcept {
        const double b = 1.0 - G_;
        // y4 = G^4 u + S, S from the four states.
        const double S = G_ * G_ * G_ * b * s_[0] + G_ * G_ * b * s_[1] + G_ * b * s_[2] + b * s_[3];
        double u = (finiteOr0(x) * gain_ - k_ * S) * norm_;
        u = softClip(u + 0.15) - 0.1495;  // an asymmetric clip, 0 at 0 (softClip(0.15) = 0.1495)
        double y = u;
        for (int i = 0; i < 4; ++i) {
            const double v = (y - s_[i]) * G_;
            double out = v + s_[i];
            s_[i] = flushTiny(out + v);
            if (i == 0) out = softClip(out);
            y = out;
        }
        return y;
    }
    void clear() noexcept { s_[0] = s_[1] = s_[2] = s_[3] = 0.0; }

private:
    double s_[4] = {};
    double G_ = 0.0, G4_ = 0.0, k_ = 0.0, norm_ = 1.0, gain_ = 1.0;
};

// A Sallen-Key 12 dB low-pass (the aggressive kind): with equal parts its response is a state-variable low-pass whose
// damping is 3 - K for the amplifier's gain K, so it is run as a TPT state-variable filter with that damping and the
// band state through a soft clip (the amplifier hitting its rails): it screams rather than whistles at high
// resonance. Resonance 0..1 is K 1..2.96 (Q 0.5..25).
class SallenKey {
public:
    void set(double cutoff, double resonance, double sampleRate) noexcept {
        g_ = tanFor(cutoff, sampleRate);
        const double r = resonance < 0.0 ? 0.0 : (resonance > 1.0 ? 1.0 : resonance);
        const double K = 1.0 + 1.96 * r;
        twoR_ = 3.0 - K;
        h_ = 1.0 / (1.0 + twoR_ * g_ + g_ * g_);
        drive_ = 1.0 + 1.5 * r;
        inGain_ = (1.0 + 0.3 * (drive_ - 1.0)) / drive_;
    }
    double process(double x) noexcept {
        const double in = softClip(finiteOr0(x) * drive_) * inGain_;
        const double hp = (in - (twoR_ + g_) * s1_ - s2_) * h_;
        const double bp = g_ * hp + s1_;
        const double lp = g_ * bp + s2_;
        s1_ = flushTiny(2.0 * softClip(0.5 * (bp + g_ * hp)));
        s2_ = flushTiny(lp + g_ * bp);
        return lp;
    }
    void clear() noexcept { s1_ = s2_ = 0.0; }

private:
    double s1_ = 0.0, s2_ = 0.0;
    double g_ = 0.0, twoR_ = 2.0, h_ = 1.0, drive_ = 1.0, inGain_ = 1.0;
};

// A phaser: 4 or 8 first-order TPT all-passes at the cutoff, their sum fed back (resonance 0..1 is feedback 0..0.9,
// through a soft clip, one sample late) and mixed half and half with the input, which notches the spectrum at
// the frequencies where the chain turns the phase by 180 degrees. An LFO slot on the cutoff sweeps it.
class Phaser {
public:
    void set(double cutoff, double resonance, double stages, double sampleRate) noexcept {
        const double g = tanFor(cutoff, sampleRate);
        G_ = g / (1.0 + g);
        const double r = resonance < 0.0 ? 0.0 : (resonance > 1.0 ? 1.0 : resonance);
        feedback_ = 0.9 * r;
        stages_ = stages >= 0.5 ? 8 : 4;
    }
    double process(double x) noexcept {
        const double in = finiteOr0(x);
        double y = in + feedback_ * last_;
        for (int i = 0; i < stages_; ++i) {
            const double v = (y - s_[i]) * G_;
            const double lp = v + s_[i];
            s_[i] = flushTiny(lp + v);
            y = 2.0 * lp - y;
        }
        last_ = flushTiny(softClip(y));
        return 0.5 * (in + y);
    }
    void clear() noexcept {
        for (double& s : s_) s = 0.0;
        last_ = 0.0;
    }

private:
    double s_[8] = {};
    double G_ = 0.0, feedback_ = 0.0, last_ = 0.0;
    int stages_ = 4;
};

}  // namespace caw::flagship
