// FX consolidation, part A, and 1.1.0's split: the Compressor, Gate and Ducker change variant (keyed, plain, key notes) while playing without allocating on the audio thread.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "builtin_fx_racks.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(the_merged_compressor_changes_variant_while_playing_without_allocating_on_the_audio_thread) {
    // A keyed Compressor on track t (key: track k's audio and notes) cycling through its four variants, an old
    // ducker migrated on the master, a rack holding a Compressor child whose variant changes too, and the Limiter
    // and Transient; each round sends the next variant (a rebuild, crossfaded in), moves a knob and reads displays.
    auto project = [](int variant) {
        ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("k", cawtest::Shape::Square, {{"freq", 2}}),
                                                    cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
        p.modules.push_back({"beats", "---\nkind: pattern\n---\n0 C4 1\n4 C4 1\n8 C4 1\n"});
        p.layers[0].pattern = "beats";
        ComponentSpec comp;
        comp.id = "org.caw.compressor";
        comp.params = {{"variant", variant}, {"talon_layout", 1}};  // 1.1.0: Down, Dynamics, Up, Bus
        comp.hasKey = true;
        comp.key.layer = "k";
        p.layers[1].components.push_back(comp);
        ComponentSpec rack;
        rack.id = std::string(kFxRackId);
        rack.params = {{"s1_fx", static_cast<double>(rackChildHash("org.caw.compressor"))}, {"s1.variant", 3 - variant},
                       {"s2_fx", static_cast<double>(rackChildHash("org.caw.gate"))}};
        p.layers[1].components.push_back(rack);
        ComponentSpec lim, tr, master;
        lim.id = "org.caw.limiter";
        tr.id = "org.caw.transient";
        tr.params = {{"attack", 0.5}};
        p.layers[1].components.push_back(tr);
        p.layers[1].components.push_back(lim);
        // 1.1.0's Gate and Ducker cycling through their three variants each, keyed (Level's look-ahead included).
        ComponentSpec gate, duck;
        gate.id = "org.caw.gate";
        gate.params = {{"variant", variant % 3}, {"sidechain", 1}};
        gate.hasKey = true;
        gate.key.layer = "k";
        duck.id = "org.caw.duck";
        duck.params = {{"variant", (variant + 1) % 3}, {"lookahead", 2}};
        duck.hasKey = true;
        duck.key.layer = "k";
        p.layers[1].components.push_back(gate);
        p.layers[1].components.push_back(duck);
        master.id = variant % 2 ? "org.caw.ducker" : "org.caw.dynamics";
        master.params = {{"mix", 0.5}};
        p.masterComponents.push_back(master);
        return p;
    };
    Engine e(48000);
    CHECK(e.setProject(project(0)).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> left(192), right(192);
    for (int k = 0; k < 100; ++k) e.process(left.data(), right.data(), 192);
    std::size_t operations = 0;
    float shown[1024];
    for (int round = 0; round < 8; ++round) {
        CHECK(e.setProject(project((round + 1) % 4)).find("\"ok\":true") != std::string::npos);
        e.setComponentParam("t", 2, "attack", 0.1 * round);
        cawtest::AllocationScope scope;
        for (int k = 0; k < 120; ++k) {
            e.process(left.data(), right.data(), 192);
            e.componentDisplay("t", 0, shown, 1024);
            e.componentDisplay("t", 1, shown, 1024);
            e.componentDisplay("t", 4, shown, 1024);
            e.componentDisplay("t", 5, shown, 1024);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
}
