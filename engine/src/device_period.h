// Device periods from the numbers a backend reports: the smallest WASAPI allows (#237, Low latency) and the frames an output really queues (#241).
#pragma once

#include <cstdint>

namespace caw {

// The floor under every "smallest" period this works out: 128 frames, about 2.7 ms at 48 kHz, two engine blocks.
// [Fact, Microsoft Learn "Low Latency Audio", updated 2025-03-26, read 2026-11-17] Windows' inbox HDAudio driver
// takes 128 to 480 frames. [Assumption] below about 128 frames each callback's fixed cost (the wake-up, the mix
// graph's planning, the FIFO) dominates and Low latency would trade dropouts for under a millisecond.
inline constexpr uint32_t kSmallestPeriodFloor = 128;

// The smallest shared-mode period IAudioClient3::InitializeSharedAudioStream takes that is at least [floor]: a
// multiple of [fundamental] from [min] to [max] ([Fact, Microsoft Learn IAudioClient3::InitializeSharedAudioStream,
// read 2026-11-17] "an integral multiple of ... pFundamentalPeriodInFrames ... greater than or equal to
// pMinPeriodInFrames and less than or equal to pMaxPeriodInFrames"). 0 when the numbers are unusable (no
// fundamental, min above max), so the caller asks nothing and keeps the backend's default.
inline uint32_t smallestSharedPeriod(uint32_t fundamental, uint32_t min, uint32_t max,
                                     uint32_t floor = kSmallestPeriodFloor) noexcept {
    if (fundamental == 0 || min == 0 || max < min) return 0;
    const uint32_t want = min > floor ? min : floor;
    const uint64_t up = (static_cast<uint64_t>(want) + fundamental - 1) / fundamental * fundamental;
    if (up <= max) return static_cast<uint32_t>(up);
    // The floor lies above the largest period: the largest legal one under max (max itself need not be a multiple).
    const uint32_t down = max / fundamental * fundamental;
    return down >= min ? down : 0;
}

// An exclusive-mode device period (100-nanosecond units, IAudioClient::GetDevicePeriod's minimum) as whole frames
// at [rate], rounded up so the period asked is never below the device's, and at least [floor]. 0 when unknown.
inline uint32_t exclusivePeriodFrames(int64_t hns, uint32_t rate, uint32_t floor = kSmallestPeriodFloor) noexcept {
    if (hns <= 0 || rate == 0) return 0;
    const uint64_t frames = (static_cast<uint64_t>(hns) * rate + 9'999'999) / 10'000'000;
    if (frames > 1u << 20) return 0;
    return frames < floor ? floor : static_cast<uint32_t>(frames);
}

// The frames the output queues ahead of the speaker, for the latency figures where no timestamp is known and the
// periods the status reports: AAudio's buffer size (AAudioStream_getBufferSizeInFrames, what is queued) where it is
// known (> 0), else every period the backend reports. On AAudio miniaudio's periods are the stream's whole buffer
// capacity ([Fact] miniaudio 0.11.25 source, ma_device_init_by_type__aaudio: periodCount = capacity / frames per
// callback, or one period of the capacity), of which a stream queues only its buffer size, so counting the
// capacity overstated the delay at the fixed 1024-frame size (#241).
inline int64_t queuedOutputFrames(int32_t aaudioBufferFrames, uint32_t period, uint32_t periods) noexcept {
    if (aaudioBufferFrames > 0) return aaudioBufferFrames;
    return static_cast<int64_t>(period) * (periods > 0 ? periods : 1);
}

// The queue in whole callbacks of [callbackFrames] (at least 1), rounded; [periods] when the callback is unknown.
inline int32_t queuedPeriods(int64_t queued, int32_t callbackFrames, uint32_t periods) noexcept {
    if (callbackFrames <= 0 || queued <= 0) return static_cast<int32_t>(periods);
    const int64_t n = (queued + callbackFrames / 2) / callbackFrames;
    return static_cast<int32_t>(n > 1 ? n : 1);
}

}  // namespace caw
