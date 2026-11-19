// The Drive's 1.1.0 variants: Amp (voicings, tone stack), Pedal (types), Bands (flat split, solo, mute, Clean), the aliasing that picks oversampling, block sizes, bad input, presets, display, references.
#include <complex>
#include <cstdio>
#include <cstdlib>

#include "fx_modes_harness.h"
#include "tolerance.h"

using namespace modes_test;

namespace {

constexpr const char* kDrive = "org.caw.drive";

// The level (dB) of the `hz` component of v[from, from + n) by a single-bin DFT (Hann window).
double toneDb(const std::vector<float>& v, double hz, size_t from, size_t n) {
    std::complex<double> acc = 0;
    double wsum = 0;
    for (size_t i = 0; i < n; ++i) {
        const double w = 0.5 - 0.5 * std::cos(2 * kPi * i / n);
        acc += w * static_cast<double>(v[from + i]) * std::polar(1.0, -2 * kPi * hz * i / 48000.0);
        wsum += w;
    }
    return db(2.0 * std::abs(acc) / wsum);
}

// The aliases of a sine at f (dB against its fundamental): the energy at the folded images of its harmonics 2..30
// that land off the true harmonics, over 8192 frames after 4800.
double aliasDb(const Stereo& out, double f) {
    const size_t from = 4800, n = 8192;
    double sum = 0;
    for (int h = 2; h <= 30; ++h) {
        double a = std::fmod(h * f, 48000.0);
        if (a > 24000.0) a = 48000.0 - a;
        if (h * f < 24000.0 || std::fabs(std::fmod(a, f)) < 50.0 || std::fabs(std::fmod(a, f) - f) < 50.0 || a < 100.0) continue;
        sum += std::pow(10.0, toneDb(out.l, a, from, n) / 10);
    }
    return 10 * std::log10(std::max(sum, 1e-30)) - toneDb(out.l, f, from, n);
}

}  // namespace

TEST(drive_modes_are_appended_after_the_old_four) {
    const fx::MergedDevice* m = fx::findMergedDevice(kDrive);
    CHECK(m && m->variants.size() == 7u);
    if (!m || m->variants.size() < 7) return;
    CHECK(m->variants[3].name == "Phase");
    const ModuleDescriptor* amp = checkVariant(kDrive, 4, "Amp");
    const ModuleDescriptor* pedal = checkVariant(kDrive, 5, "Pedal");
    const ModuleDescriptor* bands = checkVariant(kDrive, 6, "Bands");
    CHECK(amp && pedal && bands);
    if (!amp || !pedal || !bands) return;
    CHECK_EQ(amp->parameterCount, 10u);
    CHECK_EQ(pedal->parameterCount, 7u);
    CHECK_EQ(bands->parameterCount, 31u);
    for (const ModuleDescriptor* d : {amp, pedal, bands}) CHECK_EQ(d->latencyFrames, 0u);
}

TEST(amp_voicings_add_gain_in_order_and_the_tone_stack_moves_its_bands) {
    // A quiet 220 Hz sine: more harmonics (the 3rd against the fundamental) from Clean to High gain.
    const Stereo in = sine(220, 0.1, 24000);
    double last = -1e9;
    for (double v = 0; v < 4; ++v) {
        const Stereo out = render(kDrive, with({{"voicing", v}, {"gain", 0.6}, {"bass", 0.5}, {"mid", 0.5}, {"treble", 0.5}, {"presence", 0}}, 4), in);
        const double h3 = toneDb(out.l, 660, 8000, 8192) - toneDb(out.l, 220, 8000, 8192);
        if (!(h3 > last - 1.0)) cawtest::fail(__FILE__, __LINE__, "voicing " + std::to_string(v) + ": 3rd at " + std::to_string(h3));
        last = std::max(last, h3);
        CHECK(finite(out));
    }
    CHECK(last > -20.0);  // High gain is well into distortion
    // Clean at low gain stays nearly linear: bass and treble move their own ends of the spectrum.
    auto band = [&](const Values& v, double hz) {
        const Stereo out = render(kDrive, with(v, 4), sine(hz, 0.02, 24000));
        return toneDb(out.l, hz, 8000, 8192);
    };
    const Values flat = {{"voicing", 0}, {"gain", 0}, {"presence", 0}};
    Values bass = flat, treble = flat;
    bass.emplace_back("bass", 1.0);
    treble.emplace_back("treble", 1.0);
    CHECK(band(bass, 100) > band(flat, 100) + 6.0);
    CHECK(std::fabs(band(bass, 4000) - band(flat, 4000)) < 1.5);
    CHECK(band(treble, 4000) > band(flat, 4000) + 6.0);
    CHECK(std::fabs(band(treble, 100) - band(flat, 100)) < 1.5);
}

TEST(pedal_types_distort_differently_and_fuzz_is_asymmetric) {
    const Stereo in = sine(200, 0.3, 24000);
    const Stereo od = render(kDrive, with({{"type", 0}, {"drive", 0.5}}, 5), in);
    const Stereo dist = render(kDrive, with({{"type", 1}, {"drive", 0.5}}, 5), in);
    const Stereo fuzz = render(kDrive, with({{"type", 2}, {"drive", 0.5}}, 5), in);
    for (const Stereo* s : {&od, &dist, &fuzz}) CHECK(finite(*s) && peak(s->l, 4800) > 0.05);
    // Distortion clips harder than overdrive (more 3rd), fuzz makes even harmonics (2nd) the others barely do.
    auto rel = [&](const Stereo& s, double hz) { return toneDb(s.l, hz, 8000, 8192) - toneDb(s.l, 200, 8000, 8192); };
    CHECK(rel(dist, 600) > rel(od, 600));
    CHECK(rel(fuzz, 400) > rel(dist, 400) + 6.0);
    // Drive 0 overdrive is near clean (a blend of the dry and a gently driven hump).
    const Stereo soft = render(kDrive, with({{"type", 0}, {"drive", 0}, {"tone", 1}}, 5), sine(200, 0.05, 24000));
    CHECK(rel(soft, 600) < -30.0);
}

TEST(oversampling_is_on_where_aliasing_is_measured_to_need_it) {
    // A 2.9 kHz sine at 0.3 through each mode at 1x and 2x (measured 2026-11-19: Clean -103/-117 dB, Crunch -45/-57,
    // Lead -21/-41, High gain -20/-40, Overdrive -44/-87, Distortion -20/-56, Fuzz -22/-59): where Auto turns 2x
    // on (Lead, High gain, Distortion, Fuzz) the aliases sit near -20 dB at 1x and 2x cuts them by 15 dB or more;
    // the others are already under -40 dB at 1x.
    constexpr double kTestHz = 2900;  // not a divisor of the rate: its harmonics fold between its harmonics
    const Stereo in = sine(kTestHz, 0.3, 16000);
    struct Case {
        double variant;
        Values v;
        bool autoOn;
    };
    const Case cases[] = {
        {4, {{"voicing", 0}, {"gain", 0.5}}, false}, {4, {{"voicing", 1}, {"gain", 0.5}}, false},
        {4, {{"voicing", 2}, {"gain", 0.7}}, true},  {4, {{"voicing", 3}, {"gain", 0.7}}, true},
        {5, {{"type", 0}, {"drive", 0.5}}, false},   {5, {{"type", 1}, {"drive", 0.7}}, true},
        {5, {{"type", 2}, {"drive", 0.7}}, true},
    };
    for (const Case& c : cases) {
        Values off = c.v, two = c.v;
        off.emplace_back("oversample", 1);
        two.emplace_back("oversample", 2);
        const double a1 = aliasDb(render(kDrive, with(off, c.variant), in), kTestHz);
        const double a2 = aliasDb(render(kDrive, with(two, c.variant), in), kTestHz);
        if (std::getenv("CAW_ALIAS_REPORT")) std::printf("ALIAS %.0f %s: 1x %.1f dB, 2x %.1f dB\n", c.variant, c.v[0].first.c_str(), a1, a2);
        if (c.autoOn && !(a2 < a1 - 15.0))
            cawtest::fail(__FILE__, __LINE__, "2x should cut the aliases: " + std::to_string(a1) + " -> " + std::to_string(a2));
        if (!c.autoOn && !(a1 < -40.0))
            cawtest::fail(__FILE__, __LINE__, "1x aliases too loud without oversampling: " + std::to_string(a1));
        // Auto is what the display says it chose.
        auto p = make(kDrive, with(c.v, c.variant));
        if (!p) return;
        run(*p, in, with(c.v, c.variant));
        float shown[64];
        const uint32_t count = p->readDisplay(shown, 64);
        CHECK_EQ(shown[count - 1], c.autoOn ? 2.0f : 1.0f);  // the last float: the factor
    }
}

TEST(bands_split_flat_and_solo_mute_and_clean_do_what_they_say) {
    // Every band Clean: the bands sum to an all-pass, so the level is flat at every frequency.
    for (double count : {0.0, 1.0, 2.0, 3.0}) {
        Values v = {{"bands", count}, {"b1_type", 0}, {"b2_type", 0}, {"b3_type", 0}, {"b4_type", 0}};
        for (double hz : {60.0, 400.0, 1000.0, 3000.0, 9000.0}) {
            const Stereo out = render(kDrive, with(v, 6), sine(hz, 0.25, 24000));
            const double got = rms(out.l, 12000) / rms(sine(hz, 0.25, 24000).l, 12000);
            if (std::fabs(db(got)) > 0.1)
                cawtest::fail(__FILE__, __LINE__, std::to_string(count + 1) + " bands at " + std::to_string(hz) + " Hz: " + std::to_string(db(got)) + " dB");
        }
    }
    // Solo the low band of 3: a 5 kHz tone almost gone, a 60 Hz one kept; mute it instead: the other way.
    const Values solo = {{"bands", 2}, {"b1_type", 0}, {"b2_type", 0}, {"b3_type", 0}, {"b1_solo", 1}};
    const Values mute = {{"bands", 2}, {"b1_type", 0}, {"b2_type", 0}, {"b3_type", 0}, {"b1_mute", 1}};
    auto level = [&](const Values& v, double hz) { return db(rms(render(kDrive, with(v, 6), sine(hz, 0.25, 24000)).l, 12000) / (0.25 / std::sqrt(2.0))); };
    CHECK(level(solo, 60) > -1.0 && level(solo, 5000) < -40.0);
    CHECK(level(mute, 30) < -30.0 && level(mute, 5000) > -1.0);  // two octaves under the 120 Hz split
    // A driven band distorts only its own range: a 60 Hz tone through a Hard low band gains harmonics, a 5 kHz one
    // in a Clean top band stays clean.
    const Values split = {{"bands", 1}, {"x1", 300}, {"b1_type", 2}, {"b1_drive", 0.8}, {"b2_type", 0}};
    const Stereo low = render(kDrive, with(split, 6), sine(60, 0.3, 24000));
    const Stereo high = render(kDrive, with(split, 6), sine(5000, 0.3, 24000));
    CHECK(toneDb(low.l, 180, 8000, 8192) - toneDb(low.l, 60, 8000, 8192) > -25.0);
    CHECK(toneDb(high.l, 15000, 8000, 8192) - toneDb(high.l, 5000, 8000, 8192) < -60.0);
}

TEST(drive_modes_give_the_same_bits_at_any_block_size_and_survive_bad_input) {
    const Stereo in = music(30000);
    const Values amp = {{"voicing", 3}, {"gain", 0.8}, {"bass", 0.7}, {"presence", 0.6}};
    const Values pedal = {{"type", 2}, {"drive", 0.8}};
    const Values bands = {{"bands", 3}, {"b1_type", 4}, {"b2_type", 2}, {"b3_type", 5}, {"b4_type", 3}, {"b2_drive", 0.7}, {"b3_tone", 0.5}};
    checkBlockSizes(kDrive, with(amp, 4), in, "amp");
    checkBlockSizes(kDrive, with(pedal, 5), in, "pedal");
    checkBlockSizes(kDrive, with(bands, 6), in, "bands");
    checkBadInput(kDrive, with(amp, 4), "amp", 48000);
    checkBadInput(kDrive, with(pedal, 5), "pedal", 48000);
    checkBadInput(kDrive, with(bands, 6), "bands", 48000);
}

TEST(drive_mode_presets_are_job_named_and_sound) {
    const Stereo in = music(48000);
    for (double v = 4; v <= 6; ++v) checkPresets(kDrive, v, 8, in);
    CHECK(findBuiltinPreset(kDrive, "Classic crunch") && findBuiltinPreset(kDrive, "Wall of fuzz") &&
          findBuiltinPreset(kDrive, "Bass split drive"));
}

TEST(drive_modes_publish_their_display) {
    const uint32_t counts[] = {11, 7, 26};
    for (uint32_t v = 0; v < 3; ++v) {
        auto p = make(kDrive, with({}, v + 4));
        if (!p) return;
        run(*p, music(9600), with({}, v + 4));
        float shown[64];
        CHECK_EQ(p->readDisplay(shown, 64), counts[v]);
        CHECK(shown[1] > -120.0f);
    }
    auto b = make(kDrive, with({{"bands", 2}}, 6));
    if (!b) return;
    run(*b, music(9600), with({{"bands", 2}}, 6));
    float shown[64];
    b->readDisplay(shown, 64);
    CHECK_EQ(shown[2], 3.0f);
    CHECK_NEAR(shown[3], 120.0, 1e-3);
    CHECK_EQ(shown[6 + 5 * 3 + 4], 0.0f);  // band 4 not in use
    CHECK_EQ(shown[6 + 5 * 2 + 4], 1.0f);
}

TEST(drive_modes_match_their_reference_renders) {
    const Stereo in = music(48000 * 2);
    cawtest::References refs("fx_drive_modes");
    struct Case {
        const char* name;
        Values values;
    };
    const Case cases[] = {
        {"amp_crunch", with({{"voicing", 1}, {"gain", 0.55}, {"mid", 0.65}}, 4)},
        {"amp_high_gain_2x", with({{"voicing", 3}, {"gain", 0.7}, {"presence", 0.6}}, 4)},
        {"pedal_fuzz", with({{"type", 2}, {"drive", 0.8}}, 5)},
        {"bands_four", with({{"bands", 3}, {"b1_type", 4}, {"b2_type", 2}, {"b3_type", 5}, {"b4_type", 3}, {"b2_drive", 0.6}}, 6)},
    };
    for (const Case& c : cases) {
        const Stereo out = render(kDrive, c.values, in);
        CHECK_REFERENCE(refs, c.name, (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
    }
}
