// FX consolidation part E: Delay and Reverb, each variant an old class unchanged, and the old ids migrating to them.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "builtin_fx_racks.h"
#include "caw.h"
#include "component_chain.h"
#include "engine.h"
#include "fx_merged.h"
#include "fx_migrate.h"
#include "json.h"
#include "presets.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

namespace {

using Values = std::vector<std::pair<std::string, double>>;

// The devices and the old ids each replaces, by variant.
struct Device {
    const char* id;
    const char* old[2];
};
constexpr Device kDelay = {"org.caw.delay", {"org.caw.delay.pro", "org.caw.delay.pingpong"}};
constexpr Device kReverb = {"org.caw.reverb", {"org.caw.reverb.pro", "org.caw.shimmer"}};
constexpr const Device* kDevices[] = {&kDelay, &kReverb};

// The built-ins with the retired old ids registered again beside them (restoreRetired), so a variant can be
// compared with the old effect as it ran.
const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        x.restoreRetired();
        return x;
    }();
    return r;
}

struct Stereo {
    std::vector<float> l, r;
};

Stereo music(size_t frames, uint32_t seed = 99) {
    Stereo s{std::vector<float>(frames), std::vector<float>(frames)};
    for (size_t i = 0; i < frames; ++i) {
        if ((i / 9000) % 4 == 3) continue;  // a gap of silence: sleep and wake
        seed = seed * 1664525u + 1013904223u;
        const double nz = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * 0.1;
        s.l[i] = static_cast<float>(0.4 * std::sin(6.283185307179586 * 220.0 * i / 48000.0) + nz);
        s.r[i] = static_cast<float>(0.3 * std::sin(6.283185307179586 * 331.0 * i / 48000.0) - nz);
    }
    return s;
}

// `in` through p in 64-frame blocks, `values` over its defaults (an id it lacks is ignored).
Stereo run(ModuleProcessor& p, const Stereo& in, const Values& values) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    Stereo out{std::vector<float>(in.l.size()), std::vector<float>(in.l.size())};
    for (size_t start = 0; start < in.l.size(); start += 64) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(64, in.l.size() - start));
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        AudioProcessBlock b;
        b.input = {ic, 2, n};
        b.output = {oc, 2, n};
        b.frames = n;
        b.sampleRate = 48000;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        CHECK(p.process(b));
    }
    return out;
}

bool sameBits(const Stereo& a, const Stereo& b) {
    return a.l.size() == b.l.size() && std::memcmp(a.l.data(), b.l.data(), a.l.size() * 4) == 0 &&
           std::memcmp(a.r.data(), b.r.data(), a.r.size() * 4) == 0;
}

double peakOf(const Stereo& s) {
    double peak = 0;
    for (float x : s.l) peak = std::max(peak, std::fabs(static_cast<double>(x)));
    return peak;
}

std::unique_ptr<ModuleProcessor> active(std::unique_ptr<ModuleProcessor> p) {
    CHECK(p != nullptr);
    if (p) CHECK(p->activate(48000, 512));
    return p;
}

// Random values for every parameter of `d` but `variant`, inside their ranges and on their steps.
Values randomValues(const ModuleDescriptor& d, uint32_t& seed) {
    Values v;
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        const ParameterDescriptor& p = d.parameters[k];
        if (p.id == fx::kVariantParam) continue;
        seed = seed * 1664525u + 1013904223u;
        double x = p.minimum + (p.maximum - p.minimum) * (static_cast<double>(seed >> 8) / 16777216.0);
        if (p.step > 0) x = p.minimum + std::round((x - p.minimum) / p.step) * p.step;
        v.emplace_back(std::string(p.id), x);
    }
    return v;
}

double valueOf(const Values& v, std::string_view id, double fallback = -12345) {
    for (const auto& [k, x] : v)
        if (k == id) fallback = x;
    return fallback;
}

// A rack's parameter index + 1 for `param` with these values (a route's destination).
double destination(std::string_view rackId, const Values& values, std::string_view param) {
    std::unique_ptr<ModuleProcessor> p = registry().create(rackId);
    auto* rack = dynamic_cast<RackContainer*>(p.get());
    std::string error;
    if (!rack || !rack->configure(registry(), values, true, error)) return 0.0;
    const ModuleDescriptor& d = p->descriptor();
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == param) return k + 1.0;
    return 0.0;
}

Stereo renderChain(const std::vector<ComponentSpec>& specs, const Stereo& in) {
    std::string error;
    auto chain = ComponentChain::build(registry(), specs, 48000.0, error);
    if (!chain) cawtest::fail(__FILE__, __LINE__, error);
    Stereo out = in;
    if (!chain) return out;
    ChainTime t;
    t.stepLength = 6000.0;
    for (size_t start = 0, b = 0; start < in.l.size(); start += 64, ++b) {
        t.start = static_cast<int64_t>(start);
        t.chunk = static_cast<int64_t>(b);
        chain->process(out.l.data() + start, out.r.data() + start, 64, 48000.0, &t);
    }
    return out;
}

// The engine's output for a project JSON, `blocks` blocks of 256 frames from Play.
Stereo renderProject(const std::string& json, int blocks = 240) {
    ProjectSpec p;
    std::string error;
    if (!parseProject(json, p, error)) cawtest::fail(__FILE__, __LINE__, error);
    Engine e(48000);
    const std::string r = e.setProject(p);
    if (r.find("\"ok\":true") == std::string::npos) cawtest::fail(__FILE__, __LINE__, r);
    e.play();
    Stereo out{std::vector<float>(256 * blocks), std::vector<float>(256 * blocks)};
    for (int b = 0; b < blocks; ++b) e.process(out.l.data() + 256 * b, out.r.data() + 256 * b, 256);
    return out;
}

Json migrateJson(const std::string& entry) {
    char* text = caw_migrate_component(entry.c_str());
    Json j;
    std::string error;
    CHECK(text && parseJson(text, j, error) && j.boolean("ok", false));
    caw_free(text);
    return j;
}

}  // namespace

TEST(merged_delay_and_reverb_list_their_variants_as_the_old_descriptors_plus_variant) {
    for (const Device* dev : kDevices) {
        const fx::MergedDevice* m = fx::findMergedDevice(dev->id);
        CHECK(m != nullptr);
        if (!m) continue;
        CHECK_EQ(m->variants.size(), 2u);
        CHECK(registry().find(dev->id) == &m->variants[0].descriptor());
        for (uint32_t v = 0; v < 2; ++v) {
            const ModuleDescriptor& d = m->variants[v].descriptor();
            const ModuleDescriptor* old = registry().find(dev->old[v]);  // the old id stays registered (part F)
            CHECK(old != nullptr);
            if (!old) continue;
            CHECK(d.id == dev->id);
            CHECK_EQ(d.parameterCount, old->parameterCount + 1);
            for (uint32_t k = 0; k < old->parameterCount; ++k) {
                CHECK(d.parameters[k].id == old->parameters[k].id);
                CHECK_EQ(d.parameters[k].defaultValue, old->parameters[k].defaultValue);
            }
            const ParameterDescriptor& variant = d.parameters[d.parameterCount - 1];
            CHECK(variant.id == fx::kVariantParam);
            CHECK(!variant.automatable && !variant.modulatable && !variant.midiMappable);
            CHECK_EQ(variant.defaultValue, static_cast<double>(v));
            CHECK_EQ(variant.choiceCount, 2u);
            CHECK_EQ(d.tailFrames, old->tailFrames);
            CHECK_EQ(d.latencyFrames, old->latencyFrames);
            CHECK(d.cpuClass == old->cpuClass);
            CHECK_EQ(d.domains, old->domains);
            std::unique_ptr<ModuleProcessor> p = createComponent(registry(), dev->id, {{"variant", static_cast<double>(v)}});
            CHECK(p && &p->descriptor() == &d);
        }
    }
    CHECK(fx::findMergedDevice(kDelay.id)->variants[0].name == "Digital");
    CHECK(fx::findMergedDevice(kDelay.id)->variants[1].name == "Ping-pong");
    CHECK(fx::findMergedDevice(kReverb.id)->variants[0].name == "Hall");
    CHECK(fx::findMergedDevice(kReverb.id)->variants[1].name == "Shimmer");
    // Another variant's parameter is ignored, not refused; one of neither still is.
    CHECK(isOtherVariantParameter(kDelay.id, "cross") && isOtherVariantParameter(kDelay.id, "offset"));
    CHECK(isOtherVariantParameter(kReverb.id, "amount") && isOtherVariantParameter(kReverb.id, "freeze"));
    CHECK(!isOtherVariantParameter(kReverb.id, "cross") && !isOtherVariantParameter(kDelay.id, "amount"));
    CHECK(fx::findMergedDevice("org.caw.convolver") == nullptr && fx::findLegacyEffect("org.caw.convolver") == nullptr);
}

TEST(merged_delay_and_reverb_render_the_old_ids_bits_over_their_presets_and_random_values) {
    const Stereo in = music(36000);
    uint32_t seed = 2027;
    for (const Device* dev : kDevices)
        for (uint32_t v = 0; v < 2; ++v) {
            std::vector<Values> sets = {Values{}};  // the defaults
            for (const BuiltinPreset& p : builtinPresets(dev->old[v])) {
                Values x;
                for (const auto& [k, value] : p.values) x.emplace_back(std::string(k), value);
                sets.push_back(x);
            }
            for (int r = 0; r < 12; ++r) sets.push_back(randomValues(*registry().find(dev->old[v]), seed));
            for (const Values& values : sets) {
                auto old = active(registry().create(dev->old[v]));
                ComponentSpec spec;
                spec.id = dev->old[v];
                spec.params = values;
                CHECK(fx::migrateLegacyEffect(spec));
                CHECK(spec.id == dev->id && valueOf(spec.params, "variant") == v);
                CHECK_EQ(spec.params.size(), values.size() + 1);  // nothing renamed, dropped or added
                auto merged = active(createComponent(registry(), spec.id, spec.params));
                if (!old || !merged) return;
                const Stereo a = run(*old, in, values), b = run(*merged, in, spec.params);
                if (!sameBits(a, b)) cawtest::fail(__FILE__, __LINE__, std::string(dev->old[v]) + ": the merged variant's bits differ");
                // The display reads the same too.
                float da[256], db[256];
                const uint32_t na = old->readDisplay(da, 256), nb = merged->readDisplay(db, 256);
                CHECK_EQ(na, nb);
                CHECK(na == 0 || std::memcmp(da, db, na * sizeof(float)) == 0);
            }
            if (dev == &kDelay || v == 1) CHECK(sets.size() >= 13u);
        }
}

TEST(merged_delay_and_reverb_keep_each_variants_latency_and_tail) {
    for (const Device* dev : kDevices)
        for (uint32_t v = 0; v < 2; ++v)
            for (double mix : {0.0, 0.5, 1.0}) {
                ComponentSpec old;
                old.id = dev->old[v];
                old.params = {{"mix", mix}};
                ComponentSpec merged = old;
                CHECK(fx::migrateLegacyEffect(merged));
                std::string error;
                auto a = ComponentChain::build(registry(), {old}, 48000.0, error);
                auto b = ComponentChain::build(registry(), {merged}, 48000.0, error);
                CHECK(a && b);
                if (!a || !b) return;
                CHECK_EQ(a->latencyFrames(), b->latencyFrames());
                CHECK_EQ(b->latencyFrames(), 0u);
                CHECK_EQ(a->tailFrames(), b->tailFrames());
            }
}

TEST(merged_delay_and_reverb_resolve_the_old_presets_under_their_ids_with_equal_values) {
    for (const Device* dev : kDevices) {
        size_t total = 0;
        for (uint32_t v = 0; v < 2; ++v)
            for (const BuiltinPreset& p : builtinPresets(dev->old[v])) {
                ++total;
                const BuiltinPreset* merged = findBuiltinPreset(dev->id, p.name);
                CHECK(merged != nullptr);
                if (!merged) continue;
                CHECK(merged->description == p.description);
                std::map<std::string, double> want, got;
                for (const auto& [k, x] : p.values) want[std::string(k)] = x;
                want["variant"] = v;
                for (const auto& [k, x] : merged->values) got[std::string(k)] = x;
                CHECK(want == got);
                Values applied;
                CHECK(applyBuiltinPreset(dev->id, p.name, applied));
                CHECK_EQ(valueOf(applied, "variant"), static_cast<double>(v));
            }
        CHECK_EQ(builtinPresets(dev->id).size(), total);
    }
    CHECK(builtinPresets(kReverb.id).size() >= 3u);  // the shimmer's (the others have none)
}

TEST(a_saved_project_with_the_old_delays_and_reverbs_and_lanes_plays_the_merged_devices_the_same) {
    // A track with both delays and a rack holding the two reverbs (a route on the shimmer's mix), the master with
    // both reverbs, and lanes on a track delay's time and the master shimmer's decay.
    auto h = [](const char* id) { return std::to_string(static_cast<double>(rackChildHash(id))); };
    auto project = [&](const std::string& d0, const std::string& d1, const std::string& r0, const std::string& r1,
                       const std::string& rack) {
        return std::string(R"({"caw_project":1,"bpm":120,"loop_bars":2,"layers":[{"id":"t","volume":1,)"
                           R"("instrument":{"id":"org.caw.test.osc","params":{"shape":1,"freq":110,"level":0.5}},)"
                           R"("components":[)") + d0 + "," + d1 + "," + rack + R"(]}],"master_components":[)" + r0 +
               "," + r1 +
               R"(],"automation":[{"target_type":"component","layer":"t","component":1,"target":"time",)"
               R"("points":[{"step":0,"value":120},{"step":16,"value":600}]},)"
               R"({"target_type":"component","component":1,"target":"decay","points":[{"step":0,"value":1},{"step":32,"value":6}]}]})";
    };
    const std::string rackOld = R"({"id":"org.caw.rack.fx","params":{"s1_fx":)" + h("org.caw.reverb.pro") +
                                R"(,"s1.mix":0.4,"s2_fx":)" + h("org.caw.shimmer") + R"(,"s2.amount":0.7}})";
    const std::string rackNew = R"({"id":"org.caw.rack.fx","params":{"s1_fx":)" + h("org.caw.reverb") +
                                R"(,"s1.variant":0,"s1.mix":0.4,"s2_fx":)" + h("org.caw.reverb") +
                                R"(,"s2.variant":1,"s2.amount":0.7}})";
    const std::string oldJson = project(R"({"id":"org.caw.delay.pro","params":{"mode":1,"feedback":0.6,"mix":0.5}})",
                                        R"({"id":"org.caw.delay.pingpong","params":{"sync":0,"mix":0.6}})",
                                        R"({"id":"org.caw.reverb.pro","params":{"decay":3,"mix":0.3}})",
                                        R"({"id":"org.caw.shimmer","params":{"mix":0.4}})", rackOld);
    const std::string newJson = project(R"({"id":"org.caw.delay","params":{"variant":0,"mode":1,"feedback":0.6,"mix":0.5}})",
                                        R"({"id":"org.caw.delay","params":{"variant":1,"sync":0,"mix":0.6}})",
                                        R"({"id":"org.caw.reverb","params":{"decay":3,"mix":0.3}})",
                                        R"({"id":"org.caw.reverb","params":{"variant":1,"mix":0.4}})", rackNew);
    const Stereo a = renderProject(oldJson), b = renderProject(newJson);
    CHECK(sameBits(a, b));
    CHECK(peakOf(a) > 0.01);
    // The engine migrates the parsed project: every old id becomes its merged device, the lanes keep their targets.
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(oldJson, p, error));
    CHECK(fx::hasLegacyEffects(p));
    CHECK(fx::migrateLegacyEffects(p));
    CHECK(!fx::hasLegacyEffects(p));
    CHECK(p.layers[0].components[0].id == kDelay.id && p.layers[0].components[1].id == kDelay.id);
    CHECK(p.masterComponents[0].id == kReverb.id && p.masterComponents[1].id == kReverb.id);
    CHECK_EQ(valueOf(p.layers[0].components[1].params, "variant"), 1.0);
    CHECK_EQ(valueOf(p.masterComponents[1].params, "variant"), 1.0);
    CHECK_EQ(valueOf(p.layers[0].components[2].params, "s2.variant"), 1.0);
    CHECK_EQ(p.automation.size(), 2u);
    CHECK(p.automation[0].target == "time" && p.automation[1].target == "decay");
    // caw_migrate_component gives the app the same form for its document.
    const Json j = migrateJson(R"({"id":"org.caw.delay.pingpong","params":{"cross":0.5,"mix":0.25}})");
    CHECK(j.boolean("migrated", false) && j.string("id") == kDelay.id && j.boolean("keeps_state", false));
    const Json* ps = j.get("params");
    CHECK(ps && ps->number("variant", -1) == 1 && ps->number("cross", -1) == 0.5 && ps->number("mix", -1) == 0.25);
    CHECK(j.get("renamed") && j.get("renamed")->obj.empty() && j.get("dropped") && j.get("dropped")->arr.empty());
    const Json s = migrateJson(R"({"id":"org.caw.shimmer","params":{"shift":7}})");
    CHECK(s.string("id") == kReverb.id && s.get("params") && s.get("params")->number("variant", -1) == 1 &&
          s.get("params")->number("shift", -1) == 7);
    const Json r = migrateJson(R"({"id":"org.caw.reverb.pro","params":{}})");
    CHECK(r.string("id") == kReverb.id && r.get("params") && r.get("params")->number("variant", -1) == 0);
    const Json c = migrateJson(R"({"id":"org.caw.convolver","params":{}})");
    CHECK(!c.boolean("migrated", true) && c.string("id") == "org.caw.convolver");
}

TEST(a_racks_old_delays_and_reverbs_migrate_with_their_routes_and_sound_the_same) {
    auto h = [](const char* id) { return static_cast<double>(rackChildHash(id)); };
    ComponentSpec old;
    old.id = std::string(kFxRackId);
    old.params = {{"s1_fx", h("org.caw.delay.pingpong")}, {"s1.mix", 0.5}, {"s2_fx", h("org.caw.delay.pro")},
                  {"s2.feedback", 0.5},                   {"s3_fx", h("org.caw.shimmer")}, {"s3.mix", 0.3},
                  {"s4_fx", h("org.caw.reverb.pro")},     {"mod1_src", 1}, {"mod1_amt", 0.4},
                  {"mod2_src", 1},                        {"mod2_amt", -0.3}};
    old.params.emplace_back("mod1_dst", destination(kFxRackId, old.params, "s3.amount"));
    old.params.emplace_back("mod2_dst", destination(kFxRackId, old.params, "s4.decay"));
    CHECK(valueOf(old.params, "mod1_dst") > 0 && valueOf(old.params, "mod2_dst") > 0);
    ComponentSpec merged = old;
    fx::ParamRenames renames;
    CHECK(fx::migrateLegacyEffect(merged, &renames));
    CHECK(merged.id == kFxRackId && renames.empty());
    CHECK_EQ(valueOf(merged.params, "s1_fx"), h(kDelay.id));
    CHECK_EQ(valueOf(merged.params, "s2_fx"), h(kDelay.id));
    CHECK_EQ(valueOf(merged.params, "s3_fx"), h(kReverb.id));
    CHECK_EQ(valueOf(merged.params, "s4_fx"), h(kReverb.id));
    CHECK_EQ(valueOf(merged.params, "s1.variant"), 1.0);
    CHECK_EQ(valueOf(merged.params, "s2.variant"), 0.0);
    CHECK_EQ(valueOf(merged.params, "s3.variant"), 1.0);
    CHECK_EQ(valueOf(merged.params, "s4.variant"), 0.0);
    CHECK_EQ(valueOf(merged.params, "mod1_dst"), destination(kFxRackId, merged.params, "s3.amount"));
    CHECK_EQ(valueOf(merged.params, "mod2_dst"), destination(kFxRackId, merged.params, "s4.decay"));
    CHECK(valueOf(merged.params, "mod2_dst") != valueOf(old.params, "mod2_dst"));
    CHECK(!fx::migrateLegacyEffect(merged));  // done once
    const Stereo in = music(48000);
    const Stereo a = renderChain({old}, in);
    CHECK(sameBits(a, renderChain({merged}, in)));
    CHECK(!sameBits(a, in));
    // The rack presets that held the old delay and reverb (part F) name Delay and Reverb with their variants:
    // nothing to migrate, and they sound.
    size_t named = 0;
    const double delayHash = rackChildHash(kDelay.id), reverbHash = rackChildHash(kReverb.id);
    for (const char* rackId : {"org.caw.rack.fx", "org.caw.rack.multiband"})
        for (const BuiltinPreset& p : builtinPresets(rackId)) {
            ComponentSpec o;
            o.id = rackId;
            bool space = false;
            for (const auto& [k, x] : p.values) {
                o.params.emplace_back(std::string(k), x);
                space = space || (k.size() > 3 && k.substr(k.size() - 3) == "_fx" && (x == delayHash || x == reverbHash));
            }
            if (!space) continue;
            ++named;
            CHECK(!fx::migrateLegacyEffect(o));
            const Stereo out = renderChain({o}, in);
            if (sameBits(out, in)) cawtest::fail(__FILE__, __LINE__, std::string(rackId) + " preset " + std::string(p.name) + " is silent or dry");
        }
    CHECK(named >= 3u);
}

TEST(a_delay_or_reverb_variant_change_rebuilds_and_a_parameter_call_cant_change_it) {
    auto project = [](double variant, bool leftover) {
        ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
        ComponentSpec d, r;
        d.id = kDelay.id;
        d.params = {{"variant", variant}, {"mix", 0.4}, {"feedback", 0.5}};
        if (leftover) d.params.emplace_back(variant == 0 ? "cross" : "offset", 0.3);  // the other variant's
        r.id = kReverb.id;
        r.params = {{"variant", variant}, {"mix", 0.3}};
        if (leftover) r.params.emplace_back(variant == 0 ? "amount" : "freeze", 0);
        p.layers[0].components = {d, r};
        return p;
    };
    Engine e(48000);
    CHECK(e.setProject(project(0, false)).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(256), r(256);
    for (int b = 0; b < 40; ++b) e.process(l.data(), r.data(), 256);
    CHECK(!e.setComponentParam("t", 0, "variant", 1));
    CHECK(!e.setComponentParam("t", 1, "variant", 1));
    CHECK(e.setComponentParam("t", 0, "offset", 10));  // the digital delay's
    CHECK(e.setComponentParam("t", 1, "freeze", 0));   // the hall's
    CHECK(e.setProject(project(1, true)).find("\"ok\":true") != std::string::npos);  // leftovers ignored
    for (int b = 0; b < 40; ++b) e.process(l.data(), r.data(), 256);
    CHECK(e.setComponentParam("t", 0, "cross", 0.2));
    CHECK(!e.setComponentParam("t", 0, "offset", 10));
    CHECK(e.setComponentParam("t", 1, "amount", 0.4));
    CHECK(!e.setComponentParam("t", 1, "freeze", 1));
    ProjectSpec bad = project(0, false);
    bad.layers[0].components[1].params.emplace_back("cutoff", 1000);
    CHECK(e.setProject(bad).find("\"ok\":false") != std::string::npos);
}

TEST(the_components_json_lists_the_delay_and_reverb_variants) {
    Engine e(48000);
    Json j;
    std::string error;
    CHECK(parseJson(e.nativeComponentsJson(), j, error));
    const Json* list = j.get("components");
    CHECK(list != nullptr);
    if (!list) return;
    for (const Device* dev : kDevices) {
        const Json* found = nullptr;
        for (const Json& c : list->arr)
            if (c.string("id") == dev->id) found = &c;
        CHECK(found != nullptr);
        if (!found) continue;
        const Json* variants = found->get("variants");
        CHECK(variants && variants->arr.size() == 2u);
    }
}
