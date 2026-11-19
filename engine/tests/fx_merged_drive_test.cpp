// FX consolidation part B: Drive (org.caw.drive) and Bit distortion (org.caw.bits) against the old ids they replace.
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

constexpr const char* kDrive = "org.caw.drive";
constexpr const char* kBits = "org.caw.bits";

// Each old id, the merged device that replaces it and its variant there.
struct Old {
    const char* id;
    const char* merged;
    uint32_t variant;
};
const Old kOld[] = {
    {"org.caw.distortion", kDrive, 0},
    {"org.caw.saturator", kDrive, 1},
    {"org.caw.clipper", kDrive, 2},
    {"org.caw.phasedist", kDrive, 3},
    {"org.caw.bitcrush", kBits, 0},
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

// A loud enough signal to drive every curve: two tones, noise and gaps of silence (sleep and wake).
Stereo music(size_t frames, uint32_t seed = 77) {
    Stereo s{std::vector<float>(frames), std::vector<float>(frames)};
    for (size_t i = 0; i < frames; ++i) {
        if ((i / 9000) % 4 == 3) continue;
        seed = seed * 1664525u + 1013904223u;
        const double nz = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * 0.1;
        s.l[i] = static_cast<float>(0.7 * std::sin(6.283185307179586 * 110.0 * i / 48000.0) + nz);
        s.r[i] = static_cast<float>(0.5 * std::sin(6.283185307179586 * 167.0 * i / 48000.0) - nz);
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

// Every preset of the old id and a dozen random settings: the value sets each comparison runs over.
std::vector<Values> valueSets(const Old& o, uint32_t& seed) {
    std::vector<Values> sets{{}};
    for (const BuiltinPreset& p : builtinPresets(o.id)) {
        Values x;
        for (const auto& [k, value] : p.values) x.emplace_back(std::string(k), value);
        sets.push_back(x);
    }
    for (int r = 0; r < 12; ++r) sets.push_back(randomValues(*registry().find(o.id), seed));
    return sets;
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

TEST(merged_drive_and_bits_list_their_variants_with_the_old_parameters_and_a_structural_variant) {
    const fx::MergedDevice* drive = fx::findMergedDevice(kDrive);
    const fx::MergedDevice* bits = fx::findMergedDevice(kBits);
    CHECK(drive && bits);
    if (!drive || !bits) return;
    CHECK_EQ(drive->variants.size(), 7u);  // the old four, then 1.1.0's Amp, Pedal and Bands (fx_drive_modes_test.cpp)
    CHECK_EQ(bits->variants.size(), 1u);
    CHECK(drive->name == "Drive" && bits->name == "Bit distortion");
    CHECK(drive->variants[0].name == "Distortion" && drive->variants[1].name == "Saturate" &&
          drive->variants[2].name == "Clip" && drive->variants[3].name == "Phase" && bits->variants[0].name == "Crush");
    CHECK(registry().find(kDrive) == &drive->variants[0].descriptor());
    CHECK(registry().find(kBits) == &bits->variants[0].descriptor());
    for (const Old& o : kOld) {
        const fx::MergedDevice* m = fx::findMergedDevice(o.merged);
        const ModuleDescriptor& d = m->variants[o.variant].descriptor();
        const ModuleDescriptor* old = registry().find(o.id);
        CHECK(old != nullptr);  // the old ids stay registered until part F
        if (!old) continue;
        CHECK(d.id == o.merged && d.name == m->name);
        CHECK_EQ(d.parameterCount, old->parameterCount + 1);
        for (uint32_t k = 0; k < old->parameterCount; ++k) {
            CHECK(d.parameters[k].id == old->parameters[k].id);
            CHECK_EQ(d.parameters[k].defaultValue, old->parameters[k].defaultValue);
        }
        const ParameterDescriptor& variant = d.parameters[d.parameterCount - 1];
        CHECK(variant.id == fx::kVariantParam);
        CHECK(!variant.automatable && !variant.modulatable && !variant.midiMappable);
        CHECK_EQ(variant.defaultValue, static_cast<double>(o.variant));
        CHECK_EQ(variant.choiceCount, static_cast<uint32_t>(m->variants.size()));
        CHECK_EQ(d.tailFrames, old->tailFrames);
        CHECK_EQ(d.latencyFrames, old->latencyFrames);
        CHECK(d.cpuClass == old->cpuClass);
        CHECK(d.role == old->role);
        std::unique_ptr<ModuleProcessor> p = createComponent(registry(), o.merged, {{"variant", static_cast<double>(o.variant)}});
        CHECK(p && &p->descriptor() == &d);
        // The migration table points at the old class's own descriptor.
        const fx::LegacyEffect* e = fx::findLegacyEffect(o.id);
        CHECK(e && e->to == o.merged && e->variant == o.variant && e->keepsState && e->legacy && &e->legacy() == old);
    }
    // The saturator keeps its own "mode" inside its variant; Clip has one too, Distortion its "shape".
    CHECK(isOtherVariantParameter(kDrive, "mode") && isOtherVariantParameter(kDrive, "shape") &&
          isOtherVariantParameter(kDrive, "normalize") && isOtherVariantParameter(kBits, "jitter"));
    CHECK(!isOtherVariantParameter(kBits, "shape"));
}

TEST(merged_drive_and_bits_render_the_old_ids_bits_over_their_presets_and_random_values) {
    const Stereo in = music(24000);
    uint32_t seed = 1108;
    for (const Old& o : kOld) {
        const std::vector<Values> sets = valueSets(o, seed);
        CHECK(sets.size() >= 13u);
        for (const Values& values : sets) {
            auto old = active(registry().create(o.id));
            ComponentSpec spec;
            spec.id = o.id;
            spec.params = values;
            CHECK(fx::migrateLegacyEffect(spec));
            CHECK(spec.id == o.merged && valueOf(spec.params, "variant") == o.variant);
            CHECK_EQ(spec.params.size(), values.size() + 1);  // nothing renamed, dropped or added but `variant`
            auto merged = active(createComponent(registry(), spec.id, spec.params));
            if (!old || !merged) return;
            const Stereo a = run(*old, in, values);
            if (!sameBits(a, run(*merged, in, spec.params)))
                cawtest::fail(__FILE__, __LINE__, std::string(o.id) + ": the merged variant's bits differ");
            // The display reads the same too (the same class).
            float x[256], y[256];
            const uint32_t n = old->readDisplay(x, 256), m = merged->readDisplay(y, 256);
            CHECK_EQ(n, m);
            CHECK(n == m && std::memcmp(x, y, n * sizeof(float)) == 0);
        }
    }
}

TEST(merged_drive_and_bits_report_each_variants_latency_and_tail_as_the_old_id_did) {
    uint32_t seed = 4242;
    for (const Old& o : kOld)
        for (const Values& values : valueSets(o, seed)) {
            ComponentSpec old;
            old.id = o.id;
            old.params = values;
            ComponentSpec merged = old;
            CHECK(fx::migrateLegacyEffect(merged));
            std::string error;
            auto a = ComponentChain::build(registry(), {old}, 48000.0, error);
            auto b = ComponentChain::build(registry(), {merged}, 48000.0, error);
            CHECK(a && b);
            if (!a || !b) return;
            CHECK_EQ(a->latencyFrames(), b->latencyFrames());
            CHECK_EQ(a->tailFrames(), b->tailFrames());
            if (std::string_view(o.id) == "org.caw.phasedist") CHECK(b->latencyFrames() > 0);
        }
}

TEST(merged_drive_and_bits_resolve_the_old_presets_under_their_ids_with_equal_values) {
    std::map<std::string, size_t> total;
    for (const Old& o : kOld)
        for (const BuiltinPreset& p : builtinPresets(o.id)) {
            ++total[o.merged];
            const BuiltinPreset* merged = findBuiltinPreset(o.merged, p.name);
            CHECK(merged != nullptr);
            if (!merged) continue;
            CHECK(merged->description == p.description);
            std::map<std::string, double> want, got;
            for (const auto& [k, x] : p.values) want[std::string(k)] = x;
            want["variant"] = o.variant;
            for (const auto& [k, x] : merged->values) got[std::string(k)] = x;
            if (want != got) cawtest::fail(__FILE__, __LINE__, std::string(o.id) + ": preset \"" + std::string(p.name) + "\" differs");
            Values applied;
            CHECK(applyBuiltinPreset(o.merged, p.name, applied));
            CHECK_EQ(valueOf(applied, "variant"), static_cast<double>(o.variant));
        }
    // Then the 1.1.0 modes' own presets (each naming its new variant).
    CHECK_EQ(builtinPresets(kDrive).size(), total[kDrive] + fx::newVariantPresets(kDrive).size());
    CHECK_EQ(builtinPresets(kBits).size(), total[kBits] + fx::newVariantPresets(kBits).size());
    CHECK(total[kDrive] >= 10u && total[kBits] >= 3u);
}

TEST(a_saved_project_with_the_old_drive_ids_lanes_and_a_rack_child_plays_the_merged_devices_the_same) {
    const std::string rack = std::string(R"({"id":"org.caw.rack.fx","params":{"s1_fx":)") +
                             std::to_string(rackChildHash("org.caw.clipper")) + R"(,"s1.drive":9,"s1.oversample":2,"s2_fx":)" +
                             std::to_string(rackChildHash("org.caw.bitcrush")) + R"(,"s2.bits":5}})";
    const std::string rackNew = std::string(R"({"id":"org.caw.rack.fx","params":{"s1_fx":)") +
                                std::to_string(rackChildHash(kDrive)) + R"(,"s1.variant":2,"s1.drive":9,"s1.oversample":2,"s2_fx":)" +
                                std::to_string(rackChildHash(kBits)) + R"(,"s2.variant":0,"s2.bits":5}})";
    auto project = [](const std::string& a, const std::string& b, const std::string& c, const std::string& d,
                      const std::string& r) {
        return std::string(R"({"caw_project":1,"bpm":120,"loop_bars":2,"layers":[{"id":"t","volume":1,)"
                           R"("instrument":{"id":"org.caw.test.osc","params":{"shape":1,"freq":110,"level":0.5}},)"
                           R"("components":[)") + a + "," + b + "," + r + R"(]}],"master_components":[)" + c + "," + d +
               R"(],"automation":[{"target_type":"component","layer":"t","component":0,"target":"drive",)"
               R"("points":[{"step":0,"value":2},{"step":16,"value":18}]},)"
               R"({"target_type":"component","layer":"t","component":1,"target":"bias","points":[{"step":0,"value":-0.5},{"step":32,"value":0.5}]},)"
               R"({"target_type":"component","component":1,"target":"bits","points":[{"step":0,"value":3},{"step":32,"value":12}]}]})";
    };
    const std::string oldJson =
        project(R"({"id":"org.caw.distortion","params":{"shape":2,"mix":0.8}})", R"({"id":"org.caw.saturator","params":{"mode":1,"drive":12}})",
                R"({"id":"org.caw.phasedist","params":{"drive":0.7,"mix":0.6}})", R"({"id":"org.caw.bitcrush","params":{"bits":6,"mix":0.5}})",
                rack);
    const std::string newJson = project(
        R"({"id":"org.caw.drive","params":{"variant":0,"shape":2,"mix":0.8}})", R"({"id":"org.caw.drive","params":{"variant":1,"mode":1,"drive":12}})",
        R"({"id":"org.caw.drive","params":{"variant":3,"drive":0.7,"mix":0.6}})", R"({"id":"org.caw.bits","params":{"variant":0,"bits":6,"mix":0.5}})",
        rackNew);
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
    CHECK(p.layers[0].components[0].id == kDrive && p.layers[0].components[1].id == kDrive);
    CHECK(p.masterComponents[0].id == kDrive && p.masterComponents[1].id == kBits);
    CHECK_EQ(valueOf(p.layers[0].components[1].params, "variant"), 1.0);
    CHECK_EQ(valueOf(p.layers[0].components[1].params, "mode"), 1.0);  // the saturator's own mode stays
    CHECK_EQ(valueOf(p.masterComponents[0].params, "variant"), 3.0);
    CHECK_EQ(valueOf(p.layers[0].components[2].params, "s1.variant"), 2.0);
    CHECK_EQ(p.automation.size(), 3u);
    // caw_migrate_component gives the app the same form.
    char* text = caw_migrate_component(R"({"id":"org.caw.saturator","params":{"mode":4,"drive":20}})");
    Json j;
    CHECK(text && parseJson(text, j, error) && j.boolean("ok", false));
    caw_free(text);
    CHECK(j.boolean("migrated", false) && j.string("id") == kDrive && j.boolean("keeps_state", false));
    const Json* ps = j.get("params");
    CHECK(ps && ps->number("variant", -1) == 1 && ps->number("mode", -1) == 4 && ps->number("drive", -1) == 20);
    CHECK(j.get("renamed") && j.get("renamed")->obj.empty() && j.get("dropped") && j.get("dropped")->arr.empty());
}

TEST(a_racks_old_drive_children_migrate_with_their_routes_and_sound_the_same) {
    auto h = [](const char* id) { return static_cast<double>(rackChildHash(id)); };
    ComponentSpec old;
    old.id = std::string(kFxRackId);
    old.params = {{"s1_fx", h("org.caw.saturator")}, {"s1.mode", 3}, {"s1.drive", 14},  {"s2_fx", h("org.caw.phasedist")},
                  {"s2.drive", 0.6},                 {"s3_fx", h("org.caw.bitcrush")}, {"s3.bits", 4}, {"mod1_src", 1},
                  {"mod1_amt", 0.4},                 {"mod2_src", 1},                  {"mod2_amt", -0.3}};
    old.params.emplace_back("mod1_dst", destination(kFxRackId, old.params, "s2.drive"));
    old.params.emplace_back("mod2_dst", destination(kFxRackId, old.params, "s3.bits"));
    CHECK(valueOf(old.params, "mod1_dst") > 0 && valueOf(old.params, "mod2_dst") > 0);
    ComponentSpec merged = old;
    fx::ParamRenames renames;
    CHECK(fx::migrateLegacyEffect(merged, &renames));
    CHECK(merged.id == kFxRackId && renames.empty());
    CHECK_EQ(valueOf(merged.params, "s1_fx"), h(kDrive));
    CHECK_EQ(valueOf(merged.params, "s2_fx"), h(kDrive));
    CHECK_EQ(valueOf(merged.params, "s3_fx"), h(kBits));
    CHECK_EQ(valueOf(merged.params, "s1.variant"), 1.0);
    CHECK_EQ(valueOf(merged.params, "s2.variant"), 3.0);
    CHECK_EQ(valueOf(merged.params, "s3.variant"), 0.0);
    CHECK_EQ(valueOf(merged.params, "mod1_dst"), destination(kFxRackId, merged.params, "s2.drive"));
    CHECK_EQ(valueOf(merged.params, "mod2_dst"), destination(kFxRackId, merged.params, "s3.bits"));
    CHECK(!fx::migrateLegacyEffect(merged));
    const Stereo in = music(48000);
    CHECK(sameBits(renderChain({old}, in), renderChain({merged}, in)));
}
