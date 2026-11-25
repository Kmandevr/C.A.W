// Starling's guitar and harp (1.1.3): load-on-use, tuning over every range, the recorded pluck's in-phase crossfade, bounds at every key, velocity and tier, the pluck's knobs, the dampers, block sizes, presets, reference renders and the body fit's renders.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include "builtin_starling.h"
#include "presets.h"
#include "recorded_bank.h"
#include "starling_strings.h"
#include "test.h"
#include "instrument_harness.h"
#include "tolerance.h"

using namespace caw;
using namespace timber_test;

namespace {

constexpr const char* kId = "org.caw.starling";
constexpr const char* kNames[2] = {"guitar", "harp"};

std::unique_ptr<ModuleProcessor> makeS(const Values& v, double sr = 48000) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), kId, v);
    if (p && !p->activate(sr, 512)) p.reset();
    return p;
}
// inst: 0 guitar, 1 harp (the variants 1 and 2).
Values at(int inst, Values extra = {}) {
    Values v = {{"variant", static_cast<double>(inst + 1)}};
    for (auto& x : extra) v.push_back(x);
    return v;
}
starling::Strings& modelOf(ModuleProcessor& p, int inst) { return *starling::starlingStringsModel(p, static_cast<uint32_t>(inst + 1)); }
struct Flags {
    bool muteRec = false, muteModel = false, unfaded = false;
};
std::vector<float> note(int inst, double key, double vel, double seconds, Values extra = {}, Flags f = {}) {
    const Values v = at(inst, extra);
    auto p = makeS(v);
    if (!p) return {};
    starling::Strings& m = modelOf(*p, inst);
    m.testMuteRecordings = f.muteRec, m.testMuteModel = f.muteModel, m.testUnfaded = f.unfaded;
    return play(*p, v, {{0.0, -1, key, vel}}, seconds).mono();
}
double db(double x) { return 20.0 * std::log10(std::max(x, 1e-12)); }
double rms(const std::vector<float>& x, size_t from, size_t n) {
    double s = 0;
    for (size_t i = from; i < from + n && i < x.size(); ++i) s += static_cast<double>(x[i]) * x[i];
    return std::sqrt(s / static_cast<double>(n));
}
double hzOf(double key) { return 440.0 * std::pow(2.0, (key - 69.0) / 12.0); }
const starling::Layout& lay(int inst) { return starling::kLayouts[inst]; }
double zoneKey(int inst, int z) { return starling::kZones[lay(inst).firstZone + z].key; }

}  // namespace

// Load only what is used: each instrument's bank decodes with its first instance and goes with the last; the
// piano's is not touched.
TEST(starling_strings_recordings_load_on_use_and_free) {
    const size_t before = recorded::residentBytes();
    {
        auto a = makeS(at(0));
        CHECK(a != nullptr);
        const size_t guitar = recorded::residentBytes();
        CHECK(guitar >= before + 100000 * sizeof(float));
        auto b = makeS(at(0));
        CHECK(recorded::residentBytes() == guitar);  // shared, not decoded again
        auto c = makeS(at(1));
        CHECK(recorded::residentBytes() >= guitar + 300000 * sizeof(float));
    }
    CHECK(recorded::residentBytes() == before);
}

// In tune at A440 over every range: the fundamental within 5 cents once the string plays alone (0.3..0.8 s), and
// the recorded pluck played at the note's pitch over its crossfade (unfaded, where the fundamental is over 150 Hz)
// within 5 cents too: each clip's own pitch there is measured (the guitar's A2 rings 22 cents sharp, a harp's string
// starts up to 26 cents off where it settles) and taken off.
TEST(starling_strings_are_in_tune_over_every_range) {
    for (int inst = 0; inst < 2; ++inst) {
        double worst = 0, worstRec = 0;
        std::string row;
        for (int key = starling::kLow[inst]; key <= starling::kHigh[inst]; key += 2) {
            const double hz = hzOf(key);
            const std::vector<float> m = note(inst, key, 0.7, 0.8);
            const double c = cents(peakHz(m, hz, 30, 14400, 24000, 48000), hz);
            worst = std::max(worst, std::fabs(c));
            row += " " + std::to_string(key) + ":" + std::to_string(static_cast<int>(std::lround(10 * c)));
            if (hz > 150) {
                const std::vector<float> r = note(inst, key, 0.7, 0.2, {}, {false, true, true});
                const size_t from = static_cast<size_t>(lay(inst).hold * 48000), n = static_cast<size_t>(lay(inst).fade * 48000);
                const double cr = cents(peakHz(r, hz, 30, from, n, 48000), hz);
                worstRec = std::max(worstRec, std::fabs(cr));
                row += "/" + std::to_string(static_cast<int>(std::lround(10 * cr)));
            }
        }
        if (verbose()) std::printf("%s: worst %.2f ct (string), %.2f ct (recording); tenths of a cent:%s\n", kNames[inst], worst, worstRec, row.c_str());
        CHECK(worst < 5.0);
        CHECK(worstRec < 5.0);
    }
}

// The string carries the recording on in phase: the model alone (faded in) against the recording played on
// unfaded (faded the same way), over the crossfade's first quarter, correlates over 0.6 at every zone and over 0.9
// at most (the median). Later the two part where the real string beats (its two polarisations, a neighbouring string: the harp's
// B5 falls to 0.2 by mid-fade), which a single loop cannot follow; the level test below holds the handover there.
TEST(starling_strings_carry_the_recording_on_in_phase) {
    for (int inst = 0; inst < 2; ++inst) {
        double worst = 1;
        std::vector<double> all;
        std::string where, row;
        for (int z = 0; z < lay(inst).zones; ++z) {
            const double key = std::round(zoneKey(inst, z));
            // The model alone: the full render less one with the model muted (the recording's faded part).
            const std::vector<float> both = note(inst, key, 0.8, 0.25, {}, {false, false, false});
            const std::vector<float> rec = note(inst, key, 0.8, 0.25, {}, {false, true, false});
            const std::vector<float> truth = note(inst, key, 0.8, 0.25, {}, {false, true, true});
            const double ratio = std::pow(2.0, (key - zoneKey(inst, z)) / 12.0);
            const size_t a = static_cast<size_t>(lay(inst).hold * 48000 / ratio), n = static_cast<size_t>(lay(inst).fade * 48000 / ratio);
            double xy = 0, xx = 0, yy = 0;
            for (size_t i = a; i < a + n / 4; ++i) {
                const double t = static_cast<double>(i - a + 1) / n, s = t * t * (3 - 2 * t);
                const double x = both[i] - rec[i], y = truth[i] * s;
                xy += x * y, xx += x * x, yy += y * y;
            }
            const double c = xy / std::sqrt(xx * yy + 1e-30);
            all.push_back(c);
            row += " " + std::to_string(static_cast<int>(key)) + ":" + std::to_string(static_cast<int>(std::lround(100 * c)));
            if (c < worst) worst = c, where = std::to_string(static_cast<int>(key));
        }
        std::sort(all.begin(), all.end());
        const double median = all[all.size() / 2];
        if (verbose()) std::printf("%s: correlation (hundredths)%s; worst %.2f at %s, median %.2f\n", kNames[inst], row.c_str(), worst, where.c_str(), median);
        CHECK(worst > 0.6);
        CHECK(median > 0.9);
    }
}

// The recorded pluck hands over to the string with no hole or bump: across the crossfade, no window (10 ms, or two
// periods in the bass) steps from its neighbours' mean by more than 1.5 dB beyond what the recording played on
// unfaded (the real instrument, its own beating and decay) does there, at every zone's key and between zones, soft
// and loud, at each tier.
TEST(starling_strings_crossfade_is_level_matched) {
    for (int inst = 0; inst < 2; ++inst) {
        double worst = 0, worstLevel = 0;
        std::string where;
        for (int z = 0; z < lay(inst).zones; ++z)
            for (double off : {0.0, 1.0}) {
                const double key = std::round(zoneKey(inst, z)) + (z + 1 < lay(inst).zones ? off : -off);
                const size_t n = std::max<size_t>(480, static_cast<size_t>(2 * 48000.0 / hzOf(key)));
                const double ratio = std::pow(2.0, (key - zoneKey(inst, z)) / 12.0);
                const size_t end = static_cast<size_t>((lay(inst).hold + lay(inst).fade) * 48000 / ratio) + 960;
                for (double vel : {0.3, 0.9}) {
                    const std::vector<float> truth = note(inst, key, vel, 0.4, {}, {false, true, true});
                    for (int tier : {1, 2, 3}) {
                        const std::vector<float> m = note(inst, key, vel, 0.4, {{"tier", static_cast<double>(tier)}});
                        for (size_t a = std::max<size_t>(960, n); a + 2 * n <= end; a += n / 2) {
                            auto step = [&](const std::vector<float>& x) {
                                return std::fabs(db(rms(x, a, n)) - 0.5 * (db(rms(x, a - n, n)) + db(rms(x, a + n, n))));
                            };
                            const double d = step(m) - step(truth);
                            worstLevel = std::max(worstLevel, std::fabs(db(rms(m, a, n)) - db(rms(truth, a, n))));
                            if (d > worst)
                                worst = d, where = std::to_string(static_cast<int>(key)) + " vel " + std::to_string(vel) + " tier " +
                                                   std::to_string(tier) + " at " + std::to_string(a / 48);
                        }
                    }
                }
            }
        if (verbose()) std::printf("%s: worst step %.2f dB over the recording's own at %s ms; level %.2f dB from it\n", kNames[inst], worst, where.c_str(), worstLevel);
        if (worst > 1.5) cawtest::fail(__FILE__, __LINE__, std::string(kNames[inst]) + ": " + std::to_string(worst) + " dB at " + where);
    }
}

// Finite and bounded at every key (past each range too), velocity, tier, pluck, noise and body: a note every 0.12 s.
TEST(starling_strings_are_bounded_everywhere) {
    for (int inst = 0; inst < 2; ++inst)
        for (int tier : {1, 2, 3})
            for (double h : {0.0, 1.0}) {
                // Each note let go after 80 ms and damped (the harp's Let ring off): every key's own level, not 60
                // strings ringing together.
                const Values v = at(inst, {{"tier", static_cast<double>(tier)}, {"hardness", h}, {"position", h > 0 ? 0.04 : 0.5},
                                           {"noise", h}, {"velocity", 1.0}, {"body", h}, {"sustain", 0.0}});
                auto p = makeS(v);
                std::vector<Note> ns;
                double t = 0;
                for (int key = starling::kLow[inst] - 14; key <= starling::kHigh[inst] + 14; key += 5)
                    for (double vel : {0.02, 0.5, 1.0}) ns.push_back({t, t + 0.08, static_cast<double>(key), vel}), t += 0.12;
                const std::vector<float> m = play(*p, v, ns, t + 0.3).mono();
                double peak = 0;
                bool finite = true;
                for (float x : m) peak = std::max(peak, static_cast<double>(std::fabs(x))), finite = finite && std::isfinite(x);
                if (verbose()) std::printf("%s tier %d hardness %.0f: peak %.2f\n", kNames[inst], tier, h, peak);
                CHECK(finite && peak > 1e-3 && peak < 4.0);
            }
}

// Each instrument at its defaults is about as loud as the others (a mezzo-forte note in the middle of its range),
// and every key of each speaks.
TEST(starling_strings_are_balanced) {
    for (int inst = 0; inst < 2; ++inst) {
        const double key = std::round(0.5 * (starling::kLow[inst] + starling::kHigh[inst]));
        const double level = db(rms(note(inst, key, 0.7, 0.4), 0, 9600));
        double lo = 1e9, hi = -1e9;
        for (int k = starling::kLow[inst]; k <= starling::kHigh[inst]; k += 3) {
            const double l = db(rms(note(inst, k, 0.7, 0.3), 0, 9600));
            lo = std::min(lo, l), hi = std::max(hi, l);
        }
        if (verbose()) std::printf("%s key %.0f: %.1f dB RMS over the first 200 ms; keys %.1f..%.1f dB\n", kNames[inst], key, level, lo, hi);
        CHECK(level > -40.0 && level < -6.0);
        CHECK(lo > -60.0 && hi < -3.0);
    }
}

// The pluck's knobs: the nail is brighter than the flesh, near the bridge brighter than over the fingerboard, each
// in the recording and the string alike: the share over 1.5 kHz up by over 3 dB over 10..60 ms, 2 dB over 200..400 ms.
TEST(starling_strings_pluck_position_and_hardness_set_the_brightness) {
    for (int inst = 0; inst < 2; ++inst) {
        const double key = inst == 0 ? 52 : 60;
        for (size_t from : {480u, 9600u}) {
            const size_t n = from < 1000 ? 2400 : 9600;
            auto bright = [&](Values v) { return highShareDb(note(inst, key, 0.7, 0.45, v), from, n, 48000, 1500); };
            const double soft = bright({{"hardness", 0.0}}), hard = bright({{"hardness", 1.0}});
            const double middle = bright({{"position", 0.5}}), bridge = bright({{"position", 0.05}});
            if (verbose()) std::printf("%s from %zu: over 1.5 kHz flesh %.1f nail %.1f dB; middle %.1f bridge %.1f dB\n", kNames[inst], from, soft, hard, middle, bridge);
            // The string's high partials die sooner than its low ones, so later the difference is less (2 dB).
            const double need = from < 1000 ? 3.0 : 2.0;
            CHECK(hard - soft > need);
            CHECK(bridge - middle > need);
        }
    }
}

// Damping: the palm mute shortens the note; a released guitar string is stopped unless the pedal or Let ring holds
// it; the harp rings on by default and is damped as you let go with Let ring off.
TEST(starling_strings_damping_and_let_ring) {
    auto after = [](int inst, Values v, double off) {
        const Values vv = at(inst, v);
        auto p = makeS(vv);
        const std::vector<float> m = play(*p, vv, {{0.0, off, 52, 0.7}}, 1.0).mono();
        return db(rms(m, 33600, 4800));  // 0.7..0.8 s
    };
    for (int inst = 0; inst < 2; ++inst) {
        const double open = after(inst, {{"sustain", 1.0}}, -1), muted = after(inst, {{"sustain", 1.0}, {"damping", 0.8}}, -1);
        const double rung = after(inst, {{"sustain", 1.0}}, 0.3), stopped = after(inst, {{"sustain", 0.0}}, 0.3);
        if (verbose()) std::printf("%s: open %.1f, palm mute %.1f; released and let ring %.1f, released and stopped %.1f dB\n", kNames[inst], open, muted, rung, stopped);
        CHECK(open - muted > 15.0);
        CHECK(rung - stopped > 20.0);
    }
    // The defaults: the guitar stops a released string, the harp lets it ring.
    CHECK(after(1, {}, 0.3) - after(0, {}, 0.3) > 20.0);
}

// String noise: a hard low pluck buzzes on the frets at String noise 1 (more energy over 2 kHz than at 0, 0.1..0.5 s),
// and not at the default.
TEST(starling_guitar_fret_buzz_follows_string_noise) {
    auto high = [](double noise) {
        return highShareDb(note(0, 40, 1.0, 0.6, {{"noise", noise}, {"hardness", 0.9}}), 4800, 19200, 48000, 2000);
    };
    const double off = high(0.0), quiet = high(0.15), loud = high(1.0);
    if (verbose()) std::printf("guitar fret buzz: high share %.1f dB at 0, %.1f at 0.15, %.1f at 1\n", off, quiet, loud);
    CHECK(std::fabs(quiet - off) < 0.5);
    CHECK(loud - off > 3.0);
}

// Every knob audibly does something (owner, 2026-11-25): moved from its default, each changes the sound by more
// than -20 dB of difference (the difference's RMS over the default's), in a passage that lets it act: two notes,
// one bent on a wound string (the slides), one let go early (the dampers and the finger's touch). And the variants
// clearly differ: the guitar and the harp at the same notes, and each from the piano.
TEST(starling_strings_every_knob_is_heard_and_the_variants_differ) {
    auto passage = [](int variant, Values extra) {
        Values v = {{"variant", static_cast<double>(variant)}};
        for (auto& x : extra) v.push_back(x);
        auto p = makeS(v);
        const std::vector<Note> n = {{0.0, 0.25, 45, 0.8}, {0.05, -1, 64, 0.6}};
        // The bend: Note messages carry pitch; play() has none, so a second, glided note stands in (a restrike).
        return play(*p, v, n, 0.9).mono();
    };
    auto change = [](const std::vector<float>& a, const std::vector<float>& b) {
        double d = 0, s = 0;
        for (size_t i = 0; i < a.size() && i < b.size(); ++i) d += (a[i] - b[i]) * (a[i] - b[i]), s += a[i] * a[i];
        return 10.0 * std::log10(d / (s + 1e-30) + 1e-30);
    };
    // The largest change of level in any octave band (125 Hz..8 kHz) that holds sound (within 60 dB of the loudest).
    auto colour = [](const std::vector<float>& a, const std::vector<float>& b) {
        double la[7], lb[7], top = -1e9, worst = 0;
        for (int k = 0; k < 7; ++k) {
            timber::Biquad fa, fb;
            fa.band(125.0 * std::pow(2.0, k), 1.41, 48000), fb = fa;
            double ea = 0, eb = 0;
            for (size_t i = 0; i < a.size() && i < b.size(); ++i) {
                const float x = fa.run(a[i]), y = fb.run(b[i]);
                ea += x * x, eb += y * y;
            }
            la[k] = 10 * std::log10(ea + 1e-30), lb[k] = 10 * std::log10(eb + 1e-30), top = std::max(top, la[k]);
        }
        for (int k = 0; k < 7; ++k)
            if (la[k] > top - 60) worst = std::max(worst, std::fabs(la[k] - lb[k]));
        return worst;
    };
    for (int inst = 0; inst < 2; ++inst) {
        const int variant = inst + 1;
        const std::vector<float> base = passage(variant, {});
        const std::vector<std::pair<std::string, double>> moves = {
            {"position", 0.05}, {"hardness", inst == 0 ? 1.0 : 0.9}, {"damping", 0.7}, {"sustain", inst == 0 ? 1.0 : 0.0},
            {"body", 1.0}, {"space", 0.4}, {"tone", 0.6}, {"release", 2.0}, {"tier", 1.0}, {"noise", 1.0}};
        for (const auto& [k, x] : moves) {
            Values extra = {{k, x}};
            std::vector<float> a = base;
            if (k == "noise") {  // its slides and touch and buzz: against noise 0 with a hard pluck at Normal
                a = passage(variant, {{"noise", 0.0}, {"hardness", 1.0}, {"sustain", 0.0}});
                extra = {{"noise", 1.0}, {"hardness", 1.0}, {"sustain", 0.0}};
            }
            if (k == "release") extra.push_back({"sustain", 0.0}), a = passage(variant, {{"sustain", 0.0}});
            const std::vector<float> b = passage(variant, extra);
            const std::vector<float> a3(a.begin(), a.begin() + 14400), b3(b.begin(), b.begin() + 14400);
            const double d = change(a, b), c = std::max(colour(a, b), colour(a3, b3));  // the whole, or the first 0.3 s
            if (verbose()) std::printf("%s %s %.2f: %.1f dB of change, %.1f dB in its loudest-changed octave\n", kNames[inst], k.c_str(), x, d, c);
            // Heard: the difference within 20 dB of the sound, or an octave band moved 3 dB. The tier is a CPU
            // setting (fewer voices and dispersion stages, no fret buzz at Eco): it must change the bits, 40 dB down.
            const bool heard = k == "tier" ? d > -40.0 : (d > -20.0 || c > 3.0);
            if (!heard) cawtest::fail(__FILE__, __LINE__, std::string(kNames[inst]) + ": " + k + " is not heard (" + std::to_string(d) + " dB)");
        }
    }
    const std::vector<float> g = passage(1, {}), h = passage(2, {}), piano = passage(0, {});
    const double gh = change(g, h), gp = change(g, piano), hp = change(h, piano);
    if (verbose()) std::printf("variants: guitar/harp %.1f dB, guitar/piano %.1f, harp/piano %.1f\n", gh, gp, hp);
    CHECK(gh > -3.0 && gp > -3.0 && hp > -3.0);
    // And in kind, not only in phase: their spectra over the first 0.3 s differ by over 3 dB of centroid ratio.
    const double cg = centroid(g, 0, 14400, 48000), ch = centroid(h, 0, 14400, 48000);
    if (verbose()) std::printf("variants: centroid guitar %.0f Hz, harp %.0f Hz\n", cg, ch);
    CHECK(std::fabs(20.0 * std::log10(cg / ch)) > 3.0);
}

TEST(starling_strings_give_the_same_bits_at_any_block_size) {
    for (int inst = 0; inst < 2; ++inst) {
        const Values v = at(inst, {{"hardness", 0.7}, {"noise", 0.9}, {"body", 0.8}, {"sustain", 0.0}});
        const double k = starling::kLow[inst] + 3;
        const std::vector<Note> n = {{0.0, 0.3, k, 0.8}, {0.05, 0.4, k + 7, 0.4}, {0.11, 0.5, k + 12, 0.95}, {0.2, 0.25, k + 12, 0.6}};
        Stereo ref;
        for (uint32_t block : {64u, 1u, 37u, 512u}) {
            auto p = makeS(v);
            const Stereo s = play(*p, v, n, 0.7, 48000, block, {{0.35, 64, 1.0}, {0.5, 64, 0.0}});
            if (block == 64) ref = s;
            else CHECK(s.l == ref.l && s.r == ref.r);
        }
    }
}

TEST(starling_strings_presets_load_and_play) {
    const std::vector<BuiltinPreset>* list = starling::starlingPresets(kId);
    CHECK(list != nullptr);
    if (!list) return;
    int per[3] = {};
    for (const BuiltinPreset& pr : *list) {
        Values v;
        for (const auto& [k, x] : pr.values) v.emplace_back(std::string(k), x);
        double variant = 0;
        for (const auto& [k, x] : v)
            if (k == "variant") variant = x;
        ++per[static_cast<int>(variant)];
        if (variant == 0) continue;  // the piano's (starling_piano_test.cpp)
        auto p = makeS(v);
        CHECK(p != nullptr);
        if (!p) continue;
        const int inst = static_cast<int>(variant) - 1;
        const double key = std::round(0.5 * (starling::kLow[inst] + starling::kHigh[inst]));
        const std::vector<float> m = play(*p, v, {{0.0, 0.3, key, 0.7}, {0.1, 0.4, key - 12, 0.7}}, 0.6).mono();
        double peak = 0;
        for (float x : m) peak = std::max(peak, static_cast<double>(std::fabs(x)));
        if (!(std::isfinite(peak) && peak > 1e-3 && peak < 4.0)) cawtest::fail(__FILE__, __LINE__, std::string(pr.name) + " does not play");
    }
    CHECK(per[1] >= 6 && per[2] >= 6);
}

// Stable: starling_strings.cpp (the model and its frame) is compiled with strict floating point, so every build
// renders the same bits.
TEST(starling_strings_match_their_reference_renders) {
    cawtest::References refs("starling_strings");
    for (int inst = 0; inst < 2; ++inst) {
        const Values v = at(inst);
        auto p = makeS(v);
        const double k = starling::kLow[inst];
        const Stereo s = play(*p, v, {{0.0, 0.3, k + 4, 0.7}, {0.15, 0.4, k + 16, 0.5}, {0.3, 0.5, k + 28, 0.9}}, 0.7);
        CHECK_REFERENCE(refs, std::string("starling_") + kNames[inst], (cawtest::Audio{s.l, s.r}), cawtest::Class::Stable);
    }
}

// The renders tools/starling_strings_assets.py body compares with the recordings: the string alone (no recording,
// Body 0) at every semitone of each range at velocity 0.7, written to $CAW_STARLING_RENDERS as <instrument>_<key>.f32
// (nothing without it).
TEST(starling_strings_body_renders) {
    const char* dir = std::getenv("CAW_STARLING_RENDERS");
    if (!dir) return;
    for (int inst = 0; inst < 2; ++inst)
        for (int key = starling::kLow[inst]; key <= starling::kHigh[inst]; ++key) {
            const std::vector<float> s = note(inst, key, 0.7, 1.2, {{"body", 0.0}, {"sustain", 1.0}}, {true, false, false});
            const std::string path = std::string(dir) + "/" + std::to_string(inst) + "_" + std::to_string(key) + ".f32";
            std::ofstream f(path, std::ios::binary);
            f.write(reinterpret_cast<const char*>(s.data()), static_cast<std::streamsize>(s.size() * sizeof(float)));
            CHECK(f.good());
        }
}
