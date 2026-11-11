// Project modulation (#161): the built-in modulators, links to knobs, volume, pan and sends, loops refused, block-size parity.
#include <cmath>
#include <string>
#include <vector>

#include "builtin_components.h"
#include "component_chain.h"
#include "engine.h"
#include "modulation_links.h"
#include "project.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;
using cawtest::Shape;

namespace {

const double kCentre = std::cos(3.14159265358979323846 / 4.0);

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

ModulatorSpec modulator(const std::string& id, const std::string& component, std::vector<std::pair<std::string, double>> params = {}) {
    ModulatorSpec m;
    m.id = id;
    m.name = id;
    m.component.id = component;
    m.component.params = std::move(params);
    return m;
}

ModLinkSpec link(uint32_t id, const std::string& source, const std::string& type, const std::string& layer, double amount,
                 int index = -1, const std::string& param = "", uint32_t output = 0, bool bipolar = false) {
    ModLinkSpec l;
    l.id = id;
    l.source = source;
    l.output = output;
    l.target.type = type;
    l.target.layer = layer;
    l.target.index = index;
    l.target.param = param;
    l.amount = amount;
    l.bipolar = bipolar;
    return l;
}

std::vector<float> run(Engine& e, int64_t frames, int block = 64) {
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; i += block) {
        const int n = static_cast<int>(std::min<int64_t>(block, frames - i));
        e.process(l.data() + i, r.data() + i, n);
    }
    return l;
}

std::vector<float> runUneven(Engine& e, int64_t frames) {
    static const int sizes[] = {37, 64, 1, 100, 13, 256, 7, 512};
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int64_t i = 0, k = 0; i < frames; ++k) {
        const int n = static_cast<int>(std::min<int64_t>(sizes[k % 8], frames - i));
        e.process(l.data() + i, r.data() + i, n);
        i += n;
    }
    return l;
}

// A DC track ("dc", level 0.5) with a Utility (gain 0 dB) and the given modulators and links.
ProjectSpec dcProject(std::vector<ModulatorSpec> mods, std::vector<ModLinkSpec> links) {
    ComponentSpec utility;
    utility.id = "org.caw.utility";
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("dc", Shape::Dc, {{"level", 0.5}}, {utility})});
    p.modulators = std::move(mods);
    p.modulation = std::move(links);
    return p;
}

float last(const std::vector<float>& v) { return v.back(); }

std::string json(const std::string& body) {
    return R"({"caw_project":1,"layers":[{"id":"a","name":"A"},{"id":"b","name":"B"}],)" + body + "}";
}

}  // namespace

TEST(the_built_in_modulators_are_modulators_and_a_chain_refuses_them) {
    ModuleRegistry reg;
    registerBuiltinComponents(reg);
    for (const char* id : {"org.caw.mod.lfo", "org.caw.mod.envelope", "org.caw.mod.follower", "org.caw.mod.steps",
                           "org.caw.mod.random", "org.caw.mod.macros", "org.caw.mod.midi"}) {
        const ModuleDescriptor* d = reg.find(id);
        CHECK(d != nullptr);
        if (!d) continue;
        CHECK(ComponentChain::isModulator(*d));
        CHECK(validateModuleDescriptor(*d) == ModuleValidation::Ok);
        std::string error;
        ComponentSpec spec;
        spec.id = id;
        CHECK(ComponentChain::build(reg, {spec}, 48000.0, error) == nullptr);
        CHECK(error.find("is a modulator") != std::string::npos);
    }
    CHECK(!ComponentChain::isModulator(*reg.find("org.caw.utility")));
}

TEST(project_json_reads_modulators_and_links_and_refuses_loops) {
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(json(R"("modulators":[{"id":"lfo","layer":"a","component":{"id":"org.caw.mod.lfo","params":{"rate":2}}},
        {"id":"fol","input":"a","hears":"audio","tap":"post","component":"org.caw.mod.follower"}],
        "modulation":[{"id":3,"source":"lfo","target":{"type":"component","layer":"b","index":0,"param":"gain"},"amount":0.5,"bipolar":true,"curve":0.25},
        {"id":4,"source":"fol","target":{"type":"volume","layer":"b"},"amount":-1}])"), p, error));
    CHECK_EQ(error, std::string());
    CHECK_EQ(p.modulators.size(), 2u);
    CHECK_EQ(p.modulators[0].component.params.size(), 1u);
    CHECK(p.modulators[1].hearsAudio && !p.modulators[1].hearsNotes && p.modulators[1].inputPost);
    CHECK_EQ(p.modulation.size(), 2u);
    CHECK(p.modulation[0].bipolar);
    CHECK_EQ(p.modulation[0].curve, 0.25);
    CHECK_EQ(p.modulation[1].target.type, std::string("volume"));

    // A follower on a that moves a: a layer would hear itself.
    CHECK(!parseProject(json(R"("modulators":[{"id":"f","input":"a","hears":"audio","component":"org.caw.mod.follower"}],
        "modulation":[{"id":1,"source":"f","target":{"type":"pan","layer":"a"},"amount":1}])"), p, error));
    CHECK(error.find("can't hear itself") != std::string::npos);
    // Followers on a and b, each moving the other: a routing loop.
    CHECK(!parseProject(json(R"("modulators":[{"id":"f","input":"a","hears":"audio","component":"org.caw.mod.follower"},
        {"id":"g","input":"b","hears":"audio","component":"org.caw.mod.follower"}],
        "modulation":[{"id":1,"source":"f","target":{"type":"volume","layer":"b"},"amount":1},
                      {"id":2,"source":"g","target":{"type":"volume","layer":"a"},"amount":1}])"), p, error));
    CHECK(error.find("loop") != std::string::npos);
    // ... and through another modulator.
    CHECK(!parseProject(json(R"("modulators":[{"id":"f","input":"a","hears":"audio","component":"org.caw.mod.follower"},
        {"id":"m","component":"org.caw.mod.lfo"}],
        "modulation":[{"id":1,"source":"f","target":{"type":"modulator","layer":"m","param":"rate"},"amount":1},
                      {"id":2,"source":"m","target":{"type":"volume","layer":"a"},"amount":1}])"), p, error));
    CHECK(error.find("hear itself") != std::string::npos);
    // An envelope from a's notes may move a (notes don't depend on the sound).
    CHECK(parseProject(json(R"("modulators":[{"id":"e","input":"a","component":"org.caw.mod.envelope"}],
        "modulation":[{"id":1,"source":"e","target":{"type":"volume","layer":"a"},"amount":1}])"), p, error));
    // Modulators moving each other in a loop.
    CHECK(!parseProject(json(R"("modulators":[{"id":"x","component":"org.caw.mod.lfo"},{"id":"y","component":"org.caw.mod.lfo"}],
        "modulation":[{"id":1,"source":"x","target":{"type":"modulator","layer":"y","param":"rate"},"amount":1},
                      {"id":2,"source":"y","target":{"type":"modulator","layer":"x","param":"rate"},"amount":1}])"), p, error));
    CHECK(error.find("modulation makes a loop") != std::string::npos);
    // Unknown sources, layers and duplicate ids.
    CHECK(!parseProject(json(R"("modulation":[{"id":1,"source":"nope","target":{"type":"volume","layer":"a"}}])"), p, error));
    CHECK(!parseProject(json(R"("modulators":[{"id":"x","component":"org.caw.mod.lfo"}],
        "modulation":[{"id":1,"source":"x","target":{"type":"volume","layer":"zz"}}])"), p, error));
    CHECK(!parseProject(json(R"("modulators":[{"id":"x","component":"org.caw.mod.lfo"},{"id":"x","component":"org.caw.mod.lfo"}]})"), p, error));
}

TEST(a_macro_moves_a_tracks_volume_and_a_component_knob_without_changing_their_base) {
    Engine e(48000.0);
    e.setMasterBypass(true);
    // Macro 1 at 1 pulls the volume all the way down (-1 of the fader's travel): silence.
    ProjectSpec p = dcProject({modulator("mac", "org.caw.mod.macros", {{"macro1", 1.0}})},
                              {link(1, "mac", "volume", "dc", -1.0)});
    CHECK(ok(e.setProjectOffline(p)));
    e.play();
    std::vector<float> out = run(e, 4800);
    CHECK(std::fabs(last(out)) < 1e-6f);
    // Macro 1 at 0: the volume is its own again (1: the DC at the centre pan).
    CHECK(e.setModulatorParam("mac", "macro1", 0.0));
    out = run(e, 4800);
    CHECK(std::fabs(last(out) - static_cast<float>(0.5 * kCentre)) < 1e-5f);
    // To the Utility's gain (-60..24 dB): 0 dB is 60/84 of the way; -0.5 of the travel is 0.214, -42 dB.
    p.modulation = {link(2, "mac", "component", "dc", -0.5, 0, "gain")};
    p.modulators[0].component.params = {{"macro1", 1.0}};
    CHECK(ok(e.setProjectOffline(p)));
    out = run(e, 9600);
    const double want = 0.5 * kCentre * std::pow(10.0, (60.0 / 84.0 - 0.5) * 84.0 / 20.0 - 3.0);
    CHECK(std::fabs(last(out) - want) < 1e-4 * 0.5);
    // The amount while it plays (a ring drag): 0 brings the knob back.
    CHECK(e.setModulationAmount(2, 0.0));
    out = run(e, 4800);
    CHECK(std::fabs(last(out) - static_cast<float>(0.5 * kCentre)) < 1e-4f);
    float offset = 1;
    CHECK(e.modulationOffset(2, offset));
    CHECK_EQ(offset, 0.0f);
    CHECK(!e.modulationOffset(99, offset));
}

TEST(an_lfo_on_a_knob_sounds_the_same_for_every_block_size_and_restarts_at_play) {
    auto render = [](bool uneven) {
        Engine e(48000.0);
        e.setMasterBypass(true);
        ProjectSpec p = dcProject({modulator("lfo", "org.caw.mod.lfo", {{"rate", 3.0}, {"shape", 1}})},
                                  {link(1, "lfo", "component", "dc", 0.3, 0, "gain", 0, true),
                                   link(2, "lfo", "pan", "dc", 0.5, -1, "", 0, true)});
        e.setProjectOffline(p);
        run(e, 1000, 50);  // stopped first: the free-running LFO moves, then Play restarts it
        e.play();
        return uneven ? runUneven(e, 48000) : run(e, 48000);
    };
    const std::vector<float> a = render(false), b = render(true);
    CHECK_EQ(a.size(), b.size());
    bool same = true;
    for (size_t i = 0; i < a.size(); ++i) same = same && a[i] == b[i];
    CHECK(same);
    float lo = 1e9f, hi = -1e9f;
    for (float x : a) lo = std::min(lo, x), hi = std::max(hi, x);
    CHECK(hi - lo > 0.05f);  // it moves
}

TEST(a_follower_on_one_track_ducks_another) {
    Engine e(48000.0);
    e.setMasterBypass(true);
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("kick", Shape::Dc, {{"level", 0.8}}),
                                                cawtest::testSignalLayer("bass", Shape::Dc, {{"level", 0.5}})});
    ModulatorSpec f = modulator("fol", "org.caw.mod.follower", {{"attack", 1.0}, {"release", 50.0}});
    f.input = "kick";
    f.hearsAudio = true;
    f.hearsNotes = false;
    p.modulators = {f};
    p.modulation = {link(1, "fol", "volume", "bass", -1.0)};
    p.layers[0].pan = -1.0;  // kick hard left, bass hard right: the right channel is the bass alone
    p.layers[1].pan = 1.0;
    CHECK(ok(e.setProjectOffline(p)));
    e.play();
    std::vector<float> l(9600), r(9600);
    for (int i = 0; i < 9600; i += 64) e.process(l.data() + i, r.data() + i, 64);
    CHECK(r.back() < 0.3f);  // the follower is near 0.8: the fader is pulled most of the way down
    float out[4] = {};
    CHECK_EQ(e.modulatorOutputs("fol", out, 4), 1);
    CHECK(out[0] > 0.7f);
    // The kick muted: the bass comes back up.
    e.setLayerMix("kick", 1.0, -1.0, true, false);
    for (int k = 0; k < 20; ++k)
        for (int i = 0; i < 9600; i += 64) e.process(l.data() + i, r.data() + i, 64);
    CHECK(r.back() > 0.45f);
}

TEST(notes_drive_an_envelope_and_midi_to_cv_and_a_modulator_moves_another) {
    Engine e(48000.0);
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("keys", Shape::Sine, {{"mode", 1.0}})});
    ModulatorSpec env = modulator("env", "org.caw.mod.envelope", {{"attack", 0.001}, {"sustain", 0.6}});
    env.input = "keys";
    ModulatorSpec cv = modulator("cv", "org.caw.mod.midi", {{"low", 0}, {"high", 127}});
    cv.input = "keys";
    ModulatorSpec mac = modulator("mac", "org.caw.mod.macros", {{"macro1", 1.0}});
    ModulatorSpec steps = modulator("steps", "org.caw.mod.steps", {{"steps", 1}, {"s1", 0.0}});
    p.modulators = {steps, env, cv, mac};  // steps listed first: it still runs after the macro that moves it
    p.modulation = {link(1, "mac", "modulator", "steps", 0.7, -1, "s1"), link(2, "env", "pan", "keys", 0.1)};
    CHECK(ok(e.setProjectOffline(p)));
    e.play();
    run(e, 960);
    e.noteOn("keys", 1, 64.0, 1.0);
    run(e, 9600);
    float out[8] = {};
    CHECK_EQ(e.modulatorOutputs("env", out, 8), 1);
    CHECK(std::fabs(out[0] - 0.6f) < 0.02f);  // at its sustain
    CHECK_EQ(e.modulatorOutputs("cv", out, 8), 4);
    CHECK(std::fabs(out[0] - 64.0f / 127.0f) < 1e-3f);  // pitch
    CHECK(out[1] > 0.99f);                              // velocity
    CHECK_EQ(out[2], 1.0f);                             // gate
    CHECK_EQ(e.modulatorOutputs("steps", out, 8), 1);
    CHECK(std::fabs(out[0] - 0.7f) < 1e-3f);  // the macro moved its step
    e.noteOff(1);
    run(e, 48000);
    CHECK_EQ(e.modulatorOutputs("env", out, 8), 1);
    CHECK(out[0] < 0.01f);
    CHECK_EQ(e.modulatorOutputs("cv", out, 8), 4);
    CHECK_EQ(out[2], 0.0f);
    CHECK_EQ(e.modulatorOutputs("nope", out, 8), -1);
}

TEST(a_modulator_keeps_its_phase_across_a_project_update_that_only_changes_values) {
    Engine e(48000.0);
    e.setMasterBypass(true);
    ProjectSpec p = dcProject({modulator("lfo", "org.caw.mod.lfo", {{"rate", 1.0}, {"shape", 2}})},
                              {link(1, "lfo", "volume", "dc", 0.1)});
    e.setProjectOffline(p);
    e.play();
    run(e, 12000);
    float before = 0, after = 0;
    e.modulatorOutputs("lfo", &before, 1);
    p.modulation[0].amount = 0.2;  // a link's value: the LFO runs on
    e.setProjectOffline(p);
    run(e, 64);
    e.modulatorOutputs("lfo", &after, 1);
    CHECK(before > 0.2f);
    CHECK(std::fabs(after - before) < 0.01f);
}

TEST(a_link_to_a_send_level_moves_the_send) {
    Engine e(48000.0);
    e.setMasterBypass(true);
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("a", Shape::Dc, {{"level", 0.5}})});
    LayerSpec fx;
    fx.id = fx.name = "fx";
    fx.folder = true;
    fx.volume = 1.0;
    p.layers.push_back(fx);
    p.layers[0].pan = -1.0;  // the track hard left: the right channel is the pre-fader send alone
    SendSpec s;
    s.to = "fx";
    s.pre = true;
    s.level = 1.0;
    p.layers[0].sends = {s};
    p.modulators = {modulator("mac", "org.caw.mod.macros", {{"macro1", 1.0}})};
    p.modulation = {link(1, "mac", "send", "a", -1.0, 0)};
    CHECK(ok(e.setProjectOffline(p)));
    e.play();
    std::vector<float> l(4800), r(4800);
    for (int i = 0; i < 4800; i += 64) e.process(l.data() + i, r.data() + i, 64);
    CHECK(std::fabs(r.back()) < 1e-6f);
    CHECK(l.back() > 0.4f);
    e.setModulatorParam("mac", "macro1", 0.0);
    for (int k = 0; k < 2; ++k)
        for (int i = 0; i < 4800; i += 64) e.process(l.data() + i, r.data() + i, 64);
    CHECK(std::fabs(r.back() - 0.5f) < 1e-3f);
}

TEST(the_fader_taper_matches_the_apps) {
    CHECK(std::fabs(faderPosition(1.0) - 0.75) < 1e-12);
    CHECK(std::fabs(faderGain(1.0) - kMaxMixGain) < 1e-9);
    CHECK_EQ(faderGain(0.0), 0.0);
    CHECK(std::fabs(faderGain(faderPosition(0.3)) - 0.3) < 1e-9);
}

TEST(a_users_cpp_modulator_loads_and_moves_a_track) {
#ifdef CAW_TEST_MODULATOR_PATH
    Engine e(48000.0);
    e.setMasterBypass(true);
    // A modulator is a native component like any other: loaded only with an explicit trust choice.
    CHECK(e.loadNativeComponent(CAW_TEST_MODULATOR_PATH, "org.caw.examples.euclid", NativeModuleTrust::Trusted).success);
    ProjectSpec p = dcProject({modulator("euclid", "org.caw.examples.euclid", {{"hits", 16}, {"steps", 16}})},
                              {link(1, "euclid", "volume", "dc", -1.0, -1, "", 0)});
    CHECK(ok(e.setProjectOffline(p)));
    e.play();
    // Every step a hit: the gate is on for each step's first half, so the track is silent then, at full after.
    std::vector<float> out = run(e, 48000);
    float lo = 1e9f, hi = -1e9f;
    for (float x : out) lo = std::min(lo, x), hi = std::max(hi, x);
    CHECK(lo < 1e-4f);
    CHECK(std::fabs(hi - static_cast<float>(0.5 * kCentre)) < 1e-3f);
    float v[2] = {};
    CHECK_EQ(e.modulatorOutputs("euclid", v, 2), 2);
#endif
}
