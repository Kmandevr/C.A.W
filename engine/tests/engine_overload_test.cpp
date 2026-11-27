// Mixer tests: overload shedding, device callbacks, the device FIFO, the buffer tuner and output latency.
#include <algorithm>
#include <functional>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "caw.h"
#include "detmath.h"
#include "device_render.h"
#include "buffer_tuner.h"
#include "device_choice.h"
#include "device_period.h"
#include "engine.h"
#include "native_component_test_path.h"
#include "test.h"
#include "test_signal.h"
#include "engine_test_harness.h"

using namespace caw;
using namespace engine_test;

TEST(overload_mutes_the_newest_layer) {
    ProjectSpec p = project({dc(0.25), dc(0.5)});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    run(e, 1000);
    for (int i = 0; i < 40; ++i) e.reportLoad(1.5, 512);
    std::vector<float> out = run(e, 5000);
    const Meters m = e.meters();
    CHECK_EQ(m.overloaded, 1);
    LayerMeter lm;
    CHECK(e.layerMeter(1, lm) && lm.overloaded);
    CHECK(e.layerMeter(0, lm) && !lm.overloaded);
    CHECK_NEAR(out[4999], 0.25 * std::cos(kPi / 4.0), 1e-5);
    e.clearOverload();
    out = run(e, 5000);
    CHECK_EQ(e.meters().overloaded, 0);
    CHECK_NEAR(out[4999], 0.75 * std::cos(kPi / 4.0), 1e-5);
}

TEST(overload_shedding_goes_by_time_not_callbacks) {
    // The shedding was tuned at 512-frame callbacks: about 0.21 s over budget sheds a layer, then 1.07 s of rest.
    // Counting callbacks made 16-frame periods shed on a 7 ms hiccup and 8192-frame ones take 3.4 s.
    ProjectSpec p = project({dc(0.25), dc(0.5)});
    auto overloadedAfter = [&](int frames, double seconds) {
        Engine e(48000);
        e.setProject(p);
        e.play();
        run(e, 1000);
        const int calls = static_cast<int>(seconds * 48000 / frames + 0.5);
        for (int i = 0; i < calls; ++i) e.reportLoad(1.5, frames);
        run(e, 64);
        return e.meters().overloaded;
    };
    CHECK_EQ(overloadedAfter(16, 0.0083), 0);  // 25 tiny callbacks: a hiccup
    CHECK_EQ(overloadedAfter(16, 0.1), 0);
    CHECK_EQ(overloadedAfter(16, 0.35), 1);
    CHECK_EQ(overloadedAfter(512, 0.1), 0);
    CHECK_EQ(overloadedAfter(512, 0.35), 1);
    CHECK_EQ(overloadedAfter(8192, 0.35), 1);   // two callbacks, not twenty
    // The meter's average is weighted by time as well: one long callback at 1.5 reads far over budget.
    Engine e(48000);
    e.reportLoad(1.5, 8192);
    CHECK(e.meters().cpu > 1.0f);
    Engine f(48000);
    for (int i = 0; i < 32; ++i) f.reportLoad(1.5, 16);  // 10.7 ms: one 512-frame callback's worth
    CHECK_NEAR(f.meters().cpu, 0.15, 0.01);
    // The cooldown is time too: still overloaded after shedding, the next layer goes about 1.07 s later (three
    // layers: the last one still sounding is never shed, 1.1.2).
    Engine g(48000);
    g.setProject(project({dc(0.25), dc(0.5), dc(0.1)}));
    g.play();
    run(g, 1000);
    for (int i = 0; i < 300; ++i) g.reportLoad(1.5, 64);  // 0.4 s: the first layer
    run(g, 64);
    CHECK_EQ(g.meters().overloaded, 1);
    for (int i = 0; i < 600; ++i) g.reportLoad(1.5, 64);  // 0.8 s more: still cooling down
    run(g, 64);
    CHECK_EQ(g.meters().overloaded, 1);
    for (int i = 0; i < 600; ++i) g.reportLoad(1.5, 64);
    run(g, 64);
    CHECK_EQ(g.meters().overloaded, 2);
}

namespace {
// A device's callbacks, simulated: `seconds` of 512-frame callbacks, each reporting the load `load(layersOn)`
// gives for the layers not shed now. Returns the largest number of layers shed at once.
int simulateLoad(Engine& e, double seconds, const std::function<double(int)>& load, int layers) {
    std::vector<float> l(512), r(512);
    int most = 0;
    for (int k = 0, calls = static_cast<int>(seconds * 48000 / 512); k < calls; ++k) {
        e.process(l.data(), r.data(), 512);
        const int shed = e.meters().overloaded;
        most = std::max(most, shed);
        e.reportLoad(load(layers - shed), 512);
    }
    return most;
}
}  // namespace

TEST(shed_layers_come_back_on_their_own_once_the_load_drops) {
    // The owner's report (2026-11-12): in the background the song thinned out until it stopped, and shed layers
    // came back only with Unmute. Overloaded, the engine sheds; once the load is low again they return one by one.
    ProjectSpec p = project({dc(0.1), dc(0.1), dc(0.1), dc(0.1)});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    run(e, 1000);
    bool hot = true;
    // Throttled: every callback over budget for 3 s sheds a layer about every 1.07 s.
    simulateLoad(e, 3.0, [&](int) { return hot ? 1.3 : 0.3; }, 4);
    const int shed = e.meters().overloaded;
    CHECK(shed >= 2);
    CHECK_EQ(static_cast<int>(e.sheddingStats().shed), shed);
    // Back in focus: 0.1 of the budget a layer. They come back about every 2 s, the newest shed first.
    hot = false;
    simulateLoad(e, 2.0 * shed + 3.0, [](int on) { return 0.1 * on; }, 4);
    CHECK_EQ(e.meters().overloaded, 0);
    CHECK_EQ(e.sheddingStats().restored, static_cast<uint64_t>(shed));
    const std::vector<float> out = run(e, 4800);
    CHECK_NEAR(out.back(), 0.4 * std::cos(kPi / 4.0), 1e-4);  // all four play again, faded back in
}

TEST(a_layer_the_device_can_only_just_not_carry_does_not_come_and_go) {
    // Borderline: two layers cost 0.9 of the budget, one 0.55. Bringing the shed one back would overload again
    // (its cost was measured when it went), so it does not come back after 2 s quiet; only on trial after 10 s,
    // and each trial that overloads doubles the wait: a few in a minute, not a shed and return every 2.3 s.
    ProjectSpec p = project({dc(0.1), dc(0.1)});
    Engine e(48000);
    e.setProject(p);
    e.play();
    run(e, 1000);
    simulateLoad(e, 9.0, [](int on) { return 0.2 + 0.35 * on; }, 2);
    CHECK_EQ(e.sheddingStats().shed, uint64_t{1});
    CHECK_EQ(e.sheddingStats().restored, uint64_t{0});  // it does not fit: no quick return
    simulateLoad(e, 51.0, [](int on) { return 0.2 + 0.35 * on; }, 2);
    CHECK(e.sheddingStats().shed <= uint64_t{4});
    CHECK_EQ(e.meters().overloaded, 1);
    // Its cost misread (the load fell only after the meter looked): it comes back and is shed again, but each
    // re-shed within 10 s doubles its wait (2, 4, 8, 16, 32 s), so a minute holds a few cycles, not one every 3.5 s.
    Engine f(48000);
    f.setProject(p);
    f.play();
    run(f, 1000);
    int lastOn = 2, since = 0;
    simulateLoad(f, 60.0, [&](int on) {
        since = on == lastOn ? since + 1 : 0;
        lastOn = on;
        return on == 2 || since < 120 ? 0.95 : 0.5;  // 1.3 s still hot after a shed
    }, 2);
    CHECK(f.sheddingStats().shed >= uint64_t{2});  // it did come back at least once
    CHECK(f.sheddingStats().shed <= uint64_t{6});
    // Throttled whatever is shed: one layer goes, the last one still sounding never does (1.1.2: load never
    // silences the song; before, both went and came back on trial), and the shed one comes back.
    Engine g(48000);
    g.setProject(p);
    g.play();
    run(g, 1000);
    simulateLoad(g, 4.0, [](int) { return 1.4; }, 2);
    CHECK_EQ(g.meters().overloaded, 1);
    simulateLoad(g, 30.0, [](int on) { return 0.05 + 0.1 * on; }, 2);  // the device recovers
    CHECK_EQ(g.meters().overloaded, 0);
}

// The owner's 1.1.1 report (S22+, 2026-11-24): "whenever the phone warms up or takes significant load, playback
// stops". However long and however far the device is over budget, the transport plays on and the last layer still
// sounding keeps sounding; a short stall (a heat step) sheds nothing.
TEST(load_never_stops_playback) {
    for (const int frames : {96, 512, 1024}) {
        Engine e(48000);
        e.setMasterBypass(true);
        e.setProject(project({dc(0.1), dc(0.1), dc(0.1), dc(0.1)}));
        e.play();
        run(e, 1000);
        std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
        // A heat step: 0.15 s at three times the budget, then light.
        for (int k = 0, n = static_cast<int>(0.15 * 48000 / frames); k < n; ++k) {
            e.process(l.data(), r.data(), frames);
            e.reportLoad(3.0, frames);
        }
        for (int k = 0, n = 48000 / frames; k < n; ++k) {
            e.process(l.data(), r.data(), frames);
            e.reportLoad(0.3, frames);
        }
        CHECK_EQ(e.sheddingStats().shed, 0u);
        // Thirty seconds at twice the budget, whatever is shed.
        float loud = 0;
        for (int k = 0, n = 30 * 48000 / frames; k < n; ++k) {
            e.process(l.data(), r.data(), frames);
            e.reportLoad(2.0, frames);
            CHECK(e.meters().playing);
            if (k > n - 48000 / frames) loud = std::max(loud, std::fabs(l[static_cast<size_t>(frames) - 1]));
        }
        CHECK_EQ(e.meters().overloaded, 3);  // three of four went, one a second; the last never does
        CHECK(loud > 0.05f);                 // and it is heard
        CHECK(e.meters().playing);
    }
}

TEST(a_single_late_callback_sheds_nothing) {
    // The first callback after Play, a device restart or reroute, a background burst: one stall, however long.
    ProjectSpec p = project({dc(0.25), dc(0.5)});
    for (const int frames : {64, 512, 1920}) {
        Engine e(48000);
        e.setProject(p);
        e.play();
        run(e, 1000);
        std::vector<float> l(2048), r(2048);
        for (int k = 0; k < 2000; ++k) {
            e.process(l.data(), r.data(), frames);
            const bool burst = k == 0 || k == 500 || (k >= 1000 && k < 1000 + 4800 / frames);  // up to 0.1 s of them
            e.reportLoad(burst ? 40.0 : 0.3, frames);
        }
        CHECK_EQ(e.meters().overloaded, 0);
        CHECK_EQ(e.sheddingStats().shed, uint64_t{0});
    }
}

TEST(a_new_devices_first_callbacks_stay_out_of_the_cpu_meter) {
    // #234: on the owner's S22+ through Bluetooth (a shared AAudio stream, its callback not real-time, on a little
    // core) the day's worst meter read was 600 and 800%, with nothing shed. A stream that starts fills its buffer
    // back to back, on a core whose clock hasn't risen: 0.2 s of frames at 9 times their budget reads 7.8 on the
    // meter. Play reopens the device closed while idle, so those callbacks fall while playing. A device open asks
    // for a warm-up (requestDeviceWarmUp), and its first kDeviceWarmSeconds of frames stay out of the meter.
    ProjectSpec p = project({dc(0.25), dc(0.5)});
    for (const int frames : {64, 256, 1920}) {
        for (const bool warm : {false, true}) {
            Engine e(48000);
            e.setProject(p);
            e.play();
            run(e, 1000);
            e.requestSheddingReset();  // as a device open does
            if (warm) e.requestDeviceWarmUp();
            std::vector<float> l(2048), r(2048);
            float worst = 0, worstAfter = 0;
            double played = 0;
            for (int k = 0; played < 3.0; ++k) {
                e.process(l.data(), r.data(), frames);
                const bool filling = played < 0.2;
                e.reportLoad(filling ? 9.0 : 0.3, frames);
                played += static_cast<double>(frames) / 48000.0;
                worst = std::max(worst, e.meters().cpu);
                if (played > Engine::kDeviceWarmSeconds + 0.5) worstAfter = std::max(worstAfter, e.meters().cpu);
            }
            CHECK_EQ(e.sheddingStats().shed, uint64_t{0});
            if (warm) {
                CHECK(worst < 0.35f);  // the steady 0.3 only
                CHECK(worstAfter > 0.25f);  // and the meter still reads it after the warm-up
            } else {
                CHECK(worst > 5.0f);  // without the warm-up the stream's start reads as 500% and more
            }
        }
    }
    // After the warm-up a real overload still sheds.
    Engine e(48000);
    e.setProject(p);
    e.play();
    run(e, 1000);
    e.requestSheddingReset();
    e.requestDeviceWarmUp();
    std::vector<float> l(256), r(256);
    for (int k = 0; k < 48000 * 2 / 256; ++k) {
        e.process(l.data(), r.data(), 256);
        e.reportLoad(1.5, 256);
    }
    CHECK(e.sheddingStats().shed > uint64_t{0});
}

// #242: an Android device chosen by its AudioDeviceInfo id ("aaudio:<id>", from the app's settings: untrusted text)
// opens by that id; anything else opens the default; and a stream on another device than the chosen one is told.
TEST(an_aaudio_device_is_chosen_by_its_id_and_junk_opens_the_default) {
    using caw::aaudioDeviceId;
    CHECK_EQ(aaudioDeviceId("aaudio:41"), 41);
    CHECK_EQ(aaudioDeviceId("aaudio:2147483647"), 2147483647);
    for (const char* junk : {"", "41", "aaudio:", "aaudio:0", "aaudio:-3", "aaudio:4x", "aaudio: 4", "aaudio:2147483648",
                             "aaudio:99999999999", "AAUDIO:4", "android:8:WH-1000XM4", "{0.0.0.00000000}.{abc}"})
        CHECK_EQ(aaudioDeviceId(junk), 0);
    CHECK(caw::onChosenDevice(41, 41));
    CHECK(!caw::onChosenDevice(41, 3));  // Android opened another, or miniaudio reopened the default after a disconnect
    CHECK(caw::onChosenDevice(0, 3));    // nothing chosen
    CHECK(caw::onChosenDevice(41, 0));   // not known
}

// #241: the output's latency without a timestamp counts what AAudio queues, its buffer size, not miniaudio's periods,
// which on AAudio are the stream's whole capacity: at the fixed 1024-frame size a 4096-frame capacity read as 4
// periods (85 ms at 48 kHz) where the stream queued 2048 (43 ms). Elsewhere (no AAudio buffer size) every period.
TEST(the_output_latency_counts_the_frames_queued_not_the_buffer_capacity) {
    using caw::queuedOutputFrames;
    using caw::queuedPeriods;
    CHECK_EQ(queuedOutputFrames(2048, 1024, 4), int64_t{2048});  // fixed 1024, capacity 4096: the queue, not 4096
    CHECK_EQ(queuedOutputFrames(384, 1952, 1), int64_t{384});    // AAudio's own sizes: one capacity-long period
    CHECK_EQ(queuedOutputFrames(0, 480, 3), int64_t{1440});      // WASAPI, ALSA: every period
    CHECK_EQ(queuedOutputFrames(0, 480, 0), int64_t{480});
    CHECK_EQ(queuedPeriods(2048, 1024, 4), 2);                   // the status's periods follow the queue
    CHECK_EQ(queuedPeriods(384, 192, 1), 2);
    CHECK_EQ(queuedPeriods(300, 1024, 4), 1);                    // never below one callback
    CHECK_EQ(queuedPeriods(2048, 0, 4), 4);                      // no callback size: the backend's periods
}

// #237: Low latency's smallest WASAPI period (device_period.h): a multiple of the shared engine's fundamental from
// its min to its max, never under the 128-frame floor; an exclusive minimum device period rounded up to frames.
TEST(the_smallest_device_period_is_a_legal_one_above_the_floor) {
    using caw::smallestSharedPeriod;
    CHECK_EQ(smallestSharedPeriod(4, 48, 448), uint32_t{128});    // Microsoft Learn's 44.1 kHz example: 128 is legal
    CHECK_EQ(smallestSharedPeriod(48, 144, 480), uint32_t{144});   // min above the floor
    CHECK_EQ(smallestSharedPeriod(48, 96, 480), uint32_t{144});    // floor rounded up to the fundamental
    CHECK_EQ(smallestSharedPeriod(480, 480, 480), uint32_t{480});  // no small buffers: the default
    CHECK_EQ(smallestSharedPeriod(32, 32, 100), uint32_t{96});     // floor above max: the largest legal under it
    CHECK_EQ(smallestSharedPeriod(0, 48, 480), uint32_t{0});       // unusable numbers ask nothing
    CHECK_EQ(smallestSharedPeriod(48, 480, 96), uint32_t{0});
    CHECK_EQ(smallestSharedPeriod(64, 100, 120), uint32_t{0});     // no multiple of 64 in 100..120
    using caw::exclusivePeriodFrames;
    CHECK_EQ(exclusivePeriodFrames(30000, 48000), uint32_t{144});  // 3 ms
    CHECK_EQ(exclusivePeriodFrames(26667, 48000), uint32_t{129});  // rounded up, never under the device's
    CHECK_EQ(exclusivePeriodFrames(10000, 48000), uint32_t{128});  // 1 ms: the floor
    CHECK_EQ(exclusivePeriodFrames(0, 48000), uint32_t{0});
    CHECK_EQ(exclusivePeriodFrames(30000, 0), uint32_t{0});
}

// #236: the output buffer's automatic size (Oboe's LatencyTuner way, buffer_tuner.h): whole bursts from two bursts
// to the capacity, a burst more on each underrun, a burst less after a minute without one, never back to a size that
// underran on this stream, started from the size remembered for this kind of output.
TEST(the_buffer_tuner_grows_on_underruns_and_shrinks_only_to_sizes_that_held) {
    BufferTuner t;
    CHECK(!t.started());
    CHECK_EQ(t.update(5, 1.0), 0);  // not started: nothing
    CHECK_EQ(t.start(96, BufferTuner::kFloorBursts * 96, 3000, 0, 0), 192);  // two bursts
    CHECK_EQ(t.update(0, 1.0), 0);
    CHECK_EQ(t.update(-1, 1.0), 0);  // unknown count: nothing
    CHECK_EQ(t.update(2, 1.0), 288);  // underruns: a burst more
    CHECK_EQ(t.update(2, 1.0), 0);
    CHECK_EQ(t.update(3, 1.0), 384);
    // A quiet minute takes a burst off, but never back to a size that underran (288 and 192 did).
    int32_t shrunk = 0;
    for (int s = 0; s < 200; ++s)
        if (const int32_t n = t.update(3, 1.0)) shrunk = n;
    CHECK_EQ(shrunk, 0);
    CHECK_EQ(t.size(), 384);
    // From a remembered size: rounded up to a burst, kept within the floor and the capacity (whole bursts).
    CHECK_EQ(t.start(96, 192, 3000, 500, 7), 576);
    for (int s = 0; s < 59; ++s) CHECK_EQ(t.update(7, 1.0), 0);
    CHECK_EQ(t.update(7, 1.0), 480);  // 60 s quiet
    CHECK_EQ(t.update(8, 1.0), 576);  // it underran at 480: back up, and 480 is not tried again
    for (int s = 0; s < 300; ++s) CHECK_EQ(t.update(8, 1.0), 0);
    CHECK_EQ(t.start(96, 192, 3000, 100000, 0), 2976);  // the capacity in whole bursts
    CHECK_EQ(t.update(1, 1.0), 0);  // at the ceiling: nothing more to give
    CHECK_EQ(t.start(96, 192, 3000, 10, 0), 192);  // never under the floor
    CHECK_EQ(t.update(4, 1.0), 288);
    CHECK_EQ(t.update(1, 1.0), 0);  // a counter that went back (a new stream's) is taken as the new start
    CHECK_EQ(t.update(2, 1.0), 384);
}

// The review of #236, and 1.1.2: the full tuning where the output was opened without a size of its own (Low latency,
// Auto while recording); a fixed size (Auto's and Battery's 1024 frames, a chosen size) only grows, and
// caw_audio_tune_buffer returns 0.
TEST(the_buffer_tuner_tunes_fully_only_an_output_opened_without_a_size) {
    CHECK(tunesBuffer(0));
    CHECK(!tunesBuffer(1024));  // Auto while not recording, Battery
    CHECK(!tunesBuffer(256));   // a size the user chose
}

// 1.1.2 (the owner's dropouts at a 20-30 % meter): every other output only grows, from the size its stream opened
// with, a burst at each underrun (Oboe's LatencyTuner), and never goes below that size.
TEST(the_buffer_tuner_only_grows_a_fixed_buffer_from_its_opened_size) {
    BufferTuner t;
    CHECK_EQ(growOnlyStart(t, 192, 3072, 3072 * 2, 5), 0);  // nothing set at the start: it keeps its size
    CHECK_EQ(t.size(), 3072);
    CHECK_EQ(t.update(5, 1.0), 0);
    CHECK_EQ(t.update(6, 1.0), 3264);  // an underrun: a burst more
    for (int s = 0; s < 59; ++s) CHECK_EQ(t.update(6, 1.0), 0);
    CHECK_EQ(t.update(6, 1.0), 0);  // quiet for a minute: never back to the size that underran
    for (int s = 0; s < 600; ++s) CHECK_EQ(t.update(6, 1.0), 0);
    CHECK_EQ(t.size(), 3264);
    // An opened size that is not whole bursts: the first growth is still above it, never under.
    BufferTuner u;
    CHECK_EQ(growOnlyStart(u, 192, 1000, 4000, 0), 0);
    CHECK(u.update(1, 1.0) > 1000);
    // At the capacity: nothing to give, and nothing smaller is ever set.
    BufferTuner w;
    CHECK_EQ(growOnlyStart(w, 192, 3072, 3072, 0), 0);
    CHECK_EQ(w.update(3, 1.0), 0);
    CHECK_EQ(w.size(), 3072);
}

TEST(odd_callback_sizes_through_the_device_fifo_shed_nothing_under_the_threshold) {
    // The 2026-11-12 audio review: through the device's FIFO a callback renders more or fewer frames than it
    // plays (at 120 frames, 128 seven times in eight), so a load measured against the callback's own budget peaks
    // over 85% while the engine's real load is under it. The load counts per frame rendered (reportLoad's third
    // argument), and a small period that isn't whole blocks (96, a phone's low-latency burst) skips the FIFO.
    CHECK(!DeviceRender::suits(96));
    CHECK(!DeviceRender::suits(240));
    CHECK(DeviceRender::suits(192));
    CHECK(DeviceRender::suits(441));
    CHECK(DeviceRender::suits(257));
    for (const int period : {96, 120, 200, 300, 441, 1023}) {
        for (const bool fifo : {true, false}) {
            for (const double perFrame : {0.7, 0.8}) {
                Engine e(48000);
                e.setProject(project({dc(0.25), dc(0.5)}));
                e.play();
                DeviceRender dev;
                if (fifo) dev.open(period);  // as the device does: the FIFO only where the period suits it
                else dev.open(kBlock * 4);   // the FIFO forced on, at any period
                CHECK_EQ(dev.usesFifo(), fifo ? DeviceRender::suits(period) : true);
                std::vector<float> out(static_cast<size_t>(period) * 2);
                for (int k = 0, calls = 48000 * 5 / period; k < calls; ++k) {
                    const int rendered = dev.render(e, out.data(), period);
                    if (!dev.usesFifo()) CHECK_EQ(rendered, period);
                    // The callback's time: perFrame of real time for each frame rendered, against its own budget.
                    e.reportLoad(perFrame * rendered / period, period, rendered);
                }
                if (e.sheddingStats().shed != 0)
                    cawtest::fail(__FILE__, __LINE__, std::to_string(period) + "-frame callbacks at " + std::to_string(perFrame) +
                                                          " a frame rendered shed " + std::to_string(e.sheddingStats().shed));
                CHECK_NEAR(e.meters().cpu, perFrame, 0.02);  // the meter reads the engine's real load
            }
        }
    }
    // A real overload still sheds through the FIFO.
    Engine e(48000);
    e.setProject(project({dc(0.25), dc(0.5)}));
    e.play();
    DeviceRender dev;
    dev.open(441);
    std::vector<float> out(441 * 2);
    for (int k = 0; k < 48000 / 441; ++k) {
        const int rendered = dev.render(e, out.data(), 441);
        e.reportLoad(0.95 * rendered / 441, 441, rendered);
    }
    CHECK(e.sheddingStats().shed >= 1);
}

TEST(the_device_fifo_pulls_the_input_for_each_block_it_renders) {
    // The audio-resilience merge (2026-11-13): the output is always playback-only, so the FIFO stays on with the
    // input open, and the input bridge is read inside the render, block by block: the frames asked for are exactly
    // the frames rendered (not the frames played), each pull at most a chunk, and the input reaches the engine.
    for (const int period : {96, 192, 441, 1023, 1920}) {
        Engine e(48000);
        e.setProject(project({dc(0.25)}));
        e.play();
        e.liveAudio().setDeviceChannels(2);  // as attachCapture does
        DeviceRender dev;
        dev.open(period);
        std::vector<float> out(static_cast<size_t>(period) * 2);
        std::vector<float> in(static_cast<size_t>(DeviceRender::kChunk) * 2, 0.5f);
        int64_t asked = 0, rendered = 0;
        int most = 0;
        bool whole = true;
        for (int k = 0; k < 200; ++k) {
            rendered += dev.render(e, out.data(), period, [&](int m, int& ch) -> const float* {
                asked += m;
                most = std::max(most, m);
                if (dev.usesFifo() && m % kBlock != 0) whole = false;
                ch = 2;
                return in.data();
            });
        }
        CHECK_EQ(asked, rendered);
        CHECK(most <= DeviceRender::kChunk);
        CHECK(whole);  // through the FIFO the engine (and the input) only ever moves in whole blocks
        CHECK(rendered >= int64_t{200} * period - dev.latency());
        float peaks[2] = {};
        CHECK_EQ(e.liveAudio().peaks(peaks, 2), 2);
        CHECK_NEAR(peaks[0], 0.5f, 1e-6f);
    }
}

TEST(the_device_render_takes_the_devices_own_varying_callback_sizes) {
    // The Benchmark on a Galaxy S22+ (2026-11-13): at Low latency AAudio was given no size, and miniaudio's fixed
    // callback fell back to the stream's whole capacity (about 1950 frames) inside one burst's callback. The output
    // now takes AAudio's own sizes (audio_miniaudio.cpp, takesDeviceSizes): DeviceRender opened for varying sizes
    // at the burst, then called with whatever the stream asks, mostly the burst and sometimes not. The path is
    // chosen per callback (the FIFO for a size that suits it or while it holds frames, straight once empty), the
    // sound is the same frames in the same order as a plain render, the FIFO never holds more than the latency it
    // declares (a block short of one, what the input bridge's fill covers), and every frame asked is played.
    for (const int burst : {96, 192, 240, 256}) {
        const ProjectSpec p = project({sine(440.0, 0.5), sine(97.0, 0.25)});
        Engine ref(48000), dev(48000);
        ref.setProject(p);
        dev.setProject(p);
        ref.play();
        dev.play();
        DeviceRender render;
        render.openVarying(burst);
        CHECK_EQ(render.latency(), kBlock - 1);
        int switches = 0;
        bool wasFifo = render.usesFifo();
        const int sizes[] = {burst, burst, burst / 2, burst + burst / 2, 1, burst, 700, burst, 63, 65};
        std::vector<float> played;
        std::vector<float> out(static_cast<size_t>(700) * 2);
        int64_t asked = 0, rendered = 0;
        bool bounded = true;
        for (int k = 0; k < 400; ++k) {
            const int n = sizes[k % 10];
            const int got = render.render(dev, out.data(), n);
            rendered += got;
            asked += n;
            if (render.usesFifo() && (got > n + kBlock - 1 || render.held() > render.latency())) bounded = false;
            if (!render.usesFifo() && got != n) bounded = false;
            if (render.usesFifo() != wasFifo) ++switches;
            wasFifo = render.usesFifo();
            for (int i = 0; i < n; ++i) played.push_back(out[static_cast<size_t>(i) * 2]);
        }
        CHECK(bounded);
        if (!DeviceRender::suits(burst)) CHECK(switches > 0);  // a small odd burst goes straight, and through the FIFO for 700
        CHECK_EQ(static_cast<int64_t>(played.size()), asked);
        CHECK(rendered >= asked && rendered < asked + kBlock);
        const std::vector<float> want = run(ref, asked);
        double most = 0;
        for (size_t i = 0; i < played.size(); ++i) most = std::max(most, static_cast<double>(std::fabs(played[i] - want[i])));
        if (most > 1e-6)
            cawtest::fail(__FILE__, __LINE__, "a " + std::to_string(burst) + "-frame burst's varying callbacks differ by " +
                                                  std::to_string(most) + " from a plain render");
    }
}

TEST(a_callback_that_misses_its_played_deadline_counts_toward_shedding) {
    // The audio review of the merge (2026-11-13): through the FIFO a 256-frame callback that renders 320 frames at
    // its whole budget (a raw load of 1.0: its deadline missed) reads 0.8 a frame rendered, under the 0.85 that
    // counts a callback as over. It counts anyway: shedding goes by the played frames' deadline too.
    Engine e(48000);
    e.setProject(project({dc(0.25), dc(0.5)}));
    e.play();
    float l[256], r[256];
    for (int k = 0; k < 48000 / 256; ++k) {
        e.process(l, r, 256);
        e.reportLoad(1.0, 256, 320);
    }
    CHECK(e.sheddingStats().shed >= 1);
    CHECK_NEAR(e.meters().cpu, 0.8, 0.02);  // the meter still reads the load per frame rendered
    // Under the deadline and under 0.85 a frame: nothing.
    Engine f(48000);
    f.setProject(project({dc(0.25), dc(0.5)}));
    f.play();
    for (int k = 0; k < 48000 * 3 / 256; ++k) {
        f.process(l, r, 256);
        f.reportLoad(0.99, 256, 320);
    }
    CHECK_EQ(f.sheddingStats().shed, 0u);
}

TEST(a_shed_folder_bus_that_is_removed_is_no_longer_counted_shed) {
    // The 2026-11-12 audio review: a shed bus retired through runBusNode without setShed(false), so
    // CawMeters.overloaded and the shed-now count stayed up after it was gone, and recovery kept trying.
    ProjectSpec p = project({dc(0.25)});
    LayerSpec bus;
    bus.id = bus.name = "bus";
    bus.folder = true;
    bus.busEnabled = true;
    LayerSpec child = cawtest::testSignalLayer("child", Shape::Dc, {{"level", 0.5}});
    child.parentId = "bus";
    p.layers.push_back(child);
    p.layers.push_back(bus);  // the newest layer: the one shed
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    run(e, 1000);
    for (int i = 0; i < 40; ++i) e.reportLoad(1.5, 512);
    run(e, 64);
    CHECK_EQ(e.meters().overloaded, 1);
    LayerMeter lm;
    CHECK(e.layerMeter(2, lm) && lm.overloaded);  // the bus
    p.layers.pop_back();
    p.layers.pop_back();
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    run(e, 9600);  // the bus fades out and retires
    CHECK_EQ(e.meters().overloaded, 0);
    CHECK_EQ(e.sheddingStats().mutedNow, 0);
}

TEST(an_offline_render_never_sheds_and_a_shedding_reset_brings_everything_back) {
    ProjectSpec p = project({dc(0.25), dc(0.5)});
    Engine e(48000);
    e.setProjectOffline(p);
    e.play();
    run(e, 1000);
    for (int i = 0; i < 400; ++i) e.reportLoad(5.0, 512);  // an export runs flat out: "over budget" means nothing
    run(e, 64);
    CHECK_EQ(e.meters().overloaded, 0);
    CHECK_EQ(e.sheddingStats().shed, uint64_t{0});
    // Live, shed; then the device reopens (or the app goes to the background): the shed layer comes back at once.
    Engine f(48000);
    f.setProject(p);
    f.play();
    run(f, 1000);
    for (int i = 0; i < 40; ++i) f.reportLoad(1.5, 512);
    run(f, 64);
    CHECK_EQ(f.meters().overloaded, 1);
    f.requestSheddingReset();
    run(f, 64);
    CHECK_EQ(f.meters().overloaded, 0);
    CHECK_EQ(f.meters().cpu, 0.0f);  // the per-callback averages went with it
    for (int i = 0; i < 10; ++i) f.reportLoad(1.5, 512);  // the history went too: 0.1 s more sheds nothing
    run(f, 64);
    CHECK_EQ(f.meters().overloaded, 0);
}
