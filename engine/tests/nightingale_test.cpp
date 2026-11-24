// Nightingale (1.1.3): the measured window and tuning tables (generated under --update-references), the body renders, and the bowed strings' realism: clean notes over every range, in tune, clean onsets, the bow noise's level, block sizes, presets and a reference render.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include "builtin_nightingale.h"
#include "nightingale_bowed.h"
#include "presets.h"
#include "test.h"
#include "timber_harness.h"
#include "tolerance.h"

using namespace caw;
using namespace timber_test;

namespace {

constexpr const char* kId = "org.caw.nightingale";
constexpr int kHighest[4] = {100, 88, 76, 60};  // the top of each instrument's range tested

std::unique_ptr<ModuleProcessor> makeN(const Values& v, double sr = 48000) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), kId, v);
    if (p && !p->activate(sr, 512)) p.reset();
    return p;
}
nightingale::Bowed& modelOf(ModuleProcessor& p) {
    // Each variant is At<I>, a Bowed with nothing added: the model is a Bowed whatever the variant.
    return static_cast<timber::Instrument<nightingale::Bowed>&>(p).model();
}
// The normalised autocorrelation of x[from, from + n) at a fractional lag.
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
// One slip a period: periodic at the note's period and not at half of it (an octave lock or a double slip).
bool helmholtz(const std::vector<float>& s, double key, size_t from, size_t n) {
    const double T = periodOf(key);
    return ac(s, from, n, T) > 0.9 && ac(s, from, n, T / 2) < 0.6;
}
// The steady pitch's error in cents (the autocorrelation's best lag within 120 cents).
double centsOff(const std::vector<float>& s, double key, size_t from, size_t n) {
    const double T = periodOf(key);
    double best = -2, bl = T;
    for (double c = -120; c <= 120; c += 0.5) {
        const double L = T * std::pow(2.0, -c / 1200.0), r = ac(s, from, n, L);
        if (r > best) best = r, bl = L;
    }
    return 1200.0 * std::log2(T / bl);
}
std::vector<float> note(int inst, double key, double vel, double seconds, Values extra = {}, bool bodyOff = true) {
    Values v = {{"variant", static_cast<double>(inst)}};
    for (auto& x : extra) v.push_back(x);
    auto p = makeN(v);
    if (!p) return {};
    modelOf(*p).testBypassBody = bodyOff;
    return play(*p, v, {{0.0, -1, key, vel}}, seconds).mono();
}
double powerDb(const std::vector<float>& x, size_t from, size_t n) {
    double s = 0;
    for (size_t i = from; i < from + n && i < x.size(); ++i) s += static_cast<double>(x[i]) * x[i];
    return 10.0 * std::log10(s / static_cast<double>(n) + 1e-30);
}
std::string srcPath(const char* file) {
#ifdef CAW_ROOT
    return std::string(CAW_ROOT) + "/engine/src/" + file;
#else
    return std::string("engine/src/") + file;
#endif
}

}  // namespace

// ---- The measured tables (written only under --update-references; the sweeps are too slow for every run) ----

// The window: the force factor's range (log10, 0..3.4 in tenths) where a held note at velocities 0.25 and 0.9 stays
// one slip a period, per instrument, bow position (0, 0.5, 1) and key (every 3 semitones from the lowest); the longest
// run of good factors. Gaps take their neighbours' mean, then a median of three.
TEST(nightingale_window_table) {
    if (!cawtest::updateGolden) return;
    float table[4][3][16][2];
    for (int inst = 0; inst < 4; ++inst)
        for (int pi = 0; pi < 3; ++pi) {
            float lo[16], hi[16];
            for (int z = 0; z < 16; ++z) {
                const double key = nightingale::kLowestKey[inst] + 3 * z;
                std::vector<int> ok;
                for (int j = 0; j <= 34; ++j) {
                    const Values v = {{"variant", static_cast<double>(inst)}, {"vibrato", 0.0}, {"noise", 0.0}, {"position", 0.5 * pi}};
                    auto p = makeN(v);
                    modelOf(*p).testBypassBody = true;
                    modelOf(*p).testForceK = static_cast<float>(std::pow(10.0, 0.1 * j));
                    bool good = true;
                    for (double vel : {0.25, 0.9}) {
                        const std::vector<float> s = play(*p, v, {{0.0, 0.9, key, vel}}, 0.9).mono();
                        good = good && helmholtz(s, key, 14400, 9600 - static_cast<size_t>(2 * periodOf(key)));
                        p->reset();
                    }
                    ok.push_back(good);
                }
                int bs = -1, bl = 0;
                for (int j = 0; j < static_cast<int>(ok.size());) {
                    if (!ok[j]) {
                        ++j;
                        continue;
                    }
                    int k = j;
                    while (k < static_cast<int>(ok.size()) && ok[k]) ++k;
                    if (k - j > bl) bl = k - j, bs = j;
                    j = k;
                }
                lo[z] = bs < 0 ? -1.0f : 0.1f * bs, hi[z] = bs < 0 ? -1.0f : 0.1f * (bs + bl - 1);
            }
            for (float* a : {lo, hi})
                for (int z = 0; z < 16; ++z)
                    if (a[z] < 0) {
                        float s = 0;
                        int n = 0;
                        for (int k : {z - 1, z + 1})
                            if (k >= 0 && k < 16 && a[k] >= 0) s += a[k], ++n;
                        a[z] = n ? s / n : 1.0f;
                    }
            for (int z = 0; z < 16; ++z) {
                auto med = [&](const float* a) {
                    float w[3] = {a[std::max(0, z - 1)], a[z], a[std::min(15, z + 1)]};
                    std::sort(w, w + 3);
                    return w[1];
                };
                table[inst][pi][z][0] = med(lo);
                table[inst][pi][z][1] = std::max(med(hi), med(lo) + 0.2f);
            }
        }
    std::ofstream f(srcPath("nightingale_window.inc"));
    f << "// Measured (caw_tests --update-references nightingale_window_table): each instrument's window, as log10 of the force\n"
         "// factor, at bow positions 0, 0.5 and 1 and keys every 3 semitones from its lowest (violin 55, viola 48, cello 36,\n"
         "// bass 28): {lowest, highest} where a held note at velocities 0.25 and 0.9 stays one slip a period. Gaps filled from\n"
         "// the neighbouring keys, then a median of three.\n// clang-format off\ninline constexpr float kWindow[4][3][16][2] = {\n";
    char buf[32];
    for (int i = 0; i < 4; ++i) {
        f << "  {\n";
        for (int p = 0; p < 3; ++p) {
            f << "    {";
            for (int z = 0; z < 16; ++z) {
                std::snprintf(buf, sizeof buf, "%s{%.2ff, %.2ff}", z ? ", " : "", table[i][p][z][0], table[i][p][z][1]);
                f << buf;
            }
            f << "},\n";
        }
        f << "  },\n";
    }
    f << "};\n// clang-format on\n";
    CHECK(f.good());
}

// The tuning: what the compiled table aims off now, less the error measured (velocity 0.6, no vibrato). Run it, rebuild
// and run it again (the pull depends a little on the pitch itself); a cell more than 20 cents from its neighbours'
// median (a note at the bridge above the instrument's range, too noisy to measure) takes that median.
TEST(nightingale_tuning_table) {
    if (!cawtest::updateGolden) return;
    float t[4][3][3][16];
    for (int inst = 0; inst < 4; ++inst)
        for (int pi = 0; pi < 3; ++pi)
            for (int qi = 0; qi < 3; ++qi) {
                float row[16];
                for (int z = 0; z < 16; ++z) {
                    const double key = nightingale::kLowestKey[inst] + 3 * z;
                    const Values v = {{"variant", static_cast<double>(inst)}, {"vibrato", 0.0}, {"pressure", 0.2 + 0.3 * qi}, {"position", 0.5 * pi}};
                    auto p = makeN(v);
                    modelOf(*p).testBypassBody = true;
                    const std::vector<float> s = play(*p, v, {{0.0, -1, key, 0.6}}, 0.9).mono();
                    row[z] = static_cast<float>(modelOf(*p).tuneOffset(key) - centsOff(s, key, 19200, 12000));
                }
                for (int z = 0; z < 16; ++z) {
                    std::vector<float> nb;
                    for (int k : {z - 2, z - 1, z + 1, z + 2})
                        if (k >= 0 && k < 16) nb.push_back(row[k]);
                    std::sort(nb.begin(), nb.end());
                    const float med = nb[nb.size() / 2];
                    t[inst][pi][qi][z] = std::fabs(row[z] - med) > 20 ? med : row[z];
                }
            }
    std::ofstream f(srcPath("nightingale_tuning.inc"));
    f << "// Measured (caw_tests --update-references nightingale_tuning_table, run twice with a rebuild between): the tuning's\n"
         "// offset in cents for the elastic bow's pull (it flattens the note more the harder it presses and the shorter the\n"
         "// string), per instrument, bow position (0, 0.5, 1), pressure (0.2, 0.5, 0.8) and key (every 3 semitones from the\n"
         "// instrument's lowest), at velocity 0.6. A cell over 20 cents from its neighbours' median takes that median.\n"
         "// clang-format off\ninline constexpr float kTuning[4][3][3][16] = {\n";
    char buf[24];
    for (int i = 0; i < 4; ++i) {
        f << "  {\n";
        for (int p = 0; p < 3; ++p) {
            f << "    {\n";
            for (int q = 0; q < 3; ++q) {
                f << "      {";
                for (int z = 0; z < 16; ++z) {
                    std::snprintf(buf, sizeof buf, "%s%.1ff", z ? ", " : "", t[i][p][q][z]);
                    f << buf;
                }
                f << "},\n";
            }
            f << "    },\n";
        }
        f << "  },\n";
    }
    f << "};\n// clang-format on\n";
    CHECK(f.good());
}

// The renders tools/nightingale_bodies.py compares with the recordings: every semitone of each range at velocity 0.7,
// body off, written to $CAW_NIGHTINGALE_RENDERS as <instrument>_<key>.f32 (nothing without it).
TEST(nightingale_body_renders) {
    const char* dir = std::getenv("CAW_NIGHTINGALE_RENDERS");
    if (!dir) return;
    for (int inst = 0; inst < 4; ++inst)
        for (int key = nightingale::kLowestKey[inst]; key <= kHighest[inst]; ++key) {
            const std::vector<float> s = note(inst, key, 0.7, 2.0, {{"vibrato", inst == 3 ? 0.0 : 0.3}});
            const std::string path = std::string(dir) + "/" + std::to_string(inst) + "_" + std::to_string(key) + ".f32";
            std::ofstream f(path, std::ios::binary);
            f.write(reinterpret_cast<const char*>(s.data()), static_cast<std::streamsize>(s.size() * sizeof(float)));
            CHECK(f.good());
        }
}

// ---- Realism (every run) ----

// The research's glitches gone: every note of each instrument, soft and loud, at the defaults, is one slip a period
// once its attack is over, including Timber's octave lock (a loud G4 played G5).
TEST(nightingale_every_note_is_clean_at_the_defaults) {
    for (int inst = 0; inst < 4; ++inst) {
        int bad = 0, all = 0;
        std::string which;
        for (int key = nightingale::kLowestKey[inst]; key <= kHighest[inst]; key += 3)
            for (double vel : {0.25, 0.6, 1.0}) {
                const std::vector<float> s = note(inst, key, vel, 0.9, {{"vibrato", 0.0}});
                ++all;
                if (!helmholtz(s, key, 19200, 19200 - static_cast<size_t>(2 * periodOf(key))))
                    ++bad, which += " " + std::to_string(key) + "@" + std::to_string(static_cast<int>(vel * 100));
            }
        if (verbose()) std::printf("instrument %d: %d of %d not clean:%s\n", inst, bad, all, which.c_str());
        if (bad > all / 20) cawtest::fail(__FILE__, __LINE__, "instrument " + std::to_string(inst) + ":" + which);
    }
    const std::vector<float> g4 = note(0, 67, 1.0, 1.2, {{"vibrato", 0.0}});
    CHECK(helmholtz(g4, 67, 24000, 24000));
}

// In tune: every note within 6 cents at the default bow (pressure 0.5, mid position), velocity 0.6.
TEST(nightingale_plays_in_tune) {
    for (int inst = 0; inst < 4; ++inst) {
        double worst = 0;
        for (int key = nightingale::kLowestKey[inst]; key <= kHighest[inst]; key += 3) {
            const std::vector<float> s = note(inst, key, 0.6, 0.9, {{"vibrato", 0.0}});
            worst = std::max(worst, std::fabs(centsOff(s, key, 19200, 12000)));
        }
        if (verbose()) std::printf("instrument %d: worst %.1f cents\n", inst, worst);
        CHECK(worst < 6.0);
    }
}

// The onset: the pitch settles within the attack and 60 ms more (Timber's jumped for 50-150 ms past it).
TEST(nightingale_onsets_settle_within_the_attack) {
    for (int inst = 0; inst < 4; ++inst) {
        double worst = 0;
        for (int key = nightingale::kLowestKey[inst]; key <= kHighest[inst] - 6; key += 6) {
            const std::vector<float> s = note(inst, key, 0.6, 0.5, {{"vibrato", 0.0}});
            const double T = periodOf(key);
            const size_t w = std::max<size_t>(1440, static_cast<size_t>(3 * T));
            double settled = 0;
            for (size_t at = 0; at + w + static_cast<size_t>(2 * T) + 2 < 19200; at += 480) {
                double best = -2, bl = T;
                for (double L = 0.7 * T; L <= 1.4 * T; L += std::max(0.25, T / 400)) {
                    const double r = ac(s, at, w, L);
                    if (r > best) best = r, bl = L;
                }
                if (std::fabs(1200.0 * std::log2(bl / T)) > 30 || best < 0.8) settled = static_cast<double>(at) / 48000;  // the window's start
            }
            worst = std::max(worst, settled);
        }
        if (verbose()) std::printf("instrument %d: settles by %.0f ms\n", inst, worst * 1000);
        CHECK(worst < 0.12 + 0.06);  // the default attack and 60 ms (the last unsettled window's start)
    }
}

// The bow noise sits about 35 dB under the tone at the default (0.35), on the output only: with Noise 0 the string's
// own motion is unchanged (bit for bit at the bridge, the noise never reaching it).
TEST(nightingale_bow_noise_is_quiet_and_outside_the_string) {
    for (int inst : {0, 2}) {
        const double key = inst == 0 ? 69 : 48;
        const std::vector<float> a = note(inst, key, 0.6, 0.8, {{"noise", 0.35}, {"vibrato", 0.0}});
        const std::vector<float> b = note(inst, key, 0.6, 0.8, {{"noise", 0.0}, {"vibrato", 0.0}});
        std::vector<float> d(a.size());
        for (size_t i = 0; i < a.size(); ++i) d[i] = a[i] - b[i];
        const double tone = powerDb(b, 19200, 9600), noise = powerDb(d, 19200, 9600);
        if (verbose()) std::printf("instrument %d: bow noise %.1f dB under the tone\n", inst, tone - noise);
        CHECK(tone - noise > 28 && tone - noise < 44);
    }
}

// The body: Body 1 is the estimated body, 0 the bare string; at 44.1 kHz too (resampled); finite and bounded.
TEST(nightingale_body_changes_the_colour_not_the_level) {
    for (double sr : {48000.0, 44100.0})
        for (int inst = 0; inst < 4; ++inst) {
            const double key = nightingale::kLowestKey[inst] + 12;
            Values v = {{"variant", static_cast<double>(inst)}, {"vibrato", 0.0}};
            auto p = makeN(v, sr), q = makeN(v, sr);
            modelOf(*q).testBypassBody = true;
            const std::vector<float> a = play(*p, v, {{0.0, -1, key, 0.6}}, 0.8, sr).mono();
            const std::vector<float> b = play(*q, v, {{0.0, -1, key, 0.6}}, 0.8, sr).mono();
            const size_t at = static_cast<size_t>(0.4 * sr), n = static_cast<size_t>(0.3 * sr);
            const double d = powerDb(a, at, n) - powerDb(b, at, n);
            if (verbose()) std::printf("%.0f Hz, instrument %d: body %+.1f dB\n", sr, inst, d);
            CHECK(std::fabs(d) < 9.0);
            double peak = 0;
            for (float x : a) peak = std::max(peak, static_cast<double>(std::fabs(x)));
            CHECK(std::isfinite(peak) && peak < 4.0);
        }
}

TEST(nightingale_gives_the_same_bits_at_any_block_size) {
    const Values v = {{"variant", 0}, {"noise", 0.8}};
    const std::vector<Note> n = {{0.0, 0.3, 62, 0.8}, {0.1, 0.5, 69, 0.5}, {0.2, 0.6, 76, 0.95}};
    Stereo ref;
    for (uint32_t block : {64u, 1u, 37u, 512u}) {
        auto p = makeN(v);
        const Stereo s = play(*p, v, n, 0.8, 48000, block);
        if (block == 64) ref = s;
        else CHECK(s.l == ref.l && s.r == ref.r);
    }
}

TEST(nightingale_presets_load_and_play) {
    const std::vector<BuiltinPreset>* list = nightingale::nightingalePresets(kId);
    CHECK(list && list->size() >= 8);
    if (!list) return;
    for (const BuiltinPreset& pr : *list) {
        Values v;
        for (const auto& [k, x] : pr.values) v.emplace_back(std::string(k), x);
        auto p = makeN(v);
        CHECK(p != nullptr);
        if (!p) continue;
        const std::vector<float> m = play(*p, v, {{0.0, 0.5, 60, 0.7}}, 0.7).mono();
        double peak = 0;
        for (float x : m) peak = std::max(peak, static_cast<double>(std::fabs(x)));
        CHECK(std::isfinite(peak) && peak > 1e-3 && peak < 4.0);
    }
}

TEST(nightingale_matches_its_reference_render) {
    cawtest::References refs("nightingale");
    for (int inst = 0; inst < 4; ++inst) {
        const Values v = {{"variant", static_cast<double>(inst)}};
        auto p = makeN(v);
        const double k = nightingale::kLowestKey[inst];
        const Stereo s = play(*p, v, {{0.0, 0.5, k + 7, 0.7}, {0.3, 0.9, k + 12, 0.5}, {0.6, 1.1, k + 16, 0.9}}, 1.4);
        CHECK_REFERENCE(refs, "nightingale_" + std::to_string(inst), (cawtest::Audio{s.l, s.r}), cawtest::Class::Chaotic);
    }
}
