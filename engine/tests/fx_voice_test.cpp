// 1.1.0's voice devices: Glint (Exciter, Bass), Soar's Harmonizer and Octaver, Mimic: their sound, block sizes, NaN, presets, references.
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "builtin_fx_voice.h"
#include "component_chain.h"
#include "caw/instrument.hpp"
#include "fx_modes_harness.h"
#include "tolerance.h"

using namespace modes_test;

namespace {

// The level of `hz` in x[from..to) (a Goertzel bin, as a sine's amplitude).
double toneAt(const std::vector<float>& x, double hz, size_t from, size_t to) {
    const double w = 2 * kPi * hz / 48000.0, c = 2 * std::cos(w);
    double s1 = 0, s2 = 0;
    for (size_t i = from; i < to; ++i) {
        const double s = x[i] + c * s1 - s2;
        s2 = s1, s1 = s;
    }
    const double re = s1 - s2 * std::cos(w), im = s2 * std::sin(w);
    return 2.0 * std::sqrt(re * re + im * im) / static_cast<double>(to - from);
}

}  // namespace

// --- Glint -----------------------------------------------------------------------------------------------------------

TEST(glint_has_exciter_and_bass_with_presets) {
    CHECK(checkVariant("org.caw.exciter", 0, "Exciter") != nullptr);
    CHECK(checkVariant("org.caw.exciter", 1, "Bass") != nullptr);
    checkPresets("org.caw.exciter", 0, 8, music(24000));
    checkPresets("org.caw.exciter", 1, 8, music(24000));
}

TEST(glint_exciter_adds_the_highs_harmonics_by_character) {
    const Stereo in = sine(4000, 0.3, 24000);
    const Stereo even = render("org.caw.exciter", {{"variant", 0}, {"freq", 2000}, {"amount", 0.5}, {"character", 0}}, in);
    const Stereo odd = render("org.caw.exciter", {{"variant", 0}, {"freq", 2000}, {"amount", 0.5}, {"character", 1}}, in);
    const Stereo off = render("org.caw.exciter", {{"variant", 0}, {"amount", 0}}, in);
    CHECK(toneAt(off.l, 8000, 4800, 24000) < 1e-4);
    CHECK(toneAt(even.l, 8000, 4800, 24000) > 0.05);   // 2nd harmonic
    CHECK(toneAt(even.l, 12000, 4800, 24000) < 0.01);
    CHECK(toneAt(odd.l, 12000, 4800, 24000) > 0.05);   // 3rd harmonic
    CHECK(toneAt(odd.l, 8000, 4800, 24000) < 0.01);
    CHECK(std::fabs(toneAt(even.l, 4000, 4800, 24000) - 0.3) < 0.05);  // the dry passes
    // The harmonics follow the level in a straight line: 20 dB quieter in, 20 dB quieter harmonics.
    const Stereo quiet = render("org.caw.exciter", {{"variant", 0}, {"freq", 2000}, {"amount", 0.5}, {"character", 0}},
                                sine(4000, 0.03, 24000));
    CHECK(std::fabs(db(toneAt(quiet.l, 8000, 4800, 24000)) - db(toneAt(even.l, 8000, 4800, 24000)) + 20.0) < 1.5);
}

TEST(glint_bass_adds_the_lows_harmonics_and_cuts_lows) {
    const Stereo in = sine(55, 0.4, 48000);
    const Stereo out = render("org.caw.exciter", {{"variant", 1}, {"freq", 80}, {"amount", 0.6}, {"character", 0}}, in);
    CHECK(toneAt(out.l, 110, 9600, 48000) > 0.05);
    const Stereo cut = render("org.caw.exciter", {{"variant", 1}, {"freq", 120}, {"amount", 0.6}, {"cut", 1}}, in);
    CHECK(toneAt(cut.l, 55, 9600, 48000) < 0.5 * toneAt(out.l, 55, 9600, 48000));
    const Stereo off = render("org.caw.exciter", {{"variant", 1}, {"amount", 0}}, in);
    CHECK(toneAt(off.l, 110, 9600, 48000) < 1e-4);
}

TEST(glint_block_sizes_and_bad_input) {
    for (double v : {0.0, 1.0}) {
        checkBlockSizes("org.caw.exciter", {{"variant", v}, {"amount", 0.7}, {"density", 1}}, music(9000), "glint");
        checkBadInput("org.caw.exciter", {{"variant", v}, {"amount", 0.7}}, "glint", 48000);
    }
}

// --- Soar: Harmonizer and Octaver ------------------------------------------------------------------------------------

namespace {
// A band-limited saw (16 harmonics) at `hz`, a voice-like test tone.
Stereo saw(double hz, double amp, size_t frames) {
    Stereo s = silence(frames);
    for (size_t i = 0; i < frames; ++i) {
        double v = 0;
        for (int k = 1; k <= 16 && k * hz < 20000; ++k) v += std::sin(2 * kPi * k * hz * i / 48000.0) / k;
        s.l[i] = s.r[i] = static_cast<float>(amp * 0.5 * v);
    }
    return s;
}
Stereo add(Stereo a, const Stereo& b) {
    for (size_t i = 0; i < a.size(); ++i) a.l[i] += b.l[i], a.r[i] += b.r[i];
    return a;
}
}  // namespace

TEST(soar_appends_harmonizer_and_octaver_with_presets) {
    const ModuleDescriptor* h = checkVariant("org.caw.shift", 2, "Harmonizer");
    CHECK(checkVariant("org.caw.shift", 3, "Octaver") != nullptr);
    CHECK(h != nullptr);
    checkPresets("org.caw.shift", 2, 8, saw(220, 0.4, 24000));
    checkPresets("org.caw.shift", 3, 8, sine(110, 0.4, 24000));
    // The Harmonizer reports its latency (1.5 periods of 70 Hz) per instance.
    auto p = make("org.caw.shift", {{"variant", 2}});
    const auto* v = p ? dynamic_cast<const VariableLatency*>(p.get()) : nullptr;
    CHECK(v != nullptr);
    if (v) CHECK_EQ(v->latencyFor(nullptr, 0), 1033u);
}

TEST(soar_harmonizer_sings_in_key) {
    // A3 in C major: a third above is C4 (3 semitones), a fifth above E4 (7), an octave below A2.
    const Values third{{"variant", 2}, {"voices", 1}, {"v1_degree", 2}, {"v1_pan", 0}, {"mix", 1}, {"detune", 0}};
    const Stereo a3 = render("org.caw.shift", third, saw(220, 0.4, 48000));
    CHECK(toneAt(a3.l, 261.63, 12000, 48000) > 4 * toneAt(a3.l, 220, 12000, 48000));
    CHECK(toneAt(a3.l, 261.63, 12000, 48000) > 0.02);
    // E4: a third above in C major is G4 (3 semitones); in E major it is G#4 (4).
    const Stereo e4 = render("org.caw.shift", third, saw(329.63, 0.4, 48000));
    CHECK(toneAt(e4.l, 392.0, 12000, 48000) > 4 * toneAt(e4.l, 415.3, 12000, 48000));
    Values inE = third;
    inE.emplace_back("key", 4);
    const Stereo e4e = render("org.caw.shift", inE, saw(329.63, 0.4, 48000));
    CHECK(toneAt(e4e.l, 415.3, 12000, 48000) > 4 * toneAt(e4e.l, 392.0, 12000, 48000));
    const Stereo low = render("org.caw.shift", {{"variant", 2}, {"voices", 1}, {"v1_degree", -7}, {"mix", 1}, {"detune", 0}},
                              saw(220, 0.4, 48000));
    CHECK(toneAt(low.l, 110, 12000, 48000) > 0.02);
    // Mix 0: the dry, delayed by the latency.
    const Stereo in = saw(220, 0.4, 9600);
    const Stereo dry = render("org.caw.shift", {{"variant", 2}, {"mix", 0}}, in);
    double err = 0;
    for (size_t i = 2000; i < 9600; ++i) err = std::max(err, std::fabs(static_cast<double>(dry.l[i]) - in.l[i - 1033]));
    CHECK(err < 1e-6);
}

TEST(soar_octaver_tracks_a_sub_and_an_octave_up) {
    const Stereo e2 = sine(110, 0.4, 48000);
    const Stereo mono = render("org.caw.shift", {{"variant", 3}, {"tracking", 1}, {"dry", 0}, {"sub", 1}, {"up", 0}}, e2);
    CHECK(toneAt(mono.l, 55, 9600, 48000) > 0.15);
    CHECK(toneAt(mono.l, 55, 9600, 48000) > 4 * toneAt(mono.l, 110, 9600, 48000));
    const Stereo up = render("org.caw.shift", {{"variant", 3}, {"tracking", 1}, {"dry", 0}, {"sub", 0}, {"up", 1}}, e2);
    CHECK(toneAt(up.l, 220, 9600, 48000) > 0.15);
    const Stereo poly = render("org.caw.shift", {{"variant", 3}, {"tracking", 2}, {"dry", 0}, {"sub", 1}}, e2);
    // Poly's grains restart its phase every 60 ms, which smears a long bin: its level over 50 ms pieces.
    double level = 0, other = 0;
    for (size_t at = 9600; at + 2400 <= 48000; at += 2400) level += toneAt(poly.l, 55, at, at + 2400), other += toneAt(poly.l, 110, at, at + 2400);
    CHECK(level / 16 > 0.1);
    CHECK(level > 3 * other);
    // Auto: Mono on a single note, Poly on a chord (the display's Mono share).
    for (int chord = 0; chord < 2; ++chord) {
        auto p = make("org.caw.shift", {{"variant", 3}});
        if (!p) continue;
        Stereo in = e2;
        if (chord) in = add(add(in, sine(138.59, 0.3, 48000)), sine(164.81, 0.3, 48000));
        run(*p, in, {{"variant", 3}});
        float shown[16] = {};
        CHECK(p->readDisplay(shown, 16) >= 8u);
        if (chord) CHECK(shown[5] < 0.1f);
        else CHECK(shown[5] > 0.9f);
    }
}

TEST(soar_block_sizes_and_bad_input) {
    checkBlockSizes("org.caw.shift", {{"variant", 2}, {"voices", 4}}, music(24000), "harmonizer");
    checkBlockSizes("org.caw.shift", {{"variant", 3}, {"up", 0.5}}, music(24000), "octaver auto");
    checkBlockSizes("org.caw.shift", {{"variant", 3}, {"tracking", 2}, {"up", 0.5}}, music(9000), "octaver poly");
    checkBadInput("org.caw.shift", {{"variant", 2}, {"voices", 4}}, "harmonizer", 48000);
    checkBadInput("org.caw.shift", {{"variant", 3}, {"up", 0.5}}, "octaver", 48000);
}

// --- Mimic -----------------------------------------------------------------------------------------------------------

namespace {
// Runs a keyed effect with `key` audio and key note events (frames from the start) in blocks of `block`.
Stereo runKeyed(ModuleProcessor& p, const Stereo& in, const Stereo& key, const std::vector<Event>& notes,
                const Values& values, uint32_t block = 64) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
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
Stereo vocode(const Values& values, const Stereo& in, const Stereo& key, const std::vector<Event>& notes = {}, uint32_t block = 64) {
    auto p = make("org.caw.vocoder", values);
    return p ? runKeyed(*p, in, key, notes, values, block) : silence(in.size());
}
Stereo noise(size_t frames, double amp, uint32_t seed = 3) {
    Stereo s = silence(frames);
    for (size_t i = 0; i < frames; ++i) {
        seed = seed * 1664525u + 1013904223u;
        s.l[i] = s.r[i] = static_cast<float>(amp * (static_cast<double>(seed >> 8) / 8388608.0 - 1.0));
    }
    return s;
}
// The level of x near hz over 50 ms pieces (a short bin, so near harmonics count too).
double near(const std::vector<float>& x, double hz, size_t from = 9600, size_t to = ~size_t{0}) {
    double sum = 0;
    int pieces = 0;
    to = std::min(to, x.size());
    for (size_t at = from; at + 2400 <= to; at += 2400, ++pieces) sum += toneAt(x, hz, at, at + 2400);
    return pieces ? sum / pieces : 0.0;
}
}  // namespace

TEST(mimic_is_a_keyed_vocoder_with_presets) {
    const ModuleDescriptor* d = registry().find("org.caw.vocoder");
    CHECK(d != nullptr);
    if (!d) return;
    CHECK(ComponentChain::isKeyedEffect(*d));
    CHECK_EQ(d->latencyFrames, 0u);
    size_t count = 0;
    const Stereo voice = noise(24000, 0.3), key = saw(110, 0.4, 24000);
    for (const BuiltinPreset& preset : builtinPresets("org.caw.vocoder")) {
        ++count;
        CHECK(!preset.name.empty() && !preset.description.empty());
        Values values;
        CHECK(applyBuiltinPreset("org.caw.vocoder", preset.name, values));
        const Stereo out = vocode(values, voice, key);
        if (!finite(out) || !(rms(out.l) > 1e-3 && peak(out.l) < 4.0))
            cawtest::fail(__FILE__, __LINE__, std::string(preset.name) + ": level " + std::to_string(rms(out.l)));
    }
    CHECK(count >= 8u);
}

TEST(mimic_speaks_the_modulator_spectrum_on_the_carrier) {
    // A 1 kHz modulator on the built-in saw drone (C3, 130.8 Hz): its 8th harmonic (1046 Hz) speaks, the 23rd doesn't.
    // (The bands overlap, so a saw's stronger low harmonics leak through the neighbours: about 12-16 dB, not more.)
    const Stereo low = vocode({{"sibilance", 0}}, sine(1000, 0.3, 48000), silence(48000));
    CHECK(near(low.l, 1046.5) > 10 * near(low.l, 3009.0));
    const Stereo high = vocode({{"sibilance", 0}}, sine(3000, 0.3, 48000), silence(48000));
    CHECK(near(high.l, 3009.0) > 4 * near(high.l, 1046.5));
    // Formant +12 moves the spectrum's centre (the carrier's harmonics 400 Hz..5 kHz, weighted) up toward an octave.
    auto centre = [](const std::vector<float>& x) {
        double num = 0, den = 0;
        for (int h = 3; h * 130.81 < 5000; ++h) {
            const double a = near(x, h * 130.81);
            num += a * h * 130.81, den += a;
        }
        return den > 0 ? num / den : 0.0;
    };
    const Stereo up = vocode({{"sibilance", 0}, {"formant", 12}}, sine(1000, 0.3, 48000), silence(48000));
    CHECK(centre(up.l) > 1.4 * centre(low.l));
    const Stereo down = vocode({{"sibilance", 0}, {"formant", -12}}, sine(1000, 0.3, 48000), silence(48000));
    CHECK(centre(down.l) < 0.8 * centre(low.l));
    // The output follows the modulator's level (carrier flattening): about the input's.
    CHECK(std::fabs(db(rms(low.l, 9600)) - db(rms(sine(1000, 0.3, 48000).l))) < 6.0);
}

TEST(mimic_plays_the_key_tracks_notes_and_can_take_its_audio) {
    const Stereo voice = noise(48000, 0.3);
    // A3 (220 Hz) from the key's notes: the drone (C3) gives way.
    const std::vector<Event> a3 = {notes::noteOn(100, 1, 57, 0.8)};
    const Stereo played = vocode({{"sibilance", 0}}, voice, silence(48000), a3);
    CHECK(near(played.l, 220) > 3 * near(played.l, 130.8));
    // A chord (two ons together) sounds both notes; a note-off lets its note go.
    const std::vector<Event> chord = {notes::noteOn(100, 1, 57, 0.8), notes::noteOn(100, 2, 64, 0.8),
                                      notes::noteOff(24000, 2, 64)};
    const Stereo both = vocode({{"sibilance", 0}}, voice, silence(48000), chord);
    CHECK(near(both.l, 329.6, 4800, 24000) > 0.3 * near(both.l, 220, 4800, 24000));
    CHECK(near(both.l, 329.6, 28800) < 0.3 * near(both.l, 329.6, 4800, 24000));
    // Sidechain: the key's saw (110 Hz) is the carrier.
    const Stereo keyed = vocode({{"carrier", 1}, {"sibilance", 0}}, voice, saw(110, 0.4, 48000));
    CHECK(near(keyed.l, 110) > 3 * near(keyed.l, 130.8));
    // A silent modulator: silence, asleep.
    auto p = make("org.caw.vocoder", {});
    if (p) {
        const Stereo quiet = runKeyed(*p, silence(48000), silence(48000), {}, {});
        CHECK(peak(quiet.l) < 1e-6);
        CHECK(p->quiet());
    }
}

TEST(mimic_block_sizes_and_bad_input) {
    const Stereo voice = music(24000), key = saw(110, 0.4, 24000);
    const std::vector<Event> ev = {notes::noteOn(3000, 1, 57, 0.8), notes::noteOn(12001, 2, 62, 0.8)};
    for (const Values& v : {Values{{"unison", 3}}, Values{{"carrier", 1}, {"bands", 3}}, Values{{"wave", 2}, {"formant", -5}}}) {
        auto p = make("org.caw.vocoder", v);
        if (!p) continue;
        const Stereo want = runKeyed(*p, voice, key, ev, v, 64);
        for (uint32_t block : {1u, 37u, 512u}) {
            p->reset();
            const Stereo got = runKeyed(*p, voice, key, ev, v, block);
            if (std::memcmp(want.l.data(), got.l.data(), want.l.size() * 4) != 0 ||
                std::memcmp(want.r.data(), got.r.data(), want.r.size() * 4) != 0)
                cawtest::fail(__FILE__, __LINE__, "mimic: block " + std::to_string(block) + " differs from 64");
        }
    }
    Stereo bad = voice, badKey = key;
    bad.l[100] = std::nanf(""), bad.r[200] = INFINITY, badKey.l[300] = -INFINITY, badKey.r[400] = std::nanf("");
    for (size_t i = 5000; i < 5200; ++i) bad.l[i] = bad.r[i] = 1e-39f;
    for (const Values& v : {Values{}, Values{{"carrier", 1}}}) {
        auto p = make("org.caw.vocoder", v);
        if (!p) continue;
        const Stereo out = runKeyed(*p, bad, badKey, {}, v);
        CHECK(finite(out));
        const Stereo after = runKeyed(*p, silence(48000), silence(48000), {}, v, 512);
        CHECK(finite(after) && peak(after.l, 43200) < 1e-5 && p->quiet());
    }
}

TEST(voice_devices_match_their_reference_renders) {
    const Stereo in = music(48000);
    cawtest::References refs("fx_voice");
    const Stereo ex = render("org.caw.exciter", {{"variant", 0}, {"freq", 3000}, {"amount", 0.6}}, in);
    CHECK_REFERENCE(refs, "glint_exciter", (cawtest::Audio{ex.l, ex.r}), cawtest::Class::Stable);
    const Stereo bass = render("org.caw.exciter", {{"variant", 1}, {"freq", 120}, {"amount", 0.6}, {"cut", 0.5}}, in);
    CHECK_REFERENCE(refs, "glint_bass", (cawtest::Audio{bass.l, bass.r}), cawtest::Class::Stable);
    const Stereo harm = render("org.caw.shift", {{"variant", 2}, {"voices", 3}, {"key", 9}, {"scale", 1}}, in);
    // Chaotic: the tracker's threshold decisions move a grain by a frame on a 1-ulp difference (a Debug build).
    CHECK_REFERENCE(refs, "soar_harmonizer", (cawtest::Audio{harm.l, harm.r}), cawtest::Class::Chaotic);
    const Stereo oct = render("org.caw.shift", {{"variant", 3}, {"up", 0.4}}, in);
    CHECK_REFERENCE(refs, "soar_octaver", (cawtest::Audio{oct.l, oct.r}), cawtest::Class::Stable);
    const std::vector<Event> ev = {notes::noteOn(4800, 1, 57, 0.8), notes::noteOn(4800, 2, 60, 0.8), notes::noteOn(28800, 3, 62, 0.8)};
    const Stereo mimic = vocode({{"unison", 2}}, in, silence(in.size()), ev);
    CHECK_REFERENCE(refs, "mimic_builtin_chords", (cawtest::Audio{mimic.l, mimic.r}), cawtest::Class::Stable);
    const Stereo mimicKey = vocode({{"carrier", 1}, {"formant", 3}}, in, saw(110, 0.4, in.size()));
    CHECK_REFERENCE(refs, "mimic_sidechain", (cawtest::Audio{mimicKey.l, mimicKey.r}), cawtest::Class::Stable);
}
