// Timber (org.caw.timber) plays every model, takes notes, the pedal and the mod wheel, moves its knobs and publishes its display without allocating on the audio thread.
#include <cmath>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "builtin_timber.h"
#include "engine.h"
#include "fx_merged.h"
#include "test.h"

using namespace caw;

TEST(timber_never_allocates_on_the_audio_thread) {
    const fx::MergedDevice* m = fx::findMergedDevice("org.caw.timber");
    CHECK(m != nullptr);
    for (uint32_t model = 0; m && model < m->variants.size(); ++model) {
        ProjectSpec p;
        p.bpm = 120;
        p.loopBars = 1;
        LayerSpec l;
        l.id = "t";
        l.hasInstrument = true;
        l.instrument.id = "org.caw.timber";
        l.instrument.params = {{"variant", static_cast<double>(model)}, {"space", 0.3}};
        p.layers.push_back(l);
        Engine e(48000);
        const std::string set = e.setProject(p);
        if (set.find("\"ok\":true") == std::string::npos) cawtest::fail(__FILE__, __LINE__, set);
        std::vector<float> left(192), right(192);
        // Warm up: the first notes of each key range, off the measured stretch.
        for (int id = 0; id < 12; ++id) e.noteOn("t", id, 30 + 6 * id, 0.8);
        for (int k = 0; k < 50; ++k) e.process(left.data(), right.data(), 192);
        e.notesOff();
        for (int k = 0; k < 50; ++k) e.process(left.data(), right.data(), 192);
        std::size_t operations = 0;
        float shown[64];
        double sum = 0;
        for (int round = 0; round < 5; ++round) {
            for (int id = 0; id < 10; ++id) e.noteOn("t", 100 + round * 10 + id, 36 + 5 * id + round, 0.3 + 0.07 * id);
            e.setComponentParam("t", Engine::kInstrumentIndex, "tone", -0.5 + 0.25 * round);
            e.setComponentParam("t", Engine::kInstrumentIndex, "voices", 3 + round * 4);
            e.setComponentParam("t", Engine::kInstrumentIndex, "space", 0.1 * round);
            {
                cawtest::AllocationScope scope;
                for (int k = 0; k < 60; ++k) {
                    e.process(left.data(), right.data(), 192);
                    e.componentDisplay("t", Engine::kInstrumentIndex, shown, 64);
                    for (float v : left) sum += std::fabs(v);
                }
                operations += scope.count();
            }
            for (int id = 0; id < 10; ++id) e.noteOff(100 + round * 10 + id);
            cawtest::AllocationScope scope;
            for (int k = 0; k < 40; ++k) e.process(left.data(), right.data(), 192);
            operations += scope.count();
        }
        if (operations != 0) cawtest::fail(__FILE__, __LINE__, "model " + std::to_string(model) + " allocated");
        CHECK(sum > 0.0);
        CHECK(std::isfinite(sum));
    }
}
