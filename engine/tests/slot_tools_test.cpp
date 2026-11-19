// Per-slot auto gain and output meters (1.0.8, API 39): the trim matches loudness, holds on silence, is off bit-exactly, repeats from Play; the meter's peaks and clip flag.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "builtin_components.h"
#include "caw.h"
#include "component_chain.h"
#include "engine.h"
#include "json.h"
#include "project.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

namespace {

const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        return x;
    }();
    return r;
}

ComponentSpec utility(double gainDb, bool autoGain) {
    ComponentSpec s;
    s.id = "org.caw.utility";
    s.params = {{"gain", gainDb}};
    s.autoGain = autoGain;
    return s;
}

struct Stereo {
    std::vector<float> l, r;
};

// Pink-ish noise with a slow level swing: music-like loudness that is not a steady tone.
Stereo program(size_t frames, double level = 0.2, uint32_t seed = 3) {
    Stereo s{std::vector<float>(frames), std::vector<float>(frames)};
    double b = 0;
    for (size_t i = 0; i < frames; ++i) {
        seed = seed * 1664525u + 1013904223u;
        const double w = static_cast<double>(seed >> 8) / 8388608.0 - 1.0;
        b = 0.97 * b + 0.03 * w * 6.0;
        const double swing = 0.75 + 0.25 * std::sin(6.283185307179586 * 0.5 * i / 48000.0);
        s.l[i] = static_cast<float>(level * swing * (0.6 * w + b));
        s.r[i] = static_cast<float>(level * swing * (0.6 * w - b));
    }
    return s;
}

Stereo render(ComponentChain& chain, const Stereo& in, uint32_t block = 64, const ChainTime* time = nullptr) {
    Stereo out = in;
    for (size_t start = 0; start < in.l.size(); start += block) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(block, in.l.size() - start));
        chain.process(out.l.data() + start, out.r.data() + start, n, 48000.0, time);
    }
    return out;
}

double rmsDb(const std::vector<float>& v, size_t from, size_t to) {
    double e = 0;
    for (size_t i = from; i < to; ++i) e += static_cast<double>(v[i]) * v[i];
    return 10.0 * std::log10(std::max(e / static_cast<double>(to - from), 1e-30));
}

std::unique_ptr<ComponentChain> build(const std::vector<ComponentSpec>& specs) {
    std::string error;
    auto chain = ComponentChain::build(registry(), specs, 48000.0, error);
    if (!chain) cawtest::fail(__FILE__, __LINE__, error);
    return chain;
}

bool same(const Stereo& a, const Stereo& b, size_t from = 0) {
    return std::memcmp(a.l.data() + from, b.l.data() + from, (a.l.size() - from) * 4) == 0 &&
           std::memcmp(a.r.data() + from, b.r.data() + from, (a.r.size() - from) * 4) == 0;
}

}  // namespace

TEST(auto_gain_trims_a_6_db_boost_back_to_the_input_loudness) {
    for (double gain : {6.0, -9.0}) {
        auto chain = build({utility(gain, true)});
        if (!chain) return;
        const Stereo in = program(48000 * 12);
        const Stereo out = render(*chain, in);
        float trim = 99;
        CHECK(chain->autoGainDb(0, trim));
        CHECK_NEAR(trim, -gain, 0.1);
        // The last 3 s: as loud as the input (loudness, not peaks), within a fraction of a dB.
        const size_t from = 48000 * 9, to = in.l.size();
        CHECK_NEAR(rmsDb(out.l, from, to) - rmsDb(in.l, from, to), 0.0, 0.2);
    }
    // Clamped to +-24 dB: a -40 dB effect is lifted by 24 at most.
    auto quiet = build({utility(-40.0, true)});
    if (!quiet) return;
    render(*quiet, program(48000 * 15));
    float trim = 0;
    CHECK(quiet->autoGainDb(0, trim));
    CHECK_NEAR(trim, 24.0, 1e-4);
}

TEST(auto_gain_holds_on_silence_and_never_pumps_it_up) {
    auto chain = build({utility(6.0, true)});
    if (!chain) return;
    const Stereo silence{std::vector<float>(48000 * 5), std::vector<float>(48000 * 5)};
    const Stereo out = render(*chain, silence);
    float trim = 1;
    CHECK(chain->autoGainDb(0, trim));
    CHECK_EQ(trim, 0.0f);  // silence from the start: exactly 0 dB
    for (float x : out.l) CHECK_EQ(x, 0.0f);
    render(*chain, program(48000 * 10));
    CHECK(chain->autoGainDb(0, trim));
    const float settled = trim;
    CHECK_NEAR(settled, -6.0, 0.15);
    // Then 20 s of silence, and a device that falls near silent: the trim stays where it was.
    render(*chain, Stereo{std::vector<float>(48000 * 20), std::vector<float>(48000 * 20)});
    CHECK(chain->autoGainDb(0, trim));
    CHECK_NEAR(trim, settled, 0.05);
    auto gate = build({utility(-60.0, true)});  // everything at -60 dB and below the floor: no +24 dB lift
    if (!gate) return;
    render(*gate, program(48000 * 10, 0.01));
    CHECK(gate->autoGainDb(0, trim));
    CHECK_EQ(trim, 0.0f);
}

TEST(auto_gain_off_is_bit_identical_and_turning_it_off_restores_the_bits) {
    // A compressor chain with auto gain off renders exactly as the effect itself does (nothing added).
    ComponentSpec comp;
    comp.id = "org.caw.compressor";
    comp.params = {{"threshold", -30}, {"ratio", 4}};
    const Stereo in = program(48000 * 3);
    auto plain = build({comp, utility(3.0, false)});
    if (!plain) return;
    const Stereo want = render(*plain, in);
    ComponentSpec compOn = comp;
    compOn.autoGain = true;
    auto toggled = build({compOn, utility(3.0, false)});
    if (!toggled) return;
    // On for the first second, then off: from the block it goes off, the same bits as never on.
    Stereo got = in;
    const size_t split = 48000;
    for (size_t start = 0; start < in.l.size(); start += 64) {
        if (start == split) CHECK(toggled->setAutoGain(0, false));
        toggled->process(got.l.data() + start, got.r.data() + start, 64, 48000.0, nullptr);
    }
    CHECK(!same(want, got));  // it did trim while on
    // and not once its trim has ramped back to unity (AutoGainMatcher::release: 10 ms, so turning it off can't click)
    CHECK(same(want, got, split + AutoGainMatcher::fadeFrames(48000.0)));
    float trim = 5;
    CHECK(toggled->autoGainDb(0, trim));
    CHECK_EQ(trim, 0.0f);  // off reads 0
    CHECK(!toggled->setAutoGain(7, true));
    // The spec round trip keeps the flag (a rebuild, a state change).
    CHECK(toggled->setAutoGain(1, true));
    const std::vector<ComponentSpec> specs = toggled->currentSpecs();
    CHECK(!specs[0].autoGain && specs[1].autoGain);
}

TEST(auto_gain_is_the_same_at_any_block_size_and_repeats_from_play) {
    const Stereo in = program(48000 * 4);
    auto a = build({utility(6.0, true)});
    auto b = build({utility(6.0, true)});
    if (!a || !b) return;
    const Stereo x = render(*a, in, 64);
    const Stereo y = render(*b, in, 37);
    CHECK(same(x, y));
    // A new Play starts it from 0 dB again: the same render as a fresh chain's.
    ChainTime t;
    t.playEpoch = 1;
    auto c = build({utility(6.0, true)});
    if (!c) return;
    render(*c, program(48000 * 2, 0.3, 9), 64, &t);  // something else first
    t.playEpoch = 2;
    ChainTime fresh;
    fresh.playEpoch = 1;
    auto d = build({utility(6.0, true)});
    if (!d) return;
    // (c's trim was not 0 dB at the new Play: its first 10 ms ramp from that gain, so the tails don't click.)
    CHECK(same(render(*c, in, 64, &t), render(*d, in, 64, &fresh), AutoGainMatcher::fadeFrames(48000.0)));
    // Bypassed, the slot plays its input untrimmed (after its 5 ms crossfade).
    CHECK(a->setBypass(0, true));
    const Stereo z = render(*a, in, 64);
    CHECK(std::memcmp(in.l.data() + 4800, z.l.data() + 4800, (in.l.size() - 4800) * 4) == 0);
}

namespace {
// A 1 kHz cosine: a peak every 48 frames, so a gain step on one of those frames shows as a jump between samples.
Stereo cosine(size_t frames, double level = 0.1) {
    Stereo s{std::vector<float>(frames), std::vector<float>(frames)};
    for (size_t i = 0; i < frames; ++i)
        s.l[i] = s.r[i] = static_cast<float>(level * std::cos(6.283185307179586 * 1000.0 * static_cast<double>(i) / 48000.0));
    return s;
}
double largestStep(const std::vector<float>& v, size_t from, size_t to) {
    double most = 0;
    for (size_t i = from + 1; i < to; ++i) most = std::max(most, std::fabs(static_cast<double>(v[i]) - v[i - 1]));
    return most;
}
}  // namespace

TEST(auto_gain_turned_off_while_playing_ramps_its_trim_to_unity_without_a_click) {
    // Settled at about -6 dB after a +6 dB utility, then turned off on a peak of the cosine: a jump to 0 dB in one
    // sample would step by 0.1 there, while the 0.2 cosine itself moves at most 0.2 * 2 pi / 48 = 0.026 a sample.
    const size_t frames = 48000 * 11, split = 48000 * 10;
    const Stereo in = cosine(frames);
    auto chain = build({utility(6.0, true)});
    if (!chain) return;
    Stereo got = in;
    for (size_t start = 0; start < frames; start += 64) {
        if (start == split) {
            float trim = 0;
            CHECK(chain->autoGainDb(0, trim));
            CHECK_NEAR(trim, -6.0, 0.2);
            CHECK(chain->setAutoGain(0, false));
        }
        chain->process(got.l.data() + start, got.r.data() + start, 64, 48000.0, nullptr);
    }
    CHECK(largestStep(got.l, split - 960, split + 960) < 0.03);
    const uint32_t fade = AutoGainMatcher::fadeFrames(48000.0);
    CHECK_EQ(fade % AutoGainMatcher::kGrid, 0u);  // on its grid
    CHECK(fade >= 480u && fade < 480u + AutoGainMatcher::kGrid);
    CHECK_NEAR(got.l[split + fade / 2] / in.l[split + fade / 2], 2.0 * (0.5 + 0.5 * 0.5), 0.05);  // halfway there
    auto plain = build({utility(6.0, false)});
    if (!plain) return;
    CHECK(same(render(*plain, in), got, split + fade));  // then exactly as never on
    // On again before the ramp ends: from the gain it had reached, not from 0 dB at once.
    auto again = build({utility(6.0, true)});
    if (!again) return;
    Stereo flip = in;
    for (size_t start = 0; start < frames; start += 64) {
        if (start == split) CHECK(again->setAutoGain(0, false));
        if (start == split + 192) CHECK(again->setAutoGain(0, true));
        again->process(flip.l.data() + start, flip.r.data() + start, 64, 48000.0, nullptr);
    }
    CHECK(largestStep(flip.l, split - 960, split + 1920) < 0.03);
}

TEST(auto_gain_ramps_from_its_trim_at_a_new_play_while_tails_sound) {
    const size_t frames = 48000 * 10;
    const Stereo in = cosine(frames + 48000);
    const Stereo first{std::vector<float>(in.l.begin(), in.l.begin() + frames), std::vector<float>(in.r.begin(), in.r.begin() + frames)};
    const Stereo then{std::vector<float>(in.l.begin() + frames, in.l.end()), std::vector<float>(in.r.begin() + frames, in.r.end())};
    ChainTime t;
    t.playEpoch = 1;
    auto c = build({utility(6.0, true)});
    if (!c) return;
    const Stereo before = render(*c, first, 64, &t);
    t.playEpoch = 2;  // Play again: the tails still sound
    const Stereo after = render(*c, then, 64, &t);
    // No jump from the -6 dB trim to 0 dB at the Play: the first frame after it is still about as loud as before.
    CHECK_NEAR(after.l[0], before.l.back() * (then.l[0] / first.l.back()), 0.01);
    std::vector<float> joined(before.l.end() - 960, before.l.end());
    joined.insert(joined.end(), after.l.begin(), after.l.begin() + 960);
    CHECK(largestStep(joined, 0, joined.size()) < 0.03);
    // After the ramp, the render repeats from Play: as a fresh chain's.
    ChainTime fresh;
    fresh.playEpoch = 1;
    auto d = build({utility(6.0, true)});
    if (!d) return;
    CHECK(same(render(*d, then, 64, &fresh), after, AutoGainMatcher::fadeFrames(48000.0)));
}

TEST(auto_gain_over_an_effect_that_sleeps_is_the_same_at_any_block_size) {
    // Program with gaps of 300 ms (the utility sleeps after 50 ms of silence): while it sleeps the chain skips it,
    // and its matcher must advance its grid and decay over those frames as if it had heard their silence.
    Stereo in = program(48000 * 6);
    for (size_t i = 0; i < in.l.size(); ++i)
        if ((i / 4800) % 8 >= 5) in.l[i] = in.r[i] = 0.0f;  // 0.5 s on, 0.3 s off
    auto make = [] { return build({utility(6.0, true)}); };
    auto a = make();
    if (!a) return;
    const Stereo want = render(*a, in, 64);
    float trimA = 0;
    CHECK(a->autoGainDb(0, trimA));
    CHECK(trimA < -1.0f);  // it did trim
    for (uint32_t block : {37u, 16u, 1u}) {
        auto b = make();
        if (!b) return;
        const Stereo got = render(*b, in, block);
        if (!same(want, got)) cawtest::fail(__FILE__, __LINE__, "block " + std::to_string(block) + " differs");
        float trimB = 0;
        CHECK(b->autoGainDb(0, trimB));
        CHECK_EQ(trimA, trimB);
    }
}

TEST(per_note_fx_and_instruments_ignore_auto_gain) {
    // "auto_gain" is read on any component entry, but only a track's or the master's effect chain has the trim.
    std::string error;
    auto noteFx = ComponentChain::buildNoteEffects(registry(), {utility(6.0, true)}, 48000.0, error);
    CHECK(noteFx != nullptr);
    if (!noteFx) return;
    auto plain = ComponentChain::buildNoteEffects(registry(), {utility(6.0, false)}, 48000.0, error);
    if (!plain) return;
    const Stereo in = program(48000 * 5);
    CHECK(same(render(*noteFx, in), render(*plain, in)));  // untrimmed: still +6 dB
    float trim = 1;
    CHECK(noteFx->autoGainDb(0, trim));
    CHECK_EQ(trim, 0.0f);
    CHECK(!noteFx->setAutoGain(0, true));  // and it can't be turned on
    CHECK(!noteFx->currentSpecs()[0].autoGain);
    ComponentSpec osc;
    osc.id = "org.caw.test.osc";
    osc.autoGain = true;
    auto inst = ComponentChain::buildInstrument(registry(), osc, 48000.0, error);
    CHECK(inst != nullptr);
    if (!inst) return;
    CHECK(!inst->setAutoGain(0, true));
    CHECK(!inst->currentSpecs()[0].autoGain);
    CHECK(inst->autoGainDb(0, trim));
    CHECK_EQ(trim, 0.0f);
}

TEST(slot_meters_read_each_sides_peak_and_a_sticky_clip_then_reset) {
    auto chain = build({utility(0.0, false), utility(12.0, false)});
    if (!chain) return;
    Stereo in{std::vector<float>(4800, 0.0f), std::vector<float>(4800, 0.0f)};
    for (size_t i = 0; i < in.l.size(); ++i) {
        in.l[i] = static_cast<float>(0.5 * std::sin(6.283185307179586 * 100.0 * i / 48000.0));
        in.r[i] = 0.5f * in.l[i];
    }
    render(*chain, in);
    float l = 0, r = 0;
    bool clipped = false;
    CHECK(chain->readSlotMeter(0, l, r, clipped));
    CHECK_NEAR(l, 0.5, 1e-3);
    CHECK_NEAR(r, 0.25, 1e-3);
    CHECK(!clipped);
    CHECK(chain->readSlotMeter(1, l, r, clipped));
    CHECK_NEAR(l, 0.5 * std::pow(10.0, 12.0 / 20.0), 0.01);  // +12 dB: over full scale
    CHECK(clipped);
    CHECK(chain->readSlotMeter(1, l, r, clipped));  // read: reset
    CHECK_EQ(l, 0.0f);
    CHECK(!clipped);
    // Quieter audio after a clip: the flag stays until read.
    for (float& x : in.l) x *= 0.01f;
    for (float& x : in.r) x *= 0.01f;
    render(*chain, Stereo{std::vector<float>(64, 0.5f), std::vector<float>(64, 0.5f)});
    render(*chain, in);
    CHECK(chain->readSlotMeter(1, l, r, clipped));
    CHECK(clipped);
    CHECK(!chain->readSlotMeter(2, l, r, clipped));
}

TEST(c_api_sets_auto_gain_reads_the_trim_and_the_slot_meter) {
    const char* project = R"({"bpm":120,"loop_bars":4,"master":1,"layers":[{"id":"t","volume":1,
        "instrument":{"id":"org.caw.test.osc","params":{"shape":3,"level":0.2}},
        "components":[{"id":"org.caw.utility","params":{"gain":6},"auto_gain":true},{"id":"org.caw.utility","params":{"gain":-3}}]}]})";
    CawEngine* e = caw_engine_create(48000);
    CHECK(e != nullptr);
    if (!e) return;
    char* result = caw_engine_set_project(e, project);
    CHECK(result && std::string(result).find("\"ok\":true") != std::string::npos);
    caw_free(result);
    caw_engine_play(e);
    std::vector<float> l(256), r(256);
    for (int k = 0; k < 48000 * 10 / 256; ++k) caw_engine_process(e, l.data(), r.data(), 256);
    float trim = 0;
    CHECK_EQ(caw_engine_component_auto_gain(e, "t", 0, &trim), 1);
    CHECK_NEAR(trim, -6.0, 0.15);
    CHECK_EQ(caw_engine_component_auto_gain(e, "t", 1, &trim), 1);
    CHECK_EQ(trim, 0.0f);  // off
    CHECK_EQ(caw_engine_component_auto_gain(e, "t", 9, &trim), -1);
    CHECK_EQ(caw_engine_component_auto_gain(e, "nope", 0, &trim), -1);
    CHECK_EQ(caw_engine_set_component_auto_gain(e, "t", 0, 0), 1);
    CHECK_EQ(caw_engine_set_component_auto_gain(e, "t", 9, 1), 0);
    CHECK_EQ(caw_engine_set_component_auto_gain(e, "t", CAW_INSTRUMENT_INDEX, 1), 0);
    CHECK_EQ(caw_engine_component_auto_gain(e, "t", 0, &trim), 1);
    CHECK_EQ(trim, 0.0f);
    CawSlotMeter m{};
    CHECK_EQ(caw_engine_component_meter(e, "t", 0, &m), 1);
    CHECK(m.peak_l > 0.2f && m.peak_r > 0.2f);
    CHECK_EQ(caw_engine_component_meter(e, "t", CAW_INSTRUMENT_INDEX, &m), 1);
    CHECK(m.peak_l > 0.1f && m.peak_l <= 0.21f);
    CHECK_EQ(caw_engine_component_meter(e, "t", 5, &m), -1);
    caw_engine_destroy(e);
}

TEST(project_json_reads_auto_gain_only_when_given) {
    ProjectSpec spec;
    std::string error;
    const std::string json = R"({"bpm":120,"layers":[{"id":"t","components":["org.caw.utility",{"id":"org.caw.utility"},{"id":"org.caw.utility","auto_gain":true}]}],
        "master_components":[{"id":"org.caw.utility","auto_gain":true}]})";
    CHECK(parseProject(json, spec, error));
    if (spec.layers.empty() || spec.layers[0].components.size() != 3) return;
    CHECK(!spec.layers[0].components[0].autoGain && !spec.layers[0].components[1].autoGain);
    CHECK(spec.layers[0].components[2].autoGain);
    CHECK(spec.masterComponents.size() == 1 && spec.masterComponents[0].autoGain);
}
