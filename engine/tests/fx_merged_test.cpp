// The FX consolidation's framework: merged devices and their variants, the migration of old ids (Pitch/Shift as the template), optional ports.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <span>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "builtin_effects.h"
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

constexpr const char* kShift = "org.caw.shift";
// The old ids Pitch/Shift replaces, by variant.
const char* const kOld[] = {"org.caw.pitchshift", "org.caw.freqshift"};

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
Stereo run(ModuleProcessor& p, const Stereo& in, const Values& values, uint32_t block = 64) {
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

Json migrateJson(const char* entry) {
    char* text = caw_migrate_component(entry);
    Json j;
    std::string error;
    CHECK(text && parseJson(text, j, error) && j.boolean("ok", false));
    caw_free(text);
    return j;
}

}  // namespace

TEST(merged_pitch_shift_lists_its_variants_with_a_structural_variant_parameter) {
    const fx::MergedDevice* m = fx::findMergedDevice(kShift);
    CHECK(m != nullptr);
    if (!m) return;
    CHECK_EQ(m->variants.size(), 2u);
    CHECK(registry().find(kShift) == &m->variants[0].descriptor());  // the registry lists the first variant's
    for (uint32_t v = 0; v < 2; ++v) {
        const ModuleDescriptor& d = m->variants[v].descriptor();
        const ModuleDescriptor* old = registry().find(kOld[v]);
        CHECK(old != nullptr);
        if (!old) continue;
        CHECK(d.id == kShift);
        CHECK_EQ(d.parameterCount, old->parameterCount + 1);
        for (uint32_t k = 0; k < old->parameterCount; ++k) CHECK(d.parameters[k].id == old->parameters[k].id);
        const ParameterDescriptor& variant = d.parameters[d.parameterCount - 1];
        CHECK(variant.id == fx::kVariantParam);
        CHECK(!variant.automatable && !variant.modulatable && !variant.midiMappable);
        CHECK_EQ(variant.defaultValue, static_cast<double>(v));
        CHECK_EQ(variant.choiceCount, 2u);
        CHECK_EQ(d.tailFrames, old->tailFrames);
        CHECK_EQ(d.latencyFrames, old->latencyFrames);
        CHECK(d.cpuClass == old->cpuClass);
        // createComponent makes the variant's own class, under its own descriptor.
        std::unique_ptr<ModuleProcessor> p = createComponent(registry(), kShift, {{"variant", static_cast<double>(v)}});
        CHECK(p && &p->descriptor() == &d);
    }
    CHECK(isOtherVariantParameter(kShift, "semitones") && isOtherVariantParameter(kShift, "shift"));
    CHECK(!isOtherVariantParameter(kShift, "cutoff") && !isOtherVariantParameter("org.caw.eq", "semitones"));
    // The families not built yet list nothing; every merged device has at least one variant.
    for (const fx::MergedDevice* d : fx::mergedDevices()) CHECK(!d->variants.empty());
}

TEST(a_merged_device_reusing_an_old_id_replaces_its_registration_in_place) {
    // registerMergedDevices runs after the old effects: replaceBuiltin swaps the old registration for the merged
    // device's first variant, keeping its place in the list; a loaded or internal one is never replaced.
    ModuleRegistry r;
    const ModuleDescriptor* oldShift = registry().find("org.caw.pitchshift");
    const ModuleDescriptor* freq = registry().find("org.caw.freqshift");
    CHECK(oldShift && freq);
    if (!oldShift || !freq) return;
    const ModuleFactory none = []() noexcept -> ModuleProcessor* { return nullptr; };
    CHECK(r.add(*oldShift, none));
    CHECK(r.add(*freq, none));
    const fx::MergedDevice* m = fx::findMergedDevice(kShift);
    CHECK(m != nullptr);
    if (!m) return;
    // A stand-in for a reused id: the merged descriptor under the old id's name is what replaceBuiltin keys on.
    ModuleDescriptor reused = m->variants[0].descriptor();
    reused.id = "org.caw.pitchshift";
    CHECK(r.replaceBuiltin(reused, m->variants[0].create));
    CHECK(r.find("org.caw.pitchshift") == &reused);
    CHECK_EQ(r.builtinComponents().size(), 2u);
    CHECK(r.builtinComponents()[0] == &reused);  // its place kept
    CHECK(r.replaceBuiltin(m->variants[0].descriptor(), m->variants[0].create));  // a new id: added
    CHECK_EQ(r.builtinComponents().size(), 3u);
    // The engine's own registry lists every merged id with its first variant's descriptor, `variant` among them.
    for (const fx::MergedDevice* d : fx::mergedDevices()) {
        const ModuleDescriptor* listed = registry().find(d->id);
        CHECK(listed == &d->variants[0].descriptor());
        CHECK(listed && listed->parameterCount > 0 && listed->parameters[listed->parameterCount - 1].id == fx::kVariantParam);
    }
    // A merged id's presets are its own (a reused id's, variant 0) and its old effects'; any other id's are its own.
    CHECK(&builtinPresets("org.caw.convolver") == &ownBuiltinPresets("org.caw.convolver"));  // stays its own device
    CHECK(ownBuiltinPresets(kShift).empty() && builtinPresets(kShift).size() >= 10u);
}

TEST(the_old_ids_are_retired_but_still_play_as_their_merged_devices) {
    // Part F: no old id is registered, listed or made as a top-level device; each one names its merged device's
    // variant wherever a caller still names it (a project, caw_migrate_component, createNativeComponent).
    ModuleRegistry plain;
    registerBuiltinComponents(plain);
    Engine e(48000);
    const std::string json = e.nativeComponentsJson();
    CHECK(fx::legacyEffects().size() == 30u);
    for (const fx::LegacyEffect* old : fx::legacyEffects()) {
        const std::string id(old->from);
        CHECK(plain.find(id) == nullptr);
        CHECK(plain.create(id) == nullptr);
        for (const ModuleDescriptor* d : plain.builtinComponents()) CHECK(d->id != old->from);
        if (json.find("\"id\":\"" + id + "\"") != std::string::npos) cawtest::fail(__FILE__, __LINE__, id + " is still listed");
        // Engine::createNativeComponent makes the variant the old id became: the merged descriptor, `variant` set.
        std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(id);
        CHECK(p != nullptr);
        if (p) {
            const fx::MergedDevice* m = fx::findMergedDevice(old->to);
            CHECK(m && &p->descriptor() == &m->variants[old->variant].descriptor());
        }
        // The old class's own descriptor is kept (for a rack's routes and caw_migrate_component).
        CHECK(old->legacy != nullptr && old->legacy().id == old->from);
        // The old presets still resolve under the old id, and under the merged id with the variant.
        for (const BuiltinPreset& preset : ownBuiltinPresets(id)) {
            const BuiltinPreset* merged = findBuiltinPreset(old->to, preset.name);
            CHECK(merged != nullptr);
            const Json j = migrateJson(("{\"id\":\"" + id + "\",\"preset\":\"" + std::string(preset.name) + "\"}").c_str());
            CHECK(j.boolean("ok", false) && j.string("id") == std::string(old->to));
        }
    }
    // No shipped preset of any listed device needs migration: each merged device's names its variant.
    for (const ModuleDescriptor* d : plain.builtinComponents())
        for (const BuiltinPreset& preset : builtinPresets(d->id)) {
            ComponentSpec c;
            c.id = std::string(d->id);
            for (const auto& [k, v] : preset.values) c.params.emplace_back(std::string(k), v);
            if (fx::migrateLegacyEffect(c)) cawtest::fail(__FILE__, __LINE__, c.id + " preset " + std::string(preset.name) + " needs migration");
            if (fx::findMergedDevice(d->id) && !std::any_of(preset.values.begin(), preset.values.end(),
                                                            [](const auto& v) { return v.first == fx::kVariantParam; }))
                cawtest::fail(__FILE__, __LINE__, c.id + " preset " + std::string(preset.name) + " names no variant");
        }
}

TEST(merged_pitch_shift_renders_the_old_ids_bits_over_their_presets_and_random_values) {
    const Stereo in = music(24000);
    uint32_t seed = 2026;
    for (uint32_t v = 0; v < 2; ++v) {
        std::vector<Values> sets;
        for (const BuiltinPreset& p : builtinPresets(kOld[v])) {
            Values x;
            for (const auto& [k, value] : p.values) x.emplace_back(std::string(k), value);
            sets.push_back(x);
        }
        for (int r = 0; r < 12; ++r) sets.push_back(randomValues(*registry().find(kOld[v]), seed));
        CHECK(sets.size() >= 17u);
        for (const Values& values : sets) {
            auto old = active(registry().create(kOld[v]));
            ComponentSpec spec;
            spec.id = kOld[v];
            spec.params = values;
            CHECK(fx::migrateLegacyEffect(spec));
            CHECK(spec.id == kShift && valueOf(spec.params, "variant") == v);
            auto merged = active(createComponent(registry(), spec.id, spec.params));
            if (!old || !merged) return;
            if (!sameBits(run(*old, in, values), run(*merged, in, spec.params)))
                cawtest::fail(__FILE__, __LINE__, std::string(kOld[v]) + ": the merged variant's bits differ");
        }
    }
}

TEST(merged_pitch_shift_reports_each_variants_latency_as_the_old_id_did) {
    for (double grain : {10.0, 37.0, 60.0, 200.0}) {
        for (uint32_t v = 0; v < 2; ++v) {
            ComponentSpec old;
            old.id = kOld[v];
            old.params = {{v == 0 ? "grain" : "delay", grain}};
            ComponentSpec merged = old;
            CHECK(fx::migrateLegacyEffect(merged));
            std::string error;
            auto a = ComponentChain::build(registry(), {old}, 48000.0, error);
            auto b = ComponentChain::build(registry(), {merged}, 48000.0, error);
            CHECK(a && b);
            if (!a || !b) return;
            CHECK_EQ(a->latencyFrames(), b->latencyFrames());
            if (v == 0) CHECK(b->latencyFrames() > 0);
            if (v == 1) CHECK_EQ(b->latencyFrames(), 0u);
        }
    }
}

TEST(merged_pitch_shift_resolves_the_old_presets_under_its_id_with_equal_values) {
    size_t total = 0;
    for (uint32_t v = 0; v < 2; ++v)
        for (const BuiltinPreset& p : builtinPresets(kOld[v])) {
            ++total;
            const BuiltinPreset* merged = findBuiltinPreset(kShift, p.name);
            CHECK(merged != nullptr);
            if (!merged) continue;
            CHECK(merged->description == p.description);
            std::map<std::string, double> want, got;
            for (const auto& [k, x] : p.values) want[std::string(k)] = x;
            want["variant"] = v;
            for (const auto& [k, x] : merged->values) got[std::string(k)] = x;
            CHECK(want == got);
            Values applied;
            CHECK(applyBuiltinPreset(kShift, p.name, applied));
            CHECK_EQ(valueOf(applied, "variant"), static_cast<double>(v));
        }
    CHECK_EQ(builtinPresets(kShift).size(), total);
    CHECK(total >= 10u);
}

TEST(a_saved_project_with_the_old_ids_and_lanes_plays_the_merged_device_the_same) {
    auto project = [](const std::string& entry, const std::string& entry2) {
        return std::string(R"({"caw_project":1,"bpm":120,"loop_bars":2,"layers":[{"id":"t","volume":1,)"
                           R"("instrument":{"id":"org.caw.test.osc","params":{"shape":1,"freq":110,"level":0.5}},)"
                           R"("components":[)") + entry + "," + entry2 + R"(]}],"master_components":[)" + entry2 +
               R"(],"automation":[{"target_type":"component","layer":"t","component":0,"target":"semitones",)"
               R"("points":[{"step":0,"value":-12},{"step":16,"value":12}]},)"
               R"({"target_type":"component","component":0,"target":"shift","points":[{"step":0,"value":10},{"step":32,"value":400}]}]})";
    };
    const std::string oldJson = project(R"({"id":"org.caw.pitchshift","params":{"grain":45,"mix":0.7}})",
                                        R"({"id":"org.caw.freqshift","params":{"direction":2,"feedback":0.3}})");
    const std::string newJson = project(R"({"id":"org.caw.shift","params":{"variant":0,"grain":45,"mix":0.7}})",
                                        R"({"id":"org.caw.shift","params":{"variant":1,"direction":2,"feedback":0.3}})");
    const Stereo a = renderProject(oldJson), b = renderProject(newJson);
    CHECK(sameBits(a, b));
    double peak = 0;
    for (float x : a.l) peak = std::max(peak, std::fabs(static_cast<double>(x)));
    CHECK(peak > 0.01);
    // The engine migrates a parsed project: the old ids become the merged one, the lanes keep their targets.
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(oldJson, p, error));
    CHECK(fx::hasLegacyEffects(p));
    CHECK(fx::migrateLegacyEffects(p));
    CHECK(!fx::hasLegacyEffects(p));
    CHECK(p.layers[0].components[0].id == kShift && p.masterComponents[0].id == kShift);
    CHECK_EQ(valueOf(p.layers[0].components[1].params, "variant"), 1.0);
    CHECK_EQ(p.automation.size(), 2u);
    // caw_migrate_component gives the app the same form for its document.
    const Json j = migrateJson(R"({"id":"org.caw.pitchshift","params":{"grain":45,"mix":0.7}})");
    CHECK(j.boolean("migrated", false) && j.string("id") == kShift && j.boolean("keeps_state", false));
    const Json* ps = j.get("params");
    CHECK(ps && ps->number("variant", -1) == 0 && ps->number("grain", -1) == 45 && ps->number("mix", -1) == 0.7);
    CHECK(j.get("renamed") && j.get("renamed")->obj.empty() && j.get("dropped") && j.get("dropped")->arr.empty());
    const Json f = migrateJson(R"({"id":"org.caw.freqshift","preset":"Metallic up","params":{"mix":0.25}})");
    CHECK(f.get("params") && f.get("params")->number("variant", -1) == 1 && f.get("params")->number("shift", -1) == 300 &&
          f.get("params")->number("mix", -1) == 0.25);
    const Json other = migrateJson(R"({"id":"org.caw.eq","params":{"b1_gain":3}})");
    CHECK(!other.boolean("migrated", true) && other.string("id") == "org.caw.eq");
    char* bad = caw_migrate_component("[1]");
    CHECK(bad && std::string(bad).find("\"ok\":false") != std::string::npos);
    caw_free(bad);
}

TEST(a_racks_old_children_migrate_with_their_values_and_routes_and_sound_the_same) {
    auto h = [](const char* id) { return static_cast<double>(rackChildHash(id)); };
    ComponentSpec old;
    old.id = std::string(kFxRackId);
    old.params = {{"s1_fx", h("org.caw.pitchshift")}, {"s1.semitones", 7}, {"s1.mix", 0.5},
                  {"s2_fx", h("org.caw.freqshift")},  {"s2.shift", 120},    {"s3_fx", h("org.caw.eq")},
                  {"mod1_src", 1},                    {"mod1_amt", 0.4},    {"mod2_src", 1},
                  {"mod2_amt", -0.3}};
    old.params.emplace_back("mod1_dst", destination(kFxRackId, old.params, "s2.shift"));
    old.params.emplace_back("mod2_dst", destination(kFxRackId, old.params, "s3.b2_gain"));
    CHECK(valueOf(old.params, "mod1_dst") > 0 && valueOf(old.params, "mod2_dst") > 0);
    ComponentSpec merged = old;
    fx::ParamRenames renames;
    CHECK(fx::migrateLegacyEffect(merged, &renames));
    CHECK(merged.id == kFxRackId && renames.empty());
    CHECK_EQ(valueOf(merged.params, "s1_fx"), h(kShift));
    CHECK_EQ(valueOf(merged.params, "s2_fx"), h(kShift));
    CHECK_EQ(valueOf(merged.params, "s3_fx"), h("org.caw.eq"));
    CHECK_EQ(valueOf(merged.params, "s1.variant"), 0.0);
    CHECK_EQ(valueOf(merged.params, "s2.variant"), 1.0);
    // The routes still reach the same knobs: each slot's list grew by `variant`, so later indices moved.
    CHECK_EQ(valueOf(merged.params, "mod1_dst"), destination(kFxRackId, merged.params, "s2.shift"));
    CHECK_EQ(valueOf(merged.params, "mod2_dst"), destination(kFxRackId, merged.params, "s3.b2_gain"));
    CHECK(valueOf(merged.params, "mod2_dst") != valueOf(old.params, "mod2_dst"));
    CHECK(!fx::migrateLegacyEffect(merged));  // done once
    const Stereo in = music(48000);
    CHECK(sameBits(renderChain({old}, in), renderChain({merged}, in)));
    // A rack entry through the C API.
    const Json j = migrateJson((R"({"id":"org.caw.rack.fx","params":{"s1_fx":)" + std::to_string(rackChildHash("org.caw.freqshift")) +
                                R"(,"s1.shift":50}})").c_str());
    CHECK(j.boolean("migrated", false) && j.get("params") && j.get("params")->number("s1.variant", -1) == 1 &&
          j.get("params")->number("s1_fx", -1) == h(kShift) && j.get("params")->number("s1.shift", -1) == 50);
    // A different variant in a slot is a different rack structure (a rebuild).
    ComponentSpec other = merged;
    for (auto& [k, v] : other.params)
        if (k == "s1.variant") v = 1;
    CHECK(componentStructure(other) != componentStructure(merged));
}

TEST(a_rack_older_than_the_merged_devices_gets_its_routes_re_pointed_and_its_layout_version_once) {
    // A merged device in a rack that has no layout version, with no `<slot>.variant`: the rack was saved before the
    // merge, when that id (an old effect's, reused) listed no `variant`. Pitch/Shift stands in for such an id here
    // (Utility, Chorus... in their families' tests): its variant 0's list without `variant` is the "old" one.
    auto h = [](const char* id) { return static_cast<double>(rackChildHash(id)); };
    ComponentSpec expected;  // the rack as it is meant today: routes by name on the current layout
    expected.id = std::string(kFxRackId);
    expected.params = {{"s1_fx", h(kShift)}, {"s1.semitones", 5}, {"s1.variant", 0}, {"s2_fx", h("org.caw.convolver")},
                       {"mod1_src", 1}, {"mod1_amt", 0.5}, {"mod2_src", 2}, {"mod2_amt", -0.4}};
    expected.params.emplace_back("mod1_dst", destination(kFxRackId, expected.params, "s2.mix"));
    expected.params.emplace_back("mod2_dst", destination(kFxRackId, expected.params, "s1.mix"));
    expected.params.emplace_back(std::string(kRackLayoutParam), kRackLayoutCurrent);
    ComponentSpec old;  // saved before: no version, no s1.variant, and s2's knobs one place earlier
    old.id = expected.id;
    for (const auto& [k, v] : expected.params)
        if (k != "s1.variant" && k != kRackLayoutParam) old.params.emplace_back(k, k == "mod1_dst" ? v - 1 : v);
    CHECK(fx::hasLegacyEffects([&] {
        ProjectSpec p;
        p.masterComponents.push_back(old);
        return p;
    }()));
    ComponentSpec merged = old;
    fx::ParamRenames renames;
    CHECK(fx::migrateLegacyEffect(merged, &renames));
    CHECK(renames.empty());
    CHECK_EQ(valueOf(merged.params, "s1.variant"), 0.0);
    CHECK_EQ(valueOf(merged.params, kRackLayoutParam), kRackLayoutCurrent);
    CHECK_EQ(valueOf(merged.params, "mod1_dst"), valueOf(expected.params, "mod1_dst"));  // the same knob, s2.mix
    CHECK_EQ(valueOf(merged.params, "mod2_dst"), valueOf(expected.params, "mod2_dst"));  // before the variant: kept
    const Stereo in = music(32000);  // whole 64-frame blocks (renderChain's)
    CHECK(sameBits(renderChain({merged}, in), renderChain({expected}, in)));
    // Migrated once: a second pass changes nothing.
    const ComponentSpec again = merged;
    CHECK(!fx::migrateLegacyEffect(merged));
    CHECK(merged.params == again.params);
    // A current rack (with the version) whose variant-0 child omits `<slot>.variant` is left alone.
    ComponentSpec current = expected;
    std::erase_if(current.params, [](const auto& kv) { return kv.first == "s1.variant"; });
    const ComponentSpec before = current;
    CHECK(!fx::migrateLegacyEffect(current));
    CHECK(current.params == before.params);
    CHECK(sameBits(renderChain({current}, in), renderChain({expected}, in)));
    // The version is the rack's last parameter, after the routes: no route destination moved for it.
    const ModuleDescriptor* rack = registry().find(kFxRackId);
    CHECK(rack && rack->parameters[rack->parameterCount - 1].id == kRackLayoutParam &&
          !rack->parameters[rack->parameterCount - 1].automatable);
    // caw_migrate_component marks an older empty rack; every rack preset needs no migration, and settles after one.
    const Json j = migrateJson(R"({"id":"org.caw.rack.multiband","params":{"bands":2}})");
    CHECK(j.boolean("migrated", false) && j.get("params") && j.get("params")->number(std::string(kRackLayoutParam), 0) == kRackLayoutCurrent);
    for (const char* id : {kFxRackId.data(), "org.caw.rack.multiband"})
        for (const BuiltinPreset& p : builtinPresets(id)) {
            ComponentSpec c;
            c.id = id;
            for (const auto& [k, v] : p.values) c.params.emplace_back(std::string(k), v);
            // Every rack preset names the merged ids with their variants and today's layout: it needs no migration.
            CHECK(!fx::migrateLegacyEffect(c));
            // And a rack that did need one (an older layout) settles after one migration.
            ComponentSpec older = c;
            std::erase_if(older.params, [](const auto& v) { return v.first == kRackLayoutParam; });
            CHECK(fx::migrateLegacyEffect(older));
            CHECK(!fx::migrateLegacyEffect(older));
        }
}

TEST(a_variant_change_rebuilds_the_chain_and_a_parameter_call_cant_change_it) {
    auto project = [](double variant, bool leftover) {
        ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
        ComponentSpec c;
        c.id = kShift;
        c.params = {{"variant", variant}, {"mix", 0.6}};
        if (leftover) c.params.emplace_back(variant == 0 ? "shift" : "semitones", 5);  // the other variant's
        p.layers[0].components.push_back(c);
        return p;
    };
    Engine e(48000);
    CHECK(e.setProject(project(0, false)).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(256), r(256);
    float shown[64];
    for (int b = 0; b < 40; ++b) e.process(l.data(), r.data(), 256);
    CHECK_EQ(e.componentDisplay("t", 0, shown, 64), 6);  // the pitch shifter's six floats
    CHECK(!e.setComponentParam("t", 0, "variant", 1));    // structural: a project update, not a value
    CHECK(e.setComponentParam("t", 0, "variant", 0));     // the same one is harmless
    CHECK(e.setComponentParam("t", 0, "semitones", 3));
    CHECK(e.setProject(project(1, true)).find("\"ok\":true") != std::string::npos);  // leftovers ignored
    for (int b = 0; b < 40; ++b) e.process(l.data(), r.data(), 256);
    CHECK_EQ(e.componentDisplay("t", 0, shown, 64), 7);  // the frequency shifter's seven
    CHECK(e.setComponentParam("t", 0, "shift", 30));
    CHECK(!e.setComponentParam("t", 0, "semitones", 3));
    // An unknown parameter of no variant still refuses the entry.
    ProjectSpec bad = project(0, false);
    bad.layers[0].components[0].params.emplace_back("cutoff", 1000);
    CHECK(e.setProject(bad).find("\"ok\":false") != std::string::npos);
}

TEST(the_components_json_lists_every_variants_descriptor_and_the_presets) {
    Engine e(48000);
    Json j;
    std::string error;
    CHECK(parseJson(e.nativeComponentsJson(), j, error));
    const Json* list = j.get("components");
    CHECK(list != nullptr);
    if (!list) return;
    const Json* shift = nullptr;
    for (const Json& c : list->arr)
        if (c.string("id") == kShift) shift = &c;
    CHECK(shift != nullptr);
    if (!shift) return;
    const Json* variants = shift->get("variants");
    CHECK(variants && variants->arr.size() == 2u);
    if (variants && variants->arr.size() == 2u) {
        CHECK(variants->arr[1].string("id") == kShift);
        bool hasShift = false;
        for (const Json& p : variants->arr[1].get("parameters")->arr) hasShift = hasShift || p.string("id") == "shift";
        CHECK(hasShift);
    }
    CHECK(shift->get("presets") && shift->get("presets")->arr.size() >= 10u);
}

// ---------- Optional ports ----------

namespace {

// A plain gain with a slow wobble, and the same offering an optional "dry" output (a copy of its input).
class GainFx : public fx::EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override {
        static const fx::ParamTable t = [] {
            fx::ParamTable p;
            p.num("gain", "Gain", 0.5, 0.0, 1.0);
            return p;
        }();
        static const ModuleDescriptor d = fx::effectDescriptor("org.caw.tests.optional", "Optional", t, 0, 0);
        return d;
    }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void control(uint32_t at) noexcept override { gain_ = param(0, at); }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        float* dl = optionalOutLeft(0);  // once per run
        float* dr = optionalOutRight(0);
        for (uint32_t i = 0; i < n; ++i) {
            phase_ += 0.001;
            const double g = gain_ * (0.8 + 0.2 * std::sin(phase_));
            outL[i] = static_cast<float>(inL[i] * g);
            outR[i] = static_cast<float>(inR[i] * g);
        }
        if (dl)
            for (uint32_t i = 0; i < n; ++i) dl[i] = inL[i], dr[i] = inR[i];
    }
    void clearState() noexcept override { phase_ = 0.0; }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = outPeakDb();
        return 1;
    }

private:
    double gain_ = 0.5, phase_ = 0.0;
};

class GainFxWithDry final : public GainFx {
public:
    std::span<const fx::OptionalPort> optionalPorts() const noexcept override {
        static const fx::OptionalPort ports[] = {{"dry", "Dry", false}};
        return ports;
    }
};

}  // namespace

TEST(an_optional_port_changes_nothing_heard_and_fills_only_when_connected) {
    const Stereo in = music(40000);
    GainFx plain;
    GainFxWithDry offered;
    CHECK(plain.activate(48000, 512) && offered.activate(48000, 512));
    CHECK_EQ(plain.optionalPorts().size(), 0u);
    CHECK(!plain.connectOptionalPort(0, nullptr, nullptr));  // no such port
    const Stereo a = run(plain, in, {{"gain", 0.7}});
    const Stereo b = run(offered, in, {{"gain", 0.7}});
    CHECK(sameBits(a, b));  // declared and unconnected: bit-identical
    // Connected: the main output stays the same and the port gets the input (silence while asleep).
    offered.reset();
    std::vector<float> dryL(64), dryR(64);
    Stereo c{std::vector<float>(in.l.size()), std::vector<float>(in.l.size())};
    std::vector<ParameterValue> params(1);
    params[0].value = 0.7;
    bool exact = true;
    for (size_t start = 0; start < in.l.size(); start += 64) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(64, in.l.size() - start));
        std::fill(dryL.begin(), dryL.end(), 9.0f);
        std::fill(dryR.begin(), dryR.end(), 9.0f);
        CHECK(offered.connectOptionalPort(0, dryL.data(), dryR.data()));
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        float* oc[2] = {c.l.data() + start, c.r.data() + start};
        AudioProcessBlock blk;
        blk.input = {ic, 2, n};
        blk.output = {oc, 2, n};
        blk.frames = n;
        blk.sampleRate = 48000;
        blk.parameters = params.data();
        blk.parameterCount = 1;
        CHECK(offered.process(blk));
        for (uint32_t i = 0; i < n; ++i) exact = exact && dryL[i] == in.l[start + i] && dryR[i] == in.r[start + i];
    }
    CHECK(exact);
    CHECK(sameBits(a, c));
    CHECK(offered.connectOptionalPort(0, nullptr, nullptr));
    CHECK(!offered.connectOptionalPort(0, dryL.data(), nullptr));  // both sides or neither
}
