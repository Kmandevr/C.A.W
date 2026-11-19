// The audio callback's load stabilizer: its deadline arithmetic (Oboe's StabilizedCallback rules) and its spin.
#include <chrono>
#include <cstdint>

#include "load_stabilizer.h"
#include "test.h"

using caw::LoadStabilizer;

namespace {
constexpr int kRate = 48000;
constexpr int64_t kPeriod = 1024LL * 1'000'000'000 / kRate;  // 21,333,333 ns
}  // namespace

// On time: each callback spins to 0.8 of its period from its own start.
TEST(load_stabilizer_spins_to_its_share_of_each_period) {
    LoadStabilizer s;
    for (int c = 0; c < 5; ++c) {
        const int64_t start = 1'000'000 + c * kPeriod;
        CHECK_EQ(s.deadline(start, 1024, kRate), start + static_cast<int64_t>(kPeriod * 0.8));
    }
    CHECK_EQ(s.deadline(1'000'000 + 5 * kPeriod, 1024, kRate, 0.5), 1'000'000 + 5 * kPeriod + kPeriod / 2);
}

// Late: a callback that starts late spins that much less (so it never ends later than its share of the ideal
// period), and one later than its share not at all; an early one starts a new epoch.
TEST(load_stabilizer_spins_less_when_late_and_restarts_when_early) {
    LoadStabilizer s;
    const int64_t t0 = 5'000'000;
    s.deadline(t0, 1024, kRate);
    const int64_t late = 3'000'000;
    const int64_t start1 = t0 + kPeriod + late;
    CHECK_EQ(s.deadline(start1, 1024, kRate), start1 + static_cast<int64_t>(kPeriod * 0.8) - late);
    const int64_t veryLate = t0 + 3 * kPeriod;  // callback 2 starts a whole period late
    CHECK(s.deadline(veryLate, 1024, kRate) <= veryLate);
    // Callback 3 is ideally at t0 + 3 periods: one at t0 + 2.5 periods is early, so it is the new epoch.
    const int64_t early = t0 + 3 * kPeriod - kPeriod / 2;
    CHECK_EQ(s.deadline(early, 1024, kRate), early + static_cast<int64_t>(kPeriod * 0.8));
    CHECK_EQ(s.deadline(early + kPeriod, 1024, kRate), early + kPeriod + static_cast<int64_t>(kPeriod * 0.8));
}

// Varying sizes (AAudio's own bursts) count frames, not callbacks; a stall over a second, a reset or a bad size
// starts afresh instead of spinning nothing for a long time.
TEST(load_stabilizer_counts_frames_and_resyncs) {
    LoadStabilizer s;
    const int64_t t0 = 0;
    s.deadline(t0, 192, kRate);
    const int64_t p192 = 192LL * 1'000'000'000 / kRate;
    const int64_t t1 = t0 + p192;
    CHECK_EQ(s.deadline(t1, 96, kRate), t1 + static_cast<int64_t>((96LL * 1'000'000'000 / kRate) * 0.8));
    const int64_t stalled = t1 + 2'000'000'000;  // two seconds later
    CHECK_EQ(s.deadline(stalled, 96, kRate), stalled + static_cast<int64_t>((96LL * 1'000'000'000 / kRate) * 0.8));
    CHECK_EQ(s.deadline(stalled + 1, 0, kRate), stalled + 1);  // no frames: no spin
    s.reset();
    const int64_t again = stalled + 77 * kPeriod;
    CHECK_EQ(s.deadline(again, 1024, kRate), again + static_cast<int64_t>(kPeriod * 0.8));
}

// The spin stops at its deadline and reports what it spun (a driven clock), and spins nothing for a past one.
TEST(load_stabilizer_spin_stops_at_the_deadline) {
    int64_t t = 1000;
    auto now = [&t] { return t += 7; };
    CHECK_EQ(LoadStabilizer::spinUntil(500, now), 0);
    t = 1000;
    const int64_t spun = LoadStabilizer::spinUntil(1100, now);
    CHECK(t >= 1100 && t < 1107 + 7);
    CHECK(spun >= 93 && spun <= 107);
    // On the real clock: about 2 ms of spin takes about 2 ms (it never returns early).
    auto real = [] {
        return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    };
    const int64_t from = real();
    LoadStabilizer::spinUntil(from + 2'000'000, real);
    CHECK(real() - from >= 2'000'000);
}
