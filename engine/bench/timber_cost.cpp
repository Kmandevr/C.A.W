// caw_bench's cost of Timber (org.caw.timber, `caw_bench SECONDS 300` and `321`): each model with N voices sounding, in µs per second of audio and bytes per instance, against a ceiling, plus µs per voice.
#include <algorithm>
#include <cstdio>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "reference_cost.h"
#include "builtin_components.h"
#include "builtin_timber.h"
#include "caw/instrument.hpp"
#include "fp_mode.h"
#include "fx_merged.h"
#include "module_registry.h"

using namespace caw;
using Values = std::vector<std::pair<std::string, double>>;

namespace {

// The polyphonic models' ceiling (the table below says why): medium plus 20 %.
constexpr double kPoly = 9600;

constexpr double kRate = 48000.0;
constexpr uint32_t kBlock = 64;

const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        return x;
    }();
    return r;
}

// `voices` notes spread over four octaves are struck at the start and each struck again (a new note id, the old
// one released) every 0.5 s in turn, so about `voices` keep sounding; the display is read each block.
double cost(ModuleProcessor& p, const Values& values, int voices, double seconds) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [name, v] : values)
            if (d.parameters[k].id == name) params[k].value = v;
    }
    float outL[kBlock], outR[kBlock];
    float* ch[2] = {outL, outR};
    const ChannelBufferView audio{ch, 2, kBlock};
    const ScopedFlushDenormals flush;  // as every Engine::process call holds (fp_mode.h)
    bench::RelativeCost rel;
    const int period = static_cast<int>(0.5 * kRate / kBlock);
    for (int run = 0; run < bench::kRuns; ++run) {
        p.reset();
        uint32_t id = 1;
        std::vector<uint32_t> held(voices, 0);
        const int blocks = static_cast<int>(seconds * kRate / kBlock);
        rel.begin();
        for (int b = 0; b < blocks; ++b) {
            rel.tick(b);
            Event ev[64];
            uint32_t n = 0;
            for (int v = 0; v < voices && n + 2 <= 64; ++v) {
                const bool due = b == 0 || (b % period) == v * period / voices;
                if (!due) continue;
                const double pitch = 36.0 + (v * 7) % 48;
                if (held[v]) ev[n++] = notes::noteOff(0, held[v], notes::keyOf(pitch));
                held[v] = id++;
                ev[n++] = notes::noteOn(0, held[v], pitch, 0.5 + 0.4 * ((v * 5) % 7) / 6.0);
            }
            const EventInput in{ev, n};
            ProcessBlock pb;
            pb.frames = kBlock;
            pb.sampleRate = kRate;
            pb.audioOut = &audio;
            pb.audioOutCount = 1;
            pb.eventIn = &in;
            pb.eventInCount = 1;
            pb.parameters = params.data();
            pb.parameterCount = d.parameterCount;
            p.processPorts(pb);
            float sink[64];
            p.readDisplay(sink, 64);
        }
        rel.end();
    }
    return rel.us();
}

struct Case {
    const char* name;
    uint32_t model;
    Values values;
    int voices;
    double ceilingUs;  // µs per second of audio on the x86 CI machine; over it fails
};

}  // namespace

// Prints each case and returns how many went over their ceilings. Ceilings: the owner's budgets (light 0.5 %, medium
// 2 %, heavy 6 % of an S22+ core) over an assumed 2.5x slower phone core: 2000, 8000 and 24000 µs/s here.
int timberCost(double seconds) {
    const Case cases[] = {
        // kPoly: a model at its usual polyphony, medium (8,000) plus 20 %: these sit at 85-95 % of medium on the
        // development machine, and CI's x64 runner reads Timber about 8 % higher after normalisation, even run alone
        // (the electric piano 8,205 on PR #258, 2026-11-19).
        {"Timber piano: 16 voices (design point)", 0, {}, 16, 24000},
        {"Timber piano: 8 voices", 0, {}, 8, 24000},
        {"Timber piano: 32 voices, pedal down", 0, {{"sustain", 1}, {"resonance", 0.6}}, 32, 56000},  // Normal's cap, a stress case: over 2x heavy
        {"Timber piano: 16 voices, room 0.3 (the room: a light reverb)", 0, {{"space", 0.3}}, 16, 28000},
        {"Timber electric piano: 16 voices (tine)", 1, {}, 16, kPoly},
        {"Timber electric piano: 32 voices, reed, tremolo", 1, {{"kind", 1}, {"tremolo", 0.5}}, 32, 24000},  // Normal's cap: heavy
        {"Timber organ: 10 keys, 888, rotary slow", 2, {}, 10, kPoly},
        {"Timber organ: 10 keys, all drawbars, perc, C3, fast", 2,
         {{"db4", 8}, {"db223", 8}, {"db2", 8}, {"db135", 8}, {"db113", 8}, {"db1", 8}, {"perc", 1}, {"vibrato", 6}, {"rotary", 2}}, 10, 12000},  // every stage on: 1.5x medium
        {"Timber organ: 10 keys, 888, no rotary", 2, {{"rotary", 0}}, 10, kPoly},
        {"Timber plucked: 16 voices (steel guitar)", 3, {}, 16, kPoly},
        {"Timber plucked: 32 voices (harp, ringing on)", 3, {{"instrument", 2}}, 32, 24000},  // Normal's cap: heavy
        {"Timber bowed: 8 voices (violin)", 4, {}, 8, kPoly},
        {"Timber bowed: 8 voices (cello, vibrato 1)", 4, {{"section", 2}, {"vibrato", 1}}, 8, kPoly},
        {"Timber mallets: 16 voices (marimba, 4 modes)", 5, {}, 16, kPoly},
        {"Timber mallets: 32 voices (bell, 8 modes)", 5, {{"instrument", 5}}, 32, 24000},  // Normal's cap: heavy
        {"Timber winds: 8 voices (clarinet)", 6, {}, 8, kPoly},
        {"Timber winds: 8 voices (flute, noise, growl)", 6, {{"instrument", 1}, {"noise", 0.5}, {"growl", 0.5}}, 8, kPoly},
        {"Timber winds: 8 voices (brass)", 6, {{"instrument", 3}}, 8, kPoly},
        // 1.1.2 Simulated, each model at its usual polyphony at Normal (the same ceiling: medium plus 20 %; the
        // bowed's elasto-plastic bristles are High's, so its Normal runs 1.1.0's friction table with the noises).
        {"Timber sim electric piano: 16 voices (tine)", 1, {{"sim", 1}}, 16, kPoly},
        {"Timber sim electric piano: 16 voices (reed)", 1, {{"sim", 1}, {"kind", 1}}, 16, kPoly},
        {"Timber sim organ: 10 keys, 888, rotary slow", 2, {{"sim", 1}}, 10, kPoly},
        {"Timber sim plucked: 16 voices (steel guitar)", 3, {{"sim", 1}}, 16, kPoly},
        {"Timber sim plucked: 16 voices (nylon)", 3, {{"sim", 1}, {"instrument", 1}}, 16, kPoly},
        {"Timber sim bowed: 8 voices (violin)", 4, {{"sim", 1}}, 8, kPoly},
        {"Timber sim bowed: 8 voices (cello, vibrato 1)", 4, {{"sim", 1}, {"section", 2}, {"vibrato", 1}}, 8, kPoly},
        {"Timber sim mallets: 16 voices (marimba)", 5, {{"sim", 1}}, 16, kPoly},
        {"Timber sim mallets: 16 voices (bell, 8 modes)", 5, {{"sim", 1}, {"instrument", 5}}, 16, kPoly},
        {"Timber sim winds: 8 voices (clarinet)", 6, {{"sim", 1}}, 8, kPoly},
        {"Timber sim winds: 8 voices (flute)", 6, {{"sim", 1}, {"instrument", 1}}, 8, kPoly},
        {"Timber sim winds: 8 voices (sax)", 6, {{"sim", 1}, {"instrument", 2}}, 8, kPoly},
        {"Timber sim winds: 8 voices (brass)", 6, {{"sim", 1}, {"instrument", 3}}, 8, kPoly},
    };
    int over = 0;
    std::printf("Timber (µs of CPU per second of audio; per voice; bytes per instance; ceiling µs/s):\n");
    for (const Case& c : cases) {
        Values v = c.values;
        v.emplace_back("variant", c.model);
        v.emplace_back("space", 0.0);
        for (const auto& [k, x] : c.values)
            if (k == "space") v.back().second = x;
        std::unique_ptr<ModuleProcessor> p = createComponent(registry(), "org.caw.timber", v);
        if (!p || !p->activate(kRate, kBlock)) {
            std::printf("  %-50s  could not be made\n", c.name);
            ++over;
            continue;
        }
        const double us = cost(*p, v, c.voices, seconds);
        const bool bad = us > c.ceilingUs;
        over += bad;
        std::printf("  %-50s %8.0f %7.0f/v %9zu B  %6.0f%s\n", c.name, us, us / c.voices, timber::timberBytes(c.model, kRate),
                    c.ceilingUs, bad ? "  OVER" : "");
    }
    std::printf("  shared tables: %zu B once per process\n", timber::timberTableBytes());
    return over;
}
