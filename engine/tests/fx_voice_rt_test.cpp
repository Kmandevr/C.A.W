// 1.1.0's voice devices (Glint, Soar's Harmonizer and Octaver, Mimic) play, move their knobs and publish their display without allocating on the audio thread.
#include <cmath>
#include <string>
#include <utility>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(the_voice_devices_never_allocate_on_the_audio_thread) {
    const std::vector<std::pair<std::string, std::vector<std::pair<std::string, double>>>> devices = {
        {"org.caw.exciter", {{"variant", 0}}},
        {"org.caw.exciter", {{"variant", 1}, {"density", 1}}},
        {"org.caw.shift", {{"variant", 2}, {"voices", 4}}},
        {"org.caw.shift", {{"variant", 3}, {"up", 0.5}}},
        {"org.caw.vocoder", {{"unison", 3}, {"bands", 3}}},
        {"org.caw.vocoder", {{"carrier", 1}}},
    };
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
    for (const auto& [id, params] : devices) {
        ComponentSpec c;
        c.id = id;
        c.params = params;
        p.layers[0].components.push_back(c);
    }
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> left(192), right(192);
    for (int k = 0; k < 100; ++k) e.process(left.data(), right.data(), 192);
    std::size_t operations = 0;
    float shown[256];
    for (int round = 0; round < 6; ++round) {
        for (uint32_t slot = 0; slot < devices.size(); ++slot) {
            const char* knob = slot < 2 ? "amount" : (slot < 4 ? "output" : "formant");
            e.setComponentParam("t", slot, knob, 0.2 + 0.1 * round);
        }
        cawtest::AllocationScope scope;
        for (int k = 0; k < 60; ++k) {
            e.process(left.data(), right.data(), 192);
            for (uint32_t slot = 0; slot < devices.size(); ++slot) e.componentDisplay("t", slot, shown, 256);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    for (float x : left) CHECK(std::isfinite(x));
}
