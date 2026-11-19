// FX consolidation part D: Utility/Stereo, Chorus/Flanger, Phaser and Tremolo/Pan against the old effects they replace (bits, latency, presets, projects, racks, Utility's mid/side ports).
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
#include "builtin_fx_merged_stereomod.h"
#include "builtin_fx_racks.h"
#include "builtin_fx_space.h"
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

constexpr const char* kUtility = "org.caw.utility";
constexpr const char* kChorus = "org.caw.chorus";
constexpr const char* kPhaser = "org.caw.phaser";
constexpr const char* kTremolo = "org.caw.tremolo";

// Every old id of part D: the merged device, its variant there, and the old class under its own descriptor.
struct Old {
    const char* id;
    const char* device;
    uint32_t variant;
    const ModuleDescriptor& (*legacy)();
    ModuleProcessor* (*makeAs)(const ModuleDescriptor&) noexcept;
};
const Old kOld[] = {
    {"org.caw.utility", kUtility, 0, &fx::legacyUtilityDescriptor, &fx::makeUtilityAs},
    {"org.caw.stereo.width", kUtility, 1, &fx::legacyWidthDescriptor, &fx::makeWidthAs},
    {"org.caw.stereo.balance", kUtility, 2, &fx::legacyBalanceDescriptor, &fx::makeBalanceAs},
    {"org.caw.imager", kUtility, 3, &fx::legacyImagerDescriptor, &fx::makeImagerAs},
    {"org.caw.haas", kUtility, 4, &fx::legacyHaasDescriptor, &fx::makeHaasAs},
    {"org.caw.channelmixer", kUtility, 5, &fx::legacyChannelMixerDescriptor, &fx::makeChannelMixerAs},
    {"org.caw.chorus", kChorus, 0, &fx::legacyChorusDescriptor, &fx::makeChorusAs},
    {"org.caw.ensemble", kChorus, 1, &fx::legacyEnsembleDescriptor, &fx::makeEnsembleAs},
    {"org.caw.doubler", kChorus, 2, &fx::legacyDoublerDescriptor, &fx::makeDoublerAs},
    {"org.caw.flanger", kChorus, 3, &fx::legacyFlangerDescriptor, &fx::makeFlangerAs},
    {"org.caw.vibrato", kChorus, 4, &fx::legacyVibratoDescriptor, &fx::makeVibratoAs},
    {"org.caw.rotary", kChorus, 5, &fx::legacyRotaryDescriptor, &fx::makeRotaryAs},
    {"org.caw.phaser", kPhaser, 0, &fx::legacyPhaserDescriptor, &fx::makePhaserAs},
    {"org.caw.tremolo", kTremolo, 0, &fx::legacyTremoloDescriptor, &fx::makeTremoloAs},
    {"org.caw.autopan", kTremolo, 1, &fx::legacyAutopanDescriptor, &fx::makeAutopanAs},
    // 1.1.0: the drawn-shape ducker (1.0.8-1.0.9: the Compressor's variant 3) is Tremolo/Pan's Shape.
    {"org.caw.ducker", kTremolo, 2, &fx::legacyDuckerDescriptor, &fx::makeDuckerAs},
};

bool reused(const Old& o) { return std::string(o.id) == o.device; }

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

// The old effects as they were registered before the merge (their own files' register functions alone).
const ModuleRegistry& pristine() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        fx::registerKit(x);
        fx::registerFxSpaceMod(x);
        fx::registerFxSpaceStereo(x);
        return x;
    }();
    return r;
}

// The old effect, as it ran before: its registered class where it can be made alone, else the class under its
// own descriptor (Width, Balance and Chorus live with every other built-in).
std::unique_ptr<ModuleProcessor> makeOld(const Old& o) {
    if (pristine().find(o.id)) return pristine().create(o.id);
    return std::unique_ptr<ModuleProcessor>(o.makeAs(o.legacy()));
}

struct Stereo {
    std::vector<float> l, r;
};

Stereo music(size_t frames, uint32_t seed = 7) {
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

std::vector<ParameterValue> paramsFor(const ModuleDescriptor& d, const Values& values) {
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    return params;
}

// `in` through p in 64-frame blocks, `values` over its defaults (an id it lacks is ignored); `connect` is called
// before each block (an optional port's buffers).
template <class Connect>
Stereo run(ModuleProcessor& p, const Stereo& in, const Values& values, Connect connect) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params = paramsFor(d, values);
    Stereo out{std::vector<float>(in.l.size()), std::vector<float>(in.l.size())};
    for (size_t start = 0; start < in.l.size(); start += 64) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(64, in.l.size() - start));
        connect(start, n);
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
Stereo run(ModuleProcessor& p, const Stereo& in, const Values& values) {
    return run(p, in, values, [](size_t, uint32_t) {});
}

bool sameBits(const Stereo& a, const Stereo& b) {
    return a.l.size() == b.l.size() && std::memcmp(a.l.data(), b.l.data(), a.l.size() * 4) == 0 &&
           std::memcmp(a.r.data(), b.r.data(), a.r.size() * 4) == 0;
}

std::unique_ptr<ModuleProcessor> active(std::unique_ptr<ModuleProcessor> p) {
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

// The entry an old id becomes: migrated, or (a reused id, variant 0) the same entry, which runs variant 0.
ComponentSpec migrated(const Old& o, const Values& values) {
    ComponentSpec spec;
    spec.id = o.id;
    spec.params = values;
    CHECK_EQ(fx::migrateLegacyEffect(spec), !reused(o));
    CHECK(spec.id == o.device);
    if (!reused(o)) CHECK_EQ(valueOf(spec.params, "variant"), static_cast<double>(o.variant));
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

}  // namespace

TEST(stereomod_devices_list_their_variants_as_the_old_effects_descriptors) {
    const std::map<std::string, size_t> counts = {{kUtility, 6}, {kChorus, 6}, {kPhaser, 1}, {kTremolo, 3}};
    for (const auto& [id, count] : counts) {
        const fx::MergedDevice* m = fx::findMergedDevice(id);
        CHECK(m != nullptr);
        if (!m) continue;
        CHECK_EQ(m->variants.size(), count);
        // The reused id is registered as the merged device: its first variant, `variant` among its parameters.
        CHECK(registry().find(id) == &m->variants[0].descriptor());
    }
    for (const Old& o : kOld) {
        const fx::MergedDevice* m = fx::findMergedDevice(o.device);
        if (!m || o.variant >= m->variants.size()) {
            cawtest::fail(__FILE__, __LINE__, std::string(o.id) + ": no variant");
            continue;
        }
        const ModuleDescriptor& d = m->variants[o.variant].descriptor();
        const ModuleDescriptor& old = o.legacy();
        CHECK(old.id == o.id);
        if (!reused(o)) CHECK(registry().find(o.id) != nullptr && registry().find(o.id)->parameterCount == old.parameterCount);
        CHECK(d.id == o.device);
        CHECK_EQ(d.parameterCount, old.parameterCount + 1);
        for (uint32_t k = 0; k < old.parameterCount; ++k) CHECK(d.parameters[k].id == old.parameters[k].id);
        const ParameterDescriptor& variant = d.parameters[d.parameterCount - 1];
        CHECK(variant.id == fx::kVariantParam);
        CHECK(!variant.automatable && !variant.modulatable && !variant.midiMappable);
        CHECK_EQ(variant.defaultValue, static_cast<double>(o.variant));
        CHECK_EQ(variant.choiceCount, static_cast<uint32_t>(m->variants.size()));
        CHECK_EQ(d.latencyFrames, old.latencyFrames);
        CHECK_EQ(d.tailFrames, old.tailFrames);
        CHECK(d.cpuClass == old.cpuClass && d.domains == old.domains && d.portCount == old.portCount);
        std::unique_ptr<ModuleProcessor> p = createComponent(registry(), o.device, {{"variant", static_cast<double>(o.variant)}});
        CHECK(p && &p->descriptor() == &d);
    }
    // org.caw.downmix stays its own device.
    CHECK(fx::findMergedDevice("org.caw.downmix") == nullptr && fx::findLegacyEffect("org.caw.downmix") == nullptr);
}

TEST(stereomod_variants_render_the_old_ids_bits_over_their_presets_and_random_values) {
    const Stereo in = music(24000);
    uint32_t seed = 4242;
    for (const Old& o : kOld) {
        std::vector<Values> sets{{}};
        for (const BuiltinPreset& p : ownBuiltinPresets(o.id)) {
            Values x;
            for (const auto& [k, value] : p.values) x.emplace_back(std::string(k), value);
            sets.push_back(x);
        }
        for (int r = 0; r < 12; ++r) sets.push_back(randomValues(o.legacy(), seed));
        for (const Values& values : sets) {
            auto old = active(makeOld(o));
            const ComponentSpec spec = migrated(o, values);
            auto merged = active(createComponent(registry(), spec.id, spec.params));
            if (!old || !merged) return;
            CHECK(&merged->descriptor() == &fx::findMergedDevice(o.device)->variants[o.variant].descriptor());
            if (!sameBits(run(*old, in, values), run(*merged, in, spec.params)))
                cawtest::fail(__FILE__, __LINE__, std::string(o.id) + ": the merged variant's bits differ");
        }
    }
}

TEST(stereomod_variants_report_the_old_ids_latency_and_tail_in_a_chain) {
    for (const Old& o : kOld) {
        if (reused(o)) continue;  // the old id is the device itself (its descriptor is checked above)
        ComponentSpec old;
        old.id = o.id;
        const ComponentSpec merged = migrated(o, {});
        std::string error;
        auto a = ComponentChain::build(registry(), {old}, 48000.0, error);
        auto b = ComponentChain::build(registry(), {merged}, 48000.0, error);
        CHECK(a && b);
        if (!a || !b) return;
        CHECK_EQ(a->latencyFrames(), b->latencyFrames());
        CHECK_EQ(a->tailFrames(), b->tailFrames());
    }
}

TEST(stereomod_devices_hold_every_old_preset_with_equal_values) {
    std::map<std::string, size_t> total;
    for (const Old& o : kOld)
        for (const BuiltinPreset& p : ownBuiltinPresets(o.id)) {
            ++total[o.device];
            const BuiltinPreset* merged = nullptr;
            for (const BuiltinPreset& q : builtinPresets(o.device))  // names may repeat across variants
                if (q.name == p.name && q.description == p.description) merged = &q;
            CHECK(merged != nullptr);
            if (!merged) continue;
            std::map<std::string, double> want, got;
            for (const auto& [k, x] : p.values) want[std::string(k)] = x;
            want["variant"] = o.variant;
            for (const auto& [k, x] : merged->values) got[std::string(k)] = x;
            CHECK(want == got);
        }
    // Then 1.1.0's appended ones (the Phaser's, which had none), last.
    for (const auto& [device, n] : total) CHECK_EQ(builtinPresets(device).size(), n + fx::appendedVariantPresets(device).size());
    CHECK(fx::appendedVariantPresets(kPhaser).size() >= 8u);
    if (!total.count(kPhaser)) CHECK_EQ(builtinPresets(kPhaser).size(), fx::appendedVariantPresets(kPhaser).size());
    // The reused Tremolo id keeps its own presets (variant 0) and gains Auto-pan's (variant 1) and the ducker's (2).
    CHECK(!ownBuiltinPresets("org.caw.tremolo").empty() && !ownBuiltinPresets("org.caw.autopan").empty());
    CHECK_EQ(builtinPresets(kTremolo).size(), ownBuiltinPresets("org.caw.tremolo").size() +
                                                  ownBuiltinPresets("org.caw.autopan").size() +
                                                  ownBuiltinPresets("org.caw.ducker").size());
    Values applied;
    CHECK(applyBuiltinPreset(kTremolo, builtinPresets(kTremolo).back().name, applied));
    CHECK_EQ(valueOf(applied, "variant"), 1.0);
}

TEST(a_saved_project_with_stereomod_old_ids_and_lanes_plays_the_merged_devices_the_same) {
    auto project = [](const std::string& track, const std::string& master) {
        return std::string(R"({"caw_project":1,"bpm":120,"loop_bars":2,"layers":[{"id":"t","volume":1,)"
                           R"("instrument":{"id":"org.caw.test.osc","params":{"shape":1,"freq":110,"level":0.5}},)"
                           R"("components":[)") + track + R"(]}],"master_components":[)" + master +
               R"(],"automation":[{"target_type":"component","layer":"t","component":0,"target":"width",)"
               R"("points":[{"step":0,"value":0.2},{"step":16,"value":1.8}]},)"
               R"({"target_type":"component","layer":"t","component":4,"target":"rate","points":[{"step":0,"value":0.5},{"step":32,"value":6}]},)"
               R"({"target_type":"component","component":1,"target":"depth","points":[{"step":0,"value":0.1},{"step":32,"value":0.9}]}]})";
    };
    const std::string oldJson = project(
        R"({"id":"org.caw.stereo.width","params":{"width":1.4}},{"id":"org.caw.haas","params":{}},)"
        R"({"id":"org.caw.ensemble","params":{}},{"id":"org.caw.flanger","params":{"mix":0.6}},)"
        R"({"id":"org.caw.autopan","params":{"sync":0}},{"id":"org.caw.phaser","params":{}},{"id":"org.caw.utility","params":{"gain":-3}})",
        R"({"id":"org.caw.chorus","params":{}},{"id":"org.caw.tremolo","params":{"depth":0.5}},{"id":"org.caw.imager","params":{}},)"
        R"({"id":"org.caw.channelmixer","params":{}},{"id":"org.caw.rotary","params":{}},{"id":"org.caw.doubler","params":{}},)"
        R"({"id":"org.caw.vibrato","params":{}},{"id":"org.caw.stereo.balance","params":{"pan":0.3}})");
    const std::string newJson = project(
        R"({"id":"org.caw.utility","params":{"variant":1,"width":1.4}},{"id":"org.caw.utility","params":{"variant":4}},)"
        R"({"id":"org.caw.chorus","params":{"variant":1}},{"id":"org.caw.chorus","params":{"variant":3,"mix":0.6}},)"
        R"({"id":"org.caw.tremolo","params":{"variant":1,"sync":0}},{"id":"org.caw.phaser","params":{"variant":0}},)"
        R"({"id":"org.caw.utility","params":{"variant":0,"gain":-3}})",
        R"({"id":"org.caw.chorus","params":{}},{"id":"org.caw.tremolo","params":{"depth":0.5}},{"id":"org.caw.utility","params":{"variant":3}},)"
        R"({"id":"org.caw.utility","params":{"variant":5}},{"id":"org.caw.chorus","params":{"variant":5}},)"
        R"({"id":"org.caw.chorus","params":{"variant":2}},{"id":"org.caw.chorus","params":{"variant":4}},)"
        R"({"id":"org.caw.utility","params":{"variant":2,"pan":0.3}})");
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
    CHECK(p.layers[0].components[0].id == kUtility && p.layers[0].components[4].id == kTremolo);
    CHECK_EQ(p.automation.size(), 3u);  // every lane kept, on the same parameter ids
    // caw_migrate_component: an old entry and a preset.
    char* text = caw_migrate_component(R"({"id":"org.caw.autopan","params":{"rate":2}})");
    Json j;
    CHECK(text && parseJson(text, j, error));
    caw_free(text);
    CHECK(j.boolean("migrated", false) && j.string("id") == kTremolo && j.boolean("keeps_state", false));
    CHECK(j.get("params") && j.get("params")->number("variant", -1) == 1 && j.get("params")->number("rate", -1) == 2);
    text = caw_migrate_component(R"({"id":"org.caw.utility","params":{"gain":2}})");  // a reused id: nothing to do
    CHECK(text && parseJson(text, j, error));
    caw_free(text);
    CHECK(!j.boolean("migrated", true) && j.string("id") == kUtility);
}

TEST(a_racks_stereomod_old_children_migrate_with_routes_and_sound_the_same) {
    auto h = [](const char* id) { return static_cast<double>(rackChildHash(id)); };
    ComponentSpec old;
    old.id = std::string(kFxRackId);
    old.params = {{"s1_fx", h("org.caw.haas")},   {"s1.delay", 12},     {"s2_fx", h("org.caw.flanger")},
                  {"s2.mix", 0.4},                {"s3_fx", h("org.caw.autopan")}, {"s4_fx", h("org.caw.utility")},
                  {"s4.width", 1.5},              {"mod1_src", 1},      {"mod1_amt", 0.4},
                  {"mod2_src", 1},                {"mod2_amt", -0.3}};
    old.params.emplace_back("mod1_dst", destination(kFxRackId, old.params, "s2.mix"));
    old.params.emplace_back("mod2_dst", destination(kFxRackId, old.params, "s4.width"));
    CHECK(valueOf(old.params, "mod1_dst") > 0 && valueOf(old.params, "mod2_dst") > 0);
    ComponentSpec merged = old;
    fx::ParamRenames renames;
    CHECK(fx::migrateLegacyEffect(merged, &renames));
    CHECK(renames.empty());
    CHECK_EQ(valueOf(merged.params, "s1_fx"), h(kUtility));
    CHECK_EQ(valueOf(merged.params, "s2_fx"), h(kChorus));
    CHECK_EQ(valueOf(merged.params, "s3_fx"), h(kTremolo));
    CHECK_EQ(valueOf(merged.params, "s4_fx"), h(kUtility));
    CHECK_EQ(valueOf(merged.params, "s1.variant"), 4.0);
    CHECK_EQ(valueOf(merged.params, "s2.variant"), 3.0);
    CHECK_EQ(valueOf(merged.params, "s3.variant"), 1.0);
    CHECK_EQ(valueOf(merged.params, "mod1_dst"), destination(kFxRackId, merged.params, "s2.mix"));
    CHECK_EQ(valueOf(merged.params, "mod2_dst"), destination(kFxRackId, merged.params, "s4.width"));
    CHECK(valueOf(merged.params, "mod2_dst") != valueOf(old.params, "mod2_dst"));
    const Stereo in = music(48000);
    CHECK(sameBits(renderChain({old}, in), renderChain({merged}, in)));
}

TEST(an_old_rack_with_a_reused_id_child_keeps_its_route_on_the_same_knob) {
    // Saved before the merge: s1 Utility and s2 Chorus (both ids now merged devices, `variant` appended to their
    // lists), s3 Phaser; routes to s2.mix and s3.mix, whose indices were one and two lower then.
    auto h = [](const char* id) { return static_cast<double>(rackChildHash(id)); };
    ComponentSpec expected;
    expected.id = std::string(kFxRackId);
    expected.params = {{"s1_fx", h(kUtility)}, {"s1.width", 1.5}, {"s1.variant", 0}, {"s2_fx", h(kChorus)},
                       {"s2.variant", 0}, {"s3_fx", h(kPhaser)}, {"s3.variant", 0}, {"mod1_src", 1}, {"mod1_amt", 0.5},
                       {"mod2_src", 2}, {"mod2_amt", -0.5}};
    expected.params.emplace_back("mod1_dst", destination(kFxRackId, expected.params, "s2.mix"));
    expected.params.emplace_back("mod2_dst", destination(kFxRackId, expected.params, "s3.mix"));
    expected.params.emplace_back(std::string(kRackLayoutParam), kRackLayoutCurrent);
    ComponentSpec old;
    old.id = expected.id;
    for (const auto& [k, v] : expected.params) {
        if (k.ends_with(".variant") || k == kRackLayoutParam) continue;
        old.params.emplace_back(k, k == "mod1_dst" ? v - 1 : k == "mod2_dst" ? v - 2 : v);
    }
    ComponentSpec merged = old;
    CHECK(fx::migrateLegacyEffect(merged));
    for (const char* k : {"mod1_dst", "mod2_dst", "s1.variant", "s2.variant", "s3.variant"})
        CHECK_EQ(valueOf(merged.params, k), valueOf(expected.params, k));
    CHECK_EQ(valueOf(merged.params, kRackLayoutParam), kRackLayoutCurrent);
    const Stereo in = music(32000);
    CHECK(sameBits(renderChain({merged}, in), renderChain({expected}, in)));
    const ComponentSpec once = merged;
    CHECK(!fx::migrateLegacyEffect(merged));
    CHECK(merged.params == once.params);
}

TEST(utility_offers_mid_and_side_outputs_that_change_nothing_heard) {
    const Stereo in = music(30000);
    const Values values = {{"width", 1.3}, {"pan", 0.2}, {"gain", -2}, {"bass_mono", 1}};
    auto old = active(pristine().create("org.caw.utility"));
    auto merged = active(createComponent(registry(), kUtility, {}));
    if (!old || !merged) return;
    auto* fxm = dynamic_cast<fx::EffectBase*>(merged.get());
    CHECK(fxm != nullptr);
    if (!fxm) return;
    const auto ports = fxm->optionalPorts();
    CHECK_EQ(ports.size(), 2u);
    CHECK(ports.size() == 2u && ports[0].id == "mid" && ports[1].id == "side" && !ports[0].input && !ports[1].input);
    CHECK_EQ(dynamic_cast<fx::EffectBase*>(old.get())->optionalPorts().size(), 0u);
    const Stereo a = run(*old, in, values);
    CHECK(sameBits(a, run(*merged, in, values)));  // declared, unconnected: the same bits
    // Connected: the output stays the same; mid is M on both sides, side is S and -S, and the two sum to the output.
    merged->reset();
    Stereo mid{std::vector<float>(in.l.size()), std::vector<float>(in.l.size())}, side = mid;
    const Stereo c = run(*merged, in, values, [&](size_t start, uint32_t) {
        CHECK(fxm->connectOptionalPort(0, mid.l.data() + start, mid.r.data() + start));
        CHECK(fxm->connectOptionalPort(1, side.l.data() + start, side.r.data() + start));
    });
    CHECK(sameBits(a, c));
    double err = 0, energy = 0;
    bool shaped = true;
    for (size_t i = 0; i < in.l.size(); ++i) {
        shaped = shaped && mid.l[i] == mid.r[i] && side.r[i] == -side.l[i];
        err = std::max(err, std::fabs(static_cast<double>(mid.l[i] + side.l[i]) - a.l[i]));
        err = std::max(err, std::fabs(static_cast<double>(mid.r[i] + side.r[i]) - a.r[i]));
        energy += static_cast<double>(side.l[i]) * side.l[i];
    }
    CHECK(shaped);
    CHECK(err < 1e-6);
    CHECK(energy > 1.0);  // the side carries something (a wide, panned signal)
    CHECK(fxm->connectOptionalPort(0, nullptr, nullptr) && fxm->connectOptionalPort(1, nullptr, nullptr));
}
