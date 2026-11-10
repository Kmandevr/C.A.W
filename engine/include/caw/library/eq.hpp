// C.A.W. Library: a three-band EQ (low shelf, mid bell, high shelf) on state-variable filters; header-only, allocation-free.
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

}  // namespace caw::lib
