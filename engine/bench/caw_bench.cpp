// Measures the engine like a phone's audio callback does: time per callback, real-time load, compile and memory.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <atomic>
#include <map>
#include <random>
#include <thread>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "reference_cost.h"
#include "audio_clips.h"
#include "builtin_components.h"
#include "builtin_flagship.h"
#include "caw/instrument.hpp"
#include "component_chain.h"
#include "engine.h"
#include "fx_merged.h"
#include "graph.h"
#include "mix_pool.h"
#include "presets.h"
#include "project.h"
#include "render.h"
#include "stress_scenarios.h"

using namespace caw;
using namespace caw::stress;
using Clock = std::chrono::steady_clock;

int packCost(double seconds);  // bench/pack_cost.cpp: the AutoStacc beta pack against its ceilings
int cleanCost(double seconds);  // bench/clean_cost.cpp: Preen and Hush against their ceilings
int toolsCost(double seconds);  // bench/tools_cost.cpp: 1.1.0's tools against their ceilings
int dynsplitCost(double seconds);  // bench/dynsplit_cost.cpp: 1.1.0's dynamics split against its ceilings
int voiceCost(double seconds);  // bench/voice_cost.cpp: 1.1.0's voice devices against their ceilings
int larkCost(double seconds);  // bench/lark_cost.cpp: Lark (org.caw.pitchfix) against its ceilings
int ravenCost(double seconds);  // bench/raven_cost.cpp: Flagship's 1.1.0 synthesis (Raven) against its ceilings
int samplerCost(double seconds);  // bench/sampler_cost.cpp: the sampler's plain and stretched zones against their ceilings
int rookCost(double seconds);  // bench/rook_cost.cpp: the drums' 1.1.0 additions (Rook) against their ceilings
int flockCost(double seconds);  // bench/flock_cost.cpp: Flock (org.caw.flock) against its ceilings

namespace {

constexpr int kRate = 48000;
constexpr int kCallback = 192;  // a common Android burst (AAudio low latency); the budget is 4 ms at 48 kHz

long rssKb() {
    std::ifstream f("/proc/self/status");
    std::string line;
    while (std::getline(f, line))
        if (line.rfind("VmRSS:", 0) == 0) return std::atol(line.c_str() + 6);
    return -1;
}

// The song scenarios (`caw_bench SECONDS 400 K`: K 0 First loop, 1 the typical song, 2 with per-note FX, an audio
// clip and a sampler) and the profile mode (`caw_bench SECONDS 401 K`): the time each component takes per
// kProfileCallback-frame callback, over the whole run, and the host's own share (everything else Engine::process
// does: notes, the mix graph, sends, buses, meters, the safety limiter).
constexpr int kProfileCallback = 256;

// The compiler that built this bench, for the JSON report (MSVC has no __VERSION__).
std::string compilerName() {
#if defined(__VERSION__)
    return __VERSION__;
#elif defined(_MSC_FULL_VER)
    return "MSVC " + std::to_string(_MSC_FULL_VER);
#else
    return "unknown";
#endif
}

const char* scenarioName(int k) {
    return k == 0 ? "first loop" : k == 1 ? "typical song" : k == 2 ? "typical song + extras" : "three tracks";
}

ProjectSpec songScenario(int k, const std::string& dir) {
    if (k == 0) return firstLoop();
    if (k == 3) return threeTracks();
    std::string error;
    ProjectSpec p = typicalSong(k == 2, dir, &error);
    if (!error.empty()) { std::fprintf(stderr, "%s\n", error.c_str()); std::exit(3); }
    return p;
}

struct Result {
    double meanUs = 0, p99Us = 0, maxUs = 0, load = 0;
};

// The flagship synth's cost per held voice and per unison copy (`caw_bench SECONDS 200`): 8 notes held for
// `seconds` straight through the instrument (no engine around it) in kCallback-frame blocks, the best of 3 runs
// per setting; the differences between settings give each part's share.
double heldNotes(const std::vector<std::pair<std::string, double>>& values, int count, double seconds) {
    Engine e(kRate);
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent("org.caw.synth.flagship");
    if (!p || !p->activate(kRate, kCallback)) return 0.0;
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    std::vector<float> l(kCallback), r(kCallback);
    float* channels[2] = {l.data(), r.data()};
    const ChannelBufferView audio{channels, 2, kCallback};
    std::vector<Event> on;
    for (int i = 0; i < count; ++i) on.push_back(notes::noteOn(0, static_cast<uint32_t>(i + 1), 48 + 3 * i, 0.9));
    double best = 1e30;
    for (int run = 0; run < 3; ++run) {
        p->reset();
        const int calls = static_cast<int>(seconds * kRate / kCallback);
        const auto t0 = Clock::now();
        for (int c = 0; c < calls; ++c) {
            const EventInput in{c == 0 ? on.data() : nullptr, c == 0 ? static_cast<uint32_t>(on.size()) : 0u};
            ProcessBlock b;
            b.frames = kCallback;
            b.audioOut = &audio;
            b.audioOutCount = 1;
            b.eventIn = &in;
            b.eventInCount = 1;
            b.parameters = params.data();
            b.parameterCount = d.parameterCount;
            p->processPorts(b);
        }
        best = std::min(best, std::chrono::duration<double, std::micro>(Clock::now() - t0).count() / seconds);
    }
    return best;  // microseconds of CPU per second of audio
}

// The effects suite's cost (`caw_bench SECONDS 300`): each effect alone on a busy stereo signal (noise bursts
// and tones, never silent, so nothing sleeps) in the engine's 64-frame chain blocks, at its defaults and with its
// heavier options, the best of 3 runs; microseconds of CPU per second of audio (10000 = 1% of a core).
double effectCost(const char* id, const std::vector<std::pair<std::string, double>>& values, double seconds) {
    static const ModuleRegistry registry = [] {
        ModuleRegistry r;
        registerBuiltinComponents(r);
        return r;
    }();
    std::unique_ptr<ModuleProcessor> p = createComponent(registry, id, values);  // a merged device: `variant`'s class
    if (!p || !p->activate(kRate, 64)) return 0.0;
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [name, v] : values)
            if (d.parameters[k].id == name) params[k].value = v;
    }
    const int frames = kRate;  // a second of input, looped
    std::vector<float> inL(frames), inR(frames), outL(64), outR(64);
    uint32_t seed = 1;
    for (int i = 0; i < frames; ++i) {
        seed = seed * 1664525u + 1013904223u;
        const double noise = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * (0.05 + 0.3 * ((i / 6000) % 2));
        inL[i] = static_cast<float>(noise + 0.3 * std::sin(2 * 3.14159265358979 * 220 * i / kRate));
        inR[i] = static_cast<float>(0.8 * noise + 0.3 * std::sin(2 * 3.14159265358979 * 330 * i / kRate));
    }
    bench::RelativeCost rel;  // against the reference, interleaved (reference_cost.h)
    for (int run = 0; run < bench::kRuns; ++run) {
        p->reset();
        const int blocks = static_cast<int>(seconds * kRate / 64);
        rel.begin();
        for (int b = 0; b < blocks; ++b) {
            rel.tick(b);
            const int at = (b * 64) % (frames - 64);
            const float* in[2] = {inL.data() + at, inR.data() + at};
            float* out[2] = {outL.data(), outR.data()};
            AudioProcessBlock block;
            block.input = {in, 2, 64};
            block.output = {out, 2, 64};
            block.frames = 64;
            block.sampleRate = kRate;
            block.parameters = params.data();
            block.parameterCount = d.parameterCount;
            p->process(block);
        }
        rel.end();
    }
    return rel.us();
}

// False when a case with a ceiling (microseconds per second, the x86 figure: the phone budget / 2.5, an
// assumption) went over it, so CI fails a regression.
bool effectsCost(double seconds) {
    using Values = std::vector<std::pair<std::string, double>>;
    struct Case {
        const char* name;
        const char* id;
        Values values;
        double ceiling = 0;  // 0: none
    };
    const Case cases[] = {
        {"eq (default: 6 bands at 0 dB)", "org.caw.eq", {}},
        {"eq, 8 bands with gain, 2 cuts at 48 dB", "org.caw.eq",
         {{"b1_on", 1}, {"b1_type", 5}, {"b8_on", 1}, {"b8_type", 8}, {"b2_gain", 3}, {"b3_gain", -3}, {"b4_gain", 4},
          {"b5_gain", 2}, {"b6_gain", -2}, {"b7_gain", 3}}},
        {"compressor (default: peak, linked)", "org.caw.compressor", {}},
        {"compressor, RMS, unlinked, sidechain HPF", "org.caw.compressor", {{"detect", 1}, {"link", 0}, {"sc_hpf", 120}}},
        // 1.0.8's Duck (1.1.0: Ducker's variant 0; its own input, no key: a leveller) in each detection mode.
        {"Ducker: Duck (default: RMS)", "org.caw.duck", {{"variant", 0}, {"amount", 1}, {"threshold", -30}}},
        {"Ducker: Duck, Peak", "org.caw.duck", {{"variant", 0}, {"amount", 1}, {"threshold", -30}, {"detection", 1}}},
        {"Ducker: Duck, ISP (4x true peak)", "org.caw.duck", {{"variant", 0}, {"amount", 1}, {"threshold", -30}, {"detection", 2}}},
        {"limiter (default: true peak)", "org.caw.limiter", {{"gain", 12}}},
        {"limiter, sample peak", "org.caw.limiter", {{"gain", 12}, {"true_peak", 0}}},
        {"reverb (default: modulated)", "org.caw.reverb.pro", {}},
        {"reverb, no modulation", "org.caw.reverb.pro", {{"mod", 0}}},
        {"reverb, ducking", "org.caw.reverb.pro", {{"duck", 0.5}}},
        // FX consolidation part E: Delay and Reverb's variants against the old ids they replace.
        {"Reverb: Hall (default)", "org.caw.reverb", {}},
        {"shimmer (old id)", "org.caw.shimmer", {}},
        {"Reverb: Shimmer", "org.caw.reverb", {{"variant", 1}}},
        {"Delay: Digital (default)", "org.caw.delay", {}},
        {"Delay: Ping-pong (old id: ping-pong delay)", "org.caw.delay", {{"variant", 1}}},
        {"delay (default)", "org.caw.delay.pro", {}},
        {"delay, ping-pong, ducking", "org.caw.delay.pro", {{"mode", 1}, {"duck", 0.5}}},
        {"saturator (default: tape, 2x)", "org.caw.saturator", {}},
        {"saturator, tape, no oversampling", "org.caw.saturator", {{"oversample", 0}}},
        {"saturator, tube, 2x, tone", "org.caw.saturator", {{"mode", 1}, {"tone", 0.5}}},
        // FX consolidation part B: each Drive and Bit distortion variant against the old id it replaces.
        {"distortion (old id)", "org.caw.distortion", {}},
        {"Drive: Distortion", "org.caw.drive", {{"variant", 0}}},
        {"Drive: Saturate (default: tape, 2x)", "org.caw.drive", {{"variant", 1}}},
        {"clipper (old id), 4x", "org.caw.clipper", {{"drive", 6}, {"oversample", 3}}},
        {"Drive: Clip, 4x", "org.caw.drive", {{"variant", 2}, {"drive", 6}, {"oversample", 3}}},
        {"phase distortion (old id)", "org.caw.phasedist", {}},
        {"Drive: Phase", "org.caw.drive", {{"variant", 3}}},
        {"bitcrush (old id)", "org.caw.bitcrush", {}},
        {"Bit distortion: Crush", "org.caw.bits", {{"variant", 0}}},
        {"gate", "org.caw.gate", {}},
        {"transient shaper", "org.caw.transient", {{"attack", 0.5}, {"sustain", 0.3}}},
        {"filter (default: 24 dB SVF)", "org.caw.filter", {}},
        {"filter, ladder, LFO, envelope", "org.caw.filter", {{"type", 6}, {"lfo_amount", 0.5}, {"env_amount", 0.3}}},
        {"phaser (default: 6 stages)", "org.caw.phaser", {}},
        {"phaser, 12 stages", "org.caw.phaser", {{"stages", 5}}},
        {"flanger", "org.caw.flanger", {}},
        {"utility, bass mono, DC block", "org.caw.utility", {{"bass_mono", 1}, {"dc_block", 1}, {"width", 1.3}}},
        {"chorus (existing, for scale)", "org.caw.chorus", {}},
        {"ping-pong delay (existing)", "org.caw.delay.pingpong", {}},
        // FX consolidation: each merged variant against the old id it replaces (the cost must not rise).
        {"pitch shifter (old id), a fifth up", "org.caw.pitchshift", {{"semitones", 7}}},
        {"Pitch/Shift: Pitch, a fifth up", "org.caw.shift", {{"variant", 0}, {"semitones", 7}}},
        {"frequency shifter (old id), 100 Hz", "org.caw.freqshift", {{"shift", 100}}},
        {"Pitch/Shift: Frequency, 100 Hz", "org.caw.shift", {{"variant", 1}, {"shift", 100}}},
        // 1.1.0: the EQ's and Filter's new modes, each with a ceiling (light 2,000, medium 8,000, heavy 24,000).
        {"EQ: Bands, 4 dynamic bands", "org.caw.eq",
         {{"b2_dyn", 1}, {"b3_dyn", 1}, {"b3_gain", 3}, {"b5_dyn", 1}, {"b6_dyn", 1}, {"b2_thresh", -40}, {"b3_thresh", -40},
          {"b5_thresh", -40}, {"b6_thresh", -40}}, 8000},
        {"EQ: Bands, 8 dynamic bands, 2 cuts", "org.caw.eq",
         {{"b1_on", 1}, {"b8_on", 1}, {"b1_dyn", 1}, {"b2_dyn", 1}, {"b3_dyn", 1}, {"b4_dyn", 1}, {"b5_dyn", 1}, {"b6_dyn", 1},
          {"b7_dyn", 1}, {"b8_dyn", 1}}, 24000},  // heavy: its static bands alone cost about 5,800
        {"EQ: Linear, Eco (2,048 taps)", "org.caw.eq", {{"variant", 4}, {"lin_quality", 0}, {"b3_gain", 3}}, 8000},
        {"EQ: Linear, Normal (4,096 taps)", "org.caw.eq", {{"variant", 4}, {"lin_quality", 1}, {"b3_gain", 3}}, 8000},
        {"EQ: Linear, High (8,192 taps)", "org.caw.eq", {{"variant", 4}, {"lin_quality", 2}, {"b3_gain", 3}}, 8000},
        {"EQ: Linear, Normal, learning Match", "org.caw.eq", {{"variant", 4}, {"match", 1}, {"match_learn", 3}}, 8000},
        {"EQ: Match (curve playing)", "org.caw.eq", {{"variant", 5}}, 8000},
        {"EQ: Match, learning both", "org.caw.eq", {{"variant", 5}, {"match_learn", 3}}, 8000},
        {"Filter: Wah, envelope", "org.caw.filter", {{"variant", 3}}, 2000},
        {"Filter: Wah, pedal", "org.caw.filter", {{"variant", 3}, {"mode", 1}}, 2000},
    };
    std::printf("effects: microseconds of CPU per second of stereo audio, 64-frame blocks (10000 = 1%% of a core)\n");
    bool ok = true;
    for (const Case& c : cases) {
        const double us = effectCost(c.id, c.values, seconds);
        const bool over = c.ceiling > 0 && us > c.ceiling;
        ok = ok && !over;
        if (c.ceiling > 0) std::printf("  %-44s %8.0f   ceiling %6.0f%s\n", c.name, us, c.ceiling, over ? "  OVER" : "");
        else std::printf("  %-44s %8.0f\n", c.name, us);
    }
    return ok;
}

// 1.1.0's new effect modes (`caw_bench SECONDS 300`, after the suite): each with a ceiling, so a regression fails
// the run (exit 1). A ceiling is the mode's plan budget on one phone core (light 0.5 %, medium 2 %, heavy 6 %)
// divided by 2.5, **[Assumption]** the Galaxy S22+ being 2-3x slower than an x86 box: light 2000, medium 8000,
// heavy 24000 µs per second of audio here.
bool modesCostOver(double seconds) {
    using Values = std::vector<std::pair<std::string, double>>;
    constexpr double kLight = 2000, kMedium = 8000;  // heavy 24000 when a mode of that class comes
    struct Case {
        const char* name;
        const char* id;
        Values values;
        double ceiling;
    };
    const Case cases[] = {
        {"Delay: Tape (default)", "org.caw.delay", {{"variant", 2}}, kMedium},
        {"Delay: Tape, worn (wow, flutter, wear 1)", "org.caw.delay", {{"variant", 2}, {"wow", 1}, {"flutter", 1}, {"wear", 1}}, kMedium},
        {"Delay: Reverse (default)", "org.caw.delay", {{"variant", 3}}, kMedium},
        {"Delay: Multi-tap (default, unpitched)", "org.caw.delay", {{"variant", 4}}, kMedium},
        {"Delay: Multi-tap, 4 pitched taps", "org.caw.delay", {{"variant", 4}, {"t1_pitch", 7}, {"t2_pitch", 12}, {"t3_pitch", -5}, {"t4_pitch", -12}, {"t4_level", 0.5}}, kMedium},
        {"Reverb: Room (default)", "org.caw.reverb", {{"variant", 2}}, kMedium},
        {"Reverb: Plate (default)", "org.caw.reverb", {{"variant", 3}}, kMedium},
        {"Reverb: Spring (default)", "org.caw.reverb", {{"variant", 4}}, kMedium},
        {"Reverb: Gated (default)", "org.caw.reverb", {{"variant", 5}}, kMedium},
        {"Reverb: Reverse (default)", "org.caw.reverb", {{"variant", 6}}, kMedium},
        {"Drive: Amp (default: Crunch, 1x)", "org.caw.drive", {{"variant", 4}}, kMedium},
        {"Drive: Amp, High gain (Auto: 2x)", "org.caw.drive", {{"variant", 4}, {"voicing", 3}}, kMedium},
        {"Drive: Pedal (default: Overdrive, 1x)", "org.caw.drive", {{"variant", 5}}, kMedium},
        {"Drive: Pedal, Fuzz (Auto: 2x)", "org.caw.drive", {{"variant", 5}, {"type", 2}}, kMedium},
        {"Drive: Bands (default: 3 bands)", "org.caw.drive", {{"variant", 6}}, kMedium},
        {"Drive: Bands, 4 bands", "org.caw.drive", {{"variant", 6}, {"bands", 3}}, kMedium},
        {"Drive: Bands, 1 band", "org.caw.drive", {{"variant", 6}, {"bands", 0}}, kMedium},
        {"Bit distortion: Bitwise (default: 12 bits)", "org.caw.bits", {{"variant", 1}}, kLight},
        {"Bit distortion: Bitwise, shift, XOR, AND", "org.caw.bits", {{"variant", 1}, {"shift", 1}, {"xor", 4080}, {"and", 65504}}, kLight},
        {"Bit distortion: Bitwise, echo ring (1.1.1)", "org.caw.bits", {{"variant", 1}, {"combine", 2}, {"echo", 3}, {"combine_mask", 65280}, {"tone", 9000}}, kLight},
        {"Bit distortion: Bitwise, every glitch op", "org.caw.bits", {{"variant", 1}, {"xor", 3840}, {"or", 48}, {"rotate", 1}, {"reverse", 3}, {"combine", 2}, {"freeze", 61440}, {"flips", 0.1}, {"pattern", 93}, {"tone", 6000}, {"gate", -50}}, kLight},
        {"Convolver: Cab (default: 4x12)", "org.caw.convolver", {{"variant", 1}}, kMedium},
        {"Convolver: Cab, far mic", "org.caw.convolver", {{"variant", 1}, {"distance", 1}}, kMedium},
        // modes-bench end
    };
    std::printf("1.1.0 modes: microseconds of CPU per second of stereo audio, 64-frame blocks, and each one's ceiling\n");
    bool over = false;
    for (const Case& c : cases) {
        const double us = effectCost(c.id, c.values, seconds);
        const bool bad = us > c.ceiling || us <= 0.0;
        over = over || bad;
        std::printf("  %-44s %8.0f  (ceiling %5.0f)%s\n", c.name, us, c.ceiling, bad ? "  OVER" : "");
    }
    return over;
}

void flagshipVoiceCost(double seconds) {
    using Values = std::vector<std::pair<std::string, double>>;
    const Values dry = {{"flt1_on", 0}, {"fx_reverb_on", 0}, {"env1_sustain", 1}, {"mod1_src", 0}};
    auto with = [&](Values v) {
        Values x = dry;
        x.insert(x.end(), v.begin(), v.end());
        return x;
    };
    const double idle = heldNotes(dry, 0, seconds);
    const double x1 = heldNotes(with({{"osc1_unison", 1}}), 8, seconds);
    const double x7 = heldNotes(with({{"osc1_unison", 7}}), 8, seconds);
    const double x16 = heldNotes(with({{"osc1_unison", 16}}), 8, seconds);
    const double ladder = heldNotes(with({{"osc1_unison", 1}, {"flt1_on", 1}}), 8, seconds);
    const double svf = heldNotes(with({{"osc1_unison", 1}, {"flt1_on", 1}, {"flt1_type", 3}}), 8, seconds);
    const double matrix = heldNotes(with({{"osc1_unison", 1}, {"mod1_src", 4}, {"mod1_dst", 3}, {"mod1_amt", 0.3}}), 8, seconds);
    const double reverb = heldNotes(with({{"osc1_unison", 1}, {"fx_reverb_on", 1}}), 8, seconds);
    const double def = heldNotes({}, 8, seconds);
    std::printf("flagship, 8 held notes: microseconds of CPU per second of audio (10000 = 1%% of a core)\n");
    std::printf("  no notes                         %8.0f\n", idle);
    std::printf("  one copy each, no filter         %8.0f   a voice: %5.0f\n", x1, (x1 - idle) / 8);
    std::printf("  seven copies                     %8.0f   a copy:  %5.0f\n", x7, (x7 - x1) / (8 * 6));
    std::printf("  sixteen copies                   %8.0f   a copy:  %5.0f\n", x16, (x16 - x1) / (8 * 15));
    std::printf("  one copy + ladder                %8.0f   a ladder pair: %5.0f\n", ladder, (ladder - x1) / 8);
    std::printf("  one copy + SVF                   %8.0f   an SVF pair:   %5.0f\n", svf, (svf - x1) / 8);
    std::printf("  one copy + an LFO slot           %8.0f   a slot per voice: %5.0f\n", matrix, (matrix - x1) / 8);
    std::printf("  one copy + reverb                %8.0f   the reverb: %5.0f\n", reverb, reverb - x1);
    std::printf("  the default patch                %8.0f   a voice: %5.0f\n", def, (def - idle) / 8);
}


// Plays `seconds` of audio in kCallback-frame callbacks; `each` runs between callbacks (control-thread work).
Result play(Engine& e, double seconds, const std::function<void(int)>& each = nullptr) {
    const int calls = static_cast<int>(seconds * kRate / kCallback);
    std::vector<float> l(kCallback), r(kCallback);
    std::vector<double> us;
    us.reserve(static_cast<size_t>(calls));
    for (int c = 0; c < calls; ++c) {
        if (each) each(c);
        const auto t0 = Clock::now();
        e.process(l.data(), r.data(), kCallback);
        us.push_back(std::chrono::duration<double, std::micro>(Clock::now() - t0).count());
    }
    Result res;
    for (double v : us) res.meanUs += v;
    res.meanUs /= static_cast<double>(us.size());
    std::sort(us.begin(), us.end());
    res.p99Us = us[us.size() * 99 / 100];
    res.maxUs = us.back();
    res.load = res.meanUs / (1e6 * kCallback / kRate);
    return res;
}

void report(const char* name, const Result& r) {
    std::printf("%-34s mean %8.1f us  p99 %8.1f us  max %8.1f us  load %6.2f%%\n", name, r.meanUs, r.p99Us,
                r.maxUs, 100.0 * r.load);
}

double ms(Clock::time_point a) { return std::chrono::duration<double, std::milli>(Clock::now() - a).count(); }

// Times `seconds` of kCallback-frame calls of `call`, the same way play() times Engine::process.
Result timeCalls(double seconds, const std::function<bool()>& call) {
    const int calls = static_cast<int>(seconds * kRate / kCallback);
    std::vector<double> us;
    us.reserve(static_cast<size_t>(calls));
    for (int c = 0; c < calls; ++c) {
        const auto t0 = Clock::now();
        if (!call()) { std::fprintf(stderr, "graph process failed\n"); std::exit(3); }
        us.push_back(std::chrono::duration<double, std::micro>(Clock::now() - t0).count());
    }
    Result res;
    for (double v : us) res.meanUs += v;
    res.meanUs /= static_cast<double>(us.size());
    std::sort(us.begin(), us.end());
    res.p99Us = us[us.size() * 99 / 100];
    res.maxUs = us.back();
    res.load = res.meanUs / (1e6 * kCallback / kRate);
    return res;
}

void profileSong(int k, double seconds) {
    const std::string dir = (std::filesystem::temp_directory_path() / "caw_bench_song").string();
    std::filesystem::create_directories(dir);
    Engine e(kRate);
    if (const char* q = std::getenv("CAW_BENCH_QUALITY")) e.setQuality(std::atoi(q));
    const std::string warn = e.setProject(songScenario(k, dir));
    e.play();
    const int calls = static_cast<int>(seconds * kRate / kProfileCallback);
    std::vector<float> l(kProfileCallback), r(kProfileCallback);
    for (int c = 0; c < kRate / kProfileCallback; ++c) e.process(l.data(), r.data(), kProfileCallback);  // warm up 1 s
    static ChainProfile profile;  // large: not on the stack
    profile = ChainProfile{};
    e.setProfile(&profile);
    uint64_t total = 0;
    float peak = 0;
    for (int c = 0; c < calls; ++c) {
        const auto t0 = Clock::now();
        e.process(l.data(), r.data(), kProfileCallback);
        total += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - t0).count());
        for (int i = 0; i < kProfileCallback; ++i) peak = std::max(peak, std::fabs(l[i]));
    }
    e.setProfile(nullptr);
    std::printf("%s: %d callbacks of %d frames, peak %.2f; ns per callback (budget %.0f)\n", scenarioName(k),
                calls, kProfileCallback, peak, 1e9 * kProfileCallback / kRate);
    struct Row { std::string id; uint64_t ns, ran, calls; int n; };
    std::map<std::string, Row> byId;
    uint64_t inComponents = 0;
    std::vector<Row> rows;
    for (uint32_t s = 0; s < profile.used; ++s) {
        const ChainProfile::Slot& x = profile.slots[s];
        const std::string id = (x.id ? *x.id : std::string("?")) + (x.modulator ? " (modulator)" : "");
        rows.push_back({id, x.ns, x.ran, x.calls, 1});
        Row& g = byId[id];
        g.id = id;
        g.ns += x.ns;
        g.ran += x.ran;
        g.calls += x.calls;
        g.n += 1;
        inComponents += x.ns;
    }
    std::vector<Row> grouped;
    for (auto& [id, g] : byId) grouped.push_back(g);
    std::sort(grouped.begin(), grouped.end(), [](const Row& a, const Row& b) { return a.ns > b.ns; });
    const double per = 1.0 / calls;
    std::printf("  %-40s %10.0f ns  100.0%%\n", "Engine::process (all)", total * per);
    std::printf("  %-40s %10.0f ns  %5.1f%%\n", "host (everything but components)", (total - std::min(total, inComponents)) * per,
                100.0 * (total - std::min(total, inComponents)) / total);
    for (const Row& g : grouped)
        std::printf("  %-40s %10.0f ns  %5.1f%%  x%d, ran %3.0f%% of blocks\n", g.id.c_str(), g.ns * per, 100.0 * g.ns / total, g.n,
                    g.calls ? 100.0 * g.ran / g.calls : 0.0);
    if (std::getenv("CAW_BENCH_EACH")) {  // every instance, in chain-build order
        for (const Row& x : rows) std::printf("    %-38s %10.0f ns\n", x.id.c_str(), x.ns * per);
    }
    if (warn.find("\"ok\":true") == std::string::npos || std::getenv("CAW_BENCH_WARN")) std::printf("setProject: %s\n", warn.c_str());
}

// Graph scenarios are sub-microsecond, so they report nanoseconds.
void reportNs(const char* name, const Result& r) {
    std::printf("%-34s mean %8.0f ns  p99 %8.0f ns  max %8.0f ns  load %7.3f%%\n", name, 1e3 * r.meanUs,
                1e3 * r.p99Us, 1e3 * r.maxUs, 100.0 * r.load);
}

constexpr uint32_t kGraphNodes = 8;
const char* const kGraphIds[kGraphNodes] = {"n0", "n1", "n2", "n3", "n4", "n5", "n6", "n7"};

GraphResourceBudget graphBudget() {
    GraphResourceBudget budget;
    budget.maxWorkingBytes = 64u * 1024u * 1024u;
    return budget;
}

const PortDescriptor kStereoEffectPorts[] = {
    {"in", PortType::Audio, ChannelLayout::Stereo, true},
    {"out", PortType::Audio, ChannelLayout::Stereo, false},
};
const ModuleDescriptor kStereoEffect{"bench.stereo.gain", 1, kStereoEffectPorts, 2, nullptr, 0, nullptr, 0, {}};

// A legacy stereo-only processor, as existing native modules are written.
class StereoGain final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kStereoEffect; }
    void process(const StereoProcessBlock& b) noexcept override {
        for (uint32_t i = 0; i < b.frames; ++i) {
            b.outputLeft[i] = b.inputLeft[i] * 0.999f;
            b.outputRight[i] = b.inputRight[i] * 0.999f;
        }
    }
};

// An 8-node stereo chain through the stereo wrapper: the cost existing callers see.
void graphStereoBench(double secs) {
    std::vector<StereoGain> gains(kGraphNodes);
    std::vector<GraphNode> nodes;
    std::vector<GraphConnection> edges;
    std::vector<ModuleProcessor*> processors;
    for (uint32_t n = 0; n < kGraphNodes; ++n) {
        nodes.push_back({kGraphIds[n], &kStereoEffect});
        processors.push_back(&gains[n]);
        if (n) edges.push_back({n - 1, 1, n, 0});
    }
    GraphExecutor executor;
    if (executor.prepare(nodes, edges, processors, kGraphNodes - 1, kCallback, kRate, graphBudget()) !=
        GraphError::Ok) { std::fprintf(stderr, "graph prepare failed\n"); std::exit(3); }
    std::vector<float> inL(kCallback, 0.5f), inR(kCallback, -0.5f), outL(kCallback), outR(kCallback);
    reportNs("graph: 8 stereo nodes (wrapper)", timeCalls(secs, [&] {
        return executor.process(inL.data(), inR.data(), outL.data(), outR.data(), kCallback);
    }));
}

// A generic planar processor for any channel count.
class PlanarGain final : public ModuleProcessor {
public:
    explicit PlanarGain(const ModuleDescriptor& d) : d_(&d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return *d_; }
    bool process(const AudioProcessBlock& b) noexcept override {
        for (uint32_t c = 0; c < b.output.channelCount; ++c)
            for (uint32_t i = 0; i < b.frames; ++i) b.output.channels[c][i] = b.input.channels[c][i] * 0.999f;
        return true;
    }
private:
    const ModuleDescriptor* d_;
};

// 8-node planar chains at 1, 2, 6 and 8 channels through process(AudioProcessBlock).
void graphPlanarBench(double secs) {
    struct Shape { const char* name; ChannelLayout layout; uint32_t channels; };
    const Shape shapes[] = {{"graph: 8 mono nodes (planar)", ChannelLayout::Mono, 1},
                            {"graph: 8 stereo nodes (planar)", ChannelLayout::Stereo, 2},
                            {"graph: 8 5.1 nodes (planar)", ChannelLayout::Surround51, 6},
                            {"graph: 8 7.1 nodes (planar)", ChannelLayout::Surround71, 8}};
    for (const Shape& shape : shapes) {
        const PortDescriptor ports[] = {{"in", PortType::Audio, shape.layout, true},
                                        {"out", PortType::Audio, shape.layout, false}};
        const ModuleDescriptor effect{"bench.planar.gain", 1, ports, 2, nullptr, 0, nullptr, 0, {}};
        std::vector<PlanarGain> gains(kGraphNodes, PlanarGain(effect));
        std::vector<GraphNode> nodes;
        std::vector<GraphConnection> edges;
        std::vector<ModuleProcessor*> processors;
        for (uint32_t n = 0; n < kGraphNodes; ++n) {
            nodes.push_back({kGraphIds[n], &effect});
            processors.push_back(&gains[n]);
            if (n) edges.push_back({n - 1, 1, n, 0});
        }
        GraphExecutor executor;
        if (executor.prepare(nodes, edges, processors, kGraphNodes - 1, kCallback, kRate, graphBudget()) !=
            GraphError::Ok) { std::fprintf(stderr, "graph prepare failed\n"); std::exit(3); }
        std::vector<std::vector<float>> in(shape.channels, std::vector<float>(kCallback, 0.5f));
        std::vector<std::vector<float>> out(shape.channels, std::vector<float>(kCallback));
        std::vector<const float*> inPtr;
        std::vector<float*> outPtr;
        for (uint32_t c = 0; c < shape.channels; ++c) { inPtr.push_back(in[c].data()); outPtr.push_back(out[c].data()); }
        const ConstChannelBufferView inView{inPtr.data(), shape.channels, kCallback};
        const ChannelBufferView outView{outPtr.data(), shape.channels, kCallback};
        reportNs(shape.name, timeCalls(secs, [&] { return executor.process(inView, outView, kCallback); }));
    }
}

// ---------- The suite (`caw_bench SECONDS 500 [options]`): fixed scenarios at a stated callback, repeated, for CI ----------
// Options: --frames N (callback size, default 256), --runs N (default 3), --only ID[,ID] (scenario ids), --label TEXT,
// --threads N (the mix pool's workers, speed phase 5c: 0, the default, runs the mix graph on one thread; N > 0 runs
// every level of two or more nodes on the pool, whatever the load, as Engine::MixParallel::Always; `auto` takes
// MixPool::defaultWorkers(), the count a live device gets on this machine, speed phase 5d), --mode auto (with
// --threads N: the pool on Engine::MixParallel::Auto, as a live device runs it, each callback's measured time
// reported through Engine::reportLoad so Auto decides when to use it; the default, always, is the above),
// --json PATH and --md PATH (machine-readable results and a markdown table). Each run plays every scenario in turn
// (a fresh Engine each: set up, 0.25 s stopped to apply the project, then Play); a scenario's result is the median
// of its runs' means and p99s and the largest worst case of any run. docs/engine-performance.md has the numbers.
// The scenarios themselves are in engine/src/stress_scenarios.cpp, shared with the app's Benchmark.

struct SuiteRow {
    std::string id, name;
    std::vector<SuiteStats> runs;
    double seconds = -1;  // tail phases: the length of the phase in audio seconds
};

std::string jsonEscape(const std::string& s) {
    std::string o;
    for (char c : s) {
        if (c == '"' || c == '\\') o += '\\';
        if (static_cast<unsigned char>(c) >= 0x20) o += c;
    }
    return o;
}

const char* targetName() {
#if defined(__ANDROID__) && defined(__aarch64__)
    return "android-arm64";
#elif defined(__ANDROID__)
    return "android";
#elif defined(__linux__) && defined(__aarch64__)
    return "linux-arm64";
#elif defined(__linux__) && defined(__x86_64__)
    return "linux-x64";
#elif defined(_WIN32)
    return "windows";
#else
    return "other";
#endif
}

int runSuite(double secs, int argc, char** argv) {
    int frames = 256, runs = 3, threads = 0;
    bool autoMode = false;
    std::string only, label = targetName(), jsonPath, mdPath;
    for (int a = 3; a < argc; ++a) {
        const std::string k = argv[a];
        const char* v = a + 1 < argc ? argv[a + 1] : nullptr;
        if (!v) { std::fprintf(stderr, "%s needs a value\n", k.c_str()); return 2; }
        if (k == "--frames") frames = std::atoi(v);
        else if (k == "--runs") runs = std::atoi(v);
        else if (k == "--threads") threads = std::string(v) == "auto" ? static_cast<int>(MixPool::defaultWorkers()) : std::atoi(v);
        else if (k == "--only") only = std::string(",") + v + ",";
        else if (k == "--mode" && (std::string(v) == "auto" || std::string(v) == "always")) autoMode = std::string(v) == "auto";
        else if (k == "--label") label = v;
        else if (k == "--json") jsonPath = v;
        else if (k == "--md") mdPath = v;
        else { std::fprintf(stderr, "unknown option %s\n", k.c_str()); return 2; }
        ++a;
    }
    if (frames < 16 || frames > 8192 || runs < 1 || runs > 50 || secs <= 0 || threads < 0 ||
        threads > static_cast<int>(MixPool::kMaxWorkers)) {
        std::fprintf(stderr, "bad --frames, --runs, --threads (0..%u) or SECONDS\n", MixPool::kMaxWorkers);
        return 2;
    }
    const double budgetUs = 1e6 * frames / kRate;
    const std::string dir = (std::filesystem::temp_directory_path() / "caw_bench_suite").string();
    std::filesystem::create_directories(dir);
    std::vector<SuiteScenario> all = suiteScenarios();
    std::vector<SuiteRow> rows;
    std::map<std::string, size_t> rowOf;
    auto row = [&](const std::string& id, const std::string& name) -> SuiteRow& {
        auto it = rowOf.find(id);
        if (it != rowOf.end()) return rows[it->second];
        rowOf[id] = rows.size();
        rows.push_back({id, name, {}, -1});
        return rows.back();
    };
    std::printf("caw_bench suite: %s, callback %d frames at %d Hz (budget %.1f us), %.0f s per scenario, %d runs, "
                "--threads %d%s\n", label.c_str(), frames, kRate, budgetUs, secs, runs, threads, autoMode ? " --mode auto" : "");
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int run = 0; run < runs; ++run) {
        for (const SuiteScenario& sc : all) {
            if (!only.empty() && only.find(std::string(",") + sc.id + ",") == std::string::npos) continue;
            Engine e(kRate);
            if (threads > 0) {
                if (!e.startMixPool(static_cast<uint32_t>(threads))) {
                    std::fprintf(stderr, "could not start %d mix workers\n", threads);
                    return 3;
                }
                e.setMixParallel(autoMode ? Engine::MixParallel::Auto : Engine::MixParallel::Always);
            } else {
                e.setMixParallel(Engine::MixParallel::Never);
            }
            const std::string warn = e.setProject(sc.make(dir));
            if (warn.find("\"ok\":true") == std::string::npos) {
                std::fprintf(stderr, "%s: setProject: %s\n", sc.id, warn.c_str());
                return 3;
            }
            for (int c = 0; c < kRate / 4 / frames; ++c) e.process(l.data(), r.data(), frames);  // apply the project
            e.play();
            const int calls = static_cast<int>((sc.tail ? kTailSeconds : secs) * kRate / frames);
            std::vector<double> us(static_cast<size_t>(calls));
            std::vector<float> peak(static_cast<size_t>(calls));
            for (int c = 0; c < calls; ++c) {
                const auto t0 = Clock::now();
                e.process(l.data(), r.data(), frames);
                us[static_cast<size_t>(c)] = std::chrono::duration<double, std::micro>(Clock::now() - t0).count();
                if (autoMode) e.reportLoad(us[static_cast<size_t>(c)] / budgetUs, frames, frames);  // as a device callback
                float m = 0;
                for (int i = 0; i < frames; ++i) m = std::max(m, std::max(std::fabs(l[static_cast<size_t>(i)]), std::fabs(r[static_cast<size_t>(i)])));
                peak[static_cast<size_t>(c)] = m;
            }
            if (autoMode && e.mixTailFallbacks() > 0)  // the pool's late callbacks outnumbered serial's
                std::fprintf(stderr, "%s: Auto's tail guard went serial %u times\n", sc.id, e.mixTailFallbacks());
            if (autoMode && e.sheddingStats().shed > 0)  // the times then lack the layers shed
                std::fprintf(stderr, "%s: the engine shed %llu layers (the load passed the budget)\n", sc.id,
                             static_cast<unsigned long long>(e.sheddingStats().shed));
            const size_t n = us.size();
            if (!sc.tail) {
                row(sc.id, sc.name).runs.push_back(stats(us, 0, n));
                continue;
            }
            // Phases: the notes' bar; the tail, until the last callback louder than kSilence; the silence after it.
            const size_t notesEnd = std::min(n, static_cast<size_t>(kTailNotesSeconds * kRate / frames));
            size_t loud = notesEnd;
            for (size_t c = notesEnd; c < n; ++c)
                if (peak[c] > kSilence) loud = c + 1;
            const double perCall = static_cast<double>(frames) / kRate;
            SuiteRow& a = row(std::string(sc.id) + "_notes", std::string(sc.name) + ": notes (2 s)");
            a.runs.push_back(stats(us, 0, notesEnd));
            a.seconds = notesEnd * perCall;
            SuiteRow& b = row(std::string(sc.id) + "_ringing", std::string(sc.name) + ": ringing out");
            b.runs.push_back(stats(us, notesEnd, loud));
            b.seconds = (loud - notesEnd) * perCall;
            SuiteRow& s = row(std::string(sc.id) + "_silence", std::string(sc.name) + ": silence after");
            s.runs.push_back(stats(us, loud, n));
            s.seconds = (n - loud) * perCall;
        }
    }
    struct Out { const SuiteRow* row; double mean, p99, worst, worstAtS; size_t callbacks; };
    std::vector<Out> out;
    for (const SuiteRow& x : rows) {
        std::vector<double> means, p99s;
        double worst = 0, worstAt = 0;
        for (const SuiteStats& s : x.runs) {
            means.push_back(s.meanUs), p99s.push_back(s.p99Us);
            if (s.maxUs > worst) worst = s.maxUs, worstAt = static_cast<double>(s.maxAt) * frames / kRate;
        }
        out.push_back({&x, median(means), median(p99s), worst, worstAt, x.runs.empty() ? 0 : x.runs.front().callbacks});
    }
    std::printf("%-40s %10s %10s %10s %8s %8s %8s\n", "scenario", "mean us", "p99 us", "worst us", "mean %", "worst %", "worst at");
    for (const Out& o : out)
        std::printf("%-40s %10.1f %10.1f %10.1f %7.2f%% %7.1f%% %7.2fs%s\n", o.row->name.c_str(), o.mean, o.p99, o.worst,
                    100 * o.mean / budgetUs, 100 * o.worst / budgetUs, o.worstAtS,
                    o.row->seconds >= 0 ? (" (" + std::to_string(o.row->seconds).substr(0, 5) + " s)").c_str() : "");
    if (!jsonPath.empty()) {
        std::string j = "{\"tool\":\"caw_bench\",\"format\":1,\"label\":\"" + jsonEscape(label) + "\",\"target\":\"" + targetName() +
                        "\",\"compiler\":\"" + jsonEscape(compilerName()) + "\",\"rate\":" + std::to_string(kRate) +
                        ",\"frames\":" + std::to_string(frames) + ",\"budget_us\":" + std::to_string(budgetUs) +
                        ",\"runs\":" + std::to_string(runs) + ",\"seconds\":" + std::to_string(secs) +
                        ",\"threads\":" + std::to_string(threads) + ",\"scenarios\":[";
        for (size_t k = 0; k < out.size(); ++k) {
            const Out& o = out[k];
            j += std::string(k ? "," : "") + "{\"id\":\"" + o.row->id + "\",\"name\":\"" + jsonEscape(o.row->name) +
                 "\",\"callbacks\":" + std::to_string(o.callbacks) + ",\"mean_us\":" + std::to_string(o.mean) +
                 ",\"p99_us\":" + std::to_string(o.p99) + ",\"worst_us\":" + std::to_string(o.worst) +
                 ",\"mean_load_pct\":" + std::to_string(100 * o.mean / budgetUs) +
                 ",\"worst_load_pct\":" + std::to_string(100 * o.worst / budgetUs) +
                 ",\"worst_at_s\":" + std::to_string(o.worstAtS);
            if (o.row->seconds >= 0) j += ",\"phase_s\":" + std::to_string(o.row->seconds);
            j += ",\"run_means_us\":[";
            for (size_t q = 0; q < o.row->runs.size(); ++q) j += (q ? "," : "") + std::to_string(o.row->runs[q].meanUs);
            j += "],\"run_worst_us\":[";
            for (size_t q = 0; q < o.row->runs.size(); ++q) j += (q ? "," : "") + std::to_string(o.row->runs[q].maxUs);
            j += "]}";
        }
        j += "]}\n";
        std::ofstream(jsonPath) << j;
    }
    if (!mdPath.empty()) {
        std::ofstream md(mdPath);
        char line[512];
        std::snprintf(line, sizeof line, "### %s: %d frames at %d Hz (budget %.0f us), %.0f s x %d runs, --threads %d%s\n\n",
                      label.c_str(), frames, kRate, budgetUs, secs, runs, threads, autoMode ? " --mode auto" : "");
        md << line << "| Scenario | Mean us | p99 us | Worst us | Mean load | Worst load | Worst at |\n|---|---:|---:|---:|---:|---:|---:|\n";
        for (const Out& o : out) {
            std::snprintf(line, sizeof line, "| %s | %.1f | %.1f | %.1f | %.2f%% | %.1f%% | %.2f s |\n", o.row->name.c_str(), o.mean,
                          o.p99, o.worst, 100 * o.mean / budgetUs, 100 * o.worst / budgetUs, o.worstAtS);
            md << line;
        }
    }
    return 0;
}


// `caw_bench SECONDS 600 [--only ID] [--frames N] [--app] [--random]`: a long run, fast-forwarded. Plays a suite
// scenario for SECONDS of audio in device-like callbacks (beginCallback, process, afterCallback, reportLoad, as
// engine/platform/audio_miniaudio.cpp does) and prints each minute's mean, p99 and worst callback time, so a
// slowdown over time shows as a rising row. --app also runs the app's read-only polls on another thread at their
// real rates in audio time (meters, layer meters and scopes 30 Hz, a display 60 Hz, modulator outputs 20 Hz, note
// FX stats 7 Hz); without it nothing calls the engine, as when the app is in the background. --random draws each
// callback's size from 1-2048 frames.
int runLong(double secs, int argc, char** argv) {
    int frames = 256;
    bool app = false, random = false;
    std::string only = "song8";
    for (int a = 3; a < argc; ++a) {
        const std::string k = argv[a];
        if (k == "--app") { app = true; continue; }
        if (k == "--random") { random = true; continue; }
        const char* v = a + 1 < argc ? argv[a + 1] : nullptr;
        if (!v) { std::fprintf(stderr, "%s needs a value\n", k.c_str()); return 2; }
        if (k == "--frames") frames = std::atoi(v);
        else if (k == "--only") only = v;
        else { std::fprintf(stderr, "unknown option %s\n", k.c_str()); return 2; }
        ++a;
    }
    const std::string dir = (std::filesystem::temp_directory_path() / "caw_bench_suite").string();
    std::filesystem::create_directories(dir);
    ProjectSpec project;
    bool found = false;
    for (const SuiteScenario& sc : suiteScenarios())
        if (only == sc.id) project = sc.make(dir), found = true;
    if (!found) { std::fprintf(stderr, "no scenario %s\n", only.c_str()); return 2; }
    Engine e(kRate);
    e.setProject(project);
    std::vector<float> l(4096), r(4096);
    for (int c = 0; c < kRate / 4 / 256; ++c) e.process(l.data(), r.data(), 256);
    e.play();
    std::atomic<int64_t> audioFrames{0};
    std::atomic<bool> done{false};
    std::thread poller;
    std::vector<std::string> ids;
    for (const LayerSpec& layer : project.layers) ids.push_back(layer.id);
    if (app)
        poller = std::thread([&] {
            int64_t next[6] = {0, 0, 0, 0, 0, 0};
            const int64_t period[6] = {kRate / 30, kRate / 30, kRate / 30, kRate / 60, kRate / 20, kRate / 7};
            std::vector<float> buf(kScopeSize);
            NoteFxStats nfx;
            while (!done.load()) {
                const int64_t t = audioFrames.load();
                bool any = false;
                for (int k = 0; k < 6; ++k) {
                    if (t < next[k]) continue;
                    next[k] = t + period[k];
                    any = true;
                    switch (k) {
                        case 0: (void)e.meters(); break;
                        case 1: e.layerMeters(static_cast<int>(ids.size()), [](void*, int, const LayerMeter&) {}, nullptr); break;
                        case 2: e.scope(kScopeMaster, buf.data(), 512); for (int i = 0; i < static_cast<int>(ids.size()); ++i) e.scope(i, buf.data(), 256); break;
                        case 3: for (const std::string& id : ids) e.componentDisplay(id, 0, buf.data(), static_cast<uint32_t>(buf.size())); break;
                        case 4: e.modulatorOutputs("lfo", buf.data(), 8); break;
                        case 5: e.noteFxStats(ids.front(), nfx); break;
                    }
                }
                if (!any) std::this_thread::yield();
            }
        });
    std::mt19937 rng(7);
    std::uniform_int_distribution<int> size(1, 2048);
    const int64_t total = static_cast<int64_t>(secs * kRate), minute = 60LL * kRate;
    std::vector<double> us;
    int64_t played = 0, bad = 0;
    float peak = 0;
    std::printf("caw_bench long run: %s, %s callbacks, %s, %.0f s of audio\n", only.c_str(),
                random ? "random 1-2048 frame" : (std::to_string(frames) + "-frame").c_str(),
                app ? "app polls on another thread" : "no app calls (backgrounded)", secs);
    std::printf("%8s %10s %10s %10s %8s %8s\n", "minute", "mean us/ms", "p99 us/ms", "worst us/ms", "peak", "bad");
    LiveAudio& live = e.liveAudio();
    while (played < total) {
        const int n = random ? size(rng) : frames;
        const auto t0 = Clock::now();
        int doneFrames = 0;
        while (doneFrames < n) {  // the device callback's chunking (kChunk 4096 there)
            const int m = std::min(n - doneFrames, 4096);
            live.beginCallback(nullptr, 0, m);
            e.process(l.data(), r.data(), m);
            live.afterCallback(l.data(), r.data(), m);
            for (int i = 0; i < m; ++i) {
                if (!std::isfinite(l[static_cast<size_t>(i)]) || !std::isfinite(r[static_cast<size_t>(i)])) ++bad;
                peak = std::max(peak, std::max(std::fabs(l[static_cast<size_t>(i)]), std::fabs(r[static_cast<size_t>(i)])));
            }
            doneFrames += m;
        }
        const double used = std::chrono::duration<double, std::micro>(Clock::now() - t0).count();
        e.reportLoad(used / (1e6 * n / kRate), n);
        us.push_back(used * 1000.0 * kRate / 1e6 / n);  // microseconds per millisecond of audio: size independent
        if (std::getenv("CAW_BENCH_SPIKES") && us.back() > 1000.0)  // a callback over its budget: when in the song
            std::printf("  spike %.0f us/ms at %.4f s (%d frames)\n", us.back(), static_cast<double>(played) / kRate, n);
        const int64_t before = played;
        played += n;
        audioFrames.store(played);
        if (played / minute != before / minute || played >= total) {
            std::vector<double> x = us;
            double mean = 0;
            for (double v : x) mean += v;
            mean /= static_cast<double>(x.size());
            std::sort(x.begin(), x.end());
            std::printf("%8.1f %10.1f %10.1f %10.1f %8.3f %8lld\n", static_cast<double>(played) / minute, mean,
                        x[x.size() * 99 / 100], x.back(), peak, static_cast<long long>(bad));
            std::fflush(stdout);
            us.clear();
            peak = 0;
        }
    }
    done.store(true);
    if (poller.joinable()) poller.join();
    return 0;
}

// `caw_bench SECONDS 601 [--only ID|FILE.json] [--frames N|--random] [--app] [--rate HZ]`: per-track drift. Renders the scenario twice,
// in 64-frame callbacks (the reference) and in the given callbacks, with every track tapped, and prints per
// track and per minute the largest difference between the two, so a track sliding out of time shows as a growing
// number.
int runDrift(double secs, int argc, char** argv) {
    int frames = 441, rate = kRate;
    bool random = false, app = false;
    std::string only = "song8";
    for (int a = 3; a < argc; ++a) {
        const std::string k = argv[a];
        if (k == "--random") { random = true; continue; }
        if (k == "--app") { app = true; continue; }
        const char* v = a + 1 < argc ? argv[a + 1] : nullptr;
        if (!v) return 2;
        if (k == "--frames") frames = std::atoi(v);
        else if (k == "--rate") rate = std::atoi(v);
        else if (k == "--only") only = v;
        ++a;
    }
    const std::string dir = (std::filesystem::temp_directory_path() / "caw_bench_suite").string();
    std::filesystem::create_directories(dir);
    ProjectSpec project;
    for (const SuiteScenario& sc : suiteScenarios())
        if (only == sc.id) project = sc.make(dir);
    if (only.size() > 5 && only.substr(only.size() - 5) == ".json") {  // a project file (the engine's JSON)
        std::ifstream f(only);
        const std::string json((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        std::string error;
        if (!parseProject(json, project, error)) { std::fprintf(stderr, "%s\n", error.c_str()); return 3; }
    }
    const size_t tracks = project.layers.size();
    const int64_t total = static_cast<int64_t>(secs * rate);
    auto render = [&](bool ref, std::vector<std::vector<float>>& out) {
        Engine e(rate);
        e.setProject(project);
        std::vector<float> l(4096), r(4096);
        std::vector<std::vector<float>> tl(tracks, std::vector<float>(4096)), tr(tracks, std::vector<float>(4096));
        for (size_t t = 0; t < tracks; ++t) e.setOutputTap(project.layers[t].id, tl[t].data(), tr[t].data());
        e.process(l.data(), r.data(), 64);
        e.play();
        out.assign(tracks + 1, std::vector<float>(static_cast<size_t>(total)));
        std::mt19937 rng(7);
        std::uniform_int_distribution<int> size(1, 2048);
        int64_t at = 0;
        int calls = 0;
        while (at < total) {
            int n = ref ? 64 : random ? size(rng) : frames;
            n = static_cast<int>(std::min<int64_t>(n, total - at));
            e.process(l.data(), r.data(), n);
            if (app && !ref && ++calls % 8 == 0) { (void)e.meters(); }
            for (size_t t = 0; t < tracks; ++t) std::copy_n(tl[t].data(), n, out[t].data() + at);
            std::copy_n(l.data(), n, out[tracks].data() + at);
            at += n;
        }
    };
    std::vector<std::vector<float>> a, b;
    render(true, a);
    render(false, b);
    std::printf("drift: %s, %s vs 64-frame callbacks, %.0f s\n", only.c_str(), random ? "random" : std::to_string(frames).c_str(), secs);
    const int64_t minute = 60LL * rate;
    for (size_t t = 0; t <= tracks; ++t) {
        int64_t first = -1, last = -1, count = 0;
        for (int64_t i = 0; i < total; ++i)
            if (a[t][static_cast<size_t>(i)] != b[t][static_cast<size_t>(i)]) { if (first < 0) first = i; last = i; ++count; }
        if (first >= 0) std::printf("  differs from frame %lld (%.3f s) to %lld (%.3f s), %lld frames\n", static_cast<long long>(first), first / double(rate), static_cast<long long>(last), last / double(rate), static_cast<long long>(count));
        std::printf("%-10s", t < tracks ? project.layers[t].id.c_str() : "master");
        for (int64_t m0 = 0; m0 < total; m0 += minute) {
            float d = 0;
            for (int64_t i = m0; i < std::min(total, m0 + minute); ++i) d = std::max(d, std::fabs(a[t][static_cast<size_t>(i)] - b[t][static_cast<size_t>(i)]));
            std::printf(" %8.2g", d);
        }
        std::printf("\n");
    }
    return 0;
}

// A built-in preset's values (empty when it has no such preset).
Values builtinPresetValues(const char* id, std::string_view name) {
    Values v;
    for (const BuiltinPreset& b : builtinPresets(id))
        if (b.name == name)
            for (const auto& [k, x] : b.values) v.emplace_back(std::string(k), x);
    return v;
}

// 1.1.2 (the owner's spikes on 1.1.1, 2026-11-24): a song on the devices 1.1.0-1.1.2 added, which no Benchmark
// scenario plays: Rook's Acoustic kit, a piano and a cello (Timber's until 1.1.3, now Starling and Nightingale; the cello through Lark), Flock, Talon's
// Bus and Up compressors and Plume's Linear EQ. caw_bench's spike rows only (not one of the app's Benchmark's).
ProjectSpec devices112() {
    ProjectSpec p;
    p.name = "1.1.2 devices";
    p.bpm = 120;
    p.loopBars = 2;
    std::string drums, piano, cello, flock;
    for (int at = 0; at < 32; ++at)
        drums += std::to_string(at) + (at % 8 == 0 ? " C2,F#2" : at % 8 == 4 ? " D2,F#2" : at % 2 ? " F#2" : " F#2,C2") + " 1 0.9\n";
    const char* chords[] = {"A3,C4,E4,G4", "F3,A3,C4,E4", "C3,E3,G3,B3", "G3,B3,D4,F4"};
    for (int at = 0; at < 8; ++at) piano += std::to_string(at * 4) + " " + chords[at % 4] + " 3 0.7\n";
    const char* line[] = {"A2", "C3", "E3", "G3", "F3", "E3", "D3", "C3"};
    for (int at = 0; at < 8; ++at) cello += std::to_string(at * 4) + " " + line[at] + " 4 0.8\n";
    for (int at = 0; at < 4; ++at) flock += std::to_string(at * 8) + " " + chords[at] + " 8 0.6\n";
    p.modules = {{"drums", patternSource("Drums", "2 bars", drums)}, {"piano", patternSource("Piano", "2 bars", piano)},
                 {"cello", patternSource("Cello", "2 bars", cello)}, {"flock", patternSource("Flock", "2 bars", flock)}};
    addInstrumentLayer(p, "Drums", "org.caw.drums", builtinPresetValues("org.caw.drums", "Acoustic kit: Rock"), "drums", 0.7,
                       {component("org.caw.compressor", {{"variant", 3}}), component("org.caw.eq", {{"variant", 4}})});
    addInstrumentLayer(p, "Piano", "org.caw.starling", builtinPresetValues("org.caw.starling", "Grand piano"), "piano", 0.5,
                       {component("org.caw.compressor", {{"variant", 2}})});
    addInstrumentLayer(p, "Cello", "org.caw.nightingale", builtinPresetValues("org.caw.nightingale", "Solo cello"), "cello", 0.5,
                       {component("org.caw.pitchfix"), component("org.caw.eq", {{"variant", 4}})});
    addInstrumentLayer(p, "Flock", "org.caw.flock", {}, "flock", 0.4);
    return p;
}

// `caw_bench SECONDS 602 [--only ID[,ID]] [--runs N] [--threads 0|auto] [--frames N] [--cost]`: where the one-off slow
// callbacks come from. Plays each Benchmark scenario as the Benchmark's DSP rows do (0.25 s stopped, Play, 1.7 s
// untimed, then SECONDS timed; --threads auto: the mix pool on Auto as Engine::useBenchmarkMixPool, the default 0:
// serial) N times (default 3) from a fresh engine, and prints each run's p50, p99, worst and its 5 slowest
// callbacks (index and µs). A slow callback that comes back at the same index in every run is work in the code
// (deterministic: a lazy build, a recompute); one that moves is the machine (preemption, interrupts). --cost reads
// every slot's cost (Engine::componentCost) four times a second of audio, as a device header does, so the audio
// thread times every slot throughout (the readout's cost on the callback). --check RATIO (a CI test) fails when a
// scenario's slowest callback, by its fastest run, is over RATIO times the median callback.
int runSpikes(double secs, int argc, char** argv) {
    int frames = 256, runs = 3;
    double check = 0;  // --check RATIO: fail on a slow callback that is work (see below)
    bool pool = false, cost = false;
    std::string only;
    for (int a = 3; a < argc; ++a) {
        const std::string k = argv[a];
        if (k == "--cost") { cost = true; continue; }
        const char* v = a + 1 < argc ? argv[a + 1] : nullptr;
        if (!v) { std::fprintf(stderr, "%s needs a value\n", k.c_str()); return 2; }
        if (k == "--frames") frames = std::atoi(v);
        else if (k == "--runs") runs = std::atoi(v);
        else if (k == "--threads") pool = std::string(v) != "0";
        else if (k == "--only") only = std::string(",") + v + ",";
        else if (k == "--check") check = std::atof(v);
        else { std::fprintf(stderr, "unknown option %s\n", k.c_str()); return 2; }
        ++a;
    }
    if (frames < 16 || frames > 4096 || runs < 1 || runs > 20 || secs <= 0 || check < 0) return 2;
    int failed = 0;
    const std::string dir = (std::filesystem::temp_directory_path() / "caw_bench_suite").string();
    std::filesystem::create_directories(dir);
    const int64_t calls = static_cast<int64_t>(secs * kRate / frames);
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    std::printf("%-18s %3s %8s %8s %8s  slowest callbacks (index:us)\n", "scenario", "run", "p50 us", "p99 us", "worst");
    std::vector<SuiteScenario> all = benchmarkScenarios();
    SuiteScenario extra;
    extra.id = "devices_112";
    extra.name = "1.1.2 devices";
    extra.make = [](const std::string&) { return devices112(); };
    all.push_back(extra);
    for (const SuiteScenario& sc : all) {
        if (!only.empty() && only.find(std::string(",") + sc.id + ",") == std::string::npos) continue;
        ProjectSpec project;
        std::string error;
        if (!makeScenario(sc, dir, project, error)) continue;
        std::map<int64_t, int> seen;  // a slow index: in how many runs
        std::vector<double> least(static_cast<size_t>(calls), 1e30);  // each callback's fastest run
        for (int run = 0; run < runs; ++run) {
            Engine e(kRate);
            e.setShedding(false);
            if (pool) e.useBenchmarkMixPool();
            else e.setMixParallel(Engine::MixParallel::Never);
            e.setProject(project);
            for (int c = 0; c < kRate / 4 / frames; ++c) e.process(l.data(), r.data(), frames);
            e.play();
            const double budget = 1e6 * frames / kRate;
            for (int c = 0; c < static_cast<int>(1.7 * kRate / frames); ++c) {
                const auto t0 = Clock::now();
                e.process(l.data(), r.data(), frames);
                e.reportLoad(std::chrono::duration<double, std::micro>(Clock::now() - t0).count() / budget, frames, frames);
            }
            std::vector<double> us(static_cast<size_t>(calls));
            const int64_t costEvery = std::max<int64_t>(1, kRate / 4 / frames);  // the device header's 4 reads a second
            for (int64_t c = 0; c < calls; ++c) {
                if (cost && c % costEvery == 0) {  // --cost: every slot's cost read, as headers on every device would
                    double share = 0;
                    uint32_t latency = 0;
                    bool armed = false;
                    for (const LayerSpec& layer : project.layers) {
                        if (!layer.instrument.id.empty()) e.componentCost(layer.id, Engine::kInstrumentIndex, share, latency, armed);
                        for (uint32_t k = 0; k < layer.components.size(); ++k) e.componentCost(layer.id, k, share, latency, armed);
                    }
                }
                const auto t0 = Clock::now();
                e.process(l.data(), r.data(), frames);
                us[static_cast<size_t>(c)] = std::chrono::duration<double, std::micro>(Clock::now() - t0).count();
                e.reportLoad(us[static_cast<size_t>(c)] / budget, frames, frames);
                least[static_cast<size_t>(c)] = std::min(least[static_cast<size_t>(c)], us[static_cast<size_t>(c)]);
            }
            std::vector<int64_t> order(us.size());
            for (size_t i = 0; i < order.size(); ++i) order[i] = static_cast<int64_t>(i);
            std::sort(order.begin(), order.end(), [&](int64_t a, int64_t b) { return us[static_cast<size_t>(a)] > us[static_cast<size_t>(b)]; });
            std::vector<double> sorted = us;
            std::sort(sorted.begin(), sorted.end());
            const auto pct = [&](double q) { return sorted[std::min(sorted.size() - 1, static_cast<size_t>(q * static_cast<double>(sorted.size())))]; };
            std::printf("%-18s %3d %8.1f %8.1f %8.1f ", sc.id, run, pct(0.5), pct(0.99), sorted.back());
            for (size_t k = 0; k < 5 && k < order.size(); ++k) {
                std::printf(" %lld:%.0f", static_cast<long long>(order[k]), us[static_cast<size_t>(order[k])]);
                ++seen[order[k]];
            }
            std::printf("\n");
        }
        std::string again;
        for (const auto& [index, n] : seen)
            if (n == runs && runs > 1) again += " " + std::to_string(index);
        std::printf("%-18s     in every run's slowest 5:%s\n", sc.id, again.empty() ? " none" : again.c_str());
        // The work in each callback: its fastest of the runs (a preemption or an interrupt lands on a different
        // callback in each run, so the least time drops it; work in the code is there every run). --check: the
        // slowest callback's work within RATIO of the median's, or within 100 µs of it (the lightest scenarios).
        std::vector<double> sorted = least;
        std::sort(sorted.begin(), sorted.end());
        const double median = sorted[sorted.size() / 2], worst = sorted.back();
        const auto at = std::max_element(least.begin(), least.end()) - least.begin();
        const bool bad = check > 0 && runs > 1 && worst > check * median && worst - median > 100.0;
        failed += bad ? 1 : 0;
        std::printf("%-18s     work: median %.1f us, slowest %.1f us at %lld (%.2f x)%s\n", sc.id, median, worst,
                    static_cast<long long>(at), worst / median, bad ? "  OVER" : "");
    }
    if (failed > 0) std::printf("%d scenarios have a callback whose work is over %.1f x the median's\n", failed, check);
    return failed > 0 ? 1 : 0;
}

}  // namespace

int main(int argc, char** argv) {
    const double secs = argc > 1 ? std::atof(argv[1]) : 10.0;
    // `caw_bench SECONDS N` plays only playback scenario N (1-5), for exact instruction counts under callgrind;
    // N = 100 plays First loop (the app's starter project on the built-in instruments) and each built-in alone
    // (`caw_bench SECONDS 100 K`: only the K-th of those, from 0); N = 200 times the flagship synth's voices; N = 300
    // times each built-in effect.
    const int only = argc > 2 ? std::atoi(argv[2]) : 0;
    if (only >= 300 && only <= 310) {  // the cost modes: each device is timed against the reference (reference_cost.h)
        double ref = 1e30;
        for (int run = 0; run < bench::kRuns; ++run) ref = std::min(ref, bench::referenceUs(secs));
        std::printf("reference workload: %.0f µs/s now in a long run (1640 on the calibration box); the costs below "
                    "are relative to it, in that box's µs/s\n", ref);
    }
    if (only == 308) return samplerCost(secs) ? 1 : 0;  // `caw_bench SECONDS 308`: only the sampler's zones (a CI test)
    if (only == 322) return flockCost(secs) ? 1 : 0;  // `caw_bench SECONDS 322`: only Flock (a CI test)
    if (only == 307) return packCost(secs) ? 1 : 0;  // `caw_bench SECONDS 307`: only the AutoStacc beta pack (a CI test)
    if (only == 310) return cleanCost(secs) ? 1 : 0;  // `caw_bench SECONDS 310`: only Preen and Hush (a CI test)
    if (only == 301) return toolsCost(secs) ? 1 : 0;  // `caw_bench SECONDS 301`: only 1.1.0's tools (a CI test)
    if (only == 500) return runSuite(secs, argc, argv);  // `caw_bench SECONDS 500 [options]`: the CI suite (runSuite)
    if (only == 600) return runLong(secs, argc, argv);  // `caw_bench SECONDS 600 [options]`: a long run (runLong)
    if (only == 601) return runDrift(secs, argc, argv);  // `caw_bench SECONDS 601 [options]`: per-track drift (runDrift)
    if (only == 602) return runSpikes(secs, argc, argv);  // `caw_bench SECONDS 602 [options]`: the one-off slow callbacks (runSpikes)
    std::printf("callback %d frames at %d Hz (budget %.0f us); %.0f s per scenario\n", kCallback, kRate,
                1e6 * kCallback / kRate, secs);
    {
        Engine e(kRate);
        e.setProject(firstLoop());
        report("stopped (first loop)", play(e, secs));
    }
    struct Case {
        const char* name;
        ProjectSpec p;
    };
    std::vector<Case> cases = {{"1 track (bass)", firstLoop("Bass")},
                               {"first loop (6 tracks)", firstLoop()},
                               {"16 tracks", manyTracks(16)},
                               {"64 tracks", manyTracks(64)},
                               {"first loop + delay + reverb each", withSpace()}};
    if (only == 400 || only == 401) {  // the song scenarios: timed (400) or profiled per component (401)
        const int k = argc > 3 ? std::atoi(argv[3]) : 1;
        if (only == 401) {
            profileSong(k, secs);
            return 0;
        }
        const std::string dir = (std::filesystem::temp_directory_path() / "caw_bench_song").string();
        std::filesystem::create_directories(dir);
        Engine e(kRate);
        if (const char* q = std::getenv("CAW_BENCH_QUALITY")) e.setQuality(std::atoi(q));
        e.setProject(songScenario(k, dir));
        e.play();
        report(scenarioName(k), play(e, secs));
        return 0;
    }
    if (only == 306) return larkCost(secs) ? 1 : 0;  // `caw_bench SECONDS 306`: only Lark (a CI test)
    if (only == 320) return ravenCost(secs) ? 1 : 0;  // `caw_bench SECONDS 320`: only Flagship's 1.1.0 modes (a CI test)
    if (only == 323) return rookCost(secs) ? 1 : 0;  // `caw_bench SECONDS 323`: only the drums' 1.1.0 additions (a CI test)
    if (only == 303) return voiceCost(secs) ? 1 : 0;  // `caw_bench SECONDS 303`: only 1.1.0's voice devices (a CI test)
    if (only == 302) return dynsplitCost(secs) ? 1 : 0;  // `caw_bench SECONDS 302`: only 1.1.0's dynamics split (a CI test)
    if (only == 300) {  // `caw_bench SECONDS 300`: each built-in effect's cost (exit 1 when one is over its ceiling)
        const bool suiteOver = !effectsCost(secs);  // the suite's ceilings, the EQ's and Filter's 1.1.0 modes among them
        const bool modesOver = modesCostOver(secs);  // a 1.1.0 mode over its ceiling fails the run
        const bool toolsOver = toolsCost(secs) != 0;  // so do 1.1.0's tools (bench/tools_cost.cpp)
        const bool dynsplitOver = dynsplitCost(secs) != 0;  // and the dynamics variants (bench/dynsplit_cost.cpp)
        const bool voiceOver = voiceCost(secs) != 0;  // and the voice devices (bench/voice_cost.cpp)
        const bool cleanOver = cleanCost(secs) != 0;  // and Preen and Hush (bench/clean_cost.cpp)
        const bool packOver = packCost(secs) != 0;  // and the AutoStacc beta pack (bench/pack_cost.cpp)
        const bool larkOver = larkCost(secs) != 0;  // and Lark (bench/lark_cost.cpp)
        const bool ravenOver = ravenCost(secs) != 0;  // and Flagship's 1.1.0 modes (bench/raven_cost.cpp)
        const bool samplerOver = samplerCost(secs) != 0;  // and the sampler's zones (bench/sampler_cost.cpp)
        const bool rookOver = rookCost(secs) != 0;  // and the drums' 1.1.0 additions (bench/rook_cost.cpp)
        const bool flockOver = flockCost(secs) != 0;  // and Flock (bench/flock_cost.cpp)
        return (suiteOver || modesOver || toolsOver || dynsplitOver || voiceOver || cleanOver || packOver || larkOver || ravenOver || samplerOver || rookOver || flockOver) ? 1 : 0;
    }
    if (only == 200) {  // `caw_bench SECONDS 200`: the flagship synth's cost per voice and per unison copy
        flagshipVoiceCost(secs);
        return 0;
    }
    if (only < 0) {  // `caw_bench SECONDS -1`: graph executor scenarios only
        graphStereoBench(secs);
        graphPlanarBench(secs);
        return 0;
    }
    if (only == 100 || only == 0) {  // `caw_bench SECONDS 100`: First loop, its tracks and each built-in alone
        std::vector<Case> native = {
            {"first loop (6 tracks, all unmuted)", firstLoop()},
            {"  track Kick", firstLoop("Kick")},
            {"  track Hats", firstLoop("Hats")},
            {"  track Bass", firstLoop("Bass")},
            {"  track Lead (morph x3 + delay)", firstLoop("Lead")},
            {"  track Acid (+ distortion)", firstLoop("Acid")},
            {"  track Pad (morph x7 + chorus)", firstLoop("Pad")},
            {"idle track (instrument, no notes)", busy("org.caw.drum.kick", {}, {}, false)},
            {"busy kick", busy("org.caw.drum.kick", {})},
            {"busy snare", busy("org.caw.drum.snare", {})},
            {"busy hats", busy("org.caw.drum.hats", {})},
            {"busy kit", busy("org.caw.drum.kit", {})},
            {"busy bass", busy("org.caw.bass", {})},
            {"busy acid", busy("org.caw.synth.acid", {})},
            {"busy morph (unison 7)", busy("org.caw.synth.morph", {})},
            {"busy morph (unison 1)", busy("org.caw.synth.morph", {{"unison", 1}})},
            {"busy morph (unison 16)", busy("org.caw.synth.morph", {{"unison", 16}})},
            {"busy basic synth", busy("org.caw.synth.basic", {})},
            {"busy morph x1 + chorus", busy("org.caw.synth.morph", {{"unison", 1}}, {component("org.caw.chorus")})},
            {"busy morph x1 + ping-pong", busy("org.caw.synth.morph", {{"unison", 1}}, {component("org.caw.delay.pingpong")})},
            {"busy morph x1 + distortion", busy("org.caw.synth.morph", {{"unison", 1}}, {component("org.caw.distortion")})},
            {"busy flagship (default: x7, ladder, reverb)", busy("org.caw.synth.flagship", {})},
            {"busy flagship x1, no filter, no fx", busy("org.caw.synth.flagship", {{"osc1_unison", 1}, {"flt1_on", 0}, {"fx_reverb_on", 0}})},
            {"busy flagship x7, no filter, no fx", busy("org.caw.synth.flagship", {{"flt1_on", 0}, {"fx_reverb_on", 0}})},
            {"busy flagship x16, no filter, no fx", busy("org.caw.synth.flagship", {{"osc1_unison", 16}, {"flt1_on", 0}, {"fx_reverb_on", 0}})},
            {"busy flagship x7, ladder, no fx", busy("org.caw.synth.flagship", {{"fx_reverb_on", 0}})},
            {"busy flagship 3 osc x16, 2 filters, all fx",
             busy("org.caw.synth.flagship", {{"osc1_unison", 16}, {"osc2_on", 1}, {"osc2_unison", 16}, {"osc3_on", 1}, {"osc3_unison", 16},
                                             {"osc2_frame", 0.5}, {"flt2_on", 1}, {"fx_dist_on", 1}, {"fx_eq_on", 1}, {"fx_chorus_on", 1},
                                             {"fx_delay_on", 1}, {"mod2_src", 4}, {"mod2_dst", 3}, {"mod2_amt", 0.3}})},
        };
        const int pick = only == 100 && argc > 3 ? std::atoi(argv[3]) : -1;  // `caw_bench S 100 K`: case K only
        for (size_t k = 0; k < native.size(); ++k) {
            if (pick >= 0 && static_cast<size_t>(pick) != k) continue;
            Case& c = native[k];
            Engine e(kRate);
            // CAW_BENCH_QUALITY=0|1|2: the quality setting (Eco, Normal, High) to measure at.
            if (const char* q = std::getenv("CAW_BENCH_QUALITY")) e.setQuality(std::atoi(q));
            e.setProject(c.p);
            e.play();
            report(c.name, play(e, secs));
        }
        if (only == 100) return 0;
    }
    if (only > 0) {
        Case& c = cases[static_cast<size_t>(std::min<int>(only, static_cast<int>(cases.size())) - 1)];
        Engine e(kRate);
        e.setProject(c.p);
        e.play();
        report(c.name, play(e, secs));
        return 0;
    }
    for (Case& c : cases) {
        Engine e(kRate);
        const auto t0 = Clock::now();
        e.setProject(c.p);
        const double setMs = ms(t0);
        e.play();
        Result r = play(e, secs);
        report(c.name, r);
        std::printf("%-34s setProject %.1f ms\n", "", setMs);
    }
    {
        // Live editing: a pattern edit every quarter second while 16 tracks play; parsing is control-thread.
        Engine e(kRate);
        ProjectSpec p = manyTracks(16);
        const std::string bass = p.modules[2].source;
        e.setProject(p);
        e.play();
        double editMs = 0;
        int edits = 0;
        Result r = play(e, secs, [&](int c) {
            if (c % 62 != 0) return;
            p.modules[2].source = bass + (edits % 2 ? "" : "13 E2 1/2 0.8\n");
            const auto t0 = Clock::now();
            e.setProject(p);
            editMs += ms(t0);
            ++edits;
        });
        report("16 tracks, pattern edit every 0.25 s", r);
        std::printf("%-34s %d edits, setProject mean %.2f ms\n", "", edits, editMs / edits);
    }
    {
        // The cost of a project re-sent unchanged.
        Engine e(kRate);
        ProjectSpec p = manyTracks(16);
        e.setProject(p);
        const auto t0 = Clock::now();
        for (int i = 0; i < 20; ++i) e.setProject(p);
        std::printf("setProject unchanged (16 tracks)  %.3f ms\n", ms(t0) / 20);
    }
    {
        // Offline export speed, and memory with many layers.
        ProjectSpec p = manyTracks(16);
        ExportOptions o;
        RenderResult out;
        const auto t0 = Clock::now();
        renderExport(p, o, out);
        const double took = ms(t0);
        const double audio = 2.0 * out.frames / static_cast<double>(out.sampleRate);  // loop export renders 2 loops
        std::printf("loop export 16 tracks: %.0f ms for %.2f s of audio (%.0fx real time)\n", took, audio,
                    audio * 1000.0 / took);
        const long before = rssKb();
        Engine e(kRate);
        e.setProject(manyTracks(64));
        std::printf("RSS: %ld kB before, %ld kB with 64 tracks set up\n", before, rssKb());
    }
    graphStereoBench(secs);
    graphPlanarBench(secs);
    return 0;
}
