// Timber's load-time alias (1.1.3): every old model, Classic and Simulated knobs and bad values, lands on the expected instrument and variant and plays finite sound.
#include <cmath>
#include <string>
#include <vector>

#include "engine.h"
#include "fx_merged.h"
#include "json.h"
#include "presets.h"
#include "test.h"
#include "timber_harness.h"
#include "timber_migrate.h"

using namespace caw;
using namespace timber_test;

namespace {

struct Case {
    Values old;
    const char* id;
    int variant;  // -1: not a merged device (no `variant`)
};

double valueOf(const Values& v, const std::string& id, double def = -999) {
    double x = def;
    for (const auto& [k, y] : v)
        if (k == id) x = y;
    return x;
}

// Starling's plucked variants (1 guitar, 2 harp) are being added in 1.1.3; until then plucked plays its piano.
int plucked(int wanted) {
    const fx::MergedDevice* d = fx::findMergedDevice("org.caw.starling");
    return d && static_cast<size_t>(wanted) < d->variants.size() ? wanted : 0;
}

std::vector<Case> cases() {
    const double nan = std::nan("");
    return {
        // Piano: Classic (no `sim`), Simulated, each character, and no `variant` at all
        {{{"variant", 0}, {"hammer", 0.7}, {"space", 0.2}}, "org.caw.starling", 0},
        {{{"variant", 0}, {"sim", 1}, {"character", 2}, {"noise", 0.9}, {"tier", 3}}, "org.caw.starling", 0},
        {{{"character", 1}}, "org.caw.starling", 0},
        // Electric piano: tine and reed, Classic and Simulated
        {{{"variant", 1}, {"pickup", 0.9}, {"bark", 0.7}, {"tremolo", 0.5}}, "org.caw.synth.flagship", -1},
        {{{"variant", 1}, {"kind", 1}, {"sim", 1}, {"noises", 0.4}, {"decay", 3.0}}, "org.caw.synth.flagship", -1},
        // Organ: a tonewheel registration (rotary on) and a pipe-like one (rotary off, no percussion)
        {{{"variant", 2}, {"db16", 8}, {"db4", 8}, {"rotary", 2}, {"drive", 0.8}}, "org.caw.synth.flagship", -1},
        {{{"variant", 2}, {"db16", 6}, {"db8", 8}, {"db2", 4}, {"rotary", 0}, {"click", 0}}, "org.caw.bittern", -1},
        // Plucked: guitars and koto, harp
        {{{"variant", 3}, {"instrument", 0}, {"pick", 0.8}, {"damping", 0.8}}, "org.caw.starling", plucked(1)},
        {{{"variant", 3}, {"instrument", 2}, {"sim", 1}}, "org.caw.starling", plucked(2)},
        {{{"variant", 3}, {"instrument", 3}}, "org.caw.starling", plucked(1)},
        // Bowed: each section
        {{{"variant", 4}, {"section", 0}, {"position", 0.04}}, "org.caw.nightingale", 0},
        {{{"variant", 4}, {"section", 2}, {"sim", 1}, {"noises", 0.7}}, "org.caw.nightingale", 2},
        {{{"variant", 4}, {"section", 3}}, "org.caw.nightingale", 3},
        // Mallets: marimba, vibraphone (motor, damper), chimes, bell
        {{{"variant", 5}}, "org.caw.woodpecker", 0},
        {{{"variant", 5}, {"instrument", 1}, {"motor", 9.5}, {"dampen", 0.8}}, "org.caw.woodpecker", 3},
        {{{"variant", 5}, {"instrument", 4}}, "org.caw.woodpecker", 4},
        {{{"variant", 5}, {"instrument", 5}, {"sim", 1}}, "org.caw.woodpecker", 4},
        // Winds: clarinet, flute, sax, brass
        {{{"variant", 6}}, "org.caw.curlew", 1},
        {{{"variant", 6}, {"instrument", 1}, {"sim", 1}}, "org.caw.curlew", 0},
        {{{"variant", 6}, {"instrument", 2}, {"growl", 0.6}}, "org.caw.curlew", 2},
        {{{"variant", 6}, {"instrument", 3}}, "org.caw.curlew", 3},
        // Weird values: NaN, out of range, an unknown model index (past the last: the last, as Timber read it)
        {{{"variant", nan}, {"hammer", nan}, {"tone", 1e9}}, "org.caw.starling", 0},
        {{{"variant", -3}, {"level", -1e300}}, "org.caw.starling", 0},
        {{{"variant", 99}, {"instrument", 42}, {"breath", nan}}, "org.caw.curlew", 3},
        {{{"variant", 4}, {"section", nan}, {"pressure", 7}, {"voices", 1e6}}, "org.caw.nightingale", 0},
        {{{"variant", 2}, {"db16", nan}, {"db8", 99}, {"rotary", -5}, {"perc", 9}}, "org.caw.synth.flagship", -1},
    };
}

}  // namespace

TEST(timber_migrates_each_model_to_its_instrument_and_variant) {
    for (const Case& c : cases()) {
        std::string id(timber::kTimberId);
        Values params = c.old;
        std::string preset;
        CHECK(isLegacyInstrument(id));
        CHECK(migrateLegacyInstrument(id, params, &preset));
        if (id != c.id) cawtest::fail(__FILE__, __LINE__, "went to " + id + ", wanted " + c.id);
        CHECK(!preset.empty());
        CHECK(!isLegacyInstrument(id));  // once: the new entry is not migrated again
        if (c.variant >= 0) CHECK(valueOf(params, "variant") == c.variant);
        for (const auto& [k, v] : params) CHECK(std::isfinite(v));
        // Every value is one of the new instrument's parameters, inside its range.
        const ModuleDescriptor* d = findComponentDescriptor(registry(), id, params);
        CHECK(d != nullptr);
        if (!d) continue;
        for (const auto& [k, v] : params) {
            const ParameterDescriptor* p = nullptr;
            for (uint32_t i = 0; i < d->parameterCount; ++i)
                if (d->parameters[i].id == k) p = &d->parameters[i];
            if (!p) {
                cawtest::fail(__FILE__, __LINE__, id + " has no parameter " + k);
                continue;
            }
            CHECK(v >= p->minimum && v <= p->maximum);
        }
    }
}

TEST(timber_migrated_entries_play_finite_sound) {
    for (const Case& c : cases()) {
        std::string id(timber::kTimberId);
        Values params = c.old;
        migrateLegacyInstrument(id, params);
        auto p = makeInstrument(id.c_str(), params);
        CHECK(p != nullptr);
        if (!p) continue;
        const Stereo s = play(*p, params, {{0.0, 0.4, 60, 0.8}, {0.05, 0.5, 67, 0.6}, {0.1, 0.3, 36, 1.0}}, 0.8);
        bool finite = true;
        double sum = 0;
        for (size_t i = 0; i < s.size(); ++i) finite = finite && std::isfinite(s.l[i]) && std::isfinite(s.r[i]), sum += std::fabs(s.l[i]);
        CHECK(finite);
        if (!(sum > 0)) cawtest::fail(__FILE__, __LINE__, id + " was silent");
    }
}

TEST(timber_project_loads_in_the_engine_and_its_lanes_follow_the_model) {
    // A project with a Timber track per model and a lane on each loads, plays and stays finite.
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    for (int model = 0; model < 7; ++model) {
        LayerSpec l;
        l.id = "t" + std::to_string(model);
        l.hasInstrument = true;
        l.instrument.id = std::string(timber::kTimberId);
        l.instrument.params = {{"variant", static_cast<double>(model)}, {"sim", model % 2 ? 1.0 : 0.0}, {"tone", 0.3}};
        p.layers.push_back(l);
        ProjectAutomationLaneSpec lane;
        lane.targetType = "instrument";
        lane.moduleId = l.id;
        lane.target = model == 4 ? "pressure" : "tone";
        lane.points = {{0, 0.2}, {8, 0.8}};
        p.automation.push_back(lane);
    }
    Engine e(48000);
    const std::string set = e.setProject(p);
    if (set.find("\"ok\":true") == std::string::npos) cawtest::fail(__FILE__, __LINE__, set);
    std::vector<float> left(256), right(256);
    for (int model = 0; model < 7; ++model) e.noteOn("t" + std::to_string(model), model, 60, 0.8);
    double sum = 0;
    for (int k = 0; k < 100; ++k) {
        e.process(left.data(), right.data(), 256);
        for (float v : left) sum += std::fabs(v);
    }
    CHECK(std::isfinite(sum) && sum > 0);
    // The lanes, as caw_migrate_instrument reports them to the app: a bowed entry's pressure moves Nightingale's;
    // Kestrel has no Tone knob in the same units, so a tonewheel lane on it is dropped; release becomes Env 1's.
    const std::string bowed = migrateInstrumentJson(R"({"id":"org.caw.timber","params":{"variant":4,"section":2}})");
    CHECK(bowed.find("\"id\":\"org.caw.nightingale\"") != std::string::npos);
    CHECK(bowed.find("\"pressure\":\"pressure\"") != std::string::npos);
    const std::string organ = migrateInstrumentJson(R"({"id":"org.caw.timber","params":{"variant":2,"rotary":1}})");
    CHECK(organ.find("\"id\":\"org.caw.synth.flagship\"") != std::string::npos);
    CHECK(organ.find("\"tone\":") == std::string::npos);
    CHECK(organ.find("\"release\":\"env1_release\"") != std::string::npos);
    CHECK(organ.find("\"preset\":\"Tonewheel organ\"") != std::string::npos);
}

TEST(timber_is_no_longer_registered) {
    CHECK(registry().find(timber::kTimberId) == nullptr);
    CHECK(fx::findMergedDevice(timber::kTimberId) == nullptr);
}
