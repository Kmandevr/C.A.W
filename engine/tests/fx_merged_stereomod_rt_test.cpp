// FX consolidation part D: the Utility/Stereo, Chorus/Flanger and Tremolo/Pan variants change while playing without allocating on the audio thread.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "builtin_fx_racks.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(stereomod_devices_change_variant_while_playing_without_allocating_on_the_audio_thread) {
    // Each device on a track walks through its variants, an old id migrated on the master, a rack slot changing
    // variant; knobs move and displays are read.
    auto project = [](int round) {
        ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
        for (const auto& [id, count] : {std::pair<const char*, int>{"org.caw.utility", 6}, {"org.caw.chorus", 6},
                                        {"org.caw.phaser", 1}, {"org.caw.tremolo", 2}}) {
            ComponentSpec c;
            c.id = id;
            c.params = {{"variant", static_cast<double>(round % count)}};
            p.layers[0].components.push_back(c);
        }
        ComponentSpec master;
        master.id = round % 2 ? "org.caw.autopan" : "org.caw.stereo.width";
        p.masterComponents.push_back(master);
        ComponentSpec rack;
        rack.id = std::string(kFxRackId);
        rack.params = {{"s1_fx", static_cast<double>(rackChildHash("org.caw.chorus"))}, {"s1.variant", static_cast<double>(round % 6)},
                       {"s2_fx", static_cast<double>(rackChildHash("org.caw.haas"))}};
        p.layers[0].components.push_back(rack);
        return p;
    };
    Engine e(48000);
    CHECK(e.setProject(project(0)).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> left(192), right(192);
    for (int k = 0; k < 100; ++k) e.process(left.data(), right.data(), 192);
    std::size_t operations = 0;
    float shown[1024];
    for (int round = 1; round <= 7; ++round) {
        CHECK(e.setProject(project(round)).find("\"ok\":true") != std::string::npos);
        e.setComponentParam("t", 1, "mix", 0.1 * round);
        cawtest::AllocationScope scope;
        for (int k = 0; k < 120; ++k) {
            e.process(left.data(), right.data(), 192);
            for (int c = 0; c < 5; ++c) e.componentDisplay("t", c, shown, 1024);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
}
