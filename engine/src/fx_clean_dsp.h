// Preen's and Hush's shared DSP: the streaming stereo STFT (sqrt-Hann WOLA, 75 % overlap), the quality tiers' windows, shared FFT tables and a small biquad.
#pragma once

#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/convolver.hpp"

namespace caw::fx::clean {

// The window of a quality tier (0 Eco, 1 Normal, 2 High; `monitor`: the armed-monitoring window) at a rate: 1,024,
// 2,048 and 4,096 (512 monitoring) at 44.1 or 48 kHz, doubled above 70 kHz and again above 140 kHz, halved below
// 32 kHz, so the time (21, 43, 85 and 11 ms) holds. The latency is exactly one window (Stft below).
inline uint32_t tierWindow(int tier, bool monitor, double rate) noexcept {
    uint32_t n = monitor ? 512u : (1024u << (tier < 0 ? 0 : (tier > 2 ? 2 : tier)));
    if (rate > 140000.0) n *= 4;
    else if (rate > 70000.0) n *= 2;
    else if (rate < 32000.0) n /= 2;
    return n;
}
inline uint32_t maxWindow(double rate) noexcept { return tierWindow(2, false, rate); }

// Read-only tables every instance shares (built on the control thread at an instance's prepare, under a lock, once
// per size; never on the audio thread): the FFT of `n` points and the periodic sqrt-Hann window of n.
struct SharedTables {
    lib::Fft fft;  // its transforms only read its members, so instances on several threads share it safely
    std::vector<double> window;
};
inline SharedTables* sharedTables(uint32_t n) {
    static std::mutex guard;
    static std::unique_ptr<SharedTables> tables[24];
    uint32_t bits = 0;
    while ((1u << bits) < n && bits < 23) ++bits;
    const std::lock_guard<std::mutex> lock(guard);
    if (!tables[bits]) {
        auto t = std::make_unique<SharedTables>();
        const uint32_t size = 1u << bits;
        t->fft.prepare(size);
        t->window.resize(size);
        for (uint32_t i = 0; i < size; ++i) t->window[i] = detSin(kPi * i / size);  // sqrt of the periodic Hann
        tables[bits] = std::move(t);
    }
    return tables[bits].get();
}

// One frame's spectra, bins 0..n/2 of each side (written by Stft before the callback, read back after it).
struct Bins {
    double *lr, *li, *rr, *ri;
    uint32_t count;  // n/2 + 1
    uint32_t n;      // the window
};

// A streaming stereo STFT: both sides in one complex FFT (left real, right imaginary, split by symmetry), a sqrt-Hann
// window on analysis and synthesis, a hop of a quarter window (their product sums to 2 at that overlap), so a
// callback that leaves the bins alone gives back the input exactly one window late (to rounding). Buffers are sized
// once (prepare, for the largest window); setSize picks any power of two up to it (audio thread: no allocation).
class Stft {
public:
    bool prepare(uint32_t maxN) {
        try {
            for (uint32_t n = 256, b = 8; n <= maxN && b < 24; n <<= 1, ++b) byBits_[b] = sharedTables(n);
            for (auto* v : {&inL_, &inR_, &accL_, &accR_}) v->assign(maxN, 0.0f);
            re_.assign(maxN, 0.0);
            im_.assign(maxN, 0.0);
            for (auto* v : {&lr_, &li_, &rr_, &ri_}) v->assign(maxN / 2 + 1, 0.0);
        } catch (...) {
            return false;
        }
        max_ = maxN;
        setSize(maxN);
        return true;
    }
    // A new window (a power of two from 256 to the prepared maximum): the buffers start silent again.
    void setSize(uint32_t n) noexcept {
        if (n < 256 || n > max_ || (n & (n - 1)) != 0) return;
        n_ = n;
        hop_ = n / 4;
        uint32_t bits = 0;
        while ((1u << bits) < n) ++bits;
        if (!byBits_[bits]) return;
        tables_ = byBits_[bits];  // found at prepare: no lock here
        clear();
    }
    void clear() noexcept {
        for (auto* v : {&inL_, &inR_, &accL_, &accR_}) std::fill(v->begin(), v->end(), 0.0f);
        pos_ = 0;
        count_ = 0;
    }
    uint32_t size() const noexcept { return n_; }
    uint32_t hop() const noexcept { return hop_; }

    // n frames in and out; each completed hop runs `frame(Bins&)`, which may change the bins in place.
    template <class F>
    void process(const float* inL, const float* inR, float* outL, float* outR, uint32_t n, F&& frame) noexcept {
        const uint32_t mask = n_ - 1;
        float* il = inL_.data();
        float* ir = inR_.data();
        float* al = accL_.data();
        float* ar = accR_.data();
        for (uint32_t i = 0; i < n; ++i) {
            outL[i] = al[pos_];
            outR[i] = ar[pos_];
            al[pos_] = ar[pos_] = 0.0f;
            il[pos_] = static_cast<float>(finiteOr0(inL[i]));
            ir[pos_] = static_cast<float>(finiteOr0(inR[i]));
            pos_ = (pos_ + 1) & mask;
            if (++count_ == hop_) {
                count_ = 0;
                runFrame(frame);
            }
        }
    }

private:
    template <class F>
    void runFrame(F&& frame) noexcept {
        const uint32_t n = n_, mask = n - 1, half = n / 2;
        const double* w = tables_->window.data();
        double* re = re_.data();
        double* im = im_.data();
        for (uint32_t j = 0; j < n; ++j) {
            const uint32_t at = (pos_ + j) & mask;  // pos_ is the oldest frame
            re[j] = inL_[at] * w[j];
            im[j] = inR_[at] * w[j];
        }
        tables_->fft.forward(re, im);
        double *lr = lr_.data(), *li = li_.data(), *rr = rr_.data(), *ri = ri_.data();
        for (uint32_t k = 0; k <= half; ++k) {
            const uint32_t m = (n - k) & mask;
            lr[k] = 0.5 * (re[k] + re[m]);
            li[k] = 0.5 * (im[k] - im[m]);
            rr[k] = 0.5 * (im[k] + im[m]);
            ri[k] = 0.5 * (re[m] - re[k]);
        }
        Bins b{lr, li, rr, ri, half + 1, n};
        frame(b);
        for (uint32_t k = 0; k <= half; ++k) {
            const uint32_t m = (n - k) & mask;
            re[k] = lr[k] - ri[k];
            im[k] = li[k] + rr[k];
            if (k != 0 && k != half) {
                re[m] = lr[k] + ri[k];
                im[m] = rr[k] - li[k];
            }
        }
        tables_->fft.inverse(re, im);
        const double scale = 1.0 / (2.0 * n);  // the inverse's n, and the windows' overlap sum (2)
        for (uint32_t j = 0; j < n; ++j) {
            const uint32_t at = (pos_ + j) & mask;
            accL_[at] += static_cast<float>(re[j] * w[j] * scale);
            accR_[at] += static_cast<float>(im[j] * w[j] * scale);
        }
    }

    std::vector<float> inL_, inR_, accL_, accR_;  // the last window of input; the overlap-add (both circular)
    std::vector<double> re_, im_, lr_, li_, rr_, ri_;
    SharedTables* tables_ = nullptr;
    SharedTables* byBits_[24] = {};
    uint32_t max_ = 0, n_ = 0, hop_ = 0, pos_ = 0, count_ = 0;
};

// A transposed direct-form biquad (RBJ cookbook low- and high-pass), flushing tiny states.
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    void set(bool high, double hz, double q, double rate) noexcept {
        const double w = 2.0 * kPi * (hz < 0.45 * rate ? hz : 0.45 * rate) / rate;
        const double c = detCos(w), alpha = detSin(w) / (2.0 * q), a0 = 1.0 + alpha;
        const double k = high ? (1.0 + c) * 0.5 : (1.0 - c) * 0.5;
        b0 = k / a0;
        b1 = (high ? -2.0 * k : 2.0 * k) / a0;
        b2 = k / a0;
        a1 = -2.0 * c / a0;
        a2 = (1.0 - alpha) / a0;
    }
    double run(double x) noexcept {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    void flush() noexcept {
        if (z1 < 1e-25 && z1 > -1e-25) z1 = 0.0;
        if (z2 < 1e-25 && z2 > -1e-25) z2 = 0.0;
        if (!(z1 == z1) || !(z2 == z2)) z1 = z2 = 0.0;
    }
    void clear() noexcept { z1 = z2 = 0.0; }
};

inline double clampd(double x, double lo, double hi) noexcept { return x < lo ? lo : (x > hi ? hi : x); }

}  // namespace caw::fx::clean

namespace caw::fx::clean {

// The offline frame transforms (the clip pass): frame `l`/`r` (n contiguous samples each) windowed into one FFT and
// split into the two sides' bins; and back: the bins recombined and inverse-transformed, re/im then holding the
// left/right frame windowed again and scaled for overlap-add at a quarter-window hop.
inline void analyzeFrame(SharedTables& t, uint32_t n, const float* l, const float* r, double* re, double* im, Bins& b) noexcept {
    const double* w = t.window.data();
    for (uint32_t j = 0; j < n; ++j) re[j] = l[j] * w[j], im[j] = r[j] * w[j];
    t.fft.forward(re, im);
    const uint32_t mask = n - 1, half = n / 2;
    for (uint32_t k = 0; k <= half; ++k) {
        const uint32_t m = (n - k) & mask;
        b.lr[k] = 0.5 * (re[k] + re[m]);
        b.li[k] = 0.5 * (im[k] - im[m]);
        b.rr[k] = 0.5 * (im[k] + im[m]);
        b.ri[k] = 0.5 * (re[m] - re[k]);
    }
}
inline void synthesizeFrame(SharedTables& t, uint32_t n, const Bins& b, double* re, double* im) noexcept {
    const uint32_t mask = n - 1, half = n / 2;
    for (uint32_t k = 0; k <= half; ++k) {
        const uint32_t m = (n - k) & mask;
        re[k] = b.lr[k] - b.ri[k];
        im[k] = b.li[k] + b.rr[k];
        if (k != 0 && k != half) re[m] = b.lr[k] + b.ri[k], im[m] = b.rr[k] - b.li[k];
    }
    t.fft.inverse(re, im);
    const double* w = t.window.data();
    const double scale = 1.0 / (2.0 * n);
    for (uint32_t j = 0; j < n; ++j) re[j] *= w[j] * scale, im[j] *= w[j] * scale;
}

}  // namespace caw::fx::clean
