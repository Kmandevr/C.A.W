// 1.0.8: per-slot auto gain, slot meters and the Compressor's Duck variant play, toggle and are read without allocating on the audio thread.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(auto_gain_slot_meters_and_the_duck_never_allocate_on_the_audio_thread) {
    // A keyed Duck on track t (key: track k) with auto gain on, a utility after it, and auto gain on the master;
    // each round toggles auto gain on both, moves a knob, Plays again and reads the trims, meters and display.
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("k", cawtest::Shape::Square, {{"freq", 2}}),
                                                cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
    ComponentSpec duck;
    duck.id = "org.caw.compressor";
    duck.params = {{"variant", 4}, {"sidechain", 1}, {"detection", 2}, {"threshold", -30}};
    duck.hasKey = true;
    duck.key.layer = "k";
    duck.autoGain = true;
    ComponentSpec util;
    util.id = "org.caw.utility";
    util.params = {{"gain", 6}};
    p.layers[1].components = {duck, util};
    ComponentSpec master = util;
    master.autoGain = true;
    p.masterComponents.push_back(master);
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> left(192), right(192);
    for (int k = 0; k < 100; ++k) e.process(left.data(), right.data(), 192);
    std::size_t operations = 0;
    float shown[64];
    for (int round = 0; round < 8; ++round) {
        CHECK(e.setComponentAutoGain("t", 0, round % 2 == 0));
        CHECK(e.setComponentAutoGain("t", 1, round % 3 == 0));
        CHECK(e.setComponentAutoGain("", 0, round % 2 == 1));
        e.setComponentParam("t", 0, "amount", 0.1 * round);
        if (round == 4) e.play();
        cawtest::AllocationScope scope;
        for (int k = 0; k < 120; ++k) {
            e.process(left.data(), right.data(), 192);
            float db = 0, l = 0, r = 0;
            bool clipped = false;
            e.componentAutoGain("t", 0, db);
            e.componentAutoGain("", 0, db);
            e.componentMeter("t", 0, l, r, clipped);
            e.componentMeter("t", 1, l, r, clipped);
            e.componentMeter("", 0, l, r, clipped);
            e.componentDisplay("t", 0, shown, 64);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
}
