// MIDI effects (1.1.0) never allocate or free on the audio thread: notes, arpeggio steps, echoes, knobs, chain swaps.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;
using cawtest::Shape;

TEST(midi_fx_never_allocate_on_the_audio_thread) {
    Engine e(48000.0);
    auto spec = [](const std::string& id, std::vector<std::pair<std::string, double>> v = {}) {
        ComponentSpec c;
        c.id = id;
        c.params = std::move(v);
        return c;
    };
    LayerSpec l = cawtest::testSignalNotesLayer("keys", Shape::Saw, "pat", {{"level", 0.4}});
    l.midiComponents = {spec("org.caw.midi.scale"), spec("org.caw.midi.chords", {{"strum", 12}}),
                        spec("org.caw.midi.arp", {{"pattern", 5}, {"octaves", 3}}), spec("org.caw.midi.echo", {{"repeats", 8}}),
                        spec("org.caw.midi.humanize")};
    ProjectSpec p = cawtest::testSignalProject({l});
    p.modules.push_back({"pat", "---\nkind: pattern\n---\n0 C3 3 1 bend 0:0 1:2\n1 G3 2 0.7\n2 E4 2 0.8\n4 C4,E4,G4 4 0.6\n"});
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
        e.noteOn("keys", round + 1, 60.0 + round, 0.8);
        e.setComponentParam("keys", Engine::kMidiComponentFlag | 2u, "rate", round % 4);
        e.setComponentBypass("keys", Engine::kMidiComponentFlag | 3u, round % 2 == 1);
        if (round == 1) p.layers[0].midiComponents.pop_back();  // a chain swap (crossfaded)
        if (round == 3) p.layers[0].midiComponents.clear();
        if (round == 4) p.layers[0].midiComponents = {spec("org.caw.midi.arp", {{"hold", 1}})};
        CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    }
    CHECK_EQ(operations, 0u);
}
