// caw_bench's cost of Lark (org.caw.pitchfix, `caw_bench SECONDS 300` and `306`): live pitch correction in µs per second of audio and bytes per instance, each against a ceiling.
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

#include "builtin_fx_lark.h"

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

// The effect on a busy stereo signal (noise bursts and tones, never silent: voiced and unvoiced hops both), keyed (where it takes a key) by the
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

// Prints each case and returns how many went over their ceilings. Ceilings: the owner's budgets over an assumed
// 2.5x slower phone core (light 2000, medium 8000 µs/s here); Lark's design target is medium (2 % of a core).
int larkCost(double seconds) {
    const Case cases[] = {
        {"Lark: chromatic, speed 40 (default)", "org.caw.pitchfix", {}, fx::larkBytes(kRate), 8000},
        {"Lark: C major, hard tune", "org.caw.pitchfix", {{"scale", 1}, {"speed", 0}, {"keep_vibrato", 0}}, fx::larkBytes(kRate), 8000},
        {"Lark: formant +5, following the pitch", "org.caw.pitchfix", {{"formant", 5}, {"formant_keep", 0}}, fx::larkBytes(kRate), 8000},
        {"Lark: formant -12 (the most grains)", "org.caw.pitchfix", {{"formant", -12}}, fx::larkBytes(kRate), 8000},
        {"Lark: monitor (10 ms)", "org.caw.pitchfix", {{"monitor", 1}}, fx::larkBytes(kRate), 8000},
    };
    int over = 0;
    std::printf("Lark (µs of CPU per second of audio; bytes per instance; ceiling µs/s):\n");
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
