// caw_bench's cost of 1.1.0's voice devices (`caw_bench SECONDS 300` and `303`): Glint, Soar's Harmonizer and Octaver, and Mimic in µs per second of audio and bytes per instance, each against a ceiling.
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

#include "builtin_fx_voice.h"

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
int voiceCost(double seconds) {
    const Case cases[] = {
        // Exciter oversamples 2x at Normal and High quality (the bench's): the medium budget.
        {"Glint: Exciter (2x oversampled)", "org.caw.exciter", {{"variant", 0}}, fx::exciterBytes(), 8000},
        {"Glint: Exciter, tone 8 kHz", "org.caw.exciter", {{"variant", 0}, {"tone", 8000}}, fx::exciterBytes(), 8000},
        {"Glint: Bass", "org.caw.exciter", {{"variant", 1}, {"density", 1}}, fx::exciterBytes(), 2000},
        {"Soar: Harmonizer, 2 voices (default)", "org.caw.shift", {{"variant", 2}}, fx::harmonizerBytes(kRate), 8000},
        {"Soar: Harmonizer, 4 voices, formant 0.5", "org.caw.shift", {{"variant", 2}, {"voices", 4}, {"formant", 0.5}},
         fx::harmonizerBytes(kRate), 24000},
        {"Soar: Octaver, Mono", "org.caw.shift", {{"variant", 3}, {"tracking", 1}, {"up", 0.5}}, fx::octaverBytes(kRate), 2000},
        // Auto on noise runs Mono and Poly together (its fade never settles): the medium budget.
        {"Soar: Octaver, Auto (both paths on noise)", "org.caw.shift", {{"variant", 3}, {"up", 0.5}}, fx::octaverBytes(kRate), 8000},
        {"Soar: Octaver, Poly", "org.caw.shift", {{"variant", 3}, {"tracking", 2}, {"up", 0.5}}, fx::octaverBytes(kRate), 2000},
        // Mimic: 20 bands is Normal (the bench's quality), medium; 32 is High, heavy.
        {"Mimic: built-in saw drone, 20 bands", "org.caw.vocoder", {}, fx::vocoderBytes(), 8000},
        {"Mimic: built-in, 3 unison, 12 bands", "org.caw.vocoder", {{"bands", 1}, {"unison", 3}}, fx::vocoderBytes(), 8000},
        {"Mimic: sidechain carrier, 20 bands", "org.caw.vocoder", {{"carrier", 1}}, fx::vocoderBytes(), 8000},
        {"Mimic: sidechain carrier, 32 bands", "org.caw.vocoder", {{"carrier", 1}, {"bands", 3}}, fx::vocoderBytes(), 24000},
    };
    int over = 0;
    std::printf("1.1.0 voice devices (µs of CPU per second of audio; bytes per instance; ceiling µs/s):\n");
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
