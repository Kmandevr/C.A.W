// Flock (org.caw.flock) plays its built-in tones and a sample, takes notes and bends, moves its knobs (the tone, the voice cap, the grains) and publishes its display without allocating on the audio thread.
#include <cmath>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"

using namespace caw;

TEST(flock_never_allocates_on_the_audio_thread) {
    for (int kind = 0; kind < 4; ++kind) {
        ProjectSpec p;
        p.bpm = 120;
        p.loopBars = 1;
        LayerSpec l;
        l.id = "f";
        l.hasInstrument = true;
        l.instrument.id = "org.caw.flock";
        l.instrument.params = {{"builtin", static_cast<double>(kind)}, {"voices", 16}, {"spread", 12}, {"pitch", 12}};
        p.layers.push_back(l);
        Engine e(48000);
        const std::string set = e.setProject(p);
        if (set.find("\"ok\":true") == std::string::npos) cawtest::fail(__FILE__, __LINE__, set);
        std::vector<float> left(192), right(192);
        for (int id = 0; id < 12; ++id) e.noteOn("f", id, 30 + 6 * id, 0.8);  // warm up
        for (int k = 0; k < 50; ++k) e.process(left.data(), right.data(), 192);
        e.notesOff();
        for (int k = 0; k < 200; ++k) e.process(left.data(), right.data(), 192);
        std::size_t operations = 0;
        float shown[1024];
        double sum = 0;
        for (int round = 0; round < 5; ++round) {
            for (int id = 0; id < 18; ++id) e.noteOn("f", 100 + round * 20 + id, 36 + 3 * id + round, 0.3 + 0.04 * id);
            e.setComponentParam("f", Engine::kInstrumentIndex, "voices", 3 + round * 3);
            e.setComponentParam("f", Engine::kInstrumentIndex, "size", 20 + 80 * round);
            e.setComponentParam("f", Engine::kInstrumentIndex, "density", 10 + 40 * round);
            e.setComponentParam("f", Engine::kInstrumentIndex, "pitch", -24 + 12 * round);
            e.setComponentParam("f", Engine::kInstrumentIndex, "filter", round % 4);
            {
                cawtest::AllocationScope scope;
                for (int k = 0; k < 60; ++k) {
                    e.process(left.data(), right.data(), 192);
                    e.componentDisplay("f", Engine::kInstrumentIndex, shown, 1024);
                    for (float v : left) sum += std::fabs(v);
                }
                operations += scope.count();
            }
            for (int id = 0; id < 18; ++id) e.noteOff(100 + round * 20 + id);
            cawtest::AllocationScope scope;
            for (int k = 0; k < 100; ++k) e.process(left.data(), right.data(), 192);
            operations += scope.count();
        }
        if (operations != 0) cawtest::fail(__FILE__, __LINE__, "tone " + std::to_string(kind) + " allocated");
        CHECK(sum > 0.0);
        CHECK(std::isfinite(sum));
    }
}
