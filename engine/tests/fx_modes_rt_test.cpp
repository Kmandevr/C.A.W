// 1.1.0's new effect modes (Delay, Reverb, Drive, Bit distortion, Convolver) play, move their knobs and publish their display without allocating on the audio thread.
#include <cmath>
#include <string>
#include <utility>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(the_new_effect_modes_never_allocate_on_the_audio_thread) {
    // Every new variant in one chain on a track (the heaviest settings: pitched taps, 2x oversampling, 4 bands).
    const std::vector<std::pair<std::string, std::vector<std::pair<std::string, double>>>> modes = {
        {"org.caw.delay", {{"variant", 2}, {"wear", 1}}},
        {"org.caw.delay", {{"variant", 3}}},
        {"org.caw.delay", {{"variant", 4}, {"t2_pitch", 7}}},
        {"org.caw.reverb", {{"variant", 2}}},
        {"org.caw.reverb", {{"variant", 3}}},
        {"org.caw.reverb", {{"variant", 4}}},
        {"org.caw.reverb", {{"variant", 5}}},
        {"org.caw.reverb", {{"variant", 6}}},
        {"org.caw.drive", {{"variant", 4}, {"voicing", 3}}},
        {"org.caw.drive", {{"variant", 5}, {"type", 2}}},
        {"org.caw.drive", {{"variant", 6}, {"bands", 3}}},
        {"org.caw.bits", {{"variant", 1}, {"xor", 240}}},
        {"org.caw.convolver", {{"variant", 1}}},
    };
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
    for (const auto& [id, params] : modes) {
        ComponentSpec c;
        c.id = id;
        c.params = params;
        c.params.emplace_back("mix", 0.3);
        p.layers[0].components.push_back(c);
    }
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> left(192), right(192);
    for (int k = 0; k < 100; ++k) e.process(left.data(), right.data(), 192);
    std::size_t operations = 0;
    float shown[128];
    for (int round = 0; round < 6; ++round) {
        for (uint32_t slot = 0; slot < modes.size(); ++slot) e.setComponentParam("t", slot, "mix", 0.2 + 0.1 * round);
        e.setComponentParam("t", 0, "time", 100.0 + 50 * round);
        e.setComponentParam("t", 9, "drive", 0.1 * round);
        cawtest::AllocationScope scope;
        for (int k = 0; k < 60; ++k) {
            e.process(left.data(), right.data(), 192);
            for (uint32_t slot = 0; slot < modes.size(); ++slot) e.componentDisplay("t", slot, shown, 128);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    for (float x : left) CHECK(std::isfinite(x));
}
