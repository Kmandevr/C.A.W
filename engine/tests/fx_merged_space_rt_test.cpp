// FX consolidation part E: Delay and Reverb change variant while playing without allocating on the audio thread.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "builtin_fx_racks.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(a_delay_and_reverb_change_variant_while_playing_without_allocating_on_the_audio_thread) {
    // Delay and Reverb on a track, old ids migrated on the master and a rack holding both reverb variants; each
    // round sends a project with the other variants (a rebuild, crossfaded in), moves knobs and reads the displays.
    auto project = [](int variant) {
        ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
        ComponentSpec delay, reverb, master;
        delay.id = "org.caw.delay";
        delay.params = {{"variant", variant}, {"feedback", 0.5}, {"mix", 0.4}};
        reverb.id = "org.caw.reverb";
        reverb.params = {{"variant", variant}, {"mix", 0.3}};
        p.layers[0].components = {delay, reverb};
        master.id = variant ? "org.caw.delay.pingpong" : "org.caw.shimmer";
        master.params = {{"mix", 0.3}};
        p.masterComponents.push_back(master);
        ComponentSpec rack;
        rack.id = std::string(kFxRackId);
        rack.params = {{"s1_fx", static_cast<double>(rackChildHash("org.caw.reverb"))}, {"s1.variant", 1.0 - variant},
                       {"s2_fx", static_cast<double>(rackChildHash("org.caw.delay.pro"))}};
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
    for (int round = 0; round < 6; ++round) {
        CHECK(e.setProject(project((round + 1) % 2)).find("\"ok\":true") != std::string::npos);
        e.setComponentParam("t", 0, "mix", 0.1 * round);
        e.setComponentParam("t", 1, "size", 0.1 * round);
        cawtest::AllocationScope scope;
        for (int k = 0; k < 120; ++k) {
            e.process(left.data(), right.data(), 192);
            for (uint32_t c = 0; c < 3; ++c) e.componentDisplay("t", c, shown, 1024);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
}
