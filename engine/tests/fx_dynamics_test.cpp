// fx-dynamics: the Dynamics and Drive effects (dynamics, multiband/OTT, de-esser, clipper, phase distortion, the saturator's new modes).
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <iterator>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/display.hpp"
#include "engine.h"
#include "presets.h"
#include "quality.h"
#include "test.h"

using namespace caw;

namespace {

using Values = std::vector<std::pair<std::string, double>>;

const char* const kNew[] = {"org.caw.dynamics", "org.caw.multiband", "org.caw.deesser", "org.caw.clipper", "org.caw.phasedist"};
const uint32_t kDisplaySizes[] = {14, 26, 9, 75, 10};

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

// `in` through p in `block`-frame blocks with `values` over the defaults; `change` (frame, id, value) moves one
// knob from that frame on.
struct Change {
    size_t at;
    std::string id;
    double value;
};
Stereo run(ModuleProcessor& p, const Stereo& in, const Values& values = {}, uint32_t block = 64,
           const std::vector<Change>& changes = {}) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    for (const auto& [id, v] : values) {
        const int k = paramIndex(d, id);
        if (k >= 0) params[static_cast<size_t>(k)].value = v;
    }
    Stereo out;
    out.l.resize(in.size());
    out.r.resize(in.size());
    Transport t;
    t.tempo = 120;
    for (size_t start = 0; start < in.size(); start += block) {
        for (const Change& c : changes)
            if (c.at >= start && c.at < start + block) params[static_cast<size_t>(paramIndex(d, c.id))].value = c.value;
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

Stereo silence(size_t frames) { return {std::vector<float>(frames, 0.0f), std::vector<float>(frames, 0.0f)}; }
Stereo sine(double hz, double amp, size_t frames) {
    Stereo s = silence(frames);
    for (size_t i = 0; i < frames; ++i) s.l[i] = s.r[i] = static_cast<float>(amp * detSin(kTwoPi * hz * i / 48000.0));
    return s;
}
Stereo square(double hz, double amp, size_t frames) {
    Stereo s = silence(frames);
    const size_t half = static_cast<size_t>(24000.0 / hz);
    for (size_t i = 0; i < frames; ++i) s.l[i] = s.r[i] = static_cast<float>((i / half) % 2 ? -amp : amp);
    return s;
}
// The effects suite's test music (effects_test.cpp's music()): plucked partials and noise bursts, a gap of silence.
Stereo music(size_t frames) {
    Stereo s = silence(frames);
    uint32_t seed = 12345;
    for (size_t i = 0; i < frames; ++i) {
        const size_t beat = i % 12000, bar = i / 12000;
        if (bar == 3) continue;
        const double env = detExp(-static_cast<double>(beat) / 2400.0);
        seed = seed * 1664525u + 1013904223u;
        const double noise = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * detExp(-static_cast<double>(beat) / 300.0);
        const double f = 110.0 * (1 + bar % 4);
        const double t = static_cast<double>(i) / 48000.0;
        const double tone = detSin(kTwoPi * f * t) + 0.5 * detSin(kTwoPi * 2.01 * f * t) + 0.25 * detSin(kTwoPi * 5.3 * f * t);
        s.l[i] = static_cast<float>(0.4 * env * tone + 0.3 * noise);
        s.r[i] = static_cast<float>(0.4 * env * detSin(kTwoPi * 1.5 * f * t) + 0.25 * noise);
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
// The level of frequency `hz` in x[from, to) (a single DFT bin, amplitude of a sine).
double tone(const std::vector<float>& x, double hz, size_t from, size_t to) {
    double re = 0, im = 0;
    for (size_t i = from; i < to; ++i) {
        const double w = kTwoPi * hz * static_cast<double>(i) / 48000.0;
        re += x[i] * std::cos(w);
        im += x[i] * std::sin(w);
    }
    return 2.0 * std::sqrt(re * re + im * im) / static_cast<double>(to - from);
}
// The biggest step between neighbouring samples (a click shows as a jump).
double biggestStep(const std::vector<float>& x, size_t from, size_t to) {
    double m = 0;
    for (size_t i = from + 1; i < to; ++i) m = std::max(m, std::fabs(static_cast<double>(x[i]) - x[i - 1]));
    return m;
}

uint64_t hash(const Stereo& s) {
    uint64_t h = 1469598103934665603ull;
    auto mix = [&](float f) {
        uint32_t bits;
        std::memcpy(&bits, &f, 4);
        for (int k = 0; k < 4; ++k) h = (h ^ ((bits >> (8 * k)) & 255u)) * 1099511628211ull;
    };
    for (size_t i = 0; i < s.size(); ++i) mix(s.l[i]), mix(s.r[i]);
    return h;
}

// Every knob away from its default, so each path runs.
Values busy(const std::string& s) {
    if (s == "org.caw.dynamics")
        return {{"low_threshold", -36}, {"low_ratio", 3}, {"high_threshold", -20}, {"high_ratio", 5}, {"knee", 9}, {"attack", 2},
                {"release", 80}, {"range", 18}, {"detect", 1}, {"in_gain", 4}, {"out_gain", -2}, {"mix", 0.8}};
    if (s == "org.caw.multiband")
        return {{"mode", 0}, {"depth", 0.8}, {"time", 0.5}, {"upward", 0.7}, {"downward", 0.9}, {"xover_low", 200}, {"xover_high", 3000},
                {"in_gain", 3}, {"out_gain", -2}, {"b1_down_thr", -30}, {"b1_down_ratio", 6}, {"b1_up_thr", -50}, {"b1_up_ratio", 3},
                {"b2_gain", 2}, {"b2_down_ratio", 50}, {"b3_up_ratio", 50}, {"b3_attack", 1}, {"b3_release", 40}};
    if (s == "org.caw.multiband_ott") return {{"depth", 1}, {"time", 0.3}, {"upward", 0.8}};
    if (s == "org.caw.deesser") return {{"freq", 4000}, {"threshold", -40}, {"range", 18}, {"release", 30}, {"mode", 1}};
    if (s == "org.caw.clipper")
        return {{"mode", 1}, {"drive", 12}, {"ceiling", -6}, {"softness", 0.7}, {"oversample", 4}, {"output", 3}, {"mix", 0.8}};
    if (s == "org.caw.clipper_master") return {{"mode", 2}, {"drive", 9}, {"master", 1}, {"oversample", 3}};
    if (s == "org.caw.phasedist") return {{"drive", 0.8}, {"normalize", 0.6}, {"tone", 2000}, {"bias", 0.2}, {"spread", 0.4}, {"mix", 0.7}};
    return {};
}

// The cases each test runs: the defaults and the busy settings of every new effect, plus the saturator's new modes.
struct Case {
    const char* id;
    std::string name;
    Values values;
};
std::vector<Case> cases() {
    std::vector<Case> c;
    for (const char* id : kNew) {
        c.push_back({id, std::string(id) + " default", {}});
        c.push_back({id, std::string(id) + " busy", busy(id)});
    }
    c.push_back({"org.caw.multiband", "org.caw.multiband ott", busy("org.caw.multiband_ott")});
    c.push_back({"org.caw.clipper", "org.caw.clipper master", busy("org.caw.clipper_master")});
    const char* modes[] = {"fuzz", "rectify", "trifold", "bitshape", "fat"};
    for (int m = 0; m < 5; ++m)
        c.push_back({"org.caw.saturator", std::string("org.caw.saturator ") + modes[m],
                     {{"mode", 6.0 + m}, {"drive", 14}, {"bias", 0.2}, {"bits", 5}, {"spread", 0.4}, {"dynamics", 0.5}, {"mix", 0.9}}});
    return c;
}

}  // namespace

TEST(fx_dynamics_effects_are_listed_with_good_descriptors_and_presets) {
    Engine e(48000);
    for (const char* id : kNew) {
        std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(id);
        CHECK(p != nullptr);
        if (!p) continue;
        const ModuleDescriptor& d = p->descriptor();
        CHECK(d.role == ModuleRole::Effect);
        CHECK(validateModuleDescriptor(d) == ModuleValidation::Ok);
        for (uint32_t i = 0; i < d.parameterCount; ++i) {
            const ParameterDescriptor& q = d.parameters[i];
            if ((q.unit == "Hz" || (q.unit == "ms" && q.minimum > 0)) && q.curve != ParameterCurve::Exponential)
                cawtest::fail(__FILE__, __LINE__, std::string(d.id) + "." + std::string(q.id) + " should taper");
        }
    }
    CHECK_EQ(e.createNativeComponent("org.caw.phasedist")->descriptor().latencyFrames, 48u);
    CHECK_EQ(e.createNativeComponent("org.caw.clipper")->descriptor().latencyFrames, 0u);
    // 3 to 8 presets each, naming only real parameters within their ranges.
    for (const char* id : {"org.caw.dynamics", "org.caw.multiband", "org.caw.deesser", "org.caw.clipper", "org.caw.phasedist",
                           "org.caw.saturator"}) {
        const auto& presets = builtinPresets(id);
        if (presets.size() < 3 || presets.size() > 8) cawtest::fail(__FILE__, __LINE__, std::string(id) + ": preset count");
        const ModuleDescriptor& d = e.createNativeComponent(id)->descriptor();
        for (const BuiltinPreset& pr : presets)
            for (const auto& [k, v] : pr.values) {
                const int at = paramIndex(d, std::string(k));
                if (at < 0) continue;
                const ParameterDescriptor& q = d.parameters[at];
                if (v < q.minimum || v > q.maximum)
                    cawtest::fail(__FILE__, __LINE__, std::string(id) + " " + std::string(pr.name) + ": " + std::string(k) + " out of range");
            }
    }
}

TEST(fx_dynamics_effects_render_the_same_bits_at_any_block_size_through_sleep_and_wake) {
    Engine e(48000);
    const Stereo in = music(48000 * 2);
    for (const Case& c : cases()) {
        std::unique_ptr<ModuleProcessor> a = make(e, c.id);
        if (!a) continue;
        const Stereo ref = run(*a, in, c.values, 64);
        for (uint32_t block : {1u, 37u, 500u}) {
            std::unique_ptr<ModuleProcessor> b = make(e, c.id);
            const Stereo got = run(*b, in, c.values, block);
            size_t differ = 0;
            for (size_t i = 0; i < in.size(); ++i) differ += got.l[i] != ref.l[i] || got.r[i] != ref.r[i];
            if (differ)
                cawtest::fail(__FILE__, __LINE__, c.name + ": " + std::to_string(differ) + " samples differ at block " + std::to_string(block));
        }
    }
}

TEST(fx_dynamics_effects_stay_finite_and_bounded_whatever_their_knobs) {
    Engine e(48000);
    uint32_t seed = 7;
    auto rnd = [&] {
        seed = seed * 1664525u + 1013904223u;
        return (seed >> 8) / 16777216.0;
    };
    Stereo sq = square(100, 1.0, 24000), dc = silence(24000), loud = music(24000);
    std::fill(dc.l.begin(), dc.l.end(), 1.0f);
    std::fill(dc.r.begin(), dc.r.end(), -0.5f);
    for (float& x : loud.l) x *= 4.0f;
    for (const char* id : {"org.caw.dynamics", "org.caw.multiband", "org.caw.deesser", "org.caw.clipper", "org.caw.phasedist", "org.caw.saturator"}) {
        for (int round = 0; round < 15; ++round) {
            std::unique_ptr<ModuleProcessor> p = make(e, id);
            if (!p) break;
            const ModuleDescriptor& d = p->descriptor();
            Values v;
            for (uint32_t k = 0; k < d.parameterCount; ++k) {
                const ParameterDescriptor& q = d.parameters[k];
                double x = q.minimum + (q.maximum - q.minimum) * rnd();
                if (q.step > 0) x = q.minimum + std::floor((x - q.minimum) / q.step + 0.5) * q.step;
                v.push_back({std::string(q.id), x});
            }
            const Stereo& in = round % 3 == 0 ? loud : round % 3 == 1 ? sq : dc;
            const Stereo out = run(*p, in, v, 64);
            bool finite = true;
            double most = 0;
            for (size_t i = 0; i < out.size(); ++i) {
                finite &= std::isfinite(out.l[i]) && std::isfinite(out.r[i]);
                most = std::max({most, std::fabs(static_cast<double>(out.l[i])), std::fabs(static_cast<double>(out.r[i]))});
            }
            // Every gain knob at its top on a +12 dBFS input multiplies out to about 60 dB (in, band, out gains and
            // upward expansion): bounded, not quiet.
            if (!finite || most > 4000.0)
                cawtest::fail(__FILE__, __LINE__, std::string(id) + " round " + std::to_string(round) + ": " +
                                                      (finite ? "peak " + std::to_string(most) : std::string("not finite")));
            float shown[kMaxDisplayFloats];
            const uint32_t n = p->readDisplay(shown, kMaxDisplayFloats);
            for (uint32_t k = 0; k < n; ++k) CHECK(std::isfinite(shown[k]));
        }
    }
}

TEST(fx_dynamics_effects_fall_quiet_publish_their_display_and_match_their_goldens) {
    Engine e(48000);
    for (size_t k = 0; k < std::size(kNew); ++k) {
        std::unique_ptr<ModuleProcessor> p = make(e, kNew[k]);
        float shown[kMaxDisplayFloats];
        CHECK_EQ(p->readDisplay(shown, kMaxDisplayFloats), 0u);
        run(*p, sine(1000, 0.5, 4800));
        const uint32_t n = p->readDisplay(shown, kMaxDisplayFloats);
        if (n != kDisplaySizes[k]) cawtest::fail(__FILE__, __LINE__, std::string(kNew[k]) + " publishes " + std::to_string(n));
        CHECK_NEAR(shown[0], -6.02, 0.1);  // each starts with its input peak dB
        Stereo in = music(12000);
        in.l.resize(48000 * 4, 0.0f);
        in.r.resize(48000 * 4, 0.0f);
        const Stereo out = run(*p, in);
        if (!p->quiet()) cawtest::fail(__FILE__, __LINE__, std::string(kNew[k]) + " is not quiet after silence");
        CHECK_EQ(out.l.back(), 0.0f);
        CHECK(peak(run(*p, sine(440, 0.5, 4800)).l) > 0.01);
    }
    struct Golden {
        const char* name;
        uint64_t hash;
    };
    const Golden goldens[] = {
#include "fx_dynamics_golden.inc"
    };
    const Stereo in = music(48000 * 2);
    for (const Case& c : cases()) {
        std::unique_ptr<ModuleProcessor> p = make(e, c.id);
        const uint64_t h = hash(run(*p, in, c.values, 64));
        const Golden* g = nullptr;
        for (const Golden& x : goldens)
            if (c.name == x.name) g = &x;
        if (!g || g->hash != h) {
            char buf[200];
            std::snprintf(buf, sizeof buf, "    {\"%s\", 0x%016llxull},", c.name.c_str(), static_cast<unsigned long long>(h));
            cawtest::fail(__FILE__, __LINE__, buf);
        }
    }
}

// ---------- Dynamics ----------

// The steady gain (dB) of the Dynamics on a 100 Hz square at `levelDb` (its peak follower holds still on a square).
double dynGain(Engine& e, double levelDb, const Values& v) {
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.dynamics");
    const Stereo in = square(100, std::pow(10.0, levelDb / 20.0), 24000);
    const Stereo out = run(*p, in, v);
    return db(peak(out.l, 12000) / peak(in.l, 12000));
}

TEST(dynamics_compresses_and_expands_above_and_below_its_thresholds) {
    Engine e(48000);
    const Values base = {{"knee", 0}, {"low_threshold", -30}, {"high_threshold", -20}, {"range", 48}};
    auto with = [&](Values more) {
        Values v = base;
        v.insert(v.end(), more.begin(), more.end());
        return v;
    };
    // Downward above the high threshold: 14 dB over at 4:1 comes out 3.5 dB over (-10.5 dB).
    CHECK_NEAR(dynGain(e, -6, with({{"high_ratio", 4}, {"low_ratio", 1}})), -10.5, 0.1);
    // Upward expansion above it: 1:2 doubles the 14 dB (+14 dB).
    CHECK_NEAR(dynGain(e, -6, with({{"high_ratio", 0.5}, {"low_ratio", 1}})), 14.0, 0.1);
    // Upward compression below the low threshold: 20 dB under at 2:1 is lifted by 10 dB.
    CHECK_NEAR(dynGain(e, -50, with({{"low_ratio", 2}, {"high_ratio", 1}})), 10.0, 0.1);
    // Downward expansion below it: 1:2 pushes it 20 dB further down.
    CHECK_NEAR(dynGain(e, -50, with({{"low_ratio", 0.5}, {"high_ratio", 1}})), -20.0, 0.1);
    // Between the thresholds nothing changes; the range holds the lift.
    CHECK_NEAR(dynGain(e, -25, with({{"low_ratio", 4}, {"high_ratio", 4}})), 0.0, 0.05);
    CHECK_NEAR(dynGain(e, -70, with({{"low_ratio", 10}, {"high_ratio", 1}, {"range", 12}})), 12.0, 0.1);
    // In and out gain.
    CHECK_NEAR(dynGain(e, -40, with({{"low_ratio", 1}, {"high_ratio", 1}, {"in_gain", 6}, {"out_gain", -3}})), 3.0, 0.05);
}

// ---------- Multiband ----------

TEST(multiband_bands_sum_flat_and_ott_lifts_quiet_and_holds_loud) {
    Engine e(48000);
    // No compression and no band gain: the split sums to an all-pass, so every frequency keeps its level.
    const Values flat = {{"mode", 0}, {"depth", 1}, {"b1_down_ratio", 1}, {"b2_down_ratio", 1}, {"b3_down_ratio", 1},
                         {"b1_up_ratio", 1}, {"b2_up_ratio", 1}, {"b3_up_ratio", 1}};
    for (double hz : {40.0, 88.3, 300.0, 2500.0, 9000.0}) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.multiband");
        const Stereo in = sine(hz, 0.25, 48000);
        const Stereo out = run(*p, in, flat);
        CHECK_NEAR(db(rms(out.l, 24000, 48000) / rms(in.l, 24000, 48000)), 0.0, 0.05);
    }
    // OTT at full depth: a quiet sine comes up a lot, a loud one comes down to near the threshold plus makeup.
    auto level = [&](double amp) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.multiband");
        const Stereo out = run(*p, sine(1000, amp, 48000), {{"mode", 1}, {"depth", 1}});
        return db(rms(out.l, 24000, 48000) * std::sqrt(2.0));
    };
    const double quiet = level(0.003), loud = level(0.5);  // -50 dB and -6 dB peaks
    CHECK(quiet > -40.0);        // lifted by more than 10 dB (measured 2026-11-11: -32)
    CHECK(loud < -15.0);         // held down (measured: -18.5)
    CHECK(loud - quiet < 20.0);  // 44 dB apart in, under half that out
    // The display: per band, the mid band reducing on the loud sine.
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.multiband");
    run(*p, sine(1000, 0.5, 24000), {{"mode", 1}});
    float shown[kMaxDisplayFloats];
    CHECK_EQ(p->readDisplay(shown, kMaxDisplayFloats), 26u);
    CHECK(shown[5 + 7 * 1 + 3] > 10.0);  // mid: most cut
    CHECK_NEAR(shown[3], 88.3, 0.01);
}

// ---------- De-esser ----------

TEST(the_deesser_turns_down_sibilance_and_leaves_the_body) {
    Engine e(48000);
    auto gain = [&](double hz, const Values& v) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.deesser");
        const Stereo in = sine(hz, 0.3, 24000);
        const Stereo out = run(*p, in, v);
        return db(rms(out.l, 12000, 24000) / rms(in.l, 12000, 24000));
    };
    CHECK(gain(10000, {{"threshold", -40}, {"range", 12}}) < -8.0);   // well over: down by nearly the range
    CHECK(gain(10000, {{"threshold", -40}, {"range", 12}}) > -12.1);  // never past it
    CHECK_NEAR(gain(300, {{"threshold", -40}, {"range", 12}}), 0.0, 0.1);  // split: the body untouched
    CHECK_NEAR(gain(10000, {{"threshold", 0}}), 0.0, 0.05);             // under the threshold: transparent
    // A mode change while sibilance plays cross-fades (no jump bigger than the sine's own steps).
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.deesser");
    const Stereo out = run(*p, sine(7000, 0.3, 24000), {{"threshold", -40}}, 64, {{12000, "mode", 1}});
    CHECK(biggestStep(out.l, 11000, 14000) < 0.3 * 2 * kTwoPi * 7000 / 48000 * 1.05);
}

// ---------- Clipper ----------

TEST(the_clipper_holds_its_ceiling_and_clip_to_0_db_never_passes_full_scale) {
    Engine e(48000);
    Stereo loud = music(48000);
    for (float& x : loud.l) x *= 4.0f;
    for (float& x : loud.r) x *= 3.0f;
    for (int mode = 0; mode < 3; ++mode)
        for (int os = 0; os < 5; ++os) {
            std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.clipper");
            const Stereo out = run(*p, loud, {{"mode", mode}, {"drive", 12}, {"master", 1}, {"oversample", os}});
            CHECK(peak(out.l) <= 1.0);
            CHECK(peak(out.r) <= 1.0);
        }
    // Hard at -6 dB: the sample peak sits at the ceiling (the half-bands' ripple aside).
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.clipper");
    const Stereo out = run(*p, sine(200, 1.0, 24000), {{"mode", 0}, {"ceiling", -6}, {"oversample", 1}});
    CHECK_NEAR(db(peak(out.l, 12000)), -6.0, 0.01);
    // Soft below its knee is clean: a sine at -12 dB under a 0 dB ceiling with softness 0.5.
    p = make(e, "org.caw.clipper");
    const Stereo in = sine(200, 0.25, 24000);
    const Stereo clean = run(*p, in, {{"mode", 1}, {"ceiling", 0}, {"softness", 0.5}, {"oversample", 1}});
    CHECK_NEAR(db(peak(clean.l, 12000)), db(0.25), 0.01);
}

TEST(the_clipper_oversampling_cuts_aliases_and_mode_or_quality_changes_do_not_click) {
    Engine e(48000);
    // A 7 kHz sine clipped hard: its 5th harmonic (35 kHz) folds to 13 kHz and its 7th (49 kHz) to 1 kHz.
    auto alias = [&](int os) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.clipper");
        const Stereo out = run(*p, sine(7000, 0.9, 24000), {{"mode", 0}, {"drive", 12}, {"ceiling", -6}, {"oversample", os}});
        return db(std::max(tone(out.l, 13000, 4800, 24000), tone(out.l, 1000, 4800, 24000)) / tone(out.l, 7000, 4800, 24000));
    };
    const double off = alias(1), x8 = alias(4);
    CHECK(off > -30.0);
    CHECK(x8 < off - 20.0);
    // A mode change mid-note cross-fades the curves.
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.clipper");
    const Stereo out = run(*p, sine(100, 0.9, 24000), {{"mode", 0}, {"drive", 12}}, 64, {{12007, "mode", 2}});
    CHECK(biggestStep(out.l, 11000, 14000) < 1.1 * biggestStep(out.l, 1000, 11000));  // no bigger than before it
    // A quality change (Normal to High: Auto goes from 2x to 4x) cross-fades the two chains.
    std::atomic<int> q{kQualityNormal};
    std::unique_ptr<ModuleProcessor> c;
    {
        BuildingQuality building(&q);
        c = make(e, "org.caw.clipper");
    }
    Stereo first = run(*c, sine(300, 0.5, 6000), {{"drive", 6}});
    q.store(kQualityHigh);
    float shown[kMaxDisplayFloats];
    Stereo second = run(*c, sine(300, 0.5, 6000), {{"drive", 6}});
    CHECK(c->readDisplay(shown, kMaxDisplayFloats) == 75u);
    CHECK_EQ(shown[6], 4.0f);
    CHECK(std::fabs(second.l[0] - first.l.back()) < 0.1);
    CHECK(biggestStep(second.l, 0, 1000) < 0.5 * 2 * kTwoPi * 300 / 48000 * 2.5);
}

// ---------- Phase distortion ----------

TEST(phase_distortion_is_a_clean_delay_at_no_drive_and_adds_harmonics_when_driven) {
    Engine e(48000);
    const Stereo in = sine(500, 0.5, 24000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.phasedist");
    const Stereo clean = run(*p, in, {{"drive", 0}});
    for (size_t i = 48; i < in.size(); ++i)
        if (clean.l[i] != in.l[i - 48]) {
            cawtest::fail(__FILE__, __LINE__, "not the input 48 frames late at frame " + std::to_string(i));
            break;
        }
    p = make(e, "org.caw.phasedist");
    const Stereo driven = run(*p, in, {{"drive", 0.8}, {"tone", 8000}});
    const double fundamental = tone(driven.l, 500, 4800, 24000);
    CHECK(tone(driven.l, 1000, 4800, 24000) / fundamental > 0.05);  // self-modulation's harmonics
    CHECK(tone(driven.l, 1500, 4800, 24000) / fundamental > 0.02);
    // Normalize: a quiet and a loud sine are bent about as much.
    auto bend = [&](double amp) {
        std::unique_ptr<ModuleProcessor> q = make(e, "org.caw.phasedist");
        const Stereo o = run(*q, sine(500, amp, 24000), {{"drive", 0.8}, {"normalize", 1}});
        return tone(o.l, 1000, 4800, 24000) / tone(o.l, 500, 4800, 24000);
    };
    CHECK_NEAR(bend(0.05), bend(0.5), 0.02);
}

// ---------- The saturator's new modes ----------

TEST(the_saturators_new_modes_shape_as_named_and_switch_without_clicks) {
    Engine e(48000);
    auto through = [&](const Values& v, double hz = 200, double amp = 0.5) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.saturator");
        return run(*p, sine(hz, amp, 24000), v);
    };
    // Rectify: the octave above dominates.
    const Stereo r = through({{"mode", 7}, {"drive", 6}, {"auto_gain", 0}});
    CHECK(tone(r.l, 400, 4800, 24000) > 4.0 * tone(r.l, 200, 4800, 24000));
    // Fat: a strong second harmonic; fuzz: strong odd ones.
    const Stereo f = through({{"mode", 10}, {"drive", 6}});
    CHECK(tone(f.l, 400, 4800, 24000) / tone(f.l, 200, 4800, 24000) > 0.1);
    const Stereo z = through({{"mode", 6}, {"drive", 12}});
    CHECK(tone(z.l, 600, 4800, 24000) / tone(z.l, 200, 4800, 24000) > 0.15);
    // Bit shape at 2 bits: three levels, so strong odd harmonics (a 120-degree pulse has no 3rd: the 5th, then).
    const Stereo b = through({{"mode", 9}, {"bits", 2}, {"drive", 0}, {"oversample", 0}, {"auto_gain", 0}, {"tone", 0}});
    CHECK(tone(b.l, 1000, 4800, 24000) > 0.05);
    // Tri fold: driven past 1, the peak folds back down.
    const Stereo t = through({{"mode", 8}, {"drive", 9.5}, {"auto_gain", 0}}, 200, 1.0);  // x3: folds to about -1..1
    CHECK(peak(t.l, 4800) < 1.2);
    // Spread pulls the sides apart.
    const Stereo s = through({{"mode", 1}, {"drive", 12}, {"spread", 1}});
    double differ = 0;
    for (size_t i = 4800; i < s.size(); ++i) differ = std::max(differ, std::fabs(static_cast<double>(s.l[i]) - s.r[i]));
    CHECK(differ > 0.01);
    // A mode change mid-note dips the wet path for 2 ms each way: no jump bigger than the signal's own.
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.saturator");
    const Stereo out = run(*p, sine(100, 0.5, 24000), {{"mode", 3}, {"drive", 18}}, 64, {{12005, "mode", 8}});
    CHECK(biggestStep(out.l, 11500, 13500) < 0.5);
    // Dynamics: driven hard, a quiet passage stays quieter than a loud one by more with dynamics on.
    auto spreadDb = [&](double dyn) {
        Stereo in = sine(200, 0.5, 48000);
        for (size_t i = 24000; i < in.size(); ++i) in.l[i] *= 0.1f, in.r[i] *= 0.1f;  // -20 dB for the second half
        std::unique_ptr<ModuleProcessor> q = make(e, "org.caw.saturator");
        const Stereo o = run(*q, in, {{"mode", 10}, {"drive", 30}, {"dynamics", dyn}});
        return db(rms(o.l, 12000, 24000) / rms(o.l, 36000, 48000));
    };
    CHECK(spreadDb(1.0) > spreadDb(0.0) + 8.0);
}
