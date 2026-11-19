// FX consolidation part C: the merged EQ and Filter against the old ids they replace (renders, latency, presets, saved projects, racks).
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "builtin_effects.h"
#include "builtin_fx_racks.h"
#include "component_chain.h"
#include "engine.h"
#include "fx_merged.h"
#include "fx_migrate.h"
#include "presets.h"
#include "test.h"
#include "test_signal.h"

namespace caw::fx {
// The old classes' own descriptors and instances (builtin_effects_eq.cpp, builtin_fx_filters_eq.cpp,
// builtin_effects_kit.cpp, builtin_fx_filters.cpp).
const ModuleDescriptor& legacyEqDescriptor();
ModuleProcessor* makeEqAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyGeqDescriptor();
ModuleProcessor* makeGeqAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyEq3Descriptor();
ModuleProcessor* makeEq3As(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyTiltDescriptor();
ModuleProcessor* makeTiltAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyFilterDescriptor();
ModuleProcessor* makeFilterAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyLadderDescriptor();
ModuleProcessor* makeLadderAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyNlFilterDescriptor();
ModuleProcessor* makeNlFilterAs(const ModuleDescriptor& variant) noexcept;
}  // namespace caw::fx

using namespace caw;

namespace {

using Values = std::vector<std::pair<std::string, double>>;

constexpr const char* kEq = "org.caw.eq";
constexpr const char* kFilter = "org.caw.filter";

// One old effect: its id, the merged device and variant it becomes, and its class as it was (its own descriptor).
struct Old {
    const char* id;
    const char* merged;
    uint32_t variant;
    const ModuleDescriptor& (*descriptor)();
    ModuleProcessor* (*make)(const ModuleDescriptor&) noexcept;
    bool reused() const { return std::string_view(id) == merged; }  // the merged device kept this id
};
const Old kOld[] = {
    {"org.caw.eq", kEq, 0, &fx::legacyEqDescriptor, &fx::makeEqAs},
    {"org.caw.geq", kEq, 1, &fx::legacyGeqDescriptor, &fx::makeGeqAs},
    {"org.caw.eq.dj", kEq, 2, &fx::legacyEq3Descriptor, &fx::makeEq3As},
    {"org.caw.tilt", kEq, 3, &fx::legacyTiltDescriptor, &fx::makeTiltAs},
    {"org.caw.filter", kFilter, 0, &fx::legacyFilterDescriptor, &fx::makeFilterAs},
    {"org.caw.ladder", kFilter, 1, &fx::legacyLadderDescriptor, &fx::makeLadderAs},
    {"org.caw.nlfilter", kFilter, 2, &fx::legacyNlFilterDescriptor, &fx::makeNlFilterAs},
};

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

std::unique_ptr<ModuleProcessor> active(ModuleProcessor* raw) {
    std::unique_ptr<ModuleProcessor> p(raw);
    CHECK(p != nullptr);
    if (p) CHECK(p->activate(48000, 512));
    return p;
}

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

// The old id's own presets (a reused id has none of its own: its old presets would be listed under it already).
Values presetValues(const BuiltinPreset& p) {
    Values x;
    for (const auto& [k, value] : p.values) x.emplace_back(std::string(k), value);
    return x;
}
std::vector<const BuiltinPreset*> oldPresets(const Old& o) {
    std::vector<const BuiltinPreset*> out;
    if (!o.reused())
        for (const BuiltinPreset& p : builtinPresets(o.id)) out.push_back(&p);
    return out;
}

// The entry as a saved project holds it, migrated as the engine does (a reused id stays as it is: variant 0).
ComponentSpec migrated(const Old& o, const Values& values) {
    ComponentSpec spec;
    spec.id = o.id;
    spec.params = values;
    CHECK_EQ(fx::migrateLegacyEffect(spec), !o.reused());
    CHECK(spec.id == o.merged);
    CHECK_EQ(valueOf(spec.params, fx::kVariantParam, 0.0), static_cast<double>(o.variant));
    return spec;
}

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

Stereo renderProject(const std::string& json, int blocks = 200) {
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

}  // namespace

TEST(merged_eq_and_filter_list_the_old_effects_as_variants) {
    for (const Old& o : kOld) {
        const fx::MergedDevice* m = fx::findMergedDevice(o.merged);
        CHECK(m != nullptr);
        if (!m) return;
        // 1.1.0 appended EQ 4 Linear, 5 Match and Filter 3 Wah (new DSP: fx_eq_plume_test.cpp).
        CHECK_EQ(m->variants.size(), std::string_view(o.merged) == kEq ? 6u : 4u);
        const ModuleDescriptor& d = m->variants[o.variant].descriptor();
        const ModuleDescriptor& old = o.descriptor();
        CHECK(old.id == o.id);
        if (!o.reused()) CHECK(registry().find(o.id) == &old);  // the old id stays registered (until part F)
        CHECK(d.id == o.merged);
        CHECK_EQ(d.parameterCount, old.parameterCount + 1);
        for (uint32_t k = 0; k < old.parameterCount; ++k) CHECK(d.parameters[k].id == old.parameters[k].id);
        const ParameterDescriptor& variant = d.parameters[d.parameterCount - 1];
        CHECK(variant.id == fx::kVariantParam);
        CHECK(!variant.automatable && !variant.modulatable && !variant.midiMappable);
        CHECK_EQ(variant.defaultValue, static_cast<double>(o.variant));
        CHECK_EQ(variant.choiceCount, static_cast<uint32_t>(m->variants.size()));
        CHECK_EQ(d.tailFrames, old.tailFrames);
        CHECK_EQ(d.latencyFrames, old.latencyFrames);
        CHECK(d.cpuClass == old.cpuClass);
        std::unique_ptr<ModuleProcessor> p = createComponent(registry(), o.merged, {{"variant", static_cast<double>(o.variant)}});
        CHECK(p && &p->descriptor() == &d);
        // No optional ports: none of the old classes makes a low and high output alongside its response. Bands
        // has one input since 1.1.0: its dynamic bands' key.
        auto* fx = dynamic_cast<fx::EffectBase*>(p.get());
        if (o.variant == 0 && std::string_view(o.merged) == kEq) {
            CHECK(fx && fx->optionalPorts().size() == 1 && fx->optionalPorts()[0].input && fx->optionalPorts()[0].id == "key");
        } else {
            CHECK(fx && fx->optionalPorts().empty());
        }
    }
    // The registry lists each merged id (its first variant once the reused id's old registration gives way).
    for (const char* id : {kEq, kFilter}) {
        const ModuleDescriptor* r = registry().find(id);
        CHECK(r != nullptr);
        if (!r) continue;
        const fx::MergedDevice* m = fx::findMergedDevice(id);
        CHECK(r == &m->variants[0].descriptor() || r->parameterCount + 1 == m->variants[0].descriptor().parameterCount);
        // An entry with no `variant` plays variant 0: the old effect of that id.
        std::unique_ptr<ModuleProcessor> p = createComponent(registry(), id, {});
        CHECK(p && &p->descriptor() == &m->variants[0].descriptor());
    }
    CHECK(isOtherVariantParameter(kEq, "g17") && isOtherVariantParameter(kEq, "kill_mid") && isOtherVariantParameter(kEq, "tilt"));
    CHECK(isOtherVariantParameter(kFilter, "slope") && isOtherVariantParameter(kFilter, "shape"));
    CHECK(!isOtherVariantParameter(kFilter, "g17") && !isOtherVariantParameter(kEq, "slope"));
}

TEST(merged_eq_and_filter_render_the_old_ids_bits_over_their_presets_and_random_values) {
    const Stereo in = music(24000);
    uint32_t seed = 1808;
    for (const Old& o : kOld) {
        std::vector<Values> sets;
        for (const BuiltinPreset* p : oldPresets(o)) sets.push_back(presetValues(*p));
        sets.push_back({});
        for (int r = 0; r < 12; ++r) sets.push_back(randomValues(o.descriptor(), seed));
        for (const Values& values : sets) {
            auto old = active(o.make(o.descriptor()));  // the old class under its own descriptor
            const ComponentSpec spec = migrated(o, values);
            auto merged = active(createComponent(registry(), spec.id, spec.params).release());
            if (!old || !merged) return;
            const Stereo want = run(*old, in, values);
            if (!sameBits(want, run(*merged, in, spec.params)))
                cawtest::fail(__FILE__, __LINE__, std::string(o.id) + ": the merged variant's bits differ");
            if (!o.reused()) {  // and the old id's own registration, while it lasts
                auto registered = active(registry().create(o.id).release());
                if (registered && !sameBits(want, run(*registered, in, values)))
                    cawtest::fail(__FILE__, __LINE__, std::string(o.id) + ": the registered old id's bits differ");
            }
        }
    }
}

TEST(merged_eq_and_filter_report_each_variants_latency_and_tail_as_the_old_id_did) {
    uint32_t seed = 77;
    for (const Old& o : kOld)
        for (int r = 0; r < 4; ++r) {
            const Values values = randomValues(o.descriptor(), seed);
            auto old = active(o.make(o.descriptor()));
            const ComponentSpec spec = migrated(o, values);
            auto merged = active(createComponent(registry(), spec.id, spec.params).release());
            if (!old || !merged) return;
            CHECK_EQ(old->descriptor().latencyFrames, merged->descriptor().latencyFrames);
            CHECK_EQ(old->descriptor().tailFrames, merged->descriptor().tailFrames);
            if (o.reused()) continue;
            ComponentSpec plain;
            plain.id = o.id;
            plain.params = values;
            std::string error;
            auto a = ComponentChain::build(registry(), {plain}, 48000.0, error);
            auto b = ComponentChain::build(registry(), {spec}, 48000.0, error);
            CHECK(a && b);
            if (a && b) CHECK_EQ(a->latencyFrames(), b->latencyFrames());
        }
}

TEST(merged_eq_and_filter_resolve_the_old_presets_under_their_ids_with_equal_values) {
    std::map<std::string, size_t> total;
    for (const Old& o : kOld)
        for (const BuiltinPreset* p : oldPresets(o)) {
            ++total[o.merged];
            const BuiltinPreset* merged = findBuiltinPreset(o.merged, p->name);
            CHECK(merged != nullptr);
            if (!merged) continue;
            CHECK(merged->description == p->description);
            std::map<std::string, double> want, got;
            for (const auto& [k, x] : p->values) want[std::string(k)] = x;
            want["variant"] = o.variant;
            for (const auto& [k, x] : merged->values) got[std::string(k)] = x;
            if (want != got) cawtest::fail(__FILE__, __LINE__, std::string(o.id) + " preset " + std::string(p->name) + " differs");
            Values applied;
            CHECK(applyBuiltinPreset(o.merged, p->name, applied));
            CHECK_EQ(valueOf(applied, "variant"), static_cast<double>(o.variant));
        }
    // Then the 1.1.0 modes' own presets (Bands' dynamics, Linear, Match; Wah), each naming its variant.
    CHECK_EQ(builtinPresets(kEq).size(), total[kEq] + fx::newEqFilterVariantPresets(kEq).size());
    CHECK_EQ(builtinPresets(kFilter).size(), total[kFilter] + fx::newEqFilterVariantPresets(kFilter).size());
    CHECK(total[kEq] >= 10u && total[kFilter] >= 6u);
}

TEST(a_saved_project_with_the_old_eq_and_filter_ids_lanes_and_a_rack_plays_the_same) {
    // Track: graphic EQ, ladder, a rack (DJ EQ, nonlinear filter; a route to the filter's cutoff) and the old EQ and
    // filter; master: tilt, nonlinear filter. Lanes on the graphic EQ's band, the ladder's cutoff and the master's tilt.
    auto project = [&](const std::string& geq, const std::string& ladder, const std::string& rack, const std::string& tilt,
                       const std::string& nl) {
        return std::string(R"({"caw_project":1,"bpm":120,"loop_bars":2,"layers":[{"id":"t","volume":1,)"
                           R"("instrument":{"id":"org.caw.test.osc","params":{"shape":1,"freq":110,"level":0.5}},)"
                           R"("components":[)") +
               geq + "," + ladder + "," + rack +
               R"(,{"id":"org.caw.eq","params":{"b2_gain":4}},{"id":"org.caw.filter","params":{"cutoff":5000}}]}],)"
               R"("master_components":[)" + tilt + "," + nl +
               R"(],"automation":[{"target_type":"component","layer":"t","component":0,"target":"g12",)"
               R"("points":[{"step":0,"value":-9},{"step":16,"value":9}]},)"
               R"({"target_type":"component","layer":"t","component":1,"target":"cutoff",)"
               R"("points":[{"step":0,"value":300},{"step":32,"value":6000}]},)"
               R"({"target_type":"component","component":0,"target":"tilt","points":[{"step":0,"value":-6},{"step":32,"value":6}]}]})";
    };
    Values rackOld = {{"s1_fx", static_cast<double>(rackChildHash("org.caw.eq.dj"))}, {"s1.low", 3},
                      {"s2_fx", static_cast<double>(rackChildHash("org.caw.nlfilter"))}, {"s2.cutoff", 900},
                      {"mod1_src", 1}, {"mod1_amt", 0.4}};
    // The route as the old rack's list numbered it: the DJ EQ's parameters, then the nonlinear filter's.
    double oldDst = 0;
    {
        std::unique_ptr<ModuleProcessor> p = registry().create(kFxRackId);
        const ModuleDescriptor& own = p->descriptor();
        uint32_t ownCount = 0;
        for (uint32_t k = 0; k < own.parameterCount && own.parameters[k].id != "mod1_src"; ++k) ownCount = k + 1;
        oldDst = ownCount + fx::legacyEq3Descriptor().parameterCount + 2.0;  // s2's second parameter: cutoff
    }
    auto rackJson = [&](const Values& v, double dst) {
        std::string s = R"({"id":"org.caw.rack.fx","params":{)";
        for (const auto& [k, x] : v) s += "\"" + k + "\":" + std::to_string(x) + ",";
        return s + "\"mod1_dst\":" + std::to_string(dst) + "}}";
    };
    Values rackNew = {{"s1_fx", static_cast<double>(rackChildHash(kEq))}, {"s1.low", 3}, {"s1.variant", 2},
                      {"s2_fx", static_cast<double>(rackChildHash(kFilter))}, {"s2.cutoff", 900}, {"s2.variant", 2},
                      {"mod1_src", 1}, {"mod1_amt", 0.4}};
    const double newDst = destination(kFxRackId, rackNew, "s2.cutoff");
    CHECK(newDst > 0 && newDst == oldDst + 1.0);  // s1 grew by its `variant`
    const std::string oldJson = project(R"({"id":"org.caw.geq","params":{"g3":5,"range":1.2}})",
                                        R"({"id":"org.caw.ladder","params":{"mode":1,"resonance":0.6}})",
                                        rackJson(rackOld, oldDst), R"({"id":"org.caw.tilt","params":{"q":1}})",
                                        R"({"id":"org.caw.nlfilter","params":{"shape":3,"mix":0.6}})");
    const std::string newJson = project(R"({"id":"org.caw.eq","params":{"variant":1,"g3":5,"range":1.2}})",
                                        R"({"id":"org.caw.filter","params":{"variant":1,"mode":1,"resonance":0.6}})",
                                        rackJson(rackNew, newDst), R"({"id":"org.caw.eq","params":{"variant":3,"q":1}})",
                                        R"({"id":"org.caw.filter","params":{"variant":2,"shape":3,"mix":0.6}})");
    const Stereo a = renderProject(oldJson), b = renderProject(newJson);
    CHECK(sameBits(a, b));
    double peak = 0;
    for (float x : a.l) peak = std::max(peak, std::fabs(static_cast<double>(x)));
    CHECK(peak > 0.01);
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(oldJson, p, error));
    CHECK(fx::hasLegacyEffects(p));
    CHECK(fx::migrateLegacyEffects(p));
    CHECK(!fx::hasLegacyEffects(p));
    const auto& c = p.layers[0].components;
    CHECK(c[0].id == kEq && c[1].id == kFilter && c[3].id == kEq && c[4].id == kFilter);
    CHECK(p.masterComponents[0].id == kEq && p.masterComponents[1].id == kFilter);
    CHECK_EQ(valueOf(c[0].params, "variant"), 1.0);
    CHECK_EQ(valueOf(p.masterComponents[0].params, "variant"), 3.0);
    CHECK_EQ(valueOf(c[3].params, "variant", -1), -1.0);  // the reused ids are left alone: variant 0
    CHECK_EQ(valueOf(c[2].params, "s1.variant"), 2.0);
    CHECK_EQ(valueOf(c[2].params, "s2_fx"), static_cast<double>(rackChildHash(kFilter)));
    CHECK_EQ(valueOf(c[2].params, "mod1_dst"), newDst);
    CHECK_EQ(p.automation.size(), 3u);
}

TEST(a_merged_eq_variant_change_rebuilds_the_chain_and_a_parameter_call_cant_change_it) {
    auto project = [](double variant) {
        ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
        ComponentSpec c;
        c.id = kEq;
        c.params = {{"variant", variant}, {"output", -1}, {"g4", 3}, {"b2_gain", 2}};  // leftovers of other variants
        p.layers[0].components.push_back(c);
        return p;
    };
    Engine e(48000);
    CHECK(e.setProject(project(0)).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(256), r(256);
    for (int b = 0; b < 40; ++b) e.process(l.data(), r.data(), 256);
    CHECK(!e.setComponentParam("t", 0, "variant", 1));
    CHECK(e.setComponentParam("t", 0, "b2_gain", 3));
    CHECK(!e.setComponentParam("t", 0, "g4", 3));
    CHECK(e.setProject(project(1)).find("\"ok\":true") != std::string::npos);
    for (int b = 0; b < 40; ++b) e.process(l.data(), r.data(), 256);
    CHECK(e.setComponentParam("t", 0, "g4", 1));
    CHECK(!e.setComponentParam("t", 0, "b2_gain", 3));
    ProjectSpec bad = project(0);
    bad.layers[0].components[0].params.emplace_back("semitones", 3);  // no variant's
    CHECK(e.setProject(bad).find("\"ok\":false") != std::string::npos);
}
