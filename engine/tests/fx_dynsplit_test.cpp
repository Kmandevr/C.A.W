// 1.1.0's Talon/Hatch/Duck split: old projects render the same bits after migration, and each new variant's curve, latency, block-size independence, presets, display and references.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "builtin_fx_racks.h"
#include "caw.h"
#include "caw/display.hpp"
#include "component_chain.h"
#include "engine.h"
#include "fx_merged.h"
#include "fx_migrate.h"
#include "json.h"
#include "presets.h"
#include "test.h"
#include "tolerance.h"

namespace caw::fx {
void kWeighting(double sr, double shelf[5], double hp[5]) noexcept;  // builtin_fx_duck_level_carve.cpp
}

using namespace caw;

namespace {

using Values = std::vector<std::pair<std::string, double>>;
constexpr double kPi = 3.14159265358979323846;
constexpr const char* kComp = "org.caw.compressor";
constexpr const char* kGate = "org.caw.gate";
constexpr const char* kDuck = "org.caw.duck";
constexpr const char* kTrem = "org.caw.tremolo";

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

Stereo sine(double hz, double amp, size_t frames) {
    Stereo s{std::vector<float>(frames), std::vector<float>(frames)};
    for (size_t i = 0; i < frames; ++i) s.l[i] = s.r[i] = static_cast<float>(amp * std::sin(2 * kPi * hz * i / 48000.0));
    return s;
}
Stereo add(Stereo a, const Stereo& b) {
    for (size_t i = 0; i < a.l.size(); ++i) a.l[i] += b.l[i], a.r[i] += b.r[i];
    return a;
}
// Tones and noise bursts that come and go, with gaps (onsets, decays, silence).
Stereo music(size_t frames, uint32_t seed = 11) {
    Stereo s{std::vector<float>(frames), std::vector<float>(frames)};
    for (size_t i = 0; i < frames; ++i) {
        if ((i / 9000) % 4 == 3) continue;
        seed = seed * 1664525u + 1013904223u;
        const double burst = (i % 6000) < 900 ? 0.5 : 0.03;
        const double nz = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * burst;
        const double env = std::exp(-static_cast<double>(i % 12000) / 6000.0);
        s.l[i] = static_cast<float>(0.3 * env * std::sin(2 * kPi * 110.0 * i / 48000.0) + nz);
        s.r[i] = static_cast<float>(0.25 * env * std::sin(2 * kPi * 1650.0 * i / 48000.0) - nz);
    }
    return s;
}
// A kick-like key: a 60 Hz burst every 250 ms.
Stereo kicks(size_t frames) {
    Stereo s{std::vector<float>(frames), std::vector<float>(frames)};
    for (size_t i = 0; i < frames; ++i) {
        const size_t t = i % 12000;
        if (t < 3000) s.l[i] = s.r[i] = static_cast<float>(0.8 * std::exp(-static_cast<double>(t) / 900.0) * std::sin(2 * kPi * 60.0 * t / 48000.0));
    }
    return s;
}

std::unique_ptr<ModuleProcessor> make(const char* id, const Values& v) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), id, v);
    CHECK(p != nullptr);
    if (p) CHECK(p->activate(48000, 512));
    return p;
}

// Runs `p` over `in` (and `key`, its sidechain, when given) in blocks of `block`.
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

bool keyed(const ModuleProcessor& p) { return ComponentChain::isKeyedEffect(p.descriptor()); }

bool sameBits(const Stereo& a, const Stereo& b) {
    return a.l.size() == b.l.size() && std::memcmp(a.l.data(), b.l.data(), a.l.size() * 4) == 0 &&
           std::memcmp(a.r.data(), b.r.data(), a.r.size() * 4) == 0;
}
double rms(const std::vector<float>& v, size_t from, size_t to) {
    double s = 0;
    for (size_t i = from; i < to; ++i) s += static_cast<double>(v[i]) * v[i];
    return std::sqrt(s / static_cast<double>(to - from));
}
double db(double x) { return 20.0 * std::log10(std::max(x, 1e-12)); }
double valueOf(const Values& v, std::string_view id, double fallback = -12345) {
    for (const auto& [k, x] : v)
        if (k == id) fallback = x;
    return fallback;
}
// The amplitude of `hz` in v[from, to) (a single-bin DFT).
double tone(const std::vector<float>& v, double hz, size_t from, size_t to) {
    double re = 0, im = 0;
    for (size_t i = from; i < to; ++i) {
        re += v[i] * std::cos(2 * kPi * hz * i / 48000.0);
        im += v[i] * std::sin(2 * kPi * hz * i / 48000.0);
    }
    return 2.0 * std::sqrt(re * re + im * im) / static_cast<double>(to - from);
}

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

Stereo renderProject(const std::string& json, int blocks = 400) {
    ProjectSpec p;
    std::string error;
    if (!parseProject(json, p, error)) cawtest::fail(__FILE__, __LINE__, error);
    Engine e(48000);
    const std::string r = e.setProject(p);
    if (!ok(r)) cawtest::fail(__FILE__, __LINE__, r);
    e.play();
    Stereo out{std::vector<float>(256 * blocks), std::vector<float>(256 * blocks)};
    for (int b = 0; b < blocks; ++b) e.process(out.l.data() + 256 * b, out.r.data() + 256 * b, 256);
    return out;
}

// A project: a muted key track "k" (a saw keyed into the effects), track "t" (a pulse) through `components`, a
// lane on component `lane`'s `target` (none when empty).
std::string project(const std::string& components, const std::string& target = {}, int lane = 0) {
    std::string json = R"({"caw_project":1,"bpm":120,"loop_bars":2,"layers":[)"
                       R"({"id":"k","volume":1,"mute":true,"instrument":{"id":"org.caw.test.osc","params":{"shape":1,"freq":55,"level":0.8}}},)"
                       R"({"id":"t","volume":1,"instrument":{"id":"org.caw.test.osc","params":{"shape":2,"freq":220,"level":0.4}},)"
                       R"("components":[)" + components + "]}]";
    if (!target.empty())
        json += R"(,"automation":[{"target_type":"component","layer":"t","component":)" + std::to_string(lane) +
                R"(,"target":")" + target + R"(","points":[{"step":0,"value":-50},{"step":32,"value":-10}]}])";
    return json + "}";
}

double hashOf(const char* id) { return static_cast<double>(rackChildHash(id)); }

// The parameter index + 1 of `param` in the rack `values` make (its routes' destinations).
double destination(const Values& values, std::string_view param) {
    std::unique_ptr<ModuleProcessor> p = registry().create(kFxRackId);
    auto* rack = dynamic_cast<RackContainer*>(p.get());
    std::string error;
    if (!rack || !rack->configure(registry(), values, true, error)) return 0.0;
    const ModuleDescriptor& d = p->descriptor();
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == param) return k + 1.0;
    return 0.0;
}

// The new variants, as the tests run them (keyed ones get the kicks as their key).
struct NewVariant {
    const char* name;
    const char* id;
    Values values;
};
const std::vector<NewVariant>& newVariants() {
    static const std::vector<NewVariant> v = {
        {"up", kComp, {{"variant", 2}, {"talon_layout", 1}, {"threshold", -24}, {"detect", 1}, {"lookahead", 3}}},
        {"up_isp_warm", kComp, {{"variant", 2}, {"talon_layout", 1}, {"threshold", -20}, {"detect", 2}, {"character", 1}, {"mix", 0.7}}},
        {"bus_auto", kComp, {{"variant", 3}, {"talon_layout", 1}, {"threshold", -24}, {"ratio", 2}}},
        {"bus_keyed", kComp, {{"variant", 3}, {"talon_layout", 1}, {"threshold", -30}, {"sidechain", 1}, {"release", 1}, {"sc_hpf", 80}}},
        {"down_extras", kComp, {{"variant", 0}, {"talon_layout", 1}, {"threshold", -24}, {"detect", 2}, {"sc_lpf", 4000}, {"character", 1}, {"output", -2}}},
        {"expand", kGate, {{"variant", 1}, {"threshold", -30}, {"detect", 1}}},
        {"pedal", kGate, {{"variant", 2}, {"threshold", -30}}},
        {"level", kDuck, {{"variant", 1}, {"target", -14}, {"speed", 0.3}, {"lookahead", 1}}},
        {"carve", kDuck, {{"variant", 2}, {"amount", 1}, {"range", 12}, {"low", 30}, {"high", 400}}},
        {"carve_ms24", kDuck, {{"variant", 2}, {"bands", 1}, {"stereo", 2}, {"amount", 0.8}, {"low", 30}, {"high", 16000}}},
    };
    return v;
}

}  // namespace

// ---------- Migration: 1.0.8 and 1.0.9 projects open unchanged ----------

TEST(each_moved_compressor_variant_in_an_old_project_renders_its_new_devices_bits) {
    // Each 1.0.9 Compressor variant that left (no talon_layout), keyed and with a lane, against the same entry
    // written as its new device: the same bits, and the migration names the new device with its values kept.
    struct Move {
        int oldVariant;
        const char* to;
        int variant;
        const char* params;
        const char* lane;
    };
    const Move moves[] = {
        {2, kGate, 0, R"("threshold":-30,"range":-40,"sidechain":1)", "threshold"},
        {3, kTrem, 2, R"("mode":0,"depth":0.8,"lookahead":2)", "depth"},
        {4, kDuck, 0, R"("threshold":-20,"amount":0.4,"sidechain":1,"detection":1)", "threshold"},
    };
    for (const Move& m : moves) {
        const std::string oldEntry = std::string(R"({"id":"org.caw.compressor","params":{"variant":)") +
                                     std::to_string(m.oldVariant) + "," + m.params + R"(},"key":{"layer":"k"}})";
        const std::string newEntry = std::string(R"({"id":")") + m.to + R"(","params":{"variant":)" +
                                     std::to_string(m.variant) + "," + m.params + R"(},"key":{"layer":"k"}})";
        const Stereo a = renderProject(project(oldEntry, m.lane)), b = renderProject(project(newEntry, m.lane));
        if (!sameBits(a, b)) cawtest::fail(__FILE__, __LINE__, std::string(m.to) + ": the migrated bits differ");
        CHECK(rms(a.l, 0, a.l.size()) > 0.01);
        ProjectSpec p;
        std::string error;
        CHECK(parseProject(project(oldEntry, m.lane), p, error));
        CHECK(fx::hasLegacyEffects(p) && fx::migrateLegacyEffects(p) && !fx::hasLegacyEffects(p));
        const ComponentSpec& c = p.layers[1].components[0];
        CHECK(c.id == m.to && valueOf(c.params, "variant") == m.variant && c.hasKey);
        CHECK(valueOf(c.params, "talon_layout") == -12345);  // not a Talon entry
        CHECK(p.automation.size() == 1u && p.automation[0].target == m.lane);  // the lane follows, its id unchanged
        CHECK(!fx::migrateLegacyEffects(p));  // once
    }
    // Down and Dynamics stay, with the marker added; the bits are the old class's.
    for (int v : {0, 1}) {
        const std::string params = v == 0 ? R"("threshold":-30,"ratio":6)" : R"("high_ratio":5,"low_ratio":2)";
        const std::string a = R"({"id":"org.caw.compressor","params":{"variant":)" + std::to_string(v) + "," + params + "}}";
        const std::string b = R"({"id":"org.caw.compressor","params":{"variant":)" + std::to_string(v) + "," + params + R"(,"talon_layout":1}})";
        CHECK(sameBits(renderProject(project(a, v == 0 ? "threshold" : "")), renderProject(project(b, v == 0 ? "threshold" : ""))));
    }
    // A 1.1.0 entry (marked) keeps Talon's numbering: variant 2 is Up, never the gate.
    ComponentSpec up;
    up.id = kComp;
    up.params = {{"variant", 2}, {"talon_layout", 1}};
    CHECK(!fx::migrateLegacyEffect(up) && up.id == kComp);
}

TEST(an_old_racks_compressor_children_move_with_their_routes_and_sound_the_same) {
    // A 1.0.9 rack (rack_layout 2): s1 the Compressor's Down, s2 its Duck (variant 4), s3 its Gate, s4 a transient
    // shaper; routes to s2's amount and s4's sustain. Down's list grew by its extras and marker in 1.1.0, so every
    // later child's parameters sit 4 places later.
    Values now = {{"s1_fx", hashOf(kComp)}, {"s1.variant", 0}, {"s1.threshold", -30},
                  {"s2_fx", hashOf(kDuck)}, {"s2.variant", 0}, {"s2.threshold", -36}, {"s2.amount", 0.5},
                  {"s3_fx", hashOf(kGate)}, {"s3.variant", 0}, {"s3.threshold", -45},
                  {"s4_fx", hashOf("org.caw.transient")}, {"s4.attack", 0.4},
                  {"mod1_src", 1}, {"mod1_amt", 0.4}, {"mod2_src", 1}, {"mod2_amt", -0.3}};
    const double amount = destination(now, "s2.amount"), sustain = destination(now, "s4.sustain");
    CHECK(amount > 0 && sustain > 0);
    Values old = now;
    for (auto& [k, v] : old) {
        if (k == "s2_fx" || k == "s3_fx") v = hashOf(kComp);
        if (k == "s2.variant") v = 4;
        if (k == "s3.variant") v = 2;
    }
    old.emplace_back("mod1_dst", amount - 4);
    old.emplace_back("mod2_dst", sustain - 4);
    old.emplace_back(std::string(kRackLayoutParam), 2.0);
    now.emplace_back("mod1_dst", amount);
    now.emplace_back("mod2_dst", sustain);
    now.emplace_back(std::string(kRackLayoutParam), kRackLayoutCurrent);
    ComponentSpec m;
    m.id = std::string(kFxRackId);
    m.params = old;
    CHECK(fx::migrateLegacyEffect(m));
    CHECK_EQ(valueOf(m.params, "s2_fx"), hashOf(kDuck));
    CHECK_EQ(valueOf(m.params, "s2.variant"), 0.0);
    CHECK_EQ(valueOf(m.params, "s3_fx"), hashOf(kGate));
    CHECK_EQ(valueOf(m.params, "s3.variant"), 0.0);
    CHECK_EQ(valueOf(m.params, "s1_fx"), hashOf(kComp));
    CHECK_EQ(valueOf(m.params, "mod1_dst"), amount);
    CHECK_EQ(valueOf(m.params, "mod2_dst"), sustain);
    CHECK_EQ(valueOf(m.params, kRackLayoutParam), kRackLayoutCurrent);
    CHECK(!fx::migrateLegacyEffect(m));  // once
    // Through a project: the old rack sounds as the one written for 1.1.0.
    auto entry = [](const Values& v) {
        std::string json = R"({"id":"org.caw.rack.fx","params":{)";
        for (size_t i = 0; i < v.size(); ++i) {
            char num[40];
            std::snprintf(num, sizeof num, "%.17g", v[i].second);
            json += (i ? ",\"" : "\"") + v[i].first + "\":" + num;
        }
        return json + "}}";
    };
    const Stereo a = renderProject(project(entry(old))), b = renderProject(project(entry(now)));
    CHECK(sameBits(a, b));
    CHECK(rms(b.l, 0, b.l.size()) > 0.01);
}

TEST(a_1_0_9_preset_whose_variant_moved_still_opens_and_lists_under_its_new_device) {
    // An old entry naming a Duck preset under the Compressor: it opens as the Ducker's Duck with those values.
    const std::string oldEntry = R"({"id":"org.caw.compressor","preset":"Kick duck bass","params":{},"key":{"layer":"k"}})";
    const std::string newEntry = R"({"id":"org.caw.duck","preset":"Kick duck bass","params":{},"key":{"layer":"k"}})";
    CHECK(sameBits(renderProject(project(oldEntry)), renderProject(project(newEntry))));
    // The presets list under their new devices: Duck's under org.caw.duck (variant 0), the gate's and the
    // ducker's under Gate and Tremolo/Pan; none of them under the Compressor any more.
    CHECK(findBuiltinPreset(kDuck, "Kick duck bass") != nullptr);
    CHECK(findBuiltinPreset(kComp, "Kick duck bass") == nullptr);
    for (const BuiltinPreset& p : builtinPresets("org.caw.ducker")) CHECK(findBuiltinPreset(kTrem, p.name) != nullptr);
    // caw_migrate_component (the app's user presets and documents).
    char* text = caw_migrate_component(R"({"id":"org.caw.compressor","params":{"variant":4,"amount":0.7}})");
    Json j;
    std::string error;
    CHECK(text && parseJson(text, j, error) && j.boolean("migrated", false) && j.string("id") == kDuck);
    CHECK(j.get("params") && j.get("params")->number("variant", -1) == 0 && j.get("params")->number("amount", -1) == 0.7);
    caw_free(text);
    text = caw_migrate_component(R"({"id":"org.caw.compressor","params":{"variant":3,"talon_layout":1}})");
    CHECK(text && parseJson(text, j, error) && !j.boolean("migrated", true) && j.string("id") == kComp);
    caw_free(text);
    // An old id alone (createNativeComponent, the benchmark): the same rows.
    std::string id = kComp;
    Values v = {{"variant", 2}};
    CHECK(fx::migrateLegacyId(id, v) && id == kGate && valueOf(v, "variant") == 0);
}

// ---------- Each new variant ----------

TEST(talons_up_lifts_quiet_levels_by_its_curve_within_range_and_floor) {
    // RMS detection of a steady 1 kHz sine: threshold -30, 2:1, range 12, floor -60, knee 6.
    const Values v = {{"variant", 2}, {"talon_layout", 1}, {"threshold", -30}, {"ratio", 2}, {"range", 12},
                      {"floor", -60}, {"knee", 6}, {"detect", 1}};
    const std::pair<double, double> cases[] = {{-20, 0}, {-40, 5}, {-56, 12}, {-70, 2}};  // RMS level, lift dB
    for (const auto& [level, lift] : cases) {
        auto p = make(kComp, v);
        if (!p) return;
        const double amp = std::pow(10.0, level / 20.0) * std::sqrt(2.0);
        const Stereo in = sine(1000, amp, 96000);
        const Stereo out = run(*p, in, nullptr, v);
        const double got = db(rms(out.l, 72000, 96000) / rms(in.l, 72000, 96000));
        if (std::fabs(got - lift) > 0.3)
            cawtest::fail(__FILE__, __LINE__, "Up at " + std::to_string(level) + " dB lifts " + std::to_string(got));
    }
    // Silence stays silence (never lifted) and the effect sleeps.
    auto p = make(kComp, v);
    const Stereo out = run(*p, sine(1000, 0.0, 9600), nullptr, v);
    CHECK(rms(out.l, 0, 9600) == 0.0);
}

TEST(talons_bus_holds_its_stepped_ratio_through_the_feedback_loop) {
    // A steady sine, RMS -6 dBFS, threshold -12, hard knee, no makeup: 6 dB over comes out 6 / ratio over.
    const double ratios[] = {1.5, 2.0, 4.0, 10.0};
    for (int r = 0; r < 4; ++r) {
        const double ratio = ratios[r];
        const Values v = {{"variant", 3}, {"talon_layout", 1}, {"threshold", -12}, {"ratio", r}, {"knee", 0},
                          {"auto_makeup", 0}, {"release", 0}, {"detect", 1}, {"attack", 1}};
        auto p = make(kComp, v);
        if (!p) return;
        const Stereo in = sine(1000, std::pow(10.0, -6.0 / 20.0) * std::sqrt(2.0), 72000);
        const Stereo out = run(*p, in, nullptr, v);
        const double want = -6.0 * (1.0 - 1.0 / ratio), got = db(rms(out.l, 48000, 72000) / rms(in.l, 48000, 72000));
        for (float x : out.l) CHECK(std::isfinite(x));
        if (std::fabs(got - want) > 0.4)
            cawtest::fail(__FILE__, __LINE__, "Bus " + std::to_string(ratio) + ":1 gives " + std::to_string(got) + " dB");
    }
    // Auto release: after a long loud stretch the slow follower holds some reduction; after a short burst it is
    // back sooner.
    const Values v = {{"variant", 3}, {"talon_layout", 1}, {"threshold", -20}, {"ratio", 2}, {"release", 4}, {"auto_makeup", 0}};
    auto recovery = [&](size_t loud) {
        auto p = make(kComp, v);
        Stereo in = sine(1000, 0.7, loud + 24000);
        for (size_t i = loud; i < in.l.size(); ++i) in.l[i] *= 0.05f, in.r[i] *= 0.05f;
        const Stereo out = run(*p, in, nullptr, v);
        return db(rms(out.l, loud + 4800, loud + 7200) / rms(in.l, loud + 4800, loud + 7200));
    };
    CHECK(recovery(2400) > recovery(96000) + 0.5);
}

TEST(hatchs_expand_falls_ratio_times_as_fast_below_its_threshold_never_past_range) {
    const Values v = {{"variant", 1}, {"threshold", -40}, {"ratio", 2}, {"range", -40}, {"knee", 0}, {"detect", 1}};
    const std::pair<double, double> cases[] = {{-30, 0}, {-50, -10}, {-60, -20}, {-90, -40}};
    for (const auto& [level, gain] : cases) {
        auto p = make(kGate, v);
        if (!p) return;
        const Stereo in = sine(1000, std::pow(10.0, level / 20.0) * std::sqrt(2.0), 48000);
        const Stereo out = run(*p, in, nullptr, v);
        const double got = db(rms(out.l, 36000, 48000) / rms(in.l, 36000, 48000));
        if (std::fabs(got - gain) > 0.3)
            cawtest::fail(__FILE__, __LINE__, "Expand at " + std::to_string(level) + " dB: " + std::to_string(got));
    }
}

TEST(hatchs_pedal_gate_has_hysteresis_and_tracks_the_decay_for_its_release) {
    // Open above -30, closed below -40: a level of -35 keeps whichever state it came from.
    const Values v = {{"variant", 2}, {"threshold", -30}, {"hysteresis", 10}, {"hold", 0}, {"tracking", 0}, {"release", 10}};
    auto through = [&](double before) {
        auto p = make(kGate, v);
        Stereo in = sine(1000, std::pow(10.0, before / 20.0), 9600);
        const Stereo then = sine(1000, std::pow(10.0, -35.0 / 20.0), 19200);
        in.l.insert(in.l.end(), then.l.begin(), then.l.end());
        in.r.insert(in.r.end(), then.r.begin(), then.r.end());
        const Stereo out = run(*p, in, nullptr, v);
        return db(rms(out.l, 19200, 28800) / rms(in.l, 19200, 28800));
    };
    CHECK(through(-20) > -0.5);   // came from open: still open
    CHECK(through(-50) < -60.0);  // came from closed: still closed
    // No latency: an open gate passes the first sample of a loud onset at once.
    {
        auto p = make(kGate, v);
        const Stereo in = sine(1000, 0.5, 4800);
        const Stereo out = run(*p, in, nullptr, v);
        CHECK(std::fabs(out.l[20] - in.l[20]) < 0.05);
    }
    // A tone decaying 40 dB a second: tracked, the release in use is the time that decay takes to fall 20 dB.
    for (double tracking : {0.0, 1.0}) {
        Values t = v;
        t.push_back({"tracking", tracking});
        auto p = make(kGate, t);
        Stereo in = sine(500, 0.5, 48000);
        for (size_t i = 0; i < in.l.size(); ++i) {
            const float g = static_cast<float>(std::pow(10.0, -40.0 * i / 48000.0 / 20.0));
            in.l[i] *= g, in.r[i] *= g;
        }
        run(*p, Stereo{std::vector<float>(in.l.begin(), in.l.begin() + 24000), std::vector<float>(in.r.begin(), in.r.begin() + 24000)}, nullptr, t);
        float shown[16];
        CHECK_EQ(p->readDisplay(shown, 16), 10u);
        if (tracking == 0.0) CHECK_NEAR(shown[8], 10.0, 0.01);
        else if (!(shown[8] > 300.0f && shown[8] < 800.0f))
            cawtest::fail(__FILE__, __LINE__, "tracked release " + std::to_string(shown[8]) + " ms (want about 500)");
    }
}

TEST(ducks_level_uses_bs1770_k_weighting_and_rides_toward_its_target) {
    // [Fact] BS.1770's tabled K-weighting coefficients at 48 kHz (ITU-R BS.1770, tables 1 and 2).
    double shelf[5], hp[5];
    fx::kWeighting(48000.0, shelf, hp);
    const double wantShelf[5] = {1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585};
    const double wantHp[5] = {1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621};
    for (int k = 0; k < 5; ++k) {
        CHECK_NEAR(shelf[k], wantShelf[k], 1e-8);
        CHECK_NEAR(hp[k], wantHp[k], 1e-8);
    }
    // A 1 kHz sine on both sides at 0.1 (about -20 LUFS) toward -14: +6 dB, unless Max boost holds it at 3.
    for (const auto& [boost, want] : {std::pair{12.0, 6.0}, std::pair{3.0, 3.0}}) {
        const Values v = {{"variant", 1}, {"target", -14}, {"max_boost", boost}, {"speed", 0.2}, {"gate", -50}};
        auto p = make(kDuck, v);
        if (!p) return;
        const Stereo in = sine(1000, 0.1, 144000);
        const Stereo out = run(*p, in, nullptr, v);
        const double got = db(rms(out.l, 120000, 144000) / rms(in.l, 120000, 144000));
        if (std::fabs(got - want) > 0.4) cawtest::fail(__FILE__, __LINE__, "Level rides " + std::to_string(got) + " dB");
    }
    // Under the gate it holds still: a -40 LUFS part with the gate at -30 is not pulled up.
    const Values gated = {{"variant", 1}, {"target", -14}, {"max_boost", 24}, {"speed", 0.2}, {"gate", -30}};
    auto p = make(kDuck, gated);
    const Stereo quiet = sine(1000, 0.01, 96000);
    const Stereo out = run(*p, quiet, nullptr, gated);
    CHECK(std::fabs(db(rms(out.l, 72000, 96000) / rms(quiet.l, 72000, 96000))) < 0.1);
}

TEST(ducks_carve_dips_the_keys_bands_only_inside_its_window) {
    // The key: a 1 kHz tone. The signal: 100 Hz, 1 kHz and 6 kHz.
    const size_t n = 48000;
    const Stereo key = sine(1000, 0.3, n);
    const Stereo in = add(add(sine(100, 0.1, n), sine(1000, 0.1, n)), sine(6000, 0.1, n));
    auto measure = [&](const Values& v, const Stereo* k) {
        auto p = make(kDuck, v);
        const Stereo out = run(*p, in, k, v);
        std::vector<double> d;
        for (double hz : {100.0, 1000.0, 6000.0}) d.push_back(db(tone(out.l, hz, 24000, n) / tone(in.l, hz, 24000, n)));
        return d;
    };
    const Values v = {{"variant", 2}, {"amount", 1}, {"range", 9}, {"low", 40}, {"high", 16000}};
    const std::vector<double> dipped = measure(v, &key);
    CHECK(dipped[1] < -4.0);                                        // the key's band dips
    CHECK(std::fabs(dipped[0]) < 0.6 && std::fabs(dipped[2]) < 0.6);  // the others stay
    // The window above 500 Hz: nothing there to dip.
    Values window = v;
    window.push_back({"high", 400});
    CHECK(std::fabs(measure(window, &key)[1]) < 0.5);
    // Listen: what the dip takes out (about the 1 kHz part only).
    Values listen = v;
    listen.push_back({"listen", 1});
    {
        auto p = make(kDuck, listen);
        const Stereo out = run(*p, in, &key, listen);
        // (the bells' phase leaves a little of the other tones too)
        const double at1k = tone(out.l, 1000, 24000, n);
        CHECK(at1k > 0.04 && at1k > 2.5 * tone(out.l, 100, 24000, n) && at1k > 2.5 * tone(out.l, 6000, 24000, n));
    }
    // No key: the signal passes bit for bit.
    auto p = make(kDuck, v);
    const Stereo silent = sine(1000, 0.0, n);
    CHECK(sameBits(run(*p, in, &silent, v), in));
}

TEST(ducks_carve_never_dips_a_band_more_than_range_when_the_key_spans_its_neighbours) {
    // The key: a tone on every band's centre, all far over Threshold, so each band asks for the full Range. The
    // bells overlap, so without a clamp a band's neighbours add to its own dip (about 14 dB at Range 9).
    const size_t n = 48000;
    for (const double bands : {0.0, 1.0}) {
        const uint32_t count = bands == 1.0 ? 24 : 16;
        Stereo key = sine(40, 0.0, n);
        for (uint32_t b = 0; b < count; ++b) key = add(key, sine(40.0 * std::pow(400.0, b / (count - 1.0)), 0.05, n));
        for (const double range : {3.0, 9.0, 18.0}) {
            const Values v = {{"variant", 2}, {"amount", 1}, {"range", range}, {"threshold", -80}, {"bands", bands},
                              {"low", 20}, {"high", 20000}};
            for (const uint32_t b : {count / 4, count / 2, count - 4}) {
                const double hz = 40.0 * std::pow(400.0, b / (count - 1.0)) * (b == count / 2 ? 1.0 : 1.09);
                const Stereo in = sine(hz, 0.1, n);
                auto p = make(kDuck, v);
                const double dip = db(tone(run(*p, in, &key, v).l, hz, 24000, n) / tone(in.l, hz, 24000, n));
                CHECK(dip > -(range + 0.3));  // never past Range
                CHECK(dip < -0.6 * range);    // but still about Range
            }
        }
    }
}

TEST(the_new_variants_report_the_latency_they_have) {
    // Up's look-ahead (5 ms) and Level's (100 ms): the chain's reported latency is the impulse's delay.
    struct Case {
        const char* id;
        Values values;
        uint32_t frames;
    };
    const Case cases[] = {
        {kComp, {{"variant", 2}, {"talon_layout", 1}, {"lookahead", 5}, {"range", 0}}, 240},
        {kDuck, {{"variant", 1}, {"lookahead", 2}, {"max_boost", 0}, {"max_cut", 0}}, 4800},
        {kComp, {{"variant", 3}, {"talon_layout", 1}}, 0},
        {kGate, {{"variant", 1}}, 0},
        {kGate, {{"variant", 2}}, 0},
        {kDuck, {{"variant", 2}}, 0},
    };
    for (const Case& c : cases) {
        ComponentSpec s;
        s.id = c.id;
        s.params = c.values;
        std::string error;
        auto chain = ComponentChain::build(registry(), {s}, 48000.0, error);
        CHECK(chain != nullptr);
        if (!chain) return;
        CHECK_EQ(chain->latencyFrames(), c.frames);
        if (c.frames == 0) continue;
        auto p = make(c.id, c.values);
        Stereo in = sine(1, 0.0, 9600);
        in.l[100] = in.r[100] = 0.5f;
        const Stereo out = run(*p, in, nullptr, c.values);
        size_t at = 0;
        for (size_t i = 0; i < out.l.size(); ++i)
            if (std::fabs(out.l[i]) > std::fabs(out.l[at])) at = i;
        CHECK_EQ(at, 100u + c.frames);
    }
}

TEST(the_new_variants_give_the_same_bits_at_any_block_size_and_stay_sane) {
    const Stereo in = music(30000), key = kicks(30000);
    for (const NewVariant& nv : newVariants()) {
        auto p = make(nv.id, nv.values);
        if (!p) return;
        const Stereo* k = keyed(*p) ? &key : nullptr;
        const Stereo want = run(*p, in, k, nv.values, 64);
        for (uint32_t block : {1u, 37u, 512u}) {
            p->reset();
            if (!sameBits(want, run(*p, in, k, nv.values, block)))
                cawtest::fail(__FILE__, __LINE__, std::string(nv.name) + ": block " + std::to_string(block) + " differs");
        }
        // A NaN, an infinity and subnormals in the input (and key): every output once they have left the
        // look-ahead (at most 200 ms) finite, and the state not poisoned (it still sounds afterwards).
        Stereo bad = in, badKey = key;
        bad.l[1000] = std::nanf(""), bad.r[1001] = INFINITY, badKey.l[1002] = std::nanf("");
        for (size_t i = 2000; i < 2400; ++i) bad.l[i] = bad.r[i] = 1e-41f;
        p->reset();
        const Stereo out = run(*p, bad, k ? &badKey : nullptr, nv.values);
        bool finite = true;
        for (size_t i = 1100 + 9600; i < out.l.size(); ++i) finite &= std::isfinite(out.l[i]) && std::isfinite(out.r[i]);
        if (!finite) cawtest::fail(__FILE__, __LINE__, std::string(nv.name) + ": not finite after a NaN");
        CHECK(rms(out.l, 20000, 30000) > 1e-4);
    }
}

TEST(the_new_variants_have_job_named_presets_that_play) {
    // At least 8 per new mode, unique names per device, each applying and playing finite.
    const Stereo in = music(24000), key = kicks(24000);
    std::map<std::string, std::map<int, int>> perMode;
    for (const char* id : {kComp, kGate, kDuck}) {
        std::set<std::string> names;
        for (const BuiltinPreset& preset : builtinPresets(id)) {
            CHECK(names.insert(std::string(preset.name)).second);
            CHECK(!preset.description.empty());
            Values values;
            CHECK(applyBuiltinPreset(id, preset.name, values));
            const int variant = static_cast<int>(valueOf(values, "variant", 0));
            ++perMode[id][variant];
            auto p = make(id, values);
            if (!p) continue;
            const Stereo out = run(*p, in, keyed(*p) ? &key : nullptr, values);
            for (size_t i = 0; i < out.l.size(); i += 97) CHECK(std::isfinite(out.l[i]) && std::fabs(out.l[i]) < 8.0f);
        }
    }
    for (int v : {2, 3}) CHECK(perMode[kComp][v] >= 8);
    for (int v : {1, 2}) CHECK(perMode[kGate][v] >= 8);
    for (int v : {0, 1, 2}) CHECK(perMode[kDuck][v] >= 8);
}

TEST(the_new_variants_publish_their_display_data) {
    const Stereo in = music(9600), key = kicks(9600);
    const std::map<std::string, uint32_t> counts = {{"up", 12}, {"bus_auto", 12}, {"expand", 10}, {"pedal", 10},
                                                    {"level", 10}, {"carve", 5 + 3 * 16}, {"carve_ms24", 5 + 3 * 24}};
    for (const NewVariant& nv : newVariants()) {
        const auto it = counts.find(nv.name);
        if (it == counts.end()) continue;
        auto p = make(nv.id, nv.values);
        if (!p) return;
        run(*p, in, keyed(*p) ? &key : nullptr, nv.values);
        float shown[caw::kMaxDisplayFloats];
        const uint32_t n = p->readDisplay(shown, caw::kMaxDisplayFloats);
        if (n != it->second) cawtest::fail(__FILE__, __LINE__, std::string(nv.name) + ": " + std::to_string(n) + " floats");
        for (uint32_t k = 0; k < n; ++k) CHECK(std::isfinite(shown[k]));
    }
}

TEST(the_new_variants_match_their_reference_renders) {
    const Stereo in = music(48000 * 2), key = kicks(48000 * 2);
    cawtest::References refs("fx_dynsplit");
    for (const NewVariant& nv : newVariants()) {
        auto p = make(nv.id, nv.values);
        if (!p) return;
        const Stereo out = run(*p, in, keyed(*p) ? &key : nullptr, nv.values);
        CHECK_REFERENCE(refs, nv.name, (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
    }
}
