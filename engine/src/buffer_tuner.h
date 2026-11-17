// The output buffer's automatic size (#236), Oboe's LatencyTuner way: the smallest that plays without underruns, grown a burst at a time on one, shrunk after a long quiet stretch.
#pragma once

#include <algorithm>
#include <cstdint>

namespace caw {

// Pure and portable: the platform layer (audio_miniaudio.cpp, caw_audio_tune_buffer) feeds it the device's
// underrun count from the control thread and sets the size it returns (AAudioStream_setBufferSizeInFrames, never
// on the audio thread). Sizes are whole bursts between a floor and a ceiling (the stream's capacity).
//
// [Fact, Oboe main `src/common/LatencyTuner.cpp` and `include/oboe/LatencyTuner.h`, read 2026-11-17] Oboe's tuner
// sets its minimum, two bursts (kDefaultNumBursts), and adds one burst each time the stream's underrun count rises,
// up to a maximum (the capacity by default); it never shrinks. The floor here is the same two bursts
// (kFloorBursts). Here it may also shrink one burst after kShrinkSeconds without an underrun, but never back to a
// size that underran on this stream: a size that glitched once is not tried again until the device opens anew.
class BufferTuner {
public:
    static constexpr double kShrinkSeconds = 60.0;
    static constexpr int32_t kFloorBursts = 2;

    // A new stream: its burst (> 0), floor and ceiling in frames (the ceiling its capacity), and where to start
    // (the size remembered for this kind of output; 0: the floor). Returns the size to set.
    int32_t start(int32_t burst, int32_t floor, int32_t ceiling, int32_t initial, int64_t xruns) noexcept {
        burst_ = std::max<int32_t>(1, burst);
        floor_ = roundUp(std::max<int32_t>(burst_, floor));
        ceiling_ = std::max(floor_, ceiling > 0 ? ceiling / burst_ * burst_ : floor_);
        size_ = clamp(initial > 0 ? roundUp(initial) : floor_);
        lastXruns_ = xruns;
        quietSeconds_ = 0;
        badBelow_ = 0;
        started_ = true;
        return size_;
    }
    bool started() const noexcept { return started_; }
    int32_t size() const noexcept { return size_; }

    // Every second or so: the stream's underrun count since it opened (< 0: unknown) and the seconds since the last
    // call. Returns the new size to set, or 0 to leave it.
    int32_t update(int64_t xruns, double seconds) noexcept {
        if (!started_ || xruns < 0) return 0;
        if (xruns < lastXruns_) lastXruns_ = xruns;  // a counter that started again (a new stream)
        if (xruns > lastXruns_) {
            lastXruns_ = xruns;
            quietSeconds_ = 0;
            badBelow_ = std::max(badBelow_, size_);  // this size underran: never back to it or below
            const int32_t next = clamp(size_ + burst_);
            if (next == size_) return 0;
            size_ = next;
            return size_;
        }
        quietSeconds_ += std::max(0.0, seconds);
        if (quietSeconds_ < kShrinkSeconds) return 0;
        quietSeconds_ = 0;
        const int32_t next = clamp(size_ - burst_);
        if (next == size_ || next <= badBelow_) return 0;
        size_ = next;
        return size_;
    }

private:
    int32_t roundUp(int32_t n) const noexcept { return (n + burst_ - 1) / burst_ * burst_; }
    int32_t clamp(int32_t n) const noexcept { return std::clamp(n, floor_, ceiling_); }

    int32_t burst_ = 1, floor_ = 1, ceiling_ = 1, size_ = 0, badBelow_ = 0;
    int64_t lastXruns_ = 0;
    double quietSeconds_ = 0;
    bool started_ = false;
};

}  // namespace caw
