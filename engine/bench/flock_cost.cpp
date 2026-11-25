// caw_bench's cost of Flock (org.caw.flock, `caw_bench SECONDS 300` and `322`): N voices of grains at a density, in µs per second of audio (relative to the reference workload) and the grains overlapping, against a ceiling.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "asset_store.h"
#include "builtin_components.h"
#include "builtin_flock.h"
#include "caw/instrument.hpp"
#include "fp_mode.h"
#include "fx_merged.h"
#include "module_registry.h"
#include "quality.h"
#include "reference_cost.h"

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

// A 4 s stereo sample in the asset store ("mem:flock_bench"): a few partials and noise, as a recording would have.
void loadBenchSample() {
    static bool done = false;
    if (done) return;
    done = true;
    const uint32_t frames = 4 * 48000;
    std::vector<uint8_t> w;
    auto u32 = [&](uint32_t v) { for (int k = 0; k < 4; ++k) w.push_back(static_cast<uint8_t>(v >> (8 * k))); };
    auto u16 = [&](uint32_t v) { for (int k = 0; k < 2; ++k) w.push_back(static_cast<uint8_t>(v >> (8 * k))); };
    w.insert(w.end(), {'R', 'I', 'F', 'F'});
    u32(36 + frames * 4);
    w.insert(w.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
    u32(16), u16(1), u16(2), u32(48000), u32(48000 * 4), u16(4), u16(16);
    w.insert(w.end(), {'d', 'a', 't', 'a'});
    u32(frames * 4);
    uint32_t seed = 3;
    for (uint32_t i = 0; i < frames; ++i) {
        seed = seed * 1664525u + 1013904223u;
        const double t = i / 48000.0, n = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * 0.05;
        u16(static_cast<uint32_t>(static_cast<int16_t>(std::lround((0.3 * std::sin(6.2832 * 220 * t) + n) * 32767))));
        u16(static_cast<uint32_t>(static_cast<int16_t>(std::lround((0.3 * std::sin(6.2832 * 331 * t) - n) * 32767))));
    }
    std::string error;
    AssetStore::global().loadBytes("flock_bench", w.data(), w.size(), kRate, error);
}

// `voices` notes held over the whole run (each struck again every 2 s, in turn); the display is read each block.
// `grains` gets the mean of the grains alive at each display read.
double cost(ModuleProcessor& p, const Values& values, int voices, double seconds, double& grains) {
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
    const ScopedFlushDenormals flush;
    bench::RelativeCost rel;
    const int period = static_cast<int>(2.0 * kRate / kBlock);
    double alive = 0;
    long reads = 0;
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
                if (!(b == 0 || (b % period) == v * period / voices)) continue;
                const double pitch = 48.0 + (v * 7) % 24;
                if (held[v]) ev[n++] = notes::noteOff(0, held[v], notes::keyOf(pitch));
                held[v] = id++;
                ev[n++] = notes::noteOn(0, held[v], pitch, 0.8);
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
            float sink[1024];
            if (p.readDisplay(sink, 1024) > 1 && run == 0 && b > blocks / 4) alive += sink[1], ++reads;
        }
        rel.end();
    }
    grains = reads ? alive / reads : 0;
    return rel.us();
}

struct Case {
    const char* name;
    Values values;
    int voices;
    int tier;
    bool sample;
    double ceilingUs;  // µs per second of audio on the calibration box; over it fails
};

}  // namespace

// Prints each case and returns how many went over their ceilings. Ceilings: the owner's budgets (medium 2 %, heavy
// 6 % of an S22+ core) over an assumed 2.5x slower phone core: 8000 and 24000 µs/s here (as Timber's were).
int flockCost(double seconds) {
    loadBenchSample();
    const Case cases[] = {
        {"Flock: 6 voices, defaults (typical, design point)", {}, 6, 1, false, 8000},
        {"Flock: 6 voices, defaults, Eco (linear reads)", {}, 6, 0, false, 8000},
        {"Flock: 6 voices, a sample, +24 st (mips)", {{"pitch", 24}}, 6, 1, true, 8000},
        {"Flock: 4 voices, a sample, filter off", {{"filter", 0}}, 4, 1, true, 8000},
        {"Flock: 8 voices, 64 grains (dense pad)", {{"size", 200}, {"density", 40}}, 8, 1, false, 24000},
        {"Flock: 16 voices, 128 grains (the cap, stress)", {{"voices", 16}, {"size", 400}, {"density", 60}}, 16, 2, false, 40000},  // the High cap: about 1.3x heavy, as Murmur's 64 is heavy
    };
    int over = 0;
    std::printf("Flock (µs of CPU per second of audio; grains alive on average; bytes per instance; ceiling µs/s):\n");
    for (const Case& c : cases) {
        static std::atomic<int> tiers[3] = {kQualityEco, kQualityNormal, kQualityHigh};
        const BuildingQuality building(&tiers[c.tier]);
        std::unique_ptr<ModuleProcessor> p = createComponent(registry(), "org.caw.flock", c.values);
        const std::string state = "{\"path\":\"mem:flock_bench\"}";
        if (p && c.sample) p->loadState(reinterpret_cast<const uint8_t*>(state.data()), static_cast<uint32_t>(state.size()), 1);
        if (!p || !p->activate(kRate, kBlock)) {
            std::printf("  %-50s  could not be made\n", c.name);
            ++over;
            continue;
        }
        double grains = 0;
        const double us = cost(*p, c.values, c.voices, seconds, grains);
        const bool bad = us > c.ceilingUs;
        over += bad;
        std::printf("  %-50s %8.0f %6.1f grains %8zu B  %6.0f%s\n", c.name, us, grains, flock::instanceBytes(), c.ceilingUs,
                    bad ? "  OVER" : "");
    }
    return over;
}
