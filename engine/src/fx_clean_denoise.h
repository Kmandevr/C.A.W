// Preen's Denoise core, shared by the live variant and the offline clip pass: noise profile (learned or tracked by minimum statistics), decision-directed Wiener gains, smoothing.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "caw/library/fastmath.hpp"
#include "fx_clean_dsp.h"

// Original code (C.A.W. is Apache-2.0) from the published methods, none of them patented today:
// - noise power per bin: learned (the mean of the frames played while Learn is on) or tracked (Adaptive) by
//   minimum statistics: the minimum of a smoothed periodogram over about 1.5 s, kept in 4 sub-windows, times a fixed
//   bias of 2 (Martin, IEEE TSAP 9(5), 2001, simplified: no adaptive smoothing or bias correction);
// - the gain: the decision-directed a-priori SNR (Ephraim and Malah, IEEE TASSP 32(6), 1984; a = 0.95, floored at
//   -25 dB) and its Wiener gain xi / (1 + xi), floored at -Reduction;
// - against musical noise: the gains smoothed across bins (a 1-2-1 kernel) and over time (falling slower than
//   rising), and an onset (the frame's energy jumping over its recent mean) lets the gains up by Transient keep.
// The gain stage is one function (rawGains): a voice model (an RNNoise-like network, an open owner question) would
// replace it as another `model`, leaving the STFT, the smoothing and the controls as they are.

namespace caw::fx::clean {

class DenoiseCore {
public:
    static constexpr int kSubs = 4;           // minimum statistics' sub-windows
    static constexpr double kBias = 2.0;      // its fixed bias compensation
    static constexpr double kDd = 0.95;       // decision-directed weight
    static constexpr double kXiMin = 0.0031622776601683794;  // -25 dB

    struct Settings {
        double floor = 0.25;       // the gain floor (dbToGain(-Reduction))
        double sens = 1.0;         // noise estimate multiplier
        double smoothing = 0.5;
        double low = 20, high = 20000;  // Hz
        double transient = 0.3;
        bool adaptive = true;
        bool listen = false;
    };

    bool prepare(uint32_t maxBins) {
        try {
            for (int c = 0; c < 2; ++c) {
                for (auto* v : {&s_[c], &cur_[c], &prevA_[c], &g_[c], &noise_[c]}) v->assign(maxBins, 0.0f);
                sub_[c].assign(static_cast<size_t>(maxBins) * kSubs, 0.0f);
            }
            tmp_.assign(maxBins, 0.0f);
        } catch (...) {
            return false;
        }
        return true;
    }
    // A new window (or the start): every running estimate starts again.
    void start(uint32_t n, double rate) noexcept {
        n_ = n;
        bins_ = n / 2 + 1;
        rate_ = rate;
        hopSec_ = (n / 4) / rate;
        alpha_ = detExp(-hopSec_ / 0.1);
        subLen_ = std::max<uint32_t>(1, static_cast<uint32_t>(0.375 / hopSec_ + 0.5));
        clear();
    }
    void clear() noexcept {
        for (int c = 0; c < 2; ++c) {
            for (auto* v : {&s_[c], &cur_[c], &prevA_[c], &noise_[c]}) std::fill(v->begin(), v->end(), 0.0f);
            std::fill(g_[c].begin(), g_[c].end(), 1.0f);
            std::fill(sub_[c].begin(), sub_[c].end(), 3.0e38f);
        }
        subAt_ = subCount_ = 0;
        frames_ = 0;
        eSlow_ = 0.0;
    }
    uint32_t bins() const noexcept { return bins_; }
    double hopSeconds() const noexcept { return hopSec_; }
    const float* noise(int c) const noexcept { return noise_[c].data(); }
    const float* gains(int c) const noexcept { return g_[c].data(); }

    // Power of bin k of side c.
    static double power(const Bins& b, int c, uint32_t k) noexcept {
        return c == 0 ? b.lr[k] * b.lr[k] + b.li[k] * b.li[k] : b.rr[k] * b.rr[k] + b.ri[k] * b.ri[k];
    }

    // Tracks the noise by minimum statistics (every frame, also while a profile is used, so turning Adaptive on
    // finds a settled estimate).
    void track(const Bins& b) noexcept {
        const bool first = frames_ == 0;
        ++frames_;
        const bool roll = ++subCount_ >= subLen_;
        for (int c = 0; c < 2; ++c) {
            float* s = s_[c].data();
            float* cur = cur_[c].data();
            float* sub = sub_[c].data();
            for (uint32_t k = 0; k < bins_; ++k) {
                const double p = power(b, c, k);
                const double sm = first ? p : p + (s[k] - p) * alpha_;
                s[k] = static_cast<float>(sm);
                cur[k] = first ? s[k] : std::min(cur[k], s[k]);
                if (roll) {
                    sub[k * kSubs + subAt_] = cur[k];
                    cur[k] = s[k];
                }
            }
        }
        if (roll) subCount_ = 0, subAt_ = (subAt_ + 1) % kSubs;
    }
    // The tracked noise power of bin k of side c.
    double tracked(int c, uint32_t k) const noexcept {
        const float* sub = sub_[c].data() + static_cast<size_t>(k) * kSubs;
        float m = cur_[c][k];
        for (int u = 0; u < kSubs; ++u) m = std::min(m, sub[u]);
        return kBias * m;
    }

    // Raw gains for this frame into g (both sides), from `profile` (per-bin noise power for this window, both sides;
    // null: the tracked estimate) or nothing at all (no profile and not adaptive: unity).
    void rawGains(const Bins& b, const Settings& st, const float* const* profile) noexcept {
        // At their ends (20 Hz, 20 kHz) the limits are off: every bin from DC to Nyquist is cleaned.
        const uint32_t lowBin = st.low <= 20.0 ? 0 : static_cast<uint32_t>(std::max(0.0, std::ceil(st.low * n_ / rate_)));
        const double hb = st.high >= 20000.0 ? bins_ - 1.0 : std::floor(st.high * n_ / rate_);
        const uint32_t highBin = hb < 0 ? 0 : static_cast<uint32_t>(std::min<double>(hb, bins_ - 1));
        double e = 0.0;
        for (int c = 0; c < 2; ++c) {
            float* g = g_[c].data();
            float* prevA = prevA_[c].data();
            float* nz = noise_[c].data();
            for (uint32_t k = 0; k < bins_; ++k) {
                const double p = power(b, c, k);
                e += p;
                double lambda = st.adaptive ? tracked(c, k) : (profile ? profile[c][k] : 0.0);
                lambda *= st.sens;
                nz[k] = static_cast<float>(lambda);
                double gain = 1.0;
                if (lambda > 1e-30 && k >= lowBin && k <= highBin) {
                    const double gamma = p / lambda;
                    double xi = kDd * prevA[k] / lambda + (1.0 - kDd) * std::max(gamma - 1.0, 0.0);
                    xi = std::max(xi, kXiMin);
                    gain = xi / (1.0 + xi);
                }
                prevA[k] = static_cast<float>(gain * gain * p);
                tmp_[k] = static_cast<float>(gain);
            }
            // Across bins: a 1-2-1 kernel, weighted by Smoothing and by how far the gain is down (a bin the signal
            // holds keeps its gain; isolated noise bins are spread out); then the floor (so Reduction 0 is unity).
            const double sf = st.smoothing;
            for (uint32_t k = 0; k < bins_; ++k) {
                const double a = tmp_[k > 0 ? k - 1 : 0], m = tmp_[k], z = tmp_[k + 1 < bins_ ? k + 1 : k];
                const double sm = m + sf * (1.0 - m) * ((a + 2.0 * m + z) * 0.25 - m);
                g[k] = static_cast<float>(std::max(sm, st.floor));
                if (k < lowBin || k > highBin) g[k] = 1.0f;
            }
        }
        frameEnergy_ = e;
    }

    // The onset weight of this frame (0..1): its energy over the recent mean (updated here).
    double onset() noexcept {
        const double e = frameEnergy_;
        const double r = e / (eSlow_ + 1e-20);
        eSlow_ = e + (eSlow_ - e) * 0.8;
        return clampd((r - 2.0) / 6.0, 0.0, 1.0);
    }

    // Applies gains `g` (both sides) to the bins: with Transient keep's lift by `onset`, or their complement
    // (Listen: what is removed).
    static void apply(Bins& b, const float* const* g, double keep, bool listen) noexcept {
        for (uint32_t k = 0; k < b.count; ++k) {
            double gl = g[0][k], gr = g[1][k];
            gl += (1.0 - gl) * keep;
            gr += (1.0 - gr) * keep;
            if (listen) gl = 1.0 - gl, gr = 1.0 - gr;
            b.lr[k] *= gl, b.li[k] *= gl;
            b.rr[k] *= gr, b.ri[k] *= gr;
        }
    }

    float* gainsMutable(int c) noexcept { return g_[c].data(); }

private:
    std::vector<float> s_[2], cur_[2], sub_[2], prevA_[2], g_[2], noise_[2], tmp_;
    uint32_t n_ = 2048, bins_ = 1025, subLen_ = 1, subAt_ = 0, subCount_ = 0;
    uint64_t frames_ = 0;
    double rate_ = 48000, hopSec_ = 0.01, alpha_ = 0.9, eSlow_ = 0, frameEnergy_ = 0;
};

// Smooths gains over time (causal, live): `held` is last frame's smoothed gains, `g` this frame's raw (both
// replaced by the result). Falling gains move with `fall`, rising ones with `rise` (each the previous value's
// weight). Unity in stays unity.
inline void smoothInTime(float* held, float* g, uint32_t bins, double fall, double rise) noexcept {
    for (uint32_t k = 0; k < bins; ++k) {
        const double now = g[k], was = held[k];
        const double c = now < was ? fall : rise;
        const double v = now + (was - now) * c;
        held[k] = g[k] = static_cast<float>(v);
    }
}

}  // namespace caw::fx::clean
