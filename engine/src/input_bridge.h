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
// ring; the output callback pulls one chunk at a time. Whatever is not there when the output asks (the input is
// closed, starting, starved, silenced or disconnected) is silence, so the output never waits for the input and
// never changes because of it.
//
// Fill: the output starts reading once `prime` frames are queued (refilling to it after any underrun), and when
// the two clocks drift so the queue passes `prime + slack` it skips back to `prime`, so the input's latency stays
// bounded. A resume fades in over kFade frames, and when the input runs dry its last frame fades out over kFade
// frames into the silence, so monitoring never clicks. Non-finite input becomes 0.
//
// Threads: open() and close() on the control thread while the capture callback is not running (before its device
// starts, after it is uninitialised); push() on the capture thread; pull() on the output thread, which may run
// at any time. Nothing here allocates, locks or does I/O after construction.
class InputBridge {
public:
    static constexpr int kMaxFrames = 512;          // per pull (the output callback's chunk)
    static constexpr int kRingSamples = 1 << 16;    // all channels (2 channels: about 0.68 s at 48 kHz)
    static constexpr int kFade = 64;

    InputBridge()
        : ring_(new float[kRingSamples]()), out_(new float[static_cast<size_t>(kMaxFrames) * kMaxInputChannels]()) {}

    // Control thread, the capture stopped. `prime` and `slack` in frames; `stallFrames` the starved run after
    // which stalled() says so.
    void open(int channels, int prime, int slack, int64_t stallFrames) noexcept {
        close();
        ch_ = std::clamp(channels, 1, kMaxInputChannels);
        capFrames_ = kRingSamples / ch_;
        prime_ = std::clamp(prime, 1, capFrames_ / 2);
        maxFill_ = std::min<int64_t>(static_cast<int64_t>(prime_) + std::max(slack, 1), capFrames_ - 1);
        stallFrames_ = std::max<int64_t>(stallFrames, 1);
        w_.store(0, std::memory_order_relaxed);
        r_.store(0, std::memory_order_relaxed);
        priming_ = true;
        fadeIn_ = 0;
        tailLeft_ = 0;
        std::fill(std::begin(held_), std::end(held_), 0.0f);
        starved_.store(0, std::memory_order_relaxed);
        pushed_.store(0, std::memory_order_relaxed);
        underruns_.store(0, std::memory_order_relaxed);
        dropped_.store(0, std::memory_order_relaxed);
        skipped_.store(0, std::memory_order_relaxed);
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
        uint64_t r = r_.load(std::memory_order_relaxed);
        const uint64_t w = w_.load(std::memory_order_acquire);
        int64_t avail = static_cast<int64_t>(w - r);
        if (avail > maxFill_) {  // the clocks drifted apart: back to the starting fill
            skipped_.fetch_add(avail - prime_, std::memory_order_relaxed);
            r = w - static_cast<uint64_t>(prime_);
            avail = prime_;
        }
        if (priming_ && avail >= prime_) {
            priming_ = false;
            fadeIn_ = kFade;
        }
        int n = 0;
        if (!priming_) {
            n = static_cast<int>(std::min<int64_t>(avail, frames));
            for (int i = 0; i < n; ++i) {
                const float* src = ring_.get() + static_cast<size_t>((r + i) % static_cast<uint64_t>(capFrames_)) * ch;
                float* dst = out + static_cast<size_t>(i) * ch;
                float g = 1.0f;
                if (fadeIn_ > 0) g = static_cast<float>(kFade - fadeIn_--) / kFade;
                for (int c = 0; c < ch; ++c) dst[c] = std::isfinite(src[c]) ? src[c] * g : 0.0f;
            }
            r += static_cast<uint64_t>(n);
            if (n < frames) {  // ran dry: the last frame fades out, then wait for the starting fill again
                const float* last = n > 0 ? out + static_cast<size_t>(n - 1) * ch : nullptr;
                for (int c = 0; c < ch; ++c) tail_[c] = last ? last[c] : held_[c];
                tailLeft_ = kFade;
                priming_ = true;
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
        if (n > 0) starved_.store(0, std::memory_order_relaxed);
        else starved_.fetch_add(frames, std::memory_order_relaxed);
        r_.store(r, std::memory_order_release);
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

private:
    std::unique_ptr<float[]> ring_, out_;
    int ch_ = 1, capFrames_ = kRingSamples, prime_ = 1;
    int64_t maxFill_ = 1, stallFrames_ = 1;
    std::atomic<uint64_t> w_{0}, r_{0};
    std::atomic<bool> open_{false}, inPull_{false};
    // output thread only
    bool priming_ = true;
    int fadeIn_ = 0, tailLeft_ = 0;
    float tail_[kMaxInputChannels] = {}, held_[kMaxInputChannels] = {};
    // counters
    std::atomic<int64_t> starved_{0}, pushed_{0}, underruns_{0}, dropped_{0}, skipped_{0};
};

}  // namespace caw
