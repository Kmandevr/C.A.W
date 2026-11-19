// 1.1.0's voice devices: Glint (Exciter, Bass), Soar's Harmonizer and Octaver, Mimic: their sound, block sizes, NaN, presets, references.
#include <cmath>
#include <string>
#include <vector>

#include "builtin_fx_voice.h"
#include "component_chain.h"
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

TEST(voice_devices_match_their_reference_renders) {
    const Stereo in = music(48000);
    cawtest::References refs("fx_voice");
    const Stereo ex = render("org.caw.exciter", {{"variant", 0}, {"freq", 3000}, {"amount", 0.6}}, in);
    CHECK_REFERENCE(refs, "glint_exciter", (cawtest::Audio{ex.l, ex.r}), cawtest::Class::Stable);
    const Stereo bass = render("org.caw.exciter", {{"variant", 1}, {"freq", 120}, {"amount", 0.6}, {"cut", 0.5}}, in);
    CHECK_REFERENCE(refs, "glint_bass", (cawtest::Audio{bass.l, bass.r}), cawtest::Class::Stable);
    const Stereo harm = render("org.caw.shift", {{"variant", 2}, {"voices", 3}, {"key", 9}, {"scale", 1}}, in);
    CHECK_REFERENCE(refs, "soar_harmonizer", (cawtest::Audio{harm.l, harm.r}), cawtest::Class::Stable);
    const Stereo oct = render("org.caw.shift", {{"variant", 3}, {"up", 0.4}}, in);
    CHECK_REFERENCE(refs, "soar_octaver", (cawtest::Audio{oct.l, oct.r}), cawtest::Class::Stable);
}
