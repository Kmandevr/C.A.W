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
    // The two branches of each direction run side by side (lane 0 the even branch, lane 1 the odd), each lane the
    // same arithmetic as an AllpassChain of its coefficients, so the two-wide vectors (GCC and Clang: SSE2 or NEON)
    // give the same bits as two chains one after the other (2026-11-11 performance pass).
    void set(const HalfBandDesign& d) noexcept {
        n_ = d.count() / 2;
        for (int i = 0; i < kStages; ++i)
            for (int lane = 0; lane < 2; ++lane) {
                const int k = 2 * i + lane;
                a_[i][lane] = i < n_ && k < d.count() ? d.coefficient(k) : 0.0;
            }
    }
    void up(double x, double out[2]) noexcept {
        const double in[2] = {x, x};
        run(up_, in, out);
    }
    double down(const double in[2]) noexcept {
        // y[m] = (A0 on the even samples v[2m] + A1 on the odd ones, one high-rate sample later: v[2m - 1]) / 2.
        const double both[2] = {in[0], held_};
        double out[2];
        run(down_, both, out);
        held_ = in[1];
        return 0.5 * (out[0] + out[1]);
    }
    // up() for each of x[0..n) into out[0..2n) (each x's two in turn), and down() for each pair of in[0..2n) into
    // out[0..n): the same arithmetic sample by sample, with the state held in locals over the block instead of
    // loaded and stored every sample (speed phase 4).
    void upBlock(const double* x, double* out, int n) noexcept { block<false>(x, out, n); }
    void downBlock(const double* in, double* out, int n) noexcept { block<true>(in, out, n); }
    void clear() noexcept {
        for (int i = 0; i < kStages; ++i)
            for (int lane = 0; lane < 2; ++lane) up_.x[i][lane] = up_.y[i][lane] = down_.x[i][lane] = down_.y[i][lane] = 0.0;
        held_ = 0.0;
    }

private:
    static constexpr int kStages = HalfBandDesign::kMax / 2;
    struct State {
        alignas(16) double x[kStages][2] = {}, y[kStages][2] = {};
    };
    // Each lane: y = a (x - y1) + x1 per stage, flushed below 1e-25, into the next stage (AllpassChain::process).
    void run(State& s, const double in[2], double out[2]) noexcept {
#if defined(__GNUC__)
        typedef double Pair __attribute__((vector_size(16)));
        const Pair tiny = {1e-25, 1e-25}, zero = {0.0, 0.0};
        Pair x = {in[0], in[1]};
        for (int i = 0; i < n_; ++i) {
            Pair a, x1, y1;
            __builtin_memcpy(&a, a_[i], sizeof a);
            __builtin_memcpy(&x1, s.x[i], sizeof x1);
            __builtin_memcpy(&y1, s.y[i], sizeof y1);
            Pair y = a * (x - y1) + x1;
            __builtin_memcpy(s.x[i], &x, sizeof x);
            y = ((y < tiny) & (y > -tiny)) ? zero : y;
            __builtin_memcpy(s.y[i], &y, sizeof y);
            x = y;
        }
        out[0] = x[0];
        out[1] = x[1];
#else
        for (int lane = 0; lane < 2; ++lane) {
            double x = in[lane];
            for (int i = 0; i < n_; ++i) {
                const double y = a_[i][lane] * (x - s.y[i][lane]) + s.x[i][lane];
                s.x[i][lane] = x;
                s.y[i][lane] = y < 1e-25 && y > -1e-25 ? 0.0 : y;
                x = s.y[i][lane];
            }
            out[lane] = x;
        }
#endif
    }
    template <bool Down>
    void block(const double* in, double* out, int n) noexcept {
#if defined(__GNUC__)
        switch (n_) {
            case 1: return blockN<1, Down>(in, out, n);
            case 2: return blockN<2, Down>(in, out, n);
            case 3: return blockN<3, Down>(in, out, n);
            case 4: return blockN<4, Down>(in, out, n);
            case 5: return blockN<5, Down>(in, out, n);
            default: return blockN<kStages, Down>(in, out, n);
        }
#else
        for (int f = 0; f < n; ++f) {
            if (Down) out[f] = down(in + 2 * f);
            else up(in[f], out + 2 * f);
        }
#endif
    }
#if defined(__GNUC__)
    // run() over a block with N stages (n_), its state in registers.
    template <int N, bool Down>
    void blockN(const double* in, double* out, int n) noexcept {
        typedef double Pair __attribute__((vector_size(16)));
        State& s = Down ? down_ : up_;
        const Pair tiny = {1e-25, 1e-25}, zero = {0.0, 0.0};
        Pair a[N], x1[N], y1[N];
        for (int i = 0; i < N; ++i) {
            __builtin_memcpy(&a[i], a_[i], sizeof(Pair));
            __builtin_memcpy(&x1[i], s.x[i], sizeof(Pair));
            __builtin_memcpy(&y1[i], s.y[i], sizeof(Pair));
        }
        double held = held_;
        for (int f = 0; f < n; ++f) {
            Pair x;
            if (Down) {
                x = Pair{in[2 * f], held};
                held = in[2 * f + 1];
            } else {
                x = Pair{in[f], in[f]};
            }
            for (int i = 0; i < N; ++i) {
                Pair y = a[i] * (x - y1[i]) + x1[i];
                x1[i] = x;
                y = ((y < tiny) & (y > -tiny)) ? zero : y;
                y1[i] = y;
                x = y;
            }
            if (Down) {
                out[f] = 0.5 * (x[0] + x[1]);
            } else {
                out[2 * f] = x[0];
                out[2 * f + 1] = x[1];
            }
        }
        for (int i = 0; i < N; ++i) {
            __builtin_memcpy(s.x[i], &x1[i], sizeof(Pair));
            __builtin_memcpy(s.y[i], &y1[i], sizeof(Pair));
        }
        if (Down) held_ = held;
    }
#endif
    alignas(16) double a_[kStages][2] = {};
    State up_, down_;
    double held_ = 0.0;
    int n_ = 4;
};

}  // namespace caw::lib
