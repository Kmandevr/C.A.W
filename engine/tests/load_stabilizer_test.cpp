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

// On time: each callback spins to 0.8 of its period from its own start (the first, which starts the epoch, not).
TEST(load_stabilizer_spins_to_its_share_of_each_period) {
    LoadStabilizer s;
    for (int c = 0; c < 5; ++c) {
        const int64_t start = 1'000'000 + c * kPeriod;
        CHECK_EQ(s.deadline(start, 1024, kRate), c == 0 ? start : start + static_cast<int64_t>(kPeriod * 0.8));
    }
    CHECK_EQ(s.deadline(1'000'000 + 5 * kPeriod, 1024, kRate, 0.5), 1'000'000 + 5 * kPeriod + kPeriod / 2);
}

// Late: a callback that starts late spins that much less (so it never ends later than its share of the ideal
// period), and one later than its share not at all; an early one starts a new epoch (and spins nothing itself).
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
    CHECK_EQ(s.deadline(early, 1024, kRate), early);
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
    const int64_t p96 = 96LL * 1'000'000'000 / kRate;
    CHECK_EQ(s.deadline(stalled, 96, kRate), stalled);  // a new epoch
    CHECK_EQ(s.deadline(stalled + p96, 96, kRate), stalled + p96 + static_cast<int64_t>(p96 * 0.8));
    CHECK_EQ(s.deadline(stalled + p96, 0, kRate), stalled + p96);  // no frames: no spin
    s.reset();
    const int64_t again = stalled + 77 * kPeriod;
    CHECK_EQ(s.deadline(again, 1024, kRate), again);
    CHECK_EQ(s.deadline(again + kPeriod, 1024, kRate), again + kPeriod + static_cast<int64_t>(kPeriod * 0.8));
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

// Drift: a device clock 50 ppm slow of the steady clock makes every callback a little later than its epoch says;
// once that passes the share, the stabilizer would spin nothing for the rest of the session. It starts a new
// epoch instead (after a few callbacks in a row with no spin, or once one is a whole period late).
TEST(load_stabilizer_follows_a_drifting_device_clock) {
    LoadStabilizer s;
    const double slow = kPeriod * (1.0 + 50e-6);
    int64_t spun = 0, worstRun = 0, run = 0;
    const int callbacks = 60000;  // about 21 minutes of 1024-frame callbacks
    for (int c = 0; c < callbacks; ++c) {
        const int64_t start = 1'000'000 + static_cast<int64_t>(c * slow);
        const int64_t d = s.deadline(start, 1024, kRate);
        spun += d > start ? d - start : 0;
        run = d > start ? 0 : run + 1;
        worstRun = run > worstRun ? run : worstRun;
    }
    CHECK(worstRun <= 10);
    CHECK(static_cast<double>(spun) > 0.75 * kPeriod * callbacks);
}

// A one-off stall that shifts the stream (a second's fraction, or just over the share of a period): the
// callbacks after it keep their new schedule, and the stabilizer spins for them again.
TEST(load_stabilizer_resyncs_after_a_stall_that_shifts_the_stream) {
    for (const int64_t stall : {int64_t{500'000'000}, kPeriod * 9 / 10}) {
        LoadStabilizer s;
        int64_t t = 0;
        for (int c = 0; c < 10; ++c, t += kPeriod) s.deadline(t, 1024, kRate);
        t += stall;
        int idle = 0;
        for (int c = 0; c < 20; ++c, t += kPeriod) idle += s.deadline(t, 1024, kRate) <= t;
        CHECK(idle <= 10);
        CHECK_EQ(s.deadline(t, 1024, kRate), t + static_cast<int64_t>(kPeriod * 0.8));
    }
}

// Bursts: stream priming, or Android's fixed-block adapter, can run two or three callbacks back to back. Each one
// after the first is early, so it starts an epoch; the callback that starts an epoch has no ideal period to fill
// and spins nothing, so a burst never stacks spins of 0.8 of a period on top of each other.
TEST(load_stabilizer_does_not_spin_the_callback_that_starts_an_epoch) {
    LoadStabilizer s;
    for (int64_t t : {int64_t{0}, int64_t{20'000}, int64_t{40'000}}) CHECK_EQ(s.deadline(t, 1024, kRate), t);  // priming
    int64_t t = 40'000 + kPeriod;
    CHECK_EQ(s.deadline(t, 1024, kRate), t + static_cast<int64_t>(kPeriod * 0.8));  // the next on time spins
    t += kPeriod;
    CHECK_EQ(s.deadline(t - 500'000, 1024, kRate), t - 500'000 + static_cast<int64_t>(kPeriod * 0.8));  // jitter: on time
    int64_t start = t + kPeriod;  // a burst of three, a period on, each as soon as the one before it ends
    int64_t d = s.deadline(start, 1024, kRate);
    CHECK_EQ(d, start + static_cast<int64_t>(kPeriod * 0.8));  // the first is on time
    for (int c = 0; c < 2; ++c) {
        start = d + 30'000;
        d = s.deadline(start, 1024, kRate);
        CHECK_EQ(d, start);  // the others are early: new epochs, no spin
    }
}

// Battery: the stabilizer holds a core near 80 % only where the clock matters, when the callback's own work is a
// real share of its period (smoothed: on above 0.16, off below 0.04, held on at least 2 s) or it overran.
TEST(load_stabilizer_is_wanted_only_when_the_work_share_says_the_clock_matters) {
    auto work = [](double share) { return static_cast<int64_t>(kPeriod * share); };
    const int twoSeconds = static_cast<int>(2'000'000'000 / kPeriod) + 1;
    LoadStabilizer idle;
    for (int c = 0; c < 500; ++c) CHECK(!idle.wanted(work(0.02), 1024, kRate));  // a near-idle project
    CHECK_NEAR(idle.workShare(), 0.02, 0.001);
    LoadStabilizer s;
    CHECK(s.wanted(work(0.5), 1024, kRate));  // heavy from the start
    for (int c = 0; c < 500; ++c) CHECK(s.wanted(work(0.1), 1024, kRate));  // between the two: stays on
    int on = 0;
    for (int c = 0; c < 500; ++c) on += s.wanted(work(0.02), 1024, kRate);
    CHECK(!s.wanted(work(0.02), 1024, kRate));  // light again: off
    CHECK(on > 0 && on < 100);
    for (int c = 0; c < 500; ++c) CHECK(!s.wanted(work(0.12), 1024, kRate));  // under 0.16: stays off
    // One overrun turns it on and holds it about 2 s, then the light load turns it off.
    CHECK(s.wanted(work(1.2), 1024, kRate));
    for (int c = 0; c < twoSeconds - 2; ++c) CHECK(s.wanted(work(0.02), 1024, kRate));
    for (int c = 0; c < 100; ++c) s.wanted(work(0.02), 1024, kRate);
    CHECK(!s.wanted(work(0.02), 1024, kRate));
    s.resetLoad();  // stopped: it starts off and from the next callback's work
    CHECK(!s.wanted(work(0.1), 1024, kRate));
    CHECK_NEAR(s.workShare(), 0.1, 0.001);
}

namespace {
// A model of the phone's clock under the stabilizer, for the trade-off between 1.1.1's rule and 1.1.2's. The
// governor: schedutil's f = 1.25 b f_now ([Fact, docs.kernel.org/scheduler/schedutil.html, read 2026-11-19] with
// frequency-invariant utilisation), the lowest step at or over it, once per callback. [Assumption] steps of a
// Cortex-A710-class big core, 634 MHz to 2.5 GHz (the S22+'s range in the owner's Benchmark, 2026-11-19); the
// work's cycles fixed per callback. A callback whose work takes more than its period is a dropout.
struct ModelRun {
    int dropouts = 0;
    double meanClock = 0, busy = 0;  // GHz, and the core's mean busy share (the heat's proxy)
};
enum class Rule { None, Clock111, Full112 };

// 1.1.1's rule, kept here only for the comparison: the share follows the recent peak work against a target of
// the period (0.5; 0.6 warm, 0.7 hot), never under 0.6 of the full share.
double share111(double peak, int thermal) {
    const double target = thermal == 3 ? 0.7 : thermal == 2 ? 0.6 : 0.5;
    double r = peak / target;
    r = r < 0.6 ? 0.6 : (r > 1.0 ? 1.0 : r);
    return LoadStabilizer::kShare * r;
}

// `base`: the work's share of a period at the top clock; every `every`-th callback takes `burst` times that.
ModelRun governorModel(Rule rule, int thermal, double base, double burst, int every, int callbacks) {
    static constexpr double kSteps[] = {0.634, 0.8, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0, 2.2, 2.5};
    constexpr int kTop = 9;
    int f = 0;  // the phone's callback core sat at its floor (2026-11-19)
    LoadStabilizer s;
    double peak = 0;
    const double pa = static_cast<double>(kPeriod) / 3e9;  // 1.1.1's peak fell over 3 s
    ModelRun out;
    for (int c = 0; c < callbacks; ++c) {
        const double work = base * (c % every == every - 1 ? burst : 1.0) * kSteps[kTop] / kSteps[f];
        if (work > 1.0) ++out.dropouts;
        peak = std::max(work, peak - pa * peak);
        const bool on = s.wanted(static_cast<int64_t>(work * kPeriod), 1024, kRate);
        double share = 0;
        if (on && rule == Rule::Full112) share = LoadStabilizer::spinShare();
        if (on && rule == Rule::Clock111) share = share111(peak, thermal);
        const double b = std::min(1.0, std::max(work, share));
        out.meanClock += kSteps[f];
        out.busy += b;
        const double want = 1.25 * b * kSteps[f];
        int next = kTop;
        for (int k = 0; k <= kTop; ++k)
            if (kSteps[k] >= want - 1e-9) { next = k; break; }
        f = next;
    }
    out.meanClock /= callbacks;
    out.busy /= callbacks;
    return out;
}
}  // namespace

// The owner's 1.1.1 report (S22+, 2026-11-24): dropouts at a 20-30 % meter, worse once warm. In the model (the
// clock starts at its floor, as the phone's did) a song8-like load, 0.075 of the period at the top clock (0.30 at
// the floor: a 30 % meter), with a burst of 3.5 times that: 1.1.1's rule lets the clock sit lower than 1.1.2's full
// share holds it, so more bursts drop out, warm and hot most; without the stabilizer the clock never leaves the
// floor. [Assumption] schedutil's rule: the owner's Benchmark of the same day had the callback's core at 0.5-0.6
// of its top clock with the 1.1.1 stabilizer on, so the phone's governor does not follow the model closely, and
// the stabilizer is off by default since 1.1.2 (the buffer tuner gives the headroom instead).
TEST(load_stabilizer_governor_model_full_share_has_no_dropouts) {
    static_assert(LoadStabilizer::spinShare() == LoadStabilizer::kShare, "1.1.2: the full share, whatever the heat");
    const int minute = static_cast<int>(60LL * 1'000'000'000 / kPeriod);
    // A burst every 8 s: 1.1.1 7 dropouts a minute at any heat, 1.1.2 1 (measured 2026-11-24).
    for (int thermal : {0, 2, 3}) {
        const ModelRun full = governorModel(Rule::Full112, thermal, 0.075, 3.5, 375, minute);
        const ModelRun old = governorModel(Rule::Clock111, thermal, 0.075, 3.5, 375, minute);
        CHECK(full.dropouts <= 1);
        CHECK(old.dropouts > 3 * full.dropouts);
        CHECK(old.meanClock < full.meanClock);
        CHECK(old.busy < full.busy);  // what 1.1.1 saved: a less busy core
    }
    // A burst every second, warm: 1.1.1 20 a minute, 1.1.2 1, none 59 (the clock stays at its floor).
    const ModelRun warmOld = governorModel(Rule::Clock111, 2, 0.075, 3.5, 47, minute);
    const ModelRun warmFull = governorModel(Rule::Full112, 2, 0.075, 3.5, 47, minute);
    const ModelRun none = governorModel(Rule::None, 2, 0.075, 3.5, 47, minute);
    CHECK(warmFull.dropouts <= 1);
    CHECK(warmOld.dropouts >= 10);
    CHECK(none.dropouts > warmOld.dropouts);
    // Light bursts drop out under no rule.
    for (const Rule r : {Rule::None, Rule::Clock111, Rule::Full112})
        CHECK_EQ(governorModel(r, 3, 0.075, 2.5, 47, minute).dropouts, 0);
}
