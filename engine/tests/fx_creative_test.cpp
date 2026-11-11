// The Creative and Pitch & Time effects (fx-creative): each effect's sound, block sizes, sleep, display, presets, stability, goldens.
#include <algorithm>
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
#include "component_chain.h"
#include "engine.h"
#include "presets.h"
#include "quality.h"
#include "test.h"

using namespace caw;

namespace {

using Values = std::vector<std::pair<std::string, double>>;

const char* const kCreative[] = {"org.caw.tapestop",   "org.caw.reverser",  "org.caw.stutter",    "org.caw.pitchshift",
                                 "org.caw.freqshift",  "org.caw.trancegate", "org.caw.bitcrush",  "org.caw.ringmod"};
// How many floats each publishes (docs/engine.md, "Display data").
const uint32_t kSizes[] = {8, 6, 8, 6, 7, 5, 7, 8};

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

// `in` through p in `block`-frame blocks, `values` over the defaults; a transport at `tempo` (stopped, or playing
// from `beat` when `playing`), and (when given) a sidechain key through processPorts.
Stereo run(ModuleProcessor& p, const Stereo& in, const Values& values = {}, uint32_t block = 64, double tempo = 120,
           bool playing = false, double beat = 0.0, const Stereo* key = nullptr) {
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
        t.beat = beat + static_cast<double>(start) * tempo / (60.0 * 48000.0);
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        if (key) {
            const float* kc[2] = {key->l.data() + start, key->r.data() + start};
            const ConstChannelBufferView ins[2] = {{ic, 2, n}, {kc, 2, n}};
            const ChannelBufferView outs[1] = {{oc, 2, n}};
            ProcessBlock b;
            b.frames = n;
            b.sampleRate = 48000;
            b.audioIn = ins;
            b.audioInCount = 2;
            b.audioOut = outs;
            b.audioOutCount = 1;
            b.parameters = params.data();
            b.parameterCount = d.parameterCount;
            b.transport = &t;
            CHECK(p.processPorts(b));
            continue;
        }
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
Stereo sine(double hz, double amp, size_t frames) {
    Stereo s = silence(frames);
    for (size_t i = 0; i < frames; ++i) s.l[i] = s.r[i] = static_cast<float>(amp * detSin(kTwoPi * hz * i / 48000.0));
    return s;
}
Stereo noise(size_t frames, uint32_t seed = 7) {
    Stereo s = silence(frames);
    for (size_t i = 0; i < frames; ++i) {
        seed = seed * 1664525u + 1013904223u;
        s.l[i] = static_cast<float>((seed >> 8) / 8388608.0 - 1.0) * 0.5f;
        seed = seed * 1664525u + 1013904223u;
        s.r[i] = static_cast<float>((seed >> 8) / 8388608.0 - 1.0) * 0.5f;
    }
    return s;
}
// Plucked partials and noise bursts on a beat, a gap of silence, different sides (as effects_test's).
Stereo music(size_t frames) {
    Stereo s = silence(frames);
    uint32_t seed = 12345;
    for (size_t i = 0; i < frames; ++i) {
        const size_t beat = i % 12000, bar = i / 12000;
        if (bar == 3) continue;
        const double env = detExp(-static_cast<double>(beat) / 2400.0);
        seed = seed * 1664525u + 1013904223u;
        const double nz = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * detExp(-static_cast<double>(beat) / 300.0);
        const double f = 110.0 * (1 + bar % 4);
        const double t = static_cast<double>(i) / 48000.0;
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
// The level of `hz` in x[from, to) (a Hann-windowed single-bin DFT), in dB re a full-scale sine.
double toneDb(const std::vector<float>& x, size_t from, size_t to, double hz) {
    double re = 0, im = 0, wsum = 0;
    const double n = static_cast<double>(to - from);
    for (size_t i = from; i < to; ++i) {
        const double k = static_cast<double>(i - from);
        const double w = 0.5 - 0.5 * std::cos(kTwoPi * k / n);
        re += w * x[i] * std::cos(kTwoPi * hz * k / 48000.0);
        im -= w * x[i] * std::sin(kTwoPi * hz * k / 48000.0);
        wsum += w;
    }
    return db(2.0 * std::sqrt(re * re + im * im) / wsum);
}
// Zero crossings per second over [from, to).
double crossingsHz(const std::vector<float>& x, size_t from, size_t to) {
    size_t c = 0;
    for (size_t i = from + 1; i < to; ++i) c += (x[i - 1] < 0) != (x[i] < 0);
    return 0.5 * static_cast<double>(c) * 48000.0 / static_cast<double>(to - from);
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

// Every effect's busy settings: most knobs away from their defaults, so its whole path runs.
Values busy(const std::string& s) {
    if (s == "org.caw.tapestop") return {{"stop", 1}, {"stop_time", 300}, {"curve", 0.4}, {"mix", 0.9}};
    if (s == "org.caw.reverser") return {{"sync", 6}, {"crossfade", 30}, {"mix", 0.8}};
    if (s == "org.caw.stutter")
        return {{"interval", 0}, {"offset", 1}, {"division", 1}, {"length", 1}, {"chance", 0.7}, {"seed", 42}, {"decay", 0.3},
                {"pitch", 2}, {"gate", 0.6}, {"mix", 0.9}};
    if (s == "org.caw.pitchshift") return {{"semitones", 7}, {"cents", -20}, {"grain", 40}, {"jitter", 0.5}, {"mix", 0.8}};
    if (s == "org.caw.freqshift") return {{"shift", -150}, {"direction", 2}, {"spread", 30}, {"feedback", 0.6}, {"delay", 20}, {"mix", 0.8}};
    if (s == "org.caw.trancegate")
        return {{"steps", 2}, {"rate", 1}, {"attack", 3}, {"decay", 80}, {"sustain", 0.4}, {"release", 60}, {"length", 0.7},
                {"swing", 0.5}, {"legato", 1}, {"mix", 0.9}, {"s2", 0.5}, {"s5", 1}};
    if (s == "org.caw.bitcrush")
        return {{"bits", 5.5}, {"rate", 6000}, {"jitter", 0.5}, {"dither", 0.7}, {"adc", 0.6}, {"dac", 0.4}, {"output", -3}, {"mix", 0.8}};
    return {{"source", 2}, {"freq", 220}, {"spread", 0.5}, {"bias", 0.2}, {"rectify", 0.5}, {"mix", 0.9}};
}

}  // namespace

// ---------- The suite ----------

TEST(fx_creative_effects_are_registered_with_tapered_knobs_and_presets) {
    Engine e(48000);
    for (const char* id : kCreative) {
        std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(id);
        CHECK(p != nullptr);
        if (!p) continue;
        const ModuleDescriptor& d = p->descriptor();
        CHECK(d.role == ModuleRole::Effect);
        CHECK(!d.name.empty());
        CHECK(d.parameterCount <= 64);  // the chain's latency query reads at most 64 held values
        for (uint32_t i = 0; i < d.parameterCount; ++i) {
            const ParameterDescriptor& q = d.parameters[i];
            if ((q.unit == "Hz" && q.minimum > 0) || (q.unit == "ms" && q.minimum > 0))
                if (q.curve != ParameterCurve::Exponential)
                    cawtest::fail(__FILE__, __LINE__, std::string(id) + "." + std::string(q.id) + " should taper");
        }
        // 3 to 8 presets, each naming only real parameters with values in range.
        const auto& presets = builtinPresets(id);
        if (presets.size() < 3 || presets.size() > 8) cawtest::fail(__FILE__, __LINE__, std::string(id) + " has " + std::to_string(presets.size()) + " presets");
        for (const BuiltinPreset& pr : presets) {
            CHECK(!pr.description.empty());
            for (const auto& [k, v] : pr.values) {
                const int at = paramIndex(d, std::string(k));
                if (at < 0) continue;
                const ParameterDescriptor& q = d.parameters[at];
                if (v < q.minimum || v > q.maximum)
                    cawtest::fail(__FILE__, __LINE__, std::string(id) + " preset " + std::string(pr.name) + ": " + std::string(k));
            }
        }
    }
}

TEST(fx_creative_effects_render_the_same_bits_at_any_block_size) {
    Engine e(48000);
    const Stereo in = music(48000 * 2);
    for (const char* id : kCreative)
        for (bool b : {false, true})
            for (bool playing : {false, true}) {
                const Values v = b ? busy(id) : Values{};
                std::unique_ptr<ModuleProcessor> a = make(e, id);
                if (!a) continue;
                const Stereo ref = run(*a, in, v, 64, 120, playing, 0.37);
                for (uint32_t block : {1u, 37u, 500u}) {
                    std::unique_ptr<ModuleProcessor> c = make(e, id);
                    const Stereo got = run(*c, in, v, block, 120, playing, 0.37);
                    size_t differ = 0;
                    for (size_t i = 0; i < in.size(); ++i) differ += got.l[i] != ref.l[i] || got.r[i] != ref.r[i];
                    if (differ)
                        cawtest::fail(__FILE__, __LINE__, std::string(id) + (b ? " busy" : " default") + (playing ? " playing: " : ": ") +
                                                              std::to_string(differ) + " samples differ at block " + std::to_string(block));
                }
            }
}

TEST(fx_creative_effects_stay_finite_and_bounded_whatever_their_knobs) {
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
    for (const char* id : kCreative)
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
            const Stereo key = noise(in.size());
            const bool keyed = std::string(id) == "org.caw.ringmod";
            const Stereo out = run(*p, in, v, 64, 90, round % 2 == 0, 0.0, keyed ? &key : nullptr);
            bool finite = true;
            double most = 0;
            for (size_t i = 0; i < out.size(); ++i) {
                finite &= std::isfinite(out.l[i]) && std::isfinite(out.r[i]);
                most = std::max({most, std::fabs(static_cast<double>(out.l[i])), std::fabs(static_cast<double>(out.r[i]))});
            }
            if (!finite || most > 50.0)
                cawtest::fail(__FILE__, __LINE__, std::string(id) + " round " + std::to_string(round) + ": " +
                                                      (finite ? "peak " + std::to_string(most) : std::string("not finite")));
            float shown[kMaxDisplayFloats];
            const uint32_t n = p->readDisplay(shown, kMaxDisplayFloats);
            for (uint32_t k = 0; k < n; ++k)
                if (!std::isfinite(shown[k])) cawtest::fail(__FILE__, __LINE__, std::string(id) + ": display float " + std::to_string(k));
        }
}

TEST(fx_creative_effects_fall_quiet_after_silence_and_wake_on_input) {
    Engine e(48000);
    for (const char* id : kCreative) {
        std::unique_ptr<ModuleProcessor> p = make(e, id);
        if (!p) continue;
        Stereo in = music(12000);
        in.l.resize(48000 * 12, 0.0f);
        in.r.resize(48000 * 12, 0.0f);
        const Stereo out = run(*p, in);
        if (!p->quiet()) cawtest::fail(__FILE__, __LINE__, std::string(id) + " is not quiet after 11 s of silence");
        CHECK_EQ(out.l.back(), 0.0f);
        const Stereo again = run(*p, sine(440, 0.5, 72000));
        CHECK(!p->quiet());
        if (peak(again.l, 48000) < 0.01) cawtest::fail(__FILE__, __LINE__, std::string(id) + " stays silent after waking");
    }
}

TEST(fx_creative_effects_publish_their_display_layouts) {
    Engine e(48000);
    for (size_t k = 0; k < std::size(kCreative); ++k) {
        std::unique_ptr<ModuleProcessor> p = make(e, kCreative[k]);
        if (!p) continue;
        float shown[kMaxDisplayFloats];
        CHECK_EQ(p->readDisplay(shown, kMaxDisplayFloats), 0u);
        run(*p, sine(1000, 0.5, 4800));
        const uint32_t n = p->readDisplay(shown, kMaxDisplayFloats);
        if (n != kSizes[k]) cawtest::fail(__FILE__, __LINE__, std::string(kCreative[k]) + " publishes " + std::to_string(n) + " floats");
        CHECK_NEAR(shown[0], -6.02, 0.1);  // each starts with its input peak in dB
    }
}

TEST(fx_creative_effects_match_their_golden_renders) {
    // 2 s of music through each effect at its defaults and busy settings, 64-frame blocks, 120 BPM, stopped.
    // Change a hash only for an intended sound change (the failure prints the new one).
    struct Golden {
        const char* id;
        bool busy;
        uint64_t hash;
    };
    const Golden goldens[] = {
#include "fx_creative_golden.inc"
    };
    Engine e(48000);
    const Stereo in = music(48000 * 2);
    for (const char* id : kCreative)
        for (bool b : {false, true}) {
            std::unique_ptr<ModuleProcessor> p = make(e, id);
            if (!p) continue;
            const uint64_t h = hash(run(*p, in, b ? busy(id) : Values{}));
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

// ---------- Tape stop ----------

TEST(tape_stop_passes_its_input_until_stopped_then_slows_to_silence_and_spins_back) {
    Engine e(48000);
    const Stereo in = sine(1000, 0.5, 48000);
    {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.tapestop");
        const Stereo out = run(*p, in);
        CHECK(out.l == in.l);  // playing: the input bit for bit
    }
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.tapestop");
    const Stereo out = run(*p, in, {{"stop", 1}, {"stop_time", 500}, {"curve", 0}});
    // The pitch falls: 1 kHz in the first 50 ms, about half in the middle of the stop, then silence.
    CHECK_NEAR(crossingsHz(out.l, 0, 2400), 1000, 60);
    CHECK(crossingsHz(out.l, 10800, 13200) < 650);
    CHECK(crossingsHz(out.l, 10800, 13200) > 350);
    CHECK(peak(out.l, 24500, 48000) == 0.0);
    // Let go: it spins up over the start time and then plays the input again exactly.
    const Stereo back = run(*p, in, {{"stop", 0}, {"start_time", 100}});
    CHECK(crossingsHz(back.l, 0, 2400) < 800);
    size_t same = 0;
    for (size_t i = 24000; i < 48000; ++i) same += back.l[i] == in.l[i];
    CHECK_EQ(same, size_t(24000));
}

TEST(tape_stop_times_its_stop_to_the_song_when_synced) {
    Engine e(48000);
    const Stereo in = sine(500, 0.5, 48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.tapestop");
    // A quarter note at 120 BPM: silent from 0.5 s.
    const Stereo out = run(*p, in, {{"stop", 1}, {"stop_sync", 9}}, 64, 120);
    CHECK(peak(out.l, 22000, 23000) > 0.0);
    CHECK(peak(out.l, 24100, 48000) == 0.0);
}

// ---------- Reverser ----------

TEST(reverser_plays_each_chunk_backwards_one_chunk_late) {
    Engine e(48000);
    Stereo in = silence(48000);
    in.l[0] = in.r[0] = 0.25f;  // wakes it on frame 0 (an effect asleep starts its chunks on its first sound)
    in.l[100] = in.r[100] = 1.0f;
    in.l[9000] = in.r[9000] = 0.5f;
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.reverser");
    const Stereo out = run(*p, in, {{"sync", 0}, {"time", 250}, {"crossfade", 0}});
    // The chunk [0, 12000) comes back from 12000 reversed: frame k at 12000 + 11999 - k.
    CHECK_NEAR(out.l[12000 + 11999 - 100], 1.0, 1e-6);
    CHECK_NEAR(out.l[12000 + 11999 - 9000], 0.5, 1e-6);
    CHECK(peak(out.l, 0, 12000) == 0.0);
    // The later click comes first: reversed.
    CHECK(12000 + 11999 - 9000 < 12000 + 11999 - 100);
}

TEST(reverser_crossfades_its_seams_so_a_steady_tone_keeps_its_level) {
    Engine e(48000);
    const Stereo in = noise(48000 * 2);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.reverser");
    const Stereo out = run(*p, in, {{"sync", 0}, {"time", 200}, {"crossfade", 25}});
    // Short windows across seams keep within 3 dB of the input's level.
    for (size_t at = 28800; at < 96000 - 2400; at += 1200) {
        const double d = db(rms(out.l, at, at + 1200) / rms(in.l, at, at + 1200));
        if (std::fabs(d) > 3.0) cawtest::fail(__FILE__, __LINE__, "level " + std::to_string(d) + " dB at " + std::to_string(at));
    }
}

// ---------- Trance gate ----------

TEST(trance_gate_opens_on_the_steps_that_are_on_and_swings_the_off_beats) {
    Engine e(48000);
    const Stereo in = sine(300, 0.5, 48000 * 2);
    Values v = {{"steps", 0}, {"rate", 2}, {"attack", 1}, {"release", 5}, {"length", 1}, {"sustain", 1}};
    for (int k = 1; k <= 32; ++k) v.push_back({"s" + std::to_string(k), k == 1 || k == 3 ? 1.0 : 0.0});
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.trancegate");
    const Stereo out = run(*p, in, v);
    // 1/16 at 120 BPM is 6000 frames: step 1 open, step 2 closed, step 3 open, step 4 closed.
    CHECK(rms(out.l, 1000, 5000) > 0.3);
    CHECK(rms(out.l, 7000, 11000) < 0.01);
    CHECK(rms(out.l, 13000, 17000) > 0.3);
    CHECK(rms(out.l, 19000, 23000) < 0.01);
    // Swing 1: the second step of a pair starts half a step late.
    Values sw = v;
    sw.push_back({"swing", 1.0});
    for (auto& [k, x] : sw)
        if (k == "s2") x = 1.0;
        else if (k == "s1" || k == "s3") x = 0.0;
    std::unique_ptr<ModuleProcessor> q = make(e, "org.caw.trancegate");
    const Stereo swung = run(*q, in, sw);
    CHECK(rms(swung.l, 6200, 8800) < 0.01);
    CHECK(rms(swung.l, 9400, 11500) > 0.3);
}

TEST(trance_gate_locks_to_the_song_position_while_playing) {
    Engine e(48000);
    const Stereo in = sine(300, 0.5, 24000);
    Values v = {{"steps", 0}, {"rate", 2}, {"attack", 0.1}, {"release", 1}, {"length", 1}};
    for (int k = 1; k <= 32; ++k) v.push_back({"s" + std::to_string(k), k == 2 ? 1.0 : 0.0});
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.trancegate");
    // From beat 0.25 (the second sixteenth): open at once, closed after one step.
    const Stereo out = run(*p, in, v, 64, 120, true, 0.25);
    CHECK(rms(out.l, 200, 5800) > 0.3);
    CHECK(rms(out.l, 6500, 11500) < 0.01);
}

// ---------- Stutter ----------

TEST(stutter_repeats_the_first_slice_by_chance_and_the_same_way_every_time) {
    Engine e(48000);
    const Stereo in = noise(48000 * 2);
    // Every quarter (24000 frames at 120 BPM), always: the first sixteenth (6000 frames) repeats to the quarter's end.
    const Values always = {{"interval", 0}, {"offset", 0}, {"division", 3}, {"length", 2}, {"chance", 1}, {"decay", 0}, {"gate", 1}};
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.stutter");
    const Stereo out = run(*p, in, always);
    size_t same = 0;
    for (size_t i = 6200; i < 11800; ++i) same += std::fabs(out.l[i] - in.l[i - 6000]) < 1e-6;
    CHECK(same > 5500);
    for (size_t i = 100; i < 5900; ++i) CHECK_EQ(out.l[i], in.l[i]);  // the first slice plays through
    // Chance 0: the dry signal.
    std::unique_ptr<ModuleProcessor> q = make(e, "org.caw.stutter");
    Values never = always;
    never[4].second = 0.0;
    CHECK(run(*q, in, never).l == in.l);
    // Chance one half: seeded, so the same twice; another seed, another pattern.
    Values half = always;
    half[4].second = 0.5;
    auto render = [&](double seed) {
        Values v = half;
        v.push_back({"seed", seed});
        std::unique_ptr<ModuleProcessor> r = make(e, "org.caw.stutter");
        return hash(run(*r, noise(48000 * 6), v));
    };
    CHECK_EQ(render(3), render(3));
    CHECK(render(3) != render(4));
}

TEST(stutter_pitches_each_repeat_and_hold_repeats_now) {
    Engine e(48000);
    const Stereo in = sine(400, 0.5, 48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.stutter");
    // Hold from the start, 1/8 slices (12000 frames), each repeat 12 semitones up: the second slice is 800 Hz.
    const Stereo out = run(*p, in, {{"hold", 1}, {"division", 5}, {"pitch", 12}, {"decay", 0}, {"gate", 1}, {"chance", 0}});
    CHECK_NEAR(crossingsHz(out.l, 500, 11500), 400, 15);
    CHECK_NEAR(crossingsHz(out.l, 12500, 17500), 800, 30);  // the octave up plays the slice in half the time
    CHECK(peak(out.l, 18100, 23900) < 1e-3);                 // and is silent for the rest of it
}

// ---------- Bitcrush ----------

TEST(bitcrush_quantises_holds_and_is_clean_at_full_resolution) {
    Engine e(48000);
    const Stereo in = sine(997, 0.7, 24000);
    {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.bitcrush");
        const Stereo out = run(*p, in, {{"bits", 24}, {"rate", 48000}});
        double worst = 0;
        for (size_t i = 0; i < in.size(); ++i) worst = std::max(worst, std::fabs(static_cast<double>(out.l[i] - in.l[i])));
        CHECK(worst < 1e-6);
    }
    {
        // 3 bits: at most 9 levels (-1 .. 1 in quarters).
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.bitcrush");
        const Stereo out = run(*p, in, {{"bits", 3}, {"rate", 48000}});
        std::vector<float> levels(out.l.begin(), out.l.end());
        std::sort(levels.begin(), levels.end());
        levels.erase(std::unique(levels.begin(), levels.end()), levels.end());
        CHECK(levels.size() <= 9);
        for (float x : levels) CHECK_NEAR(x * 4.0, std::round(x * 4.0), 1e-6);
    }
    {
        // 1 kHz: each value held for 48 frames.
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.bitcrush");
        const Stereo out = run(*p, in, {{"bits", 24}, {"rate", 1000}});
        size_t changes = 0;
        for (size_t i = 1; i < out.size(); ++i) changes += out.l[i] != out.l[i - 1];
        CHECK_NEAR(static_cast<double>(changes), 500.0, 3.0);
        // The anti-image filter smooths the steps: much less above the crushed Nyquist.
        std::unique_ptr<ModuleProcessor> q = make(e, "org.caw.bitcrush");
        const Stereo smooth = run(*q, in, {{"bits", 24}, {"rate", 4000}, {"dac", 1}});
        std::unique_ptr<ModuleProcessor> r = make(e, "org.caw.bitcrush");
        const Stereo steps = run(*r, in, {{"bits", 24}, {"rate", 4000}, {"dac", 0}});
        CHECK(toneDb(smooth.l, 4800, 24000, 4000 - 997) < toneDb(steps.l, 4800, 24000, 4000 - 997) - 12.0);
    }
}

// ---------- Pitch shifter ----------

TEST(pitch_shifter_moves_a_tone_and_reports_half_a_grain_of_latency) {
    Engine e(48000);
    const Stereo in = sine(440, 0.5, 48000);
    for (auto [semis, want] : {std::pair{12.0, 880.0}, std::pair{-12.0, 220.0}, std::pair{7.0, 440.0 * 1.4983070768766815}}) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.pitchshift");
        const Stereo out = run(*p, in, {{"semitones", semis}, {"grain", 50}});
        const double at = toneDb(out.l, 9600, 48000, want), was = toneDb(out.l, 9600, 48000, 440);
        if (!(at > -12.0 && at > was + 15.0))
            cawtest::fail(__FILE__, __LINE__, std::to_string(semis) + " st: " + std::to_string(at) + " dB vs " + std::to_string(was));
    }
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.pitchshift");
    const auto* v = dynamic_cast<const VariableLatency*>(p.get());
    CHECK(v != nullptr);
    double values[5] = {0, 0, 50, 0, 1};
    if (v) CHECK_EQ(v->latencyFor(values, 5), 1201u);  // 50 ms: 2400 frames, half of it and the read's one
    // No shift: the input delayed by exactly the reported latency.
    const Stereo out = run(*p, in, {{"grain", 50}});
    double worst = 0;
    for (size_t i = 1201; i < 48000; ++i) worst = std::max(worst, std::fabs(static_cast<double>(out.l[i] - in.l[i - 1201])));
    CHECK(worst < 1e-5);
}

// ---------- Frequency shifter ----------

TEST(frequency_shifter_moves_every_partial_by_the_same_hertz_on_one_side) {
    Engine e(48000);
    const Stereo in = sine(1000, 0.5, 48000);
    auto level = [&](const Values& v, int ch, double hz) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.freqshift");
        const Stereo out = run(*p, in, v);
        return toneDb(ch ? out.r : out.l, 9600, 48000, hz);
    };
    // Up 100: 1100 Hz, the lower sideband (900) at least 50 dB under it.
    CHECK(level({{"shift", 100}}, 0, 1100) > -7.5);
    CHECK(level({{"shift", 100}}, 0, 1100) - level({{"shift", 100}}, 0, 900) > 50.0);
    CHECK(level({{"shift", 100}}, 0, 1000) < -50.0);
    // Down 100: 900 Hz.
    CHECK(level({{"shift", 100}, {"direction", 1}}, 0, 900) - level({{"shift", 100}, {"direction", 1}}, 0, 1100) > 50.0);
    // Both: up on the left, down on the right.
    CHECK(level({{"shift", 100}, {"direction", 2}}, 0, 1100) > -7.5);
    CHECK(level({{"shift", 100}, {"direction", 2}}, 1, 900) > -7.5);
    // At 40 Hz and 15 kHz too.
    for (double hz : {40.0, 15000.0}) {
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.freqshift");
        const Stereo out = run(*p, sine(hz, 0.5, 48000), {{"shift", 30}});
        CHECK(toneDb(out.l, 9600, 48000, hz + 30) - toneDb(out.l, 9600, 48000, hz - 30) > 45.0);
    }
}

// ---------- Ring mod ----------

TEST(ring_mod_makes_sum_and_difference_tones_and_takes_a_key) {
    Engine e(48000);
    const Stereo in = sine(1000, 0.5, 48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.ringmod");
    const Stereo out = run(*p, in, {{"freq", 300}});
    CHECK_NEAR(toneDb(out.l, 4800, 48000, 700), db(0.25), 0.5);
    CHECK_NEAR(toneDb(out.l, 4800, 48000, 1300), db(0.25), 0.5);
    CHECK(toneDb(out.l, 4800, 48000, 1000) < -60.0);
    // Bias 1: the input passes.
    std::unique_ptr<ModuleProcessor> q = make(e, "org.caw.ringmod");
    const Stereo pass = run(*q, in, {{"bias", 1}});
    CHECK(pass.l == in.l);
    // The key as carrier: the product, sample by sample; no key, silence.
    const Stereo key = noise(4800);
    const Stereo x = sine(1000, 0.5, 4800);
    std::unique_ptr<ModuleProcessor> r = make(e, "org.caw.ringmod");
    const Stereo keyed = run(*r, x, {{"source", 5}}, 64, 120, false, 0.0, &key);
    double worst = 0;
    for (size_t i = 0; i < 4800; ++i) worst = std::max(worst, std::fabs(static_cast<double>(keyed.l[i]) - static_cast<double>(x.l[i]) * key.l[i]));
    CHECK(worst < 1e-6);
    std::unique_ptr<ModuleProcessor> s = make(e, "org.caw.ringmod");
    CHECK(peak(run(*s, x, {{"source", 5}}).l) == 0.0);
}

TEST(ring_mod_oversamples_at_high_quality_so_sums_above_nyquist_fold_back_less) {
    Engine e(48000);
    const Stereo in = sine(22000, 0.5, 48000);
    auto folded = [&](int quality) {
        const std::atomic<int> q{quality};
        const BuildingQuality building(&q);  // as the Engine does while it builds a chain
        std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.ringmod");
        const Stereo out = run(*p, in, {{"freq", 8000}});
        return toneDb(out.l, 4800, 48000, 18000);  // the sum, 30 kHz, folds to 18 kHz
    };
    const double normal = folded(kQualityNormal), high = folded(kQualityHigh);
    CHECK(high < normal - 20.0);
}
