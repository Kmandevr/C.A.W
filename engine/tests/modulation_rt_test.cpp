// #161: project modulation never allocates or frees on the audio thread (modulators, links, plan swaps, Play restarts).
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;
using cawtest::Shape;

TEST(project_modulation_never_allocates_on_the_audio_thread) {
    Engine e(48000.0);
    ComponentSpec filter;
    filter.id = "org.caw.filter";
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("noise", Shape::Noise, {{"level", 0.3}}, {filter}),
                                                cawtest::testSignalLayer("keys", Shape::Saw, {{"mode", 1.0}})});
    auto mod = [](const std::string& id, const std::string& component, const std::string& input = "", bool audio = false) {
        ModulatorSpec m;
        m.id = id;
        m.component.id = component;
        m.input = input;
        m.hearsAudio = audio;
        m.hearsNotes = !audio;
        return m;
    };
    auto link = [](uint32_t id, const std::string& src, const std::string& type, const std::string& layer, int index,
                   const std::string& param, double amount, uint32_t output = 0) {
        ModLinkSpec l;
        l.id = id;
        l.source = src;
        l.output = output;
        l.target = {type, layer, param, index};
        l.amount = amount;
        l.bipolar = true;
        l.curve = 0.3;
        return l;
    };
    p.modulators = {mod("lfo", "org.caw.mod.lfo"), mod("fol", "org.caw.mod.follower", "noise", true),
                    mod("env", "org.caw.mod.envelope", "keys"), mod("cv", "org.caw.mod.midi", "keys"),
                    mod("steps", "org.caw.mod.steps"), mod("rnd", "org.caw.mod.random"), mod("mac", "org.caw.mod.macros")};
    p.modulation = {link(1, "lfo", "component", "noise", 0, "cutoff", 0.4), link(2, "fol", "volume", "keys", -1, "", -0.5),
                    link(3, "env", "pan", "keys", -1, "", 0.3), link(4, "cv", "instrument", "keys", -1, "level", 0.2, 1),
                    link(5, "steps", "modulator", "lfo", -1, "rate", 0.5), link(6, "rnd", "component", "noise", 0, "resonance", 0.2),
                    link(7, "mac", "modulator", "steps", -1, "s1", 0.5)};
    e.setProject(p);
    std::vector<float> l(192), r(192);
    std::size_t operations = 0;
    for (int round = 0; round < 3; ++round) {
        {
            cawtest::AllocationScope scope;
            for (int k = 0; k < 400; ++k) e.process(l.data(), r.data(), k % 3 == 0 ? 37 : 192);
            operations += scope.count();
        }
        // Control thread between rounds: a Play (the modulators restart), notes, knobs, a link's amount and a project
        // update that keeps the modulators (a new plan swapped in) or changes them (new modulators).
        e.play();
        e.noteOn("keys", round + 1, 60.0 + round, 0.8);
        e.setModulatorParam("mac", "macro1", 0.3 * round);
        e.setModulationAmount(1, -0.2 * round);
        p.modulation[0].amount = 0.1 * round;
        if (round == 1) p.modulators.push_back(mod("lfo2", "org.caw.mod.lfo"));
        e.setProject(p);
    }
    CHECK_EQ(operations, 0u);
}
