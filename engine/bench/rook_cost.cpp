// caw_bench's cost of the drums' 1.1.0 additions (Rook; `caw_bench SECONDS 300` and `323`): each new layer, the pad effects and groove on a busy pad, against ceilings.
#include <cstdio>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "reference_cost.h"
#include "builtin_components.h"
#include "builtin_drums_layout.h"
#include "caw/instrument.hpp"
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

// Pad A1 in Single mode hit on every 16th at 120 BPM (a 16th is 6000 frames; its sounds overlap at polyphony 2),
// a playing transport so groove works; µs per second of audio against the reference.
double busyPad(const Values& values, double seconds) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), "org.caw.drums", {});
    if (!p || !p->activate(kRate, kBlock)) return -1.0;
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    Values all = {{"mode", drums::kModeSingle}};
    const drums::Voice& n = drums::neutralVoice();
    for (uint32_t k = 0; k < drums::kPadParams; ++k) all.emplace_back("a1_" + std::string(drums::padParamSuffix(k)), n[k]);
    all.insert(all.end(), values.begin(), values.end());
    for (const auto& [id, v] : all) {
        const int k = drums::parameterIndex(id);
        if (k >= 0) params[static_cast<size_t>(k)].value = v;
    }
    std::vector<float> l(kBlock), r(kBlock);
    float* channels[2] = {l.data(), r.data()};
    const ChannelBufferView audio{channels, 2, kBlock};
    Transport transport;
    transport.playing = true;
    bench::RelativeCost rel;
    uint32_t id = 1;
    for (int run = 0; run < bench::kRuns; ++run) {
        p->reset();
        const int blocks = static_cast<int>(seconds * kRate / kBlock);
        rel.begin();
        for (int b = 0; b < blocks; ++b) {
            rel.tick(b);
            const uint64_t at = static_cast<uint64_t>(b) * kBlock;
            Event on = notes::noteOn(static_cast<uint32_t>((6000 - at % 6000) % 6000), id, 60, 0.8);
            const bool hit = at % 6000 + kBlock > 6000 || at % 6000 == 0;
            if (hit) ++id;
            const EventInput in{hit ? &on : nullptr, hit ? 1u : 0u};
            transport.beat = static_cast<double>(at) / 24000.0;
            ProcessBlock pb;
            pb.frames = kBlock;
            pb.sampleRate = kRate;
            pb.audioOut = &audio;
            pb.audioOutCount = 1;
            pb.eventIn = &in;
            pb.eventInCount = 1;
            pb.parameters = params.data();
            pb.parameterCount = d.parameterCount;
            pb.transport = &transport;
            p->processPorts(pb);
        }
        rel.end();
    }
    return rel.us();
}

struct Case {
    const char* name;
    Values values;
    double ceilingUs;  // µs per second of audio on the x86 CI machine; over it fails
};

}  // namespace

// Prints each case and returns how many went over their ceilings (about twice what each measured on the x86 box,
// 2026-11-19: 2.9 to 4.1 ms per second, so a shared runner's noise passes and a path costing double fails).
int rookCost(double seconds) {
    const Case cases[] = {
        {"body and noise (1.0.9's layers, for scale)", {{"a1_body_on", 1}, {"a1_noise_on", 1}}, 8000},
        {"FM layer", {{"a1_fm_on", 1}, {"a1_fm_feedback", 0.5}}, 8000},
        {"physical: string", {{"a1_phys_on", 1}}, 8000},
        {"physical: stiff string", {{"a1_phys_on", 1}, {"a1_phys_model", drums::kPhysStiff}}, 8000},
        {"texture: bands", {{"a1_tex_on", 1}}, 8000},
        {"texture: crackle", {{"a1_tex_on", 1}, {"a1_tex_mode", drums::kTexCrackle}}, 8000},
        {"pad FX: ring mod", {{"a1_body_on", 1}, {"a1_ring_mix", 0.5}}, 8000},
        {"echo send (kit echo on)", {{"a1_body_on", 1}, {"a1_echo_send", 0.5}, {"echo", 0.5}}, 8000},
        {"groove: swing, humanize, flam", {{"a1_body_on", 1}, {"a1_swing", 0.5}, {"a1_humanize", 0.5}, {"a1_flam", 0.5}}, 8000},
    };
    int over = 0;
    std::printf("Drums 1.1.0 (Rook), pad A1 hit every 16th (µs of CPU per second of audio; ceiling µs/s):\n");
    for (const Case& c : cases) {
        const double us = busyPad(c.values, seconds);
        const double ceiling = c.ceilingUs;
        const bool bad = us > ceiling || us <= 0.0;
        over += bad ? 1 : 0;
        std::printf("  %-44s %8.0f  (ceiling %5.0f)%s\n", c.name, us, ceiling, bad ? "  OVER" : "");
    }
    std::printf("  memory per instance added by 1.1.0 at 48 kHz: %zu bytes (waveguide lines and the echo's 2 s)\n",
                static_cast<size_t>((48000 / 30 + 8) * 64 + 2 * (2 * 48000 + 8)) * sizeof(float));
    return over;
}
