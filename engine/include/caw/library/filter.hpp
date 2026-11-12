// C.A.W. Library: filters (state-variable, one-pole, a 4-pole ladder and its multimode form), header-only and allocation-free.
#pragma once

#include <cmath>
#include <cstdint>

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
    void set(double cutoff, double q, double sampleRate) noexcept { setWith<false>(cutoff, q, sampleRate); }
    // set() with fastmath.hpp's tanApprox (within 1e-8 relative): cheaper, for a cutoff that moves every few blocks.
    void setApprox(double cutoff, double q, double sampleRate) noexcept { setWith<true>(cutoff, q, sampleRate); }
    template <bool Approx>
    void setWith(double cutoff, double q, double sampleRate) noexcept {
        // The rate is stored negated for setApprox(), so set() after setApprox() (or back) with the same
        // arguments works the coefficients out again instead of keeping the other form's.
        const double key = Approx ? -sampleRate : sampleRate;
        if (cutoff == cutoff_ && q == q_ && key == rate_) return;  // unchanged: no tan
        cutoff_ = cutoff;
        q_ = q;
        rate_ = key;
        double fc = finiteOr0(cutoff);
        const double top = 0.49 * sampleRate;
        fc = fc < 10.0 ? 10.0 : (fc > top ? top : fc);
        double qq = finiteOr0(q);
        qq = qq < 0.1 ? 0.1 : (qq > 40.0 ? 40.0 : qq);
        const double g = Approx ? tanApprox(kPi * fc / sampleRate) : detTan(kPi * fc / sampleRate);
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
    // The low-pass of a stereo pair whose right side was set like this one (setLike): both sides in one loop,
    // laid out side by side so the compiler runs them as one two-wide vector (each side's arithmetic is
    // lowpass()'s, so the bits are the same).
    void lowpassPair(Svf& right, float* l, float* r, uint32_t frames) noexcept {
#if defined(__GNUC__)  // GCC and Clang (the Android, Linux and Windows-Clang builds): a two-wide vector, SSE2 or NEON
        typedef double Pair __attribute__((vector_size(16)));
        Pair s1 = {ic1_, right.ic1_}, s2 = {ic2_, right.ic2_};
        const Pair a1 = {a1_, a1_}, a2 = {a2_, a2_}, a3 = {a3_, a3_}, zero = {0.0, 0.0}, two = {2.0, 2.0};
        for (uint32_t i = 0; i < frames; ++i) {
            Pair x = {static_cast<double>(l[i]), static_cast<double>(r[i])};
            x = x - x == zero ? x : zero;  // finiteOr0
            const Pair v3 = x - s2;
            const Pair v1 = a1 * s1 + a2 * v3;
            const Pair v2 = s2 + a2 * s1 + a3 * v3;
            s1 = two * v1 - s1;
            s2 = two * v2 - s2;
            l[i] = static_cast<float>(v2[0]);
            r[i] = static_cast<float>(v2[1]);
        }
        ic1_ = s1[0], right.ic1_ = s1[1], ic2_ = s2[0], right.ic2_ = s2[1];
#else
        for (uint32_t i = 0; i < frames; ++i) {
            l[i] = static_cast<float>(lowpass(static_cast<double>(l[i])));
            r[i] = static_cast<float>(right.lowpass(static_cast<double>(r[i])));
        }
#endif
    }
    double highpass(double x) noexcept { return process(x).high; }
    double bandpass(double x) noexcept { return process(x).band; }
    void clear() noexcept { ic1_ = ic2_ = 0.0; }
    // A silent input decays the state into subnormal numbers (slow on many CPUs): a caller whose input may be
    // silent flushes it with this once per block.
    void flushDenormals() noexcept {
        if (ic1_ < 1e-20 && ic1_ > -1e-20) ic1_ = 0.0;
        if (ic2_ < 1e-20 && ic2_ > -1e-20) ic2_ = 0.0;
    }
    // Takes another filter's coefficients (no tan): the second side of a stereo pair set like the first.
    void setLike(const Svf& other) noexcept {
        a1_ = other.a1_, a2_ = other.a2_, a3_ = other.a3_, k_ = other.k_;
        cutoff_ = other.cutoff_, q_ = other.q_, rate_ = other.rate_;
    }

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

// The ladder with low-, high- and band-pass outputs, by mixing its four stages' outputs ("pole mixing", the
// classic way a multimode ladder is built): with u the input to the first stage and y1..y4 each stage's output,
// low = y4 (24 dB/octave), high = u - 4 y1 + 6 y2 - 4 y3 + y4 (24 dB/octave: four one-pole high-passes, since
// each stage is u times a one-pole low-pass H and this is u (1 - H)^4), band = 4 (y2 - 2 y3 + y4) (u H^2
// (1 - H)^2: 12 dB/octave each side, unity near the cutoff). The resonance feeds back from y4 in every mode,
// so it peaks at the cutoff whichever output is taken.
//
// Made for many voices: set() works out every per-sample constant (the zero-delay feedback's powers of G and
// its divide), and the input stage saturates with softClip() (a rational curve, one divide) instead of a tanh,
// well under half of Ladder::processFast's cost. The curve stays within 3 % of tanh (most near |x| = 1.5 to 2),
// which at the levels a synth voice feeds it only shades the drive.
enum class LadderMode : int { LowPass, HighPass, BandPass };

// x (27 + x^2) / (27 + 9 x^2) for |x| <= 3, +-1 beyond: tanh's shape (slope 1 at 0, level and flat at 3) for a
// multiply-add and a divide. NaN gives 0.
inline double softClip(double x) noexcept {
    const double c = x < -3.0 ? -3.0 : (x > 3.0 ? 3.0 : finiteOr0(x));
    const double c2 = c * c;
    return c * (27.0 + c2) / (27.0 + 9.0 * c2);
}

class MultiLadder {
public:
    void set(double cutoff, double resonance, double sampleRate) noexcept { setWith<false>(cutoff, resonance, sampleRate); }
    // set() with fastmath.hpp's tanApprox (within 1e-8 relative): cheaper, for a cutoff that moves every few blocks.
    void setApprox(double cutoff, double resonance, double sampleRate) noexcept {
        setWith<true>(cutoff, resonance, sampleRate);
    }
    template <bool Approx>
    void setWith(double cutoff, double resonance, double sampleRate) noexcept {
        const double key = Approx ? -sampleRate : sampleRate;  // negated for setApprox(), as in Svf::setWith
        if (cutoff == cutoff_ && resonance == resonance_ && key == rate_) return;  // unchanged: no tan
        cutoff_ = cutoff;
        resonance_ = resonance;
        rate_ = key;
        double fc = finiteOr0(cutoff);
        const double top = 0.45 * sampleRate;
        fc = fc < 10.0 ? 10.0 : (fc > top ? top : fc);
        const double g = Approx ? tanApprox(kPi * fc / sampleRate) : detTan(kPi * fc / sampleRate);
        const double r0 = finiteOr0(resonance);
        const double k = 3.95 * (r0 < 0.0 ? 0.0 : (r0 > 1.0 ? 1.0 : r0));
        G_ = g / (1.0 + g);
        // u = clip((x (1 + k/2) - k S) / (1 + k G^4)) with S = (1 - G)(G^3 s0 + G^2 s1 + G s2 + s3): the
        // feedback solved for the sample itself (zero delay), every constant here.
        const double b = 1.0 - G_, G2 = G_ * G_, G3 = G2 * G_, G4 = G3 * G_;
        const double inv = 1.0 / (1.0 + k * G4);
        in_ = (1.0 + 0.5 * k) * inv;
        c_[0] = k * b * G3 * inv;
        c_[1] = k * b * G2 * inv;
        c_[2] = k * b * G_ * inv;
        c_[3] = k * b * inv;
    }
    // The coefficients of `other` (a stereo pair's second channel: one tan for both); the state stays.
    void setLike(const MultiLadder& other) noexcept {
        G_ = other.G_;
        in_ = other.in_;
        for (int i = 0; i < 4; ++i) c_[i] = other.c_[i];
        cutoff_ = other.cutoff_;
        resonance_ = other.resonance_;
        rate_ = other.rate_;
    }
    template <LadderMode Mode>
    double process(double input) noexcept {
        const double x = finiteOr0(input);
        const double u = softClip(x * in_ - (c_[0] * s_[0] + c_[1] * s_[1] + c_[2] * s_[2] + c_[3] * s_[3]));
        double y[4];
        double in = u;
        for (int i = 0; i < 4; ++i) {
            const double v = (in - s_[i]) * G_;
            y[i] = v + s_[i];
            s_[i] = y[i] + v;
            in = y[i];
        }
        if constexpr (Mode == LadderMode::LowPass) return y[3];
        else if constexpr (Mode == LadderMode::HighPass) return u - 4.0 * y[0] + 6.0 * y[1] - 4.0 * y[2] + y[3];
        else return 4.0 * (y[1] - 2.0 * y[2] + y[3]);
    }
    double process(double input, LadderMode mode) noexcept {
        switch (mode) {
            case LadderMode::HighPass: return process<LadderMode::HighPass>(input);
            case LadderMode::BandPass: return process<LadderMode::BandPass>(input);
            default: return process<LadderMode::LowPass>(input);
        }
    }
    // A block in place: the same as process<Mode>() per sample, with the state held in registers across it.
    template <LadderMode Mode>
    void process(float* x, uint32_t frames) noexcept {
        Lane a = lane();
        for (uint32_t i = 0; i < frames; ++i) x[i] = static_cast<float>(a.template step<Mode>(x[i]));
        store(a);
    }
    // A stereo pair's blocks, `left` through this filter and `right` through `other`, in one loop: the two
    // feedback chains are independent, so a CPU overlaps them (a ladder sample is a long chain of dependent
    // operations, and running the sides one after the other leaves it waiting). The same bits as two process()
    // calls.
    // With GCC or Clang the pair runs as two-wide double vectors (SSE2 or NEON; each lane's arithmetic is step()'s,
    // so the bits are the same; 2026-11-11 performance pass).
    template <LadderMode Mode>
    void processPair(MultiLadder& other, float* left, float* right, uint32_t frames) noexcept {
#if defined(__GNUC__)
        typedef double Pair __attribute__((vector_size(16)));
        const Pair G = {G_, other.G_}, in = {in_, other.in_}, c0 = {c_[0], other.c_[0]}, c1 = {c_[1], other.c_[1]};
        const Pair c2 = {c_[2], other.c_[2]}, c3 = {c_[3], other.c_[3]};
        const Pair zero = {0.0, 0.0}, three = {3.0, 3.0}, minusThree = {-3.0, -3.0}, k27 = {27.0, 27.0}, k9 = {9.0, 9.0};
        const Pair four = {4.0, 4.0}, six = {6.0, 6.0}, two = {2.0, 2.0};
        Pair s0 = {s_[0], other.s_[0]}, s1 = {s_[1], other.s_[1]}, s2 = {s_[2], other.s_[2]}, s3 = {s_[3], other.s_[3]};
        for (uint32_t i = 0; i < frames; ++i) {
            Pair x = {static_cast<double>(left[i]), static_cast<double>(right[i])};
            x = x - x == zero ? x : zero;  // finiteOr0
            const Pair w = x * in - (c0 * s0 + c1 * s1 + c2 * s2 + c3 * s3);
            const Pair f = w - w == zero ? w : zero;  // softClip's finiteOr0 (an infinity is held at +-3 below)
            const Pair c = w < minusThree ? minusThree : (w > three ? three : f);
            const Pair cc = c * c;
            const Pair u = c * (k27 + cc) / (k27 + k9 * cc);
            const Pair v0 = (u - s0) * G, y0 = v0 + s0;
            s0 = y0 + v0;
            const Pair v1 = (y0 - s1) * G, y1 = v1 + s1;
            s1 = y1 + v1;
            const Pair v2 = (y1 - s2) * G, y2 = v2 + s2;
            s2 = y2 + v2;
            const Pair v3 = (y2 - s3) * G, y3 = v3 + s3;
            s3 = y3 + v3;
            Pair y;
            if constexpr (Mode == LadderMode::LowPass) y = y3;
            else if constexpr (Mode == LadderMode::HighPass) y = u - four * y0 + six * y1 - four * y2 + y3;
            else y = four * (y1 - two * y2 + y3);
            left[i] = static_cast<float>(y[0]);
            right[i] = static_cast<float>(y[1]);
        }
        s_[0] = s0[0], s_[1] = s1[0], s_[2] = s2[0], s_[3] = s3[0];
        other.s_[0] = s0[1], other.s_[1] = s1[1], other.s_[2] = s2[1], other.s_[3] = s3[1];
#else
        Lane a = lane(), b = other.lane();
        for (uint32_t i = 0; i < frames; ++i) {
            left[i] = static_cast<float>(a.template step<Mode>(left[i]));
            right[i] = static_cast<float>(b.template step<Mode>(right[i]));
        }
        store(a);
        other.store(b);
#endif
    }
    // A silent tail would decay into subnormal numbers (slow on many CPUs): a caller that knows its input is
    // silent can flush the state with this once per block.
    void flushDenormals() noexcept {
        for (double& s : s_)
            if (s < 1e-20 && s > -1e-20) s = 0.0;
    }
    void clear() noexcept { s_[0] = s_[1] = s_[2] = s_[3] = 0.0; }

private:
    // The state and constants in locals, for a block loop.
    struct Lane {
        double s0, s1, s2, s3, G, in, c0, c1, c2, c3;
        template <LadderMode Mode>
        double step(double input) noexcept {
            const double u = softClip(finiteOr0(input) * in - (c0 * s0 + c1 * s1 + c2 * s2 + c3 * s3));
            const double v0 = (u - s0) * G, y0 = v0 + s0;
            s0 = y0 + v0;
            const double v1 = (y0 - s1) * G, y1 = v1 + s1;
            s1 = y1 + v1;
            const double v2 = (y1 - s2) * G, y2 = v2 + s2;
            s2 = y2 + v2;
            const double v3 = (y2 - s3) * G, y3 = v3 + s3;
            s3 = y3 + v3;
            if constexpr (Mode == LadderMode::LowPass) return y3;
            else if constexpr (Mode == LadderMode::HighPass) return u - 4.0 * y0 + 6.0 * y1 - 4.0 * y2 + y3;
            else return 4.0 * (y1 - 2.0 * y2 + y3);
        }
    };
    Lane lane() const noexcept { return {s_[0], s_[1], s_[2], s_[3], G_, in_, c_[0], c_[1], c_[2], c_[3]}; }
    void store(const Lane& a) noexcept {
        s_[0] = a.s0;
        s_[1] = a.s1;
        s_[2] = a.s2;
        s_[3] = a.s3;
    }
    double s_[4] = {0, 0, 0, 0};
    double G_ = 0.5, in_ = 1.0, c_[4] = {0, 0, 0, 0};
    double cutoff_ = -1, resonance_ = -1, rate_ = -1;  // what set() last worked out
};

}  // namespace caw::lib
