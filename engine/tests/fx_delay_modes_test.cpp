// The Delay's 1.1.0 variants: Tape (echo time, loss per repeat, wow), Reverse (played backwards), Multi-tap (pattern, pan, pitch), block sizes, bad input, presets, display, references.
#include "fx_modes_harness.h"
#include "tolerance.h"

using namespace modes_test;

namespace {

constexpr const char* kDelay = "org.caw.delay";

// Frame of the largest |x| in [from, to).
size_t argPeak(const std::vector<float>& v, size_t from, size_t to) {
    size_t best = from;
    for (size_t i = from; i < std::min(to, v.size()); ++i)
        if (std::fabs(v[i]) > std::fabs(v[best])) best = i;
    return best;
}
// Energy above a crude high-pass (first difference) relative to the energy, around an echo.
double brightness(const std::vector<float>& v, size_t from, size_t to) {
    double e = 0, d = 0;
    for (size_t i = from + 1; i < to; ++i) {
        e += static_cast<double>(v[i]) * v[i];
        const double x = static_cast<double>(v[i]) - v[i - 1];
        d += x * x;
    }
    return e > 0 ? d / e : 0.0;
}
// Upward zero crossings per second in [from, to).
double frequency(const std::vector<float>& v, size_t from, size_t to) {
    int n = 0;
    for (size_t i = from + 1; i < to; ++i) n += v[i - 1] < 0 && v[i] >= 0;
    return n * 48000.0 / static_cast<double>(to - from);
}

const Values kTapeClean = {{"sync", 0}, {"time", 100}, {"feedback", 0.5}, {"wow", 0}, {"flutter", 0}, {"saturation", 0},
                           {"loss", 0}, {"wear", 0}, {"spread", 0}, {"mix", 1}};

}  // namespace

TEST(delay_modes_are_appended_after_digital_and_ping_pong) {
    const fx::MergedDevice* m = fx::findMergedDevice(kDelay);
    CHECK(m && m->variants.size() == 5u);
    if (!m || m->variants.size() < 5) return;
    CHECK(m->variants[0].name == "Digital" && m->variants[1].name == "Ping-pong");
    const ModuleDescriptor* tape = checkVariant(kDelay, 2, "Tape");
    const ModuleDescriptor* rev = checkVariant(kDelay, 3, "Reverse");
    const ModuleDescriptor* multi = checkVariant(kDelay, 4, "Multi-tap");
    CHECK(tape && rev && multi);
    if (!tape || !rev || !multi) return;
    CHECK_EQ(tape->parameterCount, 11u);
    CHECK_EQ(rev->parameterCount, 7u);
    CHECK_EQ(multi->parameterCount, 19u);
    for (const ModuleDescriptor* d : {tape, rev, multi}) {
        CHECK_EQ(d->latencyFrames, 0u);
        CHECK_EQ(d->tailFrames, kInfiniteTail);
    }
}

TEST(tape_delay_repeats_at_its_time_each_repeat_darker_and_softer_with_loss) {
    const Stereo in = click(48000);
    const Stereo clean = render(kDelay, with(kTapeClean, 2), in);
    // No wow or flutter: the echoes are exactly 100 ms apart, each half the last (feedback 0.5, no loss).
    // (The tape's open filters, 16 kHz and 30 Hz at loss 0, smear a click by a frame or two.)
    CHECK(std::abs(static_cast<int>(argPeak(clean.l, 1000, 9000)) - 4800) <= 2);
    CHECK(std::abs(static_cast<int>(argPeak(clean.l, 9000, 14000)) - 9600) <= 3);
    CHECK_NEAR(rms(clean.l, 9000, 14000) / rms(clean.l, 1000, 9000), 0.5, 0.1);  // the open filters ring a little
    // Loss: every repeat is darker than the one before.
    Values lossy = kTapeClean;
    lossy.emplace_back("loss", 0.7);
    const Stereo dark = render(kDelay, with(lossy, 2), in);
    const double b1 = brightness(dark.l, 4700, 9000), b2 = brightness(dark.l, 9500, 14000), b3 = brightness(dark.l, 14300, 19000);
    CHECK(b1 > b2 && b2 > b3);
    CHECK(peak(dark.l, 9500, 14000) < peak(dark.l, 4700, 9000));
    // Saturation: a loud input comes back compressed (its echo's peak under the clean one's).
    Values hot = kTapeClean;
    hot.emplace_back("saturation", 1.0);
    const Stereo loud = sine(200, 0.95, 24000);
    CHECK(peak(render(kDelay, with(hot, 2), loud).l, 12000) < 0.9 * peak(render(kDelay, with(kTapeClean, 2), loud).l, 12000));
}

TEST(tape_delay_wow_and_flutter_bend_the_pitch_and_wear_adds_hiss_that_sleeps) {
    const Stereo in = sine(1000, 0.5, 96000);
    Values v = kTapeClean;
    v.emplace_back("feedback", 0.0);
    const Stereo steady = render(kDelay, with(v, 2), in);
    v.emplace_back("wow", 1.0);
    v.emplace_back("flutter", 1.0);
    const Stereo wobbly = render(kDelay, with(v, 2), in);
    // The clean repeat is the input 100 ms later (within the open filters); the wobbly one drifts in time around it,
    // up to a few ms: at 1 kHz whole cycles, so the two differ by about as much as they sound.
    double off = 0, offClean = 0;
    for (size_t i = 9600; i < 96000; ++i) {
        offClean = std::max(offClean, std::fabs(static_cast<double>(steady.l[i]) - in.l[i - 4800]));
        off = std::max(off, std::fabs(static_cast<double>(wobbly.l[i]) - steady.l[i]));
    }
    CHECK(offClean < 0.05);
    CHECK(off > 0.5);
    CHECK(rms(wobbly.l, 9600) > 0.3);  // moved, not lost
    // Wear: hiss on the signal, none in silence (the effect falls asleep).
    Values worn = kTapeClean;
    worn.emplace_back("wear", 1.0);
    auto p = make(kDelay, with(worn, 2));
    if (!p) return;
    run(*p, sine(300, 0.5, 9600), with(worn, 2));
    const Stereo tail = run(*p, silence(48000 * 20), with(worn, 2), 512);
    CHECK(peak(tail.l, tail.size() - 4800) == 0.0);
    CHECK(p->quiet());
}

TEST(reverse_delay_plays_each_window_backwards_without_clicks) {
    // A rising ramp of 1000 frames: the wet comes back as a falling one.
    const size_t frames = 40000, n = 1000;
    Stereo in = silence(frames);
    for (size_t i = 0; i < n; ++i) in.l[i] = in.r[i] = static_cast<float>(0.5 * i / n);
    const Values v = {{"sync", 0}, {"time", 200}, {"feedback", 0}, {"tone", 20000}, {"mix", 1}};
    const Stereo out = render(kDelay, with(v, 3), in);
    // The ramp comes back falling: over the first stretch where the wet sounds, its first half is louder than its
    // second (a forward copy would be the other way round).
    size_t from = 0;
    while (from < frames && std::fabs(out.l[from]) < 0.02) ++from;
    CHECK(from > 1000 && from < 20000);
    const double first = rms(out.l, from, from + n / 2), second = rms(out.l, from + n / 2, from + n);
    if (!(first > 2.0 * second)) cawtest::fail(__FILE__, __LINE__, std::to_string(first) + " vs " + std::to_string(second));
    CHECK(peak(out.l, 0, 1000) < 1e-6);  // nothing before it was played
    // A steady sine stays steady in level: the two windows always sum to one (no dips or clicks at the turns).
    const Stereo s = render(kDelay, with(v, 3), sine(100, 0.5, 96000));
    double lo = 1, hi = 0;
    for (size_t at = 48000; at + 4800 <= 96000; at += 4800) lo = std::min(lo, rms(s.l, at, at + 4800)), hi = std::max(hi, rms(s.l, at, at + 4800));
    CHECK(hi < 1.6 * lo);
    double jump = 0;
    for (size_t i = 48001; i < 96000; ++i) jump = std::max(jump, std::fabs(static_cast<double>(s.l[i]) - s.l[i - 1]));
    CHECK(jump < 0.1);  // a 100 Hz sine of 0.5 moves at most 0.0065 a frame; a turn's click would jump far more
}

TEST(multi_tap_delay_places_pans_and_pitches_its_taps) {
    const Stereo in = click(96000);
    Values v = {{"sync", 0}, {"time", 100}, {"pattern", 0}, {"feedback", 0}, {"tone", 20000}, {"mix", 1},
                {"t1_level", 1}, {"t1_pan", -1}, {"t2_level", 1}, {"t2_pan", 1}, {"t3_level", 0.5}, {"t3_pan", 0}, {"t4_level", 0}};
    const Stereo out = render(kDelay, with(v, 4), in);
    CHECK_EQ(argPeak(out.l, 100, 7000), 4800u);    // tap 1 at one step, hard left
    CHECK(peak(out.r, 4000, 6000) < 1e-6);
    CHECK_EQ(argPeak(out.r, 7000, 12000), 9600u);  // tap 2 at two steps, hard right
    CHECK(peak(out.l, 9000, 10500) < 1e-6);
    CHECK_NEAR(peak(out.l, 14000, 15000), 0.9 * 0.5 * std::sqrt(0.5), 0.01);  // tap 3 centred, equal power
    CHECK(peak(out.l, 15000) < 1e-6);                                         // tap 4 off, no feedback
    // The dotted pattern moves them to 1.5 steps.
    v.emplace_back("pattern", 1);
    CHECK_EQ(argPeak(render(kDelay, with(v, 4), in).l, 100, 9000), 7200u);
    // Pitch: a tap an octave up doubles a sine's frequency.
    const Values up = {{"sync", 0}, {"time", 150}, {"feedback", 0}, {"tone", 20000}, {"mix", 1}, {"t1_level", 1},
                       {"t1_pitch", 12}, {"t2_level", 0}, {"t3_level", 0}, {"t4_level", 0}};
    const Stereo shifted = render(kDelay, with(up, 4), sine(300, 0.5, 48000));
    CHECK_NEAR(frequency(shifted.l, 24000, 48000), 600.0, 15.0);
    // Feedback: echoes go on past the last tap and die away.
    Values fb = v;
    fb.emplace_back("feedback", 0.6);
    const Stereo more = render(kDelay, with(fb, 4), in);
    CHECK(peak(more.l, 30000, 60000) > 1e-3);
}

TEST(delay_modes_give_the_same_bits_at_any_block_size_and_survive_bad_input) {
    const Stereo in = music(30000);
    const Values tape = {{"wow", 0.8}, {"flutter", 0.6}, {"wear", 0.9}, {"saturation", 0.6}, {"loss", 0.5}, {"feedback", 0.7}, {"sync", 3}};
    const Values rev = {{"sync", 0}, {"time", 90}, {"feedback", 0.5}, {"spread", 0.3}};
    const Values multi = {{"sync", 0}, {"time", 70}, {"pattern", 4}, {"feedback", 0.6}, {"t2_pitch", 7}, {"t3_pitch", -5}};
    checkBlockSizes(kDelay, with(tape, 2), in, "tape");
    checkBlockSizes(kDelay, with(rev, 3), in, "reverse");
    checkBlockSizes(kDelay, with(multi, 4), in, "multi-tap");
    checkBadInput(kDelay, with(tape, 2), "tape", 48000 * 30);
    checkBadInput(kDelay, with(rev, 3), "reverse", 48000 * 30);
    checkBadInput(kDelay, with(multi, 4), "multi-tap", 48000 * 30);
}

TEST(delay_mode_presets_are_job_named_and_sound) {
    const Stereo in = music(48000);
    checkPresets(kDelay, 2, 8, in);
    checkPresets(kDelay, 3, 8, in);
    checkPresets(kDelay, 4, 8, in);
    CHECK(findBuiltinPreset(kDelay, "Space echo") && findBuiltinPreset(kDelay, "Reverse swell") &&
          findBuiltinPreset(kDelay, "Dotted gallop"));
}

TEST(delay_modes_publish_their_display) {
    float shown[64];
    {
        auto p = make(kDelay, with({}, 2));
        if (!p) return;
        run(*p, music(9600), with({}, 2));
        CHECK_EQ(p->readDisplay(shown, 64), 13u);
        CHECK_NEAR(shown[3], 0.375 * 120.0 / 120.0, 1e-3);  // 1/8 dotted at 120 BPM
        CHECK_NEAR(shown[7], 0.25, 1e-6);
    }
    {
        auto p = make(kDelay, with({{"sync", 0}, {"time", 300}}, 3));
        if (!p) return;
        run(*p, music(9600), with({{"sync", 0}, {"time", 300}}, 3));
        CHECK_EQ(p->readDisplay(shown, 64), 8u);
        CHECK_NEAR(shown[3], 0.3, 1e-4);
        CHECK(shown[4] >= 0 && shown[4] < 1 && shown[5] >= 0 && shown[5] < 1);
    }
    {
        const Values v = {{"sync", 0}, {"time", 100}, {"pattern", 1}, {"t2_pitch", 5}};
        auto p = make(kDelay, with(v, 4));
        if (!p) return;
        run(*p, music(9600), with(v, 4));
        CHECK_EQ(p->readDisplay(shown, 64), 25u);
        CHECK_NEAR(shown[2], 0.1, 1e-6);
        CHECK_EQ(shown[3], 1.0f);
        CHECK_NEAR(shown[5 + 5], 0.3, 1e-6);  // tap 2 at 3 steps
        CHECK_NEAR(shown[5 + 5 + 3], 5.0, 1e-6);
    }
}

TEST(delay_modes_match_their_reference_renders) {
    const Stereo in = music(48000 * 2);
    struct Case {
        const char* name;
        Values values;
    };
    const Case cases[] = {
        {"tape_space_echo", with({{"sync", 7}, {"feedback", 0.62}, {"wow", 0.45}, {"flutter", 0.3}, {"saturation", 0.5}, {"loss", 0.55}, {"wear", 0.3}, {"spread", 0.5}, {"mix", 0.35}}, 2)},
        {"reverse_quarter", with({{"sync", 9}, {"feedback", 0.3}, {"spread", 0.2}}, 3)},
        {"multitap_pitched_gallop", with({{"sync", 6}, {"pattern", 4}, {"feedback", 0.45}, {"t2_pitch", 7}, {"t3_pitch", 12}}, 4)},
    };
    cawtest::References refs("fx_delay_modes");
    for (const Case& c : cases) {
        const Stereo out = render(kDelay, c.values, in);
        CHECK_REFERENCE(refs, c.name, (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
    }
}
