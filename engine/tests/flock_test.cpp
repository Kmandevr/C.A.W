// Flock (org.caw.flock, 1.1.0): registration and presets, the built-in tones, a sample from the asset store, key tracking, overlap-add reconstruction, mips, caps, freeze, block sizes, bad values, display and references.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "asset_store.h"
#include "builtin_flock.h"
#include "presets.h"
#include "test.h"
#include "timber_harness.h"
#include "tolerance.h"

using namespace caw;
using timber_test::Note;
using timber_test::Stereo;
using timber_test::Values;

namespace {

constexpr const char* kFlock = "org.caw.flock";

std::unique_ptr<ModuleProcessor> make(const Values& v, const std::string& path = "", int tier = kQualityNormal) {
    static std::atomic<int> tiers[3] = {kQualityEco, kQualityNormal, kQualityHigh};
    const BuildingQuality building(&tiers[tier]);
    std::unique_ptr<ModuleProcessor> p = createComponent(timber_test::registry(), kFlock, v);
    if (!p) return p;
    if (!path.empty()) {
        const std::string state = "{\"path\":\"" + path + "\"}";
        if (!p->loadState(reinterpret_cast<const uint8_t*>(state.data()), static_cast<uint32_t>(state.size()), 1)) p.reset();
    }
    if (p && !p->activate(48000, 512)) p.reset();
    return p;
}

Stereo playF(ModuleProcessor& p, const Values& v, const std::vector<Note>& n, double seconds, uint32_t block = 64) {
    return timber_test::play(p, v, n, seconds, 48000, block);
}

// A 16-bit stereo WAV's bytes.
std::vector<uint8_t> wav(const std::vector<float>& l, const std::vector<float>& r) {
    const uint32_t frames = static_cast<uint32_t>(l.size()), align = 4;
    std::vector<uint8_t> w;
    auto u32 = [&](uint32_t v) { for (int k = 0; k < 4; ++k) w.push_back(static_cast<uint8_t>(v >> (8 * k))); };
    auto u16 = [&](uint32_t v) { for (int k = 0; k < 2; ++k) w.push_back(static_cast<uint8_t>(v >> (8 * k))); };
    w.insert(w.end(), {'R', 'I', 'F', 'F'});
    u32(36 + frames * align);
    w.insert(w.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
    u32(16), u16(1), u16(2), u32(48000), u32(48000 * align), u16(align), u16(16);
    w.insert(w.end(), {'d', 'a', 't', 'a'});
    u32(frames * align);
    for (uint32_t i = 0; i < frames; ++i) {
        u16(static_cast<uint32_t>(static_cast<int16_t>(std::lround(std::clamp(l[i], -1.0f, 1.0f) * 32767.0))));
        u16(static_cast<uint32_t>(static_cast<int16_t>(std::lround(std::clamp(r[i], -1.0f, 1.0f) * 32767.0))));
    }
    return w;
}

// A sample in the asset store ("mem:" + name), and its frames as decoded.
Stereo loadSample(const std::string& name, const std::vector<float>& l, const std::vector<float>& r) {
    const std::vector<uint8_t> bytes = wav(l, r);
    std::string error;
    auto a = AssetStore::global().loadBytes(name, bytes.data(), bytes.size(), 48000, error);
    Stereo s;
    if (!a) {
        cawtest::fail(__FILE__, __LINE__, "could not load " + name + ": " + error);
        return s;
    }
    s.l.assign(a->channel(0), a->channel(0) + a->frames);
    s.r.assign(a->channel(1), a->channel(1) + a->frames);
    return s;
}

// Music-like test material: a few partials and a little noise, different in each side.
Stereo music(size_t n) {
    std::vector<float> l(n), r(n);
    uint32_t seed = 7;
    for (size_t i = 0; i < n; ++i) {
        const double t = i / 48000.0;
        seed = seed * 1664525u + 1013904223u;
        const double noise = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * 0.03;
        l[i] = static_cast<float>(0.3 * std::sin(2 * timber_test::kPi * 220 * t) + 0.15 * std::sin(2 * timber_test::kPi * 1310 * t) + noise);
        r[i] = static_cast<float>(0.3 * std::sin(2 * timber_test::kPi * 330 * t) + 0.1 * std::sin(2 * timber_test::kPi * 2750 * t) - noise);
    }
    Stereo s;
    s.l = l, s.r = r;
    return s;
}

std::vector<float> display(ModuleProcessor& p) {
    std::vector<float> d(1024);
    d.resize(p.readDisplay(d.data(), 1024));
    return d;
}

bool same(const Stereo& a, const Stereo& b) { return a.l == b.l && a.r == b.r; }
bool finite(const Stereo& s) {
    for (size_t i = 0; i < s.size(); ++i)
        if (!std::isfinite(s.l[i]) || !std::isfinite(s.r[i])) return false;
    return true;
}
double peak(const Stereo& s, size_t from = 0) {
    double p = 0;
    for (size_t i = from; i < s.size(); ++i) p = std::max({p, std::fabs(double(s.l[i])), std::fabs(double(s.r[i]))});
    return p;
}

}  // namespace

TEST(flock_is_a_medium_instrument_with_its_presets) {
    const ModuleDescriptor* d = timber_test::registry().find(kFlock);
    CHECK(d != nullptr);
    if (!d) return;
    CHECK(d->role == ModuleRole::Instrument);
    CHECK(d->cpuClass == CpuClass::Medium);
    CHECK_EQ(d->parameterCount, 33u);
    const auto& presets = builtinPresets(kFlock);
    CHECK(presets.size() >= 8u);
    for (const BuiltinPreset& pr : presets) {
        Values v;
        for (const auto& [k, x] : pr.values) v.emplace_back(std::string(k), x);
        auto p = make(v);
        CHECK(p != nullptr);
        if (!p) continue;
        const Stereo s = playF(*p, v, {{0.0, 0.6, 60, 0.8}, {0.1, 0.6, 67, 0.6}}, 1.0);
        const double pk = peak(s);
        if (!(finite(s) && pk > 0.01 && pk < 2.0))
            cawtest::fail(__FILE__, __LINE__, std::string(pr.name) + ": peak " + std::to_string(pk));
    }
}

TEST(flock_plays_each_built_in_tone_in_tune_with_key_tracking) {
    // Glass's lowest partial is middle C: key 60 plays it, key 72 an octave up, key tracking 0 holds it.
    for (int kind = 0; kind < 4; ++kind) {
        const Values v = {{"builtin", kind}};
        auto p = make(v);
        const Stereo s = playF(*p, v, {{0.0, 0.8, 60, 0.8}}, 1.0);
        CHECK(peak(s) > 0.05);
        const std::vector<float> d = display(*p);
        CHECK(d.size() >= 12u && d[5] == kind + 1 && std::fabs(d[7] - 2.0f) < 1e-6f);
    }
    // Each grain's pitch (the display's) is pitch + keytrack x (key - root); the cloud's spectrum moves with it.
    auto run = [](double key, double keytrack, double root, double& semis) {
        const Values v = {{"builtin", 0}, {"spread", 0}, {"keytrack", keytrack}, {"root", root}, {"pitch", 2}};
        auto p = make(v);
        const Stereo s = playF(*p, v, {{0.0, -1, key, 0.8}}, 0.6);
        const std::vector<float> d = display(*p);
        semis = d.size() > 44 && d[11] > 0 ? d[44 + 3] : 1e9;
        return timber_test::centroid(s.mono(), 9600, 16384, 48000, 6000);
    };
    double a, b, c, e;
    const double c60 = run(60, 1, 60, a), c72 = run(72, 1, 60, b);
    run(67, 0.5, 60, c), run(72, 0, 60, e);
    CHECK(std::fabs(a - 2) < 1e-4 && std::fabs(b - 14) < 1e-4 && std::fabs(c - 5.5) < 1e-4 && std::fabs(e - 2) < 1e-4);
    double f;
    run(72, 1, 72, f);
    CHECK(std::fabs(f - 2) < 1e-4);
    if (timber_test::verbose()) std::printf("centroid key 60 %.0f Hz, key 72 %.0f Hz\n", c60, c72);
    CHECK(c72 > 1.6 * c60 && c72 < 2.6 * c60);  // about an octave (the spectrum is a cloud, not one line)
}

TEST(flock_reconstructs_its_sample_with_hann_grains_at_half_overlap) {
    // Size 20 ms (960 frames), density 100 Hz (480, a whole number of control periods), Hann, no spray, jitter, pan,
    // pitch or filter, scan 1 (real time): the grains overlap-add to the sample itself, from the note on (from its
    // second frame: a sample is read in place, its first frame only there for the cubic read before frame 0).
    const Stereo in = music(48000);
    const Stereo dec = loadSample("flock_recon", in.l, in.r);
    const Values v = {{"size", 20}, {"density", 100}, {"spray", 0}, {"jitter", 0}, {"pan", 0}, {"position", 0}, {"scan", 1},
                      {"filter", 0}, {"keytrack", 0}, {"velocity", 0}, {"attack", 0.001}, {"sustain", 1}};
    for (int tier : {1, 2}) {
        auto p = make(v, "mem:flock_recon", tier);
        const Stereo out = playF(*p, v, {{0.0, -1, 60, 1.0}}, 0.6);
        CHECK_EQ(display(*p)[5], 0.0f);  // the sample, not a built-in
        double err = 0, sig = 0;
        for (size_t i = 960; i < 24000; ++i) {
            err += std::pow(out.l[i] - dec.l[i + 1], 2) + std::pow(out.r[i] - dec.r[i + 1], 2);
            sig += std::pow(dec.l[i], 2) + std::pow(dec.r[i], 2);
        }
        const double db = 10 * std::log10(err / sig + 1e-30);
        if (!(db < -80.0)) cawtest::fail(__FILE__, __LINE__, "tier " + std::to_string(tier) + ": error " + std::to_string(db) + " dB");
    }
}

TEST(flock_reads_its_half_band_mips_more_than_an_octave_up) {
    // A 9 kHz tone read two octaves up would sound at 36 kHz, folding to 12 kHz; the second mip copy has filtered it
    // out. A 2 kHz tone two octaves up still sounds at 8 kHz.
    auto level = [](const char* name, double toneHz, double pitch, double hz) {
        std::vector<float> tone(96000);
        for (size_t i = 0; i < tone.size(); ++i) tone[i] = static_cast<float>(0.5 * std::sin(2 * timber_test::kPi * toneHz * i / 48000.0));
        loadSample(name, tone, tone);
        const Values v = {{"pitch", pitch}, {"keytrack", 0}, {"spray", 0}, {"size", 60}, {"density", 40}, {"filter", 0}, {"pan", 0}};
        auto p = make(v, std::string("mem:") + name);
        const Stereo s = playF(*p, v, {{0.0, -1, 60, 1.0}}, 1.0);
        return timber_test::bandDb(s.mono(), hz, 9600, 32768, 48000);
    };
    const double direct = level("flock_alias", 9000, 0, 9000), aliased = level("flock_alias", 9000, 24, 12000);
    const double low = level("flock_low", 2000, 0, 2000), up = level("flock_low", 2000, 24, 8000);
    if (timber_test::verbose()) std::printf("9 kHz %.1f dB, two octaves up at 12 kHz %.1f dB; 2 kHz %.1f dB, up at 8 kHz %.1f dB\n", direct, aliased, low, up);
    CHECK(direct > -45);
    CHECK(aliased < direct - 60);
    CHECK(up > low - 10);
}

TEST(flock_shares_one_grain_pool_between_its_voices_and_keeps_its_voice_cap) {
    // 16 voices of dense long grains: the pool holds the tier's cap and counts what it drops.
    Values v = {{"voices", 16}, {"size", 400}, {"density", 120}};
    std::vector<Note> n;
    for (int i = 0; i < 16; ++i) n.push_back({0.01 * i, -1, 40.0 + 2 * i, 0.7});
    for (int tier : {0, 1}) {
        auto p = make(v, "", tier);
        uint32_t most = 0, dropped = 0;
        for (double t = 0.2; t <= 1.0; t += 0.2) {
            // play on in steps, reading the display
            const Stereo s = playF(*p, v, t == 0.2 ? n : std::vector<Note>{}, 0.2);
            const std::vector<float> d = display(*p);
            most = std::max(most, static_cast<uint32_t>(d[1]));
            dropped += static_cast<uint32_t>(d[3]);
            CHECK(d[1] <= d[2]);
            CHECK(d[2] == (tier == 0 ? 64.0f : 128.0f));
            CHECK_EQ(d.size(), static_cast<size_t>(12 + 32 + 5 * d[11]));
            for (uint32_t g = 0; g < static_cast<uint32_t>(d[11]); ++g) {
                const float* o = d.data() + 44 + 5 * g;
                CHECK(o[0] >= 0 && o[0] <= 1 && o[1] >= 0 && o[1] <= 1 && o[4] < 20);
            }
        }
        CHECK_EQ(most, tier == 0 ? 64u : 128u);
        CHECK(dropped > 0);
    }
    // A cap of 4 voices: ten notes leave at most 4 sounding (and one fading).
    v = {{"voices", 4}};
    auto p = make(v);
    std::vector<Note> ten;
    for (int i = 0; i < 10; ++i) ten.push_back({0.05 * i, -1, 48.0 + 3 * i, 0.8});
    const Stereo s = playF(*p, v, ten, 0.6);
    CHECK(display(*p)[4] <= 4.0f);
    CHECK(finite(s));
}

TEST(flock_freeze_holds_the_position_while_scan_moves_it) {
    const Values held = {{"freeze", 1}, {"scan", 1}}, still = {{"freeze", 0}, {"scan", 0}}, moving = {{"freeze", 0}, {"scan", 1}};
    auto a = make(held), b = make(still), c = make(moving);
    const std::vector<Note> n = {{0.0, -1, 60, 0.8}};
    const Stereo x = playF(*a, held, n, 0.8), y = playF(*b, still, n, 0.8), z = playF(*c, moving, n, 0.8);
    CHECK(same(x, y));
    CHECK(!same(y, z));
}

TEST(flock_renders_the_same_bits_at_any_block_size) {
    const Stereo in = music(48000);
    loadSample("flock_blocks", in.l, in.r);
    const std::vector<Note> n = {{0.0, 0.4, 48, 0.8}, {0.013, 0.31, 64, 0.5}, {0.2, -1, 71.3, 1.0}, {0.35, 0.6, 55, 0.3}};
    for (const std::string& path : {std::string(), std::string("mem:flock_blocks")}) {
        const Values v = {{"spread", 7}, {"reverse", 0.3}, {"scan", 0.5}, {"glide", 80}, {"filter_env", 2}, {"pitch", 14}};
        Stereo ref;
        for (uint32_t block : {64u, 1u, 37u, 512u}) {
            auto p = make(v, path);
            const Stereo s = playF(*p, v, n, 0.8, block);
            if (block == 64) ref = s;
            else if (!same(ref, s)) cawtest::fail(__FILE__, __LINE__, "differs at block " + std::to_string(block) + (path.empty() ? " (built-in)" : " (sample)"));
        }
        CHECK(peak(ref) > 0.01);
    }
}

TEST(flock_falls_quiet_to_exact_zeros_and_survives_bad_values) {
    const Values v = {{"release", 0.05}};
    auto p = make(v);
    double quietAt = -1;
    const Stereo s = timber_test::play(*p, v, {{0.0, 0.2, 60, 1.0}}, 2.0, 48000, 64, {}, &quietAt);
    CHECK(quietAt > 0.2 && quietAt < 1.5);
    bool zeros = true;
    for (size_t i = 72000; i < s.size(); ++i) zeros = zeros && s.l[i] == 0.0f && s.r[i] == 0.0f;
    CHECK(zeros);
    // NaN and infinite knobs, extreme pitches, a NaN in the sample: finite output.
    std::vector<float> l(4800, 0.2f), r(4800, -0.2f);
    l[100] = NAN, r[2000] = INFINITY;
    loadSample("flock_bad", l, r);
    const Values bad = {{"position", NAN}, {"size", INFINITY}, {"density", NAN}, {"pitch", INFINITY}, {"cutoff", NAN},
                        {"resonance", -INFINITY}, {"level", NAN}, {"attack", NAN}, {"spread", NAN}, {"scan", INFINITY}};
    for (const std::string& path : {std::string(), std::string("mem:flock_bad")}) {
        auto q = make(bad, path);
        const Stereo b = playF(*q, bad, {{0.0, 0.1, 127.9, 1.0}, {0.0, 0.1, 0.0, 1.0}}, 0.4);
        CHECK(finite(b));
    }
    // Denormal-small input knobs and a quiet sample: nothing blows up and the output is finite.
    std::vector<float> tiny(4800, 1e-30f);
    loadSample("flock_tiny", tiny, tiny);
    auto t = make({{"filter", 3}, {"resonance", 20}}, "mem:flock_tiny");
    CHECK(finite(playF(*t, {{"filter", 3}, {"resonance", 20}}, {{0.0, 0.3, 60, 1.0}}, 0.5)));
}

TEST(flock_keeps_its_state_and_falls_back_to_its_built_in_tone) {
    // A named sample that is not there plays the built-in tone and says so.
    auto p = make({}, "/no/such/flock.wav");
    CHECK(p != nullptr);
    if (!p) return;
    CHECK(peak(playF(*p, {}, {{0.0, 0.3, 60, 0.8}}, 0.5)) > 0.01);
    const std::vector<float> d = display(*p);
    CHECK(d[5] == 1.0f && d[6] == 1.0f);
    uint8_t buf[256];
    uint32_t written = 0;
    CHECK(p->saveState(buf, sizeof buf, written));
    CHECK_EQ(std::string(reinterpret_cast<char*>(buf), written), std::string("{\"path\":\"/no/such/flock.wav\"}"));
    const std::string junk = "[1,2]", big = "{\"path\":" + std::string(5000, '"') + "}";
    CHECK(!p->loadState(reinterpret_cast<const uint8_t*>(junk.data()), static_cast<uint32_t>(junk.size()), 1));
    CHECK(!p->loadState(reinterpret_cast<const uint8_t*>(junk.data()), static_cast<uint32_t>(junk.size()), 2));
}

TEST(flock_matches_its_reference_renders) {
    const Stereo in = music(48000);
    loadSample("flock_ref", in.l, in.r);
    cawtest::References refs("flock");
    auto check = [&](const char* name, const Values& v, const std::string& path) {
        auto p = make(v, path);
        const Stereo s = playF(*p, v, {{0.0, 0.5, 48, 0.9}, {0.1, 0.6, 55, 0.6}, {0.2, 0.9, 64, 0.75}, {0.3, 0.7, 76, 0.4}}, 1.4);
        CHECK_REFERENCE(refs, name, (cawtest::Audio{s.l, s.r}), cawtest::Class::Chaotic);
    };
    check("flock_strings", {}, "");
    check("flock_glass_scatter", {{"builtin", 1}, {"spread", 12}, {"scale", 5}, {"reverse", 0.4}, {"pan", 0.8}, {"spray", 150}}, "");
    check("flock_choir_filtered", {{"builtin", 3}, {"filter", 1}, {"filter_env", 3}, {"cutoff", 800}, {"resonance", 3}, {"scan", 0.3}}, "");
    check("flock_sample_up", {{"pitch", 19}, {"size", 50}, {"density", 60}, {"window", 3}, {"glide", 50}}, "mem:flock_ref");
}
