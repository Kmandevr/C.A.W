// 1.1.0's EQ and Filter additions: Bands' dynamics and solo, Linear, Match and Wah (laws, latency, block sizes, presets, references).
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "builtin_effects.h"
#include "caw/detmath.hpp"
#include "caw/display.hpp"
#include "caw/library/eq.hpp"
#include "component_chain.h"
#include "fx_merged.h"
#include "presets.h"
#include "quality.h"
#include "test.h"
#include "tolerance.h"

using namespace caw;

namespace {

using Values = std::vector<std::pair<std::string, double>>;
constexpr double kSr = 48000.0;

struct Stereo {
    std::vector<float> l, r;
    size_t size() const { return l.size(); }
};

const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        return x;
    }();
    return r;
}

std::unique_ptr<ModuleProcessor> make(const char* id, double variant) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), id, {{"variant", variant}});
    CHECK(p != nullptr);
    if (p) CHECK(p->activate(kSr, 512));
    return p;
}
std::unique_ptr<ModuleProcessor> bands() { return make("org.caw.eq", 0); }
std::unique_ptr<ModuleProcessor> linear() { return make("org.caw.eq", 4); }
std::unique_ptr<ModuleProcessor> matcher() { return make("org.caw.eq", 5); }
std::unique_ptr<ModuleProcessor> wah() { return make("org.caw.filter", 3); }

enum class Key { None, Port, Optional };

// Runs p over `in` in `block`-frame blocks with `values` held (constants: a steady device's knobs). The key goes
// to the sidechain port (Key::Port) or the optional "key" input (Key::Optional).
Stereo run(ModuleProcessor& p, const Stereo& in, const Values& values = {}, uint32_t block = 64, const Stereo* key = nullptr,
           Key how = Key::None) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        bool found = false;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v, found = true;
        (void)found;
    }
    for (const auto& [id, v] : values) {
        bool known = false;
        for (uint32_t k = 0; k < d.parameterCount; ++k) known = known || d.parameters[k].id == id;
        if (!known) cawtest::fail(__FILE__, __LINE__, "no parameter " + id);
    }
    auto* fx = dynamic_cast<fx::EffectBase*>(&p);
    Stereo out{std::vector<float>(in.size()), std::vector<float>(in.size())};
    for (size_t start = 0; start < in.size(); start += block) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(block, in.size() - start));
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        if (key && how == Key::Port) {
            const float* kc[2] = {key->l.data() + start, key->r.data() + start};
            const ConstChannelBufferView ins[2] = {{ic, 2, n}, {kc, 2, n}};
            const ChannelBufferView outs{oc, 2, n};
            ProcessBlock b;
            b.frames = n;
            b.sampleRate = kSr;
            b.audioIn = ins;
            b.audioInCount = 2;
            b.audioOut = &outs;
            b.audioOutCount = 1;
            b.parameters = params.data();
            b.parameterCount = d.parameterCount;
            CHECK(p.processPorts(b));
            continue;
        }
        if (key && how == Key::Optional && fx)
            CHECK(fx->connectOptionalPort(0, const_cast<float*>(key->l.data() + start), const_cast<float*>(key->r.data() + start)));
        AudioProcessBlock b;
        b.input = {ic, 2, n};
        b.output = {oc, 2, n};
        b.frames = n;
        b.sampleRate = kSr;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        CHECK(p.process(b));
    }
    if (key && how == Key::Optional && fx) fx->connectOptionalPort(0, nullptr, nullptr);
    return out;
}

Stereo silence(size_t n) { return {std::vector<float>(n, 0.0f), std::vector<float>(n, 0.0f)}; }
Stereo sine(double hz, double amp, size_t n) {
    Stereo s = silence(n);
    for (size_t i = 0; i < n; ++i) s.l[i] = s.r[i] = static_cast<float>(amp * detSin(kTwoPi * hz * i / kSr));
    return s;
}
Stereo noise(size_t n, double amp, uint32_t seed = 777) {
    Stereo s = silence(n);
    for (size_t i = 0; i < n; ++i) {
        seed = seed * 1664525u + 1013904223u;
        s.l[i] = static_cast<float>(amp * ((seed >> 8) / 8388608.0 - 1.0));
        seed = seed * 1664525u + 1013904223u;
        s.r[i] = static_cast<float>(amp * ((seed >> 8) / 8388608.0 - 1.0));
    }
    return s;
}
Stereo impulse(size_t n) {
    Stereo s = silence(n);
    s.l[0] = s.r[0] = 1.0f;
    return s;
}
// Plucks and noise bursts with a gap (as effects_test.cpp's music()).
Stereo music(size_t frames) {
    Stereo s = silence(frames);
    uint32_t seed = 12345;
    for (size_t i = 0; i < frames; ++i) {
        const size_t beat = i % 12000, bar = i / 12000;
        if (bar == 3) continue;
        const double env = detExp(-static_cast<double>(beat) / 2400.0);
        seed = seed * 1664525u + 1013904223u;
        const double nz = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * detExp(-static_cast<double>(beat) / 300.0);
        const double f = 110.0 * (1 + bar % 4), t = static_cast<double>(i) / kSr;
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
double db(double g) { return 20.0 * std::log10(std::max(g, 1e-30)); }
std::vector<float> display(ModuleProcessor& p) {
    std::vector<float> v(kMaxDisplayFloats);
    v.resize(p.readDisplay(v.data(), kMaxDisplayFloats));
    return v;
}
bool sameBits(const Stereo& a, const Stereo& b) {
    return a.size() == b.size() && std::memcmp(a.l.data(), b.l.data(), a.size() * 4) == 0 &&
           std::memcmp(a.r.data(), b.r.data(), a.size() * 4) == 0;
}
bool finite(const Stereo& s) {
    for (size_t i = 0; i < s.size(); ++i)
        if (!std::isfinite(s.l[i]) || !std::isfinite(s.r[i])) return false;
    return true;
}

// Bands' display: a dynamic band's applied gain (439 + band) and its detector level (447 + band); solo at 455.
constexpr uint32_t kDynShown = 439, kLevelShown = 447, kSoloShown = 455;

const Values kDynBusy = {{"b2_dyn", 1}, {"b2_thresh", -30}, {"b2_range", -6},  {"b3_dyn", 1},    {"b3_gain", 3},
                         {"b3_thresh", -36}, {"b3_range", 6}, {"b3_attack", 1}, {"b5_dyn", 1},    {"b5_key", 2},
                         {"b5_channel", 2}, {"b5_gain", -2}, {"b6_dyn", 1},     {"b6_type", 0},   {"b6_ratio", 10},
                         {"b6_thresh", -40}, {"b6_range", -12}, {"b6_release", 30}};
const Values kLinBusy = {{"b1_on", 1}, {"b1_type", 4}, {"b1_freq", 40}, {"b2_gain", 3}, {"b3_gain", -4}, {"b3_q", 2},
                         {"b5_gain", 4}, {"b5_channel", 1}, {"b7_gain", 3}, {"b7_channel", 2}, {"output", -1}};

}  // namespace

// ---------- Bands: dynamics ----------

TEST(eq_dynamic_band_follows_its_gain_law_with_the_knobs_held) {
    // A 1 kHz sine at -6 dBFS through a dynamic bell at 1 kHz (0 dB): the detector reads -6 dB; above a -30 dB
    // threshold at 4:1 the band wants 24 x 3/4 = 18 dB, held to the 12 dB range.
    const Stereo tone = sine(1000, 0.5, 48000);
    struct Case {
        double thresh, ratio, range, expect;
    };
    for (const Case& c : {Case{-30, 4, -12, -12}, Case{-20, 2, -24, -7}, Case{-20, 2, 24, 7}, Case{-12, 20, -24, -5.7}}) {
        std::unique_ptr<ModuleProcessor> p = bands();
        const Values v = {{"b4_freq", 1000}, {"b4_dyn", 1}, {"b4_thresh", c.thresh}, {"b4_ratio", c.ratio}, {"b4_range", c.range},
                          {"b4_attack", 1}, {"b4_release", 50}};
        const Stereo out = run(*p, tone, v);
        CHECK_NEAR(db(rms(out.l, 36000, 48000) / rms(tone.l, 36000, 48000)), c.expect, 0.5);
        const std::vector<float> shown = display(*p);
        CHECK_EQ(shown.size(), 456u);
        if (shown.size() == 456u) {
            CHECK_NEAR(shown[kDynShown + 3], c.expect, 0.5);
            CHECK_NEAR(shown[kLevelShown + 3], -6.0, 0.8);
            CHECK_EQ(shown[kDynShown + 2], 0.0f);  // a band that isn't dynamic shows 0
        }
    }
    // Below its threshold a dynamic band at 0 dB does nothing at all: the input, bit for bit.
    std::unique_ptr<ModuleProcessor> q = bands();
    const Stereo quiet = sine(1000, 0.01, 24000);
    CHECK(sameBits(run(*q, quiet, {{"b4_dyn", 1}, {"b4_thresh", -20}}), quiet));
}

TEST(eq_dynamics_off_leave_the_bands_as_they_were) {
    // Dynamics' knobs moved with dynamics off change nothing (the 1.0.9 renders stand; effects_test's references).
    const Stereo m = music(48000);
    std::unique_ptr<ModuleProcessor> a = bands(), b = bands();
    const Values base = {{"b3_gain", 4}, {"b5_gain", -3}, {"b5_channel", 2}};
    Values moved = base;
    for (int k = 1; k <= 8; ++k) {
        const std::string id = "b" + std::to_string(k) + "_";
        moved.push_back({id + "thresh", -50}), moved.push_back({id + "range", 12}), moved.push_back({id + "key", 3});
    }
    CHECK(sameBits(run(*a, m, base), run(*b, m, moved)));
}

TEST(eq_dynamic_band_keyed_from_its_key_input_or_another_band) {
    const Stereo quiet = sine(100, 0.05, 48000), loud = sine(100, 0.7, 48000);
    const Values v = {{"b2_type", 0}, {"b2_freq", 100}, {"b2_dyn", 1}, {"b2_key", 1}, {"b2_thresh", -20}, {"b2_ratio", 20},
                      {"b2_range", -10}, {"b2_attack", 1}};
    std::unique_ptr<ModuleProcessor> p = bands();
    const Stereo ducked = run(*p, quiet, v, 64, &loud, Key::Optional);
    CHECK_NEAR(db(rms(ducked.l, 36000, 48000) / rms(quiet.l, 36000, 48000)), -10.0, 0.5);
    std::unique_ptr<ModuleProcessor> q = bands();  // no key connected: silence, nothing moves
    CHECK(sameBits(run(*q, quiet, v), quiet));
    // Keyed from band 6's region (a bell at 6 kHz): a 100 Hz tone doesn't reach it, a 6 kHz one does.
    Values other = v;
    other[3] = {"b2_key", 7};
    std::unique_ptr<ModuleProcessor> r = bands();
    CHECK(sameBits(run(*r, quiet, other), quiet));
    Stereo mix = quiet;
    const Stereo high = sine(6000, 0.5, 48000);
    for (size_t i = 0; i < mix.size(); ++i) mix.l[i] += high.l[i], mix.r[i] += high.r[i];
    std::unique_ptr<ModuleProcessor> s = bands();
    run(*s, mix, other);
    CHECK(display(*s)[kDynShown + 1] < -9.0f);
}

TEST(eq_band_solo_plays_the_band_and_an_export_never_does) {
    const Stereo low = sine(100, 0.5, 24000), mid = sine(1000, 0.5, 24000);
    const Values v = {{"b4_freq", 1000}, {"b4_q", 2}, {"solo_band", 4}};
    std::unique_ptr<ModuleProcessor> p = bands();
    CHECK(db(rms(run(*p, low, v).l, 12000, 24000) / rms(low.l, 12000, 24000)) < -20.0);
    std::unique_ptr<ModuleProcessor> q = bands();
    CHECK_NEAR(db(rms(run(*q, mid, v).l, 12000, 24000) / rms(mid.l, 12000, 24000)), 0.0, 0.2);
    CHECK_EQ(display(*q)[kSoloShown], 4.0f);
    // A low shelf's solo: the lows below it.
    std::unique_ptr<ModuleProcessor> s = bands();
    CHECK(db(rms(run(*s, mid, {{"solo_band", 2}}).l, 12000, 24000) / rms(mid.l, 12000, 24000)) < -20.0);
    // Not automatable, modulatable or MIDI-mappable.
    const ModuleDescriptor& d = p->descriptor();
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == "solo_band") CHECK(!d.parameters[k].automatable && !d.parameters[k].modulatable && !d.parameters[k].midiMappable);
    // Built for an offline render (Engine::setProjectOffline: an export, stems), it plays as if solo were off.
    std::unique_ptr<ModuleProcessor> e, f = bands();
    {
        const BuildingOffline offline(true);
        e = bands();
    }
    const Stereo m = music(24000);
    CHECK(sameBits(run(*e, m, v), run(*f, m, {{"b4_freq", 1000}, {"b4_q", 2}})));
    std::unique_ptr<ModuleProcessor> lin;
    {
        const BuildingOffline offline(true);
        lin = linear();
    }
    std::unique_ptr<ModuleProcessor> lin2 = linear();
    CHECK(sameBits(run(*lin, m, v), run(*lin2, m, {{"b4_freq", 1000}, {"b4_q", 2}})));
}

// ---------- Linear ----------

TEST(linear_phase_impulse_is_symmetric_and_matches_the_minimum_phase_curve) {
    const Values v = {{"b2_gain", 4}, {"b3_gain", -5}, {"b3_q", 1.5}, {"b5_gain", 3}, {"b5_freq", 3000}, {"b7_gain", -3}};
    std::unique_ptr<ModuleProcessor> p = linear();
    const auto* lat = dynamic_cast<const VariableLatency*>(p.get());
    CHECK(lat != nullptr);
    const uint32_t c = 2304;  // Normal: 4,096 taps / 2 + 256
    const Stereo out = run(*p, impulse(12000), v);
    uint32_t at = 0;
    for (uint32_t i = 0; i < out.size(); ++i)
        if (std::fabs(out.l[i]) > std::fabs(out.l[at])) at = i;
    CHECK_EQ(at, c);
    double asym = 0;
    for (uint32_t d = 1; d < 2048; ++d) asym = std::max(asym, std::fabs(static_cast<double>(out.l[c + d]) - out.l[c - d]));
    CHECK(asym < 1e-5 * std::fabs(out.l[c]));
    double before = 0;  // nothing before the first tap (but the FFTs' rounding)
    for (uint32_t i = 0; i <= c - 2048; ++i) before = std::max(before, std::fabs(static_cast<double>(out.l[i])));
    CHECK(before < 1e-5);
    // Its magnitude against the bands' own (minimum-phase) curve, above 50 Hz: within 0.1 dB.
    lib::EqFilter f[4];
    f[0].set(lib::EqType::LowShelf, 100, 4, 0.71, kSr);
    f[1].set(lib::EqType::Bell, 250, -5, 1.5, kSr);
    f[2].set(lib::EqType::Bell, 3000, 3, 1.0, kSr);
    f[3].set(lib::EqType::HighShelf, 10000, -3, 0.71, kSr);
    double worst = 0;
    for (double hz = 50; hz < 20000; hz *= 1.05) {
        double re = 0, im = 0;
        for (uint32_t i = c - 2048; i < c + 2048; ++i) {
            const double w = kTwoPi * hz * (static_cast<double>(i) - c) / kSr;
            re += out.l[i] * detCos(w), im -= out.l[i] * detSin(w);
        }
        double want = 1.0;
        for (const auto& b : f) want *= b.magnitude2(detTan(kPi * hz / kSr));
        worst = std::max(worst, std::fabs(10 * std::log10(re * re + im * im) - 10 * std::log10(want)));
    }
    if (worst > 0.1) cawtest::fail(__FILE__, __LINE__, "linear phase off the curve by " + std::to_string(worst) + " dB");
}

TEST(linear_phase_reports_the_latency_it_has_at_each_quality) {
    for (int tier = 0; tier < 3; ++tier) {
        std::unique_ptr<ModuleProcessor> p = linear();
        const ModuleDescriptor& d = p->descriptor();
        std::vector<double> values(d.parameterCount);
        for (uint32_t k = 0; k < d.parameterCount; ++k) values[k] = d.parameters[k].id == "lin_quality" ? tier : d.parameters[k].defaultValue;
        const uint32_t reported = dynamic_cast<const VariableLatency*>(p.get())->latencyFor(values.data(), d.parameterCount);
        CHECK_EQ(reported, (1024u << tier) + 256u);
        const Stereo out = run(*p, impulse(12000), {{"lin_quality", tier}});
        uint32_t at = 0;
        for (uint32_t i = 0; i < out.size(); ++i)
            if (std::fabs(out.l[i]) > std::fabs(out.l[at])) at = i;
        CHECK_EQ(at, reported);
        CHECK_NEAR(out.l[at], 1.0, 1e-3);  // flat bands: the impulse, delayed
        const std::vector<float> shown = display(*p);
        CHECK_EQ(shown.size(), 849u);
        if (shown.size() == 849u) {
            CHECK_NEAR(shown[456], reported * 1000.0 / kSr, 1e-3);
            CHECK_EQ(shown[457], static_cast<float>(2048u << tier));
        }
    }
    // Lin_quality sets the latency, so nothing but a hand may move it.
    std::unique_ptr<ModuleProcessor> p = linear();
    const ModuleDescriptor& d = p->descriptor();
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == "lin_quality") CHECK(!d.parameters[k].automatable && !d.parameters[k].modulatable);
    // No dynamics in Linear.
    for (uint32_t k = 0; k < d.parameterCount; ++k) CHECK(std::string_view(d.parameters[k].id).find("_dyn") == std::string_view::npos);
}

TEST(linear_phase_redesigns_a_moved_band_without_a_gap) {
    // A band moved mid-stream (a new value block): the output carries on (no silence, no jump past the levels).
    std::unique_ptr<ModuleProcessor> p = linear();
    const Stereo tone = sine(1000, 0.25, 24000);
    run(*p, tone, {{"b4_freq", 1000}});
    const Stereo after = run(*p, tone, {{"b4_freq", 1000}, {"b4_gain", 6}});
    double lo = 1e9;
    for (size_t i = 0; i < after.size(); i += 480) lo = std::min(lo, rms(after.l, i, i + 480));
    CHECK(lo > 0.15);
    CHECK_NEAR(db(rms(after.l, 12000, 24000) / rms(tone.l, 12000, 24000)), 6.0, 0.2);
}

// ---------- Match ----------

TEST(match_of_a_signal_to_itself_is_flat_and_a_quieter_input_is_lifted) {
    const Stereo n = noise(96000, 0.3);
    std::unique_ptr<ModuleProcessor> p = matcher();
    run(*p, n, {{"match_learn", 3}}, 64, &n, Key::Port);
    run(*p, silence(4800), {}, 64, &n, Key::Port);  // learning over: the curve is designed
    std::vector<float> shown = display(*p);
    CHECK_EQ(shown.size(), 394u);
    if (shown.size() != 394u) return;
    CHECK(shown[1] > 1.5f && shown[2] > 1.5f);  // seconds learned
    for (uint32_t j = 0; j < 120; ++j) CHECK_NEAR(shown[6 + 240 + j], 0.0, 1e-6);
    const Stereo imp = run(*p, impulse(4096));
    CHECK_NEAR(imp.l[128], 1.0, 1e-4);  // flat: the input, 128 frames late
    // The input at half the reference's level: matched, +6 dB everywhere.
    Stereo half = n;
    for (size_t i = 0; i < half.size(); ++i) half.l[i] *= 0.5f, half.r[i] *= 0.5f;
    std::unique_ptr<ModuleProcessor> q = matcher();
    run(*q, half, {{"match_learn", 3}}, 64, &n, Key::Port);
    const Stereo tone = sine(1000, 0.1, 24000);
    const Stereo out = run(*q, tone, {}, 64, &n, Key::Port);
    shown = display(*q);
    for (uint32_t j = 10; j < 110; ++j) CHECK_NEAR(shown[6 + 240 + j], 6.02, 0.15);
    CHECK_NEAR(db(rms(out.l, 12000, 24000) / rms(tone.l, 12000, 24000)), 6.02, 0.3);
    // Fit bands (worked out while a UI watches): the first fitted bell carries the lift.
    run(*q, tone, {}, 64, &n, Key::Port);
    shown = display(*q);
    CHECK(shown[6 + 360 + 1] > 3.0f);
}

TEST(match_snapshot_saves_and_loads_its_learned_spectra) {
    const Stereo n = noise(72000, 0.3), quiet = noise(72000, 0.1, 99);
    std::unique_ptr<ModuleProcessor> p = matcher();
    run(*p, quiet, {{"match_learn", 3}}, 64, &n, Key::Port);
    std::vector<uint8_t> state(1 << 16);
    uint32_t written = 0;
    CHECK(p->saveState(state.data(), static_cast<uint32_t>(state.size()), written));
    CHECK(written > 0);
    state.resize(written);
    std::unique_ptr<ModuleProcessor> q = matcher();
    CHECK(q->loadState(state.data(), written, 1));
    const Stereo tone = sine(2000, 0.1, 24000);
    const Stereo a = run(*p, tone), b = run(*q, tone);
    CHECK_NEAR(db(rms(a.l, 12000, 24000)), db(rms(b.l, 12000, 24000)), 0.01);
    CHECK(db(rms(b.l, 12000, 24000) / rms(tone.l, 12000, 24000)) > 5.0);  // about 9.5 dB lifted
    // Damaged snapshots are refused.
    std::vector<uint8_t> bad = state;
    bad[0] ^= 0xff;
    CHECK(!q->loadState(bad.data(), written, 1));
    CHECK(!q->loadState(state.data(), written - 4, 1));
    CHECK(!q->loadState(state.data(), written, 2));
    CHECK(q->loadState(nullptr, 0, 1));  // empty: nothing learned
}

// ---------- Wah ----------

TEST(wah_sweeps_with_its_pedal_and_with_the_playing) {
    // Pedal: heel peaks low, toe peaks high (Classic: 400 Hz .. 2.2 kHz).
    auto gain = [](double pedal, double hz) {
        std::unique_ptr<ModuleProcessor> p = wah();
        const Stereo t = sine(hz, 0.1, 24000);
        return db(rms(run(*p, t, {{"mode", 1}, {"pedal", pedal}}).l, 12000, 24000) / rms(t.l, 12000, 24000));
    };
    CHECK(gain(0, 400) > gain(0, 2200) + 12);
    CHECK(gain(1, 2200) > gain(1, 400) + 12);
    CHECK_NEAR(gain(0, 400), 0.0, 1.5);  // the peak, about unity (plus the low-pass share)
    // Envelope: a loud note opens it (the display's frequency goes up), a quiet one less.
    std::unique_ptr<ModuleProcessor> loud = wah(), soft = wah();
    run(*loud, sine(300, 0.8, 9600));
    run(*soft, sine(300, 0.001, 9600));
    CHECK(display(*loud)[2] > 1500.0f);
    CHECK(display(*soft)[2] < 700.0f);
    std::unique_ptr<ModuleProcessor> down = wah();
    run(*down, sine(300, 0.8, 9600), {{"direction", 1}});
    CHECK(display(*down)[2] < 600.0f);
    CHECK_EQ(display(*down).size(), 9u);
    // The pedal can be automated, modulated and MIDI-mapped (a knob, a lane, an expression pedal, React to...).
    const ModuleDescriptor& d = loud->descriptor();
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == "pedal") CHECK(d.parameters[k].automatable && d.parameters[k].modulatable && d.parameters[k].midiMappable);
}

// ---------- All of them ----------

struct Setting {
    const char* name;
    std::unique_ptr<ModuleProcessor> (*make)();
    Values values;
    Key key;
};
const Setting& setting(size_t k);
constexpr size_t kSettings = 7;
const Setting& setting(size_t k) {
    static const Setting s[kSettings] = {
        {"bands dynamic", &bands, kDynBusy, Key::Optional},
        {"bands dynamic solo", &bands, [] { Values v = kDynBusy; v.push_back({"solo_band", 3}); return v; }(), Key::None},
        {"linear", &linear, kLinBusy, Key::None},
        {"linear high, match learning", &linear, [] { Values v = kLinBusy; v.push_back({"lin_quality", 2}); v.push_back({"match", 1}); v.push_back({"match_learn", 3}); return v; }(), Key::Port},
        {"match learning", &matcher, {{"match_learn", 3}, {"output", -2}}, Key::Port},
        {"wah envelope", &wah, {{"curve", 3}, {"resonance", 0.8}, {"attack", 3}}, Key::None},
        {"wah pedal", &wah, {{"mode", 1}, {"curve", 1}, {"pedal", 0.3}, {"mix", 0.7}}, Key::None},
    };
    return s[k];
}

TEST(plume_and_wah_render_the_same_bits_at_any_block_size) {
    const Stereo in = music(48000 * 2), key = music(48000 * 2);
    Stereo shifted = key;
    std::rotate(shifted.l.begin(), shifted.l.begin() + 3000, shifted.l.end());
    for (size_t k = 0; k < kSettings; ++k) {
        const Setting& s = setting(k);
        std::unique_ptr<ModuleProcessor> a = s.make();
        const Stereo ref = run(*a, in, s.values, 64, &shifted, s.key);
        CHECK(finite(ref));
        for (uint32_t block : {1u, 37u, 512u}) {
            std::unique_ptr<ModuleProcessor> b = s.make();
            if (!sameBits(run(*b, in, s.values, block, &shifted, s.key), ref))
                cawtest::fail(__FILE__, __LINE__, std::string(s.name) + " differs at block " + std::to_string(block));
        }
    }
}

TEST(plume_and_wah_survive_nans_and_denormals) {
    for (size_t k = 0; k < kSettings; ++k) {
        const Setting& s = setting(k);
        // Linear and Match: their convolvers take a NaN as 0. Wah: so does its input. Bands' dynamic detectors
        // start again clean (its filters keep the EQ's old behaviour, so Bands is checked on the key here).
        Stereo in = music(24000);
        const bool bandsCase = s.make == &bands;
        Stereo key = in;
        Stereo& poisoned = bandsCase ? key : in;
        poisoned.l[1000] = std::nanf("");
        poisoned.r[1001] = std::numeric_limits<float>::infinity() * 0.0f;
        std::unique_ptr<ModuleProcessor> p = s.make();
        const Stereo out = run(*p, in, s.values, 64, &key, bandsCase ? Key::Optional : s.key);
        bool ok = true;
        for (size_t i = 12000; i < out.size(); ++i) ok = ok && std::isfinite(out.l[i]) && std::isfinite(out.r[i]);
        if (!ok) cawtest::fail(__FILE__, __LINE__, std::string(s.name) + ": not finite after a NaN");
        for (float x : display(*p))
            if (!std::isfinite(x)) {
                cawtest::fail(__FILE__, __LINE__, std::string(s.name) + ": display not finite");
                break;
            }
        // Denormal input: a finite, tiny output.
        Stereo tiny = silence(4800);
        for (size_t i = 0; i < tiny.size(); ++i) tiny.l[i] = tiny.r[i] = (i % 2 ? 1e-39f : -1e-39f);
        std::unique_ptr<ModuleProcessor> q = s.make();
        const Stereo t = run(*q, tiny, s.values, 64, &tiny, s.key);
        CHECK(finite(t));
        for (size_t i = 0; i < t.size(); ++i) CHECK(std::fabs(t.l[i]) < 1e-30f);
    }
}

TEST(plume_and_wah_presets_exist_for_each_mode_and_name_real_knobs) {
    std::map<std::string, int> count;
    for (const char* id : {"org.caw.eq", "org.caw.filter"})
        for (const BuiltinPreset& p : fx::newEqFilterVariantPresets(id)) {
            double variant = -1;
            bool dyn = false;
            Values v;
            for (const auto& [k, x] : p.values) {
                if (k == "variant") variant = x;
                if (std::string_view(k).find("_dyn") != std::string_view::npos) dyn = true;
                v.push_back({std::string(k), x});
            }
            CHECK(variant >= 0);
            std::unique_ptr<ModuleProcessor> m = createComponent(registry(), id, v);
            CHECK(m != nullptr);
            if (!m) continue;
            const ModuleDescriptor& d = m->descriptor();
            for (const auto& [k, x] : p.values) {
                bool known = false;
                for (uint32_t q = 0; q < d.parameterCount; ++q)
                    if (d.parameters[q].id == k) known = x >= d.parameters[q].minimum && x <= d.parameters[q].maximum;
                if (!known) cawtest::fail(__FILE__, __LINE__, std::string(p.name) + ": " + std::string(k) + " is not a knob in range");
            }
            ++count[std::string(id) + "/" + std::to_string(static_cast<int>(variant)) + (dyn ? "/dyn" : "")];
            CHECK(findBuiltinPreset(id, p.name) != nullptr);  // listed among the device's presets
        }
    CHECK(count["org.caw.eq/0/dyn"] >= 8);
    CHECK(count["org.caw.eq/4"] >= 8);
    CHECK(count["org.caw.eq/5"] >= 8);
    CHECK(count["org.caw.filter/3"] >= 8);
}

TEST(plume_and_wah_match_their_reference_renders) {
    // 2 s of music through each setting, 64-frame blocks, against references/plume.cawref. Re-record only for an
    // intended sound change (caw_tests plume_and_wah_match_their_reference_renders --update-references).
    const Stereo in = music(48000 * 2), key = music(48000 * 2);
    cawtest::References refs("plume");
    for (size_t k = 0; k < kSettings; ++k) {
        const Setting& s = setting(k);
        std::unique_ptr<ModuleProcessor> p = s.make();
        const Stereo out = run(*p, in, s.values, 64, &key, s.key);
        CHECK_REFERENCE(refs, s.name, (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
    }
}
