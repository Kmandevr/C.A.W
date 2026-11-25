// The AutoStacc beta pack (Murmur, Peck, Bend, Molt) plays, moves its knobs, freezes and publishes its display without allocating on the audio thread.
#include <cmath>
#include <string>
#include <utility>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(the_pack_devices_never_allocate_on_the_audio_thread) {
    const std::vector<std::pair<std::string, std::vector<std::pair<std::string, double>>>> devices = {
        {"org.caw.pack.granular", {{"spray", 50}, {"spread", 7}}},
        {"org.caw.pack.glitch", {{"chaos", 0.8}}},
        {"org.caw.pack.warp", {{"depth", 200}}},
        {"org.caw.pack.spectral", {{"blur", 0.3}}},
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
    float shown[1024];
    for (int round = 0; round < 6; ++round) {
        e.setComponentParam("t", 0, "size", 20.0 + 80 * round);
        e.setComponentParam("t", 0, "density", 10.0 + 35 * round);
        e.setComponentParam("t", 0, "freeze", round % 2);
        e.setComponentParam("t", 0, "pitch", -12.0 + 5 * round);
        e.setComponentParam("t", 0, "sync", round);
        e.setComponentParam("t", 0, "buffer", round == 3 ? 1.0 : 2.0);
        e.setComponentParam("t", 1, "grid", round);
        e.setComponentParam("t", 1, "hold", round == 2 ? 1 : 0);
        e.setComponentParam("t", 1, "chaos", 0.2 * round);
        e.setComponentParam("t", 2, "mode", round % 2);
        e.setComponentParam("t", 2, "p3", -1.0 + 0.4 * round);
        e.setComponentParam("t", 2, "cycle", round % 5);
        e.setComponentParam("t", 3, "freeze", round % 2);
        e.setComponentParam("t", 3, "quality", round % 3);
        e.setComponentParam("t", 3, "shift", -200.0 + 100 * round);
        e.setComponentParam("t", 3, "gate", round == 4 ? -40 : -100);
        cawtest::AllocationScope scope;
        for (int k = 0; k < 60; ++k) {
            e.process(left.data(), right.data(), 192);
            for (uint32_t slot = 0; slot < devices.size(); ++slot) e.componentDisplay("t", slot, shown, 1024);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    for (float x : left) CHECK(std::isfinite(x));
}
