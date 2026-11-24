// Timber's Simulated piano (1.1.2) at each tier plays notes, the pedal (its noises and the register bank), silent held keys, the action and glide, and moves its knobs without allocating on the audio thread.
#include <cmath>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"

using namespace caw;

TEST(timber_simulated_piano_never_allocates_on_the_audio_thread) {
    for (int tier = 1; tier <= 3; ++tier) {
        ProjectSpec p;
        p.bpm = 120;
        p.loopBars = 1;
        LayerSpec l;
        l.id = "t";
        l.hasInstrument = true;
        l.instrument.id = "org.caw.timber";
        l.instrument.params = {{"variant", 0}, {"sim", 1}, {"tier", static_cast<double>(tier)}, {"space", 0.3}, {"noise", 1},
                               {"touch", 1}, {"action", 1}, {"sympathy", 1}, {"glide", 1}, {"phantom", 1}, {"velocity", 1}};
        p.layers.push_back(l);
        Engine e(48000);
        const std::string set = e.setProject(p);
        if (set.find("\"ok\":true") == std::string::npos) cawtest::fail(__FILE__, __LINE__, set);
        std::vector<float> left(192), right(192);
        for (int id = 0; id < 12; ++id) e.noteOn("t", id, 30 + 6 * id, 0.8);
        for (int k = 0; k < 50; ++k) e.process(left.data(), right.data(), 192);
        e.notesOff();
        for (int k = 0; k < 50; ++k) e.process(left.data(), right.data(), 192);
        std::size_t operations = 0;
        float shown[64];
        double sum = 0;
        for (int round = 0; round < 5; ++round) {
            e.noteOn("t", 99 + round * 20, 48 + round, 0.01);  // a key held down silently (its strings listen)
            for (int id = 0; id < 10; ++id) e.noteOn("t", 100 + round * 20 + id, 30 + 6 * id + round, 0.3 + 0.07 * id);
            e.setComponentParam("t", Engine::kInstrumentIndex, "sustain", round % 2 ? 1.0 : 0.0);  // the pedal: its noise
            e.setComponentParam("t", Engine::kInstrumentIndex, "tone", -0.5 + 0.25 * round);
            e.setComponentParam("t", Engine::kInstrumentIndex, "noise", 0.2 * round);
            {
                cawtest::AllocationScope scope;
                for (int k = 0; k < 60; ++k) {
                    e.process(left.data(), right.data(), 192);
                    e.componentDisplay("t", Engine::kInstrumentIndex, shown, 64);
                    for (float v : left) sum += std::fabs(v);
                }
                operations += scope.count();
            }
            for (int id = 0; id < 10; ++id) e.noteOff(100 + round * 20 + id);  // the dampers land
            e.noteOff(99 + round * 20);
            cawtest::AllocationScope scope;
            for (int k = 0; k < 40; ++k) e.process(left.data(), right.data(), 192);
            operations += scope.count();
        }
        if (operations != 0) cawtest::fail(__FILE__, __LINE__, "tier " + std::to_string(tier) + " allocated");
        CHECK(sum > 0.0);
        CHECK(std::isfinite(sum));
    }
}
