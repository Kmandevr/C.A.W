// caw_bench's cost of 1.1.0's clean-up devices (`caw_bench SECONDS 300` and `310`): Preen's and Hush's variants in µs per second of audio and bytes per instance, each against a ceiling.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "fx_clean.h"
#include "fx_merged.h"
#include "module_registry.h"

using namespace caw;
using Clock = std::chrono::steady_clock;
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
    double best = 1e30;
    for (int run = 0; run < 3; ++run) {
        p.reset();
        const int blocks = static_cast<int>(seconds * kRate / kBlock);
        const auto t0 = Clock::now();
        for (int b = 0; b < blocks; ++b) {
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
        best = std::min(best, std::chrono::duration<double, std::micro>(Clock::now() - t0).count() / seconds);
    }
    return best;
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
int cleanCost(double seconds) {
    const char* preen = "org.caw.clean";
    const char* hush = "org.caw.vocalclean";
    const Case cases[] = {
        {"Preen: Denoise, Normal (43 ms)", preen, {{"variant", 0}}, fx::preenBytes(0, kRate), 24000},
        {"Preen: Denoise, Eco (21 ms)", preen, {{"variant", 0}, {"quality", 0}}, fx::preenBytes(0, kRate), 24000},
        {"Preen: Denoise, High (85 ms)", preen, {{"variant", 0}, {"quality", 2}}, fx::preenBytes(0, kRate), 24000},
        {"Preen: Denoise, monitoring (11 ms)", preen, {{"variant", 0}, {"monitor", 1}}, fx::preenBytes(0, kRate), 24000},
        {"Preen: Denoise, learning", preen, {{"variant", 0}, {"learn", 1}}, fx::preenBytes(0, kRate), 24000},
        {"Preen: De-hum, 8 harmonics, following", preen, {{"variant", 1}, {"frequency", 1}}, fx::preenBytes(1, kRate), 8000},
        {"Preen: De-hum, 16 harmonics", preen, {{"variant", 1}, {"frequency", 1}, {"harmonics", 16}}, fx::preenBytes(1, kRate), 8000},
        {"Preen: De-reverb, Normal", preen, {{"variant", 2}}, fx::preenBytes(2, kRate), 24000},
        {"Preen: De-reverb, High", preen, {{"variant", 2}, {"quality", 2}}, fx::preenBytes(2, kRate), 24000},
        {"Hush: De-click (10 clicks a second)", hush, {{"variant", 0}}, fx::hushBytes(0, kRate), 8000},
        {"Hush: De-click, Crackle", hush, {{"variant", 0}, {"mode", 1}}, fx::hushBytes(0, kRate), 8000},
        {"Hush: De-plosive", hush, {{"variant", 1}}, fx::hushBytes(1, kRate), 2000},
        {"Hush: Breath", hush, {{"variant", 2}}, fx::hushBytes(2, kRate), 8000},
    };
    int over = 0;
    std::printf("1.1.0 clean-up (µs of CPU per second of audio; bytes per instance; ceiling µs/s):\n");
    for (const Case& c : cases) {
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
