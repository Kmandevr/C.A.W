// Native components on tracks and the master: stereo kept, parameters set and changed, chains kept or rebuilt.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "caw.h"
#include "engine.h"
#include "json.h"
#include "caw/library/stereo.hpp"
#include "native_component_test_path.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

constexpr const char* kGain = "org.caw.tests.native-loader.gain";
constexpr const char* kDouble = "org.caw.tests.native-loader";
const double kCentre = std::cos(3.14159265358979323846 / 4.0);  // the pan law at centre

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

// One track playing a constant 0.5 through `components`, volume 1, centred, master bypassed.
ProjectSpec constantTrack(std::vector<ComponentSpec> components) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.modules.push_back({"dc", "---\nmode: float\n---\n0.5", {}});
    LayerSpec l;
    l.id = "t";
    l.name = "t";
    l.chain = {"dc"};
    l.volume = 1.0;
    l.components = std::move(components);
    p.layers.push_back(l);
    return p;
}

bool loadFixture(Engine& e, const char* id) {
    const char* path = caw::test::nativeComponentPath();
    return path && e.loadNativeComponent(path, id, NativeModuleTrust::Trusted).success;
}

// The last left and right samples after `frames` more frames.
void runLast(Engine& e, int frames, float& left, float& right) {
    std::vector<float> l(64), r(64);
    for (int done = 0; done < frames; done += 64) e.process(l.data(), r.data(), 64);
    left = l.back();
    right = r.back();
}

}  // namespace

TEST(project_json_reads_track_and_master_components_with_parameters) {
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,
        "master_components":["org.a",{"id":"org.b","params":{"mix":0.25}}],
        "layers":[{"id":"t","chain":["x"],"components":[{"id":"org.c","params":{"left":2,"right":0.5}}]}]})",
                       p, error));
    CHECK_EQ(p.masterComponents.size(), 2u);
    CHECK_EQ(p.masterComponents[0].id, std::string("org.a"));
    CHECK(p.masterComponents[0].params.empty());
    CHECK_EQ(p.masterComponents[1].params.size(), 1u);
    CHECK_EQ(p.masterComponents[1].params[0].first, std::string("mix"));
    CHECK_EQ(p.layers.size(), 1u);
    CHECK_EQ(p.layers[0].components.size(), 1u);
    CHECK_EQ(p.layers[0].components[0].id, std::string("org.c"));
    CHECK_EQ(p.layers[0].components[0].params.size(), 2u);

    ProjectSpec bad;
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","components":[{"id":"org.c","params":{"x":"loud"}}]}]})",
                        bad, error));
    CHECK(error.find("finite number") != std::string::npos);
    CHECK(!parseProject(R"({"caw_project":1,"master_components":[{"params":{}}]})", bad, error));
    CHECK(error.find("needs an id") != std::string::npos);
}

TEST(a_track_insert_keeps_its_left_and_right_apart_through_volume_and_pan) {
    Engine e(48000);
    CHECK(loadFixture(e, kGain));
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(constantTrack({{kGain, {{"left", 2.0}, {"right", 0.5}}}}))));
    e.play();
    float l = 0, r = 0;
    runLast(e, 4096, l, r);
    CHECK_NEAR(l, 0.5 * 2.0 * kCentre, 1e-5);
    CHECK_NEAR(r, 0.5 * 0.5 * kCentre, 1e-5);
    LayerMeter meter;
    CHECK(e.layerMeter(0, meter) && meter.active);
    CHECK_NEAR(meter.peak, 0.5 * 2.0 * kCentre, 1e-4);  // the louder side
}

TEST(a_track_without_inserts_pans_its_mono_signal_as_before) {
    Engine plain(48000);
    plain.setMasterBypass(true);
    CHECK(ok(plain.setProject(constantTrack({}))));
    plain.play();
    float l = 0, r = 0;
    runLast(plain, 4096, l, r);
    CHECK_EQ(l, static_cast<float>(0.5 * kCentre));
    CHECK_EQ(l, r);
}

TEST(component_parameters_change_while_playing_and_through_project_updates) {
    Engine e(48000);
    CHECK(loadFixture(e, kGain));
    e.setMasterBypass(true);
    ProjectSpec p = constantTrack({{kGain, {}}});  // defaults: both gains 1
    CHECK(ok(e.setProject(p)));
    e.play();
    float l = 0, r = 0;
    runLast(e, 4096, l, r);
    CHECK_NEAR(l, 0.5 * kCentre, 1e-5);
    CHECK_NEAR(r, 0.5 * kCentre, 1e-5);

    CHECK(e.setComponentParam("t", 0, "right", 0.0));
    CHECK(e.setComponentParam("t", 0, "left", 3.0));  // ramps over 8 frames, inside one block
    runLast(e, 128, l, r);
    CHECK_NEAR(l, 1.5 * kCentre, 1e-5);
    CHECK_EQ(r, 0.0f);
    CHECK(e.setComponentParam("t", 0, "left", 99.0));  // constrained to the range (0..4)
    runLast(e, 128, l, r);
    CHECK_NEAR(l, 2.0 * kCentre, 1e-5);

    CHECK(!e.setComponentParam("t", 0, "nope", 1.0));
    CHECK(!e.setComponentParam("t", 1, "left", 1.0));
    CHECK(!e.setComponentParam("missing", 0, "left", 1.0));
    CHECK(!e.setComponentParam("t", 0, "left", std::nan("")));

    // An update with the same components keeps the chain and sets the values it names.
    p.layers[0].components[0].params = {{"right", 1.0}};
    CHECK(ok(e.setProject(p)));
    runLast(e, 128, l, r);
    CHECK_NEAR(r, 0.5 * kCentre, 1e-5);
    // Left goes back to its default: the update didn't name it, and a fresh render (an export) of
    // this project would play the default too. The app writes live values into the project.
    CHECK_NEAR(l, 0.5 * kCentre, 1e-5);
}

TEST(a_folder_with_components_warns_that_they_are_not_played) {
    Engine e(48000);
    CHECK(loadFixture(e, kGain));
    ProjectSpec p = constantTrack({});
    LayerSpec folder;
    folder.id = "f";
    folder.name = "f";
    folder.folder = true;
    folder.components = {{kGain, {}}};
    p.layers.push_back(folder);
    const std::string result = e.setProject(p);
    CHECK(result.find("folder buses take no native components") != std::string::npos);
}

TEST(a_project_with_too_many_components_is_refused) {
    Engine e(48000);
    CHECK(loadFixture(e, kGain));
    std::vector<ComponentSpec> many(257, ComponentSpec{kGain, {}});
    ProjectSpec p = constantTrack({});
    p.masterComponents = many;
    const std::string result = e.setProject(p);
    CHECK(result.find("at most 256") != std::string::npos);
}

TEST(changing_a_tracks_components_rebuilds_its_chain_and_removing_them_frees_the_library) {
    Engine e(48000);
    CHECK(loadFixture(e, kGain));
    CHECK(loadFixture(e, kDouble));
    e.setMasterBypass(true);
    ProjectSpec p = constantTrack({{kGain, {{"right", 0.0}}}});
    CHECK(ok(e.setProject(p)));
    e.play();
    float l = 0, r = 0;
    runLast(e, 2048, l, r);
    CHECK_EQ(r, 0.0f);
    p.layers[0].components = {{kDouble, {}}, {kGain, {{"left", 0.5}}}};  // doubled, then left halved
    CHECK(ok(e.setProject(p)));
    runLast(e, 2048, l, r);
    CHECK_NEAR(l, 0.5 * kCentre, 1e-5);
    CHECK_NEAR(r, 1.0 * kCentre, 1e-5);
    CHECK(!e.unloadNativeComponent(kDouble));  // the playing chain keeps its library loaded
    p.layers[0].components.clear();
    CHECK(ok(e.setProject(p)));
    runLast(e, 2048, l, r);
    CHECK_EQ(l, r);
    CHECK(e.unloadNativeComponent(kDouble));
    CHECK(e.unloadNativeComponent(kGain));
}

TEST(a_removed_track_frees_its_inserts) {
    Engine e(48000);
    CHECK(loadFixture(e, kGain));
    ProjectSpec p = constantTrack({{kGain, {}}});
    CHECK(ok(e.setProject(p)));
    e.play();
    float l = 0, r = 0;
    runLast(e, 1024, l, r);
    p.layers.clear();
    CHECK(ok(e.setProject(p)));
    runLast(e, 4096, l, r);  // the layer fades out and its slot (with the inserts) is retired
    e.setProject(p);         // drains what the audio thread retired
    CHECK(e.unloadNativeComponent(kGain));
}

TEST(a_component_that_cannot_run_refuses_the_whole_update) {
    Engine e(48000);
    CHECK(loadFixture(e, kGain));
    const std::string missing = e.setProject(constantTrack({{"org.caw.tests.not-loaded", {}}}));
    CHECK(missing.find("\"ok\":false") != std::string::npos);
    CHECK(missing.find("layer 't'") != std::string::npos);
    CHECK(missing.find("not loaded") != std::string::npos);
    const std::string badParam = e.setProject(constantTrack({{kGain, {{"volume", 1.0}}}}));
    CHECK(badParam.find("\"ok\":false") != std::string::npos);
    CHECK(badParam.find("no parameter 'volume'") != std::string::npos);
    ProjectSpec master = constantTrack({});
    master.masterComponents = {{"org.caw.tests.not-loaded", {}}};
    const std::string masterMissing = e.setProject(master);
    CHECK(masterMissing.find("\"ok\":false") != std::string::npos);
    CHECK(masterMissing.find("master:") != std::string::npos);
}

TEST(master_components_take_parameters_and_live_changes) {
    Engine e(48000);
    CHECK(loadFixture(e, kGain));
    e.setMasterBypass(true);
    ProjectSpec p = constantTrack({});
    p.masterComponents = {{kGain, {{"left", 0.0}}}};
    CHECK(ok(e.setProject(p)));
    e.play();
    float l = 0, r = 0;
    runLast(e, 4096, l, r);
    CHECK_EQ(l, 0.0f);
    CHECK(r > 0.3f);
    CHECK(e.setComponentParam("", 0, "left", 1.0));
    runLast(e, 256, l, r);
    CHECK(l > 0.3f);
    CHECK_NEAR(l, r, 1e-6);
}

TEST(c_api_sets_a_component_parameter) {
    const char* path = caw::test::nativeComponentPath();
    CHECK(path != nullptr);
    if (!path) return;
    CawEngine* engine = caw_engine_create(48000);
    CHECK(engine != nullptr);
    if (!engine) return;
    char* loaded = caw_engine_load_component(engine, path, kGain, CAW_NATIVE_TRUST_TRUSTED);
    caw_free(loaded);
    char* result = caw_engine_set_project(engine,
        R"({"caw_project":1,"bpm":120,"modules":[{"id":"dc","source":"---\nmode: float\n---\n0.5"}],
            "layers":[{"id":"t","chain":["dc"],"components":[{"id":"org.caw.tests.native-loader.gain","params":{"left":2}}]}]})");
    CHECK(result && std::string(result).find("\"ok\":true") != std::string::npos);
    caw_free(result);
    CHECK_EQ(caw_engine_set_component_param(engine, "t", 0, "right", 0.5), 1);
    CHECK_EQ(caw_engine_set_component_param(engine, nullptr, 0, "right", 0.5), 0);  // no master chain
    CHECK_EQ(caw_engine_set_component_param(engine, "t", 0, nullptr, 0.5), 0);
    caw_engine_destroy(engine);
}

TEST(a_bypassed_component_crossfades_to_its_input_and_back) {
    Engine e(48000);
    CHECK(loadFixture(e, kGain));
    e.setMasterBypass(true);
    ProjectSpec p = constantTrack({{kGain, {{"left", 2.0}}}});
    CHECK(ok(e.setProject(p)));
    e.play();
    float l = 0, r = 0;
    runLast(e, 2048, l, r);
    CHECK_NEAR(l, 1.0 * kCentre, 1e-5);
    CHECK(e.setComponentBypass("t", 0, true));
    std::vector<float> left(64), right(64);
    e.process(left.data(), right.data(), 64);
    CHECK(left[63] < 1.0f * kCentre && left[63] > 0.5f * kCentre);  // mid-crossfade: no jump
    runLast(e, 1024, l, r);
    CHECK_NEAR(l, 0.5 * kCentre, 1e-5);  // the input, untouched
    CHECK(!e.setComponentBypass("t", 3, true));
    // The project can say it too, and an export of it starts bypassed.
    p.layers[0].components[0].bypass = true;
    CHECK(ok(e.setProject(p)));
    CHECK(e.setComponentBypass("t", 0, false));
    runLast(e, 1024, l, r);
    CHECK_NEAR(l, 1.0 * kCentre, 1e-5);
}

TEST(component_state_is_saved_and_restored_through_the_project) {
    Engine e(48000);
    CHECK(loadFixture(e, kGain));
    ProjectSpec p = constantTrack({{kGain, {}}});
    CHECK(ok(e.setProject(p)));
    e.play();
    float l = 0, r = 0;
    runLast(e, 64 * 10, l, r);
    const std::string states = e.componentStatesJson("t");
    CHECK(states.find("\"ok\":true") != std::string::npos);
    CHECK(states.find("\"version\":7") != std::string::npos);
    CHECK(e.componentStatesJson("missing").find("\"ok\":false") != std::string::npos);
    // A fresh Engine (an export, a reload) restores what was saved: 10 blocks, as 8 little-endian bytes.
    ProjectSpec restored = p;
    std::string json = R"({"caw_project":1,"layers":[{"id":"t","chain":["dc"],"components":[)"
                       R"({"id":"org.caw.tests.native-loader.gain","state":"CgAAAAAAAAA=","state_version":7}]}]})";
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(json, parsed, error));
    CHECK(parsed.layers[0].components[0].hasState);
    CHECK_EQ(parsed.layers[0].components[0].state.size(), 8u);
    CHECK_EQ(static_cast<int>(parsed.layers[0].components[0].state[0]), 10);
    restored.layers[0].components = parsed.layers[0].components;
    Engine fresh(48000);
    CHECK(loadFixture(fresh, kGain));
    CHECK(ok(fresh.setProject(restored)));
    CHECK(fresh.componentStatesJson("t").find("\"state\":\"CgAAAAAAAAA=\"") != std::string::npos);
    // A state the component refuses refuses the update.
    restored.layers[0].components[0].stateVersion = 3;
    Engine other(48000);
    CHECK(loadFixture(other, kGain));
    CHECK(other.setProject(restored).find("refused its saved state") != std::string::npos);
}

TEST(an_automation_lane_drives_a_component_parameter_until_a_knob_moves_it) {
    Engine e(48000);
    CHECK(loadFixture(e, kGain));
    e.setMasterBypass(true);
    ProjectSpec p = constantTrack({{kGain, {}}});
    ProjectAutomationLaneSpec lane;
    lane.targetType = "component";
    lane.moduleId = "t";
    lane.component = 0;
    lane.target = "right";
    lane.points = {{0, 0.0}, {16, 2.0}};  // 0 to 2 over the bar
    p.automation.push_back(lane);
    CHECK(ok(e.setProject(p)));
    e.play();
    float l = 0, r = 0;
    runLast(e, 64 * 4, l, r);  // the bar's start: right near 0
    CHECK(r < 0.05f);
    runLast(e, 48000 - 64 * 4, l, r);  // half a bar at 120 bpm (96000 samples per bar at 48 kHz)
    CHECK_NEAR(r, 0.5 * 1.0 * kCentre, 0.02);
    CHECK(e.setComponentParam("t", 0, "right", 0.0));  // a touch: overrides the lane until the next Play
    runLast(e, 2048, l, r);
    CHECK_EQ(r, 0.0f);
    // The lane changes while the chain plays on (it is kept: same components).
    p.automation[0].points = {{0, 1.0}};
    CHECK(ok(e.setProject(p)));
    e.stop();
    e.play();  // a new Play ends the touch
    runLast(e, 1024, l, r);
    CHECK_NEAR(r, 0.5 * kCentre, 1e-4);
}

TEST(after_stop_an_effect_with_a_tail_rings_out_then_goes_quiet) {
    constexpr const char* kEcho = "org.caw.tests.native-loader.echo";
    Engine e(48000);
    CHECK(loadFixture(e, kEcho));
    e.setMasterBypass(true);
    ProjectSpec p = constantTrack({{kEcho, {}}});
    CHECK(ok(e.setProject(p)));
    e.play();
    float l = 0, r = 0;
    runLast(e, 9600, l, r);
    CHECK(l > 0.5f);  // the echo builds on the constant input
    e.stop();
    runLast(e, 1024, l, r);  // past the 10 ms stop fade: the echo rings on, from silence in
    std::vector<float> left(64), right(64);
    float peak = 0;
    for (int k = 0; k < 20; ++k) {
        e.process(left.data(), right.data(), 64);
        for (float v : left) peak = std::max(peak, std::fabs(v));
    }
    CHECK(peak > 0.01f);
    runLast(e, 48000, l, r);  // halving every 5 ms: long since below -80 dB, and the tail has ended
    CHECK_EQ(l, 0.0f);
    CHECK_EQ(r, 0.0f);
}

TEST(an_effect_without_a_tail_stops_with_the_transport) {
    Engine e(48000);
    CHECK(loadFixture(e, kGain));  // declares no tail
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(constantTrack({{kGain, {}}}))));
    e.play();
    float l = 0, r = 0;
    runLast(e, 4096, l, r);
    e.stop();
    runLast(e, 2048, l, r);
    CHECK_EQ(l, 0.0f);
}

TEST(tracks_stay_in_time_with_a_track_whose_effect_adds_latency) {
    constexpr const char* kLate = "org.caw.tests.native-loader.late";
    Engine e(48000);
    CHECK(loadFixture(e, kLate));
    e.setMasterBypass(true);
    ProjectSpec p = constantTrack({});  // track "t": no effects, hard left
    p.layers[0].pan = -1.0;
    LayerSpec late = p.layers[0];  // track "u": the 100-frame effect, hard right
    late.id = "u";
    late.name = "u";
    late.pan = 1.0;
    late.components = {{kLate, {}}};
    p.layers.push_back(late);
    CHECK(ok(e.setProject(p)));
    e.play();
    std::vector<float> l(256), r(256);
    e.process(l.data(), r.data(), 64);
    e.process(l.data() + 64, r.data() + 64, 64);
    // Both start together, 100 frames in: the plain track is delayed to match the late one.
    CHECK_EQ(l[99], 0.0f);
    CHECK_EQ(r[99], 0.0f);
    CHECK(l[100] > 0.4f);
    CHECK(r[100] > 0.4f);
    // Without the late effect, nothing is delayed.
    p.layers[1].components.clear();
    CHECK(ok(e.setProject(p)));
    e.stop();
    std::vector<float> scratch(64);
    for (int k = 0; k < 20; ++k) e.process(scratch.data(), scratch.data(), 64);
    e.play();
    e.process(l.data(), r.data(), 64);
    CHECK(l[0] > 0.4f);
    CHECK(r[0] > 0.4f);
}

TEST(a_rebuilt_component_takes_over_while_playing_with_its_values_and_state) {
    const char* path = caw::test::nativeComponentPath();
    CHECK(path != nullptr);
    if (!path) return;
    // The rebuild is a new file, as a real build is.
    const std::string rebuild = std::string(path) + ".rebuild-test";
    {
        std::FILE* in = std::fopen(path, "rb");
        std::FILE* out = std::fopen(rebuild.c_str(), "wb");
        CHECK(in && out);
        if (!in || !out) return;
        char buffer[65536];
        size_t n;
        while ((n = std::fread(buffer, 1, sizeof buffer, in)) > 0) std::fwrite(buffer, 1, n, out);
        std::fclose(in);
        std::fclose(out);
    }
    Engine e(48000);
    CHECK(loadFixture(e, kGain));
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(constantTrack({{kGain, {}}}))));
    e.play();
    float l = 0, r = 0;
    runLast(e, 64 * 50, l, r);
    CHECK(e.setComponentParam("t", 0, "left", 3.0));  // a live value the project doesn't know yet
    runLast(e, 128, l, r);
    const ModuleLoadResult reloaded = e.reloadNativeComponent(rebuild, kGain, NativeModuleTrust::Trusted);
    CHECK(reloaded.success);
    runLast(e, 4096, l, r);  // past the 20 ms crossfade
    CHECK_NEAR(l, 1.5 * kCentre, 1e-5);  // the value carried over
    // The state carried over too: the block count goes on from where the old build was.
    const std::string states = e.componentStatesJson("t");
    std::vector<uint8_t> bytes;
    const size_t at = states.find("\"state\":\"");
    CHECK(at != std::string::npos);
    CHECK(base64Decode(states.substr(at + 9, 12), bytes));
    uint64_t blocks = 0;
    std::memcpy(&blocks, bytes.data(), 8);
    CHECK(blocks > 100);
    // A rebuild for a component that isn't loaded is an ordinary load error.
    CHECK(!e.reloadNativeComponent(rebuild, "org.caw.tests.nothing", NativeModuleTrust::Trusted).success);
    std::remove(rebuild.c_str());
}

TEST(a_latency_delay_starts_each_play_from_silence_and_a_bypassed_effect_adds_none) {
    constexpr const char* kLate = "org.caw.tests.native-loader.late";
    Engine e(48000);
    CHECK(loadFixture(e, kLate));
    e.setMasterBypass(true);
    ProjectSpec p = constantTrack({});
    p.layers[0].pan = -1.0;
    LayerSpec late = p.layers[0];
    late.id = "u";
    late.name = "u";
    late.pan = 1.0;
    late.components = {{kLate, {}}};
    p.layers.push_back(late);
    CHECK(ok(e.setProject(p)));
    e.play();
    float l = 0, r = 0;
    runLast(e, 4096, l, r);
    e.stop();
    runLast(e, 2048, l, r);
    e.play();
    std::vector<float> left(64), right(64);
    e.process(left.data(), right.data(), 64);
    // The plain track's delay doesn't replay the song's last frames: silence until its 100 frames have passed.
    CHECK(std::fabs(left[0]) < 1e-6f);  // (the hard-right track leaks ~1e-16 through the pan law)
    CHECK(std::fabs(left[63]) < 1e-6f);
    // Bypassing the late effect removes its latency: the plain track is no longer delayed.
    CHECK(e.setComponentBypass("u", 0, true));
    e.stop();
    runLast(e, 2048, l, r);
    e.play();
    e.process(left.data(), right.data(), 64);
    CHECK(left[0] > 0.4f);
}

TEST(a_tail_still_sounding_at_its_cap_fades_out_instead_of_stopping_dead) {
    constexpr const char* kDrone = "org.caw.tests.native-loader.drone";
    Engine e(48000);
    CHECK(loadFixture(e, kDrone));
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(constantTrack({{kDrone, {}}}))));
    e.play();
    float l = 0, r = 0;
    runLast(e, 4096, l, r);
    e.stop();
    std::vector<float> out;
    std::vector<float> left(64), right(64);
    for (int k = 0; k < 200; ++k) {  // about 0.27 s: the stop fade, the 0.1 s tail, its fade, then silence
        e.process(left.data(), right.data(), 64);
        out.insert(out.end(), left.begin(), left.end());
    }
    // It rang on after the stop fade, and ended in silence.
    size_t last = 0;
    for (size_t i = 0; i < out.size(); ++i)
        if (out[i] != 0.0f) last = i;
    CHECK(last > 4800);
    CHECK_EQ(out.back(), 0.0f);
    // No step at the end: the last loud samples ramp down.
    float biggest = 0;
    for (size_t i = last > 2000 ? last - 2000 : 1; i <= last + 1 && i < out.size(); ++i)
        biggest = std::max(biggest, std::fabs(out[i] - out[i - 1]));
    CHECK(biggest < 0.01f);
}

TEST(the_built_in_balance_and_width_shape_a_tracks_stereo_without_a_trust_choice) {
    constexpr const char* kEcho = "org.caw.tests.native-loader.gain";
    Engine e(48000);
    CHECK(loadFixture(e, kEcho));
    e.setMasterBypass(true);
    // gain makes left and right differ (2 and 0.5); width 0 sums them to mono, balance then moves them.
    ProjectSpec p = constantTrack({{kGain, {{"left", 2.0}, {"right", 0.5}}}, {"org.caw.stereo.width", {{"width", 0.0}}}});
    CHECK(ok(e.setProject(p)));
    e.play();
    float l = 0, r = 0;
    runLast(e, 4096, l, r);
    CHECK_NEAR(l, r, 1e-6);  // width 0: mono
    CHECK_NEAR(l, 0.5 * 1.25 * kCentre, 1e-5);  // the mid of 1.0 and 0.25
    p.layers[0].components[1].params = {{"width", 2.0}};  // twice the side
    CHECK(ok(e.setProject(p)));
    runLast(e, 4096, l, r);
    CHECK_NEAR(l, (0.625 + 2 * 0.375) * kCentre, 1e-5);
    CHECK_NEAR(r, (0.625 - 2 * 0.375) * kCentre, 1e-5);
    p.layers[0].components = {{"org.caw.stereo.balance", {{"pan", -0.5}}}};  // the right side halves
    CHECK(ok(e.setProject(p)));
    runLast(e, 4096, l, r);
    CHECK_NEAR(l, 0.5 * kCentre, 1e-5);
    CHECK_NEAR(r, 0.25 * kCentre, 1e-5);
    CHECK(!e.unloadNativeComponent("org.caw.stereo.balance"));  // part of the engine
}

TEST(width_keeps_a_mono_signal_as_it_is_at_every_setting) {
    for (double width : {0.0, 0.5, 1.0, 2.0}) {
        double l = 0.3, r = 0.3;
        lib::applyWidth(width, l, r);
        CHECK_EQ(l, 0.3);
        CHECK_EQ(r, 0.3);
    }
    const lib::PanGains centre = lib::balanceGains(0.0), hardLeft = lib::balanceGains(-1.0), beyond = lib::balanceGains(7.0);
    CHECK_EQ(centre.left, 1.0);
    CHECK_EQ(centre.right, 1.0);
    CHECK_EQ(hardLeft.right, 0.0);
    CHECK_EQ(beyond.left, 0.0);  // out of range clamps to hard right
    CHECK_EQ(beyond.right, 1.0);
}
