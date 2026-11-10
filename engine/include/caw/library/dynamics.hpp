// C.A.W. Library: dynamics kernels (soft-knee gain computer, envelope followers, a sliding minimum, true-peak estimate).
#pragma once

#include <cstdint>
#include <vector>

#include "../detmath.hpp"
#include "fastmath.hpp"

namespace caw::lib {

// A compressor's static curve in dB: below the knee the level passes, above it rises 1/ratio as fast, and across
// the knee (width `kneeDb`, centred on the threshold) a quadratic joins the two smoothly (the standard soft-knee
// curve, e.g. Giannoulis, Massberg and Reiss, "Digital Dynamic Range Compressor Design", JAES 2012). Returns the
// gain change in dB (0 or negative). ratio >= 1; a ratio of 1 changes nothing.
inline double compressorGainDb(double levelDb, double thresholdDb, double ratio, double kneeDb) noexcept {
    const double r = ratio < 1.0 ? 1.0 : ratio;
    const double w = kneeDb < 0.0 ? 0.0 : kneeDb;
    const double over = levelDb - thresholdDb;
    const double slope = 1.0 / r - 1.0;  // 0 .. -1
    if (2.0 * over <= -w) return 0.0;
    if (2.0 * over < w) {
        const double t = over + 0.5 * w;
        return slope * t * t / (2.0 * w);
    }
    return slope * over;
}

// An expander's (and gate's) curve in dB: above the threshold nothing changes; below it the level falls `ratio`
// times as fast (ratio 1: no change; a large ratio is a gate), with the same quadratic knee, and the gain change
// never goes below `floorDb` (the range: -80 is all but closed).
inline double expanderGainDb(double levelDb, double thresholdDb, double ratio, double kneeDb, double floorDb) noexcept {
    const double r = ratio < 1.0 ? 1.0 : ratio;
    const double w = kneeDb < 0.0 ? 0.0 : kneeDb;
    const double under = levelDb - thresholdDb;  // negative below the threshold
    const double slope = r - 1.0;
    double g;
    if (2.0 * under >= w) g = 0.0;
    else if (2.0 * under > -w) {
        const double t = under - 0.5 * w;
        g = -slope * t * t / (2.0 * w);
    } else g = slope * under;
    return g < floorDb ? floorDb : g;
}

// The one-pole coefficient that covers 1 - 1/e of a step in `seconds` (the usual attack/release time constant).
inline double timeCoefficient(double seconds, double sampleRate) noexcept {
    const double n = finiteOr0(seconds) * finiteOr0(sampleRate);
    return n > 0.0 ? detExp(-1.0 / n) : 0.0;
}

// A level follower with separate attack and release (one-pole each; set the coefficients with timeCoefficient):
// rises toward a larger input at the attack rate, falls toward a smaller one at the release rate.
class EnvelopeFollower {
public:
    void setCoefficients(double attack, double release) noexcept {
        attack_ = attack;
        release_ = release;
    }
    double process(double x) noexcept {
        const double c = x > y_ ? attack_ : release_;
        y_ = x + (y_ - x) * c;
        if (y_ < 1e-30) y_ = 0.0;  // no subnormal tail
        return y_;
    }
    double value() const noexcept { return y_; }
    void clear() noexcept { y_ = 0.0; }

private:
    double y_ = 0.0, attack_ = 0.0, release_ = 0.0;
};

// The smallest of the last `window` values pushed, in O(1) amortized per push (a monotonic queue in a ring that
// prepare() sets aside): what a look-ahead limiter holds its gain at.
class SlidingMinimum {
public:
    void prepare(uint32_t maxWindow) {
        cap_ = 1;
        while (cap_ < maxWindow + 2) cap_ <<= 1;
        idx_.assign(cap_, 0);
        val_.assign(cap_, 0.0);
        clear();
    }
    void clear() noexcept {
        head_ = tail_ = 0;
        n_ = 0;
    }
    // Pushes x and returns the minimum of the last `window` values (1 .. the prepared maximum).
    double push(double x, uint32_t window) noexcept {
        if (cap_ < 2) return x;
        if (window < 1) window = 1;
        if (window > cap_ - 2) window = cap_ - 2;
        const uint32_t mask = cap_ - 1;
        while (tail_ != head_ && val_[(tail_ - 1) & mask] >= x) --tail_;  // drop the larger ones behind it
        idx_[tail_ & mask] = n_;
        val_[tail_ & mask] = x;
        ++tail_;
        while (n_ - idx_[head_ & mask] >= window) ++head_;  // drop the ones out of the window
        ++n_;
        return val_[head_ & mask];
    }

private:
    std::vector<uint64_t> idx_;
    std::vector<double> val_;
    uint32_t cap_ = 0, head_ = 0, tail_ = 0;
    uint64_t n_ = 0;
};

// An estimate of the peak between samples (a "true peak", as on a meter after a DAC): the input interpolated at
// 4 times the rate by an 8-tap windowed sinc per phase (Hann window over +-4.5 samples, each phase normalized to
// unity at DC). process(x) returns the largest |value| between the samples 4 and 3 frames ago (both ends
// included), so the estimate lags the input by 4 frames. Within about 0.5 dB of the exact inter-sample peak for
// signals below 0.8 of Nyquist.
class TruePeak {
public:
    TruePeak() noexcept {
        for (int p = 1; p < 4; ++p) {
            double sum = 0.0;
            for (int j = 0; j < 8; ++j) {
                const double t = static_cast<double>(j) - 4.0 + 0.25 * p;  // distance to tap x[n - j]
                const double sinc = t == 0.0 ? 1.0 : detSin(kPi * t) / (kPi * t);
                const double w = 0.5 + 0.5 * detCos(kPi * t / 4.5);
                h_[p - 1][j] = sinc * w;
                sum += h_[p - 1][j];
            }
            for (int j = 0; j < 8; ++j) h_[p - 1][j] /= sum;
        }
    }
    double process(double x) noexcept {
        pos_ = (pos_ + 1) & 7;
        x_[pos_] = finiteOr0(x);
        double peak = abs(x_[(pos_ - 4) & 7]);
        const double next = abs(x_[(pos_ - 3) & 7]);
        peak = next > peak ? next : peak;
        for (int p = 0; p < 3; ++p) {
            double y = 0.0;
            for (int j = 0; j < 8; ++j) y += h_[p][j] * x_[(pos_ - j) & 7];
            y = abs(y);
            peak = y > peak ? y : peak;
        }
        return peak;
    }
    void clear() noexcept {
        for (double& v : x_) v = 0.0;
    }

private:
    static double abs(double v) noexcept { return v < 0.0 ? -v : v; }
    double h_[3][8] = {};
    double x_[8] = {};
    unsigned pos_ = 0;
};

}  // namespace caw::lib
