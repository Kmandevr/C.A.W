// C.A.W. Library: EQ bands on state-variable filters (a three-band EQ and a 12-type parametric band); header-only, allocation-free.
#pragma once

#include "../detmath.hpp"

namespace caw::lib {

// One band of an EQ: a topology-preserving state-variable filter whose output is a mix of the input, its band
// output and its low output, m0 x + m1 band + m2 low. Choosing the mix (and moving the cutoff by sqrt(A), with
// A = 10^(dB/40)) gives the shelves and the bell, each with gain A^2 (the dB asked for) exactly where it should
// be and 1 far from it, with no bump of its own (the standard construction for trapezoidal SVF shelves):
// - low shelf: g = tan(pi f / rate) / sqrt(A), m = (1, k (A - 1), A^2 - 1): A^2 at DC, 1 at the top;
// - high shelf: g = tan(pi f / rate) sqrt(A), m = (A^2, k (1 - A) A, 1 - A^2): 1 at DC, A^2 at the top;
// - bell: g = tan(pi f / rate), k = 1 / (Q A), m = (1, k (A^2 - 1), 0): A^2 at f.
class EqBand {
public:
    enum class Kind { LowShelf, Bell, HighShelf };
    // Costs a tan and a pow or two; skipped when nothing changed.
    void set(Kind kind, double hz, double db, double q, double sampleRate) noexcept {
        if (kind == kind_ && hz == hz_ && db == db_ && q == q_ && sampleRate == rate_) return;
        kind_ = kind;
        hz_ = hz;
        db_ = db;
        q_ = q;
        rate_ = sampleRate;
        double f = finiteOr0(hz);
        const double top = 0.49 * sampleRate;
        f = f < 10.0 ? 10.0 : (f > top ? top : f);
        double d = finiteOr0(db);
        d = d < -48.0 ? -48.0 : (d > 24.0 ? 24.0 : d);
        double qq = finiteOr0(q);
        qq = qq < 0.1 ? 0.1 : (qq > 40.0 ? 40.0 : qq);
        const double A = detPow(10.0, d / 40.0), rootA = detPow(10.0, d / 80.0);
        double g = detTan(kPi * f / sampleRate), k = 1.0 / qq;
        switch (kind) {
            case Kind::LowShelf:
                g /= rootA;
                m0_ = 1.0, m1_ = k * (A - 1.0), m2_ = A * A - 1.0;
                break;
            case Kind::HighShelf:
                g *= rootA;
                m0_ = A * A, m1_ = k * (1.0 - A) * A, m2_ = 1.0 - A * A;
                break;
            default:
                k = 1.0 / (qq * A);
                m0_ = 1.0, m1_ = k * (A * A - 1.0), m2_ = 0.0;
                break;
        }
        a1_ = 1.0 / (1.0 + g * (g + k));
        a2_ = g * a1_;
        a3_ = g * a2_;
    }
    double process(double input) noexcept {
        const double x = finiteOr0(input);
        const double v3 = x - ic2_;
        const double v1 = a1_ * ic1_ + a2_ * v3;
        const double v2 = ic2_ + a2_ * ic1_ + a3_ * v3;
        ic1_ = flush(2.0 * v1 - ic1_);
        ic2_ = flush(2.0 * v2 - ic2_);
        return m0_ * x + m1_ * v1 + m2_ * v2;
    }
    void clear() noexcept { ic1_ = ic2_ = 0.0; }

private:
    static double flush(double v) noexcept { return v < 1e-20 && v > -1e-20 ? 0.0 : v; }  // no subnormal tails
    double ic1_ = 0, ic2_ = 0, a1_ = 1, a2_ = 0, a3_ = 0, m0_ = 1, m1_ = 0, m2_ = 0;
    Kind kind_ = Kind::Bell;
    double hz_ = -1, db_ = 0, q_ = -1, rate_ = -1;  // what set() last worked out
};

// Low shelf at `lowHz`, a bell at `midHz` and a high shelf at `highHz`, in series; gains in dB (0 leaves a
// band as it is). One instance is one channel.
class ThreeBandEq {
public:
    void set(double lowDb, double midDb, double highDb, double midHz, double sampleRate, double lowHz = 250.0,
             double highHz = 4000.0, double midQ = 0.9) noexcept {
        low_.set(EqBand::Kind::LowShelf, lowHz, lowDb, 0.70710678118654752, sampleRate);
        mid_.set(EqBand::Kind::Bell, midHz, midDb, midQ, sampleRate);
        high_.set(EqBand::Kind::HighShelf, highHz, highDb, 0.70710678118654752, sampleRate);
    }
    double process(double x) noexcept { return high_.process(mid_.process(low_.process(x))); }
    void clear() noexcept {
        low_.clear();
        mid_.clear();
        high_.clear();
    }

private:
    EqBand low_, mid_, high_;
};

// ---------- The parametric band (the built-in EQ's, org.caw.eq) ----------

// One trapezoidal SVF stage's coefficients with an output mix y = m0 x + m1 band + m2 low: every band type below
// is one to four of these. `g` is tan(pi f / rate) (moved for a shelf), `k` 1 / Q.
struct SvfMix {
    double a1 = 1, a2 = 0, a3 = 0, g = 0, k = 1.4142135623730951, m0 = 1, m1 = 0, m2 = 0;
    void set(double gIn, double kIn, double m0In, double m1In, double m2In) noexcept {
        g = gIn, k = kIn, m0 = m0In, m1 = m1In, m2 = m2In;
        a1 = 1.0 / (1.0 + g * (g + k));
        a2 = g * a1;
        a3 = g * a2;
    }
    // |H|^2 at the frequency whose tan(pi f / rate) is t: the analog prototype at s = j t / g (bilinear, prewarped),
    // H = (m0 (s^2 + k s + 1) + m1 s + m2) / (s^2 + k s + 1).
    double magnitude2(double t) const noexcept {
        const double w = t / g, w2 = w * w;
        const double nr = m0 * (1.0 - w2) + m2, ni = (m0 * k + m1) * w;
        const double dr = 1.0 - w2, di = k * w;
        const double den = dr * dr + di * di;
        return den > 0.0 ? (nr * nr + ni * ni) / den : 1.0;
    }
};

// One channel's state of one stage.
struct SvfState {
    double ic1 = 0, ic2 = 0;
    double process(const SvfMix& c, double x) noexcept {
        const double v3 = x - ic2;
        const double v1 = c.a1 * ic1 + c.a2 * v3;
        const double v2 = ic2 + c.a2 * ic1 + c.a3 * v3;
        ic1 = 2.0 * v1 - ic1;
        ic2 = 2.0 * v2 - ic2;
        ic1 = ic1 < 1e-20 && ic1 > -1e-20 ? 0.0 : ic1;  // no subnormal tails
        ic2 = ic2 < 1e-20 && ic2 > -1e-20 ? 0.0 : ic2;
        return c.m0 * x + c.m1 * v1 + c.m2 * v2;
    }
    void clear() noexcept { ic1 = ic2 = 0.0; }
};

enum class EqType : int {
    Bell, LowShelf, HighShelf, LowCut12, LowCut24, LowCut48, HighCut12, HighCut24, HighCut48, Notch, BandPass, Tilt,
    LowCut96, HighCut96,  // appended (fx-filters, Slice EQ's 96 dB/octave): earlier types keep their numbers
    Count
};

// A parametric EQ band's coefficients: a bell, low or high shelf (eq.hpp's EqBand maths: exact gain, no bump),
// low or high cut at 12, 24, 48 or 96 dB/octave (Butterworth stages, Q_i = 1 / (2 cos((2i - 1) pi / 2N)), the last,
// sharpest stage's Q scaled by q / 0.707 so q above 0.707 adds a resonant peak at the corner), a notch, a
// band-pass (unity at the centre) or a tilt (a high shelf at the frequency, the whole band `db` / 2 down: -db/2
// below, +db/2 above). set() costs a tan and a pow or two and is skipped when nothing changed; the stages share
// one tan. The state lives outside (SvfState per stage and channel), so one set of coefficients serves a stereo
// pair or mid and side.
class EqFilter {
public:
    static constexpr int kMaxStages = 8;
    void set(EqType type, double hz, double db, double q, double sampleRate) noexcept {
        if (type == type_ && hz == hz_ && db == db_ && q == q_ && sampleRate == rate_) return;
        type_ = type, hz_ = hz, db_ = db, q_ = q, rate_ = sampleRate;
        double f = finiteOr0(hz);
        const double top = 0.49 * sampleRate;
        f = f < 10.0 ? 10.0 : (f > top ? top : f);
        double d = finiteOr0(db);
        d = d < -48.0 ? -48.0 : (d > 24.0 ? 24.0 : d);
        double qq = finiteOr0(q);
        qq = qq < 0.1 ? 0.1 : (qq > 40.0 ? 40.0 : qq);
        const double g = detTan(kPi * f / sampleRate);
        scale_ = 1.0;
        identity_ = false;
        switch (type) {
            case EqType::Bell:
            case EqType::LowShelf:
            case EqType::HighShelf:
            case EqType::Tilt: {
                identity_ = d == 0.0;  // no gain: the band is the input, exactly
                const double A = detPow(10.0, d / 40.0), rootA = detPow(10.0, d / 80.0), k = 1.0 / qq;
                stages_ = 1;
                if (type == EqType::Bell) {
                    const double kb = 1.0 / (qq * A);
                    mix_[0].set(g, kb, 1.0, kb * (A * A - 1.0), 0.0);
                } else if (type == EqType::LowShelf) {
                    mix_[0].set(g / rootA, k, 1.0, k * (A - 1.0), A * A - 1.0);
                } else {
                    mix_[0].set(g * rootA, k, A * A, k * (1.0 - A) * A, 1.0 - A * A);
                    if (type == EqType::Tilt) scale_ = 1.0 / A;  // 10^(-d/40): half the gain down
                }
                break;
            }
            case EqType::LowCut12: case EqType::LowCut24: case EqType::LowCut48:
            case EqType::HighCut12: case EqType::HighCut24: case EqType::HighCut48:
            case EqType::LowCut96: case EqType::HighCut96: {
                static constexpr double kQ2[1] = {0.70710678118654752};
                static constexpr double kQ4[2] = {0.54119610014619698, 1.30656296487637652};
                static constexpr double kQ8[4] = {0.50979557910415917, 0.60134488693504528, 0.89997622313641570,
                                                  2.56291544774150617};
                // 16th order: Q_i = 1 / (2 cos((2i - 1) pi / 32)), i = 1..8.
                static constexpr double kQ16[8] = {0.50241928618815568, 0.52249861493968885, 0.56694403481635769, 0.64682178335999008,
                                                   0.7881546234512502, 1.0606776859903471, 1.7224470982383342, 5.1011486186891553};
                const bool low = type == EqType::LowCut12 || type == EqType::LowCut24 || type == EqType::LowCut48 ||
                                 type == EqType::LowCut96;
                const int order = (type == EqType::LowCut12 || type == EqType::HighCut12) ? 2
                                  : (type == EqType::LowCut24 || type == EqType::HighCut24) ? 4
                                  : (type == EqType::LowCut96 || type == EqType::HighCut96) ? 16 : 8;
                const double* qs = order == 2 ? kQ2 : order == 4 ? kQ4 : order == 8 ? kQ8 : kQ16;
                stages_ = order / 2;
                for (int i = 0; i < stages_; ++i) {
                    double sq = qs[i];
                    if (i == stages_ - 1) sq *= qq / 0.70710678118654752;
                    const double k = 1.0 / sq;
                    if (low) mix_[i].set(g, k, 1.0, -k, -1.0);
                    else mix_[i].set(g, k, 0.0, 0.0, 1.0);
                }
                break;
            }
            case EqType::Notch: {
                const double k = 1.0 / qq;
                stages_ = 1;
                mix_[0].set(g, k, 1.0, -k, 0.0);
                break;
            }
            default: {  // band-pass
                const double k = 1.0 / qq;
                stages_ = 1;
                mix_[0].set(g, k, 0.0, k, 0.0);
                break;
            }
        }
    }
    // One sample through the band, with `state` this channel's kMaxStages stage states. A caller may skip an
    // identity() band (and clear its state, so it starts clean when it gains a gain again).
    double process(SvfState* state, double x) const noexcept {
        double y = x;
        for (int i = 0; i < stages_; ++i) y = state[i].process(mix_[i], y);
        return y * scale_;
    }
    bool identity() const noexcept { return identity_; }
    int stages() const noexcept { return stages_; }
    // Stage i's coefficients and the gain after the last stage, for a caller running process()'s arithmetic on
    // several channels at once (the built-in EQ's stereo bands, two-wide).
    const SvfMix& stage(int i) const noexcept { return mix_[i]; }
    double scale() const noexcept { return scale_; }
    // |H|^2 at the frequency whose tan(pi f / rate) is t (precompute t per display frequency).
    double magnitude2(double t) const noexcept {
        if (identity_) return 1.0;
        double m = scale_ * scale_;
        for (int i = 0; i < stages_; ++i) m *= mix_[i].magnitude2(t);
        return m;
    }

private:
    SvfMix mix_[kMaxStages];
    int stages_ = 1;
    double scale_ = 1.0;
    bool identity_ = true;
    EqType type_ = EqType::Count;
    double hz_ = -1, db_ = 0, q_ = -1, rate_ = -1;  // what set() last worked out
};

}  // namespace caw::lib
