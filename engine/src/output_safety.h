// The live output's last stage (API 35, #244): the mono check and the safety limiter, after Engine::process in the device callback only.
#pragma once

#include <cmath>

namespace caw {

// What the device callback does to the finished mix before it leaves for the device (device_render.h). Never in a
// render, an export, a freeze or a stem: Engine::process and the offline renderers don't run it, so what is saved
// is the mix as it was. One thread (the device's callback) uses it; nothing here allocates, locks or blocks.
//
// Mono check: both sides become their mean, (L + R) / 2, so a mix can be checked for what cancels in mono.
//
// Safety limiter: a gentle, zero-latency peak limiter for ears and speakers, stereo-linked. Its envelope follows
// the louder side's peak at once and falls back over kReleaseSeconds; below the knee (kKneeStart, -4 dBFS) the
// gain is exactly 1, so a quiet mix passes bit for bit. Above it the level is bent toward the ceiling (kCeiling,
// -1 dBFS) along k + (c - k)(1 - e^(-(e - k) / (c - k))), whose slope is 1 at the knee and which never reaches the
// ceiling, so the output stays under it whatever comes in. No look-ahead: it adds no latency, so the latency
// figures and the loopback ping are unchanged. A non-finite sample (a broken plug-in) is silenced. It sits after
// the master stage's own -0.2 dBFS limiter (engine.cpp), which every render keeps.
class OutputSafety {
public:
    static constexpr int kLimiter = 1;  // caw.h CAW_OUTPUT_LIMITER
    static constexpr int kMono = 2;     // caw.h CAW_OUTPUT_MONO
    static constexpr double kCeiling = 0.8912509381337456;   // -1 dBFS
    static constexpr double kKneeStart = 0.6309573444801932; // -4 dBFS
    static constexpr double kReleaseSeconds = 0.15;

    // `flags` (kLimiter | kMono) as the callback read them; `rate` the engine's sample rate.
    void process(float* left, float* right, int frames, int flags, double rate) noexcept {
        if ((flags & (kLimiter | kMono)) == 0) {
            env_ = 0;  // off: it starts fresh when it comes back on
            return;
        }
        if (rate != rate_) {
            rate_ = rate;
            release_ = rate > 0 ? std::exp(-1.0 / (kReleaseSeconds * rate)) : 0.0;
        }
        const bool mono = (flags & kMono) != 0, limit = (flags & kLimiter) != 0;
        for (int i = 0; i < frames; ++i) {
            double l = std::isfinite(left[i]) ? left[i] : 0.0, r = std::isfinite(right[i]) ? right[i] : 0.0;
            if (mono) l = r = 0.5 * (l + r);
            if (limit) {
                const double peak = std::fmax(std::fabs(l), std::fabs(r));
                env_ = peak > env_ ? peak : peak + (env_ - peak) * release_;
                if (env_ < 1e-30) env_ = 0;  // far under the knee: no subnormals
                if (env_ > kKneeStart) {
                    const double span = kCeiling - kKneeStart;
                    const double out = kKneeStart + span * (1.0 - std::exp(-(env_ - kKneeStart) / span));
                    const double g = out / env_;
                    l *= g;
                    r *= g;
                }
            }
            left[i] = static_cast<float>(l);
            right[i] = static_cast<float>(r);
        }
    }

    // The gain the limiter applies now (1 below the knee), for tests and the diagnostics.
    double gain() const noexcept {
        if (env_ <= kKneeStart) return 1.0;
        const double span = kCeiling - kKneeStart;
        return (kKneeStart + span * (1.0 - std::exp(-(env_ - kKneeStart) / span))) / env_;
    }

private:
    double env_ = 0, rate_ = 0, release_ = 0;
};

}  // namespace caw
