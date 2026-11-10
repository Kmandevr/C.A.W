// C.A.W. Library: 2x oversampling by polyphase IIR half-band filters (no latency), header-only, allocation-free.
#pragma once

#include <cstdint>

#include "../detmath.hpp"

namespace caw::lib {

// A half-band low-pass split into two all-pass branches (the polyphase IIR half-band of Valenzuela and
// Constantinides, "Digital signal processing schemes for efficient interpolation and decimation", IEE Proc. G,
// 1983): H(z) = (A0(z^2) + z^-1 A1(z^2)) / 2, each branch a chain of first-order all-passes in z^2, so at the low
// rate every section is y = a (x - y1) + x1. The coefficients come from that paper's elliptic design, worked out
// at construction for `coefficients` (even) sections and a transition band `transition` (a fraction of the high
// rate, below 0.25): more sections or a wider transition give a deeper stop band. Original code; nothing here is
// taken from another library. IIR all-passes have no latency to declare (the phase bends near the top octave).
class HalfBandDesign {
public:
    static constexpr int kMax = 12;
    HalfBandDesign(int coefficients = 8, double transition = 0.04) noexcept {
        n_ = coefficients < 2 ? 2 : (coefficients > kMax ? kMax : coefficients);
        n_ &= ~1;
        double t = transition < 1e-4 ? 1e-4 : (transition > 0.24 ? 0.24 : transition);
        // The elliptic modulus k and nome q for the transition band.
        double k = detTan((1.0 - 2.0 * t) * kPi / 4.0);
        k *= k;
        const double kk = detPow(1.0 - k * k, 0.25);
        const double e = 0.5 * (1.0 - kk) / (1.0 + kk), e2 = e * e, e4 = e2 * e2;
        const double q = e * (1.0 + e4 * (2.0 + e4 * (15.0 + 150.0 * e4)));
        const int order = n_ * 2 + 1;
        for (int i = 0; i < n_; ++i) {
            const int c = i + 1;
            double num = 0.0, den = 0.0;
            for (int m = 0, sign = 1; m < 32; ++m, sign = -sign)
                num += sign * detPow(q, static_cast<double>(m * (m + 1))) * detSin((2 * m + 1) * c * kPi / order);
            for (int m = 1, sign = -1; m < 32; ++m, sign = -sign)
                den += sign * detPow(q, static_cast<double>(m * m)) * detCos(2.0 * m * c * kPi / order);
            num *= detPow(q, 0.25);
            den = 1.0 + 2.0 * den;
            const double w = num * 2.0 / den, w2 = w * w;  // num / (den / 2)
            const double x = detPow((1.0 - w2 * k) * (1.0 - w2 / k), 0.5) / (1.0 + w2);
            a_[i] = (1.0 - x) / (1.0 + x);
        }
    }
    int count() const noexcept { return n_; }
    double coefficient(int i) const noexcept { return a_[i]; }

private:
    int n_ = 8;
    double a_[kMax] = {};
};

// One chain of first-order all-passes (a branch): coefficients a[0], a[2], ... or a[1], a[3], ...
class AllpassChain {
public:
    void set(const HalfBandDesign& d, int first) noexcept {
        n_ = 0;
        for (int i = first; i < d.count(); i += 2) a_[n_++] = d.coefficient(i);
    }
    double process(double x) noexcept {
        for (int i = 0; i < n_; ++i) {
            const double y = a_[i] * (x - y_[i]) + x_[i];
            x_[i] = x;
            y_[i] = y < 1e-25 && y > -1e-25 ? 0.0 : y;
            x = y_[i];
        }
        return x;
    }
    void clear() noexcept {
        for (int i = 0; i < n_; ++i) x_[i] = y_[i] = 0.0;
    }

private:
    double a_[HalfBandDesign::kMax / 2] = {}, x_[HalfBandDesign::kMax / 2] = {}, y_[HalfBandDesign::kMax / 2] = {};
    int n_ = 0;
};

// 2x up and down for one channel: up(x, out) writes the two high-rate samples of one input sample (images of
// the input above the old Nyquist are removed), down(in) takes two high-rate samples and returns one low-rate
// sample (what lay above the low rate's Nyquist removed). Use a nonlinearity between them.
class Oversampler2x {
public:
    explicit Oversampler2x(const HalfBandDesign& d = HalfBandDesign()) noexcept { set(d); }
    void set(const HalfBandDesign& d) noexcept {
        up0_.set(d, 0);
        up1_.set(d, 1);
        down0_.set(d, 0);
        down1_.set(d, 1);
    }
    void up(double x, double out[2]) noexcept {
        out[0] = up0_.process(x);
        out[1] = up1_.process(x);
    }
    double down(const double in[2]) noexcept {
        // y[m] = (A0 on the even samples v[2m] + A1 on the odd ones, one high-rate sample later: v[2m - 1]) / 2.
        const double a = down0_.process(in[0]);
        const double b = down1_.process(held_);
        held_ = in[1];
        return 0.5 * (a + b);
    }
    void clear() noexcept {
        up0_.clear();
        up1_.clear();
        down0_.clear();
        down1_.clear();
        held_ = 0.0;
    }

private:
    AllpassChain up0_, up1_, down0_, down1_;
    double held_ = 0.0;
};

}  // namespace caw::lib
