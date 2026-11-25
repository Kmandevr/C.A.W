// caw_bench's cost of the drums' 1.1.0, 1.1.2 and 1.1.3 additions (Rook; `caw_bench SECONDS 300` and `323`): each new layer, the pad effects and groove on a busy pad, and the Acoustic kit's grooves per quality, against ceilings.
#include <atomic>
#include <cstdio>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "reference_cost.h"
#include "builtin_components.h"
#include "builtin_drums_layout.h"
#include "drums_acoustic.h"
#include "caw/instrument.hpp"
#include "fp_mode.h"
#include "fx_merged.h"
#include "module_registry.h"
#include "presets.h"
#include "quality.h"

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

// 1.1.2: a kit (a preset's values) playing a pattern of (16th, GM key) on a one-bar loop at 120 BPM, at a quality;
// µs per second of audio.
double kitGroove(const Values& values, const std::vector<std::pair<int, int>>& pattern, double seconds, int quality) {
    std::atomic<int> q{quality};
    std::unique_ptr<ModuleProcessor> p;
    {
        const BuildingQuality building(&q);
        p = createComponent(registry(), "org.caw.drums", {});
        if (!p || !p->activate(kRate, kBlock)) return -1.0;
    }
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    for (const auto& [id, v] : values) {
        const int k = drums::parameterIndex(id);
        if (k >= 0) params[static_cast<size_t>(k)].value = v;
    }
    std::vector<float> l(kBlock), r(kBlock);
    float* channels[2] = {l.data(), r.data()};
    const ChannelBufferView audio{channels, 2, kBlock};
    bench::RelativeCost rel;
    uint32_t id = 1;
    const ScopedFlushDenormals flush;  // as Engine::process runs every component (fp_mode.h)
    for (int run = 0; run < bench::kRuns; ++run) {
        p->reset();
        const int blocks = static_cast<int>(seconds * kRate / kBlock);
        rel.begin();
        for (int b = 0; b < blocks; ++b) {
            rel.tick(b);
            const uint64_t at = static_cast<uint64_t>(b) * kBlock;
            Event ev[64];
            uint32_t count = 0;
            for (const auto& [step, key] : pattern) {  // a 16th is 6000 frames; the bar 96000
                const uint64_t when = static_cast<uint64_t>(step) * 6000u;
                const uint64_t inBar = at % 96000u;
                if (when >= inBar && when < inBar + kBlock && count < 64)
                    ev[count++] = notes::noteOn(static_cast<uint32_t>(when - inBar), id++, key, 0.8);
            }
            const EventInput in{ev, count};
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

Values presetValues(std::string_view name) {
    Values v;
    for (const BuiltinPreset& b : builtinPresets("org.caw.drums"))
        if (b.name == name)
            for (const auto& [id, x] : b.values) v.emplace_back(std::string(id), x);
    return v;
}

struct Case {
    const char* name;
    Values values;
    double ceilingUs;  // µs per second of audio on the x86 CI machine; over it fails
};

}  // namespace

// Prints each case and returns how many went over their ceilings (the pad cases about twice what each measured on the
// x86 box, 2026-11-19: 2.9 to 4.1 ms per second, so a shared runner's noise passes and a path costing double fails;
// the 1.1.2 kits about 1.2 times, below).
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
    // 1.1.2: the Acoustic kit (docs/engine.md, "Drums", Acoustic). A typical groove: kick, snare and hat on 8ths, a
    // ride on quarters; the full kit: every piece (kick, snare, three toms, hat, crash, ride) on every quarter.
    const std::vector<std::pair<int, int>> groove = {{0, 36}, {0, 42}, {0, 51}, {2, 42}, {4, 38}, {4, 42}, {4, 51}, {6, 42},
                                                     {8, 36}, {8, 42}, {8, 51}, {10, 36}, {10, 42}, {12, 38}, {12, 42}, {12, 51}, {14, 42}};
    std::vector<std::pair<int, int>> full;
    for (int step = 0; step < 16; step += 4)
        for (int key : {36, 38, 48, 45, 43, 42, 49, 51}) full.push_back({step, key});
    const Values rock = presetValues("Acoustic kit: Rock"), produced = presetValues("Produced kit: House"),
                 synth = presetValues("Synth kit: 808-style"), old909 = presetValues("Kit: 909"),
                 studio = presetValues("Acoustic kit: Studio");  // 1.1.3: a new Rook's kit, every piece recorded
    Values dryRock = rock;
    dryRock.push_back({"room", 0.0});
    struct KitCase {
        const char* name;
        const Values* values;
        const std::vector<std::pair<int, int>>* pattern;
        int quality;
        double ceilingUs, designUs;  // designUs: the design's target (0: none)
    };
    // The design's targets are on the Acoustic engine itself (its pieces, mics and bleed; docs/engine.md "Drums",
    // Acoustic, Cost): heavy (24,000 µs/s) for a full kit at Normal, medium (8,000) at Eco. The kit's room is 1.1.0's
    // reverb, priced on its own as the design does ("then 1.1.0's room"). The ceilings catch regressions: about 1.4
    // times the highest of three runs on the x86 box at CI's length (`caw_bench 0.5 323`, 2026-11-24): 1.2 failed on
    // CI's Arm64 runner, which reads 5-10 % higher even on 1.1.0's own Kit: 909 (PR #261).
    const KitCase kits[] = {
        {"Acoustic kit: typical groove (Normal)", &dryRock, &groove, kQualityNormal, 13000, 9600},  // 2.4 % of a phone core
        {"Acoustic kit: typical groove (Eco)", &dryRock, &groove, kQualityEco, 7500, 0},
        {"Acoustic kit: full kit ringing (Normal)", &dryRock, &full, kQualityNormal, 28500, 24000},
        {"Acoustic kit: full kit ringing (Eco)", &dryRock, &full, kQualityEco, 15000, 8000},
        {"Acoustic kit: full kit ringing (High, exports)", &dryRock, &full, kQualityHigh, 44500, 0},
        {"Acoustic kit: typical groove with its room (Normal)", &rock, &groove, kQualityNormal, 20500, 0},
        {"Acoustic kit: typical groove with its room (Eco)", &rock, &groove, kQualityEco, 13500, 0},
        // 1.1.3 (2026-11-25, `caw_bench 0.5 323` on a loaded box: 10,264 and 20,378): its hats and cymbals run no model.
        {"Acoustic kit: Studio, typical groove (Normal)", &studio, &groove, kQualityNormal, 14500, 0},
        {"Acoustic kit: Studio, full kit ringing (Normal)", &studio, &full, kQualityNormal, 28500, 0},
        {"Kit: 909 groove (1.1.0's Layers, for scale)", &old909, &groove, kQualityNormal, 16500, 0},
        {"Produced kit: House groove", &produced, &groove, kQualityNormal, 33000, 0},
        {"Synth kit: 808-style groove", &synth, &groove, kQualityNormal, 24500, 0},
    };
    std::printf("Drums 1.1.2 (Rook kits), a one-bar loop at 120 BPM (µs of CPU per second of audio; ceiling µs/s; design):\n");
    for (const KitCase& c : kits) {
        const double us = kitGroove(*c.values, *c.pattern, seconds, c.quality);
        const bool bad = us > c.ceilingUs || us <= 0.0;
        over += bad ? 1 : 0;
        char design[48] = "";
        if (c.designUs > 0.0) std::snprintf(design, sizeof design, "  design %5.0f%s", c.designUs, us > c.designUs ? " (over)" : "");
        std::printf("  %-52s %8.0f  (ceiling %5.0f)%s%s\n", c.name, us, c.ceilingUs, design, bad ? "  OVER" : "");
    }
    std::printf("  memory per instance added by 1.1.2 at 48 kHz: %zu bytes (16 pieces' modes and states, the mic lines)\n",
                sizeof(drums::acoustic::AcousticKit) + static_cast<size_t>(48000 * 0.008 + 4) * 16 * sizeof(float));
    return over;
}
