// Starling's piano (1.1.3) plays notes through its recorded attacks, key releases and pedal noises at each tier, and moves its knobs, without allocating on the audio thread.
#include <cmath>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "recorded_bank.h"
#include "engine.h"
#include "test.h"

using namespace caw;

TEST(starling_piano_never_allocates_on_the_audio_thread) {
    for (int tier = 1; tier <= 3; ++tier) {
        ProjectSpec p;
        p.bpm = 120;
        p.loopBars = 1;
        LayerSpec l;
        l.id = "s";
        l.hasInstrument = true;
        l.instrument.id = "org.caw.starling";
        l.instrument.params = {{"variant", 0}, {"tier", static_cast<double>(tier)}, {"noise", 1}, {"touch", 1},
                               {"action", 1}, {"sympathy", 1}, {"velocity", 1}};
        p.layers.push_back(l);
        Engine e(48000);
        const std::string set = e.setProject(p);
        if (set.find("\"ok\":true") == std::string::npos) cawtest::fail(__FILE__, __LINE__, set);
        std::vector<float> left(192), right(192);
        for (int id = 0; id < 12; ++id) e.noteOn("s", id, 30 + 6 * id, 0.8);  // the recordings decoded, warmed
        for (int k = 0; k < 50; ++k) e.process(left.data(), right.data(), 192);
        e.notesOff();
        for (int k = 0; k < 50; ++k) e.process(left.data(), right.data(), 192);
        std::size_t operations = 0;
        double sum = 0;
        for (int round = 0; round < 5; ++round) {
            for (int id = 0; id < 10; ++id) e.noteOn("s", 100 + round * 20 + id, 30 + 6 * id + round, 0.2 + 0.08 * id);
            e.setComponentParam("s", Engine::kInstrumentIndex, "sustain", round % 2 ? 1.0 : 0.0);  // the pedal's recording
            e.setComponentParam("s", Engine::kInstrumentIndex, "character", round == 3 ? 1.0 : 0.0);
            e.setComponentParam("s", Engine::kInstrumentIndex, "noise", 0.25 * round);
            {
                cawtest::AllocationScope scope;
                for (int k = 0; k < 60; ++k) {
                    e.process(left.data(), right.data(), 192);
                    for (float v : left) sum += std::fabs(v);
                }
                operations += scope.count();
            }
            for (int id = 0; id < 10; ++id) e.noteOff(100 + round * 20 + id);  // the key releases' recordings
            cawtest::AllocationScope scope;
            for (int k = 0; k < 40; ++k) e.process(left.data(), right.data(), 192);
            operations += scope.count();
        }
        if (operations != 0) cawtest::fail(__FILE__, __LINE__, "tier " + std::to_string(tier) + " allocated");
        CHECK(sum > 0.0);
        CHECK(std::isfinite(sum));
    }
}

// The recorded bank (5.6 MB of PCM) is decoded and freed only on the control thread: a project that brings Starling in
// decodes it in setProject(), and one that takes it out frees it only after the audio thread has handed the instrument
// back (the engine's retire queue); the audio callback neither decodes nor frees it (no allocation and no free in it).
TEST(starling_piano_bank_is_decoded_and_freed_off_the_audio_thread) {
    ProjectSpec with;
    with.bpm = 120;
    with.loopBars = 1;
    LayerSpec l;
    l.id = "s";
    l.hasInstrument = true;
    l.instrument.id = "org.caw.starling";
    l.instrument.params = {{"variant", 0}};
    with.layers.push_back(l);
    ProjectSpec without = with;
    without.layers[0].instrument.id = "org.caw.test.osc";
    without.layers[0].instrument.params = {};
    const size_t before = recorded::residentBytes();
    std::size_t audioOps = 0;
    {
        Engine e(48000);
        std::vector<float> left(192), right(192);
        if (e.setProject(with).find("\"ok\":true") == std::string::npos) cawtest::fail(__FILE__, __LINE__, "set");
        CHECK(recorded::residentBytes() > before);  // decoded on this (the control) thread
        {
            e.noteOn("s", 1, 60, 0.8);  // a control call
            cawtest::AllocationScope scope;
            for (int k = 0; k < 40; ++k) e.process(left.data(), right.data(), 192);
            audioOps += scope.count();
        }
        if (e.setProject(without).find("\"ok\":true") == std::string::npos) cawtest::fail(__FILE__, __LINE__, "unset");
        {
            cawtest::AllocationScope scope;  // the callback hands the old instrument back: it frees nothing itself
            for (int k = 0; k < 40; ++k) e.process(left.data(), right.data(), 192);
            audioOps += scope.count();
        }
        CHECK_EQ(audioOps, static_cast<std::size_t>(0));
        for (int k = 0; k < 4; ++k) e.process(left.data(), right.data(), 192), e.setProject(without);
    }
    CHECK_EQ(recorded::residentBytes(), before);  // freed (on this thread) once the engine let the instrument go
}
