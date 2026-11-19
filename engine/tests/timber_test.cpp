// Timber (1.1.0): its registration as one merged instrument, each model's sound, the piano's realism checks (tuning, inharmonicity, two-stage decay, hammer brightness, dampers), voice caps, block sizes, presets and references.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "presets.h"
#include "test.h"
#include "timber_harness.h"
#include "tolerance.h"

using namespace caw;
using namespace timber_test;

namespace {

// Timber's stretch curve at stretch 1 (timber_piano.h): the target each key is tuned to.
double stretchCents(double pitch) {
    const double x = pitch - 69.0;
    return x > 0 ? 30.0 * std::pow(std::min(x, 48.0) / 39.0, 3.0) : -25.0 * std::pow(std::min(-x, 60.0) / 48.0, 3.0);
}
double hzOf(double note) { return 440.0 * std::pow(2.0, (note - 69.0) / 12.0); }

bool same(const Stereo& a, const Stereo& b) { return a.l == b.l && a.r == b.r; }

}  // namespace

TEST(timber_is_one_merged_instrument_whose_model_picks_the_class) {
    const ModuleDescriptor* d = registry().find(kTimber);
    CHECK(d != nullptr);
    if (!d) return;
    CHECK(d->role == ModuleRole::Instrument);
    CHECK(d->parameters[d->parameterCount - 1].id == fx::kVariantParam);
    CHECK(!d->parameters[d->parameterCount - 1].automatable);
    const fx::MergedDevice* m = fx::findMergedDevice(kTimber);
    CHECK(m != nullptr);
    if (!m) return;
    for (uint32_t k = 0; k < m->variants.size(); ++k) {
        const ModuleDescriptor& vd = m->variants[k].descriptor();
        CHECK(validateModuleDescriptor(vd) == ModuleValidation::Ok);
        std::unique_ptr<ModuleProcessor> p = make({{"variant", static_cast<double>(k)}});
        CHECK(p && &p->descriptor() == &vd);
        // The shared knobs first, in order, then 4..15 of the model's own, then the model.
        static const char* kShared[] = {"tone", "body", "space", "velocity", "release", "voices", "level"};
        for (uint32_t i = 0; i < 7; ++i) CHECK(vd.parameters[i].id == kShared[i]);
        const uint32_t own = vd.parameterCount - 8;
        CHECK(own >= 4 && own <= 16);
        // At least six presets per model, every one naming its model.
        int presets = 0;
        for (const BuiltinPreset& p : builtinPresets(kTimber))
            for (const auto& [id, v] : p.values)
                if (id == fx::kVariantParam && static_cast<uint32_t>(v) == k) ++presets;
        CHECK(presets >= 6);
    }
}

// ---------- Piano ----------

TEST(timber_piano_is_tuned_to_its_stretch_curve_within_a_cent) {
    for (double sr : {44100.0, 48000.0, 96000.0})
        for (double key : {21.0, 33.0, 45.0, 60.0, 69.0, 81.0, 96.0, 108.0}) {
            const Values v = withModel(0, {{"unison", 0}, {"space", 0}});
            auto p = make(v, sr);
            CHECK(p != nullptr);
            if (!p) return;
            const Stereo s = play(*p, v, {{0.0, -1, key, 0.6}}, 1.6, sr);
            const std::vector<float> m = s.mono();
            const double want = hzOf(key + stretchCents(key) / 100);
            const double got = peakHz(m, want, 20, static_cast<size_t>(0.3 * sr), static_cast<size_t>(1.2 * sr), sr);
            const double err = cents(got, want);
            if (verbose()) std::printf("tune sr %.0f key %.0f: %+.3f ct\n", sr, key, err);
            if (std::fabs(err) > 1.0)
                cawtest::fail(__FILE__, __LINE__, "key " + std::to_string(key) + " at " + std::to_string(sr) + ": " + std::to_string(err) + " ct");
        }
}

TEST(timber_piano_partials_are_stretched_like_a_stiff_string) {
    // Partial n of a stiff string sits at n f1 sqrt((1 + B n^2) / (1 + B)): sharper the higher it is.
    struct K {
        double key;
        int top;
        double minCents, maxCents;  // the top partial's sharpness over n f1
    };
    for (const K k : {K{45, 12, 4, 80}, K{60, 10, 4, 80}, K{84, 5, 2, 60}}) {
        const Values v = withModel(0, {{"unison", 0}, {"space", 0}, {"hammer", 1}});
        auto p = make(v);
        const Stereo s = play(*p, v, {{0.0, -1, k.key, 0.9}}, 1.2);
        const std::vector<float> m = s.mono();
        const double f1 = peakHz(m, hzOf(k.key + stretchCents(k.key) / 100), 20, 4800, 38400, 48000);
        double last = 0;
        bool rising = true;
        for (int n = 2; n <= k.top; ++n) {
            const double want = n * f1;
            // Searched near where the last partial's stretch, growing as n^2, puts it.
            const double guess = want * std::pow(2.0, last * n * n / ((n - 1.0) * (n - 1.0)) / 1200);
            const double fn = peakHz(m, guess, 25, 4800, 38400, 48000);
            const double c = cents(fn, want);
            if (verbose()) std::printf("key %.0f partial %d: %+.2f ct\n", k.key, n, c);
            rising = rising && c > last - 0.3;
            last = c;
        }
        CHECK(rising);
        if (last < k.minCents || last > k.maxCents)
            cawtest::fail(__FILE__, __LINE__, "key " + std::to_string(k.key) + " top partial " + std::to_string(last) + " ct");
    }
}

TEST(timber_piano_decays_in_two_stages) {
    // A middle C held: the early decay (the prompt sound) is faster than the late one (the aftersound).
    for (double key : {52.0, 60.0, 72.0}) {
        const Values v = withModel(0, {{"space", 0}});
        auto p = make(v);
        const Stereo s = play(*p, v, {{0.0, -1, key, 0.7}}, 8.0);
        const std::vector<float> m = s.mono();
        const size_t w = 4800;
        const double early = (rmsDb(m, 4800, w) - rmsDb(m, 48000, w)) / 0.9;      // dB/s over 0.1..1 s
        const double late = (rmsDb(m, 2 * 48000, w) - rmsDb(m, 5 * 48000, w)) / 3.0;  // over 2..5 s
        if (verbose()) std::printf("key %.0f: early %.1f dB/s, late %.1f dB/s\n", key, early, late);
        CHECK(early > 1.5 * late);
        CHECK(late > 0.3);  // it still decays
    }
}

TEST(timber_piano_hammer_brightens_and_louder_with_velocity) {
    // The share of the attack's power above the 6th partial (at least 1.5 kHz) rises with velocity, as the level does.
    for (double key : {43.0, 55.0, 72.0}) {
        double lastH = -200, lastL = -200, first = 0;
        for (double vel : {0.2, 0.5, 0.8, 1.0}) {
            const Values v = withModel(0, {{"space", 0}, {"velocity", 1}});
            auto p = make(v);
            const Stereo s = play(*p, v, {{0.0, -1, key, vel}}, 0.2);
            const std::vector<float> m = s.mono();
            const double h = highShareDb(m, 0, 7200, 48000, std::max(1500.0, 6 * hzOf(key))), l = rmsDb(m, 0, 7200);
            if (verbose()) std::printf("key %.0f velocity %.1f: high share %.1f dB, level %.1f dB\n", key, vel, h, l);
            if (vel == 0.2) first = h;
            CHECK(h > lastH + 1);
            CHECK(l > lastL + 2);
            lastH = h, lastL = l;
        }
        CHECK(lastH > first + 8);  // pp to ff: clearly brighter
    }
}

TEST(timber_piano_dampers_stop_a_released_key_unless_the_pedal_holds_it) {
    const Values free = withModel(0, {{"space", 0}, {"release", 0.15}});
    const Values pedal = withModel(0, {{"space", 0}, {"release", 0.15}, {"sustain", 1}});
    auto a = make(free), b = make(pedal), c = make(free);
    const std::vector<Note> n = {{0.0, 0.5, 60, 0.7}};
    const std::vector<float> damped = play(*a, free, n, 1.5).mono();
    const std::vector<float> held = play(*b, pedal, n, 1.5).mono();
    // CC 64 does what the knob does.
    const std::vector<float> cc = play(*c, free, n, 1.5, 48000, 64, {{0.1, 64, 1.0}}).mono();
    const double before = rmsDb(damped, 20000, 4800), after = rmsDb(damped, 60000, 4800);
    if (verbose())
        std::printf("damped %.1f -> %.1f, pedal %.1f, cc %.1f\n", before, after, rmsDb(held, 60000, 4800), rmsDb(cc, 60000, 4800));
    CHECK(after < before - 30);
    CHECK(rmsDb(held, 60000, 4800) > after + 30);
    CHECK(rmsDb(cc, 60000, 4800) > after + 30);
    CHECK(rmsDb(held, 60000, 4800) > before - 20);  // only the string's own decay
    // The top keys have no dampers: released, they ring as if held.
    auto d = make(free), e = make(free);
    const std::vector<float> top = play(*d, free, {{0.0, 0.3, 96, 0.7}}, 0.9).mono();
    const std::vector<float> topHeld = play(*e, free, {{0.0, -1, 96, 0.7}}, 0.9).mono();
    CHECK(std::fabs(rmsDb(top, 33600, 2400) - rmsDb(topHeld, 33600, 2400)) < 1.0);
}

TEST(timber_piano_sympathetic_resonance_rings_with_the_pedal_down) {
    const Values off = withModel(0, {{"space", 0}, {"sustain", 1}, {"resonance", 0}});
    const Values on = withModel(0, {{"space", 0}, {"sustain", 1}, {"resonance", 1}});
    auto a = make(off), b = make(on);
    const std::vector<Note> n = {{0.0, 0.2, 67, 0.9}};
    const std::vector<float> x = play(*a, off, n, 2.0).mono(), y = play(*b, on, n, 2.0).mono();
    double diff = 0;
    for (size_t i = 48000; i < 96000; ++i) diff += (x[i] - y[i]) * (x[i] - y[i]);
    const double ratio = 10 * std::log10(diff / 48000 + 1e-30) - rmsDb(x, 48000, 48000);
    if (verbose()) std::printf("resonance adds %.1f dB relative\n", ratio);
    CHECK(ratio > -40 && ratio < -6);
}

// ---------- Every model ----------

TEST(timber_models_render_the_same_bits_at_any_block_size) {
    const fx::MergedDevice* m = fx::findMergedDevice(kTimber);
    for (uint32_t k = 0; m && k < m->variants.size(); ++k) {
        const Values v = withModel(static_cast<int>(k), {{"space", 0.3}});
        const std::vector<Note> n = {{0.0, 0.4, 48, 0.8}, {0.013, 0.31, 64, 0.5}, {0.2, -1, 71.3, 1.0}, {0.35, 0.6, 55, 0.3}};
        Stereo ref;
        for (uint32_t block : {64u, 1u, 37u, 512u}) {
            auto p = make(v);
            const Stereo s = play(*p, v, n, 0.8, 48000, block, {{0.1, 64, 1.0}, {0.5, 64, 0.0}, {0.3, 1, 0.7}});
            if (block == 64) ref = s;
            else if (!same(ref, s)) cawtest::fail(__FILE__, __LINE__, "model " + std::to_string(k) + " differs at block " + std::to_string(block));
        }
    }
}

TEST(timber_models_keep_to_their_voice_cap_and_steal_without_a_click) {
    const fx::MergedDevice* m = fx::findMergedDevice(kTimber);
    for (uint32_t k = 0; m && k < m->variants.size(); ++k) {
        // The same ten notes with a cap of 4 and with the model's own cap: stealing adds no step the notes don't make.
        float steps[2] = {}, level = 0;
        for (int run = 0; run < 2; ++run) {
            const Values v = withModel(static_cast<int>(k), {{"voices", run == 0 ? 4.0 : 128.0}, {"space", 0}});
            auto p = make(v);
            std::vector<Note> n;
            for (int i = 0; i < 10; ++i) n.push_back({0.05 * i, -1, 48.0 + 3 * i, 0.8});
            const Stereo s = play(*p, v, n, 0.8);
            if (run == 0) {
                float shown[64];
                const uint32_t got = p->readDisplay(shown, 64);
                CHECK(got >= 9u);
                if (got >= 9) CHECK(shown[2] <= 5.0f && shown[3] == 4.0f);  // 4 and at most one fading
            }
            for (size_t i = 1; i < s.size(); ++i) {
                steps[run] = std::max(steps[run], std::fabs(s.l[i] - s.l[i - 1]));
                level = std::max(level, std::fabs(s.l[i]));
            }
        }
        if (verbose()) std::printf("model %u: peak %.3f, largest step capped %.3f, free %.3f\n", k, level, steps[0], steps[1]);
        CHECK(level > 0.01f && level < 2.0f);
        CHECK(steps[0] < 1.25f * steps[1] + 0.02f);
    }
}

TEST(timber_models_fall_quiet_to_exact_zeros_and_survive_bad_values) {
    const fx::MergedDevice* m = fx::findMergedDevice(kTimber);
    for (uint32_t k = 0; m && k < m->variants.size(); ++k) {
        const Values v = withModel(static_cast<int>(k), {{"space", 0.5}, {"release", 0.1}});
        auto p = make(v);
        double quietAt = -1;
        const Stereo s = play(*p, v, {{0.0, 0.2, 60, 1.0}, {0.05, 0.25, 30, 1.0}}, 45.0, 48000, 64, {}, &quietAt);
        if (verbose()) std::printf("model %u quiet at %.2f s\n", k, quietAt);
        CHECK(quietAt > 0 && quietAt < 44);
        bool zeros = true;
        for (size_t i = static_cast<size_t>(44.0 * 48000); i < s.size(); ++i) zeros = zeros && s.l[i] == 0.0f && s.r[i] == 0.0f;
        CHECK(zeros);
        // NaN and infinite knobs and pitches: finite output.
        const Values bad = withModel(static_cast<int>(k), {{"tone", NAN}, {"body", INFINITY}, {"release", NAN}, {"level", -INFINITY}});
        auto q = make(bad);
        const Stereo b = play(*q, bad, {{0.0, 0.1, 127.9, 1.0}, {0.0, 0.1, 0.0, 1.0}}, 0.3);
        bool finite = true;
        for (size_t i = 0; i < b.size(); ++i) finite = finite && std::isfinite(b.l[i]) && std::isfinite(b.r[i]);
        CHECK(finite);
    }
}

TEST(timber_models_match_their_reference_renders) {
    cawtest::References refs("timber");
    const fx::MergedDevice* m = fx::findMergedDevice(kTimber);
    for (uint32_t k = 0; m && k < m->variants.size(); ++k) {
        const Values v = withModel(static_cast<int>(k), {});
        auto p = make(v);
        const Stereo s = play(*p, v, {{0.0, 0.5, 48, 0.9}, {0.1, 0.6, 55, 0.6}, {0.2, 0.9, 64, 0.75}, {0.3, 0.7, 76, 0.4}}, 1.2);
        // Chaotic: long resonant loops amplify a last-bit difference between compilers' arithmetic.
        CHECK_REFERENCE(refs, "timber_" + std::string(m->variants[k].name), (cawtest::Audio{s.l, s.r}), cawtest::Class::Chaotic);
    }
}

TEST(timber_piano_keyboard_is_even_in_loudness) {
    // Each key's first 300 ms at the same velocity stays within 12 dB of the others (no register jumps out).
    double lo = 1e9, hi = -1e9;
    for (double key = 21; key <= 108; key += 7) {
        const Values v = withModel(0, {{"space", 0}});
        auto p = make(v);
        const std::vector<float> m = play(*p, v, {{0.0, -1, key, 0.7}}, 0.3).mono();
        const double l = rmsDb(m, 0, 14400);
        if (verbose()) std::printf("key %.0f: %.1f dB\n", key, l);
        lo = std::min(lo, l), hi = std::max(hi, l);
    }
    CHECK(hi - lo < 12);
}

// ---------- Electric piano ----------

TEST(timber_epiano_pickup_bends_harder_close_and_loud_and_dampers_stop_it) {
    // The 2nd and 3rd harmonics against the fundamental: a close pickup struck hard has far more than a far one soft.
    auto harmonics = [](const Values& v, double vel) {
        auto p = make(v);
        const std::vector<float> m = play(*p, v, {{0.0, -1, 57, vel}}, 0.6).mono();
        const double f = hzOf(57);
        const double h1 = bandDb(m, f, 9600, 9600, 48000);
        return std::max(bandDb(m, 2 * f, 9600, 9600, 48000), bandDb(m, 3 * f, 9600, 9600, 48000)) - h1;
    };
    const double soft = harmonics(withModel(1, {{"pickup", 0.0}, {"bell", 0}, {"bark", 0}, {"space", 0}}), 0.3);
    const double hard = harmonics(withModel(1, {{"pickup", 1.0}, {"bell", 0}, {"bark", 0}, {"space", 0}}), 1.0);
    const double reed = harmonics(withModel(1, {{"kind", 1}, {"pickup", 1.0}, {"bell", 0}, {"bark", 0}, {"space", 0}}), 1.0);
    if (verbose()) std::printf("epiano harmonics: soft %.1f, hard %.1f, reed %.1f dB\n", soft, hard, reed);
    CHECK(hard > soft + 15);
    CHECK(std::fabs(reed - hard) > 1);  // the reed's curve is its own
    // In tune, and the damper stops a released key.
    const Values v = withModel(1, {{"space", 0}, {"release", 0.1}, {"pickup", 0.2}});
    auto p = make(v);
    const std::vector<float> m = play(*p, v, {{0.0, 0.3, 69, 0.6}}, 1.0).mono();
    CHECK(std::fabs(cents(peakHz(m, 440, 20, 2400, 9600, 48000), 440)) < 3);
    CHECK(rmsDb(m, 33600, 4800) < rmsDb(m, 4800, 4800) - 30);
}

// ---------- Organ ----------

TEST(timber_organ_drawbars_are_pure_footages_and_wheels_are_shared_in_phase) {
    const double f = hzOf(60);
    // 8' alone: a sine at the key's pitch (no other drawbar sounds).
    {
        const Values v = withModel(2, {{"db16", 0}, {"db513", 0}, {"db8", 8}, {"rotary", 0}, {"drive", 0}, {"click", 0}, {"space", 0}});
        auto p = make(v);
        const std::vector<float> m = play(*p, v, {{0.0, -1, 60, 0.8}}, 0.5).mono();
        const double h1 = bandDb(m, f, 4800, 9600, 48000);
        CHECK(bandDb(m, f / 2, 4800, 9600, 48000) < h1 - 50);
        CHECK(bandDb(m, 2 * f, 4800, 9600, 48000) < h1 - 50);
        CHECK(std::fabs(cents(peakHz(m, f, 10, 4800, 19200, 48000), f)) < 0.5);
    }
    // 16' sounds an octave down, 5 1/3' a fifth above the 8'.
    {
        const Values v = withModel(2, {{"db16", 8}, {"db513", 8}, {"db8", 0}, {"rotary", 0}, {"drive", 0}, {"click", 0}, {"space", 0}});
        auto p = make(v);
        const std::vector<float> m = play(*p, v, {{0.0, -1, 60, 0.8}}, 0.5).mono();
        CHECK(std::fabs(bandDb(m, f / 2, 4800, 9600, 48000) - bandDb(m, 1.5 * f, 4800, 9600, 48000)) < 1.5);
        CHECK(bandDb(m, f, 4800, 9600, 48000) < bandDb(m, f / 2, 4800, 9600, 48000) - 40);
    }
    // C4's 4' and C5's 8' read the same wheel: in phase, the two together are 6 dB over one (not 3, as unrelated phases).
    {
        const Values one = withModel(2, {{"db16", 0}, {"db513", 0}, {"db8", 8}, {"rotary", 0}, {"drive", 0}, {"click", 0}, {"space", 0}});
        const Values both = withModel(2, {{"db16", 0}, {"db513", 0}, {"db8", 8}, {"db4", 8}, {"rotary", 0}, {"drive", 0}, {"click", 0}, {"space", 0}});
        auto a = make(one), b = make(both);
        const std::vector<float> x = play(*a, one, {{0.0, -1, 72, 0.8}}, 0.5).mono();
        const std::vector<float> y = play(*b, both, {{0.0, -1, 72, 0.8}, {0.1234, -1, 60, 0.8}}, 0.5).mono();
        const double gain = bandDb(y, 2 * f, 9600, 9600, 48000) - bandDb(x, 2 * f, 9600, 9600, 48000);
        if (verbose()) std::printf("shared wheel: +%.2f dB\n", gain);
        CHECK(std::fabs(gain - 6.02) < 0.3);
    }
}

TEST(timber_organ_percussion_is_single_triggered_and_the_rotary_moves) {
    const double f = hzOf(60);
    const Values v = withModel(2, {{"db16", 0}, {"db513", 0}, {"perc", 2}, {"perc_decay", 1}, {"rotary", 0}, {"click", 0}, {"space", 0}});
    auto p = make(v);
    // A note alone, then a second while the first is held: only the first gets the 3rd-harmonic percussion.
    const std::vector<float> m = play(*p, v, {{0.0, 0.25, 60, 0.8}, {0.5, -1, 60.0 + 12, 0.8}, {0.6, -1, 60, 0.8}}, 0.9).mono();
    const double first = bandDb(m, 3 * f, 0, 2400, 48000), later = bandDb(m, 3 * f, static_cast<size_t>(0.6 * 48000), 2400, 48000);
    if (verbose()) std::printf("percussion: first %.1f, legato %.1f dB\n", first, later);
    CHECK(first > later + 15);
    // The rotary at Fast swings the level of a held note; Off holds it steady.
    for (int rotary : {0, 2}) {
        const Values r = withModel(2, {{"rotary", rotary}, {"click", 0}, {"space", 0}, {"drive", 0}});
        auto q = make(r);
        const std::vector<float> s = play(*q, r, {{0.0, -1, 79, 0.8}}, 2.5).l;
        double lo = 1e9, hi = -1e9;
        for (size_t at = 48000; at + 1200 < s.size(); at += 1200) {
            const double l = rmsDb(s, at, 1200);
            lo = std::min(lo, l), hi = std::max(hi, l);
        }
        if (verbose()) std::printf("rotary %d: level swing %.1f dB\n", rotary, hi - lo);
        if (rotary == 0) CHECK(hi - lo < 0.5);
        else CHECK(hi - lo > 2);
    }
}
// ---------- Plucked ----------

TEST(timber_pluck_is_in_tune_its_position_notches_and_the_harp_rings_on) {
    for (double key : {40.0, 52.0, 64.0, 76.0, 88.0}) {
        const Values v = withModel(3, {{"space", 0}, {"body", 0}});
        auto p = make(v);
        const std::vector<float> m = play(*p, v, {{0.0, -1, key, 0.7}}, 1.0).mono();
        const double err = cents(peakHz(m, hzOf(key), 20, 4800, 33600, 48000), hzOf(key));
        if (verbose()) std::printf("pluck key %.0f: %+.2f ct\n", key, err);
        CHECK(std::fabs(err) < 1.0);
    }
    // Plucked at a quarter of the string, the 4th harmonic (a node there) is far under the 3rd and the 5th.
    {
        const Values v = withModel(3, {{"space", 0}, {"body", 0}, {"position", 0.25}, {"pick", 1}, {"brightness", 1}});
        auto p = make(v);
        const std::vector<float> m = play(*p, v, {{0.0, -1, 45, 1.0}}, 0.5).mono();
        const double f = hzOf(45);
        const double h3 = bandDb(m, 3 * f, 2400, 9600, 48000), h4 = bandDb(m, 4 * f, 2400, 9600, 48000), h5 = bandDb(m, 5 * f, 2400, 9600, 48000);
        if (verbose()) std::printf("pluck harmonics 3/4/5: %.1f %.1f %.1f dB\n", h3, h4, h5);
        CHECK(h4 < std::min(h3, h5) - 12);
    }
    // Damping shortens it; a released guitar string stops, a harp's rings on.
    auto level = [](const Values& v, double off, double at) {
        auto p = make(v);
        const std::vector<float> m = play(*p, v, {{0.0, off, 57, 0.8}}, 1.5).mono();
        return rmsDb(m, static_cast<size_t>(at * 48000), 4800) - rmsDb(m, 2400, 4800);
    };
    const double open = level(withModel(3, {{"space", 0}}), -1, 1.0), muted = level(withModel(3, {{"space", 0}, {"damping", 0.8}}), -1, 1.0);
    const double guitar = level(withModel(3, {{"space", 0}, {"release", 0.1}}), 0.3, 1.0);
    const double harp = level(withModel(3, {{"space", 0}, {"release", 0.1}, {"instrument", 2}}), 0.3, 1.0);
    const double harpHeld = level(withModel(3, {{"space", 0}, {"release", 0.1}, {"instrument", 2}}), -1, 1.0);
    if (verbose()) std::printf("pluck: open %.1f, muted %.1f, guitar released %.1f, harp released %.1f held %.1f\n", open, muted, guitar, harp, harpHeld);
    CHECK(muted < open - 15);
    CHECK(guitar < open - 30);
    CHECK(std::fabs(harp - harpHeld) < 0.5);
}

// ---------- Bowed ----------

TEST(timber_bowed_string_sustains_in_tune_while_bowed_and_stops_after) {
    for (int section = 0; section < 4; ++section) {
        static constexpr double kKey[4] = {69, 62, 48, 36};
        const double key = kKey[section];
        const Values v = withModel(4, {{"space", 0}, {"vibrato", 0}, {"section", section}, {"release", 0.15}});
        auto p = make(v);
        const std::vector<float> m = play(*p, v, {{0.0, 1.5, key, 0.8}}, 2.5).mono();
        const double a = rmsDb(m, 38400, 9600), b = rmsDb(m, 60000, 9600), after = rmsDb(m, 96000, 9600);
        const double err = cents(peakHz(m, hzOf(key), 60, 24000, 38400, 48000), hzOf(key));
        if (verbose()) std::printf("bowed %d: %.1f / %.1f dB held, %.1f after, %+.1f ct\n", section, a, b, after, err);
        CHECK(a > -40);
        CHECK(std::fabs(a - b) < 4);  // it sustains
        CHECK(after < b - 40);
        CHECK(std::fabs(err) < 15);  // [Assumption] the bow's own pull on pitch: within 15 cents
    }
}


// ---------- Mallets ----------

TEST(timber_mallets_ring_at_their_modes_and_hard_mallets_are_brighter) {
    // A marimba bar's first overtone sits two octaves up (its tuning), a glockenspiel's at 2.76; each in tune.
    struct M {
        int instrument;
        double ratio;
    };
    for (const M m : {M{0, 4.0}, M{3, 2.756}, M{2, 3.0}}) {
        const Values v = withModel(5, {{"instrument", m.instrument}, {"space", 0}, {"hardness", 1}});
        auto p = make(v);
        const std::vector<float> x = play(*p, v, {{0.0, -1, 64, 1.0}}, 0.6).mono();
        const double f = hzOf(64);
        CHECK(std::fabs(cents(peakHz(x, f, 20, 2400, 12000, 48000), f)) < 1);
        CHECK(std::fabs(cents(peakHz(x, f * m.ratio, 20, 2400, 12000, 48000), f * m.ratio)) < 1);
    }
    double soft = 0, hard = 0;
    for (double h : {0.1, 1.0}) {
        const Values v = withModel(5, {{"space", 0}, {"hardness", h}});
        auto p = make(v);
        const std::vector<float> x = play(*p, v, {{0.0, -1, 60, 0.9}}, 0.3).mono();
        (h < 0.5 ? soft : hard) = highShareDb(x, 0, 4800, 48000, 1000);
    }
    if (verbose()) std::printf("mallet high share: soft %.1f, hard %.1f dB\n", soft, hard);
    CHECK(hard > soft + 10);
    // The vibraphone's damper stops a released bar; a marimba's (no damper) rings on.
    auto after = [](const Values& v) {
        auto p = make(v);
        const std::vector<float> x = play(*p, v, {{0.0, 0.2, 67, 0.8}}, 1.0).mono();
        return rmsDb(x, 33600, 4800) - rmsDb(x, 2400, 4800);
    };
    const double vibes = after(withModel(5, {{"instrument", 1}, {"dampen", 1}, {"release", 0.05}, {"space", 0}}));
    const double ringing = after(withModel(5, {{"instrument", 1}, {"dampen", 0}, {"space", 0}}));
    CHECK(vibes < ringing - 30);
}

// ---------- Winds ----------

TEST(timber_winds_speak_and_hold_their_pitch) {
    for (int instrument = 0; instrument < 4; ++instrument) {
        for (double key : {45.0, 50.0, 62.0, 74.0, 81.0}) {
            if (instrument == 3 && key < 48) continue;  // [Assumption] the brass model speaks from about C3 up
            const Values v = withModel(6, {{"instrument", instrument}, {"space", 0}, {"vibrato", 0}, {"noise", 0}});
            auto p = make(v);
            const std::vector<float> x = play(*p, v, {{0.0, 1.0, key, 0.8}}, 1.6).mono();
            const double f = hzOf(key);
            const double a = rmsDb(x, 24000, 9600), b = rmsDb(x, 38400, 9600), after = rmsDb(x, 67200, 4800);
            const double got = peakHz(x, f, 100, 19200, 24000, 48000);
            const double err = cents(got, f);
            if (verbose()) std::printf("wind %d key %.0f: %.1f / %.1f dB, after %.1f, %+.1f ct\n", instrument, key, a, b, after, err);
            CHECK(a > -45);
            CHECK(std::fabs(a - b) < 4);
            CHECK(after < b - 30);
            CHECK(std::fabs(err) < 12);
        }
    }
}
