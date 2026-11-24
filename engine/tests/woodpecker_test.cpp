// Woodpecker (1.1.3): load-on-use, tuning over every range, the recorded attack's in-phase crossfade, bounds at every key, velocity and tier, the resonator, motor, dampers and mallets, block sizes, presets and reference renders.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "builtin_woodpecker.h"
#include "presets.h"
#include "recorded_bank.h"
#include "test.h"
#include "timber_harness.h"
#include "tolerance.h"
#include "woodpecker_bars.h"

using namespace caw;
using namespace timber_test;

namespace {

constexpr const char* kId = "org.caw.woodpecker";
constexpr const char* kNames[6] = {"marimba", "xylophone", "glockenspiel", "vibraphone", "chimes", "timpani"};

std::unique_ptr<ModuleProcessor> makeW(const Values& v, double sr = 48000) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), kId, v);
    if (p && !p->activate(sr, 512)) p.reset();
    return p;
}
woodpecker::Bars& modelOf(ModuleProcessor& p, int variant) { return *woodpecker::woodpeckerModel(p, static_cast<uint32_t>(variant)); }
Values at(int variant, Values extra = {}) {
    Values v = {{"variant", static_cast<double>(variant)}};
    for (auto& x : extra) v.push_back(x);
    return v;
}
// One note of `variant`, the model and the recording each mutable.
std::vector<float> note(int variant, double key, double vel, double seconds, Values extra = {}, bool muteRec = false,
                        bool muteModel = false) {
    const Values v = at(variant, extra);
    auto p = makeW(v);
    if (!p) return {};
    modelOf(*p, variant).testMuteRecordings = muteRec;
    modelOf(*p, variant).testMuteModel = muteModel;
    return play(*p, v, {{0.0, -1, key, vel}}, seconds).mono();
}
double db(double x) { return 20.0 * std::log10(std::max(x, 1e-12)); }
double rms(const std::vector<float>& x, size_t from, size_t n) {
    double s = 0;
    for (size_t i = from; i < from + n && i < x.size(); ++i) s += static_cast<double>(x[i]) * x[i];
    return std::sqrt(s / static_cast<double>(n));
}
// The reference mode's ratio to the note's pitch (the chimes' 4th mode: 2).
double refRatio(int variant) { return woodpecker::kZones[woodpecker::kLayouts[variant].firstZone].ratio[0]; }

}  // namespace

// Load only what is used: the mallets' bank decodes with the first Woodpecker and goes with the last.
TEST(woodpecker_recordings_load_on_use_and_free) {
    const size_t before = recorded::residentBytes();
    {
        auto a = makeW(at(0));
        CHECK(a != nullptr);
        const size_t one = recorded::residentBytes();
        CHECK(one >= before + 1100000 * sizeof(float));  // the whole bank decoded once
        auto b = makeW(at(3));
        CHECK(recorded::residentBytes() == one);  // shared, not decoded again
    }
    CHECK(recorded::residentBytes() == before);
}

// In tune at A440 over every range: the reference mode (a bar's fundamental, the chime's 4th mode at twice its strike
// note, the timpani's (1,1) mode) within 5 cents for the model (0.15..0.5 s), and the recorded attack played at the
// note's pitch (unfaded, 30..150 ms, where the mode is over 200 Hz) within 8 cents: a struck bar's first 150 ms read up to
// 7.5 cents from its ringing pitch (the marimba's G3..G4, measured), and the timpani is not held to it: a struck
// kettle's pitch glides down (its D3 starts 20 cents sharp).
TEST(woodpecker_is_in_tune_over_every_range) {
    for (int inst = 0; inst < 6; ++inst) {
        double worst = 0, worstRec = 0;
        std::string row;
        for (int key = woodpecker::kLow[inst]; key <= woodpecker::kHigh[inst]; key += 2) {
            const double hz = refRatio(inst) * 440.0 * std::pow(2.0, (key - 69.0) / 12.0);
            const std::vector<float> m = note(inst, key, 0.7, 0.5, {}, true);
            const double c = cents(peakHz(m, hz, 20, 7200, 16800, 48000), hz);
            worst = std::max(worst, std::fabs(c));
            row += " " + std::to_string(key) + ":" + std::to_string(static_cast<int>(std::lround(10 * c)));
            if (hz > 200) {
                const Values tv = at(inst);
                auto q = makeW(tv);
                modelOf(*q, inst).testMuteModel = modelOf(*q, inst).testUnfaded = true;
                const std::vector<float> r = play(*q, tv, {{0.0, -1, static_cast<double>(key), 0.7}}, 0.2).mono();
                const double cr = cents(peakHz(r, hz, 20, 1440, 5760, 48000), hz);
                worstRec = std::max(worstRec, std::fabs(cr));
                row += "/" + std::to_string(static_cast<int>(std::lround(10 * cr)));
            }
        }
        if (verbose()) std::printf("%s: worst %.2f ct (model), %.2f ct (recording); tenths of a cent:%s\n", kNames[inst], worst, worstRec, row.c_str());
        CHECK(worst < 5.0);
        if (inst != woodpecker::kTimpani) CHECK(worstRec < 8.0);
    }
}

// The recorded attack hands over to the model with no hole or bump: across the crossfade, no 10 ms window (two periods
// in the bass) steps from its neighbours' mean by more than 1.5 dB beyond what the recording played on unfaded (the
// real instrument, its own beating and decay) does there, at every zone's key and between zones, soft and loud, at
// each tier.
TEST(woodpecker_crossfade_is_level_matched) {
    for (int inst = 0; inst < 6; ++inst) {
        const woodpecker::Layout& lay = woodpecker::kLayouts[inst];
        double worst = 0, worstLevel = 0;
        std::string where;
        for (int z = 0; z < lay.zones; ++z)
            for (double off : {0.0, 2.0}) {
                const double key = std::round(woodpecker::kZones[lay.firstZone + z].key) + (z + 1 < lay.zones ? off : -off);
                const size_t n = std::max<size_t>(inst == woodpecker::kTimpani ? 1440 : 480, static_cast<size_t>(2 * 48000.0 / (440.0 * std::pow(2.0, (key - 69.0) / 12.0))));
                for (double vel : {0.3, 0.9}) {
                    const Values tv = at(inst);
                    auto q = makeW(tv);
                    modelOf(*q, inst).testMuteModel = modelOf(*q, inst).testUnfaded = true;
                    const std::vector<float> truth = play(*q, tv, {{0.0, -1, key, vel}}, 0.35).mono();
                    for (int tier : {1, 2, 3}) {
                        const std::vector<float> m = note(inst, key, vel, 0.35, {{"tier", static_cast<double>(tier)}});
                        for (size_t a = std::max<size_t>(960, n); a + 2 * n <= static_cast<size_t>((lay.hold + lay.fade) * 48000 + 960); a += n / 2) {
                            auto step = [&](const std::vector<float>& x) {
                                return std::fabs(db(rms(x, a, n)) - 0.5 * (db(rms(x, a - n, n)) + db(rms(x, a + n, n))));
                            };
                            const double d = step(m) - step(truth);
                            const double l = std::fabs(db(rms(m, a, n)) - db(rms(truth, a, n)));
                            worstLevel = std::max(worstLevel, l);
                            if (d > worst) worst = d, where = std::to_string(key) + " vel " + std::to_string(vel) + " tier " + std::to_string(tier) + " at " + std::to_string(a / 48);
                        }
                    }
                }
            }
        if (verbose()) std::printf("%s: worst step %.2f dB over the recording's own at %s ms; level %.2f dB from it\n", kNames[inst], worst, where.c_str(), worstLevel);
        // The timpani: 3 dB over 30 ms windows. Its model holds 12 of the kettle's many modes, and the recording's own
        // beating between them is not the model's (docs/engine.md, "Woodpecker").
        const double limit = inst == woodpecker::kTimpani ? 3.0 : 1.5;
        if (worst > limit) cawtest::fail(__FILE__, __LINE__, std::string(kNames[inst]) + ": " + std::to_string(worst) + " dB at " + where);
    }
}

// Finite and bounded at every key (past each range too), velocity, tier and mallet: a note every 0.15 s, so a few
// ring together.
TEST(woodpecker_is_bounded_everywhere) {
    for (int inst = 0; inst < 6; ++inst)
        for (int tier : {1, 2, 3})
            for (double h : {0.0, 1.0}) {
                const Values v = at(inst, {{"tier", static_cast<double>(tier)}, {"hardness", h}, {"velocity", 1.0}});
                auto p = makeW(v);
                std::vector<Note> ns;
                double t = 0;
                for (int key = woodpecker::kLow[inst] - 14; key <= woodpecker::kHigh[inst] + 14; key += 5)
                    for (double vel : {0.02, 0.5, 1.0}) ns.push_back({t, t + 0.05, static_cast<double>(key), vel}), t += 0.15;
                const std::vector<float> m = play(*p, v, ns, t + 0.3).mono();
                double peak = 0;
                bool finite = true;
                for (float x : m) peak = std::max(peak, static_cast<double>(std::fabs(x))), finite = finite && std::isfinite(x);
                if (verbose()) std::printf("%s tier %d hardness %.0f: peak %.2f\n", kNames[inst], tier, h, peak);
                CHECK(finite && peak > 1e-3 && peak < 4.0);
            }
}

// Each instrument at its defaults is about as loud as the others (a mezzo-forte note in the middle of its range).
TEST(woodpecker_instruments_are_balanced) {
    for (int inst = 0; inst < 6; ++inst) {
        const double key = std::round(0.5 * (woodpecker::kLow[inst] + woodpecker::kHigh[inst]));
        const std::vector<float> m = note(inst, key, 0.7, 0.4);
        const double level = db(rms(m, 0, 9600));
        if (verbose()) std::printf("%s key %.0f: %.1f dB RMS over the first 200 ms\n", kNames[inst], key, level);
        CHECK(level > -40.0 && level < -6.0);
    }
}

// The resonator: Resonator 0 takes the tube's half of the marimba's fundamental away (about 6 dB), the 4th mode stays.
TEST(woodpecker_resonator_reinforces_the_fundamental) {
    const double key = 60, hz = 440.0 * std::pow(2.0, (key - 69.0) / 12.0);
    const std::vector<float> a = note(0, key, 0.7, 0.6, {{"resonator", 1.0}}), b = note(0, key, 0.7, 0.6, {{"resonator", 0.0}});
    const double d1 = bandDb(a, hz, 9600, 14400, 48000) - bandDb(b, hz, 9600, 14400, 48000);
    const double d4 = bandDb(a, 4 * hz, 9600, 14400, 48000) - bandDb(b, 4 * hz, 9600, 14400, 48000);
    if (verbose()) std::printf("resonator: fundamental %+.1f dB, 4th mode %+.1f dB\n", d1, d4);
    CHECK(d1 > 4.5 && d1 < 7.5);
    CHECK(std::fabs(d4) < 1.0);
}

// The vibraphone's motor: off by default (the level falls smoothly), at 5 Hz the fundamental swells and fades.
TEST(woodpecker_vibraphone_motor_and_damper) {
    auto swing = [](double motor) {
        const std::vector<float> m = note(3, 65, 0.7, 1.6, {{"motor", motor}, {"sustain", 1.0}});
        double lo = 1e9, hi = -1e9;
        for (size_t a = 24000; a + 2400 < 72000; a += 1200) {  // 25 ms windows, a third of a cycle apart
            const double x = db(rms(m, a, 2400)) + 2.0 * (a - 24000) / 48000.0;  // the decay taken off (about 2 dB/s here)
            lo = std::min(lo, x), hi = std::max(hi, x);
        }
        return hi - lo;
    };
    const double off = swing(0.0), on = swing(5.0);
    if (verbose()) std::printf("vibraphone motor: swing %.1f dB off, %.1f dB at 5 Hz\n", off, on);
    CHECK(off < 1.5);
    CHECK(on > 4.0);
    // The damper: a note let go at 0.3 s with the pedal up is far quieter half a second later than with it down.
    auto after = [](double sustain) {
        const Values v = at(3, {{"sustain", sustain}});
        auto p = makeW(v);
        const std::vector<float> m = play(*p, v, {{0.0, 0.3, 65, 0.7}}, 0.9).mono();
        return db(rms(m, 38400, 4800));
    };
    const double up = after(0.0), down = after(1.0);
    if (verbose()) std::printf("vibraphone damper: %.1f dB damped, %.1f dB pedal down\n", up, down);
    CHECK(down - up > 20.0);
}

// A harder mallet is brighter: the marimba's one recorded mallet tilted (its ring, 100..300 ms), the xylophone's own
// recorded sets (its attack, 5..65 ms).
TEST(woodpecker_mallet_hardness_sets_the_brightness) {
    for (int inst : {0, 1}) {
        const double key = inst == 0 ? 60 : 72;
        const size_t from = inst == 0 ? 4800 : 240, n = inst == 0 ? 9600 : 2880;
        const double soft = centroid(note(inst, key, 0.7, 0.6, {{"hardness", 0.05}}), from, n, 48000);
        const double hard = centroid(note(inst, key, 0.7, 0.6, {{"hardness", 0.95}}), from, n, 48000);
        if (verbose()) std::printf("%s: centroid %.0f Hz soft, %.0f Hz hard\n", kNames[inst], soft, hard);
        CHECK(hard > 1.15 * soft);
    }
}

TEST(woodpecker_gives_the_same_bits_at_any_block_size) {
    for (int inst = 0; inst < 6; ++inst) {
        const Values v = at(inst, {{"motor", 4.0}, {"hardness", 0.7}});
        const double k = woodpecker::kLow[inst] + 3;
        const std::vector<Note> n = {{0.0, 0.3, k, 0.8}, {0.05, 0.4, k + 5, 0.4}, {0.11, 0.5, k + 9, 0.95}, {0.2, 0.25, k + 9, 0.6}};
        Stereo ref;
        for (uint32_t block : {64u, 1u, 37u, 512u}) {
            auto p = makeW(v);
            const Stereo s = play(*p, v, n, 0.7, 48000, block, {{0.35, 64, 1.0}, {0.5, 64, 0.0}});
            if (block == 64) ref = s;
            else CHECK(s.l == ref.l && s.r == ref.r);
        }
    }
}

TEST(woodpecker_presets_load_and_play) {
    const std::vector<BuiltinPreset>* list = woodpecker::woodpeckerPresets(kId);
    CHECK(list && list->size() >= 8);
    if (!list) return;
    for (const BuiltinPreset& pr : *list) {
        Values v;
        for (const auto& [k, x] : pr.values) v.emplace_back(std::string(k), x);
        auto p = makeW(v);
        CHECK(p != nullptr);
        if (!p) continue;
        double variant = 0;
        for (const auto& [k, x] : v)
            if (k == "variant") variant = x;
        const double key = std::round(0.5 * (woodpecker::kLow[static_cast<int>(variant)] + woodpecker::kHigh[static_cast<int>(variant)]));
        const std::vector<float> m = play(*p, v, {{0.0, 0.3, key, 0.7}}, 0.5).mono();
        double peak = 0;
        for (float x : m) peak = std::max(peak, static_cast<double>(std::fabs(x)));
        CHECK(std::isfinite(peak) && peak > 1e-3 && peak < 4.0);
    }
}

// Stable: builtin_woodpecker.cpp (the model and its frame) is compiled with strict floating point, so every build
// renders the same bits.
TEST(woodpecker_matches_its_reference_render) {
    cawtest::References refs("woodpecker");
    for (int inst = 0; inst < 6; ++inst) {
        const Values v = at(inst);
        auto p = makeW(v);
        const double k = woodpecker::kLow[inst];
        const Stereo s = play(*p, v, {{0.0, 0.3, k + 4, 0.7}, {0.15, 0.4, k + 9, 0.5}, {0.3, 0.5, k + 14, 0.9}}, 0.6);
        CHECK_REFERENCE(refs, "woodpecker_" + std::to_string(inst), (cawtest::Audio{s.l, s.r}), cawtest::Class::Stable);
    }
}
