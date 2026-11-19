// 1.1.0's EQ and Filter additions play, redesign and learn on a track without allocating on the audio thread.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(plume_and_wah_play_redesign_and_learn_without_allocating_on_the_audio_thread) {
    // Bands with dynamic bands and solo, Linear (redesigning as a band moves, at each quality), Match learning
    // and the Wah's pedal moving.
    auto project = [](int round) {
        ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
        ComponentSpec bands, linear, match, wah;
        bands.id = linear.id = match.id = "org.caw.eq";
        bands.params = {{"b3_dyn", 1}, {"b3_thresh", -40}, {"b6_dyn", 1}, {"b6_key", 4}, {"solo_band", round % 3}};
        linear.params = {{"variant", 4}, {"lin_quality", round % 3}, {"b4_gain", 3}, {"match", 1}};
        match.params = {{"variant", 5}, {"match_learn", round % 2 ? 3 : 0}};
        wah.id = "org.caw.filter";
        wah.params = {{"variant", 3}, {"mode", round % 2}};
        p.layers[0].components = {bands, linear, match, wah};
        return p;
    };
    Engine e(48000);
    CHECK(e.setProject(project(0)).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> left(192), right(192);
    for (int k = 0; k < 100; ++k) e.process(left.data(), right.data(), 192);
    std::size_t operations = 0;
    float shown[1024];
    for (int round = 1; round <= 6; ++round) {
        CHECK(e.setProject(project(round)).find("\"ok\":true") != std::string::npos);
        for (int step = 0; step < 4; ++step) {
            e.setComponentParam("t", 1, "b4_gain", step - round * 0.5);
            e.setComponentParam("t", 0, "b3_thresh", -40.0 + step);
            e.setComponentParam("t", 3, "pedal", 0.2 * step);
            cawtest::AllocationScope scope;
            for (int k = 0; k < 60; ++k) {
                e.process(left.data(), right.data(), 192);
                for (uint32_t c = 0; c < 4; ++c) e.componentDisplay("t", c, shown, 1024);
            }
            operations += scope.count();
        }
    }
    CHECK_EQ(operations, 0u);
}
