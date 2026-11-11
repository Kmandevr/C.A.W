// fx-space: the Space, Modulation and Utility effects (convolver, shimmer, ensemble, doubler, Haas, imager, LFO effects, rotary, mixer).
#include <algorithm>
#include <cmath>
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
#include "caw/library/convolver.hpp"
#include "builtin_fx_space.h"
#include "component_chain.h"
#include "engine.h"
#include "presets.h"
#include "test.h"

using namespace caw;
using fx::DecodedIr;
using fx::decodeIrWav;

namespace {

using Values = std::vector<std::pair<std::string, double>>;

const char* const kSpaceSuite[] = {"org.caw.ensemble", "org.caw.doubler",  "org.caw.vibrato", "org.caw.tremolo",
                                   "org.caw.autopan",  "org.caw.rotary",   "org.caw.haas",    "org.caw.imager",
                                   "org.caw.channelmixer", "org.caw.convolver", "org.caw.shimmer"};
// How many floats each publishes (docs/engine.md, "Display data").
const uint32_t kSpaceDisplay[] = {13, 7, 6, 7, 7, 6, 7, 265, 4, 73, 7};

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

// `in` through p in `block`-frame blocks, `values` over the defaults, a transport at `tempo` (playing when `playing`).
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
    t.playing = playing;
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
        t.beat = tempo > 0 ? static_cast<double>(start) * tempo / (60.0 * 48000) : 0.0;
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
// The same music the suite's tests use (effects_test.cpp): plucks, noise bursts, a gap of silence.
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
double correlation(const Stereo& s, size_t from, size_t to) {
    double lr = 0, ll = 0, rr = 0;
    for (size_t i = from; i < to; ++i) lr += double(s.l[i]) * s.r[i], ll += double(s.l[i]) * s.l[i], rr += double(s.r[i]) * s.r[i];
    return lr / std::sqrt(std::max(1e-30, ll * rr));
}
// The level of `hz` in x[from, to) (Goertzel), as an amplitude.
double toneLevel(const std::vector<float>& x, size_t from, size_t to, double hz) {
    const double w = kTwoPi * hz / 48000.0, c = 2.0 * std::cos(w);
    double s1 = 0, s2 = 0;
    for (size_t i = from; i < to; ++i) {
        const double s0 = x[i] + c * s1 - s2;
        s2 = s1, s1 = s0;
    }
    const double re = s1 - s2 * std::cos(w), im = s2 * std::sin(w);
    return 2.0 * std::sqrt(re * re + im * im) / static_cast<double>(to - from);
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

Values busy(const char* id) {
    const std::string s = id;
    if (s == "org.caw.ensemble") return {{"voices", 5}, {"delay", 15}, {"detune", 30}, {"rate", 1.3}, {"motion", 2}, {"tone", 6000}, {"mix", 0.7}};
    if (s == "org.caw.doubler") return {{"voices", 1}, {"delay", 30}, {"detune", 15}, {"drift", 0.8}, {"low_cut", 300}, {"high_cut", 5000}, {"mix", 0.8}};
    if (s == "org.caw.vibrato") return {{"sync", 6}, {"depth", 60}, {"shape", 1}, {"stereo", 0.7}, {"mix", 0.8}};
    if (s == "org.caw.tremolo") return {{"sync", 3}, {"depth", 0.9}, {"shape", 4}, {"smooth", 0.4}, {"stereo", 1}, {"mode", 1}};
    if (s == "org.caw.autopan") return {{"sync", 6}, {"depth", 1}, {"shape", 1}, {"smooth", 0.3}, {"offset", 0.25}, {"width", 0.2}};
    if (s == "org.caw.rotary") return {{"speed", 1}, {"accel", 0.5}, {"balance", 0.3}, {"drive", 12}, {"width", 1}, {"doppler", 1}, {"mix", 0.8}};
    if (s == "org.caw.haas") return {{"side", 0}, {"delay", 25}, {"guard", 300}, {"level", -3}, {"mix", 0.8}};
    if (s == "org.caw.imager") return {{"low_freq", 300}, {"high_freq", 3000}, {"low_width", 0}, {"mid_width", 1.5}, {"high_width", 2}, {"mid_gain", -2}, {"side_gain", 3}, {"output", -1}};
    if (s == "org.caw.channelmixer") return {{"left_to_left", 0.3}, {"right_to_left", -0.7}, {"left_to_right", 0.6}, {"right_to_right", 0.2}};
    if (s == "org.caw.convolver") return {{"source", 3}, {"decay", 1.5}, {"size", 0.7}, {"damping", 0.6}, {"length", 0.8}, {"reverse", 1}, {"predelay", 40}, {"low_cut", 200}, {"high_cut", 8000}, {"width", 1.5}, {"mix", 0.6}};
    return {{"size", 0.9}, {"decay", 10}, {"shift", 1}, {"amount", 0.9}, {"tone", 5000}, {"low_cut", 500}, {"mod", 0.8}, {"width", 1.5}, {"mix", 0.6}};
}

// A WAV file's bytes: 16-bit (bits 16), 24-bit (24) or 32-bit float (32), `channels` sides of `frames` frames.
std::vector<uint8_t> wav(int bits, int channels, const std::vector<std::vector<float>>& sides, uint32_t rate = 48000) {
    const uint32_t frames = static_cast<uint32_t>(sides[0].size()), bytes = bits / 8, align = channels * bytes;
    std::vector<uint8_t> w;
    auto u32 = [&](uint32_t v) { for (int k = 0; k < 4; ++k) w.push_back(static_cast<uint8_t>(v >> (8 * k))); };
    auto u16 = [&](uint32_t v) { for (int k = 0; k < 2; ++k) w.push_back(static_cast<uint8_t>(v >> (8 * k))); };
    w.insert(w.end(), {'R', 'I', 'F', 'F'});
    u32(36 + frames * align);
    w.insert(w.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
    u32(16), u16(bits == 32 ? 3 : 1), u16(channels), u32(rate), u32(rate * align), u16(align), u16(bits);
    w.insert(w.end(), {'d', 'a', 't', 'a'});
    u32(frames * align);
    for (uint32_t i = 0; i < frames; ++i)
        for (int c = 0; c < channels; ++c) {
            const double v = sides[static_cast<size_t>(c)][i];
            if (bits == 32) {
                const float f = static_cast<float>(v);
                uint32_t b;
                std::memcpy(&b, &f, 4);
                u32(b);
            } else if (bits == 24) {
                const int32_t s = static_cast<int32_t>(std::lround(v * 8388607.0));
                for (int k = 0; k < 3; ++k) w.push_back(static_cast<uint8_t>(s >> (8 * k)));
            } else {
                u16(static_cast<uint32_t>(static_cast<int16_t>(std::lround(v * 32767.0))));
            }
        }
    return w;
}

}  // namespace

// ---------- The convolution kernel ----------

TEST(fx_space_the_partitioned_convolver_matches_direct_convolution_and_crossfades) {
    lib::PartitionedConvolver c;
    c.prepare(64, 1000);
    CHECK_EQ(c.latency(), 64u);
    // A response of 300 frames, different per side, staged and committed.
    std::vector<float> hl(300), hr(300);
    uint32_t seed = 3;
    for (size_t i = 0; i < hl.size(); ++i) {
        seed = seed * 1664525u + 1013904223u;
        hl[i] = static_cast<float>(((seed >> 8) / 8388608.0 - 1.0) * std::exp(-double(i) / 80.0));
        hr[i] = static_cast<float>(i % 37 == 0 ? 0.5 : 0.0);
    }
    const uint32_t parts = (300 + 63) / 64;
    for (uint32_t k = 0; k < parts; ++k) {
        const uint32_t n = std::min<uint32_t>(64, 300 - k * 64);
        c.stage(k, hl.data() + k * 64, hr.data() + k * 64, n);
    }
    c.commit(parts);
    // Silence through it until the response plays (one block), then a signal: the output is the direct
    // convolution, 64 frames late, at any call size.
    // Two blocks: the commit's boundary, then the fade in from the empty response.
    std::vector<float> zl(128), zr(128);
    c.process(zl.data(), zr.data(), zl.data(), zr.data(), 128);
    std::vector<float> xl(2000), xr(2000), yl(2000), yr(2000);
    for (size_t i = 0; i < xl.size(); ++i) {
        seed = seed * 1664525u + 1013904223u;
        xl[i] = static_cast<float>((seed >> 8) / 8388608.0 - 1.0);
        xr[i] = static_cast<float>(std::sin(0.01 * i));
    }
    for (size_t at = 0; at < xl.size();) {
        const uint32_t n = std::min<uint32_t>(static_cast<uint32_t>(xl.size() - at), static_cast<uint32_t>(1 + at % 23));
        c.process(xl.data() + at, xr.data() + at, yl.data() + at, yr.data() + at, n);
        at += n;
    }
    double worst = 0;
    for (size_t i = 64; i < xl.size(); ++i) {
        double el = 0, er = 0;
        for (size_t k = 0; k < hl.size() && k <= i - 64; ++k) {
            el += double(hl[k]) * xl[i - 64 - k];
            er += double(hr[k]) * xr[i - 64 - k];
        }
        worst = std::max({worst, std::fabs(el - yl[i]), std::fabs(er - yr[i])});
    }
    CHECK(worst < 2e-4);
    // A new response (a single tap of 0.5) fades in over one block and then plays alone.
    std::vector<float> tap(1, 0.5f);
    c.stage(0, tap.data(), tap.data(), 1);
    c.commit(1);
    CHECK(!c.canStage());
    std::vector<float> ones(64 * 6, 1.0f), ol(64 * 6), orr(64 * 6);
    c.process(ones.data(), ones.data(), ol.data(), orr.data(), static_cast<uint32_t>(ones.size()));
    CHECK(c.canStage());
    CHECK_NEAR(ol.back(), 0.5, 1e-5);
    CHECK_NEAR(orr.back(), 0.5, 1e-5);
}

// ---------- The suite's contract (as effects_test.cpp checks the others) ----------

TEST(fx_space_effects_are_listed_with_good_descriptors_and_presets) {
    Engine e(48000);
    for (const char* id : kSpaceSuite) {
        std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(id);
        if (!p) {
            cawtest::fail(__FILE__, __LINE__, std::string(id) + " is not registered");
            continue;
        }
        const ModuleDescriptor& d = p->descriptor();
        CHECK(d.role == ModuleRole::Effect);
        CHECK(validateModuleDescriptor(d) == ModuleValidation::Ok);
        for (uint32_t i = 0; i < d.parameterCount; ++i) {
            const ParameterDescriptor& q = d.parameters[i];
            if (q.unit == "Hz" || (q.unit == "ms" && q.minimum > 0) || (q.unit == "s" && q.minimum > 0))
                if (q.curve != ParameterCurve::Exponential)
                    cawtest::fail(__FILE__, __LINE__, std::string(id) + "." + std::string(q.id) + " should taper");
        }
        // 3 to 8 factory presets, each naming only the effect's own parameters, within their ranges.
        const std::vector<BuiltinPreset>& presets = builtinPresets(id);
        if (presets.size() < 3 || presets.size() > 8) cawtest::fail(__FILE__, __LINE__, std::string(id) + " has " + std::to_string(presets.size()) + " presets");
        for (const BuiltinPreset& pr : presets)
            for (const auto& [k, v] : pr.values) {
                const int at = paramIndex(d, std::string(k));
                if (at >= 0 && (v < d.parameters[at].minimum || v > d.parameters[at].maximum))
                    cawtest::fail(__FILE__, __LINE__, std::string(id) + " preset " + std::string(pr.name) + ": " + std::string(k) + " out of range");
            }
    }
    CHECK_EQ(e.createNativeComponent("org.caw.convolver")->descriptor().latencyFrames, 512u);
    CHECK(e.createNativeComponent("org.caw.convolver")->descriptor().maxStateBytes >= 7680000u);
}

TEST(fx_space_effects_render_the_same_bits_at_any_block_size_through_sleep_and_wake) {
    Engine e(48000);
    const Stereo in = music(48000 * 2);
    for (const char* id : kSpaceSuite)
        for (const Values& v : {Values{}, busy(id)}) {
            std::unique_ptr<ModuleProcessor> a = make(e, id);
            if (!a) continue;
            const Stereo ref = run(*a, in, v, 64, 120, true);
            for (uint32_t block : {1u, 37u, 500u}) {
                std::unique_ptr<ModuleProcessor> b = make(e, id);
                const Stereo got = run(*b, in, v, block, 120, true);
                size_t differ = 0;
                for (size_t i = 0; i < in.size(); ++i) differ += got.l[i] != ref.l[i] || got.r[i] != ref.r[i];
                if (differ)
                    cawtest::fail(__FILE__, __LINE__, std::string(id) + (v.empty() ? " default" : " busy") + ": " +
                                                          std::to_string(differ) + " samples differ at block " + std::to_string(block));
            }
        }
}

TEST(fx_space_effects_stay_finite_and_bounded_whatever_their_knobs) {
    Engine e(48000);
    uint32_t seed = 77;
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
    for (const char* id : kSpaceSuite)
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
            const Stereo out = run(*p, in, v, 64, 90, true);
            bool finite = true;
            double most = 0;
            for (size_t i = 0; i < out.size(); ++i) {
                finite &= std::isfinite(out.l[i]) && std::isfinite(out.r[i]);
                most = std::max({most, std::fabs(double(out.l[i])), std::fabs(double(out.r[i]))});
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

TEST(fx_space_effects_fall_quiet_after_their_input_stops_and_wake_on_input) {
    Engine e(48000);
    for (const char* id : kSpaceSuite) {
        std::unique_ptr<ModuleProcessor> p = make(e, id);
        if (!p) continue;
        Stereo in = music(12000);
        in.l.resize(48000 * 14, 0.0f);
        in.r.resize(48000 * 14, 0.0f);
        const Stereo out = run(*p, in);
        if (!p->quiet()) cawtest::fail(__FILE__, __LINE__, std::string(id) + " is not quiet after 13 s of silence");
        CHECK_EQ(out.l.back(), 0.0f);
        const Stereo again = run(*p, sine(440, 0.5, 9600));
        CHECK(!p->quiet());
        if (peak(again.l) <= 0.01 && peak(again.r) <= 0.01) cawtest::fail(__FILE__, __LINE__, std::string(id) + " did not wake");
    }
}

TEST(fx_space_effects_publish_their_display_layouts) {
    Engine e(48000);
    for (size_t k = 0; k < std::size(kSpaceSuite); ++k) {
        std::unique_ptr<ModuleProcessor> p = make(e, kSpaceSuite[k]);
        if (!p) continue;
        float shown[kMaxDisplayFloats];
        CHECK_EQ(p->readDisplay(shown, kMaxDisplayFloats), 0u);
        run(*p, sine(1000, 0.5, 4800));
        const uint32_t n = p->readDisplay(shown, kMaxDisplayFloats);
        if (n != kSpaceDisplay[k]) cawtest::fail(__FILE__, __LINE__, std::string(kSpaceSuite[k]) + " publishes " + std::to_string(n) + " floats");
        CHECK_NEAR(shown[0], -6.02, 0.1);  // each starts with its input peak in dB
    }
}

TEST(fx_space_effects_match_their_golden_renders) {
    struct Golden {
        const char* id;
        bool busy;
        uint64_t hash;
    };
    const Golden goldens[] = {
#include "fx_space_golden.inc"
    };
    Engine e(48000);
    const Stereo in = music(48000 * 2);
    for (const char* id : kSpaceSuite)
        for (bool b : {false, true}) {
            std::unique_ptr<ModuleProcessor> p = make(e, id);
            if (!p) continue;
            const uint64_t h = hash(run(*p, in, b ? busy(id) : Values{}, 64, 120, true));
            const Golden* g = nullptr;
            for (const Golden& x : goldens)
                if (std::strcmp(x.id, id) == 0 && x.busy == b) g = &x;
            if (!g || g->hash != h) {
                char buf[160];
                std::snprintf(buf, sizeof buf, "    {\"%s\", %s, 0x%016llxull},", id, b ? "true" : "false", static_cast<unsigned long long>(h));
                cawtest::fail(__FILE__, __LINE__, buf);
            }
        }
}

// ---------- Convolution reverb ----------

TEST(fx_space_wav_impulse_responses_decode_and_bad_files_are_refused) {
    DecodedIr ir;
    const char* error = nullptr;
    const std::vector<float> a = {0.5f, -0.25f, 0.125f, 0.0f}, b = {-1.0f, 0.75f, 0.0f, 0.25f};
    CHECK(decodeIrWav(wav(16, 1, {a}).data(), wav(16, 1, {a}).size(), ir, error));
    CHECK_EQ(ir.channels, 1u);
    CHECK_EQ(ir.left.size(), 4u);
    CHECK_NEAR(ir.left[1], -0.25, 1e-4);
    CHECK_NEAR(ir.right[1], -0.25, 1e-4);
    const std::vector<uint8_t> w24 = wav(24, 2, {a, b}, 44100);
    CHECK(decodeIrWav(w24.data(), w24.size(), ir, error));
    CHECK_EQ(ir.sampleRate, 44100u);
    CHECK_NEAR(ir.right[0], -1.0, 1e-6);
    CHECK_NEAR(ir.right[1], 0.75, 1e-6);
    const std::vector<uint8_t> wf = wav(32, 2, {a, b});
    CHECK(decodeIrWav(wf.data(), wf.size(), ir, error));
    CHECK_EQ(ir.left[2], 0.125f);
    // Refused: not RIFF, a chunk past the end, a wrong alignment, a truncated file, no data, an odd format.
    std::vector<uint8_t> bad = wf;
    bad[0] = 'X';
    CHECK(!decodeIrWav(bad.data(), bad.size(), ir, error));
    bad = wf;
    bad[40] = 0xFF, bad[41] = 0xFF, bad[42] = 0xFF, bad[43] = 0x7F;  // the data chunk claims 2 GB
    CHECK(!decodeIrWav(bad.data(), bad.size(), ir, error));
    CHECK(error != nullptr);
    bad = wf;
    bad[32] = 3;  // block align
    CHECK(!decodeIrWav(bad.data(), bad.size(), ir, error));
    CHECK(!decodeIrWav(wf.data(), 30, ir, error));
    bad = wf;
    bad[20] = 2;  // ADPCM
    CHECK(!decodeIrWav(bad.data(), bad.size(), ir, error));
    CHECK(!decodeIrWav(nullptr, 0, ir, error));
    // Random bytes behind a RIFF header never crash or read out of bounds.
    uint32_t seed = 5;
    for (int round = 0; round < 300; ++round) {
        std::vector<uint8_t> junk = wf;
        for (int k = 0; k < 6; ++k) {
            seed = seed * 1664525u + 1013904223u;
            junk[12 + (seed >> 8) % (junk.size() - 12)] = static_cast<uint8_t>(seed >> 24);
        }
        decodeIrWav(junk.data(), junk.size() - (seed % 7), ir, error);
    }
}

TEST(fx_space_the_convolver_plays_a_loaded_file_exactly_after_its_latency_and_saves_it) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.convolver");
    if (!p) return;
    // A response of four taps (left) and two (right) in 6000 frames, all before the fade over its last tenth: some
    // in the head (the first 3,584 frames, 512-frame partitions), some in the tail (4,096-frame partitions).
    std::vector<float> l(6000, 0.0f), r(6000, 0.0f);
    l[0] = 0.5f, l[100] = -0.25f, l[700] = 0.125f, l[5000] = 0.2f, r[300] = 0.5f, r[3584] = -0.3f;
    const std::vector<uint8_t> file = wav(32, 2, {l, r});
    CHECK(p->loadState(file.data(), static_cast<uint32_t>(file.size()), 1));
    const Values v = {{"source", 9}, {"predelay", 0}, {"low_cut", 20}, {"high_cut", 20000}, {"width", 1}, {"mix", 1},
                      {"damping", 0}, {"size", 0.5}};
    Stereo in = silence(48000);
    in.l[0] = in.r[0] = 1e-6f;  // wakes it to build the response
    in.l[20000] = in.r[20000] = 1.0f;
    const Stereo out = run(*p, in, v, 128);
    const double energy = 0.5 * 0.5 + 0.25 * 0.25 + 0.125 * 0.125 + 0.2 * 0.2 + 0.5 * 0.5 + 0.3 * 0.3, norm = std::sqrt(0.5 / energy);
    CHECK_NEAR(out.l[20000 + 512], 0.5 * norm, 1e-4);
    CHECK_NEAR(out.l[20000 + 512 + 100], -0.25 * norm, 1e-4);
    CHECK_NEAR(out.l[20000 + 512 + 700], 0.125 * norm, 1e-4);
    CHECK_NEAR(out.r[20000 + 512 + 300], 0.5 * norm, 1e-4);
    CHECK_NEAR(out.l[20000 + 512 + 5000], 0.2 * norm, 1e-4);
    CHECK_NEAR(out.r[20000 + 512 + 3584], -0.3 * norm, 1e-4);
    CHECK(std::fabs(out.l[20000 + 512 + 4999]) < 1e-4 && std::fabs(out.r[20000 + 512 + 3583]) < 1e-4);
    CHECK(std::fabs(out.l[20000 + 511]) < 1e-5);  // nothing before the declared latency
    CHECK(std::fabs(out.r[20000 + 512]) < 1e-5);
    // The saved state is the decoded file, and loads back into another instance.
    std::vector<uint8_t> saved(p->descriptor().maxStateBytes);
    uint32_t written = 0;
    CHECK(p->saveState(saved.data(), static_cast<uint32_t>(saved.size()), written));
    CHECK_EQ(written, 16u + 6000u * 2u * 4u);
    std::unique_ptr<ModuleProcessor> q = make(e, "org.caw.convolver");
    CHECK(q->loadState(saved.data(), written, 1));
    const Stereo again = run(*q, in, v, 64);
    CHECK_NEAR(again.l[20000 + 612], -0.25 * norm, 1e-4);
    // A truncated saved state or a bad WAV is refused; an empty state clears the file.
    CHECK(!q->loadState(saved.data(), written - 4, 1));
    CHECK(!q->loadState(file.data(), 30, 1));
    CHECK(q->loadState(nullptr, 0, 1));
    CHECK(q->saveState(saved.data(), static_cast<uint32_t>(saved.size()), written));
    CHECK_EQ(written, 0u);
}

// The app loads a WAV impulse into a playing convolver through caw_engine_set_component_state (API 14): the chain is
// rebuilt off the audio thread with the file as the convolver's state, the other effects keep their values, and a bad
// file, a wrong index or a missing layer change nothing.
TEST(fx_space_a_playing_convolver_takes_a_wav_through_the_c_api) {
    CawEngine* engine = caw_engine_create(48000);
    CHECK(engine != nullptr);
    if (!engine) return;
    char* result = caw_engine_set_project(engine,
        R"({"caw_project":1,"bpm":120,"modules":[{"id":"p","source":"---\nkind: pattern\nname: P\nlength: 16\n---\n0 C4 4 1\n"}],
            "layers":[{"id":"t","pattern":"p","instrument":"org.caw.synth.flagship",
              "components":[{"id":"org.caw.utility","params":{"gain":-6}},
                            {"id":"org.caw.convolver","params":{"source":9,"mix":1,"predelay":0}}]}]})");
    CHECK(result && std::string(result).find("\"ok\":true") != std::string::npos);
    caw_free(result);
    std::vector<float> l(4800, 0.0f);
    l[0] = 0.5f, l[2400] = 0.25f;
    const std::vector<uint8_t> file = wav(16, 1, {l});
    const int32_t size = static_cast<int32_t>(file.size());
    CHECK_EQ(caw_engine_set_component_state(engine, "t", 1, file.data(), size, 1), 1);
    char* states = caw_engine_component_states(engine, "t");
    const std::string j = states ? states : "";
    caw_free(states);
    // The convolver saves the decoded file (16-byte header + 4800 float frames); the utility saves nothing.
    CHECK(j.find("\"index\":1,\"ok\":true,\"version\":1,\"state\":\"") != std::string::npos);
    CHECK(j.find("\"index\":1,\"ok\":true,\"version\":1,\"state\":\"\"") == std::string::npos);
    std::vector<float> outL(512), outR(512);
    caw_engine_play(engine);
    for (int k = 0; k < 40; ++k) caw_engine_process(engine, outL.data(), outR.data(), 512);
    for (size_t i = 0; i < outL.size(); ++i) CHECK(std::isfinite(outL[i]) && std::isfinite(outR[i]));
    // Refused: a truncated WAV, a component past the end, a layer that isn't there, a null pointer with a size.
    CHECK_EQ(caw_engine_set_component_state(engine, "t", 1, file.data(), 40, 1), 0);
    CHECK_EQ(caw_engine_set_component_state(engine, "t", 2, file.data(), size, 1), 0);
    CHECK_EQ(caw_engine_set_component_state(engine, "nope", 1, file.data(), size, 1), 0);
    CHECK_EQ(caw_engine_set_component_state(engine, "t", 1, nullptr, size, 1), 0);
    // An empty state clears the file.
    CHECK_EQ(caw_engine_set_component_state(engine, "t", 1, nullptr, 0, 1), 1);
    states = caw_engine_component_states(engine, "t");
    CHECK(states && std::string(states).find("\"index\":1,\"ok\":true,\"version\":1,\"state\":\"\"") != std::string::npos);
    caw_free(states);
    caw_engine_destroy(engine);
}

TEST(fx_space_every_generated_impulse_response_sounds_and_decays) {
    Engine e(48000);
    for (int source = 0; source < 9; ++source)
        for (int reverse : {0, 1}) {
            std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.convolver");
            if (!p) return;
            Stereo in = silence(48000 * 3);
            in.l[0] = in.r[0] = 1e-6f;
            in.l[24000] = in.r[24000] = 1.0f;
            const Stereo out = run(*p, in, {{"source", source}, {"decay", 1.0}, {"mix", 1}, {"reverse", reverse}, {"predelay", 0}});
            const size_t at = 24000 + 512;
            const double early = rms(out.l, at, at + 12000) + rms(out.r, at, at + 12000);
            const size_t later = reverse ? at + 43200 : at + 24000;  // a reversed 1.2 s response swells toward its end
            const double late = rms(out.l, later, later + 9600) + rms(out.r, later, later + 9600);
            if (!(std::max(early, late) > 1e-3)) cawtest::fail(__FILE__, __LINE__, "source " + std::to_string(source) + " is silent");
            // It decays (reversed, it swells), except Gated: a flat burst either way.
            if (source != 6 && !(reverse ? early < late * 0.5 : late < early * 0.5))
                cawtest::fail(__FILE__, __LINE__, "source " + std::to_string(source) + (reverse ? " does not swell" : " does not decay"));
            if (!(correlation(out, at, at + 24000) < 0.9))
                cawtest::fail(__FILE__, __LINE__, "source " + std::to_string(source) + " is not stereo");
            float shown[kMaxDisplayFloats];
            CHECK_EQ(p->readDisplay(shown, kMaxDisplayFloats), 73u);
            CHECK_EQ(shown[5], 1.0f);  // built
            CHECK_EQ(shown[6], static_cast<float>(source));
        }
}

TEST(fx_space_the_convolver_crossfades_to_a_new_response_without_a_click) {
    // A sine plays while the response changes from Room to Plate: the output's step from one frame to the next
    // never jumps past what the sine and the tails make anyway.
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.convolver");
    if (!p) return;
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    params[static_cast<size_t>(paramIndex(d, "mix"))].value = 1;
    params[static_cast<size_t>(paramIndex(d, "source"))].value = 0;
    const Stereo in = sine(220, 0.5, 48000 * 3);
    Stereo out = silence(in.size());
    for (size_t start = 0; start < in.size(); start += 240) {
        if (start >= 48000 && start < 48000 + 240) params[static_cast<size_t>(paramIndex(d, "source"))].value = 2;
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        AudioProcessBlock b;
        b.input = {ic, 2, 240};
        b.output = {oc, 2, 240};
        b.frames = 240;
        b.sampleRate = 48000;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        CHECK(p->process(b));
    }
    double before = 0, during = 0;
    for (size_t i = 24000; i < 48000; ++i) before = std::max(before, std::fabs(double(out.l[i]) - out.l[i - 1]));
    for (size_t i = 48000; i < 48000 * 2; ++i) during = std::max(during, std::fabs(double(out.l[i]) - out.l[i - 1]));
    CHECK(during < 2.0 * before + 1e-3);
    float shown[kMaxDisplayFloats];
    p->readDisplay(shown, kMaxDisplayFloats);
    CHECK_EQ(shown[6], 2.0f);
    CHECK_EQ(shown[5], 1.0f);
}

// ---------- Shimmer ----------

TEST(fx_space_the_shimmer_climbs_an_octave_in_its_tail) {
    Engine e(48000);
    double octave[2] = {0, 0};
    for (int k = 0; k < 2; ++k) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.shimmer");
        if (!p) return;
        Stereo in = sine(440, 0.3, 48000 * 4);
        for (size_t i = 24000; i < in.size(); ++i) in.l[i] = in.r[i] = 0.0f;
        const Stereo out = run(*p, in, {{"amount", k ? 1.0 : 0.0}, {"mix", 1}, {"tone", 12000}, {"decay", 6}});
        octave[k] = toneLevel(out.l, 72000, 120000, 880) / std::max(1e-9, toneLevel(out.l, 72000, 120000, 440));
    }
    CHECK(octave[1] > 3.0 * octave[0]);
    CHECK(octave[1] > 0.15);
}

// ---------- Modulation ----------

TEST(fx_space_ensemble_and_doubler_widen_a_mono_source) {
    Engine e(48000);
    for (const char* id : {"org.caw.ensemble", "org.caw.doubler"}) {
        std::unique_ptr<ModuleProcessor> p = make(e, id);
        const Stereo in = music(48000);
        Stereo mono = in;
        mono.r = mono.l;
        const Stereo out = run(*p, mono, {{"mix", 1}});
        const double c = correlation(out, 4800, 48000);
        if (!(c < 0.8)) cawtest::fail(__FILE__, __LINE__, std::string(id) + " correlation " + std::to_string(c));
        CHECK(rms(out.l, 4800, 48000) > 0.3 * rms(in.l, 4800, 48000));
    }
}

TEST(fx_space_vibrato_bends_the_pitch_by_its_depth) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.vibrato");
    const Stereo out = run(*p, sine(1000, 0.5, 48000), {{"rate", 4}, {"depth", 50}});
    // Instantaneous frequency from the zero crossings: within 50 cents of 1 kHz, and reaching most of it.
    double lo = 1e9, hi = 0, last = -1;
    for (size_t i = 4800; i < 48000; ++i)
        if (out.l[i - 1] < 0 && out.l[i] >= 0) {
            const double t = (i - 1) + out.l[i - 1] / (out.l[i - 1] - out.l[i]);
            if (last > 0) {
                const double f = 48000.0 / (t - last);
                lo = std::min(lo, f), hi = std::max(hi, f);
            }
            last = t;
        }
    const double up = 1200 * std::log2(hi / 1000), down = 1200 * std::log2(1000 / lo);
    CHECK(up > 35 && up < 56);
    CHECK(down > 35 && down < 56);
}

TEST(fx_space_tremolo_and_autopan_move_level_and_place_in_time) {
    Engine e(48000);
    {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.tremolo");
        const Stereo out = run(*p, sine(1000, 0.5, 48000), {{"rate", 5}, {"depth", 1}, {"smooth", 0}});
        double lo = 1, hi = 0;
        for (size_t w = 4800; w + 480 < 48000; w += 240) {
            const double r = rms(out.l, w, w + 240);
            lo = std::min(lo, r), hi = std::max(hi, r);
        }
        CHECK(hi > 0.3);
        CHECK(lo < 0.05);
        // Harmonic: lows and highs move against each other, so the full band barely changes level.
        std::unique_ptr<ModuleProcessor> h = make(e, "org.caw.tremolo");
        const Stereo low = run(*h, sine(100, 0.5, 48000), {{"rate", 5}, {"depth", 1}, {"mode", 1}, {"smooth", 0}});
        double hlo = 1, hhi = 0;
        for (size_t w = 4800; w + 960 < 48000; w += 480) {
            const double r = rms(low.l, w, w + 480);
            hlo = std::min(hlo, r), hhi = std::max(hhi, r);
        }
        CHECK(hhi > 2.0 * hlo);
    }
    {
        // Auto-pan, synced to quarter notes at 120 BPM (a cycle every 0.5 s): the level moves from side to side.
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.autopan");
        const Stereo out = run(*p, sine(1000, 0.5, 48000), {{"sync", 9}, {"depth", 1}, {"smooth", 0}}, 64, 120, true);
        const double l1 = rms(out.l, 5400 - 600, 5400 + 600), r1 = rms(out.r, 5400 - 600, 5400 + 600);   // a quarter cycle in: right
        const double l2 = rms(out.l, 17400 - 600, 17400 + 600), r2 = rms(out.r, 17400 - 600, 17400 + 600);  // three quarters: left
        CHECK(r1 > 3 * l1);
        CHECK(l2 > 3 * r2);
    }
}

TEST(fx_space_the_rotary_spins_up_to_tremolo_speed_and_brakes) {
    Engine e(48000);
    float shown[kMaxDisplayFloats];
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.rotary");
    run(*p, sine(2000, 0.3, 48000), {{"speed", 0}});
    run(*p, sine(2000, 0.3, 48000 * 4), {{"speed", 1}});
    p->readDisplay(shown, kMaxDisplayFloats);
    CHECK(shown[4] > 6.5);  // the horn near its 6.75 Hz after 4 s
    CHECK(shown[5] > 3.0 && shown[5] < 5.8);  // the drum still spinning up
    const Stereo out = run(*p, sine(2000, 0.3, 48000 * 6), {{"speed", 2}});
    p->readDisplay(shown, kMaxDisplayFloats);
    CHECK(shown[4] < 0.05);
    CHECK(rms(out.l, 48000 * 5, 48000 * 6) > 0.05);  // stopped, but still sounding
}

// ---------- Stereo ----------

TEST(fx_space_haas_delays_one_side_keeps_the_bass_and_checks_mono) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.haas");
    Stereo in = silence(4800);
    in.l[100] = in.r[100] = 1.0f;
    const Stereo out = run(*p, in, {{"side", 1}, {"delay", 10}, {"guard", 20}});
    CHECK_NEAR(out.l[100], 1.0, 1e-6);
    CHECK_NEAR(out.r[100 + 480], 1.0, 1e-4);
    CHECK(std::fabs(out.r[100]) < 1e-6);
    // With a guard, a low sine stays in phase on both sides; a high one is delayed.
    std::unique_ptr<ModuleProcessor> g = make(e, "org.caw.haas");
    const Stereo lows = run(*g, sine(40, 0.5, 48000), {{"delay", 10}, {"guard", 400}});
    CHECK(correlation(lows, 24000, 48000) > 0.9);
    // Mono check: both outputs the same.
    std::unique_ptr<ModuleProcessor> m = make(e, "org.caw.haas");
    const Stereo mono = run(*m, music(24000), {{"mono_check", 1}});
    for (size_t i = 0; i < mono.size(); ++i) CHECK_EQ(mono.l[i], mono.r[i]);
    float shown[kMaxDisplayFloats];
    CHECK_EQ(m->readDisplay(shown, kMaxDisplayFloats), 7u);
    CHECK(shown[3] <= 0.0f && shown[3] > -10.0f);
    CHECK_NEAR(shown[5], 500.0 / 12.0, 1e-3);
}

TEST(fx_space_the_imager_is_flat_at_unity_and_narrows_each_band) {
    Engine e(48000);
    for (double hz : {60.0, 1000.0, 9000.0}) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.imager");
        const Stereo in = sine(hz, 0.5, 48000, 1.0);
        const Stereo out = run(*p, in);
        CHECK_NEAR(db(rms(out.l, 24000, 48000) / rms(in.l, 24000, 48000)), 0.0, 0.05);
        CHECK_NEAR(db(rms(out.r, 24000, 48000) / rms(in.r, 24000, 48000)), 0.0, 0.05);
    }
    // Low width 0: a wide 60 Hz comes out mono, a wide 9 kHz stays wide.
    for (auto [hz, mono] : {std::pair{60.0, true}, std::pair{9000.0, false}}) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.imager");
        const Stereo out = run(*p, sine(hz, 0.5, 48000, 2.0), {{"low_width", 0}});
        const double c = correlation(out, 24000, 48000);
        CHECK(mono ? c > 0.99 : c < 0.0);
    }
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.imager");
    float shown[kMaxDisplayFloats];
    run(*p, sine(1000, 0.5, 4800, 2.0));
    p->readDisplay(shown, kMaxDisplayFloats);  // a UI reading: the scope fills from the next publish
    run(*p, sine(1000, 0.5, 4800, 2.0));
    CHECK_EQ(p->readDisplay(shown, kMaxDisplayFloats), 265u);
    CHECK_EQ(shown[8], 128.0f);
    CHECK(shown[2] < 0.0f);  // a 2-radian offset correlates negatively
    double reach = 0;
    for (int k = 0; k < 256; ++k) reach = std::max(reach, std::fabs(double(shown[9 + k])));
    CHECK(reach > 0.1);
}

TEST(fx_space_the_channel_mixer_swaps_and_inverts) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.channelmixer");
    const Stereo in = music(9600);
    const Stereo same = run(*p, in);
    for (size_t i = 0; i < in.size(); ++i) CHECK(same.l[i] == in.l[i] && same.r[i] == in.r[i]);
    std::unique_ptr<ModuleProcessor> q = make(e, "org.caw.channelmixer");
    const Stereo swapped = run(*q, in, {{"left_to_left", 0}, {"right_to_left", -1}, {"left_to_right", 1}, {"right_to_right", 0}});
    for (size_t i = 16; i < in.size(); ++i) CHECK(swapped.l[i] == -in.r[i] && swapped.r[i] == in.l[i]);
}
