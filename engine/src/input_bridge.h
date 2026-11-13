// The input bridge: hands a separate capture device's frames to the output callback; missing input is silence.
#pragma once

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <iterator>
#include <memory>
#include <thread>

#include "audio_input.h"

namespace caw {

// The output and the input are two devices (docs/engine.md, "Audio input and recording"): the output's clock runs
// the engine, and the input only feeds it. The capture callback pushes into this single-producer, single-consumer
// ring; the output callback pulls one chunk at a time (one per block it renders), after beginCallback. Whatever is not there when the output asks (the input is
// closed, starting, starved, silenced or disconnected) is silence, so the output never waits for the input and
// never changes because of it.
//
// Drift: the two clocks differ by up to a few hundred ppm, so the output reads the ring at a slightly changing
// rate (4-point Hermite interpolation between frames), steered by a slow PI loop on the smoothed fill so the fill,
// and with it the input's delay, stays at `prime` frames: no gaps, splices or creeping delay in normal running.
// The read rate moves at most kMaxAdjust from 1.
//
// Discontinuities: the output starts reading once `prime` frames are queued and fades in over kFade frames; when
// the input runs dry its last frame fades out over kFade frames into silence, and it waits for `prime` again (a
// real gap: the capture stopped). When the queue passes `prime + slack` anyway (the output stalled while capture
// ran on, or a drift beyond kMaxAdjust), the read position jumps back to `prime` through a kFade-frame crossfade.
// Non-finite input becomes 0.
//
// Threads: open() and close() on the control thread while the capture callback is not running (before its device
// starts, after it is uninitialised); push() on the capture thread; pull() on the output thread, which may run
// at any time. Nothing here allocates, locks or does I/O after construction.
class InputBridge {
public:
    static constexpr int kMaxFrames = 512;          // per pull (the output callback's chunk)
    static constexpr int kRingSamples = 1 << 16;    // all channels (2 channels: about 0.68 s at 48 kHz)
    static constexpr int kFade = 64;
    static constexpr double kMaxAdjust = 0.002;     // 2000 ppm

    InputBridge()
        : ring_(new float[kRingSamples]()), out_(new float[static_cast<size_t>(kMaxFrames) * kMaxInputChannels]()) {}

    // Control thread, the capture stopped. `prime` and `slack` in frames; `stallFrames` the starved run after
    // which stalled() says so; `rate` the engine's sample rate (the drift loop's time constants).
    void open(int channels, int prime, int slack, int64_t stallFrames, int rate = 48000) noexcept {
        close();
        ch_ = std::clamp(channels, 1, kMaxInputChannels);
        capFrames_ = kRingSamples / ch_;
        prime_ = std::clamp(prime, 4, capFrames_ / 2);
        maxFill_ = std::min<int64_t>(static_cast<int64_t>(prime_) + std::max(slack, 1), capFrames_ - 4);
        stallFrames_ = std::max<int64_t>(stallFrames, 1);
        rate_ = std::max(rate, 1000);
        w_.store(0, std::memory_order_relaxed);
        r_.store(0, std::memory_order_relaxed);
        idx_ = 1;  // x[-1] is frame 0
        frac_ = 0.0;
        xf_ = 0;
        priming_ = true;
        delivered_ = false;
        fadeIn_ = 0;
        tailLeft_ = 0;
        std::fill(std::begin(held_), std::end(held_), 0.0f);
        avg_ = prime_;
        integ_ = 0.0;
        ratio_.store(1.0, std::memory_order_relaxed);
        delay_.store(static_cast<double>(prime_), std::memory_order_relaxed);
        starved_.store(0, std::memory_order_relaxed);
        pushed_.store(0, std::memory_order_relaxed);
        underruns_.store(0, std::memory_order_relaxed);
        dropped_.store(0, std::memory_order_relaxed);
        skipped_.store(0, std::memory_order_relaxed);
        missing_.store(0, std::memory_order_relaxed);
        open_.store(true);  // sequentially consistent: pull() sees the fields above once it sees this
    }

    // Control thread, the capture stopped: pull() gives no input from its next call; returns once no pull() is
    // still inside.
    void close() noexcept {
        open_.store(false);
        while (inPull_.load()) std::this_thread::yield();  // at most one output chunk
    }

    // Capture thread: `frames` interleaved frames of channels(). A full ring drops the newest (counted).
    void push(const float* in, int frames) noexcept {
        if (!in || frames <= 0 || !open_.load(std::memory_order_acquire)) return;
        const uint64_t w = w_.load(std::memory_order_relaxed);
        const uint64_t r = r_.load(std::memory_order_acquire);
        const int64_t room = capFrames_ - static_cast<int64_t>(w - r);
        const int n = static_cast<int>(std::clamp<int64_t>(frames, 0, std::max<int64_t>(room, 0)));
        for (int i = 0; i < n; ++i) {
            float* dst = ring_.get() + static_cast<size_t>((w + i) % static_cast<uint64_t>(capFrames_)) * ch_;
            const float* src = in + static_cast<size_t>(i) * ch_;
            for (int c = 0; c < ch_; ++c) dst[c] = src[c];
        }
        if (n < frames) dropped_.fetch_add(frames - n, std::memory_order_relaxed);
        pushed_.fetch_add(frames, std::memory_order_relaxed);
        w_.store(w + static_cast<uint64_t>(n), std::memory_order_release);
    }

    // Output thread, at the start of each output callback of `frames` frames: the drift loop samples the fill once
    // here, at the callback's first pull, not at every pull (the fill falls through a callback as its blocks pull,
    // so an average over the pulls would read about half a callback low and hold the delay that much high). Without
    // it (a caller that never calls it), every pull samples the fill.
    void beginCallback(int frames) noexcept {
        if (frames <= 0 || !open_.load(std::memory_order_relaxed)) return;
        perCallback_ = true;
        cbFrames_ += frames;
    }

    // Output thread: the input for the next `frames` (at most kMaxFrames) frames, interleaved, with its channel
    // count in `channels`; nullptr and 0 when the bridge is closed. Missing frames are silence.
    const float* pull(int frames, int& channels) noexcept {
        channels = 0;
        if (frames <= 0 || frames > kMaxFrames) return nullptr;
        inPull_.store(true);  // before open_ is read (both sequentially consistent): close() waits this out
        if (!open_.load()) {
            inPull_.store(false, std::memory_order_release);
            return nullptr;
        }
        const int ch = ch_;
        float* out = out_.get();
        const uint64_t w = w_.load(std::memory_order_acquire);
        if (priming_ && static_cast<int64_t>(w - idx_) >= prime_ + 1) {
            // Enough queued: start `prime` frames behind the newest (older frames are late), fading in.
            idx_ = w - static_cast<uint64_t>(prime_);
            frac_ = 0.0;
            xf_ = 0;
            priming_ = false;
            delivered_ = true;
            fadeIn_ = kFade;
            avg_ = prime_;
            cbFrames_ = 0;  // the loop starts with the next callback
        }
        int n = 0;
        if (!priming_) {
            const double fill = static_cast<double>(static_cast<int64_t>(w - idx_)) - frac_;
            if (fill > static_cast<double>(maxFill_) && xf_ == 0) {
                // Far behind (the output stalled, or drift beyond the loop's reach): back to the starting fill,
                // crossfading from where it was.
                skipped_.fetch_add(static_cast<int64_t>(fill) - prime_, std::memory_order_relaxed);
                oIdx_ = idx_;
                oFrac_ = frac_;
                idx_ = w - static_cast<uint64_t>(prime_);
                frac_ = 0.0;
                xf_ = kFade;
                avg_ = prime_;
                cbFrames_ = 0;
            } else if (!perCallback_) {
                steer(fill, frames);
            } else if (cbFrames_ > 0) {  // the callback's first pull: the fill as the callback starts
                steer(fill, static_cast<int>(std::min<int64_t>(cbFrames_, rate_)));
                cbFrames_ = 0;
            }
            const double ratio = ratio_.load(std::memory_order_relaxed);
            for (; n < frames; ++n) {
                if (static_cast<int64_t>(w - idx_) < 3) break;  // x[2] not there yet: ran dry
                float* dst = out + static_cast<size_t>(n) * ch;
                float g = 1.0f;
                if (fadeIn_ > 0) g = static_cast<float>(kFade - fadeIn_--) / kFade;
                if (xf_ > 0) {
                    const float b = static_cast<float>(kFade - xf_) / kFade;
                    for (int c = 0; c < ch; ++c)
                        dst[c] = g * (b * sample(idx_, frac_, c, ch) + (1.0f - b) * sample(oIdx_, oFrac_, c, ch));
                    advance(oIdx_, oFrac_, ratio);
                    --xf_;
                } else {
                    for (int c = 0; c < ch; ++c) dst[c] = g * sample(idx_, frac_, c, ch);
                }
                advance(idx_, frac_, ratio);
            }
            if (n < frames) {  // ran dry: the last frame fades out, then wait for the starting fill again
                const float* last = n > 0 ? out + static_cast<size_t>(n - 1) * ch : nullptr;
                for (int c = 0; c < ch; ++c) tail_[c] = last ? last[c] : held_[c];
                tailLeft_ = kFade;
                priming_ = true;
                xf_ = 0;
                underruns_.fetch_add(1, std::memory_order_relaxed);
            } else if (n > 0) {
                const float* last = out + static_cast<size_t>(n - 1) * ch;
                for (int c = 0; c < ch; ++c) held_[c] = last[c];
            }
        }
        for (int i = n; i < frames; ++i) {  // silence, after what is left of a fade-out
            float* dst = out + static_cast<size_t>(i) * ch;
            const float g = tailLeft_ > 0 ? static_cast<float>(--tailLeft_) / kFade : 0.0f;
            for (int c = 0; c < ch; ++c) dst[c] = tail_[c] * g;
        }
        if (delivered_ && n < frames) missing_.fetch_add(frames - n, std::memory_order_relaxed);
        if (n > 0) starved_.store(0, std::memory_order_relaxed);
        else starved_.fetch_add(frames, std::memory_order_relaxed);
        // What the capture may overwrite: everything before the oldest frame still read (x[-1]).
        const uint64_t keep = (xf_ > 0 ? std::min(idx_, oIdx_) : idx_);
        r_.store(keep > 0 ? keep - 1 : 0, std::memory_order_release);
        inPull_.store(false, std::memory_order_release);
        channels = ch;
        return out;
    }

    // Any thread.
    bool isOpen() const noexcept { return open_.load(std::memory_order_relaxed); }
    // Open, and the output has had no input for at least stallFrames (the capture stopped delivering).
    bool stalled() const noexcept { return isOpen() && starved_.load(std::memory_order_relaxed) >= stallFrames_; }
    int channels() const noexcept { return isOpen() ? ch_ : 0; }
    int prime() const noexcept { return prime_; }
    int64_t pushed() const noexcept { return pushed_.load(std::memory_order_relaxed); }
    int64_t underruns() const noexcept { return underruns_.load(std::memory_order_relaxed); }
    int64_t dropped() const noexcept { return dropped_.load(std::memory_order_relaxed); }
    int64_t skipped() const noexcept { return skipped_.load(std::memory_order_relaxed); }
    // Output frames given as silence (or a fade) since the input first delivered: the gaps a take has.
    int64_t missing() const noexcept { return missing_.load(std::memory_order_relaxed); }
    // The read rate against the output's clock (1 + the drift it follows) and the smoothed fill (the delay, frames).
    double ratio() const noexcept { return ratio_.load(std::memory_order_relaxed); }
    double delay() const noexcept { return delay_.load(std::memory_order_relaxed); }

private:
    // Output thread: the fill's error drives the read rate. A one-pole smooths the capture's bursts (tau 0.1 s);
    // a PI loop with its poles at about 0.3 rad/s, critically damped, holds the mean fill at `prime` (a 500 ppm
    // step settles in about 15 s, about 30 frames off on the way).
    void steer(double fill, int frames) noexcept {
        const double dt = static_cast<double>(frames) / rate_;
        avg_ += std::min(1.0, dt / 0.1) * (fill - avg_);
        const double err = avg_ - prime_;
        const double kp = 0.6 / rate_, ki = 0.09 / rate_;
        integ_ = std::clamp(integ_ + ki * err * dt, -kMaxAdjust, kMaxAdjust);
        ratio_.store(1.0 + std::clamp(kp * err + integ_, -kMaxAdjust, kMaxAdjust), std::memory_order_relaxed);
        delay_.store(avg_, std::memory_order_relaxed);
    }

    static void advance(uint64_t& idx, double& frac, double ratio) noexcept {
        frac += ratio;
        const double whole = std::floor(frac);
        idx += static_cast<uint64_t>(whole);
        frac -= whole;
    }

    float at(uint64_t i, int c, int ch) const noexcept {
        const float v = ring_[static_cast<size_t>(i % static_cast<uint64_t>(capFrames_)) * ch + c];
        return std::isfinite(v) ? v : 0.0f;
    }

    // 4-point, 3rd-order Hermite between frames idx and idx + 1 (exactly frame idx at frac 0).
    float sample(uint64_t idx, double frac, int c, int ch) const noexcept {
        const float xm1 = at(idx - 1, c, ch), x0 = at(idx, c, ch), x1 = at(idx + 1, c, ch), x2 = at(idx + 2, c, ch);
        if (frac == 0.0) return x0;
        const float t = static_cast<float>(frac);
        const float c1 = 0.5f * (x1 - xm1);
        const float c2 = xm1 - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
        const float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
        return ((c3 * t + c2) * t + c1) * t + x0;
    }

    std::unique_ptr<float[]> ring_, out_;
    int ch_ = 1, capFrames_ = kRingSamples, prime_ = 4, rate_ = 48000;
    int64_t maxFill_ = 4, stallFrames_ = 1;
    std::atomic<uint64_t> w_{0}, r_{0};
    std::atomic<bool> open_{false}, inPull_{false};
    // output thread only
    uint64_t idx_ = 1, oIdx_ = 1;
    double frac_ = 0.0, oFrac_ = 0.0, avg_ = 0.0, integ_ = 0.0;
    int xf_ = 0;
    bool priming_ = true, delivered_ = false, perCallback_ = false;
    int64_t cbFrames_ = 0;  // output frames since the drift loop last sampled the fill (beginCallback)
    int fadeIn_ = 0, tailLeft_ = 0;
    float tail_[kMaxInputChannels] = {}, held_[kMaxInputChannels] = {};
    // counters and readings
    std::atomic<int64_t> starved_{0}, pushed_{0}, underruns_{0}, dropped_{0}, skipped_{0}, missing_{0};
    std::atomic<double> ratio_{1.0}, delay_{0.0};
};

}  // namespace caw
