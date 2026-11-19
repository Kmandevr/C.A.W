// 1.1.0's voice devices: Glint (Exciter, Bass), Soar's Harmonizer and Octaver, Mimic: their sound, block sizes, NaN, presets, references.
#include <cmath>
#include <string>
#include <vector>

#include "builtin_fx_voice.h"
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

TEST(voice_devices_match_their_reference_renders) {
    const Stereo in = music(48000);
    cawtest::References refs("fx_voice");
    const Stereo ex = render("org.caw.exciter", {{"variant", 0}, {"freq", 3000}, {"amount", 0.6}}, in);
    CHECK_REFERENCE(refs, "glint_exciter", (cawtest::Audio{ex.l, ex.r}), cawtest::Class::Stable);
    const Stereo bass = render("org.caw.exciter", {{"variant", 1}, {"freq", 120}, {"amount", 0.6}, {"cut", 0.5}}, in);
    CHECK_REFERENCE(refs, "glint_bass", (cawtest::Audio{bass.l, bass.r}), cawtest::Class::Stable);
}
