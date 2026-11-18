// FX consolidation: a merged device never allocates on the audio thread, its variant changed by project updates while playing.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "builtin_fx_racks.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(a_merged_device_changes_variant_while_playing_without_allocating_on_the_audio_thread) {
    // Pitch/Shift on a track, an old id migrated on the master and a rack holding both variants; each round sends a
    // project with the other variant (a rebuild, crossfaded in), moves knobs and reads the display.
    auto project = [](int variant) {
        ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
        ComponentSpec shift, master;
        shift.id = "org.caw.shift";
        shift.params = {{"variant", variant}, {"semitones", 5}, {"shift", 40}};
        p.layers[0].components.push_back(shift);
        master.id = variant ? "org.caw.freqshift" : "org.caw.pitchshift";
        master.params = {{"mix", 0.5}};
        p.masterComponents.push_back(master);
        ComponentSpec rack;
        rack.id = std::string(kFxRackId);
        rack.params = {{"s1_fx", static_cast<double>(rackChildHash("org.caw.shift"))}, {"s1.variant", 1.0 - variant},
                       {"s2_fx", static_cast<double>(rackChildHash("org.caw.pitchshift"))}};
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
        e.setComponentParam("t", 0, round % 2 ? "semitones" : "shift", round);
        cawtest::AllocationScope scope;
        for (int k = 0; k < 120; ++k) {
            e.process(left.data(), right.data(), 192);
            e.componentDisplay("t", 0, shown, 1024);
            e.componentDisplay("t", 1, shown, 1024);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
}
