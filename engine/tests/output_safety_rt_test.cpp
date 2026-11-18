// The live output's mono check and safety limiter (API 35, #244): what they do, that only the device path runs them (never a render), and that they never allocate there.
#include <cmath>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "device_render.h"
#include "engine.h"
#include "output_safety.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;
using cawtest::Shape;

namespace {

float peakOf(const std::vector<float>& v) {
    float p = 0;
    for (float x : v) p = std::fabs(x) > p ? std::fabs(x) : p;
    return p;
}

}  // namespace

TEST(the_safety_limiter_passes_a_quiet_mix_bit_for_bit_and_keeps_a_loud_one_under_its_ceiling) {
    OutputSafety s;
    std::vector<float> l(4800), r(4800);
    for (int i = 0; i < 4800; ++i) {
        l[static_cast<size_t>(i)] = static_cast<float>(0.5 * std::sin(0.03 * i));  // -6 dBFS: under the knee
        r[static_cast<size_t>(i)] = static_cast<float>(0.4 * std::sin(0.05 * i));
    }
    const auto l0 = l, r0 = r;
    s.process(l.data(), r.data(), 4800, OutputSafety::kLimiter, 48000);
    CHECK(l == l0);
    CHECK(r == r0);
    CHECK_EQ(s.gain(), 1.0);
    // Far over full scale (a broken effect): held under -1 dBFS from the first sample, no look-ahead.
    for (int i = 0; i < 4800; ++i) {
        l[static_cast<size_t>(i)] = static_cast<float>(8.0 * std::sin(0.03 * i));
        r[static_cast<size_t>(i)] = static_cast<float>(-3.0 * std::sin(0.05 * i));
    }
    s.process(l.data(), r.data(), 4800, OutputSafety::kLimiter, 48000);
    CHECK(peakOf(l) < OutputSafety::kCeiling);
    CHECK(peakOf(r) < OutputSafety::kCeiling);
    CHECK(peakOf(l) > 0.8);  // limited, not muted
    CHECK(s.gain() < 1.0);
    // It lets go: a second of quiet later the gain is back to 1.
    std::vector<float> ql(48000, 0.1f), qr(48000, 0.1f);
    s.process(ql.data(), qr.data(), 48000, OutputSafety::kLimiter, 48000);
    CHECK_EQ(s.gain(), 1.0);
    CHECK_EQ(ql.back(), 0.1f);
    // A non-finite sample is silenced; with the stage off nothing is touched at all.
    float nl[2] = {NAN, INFINITY}, nr[2] = {0.25f, -INFINITY};
    s.process(nl, nr, 2, OutputSafety::kLimiter, 48000);
    CHECK_EQ(nl[0], 0.0f);
    CHECK_EQ(nl[1], 0.0f);
    CHECK_EQ(nr[1], 0.0f);
    float ol[1] = {4.0f}, orr[1] = {NAN};
    s.process(ol, orr, 1, 0, 48000);
    CHECK_EQ(ol[0], 4.0f);
    CHECK(std::isnan(orr[0]));
}

TEST(the_mono_check_plays_both_sides_as_their_mean) {
    OutputSafety s;
    float l[3] = {0.5f, -0.2f, 0.0f}, r[3] = {0.1f, 0.2f, 0.3f};
    s.process(l, r, 3, OutputSafety::kMono, 48000);
    for (int i = 0; i < 3; ++i) CHECK_EQ(l[i], r[i]);
    CHECK_NEAR(l[0], 0.3f, 1e-7);
    CHECK_NEAR(l[1], 0.0f, 1e-7);
    CHECK_NEAR(l[2], 0.15f, 1e-7);
}

TEST(the_output_safety_runs_only_in_the_live_output_never_in_a_render) {
    // A square at 1.0 through a track at +6 dB: the master stage's own -0.2 dBFS limiter holds it near full scale.
    auto loud = cawtest::testSignalProject({cawtest::testSignalLayer("a", Shape::Square, {{"freq", 220}, {"level", 2.0}})});
    auto render = [&](int flags, bool device) {
        Engine e(48000);
        e.setOutputSafety(flags);
        CHECK(e.setProject(loud).find("\"ok\":true") != std::string::npos);
        e.play();
        std::vector<float> outL, out(512 * 2), l(512), r(512);
        DeviceRender dev;
        dev.open(512);
        for (int k = 0; k < 40; ++k) {
            if (device) {
                dev.render(e, out.data(), 512);
                for (int i = 0; i < 512; ++i) outL.push_back(out[static_cast<size_t>(i) * 2]);
            } else {
                e.process(l.data(), r.data(), 512);
                outL.insert(outL.end(), l.begin(), l.end());
            }
        }
        return outL;
    };
    const auto renderOn = render(OutputSafety::kLimiter | OutputSafety::kMono, false);
    const auto renderOff = render(0, false);
    CHECK(renderOn == renderOff);           // Engine::process (every render and export) never runs it
    CHECK(peakOf(renderOn) > 0.95f);        // the master stage's ceiling, -0.2 dBFS
    const auto liveOn = render(OutputSafety::kLimiter, true);
    const auto liveOff = render(0, true);
    CHECK(peakOf(liveOff) > 0.95f);
    CHECK(peakOf(liveOn) < OutputSafety::kCeiling);  // the live output is held under -1 dBFS
}

TEST(the_output_safety_never_allocates_on_the_audio_thread) {
    Engine e(48000);
    CHECK(e.setProject(cawtest::testSignalProject({cawtest::testSignalLayer("a", Shape::Saw, {{"level", 3.0}})}))
              .find("\"ok\":true") != std::string::npos);
    e.play();
    DeviceRender dev;
    dev.open(192);
    std::vector<float> out(192 * 2);
    dev.render(e, out.data(), 192);  // the first callback takes the project
    std::size_t operations = 0;
    for (int flags : {OutputSafety::kLimiter, OutputSafety::kMono, OutputSafety::kLimiter | OutputSafety::kMono, 0}) {
        e.setOutputSafety(flags);
        for (bool timed : {false, true}) {
            dev.timeProcess(timed);  // the Benchmark's live run times the stage apart
            cawtest::AllocationScope scope;
            for (int k = 0; k < 200; ++k) dev.render(e, out.data(), 192);
            operations += scope.count();
            dev.takeSafetyNs();
            dev.takeProcessNs();
        }
    }
    CHECK_EQ(operations, static_cast<std::size_t>(0));
}
