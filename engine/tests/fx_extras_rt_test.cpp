// 1.1.0's "Around the effects" on the audio thread: arming, the sidechain filter, the Limiter's target and per-slot timing never allocate.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"

using namespace caw;

namespace {
std::string extrasProject(bool armed, int round) {
    const std::string r = std::to_string(round % 3);
    return "{\"caw_project\":1,\"bpm\":120,\"loop_bars\":1,\"master\":1,\"layers\":["
           "{\"id\":\"k\",\"volume\":1,\"mute\":true,\"instrument\":{\"id\":\"org.caw.test.osc\",\"params\":{\"shape\":1,\"freq\":55,\"level\":0.8}}},"
           "{\"id\":\"t\",\"name\":\"T\",\"volume\":1,"
           "\"input\":{\"channel\":0,\"channels\":1,\"monitor\":\"on\",\"armed\":" + std::string(armed ? "true" : "false") + "},"
           "\"components\":["
           "{\"id\":\"org.caw.duck\",\"params\":{\"variant\":0,\"sidechain\":1,\"sc_hpf\":" + std::to_string(60 + 40 * round) +
           ",\"sc_lpf\":4000,\"sc_listen\":" + std::to_string(round % 2) + "},\"key\":{\"layer\":\"k\"}},"
           "{\"id\":\"org.caw.eq\",\"params\":{\"variant\":4,\"b4_gain\":" + r + ",\"lin_quality\":" + r + "}},"
           "{\"id\":\"org.caw.clean\",\"params\":{\"variant\":0,\"quality\":" + r + "}},"
           "{\"id\":\"org.caw.shift\",\"params\":{\"variant\":0,\"grain\":60}},"
           "{\"id\":\"org.caw.limiter\",\"params\":{\"target_on\":1,\"target\":-14}}]}]}";
}
}  // namespace

TEST(arming_the_sidechain_filter_the_loudness_target_and_slot_timing_never_allocate_on_the_audio_thread) {
    Engine e(48000);
    CHECK(e.setProjectJson(extrasProject(false, 0)).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> left(192), right(192), in(192);
    uint32_t seed = 1;
    // One callback: the device input (noise, monitored through the armed track), then the mix.
    auto callback = [&] {
        for (float& x : in) seed = seed * 1664525u + 1013904223u, x = static_cast<float>(seed >> 8) / 16777216.0f - 0.5f;
        e.liveAudio().beginCallback(in.data(), 1, 192);
        e.process(left.data(), right.data(), 192);
        e.liveAudio().afterCallback(left.data(), right.data(), 192);
    };
    for (int k = 0; k < 100; ++k) callback();
    std::size_t operations = 0;
    float shown[1024];
    double share = 0;
    uint32_t latency = 0;
    bool armed = false;
    for (int round = 1; round <= 6; ++round) {
        // Armed and disarmed in turn: the effects switch versions while the song plays.
        CHECK(e.setProjectJson(extrasProject(round % 2 == 1, round)).find("\"ok\":true") != std::string::npos);
        for (uint32_t c = 0; c < 5; ++c) CHECK_EQ(e.componentCost("t", c, share, latency, armed), 1);  // timing on
        for (int step = 0; step < 4; ++step) {
            e.setComponentParam("t", 0, "sc_lpf", 2000.0 + 500.0 * step);
            cawtest::AllocationScope scope;
            for (int k = 0; k < 60; ++k) {
                callback();
                e.componentDisplay("t", 4, shown, 1024);
            }
            operations += scope.count();
        }
    }
    CHECK_EQ(operations, 0u);
}
