// caw_bench's cost of Flagship's 1.1.0 synthesis (Raven; `caw_bench SECONDS 300` and `320`): each new mode per held voice, and flagship_heavy16, against ceilings.
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "reference_cost.h"
#include "builtin_components.h"
#include "caw/instrument.hpp"
#include "engine.h"
#include "fx_merged.h"
#include "module_registry.h"
#include "quality.h"
#include "stress_scenarios.h"

using namespace caw;
using namespace caw::stress;
using Values = std::vector<std::pair<std::string, double>>;

namespace {

constexpr double kRate = 48000.0;
constexpr uint32_t kBlock = 64;
constexpr int kNotes = 8;

const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        return x;
    }();
    return r;
}

// Eight notes held through one Flagship (no engine around it) in 64-frame blocks, against the reference; built
// offline, so a spectral warp's bank is there from the first block (as it is live once the worker built it).
double held(const Values& values, double seconds) {
    std::unique_ptr<ModuleProcessor> p;
    {
        const BuildingOffline offline(true);
        p = createComponent(registry(), "org.caw.synth.flagship", values);
        if (!p || !p->activate(kRate, kBlock)) return -1.0;
    }
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    std::vector<float> l(kBlock), r(kBlock);
    float* channels[2] = {l.data(), r.data()};
    const ChannelBufferView audio{channels, 2, kBlock};
    std::vector<Event> on;
    for (int i = 0; i < kNotes; ++i) on.push_back(notes::noteOn(0, static_cast<uint32_t>(i + 1), 48 + 3 * i, 0.9));
    bench::RelativeCost rel;
    for (int run = 0; run < bench::kRuns; ++run) {
        p->reset();
        const int blocks = static_cast<int>(seconds * kRate / kBlock);
        rel.begin();
        for (int b = 0; b < blocks; ++b) {
            rel.tick(b);
            const EventInput in{b == 0 ? on.data() : nullptr, b == 0 ? static_cast<uint32_t>(on.size()) : 0u};
            ProcessBlock pb;
            pb.frames = kBlock;
            pb.sampleRate = kRate;
            pb.audioOut = &audio;
            pb.audioOutCount = 1;
            pb.eventIn = &in;
            pb.eventInCount = 1;
            pb.parameters = params.data();
            pb.parameterCount = d.parameterCount;
            p->processPorts(pb);
        }
        rel.end();
    }
    return rel.us();
}

// A suite scenario through an Engine in 256-frame callbacks, against the reference (each callback is four of the
// reference's 64-frame blocks). `extra` is added to every Flagship layer's values.
double scenario(const char* id, const Values& extra, double seconds) {
    const std::string dir = (std::filesystem::temp_directory_path() / "caw_bench_raven").string();
    std::filesystem::create_directories(dir);
    ProjectSpec project;
    bool found = false;
    for (const SuiteScenario& sc : suiteScenarios())
        if (std::string(sc.id) == id) project = sc.make(dir), found = true;
    if (!found) return -1.0;
    for (LayerSpec& l : project.layers)
        if (l.instrument.id == "org.caw.synth.flagship")
            for (const auto& v : extra) l.instrument.params.push_back(v);
    Engine e(static_cast<int>(kRate));
    e.setProject(project);
    std::vector<float> L(256), R(256);
    for (int c = 0; c < 48; ++c) e.process(L.data(), R.data(), 256);
    e.play();
    for (int c = 0; c < 48; ++c) e.process(L.data(), R.data(), 256);  // the notes start, the banks are asked for
    std::this_thread::sleep_for(std::chrono::milliseconds(400));    // the worker builds them (live, as on a phone)
    for (int c = 0; c < 48; ++c) e.process(L.data(), R.data(), 256);
    bench::RelativeCost rel;
    for (int run = 0; run < 3; ++run) {
        const int calls = static_cast<int>(seconds * kRate / 256);
        rel.begin();
        for (int c = 0; c < calls; ++c) {
            rel.tick(4 * c);
            e.process(L.data(), R.data(), 256);
        }
        rel.end();
    }
    return rel.us();
}

struct Case {
    const char* name;
    Values values;
    double ceilingUs;  // for the eight voices, µs per second of audio on the x86 CI machine; over it fails
};

}  // namespace

// Prints each case (the eight voices' cost and a voice's share) and returns how many went over their ceilings.
// Ceilings: about twice what each measured on the x86 box (2026-11-19, a busy machine), so the noise of a shared CI
// runner passes and a real regression (a mode's path costing double) fails. The default patch's ceiling is the
// 1.0.9 figure's: Raven must not make it dearer (song8's Flagship share, 31 %).
int ravenCost(double seconds) {
    const Values one = {{"osc1_unison", 1}, {"flt1_on", 0}, {"fx_reverb_on", 0}, {"env1_sustain", 1}, {"mod1_src", 0},
                        {"osc2_on", 1}, {"osc2_unison", 1}, {"osc2_semi", 7}};
    auto with = [&](Values v) {
        Values x = one;
        x.insert(x.end(), v.begin(), v.end());
        return x;
    };
    const Case cases[] = {
        {"default patch (x7, ladder)", {}, 26000},
        {"two oscs, one copy each", with({}), 12000},
        {"Osc RM from osc 2", with({{"osc1_warp", 8}, {"osc1_warp_amt", 0.7}, {"osc1_mod_src", 2}}), 14000},
        {"Osc AM from noise", with({{"osc1_warp", 9}, {"osc1_warp_amt", 0.7}, {"osc1_mod_src", 4}}), 14000},
        {"Osc sync to osc 2 (polyBLEP)", with({{"osc1_warp", 10}, {"osc1_warp_amt", 0.4}, {"osc1_mod_src", 2}}), 16000},
        {"Stretch, on a bank level", with({{"osc1_warp", 11}, {"osc1_warp_amt", 3.0 / 7.0}}), 12000},
        {"Formant, between levels, frame moving", with({{"osc1_warp", 14}, {"osc1_warp_amt", 0.5}, {"osc1_frame", 0.5}}), 14000},
        {"Formant x7 between levels", with({{"osc1_unison", 7}, {"osc1_warp", 14}, {"osc1_warp_amt", 0.5}}), 30000},
        {"Diode LP", with({{"flt1_on", 1}, {"flt1_type", 9}, {"flt1_resonance", 0.6}}), 26000},
        {"Sallen-Key", with({{"flt1_on", 1}, {"flt1_type", 10}, {"flt1_resonance", 0.6}}), 20000},
        {"Phaser (8 stages)", with({{"flt1_on", 1}, {"flt1_type", 11}, {"flt1_morph", 1}}), 36000},
        {"Neg comb", with({{"flt1_on", 1}, {"flt1_type", 12}}), 18000},
        {"Vowel", with({{"flt1_on", 1}, {"flt1_type", 13}}), 20000},
        {"LFO 4 and a macro on slots", with({{"mod2_src", 15}, {"mod2_dst", 3}, {"mod2_amt", 0.3}, {"lfo4_mode", 1},
                                             {"mod3_src", 16}, {"mod3_dst", 4}, {"mod3_amt", -0.3}, {"macro1", 0.5}}),
         14000},
    };
    int over = 0;
    std::printf("Flagship 1.1.0 (Raven), 8 held notes (µs of CPU per second of audio; a voice's share; ceiling µs/s):\n");
    for (const Case& c : cases) {
        const double us = held(c.values, seconds);
        const bool bad = us > c.ceilingUs || us <= 0.0;
        over += bad ? 1 : 0;
        std::printf("  %-44s %8.0f  a voice %6.0f  (ceiling %5.0f)%s\n", c.name, us, us / kNotes, c.ceilingUs, bad ? "  OVER" : "");
    }
    // flagship_heavy16 (16 voices of 48 copies, every filter and effect) as it is, and with Raven's modes on its
    // oscillators and filter 2; µs per second of audio through the whole engine.
    struct Heavy {
        const char* name;
        Values extra;
        double ceilingUs;
    } heavy[] = {
        {"flagship_heavy16", {}, 600000},
        {"flagship_heavy16, Raven modes", {{"osc2_warp", 14}, {"osc2_warp_amt", 0.5}, {"osc3_warp", 10}, {"osc3_warp_amt", 0.3},
                                           {"osc3_mod_src", 1}, {"flt2_type", 9}}, 800000},
    };
    for (const Heavy& h : heavy) {
        const double us = scenario("flagship_heavy16", h.extra, seconds);
        const bool bad = us > h.ceilingUs || us <= 0.0;
        over += bad ? 1 : 0;
        std::printf("  %-44s %8.0f                 (ceiling %6.0f)%s\n", h.name, us, h.ceilingUs, bad ? "  OVER" : "");
    }
    return over;
}
