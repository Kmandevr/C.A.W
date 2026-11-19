// caw_bench's cost of the AutoStacc beta pack (`caw_bench SECONDS 300` and `307`): Murmur, Peck, Bend and Iris in µs per second of audio and bytes per instance, each against a ceiling.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <atomic>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "reference_cost.h"
#include "builtin_components.h"
#include "builtin_pack.h"
#include "fx_merged.h"
#include "quality.h"
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

// The effect on a busy stereo signal (noise bursts, tones and clicks, never silent) in 64-frame blocks, its display
// read each block; the best of 3 runs.
double cost(ModuleProcessor& p, const Values& values, double seconds) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [name, v] : values)
            if (d.parameters[k].id == name) params[k].value = v;
    }
    const int frames = static_cast<int>(kRate);
    std::vector<float> inL(frames), inR(frames), outL(kBlock), outR(kBlock);
    uint32_t seed = 1;
    for (int i = 0; i < frames; ++i) {
        seed = seed * 1664525u + 1013904223u;
        const double noise = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * (0.05 + 0.3 * ((i / 6000) % 2));
        const double click = i % 4800 == 100 ? 0.6 : 0.0;  // ten clicks a second (De-click repairs each)
        inL[i] = static_cast<float>(noise + click + 0.3 * std::sin(2 * 3.14159265358979 * 220 * i / kRate));
        inR[i] = static_cast<float>(0.8 * noise + click + 0.3 * std::sin(2 * 3.14159265358979 * 330 * i / kRate));
    }
    Transport tr;
    tr.playing = true;
    bench::RelativeCost rel;  // against the reference, interleaved (reference_cost.h)
    for (int run = 0; run < bench::kRuns; ++run) {
        p.reset();
        const int blocks = static_cast<int>(seconds * kRate / kBlock);
        rel.begin();
        for (int b = 0; b < blocks; ++b) {
            rel.tick(b);
            const int at = (b * static_cast<int>(kBlock)) % (frames - static_cast<int>(kBlock));
            const float* in[2] = {inL.data() + at, inR.data() + at};
            float* out[2] = {outL.data(), outR.data()};
            AudioProcessBlock block;
            block.input = {in, 2, kBlock};
            block.output = {out, 2, kBlock};
            block.frames = kBlock;
            block.sampleRate = kRate;
            block.parameters = params.data();
            block.parameterCount = d.parameterCount;
            block.transport = &tr;
            p.process(block);
            float sink[128];
            p.readDisplay(sink, 128);
        }
        rel.end();
    }
    return rel.us();
}

struct Case {
    const char* name;
    const char* id;
    Values values;
    size_t bytes;
    double ceilingUs;  // µs per second of audio on the x86 CI machine; over it fails
    int tier = kQualityNormal;
};

}  // namespace

// Prints each case and returns how many went over their ceilings. Ceilings: the owner's budgets (light 0.5 %,
// medium 2 %, heavy 6 % of an S22+ core) over an assumed 2.5x slower phone core: 2000, 8000 and 24000 µs/s here.
int packCost(double seconds) {
    const char* murmur = "org.caw.pack.granular";
    const size_t mb = fx::murmurBytes(kRate);
    const Case cases[] = {
        {"Murmur: default (80 ms, 20 Hz)", murmur, {}, mb, 8000},
        {"Murmur: dense, Normal cap 32", murmur, {{"size", 300}, {"density", 150}, {"spray", 50}}, mb, 24000},
        {"Murmur: dense, Eco cap 16 (linear)", murmur, {{"size", 300}, {"density", 150}, {"spray", 50}}, mb, 8000, kQualityEco},
        {"Murmur: dense, High cap 64", murmur, {{"size", 500}, {"density", 200}, {"spray", 50}}, mb, 24000, kQualityHigh},
        {"Murmur: frozen, scanning, fed back", murmur, {{"freeze", 1}, {"scan", 0.5}, {"feedback", 0.5}, {"size", 200}, {"density", 40}}, mb, 8000},
    };
    int over = 0;
    std::printf("AutoStacc beta pack (µs of CPU per second of audio; bytes per instance; ceiling µs/s):\n");
    for (const Case& c : cases) {
        static std::atomic<int> tiers[3] = {kQualityEco, kQualityNormal, kQualityHigh};
        const BuildingQuality building(&tiers[std::clamp(c.tier, 0, 2)]);
        std::unique_ptr<ModuleProcessor> p = createComponent(registry(), c.id, c.values);
        if (!p || !p->activate(kRate, kBlock)) {
            std::printf("  %-44s  could not be made\n", c.name);
            ++over;
            continue;
        }
        const double us = cost(*p, c.values, seconds);
        const bool bad = us > c.ceilingUs;
        over += bad;
        std::printf("  %-44s %8.0f %9zu B  %6.0f%s\n", c.name, us, c.bytes, c.ceilingUs, bad ? "  OVER" : "");
    }
    return over;
}
