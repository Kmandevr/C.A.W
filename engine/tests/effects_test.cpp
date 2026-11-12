// The built-in effects suite (#173): kernels, each effect's response, stability, block sizes, sleep, display, reference renders.
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstring>
#include <iterator>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "caw.h"
#include "caw/detmath.hpp"
#include "caw/display.hpp"
#include "caw/library/dynamics.hpp"
#include "caw/library/eq.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/oversample.hpp"
#include "caw/library/spectrum.hpp"
#include "analysis.h"
#include "capi_internal.h"

// M_PI is not standard C++ (MSVC lacks it without _USE_MATH_DEFINES).
static constexpr double kTestPi = 3.14159265358979323846;
#include "component_chain.h"
#include "engine.h"
#include "project.h"
#include "test.h"
#include "tolerance.h"
#include "test_signal.h"

using namespace caw;

namespace {

using Values = std::vector<std::pair<std::string, double>>;

const char* const kSuite[] = {"org.caw.eq",        "org.caw.compressor", "org.caw.limiter", "org.caw.reverb.pro",
                              "org.caw.delay.pro", "org.caw.saturator",  "org.caw.gate",    "org.caw.transient",
                              "org.caw.filter",    "org.caw.phaser",     "org.caw.flanger", "org.caw.utility"};
// How many floats each publishes (docs/engine.md, "Display data").
const uint32_t kDisplaySizes[] = {439, 11, 7, 8, 9, 73, 8, 5, 73, 7, 6, 6};  // the gate: 8 since its sidechain (#175)

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

std::unique_ptr<ModuleProcessor> make(Engine& e, const char* id, double rate = 48000) {
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(id);
    CHECK(p != nullptr);
    if (p) CHECK(p->activate(rate, 512));
    return p;
}

// Runs `in` through p in `block`-frame blocks, with `values` over the defaults (and a transport at `tempo` when
// tempo > 0, stopped at beat 0 unless `playing`, which plays it from beat 0).
Stereo run(ModuleProcessor& p, const Stereo& in, const Values& values = {}, uint32_t block = 64, double tempo = 0,
           bool playing = false) {
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
    t.tempo = tempo;
    for (size_t start = 0; start < in.size(); start += block) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(block, in.size() - start));
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        if (playing) t.beat = static_cast<double>(start) * tempo / (60.0 * 48000.0);
        t.playing = playing;
        AudioProcessBlock b;
        b.input = {ic, 2, n};
        b.output = {oc, 2, n};
        b.frames = n;
        b.sampleRate = 48000;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        b.transport = tempo > 0 ? &t : nullptr;
        CHECK(p.process(b));
    }
    return out;
}

Stereo silence(size_t frames) { return {std::vector<float>(frames, 0.0f), std::vector<float>(frames, 0.0f)}; }
Stereo sine(double hz, double amp, size_t frames, double phaseR = 0.0) {
    Stereo s = silence(frames);
    for (size_t i = 0; i < frames; ++i) {
        s.l[i] = static_cast<float>(amp * detSin(kTwoPi * hz * i / 48000.0));
        s.r[i] = static_cast<float>(amp * detSin(kTwoPi * hz * i / 48000.0 + phaseR));
    }
    return s;
}
Stereo impulse(size_t frames, float level = 1.0f) {
    Stereo s = silence(frames);
    s.l[0] = s.r[0] = level;
    return s;
}
// Something like music, the same on every platform: plucked partials and noise bursts on a beat, a gap of silence
// (so effects fall asleep and wake), and different sides.
Stereo music(size_t frames) {
    Stereo s = silence(frames);
    uint32_t seed = 12345;
    for (size_t i = 0; i < frames; ++i) {
        const size_t beat = i % 12000, bar = i / 12000;
        if (bar == 3) continue;  // a quarter second of silence
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
// A sine's level through p at steady state, in dB relative to the input.
double gainAt(Engine& e, const char* id, const Values& v, double hz) {
    std::unique_ptr<ModuleProcessor> p = make(e, id);
    if (!p) return 0;
    const Stereo in = sine(hz, 0.25, 48000);
    const Stereo out = run(*p, in, v);
    return db(rms(out.l, 24000, 48000) / rms(in.l, 24000, 48000));
}

// A reference's name: the effect's id, and " busy" for its busy settings.
std::string caseName(const char* id, bool busy) { return std::string(id) + (busy ? " busy" : ""); }
// The input repeats each second: a reference's waveform holds its first 1.25 s (the start, the silent bar and the
// wake-up after it), the whole 2 s render is also compared as heard (tolerance.h).
constexpr uint32_t kWaveformFrames = 60000;
// How each case is compared with its reference (tolerance.h).
// Chaotic (2026-11-12 probes, docs/engine.md "Reference renders"): the transient shaper's and the distortion's busy
// settings amplify a one-float-step change of their input to within 3 dB of -120 dBFS; every other case is stable.
cawtest::Class effectClass(const char* id, bool busy) {
    const std::string s = id;
    return busy && (s == "org.caw.transient" || s == "org.caw.distortion") ? cawtest::Class::Chaotic : cawtest::Class::Stable;
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

// Every knob away from its default, so each effect's whole path runs (for block sizes, stability, reference renders).
Values busy(const char* id) {
    const std::string s = id;
    if (s == "org.caw.eq")
        return {{"b1_on", 1}, {"b1_type", 5}, {"b1_freq", 60}, {"b2_gain", 4}, {"b3_gain", -6}, {"b3_q", 3}, {"b3_channel", 1},
                {"b4_type", 9}, {"b4_freq", 1500}, {"b5_gain", 5}, {"b5_channel", 2}, {"b6_type", 11}, {"b6_gain", -4},
                {"b7_gain", 3}, {"b7_channel", 3}, {"b8_on", 1}, {"b8_type", 7}, {"b8_freq", 9000}, {"b8_q", 2}, {"output", -2}};
    if (s == "org.caw.compressor")
        return {{"threshold", -30}, {"ratio", 8}, {"attack", 2}, {"release", 80}, {"auto_release", 1}, {"lookahead", 2},
                {"detect", 1}, {"link", 0.5}, {"sc_hpf", 150}, {"mix", 0.8}};
    if (s == "org.caw.limiter") return {{"gain", 12}, {"ceiling", -2}, {"release", 30}, {"lookahead", 3}};
    if (s == "org.caw.reverb.pro")
        return {{"size", 0.8}, {"decay", 4}, {"predelay_sync", 3}, {"damping", 0.3}, {"low_cut", 200}, {"high_cut", 6000},
                {"width", 1.5}, {"mod", 0.8}, {"duck", 0.5}, {"mix", 0.5}};
    if (s == "org.caw.delay.pro")
        return {{"mode", 1}, {"sync", 6}, {"feedback", 0.7}, {"drive", 0.6}, {"mod_depth", 0.5}, {"duck", 0.4}, {"mix", 0.5},
                {"low_cut", 200}, {"high_cut", 5000}};
    if (s == "org.caw.saturator") return {{"mode", 1}, {"drive", 18}, {"bias", 0.3}, {"tone", 0.4}, {"mix", 0.8}};
    if (s == "org.caw.gate") return {{"threshold", -20}, {"range", -40}, {"hold", 10}, {"sc_hpf", 100}};
    if (s == "org.caw.transient") return {{"attack", 0.8}, {"sustain", -0.5}, {"output", -2}};
    if (s == "org.caw.filter")
        return {{"type", 6}, {"cutoff", 800}, {"resonance", 0.6}, {"drive", 6}, {"lfo_amount", 0.4}, {"lfo_rate", 3},
                {"lfo_stereo", 0.5}, {"env_amount", 0.3}};
    if (s == "org.caw.phaser") return {{"stages", 4}, {"rate", 1.3}, {"feedback", 0.7}, {"stereo", 1}};
    if (s == "org.caw.flanger") return {{"delay", 3}, {"rate", 0.8}, {"feedback", -0.7}, {"mix", 0.6}};
    return {{"gain", -3}, {"invert_r", 1}, {"width", 1.4}, {"pan", 0.3}, {"bass_mono", 1}, {"dc_block", 1}};
}

}  // namespace

// ---------- Library kernels ----------

TEST(fast_log_and_decibels_match_the_library_maths) {
    double worst = 0;
    for (double x = 1e-300; x < 1e300; x *= 1.37) worst = std::max(worst, std::fabs(lib::fastLog(x) - std::log(x)) / std::max(1.0, std::fabs(std::log(x))));
    CHECK(worst < 1e-14);
    CHECK_EQ(lib::fastLog(0.0), -746.0);
    CHECK_EQ(lib::fastLog(-1.0), -746.0);
    CHECK_NEAR(lib::fastLog(5e-320), std::log(5e-320), 1e-9);  // subnormal
    CHECK_EQ(lib::dbToGain(0.0), 1.0);
    CHECK_NEAR(lib::dbToGain(-6.0), std::pow(10.0, -0.3), 1e-12);
    CHECK_NEAR(lib::gainToDb(0.5), 20 * std::log10(0.5), 1e-12);
    CHECK_EQ(lib::gainToDb(0.0), -120.0);
}

TEST(a_parametric_band_has_its_type_s_response_measured_and_computed) {
    // Each type's computed |H| (what the EQ's display curve shows) matches a sine measured through the filter.
    const double rate = 48000;
    for (int type = 0; type < static_cast<int>(lib::EqType::Count); ++type) {
        lib::EqFilter f;
        f.set(static_cast<lib::EqType>(type), 1000.0, 9.0, 2.0, rate);
        for (double hz : {100.0, 700.0, 1000.0, 1400.0, 8000.0}) {
            lib::SvfState st[lib::EqFilter::kMaxStages];
            double in = 0, out = 0;
            for (int i = 0; i < 48000; ++i) {
                const double x = std::sin(2 * kTestPi * hz * i / rate);
                const double y = f.process(st, x);
                if (i >= 24000) in += x * x, out += y * y;
            }
            const double measured = 10 * std::log10(out / in + 1e-30);
            const double computed = 10 * std::log10(f.magnitude2(std::tan(kTestPi * hz / rate)) + 1e-30);
            if (computed > -60 && std::fabs(measured - computed) > 0.05)
                cawtest::fail(__FILE__, __LINE__, "type " + std::to_string(type) + " at " + std::to_string(hz) + " Hz: measured " +
                                                      std::to_string(measured) + " computed " + std::to_string(computed));
        }
    }
    // The cuts fall at their slopes: an octave and two below a 1 kHz 48 dB/octave low cut.
    lib::EqFilter cut;
    cut.set(lib::EqType::LowCut48, 1000.0, 0.0, 0.70710678, rate);
    CHECK_NEAR(10 * std::log10(cut.magnitude2(std::tan(kTestPi * 1000 / rate))), -3.01, 0.05);
    CHECK(10 * std::log10(cut.magnitude2(std::tan(kTestPi * 250 / rate))) < -90);
    lib::EqFilter tilt;
    tilt.set(lib::EqType::Tilt, 1000.0, 12.0, 0.7071, rate);
    CHECK_NEAR(10 * std::log10(tilt.magnitude2(std::tan(kTestPi * 20 / rate))), -6.0, 0.1);
    CHECK_NEAR(10 * std::log10(tilt.magnitude2(std::tan(kTestPi * 20000 / rate))), 6.0, 0.2);
}

TEST(the_half_band_oversampler_passes_the_audio_band_and_stops_images) {
    const lib::HalfBandDesign d(8, 0.04);
    double stop = -1e9, ripple = 0;
    for (int i = 0; i <= 2000; ++i) {
        const double f = 0.5 * i / 2000;
        const std::complex<double> z = std::polar(1.0, 2 * kTestPi * f), z2 = z * z;
        std::complex<double> a0 = 1, a1 = 1;
        for (int k = 0; k < d.count(); ++k) {
            const std::complex<double> s = (d.coefficient(k) + 1.0 / z2) / (1.0 + d.coefficient(k) / z2);
            (k % 2 == 0 ? a0 : a1) *= s;
        }
        const double m = 20 * std::log10(std::abs(0.5 * (a0 + a1 / z)) + 1e-30);
        if (f > 0.29) stop = std::max(stop, m);
        if (f < 0.21) ripple = std::max(ripple, std::fabs(m));
    }
    CHECK(stop < -95);
    CHECK(ripple < 1e-6);
    // Up then down returns a 1 kHz sine at its level (a pure phase shift), and a 10 kHz one too.
    for (double hz : {1000.0, 10000.0}) {
        lib::Oversampler2x os(d);
        double in = 0, out = 0;
        for (int i = 0; i < 48000; ++i) {
            const double x = std::sin(2 * kTestPi * hz * i / 48000);
            double up[2];
            os.up(x, up);
            const double y = os.down(up);
            if (i > 1000) in += x * x, out += y * y;
        }
        CHECK_NEAR(10 * std::log10(out / in), 0.0, 0.01);
    }
}

TEST(the_sliding_minimum_and_true_peak_estimate_are_exact_enough) {
    lib::SlidingMinimum m;
    m.prepare(64);
    std::vector<double> xs;
    uint32_t seed = 7;
    for (int i = 0; i < 5000; ++i) {
        seed = seed * 1664525u + 1013904223u;
        const double x = (seed >> 8) / 16777216.0;
        xs.push_back(x);
        const uint32_t w = 1 + (i / 500) % 40;
        const double got = m.push(x, w);
        double want = 1e9;
        for (int k = std::max(0, i - static_cast<int>(w) + 1); k <= i; ++k) want = std::min(want, xs[static_cast<size_t>(k)]);
        if (got != want && w == 1 + ((i - 1) / 500) % 40) {  // a shrinking window settles over the next pushes
            cawtest::fail(__FILE__, __LINE__, "sliding minimum wrong at " + std::to_string(i));
            break;
        }
    }
    // A quarter-rate sine at 45 degrees peaks 3 dB between its samples; the estimate sees it within 0.5 dB.
    lib::TruePeak tp;
    double est = 0, samples = 0;
    for (int i = 0; i < 2000; ++i) {
        const double x = std::sin(kTestPi / 2 * i + kTestPi / 4);
        samples = std::max(samples, std::fabs(x));
        if (i > 16) est = std::max(est, tp.process(x));
        else tp.process(x);
    }
    CHECK_NEAR(db(samples), -3.01, 0.01);
    CHECK(db(est) > -0.5 && db(est) < 0.1);
}

TEST(the_spectrum_analyzer_finds_a_sine_at_its_level_and_frequency) {
    lib::SpectrumAnalyzer a;
    a.prepare(48000, 128, 20, 20000);
    std::vector<float> pre(128), post(128);
    for (int round = 0; round < 10; ++round) {
        for (uint32_t i = 0; i < 2048; ++i) {
            const double t = (round * 2048 + i) / 48000.0;
            a.push(static_cast<float>(std::sin(2 * kTestPi * 1000 * t)), static_cast<float>(0.1 * std::sin(2 * kTestPi * 200 * t)));
        }
        a.analyze(pre.data(), post.data());
    }
    const size_t loudPre = static_cast<size_t>(std::max_element(pre.begin(), pre.end()) - pre.begin());
    const size_t loudPost = static_cast<size_t>(std::max_element(post.begin(), post.end()) - post.begin());
    CHECK(std::fabs(std::log2(a.binHz(static_cast<uint32_t>(loudPre)) / 1000.0)) < 0.1);
    CHECK(std::fabs(std::log2(a.binHz(static_cast<uint32_t>(loudPost)) / 200.0)) < 0.1);
    CHECK_NEAR(pre[loudPre], 0.0, 1.5);   // a full-scale sine reads about 0 dB
    CHECK_NEAR(post[loudPost], -20.0, 1.5);
}

// ---------- Every effect of the suite ----------

TEST(the_effects_suite_is_listed_with_good_descriptors) {
    Engine e(48000);
    for (size_t k = 0; k < std::size(kSuite); ++k) {
        std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(kSuite[k]);
        CHECK(p != nullptr);
        if (!p) continue;
        const ModuleDescriptor& d = p->descriptor();
        CHECK(d.role == ModuleRole::Effect);
        CHECK(ComponentChain::isInstrument(d) == false);
        CHECK(validateModuleDescriptor(d) == ModuleValidation::Ok);
        CHECK(!d.name.empty());
        for (uint32_t i = 0; i < d.parameterCount; ++i) {
            const ParameterDescriptor& q = d.parameters[i];
            CHECK(!q.name.empty());
            // Times, frequencies and rates taper.
            if (q.unit == "Hz" || (q.unit == "ms" && q.minimum > 0) || (q.unit == "s" && q.minimum > 0))
                if (q.curve != ParameterCurve::Exponential)
                    cawtest::fail(__FILE__, __LINE__, std::string(d.id) + "." + std::string(q.id) + " should taper");
        }
    }
    CHECK(e.createNativeComponent("org.caw.compressor")->descriptor().latencyFrames == 240);
    CHECK(e.createNativeComponent("org.caw.limiter")->descriptor().latencyFrames == 240);
    CHECK(e.createNativeComponent("org.caw.eq")->descriptor().latencyFrames == 0);
    CHECK(e.createNativeComponent("org.caw.reverb.pro")->descriptor().tailFrames == kInfiniteTail);
    CHECK(e.createNativeComponent("org.caw.delay.pro")->descriptor().tailFrames == kInfiniteTail);
}

TEST(every_effect_renders_the_same_bits_at_any_block_size_through_sleep_and_wake) {
    Engine e(48000);
    const Stereo in = music(48000 * 2);
    for (const char* id : kSuite) {
        for (const Values& v : {Values{}, busy(id)}) {
            std::unique_ptr<ModuleProcessor> a = make(e, id);
            if (!a) continue;
            const Stereo ref = run(*a, in, v, 64, 120);
            for (uint32_t block : {1u, 37u, 500u}) {
                std::unique_ptr<ModuleProcessor> b = make(e, id);
                const Stereo got = run(*b, in, v, block, 120);
                size_t differ = 0;
                for (size_t i = 0; i < in.size(); ++i) differ += got.l[i] != ref.l[i] || got.r[i] != ref.r[i];
                if (differ)
                    cawtest::fail(__FILE__, __LINE__, std::string(id) + (v.empty() ? " default" : " busy") + ": " +
                                                          std::to_string(differ) + " samples differ at block " + std::to_string(block));
            }
        }
    }
}

TEST(every_effect_stays_finite_and_bounded_whatever_its_knobs) {
    // Random settings (every parameter anywhere in its range) on loud music, a full-scale square and DC.
    Engine e(48000);
    uint32_t seed = 99;
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
    for (const char* id : kSuite) {
        for (int round = 0; round < 12; ++round) {
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
            const Stereo& in = round % 3 == 0 ? loud : round % 3 == 1 ? square : dc;
            const Stereo out = run(*p, in, v, 64, 90);
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
}

TEST(every_effect_falls_quiet_after_its_input_stops_and_wakes_on_input) {
    Engine e(48000);
    for (const char* id : kSuite) {
        std::unique_ptr<ModuleProcessor> p = make(e, id);
        if (!p) continue;
        Stereo in = music(12000);
        in.l.resize(48000 * 12, 0.0f);  // then 11.75 s of silence: past every default tail
        in.r.resize(48000 * 12, 0.0f);
        const Stereo out = run(*p, in);
        if (!p->quiet()) cawtest::fail(__FILE__, __LINE__, std::string(id) + " is not quiet after 11 s of silence");
        CHECK_EQ(out.l.back(), 0.0f);
        const Stereo again = run(*p, sine(440, 0.5, 4800));
        CHECK(!p->quiet());
        CHECK(peak(again.l) > 0.01);
    }
}

TEST(every_effect_publishes_its_display_layout) {
    Engine e(48000);
    for (size_t k = 0; k < std::size(kSuite); ++k) {
        std::unique_ptr<ModuleProcessor> p = make(e, kSuite[k]);
        if (!p) continue;
        float shown[kMaxDisplayFloats];
        CHECK_EQ(p->readDisplay(shown, kMaxDisplayFloats), 0u);  // nothing before it runs
        run(*p, sine(1000, 0.5, 4800));
        const uint32_t n = p->readDisplay(shown, kMaxDisplayFloats);
        if (n != kDisplaySizes[k])
            cawtest::fail(__FILE__, __LINE__, std::string(kSuite[k]) + " publishes " + std::to_string(n) + " floats");
        if (std::string(kSuite[k]) != "org.caw.eq") CHECK_NEAR(shown[0], -6.02, 0.1);  // every other starts with its input peak dB
    }
}

TEST(the_effects_match_their_reference_renders) {
    // 2 s of music through each effect at its defaults and its busy settings, 64-frame blocks, 120 BPM, against
    // references/effects.cawref. Re-record only for an intended sound change (caw_tests --update-references).
    Engine e(48000);
    const Stereo in = music(48000 * 2);
    cawtest::References refs("effects");
    refs.storeWaveformFrames(kWaveformFrames);
    for (const char* id : kSuite)
        for (bool b : {false, true}) {
            std::unique_ptr<ModuleProcessor> p = make(e, id);
            if (!p) continue;
            const Stereo out = run(*p, in, b ? busy(id) : Values{}, 64, 120);
            CHECK_REFERENCE(refs, caseName(id, b), (cawtest::Audio{out.l, out.r}), effectClass(id, b));
        }
}

// The Library's stereo tools and the ducker (#121, #175): the same reference pattern, from a list of their own.
static const char* const kStereoTools[] = {"org.caw.stereo.balance", "org.caw.stereo.width", "org.caw.distortion",
                                    "org.caw.delay.pingpong", "org.caw.chorus",       "org.caw.ducker"};

static Values stereoToolBusy(const char* id) {
    const std::string s = id;
    if (s == "org.caw.stereo.balance") return {{"pan", -0.6}};
    if (s == "org.caw.stereo.width") return {{"width", 1.7}};
    if (s == "org.caw.distortion") return {{"shape", 2}, {"drive", 9}, {"bits", 5}, {"mix", 0.7}, {"output", 0.8}};
    if (s == "org.caw.delay.pingpong") return {{"sync", 2}, {"feedback", 0.7}, {"cross", 0.6}, {"mix", 0.6}};
    if (s == "org.caw.chorus") return {{"rate", 2.2}, {"depth", 0.9}, {"mix", 0.8}};
    // The ducker in Tempo mode (no key needed), every eighth, lows only, a bent shape.
    return {{"mode", 2}, {"rate", 2}, {"depth", 0.7}, {"attack", 5}, {"hold", 20}, {"release", 120}, {"tension", -0.4},
            {"offset", 0.25}, {"bands", 1}, {"crossover", 300}};
}

TEST(the_stereo_tools_and_the_ducker_match_their_reference_renders) {
    // As the_effects_match_their_reference_renders (2 s of music, defaults and busy settings, 64-frame blocks, 120 BPM),
    // with the song playing (the ducker's Tempo mode ducks on its beat), against references/stereo_tools.cawref, and the
    // same bits at 37-frame blocks.
    Engine e(48000);
    const Stereo in = music(48000 * 2);
    cawtest::References refs("stereo_tools");
    refs.storeWaveformFrames(kWaveformFrames);
    for (const char* id : kStereoTools)
        for (bool b : {false, true}) {
            std::unique_ptr<ModuleProcessor> p = make(e, id);
            if (!p) continue;
            const Stereo out = run(*p, in, b ? stereoToolBusy(id) : Values{}, 64, 120, true);  // playing: the ducks
            CHECK_REFERENCE(refs, caseName(id, b), (cawtest::Audio{out.l, out.r}), effectClass(id, b));
            const uint64_t h = hash(out);
            if (hash(run(*make(e, id), in, b ? stereoToolBusy(id) : Values{}, 37, 120, true)) != h)
                cawtest::fail(__FILE__, __LINE__, std::string(id) + " renders differently at another block size");
        }
}

// ---------- EQ ----------

TEST(the_eq_is_transparent_by_default_and_shapes_as_its_bands_say) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.eq");
    const Stereo in = music(48000);
    const Stereo out = run(*p, in);
    size_t differ = 0;
    for (size_t i = 0; i < in.size(); ++i) differ += out.l[i] != in.l[i] || out.r[i] != in.r[i];
    CHECK_EQ(differ, 0u);  // every default band has no gain: the input, bit for bit
    const Values bell = {{"b4_gain", 12}, {"b4_freq", 1000}, {"b4_q", 1}};
    CHECK_NEAR(gainAt(e, "org.caw.eq", bell, 1000), 12.0, 0.05);
    CHECK_NEAR(gainAt(e, "org.caw.eq", bell, 100), 0.0, 0.2);
    const Values cut = {{"b1_on", 1}, {"b1_type", 5}, {"b1_freq", 1000}};
    CHECK(gainAt(e, "org.caw.eq", cut, 250) < -90);
    CHECK_NEAR(gainAt(e, "org.caw.eq", cut, 8000), 0.0, 0.1);
    CHECK_NEAR(gainAt(e, "org.caw.eq", {{"output", -6}}, 500), -6.0, 0.01);
    // A mid band leaves a side-only signal alone; a side band leaves a mono one alone.
    std::unique_ptr<ModuleProcessor> q = make(e, "org.caw.eq");
    Stereo side = sine(1000, 0.25, 24000);
    for (float& x : side.r) x = -x;
    for (size_t i = 0; i < side.size(); ++i) side.r[i] = -side.l[i];
    const Stereo sOut = run(*q, side, {{"b4_gain", 12}, {"b4_channel", 1}});
    CHECK_NEAR(db(rms(sOut.l, 12000, 24000) / rms(side.l, 12000, 24000)), 0.0, 0.01);
    std::unique_ptr<ModuleProcessor> r = make(e, "org.caw.eq");
    const Stereo mono = sine(1000, 0.25, 24000);
    const Stereo mOut = run(*r, mono, {{"b4_gain", 12}, {"b4_channel", 2}});
    CHECK_NEAR(db(rms(mOut.l, 12000, 24000) / rms(mono.l, 12000, 24000)), 0.0, 0.01);
}

TEST(the_eq_display_shows_its_spectrum_and_curve_while_watched) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.eq");
    float shown[kMaxDisplayFloats];
    const Values bell = {{"b4_gain", 9}, {"b4_freq", 2000}, {"b4_q", 2}};
    run(*p, sine(500, 0.5, 4800), bell);
    CHECK_EQ(p->readDisplay(shown, kMaxDisplayFloats), 439u);
    CHECK_EQ(shown[3], 0.0f);  // nobody had looked: no spectrum worked out
    for (int k = 0; k < 20; ++k) {  // a UI reading every frame
        run(*p, sine(500, 0.5, 800), bell);
        p->readDisplay(shown, kMaxDisplayFloats);
    }
    CHECK_EQ(shown[3], 1.0f);
    CHECK_EQ(shown[0], 128.0f);
    const float* pre = shown + 4;
    const float* curve = shown + 4 + 256;
    int loudest = 0, top = 0;
    for (int j = 0; j < 128; ++j) {
        if (pre[j] > pre[loudest]) loudest = j;
        if (curve[j] > curve[top]) top = j;
    }
    auto hz = [](int j) { return 20.0 * std::pow(1000.0, (j + 0.5) / 128.0); };
    CHECK(std::fabs(std::log2(hz(loudest) / 500.0)) < 0.1);
    CHECK(std::fabs(std::log2(hz(top) / 2000.0)) < 0.1);
    CHECK_NEAR(curve[top], 9.0, 0.3);
    const float* band4 = shown + 4 + 384 + 3 * 6;
    CHECK_EQ(band4[2], 2000.0f);
    CHECK_EQ(band4[3], 9.0f);
}

// ---------- Dynamics ----------

TEST(the_compressor_holds_a_steady_level_at_its_curve_and_declares_its_delay) {
    Engine e(48000);
    // A square wave at -6 dBFS (a steady level for the peak detector), threshold -18, ratio 4, hard knee:
    // -18 + 12 / 4 = -15 dBFS out.
    Stereo sq = silence(48000);
    for (size_t i = 0; i < sq.size(); ++i) sq.l[i] = sq.r[i] = (i / 240) % 2 ? 0.5f : -0.5f;
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.compressor");
    const Stereo out = run(*p, sq, {{"knee", 0}, {"auto_makeup", 0}});
    CHECK_NEAR(db(peak(out.l, 40000, 48000)), -15.0, 0.1);
    float shown[16];
    CHECK_EQ(p->readDisplay(shown, 16), 11u);
    CHECK_NEAR(shown[3], 9.0, 0.1);  // gain reduction now
    CHECK_NEAR(shown[5], -18.0, 1e-6);
    // Auto makeup adds back half the reduction a 0 dBFS signal would get (13.5 / 2 dB).
    std::unique_ptr<ModuleProcessor> m = make(e, "org.caw.compressor");
    const Stereo made = run(*m, sq, {{"knee", 0}});
    CHECK_NEAR(db(peak(made.l, 40000, 48000)), -15.0 + 6.75, 0.1);
    // The audio is delayed by the declared 240 frames, whatever the look-ahead.
    for (double look : {0.0, 5.0}) {
        std::unique_ptr<ModuleProcessor> d = make(e, "org.caw.compressor");
        const Stereo imp = run(*d, impulse(1000, 0.01f), {{"lookahead", look}, {"auto_makeup", 0}});
        CHECK_NEAR(imp.l[240], 0.01, 1e-6);
        CHECK_EQ(imp.l[239], 0.0f);
    }
    // Below the threshold nothing changes.
    CHECK_NEAR(gainAt(e, "org.caw.compressor", {{"threshold", -6}, {"auto_makeup", 0}}, 300), 0.0, 0.01);
}

TEST(the_compressor_look_ahead_catches_a_step_before_it_arrives) {
    Engine e(48000);
    Stereo step = silence(9600);
    for (size_t i = 4800; i < step.size(); ++i) step.l[i] = step.r[i] = 0.9f;
    const Values v = {{"threshold", -20}, {"ratio", 20}, {"attack", 0.5}, {"knee", 0}, {"auto_makeup", 0}};
    std::unique_ptr<ModuleProcessor> a = make(e, "org.caw.compressor");
    std::unique_ptr<ModuleProcessor> b = make(e, "org.caw.compressor");
    Values ahead = v;
    ahead.push_back({"lookahead", 5});
    const Stereo late = run(*a, step, v), early = run(*b, step, ahead);
    // The step leaves the delay at 4800 + 240: with look-ahead it is already turned down there.
    CHECK(early.l[5040] < 0.5 * late.l[5040]);
}

TEST(the_limiter_never_passes_its_ceiling_and_keeps_true_peaks_near_it) {
    Engine e(48000);
    const Stereo in = music(48000 * 2);
    for (double ceiling : {-1.0, -6.0}) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.limiter");
        const Stereo out = run(*p, in, {{"gain", 18}, {"ceiling", ceiling}});
        const double limit = std::pow(10.0, ceiling / 20.0);
        CHECK(peak(out.l) <= limit * 1.000001);
        CHECK(peak(out.r) <= limit * 1.000001);
        CHECK(db(peak(out.l)) > ceiling - 1.0);  // and it gets there
        // The 4x-interpolated peak of the output stays within 0.5 dB of the ceiling.
        lib::TruePeak tp;
        double tpMax = 0;
        for (float x : out.l) tpMax = std::max(tpMax, tp.process(x));
        CHECK(db(tpMax) < ceiling + 0.5);
    }
    // Quiet audio passes unchanged (after the delay).
    std::unique_ptr<ModuleProcessor> q = make(e, "org.caw.limiter");
    const Stereo quietIn = sine(200, 0.1, 9600);
    const Stereo quietOut = run(*q, quietIn);
    for (size_t i = 240; i < 9600; i += 97) CHECK_NEAR(quietOut.l[i], quietIn.l[i - 240], 1e-6);
    float shown[8];
    CHECK_EQ(q->readDisplay(shown, 8), 7u);
    CHECK_EQ(shown[3], 0.0f);
}

TEST(the_gate_closes_below_its_threshold_and_opens_above) {
    Engine e(48000);
    CHECK(gainAt(e, "org.caw.gate", {{"threshold", 0}}, 300) < -60);  // the sine peaks 12 dB under: 9 x 12 dB down, held at the -80 range
    CHECK_NEAR(gainAt(e, "org.caw.gate", {{"threshold", -40}}, 300), 0.0, 0.05);
    CHECK_NEAR(gainAt(e, "org.caw.gate", {{"threshold", -6}, {"range", -12}, {"ratio", 50}}, 300), -12.0, 0.1);
}

TEST(the_transient_shaper_lifts_or_softens_attacks) {
    Engine e(48000);
    Stereo hits = silence(48000);
    for (size_t i = 0; i < hits.size(); ++i) {
        const double env = detExp(-static_cast<double>(i % 12000) / 3000.0);
        hits.l[i] = hits.r[i] = static_cast<float>(0.5 * env * detSin(kTwoPi * 200 * i / 48000.0));
    }
    auto attackToTail = [&](const Values& v) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.transient");
        const Stereo out = run(*p, hits, v);
        return db(rms(out.l, 24000, 24480) / rms(out.l, 30000, 33000));
    };
    const double flat = attackToTail({}), punchy = attackToTail({{"attack", 1}}), soft = attackToTail({{"attack", -1}});
    const double longer = attackToTail({{"sustain", 1}});
    CHECK(punchy > flat + 3);
    CHECK(soft < flat - 3);
    CHECK(longer < flat - 2);
}

// ---------- Reverb and delay ----------

TEST(the_reverb_tail_decays_at_its_decay_time_and_freezes) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.reverb.pro");
    const Values v = {{"mix", 1}, {"low_cut", 20}, {"high_cut", 20000}, {"damping", 0}, {"mod", 0}, {"decay", 2}, {"predelay", 0}};
    const Stereo out = run(*p, impulse(48000 * 3, 0.5f), v);
    // Energy in 100 ms windows: the drop from 0.5 s to 1.5 s is 30 dB at RT60 = 2 s.
    const double a = rms(out.l, 24000, 28800), b = rms(out.l, 72000, 76800);
    CHECK_NEAR(db(a / b), 30.0, 4.0);
    // Frozen after 0.5 s: the level a second later is where it was.
    std::unique_ptr<ModuleProcessor> f = make(e, "org.caw.reverb.pro");
    Stereo in = impulse(48000 * 2, 0.5f);
    Stereo first = silence(24000), second = silence(72000);
    first.l = std::vector<float>(in.l.begin(), in.l.begin() + 24000);
    first.r = std::vector<float>(in.r.begin(), in.r.begin() + 24000);
    run(*f, first, v);
    Values frozen = v;
    frozen.push_back({"freeze", 1});
    const Stereo held = run(*f, second, frozen);
    CHECK_NEAR(db(rms(held.l, 2400, 7200) / rms(held.l, 60000, 64800)), 0.0, 1.5);
    CHECK(!f->quiet());
}

TEST(the_reverb_ducks_its_tail_under_the_input) {
    Engine e(48000);
    const Stereo in = sine(300, 0.7, 48000);
    auto wet = [&](double duck) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.reverb.pro");
        const Stereo out = run(*p, in, {{"mix", 1}, {"duck", duck}});
        return rms(out.l, 24000, 48000);
    };
    CHECK(db(wet(1.0) / wet(0.0)) < -20);
}

TEST(the_delay_repeats_at_its_time_with_its_feedback_bouncing_in_ping_pong) {
    Engine e(48000);
    const Values plain = {{"sync", 0}, {"time", 100}, {"feedback", 0.5}, {"mix", 1}, {"low_cut", 20}, {"high_cut", 20000},
                          {"drive", 0}, {"mod_depth", 0}};
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.delay.pro");
    const Stereo out = run(*p, impulse(24000, 0.5f), plain);
    CHECK_NEAR(out.l[4800], 0.5, 0.01);
    CHECK_NEAR(out.l[9600], 0.25, 0.01);
    CHECK_NEAR(out.l[14400], 0.125, 0.01);
    CHECK(std::fabs(out.l[4700]) < 1e-3);
    Values pp = plain;
    pp.push_back({"mode", 1});
    std::unique_ptr<ModuleProcessor> q = make(e, "org.caw.delay.pro");
    const Stereo bounce = run(*q, impulse(24000, 0.5f), pp);
    CHECK(std::fabs(bounce.l[4800]) > 0.4 && std::fabs(bounce.r[4800]) < 1e-3);
    CHECK(std::fabs(bounce.r[9600]) > 0.2 && std::fabs(bounce.l[9600]) < 1e-3);
    // Synced: a quarter note at 120 BPM is half a second; the transport's tempo moves it.
    Values synced = plain;
    synced[0].second = 9;  // 1/4
    std::unique_ptr<ModuleProcessor> s = make(e, "org.caw.delay.pro");
    const Stereo q4 = run(*s, impulse(48000, 0.5f), synced, 64, 120);
    CHECK_NEAR(q4.l[24000], 0.5, 0.01);
    std::unique_ptr<ModuleProcessor> t = make(e, "org.caw.delay.pro");
    const Stereo q4fast = run(*t, impulse(48000, 0.5f), synced, 64, 150);
    CHECK_NEAR(q4fast.l[19200], 0.5, 0.01);
    // Frozen, the loop repeats without fading and takes no new input.
    std::unique_ptr<ModuleProcessor> f = make(e, "org.caw.delay.pro");
    run(*f, impulse(4000, 0.5f), plain);
    Values freeze = plain;
    freeze.push_back({"freeze", 1});
    const Stereo held = run(*f, sine(1000, 0.5, 48000), freeze);
    CHECK_NEAR(peak(held.l, 40000, 48000), 0.5, 0.02);
}

// ---------- Saturator ----------

TEST(the_saturator_bends_loud_signals_and_oversampling_cuts_aliases) {
    Engine e(48000);
    // Nearly clean at no drive and -12 dBFS: every mode passes the sine within a dB (the tube's asymmetry bends
    // its negative half soonest).
    for (int mode = 0; mode < 5; ++mode)
        CHECK_NEAR(gainAt(e, "org.caw.saturator", {{"mode", mode}, {"drive", 0}, {"auto_gain", 0}}, 400), 0.0, mode == 1 ? 1.0 : 0.25);
    // A 7 kHz sine hard-clipped at 24 dB of drive: the aliases (energy away from the harmonics' bins) fall with 2x.
    auto aliases = [&](double oversample) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.saturator");
        const Stereo out = run(*p, sine(7031.25, 0.5, 8192 * 2), {{"mode", 3}, {"drive", 24}, {"oversample", oversample}});
        std::vector<std::complex<double>> d(8192);
        for (size_t i = 0; i < 8192; ++i) d[i] = out.l[8192 + i] * (0.5 - 0.5 * std::cos(2 * kTestPi * i / 8192));
        analysis::fft(d, false);
        double harm = 0, other = 0;
        for (size_t k = 2; k < 4096; ++k) {
            const double hz = k * 48000.0 / 8192, n = hz / 7031.25, p = std::norm(d[k]);
            (std::fabs(n - std::round(n)) * 7031.25 < 30 ? harm : other) += p;
        }
        return 10 * std::log10(other / harm);
    };
    CHECK(aliases(1) < aliases(0) - 8);  // a hard clip's harmonics fall slowly (1/n): 2x buys about 9 dB
    // Crush: few bits leave few levels.
    std::unique_ptr<ModuleProcessor> c = make(e, "org.caw.saturator");
    const Stereo crushed = run(*c, sine(100, 0.9, 4800), {{"mode", 5}, {"bits", 2}, {"drive", 0}, {"auto_gain", 0}, {"tone", 0}});
    CHECK(peak(crushed.l) > 0.3);
    float shown[80];
    CHECK_EQ(c->readDisplay(shown, 80), 73u);
    CHECK_EQ(shown[2], 5.0f);
}

// ---------- Kit ----------

TEST(the_filter_cuts_as_its_type_says_and_follows_its_lfo) {
    Engine e(48000);
    CHECK(gainAt(e, "org.caw.filter", {{"cutoff", 1000}}, 4000) < -40);
    CHECK_NEAR(gainAt(e, "org.caw.filter", {{"cutoff", 1000}}, 100), 0.0, 0.2);
    CHECK(gainAt(e, "org.caw.filter", {{"type", 3}, {"cutoff", 1000}}, 250) < -40);
    CHECK(gainAt(e, "org.caw.filter", {{"type", 6}, {"cutoff", 500}, {"resonance", 0}}, 4000) < -50);
    CHECK(gainAt(e, "org.caw.filter", {{"type", 5}, {"cutoff", 1000}, {"resonance", 0}}, 1000) < -30);
    // The LFO moves the cutoff it shows.
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.filter");
    float shown[80], lo = 1e9, hi = 0;
    for (int k = 0; k < 60; ++k) {
        run(*p, sine(300, 0.3, 800), {{"lfo_amount", 0.5}, {"lfo_rate", 2}});
        p->readDisplay(shown, 80);
        lo = std::min(lo, shown[3]);
        hi = std::max(hi, shown[3]);
    }
    CHECK(hi / lo > 8.0);  // +-2 octaves
}

TEST(the_phaser_and_flanger_notch_and_sweep) {
    Engine e(48000);
    // White-ish noise in: the output's spectrum gets notches (its band energies spread much more than the input's).
    const Stereo in = music(48000);
    for (const char* id : {"org.caw.phaser", "org.caw.flanger"}) {
        std::unique_ptr<ModuleProcessor> p = make(e, id);
        const Stereo out = run(*p, in);
        double differ = 0;
        for (size_t i = 0; i < in.size(); ++i) differ += std::fabs(out.l[i] - in.l[i]);
        CHECK(differ / in.size() > 0.005);
        CHECK(peak(out.l) < 2.0);
    }
    // A flanger at mix 0.5 and no feedback, its delay held (depth 0), cancels a sine whose half period is the delay.
    std::unique_ptr<ModuleProcessor> f = make(e, "org.caw.flanger");
    const Stereo out = run(*f, sine(250, 0.5, 24000), {{"delay", 2}, {"depth", 0}, {"feedback", 0}, {"mix", 0.5}});
    CHECK(rms(out.l, 12000, 24000) < 0.01);
}

TEST(the_utility_monos_inverts_widens_and_keeps_the_bass_central) {
    Engine e(48000);
    const Stereo in = sine(1000, 0.4, 4800, 1.0);
    std::unique_ptr<ModuleProcessor> m = make(e, "org.caw.utility");
    const Stereo mono = run(*m, in, {{"channels", 1}});
    for (size_t i = 0; i < in.size(); i += 37) CHECK_EQ(mono.l[i], mono.r[i]);
    std::unique_ptr<ModuleProcessor> v = make(e, "org.caw.utility");
    const Stereo inv = run(*v, in, {{"invert_l", 1}});
    for (size_t i = 100; i < in.size(); i += 37) CHECK_NEAR(inv.l[i], -in.l[i], 1e-6);
    CHECK_NEAR(gainAt(e, "org.caw.utility", {{"gain", -6}}, 500), -6.0, 1e-3);
    // Bass mono: a 50 Hz side signal is all but gone below a 200 Hz corner; at 5 kHz it stays.
    auto sideLeft = [&](double hz) {
        Stereo s = sine(hz, 0.4, 24000);
        for (size_t i = 0; i < s.size(); ++i) s.r[i] = -s.l[i];
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.utility");
        const Stereo out = run(*p, s, {{"bass_mono", 1}, {"bass_freq", 200}});
        return db(rms(out.l, 12000, 24000) / rms(s.l, 12000, 24000));
    };
    CHECK(sideLeft(50) < -20);
    CHECK_NEAR(sideLeft(5000), 0.0, 0.1);
    float shown[8];
    CHECK_EQ(m->readDisplay(shown, 8), 6u);
    CHECK_NEAR(shown[2], 1.0, 1e-6);  // mono: correlation 1
}

// ---------- Through the engine ----------

TEST(an_eq_on_a_track_publishes_through_the_c_api) {
    CawEngine* handle = caw_engine_create(48000);
    CHECK(handle != nullptr);
    if (!handle) return;
    Engine& e = *handle->engine;
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    LayerSpec l = cawtest::testSignalLayer("t", cawtest::Shape::Sine, {{"freq", 440}, {"level", 0.5}});
    l.components = {{"org.caw.eq", {{"b4_gain", 6}}}, {"org.caw.compressor", {}}};
    p.layers.push_back(l);
    p.masterComponents = {{"org.caw.limiter", {}}};
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> left(256), right(256);
    std::vector<float> shown(1024);
    for (int k = 0; k < 40; ++k) {
        caw_engine_process(handle, left.data(), right.data(), 256);
        caw_engine_component_display(handle, "t", 0, shown.data(), 1024);  // a UI watching
    }
    CHECK_EQ(caw_engine_component_display(handle, "t", 0, shown.data(), 1024), 439);
    CHECK_EQ(shown[3], 1.0f);
    CHECK_EQ(caw_engine_component_display(handle, "t", 1, shown.data(), 1024), 11);
    CHECK_EQ(caw_engine_component_display(handle, nullptr, 0, shown.data(), 1024), 7);
    // The compressor reports the latency the engine compensates.
    CHECK(caw_engine_component_display(handle, "t", 2, shown.data(), 1024) == -1);
    caw_engine_destroy(handle);
}
