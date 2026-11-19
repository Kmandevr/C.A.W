// The Reverb's 1.1.0 variants: Room, Plate, Spring, Gated and Reverse (their decays, reflections, chirp, gate and swell), block sizes, bad input, presets, display, references.
#include "fx_modes_harness.h"
#include "tolerance.h"

using namespace modes_test;

namespace {

constexpr const char* kReverb = "org.caw.reverb";
const char* const kNames[] = {"Room", "Plate", "Spring", "Gated", "Reverse"};

// The wet alone (mix 1) of a click, for each mode at its defaults plus `v`.
Stereo impulse(double variant, Values v, size_t frames = 48000 * 3) {
    v.emplace_back("mix", 1.0);
    return render(kReverb, with(v, variant), click(frames, 0));
}
// RMS of 50 ms windows starting at `at` s.
double level(const Stereo& s, double at) {
    const size_t from = static_cast<size_t>(at * 48000);
    return rms(s.l, from, from + 2400) + rms(s.r, from, from + 2400);
}

}  // namespace

TEST(reverb_modes_are_appended_after_hall_and_shimmer) {
    const fx::MergedDevice* m = fx::findMergedDevice(kReverb);
    CHECK(m && m->variants.size() == 7u);
    if (!m || m->variants.size() < 7) return;
    CHECK(m->variants[0].name == "Hall" && m->variants[1].name == "Shimmer");
    const uint32_t counts[] = {10, 10, 9, 11, 8};
    for (uint32_t v = 0; v < 5; ++v) {
        const ModuleDescriptor* d = checkVariant(kReverb, v + 2, kNames[v]);
        if (!d) continue;
        CHECK_EQ(d->parameterCount, counts[v]);
        CHECK_EQ(d->latencyFrames, 0u);
    }
}

TEST(every_reverb_mode_decays_by_its_decay_and_falls_silent) {
    // A longer decay keeps more of the tail 0.6 s in (Room, Plate, Spring); every mode's tail ends.
    struct Case {
        double variant;
        double shortDecay, longDecay;
    };
    for (const Case& c : {Case{2, 0.3, 2.0}, Case{3, 0.5, 4.0}, Case{4, 0.5, 4.0}}) {
        const Stereo a = impulse(c.variant, {{"decay", c.shortDecay}});
        const Stereo b = impulse(c.variant, {{"decay", c.longDecay}});
        if (!(level(b, 0.6) > 4.0 * level(a, 0.6)))
            cawtest::fail(__FILE__, __LINE__, std::string(kNames[static_cast<int>(c.variant) - 2]) + " decay does not lengthen the tail");
        CHECK(level(a, 0.05) > 1e-4);
    }
    for (double v = 2; v <= 6; ++v) {
        const Stereo s = impulse(v, {}, 48000 * 12);
        if (!(peak(s.l, 48000 * 11) < 1e-5)) cawtest::fail(__FILE__, __LINE__, std::string(kNames[static_cast<int>(v) - 2]) + " never ends");
    }
}

TEST(room_reflections_come_first_and_follow_its_size) {
    // With no tail (shortest decay) the first reflection arrives at the pre-delay plus 4.3 ms x the size's scale.
    auto first = [](double size) {
        const Stereo s = impulse(2, {{"size", size}, {"predelay", 0}, {"early", 1}, {"decay", 0.1}, {"low_cut", 20}, {"high_cut", 20000}});
        for (size_t i = 0; i < s.size(); ++i)
            if (std::fabs(s.l[i]) > 0.05) return i;
        return s.size();
    };
    const size_t small = first(0.0), big = first(1.0);
    CHECK(small < big);
    CHECK(std::abs(static_cast<int>(small) - static_cast<int>(0.0043 * 0.3 * 48000)) <= 3);
    CHECK(std::abs(static_cast<int>(big) - static_cast<int>(0.0043 * 2.0 * 48000)) <= 3);
    // Early 0: no discrete reflections, only the tail.
    const Stereo none = impulse(2, {{"early", 0}, {"predelay", 0}});
    CHECK(peak(none.l, 0, 48) < 1e-6);
}

TEST(plate_and_spring_have_their_character) {
    // Plate: dense quickly (no gaps after 50 ms), wide (the sides differ).
    const Stereo p = impulse(3, {{"predelay", 0}});
    double gaps = 0;
    for (double t = 0.1; t < 1.0; t += 0.05) gaps += level(p, t) < 1e-4;
    CHECK_EQ(gaps, 0.0);
    double diff = 0;
    for (size_t i = 0; i < 48000; ++i) diff += std::fabs(static_cast<double>(p.l[i]) - p.r[i]);
    CHECK(diff > 1.0);
    // Spring: dispersion delays the lows behind the highs: the low band's energy peaks later than the high band's
    // in the first echo. Tension spreads them further.
    auto spread = [](double tension) {
        const Stereo s = impulse(4, {{"tension", tension}, {"decay", 0.3}, {"low_cut", 20}, {"high_cut", 20000}, {"width", 1}});
        // A crude split: the running mean of 24 frames (lows) and what's left (highs).
        std::vector<float> low(s.size()), high(s.size());
        double acc = 0;
        for (size_t i = 0; i < s.size(); ++i) {
            acc += s.l[i] - (i >= 24 ? s.l[i - 24] : 0.0f);
            low[i] = static_cast<float>(acc / 24);
            high[i] = static_cast<float>(s.l[i] - low[i]);
        }
        auto centre = [](const std::vector<float>& v) {
            double e = 0, t = 0;
            for (size_t i = 0; i < 4800; ++i) e += v[i] * v[i], t += i * static_cast<double>(v[i]) * v[i];
            return e > 0 ? t / e : 0.0;
        };
        return centre(low) - centre(high);
    };
    const double loose = spread(0.0), tight = spread(1.0);
    CHECK(tight > 0.0);
    CHECK(tight > loose);
}

TEST(gated_reverb_opens_on_the_input_and_shuts_after_its_hold) {
    // A hit at 0, then silence: the wet is full while the gate holds (250 ms) and gone 100 ms after.
    const Values v = {{"hold", 250}, {"release", 10}, {"threshold", -30}, {"decay", 5}, {"predelay", 0}};
    const Stereo s = impulse(5, v);
    CHECK(level(s, 0.15) > 1e-3);
    CHECK(level(s, 0.40) < 1e-5);
    // Under the threshold it never opens.
    const Stereo q = render(kReverb, with({{"mix", 1}, {"threshold", -10}, {"hold", 250}}, 5), sine(200, 0.1, 24000));
    CHECK(peak(q.l) < 1e-6);
    // Held open (a low threshold, a long hold), the same tail is still there at 0.4 s: the gate is what cut it.
    const Stereo open = render(kReverb, with({{"mix", 1}, {"threshold", -60}, {"hold", 1000}, {"decay", 5}}, 5), click(48000, 0));
    CHECK(level(open, 0.40) > 1e-3);
}

TEST(reverse_reverb_swells_up_to_its_length_then_stops) {
    const Values v = {{"length", 600}, {"curve", 0.8}};
    const Stereo s = impulse(6, v);
    CHECK(level(s, 0.5) > 3.0 * level(s, 0.1));  // rising
    CHECK(level(s, 0.75) < 0.05 * level(s, 0.5));  // and stopped past the length (diffusion's few ms aside)
    const Stereo lin = impulse(6, {{"length", 600}, {"curve", 0}});
    CHECK(level(lin, 0.1) / level(lin, 0.5) > level(s, 0.1) / level(s, 0.5));  // a gentler curve starts louder
}

TEST(reverb_modes_give_the_same_bits_at_any_block_size_and_survive_bad_input) {
    const Stereo in = music(30000);
    for (double v = 2; v <= 6; ++v) {
        const std::string name = kNames[static_cast<int>(v) - 2];
        checkBlockSizes(kReverb, with({{"mix", 0.5}}, v), in, name);
        checkBadInput(kReverb, with({}, v), name, 48000 * 15);
    }
}

TEST(reverb_mode_presets_are_job_named_and_sound) {
    const Stereo in = music(48000);
    for (double v = 2; v <= 6; ++v) checkPresets(kReverb, v, 8, in);
    CHECK(findBuiltinPreset(kReverb, "Vocal plate") && findBuiltinPreset(kReverb, "80s gated snare") &&
          findBuiltinPreset(kReverb, "Surf spring") && findBuiltinPreset(kReverb, "Drum room") &&
          findBuiltinPreset(kReverb, "Reverse snare"));
}

TEST(reverb_modes_publish_their_display) {
    const uint32_t counts[] = {15, 8, 7, 8, 30};
    for (uint32_t v = 0; v < 5; ++v) {
        auto p = make(kReverb, with({}, v + 2));
        if (!p) return;
        run(*p, music(9600), with({}, v + 2));
        float shown[64];
        CHECK_EQ(p->readDisplay(shown, 64), counts[v]);
        CHECK(shown[1] > -120.0f);  // the wet sounded
    }
    auto g = make(kReverb, with({}, 5));
    if (!g) return;
    run(*g, music(4800), with({}, 5));
    float shown[64];
    g->readDisplay(shown, 64);
    CHECK_NEAR(shown[4], 1.0, 0.01);  // the gate opened
}

TEST(reverb_modes_match_their_reference_renders) {
    const Stereo in = music(48000 * 2);
    cawtest::References refs("fx_reverb_modes");
    const char* names[] = {"room_default", "plate_default", "spring_default", "gated_default", "reverse_default"};
    for (uint32_t v = 0; v < 5; ++v) {
        const Stereo out = render(kReverb, with({{"mix", 0.5}}, v + 2), in);
        CHECK_REFERENCE(refs, names[v], (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
    }
}
