// 1.1.0's clean-up devices (Preen, Hush) play, move their knobs, change tier and learn, and publish their display without allocating on the audio thread.
#include <cmath>
#include <string>
#include <utility>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(the_clean_devices_never_allocate_on_the_audio_thread) {
    const std::vector<std::pair<std::string, std::vector<std::pair<std::string, double>>>> devices = {
        {"org.caw.clean", {{"variant", 0}}},
        {"org.caw.clean", {{"variant", 1}}},
        {"org.caw.clean", {{"variant", 2}}},
        {"org.caw.vocalclean", {{"variant", 0}}},
        {"org.caw.vocalclean", {{"variant", 1}}},
        {"org.caw.vocalclean", {{"variant", 2}}},
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
    float shown[128];
    for (int round = 0; round < 6; ++round) {
        // Knobs, the tier, monitoring and Learn (on, then off: the profile is published on the audio thread).
        e.setComponentParam("t", 0, "reduction", 6.0 + 3 * round);
        e.setComponentParam("t", 0, "quality", round % 3);
        e.setComponentParam("t", 0, "monitor", round == 4 ? 1 : 0);
        e.setComponentParam("t", 0, "learn", round == 1 || round == 2 ? 1 : 0);
        e.setComponentParam("t", 0, "adaptive", round >= 3 ? 0 : 1);
        e.setComponentParam("t", 1, "harmonics", 4 + 2 * round);
        e.setComponentParam("t", 1, "frequency", round % 4);
        e.setComponentParam("t", 2, "quality", (round + 1) % 3);
        e.setComponentParam("t", 3, "mode", round % 2);
        e.setComponentParam("t", 4, "frequency", 100.0 + 20 * round);
        e.setComponentParam("t", 5, "range", 6.0 + 4 * round);
        cawtest::AllocationScope scope;
        for (int k = 0; k < 60; ++k) {
            e.process(left.data(), right.data(), 192);
            for (uint32_t slot = 0; slot < devices.size(); ++slot) e.componentDisplay("t", slot, shown, 128);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    for (float x : left) CHECK(std::isfinite(x));
}
