// #127: per-note FX never allocate or free on the audio thread (slots, steals, overflow, tails, rack swaps, knobs).
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;
using cawtest::Shape;

TEST(per_note_fx_never_allocate_on_the_audio_thread) {
    Engine e(48000.0);
    auto spec = [](const std::string& id) {
        ComponentSpec c;
        c.id = id;
        return c;
    };
    LayerSpec l = cawtest::testSignalNotesLayer("keys", Shape::Saw, "pat", {{"level", 0.4}});
    l.noteComponents = {spec("org.caw.filter"), spec("org.caw.delay.pro")};
    l.noteVoices = 3;
    LayerSpec flag;
    flag.id = "syn";
    flag.name = "syn";
    flag.hasInstrument = true;
    flag.instrument = spec("org.caw.synth.flagship");
    flag.noteComponents = {spec("org.caw.saturator")};
    flag.noteVoices = 2;
    flag.pattern = "pat";
    ProjectSpec p = cawtest::testSignalProject({l, flag});
    p.modules.push_back({"pat", "---\nkind: pattern\n---\n0 C3 3 1 bend 0:0 1:2\n1 G3 2 0.7 press 0:0 1:1\n2 E4 2 0.8\n"
                                "3 B4 1 1\n4 C4 4 0.6\n6 D4,F4,A4 2 0.9\n"});
    ModLinkSpec link;
    link.id = 1;
    link.source = "note.pitch";
    link.target = {"noteComponent", "keys", "cutoff", 0};
    link.amount = 0.5;
    ModLinkSpec age = link;
    age.id = 2;
    age.source = "note.age";
    age.target.param = "resonance";
    ModulatorSpec lfo;
    lfo.id = "lfo";
    lfo.component.id = "org.caw.mod.lfo";
    ModLinkSpec global = link;
    global.id = 3;
    global.source = "lfo";
    p.modulators = {lfo};
    p.modulation = {link, age, global};
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> lb(192), rb(192);
    std::size_t operations = 0;
    for (int round = 0; round < 5; ++round) {
        {
            cawtest::AllocationScope scope;
            for (int k = 0; k < 600; ++k) e.process(lb.data(), rb.data(), k % 3 == 0 ? 37 : 192);
            operations += scope.count();
        }
        // Control thread between rounds: notes, knob moves, a quality change, and project updates that keep the
        // racks, swap one in (new components), change the voices, and turn per-note FX off and on again.
        e.noteOn("keys", round + 1, 60.0 + round, 0.8);
        e.setComponentParam("keys", Engine::kNoteComponentFlag | 0u, "cutoff", 400.0 + 300.0 * round);
        e.setQuality(round % 3);
        e.setModulationAmount(1, -0.2 * round);
        if (round == 1) p.layers[0].noteComponents.push_back(spec("org.caw.utility"));
        if (round == 2) p.layers[0].noteVoices = 5;
        if (round == 3) p.layers[1].noteComponents.clear();
        if (round == 4) p.layers[1].noteComponents = {spec("org.caw.filter")};
        CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    }
    CHECK_EQ(operations, 0u);
}
