// org.caw.drums' settings audit (every parameter, moved, changes the sound or behaviour its name says, at every quality; its
// needs are honest), and the 1.1.0 layers, groove and echo: timing, determinism, block sizes, ending quiet.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "builtin_drums_layout.h"
#include "caw/instrument.hpp"
#include "component_samples.h"
#include "engine.h"
#include "quality.h"
#include "test.h"

using namespace caw;
using namespace caw::drums;

namespace {

using Values = std::vector<std::pair<std::string, double>>;

std::unique_ptr<ModuleProcessor> makeAt(int quality) {
    static Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent("org.caw.drums");
    CHECK(p != nullptr);
    if (!p) return p;
    static std::atomic<int> qualities[3] = {kQualityEco, kQualityNormal, kQualityHigh};
    const BuildingQuality building(&qualities[quality]);
    CHECK(p->activate(48000, 64));
    return p;
}

// A decaying 300 Hz tone with some noise: pad A1's sample in the sample layer's probes.
std::unique_ptr<SampleBuffer> testSample() {
    auto b = std::make_unique<SampleBuffer>();
    b->source = "test";
    uint32_t x = 12345;
    for (int i = 0; i < 24000; ++i) {
        x = x * 1664525u + 1013904223u;
        const double n = static_cast<double>(x >> 8) / 8388608.0 - 1.0;
        b->data.push_back(static_cast<float>((0.6 * std::sin(6.283185307 * 300.0 * i / 48000.0) + 0.3 * n) *
                                             std::exp(-i / 6000.0)));
    }
    return b;
}

// Plays `events` (stereo, interleaved) with the values over the descriptor's defaults, in blocks of 64.
std::vector<float> render(int quality, const Values& values, const std::vector<Event>& events, uint32_t frames,
                          bool sample, bool playing, uint32_t kBlock = 64, bool* quietAtEnd = nullptr) {
    std::unique_ptr<ModuleProcessor> p = makeAt(quality);
    if (!p) return {};
    if (sample) {
        auto* slots = dynamic_cast<SampleSlots*>(p.get());
        CHECK(slots != nullptr);
        if (slots) slots->setSample(0, testSample());
    }
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    for (const auto& [id, v] : values) {
        const int k = parameterIndex(id);
        if (k < 0) cawtest::fail(__FILE__, __LINE__, "no parameter " + id);
        else params[static_cast<size_t>(k)].value = v;
    }
    std::vector<float> out, l(kBlock), r(kBlock);
    float* channels[2] = {l.data(), r.data()};
    const ChannelBufferView audio{channels, 2, kBlock};
    Transport transport;
    transport.playing = true;
    size_t next = 0;
    for (uint32_t start = 0; start < frames; start += kBlock) {
        std::vector<Event> in;
        while (next < events.size() && events[next].frame < start + kBlock) {
            Event e = events[next++];
            e.frame -= start;
            in.push_back(e);
        }
        const EventInput ev{in.data(), static_cast<uint32_t>(in.size())};
        transport.tempo = 240;
        transport.beat = start / 12000.0;  // 240 BPM at 48 kHz: a 16th is 3000 frames
        ProcessBlock b;
        b.frames = std::min(kBlock, frames - start);
        b.audioOut = &audio;
        b.audioOutCount = 1;
        b.eventIn = &ev;
        b.eventInCount = 1;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        b.transport = playing ? &transport : nullptr;
        CHECK(p->processPorts(b));
        for (uint32_t i = 0; i < b.frames; ++i) out.push_back(l[i]), out.push_back(r[i]);
    }
    if (quietAtEnd) *quietAtEnd = p->quiet();
    return out;
}

// How far two renders are apart, relative to the louder one (L1).
double apart(const std::vector<float>& a, const std::vector<float>& b) {
    double d = 0, s = 0;
    for (size_t i = 0; i < a.size() && i < b.size(); ++i) {
        d += std::fabs(static_cast<double>(a[i]) - b[i]);
        s += std::max(std::fabs(a[i]), std::fabs(b[i]));
    }
    return s > 0 ? d / s : 0.0;
}

// One probe: the context a parameter is heard in (other values and notes), and the values it is moved to.
struct Probe {
    Values base;
    std::vector<Event> events;
    uint32_t frames = 19200;
    bool sample = false, playing = false;
};

Values single(Values more) {
    Values out = {{"mode", kModeSingle}};
    const Voice& n = neutralVoice();
    for (uint32_t k = 0; k < kPadParams; ++k) out.emplace_back("a1_" + std::string(padParamSuffix(k)), n[k]);
    for (auto& m : more) out.push_back(m);
    return out;
}

const std::vector<Event> kOneHit = {notes::noteOn(0, 1, 60, 0.7)};

// Where pad parameter `suffix` (of layer `layer`) is heard.
Probe probeFor(const std::string& suffix, const std::string& layer) {
    Probe p;
    p.events = kOneHit;
    const Values tone = {{"a1_body_on", 1}, {"a1_noise_on", 1}, {"a1_click_on", 1}};
    auto with = [](Values a, const Values& b) {
        for (auto& x : b) a.push_back(x);
        return a;
    };
    if (layer == "body") p.base = single({{"a1_body_on", 1}, {"a1_body_p2_level", 0.5}, {"a1_body_hold", 0.02}});
    else if (layer == "penv") p.base = single({{"a1_body_on", 1}, {"a1_penv_mode", kPenvPoints}, {"a1_penv_p3", 6}});
    else if (layer == "sub") p.base = single({{"a1_sub_on", 1}, {"a1_body_on", 1}, {"a1_body_level", -12}, {"a1_sub_hold", 0.02}});
    else if (layer == "click") p.base = single({{"a1_click_on", 1}});
    else if (layer == "noise") p.base = single({{"a1_noise_on", 1}, {"a1_noise_filter", kFilterBp}});
    else if (layer == "metal") p.base = single({{"a1_metal_on", 1}, {"a1_metal_band", 0.5}, {"a1_metal_noise", 0.2}});
    else if (layer == "res") p.base = single({{"a1_res_on", 1}, {"a1_body_on", 1}, {"a1_body_level", -60}});
    else if (layer == "smp") p.base = single({{"a1_smp_on", 1}}), p.sample = true;
    else if (layer == "drive") p.base = single(with(tone, {{"a1_drive_type", kDriveSoft}, {"a1_drive", 6}}));
    else if (layer == "filter") p.base = single(with(tone, {{"a1_flt", kVfLp12}, {"a1_cutoff", 1500}, {"a1_flt_env", 2}}));
    else if (layer == "eq") p.base = single(with(tone, {{"a1_eq_low", 9}, {"a1_eq_mid", 9}, {"a1_eq_high", 9}}));
    else if (layer == "dyn") p.base = single(with(tone, {{"a1_comp", 0.8}, {"a1_clip", kClipSoft}, {"a1_clip_gain", 6}}));
    else if (layer == "space") p.base = single(with(tone, {{"a1_width", 0.8}, {"room", 1}}));
    else if (layer == "macro") p.base = single(with(tone, {{"a1_sub_on", 1}, {"a1_flt", kVfLp12}, {"a1_metal_on", 1}, {"a1_res_on", 1}}));
    else if (layer == "var") p.base = single(with(tone, {{"a1_res_on", 1}, {"a1_flt", kVfLp12}, {"a1_cutoff", 3000}}));
    else if (layer == "press") {
        p.base = single(with(tone, {{"a1_drive_type", kDriveSoft}, {"a1_flt", kVfLp12}, {"a1_cutoff", 3000},
                                    {"a1_body_decay", 1}, {"a1_noise_decay", 1}}));
        p.events.push_back(notes::notePressure(2400, 1, 60, 0.9));
    } else if (layer == "fm") p.base = single({{"a1_fm_on", 1}, {"a1_fm_pitch", 12}});
    else if (layer == "phys") p.base = single({{"a1_phys_on", 1}, {"a1_click_on", 1}});
    else if (layer == "tex") p.base = single({{"a1_tex_on", 1}});
    else if (layer == "fx") p.base = single(with(tone, {{"a1_ring_mix", 0.5}, {"echo", 1}, {"glue", 1}, {"glue_threshold", -30},
                                                         {"kit_drive_type", 3}, {"kit_drive", 6}}));
    else if (layer == "groove") {
        // On the grid of a playing transport (a 16th is 3000 frames), every 16th of a beat and a half.
        p.base = single(with(tone, {{"a1_swing", 0.5}, {"a1_accent", 0.6}, {"a1_flam", 0.5}, {"a1_groove", kGrooveShuffle},
                                    {"a1_body_decay", 0.05}, {"a1_noise_decay", 0.05}}));
        p.events.clear();
        for (uint32_t k = 0; k < 6; ++k) p.events.push_back(notes::noteOn(k * 3000, k + 1, 60, k == 3 ? 0.9 : 0.7));
        p.playing = true;
    } else p.base = single(with(tone, {{"a1_body_decay", 1}}));
    // The parameters only heard with a partner, a mode or a note pattern.
    if (suffix == "body_ptime" || suffix == "body_pcurve") p.base.push_back({"a1_body_pitch", 36});
    if (suffix == "noise_bursts" || suffix == "noise_spacing") p.base.push_back({"a1_noise_mode", kNoiseClap});
    if (suffix == "metal_fm") p.base.push_back({"a1_metal_mode", kMetalFmPairs});
    if (suffix == "res_input") p.base.push_back({"a1_body_level", 0}), p.base.push_back({"a1_res_exciter", kExciteLayers});
    if (suffix == "sub_route") p.base.push_back({"a1_drive_type", kDriveHard}), p.base.push_back({"a1_drive", 8});
    if (suffix == "sub_lp") p.base.push_back({"a1_sub_wave", kSubTriangle});
    if (suffix == "drive_pos") p.base.push_back({"a1_flt", kVfLp12}), p.base.push_back({"a1_cutoff", 1200});
    if (suffix == "dirt") p.base.push_back({"a1_drive_type", kDriveSoft});
    if (suffix == "vel_click") p.base = single({{"a1_click_on", 1}, {"a1_click_length", 0.03}});
    if (suffix == "flt_res") p.base.push_back({"a1_flt_env", 0});
    if (suffix == "comp_attack" || suffix == "comp_release") p.base.push_back({"a1_comp", 1});
    if (suffix == "smp_decay") p.frames = 24000;
    if (suffix == "smp_ptime") p.base.push_back({"a1_smp_pitch", 12});
    if (suffix == "tex_density") p.base.push_back({"a1_tex_mode", kTexDust});
    if (suffix == "phys_input") p.base.push_back({"a1_phys_exciter", kPhysLayers});
    if (suffix == "accent_on") p.base.push_back({"a1_accent", 1});
    if (suffix == "release") p.base.push_back({"a1_trig", kGate}), p.events.push_back(notes::noteOff(2400, 1, 60));
    if (suffix == "trig") p.events.push_back(notes::noteOff(2400, 1, 60));
    if (suffix == "root" || suffix == "glide" || suffix == "mono") p.base.push_back({"a1_track", 1});
    if (suffix == "track" || suffix == "root") p.events = {notes::noteOn(0, 1, 72, 0.7)};
    if (suffix == "glide") p.base.push_back({"a1_mono", 1});
    if (suffix == "mono" || suffix == "glide")
        p.events = {notes::noteOn(0, 1, 60, 0.7), notes::noteOn(4800, 2, 67, 0.7)};
    if (suffix == "poly") p.events = {notes::noteOn(0, 1, 60, 0.7), notes::noteOn(2400, 2, 60, 0.7), notes::noteOn(4800, 3, 60, 0.7)};
    if (suffix == "out") p.base.push_back({"room", 1}), p.base.push_back({"glue", 1});
    if (suffix == "press_choke") p.events.back() = notes::notePressure(2400, 1, 60, 1.0);
    if (layer == "var" && suffix.rfind("rnd_", 0) == 0) p.base.push_back({"a1_vel_tone", 0});
    if (suffix == "rnd_pos") p.base.push_back({"a1_body_on", 0}), p.base.push_back({"a1_noise_on", 0}), p.base.push_back({"a1_click_on", 0});
    // Kit mode: the note map, the channel and the choke group (pad A2 rings, A1 hit after it).
    if (suffix == "note" || suffix == "chan") {
        p.base = {{"mode", kModeKit}};
        p.events = {notes::noteOn(0, 1, 37, 0.7), notes::noteOn(4800, 2, 36, 0.7), notes::noteOn(9600, 3, 60, 0.7)};
    }
    if (suffix == "choke") {  // the open hat (A11) rings, then A1 is hit
        p.base = {{"mode", kModeKit}, {"a11_choke", 1}};
        p.events = {notes::noteOn(0, 1, 46, 0.7), notes::noteOn(4800, 2, 36, 0.7)};
    }
    return p;
}

// The probe again in the layer's other modes (a number must work in each), as extra values on its context.
std::vector<Probe> probesFor(const std::string& suffix, const std::string& layer, bool choice) {
    std::vector<Probe> out = {probeFor(suffix, layer)};
    if (choice) return out;
    std::vector<Values> modes;
    if (layer == "noise" && suffix != "noise_bursts" && suffix != "noise_spacing") modes = {{{"a1_noise_mode", kNoiseClap}}};
    if (layer == "metal" && suffix != "metal_fm") modes = {{{"a1_metal_mode", kMetalFmPairs}}, {{"a1_metal_mode", kMetalRing}}};
    if (layer == "res") modes = {{{"a1_res_model", 2}}, {{"a1_res_model", 5}}};
    if (layer == "body") modes = {{{"a1_body_wave", kWaveSaw}}};
    if (layer == "fm") modes = {{{"a1_fm_feedback", 0.7}}};
    if (layer == "phys" && suffix != "phys_input") modes = {{{"a1_phys_model", kPhysPipe}}, {{"a1_phys_model", kPhysStiff}}, {{"a1_phys_exciter", kPhysNoise}}};
    if (layer == "tex" && suffix != "tex_density" && suffix != "tex_spread" && suffix != "tex_tilt")
        modes = {{{"a1_tex_mode", kTexDust}}, {{"a1_tex_mode", kTexCrackle}}};
    if (layer == "filter") modes = {{{"a1_flt", kVfHp}}, {{"a1_flt", kVfBp}}};
    for (const Values& m : modes) {
        Probe p = out.front();
        for (auto& x : m) p.base.push_back(x);
        out.push_back(p);
    }
    return out;
}

// The values a parameter is moved to: every choice; a number's ends (each away from the default).
std::vector<double> movesFor(const ParameterDescriptor& d) {
    std::vector<double> v;
    const std::string id(d.id);
    // Routing choices: one move that must be heard (their other options route elsewhere alike).
    if (id == "a1_note") return {static_cast<double>(kNoteOff), static_cast<double>(kNoteFirst + 60)};
    if (id == "a1_chan") return {4};
    if (id == "a1_choke") return {1};
    if (id == "a1_out") return {1};
    if (d.choiceCount > 0) {
        for (uint32_t c = 0; c < d.choiceCount; ++c) v.push_back(c);
        return v;
    }
    const double span = d.maximum - d.minimum;
    for (double x : {d.minimum, d.maximum, d.minimum + 0.3 * span}) {
        if (d.step > 0) x = std::round(x);
        if (id == "a1_body_phase" && x == d.maximum) continue;  // a cycle: 1 is 0
        if (std::fabs(x - d.defaultValue) > 0.05 * span) v.push_back(x);
    }
    return v;
}

// Settings that by design change no sound: display or metadata.
bool silentByDesign(const std::string& id) {
    return id == "a1_type" || id == "view_pad";
}

bool routing(const std::string& suffix) { return suffix == "note" || suffix == "chan" || suffix == "choke" || suffix == "out"; }

}  // namespace

TEST(drums_audit_every_pad_setting_changes_the_sound) {
    int failures = 0;
    for (uint32_t k = 0; k < kPadParams; ++k) {
        const ParameterDescriptor& d = padParamDescriptor(0, k);
        const std::string id(d.id), suffix(padParamSuffix(k));
        if (silentByDesign(id)) continue;
        const std::string layer(d.group.substr(d.group.find('/') + 1));
        const std::vector<double> moves = movesFor(d);
        for (const Probe& probe : probesFor(suffix, layer, d.choiceCount > 0))
        for (int q = 0; q < 3; ++q) {
            // The value in context, then each move; a choice's options must also differ from one another.
            double was = d.defaultValue;
            for (auto& [i, x] : probe.base)
                if (i == id) was = x;
            std::vector<std::vector<float>> outs;
            std::vector<double> at;
            Values base = probe.base;
            base.push_back({id, was});
            outs.push_back(render(q, base, probe.events, probe.frames, probe.sample, probe.playing));
            at.push_back(was);
            for (double m : moves) {
                if (m == was) continue;
                Values moved = probe.base;
                moved.push_back({id, m});
                outs.push_back(render(q, moved, probe.events, probe.frames, probe.sample, probe.playing));
                at.push_back(m);
            }
            for (size_t a = 0; a < outs.size(); ++a)
                for (size_t b = a + 1; b < outs.size(); ++b) {
                    if ((d.choiceCount == 0 || routing(suffix)) && a > 0) continue;  // each move against the base
                    const double x = apart(outs[a], outs[b]);
                    if (x < 2e-3) {
                        char msg[200];
                        std::snprintf(msg, sizeof msg, "%s at %g and %g sound the same (quality %d, %.2g apart)", id.c_str(),
                                      at[a], at[b], q, x);
                        if (++failures <= 60) cawtest::fail(__FILE__, __LINE__, msg);
                    }
                }
        }
    }
    if (failures) std::printf("audit: %d pad settings changed nothing\n", failures);
}

TEST(drums_audit_every_kit_setting_changes_the_sound) {
    // The kit's own settings, heard on a busy two-pad pattern through the kit effects.
    const Values base = {{"mode", kModeKit}, {"glue", 0.5}, {"kit_drive_type", 1}, {"room", 0.5}, {"kit_low", 3},
                         {"kit_clip", kClipSoft}, {"kit_clip_gain", 6}, {"glue_threshold", -24}, {"a1_rnd_pitch", 80},
                         {"a1_rnd_level", 1}, {"kit_high", 3}, {"echo", 0.5}, {"a1_echo_send", 1}, {"a3_echo_send", 1},
                         {"echo_sync", kEcho16}};
    const std::vector<Event> events = {notes::noteOn(0, 1, 36, 1), notes::noteOn(0, 2, 42, 0.8), notes::noteOn(6000, 3, 38, 0.9),
                                       notes::noteOn(12000, 4, 36, 0.6, 2)};
    int failures = 0;
    for (uint32_t k = 0; k < kGlobalCount; ++k) {
        const ParameterDescriptor& d = parameterTable()[k];
        const std::string id(d.id);
        if (silentByDesign(id)) continue;
        for (int q = 0; q < 3; ++q) {
            double was = d.defaultValue;
            for (auto& [i, x] : base)
                if (i == id) was = x;
            Values b = base;
            if (id == "echo_time") b.push_back({"echo_sync", kEchoFree});
            const Values context = b;
            b.push_back({id, was});
            const std::vector<float> ref = render(q, b, events, 36000, false, false);
            for (double m : movesFor(d)) {
                if (m == was) continue;
                Values moved = context;
                moved.push_back({id, m});
                const double x = apart(ref, render(q, moved, events, 36000, false, false));
                if (x < 2e-3) {
                    char msg[200];
                    std::snprintf(msg, sizeof msg, "%s at %g sounds as at %g (quality %d)", id.c_str(), m, was, q);
                    if (++failures <= 40) cawtest::fail(__FILE__, __LINE__, msg);
                }
            }
        }
    }
}

TEST(drums_audit_needs_say_when_a_setting_is_heard) {
    // Each "needs" rule (what the app dims a setting by) is honest: with a condition failing, moving the setting
    // changes nothing at all; with them all holding, the audit above already hears it.
    int checked = 0;
    for (const NeedRule& r : needs()) {
        if (r.global) continue;  // the kit's: checked below on the kit's probe
        const ParameterDescriptor& d = padParamDescriptor(0, r.param);
        const std::string id(d.id), suffix(padParamSuffix(r.param));
        const std::string layer(d.group.substr(d.group.find('/') + 1));
        const Probe probe = probeFor(suffix, layer);
        for (const Need& n : r.all) {
            const ParameterDescriptor& nd = n.global ? parameterTable()[n.param] : padParamDescriptor(0, n.param);
            double off = 0.0;
            if (!n.in.empty())
                for (uint32_t c = 0; c < nd.choiceCount; ++c)
                    if (std::find(n.in.begin(), n.in.end(), static_cast<int>(c)) == n.in.end()) {
                        off = c;
                        break;
                    }
            Values base = probe.base;
            base.push_back({std::string(nd.id), off});
            const std::vector<float> ref = render(kQualityNormal, base, probe.events, probe.frames, probe.sample, probe.playing);
            for (double m : movesFor(d)) {
                Values moved = base;
                moved.push_back({id, m});
                const double x = apart(ref, render(kQualityNormal, moved, probe.events, probe.frames, probe.sample, probe.playing));
                if (x > 1e-9) {
                    char msg[200];
                    std::snprintf(msg, sizeof msg, "%s at %g is heard with %s at %g, which its needs say silences it",
                                  id.c_str(), m, std::string(nd.id).c_str(), off);
                    cawtest::fail(__FILE__, __LINE__, msg);
                }
            }
            ++checked;
        }
    }
    CHECK(checked > 100);
}

namespace {
// The first frame (of the left side) louder than `floor` from frame `from` on.
size_t onset(const std::vector<float>& stereo, size_t from, float floor = 1e-3f) {
    for (size_t i = from; 2 * i < stereo.size(); ++i)
        if (std::fabs(stereo[2 * i]) > floor) return i;
    return ~size_t(0);
}
}  // namespace

TEST(drums_groove_moves_hits_by_the_grid_seeded_and_the_same_at_any_block_size) {
    const Values click = single({{"a1_click_on", 1}, {"a1_click_type", kClickImpulse}, {"a1_click_length", 0.002}});
    auto with = [](Values a, const Values& b) {
        for (auto& x : b) a.push_back(x);
        return a;
    };
    // Swing 1 on the 16ths: the off 16th (frame 3000 at 240 BPM) comes half a 16th (1500 frames) late; the on-beat
    // one stays.
    const std::vector<Event> two = {notes::noteOn(0, 1, 60, 0.8), notes::noteOn(3000, 2, 60, 0.8)};
    const std::vector<float> straight = render(kQualityNormal, click, two, 9000, false, true);
    const std::vector<float> swung = render(kQualityNormal, with(click, {{"a1_swing", 1}}), two, 9000, false, true);
    CHECK_EQ(onset(swung, 0), onset(straight, 0));
    CHECK_EQ(onset(swung, 1000), onset(straight, 1000) + 1500);
    // Without a playing transport (a preview) nothing moves.
    const std::vector<float> still = render(kQualityNormal, with(click, {{"a1_swing", 1}}), two, 9000, false, false);
    CHECK_EQ(onset(still, 1000), onset(straight, 1000));
    // A flam: a softer grace hit, then the hit flam_time (20 ms = 960 frames) later.
    const std::vector<float> flam = render(kQualityNormal, with(click, {{"a1_flam", 0.5}, {"a1_flam_time", 0.02}}),
                                           {notes::noteOn(0, 1, 60, 0.8)}, 4000, false, false);
    const size_t grace = onset(flam, 0), main = onset(flam, grace + 200);
    CHECK_EQ(grace, onset(straight, 0));
    CHECK_EQ(main, grace + 960);
    float gp = 0, mp = 0;
    for (size_t i = grace; i < grace + 200; ++i) gp = std::max(gp, std::fabs(flam[2 * i]));
    for (size_t i = main; i < main + 200; ++i) mp = std::max(mp, std::fabs(flam[2 * i]));
    CHECK(gp < mp);
    // Accent on loud hits: the same hit louder.
    const std::vector<Event> loud = {notes::noteOn(0, 1, 60, 0.9)};
    const std::vector<float> plain = render(kQualityNormal, click, loud, 2000, false, false);
    const std::vector<float> accented = render(kQualityNormal, with(click, {{"a1_accent", 1}, {"a1_accent_on", kAccentLoud}}),
                                               loud, 2000, false, false);
    float pp = 0, ap = 0;
    for (float x : plain) pp = std::max(pp, std::fabs(x));
    for (float x : accented) ap = std::max(ap, std::fabs(x));
    CHECK(ap > 1.5f * pp);
    // Humanize: seeded (the same render twice), a new seed moves it; every 16th of a bar on the grid.
    std::vector<Event> bar;
    for (uint32_t k = 0; k < 16; ++k) bar.push_back(notes::noteOn(k * 3000, k + 1, 60, 0.8));
    const Values human = with(click, {{"a1_humanize", 1}});
    const std::vector<float> h1 = render(kQualityNormal, human, bar, 48000, false, true);
    CHECK(h1 == render(kQualityNormal, human, bar, 48000, false, true));
    CHECK(h1 != render(kQualityNormal, with(human, {{"seed", 9}}), bar, 48000, false, true));
    // Everything 1.1.0 adds at once renders the same at any block size and ends quiet.
    const Values all = single({{"a1_fm_on", 1}, {"a1_phys_on", 1}, {"a1_tex_on", 1}, {"a1_tex_mode", kTexCrackle},
                               {"a1_ring_mix", 0.4}, {"a1_echo_send", 0.6}, {"echo", 0.6}, {"echo_feedback", 0.5},
                               {"a1_bus_send", 0.5}, {"glue", 1}, {"a1_swing", 0.7}, {"a1_humanize", 0.5}, {"a1_flam", 0.4},
                               {"a1_groove", kGrooveBroken}, {"a1_accent", 0.5}, {"a1_phys_decay", 0.3}, {"a1_fm_decay", 0.2},
                               {"a1_tex_decay", 0.2}, {"a1_body_on", 1}, {"a1_body_decay", 0.2}});
    bool quiet = false;
    const std::vector<float> ref = render(kQualityNormal, all, bar, 48000 * 6, false, true, 64, &quiet);
    CHECK(quiet);
    for (uint32_t block : {1u, 37u, 512u}) {
        if (render(kQualityNormal, all, bar, 48000 * 6, false, true, block) != ref)
            cawtest::fail(__FILE__, __LINE__, "the 1.1.0 layers render differently at block " + std::to_string(block));
    }
    double tail = 0;
    for (size_t i = ref.size() - 9600; i < ref.size(); ++i) tail += std::fabs(ref[i]);
    CHECK_EQ(tail, 0.0);
    // Non-finite knobs read as their ends, never as noise.
    const Values bad = with(all, {{"a1_fm_index", NAN}, {"a1_phys_freq", INFINITY}, {"a1_tex_freq", -INFINITY}, {"echo_time", NAN}});
    for (float x : render(kQualityNormal, bad, bar, 24000, false, true)) {
        if (!std::isfinite(x) || std::fabs(x) > 4.0f) {
            cawtest::fail(__FILE__, __LINE__, "a non-finite knob made a non-finite or huge sample");
            break;
        }
    }
}
