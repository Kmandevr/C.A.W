// Following an incoming MIDI clock: a least-squares tempo over the last two beats of ticks, and the transport bytes.
#include "midi_clock.h"

#include <algorithm>
#include <cmath>

namespace caw {

void ClockFollower::reset() noexcept { *this = ClockFollower{}; }

ClockFollower::Action ClockFollower::feed(uint8_t b, int64_t ns) noexcept {
    if (b >= 0xF8) {
        switch (b) {
            case 0xF8: tick(ns); if (running_) ++ticksRun_; return Action::Tick;
            case 0xFA: running_ = true; spp_ = 0; ticksRun_ = 0; return Action::Start;
            case 0xFB: running_ = true; ticksRun_ = 0; return Action::Continue;
            case 0xFC: running_ = false; return Action::Stop;
            default: return Action::None;
        }
    }
    if (b >= 0x80) {  // any other status: a Song Position Pointer starts, anything else cancels one
        sppWant_ = b == 0xF2 ? 2 : 0;
        return Action::None;
    }
    if (sppWant_ == 2) {
        sppLsb_ = b;
        sppWant_ = 1;
    } else if (sppWant_ == 1) {
        sppWant_ = 0;
        spp_ = sppLsb_ | (b << 7);
        ticksRun_ = 0;
        return Action::Locate;
    }
    return Action::None;
}

void ClockFollower::tick(int64_t ns) noexcept {
    if (count_ > 0 && (ns - last_ > kGapNs || ns < last_)) count_ = head_ = 0;  // a gap or time going back
    int64_t idx = 0;
    if (count_ > 0) {
        // A tick that took about twice the expected time is a dropped one: its number skips, so the fit holds.
        const double period = bpm_ > 0 ? 60e9 / (24.0 * bpm_) : 0.0;
        const double gap = static_cast<double>(ns - last_);
        const int64_t step = period > 0 ? std::max<int64_t>(1, std::llround(gap / period)) : 1;
        idx = lastIdx_ + (step > 4 ? 1 : step);
    }
    idx_[head_] = idx;
    t_[head_] = ns;
    head_ = (head_ + 1) % kWindow;
    if (count_ < kWindow) ++count_;
    last_ = ns;
    lastIdx_ = idx;
    fit();
}

void ClockFollower::fit() noexcept {
    if (count_ < kLockTicks) {
        bpm_ = 0;
        return;
    }
    // Relative to the newest tick, so the sums stay small and exact enough in double.
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (int k = 0; k < count_; ++k) {
        const double x = static_cast<double>(idx_[k] - lastIdx_);
        const double y = static_cast<double>(t_[k] - last_);
        sx += x;
        sy += y;
        sxx += x * x;
        sxy += x * y;
    }
    const double n = count_;
    const double den = n * sxx - sx * sx;
    if (!(den > 0)) return;
    const double nsPerTick = (n * sxy - sx * sy) / den;
    const double bpm = nsPerTick > 0 ? 60e9 / (24.0 * nsPerTick) : 0.0;
    bpm_ = bpm >= kMinBpm && bpm <= kMaxBpm ? bpm : 0.0;
}

}  // namespace caw
