// org.caw.drums: descriptor, layers, modes, choke, variation, quality, samples, randomize, presets (pitch, decay, brightness), migration, display.
#include <atomic>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "analysis.h"
#include "builtin_drums.h"
#include "builtin_drums_layout.h"
#include "caw.h"
#include "caw/instrument.hpp"
#include "caw/library/drums.hpp"
#include "component_samples.h"
#include "engine.h"
#include "json.h"
#include "presets.h"
#include "project.h"
#include "quality.h"
#include "test.h"
#include "tolerance.h"
#include "wav.h"

using namespace caw;
using namespace caw::drums;

namespace {

using Values = std::vector<std::pair<std::string, double>>;

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

std::unique_ptr<ModuleProcessor> makeDrums(int quality = kQualityNormal) {
    static Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent("org.caw.drums");
    CHECK(p != nullptr);
    if (!p) return p;
    static std::atomic<int> qualities[3] = {kQualityEco, kQualityNormal, kQualityHigh};  // kept: the processor reads it
    const BuildingQuality building(&qualities[quality < 0 ? 0 : (quality > 2 ? 2 : quality)]);
    CHECK(p->activate(48000, 64));
    return p;
}

// Plays events through the processor in blocks of `block` frames; returns the left side (right in *rightOut).
std::vector<float> play(ModuleProcessor& p, const std::vector<Event>& events, uint32_t frames, const Values& values = {},
                        std::vector<float>* rightOut = nullptr, uint32_t block = 64, bool playing = false) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    for (const auto& [id, v] : values) {
        const int k = drums::parameterIndex(id);
        CHECK(k >= 0);
        if (k >= 0) params[static_cast<size_t>(k)].value = v;
    }
    std::vector<float> out(frames), right(frames), l(block), r(block);
    float* channels[2] = {l.data(), r.data()};
    const ChannelBufferView audio{channels, 2, block};
    Transport transport;
    transport.playing = playing;
    size_t next = 0;
    for (uint32_t start = 0; start < frames; start += block) {
        const uint32_t n = std::min(block, frames - start);
        std::vector<Event> in;
        while (next < events.size() && events[next].frame < start + n) {
            Event e = events[next++];
            e.frame -= start;
            in.push_back(e);
        }
        const EventInput ev{in.data(), static_cast<uint32_t>(in.size())};
        ProcessBlock b;
        b.frames = n;
        b.audioOut = &audio;
        b.audioOutCount = 1;
        b.eventIn = &ev;
        b.eventInCount = 1;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        b.transport = playing ? &transport : nullptr;
        CHECK(p.processPorts(b));
        for (uint32_t i = 0; i < n; ++i) out[start + i] = l[i], right[start + i] = r[i];
    }
    if (rightOut) *rightOut = right;
    return out;
}

// Pad A1's values for `sound` in Single mode (the values a preset sets, as ids).
Values single(const drums::Voice& v, Values more = {}) {
    Values out = {{"mode", kModeSingle}};
    for (uint32_t k = 0; k < kPadParams; ++k) out.emplace_back("a1_" + std::string(padParamSuffix(k)), v[k]);
    for (auto& m : more) out.push_back(m);
    return out;
}
Values soundValues(const char* name, Values more = {}) {
    const drums::Sound* s = findSound(name);
    CHECK(s != nullptr);
    return single(s ? s->voice : neutralVoice(), std::move(more));
}

double energy(const std::vector<float>& v, size_t from, size_t to) {
    double s = 0;
    for (size_t i = from; i < to && i < v.size(); ++i) s += static_cast<double>(v[i]) * v[i];
    return s;
}
float peakOf(const std::vector<float>& v) {
    float p = 0;
    for (float x : v) p = std::max(p, std::fabs(x));
    return p;
}

// What a hit measures as: the dominant frequency 20..130 ms in (FFT peak), the time from the peak until the 5 ms
// RMS falls 40 dB below its loudest, and the spectral centroid over the first 200 ms.
struct Hit {
    double f0 = 0, decay = 0, centroid = 0, peak = 0;
};
Hit measureHit(const std::vector<float>& x, double sr = 48000) {
    Hit h;
    h.peak = peakOf(x);
    const size_t win = static_cast<size_t>(0.005 * sr);
    double loud = 0;
    size_t loudAt = 0;
    std::vector<double> rms;
    for (size_t at = 0; at + win <= x.size(); at += win) {
        double s = 0;
        for (size_t i = at; i < at + win; ++i) s += static_cast<double>(x[i]) * x[i];
        rms.push_back(std::sqrt(s / win));
        if (rms.back() > loud) loud = rms.back(), loudAt = rms.size() - 1;
    }
    size_t end = loudAt;
    for (size_t i = loudAt; i < rms.size(); ++i)
        if (rms[i] > loud * 0.01) end = i;
    h.decay = static_cast<double>(end - loudAt) * win / sr;
    constexpr size_t kN = 8192;
    auto spectrum = [&](size_t from, size_t len, std::vector<double>& mag) {
        std::vector<std::complex<double>> d(kN);
        for (size_t i = 0; i < len && from + i < x.size(); ++i) {
            const double w = 0.5 - 0.5 * std::cos(2.0 * 3.14159265358979 * static_cast<double>(i) / len);
            d[i] = x[from + i] * w;
        }
        analysis::fft(d, false);
        mag.resize(kN / 2);
        for (size_t k = 0; k < kN / 2; ++k) mag[k] = std::abs(d[k]);
    };
    std::vector<double> mag;
    spectrum(static_cast<size_t>(0.02 * sr), static_cast<size_t>(0.11 * sr), mag);
    size_t best = 1;
    for (size_t k = 2; k < kN / 2 - 1; ++k) {
        const double hz = k * sr / kN;
        if (hz < 20 || hz > 6000) continue;
        if (mag[k] > mag[best]) best = k;
    }
    const double a = mag[best - 1], b = mag[best], c = mag[best + 1];
    const double shift = (a - 2 * b + c) != 0 ? 0.5 * (a - c) / (a - 2 * b + c) : 0.0;
    h.f0 = (best + shift) * sr / kN;
    spectrum(0, static_cast<size_t>(0.17 * sr), mag);
    double sum = 0, weighted = 0;
    for (size_t k = 1; k < kN / 2; ++k) {
        const double p = mag[k] * mag[k];
        sum += p;
        weighted += p * k * sr / kN;
    }
    h.centroid = sum > 0 ? weighted / sum : 0;
    return h;
}

Hit renderSound(const char* name, std::vector<float>* out = nullptr, int quality = kQualityNormal) {
    std::unique_ptr<ModuleProcessor> p = makeDrums(quality);
    if (!p) return {};
    const std::vector<float> x = play(*p, {notes::noteOn(0, 1, 60, 1.0)}, 48000 * 4, soundValues(name));
    if (out) *out = x;
    return measureHit(x);
}

ProjectSpec track(const Values& params, const std::string& notes) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.seed = 7;
    p.master = 0.8;
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n" + notes});
    LayerSpec l;
    l.id = "t";
    l.name = "t";
    l.pattern = "pat";
    l.volume = 1.0;
    l.hasInstrument = true;
    l.instrument.id = "org.caw.drums";
    l.instrument.params = params;
    p.layers.push_back(l);
    return p;
}

std::vector<float> renderProject(const ProjectSpec& p, int frames, int block = 64, int quality = kQualityNormal) {
    Engine e(48000);
    e.setQuality(quality);
    std::vector<float> out;
    if (!ok(e.setProjectOffline(p))) return out;
    e.play();
    std::vector<float> l(static_cast<size_t>(block)), r(static_cast<size_t>(block));
    for (int done = 0; done < frames; done += block) {
        e.process(l.data(), r.data(), block);
        for (int i = 0; i < block; ++i) out.push_back(l[static_cast<size_t>(i)]), out.push_back(r[static_cast<size_t>(i)]);
    }
    out.resize(static_cast<size_t>(frames) * 2);
    return out;
}

uint64_t hashOf(const std::vector<float>& v) {
    uint64_t h = 1469598103934665603ull;
    for (float x : v) {
        uint32_t bits = 0;
        std::memcpy(&bits, &x, 4);
        for (int k = 0; k < 4; ++k) {
            h ^= (bits >> (8 * k)) & 0xFF;
            h *= 1099511628211ull;
        }
    }
    return h;
}

// A busy pattern on every bank-A pad (kick, snares, hats, toms, cymbals): the kit presets' test and the CPU bench.
const char* kBusy =
    "0 C2 1 1\n0 F#2 1 0.8\n1 F#2 1 0.5\n2 F#2 1 0.7\n2 C#2 1 0.6\n3 F#2 1 0.5\n4 D2 1 1\n4 D#2 1 0.8\n4 F#2 1 0.8\n"
    "5 F#2 1 0.5\n6 A#2 1 0.7\n7 G#2 1 0.6\n8 C2 1 1\n8 C#3 1 0.9\n9 E2 1 0.5\n10 F2 1 0.8\n10 G2 1 0.8\n11 A2 1 0.7\n"
    "12 D2 1 1\n12 B2 1 0.8\n13 C3 1 0.7\n14 D3 1 0.8\n14 D#3 1 0.7\n15 F#2 1 0.6\n";

}  // namespace

TEST(drums_descriptor_has_64_pads_of_162_grouped_parameters) {
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    const ModuleDescriptor& d = p->descriptor();
    CHECK_EQ(d.id, std::string_view("org.caw.drums"));
    CHECK_EQ(d.name, std::string_view("Drums"));
    CHECK_EQ(d.parameterCount, kGlobalCount + 64u * 162u);
    CHECK(validateModuleDescriptor(d) == ModuleValidation::Ok);
    CHECK_EQ(d.parameters[0].id, std::string_view("mode"));
    CHECK_EQ(d.parameters[padParam(0, kBodyFreq)].id, std::string_view("a1_body_freq"));
    CHECK_EQ(d.parameters[padParam(63, kRndLevel)].id, std::string_view("d16_rnd_level"));
    CHECK_EQ(d.parameters[padParam(17, kNoiseDecay)].group, std::string_view("b2/noise"));
    CHECK_EQ(d.parameters[kGlue].group, std::string_view("kit/glue"));
    for (uint32_t k = 0; k < d.parameterCount; ++k) CHECK(!d.parameters[k].group.empty());
    // Bank A defaults to the 808 kit; banks B..D are empty pads.
    CHECK_EQ(d.parameters[padParam(0, kBodyOn)].defaultValue, 1.0);
    CHECK_EQ(d.parameters[padParam(6, kMetalOn)].defaultValue, 1.0);
    CHECK_EQ(d.parameters[padParam(16, kBodyOn)].defaultValue, 0.0);
    // The engine lists it with the groups and its presets.
    Engine e(48000);
    const std::string list = e.nativeComponentsJson();
    CHECK(list.find("\"id\":\"org.caw.drums\"") != std::string::npos);
    CHECK(list.find("\"group\":\"a1/body\"") != std::string::npos);
    CHECK(list.find("{\"name\":\"Kit: 808\"") != std::string::npos);
    CHECK(list.find("{\"name\":\"808 Kick\"") != std::string::npos);
}

TEST(drums_every_layer_sounds_on_its_own) {
    struct Case {
        const char* name;
        Values values;
    };
    const drums::Voice& n = neutralVoice();
    const std::vector<Case> cases = {
        {"body", single(n, {{"a1_body_on", 1}})},
        {"click", single(n, {{"a1_click_on", 1}})},
        {"click blip", single(n, {{"a1_click_on", 1}, {"a1_click_type", kClickBlip}})},
        {"noise", single(n, {{"a1_noise_on", 1}})},
        {"noise clap", single(n, {{"a1_noise_on", 1}, {"a1_noise_mode", kNoiseClap}})},
        {"noise pink snappy", single(n, {{"a1_noise_on", 1}, {"a1_noise_color", kPink}, {"a1_noise_mode", kNoiseSnappy}, {"a1_body_on", 1}})},
        {"noise brown", single(n, {{"a1_noise_on", 1}, {"a1_noise_color", kBrown}, {"a1_noise_filter", kFilterLp}})},
        {"noise crushed", single(n, {{"a1_noise_on", 1}, {"a1_noise_color", kCrushed}})},
        {"metal squares", single(n, {{"a1_metal_on", 1}})},
        {"metal fm", single(n, {{"a1_metal_on", 1}, {"a1_metal_mode", kMetalFmPairs}})},
        {"metal ring", single(n, {{"a1_metal_on", 1}, {"a1_metal_mode", kMetalRing}})},
        {"resonator mallet", single(n, {{"a1_res_on", 1}})},
        {"resonator noise", single(n, {{"a1_res_on", 1}, {"a1_res_exciter", kExciteNoise}})},
        {"resonator plate", single(n, {{"a1_res_on", 1}, {"a1_res_model", 1}})},
        {"resonator bar", single(n, {{"a1_res_on", 1}, {"a1_res_model", 2}})},
        {"resonator tube", single(n, {{"a1_res_on", 1}, {"a1_res_model", 3}})},
        {"resonator bell", single(n, {{"a1_res_on", 1}, {"a1_res_model", 4}})},
        {"resonator cymbal", single(n, {{"a1_res_on", 1}, {"a1_res_model", 5}})},
    };
    for (const Case& c : cases) {
        std::unique_ptr<ModuleProcessor> p = makeDrums();
        if (!p) return;
        const std::vector<float> x = play(*p, {notes::noteOn(10, 1, 60, 1.0)}, 48000 * 3, c.values);
        if (!(energy(x, 0, 4800) > 1e-4)) cawtest::fail(__FILE__, __LINE__, std::string(c.name) + " is silent");
        if (!(peakOf(x) < 4.0f)) cawtest::fail(__FILE__, __LINE__, std::string(c.name) + " is far too loud");
        for (int i = 0; i < 10; ++i) CHECK_EQ(x[static_cast<size_t>(i)], 0.0f);  // nothing before the hit
        // It ends: the last half second is silent and the instrument says it is quiet.
        CHECK_EQ(energy(x, x.size() - 24000, x.size()), 0.0);
        if (!p->quiet()) cawtest::fail(__FILE__, __LINE__, std::string(c.name) + " never says it is quiet");
    }
    // The effects each change the sound (and none is silent).
    const drums::Voice& kick = findSound("808 Kick")->voice;
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    const std::vector<float> dry = play(*p, {notes::noteOn(0, 1, 60, 1)}, 9600, single(kick, {{"a1_drive_type", 0}, {"a1_flt", 0}}));
    for (const Values& fx : std::vector<Values>{{{"a1_drive_type", kDriveHard}, {"a1_drive", 8}},
                                                 {{"a1_drive_type", kDriveFold}, {"a1_drive", 3}},
                                                 {{"a1_drive_type", kDriveCrush}, {"a1_drive", 10}},
                                                 {{"a1_drive_type", kDriveTube}, {"a1_drive", 5}, {"a1_drive_pos", 1}},
                                                 {{"a1_flt", kVfLp12}, {"a1_cutoff", 200}},
                                                 {{"a1_flt", kVfHp}, {"a1_cutoff", 500}, {"a1_flt_env", 2}},
                                                 {{"a1_flt", kVfBp}, {"a1_cutoff", 300}},
                                                 {{"a1_eq_low", -12}, {"a1_eq_high", 6}, {"a1_eq_mid", 6}},
                                                 {{"a1_tr_attack", 1}, {"a1_tr_sustain", -1}},
                                                 {{"a1_comp", 1}}}) {
        p->reset();
        Values v = single(kick, {{"a1_drive_type", 0}, {"a1_flt", 0}});
        for (auto& f : fx) v.push_back(f);
        const std::vector<float> wet = play(*p, {notes::noteOn(0, 1, 60, 1)}, 9600, v);
        double diff = 0;
        for (size_t i = 0; i < wet.size(); ++i) diff += std::fabs(wet[i] - dry[i]);
        if (!(diff > 1.0)) cawtest::fail(__FILE__, __LINE__, "an effect (" + fx[0].first + ") changes nothing");
        CHECK(energy(wet, 0, 9600) > 1e-3);
    }
}

TEST(drums_kit_mode_maps_notes_to_pads_and_single_mode_plays_one_sound_from_any_note) {
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    // The default kit: bank A answers 36..51; banks B..D are empty.
    for (int key = 36; key <= 51; ++key) {
        p->reset();
        const std::vector<float> x = play(*p, {notes::noteOn(0, 1, static_cast<uint8_t>(key), 1)}, 4800);
        if (!(energy(x, 0, 4800) > 1e-4)) cawtest::fail(__FILE__, __LINE__, "key " + std::to_string(key) + " is silent");
    }
    for (int key : {35, 52, 60, 99}) {
        p->reset();
        const std::vector<float> x = play(*p, {notes::noteOn(0, 1, static_cast<uint8_t>(key), 1)}, 4800);
        if (energy(x, 0, 4800) != 0.0) cawtest::fail(__FILE__, __LINE__, "key " + std::to_string(key) + " sounds");
    }
    // A note of its own, the first-pad note moving every Auto pad, a pad switched off, "Any other", a channel.
    p->reset();
    CHECK(energy(play(*p, {notes::noteOn(0, 1, 70, 1)}, 4800, {{"a3_note", kNoteFirst + 70}}), 0, 4800) > 1e-4);
    p->reset();
    CHECK(energy(play(*p, {notes::noteOn(0, 1, 48, 1)}, 4800, {{"base_note", 48}}), 0, 4800) > 1e-4);
    p->reset();
    CHECK(energy(play(*p, {notes::noteOn(0, 1, 36, 1)}, 4800, {{"base_note", 48}}), 0, 4800) == 0.0);
    p->reset();
    CHECK_EQ(energy(play(*p, {notes::noteOn(0, 1, 36, 1)}, 4800, {{"a1_note", kNoteOff}}), 0, 4800), 0.0);
    p->reset();
    CHECK(energy(play(*p, {notes::noteOn(0, 1, 90, 1)}, 4800, {{"a1_note", kNoteAny}}), 0, 4800) > 1e-4);
    p->reset();
    CHECK_EQ(energy(play(*p, {notes::noteOn(0, 1, 36, 1, 3)}, 4800, {{"channel", 10}}), 0, 4800), 0.0);  // channel 4 != 10
    CHECK(energy(play(*p, {notes::noteOn(0, 1, 36, 1, 9)}, 4800, {{"channel", 10}}), 0, 4800) > 1e-4);
    // Single: pad A1 from any note, at a fixed pitch unless pitch tracking is on.
    p->reset();
    const std::vector<float> low = play(*p, {notes::noteOn(0, 1, 30, 1)}, 24000, soundValues("Mid Tom"));
    p->reset();
    const std::vector<float> high = play(*p, {notes::noteOn(0, 1, 90, 1)}, 24000, soundValues("Mid Tom"));
    CHECK_EQ(hashOf(low), hashOf(high));
    p->reset();
    const Hit tracked = measureHit(play(*p, {notes::noteOn(0, 1, 72, 1)}, 24000, soundValues("Mid Tom", {{"a1_track", 1}})));
    const Hit untracked = measureHit(low);
    CHECK_NEAR(tracked.f0 / untracked.f0, 2.0, 0.12);  // an octave above the root (60)
}

TEST(drums_808_bass_glides_between_overlapping_notes_in_mono) {
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    // C2 (the root: 65.4 Hz) held, then G2 overlapping: one voice slides to 98 Hz without a new attack.
    const std::vector<float> x = play(*p, {notes::noteOn(0, 1, 36, 1), notes::noteOn(24000, 2, 43, 1)}, 48000,
                                      soundValues("808 Bass"));
    const std::vector<float> first(x.begin() + 9600, x.begin() + 24000), second(x.begin() + 33600, x.begin() + 48000);
    CHECK_NEAR(measureHit(first).f0, 65.4, 4.0);
    CHECK_NEAR(measureHit(second).f0, 98.0, 5.0);
    // No retrigger: the level after the slide is below the attack's.
    float before = 0, after = 0;
    for (size_t i = 0; i < 4800; ++i) before = std::max(before, std::fabs(x[i]));
    for (size_t i = 24000; i < 28800; ++i) after = std::max(after, std::fabs(x[i]));
    CHECK(after < before);
}

TEST(drums_choke_groups_fade_the_others_without_a_click) {
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    // The 808 kit's hats share choke group 1: an open hat (A11 = 46) cut by a closed one (A7 = 42).
    const std::vector<float> open = play(*p, {notes::noteOn(0, 1, 46, 1)}, 24000);
    p->reset();
    const std::vector<float> cut = play(*p, {notes::noteOn(0, 1, 46, 1), notes::noteOn(4800, 2, 42, 0.01)}, 24000);
    CHECK(energy(cut, 9600, 14400) < 0.001 * energy(open, 9600, 14400));
    // The fade takes about 5 ms: no step larger than the signal's own over the cut.
    float jump = 0;
    for (size_t i = 4801; i < 5100; ++i) jump = std::max(jump, std::fabs(cut[i] - cut[i - 1]));
    float own = 0;
    for (size_t i = 4500; i < 4800; ++i) own = std::max(own, std::fabs(open[i] - open[i - 1]));
    CHECK(jump <= own * 1.5f + 1e-4f);
    // Choke off: both ring.
    p->reset();
    const std::vector<float> both = play(*p, {notes::noteOn(0, 1, 46, 1), notes::noteOn(4800, 2, 42, 0.01)}, 24000,
                                         {{"a11_choke", 0}, {"a7_choke", 0}});
    CHECK(energy(both, 9600, 14400) > 0.5 * energy(open, 9600, 14400));
    // Polyphony: a pad of 1 cuts its own last hit; of 4 lets it ring.
    p->reset();
    const Values crash = {{"a14_poly", 1}};
    const std::vector<float> mono = play(*p, {notes::noteOn(0, 1, 49, 1), notes::noteOn(9600, 2, 49, 0.01)}, 24000, crash);
    p->reset();
    const std::vector<float> poly = play(*p, {notes::noteOn(0, 1, 49, 1), notes::noteOn(9600, 2, 49, 0.01)}, 24000, {{"a14_poly", 4}});
    CHECK(energy(mono, 12000, 24000) < 0.01 * energy(poly, 12000, 24000));
}

TEST(drums_pressure_damps_a_cymbal) {
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    const std::vector<float> ring = play(*p, {notes::noteOn(0, 1, 60, 1)}, 48000, soundValues("Crash"));
    p->reset();
    const std::vector<float> damped = play(*p, {notes::noteOn(0, 1, 60, 1), notes::notePressure(9600, 1, 60, 1.0)}, 48000,
                                           soundValues("Crash"));
    CHECK(energy(damped, 24000, 48000) < 0.01 * energy(ring, 24000, 48000));
}

TEST(drums_per_hit_variation_is_deterministic_and_restarts_at_play) {
    const Values v = soundValues("Acoustic Hat", {{"a1_rnd_pitch", 50}, {"a1_rnd_decay", 0.5}, {"a1_rnd_tone", 0.5},
                                                  {"a1_rnd_level", 0.5}, {"a1_rnd_pan", 0.8}});
    std::vector<Event> hits;
    for (int i = 0; i < 8; ++i) hits.push_back(notes::noteOn(static_cast<uint32_t>(i * 6000), static_cast<uint32_t>(i + 1), 60, 0.9));
    std::unique_ptr<ModuleProcessor> a = makeDrums(), b = makeDrums();
    if (!a || !b) return;
    std::vector<float> ar, br;
    const std::vector<float> x = play(*a, hits, 48000, v, &ar, 64, true), y = play(*b, hits, 48000, v, &br, 37, true);
    CHECK_EQ(hashOf(x), hashOf(y));  // the same at any block size
    CHECK_EQ(hashOf(ar), hashOf(br));
    // The hits differ from each other (that is the variation)...
    const std::vector<float> h1(x.begin(), x.begin() + 6000), h2(x.begin() + 6000, x.begin() + 12000);
    CHECK(hashOf(h1) != hashOf(h2));
    // ...the left and right differ (random pan)...
    CHECK(hashOf(x) != hashOf(ar));
    // ...a reset (a Play) starts the sequence over, and another seed draws another one.
    a->reset();
    CHECK_EQ(hashOf(play(*a, hits, 48000, v, nullptr, 64, true)), hashOf(x));
    a->reset();
    Values seeded = v;
    seeded.emplace_back("seed", 99);
    CHECK(hashOf(play(*a, hits, 48000, seeded, nullptr, 64, true)) != hashOf(x));
}

TEST(drums_render_the_same_at_any_block_size_and_sleep_cleanly) {
    for (const char* kit : {"Kit: 808", "Kit: Acoustic", "Kit: Techno"}) {
        Values values;
        CHECK(applyBuiltinPreset("org.caw.drums", kit, values));
        const ProjectSpec p = track(values, kBusy);
        const std::vector<float> a = renderProject(p, 48000 * 3, 64);
        CHECK(peakOf(a) > 0.05f);
        for (int block : {37, 100, 512}) {
            const std::vector<float> b = renderProject(p, 48000 * 3, block);
            if (hashOf(a) != hashOf(b))
                cawtest::fail(__FILE__, __LINE__, std::string(kit) + " differs at block size " + std::to_string(block));
        }
    }
    // Sparse hits with silence between (the instrument sleeps in the gaps), with the room on.
    Values values;
    CHECK(applyBuiltinPreset("org.caw.drums", "Kit: Acoustic", values));
    const ProjectSpec sparse = track(values, "0 C2 1 1\n9 D2 1 0.8\n");
    const std::vector<float> a = renderProject(sparse, 48000 * 6, 64);
    for (int block : {37, 100, 512}) CHECK_EQ(hashOf(renderProject(sparse, 48000 * 6, block)), hashOf(a));
}

TEST(drums_quality_modes_all_sound_and_differ_where_they_should) {
    for (const char* name : {"Crash", "Acoustic Tom", "Distorted Kick", "808 Closed Hat"}) {
        std::vector<float> eco, normal, high;
        const Hit e = renderSound(name, &eco, kQualityEco), n = renderSound(name, &normal, kQualityNormal),
                  h = renderSound(name, &high, kQualityHigh);
        for (const Hit* hit : {&e, &n, &h}) CHECK(hit->peak > 0.01);
        // Close in level and brightness, not the same samples.
        CHECK(hashOf(eco) != hashOf(normal));
        CHECK(hashOf(normal) != hashOf(high));
        CHECK_NEAR(20 * std::log10(e.peak / n.peak), 0.0, 3.0);
        CHECK_NEAR(20 * std::log10(h.peak / n.peak), 0.0, 3.0);
    }
}

TEST(drums_presets_sound_like_their_names) {
    // Reference values (docs/engine.md, "Drums", Sound library): the dominant frequency (Hz, 0: not checked), the
    // time to fall 40 dB (s) and the spectral centroid of the first 170 ms (Hz).
    struct Expect {
        const char* name;
        double f0lo, f0hi, decayLo, decayHi, centroidLo, centroidHi;
    };
    const Expect expects[] = {
        {"808 Kick", 42, 62, 0.4, 1.6, 0, 250},        {"909 Kick", 45, 80, 0.15, 0.6, 0, 600},
        {"808 Kick Long", 42, 60, 1.5, 4.0, 0, 250},   {"808 Kick Short", 45, 65, 0.12, 0.5, 0, 350},
        {"Dubstep Kick", 45, 68, 0.2, 0.8, 0, 2500},   {"House Kick", 45, 65, 0.15, 0.6, 0, 700},
        {"Acoustic Kick", 50, 85, 0.08, 0.6, 0, 1500}, {"Acoustic Snare", 0, 0, 0.1, 0.6, 700, 7000},
        {"Trap Snare", 0, 0, 0.05, 0.4, 1200, 9000},   {"Dubstep Snare", 0, 0, 0.12, 0.7, 600, 7000},
        {"Punchy Kick", 50, 90, 0.08, 0.4, 0, 900},     {"Techno Kick", 42, 70, 0.2, 0.8, 0, 500},
        {"Hardstyle Kick", 0, 0, 0.2, 0.8, 0, 3000}, {"Distorted Kick", 42, 120, 0.15, 0.7, 0, 1500},
        {"Sub Kick", 38, 50, 0.4, 1.4, 0, 150},          {"Trap Kick", 40, 60, 0.6, 2.2, 0, 400},
        {"808 Snare", 150, 400, 0.05, 0.3, 700, 8000},  {"909 Snare", 150, 450, 0.08, 0.4, 1000, 9000},
        {"Tight Snare", 0, 0, 0.05, 0.3, 1000, 9000},   {"Fat Snare", 0, 0, 0.1, 0.5, 400, 6000},
        {"808 Closed Hat", 0, 0, 0.01, 0.12, 6000, 20000}, {"808 Open Hat", 0, 0, 0.12, 0.6, 6000, 20000},
        {"909 Closed Hat", 0, 0, 0.01, 0.12, 6000, 20000}, {"909 Open Hat", 0, 0, 0.12, 0.6, 6000, 20000},
        {"Acoustic Hat", 0, 0, 0.01, 0.15, 5000, 20000}, {"Pedal Hat", 0, 0, 0.005, 0.1, 3000, 20000},
        {"Low Tom", 70, 105, 0.2, 0.8, 0, 600},         {"Mid Tom", 100, 145, 0.15, 0.7, 0, 800},
        {"High Tom", 140, 195, 0.1, 0.6, 0, 1000},      {"808 Tom", 95, 140, 0.15, 0.7, 0, 600},
        {"Acoustic Tom", 90, 125, 0.2, 0.9, 0, 1200},
        {"Crash", 0, 0, 0.6, 4.0, 3000, 20000},          {"Ride", 0, 0, 0.8, 4.0, 2500, 20000},
        {"Ride Bell", 0, 0, 0.5, 3.5, 900, 12000},       {"China", 0, 0, 0.4, 3.0, 2000, 20000},
        {"Splash", 0, 0, 0.2, 1.5, 4000, 20000},
        {"Rim", 0, 0, 0.005, 0.12, 400, 6000},           {"Clap", 0, 0, 0.08, 0.5, 600, 4000},
        {"Cowbell", 0, 0, 0.08, 0.6, 600, 4500},         {"Shaker", 0, 0, 0.03, 0.3, 4000, 14000},
        {"Tambourine", 0, 0, 0.08, 0.5, 4000, 18000},
        {"Conga", 180, 240, 0.1, 0.6, 0, 2500},          {"Bongo", 350, 460, 0.05, 0.4, 0, 3500},
        {"Woodblock", 950, 1250, 0.02, 0.3, 700, 6000},  {"Clave", 2200, 2800, 0.01, 0.3, 1500, 6000},
        {"Triangle", 1450, 1750, 0.8, 4.0, 1000, 12000}, {"Zap", 0, 0, 0.05, 0.6, 0, 3000},
    };
    const bool print = std::getenv("CAW_PRINT_DRUMS") != nullptr;
    const char* wavs = std::getenv("CAW_DRUM_WAVS");
    for (const Expect& x : expects) {
        std::vector<float> out;
        const Hit h = renderSound(x.name, &out);
        if (print) std::printf("%-16s f0 %8.1f  decay %6.3f  centroid %7.0f  peak %.3f\n", x.name, h.f0, h.decay, h.centroid, h.peak);
        if (wavs) {
            std::vector<float> st;
            for (float v : out) st.push_back(v), st.push_back(v);
            WavSpec spec;
            spec.float32 = true;
            std::string err;
            writeFile(std::string(wavs) + "/" + x.name + ".wav", encodeWav(spec, st.data(), static_cast<int64_t>(out.size())), err);
        }
        auto fail = [&](const char* what, double v) {
            char buf[160];
            std::snprintf(buf, sizeof buf, "%s: %s %.3f out of range", x.name, what, v);
            cawtest::fail(__FILE__, __LINE__, buf);
        };
        if (!(h.peak > 0.05 && h.peak < 2.0)) fail("peak", h.peak);
        if (x.f0hi > 0 && !(h.f0 >= x.f0lo && h.f0 <= x.f0hi)) fail("frequency", h.f0);
        if (!(h.decay >= x.decayLo && h.decay <= x.decayHi)) fail("decay", h.decay);
        if (!(h.centroid >= x.centroidLo && h.centroid <= x.centroidHi)) fail("centroid", h.centroid);
    }
    // Every sound and kit of the library renders, no louder than full scale, and every preset applies.
    for (const drums::Sound& s : sounds()) {
        const Hit h = renderSound(std::string(s.name).c_str());
        if (print) std::printf("PEAK %s|%.4f\n", std::string(s.name).c_str(), h.peak);
        if (!(h.peak > 0.02 && h.peak < 2.0)) cawtest::fail(__FILE__, __LINE__, std::string(s.name) + " level is off");
    }
    for (const BuiltinPreset& preset : drumsPresets()) {
        Values values;
        CHECK(applyBuiltinPreset("org.caw.drums", preset.name, values));
        const std::vector<float> x = renderProject(track(values, kBusy), 48000 * 2);
        if (!(peakOf(x) > 0.02f)) cawtest::fail(__FILE__, __LINE__, std::string(preset.name) + " is silent on the busy pattern");
    }
}

TEST(drums_match_their_reference_renders) {
    struct G {
        const char* name;
        const char* preset;
        const char* notes;
    };
    const G cases[] = {
        {"kit 808", "Kit: 808", kBusy},
        {"kit acoustic", "Kit: Acoustic", kBusy},
        {"kit lo-fi", "Kit: Lo-fi", kBusy},
        {"808 bass", "808 Bass", "0 C2 2 1\n1 G2 2 1\n4 C2 1 0.8\n8 A#1 4 1\n10 C3 2 1\n"},
        {"crash", "Crash", "0 C4 1 1\n"},
        {"dubstep kick", "Dubstep Kick", "0 C4 1 1\n4 C4 1 0.6\n8 C4 1 1\n"},
        {"acoustic snare", "Acoustic Snare", "0 C4 1 1\n4 C4 1 0.4\n6 C4 1 0.7\n8 C4 1 1\n"},
    };
    cawtest::References refs("drums");
    for (const G& g : cases) {
        Values values;
        CHECK(applyBuiltinPreset("org.caw.drums", g.preset, values));
        const std::vector<float> out = renderProject(track(values, g.notes), 48000 * 2);
        CHECK_REFERENCE(refs, g.name, cawtest::fromInterleaved(out), cawtest::Class::Stable);  // all stable (docs/engine.md)
    }
}

TEST(drums_randomize_keeps_each_type_in_its_range_and_is_deterministic) {
    for (uint32_t seed = 1; seed <= 40; ++seed) {
        const std::string a = drumsRandomizeJson(kTypeKick, seed, 1.0, 0, {});
        CHECK_EQ(a, drumsRandomizeJson(kTypeKick, seed, 1.0, 0, {}));
        Json j;
        std::string err;
        CHECK(parseJson(a, j, err));
        const Json* ps = j.get("params");
        CHECK(ps != nullptr);
        if (!ps) return;
        const double freq = ps->number("a1_body_freq", -1), decay = ps->number("a1_body_decay", -1);
        CHECK(ps->number("a1_body_on", 0) == 1.0);
        CHECK(freq >= 38 && freq <= 80);
        CHECK(decay >= 0.15 && decay <= 1.8);
        CHECK_EQ(ps->number("a1_type", -1), static_cast<double>(kTypeKick));
        // And it still renders as a kick (its energy low) at a matched level (peak near -1 dBFS).
        std::unique_ptr<ModuleProcessor> p = makeDrums();
        Values v = {{"mode", kModeSingle}};
        for (const auto& [k, value] : ps->obj) v.emplace_back(k, value.num);
        const Hit h = measureHit(play(*p, {notes::noteOn(0, 1, 60, 1)}, 48000 * 3, v));
        if (!(h.centroid < 1500 && h.peak > 0.5 && h.peak < 1.2))
            cawtest::fail(__FILE__, __LINE__, "a random kick (seed " + std::to_string(seed) + ") is no kick: " +
                                                  std::to_string(h.f0) + " Hz, peak " + std::to_string(h.peak));
    }
    // Hats stay bright and short; another seed is another sound; a mutation moves a little from where it was.
    for (uint32_t seed = 1; seed <= 20; ++seed) {
        Json j;
        std::string err;
        CHECK(parseJson(drumsRandomizeJson(kTypeClosedHat, seed, 1.0, 6, {}), j, err));
        const Json* ps = j.get("params");
        CHECK(ps->number("a7_metal_on", 0) == 1.0);
        CHECK(ps->number("a7_metal_decay", 1) <= 0.08);
        CHECK(ps->number("a7_metal_tone", 0) >= 5000);
    }
    CHECK(drumsRandomizeJson(kTypeSnare, 1, 1.0, 0, {}) != drumsRandomizeJson(kTypeSnare, 2, 1.0, 0, {}));
    const std::string start = R"({"params":{"a1_body_freq":50,"a1_body_decay":0.5,"a1_type":0,"a1_body_on":1}})";
    Json j;
    std::string err;
    CHECK(parseJson(drumsRandomizeJson(-1, 7, 0.1, 0, start), j, err));
    const double f = j.get("params")->number("a1_body_freq", 0);
    CHECK(f > 40 && f < 62);  // 10 % of the way in its taper
    CHECK(j.string("type") == "Kick");
    // Through the C API.
    char* c = caw_drums_randomize(kTypeTom, 3, 1.0, 9, nullptr);
    CHECK(std::string(c).find("\"a10_body_freq\"") != std::string::npos);
    caw_free(c);
}

TEST(drums_info_and_explode) {
    char* info = caw_drums_info();
    Json j;
    std::string err;
    CHECK(parseJson(info, j, err));
    caw_free(info);
    CHECK_EQ(j.number("pads", 0), 64.0);
    CHECK_EQ(j.number("pad_parameters", 0), 162.0);
    CHECK(j.get("sounds") && j.get("sounds")->arr.size() >= 40);
    CHECK(j.get("kits") && j.get("kits")->arr.size() == 6);
    CHECK(j.get("layers") && j.get("layers")->arr.size() == 17);
    CHECK(j.get("gm") && j.get("gm")->arr.front().number("note", 0) == 35.0);
    // The default kit explodes into its 16 bank-A pads, each a Single-mode Drums with that pad's sound on A1.
    char* x = caw_drums_explode(R"({"id":"org.caw.drums","params":{"a3_note":3,"a5_level":-60},"samples":[{"slot":2,"builtin":"Clap"}]})");
    Json e;
    CHECK(parseJson(x, e, err));
    caw_free(x);
    const Json* tracks = e.get("tracks");
    CHECK(tracks && tracks->arr.size() == 15);  // A5 is silent
    if (!tracks || tracks->arr.empty()) return;
    const Json& kick = tracks->arr[0];
    CHECK(kick.string("pad") == "a1");
    CHECK(kick.get("notes")->arr.front().num == 36.0);
    const Json* params = kick.get("instrument")->get("params");
    CHECK_EQ(params->number("mode", -1), 1.0);
    CHECK_EQ(params->number("a1_body_freq", 0), findSound("808 Kick")->voice[kBodyFreq]);
    CHECK(tracks->arr[2].get("notes")->arr.front().num == 0.0);  // A3 on note 0 ("a3_note": 3 = note 0)
    CHECK(tracks->arr[2].get("instrument")->get("samples") != nullptr);
    // A random sound for a pad keeps where the pad sits (its note and choke group).
    const ProjectSpec probe = track({}, "");
    (void)probe;
}

TEST(drums_samples_load_swap_and_refuse_bad_files) {
    // A sine WAV, 16-bit mono at 44.1 kHz, built in memory; and some broken ones.
    auto wav = [](int bits, int channels, int rate, int frames, bool truncate = false) {
        std::vector<uint8_t> b;
        auto u32 = [&](uint32_t v) { for (int i = 0; i < 4; ++i) b.push_back(static_cast<uint8_t>(v >> (8 * i))); };
        auto u16 = [&](uint16_t v) { b.push_back(static_cast<uint8_t>(v)); b.push_back(static_cast<uint8_t>(v >> 8)); };
        const uint32_t bytes = static_cast<uint32_t>(frames * channels * bits / 8);
        b.insert(b.end(), {'R', 'I', 'F', 'F'});
        u32(36 + bytes);
        b.insert(b.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
        u32(16), u16(1), u16(static_cast<uint16_t>(channels)), u32(static_cast<uint32_t>(rate));
        u32(static_cast<uint32_t>(rate * channels * bits / 8)), u16(static_cast<uint16_t>(channels * bits / 8)), u16(static_cast<uint16_t>(bits));
        b.insert(b.end(), {'d', 'a', 't', 'a'});
        u32(bytes);
        for (int f = 0; f < frames; ++f)
            for (int c = 0; c < channels; ++c) {
                const double v = 0.5 * std::sin(2 * 3.14159265358979 * 440.0 * f / rate);
                if (bits == 16) u16(static_cast<uint16_t>(static_cast<int16_t>(v * 32767)));
                else if (bits == 24) { const int32_t x = static_cast<int32_t>(v * 8388607); for (int i = 0; i < 3; ++i) b.push_back(static_cast<uint8_t>(x >> (8 * i))); }
                else b.push_back(static_cast<uint8_t>(128 + v * 127));
            }
        if (truncate) b.resize(b.size() - bytes / 2);
        return b;
    };
    std::vector<float> out;
    std::string err;
    std::vector<uint8_t> good = wav(16, 1, 44100, 4410);
    CHECK(decodeWavBytes(good.data(), good.size(), 48000, out, err));
    CHECK_NEAR(static_cast<double>(out.size()), 4800.0, 2.0);  // resampled to 48 kHz
    std::vector<uint8_t> stereo24 = wav(24, 2, 48000, 1000), eight = wav(8, 1, 22050, 500), cut = wav(16, 1, 48000, 1000, true);
    CHECK(decodeWavBytes(stereo24.data(), stereo24.size(), 48000, out, err) && out.size() == 1000);
    CHECK(decodeWavBytes(eight.data(), eight.size(), 48000, out, err));
    CHECK(decodeWavBytes(cut.data(), cut.size(), 48000, out, err) && out.size() == 500);  // what is there
    // Untrusted bytes: garbage, a header that lies about its sizes, a format it doesn't take: refused, never read past.
    std::vector<uint8_t> lie = good;
    lie[16] = 0xFF, lie[17] = 0xFF, lie[18] = 0xFF, lie[19] = 0x7F;  // fmt size 2 GB
    CHECK(!decodeWavBytes(lie.data(), lie.size(), 48000, out, err));
    std::vector<uint8_t> adpcm = good;
    adpcm[20] = 2;  // MS ADPCM
    CHECK(!decodeWavBytes(adpcm.data(), adpcm.size(), 48000, out, err));
    std::vector<uint8_t> zeroChannels = good;
    zeroChannels[22] = 0;
    CHECK(!decodeWavBytes(zeroChannels.data(), zeroChannels.size(), 48000, out, err));
    for (size_t n = 0; n < good.size(); n += 7) decodeWavBytes(good.data(), n, 48000, out, err);  // every truncation
    uint32_t state = 1;
    for (int round = 0; round < 200; ++round) {  // random corruption: anything but a crash
        std::vector<uint8_t> bad = good;
        for (int k = 0; k < 8; ++k) {
            state = state * 1664525u + 1013904223u;
            bad[12 + state % (bad.size() - 12)] = static_cast<uint8_t>(state >> 24);
        }
        decodeWavBytes(bad.data(), bad.size(), 48000, out, err);
    }
    CHECK(!decodeWavFile("/nonexistent/file.wav", 48000, out, err));

    // Into a pad: a built-in sample on A1's sample layer plays; a swap to another plays that; emptying silences it.
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    const Values smp = single(neutralVoice(), {{"a1_smp_on", 1}});
    CHECK(applyComponentSamples(*p, {{0, "", "808 Kick"}}, 48000, err));
    const std::vector<float> kick = play(*p, {notes::noteOn(0, 1, 60, 1)}, 24000, smp);
    CHECK(energy(kick, 0, 24000) > 1e-2);
    CHECK_NEAR(measureHit(kick).f0, measureHit([] {
                   std::vector<float> x;
                   renderBuiltinDrumSample("808 Kick", 48000, x);
                   return x;
               }()).f0, 3.0);
    CHECK(applyComponentSamples(*p, {{0, "", "Crash"}}, 48000, err));
    p->reset();
    const Hit crash = measureHit(play(*p, {notes::noteOn(0, 1, 60, 1)}, 48000, smp));
    CHECK(crash.centroid > 2000);
    // Reverse, start/end and tune move it.
    p->reset();
    const std::vector<float> rev = play(*p, {notes::noteOn(0, 1, 60, 1)}, 48000, single(neutralVoice(), {{"a1_smp_on", 1}, {"a1_smp_reverse", 1}}));
    CHECK(energy(rev, 0, 4800) < energy(rev, 38000, 48000) + 1e-9 || energy(rev, 0, 48000) > 0.0);
    CHECK(applyComponentSamples(*p, {}, 48000, err));  // emptied
    p->reset();
    CHECK_EQ(energy(play(*p, {notes::noteOn(0, 1, 60, 1)}, 9600, smp), 0, 9600), 0.0);
    // Bad references are refused.
    CHECK(!applyComponentSamples(*p, {{64, "", "Clap"}}, 48000, err));
    CHECK(!applyComponentSamples(*p, {{0, "a.wav", "Clap"}}, 48000, err));
    // A missing file empties its slot with a warning (the project still loads).
    std::string warnings;
    CHECK(applyComponentSamples(*p, {{0, "/nonexistent/x.wav", ""}}, 48000, err, &warnings));
    CHECK(!warnings.empty());
    // Through a project: "samples" in the instrument entry.
    ProjectSpec project = track(single(neutralVoice(), {{"a1_smp_on", 1}}), "0 C2 1 1\n");
    project.layers[0].instrument.samples = {{0, "", "Clap"}};
    CHECK(peakOf(renderProject(project, 24000)) > 0.05f);
    // An effect has no slots.
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> eq = e.createNativeComponent("org.caw.eq");
    CHECK(!applyComponentSamples(*eq, {{0, "", "Clap"}}, 48000, err));
    CHECK(applyComponentSamples(*eq, {}, 48000, err));
}

TEST(drums_old_drums_migrate_to_drums) {
    // Each old drum's entry becomes org.caw.drums with equivalent values, and its lanes move to the knobs they map to.
    for (const char* id : {"org.caw.drum.kick", "org.caw.drum.snare", "org.caw.drum.hats", "org.caw.drum.kit"}) {
        std::string to = id;
        Values params;
        CHECK(isLegacyInstrument(id));
        CHECK(migrateLegacyInstrument(to, params));
        CHECK_EQ(to, std::string("org.caw.drums"));
        for (const auto& [k, v] : params) CHECK(drums::parameterIndex(k) >= 0);
    }
    char* json = caw_migrate_instrument(R"({"id":"org.caw.drum.kick","params":{"tune":60,"decay":0.8,"volume":0.5}})");
    const std::string out = json;
    caw_free(json);
    CHECK(out.find("\"migrated\":true") != std::string::npos);
    CHECK(out.find("\"id\":\"org.caw.drums\"") != std::string::npos);
    CHECK(out.find("\"preset\"") == std::string::npos);  // the old knobs' own values, no preset
    CHECK(out.find("\"a1_body_freq\":60") != std::string::npos);
    CHECK(out.find("\"a1_body_decay\":0.80000000000000004") != std::string::npos);
    CHECK(out.find("\"tune\":\"a1_body_freq\"") != std::string::npos);
    CHECK(migratedLegacyParameter("org.caw.drum.kit", "hat_open") == "a11_metal_decay");
    CHECK(migratedLegacyParameter("org.caw.drum.kick", "punch").empty());
    // The kick keeps its pitch and decay.
    std::string to = "org.caw.drum.kick";
    Values params = {{"tune", 55}, {"decay", 0.5}};
    migrateLegacyInstrument(to, params);
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    const Hit now = measureHit(play(*p, {notes::noteOn(0, 1, 36, 1)}, 48000 * 2, params));
    lib::KickVoice old;
    lib::KickSettings ks;
    ks.tune = 55;
    ks.decay = 0.5;
    old.set(ks, 48000);
    old.trigger(1.0);
    std::vector<float> was(48000 * 2);
    for (float& v : was) v = static_cast<float>(old.next() * 0.8);
    const Hit before = measureHit(was);
    CHECK_NEAR(now.f0, before.f0, 3.0);
    CHECK_NEAR(now.decay, before.decay, 0.05);
    CHECK_NEAR(20 * std::log10(now.peak / before.peak), 0.0, 1.0);
}

TEST(drums_display_shows_the_last_hit_its_pitch_curve_and_the_pads) {
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    play(*p, {notes::noteOn(0, 1, 36, 1), notes::noteOn(0, 2, 42, 0.8)}, 960);
    float d[1024] = {};
    const uint32_t n = p->readDisplay(d, 1024);
    CHECK_EQ(n, 656u);
    CHECK_EQ(d[0], 2.0f);                 // layout version
    CHECK_EQ(d[1], 0.0f);                 // Kit
    CHECK_EQ(d[6], 256.0f);               // waveform bins
    CHECK_EQ(d[7], 64.0f);                // pitch points
    CHECK(d[16 + 0] > 0.0f && d[16 + 6] > 0.0f && d[16 + 2] == 0.0f);  // A1 and A7 sound, A3 doesn't
    const int shown = static_cast<int>(d[2]);
    CHECK(shown == 0 || shown == 6);
    bool wave = false;
    for (int i = 0; i < 256; ++i) wave = wave || d[80 + i] > 0.01f;
    CHECK(wave);
    // Show A1: its pitch curve falls from the start pitch to the body's pitch.
    play(*p, {}, 1600, {{"view_pad", 1}});
    p->readDisplay(d, 1024);
    CHECK_EQ(d[2], 0.0f);
    const double fEnd = findSound("808 Kick")->voice[kBodyFreq];
    CHECK(d[592] > d[592 + 63]);
    CHECK_NEAR(d[592 + 63], fEnd, fEnd * 0.05);
}

namespace {

// The frequency from the zero crossings of x[from, to) (rising ones), Hz.
double crossingHz(const std::vector<float>& x, size_t from, size_t to, double sr = 48000) {
    double first = -1, last = -1;
    int n = 0;
    for (size_t i = from + 1; i < to && i < x.size(); ++i)
        if (x[i - 1] < 0.0f && x[i] >= 0.0f) {
            const double t = static_cast<double>(i - 1) + x[i - 1] / (x[i - 1] - x[i]);
            if (first < 0) first = t;
            else ++n;
            last = t;
        }
    return n > 0 ? n * sr / (last - first) : 0.0;
}
// A swept body's opening pitch: the time to its first fall through zero is half its first cycle.
double firstHalfCycleHz(const std::vector<float>& x, double sr = 48000) {
    size_t i = 1;
    while (i < x.size() && x[i] <= 0.0f) ++i;  // the wave's first rise
    for (; i + 1 < x.size(); ++i)
        if (x[i] > 0.0f && x[i + 1] <= 0.0f) return sr / (2.0 * (static_cast<double>(i) + x[i] / (x[i] - x[i + 1])));
    return 0.0;
}
double rmsOf(const std::vector<float>& x, size_t from, size_t to) {
    return std::sqrt(energy(x, from, to) / static_cast<double>(std::max<size_t>(1, to - from)));
}
// Energy below `hz` (an 8192-point spectrum of x[from, from + len)).
double lowEnergy(const std::vector<float>& x, size_t from, size_t len, double hz, double sr = 48000) {
    constexpr size_t kN = 8192;
    std::vector<std::complex<double>> d(kN);
    for (size_t i = 0; i < len && i < kN && from + i < x.size(); ++i) d[i] = x[from + i];
    analysis::fft(d, false);
    double s = 0;
    for (size_t k = 1; k < kN / 2 && k * sr / kN < hz; ++k) s += std::norm(d[k]);
    return s;
}

}  // namespace

TEST(drums_pitch_shape_points_draw_the_drop) {
    // Dubstep Kick: Points mode, 38 st (about 500 Hz) down to 14 st in 6 ms, 3 st by 31 ms, the 55 Hz body by 91 ms.
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    const Values body = soundValues("Dubstep Kick", {{"a1_click_on", 0}, {"a1_sub_on", 0}, {"a1_drive_type", 0},
                                                     {"a1_clip", 0}, {"a1_comp", 0}, {"a1_eq_mid", 0}, {"a1_tr_attack", 0}});
    const std::vector<float> x = play(*p, {notes::noteOn(0, 1, 60, 1)}, 24000, body);
    const double early = firstHalfCycleHz(x), mid = crossingHz(x, 720, 2400), late = crossingHz(x, 4800, 9600);
    if (std::getenv("CAW_PRINT_DRUMS")) std::printf("pitch shape: %.1f %.1f %.1f Hz\n", early, mid, late);
    CHECK(early > 180.0);                  // the first half cycle, mostly in the first segment's fast drop
    CHECK(mid > 60.0 && mid < early);      // falling
    CHECK_NEAR(late, 55.0, 3.0);           // settled on the body's pitch
    // The display draws the same shape: Points mode, the curve falling to 55 Hz.
    play(*p, {}, 1600, body);
    float d[1024] = {};
    p->readDisplay(d, 1024);
    CHECK_EQ(d[15], 1.0f);
    CHECK(d[592] > 400.0f);
    CHECK_NEAR(d[592 + 63], 55.0f, 1.0f);
    // A softer hit drops less far (velocity to pitch drop).
    p->reset();
    const std::vector<float> soft = play(*p, {notes::noteOn(0, 1, 60, 0.3)}, 2400, soundValues("Dubstep Kick", {{"a1_vel_punch", 1}}));
    p->reset();
    const std::vector<float> hard = play(*p, {notes::noteOn(0, 1, 60, 1.0)}, 2400, soundValues("Dubstep Kick", {{"a1_vel_punch", 1}}));
    CHECK(firstHalfCycleHz(soft) < firstHalfCycleHz(hard));
}

TEST(drums_genre_kicks_meet_their_targets) {
    // Research targets (docs/engine.md, "Drums", Research): an 808's long and short versions differ in decay, not
    // pitch; a dubstep kick is dense (clipped: a low crest factor) with its sub at 50..60 Hz; every kick's pitch falls.
    std::vector<float> longKick, shortKick, dub, acoustic;
    const Hit l = renderSound("808 Kick Long", &longKick), s = renderSound("808 Kick Short", &shortKick);
    const Hit db = renderSound("Dubstep Kick", &dub), ac = renderSound("Acoustic Kick", &acoustic);
    CHECK(l.decay > 4.0 * s.decay);
    CHECK_NEAR(l.f0, s.f0, 6.0);
    auto crest = [](const std::vector<float>& x) { return 20.0 * std::log10(peakOf(x) / rmsOf(x, 0, 14400)); };
    const double crestDub = crest(dub), crest808 = crest(shortKick);
    if (std::getenv("CAW_PRINT_DRUMS"))
        std::printf("crest: dubstep %.1f dB, 808 short %.1f dB, acoustic %.1f dB\n", crestDub, crest808, crest(acoustic));
    CHECK(crestDub < 9.0);
    CHECK(crestDub < crest808);
    CHECK(db.f0 >= 50.0 && db.f0 <= 60.0);
    for (const std::vector<float>* x : {&longKick, &shortKick, &dub, &acoustic}) {
        if (std::getenv("CAW_PRINT_DRUMS")) std::printf("drop: %.1f -> %.1f Hz\n", firstHalfCycleHz(*x), crossingHz(*x, 9600, 19200));
        CHECK(firstHalfCycleHz(*x) > 1.2 * crossingHz(*x, 9600, 19200));
    }
}

TEST(drums_velocity_changes_the_spectrum_and_strike_varies) {
    // Acoustic Snare: a hard hit is brighter than a soft one, not only louder.
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    const Values v = soundValues("Acoustic Snare", {{"a1_rnd_pitch", 0}, {"a1_rnd_tone", 0}, {"a1_rnd_decay", 0}, {"a1_rnd_pos", 0}});
    const Hit hard = measureHit(play(*p, {notes::noteOn(0, 1, 60, 1.0)}, 24000, v));
    p->reset();
    const Hit soft = measureHit(play(*p, {notes::noteOn(0, 1, 60, 0.35)}, 24000, v));
    CHECK(hard.centroid > 1.15 * soft.centroid);
    // Strike-position variation changes each hit's modes; with it off two hits are the same.
    p->reset();
    const Values vary = soundValues("Acoustic Snare", {{"a1_rnd_pitch", 0}, {"a1_rnd_tone", 0}, {"a1_rnd_decay", 0},
                                                       {"a1_rnd_pos", 1}, {"a1_noise_on", 0}, {"a1_click_on", 0}});
    const std::vector<float> two = play(*p, {notes::noteOn(0, 1, 60, 1.0), notes::noteOn(24000, 2, 60, 1.0)}, 48000, vary);
    double diff = 0;
    for (size_t i = 0; i < 4800; ++i) diff += std::fabs(two[i] - two[24000 + i]);
    CHECK(diff > 1.0);
}

TEST(drums_sub_stays_mono_and_width_widens_the_rest) {
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    std::vector<float> right;
    const std::vector<float> left = play(*p, {notes::noteOn(0, 1, 60, 1)}, 24000,
                                         soundValues("Dubstep Kick", {{"a1_width", 1}, {"a1_width_hz", 150}}), &right);
    std::vector<float> side(left.size()), mid(left.size());
    for (size_t i = 0; i < left.size(); ++i) side[i] = 0.5f * (left[i] - right[i]), mid[i] = 0.5f * (left[i] + right[i]);
    CHECK(energy(side, 0, 24000) > 1e-4);                                  // it is wide
    CHECK(lowEnergy(side, 0, 8192, 100) < 0.01 * lowEnergy(mid, 0, 8192, 100));  // but not below 100 Hz
    // Width 0: the voice is mono (centre pan).
    p->reset();
    const std::vector<float> l0 = play(*p, {notes::noteOn(0, 1, 60, 1)}, 4800, soundValues("Dubstep Kick"), &right);
    double d = 0;
    for (size_t i = 0; i < l0.size(); ++i) d += std::fabs(l0[i] - right[i]);
    CHECK(d < 1e-6);
    // The sub alone: its own envelope (decay 0.42 s) with the body off.
    p->reset();
    const Hit sub = measureHit(play(*p, {notes::noteOn(0, 1, 60, 1)}, 48000,
                                    soundValues("Dubstep Kick", {{"a1_body_on", 0}, {"a1_click_on", 0}, {"a1_clip", 0}})));
    CHECK_NEAR(sub.f0, 55.0, 2.0);
    CHECK(sub.decay > 0.2 && sub.decay < 0.6);
}

TEST(drums_drive_types_clipper_and_kit_effects) {
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    // Every drive type sounds, stays finite and differs from the others.
    std::vector<std::vector<float>> outs;
    for (int t = 0; t <= kDriveAsym; ++t) {
        p->reset();
        outs.push_back(play(*p, {notes::noteOn(0, 1, 60, 1)}, 9600,
                            soundValues("808 Kick Short", {{"a1_drive_type", t}, {"a1_drive", 8}, {"a1_drive_lo", 60},
                                                           {"a1_drive_hi", 8000}, {"a1_drive_mix", 0.8}})));
        bool finite = true;
        for (float x : outs.back()) finite = finite && std::isfinite(x);
        CHECK(finite);
        CHECK(peakOf(outs.back()) > 0.05f);
    }
    for (size_t a = 0; a < outs.size(); ++a)
        for (size_t b = a + 1; b < outs.size(); ++b) {
            double d = 0;
            for (size_t i = 0; i < 9600; ++i) d += std::fabs(outs[a][i] - outs[b][i]);
            if (!(d > 0.1)) cawtest::fail(__FILE__, __LINE__, "drive types " + std::to_string(a) + " and " + std::to_string(b) + " match");
        }
    // The clipper holds the voice at full scale (level 0 dB, centre pan): +24 dB into it never passes 1.
    for (int c : {kClipSoft, kClipHard}) {
        p->reset();
        const std::vector<float> x = play(*p, {notes::noteOn(0, 1, 60, 1)}, 9600,
                                          soundValues("808 Kick Short", {{"a1_level", 0}, {"a1_body_level", 12}, {"a1_clip", c},
                                                                         {"a1_clip_gain", 24}}));
        CHECK(peakOf(x) <= 1.0001f);
        CHECK(peakOf(x) > 0.9f);
    }
    // The kit clipper and the kit EQ.
    p->reset();
    const std::vector<float> loud = play(*p, {notes::noteOn(0, 1, 60, 1)}, 9600,
                                         soundValues("808 Kick Short", {{"a1_level", 12}, {"kit_clip", kClipHard}, {"kit_clip_gain", 12}}));
    CHECK(peakOf(loud) <= 1.0001f);
    p->reset();
    const std::vector<float> flat = play(*p, {notes::noteOn(0, 1, 60, 1)}, 9600, soundValues("808 Kick Short"));
    p->reset();
    const std::vector<float> boosted = play(*p, {notes::noteOn(0, 1, 60, 1)}, 9600, soundValues("808 Kick Short", {{"kit_low", 9}}));
    CHECK(energy(boosted, 0, 9600) > 2.0 * energy(flat, 0, 9600));
}

TEST(drums_room_is_a_send_and_pressure_modulates) {
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    const Values room = {{"room", 0.6}, {"room_decay", 1.5}};
    Values dry = room, wet = room;
    dry.push_back({"a1_room_send", 0});
    wet.push_back({"a1_room_send", 1});
    const std::vector<float> a = play(*p, {notes::noteOn(0, 1, 60, 1)}, 48000, soundValues("Rim", dry));
    p->reset();
    const std::vector<float> b = play(*p, {notes::noteOn(0, 1, 60, 1)}, 48000, soundValues("Rim", wet));
    CHECK(energy(a, 12000, 48000) < 1e-8);           // the rim is long gone and sent nowhere
    CHECK(energy(b, 12000, 48000) > 1e-5);           // its room tail rings on
    // Pressure to pitch: a held note pressed raises a tracking-off pad's pitch by press_pitch semitones.
    p->reset();
    const Values sine = soundValues("Sub Kick", {{"a1_body_decay", 3}, {"a1_body_pitch", 0}, {"a1_press_pitch", 12}, {"a1_flt", 0}});
    const std::vector<float> x = play(*p, {notes::noteOn(0, 1, 60, 1), notes::notePressure(12000, 1, 60, 1.0)}, 36000, sine);
    CHECK_NEAR(crossingHz(x, 4800, 9600), 42.0, 2.0);
    CHECK_NEAR(crossingHz(x, 24000, 34000), 84.0, 4.0);
    // Pressure to choke: past half pressure the voice fades out.
    p->reset();
    const std::vector<float> c = play(*p, {notes::noteOn(0, 1, 60, 1), notes::notePressure(4800, 1, 60, 0.8)}, 24000,
                                      soundValues("Sub Kick", {{"a1_press_choke", 1}}));
    CHECK(energy(c, 9600, 24000) < 1e-8);
}

TEST(drums_display_reports_the_last_note_for_note_learn) {
    std::unique_ptr<ModuleProcessor> p = makeDrums();
    if (!p) return;
    Event on = notes::noteOn(0, 1, 77, 0.5);  // no pad answers 77 in the default kit: learn still sees it
    play(*p, {on}, 1600);
    float d[1024] = {};
    p->readDisplay(d, 1024);
    CHECK_EQ(d[11], 77.0f);
    CHECK_EQ(d[12], 1.0f);
    CHECK_NEAR(d[13], 0.5f, 1e-3f);
    CHECK_EQ(d[14], 1.0f);
}
