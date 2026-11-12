// The EQ & Filter group (fx-filters): each effect's response, stability, block sizes, sleep, display, presets and reference renders.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/display.hpp"
#include "caw/library/eq.hpp"
#include "engine.h"
#include "presets.h"
#include "quality.h"
#include "wav.h"
#include "test.h"
#include "tolerance.h"

using namespace caw;

namespace {

constexpr double kPiF = 3.14159265358979323846;
using Values = std::vector<std::pair<std::string, double>>;

const char* const kGroup[] = {"org.caw.ladder", "org.caw.nlfilter", "org.caw.comb",  "org.caw.resonator", "org.caw.formant",
                              "org.caw.disperser", "org.caw.eq.dj",  "org.caw.tilt", "org.caw.geq"};
const uint32_t kGroupDisplay[] = {9, 7, 5, 38, 7, 6, 10, 6, 132};

struct Stereo {
    std::vector<float> l, r;
    size_t size() const { return l.size(); }
};

int paramIndex(const ModuleDescriptor& d, const std::string& id) {
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == id) return static_cast<int>(k);
    cawtest::fail(__FILE__, __LINE__, std::string(d.id) + " has no parameter " + id);
    return -1;
}

std::unique_ptr<ModuleProcessor> make(Engine& e, const char* id) {
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(id);
    CHECK(p != nullptr);
    if (p) CHECK(p->activate(48000, 512));
    return p;
}

Stereo run(ModuleProcessor& p, const Stereo& in, const Values& values = {}, uint32_t block = 64) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    for (const auto& [id, v] : values) {
        const int k = paramIndex(d, id);
        if (k >= 0) params[static_cast<size_t>(k)].value = v;
    }
    Stereo out{std::vector<float>(in.size()), std::vector<float>(in.size())};
    Transport t;
    t.tempo = 120;
    for (size_t start = 0; start < in.size(); start += block) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(block, in.size() - start));
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        AudioProcessBlock b;
        b.input = {ic, 2, n};
        b.output = {oc, 2, n};
        b.frames = n;
        b.sampleRate = 48000;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        b.transport = &t;
        CHECK(p.process(b));
    }
    return out;
}

Stereo silence(size_t n) { return {std::vector<float>(n, 0.0f), std::vector<float>(n, 0.0f)}; }
Stereo sine(double hz, double amp, size_t n) {
    Stereo s = silence(n);
    for (size_t i = 0; i < n; ++i) s.l[i] = s.r[i] = static_cast<float>(amp * detSin(kTwoPi * hz * i / 48000.0));
    return s;
}
Stereo impulse(size_t n, float level = 1.0f) {
    Stereo s = silence(n);
    s.l[0] = s.r[0] = level;
    return s;
}
Stereo noise(size_t n, double amp = 0.3) {
    Stereo s = silence(n);
    uint32_t seed = 777;
    for (size_t i = 0; i < n; ++i) {
        seed = seed * 1664525u + 1013904223u;
        s.l[i] = s.r[i] = static_cast<float>(amp * ((seed >> 8) / 8388608.0 - 1.0));
    }
    return s;
}
// Plucks, noise bursts, a gap of silence and different sides (as effects_test.cpp's music()).
Stereo music(size_t frames) {
    Stereo s = silence(frames);
    uint32_t seed = 12345;
    for (size_t i = 0; i < frames; ++i) {
        const size_t beat = i % 12000, bar = i / 12000;
        if (bar == 3) continue;
        const double env = detExp(-static_cast<double>(beat) / 2400.0);
        seed = seed * 1664525u + 1013904223u;
        const double nz = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * detExp(-static_cast<double>(beat) / 300.0);
        const double f = 110.0 * (1 + bar % 4), t = static_cast<double>(i) / 48000.0;
        const double tone = detSin(kTwoPi * f * t) + 0.5 * detSin(kTwoPi * 2.01 * f * t) + 0.25 * detSin(kTwoPi * 5.3 * f * t);
        s.l[i] = static_cast<float>(0.4 * env * tone + 0.3 * nz);
        s.r[i] = static_cast<float>(0.4 * env * detSin(kTwoPi * 1.5 * f * t) + 0.25 * nz);
    }
    return s;
}

double rms(const std::vector<float>& x, size_t from, size_t to) {
    double s = 0;
    for (size_t i = from; i < to; ++i) s += static_cast<double>(x[i]) * x[i];
    return std::sqrt(s / std::max<size_t>(1, to - from));
}
double peak(const std::vector<float>& x, size_t from = 0, size_t to = ~size_t(0)) {
    double p = 0;
    for (size_t i = from; i < std::min(to, x.size()); ++i) p = std::max(p, std::fabs(static_cast<double>(x[i])));
    return p;
}
double db(double g) { return 20.0 * std::log10(std::max(g, 1e-30)); }
double gainAt(Engine& e, const char* id, const Values& v, double hz, double amp = 0.1) {
    std::unique_ptr<ModuleProcessor> p = make(e, id);
    if (!p) return 0;
    const Stereo in = sine(hz, amp, 48000);
    const Stereo out = run(*p, in, v);
    return db(rms(out.l, 24000, 48000) / rms(in.l, 24000, 48000));
}
// The period (in samples) of a steady signal: the lag in [lo, hi] where it best matches itself, over [from, to).
size_t periodOf(const std::vector<float>& x, size_t from, size_t to, size_t lo, size_t hi) {
    size_t best = lo;
    double most = -1e300;
    for (size_t lag = lo; lag <= hi; ++lag) {
        double c = 0;
        for (size_t i = from; i + lag < to; ++i) c += static_cast<double>(x[i]) * x[i + lag];
        if (c > most) most = c, best = lag;
    }
    return best;
}
// The frequency of a steady tone by its zero crossings (rising) in [from, to).
double pitchOf(const std::vector<float>& x, size_t from, size_t to) {
    size_t first = 0, last = 0, count = 0;
    for (size_t i = from + 1; i < to; ++i)
        if (x[i - 1] < 0.0f && x[i] >= 0.0f) {
            if (!count) first = i;
            last = i;
            ++count;
        }
    return count > 1 ? 48000.0 * (count - 1) / static_cast<double>(last - first) : 0.0;
}

// A reference's name: the effect's id, and " busy" for its busy settings.
std::string caseName(const char* id, bool busy) { return std::string(id) + (busy ? " busy" : ""); }
// How each case is compared with its reference (tolerance.h): all stable (2026-11-12 probes, docs/engine.md).
cawtest::Class effectClass(const char*, bool) { return cawtest::Class::Stable; }

Values busy(const std::string& s) {
    if (s == "org.caw.ladder") return {{"mode", 0}, {"slope", 1}, {"cutoff", 700}, {"resonance", 0.85}, {"drive", 12}, {"bias", 0.3}, {"comp", 0.7}, {"mix", 0.9}};
    if (s == "org.caw.nlfilter") return {{"type", 1}, {"cutoff", 900}, {"q", 10}, {"drive", 20}, {"shape", 2}, {"mix", 0.8}};
    if (s == "org.caw.comb") return {{"tune", 1}, {"note", 50}, {"fine", 20}, {"feedback", -0.8}, {"damping", 0.4}, {"polarity", 1}, {"stereo", 1}, {"spread", 0.5}};
    if (s == "org.caw.resonator") return {{"mode", 3}, {"chord", 1}, {"note", 55}, {"decay", 2}, {"brightness", 0.7}, {"spread", 0.6}, {"mix", 0.6}};
    if (s == "org.caw.formant") return {{"vowel_x", 0.3}, {"vowel_y", 0.4}, {"shift", 3}, {"q", 12}, {"lows", 0.3}, {"highs", 0.2}};
    if (s == "org.caw.disperser") return {{"amount", 0.7}, {"freq", 400}, {"pinch", 0.6}, {"spread", 0.3}, {"mix", 0.8}};
    if (s == "org.caw.eq.dj") return {{"low", 4}, {"mid", -6}, {"high", 3}, {"kill_low", 1}, {"low_x", 180}, {"high_x", 4000}};
    if (s == "org.caw.tilt") return {{"tilt", 6}, {"freq", 1500}, {"q", 0.9}, {"channel", 1}, {"output", -2}};
    return {{"g3", 6}, {"g10", -5}, {"g18", 4}, {"g25", -3}, {"g30", 6}, {"range", 1.2}, {"output", -1}};
}

}  // namespace

// ---------- The whole group ----------

TEST(fx_filters_are_listed_with_good_descriptors_and_presets) {
    Engine e(48000);
    for (const char* id : kGroup) {
        std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(id);
        CHECK(p != nullptr);
        if (!p) continue;
        const ModuleDescriptor& d = p->descriptor();
        CHECK(d.role == ModuleRole::Effect);
        CHECK(validateModuleDescriptor(d) == ModuleValidation::Ok);
        CHECK_EQ(d.latencyFrames, 0u);
        for (uint32_t i = 0; i < d.parameterCount; ++i) {
            const ParameterDescriptor& q = d.parameters[i];
            CHECK(!q.name.empty());
            if ((q.unit == "Hz" || q.unit == "s") && q.curve != ParameterCurve::Exponential)
                cawtest::fail(__FILE__, __LINE__, std::string(id) + "." + std::string(q.id) + " should taper");
        }
        const auto& presets = builtinPresets(id);
        if (presets.size() < 3 || presets.size() > 8) cawtest::fail(__FILE__, __LINE__, std::string(id) + ": 3 to 8 presets");
        for (const BuiltinPreset& pr : presets)
            for (const auto& [k, v] : pr.values) {
                const int at = paramIndex(d, std::string(k));
                if (at < 0) continue;
                const ParameterDescriptor& q = d.parameters[at];
                if (v < q.minimum || v > q.maximum)
                    cawtest::fail(__FILE__, __LINE__, std::string(id) + " preset " + std::string(pr.name) + ": " + std::string(k) + " out of range");
            }
    }
}

TEST(fx_filters_render_the_same_bits_at_any_block_size) {
    Engine e(48000);
    const Stereo in = music(48000 * 2);
    for (const char* id : kGroup)
        for (const Values& v : {Values{}, busy(id)}) {
            std::unique_ptr<ModuleProcessor> a = make(e, id);
            if (!a) continue;
            const Stereo ref = run(*a, in, v, 64);
            for (uint32_t block : {1u, 37u, 500u}) {
                std::unique_ptr<ModuleProcessor> b = make(e, id);
                const Stereo got = run(*b, in, v, block);
                size_t differ = 0;
                for (size_t i = 0; i < in.size(); ++i) differ += got.l[i] != ref.l[i] || got.r[i] != ref.r[i];
                if (differ)
                    cawtest::fail(__FILE__, __LINE__, std::string(id) + (v.empty() ? " default" : " busy") + ": " +
                                                          std::to_string(differ) + " samples differ at block " + std::to_string(block));
            }
        }
}

TEST(fx_filters_stay_finite_and_bounded_whatever_their_knobs) {
    Engine e(48000);
    uint32_t seed = 4242;
    auto rnd = [&] {
        seed = seed * 1664525u + 1013904223u;
        return (seed >> 8) / 16777216.0;
    };
    Stereo square = silence(24000);
    for (size_t i = 0; i < square.size(); ++i) square.l[i] = square.r[i] = (i / 60) % 2 ? 1.0f : -1.0f;
    Stereo dc = silence(24000);
    std::fill(dc.l.begin(), dc.l.end(), 1.0f);
    std::fill(dc.r.begin(), dc.r.end(), -0.5f);
    Stereo loud = music(24000);
    for (float& x : loud.l) x *= 4.0f;
    for (const char* id : kGroup)
        for (int round = 0; round < 24; ++round) {
            std::unique_ptr<ModuleProcessor> p = make(e, id);
            if (!p) break;
            const ModuleDescriptor& d = p->descriptor();
            Values v;
            for (uint32_t k = 0; k < d.parameterCount; ++k) {
                const ParameterDescriptor& q = d.parameters[k];
                double x = q.minimum + (q.maximum - q.minimum) * (round >= 20 ? (round % 2 ? 1.0 : 0.0) : rnd());
                if (q.step > 0) x = q.minimum + std::floor((x - q.minimum) / q.step + 0.5) * q.step;
                v.push_back({std::string(q.id), x});
            }
            const Stereo& in = round % 3 == 0 ? loud : round % 3 == 1 ? square : dc;
            const Stereo out = run(*p, in, v, 64);
            bool finite = true;
            double most = 0;
            for (size_t i = 0; i < out.size(); ++i) {
                finite &= std::isfinite(out.l[i]) && std::isfinite(out.r[i]);
                most = std::max({most, std::fabs(static_cast<double>(out.l[i])), std::fabs(static_cast<double>(out.r[i]))});
            }
            if (!finite || most > 200.0)
                cawtest::fail(__FILE__, __LINE__, std::string(id) + " round " + std::to_string(round) + ": " +
                                                      (finite ? "peak " + std::to_string(most) : std::string("not finite")));
            float shown[kMaxDisplayFloats];
            const uint32_t n = p->readDisplay(shown, kMaxDisplayFloats);
            for (uint32_t k = 0; k < n; ++k)
                if (!std::isfinite(shown[k])) {
                    cawtest::fail(__FILE__, __LINE__, std::string(id) + ": display float " + std::to_string(k) + " is not finite");
                    break;
                }
        }
}

TEST(fx_filters_fall_quiet_after_their_input_stops_and_wake) {
    Engine e(48000);
    for (const char* id : kGroup) {
        std::unique_ptr<ModuleProcessor> p = make(e, id);
        if (!p) continue;
        Stereo in = music(12000);
        in.l.resize(48000 * 12, 0.0f);
        in.r.resize(48000 * 12, 0.0f);
        const Stereo out = run(*p, in);
        if (!p->quiet()) cawtest::fail(__FILE__, __LINE__, std::string(id) + " is not quiet after 11 s of silence");
        CHECK_EQ(out.l.back(), 0.0f);
        const Stereo again = run(*p, sine(440, 0.5, 4800));
        CHECK(!p->quiet());
        CHECK(peak(again.l) > 0.01);
    }
}

TEST(fx_filters_publish_their_display_layouts) {
    Engine e(48000);
    for (size_t k = 0; k < std::size(kGroup); ++k) {
        std::unique_ptr<ModuleProcessor> p = make(e, kGroup[k]);
        if (!p) continue;
        float shown[kMaxDisplayFloats];
        CHECK_EQ(p->readDisplay(shown, kMaxDisplayFloats), 0u);
        run(*p, sine(1000, 0.5, 4800));
        const uint32_t n = p->readDisplay(shown, kMaxDisplayFloats);
        if (n != kGroupDisplay[k]) cawtest::fail(__FILE__, __LINE__, std::string(kGroup[k]) + " publishes " + std::to_string(n) + " floats");
        CHECK_NEAR(shown[0], -6.02, 0.1);  // every one starts with its input peak in dB
    }
}

TEST(fx_filters_match_their_reference_renders) {
    Engine e(48000);
    const Stereo in = music(48000 * 2);
    cawtest::References refs("fx_filters");
    for (const char* id : kGroup)
        for (bool b : {false, true}) {
            std::unique_ptr<ModuleProcessor> p = make(e, id);
            if (!p) continue;
            const Stereo out = run(*p, in, b ? busy(id) : Values{}, 64);
            CHECK_REFERENCE(refs, caseName(id, b), (cawtest::Audio{out.l, out.r}), effectClass(id, b));
        }
}

// ---------- Each effect ----------

TEST(the_ladder_cuts_at_its_slopes_and_sings_at_full_resonance) {
    Engine e(48000);
    const Values lp24 = {{"resonance", 0}, {"cutoff", 1000}, {"comp", 1}};
    CHECK_NEAR(gainAt(e, "org.caw.ladder", lp24, 100), 0.0, 0.5);
    const double at8k = gainAt(e, "org.caw.ladder", lp24, 8000);
    CHECK(at8k < -60 && at8k > -80);  // 3 octaves at 24 dB/octave, a bit more near the top (bilinear)
    const double at8k12 = gainAt(e, "org.caw.ladder", {{"resonance", 0}, {"cutoff", 1000}, {"slope", 0}}, 8000);
    CHECK(at8k12 < -30 && at8k12 > -45);
    CHECK(gainAt(e, "org.caw.ladder", {{"resonance", 0}, {"cutoff", 1000}, {"mode", 2}}, 100) < -60);   // high-pass
    CHECK_NEAR(gainAt(e, "org.caw.ladder", {{"resonance", 0}, {"cutoff", 1000}, {"mode", 2}, {"comp", 0}}, 15000), 0.0, 1.0);
    CHECK(gainAt(e, "org.caw.ladder", {{"resonance", 0}, {"cutoff", 1000}, {"mode", 1}}, 100) < -25);   // band-pass
    CHECK_NEAR(gainAt(e, "org.caw.ladder", {{"resonance", 0}, {"cutoff", 1000}, {"mode", 1}}, 1000), 0.0, 0.5);
    // Resonance raises a peak at the cutoff.
    const Values ringing = {{"resonance", 0.8}, {"cutoff", 1000}, {"comp", 0}};
    CHECK(gainAt(e, "org.caw.ladder", ringing, 1000) - gainAt(e, "org.caw.ladder", ringing, 100) > 12.0);
    // Full resonance: a tap starts a tone that keeps ringing at the cutoff, bounded.
    for (double hz : {220.0, 1000.0, 3000.0}) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.ladder");
        Stereo in = impulse(48000 * 2, 0.5f);
        const Stereo out = run(*p, in, {{"resonance", 1.0}, {"cutoff", hz}});
        CHECK(rms(out.l, 72000, 96000) > 0.05);
        CHECK(peak(out.l) < 4.0);
        const double f = pitchOf(out.l, 48000, 96000);
        if (std::fabs(f / hz - 1.0) > 0.04)
            cawtest::fail(__FILE__, __LINE__, "self-oscillation at " + std::to_string(hz) + " Hz sings at " + std::to_string(f));
    }
    // Below the threshold it dies away.
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.ladder");
    const Stereo out = run(*p, impulse(48000, 0.5f), {{"resonance", 0.85}, {"cutoff", 1000}});
    CHECK(peak(out.l, 40000) < 1e-4);
}

TEST(the_ladder_drive_adds_harmonics_and_high_quality_oversamples) {
    Engine e(48000);
    auto thd = [&](double drive) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.ladder");
        const Stereo out = run(*p, sine(200, 0.5, 48000), {{"cutoff", 18000}, {"resonance", 0}, {"drive", drive}});
        // The 200 Hz fundamental removed by projection; what's left is distortion.
        double c = 0, s = 0;
        for (size_t i = 24000; i < 48000; ++i) c += out.l[i] * std::cos(kTwoPi * 200 * i / 48000.0), s += out.l[i] * std::sin(kTwoPi * 200 * i / 48000.0);
        c *= 2.0 / 24000, s *= 2.0 / 24000;
        double res = 0;
        for (size_t i = 24000; i < 48000; ++i) {
            const double r = out.l[i] - c * std::cos(kTwoPi * 200 * i / 48000.0) - s * std::sin(kTwoPi * 200 * i / 48000.0);
            res += r * r;
        }
        return std::sqrt(res / 24000) / rms(out.l, 24000, 48000);
    };
    CHECK(thd(0) < 0.05);
    CHECK(thd(24) > 0.1);
}

TEST(the_nonlinear_filter_is_a_clean_svf_when_clean_and_bends_when_driven) {
    Engine e(48000);
    const Values clean = {{"shape", 0}, {"cutoff", 1000}, {"q", 0.707}, {"drive", 0}};
    CHECK_NEAR(gainAt(e, "org.caw.nlfilter", clean, 100), 0.0, 0.2);
    CHECK_NEAR(gainAt(e, "org.caw.nlfilter", clean, 1000), -3.0, 0.3);
    const double at8k = gainAt(e, "org.caw.nlfilter", clean, 8000);
    CHECK(at8k < -33 && at8k > -40);
    Values hp = clean;
    hp.push_back({"type", 2});
    CHECK(gainAt(e, "org.caw.nlfilter", hp, 100) < -35);
    Values ap = clean;
    ap.push_back({"type", 4});
    for (double hz : {100.0, 1000.0, 9000.0}) CHECK_NEAR(gainAt(e, "org.caw.nlfilter", ap, hz), 0.0, 0.2);
    // Driven hard with a high Q, every shape stays bounded and sounds different from clean.
    std::unique_ptr<ModuleProcessor> c = make(e, "org.caw.nlfilter");
    const Stereo ref = run(*c, sine(300, 0.8, 24000), {{"shape", 0}, {"q", 20}, {"drive", 30}, {"cutoff", 300}});
    for (int shape = 1; shape <= 5; ++shape) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.nlfilter");
        const Stereo out = run(*p, sine(300, 0.8, 24000), {{"shape", shape}, {"q", 20}, {"drive", 30}, {"cutoff", 300}});
        CHECK(peak(out.l) < 10.0);
        CHECK(std::fabs(rms(out.l, 12000, 24000) - rms(ref.l, 12000, 24000)) > 0.01);
    }
}

TEST(the_comb_is_tuned_by_hz_or_note_and_its_polarity_flips_the_peaks) {
    Engine e(48000);
    // The first echo of an impulse comes one period later (no damping: no lag correction).
    for (auto [values, period] : {std::pair<Values, double>{{{"freq", 480}, {"damping", 0}}, 100.0},
                                  std::pair<Values, double>{{{"tune", 1}, {"note", 69}, {"damping", 0}}, 48000.0 / 440.0}}) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.comb");
        const Stereo out = run(*p, impulse(4800), values);
        size_t best = 1;
        for (size_t i = 2; i < 300; ++i)
            if (std::fabs(out.l[i]) > std::fabs(out.l[best])) best = i;
        CHECK(std::fabs(static_cast<double>(best) - period) <= 1.0);
    }
    // Plus: a peak at DC and at f; minus: a trough there. Feedback 0.9 at 480 Hz.
    const Values plus = {{"freq", 480}, {"feedback", 0.9}, {"damping", 0}};
    Values minus = plus;
    minus.push_back({"polarity", 1});
    CHECK(gainAt(e, "org.caw.comb", plus, 480) - gainAt(e, "org.caw.comb", plus, 720) > 15);
    CHECK(gainAt(e, "org.caw.comb", minus, 720) - gainAt(e, "org.caw.comb", minus, 480) > 15);
    // Negative feedback rings at the odd multiples of f / 2.
    const Values neg = {{"freq", 480}, {"feedback", -0.9}, {"damping", 0}};
    CHECK(gainAt(e, "org.caw.comb", neg, 240) - gainAt(e, "org.caw.comb", neg, 480) > 15);
    // Damping keeps it in tune: the loop's lag is taken off the line.
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.comb");
    const Stereo out = run(*p, impulse(48000), {{"freq", 200}, {"feedback", 0.99}, {"damping", 0.6}});
    const size_t period = periodOf(out.l, 12000, 36000, 200, 300);
    if (period < 239 || period > 241) cawtest::fail(__FILE__, __LINE__, "the damped comb's period is " + std::to_string(period));
}

TEST(the_resonator_rings_at_its_note_for_its_decay) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.resonator");
    const Stereo out = run(*p, impulse(48000 * 2, 1.0f), {{"mode", 2}, {"note", 57}, {"decay", 1.0}, {"brightness", 0}, {"spread", 0}, {"mix", 1}});
    // Modal with no brightness: the root rings longest; its pitch and decay (60 dB a second: 24 dB in 0.4 s).
    CHECK_NEAR(pitchOf(out.l, 24000, 48000), 220.0, 3.0);
    const double early = rms(out.l, 2400, 7200), late = rms(out.l, 21600, 26400);
    const double fall = db(late / early);
    if (fall < -32 || fall > -17) cawtest::fail(__FILE__, __LINE__, "the resonator fell " + std::to_string(fall) + " dB in 0.4 s");
    // Every mode keeps the bank under the ceiling, even fed a loud tone at its root.
    for (int mode = 0; mode < 5; ++mode) {
        std::unique_ptr<ModuleProcessor> q = make(e, "org.caw.resonator");
        const Stereo o = run(*q, sine(220, 1.0, 24000), {{"mode", mode}, {"note", 57}, {"decay", 10}, {"mix", 1}});
        CHECK(peak(o.l) <= 1.0001);
        CHECK(rms(o.l, 12000, 24000) > 0.05);
    }
}

TEST(the_formant_filter_lands_on_each_vowel_and_shifts) {
    Engine e(48000);
    const Values a = {{"vowel_x", 0.5}, {"vowel_y", 0.85}};
    const Values i = {{"vowel_x", 0.1}, {"vowel_y", 0.1}};
    CHECK(gainAt(e, "org.caw.formant", a, 730) - gainAt(e, "org.caw.formant", a, 2290) > 10);
    CHECK(gainAt(e, "org.caw.formant", i, 2290) - gainAt(e, "org.caw.formant", i, 730) > 5);
    CHECK_NEAR(gainAt(e, "org.caw.formant", a, 730), 6.0, 1.0);  // F1 6 dB up
    Values up = a;
    up.push_back({"shift", 12});
    CHECK(gainAt(e, "org.caw.formant", up, 1460) - gainAt(e, "org.caw.formant", up, 730) > 6);
    Values lows = a;
    lows.push_back({"lows", 1});
    CHECK(gainAt(e, "org.caw.formant", lows, 80) - gainAt(e, "org.caw.formant", a, 80) > 10);
}

TEST(the_disperser_keeps_the_level_and_delays_around_its_frequency) {
    Engine e(48000);
    for (double hz : {100.0, 1000.0, 10000.0}) CHECK_NEAR(gainAt(e, "org.caw.disperser", {{"amount", 1}}, hz), 0.0, 0.05);
    // The energy of an impulse's 1 kHz region comes later with more stages.
    auto centre = [&](double amount) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.disperser");
        const Stereo out = run(*p, impulse(24000), {{"amount", amount}, {"freq", 1000}});
        double m = 0, w = 0;
        for (size_t k = 0; k < out.size(); ++k) m += k * out.l[k] * out.l[k], w += out.l[k] * out.l[k];
        return m / w;
    };
    const double c0 = centre(0.0), c1 = centre(0.25), c2 = centre(1.0);
    CHECK(c0 < 1.0);
    CHECK(c1 > 5.0);
    CHECK(c2 > 3.0 * c1);
}

TEST(the_three_band_eq_sums_flat_and_kills_its_bands) {
    Engine e(48000);
    for (double hz : {40.0, 250.0, 1000.0, 2500.0, 12000.0}) CHECK_NEAR(gainAt(e, "org.caw.eq.dj", {}, hz), 0.0, 0.05);
    CHECK(gainAt(e, "org.caw.eq.dj", {{"kill_low", 1}}, 50) < -40);
    CHECK(gainAt(e, "org.caw.eq.dj", {{"kill_mid", 1}}, 800) < -25);
    CHECK(gainAt(e, "org.caw.eq.dj", {{"kill_high", 1}}, 12000) < -40);
    CHECK_NEAR(gainAt(e, "org.caw.eq.dj", {{"kill_low", 1}}, 8000), 0.0, 0.1);
    CHECK_NEAR(gainAt(e, "org.caw.eq.dj", {{"low", -12}}, 40), -12.0, 0.5);
    CHECK_NEAR(gainAt(e, "org.caw.eq.dj", {{"high", 6}}, 15000), 6.0, 0.3);
}

TEST(the_tilt_eq_tilts_around_its_pivot) {
    Engine e(48000);
    const Values t = {{"tilt", 6}, {"freq", 1000}};
    CHECK_NEAR(gainAt(e, "org.caw.tilt", t, 30), -3.0, 0.3);
    CHECK_NEAR(gainAt(e, "org.caw.tilt", t, 16000), 3.0, 0.4);
    CHECK_NEAR(gainAt(e, "org.caw.tilt", t, 1000), 0.0, 0.5);
    // Side only: a mono signal passes untouched.
    CHECK_NEAR(gainAt(e, "org.caw.tilt", {{"tilt", 6}, {"channel", 2}}, 16000), 0.0, 0.01);
}

TEST(the_graphic_eq_hits_its_band_gains_despite_their_overlap) {
    Engine e(48000);
    for (double hz : {50.0, 1000.0, 12000.0}) CHECK_NEAR(gainAt(e, "org.caw.geq", {}, hz), 0.0, 0.01);
    CHECK_NEAR(gainAt(e, "org.caw.geq", {{"g18", 6}}, 1000), 6.0, 0.6);
    // All bands up 6 dB: flat at +6 across the range (each bell alone would sum far higher).
    Values all;
    for (int b = 1; b <= 31; ++b) all.push_back({"g" + std::to_string(b), 6.0});
    for (double hz : {100.0, 440.0, 1000.0, 3150.0, 8000.0}) CHECK_NEAR(gainAt(e, "org.caw.geq", all, hz), 6.0, 0.6);
    // A zig-zag lands near each target at the centres.
    Values zig;
    for (int b = 1; b <= 31; ++b) zig.push_back({"g" + std::to_string(b), b % 2 ? 6.0 : -6.0});
    CHECK(gainAt(e, "org.caw.geq", zig, 1000) < -2.0);  // band 18 (1 kHz) at -6
    CHECK(gainAt(e, "org.caw.geq", zig, 800) > 2.0);    // band 17 (800 Hz) at +6
    // Range scales the curve.
    CHECK_NEAR(gainAt(e, "org.caw.geq", {{"g18", 6}, {"range", 0.5}}, 1000), 3.0, 0.4);
}

TEST(the_eq_has_96_db_cuts) {
    lib::EqFilter cut;
    cut.set(lib::EqType::LowCut96, 1000.0, 0.0, 0.70710678, 48000);
    CHECK_NEAR(10 * std::log10(cut.magnitude2(std::tan(kPiF * 1000 / 48000))), -3.01, 0.05);
    const double half = 10 * std::log10(cut.magnitude2(std::tan(kPiF * 500 / 48000)));
    CHECK(half < -90 && half > -100);
    lib::EqFilter hi;
    hi.set(lib::EqType::HighCut96, 1000.0, 0.0, 0.70710678, 48000);
    CHECK(10 * std::log10(hi.magnitude2(std::tan(kPiF * 2000 / 48000))) < -90);
}
