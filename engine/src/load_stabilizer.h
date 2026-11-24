// The audio callback's synthetic load: keeps its core busy for a share of each period so the CPU governor holds its clock (after Oboe's StabilizedCallback).
#pragma once

#include <climits>
#include <cstdint>

#if (defined(__x86_64__) || defined(__i386__)) && (defined(__GNUC__) || defined(__clang__))
#include <immintrin.h>
#define CAW_STABILIZER_PAUSE() _mm_pause()
#elif (defined(__aarch64__) || defined(__arm__)) && (defined(__GNUC__) || defined(__clang__))
#define CAW_STABILIZER_PAUSE() __asm__ __volatile__("yield" ::: "memory")
#elif defined(_MSC_VER) && (defined(_M_ARM64) || defined(_M_ARM))
#include <intrin.h>
#define CAW_STABILIZER_PAUSE() __yield()
#elif defined(_MSC_VER)
#include <intrin.h>
#define CAW_STABILIZER_PAUSE() _mm_pause()
#else
#define CAW_STABILIZER_PAUSE() ((void)0)
#endif

namespace caw {

// Why: Android's CPU governors set a core's clock from how busy it was, and a callback that does its work in a
// fraction of its period and then waits looks idle, so its core's clock drops (the S22+ ran the callback's core at
// 634 MHz of 2.5 GHz, 2026-11-19, docs/performance.md). Where there is no performance hint session (ADPF), the
// callback keeps its core busy, after its real work, until `share` of its period from its ideal start: the same
// arithmetic as Oboe's StabilizedCallback (github.com/google/oboe src/common/StabilizedCallback.cpp, Apache-2.0,
// reimplemented here, not copied: docs/decisions.md). A callback that starts late spins that much less, and one
// whose work took the share or more spins not at all, so the stabilizer never makes a callback later than its
// own work did.
//
// Callback-only state, no allocation, lock or system call (steady_clock reads, as the callback's own timing).
// Portable arithmetic, so its rules are tested on every target; engine/platform decides where it runs.
class LoadStabilizer {
public:
    // Oboe's kPercentageOfCallbackToUse. [Inference from docs.kernel.org/scheduler/schedutil.html, read 2026-11-19]
    // schedutil asks for f = 1.25 u f_max with u frequency-invariant, so a core busy a share b of the time at clock
    // f is asked for 1.25 b f: 0.8 holds the clock where it is, and less lets it fall (a 60% load would let it sink
    // to the floor again). With 0.8 a burst of real work raises the clock and the stabilizer keeps it there while
    // playing instead of letting it sag between bursts. [Assumption] the S22+'s vendor governor behaves alike.
    static constexpr double kShare = 0.8;

    // Callbacks in a row that may spin nothing (each later than its share of the ideal period) before the next
    // starts a new epoch: the device's clock drifts from the steady clock (about 50 ppm moves the ideal starts a
    // whole 21 ms period in 7 minutes), or a stall shifted the stream, and lateness that stays is not lateness.
    static constexpr int kNoSpinResync = 8;
    static constexpr int kDriftWindow = 64;  // callbacks (about 1.4 s of 1024 frames at 48 kHz, 0.1 s of 96)

    // The callback that started at `startNs` (steady clock) with `frames` at `rate`: the steady-clock time until
    // which to keep the core busy (at or before startNs: not at all). Callbacks are counted from an epoch, so
    // the ideal start of each is known; an early one starts a new epoch, and so does a late one that stays late.
    int64_t deadline(int64_t startNs, int frames, int rate, double share = kShare) noexcept {
        if (frames <= 0 || rate <= 0 || !(share > 0.0)) {
            reset();
            return startNs;
        }
        const int64_t period = int64_t{frames} * 1'000'000'000 / rate;
        // A new epoch: the first callback, one early by more than jitter, one an hour of frames on (the products stay in range), one
        // more than a period late (a stalled or rerouted stream, or drift: start over rather than spin nothing for
        // long), or one after kNoSpinResync callbacks in a row that spun nothing.
        const bool fresh = frames_ == 0 || frames_ > int64_t{rate} * 3600 || noSpin_ >= kNoSpinResync;
        const int64_t late = fresh ? 0 : startNs - epochNs_ - frames_ * 1'000'000'000 / rate;
        if (fresh || late < -period / 16 || late > period) {
            // The callback that starts an epoch spins nothing: it may be one of a burst (stream priming, Android's
            // fixed-block adapter running two or three back to back), and its own start says nothing of when the
            // next is due, so a full share could make the next one late. The next on-time callback spins.
            epochNs_ = startNs;
            frames_ = frames;
            noSpin_ = 0;
            window_ = 0;
            minLate_ = INT64_MAX;
            return startNs;
        }
        // Drift: the earliest callback of each kDriftWindow is where the device's clock has the schedule now, so the
        // epoch follows it (one-off lateness leaves the earliest on time; lateness that every callback shares moves it).
        if (late < minLate_) minLate_ = late;
        if (++window_ >= kDriftWindow) {
            epochNs_ += minLate_;
            window_ = 0;
            minLate_ = INT64_MAX;
        }
        frames_ += frames;
        // Early by less than a sixteenth of a period is jitter: on time (and the drift window moves the epoch to it).
        const int64_t d = startNs + static_cast<int64_t>(static_cast<double>(period) * (share > 1.0 ? 1.0 : share)) - (late > 0 ? late : 0);
        noSpin_ = d > startNs ? 0 : noSpin_ + 1;
        return d;
    }

    // Battery (1.0.9 review): a near-idle project does its work in a sliver of each period, and its clock does not
    // matter, so holding a core near 80 % busy for it only spends the battery. The stabilizer is wanted only while
    // the callback's own work (before any spin) is a real share of its period: on when the smoothed share (about
    // 0.5 s) rises above kOnWork, off once it falls below kOffWork, and on at least kHoldNs each time it turns on or
    // a callback overruns its period (work of a whole period or more). The gap and the hold keep it from flapping:
    // a low clock makes the same work look up to about 4 times bigger (634 MHz of 2.5 GHz on the S22+), so it may
    // turn on at a low clock and then see a quarter of that once the clock is up: off is a quarter of on. The S22+'s
    // song8 took 6.3 ms of a 21.3 ms period at the low clock (0.30; about 0.075 at the top clock), so it turns on and
    // stays on; a project under 0.16 at the floor clock has room to spare there. [Assumption] thresholds to tune
    // with the owner's Benchmark (docs/performance.md).
    static constexpr double kOnWork = 0.16, kOffWork = 0.04;
    static constexpr int64_t kWorkTauNs = 500'000'000, kHoldNs = 2'000'000'000;

    // Heat (1.1.2, replacing 1.1.1's "only as far as the clock needs" and its heat backoff): the full kShare
    // whenever it is wanted, whatever the heat. 1.1.1 spun proportionally less while the recent peak work was under
    // a target of the period (0.5; 0.6 warm, 0.7 hot; none at critical), and by schedutil's 1.25 b f (above) that let
    // the governor lower the clock until the slowest callbacks took the target, so a burst of 2x (1.67x warm, 1.43x
    // hot) over the last few seconds' peak dropped out, and the meter swung as the clock moved (the owner's S22+ on
    // 1.1.1, 2026-11-24: dropouts at a 20-30 % meter, worse once warm; one track swinging 9-35 %). The governor model
    // in load_stabilizer_test.cpp shows the trade-off. Heat is the platform's to handle: it throttles the clock
    // itself (owner, 2026-11-24: "the system throttles, not the app"; docs/decisions.md).
    static constexpr double spinShare() noexcept { return kShare; }

    // The callback's own work this time (steady-clock ns from its start to before the spin): whether to spin.
    bool wanted(int64_t workNs, int frames, int rate) noexcept {
        if (frames <= 0 || rate <= 0) return on_;
        const int64_t period = int64_t{frames} * 1'000'000'000 / rate;
        if (period <= 0) return on_;
        double share = static_cast<double>(workNs) / static_cast<double>(period);
        share = share < 0.0 ? 0.0 : (share > 4.0 ? 4.0 : share);
        const double a = static_cast<double>(period) / static_cast<double>(kWorkTauNs);
        work_ = seeded_ ? work_ + (a > 1.0 ? 1.0 : a) * (share - work_) : share;
        seeded_ = true;
        holdNs_ = holdNs_ > period ? holdNs_ - period : 0;
        if (share >= 1.0 || (!on_ && work_ > kOnWork)) {
            on_ = true;
            holdNs_ = kHoldNs;
        } else if (on_ && holdNs_ == 0 && work_ < kOffWork) {
            on_ = false;
        }
        return on_;
    }
    // The smoothed work share wanted() decides on (caw_audio_threads' "stabilizer_work").
    double workShare() const noexcept { return work_; }
    // Nothing sounds: the next callback's work decides afresh, starting off.
    void resetLoad() noexcept {
        seeded_ = on_ = false;
        work_ = 0.0;
        holdNs_ = 0;
    }

    // Not stabilizing (stopped, behind the app, a hint session took over): the next callback starts an epoch.
    void reset() noexcept {
        frames_ = 0;
        noSpin_ = 0;
        window_ = 0;
        minLate_ = INT64_MAX;
    }

    // Keeps the calling thread busy until now() reaches deadlineNs; returns the nanoseconds it spun. `now` is the
    // callback's steady clock (a function object, so tests can drive it).
    template <class Now>
    static int64_t spinUntil(int64_t deadlineNs, Now&& now) noexcept {
        int64_t t = now();
        const int64_t from = t;
        while (t < deadlineNs) {
            for (int i = 0; i < 16; ++i) CAW_STABILIZER_PAUSE();
            t = now();
        }
        return t - from;
    }

private:
    int64_t epochNs_ = 0;
    int64_t frames_ = 0;  // frames since the epoch
    int noSpin_ = 0;      // callbacks in a row with no spin
    int window_ = 0;      // callbacks into this drift window
    int64_t minLate_ = INT64_MAX;  // the earliest lateness in it
    double work_ = 0.0;     // wanted: the smoothed share of each period the callback's own work took
    int64_t holdNs_ = 0;    // stays on at least this much longer
    bool seeded_ = false, on_ = false;
};

// What the stabilizer did in the callback last seen, for caw_audio_threads' "stabilizer": Off (not used here: not
// Android, the Battery buffer, or a performance hint session is on), Idle (it would run, but nothing plays, the
// app is behind another, or the callback's work is too small a share of its period for the clock to matter:
// LoadStabilizer::wanted), On (it kept the core busy).
enum class StabilizerState : uint8_t { Off = 0, Idle = 1, On = 2 };
inline const char* stabilizerStateName(StabilizerState s) noexcept {
    switch (s) {
        case StabilizerState::Idle: return "idle";
        case StabilizerState::On: return "on";
        case StabilizerState::Off: break;
    }
    return "off";
}

}  // namespace caw
