// caw_bench's reference workload (`caw_bench SECONDS 300`–`310`): a fixed DSP loop timed next to each device, so
// a cost ceiling means "cost relative to the reference" and a busy machine slows both alike (docs/performance.md).
#pragma once

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <ctime>

namespace caw::bench {

// The reference's µs per second of audio on the x86 box where the ceilings were set (2026-11-19, idle), timed in
// interleaved chunks as RelativeCost times it (a long run alone reads about 1640: chunks start with colder caches).
// A device's cost relative to the reference, times this, reads in that box's µs, so the ceilings keep their numbers.
inline constexpr double kReferenceUs = 1800.0;

// The calling thread's CPU time where the platform has it (POSIX CLOCK_THREAD_CPUTIME_ID), so time the scheduler
// gives other processes is not counted; elsewhere the steady wall clock. A std::chrono clock.
struct CpuClock {
    using duration = std::chrono::nanoseconds;
    using rep = duration::rep;
    using period = duration::period;
    using time_point = std::chrono::time_point<CpuClock>;
    static constexpr bool is_steady = true;
    static time_point now() noexcept {
#if defined(CLOCK_THREAD_CPUTIME_ID)
        timespec ts{};
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
        return time_point(duration(static_cast<rep>(ts.tv_sec) * 1000000000 + ts.tv_nsec));
#else
        return time_point(std::chrono::duration_cast<duration>(std::chrono::steady_clock::now().time_since_epoch()));
#endif
    }
};

// How many interleaved reference and device runs each case takes; the best of each is kept.
inline constexpr int kRuns = 9;

namespace detail {
// One 64-frame stereo block: noise through a biquad low-pass, a tanh and a 16,384-frame delay line (128 KB), so
// the loop has a device's mix of arithmetic, a transcendental and memory traffic. Not inlined, like a process().
[[gnu::noinline]] inline float referenceBlock(uint32_t& seed, double* z, float* delay, uint32_t& pos) {
    constexpr double b0 = 0.0039160, b1 = 0.0078320, b2 = 0.0039160, a1 = -1.8153396, a2 = 0.8310036;  // 1 kHz, Q 0.7
    float acc = 0;
    for (int i = 0; i < 64; ++i) {
        for (int c = 0; c < 2; ++c) {
            seed = seed * 1664525u + 1013904223u;
            const double x = static_cast<double>(seed >> 8) / 8388608.0 - 1.0;
            double* s = z + 4 * c;  // x1, x2, y1, y2
            const double y = b0 * x + b1 * s[0] + b2 * s[1] - a1 * s[2] - a2 * s[3];
            s[1] = s[0];
            s[0] = x;
            s[3] = s[2];
            s[2] = y;
            const float shaped = std::tanh(static_cast<float>(3.0 * y));
            float* line = delay + 16384 * c;
            const float echo = line[(pos + 16384 - 9973) & 16383];
            line[pos] = shaped + 0.5f * echo;
            acc += echo;
        }
        pos = (pos + 1) & 16383;
    }
    return acc;
}
}  // namespace detail

// The reference's state, kept between chunks (static: no allocation, so a bench counting bytes never sees it).
struct ReferenceState {
    double z[8] = {};
    float delay[2 * 16384] = {};
    uint32_t seed = 1, pos = 0;
};
inline ReferenceState& referenceState() {
    static ReferenceState s;
    return s;
}

// Seconds of thread CPU time the reference takes for `blocks` 64-frame stereo blocks.
inline double referenceSeconds(int64_t blocks) {
    static volatile float sink = 0;  // keeps the loop from being optimised away
    (void)sink;
    ReferenceState& s = referenceState();
    float acc = 0;
    const auto t0 = CpuClock::now();
    for (int64_t b = 0; b < blocks; ++b) acc += detail::referenceBlock(s.seed, s.z, s.delay, s.pos);
    const double t = std::chrono::duration<double>(CpuClock::now() - t0).count();
    sink = acc;
    return t;
}

// The reference's µs of CPU per second of 48 kHz stereo audio, one run of `seconds`.
inline double referenceUs(double seconds) {
    const int64_t blocks = static_cast<int64_t>(seconds * 48000.0 / 64);
    return referenceSeconds(blocks) * 1e6 / seconds;
}

// Times a device against the reference, interleaved finely: in each run, every kChunk device blocks the reference
// plays as many blocks, timed apart, so both share the same moments of load. A run's ratio is the device's total
// time over the reference's; the best of kRuns runs is kept, in kReferenceUs units (the calibration box's µs per
// second of audio). Use: begin() before a run's block loop, tick(b) first in each block, end() after the loop.
class RelativeCost {
public:
    static constexpr int kChunk = 32;  // 32 blocks of 64 frames: about 43 ms of audio between reference chunks

    void begin() {
        dev_ = ref_ = 0;
        t0_ = CpuClock::now();
    }
    void tick(int64_t block) {
        if (block % kChunk != 0) return;
        const auto t1 = CpuClock::now();
        dev_ += std::chrono::duration<double>(t1 - t0_).count();
        ref_ += referenceSeconds(kChunk);
        t0_ = CpuClock::now();
    }
    void end() {
        dev_ += std::chrono::duration<double>(CpuClock::now() - t0_).count();
        if (ref_ > 0) best_ = std::min(best_, dev_ / ref_);
    }
    double us() const { return best_ * kReferenceUs; }

private:
    CpuClock::time_point t0_{};
    double dev_ = 0, ref_ = 0, best_ = 1e30;
};

}  // namespace caw::bench
