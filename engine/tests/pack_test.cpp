// The AutoStacc beta pack: the grain engine (overlap-add, cap, seeding) and Murmur, Peck, Bend and Molt (their sound, pack mark, display, block sizes, bad input, presets and reference renders).
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_pack.h"
#include "component_chain.h"
#include "caw/library/grain.hpp"
#include "engine.h"
#include "fx_modes_harness.h"
#include "quality.h"
#include "tolerance.h"

using namespace caw;
using namespace modes_test;

namespace {

constexpr const char* kMurmur = "org.caw.pack.granular";
constexpr const char* kPeck = "org.caw.pack.glitch";
constexpr const char* kBend = "org.caw.pack.warp";
constexpr const char* kIris = "org.caw.pack.spectral";

// The error of `out` against `want` delayed by `lag`, from `from` on, in dB of `want`'s power.
double errorDb(const Stereo& out, const Stereo& want, size_t lag, size_t from) {
    double e = 0, w = 0;
    for (size_t i = from; i < out.size(); ++i) {
        const double ref = i >= lag ? want.l[i - lag] : 0.0;
        e += (out.l[i] - ref) * (out.l[i] - ref);
        w += ref * ref;
    }
    return 10.0 * std::log10((e + 1e-30) / (w + 1e-30));
}
double goertzelDb(const std::vector<float>& x, double hz, size_t from, size_t to) {
    const double c = 2 * std::cos(2 * modes_test::kPi * hz / 48000.0);
    double s1 = 0, s2 = 0;
    for (size_t i = from; i < to; ++i) {
        const double s = x[i] + c * s1 - s2;
        s2 = s1, s1 = s;
    }
    const double n = static_cast<double>(to - from);
    return 10 * std::log10((s1 * s1 + s2 * s2 - c * s1 * s2) / (n * n) + 1e-30);
}
std::vector<float> display(ModuleProcessor& p) {
    std::vector<float> d(1024);
    d.resize(p.readDisplay(d.data(), 1024));
    return d;
}
// A device made at a quality tier.
std::unique_ptr<ModuleProcessor> makeAt(const char* id, const Values& v, int tier) {
    static std::atomic<int> tiers[3] = {kQualityEco, kQualityNormal, kQualityHigh};
    const BuildingQuality building(&tiers[tier]);
    return make(id, v);
}
bool same(const Stereo& a, const Stereo& b) {
    return std::memcmp(a.l.data(), b.l.data(), a.l.size() * 4) == 0 && std::memcmp(a.r.data(), b.r.data(), a.r.size() * 4) == 0;
}
// At least `least` presets, each named and described, rendering finite and audible.
void checkPackPresets(const char* id, size_t least, const Stereo& in) {
    const auto& presets = builtinPresets(id);
    if (presets.size() < least) cawtest::fail(__FILE__, __LINE__, std::string(id) + ": " + std::to_string(presets.size()) + " presets");
    for (const BuiltinPreset& preset : presets) {
        CHECK(!preset.name.empty() && !preset.description.empty());
        Values values;
        CHECK(applyBuiltinPreset(id, preset.name, values));
        const Stereo out = render(id, values, in);
        if (!finite(out)) cawtest::fail(__FILE__, __LINE__, std::string(preset.name) + ": not finite");
        const double level = rms(out.l);
        if (!(level > 1e-3 && peak(out.l) < 4.0))
            cawtest::fail(__FILE__, __LINE__, std::string(preset.name) + ": level " + std::to_string(level));
    }
}

}  // namespace

TEST(pack_devices_are_marked_as_the_autostacc_beta_pack) {
    Engine e(48000);
    const std::string json = e.nativeComponentsJson();
    for (const char* id : {kMurmur, kPeck, kBend, kIris}) {
        CHECK(fx::packOf(id) == "autostacc-beta");
        const size_t at = json.find(std::string("\"id\":\"") + id + "\"");
        CHECK(at != std::string::npos);
        const size_t start = json.rfind("{\"builtin\":true", at);
        CHECK(start != std::string::npos && json.find("\"pack\":\"autostacc-beta\"", start) < at);
    }
    CHECK(fx::packOf("org.caw.eq").empty());
}

TEST(grain_engine_holds_its_cap_and_counts_what_it_drops) {
    lib::grain::Ring ring;
    CHECK(ring.prepare(48000));
    for (int i = 0; i < 48000; ++i) ring.write(0.1f, 0.1f);
    lib::grain::Engine eng;
    eng.setCap(lib::grain::murmurCap(0));
    CHECK_EQ(eng.cap(), 16u);
    lib::grain::Settings st;
    st.sizeFrames = 24000, st.interval = 100;
    float l[16], r[16];
    uint32_t dropped = 0, most = 0;
    for (int k = 0; k < 600; ++k) {
        eng.schedule(ring.source(true), st, 16);
        std::fill(l, l + 16, 0.0f), std::fill(r, r + 16, 0.0f);
        eng.render<true>(ring.source(true), l, r, 16);
        most = std::max(most, eng.alive());
        dropped += eng.takeDropped();
    }
    CHECK_EQ(most, 16u);
    CHECK(dropped > 0);
    CHECK_EQ(lib::grain::murmurCap(1), 32u);
    CHECK_EQ(lib::grain::murmurCap(2), 64u);
    CHECK_EQ(lib::grain::flockCap(0), 64u);
    CHECK_EQ(lib::grain::flockCap(2), 128u);
    // Every window starts at 0 and ends at 0; Hann's two halves sum to 1.
    const auto& w = lib::grain::windows();
    for (uint32_t k = 0; k < lib::grain::kWindowCount; ++k)
        CHECK(std::fabs(w.w[k][0]) < 1e-3 && std::fabs(w.w[k][lib::grain::kWindowPoints]) < 1e-6);
    for (uint32_t j = 0; j < 512; ++j) CHECK(std::fabs(w.w[0][j] + w.w[0][j + 512] - 1.0f) < 1e-6f);
}

TEST(murmur_reconstructs_its_input_with_hann_grains_at_half_overlap) {
    // Size 10 ms (480 frames), density 200 Hz (240): two Hann grains always overlap and sum to 1, no spray, pan,
    // jitter or pitch: the output is the input 24 frames late (the newest age a grain may start at).
    const Stereo in = music(48000);
    const Values v = {{"size", 10}, {"density", 200}, {"spray", 0}, {"jitter", 0}, {"pan", 0}, {"position", 0}, {"mix", 1}};
    for (int tier : {1, 2}) {
        auto p = makeAt(kMurmur, v, tier);
        if (!p) return;
        const Stereo out = run(*p, in, v);
        const double err = errorDb(out, in, 24, 4800);
        if (!(err < -60.0)) cawtest::fail(__FILE__, __LINE__, "tier " + std::to_string(tier) + ": error " + std::to_string(err) + " dB");
    }
}

TEST(murmur_holds_its_cap_per_quality_tier) {
    const Stereo in = music(48000);
    const Values v = {{"size", 500}, {"density", 200}};
    const uint32_t caps[] = {16, 32, 64};
    for (int tier = 0; tier < 3; ++tier) {
        auto p = makeAt(kMurmur, v, tier);
        if (!p) return;
        float most = 0, cap = 0;
        for (int k = 0; k < 10; ++k) {
            run(*p, Stereo{std::vector<float>(in.l.begin() + 4800 * k, in.l.begin() + 4800 * (k + 1)),
                           std::vector<float>(in.r.begin() + 4800 * k, in.r.begin() + 4800 * (k + 1))}, v);
            const std::vector<float> d = display(*p);
            if (d.size() < 43) continue;
            most = std::max(most, d[2]);
            cap = d[3];
            CHECK_EQ(d.size(), static_cast<size_t>(43 + 4 * d[10]));
        }
        CHECK_EQ(cap, static_cast<float>(caps[tier]));
        CHECK(most <= cap && most >= cap - 1);
    }
}

TEST(murmur_freeze_holds_the_buffer) {
    // Half a second of 440 Hz recorded, then frozen: over 1 kHz input the cloud keeps playing 440 Hz only.
    const Values live = {{"buffer", 0.5}, {"size", 100}, {"density", 30}, {"mix", 1}};
    Values frozen = live;
    frozen.emplace_back("freeze", 1);
    auto p = make(kMurmur, live);
    if (!p) return;
    run(*p, sine(440, 0.3, 36000), live);
    const Stereo out = run(*p, sine(1000, 0.3, 48000), frozen);
    const double at440 = goertzelDb(out.l, 440, 9600, 48000), at1k = goertzelDb(out.l, 1000, 9600, 48000);
    if (!(at440 > -30.0 && at440 - at1k > 30.0))
        cawtest::fail(__FILE__, __LINE__, "440 Hz " + std::to_string(at440) + " dB, 1 kHz " + std::to_string(at1k));
    CHECK(display(*p).at(5) == 1.0f);
    // Over silence a frozen cloud plays on and does not sleep.
    const Stereo after = run(*p, silence(48000 * 3), frozen, 512);
    CHECK(rms(after.l, 48000 * 2) > 0.01 && !p->quiet());
}

TEST(murmur_pitch_moves_the_cloud_and_seeds_repeat) {
    const Values up = {{"pitch", 12}, {"size", 60}, {"density", 40}, {"mix", 1}, {"spray", 0}};
    const Stereo out = render(kMurmur, up, sine(500, 0.3, 48000));
    CHECK(goertzelDb(out.l, 1000, 9600, 48000) - goertzelDb(out.l, 500, 9600, 48000) > 20.0);
    const Values a = {{"spray", 80}, {"spread", 7}, {"pan", 1}, {"seed", 3}};
    Values b = a;
    b.back().second = 4;
    const Stereo in = music(48000);
    CHECK(same(render(kMurmur, a, in), render(kMurmur, a, in)));
    CHECK(!same(render(kMurmur, a, in), render(kMurmur, b, in)));
    // Reverse 1: every grain is shown playing backwards (negative pitch).
    const Values back = {{"reverse", 1}, {"pitch", 5}};
    auto p = make(kMurmur, back);
    if (!p) return;
    run(*p, in, back);
    const std::vector<float> d = display(*p);
    CHECK(d.size() > 43 && d[10] > 0);
    for (size_t g = 0; d.size() > 43 && g < d[10]; ++g) CHECK(d[43 + 4 * g + 3] < 0.0f);
}

TEST(murmur_is_block_size_independent_and_survives_bad_input) {
    const Stereo in = music(48000);
    const Values all[] = {{}, {{"spray", 120}, {"spread", 12}, {"scale", 2}, {"reverse", 0.5}, {"pan", 1}},
                          {{"feedback", 0.6}, {"window", 3}, {"sync", 6}}, {{"glide", 300}, {"pitch", -7}, {"width", 1.8}}};
    for (size_t k = 0; k < std::size(all); ++k) {
        checkBlockSizes(kMurmur, all[k], in, "murmur " + std::to_string(k));
        checkBadInput(kMurmur, all[k], "murmur " + std::to_string(k));
    }
    Values frozen = {{"freeze", 1}, {"buffer", 0.5}, {"scan", 0.7}};
    checkBlockSizes(kMurmur, frozen, in, "murmur frozen");
}

TEST(murmur_presets_render) { checkPackPresets(kMurmur, 8, music(48000 * 2)); }

TEST(murmur_matches_its_reference_renders) {
    const Stereo in = music(48000 * 2);
    cawtest::References refs("pack_murmur");
    auto check = [&](const char* name, const Values& v) {
        const Stereo out = render(kMurmur, v, in);
        CHECK_REFERENCE(refs, name, (cawtest::Audio{out.l, out.r}), cawtest::Class::Chaotic);
    };
    check("murmur_default", {});
    check("murmur_scatter", {{"spray", 150}, {"spread", 12}, {"scale", 5}, {"reverse", 0.4}, {"pan", 0.8}, {"mix", 1}});
    check("murmur_freeze", {{"buffer", 0.5}, {"freeze", 1}, {"size", 200}, {"density", 30}, {"mix", 1}});
}

namespace {
// A run of `p` over `in` with the song playing from beat 0 at 120 BPM (the grid locked to it).
Stereo runPlaying(ModuleProcessor& p, const Stereo& in, const Values& values, uint32_t block = 64) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    Stereo out = silence(in.size());
    Transport tr;
    tr.playing = true;
    tr.tempo = 120;
    for (size_t start = 0; start < in.size(); start += block) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(block, in.size() - start));
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        tr.beat = static_cast<double>(start) * 2.0 / 48000.0;
        AudioProcessBlock b;
        b.input = {ic, 2, n};
        b.output = {oc, 2, n};
        b.frames = n;
        b.sampleRate = 48000;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        b.transport = &tr;
        CHECK(p.process(b));
    }
    return out;
}
// A ramp: frame i is i / n (each frame tells where it came from).
Stereo ramp(size_t n) {
    Stereo s = silence(n);
    for (size_t i = 0; i < n; ++i) s.l[i] = s.r[i] = static_cast<float>(static_cast<double>(i) / static_cast<double>(n));
    return s;
}
}  // namespace

TEST(peck_chaos_0_passes_the_input_and_each_action_does_its_job) {
    const Stereo in = music(48000);
    const Stereo out = render(kPeck, {{"chaos", 0}}, in);
    CHECK(same(out, in));
    // At 120 BPM a sixteenth is 6000 frames. With only one action weighted and chaos 1, every slice does it.
    const size_t L = 6000;
    const Stereo r = ramp(48000 * 2);
    auto only = [](const char* action) {
        Values v = {{"chaos", 1}, {"repeat", 0}, {"stutter", 0}, {"reverse", 0}, {"gate", 0}, {"pitch", 0}, {"smooth", 0.5}};
        for (auto& [k, x] : v)
            if (k == action) x = 1;
        return v;
    };
    auto p = make(kPeck, only("repeat"));
    if (!p) return;
    Stereo o = runPlaying(*p, r, only("repeat"));
    // Repeat: the middle of slice 3 plays the middle of slice 2.
    CHECK(std::fabs(o.l[3 * L + L / 2] - r.l[2 * L + L / 2]) < 1e-6);
    p = make(kPeck, only("reverse"));
    o = runPlaying(*p, r, only("reverse"));
    CHECK(std::fabs(o.l[3 * L + 1000] - r.l[3 * L - 1 - 1000]) < 1e-6);
    p = make(kPeck, only("gate"));
    o = runPlaying(*p, r, only("gate"));
    bool closed = false;
    for (size_t s = 2; s < 8; ++s) closed = closed || std::fabs(o.l[s * L + L * 7 / 8 - 200]) < 1e-9;
    CHECK(closed);
    // Stutter: the slice's first 1/N comes back: frame sub + 10 equals frame 10 of the slice.
    p = make(kPeck, only("stutter"));
    o = runPlaying(*p, r, only("stutter"));
    const std::vector<float> d = display(*p);
    CHECK(d.size() == 40);
    bool repeated = false;
    for (int n : {2, 3, 4}) repeated = repeated || std::fabs(o.l[5 * L + L / n + 100] - r.l[5 * L + 100]) < 1e-6;
    CHECK(repeated);
    // Pitch: a 1 kHz tone moves by whole semitones (energy leaves 1 kHz in most slices).
    p = make(kPeck, only("pitch"));
    const Stereo tone = sine(1000, 0.3, 48000 * 2);
    o = runPlaying(*p, tone, only("pitch"));
    CHECK(goertzelDb(o.l, 1000, 6000, 96000) < goertzelDb(tone.l, 1000, 6000, 96000) - 6.0);
}

TEST(peck_plays_the_same_glitches_wherever_playback_starts_and_shows_them_first) {
    const Values v = {{"chaos", 0.6}, {"seed", 9}};
    const Stereo in = music(48000 * 2);
    auto a = make(kPeck, v);
    if (!a) return;
    runPlaying(*a, in, v);
    const std::vector<float> lane = display(*a);
    // The lane shows a bar of plans: a fresh instance shows the same plans for the same bar.
    auto b = make(kPeck, v);
    runPlaying(*b, in, v);
    CHECK(display(*b) == lane);
    // Seeds differ: the plans differ.
    Values w = v;
    w[1].second = 10;
    auto c = make(kPeck, w);
    runPlaying(*c, in, w);
    const std::vector<float> other = display(*c);
    CHECK(other.size() == 40 && !std::equal(other.begin() + 8, other.end(), lane.begin() + 8));
}

TEST(peck_hold_repeats_the_slice_before_it) {
    const Stereo r = ramp(48000);
    const Values v = {{"hold", 1}, {"smooth", 0.5}};
    auto p = make(kPeck, v);
    if (!p) return;
    const Stereo o = runPlaying(*p, r, v);
    // Every slice after the first plays the one before the hold (slice -1, silent before the start) or loops it.
    CHECK(std::fabs(o.l[6000 * 4 + 300] - o.l[6000 * 5 + 300]) < 1e-6);
    CHECK(display(*p).at(6) == 1.0f);
}

TEST(peck_is_block_size_independent_and_survives_bad_input) {
    const Stereo in = music(48000);
    const Values all[] = {{}, {{"chaos", 1}, {"grid", 0}}, {{"chaos", 0.8}, {"pitch", 1}, {"range", 24}, {"grid", 3}}};
    for (size_t k = 0; k < std::size(all); ++k) {
        checkBlockSizes(kPeck, all[k], in, "peck " + std::to_string(k));
        checkBadInput(kPeck, all[k], "peck " + std::to_string(k));
    }
}

TEST(peck_presets_render) { checkPackPresets(kPeck, 8, music(48000 * 2)); }

TEST(peck_matches_its_reference_renders) {
    const Stereo in = music(48000 * 2);
    cawtest::References refs("pack_peck");
    auto check = [&](const char* name, const Values& v) {
        const Stereo out = render(kPeck, v, in);
        CHECK_REFERENCE(refs, name, (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
    };
    check("peck_default", {});
    check("peck_chaos", {{"chaos", 1}, {"grid", 0}, {"range", 7}});
}

TEST(bend_with_no_depth_is_the_input_three_frames_late_and_reports_it) {
    const Stereo in = music(48000);
    for (double mix : {1.0, 0.5, 0.0}) {
        const Stereo out = render(kBend, {{"depth", 0}, {"mix", mix}}, in);
        for (size_t i = 3; i < in.size(); ++i)
            if (std::fabs(out.l[i] - in.l[i - 3]) > 1e-6f) {
                cawtest::fail(__FILE__, __LINE__, "mix " + std::to_string(mix) + ": frame " + std::to_string(i) + " is not the input 3 frames late");
                break;
            }
    }
    const ModuleDescriptor* d = registry().find(kBend);
    CHECK(d && d->latencyFrames == 3u);
}

TEST(bend_time_curve_slope_sets_the_pitch_and_speed_mode_sets_the_speed) {
    const Stereo tone = sine(1000, 0.3, 48000 * 2);
    // Time: the delay rises by a third of real time over the first three quarters of the bar (2 s at 120 BPM).
    const Values rise = {{"depth", 500}, {"points", 0}, {"shape", 0}, {"smooth", 0}, {"p0", -1}, {"p1", -1.0 / 3}, {"p2", 1.0 / 3}, {"p3", 1}};
    Stereo out = runPlaying(*make(kBend, rise), tone, rise);
    CHECK(goertzelDb(out.l, 1000 * 2.0 / 3, 9600, 67200) - goertzelDb(out.l, 1000, 9600, 67200) > 20.0);
    // Speed: every point -1 at a range of one octave: half speed, an octave down.
    const Values half = {{"mode", 1}, {"range", 1}, {"smooth", 0}, {"p0", -1}, {"p1", -1}, {"p2", -1}, {"p3", -1}, {"p4", -1}, {"p5", -1}, {"p6", -1}, {"p7", -1}};
    auto p = make(kBend, half);
    if (!p) return;
    out = runPlaying(*p, tone, half);
    CHECK(goertzelDb(out.l, 500, 9600, 72000) - goertzelDb(out.l, 1000, 9600, 72000) > 20.0);
    const std::vector<float> d = display(*p);
    CHECK(d.size() == 88 && d[2] == 1.0f && std::fabs(d[6] - 0.5f) < 1e-3 && d[8] == -1.0f);
}

TEST(bend_is_block_size_independent_and_survives_bad_input) {
    const Stereo in = music(48000);
    const Values all[] = {{}, {{"depth", 600}, {"shape", 2}, {"smooth", 0}}, {{"mode", 1}, {"cycle", 0}, {"range", 2}}, {{"mode", 1}, {"resync", 0}, {"shape", 0}}};
    for (size_t k = 0; k < std::size(all); ++k) {
        checkBlockSizes(kBend, all[k], in, "bend " + std::to_string(k));
        checkBadInput(kBend, all[k], "bend " + std::to_string(k));
    }
}

TEST(bend_presets_render) { checkPackPresets(kBend, 8, music(48000 * 2)); }

TEST(bend_matches_its_reference_renders) {
    const Stereo in = music(48000 * 2);
    cawtest::References refs("pack_bend");
    auto check = [&](const char* name, const Values& v) {
        const Stereo out = render(kBend, v, in);
        CHECK_REFERENCE(refs, name, (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
    };
    check("bend_time", {{"depth", 80}, {"cycle", 1}});
    check("bend_speed", {{"mode", 1}, {"cycle", 1}});
}

namespace {
uint32_t irisLatency(const Values& v) {
    auto p = make(kIris, v);
    const auto* var = p ? dynamic_cast<const VariableLatency*>(p.get()) : nullptr;
    if (!var) return ~0u;
    const ModuleDescriptor& d = p->descriptor();
    std::vector<double> values(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        values[k] = d.parameters[k].defaultValue;
        for (const auto& [name, x] : v)
            if (d.parameters[k].id == name) values[k] = x;
    }
    return var->latencyFor(values.data(), d.parameterCount);
}
Stereo noise(size_t n, double amp, uint32_t seed = 5) {
    Stereo s = silence(n);
    for (size_t i = 0; i < n; ++i) {
        seed = seed * 1664525u + 1013904223u;
        s.l[i] = static_cast<float>(amp * (static_cast<double>(seed >> 8) / 8388608.0 - 1.0));
        seed = seed * 1664525u + 1013904223u;
        s.r[i] = static_cast<float>(amp * (static_cast<double>(seed >> 8) / 8388608.0 - 1.0));
    }
    return s;
}
}  // namespace

TEST(iris_with_every_stage_off_is_the_input_one_window_late) {
    const Stereo in = music(48000);
    const uint32_t windows[] = {1024, 2048, 4096};
    for (int q = 0; q < 3; ++q) {
        const Values v = {{"quality", static_cast<double>(q)}};
        CHECK_EQ(irisLatency(v), windows[q]);
        const Stereo out = render(kIris, v, in);
        const double err = errorDb(out, in, windows[q], windows[q] + 100);
        if (!(err < -90.0)) cawtest::fail(__FILE__, __LINE__, "quality " + std::to_string(q) + ": " + std::to_string(err) + " dB");
    }
    const ModuleDescriptor* d = registry().find(kIris);
    CHECK(d && d->latencyFrames == 2048u);
}

TEST(iris_freezes_a_spectrum_and_holds_it_over_new_input_and_silence) {
    const Values live = {{"fade", 20}, {"drift", 0}};  // no phase dither: the frozen tone's level is steady
    Values frozen = live;
    frozen.emplace_back("freeze", 1);
    auto p = make(kIris, live);
    if (!p) return;
    run(*p, sine(440, 0.3, 48000), live);
    run(*p, sine(440, 0.3, 12000), frozen);  // the capture averages its first frames, all of 440 Hz
    const Stereo out = run(*p, sine(1000, 0.3, 48000), frozen);
    const double at440 = goertzelDb(out.l, 440, 9600, 48000), at1k = goertzelDb(out.l, 1000, 9600, 48000);
    if (!(at440 > -22.0 && at440 - at1k > 40.0)) cawtest::fail(__FILE__, __LINE__, "440 " + std::to_string(at440) + ", 1k " + std::to_string(at1k));
    const std::vector<float> d = display(*p);
    CHECK(d.size() == 9 + 3 * 64 && d[3] == 1.0f && d[2] == 1.0f);
    // The frozen spectrum's loudest band is the one holding 440 Hz.
    const size_t loud = std::max_element(d.begin() + 73, d.begin() + 137) - (d.begin() + 73);
    const double band = 64 * std::log(440.0 / 20.0) / std::log(1000.0);
    CHECK(std::fabs(static_cast<double>(loud) - band) <= 1.0);
    const Stereo after = run(*p, silence(48000 * 3), frozen, 512);
    CHECK(rms(after.l, 48000 * 2) > 0.01 && !p->quiet());
    // Freeze off: it fades out and the input comes back.
    const Stereo back = run(*p, sine(1000, 0.3, 48000), live);
    CHECK(goertzelDb(back.l, 1000, 24000, 48000) - goertzelDb(back.l, 440, 24000, 48000) > 30.0);
}

TEST(iris_freeze_averages_several_frames) {
    // Freeze on with 440 Hz playing, then 1 kHz a little after: one frame would hold only 440 Hz; the capture's
    // average over its frames holds both, and it completes only after those frames.
    const Values live = {{"fade", 20}, {"drift", 0}};
    Values frozen = live;
    frozen.emplace_back("freeze", 1);
    auto p = make(kIris, live);
    if (!p) return;
    run(*p, sine(440, 0.3, 48000), live);
    run(*p, sine(440, 0.3, 1024), frozen);
    CHECK(display(*p)[3] == 0.0f);  // still gathering
    run(*p, sine(1000, 0.3, 24000), frozen);
    const std::vector<float> d = display(*p);
    CHECK(d.size() == 9 + 3 * 64 && d[3] == 1.0f);
    const auto bandOf = [](double hz) { return static_cast<size_t>(64 * std::log(hz / 20.0) / std::log(1000.0)); };
    const float top = *std::max_element(d.begin() + 73, d.begin() + 137);
    const auto near = [&](double hz) {
        const size_t b = bandOf(hz);
        return std::max({d[73 + b - 1], d[73 + b], d[73 + b + 1]});
    };
    if (!(near(440) > top - 15.0f && near(1000) > top - 15.0f))
        cawtest::fail(__FILE__, __LINE__, "440 " + std::to_string(near(440)) + ", 1k " + std::to_string(near(1000)) + ", top " + std::to_string(top));
}

TEST(iris_paints_its_frozen_spectrum_through_its_state) {
    const Values frozen = {{"freeze", 1}, {"fade", 20}, {"drift", 0}};
    const Values live = {{"fade", 20}, {"drift", 0}};
    auto p = make(kIris, live);
    if (!p) return;
    run(*p, sine(440, 0.3, 24000), live);
    run(*p, sine(440, 0.3, 12000), frozen);
    std::vector<uint8_t> state(p->descriptor().maxStateBytes);
    uint32_t written = 0;
    CHECK(p->saveState(state.data(), static_cast<uint32_t>(state.size()), written) && written == 20 + 256 + 16 * 1025);
    state.resize(written);
    // A fresh instance, frozen from the state (no capture): the same 440 Hz over 1 kHz input.
    auto q = make(kIris, frozen);
    CHECK(q->loadState(state.data(), written, 1));
    const Stereo plain = run(*q, sine(1000, 0.3, 48000), frozen);
    if (!(goertzelDb(plain.l, 440, 9600, 48000) - goertzelDb(plain.l, 1000, 9600, 48000) > 40.0))
        cawtest::fail(__FILE__, __LINE__, "loaded: 440 " + std::to_string(goertzelDb(plain.l, 440, 9600, 48000)) + ", 1k " + std::to_string(goertzelDb(plain.l, 1000, 9600, 48000)) + ", rms " + std::to_string(rms(plain.l, 9600)));
    // Paint the bands around 440 Hz down 40 dB: the frozen tone drops by about that.
    std::vector<uint8_t> painted = state;
    for (int b = 26; b <= 31; ++b) {
        const float db = -40.0f;
        std::memcpy(painted.data() + 20 + 4 * b, &db, 4);
    }
    auto r = make(kIris, frozen);
    CHECK(r->loadState(painted.data(), written, 1));
    const Stereo dim = run(*r, sine(1000, 0.3, 48000), frozen);
    const double drop = goertzelDb(plain.l, 440, 9600, 48000) - goertzelDb(dim.l, 440, 9600, 48000);
    if (!(drop > 30.0 && drop < 45.0)) cawtest::fail(__FILE__, __LINE__, "painted down " + std::to_string(drop) + " dB");
    const std::vector<float> d = display(*r);
    CHECK(d.size() > 137 + 31 && d[137 + 28] == -40.0f);
    // Bad states are refused: a wrong magic, a short buffer, a window that is not a power of two.
    std::vector<uint8_t> bad = state;
    bad[0] ^= 1;
    CHECK(!r->loadState(bad.data(), written, 1));
    CHECK(!r->loadState(state.data(), written - 4, 1));
    bad = state;
    const uint32_t odd = 2000;
    std::memcpy(bad.data() + 12, &odd, 4);
    CHECK(!r->loadState(bad.data(), written, 1));
    CHECK(!r->loadState(state.data(), written, 2));
    // A state taken at another window plays at this one (resampled by frequency).
    auto hi = make(kIris, {{"freeze", 1}, {"fade", 20}, {"drift", 0}, {"quality", 2}});
    CHECK(hi->loadState(state.data(), written, 1));
    const Stereo h = run(*hi, sine(1000, 0.3, 48000), {{"freeze", 1}, {"fade", 20}, {"drift", 0}, {"quality", 2}});
    CHECK(goertzelDb(h.l, 440, 9600, 48000) - goertzelDb(h.l, 1000, 9600, 48000) > 30.0);
    // Nothing painted or captured: no state.
    auto none = make(kIris, {});
    CHECK(none->saveState(state.data(), static_cast<uint32_t>(state.size()), written) && written == 0);
}

TEST(iris_shift_gate_and_blur_do_their_jobs) {
    // Shift +200 Hz at Normal: 9 bins of 23.4 Hz, 1 kHz to 1210.9 Hz.
    Stereo out = render(kIris, {{"shift", 200}}, sine(1000, 0.3, 48000));
    CHECK(goertzelDb(out.l, 1000 + 9 * 48000.0 / 2048, 9600, 48000) - goertzelDb(out.l, 1000, 9600, 48000) > 30.0);
    CHECK(goertzelDb(out.l, 1000 + 9 * 48000.0 / 2048, 9600, 48000) > -20.0);
    // Gate -30 dB: low noise (-50 dB) goes, a loud tone stays.
    const Stereo quiet = noise(48000, 0.005);
    out = render(kIris, {{"gate", -30}}, quiet);
    CHECK(db(rms(out.l, 9600)) < db(rms(quiet.l, 9600)) - 30.0);
    const Stereo loud = sine(440, 0.5, 48000);
    out = render(kIris, {{"gate", -30}}, loud);
    CHECK(std::fabs(db(rms(out.l, 9600)) - db(rms(loud.l, 9600))) < 1.0);
    // Blur: a click's energy is spread over the following second.
    const Stereo c = click(48000, 4800);
    const Stereo plain = render(kIris, {}, c), blurred = render(kIris, {{"blur", 0.6}}, c);
    CHECK(rms(blurred.l, 4800 + 2048 + 4800, 48000) > 10.0 * rms(plain.l, 4800 + 2048 + 4800, 48000) + 1e-6);
}

TEST(iris_is_block_size_independent_and_survives_bad_input) {
    const Stereo in = music(48000);
    const Values all[] = {{}, {{"blur", 0.5}, {"gate", -40}}, {{"shift", -300}, {"quality", 0}}, {{"shift", 150}, {"quality", 2}, {"mix", 0.5}}};
    for (size_t k = 0; k < std::size(all); ++k) {
        checkBlockSizes(kIris, all[k], in, "iris " + std::to_string(k));
        checkBadInput(kIris, all[k], "iris " + std::to_string(k));
    }
    // Frozen (a fresh instance each time: a reset keeps the frozen spectrum, which is state).
    const Values frozen = {{"freeze", 1}, {"drift", 0.7}, {"shift", 100}};
    const Stereo want = render(kIris, frozen, in, 64);
    for (uint32_t block : {1u, 37u, 512u}) CHECK(same(want, render(kIris, frozen, in, block)));
    // NaN into a frozen Molt: finite throughout.
    Stereo bad = music(9600);
    bad.l[100] = std::nanf("");
    bad.r[300] = INFINITY;
    CHECK(finite(render(kIris, {{"freeze", 1}, {"blur", 0.4}}, bad)));
}

TEST(iris_presets_render) { checkPackPresets(kIris, 8, music(48000 * 2)); }

TEST(iris_matches_its_reference_renders) {
    const Stereo in = music(48000 * 2);
    cawtest::References refs("pack_iris");
    auto check = [&](const char* name, const Values& v) {
        const Stereo out = render(kIris, v, in);
        CHECK_REFERENCE(refs, name, (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
    };
    check("iris_freeze", {{"freeze", 1}, {"fade", 100}});
    check("iris_blur_shift_gate", {{"blur", 0.4}, {"shift", 120}, {"gate", -50}});
}
