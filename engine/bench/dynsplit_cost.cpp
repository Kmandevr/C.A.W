// caw_bench's cost of 1.1.0's dynamics split (`caw_bench SECONDS 300` and `302`): Talon, Hatch and Duck's new variants in µs per second of audio and bytes per instance, each against a ceiling.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "reference_cost.h"
#include "builtin_components.h"
#include "caw/instrument.hpp"
#include "fx_merged.h"
#include "module_registry.h"

namespace caw::fx {
size_t talonUpBytes(double sampleRate) noexcept;  // the classes' sizes (each allocates nothing else, except Level's buffers)
size_t talonBusBytes() noexcept;
size_t hatchExpandBytes() noexcept;
size_t hatchPedalBytes() noexcept;
size_t duckLevelBytes(double sampleRate) noexcept;
size_t duckCarveBytes() noexcept;
}  // namespace caw::fx

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

// The effect on a busy stereo signal (noise bursts and tones, never silent), keyed (where it takes a key) by the
// same signal 37 frames early, in 64-frame blocks, its display read each block; the best of 3 runs.
double cost(ModuleProcessor& p, const Values& values, double seconds) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [name, v] : values)
            if (d.parameters[k].id == name) params[k].value = v;
    }
    const int frames = static_cast<int>(kRate);
    std::vector<float> inL(frames), inR(frames), keyL(frames), keyR(frames), outL(kBlock), outR(kBlock);
    uint32_t seed = 1;
    for (int i = 0; i < frames; ++i) {
        seed = seed * 1664525u + 1013904223u;
        const double noise = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * (0.05 + 0.3 * ((i / 6000) % 2));
        inL[i] = static_cast<float>(noise + 0.3 * std::sin(2 * 3.14159265358979 * 220 * i / kRate));
        inR[i] = static_cast<float>(0.8 * noise + 0.3 * std::sin(2 * 3.14159265358979 * 330 * i / kRate));
    }
    for (int i = 0; i < frames; ++i) keyL[i] = keyR[i] = i >= 37 ? inL[i - 37] : 0.0f;
    bool keyed = false;
    for (uint32_t k = 0; k < d.portCount; ++k) keyed = keyed || (d.ports[k].input && d.ports[k].id == "sidechain");
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
            const float* key[2] = {keyL.data() + at, keyR.data() + at};
            float* out[2] = {outL.data(), outR.data()};
            if (keyed) {
                const ConstChannelBufferView audioIn[2] = {{in, 2, kBlock}, {key, 2, kBlock}};
                const ChannelBufferView audioOut{out, 2, kBlock};
                ProcessBlock pb;
                pb.frames = kBlock;
                pb.sampleRate = kRate;
                pb.audioIn = audioIn;
                pb.audioInCount = 2;
                pb.audioOut = &audioOut;
                pb.audioOutCount = 1;
                pb.parameters = params.data();
                pb.parameterCount = d.parameterCount;
                pb.transport = &tr;
                p.processPorts(pb);
            } else {
                AudioProcessBlock block;
                block.input = {in, 2, kBlock};
                block.output = {out, 2, kBlock};
                block.frames = kBlock;
                block.sampleRate = kRate;
                block.parameters = params.data();
                block.parameterCount = d.parameterCount;
                block.transport = &tr;
                p.process(block);
            }
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
};

}  // namespace

// Prints each case and returns how many went over their ceilings. Ceilings: the owner's budgets (light 0.5 %,
// medium 2 %, heavy 6 % of an S22+ core) over an assumed 2.5x slower phone core: 2000, 8000 and 24000 µs/s here.
#if defined(__aarch64__) || defined(_M_ARM64) || defined(_MSC_VER)
constexpr double kShapeCeiling = 8000;  // provisional (above)
#else
constexpr double kShapeCeiling = 3000;  // measured
#endif

int dynsplitCost(double seconds) {
    const Values talon{{"talon_layout", 1}};
    auto with = [&](Values v) {
        v.insert(v.end(), talon.begin(), talon.end());
        return v;
    };
    const Case cases[] = {
        {"Talon: Down (the old class, for scale)", "org.caw.compressor", with({{"variant", 0}}), 0, 2000},
        {"Talon: Down, ISP, key low-pass, warm, output", "org.caw.compressor",
         with({{"variant", 0}, {"detect", 2}, {"sc_lpf", 5000}, {"character", 1}, {"output", 2}}), 0, 8000},
        {"Talon: Up (default: peak)", "org.caw.compressor", with({{"variant", 2}, {"threshold", -20}}), fx::talonUpBytes(kRate), 2000},
        {"Talon: Up, RMS, 5 ms look-ahead, warm", "org.caw.compressor",
         with({{"variant", 2}, {"threshold", -20}, {"detect", 1}, {"lookahead", 5}, {"character", 1}}), fx::talonUpBytes(kRate), 2000},
        {"Talon: Up, ISP", "org.caw.compressor", with({{"variant", 2}, {"threshold", -20}, {"detect", 2}}), fx::talonUpBytes(kRate), 8000},
        {"Talon: Bus (default: feedback, auto release)", "org.caw.compressor", with({{"variant", 3}, {"threshold", -24}}),
         fx::talonBusBytes(), 2000},
        {"Talon: Bus, ISP, key filters", "org.caw.compressor",
         with({{"variant", 3}, {"threshold", -24}, {"detect", 2}, {"sc_hpf", 90}, {"sc_lpf", 8000}}), fx::talonBusBytes(), 8000},
        {"Talon: Bus, keyed (fed forward)", "org.caw.compressor", with({{"variant", 3}, {"threshold", -24}, {"sidechain", 1}}),
         fx::talonBusBytes(), 2000},
        {"Hatch: Gate (the old class, for scale)", "org.caw.gate", {{"variant", 0}}, 0, 2000},
        {"Hatch: Expand (default)", "org.caw.gate", {{"variant", 1}, {"threshold", -20}}, fx::hatchExpandBytes(), 2000},
        {"Hatch: Expand, ISP, key filters", "org.caw.gate",
         {{"variant", 1}, {"threshold", -20}, {"detect", 2}, {"sc_hpf", 200}, {"sc_lpf", 6000}}, fx::hatchExpandBytes(), 8000},
        {"Hatch: Pedal gate (tracking)", "org.caw.gate", {{"variant", 2}, {"threshold", -20}}, fx::hatchPedalBytes(), 2000},
        {"Duck: Duck (1.0.8's class, for scale)", "org.caw.duck", {{"variant", 0}}, 0, 2000},
        {"Duck: Level (default)", "org.caw.duck", {{"variant", 1}}, fx::duckLevelBytes(kRate), 2000},
        {"Duck: Level, 200 ms look-ahead", "org.caw.duck", {{"variant", 1}, {"lookahead", 3}}, fx::duckLevelBytes(kRate), 2000},
        {"Duck: Carve, 16 bands, linked", "org.caw.duck", {{"variant", 2}}, fx::duckCarveBytes(), 8000},
        // 24 bands is the High setting: the heavy budget.
        {"Duck: Carve, 24 bands, Mid/Side", "org.caw.duck", {{"variant", 2}, {"bands", 1}, {"stereo", 2}}, fx::duckCarveBytes(), 24000},
        // 2026-11-27 effects pass: about 2,100 on Linux x64 (3,000, measured); Arm64 and Windows clang-cl keep Main's
        // 8,000 (provisional, until a CI run on each runner measures it: docs/engine-performance.md, A8).
        {"Tremolo/Pan: Shape (the old ducker, for scale)", "org.caw.tremolo", {{"variant", 2}}, 0, kShapeCeiling},
    };
    int over = 0;
    std::printf("1.1.0 dynamics split (µs of CPU per second of audio; bytes per instance; ceiling µs/s):\n");
    for (const Case& c : cases) {
        std::unique_ptr<ModuleProcessor> p = createComponent(registry(), c.id, c.values);
        if (!p || !p->activate(kRate, kBlock)) {
            std::printf("  %-48s  could not be made\n", c.name);
            ++over;
            continue;
        }
        const double us = cost(*p, c.values, seconds);
        const bool bad = us > c.ceilingUs;
        over += bad;
        std::printf("  %-48s %8.0f %9zu B  %6.0f%s\n", c.name, us, c.bytes, c.ceilingUs, bad ? "  OVER" : "");
    }
    return over;
}
