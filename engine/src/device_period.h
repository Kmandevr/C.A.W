// The smallest device period a backend allows (#237), worked out from the numbers it reports, for Low latency on WASAPI.
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

}  // namespace caw
