// FX consolidation, part A: the merged Compressor (Down, Dynamics), Gate, Shape (Tremolo/Pan's since 1.1.0), Limiter and Transient against the old ids they replace.
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

namespace caw::fx {
// The old classes under their own (old) descriptors: the old ids exactly, even once a merged device has its id.
const ModuleDescriptor& legacyCompressorDescriptor();
const ModuleDescriptor& legacyLimiterDescriptor();
const ModuleDescriptor& legacyGateDescriptor();
const ModuleDescriptor& legacyTransientDescriptor();
const ModuleDescriptor& legacyDynamicsDescriptor();
const ModuleDescriptor& legacyDuckerDescriptor();
ModuleProcessor* makeCompressorAs(const ModuleDescriptor&) noexcept;
ModuleProcessor* makeLimiterAs(const ModuleDescriptor&) noexcept;
ModuleProcessor* makeGateAs(const ModuleDescriptor&) noexcept;
ModuleProcessor* makeTransientAs(const ModuleDescriptor&) noexcept;
ModuleProcessor* makeDynamicsAs(const ModuleDescriptor&) noexcept;
ModuleProcessor* makeDuckerAs(const ModuleDescriptor&) noexcept;
}  // namespace caw::fx

using namespace caw;

namespace {

using Values = std::vector<std::pair<std::string, double>>;

constexpr const char* kCompressor = "org.caw.compressor";
constexpr const char* kLimiter = "org.caw.limiter";
constexpr const char* kTransient = "org.caw.transient";
constexpr const char* kGate = "org.caw.gate";        // 1.1.0: its own device again (1.0.8-1.0.9: the Compressor's variant 2)
constexpr const char* kTremolo = "org.caw.tremolo";  // 1.1.0: Shape is its variant 2 (1.0.8-1.0.9: the Compressor's 3)

// Each variant and the old id it replaces (`reused`: the merged device has the old id itself).
struct Case {
    const char* merged;
    uint32_t variant;
    const char* old;
    bool reused;
    const ModuleDescriptor& (*legacy)();
    ModuleProcessor* (*makeAs)(const ModuleDescriptor&) noexcept;
};
const Case kCases[] = {
    {kCompressor, 0, "org.caw.compressor", true, &fx::legacyCompressorDescriptor, &fx::makeCompressorAs},
    {kCompressor, 1, "org.caw.dynamics", false, &fx::legacyDynamicsDescriptor, &fx::makeDynamicsAs},
    {kGate, 0, "org.caw.gate", true, &fx::legacyGateDescriptor, &fx::makeGateAs},
    {kTremolo, 2, "org.caw.ducker", false, &fx::legacyDuckerDescriptor, &fx::makeDuckerAs},
    {kLimiter, 0, "org.caw.limiter", true, &fx::legacyLimiterDescriptor, &fx::makeLimiterAs},
    {kTransient, 0, "org.caw.transient", true, &fx::legacyTransientDescriptor, &fx::makeTransientAs},
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

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

struct Stereo {
    std::vector<float> l, r;
};

// Tones, noise bursts that come and go (onsets for the transient shaper and the gate) and gaps of silence.
Stereo music(size_t frames, uint32_t seed = 7) {
    Stereo s{std::vector<float>(frames), std::vector<float>(frames)};
    for (size_t i = 0; i < frames; ++i) {
        if ((i / 9000) % 4 == 3) continue;
        seed = seed * 1664525u + 1013904223u;
        const double burst = (i % 6000) < 900 ? 0.6 : 0.05;
        const double nz = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * burst;
        s.l[i] = static_cast<float>(0.3 * std::sin(6.283185307179586 * 110.0 * i / 48000.0) + nz);
        s.r[i] = static_cast<float>(0.25 * std::sin(6.283185307179586 * 165.0 * i / 48000.0) - nz);
    }
    return s;
}

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

double peak(const std::vector<float>& v) {
    double p = 0;
    for (float x : v) p = std::max(p, std::fabs(static_cast<double>(x)));
    return p;
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

// The merged entry for an old one: migrated (an old id another device replaces) or given its `variant` 0.
ComponentSpec merged(const Case& c, const Values& values) {
    ComponentSpec spec;
    spec.id = c.old;
    spec.params = values;
    if (c.reused) {
        // The merged device's own id: nothing to migrate, but a Compressor entry without talon_layout is older than
        // 1.1.0 and gets it (its variant 0 stays).
        CHECK_EQ(fx::migrateLegacyEffect(spec), c.merged == std::string(kCompressor));
        spec.params.emplace_back(std::string(fx::kVariantParam), 0.0);
    } else {
        CHECK(fx::migrateLegacyEffect(spec));
    }
    CHECK(spec.id == c.merged && valueOf(spec.params, "variant") == c.variant);
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

Stereo renderProject(const std::string& json, int blocks = 300) {
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

std::vector<float> renderLeft(Engine& e, int frames) {
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int i = 0; i < frames; i += 64) e.process(l.data() + i, r.data() + i, std::min(64, frames - i));
    return l;
}

const double kCentre = std::cos(3.14159265358979323846 / 4.0);  // a mono track's pan law at centre

// Track "a" (a constant 0.5, muted: it only keys) and "b" (0.25) through `fx`, keyed by a when `keyed`; a plays a
// note on beats 1 and 2 of its one-bar loop. Master bypassed by the caller.
ProjectSpec keyedB(const ComponentSpec& fx, bool keyed) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.layers.push_back(cawtest::testSignalLayer("a", cawtest::Shape::Dc, {{"level", 0.5}}));
    p.layers.push_back(cawtest::testSignalLayer("b", cawtest::Shape::Dc, {{"level", 0.25}}));
    p.modules.push_back({"beats", "---\nkind: pattern\n---\n0 C4 1\n4 C4 1\n"});
    p.layers[0].pattern = "beats";
    p.layers[0].mute = true;
    ComponentSpec c = fx;
    c.hasKey = keyed;
    c.key.layer = "a";
    p.layers[1].components = {c};
    return p;
}

ComponentSpec spec(const char* id, Values values) {
    ComponentSpec c;
    c.id = id;
    c.params = std::move(values);
    return c;
}

}  // namespace

TEST(merged_dynamics_devices_list_their_variants_with_the_old_descriptors) {
    for (const Case& c : kCases) {
        const fx::MergedDevice* m = fx::findMergedDevice(c.merged);
        CHECK(m != nullptr);
        if (!m) return;
        CHECK(registry().find(c.merged) != nullptr);
        CHECK(c.variant < m->variants.size());
        const ModuleDescriptor& d = m->variants[c.variant].descriptor();
        const ModuleDescriptor& old = c.legacy();
        CHECK(old.id == c.old);
        if (const ModuleDescriptor* listed = registry().find(c.old); listed && !c.reused) CHECK(listed == &old);
        CHECK(d.id == c.merged);
        // `variant` right after the old parameters; Talon's (1.1.0) then Down's extras and the talon_layout marker;
        // the Gate's (Gate, Pedal) and the Limiter's then 1.1.0's appended sidechain filter or loudness target (two).
        const bool talon = c.merged == std::string(kCompressor);
        const bool appended = c.merged == std::string(kGate) ? c.variant != 1 : c.merged == std::string(kLimiter);
        const uint32_t after = talon ? (c.variant == 0 ? 4u : 1u) : (appended ? 2u : 0u);
        CHECK_EQ(d.parameterCount, old.parameterCount + 1 + after);
        for (uint32_t k = 0; k < old.parameterCount; ++k) CHECK(d.parameters[k].id == old.parameters[k].id);
        const ParameterDescriptor& variant = d.parameters[old.parameterCount];
        if (talon) {
            const ParameterDescriptor& marker = d.parameters[d.parameterCount - 1];
            CHECK(marker.id == std::string("talon_layout") && marker.defaultValue == 1.0 && !marker.automatable && !marker.modulatable);
        }
        CHECK(variant.id == fx::kVariantParam);
        CHECK(!variant.automatable && !variant.modulatable && !variant.midiMappable);
        CHECK_EQ(variant.defaultValue, static_cast<double>(c.variant));
        CHECK_EQ(variant.choiceCount, static_cast<uint32_t>(m->variants.size()));
        // Ports (the sidechain where it was), latency, tail, domains and cost kept.
        CHECK_EQ(d.portCount, old.portCount);
        CHECK(d.ports == old.ports);
        CHECK_EQ(d.latencyFrames, old.latencyFrames);
        CHECK_EQ(d.tailFrames, old.tailFrames);
        CHECK_EQ(d.domains, old.domains);
        CHECK_EQ(d.capabilities, old.capabilities);
        CHECK(d.cpuClass == old.cpuClass);
        std::unique_ptr<ModuleProcessor> p = createComponent(registry(), c.merged, {{"variant", static_cast<double>(c.variant)}});
        CHECK(p && &p->descriptor() == &d);
    }
    const fx::MergedDevice* comp = fx::findMergedDevice(kCompressor);
    CHECK(comp && comp->variants.size() == 4u && comp->variants[0].name == "Down" && comp->variants[2].name == "Up" &&
          comp->variants[3].name == "Bus");
    const fx::MergedDevice* gate = fx::findMergedDevice(kGate);
    const fx::MergedDevice* trem = fx::findMergedDevice(kTremolo);
    CHECK(gate && gate->variants.size() == 3u && trem && trem->variants.size() == 3u && trem->variants[2].name == "Shape");
    if (!comp || !gate || !trem) return;
    CHECK(fx::findMergedDevice(kLimiter)->variants.size() == 1u && fx::findMergedDevice(kTransient)->variants.size() == 1u);
    // The keyed variants keep a real sidechain input; Dynamics has none; Shape also takes the key's notes.
    CHECK(ComponentChain::isKeyedEffect(comp->variants[0].descriptor()));
    CHECK(!ComponentChain::isKeyedEffect(comp->variants[1].descriptor()));
    CHECK(ComponentChain::isKeyedEffect(gate->variants[0].descriptor()));
    CHECK(ComponentChain::isKeyedEffect(trem->variants[2].descriptor()) && trem->variants[2].descriptor().portCount == 4u);
    CHECK(isOtherVariantParameter(kCompressor, "high_threshold") && isOtherVariantParameter(kTremolo, "depth"));
    CHECK(!isOtherVariantParameter(kCompressor, "cutoff"));
    // Not merged here: the multiband and the de-esser stay their own ids.
    CHECK(!fx::findLegacyEffect("org.caw.multiband") && !fx::findLegacyEffect("org.caw.deesser"));
}

TEST(merged_dynamics_variants_render_the_old_ids_bits_over_their_presets_and_random_values) {
    const Stereo in = music(30000);
    uint32_t seed = 1808;
    for (const Case& c : kCases) {
        std::vector<Values> sets{{}};
        for (const BuiltinPreset& p : builtinPresets(c.old)) {
            if (c.reused) break;  // the merged id's list: its old effects' (none of the reused ids has presets)
            Values x;
            for (const auto& [k, value] : p.values) x.emplace_back(std::string(k), value);
            sets.push_back(x);
        }
        for (int r = 0; r < 12; ++r) sets.push_back(randomValues(c.legacy(), seed));
        for (const Values& values : sets) {
            auto old = active(c.makeAs(c.legacy()));  // the old class under the old descriptor
            const ComponentSpec m = merged(c, values);
            auto now = active(createComponent(registry(), m.id, m.params).release());
            if (!old || !now) return;
            const Stereo want = run(*old, in, values);
            if (!sameBits(want, run(*now, in, m.params)))
                cawtest::fail(__FILE__, __LINE__, std::string(c.old) + ": the merged variant's bits differ");
            if (!c.reused) {  // and the registered old id itself, while it stays registered
                auto listed = active(registry().create(c.old).release());
                if (listed) CHECK(sameBits(want, run(*listed, in, values)));
            }
        }
    }
}

TEST(merged_dynamics_variants_report_the_old_latency_and_tail) {
    // Each variant in a chain: the latency the old effect reported (the ducker's per look-ahead and mode).
    std::vector<std::pair<const Case*, Values>> sets;
    for (const Case& c : kCases) sets.push_back({&c, {}});
    const Case& shape = kCases[3];
    for (double mode : {0.0, 1.0, 2.0})
        for (double look : {0.0, 1.0, 2.0, 3.0, 4.0}) sets.push_back({&shape, {{"mode", mode}, {"lookahead", look}}});
    for (const auto& [c, values] : sets) {
        std::string error;
        const ComponentSpec m = merged(*c, values);
        auto chain = ComponentChain::build(registry(), {m}, 48000.0, error);
        CHECK(chain != nullptr);
        if (!chain) return;
        uint32_t want = c->legacy().latencyFrames;
        if (!c->reused) {
            auto old = ComponentChain::build(registry(), {spec(c->old, values)}, 48000.0, error);
            CHECK(old != nullptr);
            if (old) want = old->latencyFrames();
        }
        CHECK_EQ(chain->latencyFrames(), want);
        if (c->old == std::string("org.caw.compressor") || c->old == std::string("org.caw.limiter"))
            CHECK_EQ(chain->latencyFrames(), 240u);
    }
    // The ducker's 10 ms look-ahead in Audio mode is reported through the merged device too.
    std::string error;
    auto look = ComponentChain::build(registry(), {merged(shape, {{"mode", 0.0}, {"lookahead", 4.0}})}, 48000.0, error);
    CHECK(look && look->latencyFrames() == 480u);
}

TEST(merged_dynamics_resolves_the_old_presets_under_its_id_with_equal_values) {
    std::map<std::string, size_t> total;
    for (const Case& c : kCases) {
        if (c.reused) continue;
        for (const BuiltinPreset& p : builtinPresets(c.old)) {
            ++total[c.merged];
            const BuiltinPreset* found = findBuiltinPreset(c.merged, p.name);
            CHECK(found != nullptr);
            if (!found) continue;
            CHECK(found->description == p.description);
            std::map<std::string, double> want, got;
            for (const auto& [k, x] : p.values) want[std::string(k)] = x;
            want["variant"] = c.variant;
            if (c.merged == std::string(kCompressor)) want["talon_layout"] = 1.0;  // 1.1.0: every Talon preset says so
            for (const auto& [k, x] : found->values) got[std::string(k)] = x;
            CHECK(want == got);
            Values applied;
            CHECK(applyBuiltinPreset(c.merged, p.name, applied));
            CHECK_EQ(valueOf(applied, "variant"), static_cast<double>(c.variant));
        }
    }
    CHECK(total[kCompressor] >= 1u && total[kTremolo] >= 1u);  // the dynamics processor's; the ducker's
    // ... followed by Up's and Bus's own (1.1.0, new DSP, no old effect): each names variant 2 or 3. Every Talon
    // preset carries talon_layout.
    size_t fresh = 0;
    for (const BuiltinPreset& p : builtinPresets(kCompressor)) {
        bool marked = false;
        for (const auto& [k, x] : p.values) {
            if (k == "variant" && (x == 2.0 || x == 3.0)) ++fresh;
            marked = marked || (k == "talon_layout" && x == 1.0);
        }
        CHECK(marked);
    }
    CHECK(fresh >= 16u);
    // ... and last 1.1.0's appended ones (Down's; the Limiter's and Transient's, which had none), as they are.
    const size_t downs = fx::appendedVariantPresets(kCompressor).size();
    CHECK(downs >= 8u);
    CHECK_EQ(builtinPresets(kCompressor).size(), total[kCompressor] + fresh + downs);
    for (size_t k = 0; k < downs; ++k)
        CHECK(builtinPresets(kCompressor)[total[kCompressor] + fresh + k].name == fx::appendedVariantPresets(kCompressor)[k].name);
    for (const char* id : {kLimiter, kTransient}) {
        CHECK(builtinPresets(id).size() == fx::appendedVariantPresets(id).size() && builtinPresets(id).size() >= 8u);
        for (const BuiltinPreset& p : builtinPresets(id)) CHECK_EQ(valueOf(Values(p.values.begin(), p.values.end()), "variant"), 0.0);
    }
}

TEST(a_saved_project_with_the_old_dynamics_ids_lanes_and_a_rack_plays_the_merged_devices_the_same) {
    const std::string gateHash = std::to_string(rackChildHash("org.caw.gate"));
    const std::string duckHash = std::to_string(rackChildHash("org.caw.ducker"));
    const std::string compHash = std::to_string(rackChildHash(kCompressor));
    auto project = [](const std::string& track, const std::string& master) {
        return std::string(R"({"caw_project":1,"bpm":120,"loop_bars":2,"layers":[)"
                           R"({"id":"k","volume":1,"mute":true,"instrument":{"id":"org.caw.test.osc","params":{"shape":0,"freq":60,"level":0.8}}},)"
                           R"({"id":"t","volume":1,"instrument":{"id":"org.caw.test.osc","params":{"shape":1,"freq":110,"level":0.5}},)"
                           R"("components":[)") + track + R"(]}],"master_components":[)" + master +
               R"(],"automation":[{"target_type":"component","layer":"t","component":0,"target":"high_threshold",)"
               R"("points":[{"step":0,"value":-40},{"step":16,"value":-6}]},)"
               R"({"target_type":"component","layer":"t","component":3,"target":"s1.threshold","points":[{"step":0,"value":-50},{"step":24,"value":-10}]},)"
               R"({"target_type":"component","component":0,"target":"depth","points":[{"step":0,"value":0.2},{"step":32,"value":1}]}]})";
    };
    const std::string oldJson = project(
        R"({"id":"org.caw.dynamics","params":{"high_ratio":6,"low_ratio":2,"mix":0.8}},)"
        R"({"id":"org.caw.gate","params":{"threshold":-30,"range":-40,"sidechain":1},"key":{"layer":"k"}},)"
        R"({"id":"org.caw.ducker","params":{"mode":0,"depth":0.8,"lookahead":2},"key":{"layer":"k"}},)"
        R"({"id":"org.caw.rack.fx","params":{"s1_fx":)" + gateHash + R"(,"s1.threshold":-35,"s2_fx":)" + duckHash +
            R"(,"s2.mode":2,"s2.depth":0.6}},)"
        R"({"id":"org.caw.transient","params":{"attack":0.6,"sustain":-0.3}},{"id":"org.caw.compressor","params":{"ratio":8}})",
        R"({"id":"org.caw.ducker","params":{"mode":2,"rate":3}},{"id":"org.caw.limiter","params":{"gain":6}})");
    const std::string newJson = project(
        R"({"id":"org.caw.compressor","params":{"variant":1,"high_ratio":6,"low_ratio":2,"mix":0.8}},)"
        R"({"id":"org.caw.compressor","params":{"variant":2,"threshold":-30,"range":-40,"sidechain":1},"key":{"layer":"k"}},)"
        R"({"id":"org.caw.compressor","params":{"variant":3,"mode":0,"depth":0.8,"lookahead":2},"key":{"layer":"k"}},)"
        R"({"id":"org.caw.rack.fx","params":{"s1_fx":)" + compHash + R"(,"s1.variant":2,"s1.threshold":-35,"s2_fx":)" +
            compHash + R"(,"s2.variant":3,"s2.mode":2,"s2.depth":0.6}},)"
        R"({"id":"org.caw.transient","params":{"variant":0,"attack":0.6,"sustain":-0.3}},{"id":"org.caw.compressor","params":{"variant":0,"ratio":8}})",
        R"({"id":"org.caw.compressor","params":{"variant":3,"mode":2,"rate":3}},{"id":"org.caw.limiter","params":{"variant":0,"gain":6}})");
    const Stereo a = renderProject(oldJson), b = renderProject(newJson);
    CHECK(sameBits(a, b));
    CHECK(peak(a.l) > 0.01);
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(oldJson, p, error));
    CHECK(fx::hasLegacyEffects(p));
    CHECK(fx::migrateLegacyEffects(p));
    CHECK(!fx::hasLegacyEffects(p));
    const auto& t = p.layers[1].components;
    CHECK(t[0].id == kCompressor && t[1].id == kGate && t[2].id == kTremolo && p.masterComponents[0].id == kTremolo);
    CHECK(valueOf(t[0].params, "variant") == 1 && valueOf(t[1].params, "variant") == -12345 && valueOf(t[2].params, "variant") == 2);
    CHECK(t[1].hasKey && t[2].hasKey);  // the keys stay
    CHECK(valueOf(t[3].params, "s1_fx") == rackChildHash(kGate) && valueOf(t[3].params, "s1.variant") == 0);
    CHECK(valueOf(t[3].params, "s2_fx") == rackChildHash(kTremolo) && valueOf(t[3].params, "s2.variant") == 2);
    CHECK(valueOf(t[3].params, "rack_layout") == kRackLayoutCurrent);
    CHECK(t[4].id == kTransient && t[5].id == kCompressor && valueOf(t[5].params, "variant") == -12345);  // reused: untouched
    CHECK(valueOf(t[0].params, "talon_layout") == 1 && valueOf(t[5].params, "talon_layout") == 1);  // marked 1.1.0
    CHECK_EQ(p.automation.size(), 3u);
    // The 1.0.9 form (Gate and Shape as the Compressor's variants 2 and 3, no talon_layout) moves the same way.
    ProjectSpec q;
    CHECK(parseProject(newJson, q, error));
    CHECK(fx::hasLegacyEffects(q) && fx::migrateLegacyEffects(q) && !fx::hasLegacyEffects(q));
    const auto& u = q.layers[1].components;
    CHECK(u[1].id == kGate && valueOf(u[1].params, "variant") == 0 && u[2].id == kTremolo && valueOf(u[2].params, "variant") == 2);
    CHECK(valueOf(u[3].params, "s1_fx") == rackChildHash(kGate) && valueOf(u[3].params, "s1.variant") == 0);
    CHECK(valueOf(u[3].params, "s2_fx") == rackChildHash(kTremolo) && valueOf(u[3].params, "s2.variant") == 2);
    CHECK(q.masterComponents[0].id == kTremolo && u[5].id == kCompressor && valueOf(u[5].params, "talon_layout") == 1);
    CHECK_EQ(q.automation.size(), 3u);
    // caw_migrate_component for the app's document.
    char* text = caw_migrate_component(R"({"id":"org.caw.ducker","preset":"Pump","params":{"mode":1}})");
    Json j;
    CHECK(text && parseJson(text, j, error) && j.boolean("migrated", false) && j.string("id") == kTremolo);
    CHECK(j.get("params") && j.get("params")->number("variant", -1) == 2 && j.get("params")->number("mode", -1) == 1);
    caw_free(text);
    text = caw_migrate_component(R"({"id":"org.caw.limiter","params":{"gain":3}})");
    CHECK(text && parseJson(text, j, error) && !j.boolean("migrated", true) && j.string("id") == kLimiter);
    caw_free(text);
}

TEST(a_racks_old_dynamics_children_migrate_with_their_values_and_routes_and_sound_the_same) {
    auto h = [](const char* id) { return static_cast<double>(rackChildHash(id)); };
    ComponentSpec old;
    old.id = std::string(kFxRackId);
    old.params = {{"s1_fx", h("org.caw.gate")},     {"s1.threshold", -30}, {"s2_fx", h("org.caw.dynamics")},
                  {"s2.high_ratio", 5},             {"s3_fx", h("org.caw.ducker")}, {"s3.mode", 2},
                  {"s4_fx", h("org.caw.transient")}, {"s4.attack", 0.5},  {"mod1_src", 1},
                  {"mod1_amt", 0.4},                {"mod2_src", 1},       {"mod2_amt", -0.3}};
    // The routes as a pre-1.0.8 rack had them: today's rack reads s1's hash as Gate's own id (1.1.0), whose list
    // has `variant` and then 1.1.0's sc_lpf and sc_listen (rack layout 4); the old gate's had none of them, so
    // everything after s1 sat three places earlier.
    old.params.emplace_back("mod1_dst", destination(kFxRackId, old.params, "s3.depth") - 3);
    old.params.emplace_back("mod2_dst", destination(kFxRackId, old.params, "s4.sustain") - 3);
    CHECK(valueOf(old.params, "mod1_dst") > 0 && valueOf(old.params, "mod2_dst") > 0);
    ComponentSpec m = old;
    CHECK(fx::migrateLegacyEffect(m));
    CHECK_EQ(valueOf(m.params, "s1_fx"), h(kGate));  // 1.1.0: the gate's own id again
    CHECK_EQ(valueOf(m.params, "s2_fx"), h(kCompressor));
    CHECK_EQ(valueOf(m.params, "s3_fx"), h(kTremolo));
    CHECK_EQ(valueOf(m.params, "s4_fx"), h(kTransient));  // the merged id's own: unchanged
    CHECK_EQ(valueOf(m.params, "s1.variant"), 0.0);
    CHECK_EQ(valueOf(m.params, "s2.variant"), 1.0);
    CHECK_EQ(valueOf(m.params, "s3.variant"), 2.0);
    CHECK_EQ(valueOf(m.params, "mod1_dst"), destination(kFxRackId, m.params, "s3.depth"));
    CHECK_EQ(valueOf(m.params, "mod2_dst"), destination(kFxRackId, m.params, "s4.sustain"));
    CHECK(valueOf(m.params, "mod2_dst") != valueOf(old.params, "mod2_dst"));
    CHECK(!fx::migrateLegacyEffect(m));
    // The old rack's sound: the same children with its routes on s3.depth and s4.sustain as today's rack reads them.
    ComponentSpec heard = old;
    for (auto& [k, v] : heard.params)
        if (k == "mod1_dst" || k == "mod2_dst") v += 3.0;
    const Stereo in = music(48000);
    const Stereo a = renderChain({heard}, in), b = renderChain({m}, in);
    CHECK(sameBits(a, b));
    CHECK(peak(b.l) > 0.01);
}

// ---------- Each variant's own ports in the chain (keyed, key notes, plain, per note) ----------

TEST(a_migrated_ducker_in_notes_mode_hears_the_key_tracks_notes) {
    // Fails if the chain wires a merged device by its first variant's ports (the compressor has no key notes).
    const ComponentSpec oldDucker = spec("org.caw.ducker", {{"mode", 1.0}, {"depth", 1.0}, {"attack", 0.5}, {"hold", 5.0}, {"release", 60.0}});
    ComponentSpec shape = oldDucker;
    shape.id = kCompressor;
    shape.params.emplace_back("variant", 3.0);
    std::vector<std::vector<float>> outs;
    for (const ComponentSpec& c : {oldDucker, shape}) {
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(ok(e.setProject(keyedB(c, true))));
        e.play();
        outs.push_back(renderLeft(e, 48000));
    }
    for (const auto& out : outs) {
        CHECK(std::fabs(out[200]) < 1e-3);    // ducked on the note
        CHECK_NEAR(out[12000], 0.25 * kCentre, 1e-4);
        CHECK(std::fabs(out[24200]) < 1e-3);
    }
    CHECK(outs[0] == outs[1]);
}

TEST(the_dynamics_variant_is_a_plain_effect_that_passes_audio_and_runs_per_note) {
    const Values values = {{"high_ratio", 4}, {"low_ratio", 3}};
    const ComponentSpec dyn = merged(kCases[1], values);
    std::string error;
    auto chain = ComponentChain::build(registry(), {dyn}, 48000.0, error);
    CHECK(chain && !chain->keyed(0));
    auto comp = ComponentChain::build(registry(), {merged(kCases[0], {})}, 48000.0, error);
    CHECK(comp && comp->keyed(0));
    const Stereo in = music(24000);
    const Stereo a = renderChain({spec("org.caw.dynamics", values)}, in), b = renderChain({dyn}, in);
    CHECK(sameBits(a, b));
    CHECK(peak(b.l) > 0.05);  // processed, not silence
    // A key on it is ignored with a warning, as on any effect without a sidechain input; the track still sounds.
    Engine e(48000);
    e.setMasterBypass(true);
    const std::string r = e.setProject(keyedB(dyn, true));
    CHECK(ok(r) && r.find("no sidechain input") != std::string::npos);
    e.play();
    CHECK(std::fabs(renderLeft(e, 4800)[4000]) > 0.05f);
    // Per note: the old dynamics could run in a track's noteComponents, and so does its variant; a keyed one can't.
    CHECK(ComponentChain::buildNoteEffects(registry(), {dyn}, 48000.0, error) != nullptr);
    CHECK(ComponentChain::buildNoteEffects(registry(), {spec("org.caw.dynamics", values)}, 48000.0, error) != nullptr);
    CHECK(ComponentChain::buildNoteEffects(registry(), {merged(kCases[2], {})}, 48000.0, error) == nullptr);
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
    p.layers[0].noteComponents = {spec("org.caw.dynamics", values)};
    Engine f(48000);
    CHECK(ok(f.setProject(p)));
}

TEST(a_variant_change_between_keyed_and_plain_rewires_the_chain) {
    auto with = [](double variant) {
        ComponentSpec c = spec(kCompressor, {{"variant", variant}});
        if (variant == 0) c.params = {{"variant", 0.0}, {"sidechain", 1.0}, {"threshold", -30.0}, {"ratio", 20.0},
                                      {"knee", 0.0}, {"auto_makeup", 0.0}, {"attack", 0.05}};
        if (variant == 3) c.params = {{"variant", 3.0}, {"sidechain", 1.0}, {"threshold", -30.0}, {"ratio", 3.0}, {"attack", 0.1}};
        c.params.emplace_back("talon_layout", 1.0);  // 1.1.0's variants (Bus is 3)
        return keyedB(c, true);
    };
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(with(0))));
    e.play();
    std::vector<float> out = renderLeft(e, 9600);
    CHECK(out[9000] < 0.25 * kCentre * 0.2 && out[9000] > 0.0f);  // keyed: held down by the key
    for (double v : {1.0, 3.0, 0.0}) {
        const std::string r = e.setProject(with(v));
        CHECK(ok(r));
        CHECK((r.find("no sidechain input") != std::string::npos) == (v == 1.0));
        renderLeft(e, 4800);  // the crossfade into the rebuilt chain
        float shown[64];
        CHECK(e.componentDisplay("b", 0, shown, 64) > 0);
    }
    // Back on the compressor: the key holds b down again.
    out = renderLeft(e, 9600);
    CHECK(out[9000] < 0.25 * kCentre * 0.2);
}

TEST(the_components_json_lists_the_merged_dynamics_variants) {
    Engine e(48000);
    Json j;
    std::string error;
    CHECK(parseJson(e.nativeComponentsJson(), j, error));
    const Json* list = j.get("components");
    CHECK(list != nullptr);
    if (!list) return;
    std::map<std::string, size_t> variants;
    for (const Json& c : list->arr)
        if (const Json* v = c.get("variants")) variants[c.string("id")] = v->arr.size();
    CHECK_EQ(variants[kCompressor], 4u);
    CHECK_EQ(variants[kGate], 3u);
    CHECK_EQ(variants["org.caw.duck"], 3u);
    CHECK_EQ(variants[kTremolo], 3u);
    CHECK_EQ(variants[kLimiter], 1u);
    CHECK_EQ(variants[kTransient], 1u);
}

// ---------- The transient shaper's optional outputs ----------

TEST(the_transient_variants_optional_outputs_change_nothing_heard_and_split_its_output) {
    const Stereo in = music(36000);
    const Values values = {{"attack", 0.7}, {"sustain", -0.4}, {"mix", 0.9}};
    auto plain = active(createComponent(registry(), kTransient, {}).release());
    auto ported = active(createComponent(registry(), kTransient, {}).release());
    auto* fx = dynamic_cast<fx::EffectBase*>(ported.get());
    CHECK(fx != nullptr);
    if (!fx || !plain) return;
    const auto ports = fx->optionalPorts();
    CHECK(ports.size() == 2u && ports[0].id == "transient" && ports[1].id == "sustain" && !ports[0].input && !ports[1].input);
    const Stereo a = run(*plain, in, values);
    // Connected: the main output is the same bits, and the two outputs sum to it.
    const ModuleDescriptor& d = ported->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    Stereo b{std::vector<float>(in.l.size()), std::vector<float>(in.l.size())};
    std::vector<float> tl(64), tr(64), sl(64), sr(64);
    double worst = 0, transient = 0, sustain = 0;
    for (size_t start = 0; start < in.l.size(); start += 64) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(64, in.l.size() - start));
        CHECK(fx->connectOptionalPort(0, tl.data(), tr.data()) && fx->connectOptionalPort(1, sl.data(), sr.data()));
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        float* oc[2] = {b.l.data() + start, b.r.data() + start};
        AudioProcessBlock blk;
        blk.input = {ic, 2, n};
        blk.output = {oc, 2, n};
        blk.frames = n;
        blk.sampleRate = 48000;
        blk.parameters = params.data();
        blk.parameterCount = d.parameterCount;
        CHECK(ported->process(blk));
        for (uint32_t i = 0; i < n; ++i) {
            worst = std::max(worst, std::fabs(static_cast<double>(tl[i]) + sl[i] - oc[0][i]));
            worst = std::max(worst, std::fabs(static_cast<double>(tr[i]) + sr[i] - oc[1][i]));
            transient = std::max(transient, std::fabs(static_cast<double>(tl[i])));
            sustain = std::max(sustain, std::fabs(static_cast<double>(sl[i])));
        }
    }
    CHECK(sameBits(a, b));
    CHECK(worst < 1e-6);
    CHECK(transient > 0.01 && sustain > 0.01);
    // The class under the old descriptor (the old id itself) sounds the same.
    auto old = active(fx::makeTransientAs(fx::legacyTransientDescriptor()));
    if (old) CHECK(sameBits(a, run(*old, in, values)));
}
