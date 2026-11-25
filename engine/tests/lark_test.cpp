// Chirp (1.1.0): detection accuracy, correction to scale, speed, Keep vibrato, MIDI target, formant, latency, block sizes, NaN, presets, display, the clip editor's analyse and render round trip and C API, references.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "builtin_fx_lark.h"
#include "caw.h"
#include "caw/instrument.hpp"
#include "component_chain.h"
#include "fx_modes_harness.h"
#include "lark_dsp.h"
#include "lark_editor.h"
#include "tolerance.h"

using namespace modes_test;

namespace {

constexpr const char* kLark = "org.caw.pitchfix";
constexpr double kRate = 48000.0;

double cents(double hz, double ref) { return 1200.0 * std::log2(hz / ref); }

// A voice-like tone: harmonics (1/k, in cosine phase: a pulse a period) under three formants, its pitch `f0(t)` in Hz, plus optional noise.
template <class F>
Stereo voice(F f0, size_t frames, double amp = 0.3, double noise = 0.0, uint32_t seed = 11) {
    Stereo s = silence(frames);
    double phase = 0;
    auto env = [](double f) {
        auto res = [&](double c, double w) { return 1.0 / (1.0 + ((f - c) / w) * ((f - c) / w)); };
        return res(700, 150) + 0.6 * res(1200, 200) + 0.3 * res(2600, 300) + 0.05;
    };
    for (size_t i = 0; i < frames; ++i) {
        const double hz = f0(i / kRate);
        phase += hz / kRate;
        phase -= std::floor(phase);
        double v = 0;
        for (int k = 1; k * hz < 7000; ++k) v += env(k * hz) * std::cos(2 * modes_test::kPi * k * phase) / k;
        double n = 0;
        if (noise > 0) {
            seed = seed * 1664525u + 1013904223u;
            n = noise * (static_cast<double>(seed >> 8) / 8388608.0 - 1.0);
        }
        s.l[i] = s.r[i] = static_cast<float>(amp * v + n);
    }
    return s;
}
Stereo steady(double hz, size_t frames, double amp = 0.3) {
    return voice([hz](double) { return hz; }, frames, amp);
}

// The detector's pitch every hop of x (0 when unvoiced), and the hop's frame.
struct Track {
    std::vector<double> hz;
    std::vector<size_t> at;
};
Track track(const std::vector<float>& x, double low = 60, double high = 1000) {
    lark::warmTables();
    lark::Detector d;
    CHECK(d.prepare(kRate));
    d.configure(low, high, false, 0.15);
    Track t;
    for (size_t i = 0; i < x.size(); ++i)
        if (d.push(x[i])) t.hz.push_back(d.result().voiced ? d.result().hz : 0.0), t.at.push_back(i);
    return t;
}
// The median pitch of the hops between two times.
double medianHz(const Track& t, double from, double to) {
    std::vector<double> v;
    for (size_t k = 0; k < t.hz.size(); ++k)
        if (t.at[k] >= from * kRate && t.at[k] < to * kRate && t.hz[k] > 0) v.push_back(t.hz[k]);
    if (v.empty()) return 0;
    std::sort(v.begin(), v.end());
    return v[v.size() / 2];
}

uint32_t latencyOf(const Values& v) {
    auto p = make(kLark, v);
    if (!p) return 0;
    const ModuleDescriptor& d = p->descriptor();
    std::vector<double> values(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        values[k] = d.parameters[k].defaultValue;
        for (const auto& [id, x] : v)
            if (d.parameters[k].id == id) values[k] = x;
    }
    const auto* var = dynamic_cast<const VariableLatency*>(p.get());
    CHECK(var != nullptr);
    return var ? var->latencyFor(values.data(), d.parameterCount) : 0;
}

Stereo runKeyed(ModuleProcessor& p, const Stereo& in, const std::vector<Event>& notes, const Values& values, uint32_t block = 64) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    const Stereo key = silence(in.size());
    Stereo out = silence(in.size());
    std::vector<Event> now;
    for (size_t start = 0; start < in.size(); start += block) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(block, in.size() - start));
        now.clear();
        for (Event e : notes)
            if (e.frame >= start && e.frame < start + n) e.frame -= static_cast<uint32_t>(start), now.push_back(e);
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        const float* kc[2] = {key.l.data() + start, key.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        const ConstChannelBufferView audioIn[2] = {{ic, 2, n}, {kc, 2, n}};
        const ChannelBufferView audioOut{oc, 2, n};
        const EventInput ev{now.data(), static_cast<uint32_t>(now.size())};
        ProcessBlock pb;
        pb.frames = n;
        pb.sampleRate = 48000;
        pb.audioIn = audioIn;
        pb.audioInCount = 2;
        pb.audioOut = &audioOut;
        pb.audioOutCount = 1;
        pb.eventIn = &ev;
        pb.eventInCount = 1;
        pb.parameters = params.data();
        pb.parameterCount = d.parameterCount;
        CHECK(p.processPorts(pb));
    }
    return out;
}

// The spectral envelope's centre of mass between 300 Hz and 5 kHz of x[from..to): its harmonics of f0's levels.
double centroid(const std::vector<float>& x, double f0, size_t from, size_t to) {
    double num = 0, den = 0;
    for (double f = f0 * std::ceil(300 / f0); f < 5000; f += f0) {
        const double w = 2 * modes_test::kPi * f / kRate, k = 2 * std::cos(w);
        double s1 = 0, s2 = 0;
        for (size_t i = from; i < to; ++i) {
            const double s = x[i] + k * s1 - s2;
            s2 = s1, s1 = s;
        }
        const double e = s1 * s1 + s2 * s2 - k * s1 * s2;
        num += f * e, den += e;
    }
    return num / den;
}

}  // namespace

// --- Detection -------------------------------------------------------------------------------------------------------

TEST(lark_detects_test_tones_within_cents) {
    for (double hz : {82.41, 110.0, 196.0, 261.63, 440.0, 659.26, 880.0}) {
        const Stereo s = steady(hz, 24000);
        const Stereo sine = modes_test::sine(hz, 0.3, 24000);
        for (const Stereo* x : {&s, &sine}) {
            const Track t = track(x->l);
            int checked = 0;
            for (size_t k = 0; k < t.hz.size(); ++k) {
                if (t.at[k] < 4800) continue;
                ++checked;
                if (!(t.hz[k] > 0 && std::fabs(cents(t.hz[k], hz)) < 2.0))
                    cawtest::fail(__FILE__, __LINE__, std::to_string(hz) + " Hz read as " + std::to_string(t.hz[k]));
            }
            CHECK(checked > 50);
        }
    }
    // Silence and white noise are unvoiced.
    Stereo n = silence(24000);
    uint32_t seed = 5;
    for (float& v : n.l) seed = seed * 1664525u + 1013904223u, v = 0.3f * (static_cast<float>(seed >> 8) / 8388608.0f - 1.0f);
    const Track tn = track(n.l);
    int voiced = 0;
    for (double h : tn.hz) voiced += h > 0;
    CHECK(voiced < static_cast<int>(tn.hz.size()) / 10);
    for (double h : track(silence(24000).l).hz) CHECK_EQ(h, 0.0);
}

TEST(lark_detects_a_sung_like_voice_with_vibrato_glide_and_noise) {
    // 1.5 s: a held 220 Hz with 5.5 Hz vibrato (+-40 cents), a glide to 330 Hz, held; noise at about 20 dB SNR.
    auto f0 = [](double t) {
        if (t < 0.6) return 220.0 * std::pow(2.0, 0.4 / 12.0 * std::sin(2 * modes_test::kPi * 5.5 * t));
        if (t < 0.8) return 220.0 * std::pow(1.5, (t - 0.6) / 0.2);
        return 330.0;
    };
    const Stereo x = voice(f0, 72000, 0.3, 0.03);
    const Track t = track(x.l);
    // Each hop's analysis is centred about 1.5 periods before its newest sample: compared with the truth then.
    std::vector<double> errs;
    int octave = 0, voiced = 0;
    for (size_t k = 0; k < t.hz.size(); ++k) {
        if (t.at[k] < 4800) continue;
        const double truth = f0(t.at[k] / kRate - 0.008);
        if (t.hz[k] <= 0) continue;
        ++voiced;
        const double e = cents(t.hz[k], truth);
        if (std::fabs(e) > 600) ++octave;
        else errs.push_back(std::fabs(e));
    }
    std::sort(errs.begin(), errs.end());
    CHECK(voiced > static_cast<int>(t.hz.size()) * 9 / 10);
    CHECK(octave * 100 < voiced);  // octave errors under 1 %
    CHECK(errs[errs.size() / 2] < 5.0);          // within 5 cents (median)
    CHECK(errs[errs.size() * 9 / 10] < 15.0);    // and the 90th percentile within 15 while it moves
    // Held: within 5 cents throughout.
    for (size_t k = 0; k < t.hz.size(); ++k)
        if (t.at[k] > 0.9 * kRate) CHECK(std::fabs(cents(t.hz[k], 330.0)) < 5.0);
}

// --- Correction ------------------------------------------------------------------------------------------------------

TEST(lark_corrects_to_the_key_and_scale) {
    // 455 Hz is 58 cents above A4: chromatically it goes to Bb4, in C major (no Bb) down to A4.
    const Stereo in = steady(455.0, 48000);
    const Stereo chroma = render(kLark, {{"speed", 0}}, in);
    CHECK(std::fabs(cents(medianHz(track(chroma.l), 0.4, 1.0), 466.16)) < 5.0);
    const Stereo major = render(kLark, {{"speed", 0}, {"scale", 1}}, in);
    CHECK(std::fabs(cents(medianHz(track(major.l), 0.4, 1.0), 440.0)) < 5.0);
    // In D major (F# and C#) 270 Hz (C#4 = 277.2 is nearer than D4) goes to C#4; in C major to C4 (261.6).
    const Stereo d = render(kLark, {{"speed", 0}, {"scale", 1}, {"key", 2}}, steady(270.0, 48000));
    CHECK(std::fabs(cents(medianHz(track(d.l), 0.4, 1.0), 277.18)) < 5.0);
    const Stereo c = render(kLark, {{"speed", 0}, {"scale", 1}}, steady(270.0, 48000));
    CHECK(std::fabs(cents(medianHz(track(c.l), 0.4, 1.0), 261.63)) < 5.0);
    // Custom notes: only E allowed: 300 Hz (D4 + 30 c) goes to E4.
    Values custom{{"speed", 0}, {"scale", 12}};
    for (const char* k : {"note_c", "note_cs", "note_d", "note_eb", "note_f", "note_fs", "note_g", "note_ab", "note_a", "note_bb", "note_b"})
        custom.emplace_back(k, 0);
    const Stereo e = render(kLark, custom, steady(300.0, 48000));
    CHECK(std::fabs(cents(medianHz(track(e.l), 0.4, 1.0), 329.63)) < 5.0);
    // Mix 0 is the dry delayed by the latency, exactly.
    const Stereo dry = render(kLark, {{"mix", 0}}, in);
    for (size_t i = 1200; i < in.size(); ++i) CHECK_EQ(dry.l[i], in.l[i - 1200]);
}

TEST(lark_converges_within_the_speed_constant) {
    // 450 Hz: 39 cents sharp of A4. With Speed 100 ms the error is mostly gone after three constants.
    const Stereo in = steady(450.0, 72000);
    const Stereo out = render(kLark, {{"speed", 100}}, in);
    const Track t = track(out.l);
    const double early = cents(medianHz(t, 0.08, 0.12), 440.0);  // under a constant in: still sharp
    const double late = cents(medianHz(t, 0.5, 1.4), 440.0);
    CHECK(early > 10.0);
    CHECK(std::fabs(late) < 3.0);
    // Speed 0 is there within a few hops.
    const Track fast = track(render(kLark, {{"speed", 0}}, in).l);
    CHECK(std::fabs(cents(medianHz(fast, 0.1, 0.2), 440.0)) < 5.0);
    // Humanize slows a held note.
    const Track human = track(render(kLark, {{"speed", 100}, {"humanize", 1}}, in).l);
    CHECK(cents(medianHz(human, 0.25, 0.3), 440.0) > cents(medianHz(t, 0.25, 0.3), 440.0) + 1.0);
}

TEST(lark_keep_vibrato_corrects_the_centre_and_keeps_the_vibrato) {
    // 445 Hz centre (20 cents sharp), 5 Hz vibrato of +-30 cents.
    auto f0 = [](double t) { return 445.0 * std::pow(2.0, 0.3 / 12.0 * std::sin(2 * modes_test::kPi * 5.0 * t)); };
    const Stereo in = voice(f0, 96000);
    auto depthAndCentre = [](const Track& t, double& centre) {
        std::vector<double> c;
        for (size_t k = 0; k < t.hz.size(); ++k)
            if (t.at[k] > 0.6 * kRate && t.hz[k] > 0) c.push_back(cents(t.hz[k], 440.0));
        double mean = 0, var = 0;
        for (double v : c) mean += v;
        mean /= c.size();
        for (double v : c) var += (v - mean) * (v - mean);
        centre = mean;
        return std::sqrt(2.0 * var / c.size());  // a sine's peak from its rms
    };
    double cIn, cKeep, cFlat;
    const double dIn = depthAndCentre(track(in.l), cIn);
    const double dKeep = depthAndCentre(track(render(kLark, {{"speed", 0}, {"keep_vibrato", 1}}, in).l), cKeep);
    const double dFlat = depthAndCentre(track(render(kLark, {{"speed", 0}, {"keep_vibrato", 0}}, in).l), cFlat);
    CHECK(dIn > 25.0);
    CHECK(std::fabs(cKeep) < 6.0);       // the centre on A4
    CHECK(dKeep > 0.75 * dIn);           // the vibrato kept
    CHECK(dFlat < 0.4 * dIn);            // without: flattened
}

TEST(lark_follows_the_key_tracks_midi_notes) {
    // 500 Hz with C5 (523.25 Hz) held on the key track: the target is the held note, not the scale's B4.
    const Stereo in = steady(500.0, 48000);
    auto p = make(kLark, {{"target", 1}, {"speed", 0}});
    if (!p) return;
    const Stereo out = runKeyed(*p, in, {notes::noteOn(0, 1, 72, 0.8)}, {{"target", 1}, {"speed", 0}});
    CHECK(std::fabs(cents(medianHz(track(out.l), 0.4, 1.0), 523.25)) < 5.0);
    // None held: the scale (chromatic: B4).
    auto q = make(kLark, {{"target", 1}, {"speed", 0}});
    const Stereo none = runKeyed(*q, in, {}, {{"target", 1}, {"speed", 0}});
    CHECK(std::fabs(cents(medianHz(track(none.l), 0.4, 1.0), 493.88)) < 5.0);
}

TEST(lark_keeps_the_formant_through_a_five_semitone_shift) {
    // A3 (220 Hz) corrected up 5 semitones to D4 by a held key note: with Formant keep the spectral envelope stays.
    const Stereo in = steady(220.0, 48000);
    const std::vector<Event> held = {notes::noteOn(0, 1, 62, 0.8)};
    auto shifted = [&](double keep) {
        const Values v{{"target", 1}, {"speed", 0}, {"formant_keep", keep}};
        auto p = make(kLark, v);
        return p ? runKeyed(*p, in, held, v) : silence(in.size());
    };
    const Stereo keep = shifted(1), follow = shifted(0);
    CHECK(std::fabs(cents(medianHz(track(keep.l), 0.4, 1.0), 293.66)) < 5.0);
    CHECK(std::fabs(cents(medianHz(track(follow.l), 0.4, 1.0), 293.66)) < 5.0);
    // The spectral envelope's centre (300 Hz..5 kHz): kept within 8 %, or moved up with the pitch (x 1.33).
    const double c0 = centroid(in.l, 220.0, 19200, 48000), ck = centroid(keep.l, 293.66, 19200, 48000), cf = centroid(follow.l, 293.66, 19200, 48000);
    CHECK(std::fabs(ck / c0 - 1.0) < 0.08);
    CHECK(cf / c0 > 1.2);
    // Formant shift alone (+5 semitones, the pitch in tune and kept) moves the envelope up as far.
    const Stereo f5 = render(kLark, {{"formant", 5}, {"speed", 0}}, in);
    CHECK(std::fabs(cents(medianHz(track(f5.l), 0.4, 1.0), 220.0)) < 5.0);
    CHECK(centroid(f5.l, 220.0, 19200, 48000) / c0 > 1.2);
}

// --- Latency, block sizes, bad input, presets, display ----------------------------------------------------------------

TEST(lark_reports_its_latency_and_it_is_measured) {
    CHECK_EQ(latencyOf({}), 1200u);
    CHECK_EQ(latencyOf({{"monitor", 1}}), 480u);
    for (double monitor : {0.0, 1.0}) {
        const uint32_t d = monitor ? 480 : 1200;
        // A click (unvoiced: passed through the grains) comes out exactly the latency late.
        const Stereo out = render(kLark, {{"monitor", monitor}}, click(9600, 2000));
        size_t at = 0;
        for (size_t i = 0; i < out.size(); ++i)
            if (std::fabs(out.l[i]) > std::fabs(out.l[at])) at = i;
        CHECK_EQ(at, 2000u + d);
        // An in-tune voice: the output matches the input best at the latency.
        const Stereo in = steady(440.0, 48000);
        const Stereo v = render(kLark, {{"monitor", monitor}, {"speed", 0}}, in);
        size_t best = 0;
        double bestC = -1e30;
        for (size_t lag = d - 60; lag <= d + 60; ++lag) {
            double c = 0;
            for (size_t i = 24000; i < 46000; ++i) c += static_cast<double>(v.l[i]) * in.l[i - lag];
            if (c > bestC) bestC = c, best = lag;
        }
        CHECK(best + 2 >= d && best <= d + 2);
        // and is the input that late within -30 dB.
        double err = 0, ref = 0;
        for (size_t i = 24000; i < 46000; ++i) err += std::pow(v.l[i] - in.l[i - d], 2), ref += std::pow(in.l[i - d], 2);
        CHECK(10 * std::log10(err / ref) < -30.0);
    }
    // Unvoiced input (noise) is passed through exactly that late, to rounding.
    Stereo n = silence(24000);
    uint32_t seed = 9;
    for (size_t i = 0; i < n.size(); ++i) seed = seed * 1664525u + 1013904223u, n.l[i] = n.r[i] = 0.2f * (static_cast<float>(seed >> 8) / 8388608.0f - 1.0f);
    const Stereo out = render(kLark, {}, n);
    double e = 0;
    for (size_t i = 4800; i < n.size(); ++i) e = std::max(e, std::fabs(static_cast<double>(out.l[i]) - n.l[i - 1200]));
    CHECK(e < 1e-5);
}

TEST(lark_block_sizes_and_bad_input) {
    auto f0 = [](double t) { return 200.0 + 60.0 * std::sin(2 * modes_test::kPi * 1.3 * t); };
    const Stereo v = voice(f0, 24000, 0.3, 0.01);
    checkBlockSizes(kLark, {{"speed", 20}, {"humanize", 0.5}}, v, "lark");
    checkBlockSizes(kLark, {{"speed", 0}, {"formant", 3}, {"formant_keep", 0}, {"scale", 1}}, v, "lark formant");
    checkBlockSizes(kLark, {{"monitor", 1}, {"mix", 0.5}}, music(24000), "lark monitor");
    checkBadInput(kLark, {}, "lark");
    checkBadInput(kLark, {{"monitor", 1}, {"formant", -12}}, "lark monitor");
}

TEST(lark_has_presets_and_publishes_its_display) {
    size_t count = 0;
    const Stereo in = steady(230.0, 24000);
    for (const BuiltinPreset& preset : builtinPresets(kLark)) {
        ++count;
        CHECK(!preset.name.empty() && !preset.description.empty());
        Values values;
        CHECK(applyBuiltinPreset(kLark, preset.name, values));
        const Stereo out = render(kLark, values, in);
        if (!(finite(out) && rms(out.l, 4800) > 0.02 && peak(out.l) < 2.0))
            cawtest::fail(__FILE__, __LINE__, std::string(preset.name) + ": level " + std::to_string(rms(out.l, 4800)));
    }
    CHECK(count >= 8);
    // The display: the detected pitch, the target and the correction, and their history.
    auto p = make(kLark, {{"speed", 0}, {"scale", 1}});
    if (!p) return;
    run(*p, steady(455.0, 24000), {{"speed", 0}, {"scale", 1}});
    float d[256];
    const uint32_t n = p->readDisplay(d, 256);
    CHECK_EQ(n, 154u);
    CHECK(std::fabs(d[3] - 69.58f) < 0.05f);  // 455 Hz
    CHECK_EQ(d[4], 69.0f);                    // A4
    CHECK(std::fabs(d[5] + 0.58f) < 0.05f);   // the correction
    CHECK(std::fabs(d[7] - 25.0f) < 0.01f);   // latency ms
    CHECK_EQ(d[12 + 10], 0.0f);               // Bb is not in C major
    CHECK_EQ(d[12 + 9], 1.0f);
    CHECK_EQ(d[25], 64.0f);
    CHECK(std::fabs(d[26 + 63] - 69.58f) < 0.05f);
    CHECK(std::fabs(d[26 + 64 + 63] - 69.0f) < 0.05f);
}

// --- The clip editor -------------------------------------------------------------------------------------------------

namespace {
// Three sung notes: A3 held with drift, C4 with vibrato, E4 plain, with short breaths between.
double phraseHz(double t) {
    if (t < 0.05) return 0;
    if (t < 0.65) return 220.0 * std::pow(2.0, (0.2 - 0.4 * (t - 0.05) / 0.6) / 12.0);  // drifting flat
    if (t < 0.75) return 0;
    if (t < 1.35) return 261.63 * std::pow(2.0, 0.45 / 12.0 * std::sin(2 * modes_test::kPi * 5.5 * (t - 0.75)));
    if (t < 1.45) return 0;
    if (t < 1.95) return 329.63;
    return 0;
}
Stereo phrase() {
    const size_t frames = static_cast<size_t>(2.05 * kRate);
    Stereo s = voice([](double t) { return std::max(phraseHz(t), 100.0); }, frames, 0.3);
    for (size_t i = 0; i < frames; ++i) {
        const double t = i / kRate;
        // Silence where unvoiced, 5 ms fades.
        double g = phraseHz(t) > 0 ? 1.0 : 0.0;
        for (double edge : {0.05, 0.65, 0.75, 1.35, 1.45, 1.95})
            if (std::fabs(t - edge) < 0.005) g = std::min(g, std::fabs(t - edge) / 0.005);
        s.l[i] *= static_cast<float>(g);
        s.r[i] = 0.8f * s.l[i];
    }
    return s;
}
lark::Analysis analyse(const Stereo& s) {
    lark::Analysis a;
    std::string error;
    CHECK(lark::analyse(s.l.data(), s.r.data(), static_cast<int64_t>(s.size()), kRate, {}, a, error));
    return a;
}
Stereo renderEdits(const lark::Analysis& a, const Stereo& s, const std::vector<lark::NoteEdit>& e) {
    Stereo out = silence(s.size());
    std::string error;
    CHECK(lark::render(a, s.l.data(), s.r.data(), static_cast<int64_t>(s.size()), e, out.l.data(), out.r.data(), error));
    if (!error.empty()) cawtest::fail(__FILE__, __LINE__, error);
    return out;
}
}  // namespace

TEST(lark_editor_finds_the_notes_their_drift_and_vibrato) {
    const Stereo s = phrase();
    const lark::Analysis a = analyse(s);
    CHECK_EQ(a.notes.size(), 3u);
    if (a.notes.size() != 3) return;
    const double want[] = {57.0, 60.0, 64.0}, starts[] = {0.05, 0.75, 1.45}, ends[] = {0.65, 1.35, 1.95};
    for (int k = 0; k < 3; ++k) {
        CHECK(std::fabs(a.notes[k].pitch - want[k]) < 0.06);
        CHECK(std::fabs(a.notes[k].start / kRate - starts[k]) < 0.02);
        CHECK(std::fabs(a.notes[k].end / kRate - ends[k]) < 0.02);
    }
    CHECK(a.notes[0].driftCents > 6.0);
    CHECK(a.notes[0].vibratoRate == 0.0);
    CHECK(std::fabs(a.notes[1].vibratoRate - 5.5) < 0.8);
    CHECK(std::fabs(a.notes[1].vibratoCents - 45.0) < 12.0);
    CHECK(a.notes[2].driftCents < 3.0 && a.notes[2].vibratoCents < 8.0);
    // The same audio analyses the same, bit for bit.
    const lark::Analysis b = analyse(s);
    CHECK(a.midi == b.midi && a.notes.size() == b.notes.size());
    // A clip pass is bounded on silence, noise and NaN.
    Stereo bad = silence(4800);
    bad.l[10] = std::nanf("");
    bad.r[20] = INFINITY;
    const lark::Analysis c = analyse(bad);
    CHECK(c.notes.empty());
}

TEST(lark_editor_renders_edits_and_round_trips) {
    const Stereo s = phrase();
    const lark::Analysis a = analyse(s);
    if (a.notes.size() != 3) return cawtest::fail(__FILE__, __LINE__, "three notes needed");
    // No edits: the input, bit for bit.
    std::vector<lark::NoteEdit> none(3);
    const Stereo same = renderEdits(a, s, none);
    CHECK(std::memcmp(same.l.data(), s.l.data(), s.size() * 4) == 0 && std::memcmp(same.r.data(), s.r.data(), s.size() * 4) == 0);
    // Note 0 up 2 semitones: re-analysed it is 2 up; the others are the input exactly where no edit reaches.
    std::vector<lark::NoteEdit> up(3);
    up[0].pitch = 2.0;
    const Stereo u = renderEdits(a, s, up);
    const lark::Analysis au = analyse(u);
    CHECK_EQ(au.notes.size(), 3u);
    if (au.notes.size() == 3) {
        CHECK(std::fabs(au.notes[0].pitch - 59.0) < 0.06);
        CHECK(std::fabs(au.notes[1].pitch - a.notes[1].pitch) < 0.02);
        CHECK(std::fabs(au.notes[0].driftCents - a.notes[0].driftCents) < 4.0);  // the drift kept
    }
    for (size_t i = static_cast<size_t>(1.0 * kRate); i < s.size(); ++i) CHECK_EQ(u.l[i], s.l[i]);
    CHECK(std::fabs(db(rms(u.l, 4800, 28800)) - db(rms(s.l, 4800, 28800))) < 1.5);  // level kept
    // Drift flattened on note 0, vibrato off on note 1.
    std::vector<lark::NoteEdit> flat(3);
    flat[0].drift = 0.0;
    flat[1].vibrato = 0.0;
    const lark::Analysis af = analyse(renderEdits(a, s, flat));
    if (af.notes.size() == 3) {
        CHECK(af.notes[0].driftCents < 0.4 * a.notes[0].driftCents);
        CHECK(af.notes[1].vibratoCents < 0.3 * a.notes[1].vibratoCents);
        CHECK(std::fabs(af.notes[1].pitch - a.notes[1].pitch) < 0.06);
    } else {
        cawtest::fail(__FILE__, __LINE__, "flattened: " + std::to_string(af.notes.size()) + " notes");
    }
    // Note 1 moved 50 ms later: its start moves by that, to a hop.
    std::vector<lark::NoteEdit> moved(3);
    moved[1].timeFrames = 2400;
    const lark::Analysis am = analyse(renderEdits(a, s, moved));
    // An edit that changes next to nothing re-synthesises notes 1 and 2 (TD-PSOLA from the original): within -60 dB.
    {
        std::vector<lark::NoteEdit> g(3);
        g[1].gainDb = g[2].gainDb = 0.001;
        const Stereo gg = renderEdits(a, s, g);
        double e = 0, r = 0;
        for (size_t i = static_cast<size_t>(0.8 * kRate); i < static_cast<size_t>(1.9 * kRate); ++i)
            e += std::pow(gg.l[i] - s.l[i], 2), r += std::pow(s.l[i], 2);
        CHECK(10 * std::log10(e / r) < -60.0);
    }
    if (am.notes.size() == 3) {
        CHECK(std::llabs(am.notes[1].start - a.notes[1].start - 2400) <= static_cast<long long>(a.hopFrames));
        CHECK(std::fabs(am.notes[1].pitch - a.notes[1].pitch) < 0.06);
    } else {
        cawtest::fail(__FILE__, __LINE__, "moved: " + std::to_string(am.notes.size()) + " notes");
    }
    // Formant follow off and a gain: finite, deterministic.
    std::vector<lark::NoteEdit> many(3);
    many[2].pitch = -3, many[2].formantKeep = false, many[2].gainDb = -6, many[2].stretch = 0.8, many[1].formant = 4;
    const Stereo m1 = renderEdits(a, s, many), m2 = renderEdits(a, s, many);
    CHECK(finite(m1));
    CHECK(std::memcmp(m1.l.data(), m2.l.data(), s.size() * 4) == 0);
}

TEST(lark_editor_c_api_checks_its_input) {
    const Stereo s = phrase();
    const int64_t n = static_cast<int64_t>(s.size());
    CawPitchClip* clip = nullptr;
    char* r = caw_pitch_clip_analyse(s.l.data(), s.r.data(), n, 48000, "{\"low_hz\":60}", &clip);
    CHECK(clip != nullptr);
    CHECK(std::string(r).find("\"ok\":true") != std::string::npos);
    CHECK(std::string(r).find("\"notes\":[{\"start\":") != std::string::npos);
    caw_free(r);
    if (!clip) return;
    const int64_t hops = caw_pitch_clip_curve(clip, nullptr, nullptr, nullptr, 0);
    CHECK(hops > 300);
    std::vector<float> midi(static_cast<size_t>(hops));
    CHECK_EQ(caw_pitch_clip_curve(clip, midi.data(), nullptr, nullptr, hops), hops);
    CHECK(std::fabs(midi[static_cast<size_t>(1.7 * 48000 / 256)] - 64.0f) < 0.06f);
    Stereo out = silence(s.size());
    r = caw_pitch_clip_render(clip, s.l.data(), s.r.data(), n, "{\"edits\":[{\"note\":2,\"pitch\":-1,\"formant_keep\":true}]}",
                              out.l.data(), out.r.data());
    CHECK(std::string(r).find("\"ok\":true") != std::string::npos && std::string(r).find("\"notes_edited\":1") != std::string::npos);
    caw_free(r);
    const lark::Analysis a = analyse(out);
    if (a.notes.size() == 3) CHECK(std::fabs(a.notes[2].pitch - 63.0) < 0.06);
    // Refused, naming the problem.
    struct Bad {
        const char* json;
        const char* says;
    } bad[] = {{"{\"edits\":[{\"note\":7}]}", "note"},
               {"{\"edits\":[{\"note\":0},{\"note\":0}]}", "twice"},
               {"{\"edits\":[{\"note\":0,\"pich\":1}]}", "pich"},
               {"{\"edits\":[{\"note\":0,\"pitch\":40}]}", "pitch"},
               {"{\"edits\":[{\"note\":0,\"formant_keep\":1}]}", "formant_keep"},
               {"{\"edits\":5}", "array"},
               {"[1]", "object"},
               {"{\"edits\":[", "edits"}};
    for (const Bad& b : bad) {
        r = caw_pitch_clip_render(clip, s.l.data(), s.r.data(), n, b.json, out.l.data(), out.r.data());
        const std::string got(r);
        caw_free(r);
        if (got.find("\"ok\":false") == std::string::npos || got.find(b.says) == std::string::npos)
            cawtest::fail(__FILE__, __LINE__, std::string(b.json) + " -> " + got);
    }
    // Another clip's audio is refused.
    Stereo other = s;
    other.l[100] += 0.01f;
    r = caw_pitch_clip_render(clip, other.l.data(), other.r.data(), n, nullptr, out.l.data(), out.r.data());
    CHECK(std::string(r).find("not the analysed clip") != std::string::npos);
    caw_free(r);
    caw_pitch_clip_free(clip);
    // Bad analysis input.
    CawPitchClip* none = nullptr;
    for (const char* opts : {"{\"low_hz\":10}", "{\"lowhz\":60}", "{\"low_hz\":300,\"high_hz\":350}"}) {
        r = caw_pitch_clip_analyse(s.l.data(), nullptr, n, 48000, opts, &none);
        CHECK(none == nullptr && std::string(r).find("\"ok\":false") != std::string::npos);
        caw_free(r);
    }
    r = caw_pitch_clip_analyse(s.l.data(), nullptr, n, 1000, nullptr, &none);
    CHECK(none == nullptr && std::string(r).find("sample_rate") != std::string::npos);
    caw_free(r);
    r = caw_pitch_clip_analyse(s.l.data(), nullptr, 0, 48000, nullptr, &none);
    CHECK(none == nullptr);
    caw_free(r);
}

TEST(lark_matches_its_reference_renders) {
    cawtest::References refs("lark");
    auto f0 = [](double t) { return 230.0 * std::pow(2.0, (0.3 * std::sin(2 * modes_test::kPi * 5 * t) + 2.0 * (t > 0.5)) / 12.0); };
    const Stereo in = voice(f0, 48000, 0.3, 0.005);
    const Stereo live = render(kLark, {{"scale", 1}, {"speed", 30}, {"humanize", 0.3}}, in);
    // Chaotic: the detector's threshold decisions may move a grain on a 1-ulp difference (a Debug build).
    CHECK_REFERENCE(refs, "pitchfix_major", (cawtest::Audio{live.l, live.r}), cawtest::Class::Chaotic);
    const Stereo hard = render(kLark, {{"speed", 0}, {"keep_vibrato", 0}, {"formant", -3}}, in);
    CHECK_REFERENCE(refs, "pitchfix_hard_formant", (cawtest::Audio{hard.l, hard.r}), cawtest::Class::Chaotic);
    const Stereo s = phrase();
    const lark::Analysis a = analyse(s);
    if (a.notes.size() == 3) {
        std::vector<lark::NoteEdit> e(3);
        e[0].pitch = 1, e[1].vibrato = 0.3, e[2].pitch = -2, e[2].timeFrames = -1200;
        const Stereo ed = renderEdits(a, s, e);
        CHECK_REFERENCE(refs, "pitch_clip_edits", (cawtest::Audio{ed.l, ed.r}), cawtest::Class::Chaotic);
    }
}
