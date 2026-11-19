// The AutoStacc beta pack: the grain engine (overlap-add, cap, seeding) and Murmur, Peck, Bend and Iris (their sound, pack mark, display, block sizes, bad input, presets and reference renders).
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_pack.h"
#include "caw/library/grain.hpp"
#include "engine.h"
#include "fx_modes_harness.h"
#include "quality.h"
#include "tolerance.h"

using namespace caw;
using namespace modes_test;

namespace {

constexpr const char* kMurmur = "org.caw.pack.granular";

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
    for (const char* id : {kMurmur}) {
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
