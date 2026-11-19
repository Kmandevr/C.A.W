// Ducker's Duck variant (org.caw.duck variant 0; 1.0.8-1.0.9 the Compressor's variant 4): its static curve, hold, detection modes, key against no key, block sizes, presets, display and reference renders.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "component_chain.h"
#include "fx_merged.h"
#include "presets.h"
#include "test.h"
#include "tolerance.h"

using namespace caw;

namespace {

using Values = std::vector<std::pair<std::string, double>>;
constexpr const char* kDuck = "org.caw.duck";  // 1.1.0 (1.0.8-1.0.9: org.caw.compressor variant 4)
constexpr double kPi = 3.14159265358979323846;

const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        return x;
    }();
    return r;
}

struct Stereo {
    std::vector<float> l, r;
};

Stereo constant(double level, size_t frames) {
    return {std::vector<float>(frames, static_cast<float>(level)), std::vector<float>(frames, static_cast<float>(level))};
}
Stereo sine(double hz, double amp, size_t frames, double phase = 0.0) {
    Stereo s{std::vector<float>(frames), std::vector<float>(frames)};
    for (size_t i = 0; i < frames; ++i)
        s.l[i] = s.r[i] = static_cast<float>(amp * std::sin(2 * kPi * hz * i / 48000.0 + phase));
    return s;
}
// A bass-like tone and a kick-like key (a 60 Hz burst every 500 ms, 80 ms long), for the presets and references.
Stereo bass(size_t frames) {
    Stereo s{std::vector<float>(frames), std::vector<float>(frames)};
    uint32_t seed = 5;
    for (size_t i = 0; i < frames; ++i) {
        seed = seed * 1664525u + 1013904223u;
        const double nz = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * 0.02;
        s.l[i] = static_cast<float>(0.35 * std::sin(2 * kPi * 55.0 * i / 48000.0) + nz);
        s.r[i] = static_cast<float>(0.3 * std::sin(2 * kPi * 82.5 * i / 48000.0) - nz);
    }
    return s;
}
Stereo kicks(size_t frames) {
    Stereo s{std::vector<float>(frames), std::vector<float>(frames)};
    for (size_t i = 0; i < frames; ++i) {
        const size_t t = i % 24000;
        if (t < 3840) {
            const double env = std::exp(-static_cast<double>(t) / 1200.0);
            s.l[i] = s.r[i] = static_cast<float>(0.9 * env * std::sin(2 * kPi * 60.0 * t / 48000.0));
        }
    }
    return s;
}

std::unique_ptr<ModuleProcessor> duck() {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), kDuck, {{"variant", 0.0}});
    CHECK(p != nullptr);
    if (p) CHECK(p->activate(48000, 512));
    return p;
}

// Runs `p` over `in` (and `key`, its sidechain, when given; null: process() with no key port at all).
Stereo run(ModuleProcessor& p, const Stereo& in, const Stereo* key, const Values& values, uint32_t block = 64) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    Stereo out{std::vector<float>(in.l.size()), std::vector<float>(in.l.size())};
    for (size_t start = 0; start < in.l.size(); start += block) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(block, in.l.size() - start));
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        if (key) {
            const float* kc[2] = {key->l.data() + start, key->r.data() + start};
            const ConstChannelBufferView ins[2] = {{ic, 2, n}, {kc, 2, n}};
            const ChannelBufferView outs{oc, 2, n};
            ProcessBlock b;
            b.frames = n;
            b.sampleRate = 48000;
            b.audioIn = ins;
            b.audioInCount = 2;
            b.audioOut = &outs;
            b.audioOutCount = 1;
            b.parameters = params.data();
            b.parameterCount = d.parameterCount;
            CHECK(p.processPorts(b));
        } else {
            AudioProcessBlock b;
            b.input = {ic, 2, n};
            b.output = {oc, 2, n};
            b.frames = n;
            b.sampleRate = 48000;
            b.parameters = params.data();
            b.parameterCount = d.parameterCount;
            CHECK(p.process(b));
        }
    }
    return out;
}

double peak(const std::vector<float>& v, size_t from = 0, size_t to = ~size_t{0}) {
    double p = 0;
    for (size_t i = from; i < std::min(to, v.size()); ++i) p = std::max(p, std::fabs(static_cast<double>(v[i])));
    return p;
}
double db(double x) { return 20.0 * std::log10(std::max(x, 1e-12)); }

// The steady gain (dB) Duck gives a constant 0.5 (-6.02 dBFS) with these values (own input).
double steadyGain(const Values& v) {
    auto p = duck();
    if (!p) return 0;
    const Stereo out = run(*p, constant(0.5, 24000), nullptr, v);
    return db(out.l.back() / 0.5);
}

}  // namespace

TEST(duck_is_the_duckers_first_variant_keyed_without_latency) {
    const fx::MergedDevice* m = fx::findMergedDevice(kDuck);
    CHECK(m && m->variants.size() == 3u && m->variants[0].name == "Duck");
    if (!m || m->variants.size() < 3) return;
    const ModuleDescriptor& d = m->variants[0].descriptor();
    CHECK(d.id == std::string(kDuck));
    CHECK(ComponentChain::isKeyedEffect(d));
    CHECK_EQ(d.latencyFrames, 0u);
    const char* ids[] = {"threshold", "amount", "attack", "hold", "release", "detection", "output", "mix", "sidechain", "variant"};
    // 1.1.0 appends the sidechain filter after `variant` (sc_hpf, sc_lpf, sc_listen), so `variant` keeps its place.
    CHECK_EQ(d.parameterCount, 13u);
    for (uint32_t k = 0; k < d.parameterCount && k < 10; ++k) CHECK(d.parameters[k].id == std::string(ids[k]));
    CHECK(d.parameters[10].id == std::string("sc_hpf") && d.parameters[11].id == std::string("sc_lpf") &&
          d.parameters[12].id == std::string("sc_listen"));
    const ParameterDescriptor& variant = d.parameters[9];
    CHECK_EQ(variant.defaultValue, 0.0);
    CHECK(!variant.automatable && !variant.modulatable);
    CHECK_EQ(d.parameters[5].choiceCount, 3u);  // RMS, Peak, ISP
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), kDuck, {{"variant", 0.0}});
    CHECK(p && &p->descriptor() == &d);
    // Its `variant` lists the Ducker's three (Duck, Level, Carve).
    CHECK_EQ(variant.choiceCount, 3u);
}

TEST(duck_pulls_the_level_above_the_threshold_by_its_amount_in_every_detection_mode) {
    for (double mode : {0.0, 1.0, 2.0}) {
        for (double amount : {0.0, 0.25, 0.5, 1.0}) {
            for (double thr : {-24.0, -12.0}) {
                const double want = -amount * (db(0.5) - thr);
                const double got = steadyGain({{"threshold", thr}, {"amount", amount}, {"detection", mode}, {"attack", 1}});
                // ISP's interpolator gains a hair on DC (its phases' taps sum to 1 within 0.02 dB).
                if (std::fabs(got - want) > 0.05)
                    cawtest::fail(__FILE__, __LINE__, "mode " + std::to_string(mode) + " amount " + std::to_string(amount) +
                                                          ": " + std::to_string(got) + " dB, want " + std::to_string(want));
            }
        }
    }
    // Below the threshold nothing happens; the output knob and the mix apply as stated.
    CHECK_NEAR(steadyGain({{"threshold", -3}, {"amount", 1}}), 0.0, 1e-6);
    CHECK_NEAR(steadyGain({{"threshold", -3}, {"amount", 1}, {"output", 6}}), 6.0, 0.01);
    const double halfMix = steadyGain({{"threshold", -18}, {"amount", 1}, {"mix", 0.5}});
    CHECK_NEAR(halfMix, db(0.5 + 0.5 * std::pow(10.0, -(db(0.5) + 18) / 20)), 0.05);
}

TEST(duck_holds_its_reduction_after_the_key_stops_then_releases) {
    // A constant input, a key burst of 20 ms; the reduction is held for `hold`, then released.
    const size_t frames = 48000;
    const Stereo in = constant(0.25, frames);
    Stereo key = constant(0.0, frames);
    for (size_t i = 4800; i < 4800 + 960; ++i) key.l[i] = key.r[i] = 0.9f;
    const size_t end = 4800 + 960;
    auto gainAt = [&](const Stereo& out, size_t i) { return db(out.l[i] / 0.25); };
    const Values base = {{"threshold", -30}, {"amount", 1}, {"attack", 0.05}, {"release", 20}, {"detection", 1}, {"sidechain", 1}};
    auto p = duck();
    if (!p) return;
    Values held = base;
    held.emplace_back("hold", 100.0);
    const Stereo a = run(*p, in, &key, held);
    const double full = gainAt(a, end - 1);
    CHECK_NEAR(full, db(std::pow(10.0, -30.0 / 20) / 0.9), 0.1);  // the key's 0.9 pulled to -30 dB
    CHECK_NEAR(gainAt(a, end + 4320), full, 0.01);  // 90 ms later: still held
    CHECK(gainAt(a, end + 4800 + 9600) > -0.1);     // hold and 200 ms of release later: back
    p->reset();
    Values none = base;
    none.emplace_back("hold", 0.0);
    const Stereo b = run(*p, in, &key, none);
    CHECK(gainAt(b, end + 4320) > full / 4);  // no hold: well on its way back after 90 ms
}

TEST(duck_isp_detection_sees_the_peaks_between_samples) {
    // A sine at a quarter of the rate, sampled 45 degrees off its peaks: every sample is 3 dB under the true peak.
    const Stereo in = sine(12000, 0.5, 24000, kPi / 4);
    auto gain = [&](double mode) {
        auto p = duck();
        if (!p) return 0.0;
        const Stereo out = run(*p, in, nullptr, {{"threshold", -9}, {"amount", 1}, {"detection", mode}, {"attack", 1}});
        return db(peak(out.l, 12000) / peak(in.l, 12000));
    };
    CHECK_NEAR(gain(1), 0.0, 0.01);       // Peak: the samples are at -9.03 dB, under the threshold
    CHECK_NEAR(gain(2), -2.98, 0.15);     // ISP: the true peak -6.02 dB, pulled to -9
    CHECK_NEAR(gain(0), 0.0, 0.01);       // RMS: 0.354 rms, under the threshold too
    // RMS against Peak on a square, where they agree, and on a sine, where RMS reads 3 dB lower.
    const Stereo s = sine(100, 0.5, 48000);
    auto sineGain = [&](double mode) {
        auto p = duck();
        if (!p) return 0.0;
        const Stereo out = run(*p, s, nullptr, {{"threshold", -24}, {"amount", 1}, {"detection", mode}, {"attack", 1}, {"hold", 20}, {"release", 500}});
        return db(peak(out.l, 36000) / 0.5);
    };
    CHECK(sineGain(0) > sineGain(1) + 2.0);  // RMS ducks less than Peak on a sine
}

TEST(duck_follows_the_key_when_external_and_its_own_input_otherwise) {
    const Stereo in = constant(0.05, 24000);   // -26 dB: under the threshold
    const Stereo key = constant(0.8, 24000);   // -1.9 dB: well over
    const Values ext = {{"threshold", -20}, {"amount", 1}, {"sidechain", 1}};
    const Values internal = {{"threshold", -20}, {"amount", 1}, {"sidechain", 0}};
    auto p = duck();
    if (!p) return;
    CHECK_NEAR(db(run(*p, in, &key, ext).l.back() / 0.05), -20.0 - db(0.8), 0.05);  // keyed: ducked by the key
    p->reset();
    CHECK_NEAR(run(*p, in, &key, internal).l.back(), 0.05f, 1e-6);  // Internal: the key is not heard
    p->reset();
    CHECK_NEAR(run(*p, in, nullptr, ext).l.back(), 0.05f, 1e-6);  // no key at all: its own input (a leveller)
    p->reset();
    const Stereo loud = constant(0.8, 24000);
    CHECK_NEAR(db(run(*p, loud, nullptr, ext).l.back() / 0.8), -20.0 - db(0.8), 0.05);  // ... levelling itself
    // In a chain with no track keying it, External hears silence: nothing ducks (as the Compressor variant).
    std::string error;
    ComponentSpec spec;
    spec.id = kDuck;
    spec.params = {{"variant", 0}, {"threshold", -20}, {"amount", 1}, {"sidechain", 1}};
    auto chain = ComponentChain::build(registry(), {spec}, 48000.0, error);
    CHECK(chain != nullptr);
    if (!chain) return;
    std::vector<float> l(64, 0.8f), r(64, 0.8f);
    for (int b = 0; b < 100; ++b) {
        std::fill(l.begin(), l.end(), 0.8f);
        std::fill(r.begin(), r.end(), 0.8f);
        chain->process(l.data(), r.data(), 64, 48000.0, nullptr);
    }
    CHECK_NEAR(l.back(), 0.8f, 1e-6);
}

TEST(duck_keeps_ducking_through_a_gap_in_its_input_while_the_key_pumps) {
    // External key, a gappy input: through 500 ms of silent input (ten times its 50 ms sleep) the key goes on, so
    // the duck must not fall asleep (which clears it to 0 dB): the input coming back mid-duck is ducked at once.
    const size_t frames = 48000;
    Stereo in = constant(0.25, frames);
    for (size_t i = 9600; i < 33600; ++i) in.l[i] = in.r[i] = 0.0f;
    const Stereo key = constant(0.9, frames);
    const Values v = {{"threshold", -30}, {"amount", 1}, {"attack", 5}, {"release", 150}, {"detection", 1}, {"sidechain", 1}};
    const double ducked = -30.0 - db(0.9);
    auto p = duck();
    if (!p) return;
    const Stereo out = run(*p, in, &key, v);
    CHECK_NEAR(db(out.l[9599] / 0.25), ducked, 0.1);
    CHECK_NEAR(db(out.l[33600] / 0.25), ducked, 0.1);  // back: still ducked, no pop at full level
    // Asleep before the key began (silent input and key), it wakes on the key, not only on its input.
    Stereo late = constant(0.0, frames);
    for (size_t i = 24000; i < frames; ++i) late.l[i] = late.r[i] = 0.25f;
    Stereo lateKey = constant(0.0, frames);
    for (size_t i = 9600; i < frames; ++i) lateKey.l[i] = lateKey.r[i] = 0.9f;
    p->reset();
    const Stereo woke = run(*p, late, &lateKey, v);
    CHECK_NEAR(db(woke.l[24000] / 0.25), ducked, 0.1);
    // The same in a track's chain, which skips a sleeping effect: its key is heard there too.
    std::string error;
    ComponentSpec spec;
    spec.id = kDuck;
    spec.params = {{"variant", 0}};
    for (const auto& [id, x] : v) spec.params.emplace_back(id, x);
    auto chain = ComponentChain::build(registry(), {spec}, 48000.0, error);
    CHECK(chain != nullptr);
    if (!chain) return;
    Stereo got = late;
    ChainTime t;
    for (size_t at = 0; at < frames; at += 64) {
        t.chunk = static_cast<int64_t>(at / 64);
        ComponentChain::KeyInput* k = chain->keyInput(0);
        CHECK(k != nullptr);
        if (!k) return;
        k->begin(t.chunk);
        for (uint32_t i = 0; i < 64; ++i) k->l[i] = k->r[i] = lateKey.l[at + i];
        chain->process(got.l.data() + at, got.r.data() + at, 64, 48000.0, &t);
    }
    CHECK_NEAR(db(got.l[24000] / 0.25), ducked, 0.1);
}

TEST(duck_ramps_its_output_and_mix_within_each_control_step) {
    // Output and Mix moving (a knob's 10 ms ramp, automation) change the gain a little every frame, never in
    // 16-frame steps: no zipper noise.
    for (const char* knob : {"output", "mix"}) {
        auto p = duck();
        if (!p) return;
        const ModuleDescriptor& d = p->descriptor();
        std::vector<ParameterValue> params(d.parameterCount);
        uint32_t moving = d.parameterCount;
        for (uint32_t k = 0; k < d.parameterCount; ++k) {
            params[k].value = d.parameters[k].defaultValue;
            if (d.parameters[k].id == std::string("threshold")) params[k].value = -40;
            if (d.parameters[k].id == std::string("amount")) params[k].value = 1;
            if (d.parameters[k].id == std::string(knob)) moving = k;
        }
        CHECK(moving < d.parameterCount);
        if (moving >= d.parameterCount) return;
        const bool mix = std::string(knob) == "mix";
        std::vector<double> samples(64);
        const size_t frames = 4800;
        const Stereo in = constant(0.25, frames);  // ducked by 28 dB: Mix moves the gain a lot
        Stereo out = constant(0.0, frames);
        for (size_t start = 0; start < frames; start += 64) {
            for (uint32_t i = 0; i < 64; ++i) {
                const double x = static_cast<double>(start + i) / static_cast<double>(frames);  // 0..1 over 100 ms
                samples[i] = mix ? 1.0 - x : -12.0 * x;
            }
            params[moving].samples = samples.data();
            const float* ic[2] = {in.l.data() + start, in.r.data() + start};
            float* oc[2] = {out.l.data() + start, out.r.data() + start};
            AudioProcessBlock b;
            b.input = {ic, 2, 64};
            b.output = {oc, 2, 64};
            b.frames = 64;
            b.sampleRate = 48000;
            b.parameters = params.data();
            b.parameterCount = d.parameterCount;
            CHECK(p->process(b));
        }
        // Past the attack: the gain moves about as much every frame (a step would hold 15 frames, then jump 16 times
        // as far).
        double most = 0, sum = 0;
        for (size_t i = 2400; i < frames; ++i) {
            const double step = std::fabs(static_cast<double>(out.l[i]) - out.l[i - 1]);
            most = std::max(most, step);
            sum += step;
        }
        const double mean = sum / static_cast<double>(frames - 2400);
        if (!(most < 2.0 * mean))
            cawtest::fail(__FILE__, __LINE__, std::string(knob) + ": the largest step is " + std::to_string(most / mean) + " times the mean");
    }
}

TEST(duck_gives_the_same_bits_at_any_block_size) {
    const Stereo in = bass(30000), key = kicks(30000);
    const Values v = {{"threshold", -30}, {"amount", 0.8}, {"attack", 0.5}, {"hold", 20}, {"release", 110}, {"detection", 2}, {"sidechain", 1}};
    auto p = duck();
    if (!p) return;
    const Stereo want = run(*p, in, &key, v, 64);
    for (uint32_t block : {1u, 37u, 500u}) {
        p->reset();
        const Stereo got = run(*p, in, &key, v, block);
        CHECK(std::memcmp(want.l.data(), got.l.data(), want.l.size() * 4) == 0);
        CHECK(std::memcmp(want.r.data(), got.r.data(), want.r.size() * 4) == 0);
    }
}

TEST(duck_presets_are_job_named_and_duck_a_bass_under_kicks) {
    size_t count = 0;
    const Stereo in = bass(48000), key = kicks(48000);
    for (const BuiltinPreset& preset : builtinPresets(kDuck)) {
        bool isDuck = false, keyed = false;
        for (const auto& [k, x] : preset.values) {
            isDuck = isDuck || (k == "variant" && x == 0.0);
            keyed = keyed || (k == "sidechain" && x == 1.0);
        }
        if (!isDuck) continue;
        ++count;
        Values values;
        CHECK(applyBuiltinPreset(kDuck, preset.name, values));
        auto p = std::unique_ptr<ModuleProcessor>(createComponent(registry(), kDuck, values).release());
        CHECK(p && p->activate(48000, 512));
        if (!p) continue;
        // A leveller hears its own input: louder (peaks near -3 dBFS), so the peak catcher's -6 dB is crossed too.
        Stereo loud = in;
        for (float& x : loud.l) x *= 2.0f;
        for (float& x : loud.r) x *= 2.0f;
        const Stereo& src = keyed ? in : loud;
        const Stereo out = run(*p, src, &key, values);
        for (float x : out.l) CHECK(std::isfinite(x));
        // Each reduces something: a keyed preset under the kicks, a leveller on the bass itself.
        double most = 0;
        for (size_t i = 0; i < out.l.size(); ++i)
            if (std::fabs(src.l[i]) > 0.2) most = std::min(most, db(std::fabs(out.l[i]) / std::fabs(src.l[i])));
        if (!(most < -1.0)) cawtest::fail(__FILE__, __LINE__, std::string(preset.name) + " does not reduce");
    }
    CHECK(count >= 8u);
    CHECK(findBuiltinPreset(kDuck, "Kick duck bass") && findBuiltinPreset(kDuck, "Voice over music") &&
          findBuiltinPreset(kDuck, "Gentle leveller"));
}

TEST(duck_publishes_its_levels_and_reduction) {
    auto p = duck();
    if (!p) return;
    const Stereo in = constant(0.25, 9600), key = constant(0.9, 9600);
    run(*p, in, &key, {{"threshold", -30}, {"amount", 1}, {"detection", 1}, {"sidechain", 1}});
    float shown[64];
    const uint32_t n = p->readDisplay(shown, 64);
    CHECK_EQ(n, 10u);
    if (n < 10) return;
    CHECK_NEAR(shown[0], db(0.25), 0.05);              // input peak
    CHECK_NEAR(shown[2], db(0.9), 0.05);               // detector level (the key, Peak)
    CHECK_NEAR(shown[3], db(0.9), 0.05);               // the key's own peak
    CHECK_NEAR(shown[4], db(0.9) + 30.0, 0.1);         // reduction now
    CHECK(shown[5] >= shown[4] - 1e-3f);               // most reduction
    CHECK_NEAR(shown[1], db(0.25) - shown[4], 0.1);    // output peak
    CHECK_EQ(shown[6], -30.0f);
    CHECK_EQ(shown[7], 1.0f);
    CHECK_EQ(shown[8], 1.0f);
    CHECK_EQ(shown[9], 1.0f);
}

TEST(duck_matches_its_reference_renders) {
    const Stereo in = bass(48000 * 2), key = kicks(48000 * 2);
    struct Case {
        const char* name;
        Values values;
        bool keyed;
    };
    const Case cases[] = {
        {"duck_kick_peak", {{"threshold", -30}, {"amount", 0.8}, {"attack", 0.5}, {"hold", 20}, {"release", 110}, {"detection", 1}, {"sidechain", 1}}, true},
        {"duck_kick_isp_parallel", {{"threshold", -32}, {"amount", 1}, {"attack", 0.2}, {"hold", 15}, {"release", 140}, {"detection", 2}, {"mix", 0.5}, {"sidechain", 1}}, true},
        {"duck_leveller_rms", {{"threshold", -24}, {"amount", 0.5}, {"attack", 10}, {"hold", 50}, {"release", 300}, {"detection", 0}, {"output", 3}}, false},
    };
    cawtest::References refs("fx_duck");
    for (const Case& c : cases) {
        auto p = duck();
        if (!p) return;
        const Stereo out = run(*p, in, c.keyed ? &key : nullptr, c.values);
        CHECK_REFERENCE(refs, c.name, (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
    }
}
