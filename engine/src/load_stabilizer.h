// The audio callback's synthetic load: keeps its core busy for a share of each period so the CPU governor holds its clock (after Oboe's StabilizedCallback).
#pragma once

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

    // The callback that started at `startNs` (steady clock) with `frames` at `rate`: the steady-clock time until
    // which to keep the core busy (at or before startNs: not at all). Callbacks are counted from an epoch, so
    // the ideal start of each is known; an early one (the last epoch was a late callback) starts a new epoch.
    int64_t deadline(int64_t startNs, int frames, int rate, double share = kShare) noexcept {
        if (frames <= 0 || rate <= 0 || !(share > 0.0)) {
            reset();
            return startNs;
        }
        // A new epoch: the first callback, an early one, one an hour of frames on (the products stay in range), or
        // one more than a second late (a stalled or rerouted stream: start over rather than spin nothing for long).
        if (frames_ == 0 || frames_ > int64_t{rate} * 3600) {
            epochNs_ = startNs;
            frames_ = 0;
        }
        const int64_t ideal = frames_ * 1'000'000'000 / rate;
        int64_t late = startNs - epochNs_ - ideal;
        if (late < 0 || late > 1'000'000'000) {
            epochNs_ = startNs;
            frames_ = 0;
            late = 0;
        }
        frames_ += frames;
        const int64_t period = int64_t{frames} * 1'000'000'000 / rate;
        return startNs + static_cast<int64_t>(static_cast<double>(period) * (share > 1.0 ? 1.0 : share)) - late;
    }

    // Not stabilizing (stopped, behind the app, a hint session took over): the next callback starts an epoch.
    void reset() noexcept { frames_ = 0; }

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
};

// What the stabilizer did in the callback last seen, for caw_audio_threads' "stabilizer": Off (not used here: not
// Android, the Battery buffer, or a performance hint session is on), Idle (it would run, but nothing plays or the
// app is behind another), On (it kept the core busy).
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
