// 1.1.0's "Around the effects": the armed signal, the sidechain filter on every keyed effect, the Limiter's loudness target and per-slot cost.
#include <chrono>
#include <cstddef>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <tuple>
#include <vector>

#include "caw.h"
#include "component_chain.h"
#include "engine.h"
#include "fx_modes_harness.h"
#include "meters.h"
#include "builtin_fx_racks.h"
#include "fx_migrate.h"
#include "project.h"

using namespace modes_test;

namespace {

// Runs a keyed effect over `in` with `key` as its sidechain, in blocks of `block`.
Stereo runKeyed(ModuleProcessor& p, const Stereo& in, const Stereo& key, const Values& values, uint32_t block = 64) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    Stereo out = silence(in.size());
    for (size_t start = 0; start < in.size(); start += block) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(block, in.size() - start));
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        const float* kc[2] = {key.l.data() + start, key.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        const ConstChannelBufferView audioIn[2] = {{ic, 2, n}, {kc, 2, n}};
        const ChannelBufferView audioOut{oc, 2, n};
        const EventInput none{nullptr, 0};
        ProcessBlock b;
        b.frames = n;
        b.sampleRate = 48000;
        b.audioIn = audioIn;
        b.audioInCount = 2;
        b.audioOut = &audioOut;
        b.audioOutCount = 1;
        bool notes = false;
        for (uint32_t k = 0; k < d.portCount; ++k) notes = notes || (d.ports[k].type == PortType::Event && d.ports[k].input);
        b.eventIn = notes ? &none : nullptr;
        b.eventInCount = notes ? 1 : 0;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        CHECK(p.processPorts(b));
    }
    return out;
}

double valueOf(const Values& v, std::string_view id) {
    for (const auto& [k, x] : v)
        if (k == id) return x;
    return -12345;
}

int paramIndex(const ModuleDescriptor& d, const char* id) {
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == id) return static_cast<int>(k);
    return -1;
}

std::string project(bool armed, const std::string& components, const std::string& monitor = "auto") {
    return "{\"caw_project\":1,\"bpm\":120,\"loop_bars\":1,\"master\":1,\"layers\":[{\"id\":\"t\",\"name\":\"T\",\"volume\":1,"
           "\"input\":{\"channel\":0,\"channels\":1,\"monitor\":\"" + monitor + "\",\"armed\":" + (armed ? "true" : "false") +
           "},\"components\":[" + components + "]}]}";
}

const char* kHeavy =
    "{\"id\":\"org.caw.eq\",\"params\":{\"variant\":4,\"b4_gain\":6}},"            // Linear: 2,304 frames
    "{\"id\":\"org.caw.clean\",\"params\":{\"variant\":0}},"                        // Denoise Normal: 2,048
    "{\"id\":\"org.caw.duck\",\"params\":{\"variant\":1,\"lookahead\":1}},"          // Level, 50 ms: 2,400
    "{\"id\":\"org.caw.shift\",\"params\":{\"variant\":0,\"grain\":60}},"            // Pitch, 60 ms grain: 1,441
    "{\"id\":\"org.caw.utility\"}";                                                  // nothing to arm

}  // namespace

// ---------------------------------------------------------------- the armed signal

TEST(an_armed_track_plays_its_effects_near_zero_delay_versions_and_compensation_follows) {
    Engine e(48000);
    CHECK(e.setProjectJson(project(false, kHeavy)).find("\"ok\":true") != std::string::npos);
    const int64_t full = e.layerLatency("t");
    CHECK_EQ(full, 2304 + 2048 + 2400 + 1441);
    double share = 0;
    uint32_t latency = 0;
    bool armed = true;
    CHECK_EQ(e.componentCost("t", 0, share, latency, armed), 1);
    CHECK_EQ(latency, 2304u);
    CHECK(!armed);
    // Armed: Linear minimum phase (0), Denoise the 512 window, Level no look-ahead, Pitch a 20 ms grain (481).
    CHECK(e.setProjectJson(project(true, kHeavy)).find("\"ok\":true") != std::string::npos);
    CHECK_EQ(e.layerLatency("t"), 0 + 512 + 0 + 481);
    const uint32_t want[] = {0, 512, 0, 481, 0};
    const bool badge[] = {true, true, true, true, false};
    for (uint32_t k = 0; k < 5; ++k) {
        CHECK_EQ(e.componentCost("t", k, share, latency, armed), 1);
        CHECK_EQ(latency, want[k]);
        CHECK_EQ(armed, badge[k]);
    }
    // Monitoring off: the track is not monitored, so the full versions play.
    CHECK(e.setProjectJson(project(true, kHeavy, "off")).find("\"ok\":true") != std::string::npos);
    CHECK_EQ(e.layerLatency("t"), full);
    // Disarmed again: back to the full versions.
    CHECK(e.setProjectJson(project(false, kHeavy)).find("\"ok\":true") != std::string::npos);
    CHECK_EQ(e.layerLatency("t"), full);
    // An export never arms.
    ProjectSpec spec;
    std::string error;
    CHECK(parseProject(project(true, kHeavy), spec, error));
    Engine offline(48000);
    CHECK(offline.setProjectOffline(spec).find("\"ok\":true") != std::string::npos);
    CHECK_EQ(offline.layerLatency("t"), full);
    CHECK_EQ(offline.componentCost("t", 0, share, latency, armed), 1);
    CHECK(!armed);
}

TEST(an_effect_already_on_its_short_setting_shows_no_armed_badge) {
    Engine e(48000);
    const std::string c =
        "{\"id\":\"org.caw.clean\",\"params\":{\"variant\":0,\"monitor\":1}},{\"id\":\"org.caw.duck\",\"params\":{\"variant\":1}}";
    CHECK(e.setProjectJson(project(true, c)).find("\"ok\":true") != std::string::npos);
    double share = 0;
    uint32_t latency = 0;
    bool armed = true;
    CHECK_EQ(e.componentCost("t", 0, share, latency, armed), 1);
    CHECK(!armed);
    CHECK_EQ(latency, 512u);
    CHECK_EQ(e.componentCost("t", 1, share, latency, armed), 1);
    CHECK(!armed);
    CHECK_EQ(latency, 0u);
}

TEST(armed_linear_eq_plays_the_bands_minimum_phase_with_no_delay) {
    const Values v = {{"variant", 4}, {"b4_gain", 9}, {"b4_freq", 1000}, {"b4_q", 1}};
    auto lin = make("org.caw.eq", v);
    auto* armedIf = lin ? dynamic_cast<ArmedVersion*>(lin.get()) : nullptr;
    auto* variable = lin ? dynamic_cast<VariableLatency*>(lin.get()) : nullptr;
    CHECK(armedIf && variable);
    if (!armedIf || !variable) return;
    armedIf->setArmed(true);
    CHECK_EQ(variable->latencyFor(nullptr, 0), 0u);
    const Stereo in = music(48000);
    const Stereo armedOut = run(*lin, in, v);
    // The same band on Bands (variant 0, minimum phase): the armed Linear matches it closely, with no delay.
    const Values bandsV = {{"variant", 0}, {"b4_gain", 9}, {"b4_freq", 1000}, {"b4_q", 1}};
    const Stereo bands = render("org.caw.eq", bandsV, in);
    double diff = 0, ref = 0;
    for (size_t i = 0; i < in.size(); ++i) {
        diff += std::pow(static_cast<double>(armedOut.l[i]) - bands.l[i], 2.0);
        ref += std::pow(static_cast<double>(bands.l[i]), 2.0);
    }
    const double errDb = 10.0 * std::log10(std::max(diff, 1e-30) / ref);
    if (!(errDb < -40.0)) cawtest::fail(__FILE__, __LINE__, "armed Linear differs from Bands by " + std::to_string(errDb) + " dB");
    // Block-size independent while armed.
    for (uint32_t block : {1u, 37u, 512u}) {
        lin->reset();
        const Stereo got = run(*lin, in, v, block);
        lin->reset();
        const Stereo again = run(*lin, in, v, 64);
        CHECK(std::memcmp(got.l.data(), again.l.data(), got.l.size() * 4) == 0);
    }
    // Disarmed: the linear-phase FIR again (the click comes out 2,304 frames late).
    armedIf->setArmed(false);
    lin->reset();
    const Stereo late = run(*lin, click(8192, 0), v);
    CHECK(peak(late.l, 0, 2000) < 0.01);
    CHECK(peak(late.l, 2200, 2400) > 0.3);
}

TEST(armed_preen_and_pitch_fix_use_their_monitoring_windows) {
    for (const auto& [id, values, full, low] :
         std::vector<std::tuple<const char*, Values, uint32_t, uint32_t>>{{"org.caw.clean", {{"variant", 0}}, 2048, 512},
                                                                          {"org.caw.clean", {{"variant", 2}}, 2048, 512},
                                                                          {"org.caw.pitchfix", {}, 1200, 480}}) {
        auto p = make(id, values);
        auto* a = p ? dynamic_cast<ArmedVersion*>(p.get()) : nullptr;
        auto* v = p ? dynamic_cast<VariableLatency*>(p.get()) : nullptr;
        CHECK(a && v);
        if (!a || !v) continue;
        std::vector<double> held(p->descriptor().parameterCount);
        for (uint32_t k = 0; k < held.size(); ++k) held[k] = p->descriptor().parameters[k].defaultValue;
        for (const auto& [pid, x] : values) held[static_cast<size_t>(paramIndex(p->descriptor(), pid.c_str()))] = x;
        CHECK_EQ(v->latencyFor(held.data(), static_cast<uint32_t>(held.size())), full);
        a->setArmed(true);
        CHECK_EQ(v->latencyFor(held.data(), static_cast<uint32_t>(held.size())), low);
        CHECK(a->armedDiffers(held.data(), static_cast<uint32_t>(held.size())));
        const Stereo out = run(*p, music(24000), values);
        CHECK(finite(out));
        CHECK(rms(out.l, 4800) > 1e-3);
    }
}

// ---------------------------------------------------------------- the sidechain filter

namespace {
struct Keyed {
    const char* id;
    Values values;  // the key in use (external, sidechain carrier...)
};
const std::vector<Keyed>& keyedEffects() {
    static const std::vector<Keyed> k = {
        {"org.caw.duck", {{"variant", 0}, {"sidechain", 1}, {"threshold", -40}}},
        {"org.caw.duck", {{"variant", 2}}},
        {"org.caw.gate", {{"variant", 0}, {"sidechain", 1}}},
        {"org.caw.gate", {{"variant", 1}, {"sidechain", 1}}},  // Expand: its own, the same three
        {"org.caw.gate", {{"variant", 2}, {"sidechain", 1}}},
        {"org.caw.ringmod", {{"source", 5}}},
        {"org.caw.vocoder", {{"carrier", 1}}},
        {"org.caw.compressor", {{"variant", 2}, {"sidechain", 1}}},  // Talon Up: already had them
    };
    return k;
}
}  // namespace

TEST(every_keyed_effect_has_the_sidechain_filter_off_by_default) {
    for (const Keyed& k : keyedEffects()) {
        auto p = make(k.id, k.values);
        if (!p) continue;
        const ModuleDescriptor& d = p->descriptor();
        const int hp = paramIndex(d, "sc_hpf"), lp = paramIndex(d, "sc_lpf"), li = paramIndex(d, "sc_listen");
        const std::string what = std::string(k.id) + " " + std::to_string(k.values[0].second);
        if (hp < 0 || lp < 0 || li < 0) {
            cawtest::fail(__FILE__, __LINE__, what + ": lacks a sidechain filter parameter");
            continue;
        }
        CHECK_EQ(d.parameters[hp].defaultValue, 20.0);
        CHECK_EQ(d.parameters[lp].defaultValue, 20000.0);
        CHECK_EQ(d.parameters[li].defaultValue, 0.0);
        // A merged device's `variant` keeps its place: the filter comes after it (or was in the table already).
        const int variant = paramIndex(d, "variant");
        if (variant >= 0 && fx::findMergedDevice(k.id) && std::string(k.id) != "org.caw.compressor" &&
            !(std::string(k.id) == "org.caw.gate" && k.values[0].second == 1))
            CHECK(lp > variant && li > variant);
    }
}

TEST(sidechain_listen_plays_the_filtered_key_on_every_keyed_effect) {
    const Stereo in = sine(220, 0.3, 24000);
    const Stereo highKey = sine(6000, 0.5, 24000), lowKey = sine(80, 0.5, 24000);
    for (const Keyed& k : keyedEffects()) {
        const std::string what = std::string(k.id) + " " + std::to_string(k.values[0].second);
        Values listen = k.values;
        listen.emplace_back("sc_listen", 1);
        auto p = make(k.id, listen);
        if (!p) continue;
        const Stereo open = runKeyed(*p, in, highKey, listen);
        CHECK(finite(open));
        // Listen with the filter open: the key itself (6 kHz at 0.5).
        const double heard = rms(open.l, 4800);
        if (!(heard > 0.2)) cawtest::fail(__FILE__, __LINE__, what + ": Listen open " + std::to_string(heard));
        // The low-pass at 500 Hz takes the 6 kHz key down by about 42 dB (12 dB/octave, 3.6 octaves).
        Values lp = listen;
        lp.emplace_back("sc_lpf", 500);
        p->reset();
        const double low = rms(runKeyed(*p, in, highKey, lp).l, 4800);
        if (!(db(low / heard) < -30.0)) cawtest::fail(__FILE__, __LINE__, what + ": low-pass " + std::to_string(db(low / heard)));
        // The high-pass at 1 kHz takes an 80 Hz key down likewise.
        Values hp = listen;
        hp.emplace_back("sc_hpf", 1000);
        p->reset();
        const double bass = rms(runKeyed(*p, in, lowKey, listen).l, 4800);
        p->reset();
        const double cut = rms(runKeyed(*p, in, lowKey, hp).l, 4800);
        if (!(db(cut / bass) < -30.0)) cawtest::fail(__FILE__, __LINE__, what + ": high-pass " + std::to_string(db(cut / bass)));
        // Block-size independent with the filter on and the effect running (not listening).
        Values filtered = k.values;
        filtered.emplace_back("sc_lpf", 800);
        filtered.emplace_back("sc_hpf", 100);
        auto q = make(k.id, filtered);
        const Stereo key = music(24000, 3);
        const Stereo want = runKeyed(*q, music(24000), key, filtered, 64);
        for (uint32_t block : {1u, 37u, 512u}) {
            q->reset();
            const Stereo got = runKeyed(*q, music(24000), key, filtered, block);
            if (std::memcmp(want.l.data(), got.l.data(), want.l.size() * 4) != 0)
                cawtest::fail(__FILE__, __LINE__, what + ": block " + std::to_string(block) + " differs");
        }
        // NaN in the key never sticks.
        Stereo bad = key;
        bad.l[100] = std::nanf("");
        bad.r[300] = INFINITY;
        q->reset();
        const Stereo after = runKeyed(*q, music(24000), bad, filtered);
        for (size_t i = 400; i < after.size(); ++i)
            if (!std::isfinite(after.l[i]) || !std::isfinite(after.r[i])) {
                cawtest::fail(__FILE__, __LINE__, what + ": a NaN in the key sticks");
                break;
            }
    }
}

TEST(the_sidechain_filter_at_its_defaults_changes_nothing) {
    // Explicit defaults give the same bits as leaving them out (each filter skipped at its end stop).
    for (const Keyed& k : keyedEffects()) {
        Values explicitOff = k.values;
        explicitOff.emplace_back("sc_hpf", 20);
        explicitOff.emplace_back("sc_lpf", 20000);
        explicitOff.emplace_back("sc_listen", 0);
        auto a = make(k.id, k.values), b = make(k.id, explicitOff);
        if (!a || !b) continue;
        const Stereo key = music(12000, 5);
        const Stereo x = runKeyed(*a, music(12000), key, k.values), y = runKeyed(*b, music(12000), key, explicitOff);
        CHECK(std::memcmp(x.l.data(), y.l.data(), x.l.size() * 4) == 0);
    }
}

TEST(a_rack_saved_before_the_sidechain_filter_keeps_its_routes) {
    // Rack layout 3: s1's Duck listed without sc_hpf, sc_lpf and sc_listen, so a route on s2's Transient sustain sat
    // three places earlier than today's.
    auto destination = [](const Values& values, const char* param) {
        std::unique_ptr<ModuleProcessor> p = registry().create(kFxRackId);
        auto* rack = dynamic_cast<RackContainer*>(p.get());
        std::string error;
        if (!rack || !rack->configure(registry(), values, true, error)) return 0.0;
        const ModuleDescriptor& d = p->descriptor();
        for (uint32_t k = 0; k < d.parameterCount; ++k)
            if (d.parameters[k].id == param) return k + 1.0;
        return 0.0;
    };
    Values now = {{"s1_fx", static_cast<double>(rackChildHash("org.caw.duck"))}, {"s1.variant", 0},
                  {"s2_fx", static_cast<double>(rackChildHash("org.caw.transient"))}, {"s2.variant", 0},
                  {"mod1_src", 1}, {"mod1_amt", 0.5}};
    const double sustain = destination(now, "s2.sustain");
    CHECK(sustain > 0);
    ComponentSpec old;
    old.id = std::string(kFxRackId);
    old.params = now;
    old.params.emplace_back("mod1_dst", sustain - 3);
    old.params.emplace_back(std::string(kRackLayoutParam), 3.0);
    CHECK(fx::migrateLegacyEffect(old));
    CHECK_EQ(valueOf(old.params, "mod1_dst"), sustain);
    CHECK_EQ(valueOf(old.params, kRackLayoutParam), kRackLayoutCurrent);
    CHECK(!fx::migrateLegacyEffect(old));  // once
}

// ---------------------------------------------------------------- the Limiter's loudness target

TEST(the_limiter_reports_short_term_and_integrated_loudness_against_its_target) {
    const Values off = {{"ceiling", -0.1}};
    const Values on = {{"ceiling", -0.1}, {"target_on", 1}, {"target", -14}};
    auto p = make("org.caw.limiter", on);
    if (!p) return;
    const ModuleDescriptor& d = p->descriptor();
    const int variant = paramIndex(d, "variant"), tOn = paramIndex(d, "target_on"), t = paramIndex(d, "target");
    CHECK(variant >= 0 && tOn > variant && t > tOn);
    CHECK_EQ(d.parameters[tOn].defaultValue, 0.0);
    CHECK_EQ(d.parameters[t].defaultValue, -14.0);
    // A 1 kHz sine at 0.1 on both sides: -20 LUFS (BS.1770 is calibrated so a full-scale 1 kHz sine in one channel
    // reads -3.01 LKFS: the K-weighting's +0.69 dB there cancels the -0.691).
    const Stereo in = sine(1000, 0.1, 48000 * 4);
    const Stereo out = run(*p, in, on, 64);
    float shown[64];
    const uint32_t n = p->readDisplay(shown, 64);
    CHECK_EQ(n, 13u);
    CHECK_EQ(shown[7], 1.0f);
    CHECK_EQ(shown[8], -14.0f);
    if (!(std::fabs(shown[9] - -20.0f) < 0.3f)) cawtest::fail(__FILE__, __LINE__, "short-term " + std::to_string(shown[9]));
    if (!(std::fabs(shown[10] - -20.0f) < 0.3f)) cawtest::fail(__FILE__, __LINE__, "integrated " + std::to_string(shown[10]));
    CHECK(std::fabs(shown[11] - (shown[9] + 14.0f)) < 1e-4f);
    CHECK(std::fabs(shown[12] - (shown[10] + 14.0f)) < 1e-4f);
    // Only a readout: the sound is the same bits as with the target off.
    const Stereo plain = render("org.caw.limiter", off, in);
    CHECK(std::memcmp(out.l.data(), plain.l.data(), out.l.size() * 4) == 0);
    // Off: no loudness shown.
    auto q = make("org.caw.limiter", off);
    run(*q, in, off);
    const uint32_t m = q->readDisplay(shown, 64);
    CHECK_EQ(m, 13u);
    CHECK_EQ(shown[7], 0.0f);
    CHECK_EQ(shown[9], kMeterNone);
    CHECK_EQ(shown[12], kMeterNone);
}

// ---------------------------------------------------------------- per-slot cost

TEST(per_slot_cost_is_measured_only_after_a_read_and_reports_latency) {
    Engine e(48000);
    CHECK(e.setProjectJson(project(false, kHeavy)).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(256), r(256);
    double share = 0;
    uint32_t latency = 0;
    bool armed = false;
    CHECK_EQ(e.componentCost("t", 0, share, latency, armed), 1);
    CHECK_EQ(share, -1.0);  // nothing measured before the first read
    CHECK_EQ(e.componentCost("t", 9, share, latency, armed), -1);
    CHECK_EQ(e.componentCost("nope", 0, share, latency, armed), -1);
    // A signal through the track so every slot works.
    for (int k = 0; k < 200; ++k) e.process(l.data(), r.data(), 256);
    CHECK_EQ(e.componentCost("t", 0, share, latency, armed), 1);
    if (!(share > 0.0 && share < 1.0)) cawtest::fail(__FILE__, __LINE__, "Linear's share " + std::to_string(share));
    CHECK_EQ(latency, 2304u);
    CHECK_EQ(e.componentCost("t", 4, share, latency, armed), 1);
    CHECK(share >= 0.0 && share < 0.05);  // a utility costs next to nothing

    // The measurement's own overhead: the same chain with and without a reader, best of several runs.
    auto time = [&](bool watched) {
        double best = 1e300;
        for (int round = 0; round < 5; ++round) {
            if (watched) e.componentCost("t", 0, share, latency, armed);
            else for (int k = 0; k < 400; ++k) e.process(l.data(), r.data(), 256);  // past the 2 s watch
            const auto t0 = std::chrono::steady_clock::now();
            for (int k = 0; k < 150; ++k) e.process(l.data(), r.data(), 256);
            best = std::min(best, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
        }
        return best;
    };
    const double plain = time(false), watched = time(true);
    const double audio = 150 * 256 / 48000.0;
    std::printf("    per-slot cost: %.1f us per second of audio watched vs %.1f unwatched (%+.1f us/s, 5 slots)\n",
                watched / audio * 1e6, plain / audio * 1e6, (watched - plain) / audio * 1e6);
}

TEST(c_api_component_cost_fills_only_the_size_the_caller_gives) {
    CawEngine* e = caw_engine_create(48000);
    CHECK(e != nullptr);
    if (!e) return;
    char* res = caw_engine_set_project(e, project(true, kHeavy).c_str());
    CHECK(res && std::string(res).find("\"ok\":true") != std::string::npos);
    caw_free(res);
    CawSlotCost c{};
    c.struct_size = sizeof(CawSlotCost);
    CHECK_EQ(caw_engine_component_cost(e, "t", 1, &c), 1);
    CHECK_EQ(c.struct_size, static_cast<uint32_t>(sizeof(CawSlotCost)));
    CHECK_EQ(c.cpu_share, -1.0f);
    CHECK_EQ(c.latency_frames, 512u);
    CHECK(std::fabs(c.latency_ms - 512 * 1000.0f / 48000.0f) < 1e-3f);
    CHECK_EQ(c.armed, 1);
    // An older, shorter struct: only what it covers.
    struct {
        CawSlotCost c;
        uint32_t guard;
    } small{};
    std::memset(&small, 0xAB, sizeof(small));
    small.c.struct_size = static_cast<uint32_t>(offsetof(CawSlotCost, latency_ms));
    CHECK_EQ(caw_engine_component_cost(e, "t", 1, &small.c), 1);
    CHECK_EQ(small.c.latency_frames, 512u);
    uint32_t untouched;
    std::memcpy(&untouched, &small.c.latency_ms, 4);
    CHECK_EQ(untouched, 0xABABABABu);
    CHECK_EQ(caw_engine_component_cost(e, "t", 7, &c), -1);
    CHECK_EQ(caw_engine_component_cost(nullptr, "t", 0, &c), -1);
    caw_engine_destroy(e);
}
