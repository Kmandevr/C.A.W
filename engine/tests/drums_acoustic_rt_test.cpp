// Rook 1.1.2: the Acoustic kits play every articulation, take the hat pedal (CC 4) and cymbal chokes, and move their pieces' knobs without allocating or lazily initialising on the audio thread.
#include <cmath>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "builtin_drums_layout.h"
#include "engine.h"
#include "presets.h"
#include "test.h"

using namespace caw;

TEST(rook_acoustic_kits_never_allocate_on_the_audio_thread) {
    int kits = 0;
    for (const BuiltinPreset& preset : builtinPresets("org.caw.drums")) {
        const std::string name(preset.name);
        if (name.rfind("Acoustic kit: ", 0) != 0 && name != "Produced kit: House") continue;
        ++kits;
        ProjectSpec p;
        p.bpm = 120;
        p.loopBars = 1;
        LayerSpec l;
        l.id = "t";
        l.hasInstrument = true;
        l.instrument.id = "org.caw.drums";
        for (const auto& [id, v] : preset.values) l.instrument.params.emplace_back(std::string(id), v);
        // a Layers pad (B1) with an acoustic layer, so that path runs too
        l.instrument.params.push_back({"b1_body_on", 1});
        l.instrument.params.push_back({"b1_acou_layer", 1});
        l.instrument.params.push_back({"b1_note", drums::kNoteFirst + 60});
        p.layers.push_back(l);
        Engine e(48000);
        const std::string set = e.setProject(p);
        if (set.find("\"ok\":true") == std::string::npos) cawtest::fail(__FILE__, __LINE__, set);
        std::vector<float> left(192), right(192);
        // Warm up: every piece once (each configures on its first stroke), off the measured stretch.
        for (int key = 12; key <= 60; ++key) e.noteOn("t", 1000 + key, key, 0.8);
        for (int k = 0; k < 50; ++k) e.process(left.data(), right.data(), 192);
        e.notesOff();
        const long long lazyBefore = cawtest::threadLazyInits();
        std::size_t operations = 0;
        double sum = 0;
        for (int round = 0; round < 4; ++round) {
            cawtest::AllocationScope scope;
            const int keys[] = {36, 38, 42, 46, 44, 49, 51, 53, 12, 13, 14, 17, 45, 43, 60};
            int id = 2000 + round * 100;
            for (int key : keys) e.noteOn("t", id++, key, 0.4 + 0.15 * round);
            for (int k = 0; k < 30; ++k) {
                e.process(left.data(), right.data(), 192);
                for (float v : left) sum += std::fabs(v);
            }
            e.setComponentParam("t", Engine::kInstrumentIndex, "acou_hat_pedal", round & 1 ? 0.2 : 1.0);
            e.setComponentParam("t", Engine::kInstrumentIndex, "pc2_tune", -3.0 + 2.0 * round);
            e.setComponentParam("t", Engine::kInstrumentIndex, "acou_mics", round);
            for (int k = 0; k < 30; ++k) e.process(left.data(), right.data(), 192);
            for (int k = 2000 + round * 100; k < id; ++k) e.noteOff(k);
            for (int k = 0; k < 20; ++k) e.process(left.data(), right.data(), 192);
            operations += scope.count();
        }
        if (operations != 0) cawtest::fail(__FILE__, __LINE__, name + " allocated on the audio thread");
        const long long lazyAfter = cawtest::threadLazyInits();
        if (lazyBefore >= 0 && lazyAfter != lazyBefore) cawtest::fail(__FILE__, __LINE__, name + " initialised a static lazily");
        CHECK(sum > 0.0);
        CHECK(std::isfinite(sum));
    }
    CHECK(kits >= 9);
}
