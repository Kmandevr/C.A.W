// Woodpecker (1.1.3) plays every instrument through its recorded attacks, crossfades, resonators, motor and dampers at each tier, and moves its knobs, without allocating on the audio thread.
#include <cmath>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"

using namespace caw;

TEST(woodpecker_never_allocates_on_the_audio_thread) {
    for (int variant = 0; variant < 6; ++variant)
        for (int tier = 1; tier <= 3; ++tier) {
            ProjectSpec p;
            p.bpm = 120;
            p.loopBars = 1;
            LayerSpec l;
            l.id = "w";
            l.hasInstrument = true;
            l.instrument.id = "org.caw.woodpecker";
            l.instrument.params = {{"variant", static_cast<double>(variant)}, {"tier", static_cast<double>(tier)}, {"velocity", 1}};
            if (variant == 3) l.instrument.params.push_back({"motor", 5.0});
            p.layers.push_back(l);
            Engine e(48000);
            const std::string set = e.setProject(p);
            if (set.find("\"ok\":true") == std::string::npos) cawtest::fail(__FILE__, __LINE__, set);
            std::vector<float> left(192), right(192);
            for (int id = 0; id < 12; ++id) e.noteOn("w", id, 40 + 5 * id, 0.8);  // the recordings decoded, warmed
            for (int k = 0; k < 50; ++k) e.process(left.data(), right.data(), 192);
            e.notesOff();
            for (int k = 0; k < 50; ++k) e.process(left.data(), right.data(), 192);
            std::size_t operations = 0;
            double sum = 0;
            for (int round = 0; round < 4; ++round) {
                for (int id = 0; id < 10; ++id) e.noteOn("w", 100 + round * 20 + id, 38 + 7 * id + round, 0.15 + 0.09 * id);
                e.setComponentParam("w", Engine::kInstrumentIndex, "hardness", 0.3 * round);
                e.setComponentParam("w", Engine::kInstrumentIndex, "attack", round == 2 ? 0.0 : 1.0);
                if (variant == 3 || variant == 4) e.setComponentParam("w", Engine::kInstrumentIndex, "sustain", round % 2 ? 1.0 : 0.0);
                {
                    cawtest::AllocationScope scope;
                    for (int k = 0; k < 60; ++k) {
                        e.process(left.data(), right.data(), 192);
                        for (float v : left) sum += std::fabs(v);
                    }
                    operations += scope.count();
                }
                for (int id = 0; id < 10; ++id) e.noteOff(100 + round * 20 + id);  // the dampers
                cawtest::AllocationScope scope;
                for (int k = 0; k < 40; ++k) e.process(left.data(), right.data(), 192);
                operations += scope.count();
            }
            if (operations != 0)
                cawtest::fail(__FILE__, __LINE__, "variant " + std::to_string(variant) + " tier " + std::to_string(tier) + " allocated");
            CHECK(sum > 0.0);
            CHECK(std::isfinite(sum));
        }
}
