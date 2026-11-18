// FX consolidation part C: the merged EQ and Filter change variant while playing without allocating on the audio thread.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "builtin_fx_racks.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(merged_eq_and_filter_change_variant_while_playing_without_allocating_on_the_audio_thread) {
    // EQ and Filter on a track (every variant in turn), old ids migrated on the master and a rack holding both.
    const char* const masterIds[] = {"org.caw.geq", "org.caw.ladder", "org.caw.tilt", "org.caw.nlfilter"};
    auto project = [&](int round) {
        ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
        ComponentSpec eq, filter, master, rack;
        eq.id = "org.caw.eq";
        eq.params = {{"variant", round % 4}, {"output", -2}};
        filter.id = "org.caw.filter";
        filter.params = {{"variant", round % 3}, {"cutoff", 2000}};
        p.layers[0].components = {eq, filter};
        master.id = masterIds[round % 4];
        p.masterComponents.push_back(master);
        rack.id = std::string(kFxRackId);
        rack.params = {{"s1_fx", static_cast<double>(rackChildHash("org.caw.eq"))}, {"s1.variant", 3.0 - round % 4},
                       {"s2_fx", static_cast<double>(rackChildHash("org.caw.filter"))}, {"s2.variant", (round + 1) % 3}};
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
    for (int round = 1; round <= 12; ++round) {
        CHECK(e.setProject(project(round)).find("\"ok\":true") != std::string::npos);
        e.setComponentParam("t", 1, "cutoff", 500 + 100 * round);
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
