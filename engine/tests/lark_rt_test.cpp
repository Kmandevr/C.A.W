// Chirp (org.caw.pitchfix, 1.1.0) plays, corrects, moves its knobs and publishes its display without allocating on the audio thread.
#include <cmath>
#include <string>
#include <utility>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(lark_never_allocates_on_the_audio_thread) {
    const std::vector<std::vector<std::pair<std::string, double>>> slots = {
        {{"scale", 1}, {"speed", 0}},
        {{"speed", 80}, {"humanize", 1}, {"formant_keep", 0}, {"formant", 4}},
        {{"monitor", 1}, {"target", 1}},
    };
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 205}})});
    for (const auto& params : slots) {
        ComponentSpec c;
        c.id = "org.caw.pitchfix";
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
        for (uint32_t slot = 0; slot < slots.size(); ++slot) {
            e.setComponentParam("t", slot, "speed", 10.0 * round);
            e.setComponentParam("t", slot, "key", round);
            e.setComponentParam("t", slot, "scale", round);
        }
        cawtest::AllocationScope scope;
        for (int k = 0; k < 60; ++k) {
            e.process(left.data(), right.data(), 192);
            for (uint32_t slot = 0; slot < slots.size(); ++slot) e.componentDisplay("t", slot, shown, 256);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    for (float x : left) CHECK(std::isfinite(x));
}
