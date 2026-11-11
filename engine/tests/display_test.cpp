// Live display data (#173): the lock-free DisplayBuffer, its clock, and caw_engine_component_display end to end.
#include <atomic>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "caw.h"
#include "caw/display.hpp"
#include "capi_internal.h"
#include "engine.h"
#include "native_component_test_path.h"
#include "project.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

namespace {

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

constexpr const char* kGain = "org.caw.tests.native-loader.gain";

// A track playing a constant 0.5 through the fixture's gain component (which publishes {blocks, peak}), and the
// same component on the master.
ProjectSpec gainProject() {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    LayerSpec l = cawtest::testSignalLayer("t", cawtest::Shape::Dc, {{"level", 0.5}}, {{kGain, {{"left", 2.0}}}});
    p.layers.push_back(l);
    p.masterComponents = {{kGain, {}}};
    return p;
}

}  // namespace

TEST(a_display_buffer_reads_nothing_before_the_first_publish_then_the_latest_block) {
    DisplayBuffer<8> d;
    float out[16] = {};
    CHECK_EQ(d.read(out, 16), 0u);
    CHECK_EQ(d.sequence(), 0u);
    const float a[3] = {1, 2, 3};
    d.publish(a, 3);
    CHECK_EQ(d.read(out, 16), 3u);
    CHECK_EQ(out[2], 3.0f);
    const float b[12] = {9, 8, 7, 6, 5, 4, 3, 2, 1, 0, -1, -2};
    d.publish(b, 12);  // held to the capacity
    CHECK_EQ(d.read(out, 16), 8u);
    CHECK_EQ(out[7], 2.0f);
    CHECK_EQ(d.read(out, 2), 2u);  // and to what the reader has room for
    CHECK_EQ(out[1], 8.0f);
    CHECK_EQ(d.read(nullptr, 4), 0u);
    CHECK_EQ(d.sequence(), 2u);
    d.clear();
    CHECK_EQ(d.read(out, 16), 0u);
}

TEST(a_display_buffer_never_hands_a_reader_a_torn_block) {
    // The writer publishes blocks whose every float is the block's number, as fast as it can; a reader on
    // another thread must only ever see whole blocks (every float the same) and never go back in time.
    static DisplayBuffer<256> d;  // static: 2 KB, off the test's stack
    d.clear();
    std::atomic<bool> done{false};
    std::thread writer([&] {
        float block[256];
        for (uint32_t k = 1; k <= 200000; ++k) {
            for (float& v : block) v = static_cast<float>(k);
            d.publish(block, 256);
        }
        done.store(true);
    });
    float out[256];
    uint32_t reads = 0, torn = 0;
    float last = 0;
    bool backwards = false;
    while (!done.load()) {
        const uint32_t n = d.read(out, 256);
        if (n == 0) continue;
        ++reads;
        CHECK_EQ(n, 256u);
        for (uint32_t i = 1; i < n; ++i) torn += out[i] != out[0];
        backwards |= out[0] < last;
        last = out[0];
    }
    writer.join();
    CHECK(reads > 0);
    CHECK_EQ(torn, 0u);
    CHECK(!backwards);
    CHECK_EQ(d.read(out, 256), 256u);
    CHECK_EQ(out[255], 200000.0f);
}

TEST(a_display_clock_fires_about_sixty_times_a_second_at_any_block_size) {
    for (uint32_t block : {1u, 37u, 64u, 512u}) {
        DisplayClock c;
        c.prepare(48000.0, 60.0);
        uint32_t fired = 0;
        for (uint32_t done = 0; done < 48000; done += block) fired += c.tick(block);
        CHECK(fired >= 55 && fired <= 61);
    }
}

TEST(a_playing_component_s_display_data_reaches_the_c_api) {
    const char* path = caw::test::nativeComponentPath();
    CHECK(path != nullptr);
    if (!path) return;
    CawEngine* handle = caw_engine_create(48000);
    CHECK(handle != nullptr);
    if (!handle) return;
    Engine& e = *handle->engine;
    CHECK(e.loadNativeComponent(path, kGain, NativeModuleTrust::Trusted).success);
    CHECK(ok(e.setProject(gainProject())));
    float out[8] = {};
    // Nothing yet: built, but not run.
    CHECK_EQ(caw_engine_component_display(handle, "t", 0, out, 8), 0);
    e.play();
    std::vector<float> l(256), r(256);
    for (int k = 0; k < 10; ++k) caw_engine_process(handle, l.data(), r.data(), 256);
    CHECK_EQ(caw_engine_component_display(handle, "t", 0, out, 8), 2);
    CHECK(out[0] >= 10.0f);             // blocks it has processed (the engine runs 64 frames at a time)
    CHECK_NEAR(out[1], 1.0, 1e-6);      // 0.5 x left gain 2
    CHECK_EQ(caw_engine_component_display(handle, nullptr, 0, out, 8), 2);  // the master's
    CHECK(out[0] >= 10.0f);
    CHECK_EQ(caw_engine_component_display(handle, "", 0, out, 1), 1);       // held to max
    // No such component, layer or instrument; bad arguments.
    CHECK_EQ(caw_engine_component_display(handle, "t", 1, out, 8), -1);
    CHECK_EQ(caw_engine_component_display(handle, "nope", 0, out, 8), -1);
    CHECK_EQ(caw_engine_component_display(handle, "t", CAW_INSTRUMENT_INDEX, out, 8), 0);  // the test signal shows none
    CHECK_EQ(caw_engine_component_display(handle, "t", 0, nullptr, 8), 0);
    CHECK_EQ(caw_engine_component_display(handle, "t", 0, out, 0), 0);
    CHECK_EQ(caw_engine_component_display(nullptr, "t", 0, out, 8), -1);
    caw_engine_destroy(handle);
}

TEST(display_reads_never_wait_for_the_audio_thread_or_a_busy_control_thread) {
    // The audio thread plays on another thread while this one reads as fast as it can: every read returns at
    // once with whole data.
    const char* path = caw::test::nativeComponentPath();
    if (!path) return;
    Engine e(48000);
    CHECK(e.loadNativeComponent(path, kGain, NativeModuleTrust::Trusted).success);
    CHECK(ok(e.setProject(gainProject())));
    e.play();
    std::atomic<bool> done{false};
    std::thread audio([&] {
        std::vector<float> l(64), r(64);
        for (int k = 0; k < 20000; ++k) e.process(l.data(), r.data(), 64);
        done.store(true);
    });
    uint32_t got = 0;
    float last = 0;
    bool backwards = false, wrongPeak = false;
    while (!done.load()) {
        float out[2];
        if (e.componentDisplay("t", 0, out, 2) == 2) {
            ++got;
            backwards |= out[0] < last;
            last = out[0];
            wrongPeak |= !(out[1] >= 0.0f && out[1] <= 1.01f);  // 0.5 x 2 (a loop seam may dip it)
        }
    }
    audio.join();
    CHECK(got > 0);
    CHECK(!backwards);
    CHECK(!wrongPeak);
}
