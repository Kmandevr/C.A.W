// A monophonic pitch tracker for effects on the audio thread: YIN on a decimated copy of the input, its lags spread over control steps.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

// Original code (C.A.W. is Apache-2.0) from the paper: A. de Cheveigné and H. Kawahara, "YIN, a fundamental
// frequency estimator for speech and music", JASA 111(4), 2002 (steps 2-5: the difference function, its cumulative
// mean normalised form, the absolute threshold and parabolic interpolation). The Tuner (builtin_fx_meters.cpp) runs
// the same steps all at once while a page watches it; this one runs continuously for an effect, so its work is spread
// evenly: the input is low-passed (two one-poles at about 1.9 kHz) and decimated to about 8 kHz into a ring, and each
// step() (one per 16-frame control step, so the result is the same at any block size) works out a few lags of the
// current analysis. A full analysis takes maxLag / kLagsPerStep steps (about 10 ms at 48 kHz), then the next one
// starts from the newest samples. No allocation: fixed arrays.

namespace caw::fx {

class PitchTracker {
public:
    static constexpr uint32_t kRing = 1024;      // decimated samples kept (a power of two)
    static constexpr uint32_t kMaxWindow = 256;  // the difference function's window
    static constexpr uint32_t kMaxLag = 256;
    static constexpr uint32_t kLagsPerStep = 4;

    // `lowHz`..`highHz`: the pitches it looks for (lowHz at least about 35 Hz).
    void setup(double sampleRate, double lowHz, double highHz) noexcept {
        decim_ = std::max(1, static_cast<int>(sampleRate / 8000.0 + 0.5));
        fs_ = sampleRate / decim_;
        window_ = std::min<uint32_t>(kMaxWindow, static_cast<uint32_t>(0.024 * fs_));
        maxLag_ = std::min<uint32_t>(kMaxLag - 2, static_cast<uint32_t>(fs_ / lowHz));
        minLag_ = std::max<uint32_t>(2, static_cast<uint32_t>(fs_ / highHz));
        lp_ = static_cast<float>(1.0 - std::exp(-2.0 * 3.14159265358979323846 * 1900.0 / sampleRate));
        clear();
    }
    void clear() noexcept {
        std::fill(ring_, ring_ + kRing, 0.0f);
        a_ = b_ = acc_ = 0.0f;
        count_ = 0;
        pos_ = 0;
        tau_ = 0;
        voiced_ = false;
        hz_ = 0.0, confidence_ = 0.0;
    }
    // One input sample (the audio thread, per frame).
    void push(float x) noexcept {
        a_ += lp_ * (x - a_);
        b_ += lp_ * (a_ - b_);
        acc_ += b_;
        if (++count_ == decim_) {
            ring_[pos_] = acc_ / static_cast<float>(decim_);
            pos_ = (pos_ + 1) & (kRing - 1);
            acc_ = 0.0f;
            count_ = 0;
        }
    }
    // Part of the analysis (once per control step).
    void step() noexcept {
        if (tau_ == 0) {  // a new analysis: the newest samples
            const uint32_t need = window_ + maxLag_ + 1;
            double energy = 0.0;
            for (uint32_t i = 0; i < need; ++i) {
                x_[i] = ring_[(pos_ + kRing - need + i) & (kRing - 1)];
                if (i < window_) energy += static_cast<double>(x_[i]) * x_[i];
            }
            if (!(energy / window_ > 1e-7)) {  // below about -70 dBFS (or not finite): nothing to track
                voiced_ = false;
                confidence_ = 0.0;
                return;
            }
            dn_[0] = 1.0f;
            running_ = 0.0;
            tau_ = 1;
        }
        const uint32_t end = std::min(maxLag_ + 1, tau_ + kLagsPerStep - 1);
        for (; tau_ <= end; ++tau_) {
            float d = 0.0f;
            for (uint32_t j = 0; j < window_; ++j) {
                const float e = x_[j] - x_[j + tau_];
                d += e * e;
            }
            running_ += d;
            dn_[tau_] = running_ > 0.0 ? static_cast<float>(d * tau_ / running_) : 1.0f;
        }
        if (tau_ > maxLag_ + 1) {
            finish();
            tau_ = 0;
        }
    }
    bool voiced() const noexcept { return voiced_; }
    double hz() const noexcept { return hz_; }                  // the last voiced analysis's pitch
    double confidence() const noexcept { return confidence_; }  // 1 - d'(tau): 0..1

private:
    void finish() noexcept {
        uint32_t best = 0;
        for (uint32_t t = minLag_; t <= maxLag_; ++t)
            if (dn_[t] < kThreshold) {
                while (t + 1 <= maxLag_ && dn_[t + 1] < dn_[t]) ++t;
                best = t;
                break;
            }
        if (best == 0) {  // none under the threshold: the deepest dip, if it is clear enough
            float lowest = 1.0f;
            for (uint32_t t = minLag_; t <= maxLag_; ++t)
                if (dn_[t] < lowest) lowest = dn_[t], best = t;
            if (lowest > kFallback) best = 0;
        }
        if (best == 0) {
            voiced_ = false;
            confidence_ = 0.0;
            return;
        }
        double t = best;
        if (best > 1 && best < maxLag_ + 1) {
            const double l = dn_[best - 1], c = dn_[best], r = dn_[best + 1], den = l - 2.0 * c + r;
            if (den > 0.0) t += std::clamp(0.5 * (l - r) / den, -0.5, 0.5);
        }
        voiced_ = true;
        hz_ = fs_ / t;
        confidence_ = std::clamp(1.0 - static_cast<double>(dn_[best]), 0.0, 1.0);
    }

    static constexpr float kThreshold = 0.15f, kFallback = 0.3f;
    float ring_[kRing] = {};
    float x_[kMaxWindow + kMaxLag + 2] = {};
    float dn_[kMaxLag + 2] = {};
    float a_ = 0, b_ = 0, acc_ = 0, lp_ = 0.2f;
    int count_ = 0, decim_ = 6;
    uint32_t pos_ = 0, window_ = 192, maxLag_ = 114, minLag_ = 8, tau_ = 0;
    double fs_ = 8000.0, running_ = 0.0, hz_ = 0.0, confidence_ = 0.0;
    bool voiced_ = false;
};

}  // namespace caw::fx
