// 1.1.0's tools: Meters (pass-through, spectrum peak, tuner notes and cents, BS.1770 loudness), Lo-fi and Phase align (delays, polarity, learning), block sizes, NaN, presets, references.
#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "fx_merged.h"
#include "presets.h"
#include "test.h"
#include "tolerance.h"

using namespace caw;

namespace {

using Values = std::vector<std::pair<std::string, double>>;
constexpr double kPi = 3.14159265358979323846;
constexpr double kSr = 48000.0;

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
Stereo sine(double hz, double amp, size_t n) {
    Stereo s{std::vector<float>(n), std::vector<float>(n)};
    for (size_t i = 0; i < n; ++i) s.l[i] = s.r[i] = static_cast<float>(amp * std::sin(2 * kPi * hz * i / kSr));
    return s;
}
Stereo noise(size_t n, uint32_t seed, double amp = 0.3) {
    Stereo s{std::vector<float>(n), std::vector<float>(n)};
    for (size_t i = 0; i < n; ++i) {
        seed = seed * 1664525u + 1013904223u;
        s.l[i] = static_cast<float>(amp * (static_cast<double>(seed >> 8) / 8388608.0 - 1.0));
        seed = seed * 1664525u + 1013904223u;
        s.r[i] = static_cast<float>(amp * (static_cast<double>(seed >> 8) / 8388608.0 - 1.0));
    }
    return s;
}
// A busy test signal: tones and noise bursts.
Stereo music(size_t n) {
    Stereo s = noise(n, 7, 0.1);
    for (size_t i = 0; i < n; ++i) {
        const double t = static_cast<double>(i) / kSr;
        const double env = std::exp(-6.0 * std::fmod(t, 0.5));
        s.l[i] += static_cast<float>(0.4 * env * std::sin(2 * kPi * 110 * t) + 0.2 * std::sin(2 * kPi * 660 * t));
        s.r[i] += static_cast<float>(0.4 * env * std::sin(2 * kPi * 165 * t) + 0.2 * std::sin(2 * kPi * 440 * t));
    }
    return s;
}

struct Result {
    Stereo out;
    std::vector<float> display;
};
// Runs a device over `in` (with `key` when given) in blocks of `block`, reading its display every 800 frames.
Result run(const Values& id_values, const char* id, const Stereo& in, uint32_t block = 64, const Stereo* key = nullptr) {
    Result res;
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), id, {id_values.begin(), id_values.end()});
    CHECK(p != nullptr);
    if (!p) return res;
    CHECK(p->activate(kSr, 512));
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [name, v] : id_values)
            if (d.parameters[k].id == name) params[k].value = v;
    }
    const size_t n = in.l.size();
    res.out.l.assign(n, 0.0f);
    res.out.r.assign(n, 0.0f);
    std::vector<float> shown(1024);
    size_t nextRead = 0;
    Transport tr;
    for (size_t at = 0; at < n; at += block) {
        const uint32_t m = static_cast<uint32_t>(std::min<size_t>(block, n - at));
        const float* ins[2] = {in.l.data() + at, in.r.data() + at};
        float* outs[2] = {res.out.l.data() + at, res.out.r.data() + at};
        if (key) {
            const float* keys[2] = {key->l.data() + at, key->r.data() + at};
            const ConstChannelBufferView audioIn[2] = {{ins, 2, m}, {keys, 2, m}};
            const ChannelBufferView audioOut{outs, 2, m};
            ProcessBlock pb;
            pb.frames = m;
            pb.sampleRate = kSr;
            pb.audioIn = audioIn;
            pb.audioInCount = 2;
            pb.audioOut = &audioOut;
            pb.audioOutCount = 1;
            pb.parameters = params.data();
            pb.parameterCount = d.parameterCount;
            pb.transport = &tr;
            CHECK(p->processPorts(pb));
        } else {
            AudioProcessBlock b;
            b.input = {ins, 2, m};
            b.output = {outs, 2, m};
            b.frames = m;
            b.sampleRate = kSr;
            b.parameters = params.data();
            b.parameterCount = d.parameterCount;
            b.transport = &tr;
            CHECK(p->process(b));
        }
        if (at + m >= nextRead) {
            const uint32_t got = p->readDisplay(shown.data(), 1024);
            if (got) res.display.assign(shown.begin(), shown.begin() + got);
            nextRead += 800;
        }
    }
    return res;
}
bool same(const Stereo& a, const Stereo& b) { return a.l == b.l && a.r == b.r; }
bool finite(const Stereo& s) {
    for (size_t i = 0; i < s.l.size(); ++i)
        if (!std::isfinite(s.l[i]) || !std::isfinite(s.r[i])) return false;
    return true;
}

}  // namespace

TEST(tools_are_registered_with_presets_and_meters_has_three_variants) {
    for (const char* id : {"org.caw.meters", "org.caw.lofi", "org.caw.phasealign"}) {
        CHECK(registry().find(id) != nullptr);
        CHECK(builtinPresets(id).size() >= 8);
    }
    const fx::MergedDevice* m = fx::findMergedDevice("org.caw.meters");
    CHECK(m != nullptr);
    if (m) CHECK_EQ(m->variants.size(), 3u);
    // Eight or more presets for each Meters mode.
    int perVariant[3] = {};
    for (const BuiltinPreset& p : builtinPresets("org.caw.meters"))
        for (const auto& [k, v] : p.values)
            if (k == "variant") ++perVariant[static_cast<int>(v)];
    for (int c : perVariant) CHECK(c >= 8);
}

TEST(meters_pass_audio_unchanged_in_every_mode_and_block_size) {
    const Stereo in = music(24000);
    for (int v = 0; v < 3; ++v)
        for (uint32_t block : {1u, 37u, 64u, 512u}) CHECK(same(run({{"variant", v}}, "org.caw.meters", in, block).out, in));
}

TEST(meters_analyzer_finds_a_sine) {
    const Result r = run({{"variant", 0}, {"tilt", 0}}, "org.caw.meters", sine(1000.0, 1.0, 48000));
    CHECK(r.display.size() == 264u);
    if (r.display.size() < 8) return;
    CHECK_EQ(r.display[3], 1.0f);  // read lately: analysed
    CHECK(std::fabs(std::log2(r.display[6] / 1000.0)) < 0.1);
    CHECK(std::fabs(r.display[7]) < 1.5f);  // a full-scale sine near 0 dB
}

TEST(meters_tuner_reads_notes_and_cents) {
    struct Case {
        double hz, ref;
        int note;
        double cents;
    };
    const Case cases[] = {{110.0, 440.0, 45, 0.0}, {82.4069, 440.0, 40, 0.0}, {112.0, 440.0, 45, 31.2}, {329.6276, 440.0, 64, 0.0},
                          {415.0, 415.0, 69, 0.0}, {41.2034, 440.0, 28, 0.0}};
    for (const Case& c : cases) {
        const Result r = run({{"variant", 1}, {"reference", c.ref}}, "org.caw.meters", sine(c.hz, 0.5, 24000));
        CHECK(r.display.size() == 9u);
        if (r.display.size() < 9) continue;
        CHECK_EQ(r.display[2], 1.0f);
        CHECK_EQ(static_cast<int>(r.display[4]), c.note);
        CHECK(std::fabs(r.display[5] - c.cents) < 3.0);
    }
    // Silence and noise: nothing detected.
    const Result quiet = run({{"variant", 1}}, "org.caw.meters", sine(110.0, 0.0, 24000));
    if (quiet.display.size() >= 3) CHECK_EQ(quiet.display[2], 0.0f);
}

TEST(meters_loudness_reads_the_ebu_test_tone) {
    // EBU Tech 3341, test 1: a stereo 1 kHz sine at -23 dBFS reads -23.0 LUFS (+-0.1).
    const Result r = run({{"variant", 2}}, "org.caw.meters", sine(1000.0, std::pow(10.0, -23.0 / 20.0), 48000 * 4));
    CHECK(r.display.size() == 13u);
    if (r.display.size() < 13) return;
    CHECK(std::fabs(r.display[2] + 23.0) < 0.1);  // momentary
    CHECK(std::fabs(r.display[3] + 23.0) < 0.1);  // short-term
    CHECK(std::fabs(r.display[4] + 23.0) < 0.1);  // integrated
    CHECK(std::fabs(r.display[9] + 23.0) < 0.3);  // true peak max
    CHECK(std::fabs(r.display[12] - (-23.0 + 14.0)) < 0.1);  // against the -14 LUFS target
}

TEST(lofi_off_passes_through_and_age_changes_sleeps_and_repeats) {
    const Stereo in = music(48000);
    CHECK(same(run({}, "org.caw.lofi", in).out, in));
    const Values aged = {{"age", 0.9}, {"band", 3}};
    const Result a = run(aged, "org.caw.lofi", in);
    CHECK(!same(a.out, in));
    CHECK(finite(a.out));
    for (uint32_t block : {1u, 37u, 512u}) CHECK(same(run(aged, "org.caw.lofi", in, block).out, a.out));
    for (const Values& v : {Values{{"crackle", 1}}, Values{{"hiss", 1}}, Values{{"wobble", 1}}, Values{{"grit", 1}},
                            Values{{"band", 2}}, Values{{"wear", 1}}})
        CHECK(!same(run(v, "org.caw.lofi", in).out, in));
    // After the input stops, the noise follows it down and the effect falls silent.
    Stereo tail = in;
    tail.l.resize(48000 * 4, 0.0f);
    tail.r.resize(48000 * 4, 0.0f);
    const Result t = run({{"age", 1.0}}, "org.caw.lofi", tail);
    CHECK_EQ(t.out.l.back(), 0.0f);
    // A NaN in the input does not stick.
    Stereo bad = in;
    bad.l[100] = std::numeric_limits<float>::quiet_NaN();
    const Result n = run({{"age", 0.8}, {"band", 1}}, "org.caw.lofi", bad);
    CHECK(std::isfinite(n.out.l.back()));
}

TEST(phase_align_delays_by_hand_and_flips) {
    const Stereo in = music(9600);
    const Result zero = run({}, "org.caw.phasealign", in);
    for (size_t i = 1; i < in.l.size(); ++i) CHECK_EQ(zero.out.l[i], in.l[i - 1]);  // 1 frame of latency
    const Result half = run({{"delay", 0.5}, {"invert", 1}}, "org.caw.phasealign", in);  // 24 frames, flipped
    for (size_t i = 25 + 960; i < in.l.size(); ++i) CHECK(std::fabs(half.out.l[i] + in.l[i - 25]) < 1e-6f);
    // A fractional delay (10.5 frames) on a low tone matches the tone delayed.
    const Stereo tone = sine(200.0, 0.5, 9600);
    const Result frac = run({{"delay", 10.5 / 48.0}}, "org.caw.phasealign", tone);
    double worst = 0;
    for (size_t i = 2000; i < 9600; ++i)
        worst = std::max(worst, std::fabs(frac.out.l[i] - 0.5 * std::sin(2 * kPi * 200.0 * (static_cast<double>(i) - 11.5) / kSr)));
    CHECK(worst < 1e-4);
}

TEST(phase_align_learns_delay_and_polarity) {
    // This track early by 37 frames and flipped against the key: auto finds both and lines it up.
    const size_t n = 48000 * 2;
    const Stereo x = noise(n, 3);
    Stereo key{std::vector<float>(n, 0.0f), std::vector<float>(n, 0.0f)};
    for (size_t i = 37; i < n; ++i) key.l[i] = -x.l[i - 37], key.r[i] = -x.r[i - 37];
    const Result r = run({{"mode", 1}, {"window", 0.5}}, "org.caw.phasealign", x, 64, &key);
    CHECK(r.display.size() == 10u);
    if (r.display.size() < 10) return;
    CHECK(std::fabs(r.display[2] - 37.0 / 48.0) < 0.002);  // ms
    CHECK_EQ(r.display[3], 1.0f);                          // flipped
    CHECK_EQ(r.display[5], 1.0f);                          // learned
    CHECK(r.display[7] > 0.5f);                            // confident
    CHECK(r.display[8] > 0.95f);                           // and now in line with the key
    for (uint32_t block : {1u, 37u, 512u}) CHECK(same(run({{"mode", 1}, {"window", 0.5}}, "org.caw.phasealign", x, block, &key).out, r.out));
    // Late against the key: it can't move earlier, says how far, and stays at 0.
    Stereo early{std::vector<float>(n, 0.0f), std::vector<float>(n, 0.0f)};
    for (size_t i = 20; i < n; ++i) early.l[i] = x.l[i - 20], early.r[i] = x.r[i - 20];
    const Result late = run({{"mode", 1}, {"window", 0.5}}, "org.caw.phasealign", early, 64, &x);
    if (late.display.size() >= 10) {
        CHECK(std::fabs(late.display[6] + 20.0 / 48.0) < 0.002);
        CHECK_EQ(late.display[2], 0.0f);
    }
    // NaN in: the output recovers.
    Stereo bad = x;
    bad.l[500] = std::numeric_limits<float>::quiet_NaN();
    const Result b = run({{"mode", 1}, {"window", 0.5}}, "org.caw.phasealign", bad, 64, &key);
    CHECK(std::isfinite(b.out.l.back()));
}

TEST(tools_match_their_reference_renders) {
    const Stereo in = music(48000);
    cawtest::References refs("fx_tools");
    const Result lofi = run({{"age", 0.7}, {"band", 3}, {"seed", 3}}, "org.caw.lofi", in);
    CHECK_REFERENCE(refs, "lofi_age_cassette", (cawtest::Audio{lofi.out.l, lofi.out.r}), cawtest::Class::Stable);
    const Result radio = run({{"band", 1}, {"grit", 0.5}, {"wear", 0.4}}, "org.caw.lofi", in);
    CHECK_REFERENCE(refs, "lofi_radio_grit", (cawtest::Audio{radio.out.l, radio.out.r}), cawtest::Class::Stable);
    const Result align = run({{"delay", 3.3}, {"invert", 1}}, "org.caw.phasealign", in);
    CHECK_REFERENCE(refs, "phasealign_manual", (cawtest::Audio{align.out.l, align.out.r}), cawtest::Class::Stable);
}
