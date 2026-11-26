// Curlew (1.1.3): the winds' realism (clean, in-tune notes over every range, no click into the bore, a quiet onset), the body renders and level, block sizes, presets and reference renders.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include "builtin_curlew.h"
#include "curlew_winds.h"
#include "presets.h"
#include "test.h"
#include "instrument_harness.h"
#include "tolerance.h"

using namespace caw;
using namespace timber_test;

namespace {

constexpr const char* kId = "org.caw.curlew";
// Each instrument's range tested (MIDI): flute, clarinet, alto sax, trumpet, trombone, French horn. Not yet: the
// flute's top C7, the trombone's E2 and the horn's lowest notes, where the model does not hold (docs/engine.md, "Curlew").
constexpr int kLow[6] = {60, 50, 49, 54, 43, 44}, kHigh[6] = {93, 89, 81, 82, 72, 77};

std::unique_ptr<ModuleProcessor> makeC(const Values& v, double sr = 48000) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), kId, v);
    if (p && !p->activate(sr, 512)) p.reset();
    return p;
}
curlew::Winds& modelOf(ModuleProcessor& p) {
    curlew::Winds* m = curlew::curlewModelOf(p);  // each variant is Instrument<At<I>>
    if (!m) std::abort();
    return *m;
}
double ac(const std::vector<float>& x, size_t from, size_t n, double lag) {
    const size_t L = static_cast<size_t>(lag);
    const double f = lag - L;
    double s = 0, a = 0, b = 0;
    for (size_t i = from; i < from + n && i + L + 1 < x.size(); ++i) {
        const double y = x[i + L] + (x[i + L + 1] - x[i + L]) * f;
        s += static_cast<double>(x[i]) * y, a += static_cast<double>(x[i]) * x[i], b += y * y;
    }
    return s / std::sqrt(a * b + 1e-30);
}
double periodOf(double key) { return 48000.0 / (440.0 * std::pow(2.0, (key - 69.0) / 12.0)); }
double centsOff(const std::vector<float>& s, double key, size_t from, size_t n) {
    const double T = periodOf(key);
    double best = -2, bl = T;
    for (double c = -150; c <= 150; c += 0.5) {
        const double L = T * std::pow(2.0, -c / 1200.0), r = ac(s, from, n, L);
        if (r > best) best = r, bl = L;
    }
    return 1200.0 * std::log2(T / bl);
}
std::vector<float> note(int inst, double key, double vel, double seconds, Values extra = {}, bool bodyOff = true) {
    Values v = {{"variant", static_cast<double>(inst)}};
    for (auto& x : extra) v.push_back(x);
    auto p = makeC(v);
    if (!p) return {};
    modelOf(*p).testBypassBody = bodyOff;
    return play(*p, v, {{0.0, -1, key, vel}}, seconds).mono();
}
double powerDb(const std::vector<float>& x, size_t from, size_t n) {
    double s = 0;
    for (size_t i = from; i < from + n && i < x.size(); ++i) s += static_cast<double>(x[i]) * x[i];
    return 10.0 * std::log10(s / static_cast<double>(n) + 1e-30);
}

}  // namespace

// The renders tools/instrument_bodies.py curlew compares with the recordings: every semitone of each range at
// velocity 0.7, body off, no vibrato, to $CAW_CURLEW_RENDERS as <instrument>_<key>.f32 (nothing without it). With
// CAW_CURLEW_BODY set, the body on (the sound as heard, for the noise and spectrum against the recordings).
TEST(curlew_body_renders) {
    const char* dir = std::getenv("CAW_CURLEW_RENDERS");
    if (!dir) return;
    const bool bodyOff = std::getenv("CAW_CURLEW_BODY") == nullptr;
    for (int inst = 0; inst < 6; ++inst)
        for (int key = kLow[inst]; key <= kHigh[inst]; ++key) {
            Values extra = {{"vibrato", 0.0}};
            if (const char* set = std::getenv("CAW_CURLEW_SET")) {  // "knob=value" (one knob)
                const std::string kv(set);
                const size_t eq = kv.find('=');
                if (eq != std::string::npos) extra.emplace_back(kv.substr(0, eq), std::atof(kv.c_str() + eq + 1));
            }
            const std::vector<float> s = note(inst, key, 0.7, 2.0, extra, bodyOff);
            const std::string path = std::string(dir) + "/" + std::to_string(inst) + "_" + std::to_string(key) + ".f32";
            std::ofstream f(path, std::ios::binary);
            f.write(reinterpret_cast<const char*>(s.data()), static_cast<std::streamsize>(s.size() * sizeof(float)));
            CHECK(f.good());
        }
}

// The pull table: what the compiled one aims off now plus the error measured (velocity 0.6, no vibrato), written under
// --update-references; run it, rebuild, and run it again until it settles. A cell over 25 cents from its neighbours'
// median (a note the model does not hold, too unsteady to measure) takes that median.
TEST(curlew_tuning_table) {
    if (!cawtest::updateGolden) return;
    float t[6][curlew::kPullKeys];  // the semitones
    for (int inst = 0; inst < 6; ++inst) {
        float row[curlew::kPullKeys];
        for (int z = 0; z < curlew::kPullKeys; ++z) {
            const double key = curlew::kPullFirst[inst] + z;
            Values v = {{"variant", static_cast<double>(inst)}, {"vibrato", 0.0}};
            auto p = makeC(v);
            modelOf(*p).testBypassBody = true;
            const std::vector<float> s = play(*p, v, {{0.0, -1, key, 0.6}}, 0.8).mono();
            row[z] = static_cast<float>(modelOf(*p).pullAt(key) + centsOff(s, key, 19200, 12000));
        }
        for (int z = 0; z < curlew::kPullKeys; ++z) {
            std::vector<float> nb;
            for (int k : {z - 3, z - 2, z - 1, z + 1, z + 2, z + 3})
                if (k >= 0 && k < curlew::kPullKeys) nb.push_back(row[k]);
            std::sort(nb.begin(), nb.end());
            const float med = nb[nb.size() / 2];
            t[inst][z] = std::fabs(row[z] - med) > 25 ? med : row[z];
        }
    }
#ifdef CAW_ROOT
    std::ofstream f(std::string(CAW_ROOT) + "/engine/src/curlew_tuning.inc");
#else
    std::ofstream f("engine/src/curlew_tuning.inc");
#endif
    f << "// Measured (caw_tests --update-references curlew_tuning_table, repeated with a rebuild between until it settles): each\n"
         "// instrument's pull in cents (the note flattens by it and is aimed off), every semitone from kPullFirst, at\n"
         "// velocity 0.6. A cell over 25 cents from its neighbours' median takes that median.\n// clang-format off\n"
         "inline constexpr float kPull[6][40] = {\n";
    char buf[24];
    for (int i = 0; i < 6; ++i) {
        f << "    {";
        for (int z = 0; z < curlew::kPullKeys; ++z) {
            std::snprintf(buf, sizeof buf, "%s%.1ff", z ? ", " : "", t[i][z]);
            f << buf;
        }
        f << "},\n";
    }
    f << "};\n// clang-format on\n";
    CHECK(f.good());
}

// Every note of each range speaks and holds a steady pitch at the defaults, soft and loud (at most a tenth may not:
// the sax still jumps to its octave at C#4).
TEST(curlew_every_note_speaks) {
    for (int inst = 0; inst < 6; ++inst) {
        int bad = 0, all = 0;
        std::string which;
        for (int key = kLow[inst]; key <= kHigh[inst]; key += 3)
            for (double vel : {0.3, 0.9}) {
                const std::vector<float> s = note(inst, key, vel, 0.8, {{"vibrato", 0.0}});
                ++all;
                const double T = periodOf(key);
                // Periodic at the note (a breath's noise keeps the correlation under 1) and not at the octave.
                const bool ok = ac(s, 19200, 14400, T) > 0.8 && ac(s, 19200, 14400, T / 2) < 0.6 && powerDb(s, 19200, 14400) > -60;
                if (!ok) ++bad, which += " " + std::to_string(key) + "@" + std::to_string(static_cast<int>(vel * 100));
            }
        if (verbose()) std::printf("instrument %d: %d of %d not steady:%s\n", inst, bad, all, which.c_str());
        if (bad > all / 10) cawtest::fail(__FILE__, __LINE__, "instrument " + std::to_string(inst) + ":" + which);
    }
}

// In tune: every note within 20 cents at the defaults, velocity 0.6 (a player's own spread; the lips and the sax's reed
// follow the aim, so a few keys keep 10-17 cents however often the table is measured again).
TEST(curlew_plays_in_tune) {
    for (int inst = 0; inst < 6; ++inst) {
        double worst = 0;
        std::string row;
        for (int key = kLow[inst]; key <= kHigh[inst]; key += 3) {
            const std::vector<float> s = note(inst, key, 0.6, 0.8, {{"vibrato", 0.0}});
            const double c = centsOff(s, key, 19200, 12000);
            worst = std::max(worst, std::fabs(c));
            row += " " + std::to_string(key) + ":" + std::to_string(static_cast<int>(std::lround(c)));
        }
        if (verbose()) std::printf("instrument %d: worst %.1f cents:%s\n", inst, worst, row.c_str());
        CHECK(worst < 20.0);
    }
}

// No click into the bore: the first 5 ms hold no more than a breath (Timber's pad click peaked 18 dB under the tone,
// pitched by the bore: the "piano on the flute"), and a slur adds no click either.
TEST(curlew_has_no_click_at_the_onset) {
    for (int inst = 0; inst < 6; ++inst) {
        const double key = (kLow[inst] + kHigh[inst]) / 2;
        const std::vector<float> s = note(inst, key, 0.9, 0.6, {{"vibrato", 0.0}});
        const double onset = powerDb(s, 0, 240), tone = powerDb(s, 14400, 9600);
        if (verbose()) std::printf("instrument %d: the first 5 ms %.1f dB under the tone\n", inst, tone - onset);
        CHECK(tone - onset > 30);
    }
}

// The body: Body 1 the estimated one, 0 the bare model; the level moves by under 9 dB, at 48 and 44.1 kHz.
TEST(curlew_body_changes_the_colour_not_the_level) {
    for (double sr : {48000.0, 44100.0})
        for (int inst = 0; inst < 6; ++inst) {
            const double key = (kLow[inst] + kHigh[inst]) / 2;
            Values v = {{"variant", static_cast<double>(inst)}, {"vibrato", 0.0}};
            auto p = makeC(v, sr), q = makeC(v, sr);
            modelOf(*q).testBypassBody = true;
            const std::vector<float> a = play(*p, v, {{0.0, -1, key, 0.6}}, 0.8, sr).mono();
            const std::vector<float> b = play(*q, v, {{0.0, -1, key, 0.6}}, 0.8, sr).mono();
            const size_t at = static_cast<size_t>(0.4 * sr), n = static_cast<size_t>(0.3 * sr);
            const double d = powerDb(a, at, n) - powerDb(b, at, n);
            if (verbose()) std::printf("%.0f Hz, instrument %d: body %+.1f dB\n", sr, inst, d);
            CHECK(std::fabs(d) < 9.0);
        }
}

TEST(curlew_gives_the_same_bits_at_any_block_size) {
    for (int inst : {0, 1, 3}) {
        const Values v = {{"variant", static_cast<double>(inst)}, {"noise", 0.4}};
        const double k = kLow[inst] + 7;
        const std::vector<Note> n = {{0.0, 0.3, k, 0.8}, {0.1, 0.5, k + 5, 0.5}, {0.2, 0.6, k + 9, 0.95}};
        Stereo ref;
        for (uint32_t block : {64u, 1u, 37u, 512u}) {
            auto p = makeC(v);
            const Stereo s = play(*p, v, n, 0.8, 48000, block);
            if (block == 64) ref = s;
            else CHECK(s.l == ref.l && s.r == ref.r);
        }
    }
}

TEST(curlew_presets_load_and_play) {
    const std::vector<BuiltinPreset>* list = curlew::curlewPresets(kId);
    CHECK(list && list->size() >= 8);
    if (!list) return;
    for (const BuiltinPreset& pr : *list) {
        Values v;
        for (const auto& [k, x] : pr.values) v.emplace_back(std::string(k), x);
        auto p = makeC(v);
        CHECK(p != nullptr);
        if (!p) continue;
        const std::vector<float> m = play(*p, v, {{0.0, 0.5, 64, 0.7}}, 0.7).mono();
        double peak = 0;
        for (float x : m) peak = std::max(peak, static_cast<double>(std::fabs(x)));
        CHECK(std::isfinite(peak) && peak > 1e-3 && peak < 4.0);
    }
}

TEST(curlew_matches_its_reference_render) {
    cawtest::References refs("curlew");
    for (int inst = 0; inst < 6; ++inst) {
        const Values v = {{"variant", static_cast<double>(inst)}};
        auto p = makeC(v);
        const double k = kLow[inst];
        Stereo s = play(*p, v, {{0.0, 0.4, k + 7, 0.7}, {0.3, 0.8, k + 12, 0.5}, {0.6, 1.0, k + 16, 0.9}}, 1.3);
        // Compared up to the last note's release: a self-oscillating model's release tail differs between builds
        // (the chaotic class's 0.1 dB is for the held sound), and the release has its own checks.
        s.l.resize(48000), s.r.resize(48000);
        CHECK_REFERENCE(refs, "curlew_" + std::to_string(inst), (cawtest::Audio{s.l, s.r}), cawtest::Class::Chaotic);
    }
}

// Legato (owner, 2026-11-25: a flute "restarts every time a note changes"; it should work like a one-voice synth):
// a note played while one is held moves the sounding note to it, the held one gone from the sound, and when the newer
// note ends the held one sounds again. Poly keeps both, as chords.
TEST(curlew_legato_slurs_one_note_at_a_time) {
    for (double mode : {0.0, 1.0}) {
        const Values v = {{"variant", 0.0}, {"play", mode}, {"vibrato", 0.0}};
        auto p = makeC(v);
        CHECK(p != nullptr);
        if (!p) return;
        const double a = 72, b = 79;  // C5 held, G5 over it from 0.4 s to 0.9 s
        const std::vector<float> x = play(*p, v, {{0.0, 1.4, a, 0.7}, {0.4, 0.9, b, 0.7}}, 1.4).mono();
        const double held = bandDb(x, timber::noteHz(a), 31200, 8192, 48000);
        const double over = bandDb(x, timber::noteHz(b), 31200, 8192, 48000);
        const double back = bandDb(x, timber::noteHz(a), 52800, 8192, 48000);
        if (verbose()) std::printf("play %g: C5 under G5 %.1f dB, G5 %.1f dB, C5 after %.1f dB\n", mode, held, over, back);
        if (mode == 0) {
            CHECK(over - held > 20);  // one note sounding: the G5, the C5 not under it
            CHECK(back - held > 20);  // the held C5 returns when the G5 ends
        } else {
            CHECK(std::fabs(over - held) < 15);  // Poly: both sound
        }
    }
}
