// Bittern (1.1.3) plays and releases chords through its stops, tremulant, swell box and room, and moves its knobs, without allocating on the audio thread.
#include <cmath>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"

using namespace caw;

TEST(bittern_never_allocates_on_the_audio_thread) {
    for (int tier = 1; tier <= 3; ++tier) {
        ProjectSpec p;
        p.bpm = 120;
        p.loopBars = 1;
        LayerSpec l;
        l.id = "s";
        l.hasInstrument = true;
        l.instrument.id = "org.caw.bittern";
        l.instrument.params = {{"mixture", 0.6}, {"trumpet8", 0.5}, {"celeste8", 0.5}, {"tremulant", 0.4}, {"subbass32", static_cast<double>(tier - 1) * 0.5}};
        p.layers.push_back(l);
        Engine e(48000);
        const std::string set = e.setProject(p);
        if (set.find("\"ok\":true") == std::string::npos) cawtest::fail(__FILE__, __LINE__, set);
        std::vector<float> left(192), right(192);
        for (int id = 0; id < 12; ++id) e.noteOn("s", id, 30 + 6 * id, 0.8);  // warmed
        for (int k = 0; k < 50; ++k) e.process(left.data(), right.data(), 192);
        e.notesOff();
        for (int k = 0; k < 50; ++k) e.process(left.data(), right.data(), 192);
        std::size_t operations = 0;
        double sum = 0;
        for (int round = 0; round < 5; ++round) {
            for (int id = 0; id < 10; ++id) e.noteOn("s", 100 + round * 20 + id, 30 + 6 * id + round, 0.2 + 0.08 * id);
            e.setComponentParam("s", Engine::kInstrumentIndex, "principal8", 0.2 * round);
            e.setComponentParam("s", Engine::kInstrumentIndex, "space", 0.2 * round);
            e.setComponentParam("s", Engine::kInstrumentIndex, "noise", 0.25 * round);
            {
                cawtest::AllocationScope scope;
                for (int k = 0; k < 60; ++k) {
                    e.process(left.data(), right.data(), 192);
                    for (float v : left) sum += std::fabs(v);
                }
                operations += scope.count();
            }
            for (int id = 0; id < 10; ++id) e.noteOff(100 + round * 20 + id);  // the notes end
            cawtest::AllocationScope scope;
            for (int k = 0; k < 40; ++k) e.process(left.data(), right.data(), 192);
            operations += scope.count();
        }
        if (operations != 0) cawtest::fail(__FILE__, __LINE__, "tier " + std::to_string(tier) + " allocated");
        CHECK(sum > 0.0);
        CHECK(std::isfinite(sum));
    }
}
