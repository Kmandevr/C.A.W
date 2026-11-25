// caw_bench's cost of the modelled instruments (Starling, Nightingale, Curlew, Bittern, Woodpecker; Timber's cases left with it in 1.1.3) (`caw_bench SECONDS 300` and `321`): each with N voices sounding, in µs per second of audio and bytes per instance, against a ceiling, plus µs per voice.
#include <algorithm>
#include <cstdio>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "reference_cost.h"
#include "builtin_components.h"
#include "builtin_curlew.h"
#include "builtin_nightingale.h"
#include "builtin_starling.h"
#include "builtin_woodpecker.h"
#include "caw/instrument.hpp"
#include "fp_mode.h"
#include "fx_merged.h"
#include "module_registry.h"

using namespace caw;
using Values = std::vector<std::pair<std::string, double>>;

namespace {

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

}  // namespace

// Prints each case and returns how many went over their ceilings. Ceilings: the owner's budgets (light 0.5 %, medium
// 2 %, heavy 6 % of an S22+ core) over an assumed 2.5x slower phone core: 2000, 8000 and 24000 µs/s here.
int timberCost(double seconds) {
    int over = 0;
    std::printf("The modelled instruments (µs of CPU per second of audio; per voice; bytes per instance; ceiling µs/s):\n");
    // 1.1.3: the realistic instruments (Nightingale at its polyphony: medium plus 20 %, as Timber's bowed strings).
    // Starling's recordings are shared, not counted per instance.
    struct NewCase {
        const char* id;
        const char* name;
        uint32_t model;
        Values values;
        int voices;
        double ceilingUs;
    };
    // The 1.1.3 instruments' ceilings sit about 1.4x over a local run (CI's runners read 10-20 % slower and vary):
    // they catch a regression; the budgets are the owner's (light, medium, heavy, above).
    constexpr double kNew = 12500;
    const NewCase more[] = {
        // Starling: Timber's Simulated piano plus its recordings (two attack layers and a release a note: about 10 % more
        // in this case, 32 notes struck a second), so heavy plus 10 % (Claude's call, docs/decisions.md, 2026-11-24).
        {"org.caw.starling", "Starling piano Normal: 16 voices", 0, {{"tier", 2}}, 16, 34000},
        {"org.caw.starling", "Starling piano Normal: 16 voices, pedal down", 0, {{"tier", 2}, {"sustain", 1}, {"resonance", 0.6}}, 16, 35500},
        {"org.caw.starling", "Starling piano Eco: 16 voices", 0, {{"tier", 1}}, 16, 27000},
        {"org.caw.starling", "Starling guitar Normal: 16 voices", 1, {{"tier", 2}}, 16, 17500},
        {"org.caw.starling", "Starling guitar High: 16 voices, let ring", 1, {{"tier", 3}, {"sustain", 1}}, 16, 18200},
        {"org.caw.starling", "Starling harp Normal: 16 voices", 2, {{"tier", 2}}, 16, 17700},
        {"org.caw.starling", "Starling harp Eco: 16 voices, Body 1", 2, {{"tier", 1}, {"body", 1}}, 16, 18300},
        {"org.caw.nightingale", "Nightingale violin: 8 voices", 0, {}, 8, kNew},
        {"org.caw.nightingale", "Nightingale cello: 8 voices, vibrato 1", 2, {{"vibrato", 1}}, 8, kNew},
        {"org.caw.nightingale", "Nightingale bass: 8 voices, High", 3, {{"tier", 3}}, 8, 15000},  // High: exports
        {"org.caw.curlew", "Curlew flute: 8 voices", 0, {}, 8, kNew},
        {"org.caw.curlew", "Curlew clarinet: 8 voices", 1, {}, 8, kNew},
        {"org.caw.curlew", "Curlew saxophone: 8 voices, growl", 2, {{"growl", 0.5}}, 8, kNew},
        {"org.caw.curlew", "Curlew trombone: 8 voices", 4, {}, 8, 13000},  // brass: the lips and steepening, plus the body (Timber's 8,957)
        {"org.caw.bittern", "Bittern: 10 keys, principal chorus, room", 0, {}, 10, 24000},  // heavy: the room is part of it
        {"org.caw.bittern", "Bittern: 10 keys, full organ", 0, {{"principal8", 1}, {"octave4", 1}, {"fifteenth2", 1}, {"mixture", 1}, {"trumpet8", 1}, {"subbass32", 1}, {"gamba8", 1}, {"celeste8", 1}}, 10, 24000},
        // Woodpecker: 8 (High 12) modes a voice and a recorded attack a note; the marimba and vibraphone add the tube.
        // Measured 9,400 / 8,700 / 7,500 / 7,300 locally (x86-64, 2026-11-24); ceilings about 1.4x.
        {"org.caw.woodpecker", "Woodpecker marimba: 16 voices", 0, {}, 16, 13500},
        {"org.caw.woodpecker", "Woodpecker vibraphone: 16 voices, motor, pedal", 3, {{"motor", 5}, {"sustain", 1}}, 16, 13000},
        {"org.caw.woodpecker", "Woodpecker tubular bells: 16 voices, High", 4, {{"tier", 3}, {"sustain", 1}}, 16, 11000},
        {"org.caw.woodpecker", "Woodpecker timpani: 16 voices", 5, {}, 16, 10500},
    };
    for (const NewCase& c : more) {
        Values v = c.values;
        v.emplace_back("variant", c.model);
        std::unique_ptr<ModuleProcessor> p = createComponent(registry(), c.id, v);
        if (!p || !p->activate(kRate, kBlock)) {
            std::printf("  %-50s  could not be made\n", c.name);
            ++over;
            continue;
        }
        const double us = cost(*p, v, c.voices, seconds);
        const bool bad = us > c.ceilingUs;
        over += bad;
        const std::string_view id = c.id;
        const size_t bytes = id == "org.caw.starling"      ? starling::starlingBytes(c.model, kRate)
                             : id == "org.caw.nightingale" ? nightingale::nightingaleBytes(c.model, kRate)
                             : id == "org.caw.curlew"      ? curlew::curlewBytes(c.model, kRate)
                             : id == "org.caw.woodpecker"  ? woodpecker::woodpeckerBytes(c.model, kRate)
                                                           : size_t{0};  // Bittern: its tables are shared
        std::printf("  %-50s %8.0f %7.0f/v %9zu B  %6.0f%s\n", c.name, us, us / c.voices, bytes, c.ceilingUs, bad ? "  OVER" : "");
    }
    return over;
}
