// Following an incoming MIDI clock: 24 ppqn ticks to a tempo estimate that rides over jitter, and Start, Continue,
// Stop and Song Position Pointer to transport actions. Pure and deterministic (no clock of its own, no allocation).
#pragma once

#include <cstdint>

namespace caw {

class ClockFollower {
public:
    enum class Action : uint8_t { None, Tick, Start, Continue, Stop, Locate };
    static constexpr int kWindow = 48;                 // ticks the tempo is fitted over (two beats)
    static constexpr int kLockTicks = 12;              // ticks before an estimate is given (half a beat)
    static constexpr int64_t kGapNs = 1'000'000'000;   // a tick this long after the last starts a new fit (< 2.5 BPM)
    static constexpr double kMinBpm = 10.0, kMaxBpm = 999.0;

    // One byte of the incoming stream at `ns` (any monotonic clock, nanoseconds). Real-time bytes (0xF8..0xFF) may
    // come between a Song Position Pointer's data bytes, as MIDI 1.0 allows; any other status byte cancels it.
    Action feed(uint8_t byte, int64_t ns) noexcept;
    void reset() noexcept;

    // The tempo the ticks give, in quarter notes a minute: a least-squares line through the last kWindow tick
    // times against their tick numbers, so random jitter averages out and a tempo change is followed within the
    // window. 0 before kLockTicks ticks (or after a gap).
    double bpm() const noexcept { return bpm_; }
    bool locked() const noexcept { return bpm_ > 0; }
    // Start or Continue was the last transport message (not Stop).
    bool running() const noexcept { return running_; }
    // The last Song Position Pointer, in sixteenth steps (MIDI beats), 0 after Start.
    int songPosition() const noexcept { return spp_; }
    // Where the master is, in steps: the song position plus the ticks since Start or Continue (6 a step). Per MIDI
    // 1.0, the first tick after Start or Continue is the song position itself, so it counts from there.
    double positionSteps() const noexcept { return spp_ + (ticksRun_ > 0 ? (ticksRun_ - 1) / 6.0 : 0.0); }
    int64_t lastTickNs() const noexcept { return count_ > 0 ? last_ : -1; }

private:
    void tick(int64_t ns) noexcept;
    void fit() noexcept;
    int64_t idx_[kWindow] = {};  // tick numbers (a dropped tick leaves a gap) and their times
    int64_t t_[kWindow] = {};
    int count_ = 0, head_ = 0;
    int64_t last_ = 0, lastIdx_ = 0;
    double bpm_ = 0;
    bool running_ = false;
    int spp_ = 0;
    int64_t ticksRun_ = 0;
    int sppWant_ = 0;  // data bytes a Song Position Pointer still needs (2, 1, 0)
    uint8_t sppLsb_ = 0;
};

}  // namespace caw
