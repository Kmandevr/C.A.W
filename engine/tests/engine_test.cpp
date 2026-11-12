// Mixer tests: block-size independence, per-layer loop lengths, hot swap, broken code, mute/solo, overload, stop.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "caw.h"
#include "detmath.h"
#include "engine.h"
#include "native_component_test_path.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

namespace {

using cawtest::Shape;

// A track's test signal (test_signal.h): its shape and values.
struct Signal {
    Shape shape;
    cawtest::Params params;
};
Signal dc(double level) { return {Shape::Dc, {{"level", level}}}; }
Signal sine(double hz, double level = 1.0) { return {Shape::Sine, {{"freq", hz}, {"level", level}}}; }

// One track per signal (l0, l1, ...), volume 1 and centred, in a project with master gain 1.
ProjectSpec project(std::vector<Signal> signals, int bars = 1, double bpm = 120) {
    std::vector<LayerSpec> layers;
    for (size_t i = 0; i < signals.size(); ++i)
        layers.push_back(cawtest::testSignalLayer("l" + std::to_string(i), signals[i].shape, signals[i].params));
    return cawtest::testSignalProject(std::move(layers), bpm, bars);
}

// A one-bar project whose one track (l0) holds a note through the loop on the test signal (Notes mode), so a Stop
// ends it: a free-running signal ignores notes and rings on after a Stop like any instrument still sounding.
ProjectSpec heldProject(Signal s) {
    ProjectSpec p = project({});
    p.modules.push_back({"hold", "---\nkind: pattern\nlength: 16\n---\n0 C4 16 1\n"});
    p.layers.push_back(cawtest::testSignalNotesLayer("l0", s.shape, "hold", s.params));
    return p;
}

std::vector<float> run(Engine& e, int64_t frames, int block = 64, std::vector<float>* right = nullptr) {
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; i += block) {
        const int n = static_cast<int>(std::min<int64_t>(block, frames - i));
        e.process(l.data() + i, r.data() + i, n);
    }
    if (right) *right = r;
    return l;
}

float maxStep(const std::vector<float>& v, size_t from, size_t to) {
    float m = 0;
    for (size_t i = from + 1; i < to && i < v.size(); ++i) m = std::max(m, std::fabs(v[i] - v[i - 1]));
    return m;
}

}  // namespace

TEST(engine_runs_trusted_native_stereo_master_effect_before_the_safety_limiter) {
    constexpr const char* componentId = "org.caw.tests.native-loader";
    const char* path = caw::test::nativeComponentPath();
    CHECK(path != nullptr);
    CHECK(path && path[0] != 0);
    if (!path) return;

    Engine e(48000);
    const ModuleLoadResult loaded = e.loadNativeComponent(path, componentId, NativeModuleTrust::Trusted);
    CHECK(loaded.success);
    if (!loaded.success) return;

    ProjectSpec p = project({sine(220, 0.8)});
    p.masterComponents.push_back({componentId, {}});
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> right;
    const auto left = run(e, 2048, 64, &right);
    // The component doubles the stereo signal; the master safety limiter still runs after it.
    CHECK(std::fabs(left[1145]) > 0.9f);
    CHECK(std::fabs(left[1145]) <= 0.98f);
    CHECK_NEAR(left[1145], right[1145], 1e-5);
    CHECK(!e.unloadNativeComponent(componentId)); // the active master chain keeps its library loaded

    p.masterComponents.clear();
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    run(e, 2048);  // the removed chain crossfades out over 20 ms, then goes back to the control thread
    CHECK(e.unloadNativeComponent(componentId));
}

TEST(meters_read_what_each_track_and_folder_sends_on_after_volume_and_pan) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    LayerSpec folder;
    folder.id = "folder";
    folder.name = "Folder";
    folder.folder = true;
    folder.volume = 0.5;
    p.layers.push_back(folder);
    LayerSpec centre = cawtest::testSignalLayer("centre", Shape::Dc, {{"level", 0.5}});  // each side 0.5 * cos(pi/4)
    centre.parentId = "folder";
    p.layers.push_back(centre);
    LayerSpec left = cawtest::testSignalLayer("left", Shape::Dc, {{"level", 0.5}});  // hard left, half volume: 0.25 left
    left.volume = 0.5;
    left.pan = -1.0;
    p.layers.push_back(left);
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    run(e, 9600);
    LayerMeter lm;
    const double c = 0.5 * std::cos(kPi / 4.0);
    CHECK(e.layerMeter(1, lm) && lm.active);
    CHECK_NEAR(lm.peak, c, 1e-4);
    CHECK(e.layerMeter(2, lm) && lm.active);
    CHECK_NEAR(lm.peak, 0.25, 1e-4);
    CHECK(e.layerMeter(0, lm) && lm.active);  // the folder: its child at half volume, through the folder's pan
    CHECK_NEAR(lm.peak, 0.5 * c, 1e-4);
}

TEST(track_meters_read_each_side_for_stereo_tracks) {
    // Owner, 2026-11-10 (feel pass): stereo meters on tracks. The C API read one peak per track (the louder
    // side); caw_engine_layer_meter_stereo reads left and right, and the mono peak stays their maximum.
    CawEngine* engine = caw_engine_create(48000);
    CHECK(engine != nullptr);
    if (!engine) return;
    char* result = caw_engine_set_project(engine,
        R"({"caw_project":1,"bpm":120,"master":1,
            "layers":[{"id":"l","instrument":{"id":"org.caw.test.osc","params":{"shape":4,"level":0.5}},"volume":0.5,"pan":-1},
                      {"id":"c","instrument":{"id":"org.caw.test.osc","params":{"shape":4,"level":0.5}},"volume":1,"pan":0.5}]})");
    CHECK(result && std::string(result).find("\"ok\":true") != std::string::npos);
    caw_free(result);
    caw_engine_play(engine);
    std::vector<float> l(256), r(256);
    for (int k = 0; k < 40; ++k) caw_engine_process(engine, l.data(), r.data(), 256);
    CawLayerMeter m{};
    float left = -1, right = -1;
    CHECK_EQ(caw_engine_layer_meter_stereo(engine, 0, &m, &left, &right), 1);
    CHECK(m.active == 1);
    CHECK_NEAR(left, 0.25, 1e-4);  // hard left at half volume
    CHECK_EQ(right, 0.0f);
    CHECK_NEAR(m.peak, 0.25, 1e-4);
    CHECK_EQ(caw_engine_layer_meter_stereo(engine, 1, &m, &left, &right), 1);
    const double gl = std::cos((0.5 + 1.0) * kPi / 4.0), gr = std::sin((0.5 + 1.0) * kPi / 4.0);  // constant power
    CHECK_NEAR(left, 0.5 * gl, 1e-4);
    CHECK_NEAR(right, 0.5 * gr, 1e-4);
    CHECK_NEAR(m.peak, 0.5 * gr, 1e-4);
    // Read since the last call: both sides start again from 0, and the mono reading shares them.
    CHECK_EQ(caw_engine_layer_meter(engine, 1, &m), 1);
    CHECK_EQ(m.peak, 0.0f);
    CHECK_EQ(caw_engine_layer_meter_stereo(engine, 5, &m, &left, &right), 0);  // no such layer
    CHECK_EQ(caw_engine_layer_meter_stereo(engine, 0, &m, nullptr, nullptr), 1);  // either side may be left out
    caw_engine_destroy(engine);
}

TEST(all_track_meters_read_in_one_call) {
    // Beta plan B4.8: the app read one C API call per track every poll; caw_engine_layer_meters reads them all at
    // once, the same values caw_engine_layer_meter_stereo gives, and resets them the same way.
    CawEngine* engine = caw_engine_create(48000);
    CHECK(engine != nullptr);
    if (!engine) return;
    char* result = caw_engine_set_project(engine,
        R"({"caw_project":1,"bpm":120,"master":1,
            "layers":[{"id":"l","instrument":{"id":"org.caw.test.osc","params":{"shape":4,"level":0.5}},"volume":0.5,"pan":-1},
                      {"id":"c","instrument":{"id":"org.caw.test.osc","params":{"shape":4,"level":0.5}},"volume":1,"pan":0.5}]})");
    CHECK(result && std::string(result).find("\"ok\":true") != std::string::npos);
    caw_free(result);
    caw_engine_play(engine);
    std::vector<float> l(256), r(256);
    for (int k = 0; k < 40; ++k) caw_engine_process(engine, l.data(), r.data(), 256);
    CHECK_EQ(caw_engine_layer_meters(engine, nullptr, 0), 2);  // the count alone, nothing read
    CawLayerMeterStereo m[3] = {};
    m[2].peak = -1;
    CHECK_EQ(caw_engine_layer_meters(engine, m, 3), 2);
    CHECK(m[0].active == 1 && m[1].active == 1);
    CHECK_NEAR(m[0].peak_l, 0.25, 1e-4);
    CHECK_EQ(m[0].peak_r, 0.0f);
    CHECK_NEAR(m[0].peak, 0.25, 1e-4);
    const double gr = std::sin((0.5 + 1.0) * kPi / 4.0);
    CHECK_NEAR(m[1].peak_r, 0.5 * gr, 1e-4);
    CHECK_NEAR(m[1].peak, 0.5 * gr, 1e-4);
    CHECK_EQ(m[2].peak, -1.0f);  // past the layer count: untouched
    // Read since the last call, as the one-track read is.
    CawLayerMeter one{};
    CHECK_EQ(caw_engine_layer_meter(engine, 1, &one), 1);
    CHECK_EQ(one.peak, 0.0f);
    for (int k = 0; k < 4; ++k) caw_engine_process(engine, l.data(), r.data(), 256);
    CHECK_EQ(caw_engine_layer_meters(engine, m, 1), 2);  // a short array: only the first is read
    CHECK(m[0].peak > 0.2f);
    float left = -1, right = -1;
    CHECK_EQ(caw_engine_layer_meter_stereo(engine, 1, &one, &left, &right), 1);
    CHECK(right > 0.2f);  // the second was not read (nor reset) by the short call
    CHECK_EQ(caw_engine_layer_meters(nullptr, m, 3), 0);
    caw_engine_destroy(engine);
}

TEST(audition_only_uses_the_dedicated_audition_slot) {
    ProjectSpec p = project({});
    p.hasAuditionInstrument = true;
    p.auditionInstrument = cawtest::testSignal(Shape::Dc, {{"level", 0.5}});
    p.auditionOnly = true;

    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const auto left = run(e, 256);
    CHECK_NEAR(left[200], static_cast<float>(0.8 * 0.5 * std::cos(kPi / 4.0)), 1e-5);
}

TEST(audition_plays_a_cpp_instrument_and_its_effects) {
    // The Builder's preview of a C++ instrument: the project JSON's audition names the instrument and effects.
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"bpm":120,"master":1,
        "modules":[{"id":"pat","source":"---\nkind: pattern\n---\n4 C4 4 1\n"}],
        "layers":[{"id":"song","instrument":{"id":"org.caw.test.osc","params":{"shape":4,"level":0.3}}}],
        "audition":{"instrument":{"id":"org.caw.test.osc","params":{"shape":4,"level":0.5}},
                    "components":[{"id":"org.caw.stereo.balance","params":{"pan":1}}]},
        "audition_only":true})", p, error));
    CHECK(error.empty());
    CHECK(p.auditionOnly && p.hasAuditionInstrument);
    CHECK_EQ(p.auditionComponents.size(), 1u);
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(2048), r(2048);
    for (int i = 0; i < 2048; i += 64) e.process(l.data() + i, r.data() + i, 64);
    // Only the preview sounds (the song's layer is silent): DC 0.5, volume 0.8, centred, then balanced right.
    CHECK_NEAR(l[2000], 0.0, 1e-6);
    CHECK_NEAR(r[2000], 0.8 * 0.5 * std::cos(kPi / 4.0), 1e-5);
    float scope[64];
    CHECK_EQ(e.scope(kScopeAudition, scope, 64), 64);
    CHECK(std::fabs(scope[63]) > 0.1f);

    // In Notes mode it plays the audition's pattern: silent until step 4 (24000 frames), then the note.
    p.auditionInstrument.params = {{"shape", 4}, {"level", 0.5}, {"mode", 1}};
    p.auditionComponents.clear();
    p.auditionPattern = "pat";
    Engine notes(48000);
    notes.setMasterBypass(true);
    CHECK(notes.setProject(p).find("\"ok\":true") != std::string::npos);
    notes.play();
    std::vector<float> nl(30000), nr(30000);
    for (int i = 0; i < 30000; i += 64) notes.process(nl.data() + i, nr.data() + i, std::min(64, 30000 - i));
    CHECK_EQ(nl[23000], 0.0f);
    CHECK_NEAR(nl[29000], 0.8 * 0.5 * std::cos(kPi / 4.0), 1e-5);
    // Audition off: the song plays again and the preview's slot falls silent.
    p.auditionOnly = false;
    CHECK(notes.setProject(p).find("\"ok\":true") != std::string::npos);
    for (int i = 0; i < 30000; i += 64) notes.process(nl.data() + i, nr.data() + i, std::min(64, 30000 - i));
    CHECK_NEAR(nl[29999], 0.3 * 0.8 * std::cos(kPi / 4.0), 1e-5);

    // A bad audition instrument refuses the JSON with a message naming it.
    ProjectSpec bad;
    CHECK(!parseProject(R"({"caw_project":1,"audition":{"instrument":3}})", bad, error));
    CHECK(error.find("audition instrument") != std::string::npos);
}

TEST(audition_slot_follows_the_last_layer_slot_and_both_play) {
    Engine e(48000);
    CHECK_EQ(e.layerCapacity(), kInitialLayerCapacity);
    CHECK_EQ(e.auditionSlot(), e.layerCapacity());
    std::vector<Signal> signals;
    for (int i = 0; i < kInitialLayerCapacity; ++i) signals.push_back(dc(i == kInitialLayerCapacity - 1 ? 0.25 : 0));
    ProjectSpec p = project(signals);
    p.hasAuditionInstrument = true;
    p.auditionInstrument = cawtest::testSignal(Shape::Dc, {{"level", 0.5}});
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    auto left = run(e, 2048);
    LayerMeter lm;
    CHECK(e.layerMeter(kInitialLayerCapacity - 1, lm) && lm.active);
    // Only layer 63 sounds; the audition slot is silent outside audition-only mode.
    CHECK_NEAR(left[2000], static_cast<float>(0.25 * std::cos(kPi / 4.0)), 1e-5);
    p.auditionOnly = true;
    e.setProject(p);
    left = run(e, 24000);
    CHECK_NEAR(left[23999], static_cast<float>(0.8 * 0.5 * std::cos(kPi / 4.0)), 1e-5);
    float scope[64];  // the audition's own scope (before pan)
    CHECK_EQ(e.scope(kScopeAudition, scope, 64), 64);
    CHECK_NEAR(scope[63], 0.4f, 1e-4);
}

TEST(folder_bus_routes_children_and_applies_group_gain) {
    ProjectSpec p = project({dc(0.8)});
    LayerSpec folder;
    folder.id = "bus";
    folder.name = "Group";
    folder.folder = true;
    folder.busEnabled = true;
    folder.volume = 0.5;
    p.layers.insert(p.layers.begin(), folder);
    p.layers[1].parentId = "bus";
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    std::vector<float> right;
    const auto left = run(e, 256, 64, &right);
    const float expected = static_cast<float>(0.8 * std::cos(kPi / 4.0) * 0.5);
    CHECK_NEAR(left[200], expected, 1e-5);
    CHECK_NEAR(right[200], expected, 1e-5);
}

TEST(reparenting_track_detaches_it_from_previous_folder_bus) {
    ProjectSpec p = project({dc(0.8)});
    LayerSpec folder;
    folder.id = "bus";
    folder.folder = true;
    folder.busEnabled = true;
    folder.volume = 0.5;
    p.layers.insert(p.layers.begin(), folder);
    p.layers[1].parentId = "bus";

    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const auto grouped = run(e, 256);
    const float groupedLevel = static_cast<float>(0.8 * std::cos(kPi / 4.0) * 0.5);
    CHECK_NEAR(grouped[200], groupedLevel, 1e-5);

    // Moving the track out must remove the old parent bus from its routing.
    p.layers[1].parentId.clear();
    e.setProject(p);
    const auto detached = run(e, 256);
    const float directLevel = static_cast<float>(0.8 * std::cos(kPi / 4.0));
    CHECK_NEAR(detached[200], directLevel, 1e-5);
}

TEST(reparenting_folder_bus_detaches_it_from_old_parent_bus) {
    ProjectSpec p = project({dc(0.8)});
    LayerSpec outer;
    outer.id = "outer"; outer.folder = true; outer.busEnabled = true; outer.volume = 0.5;
    LayerSpec inner;
    inner.id = "inner"; inner.folder = true; inner.busEnabled = true; inner.parentId = "outer"; inner.volume = 0.5;
    p.layers.insert(p.layers.begin(), outer);
    p.layers.insert(p.layers.begin() + 1, inner);
    p.layers[2].parentId = "inner";

    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const auto nested = run(e, 256);
    const float nestedLevel = static_cast<float>(0.8 * std::cos(kPi / 4.0) * 0.25);
    CHECK_NEAR(nested[200], nestedLevel, 1e-5);

    // Detaching the inner bus should preserve its children but remove the outer gain stage.
    p.layers[1].parentId.clear();
    e.setProject(p);
    const auto detached = run(e, 256);
    const float directBusLevel = static_cast<float>(0.8 * std::cos(kPi / 4.0) * 0.5);
    CHECK_NEAR(detached[200], directBusLevel, 1e-5);
}

TEST(organization_only_folder_mute_propagates_to_descendants) {
    ProjectSpec p = project({dc(1)});
    LayerSpec folder;
    folder.id = "group"; folder.folder = true; folder.busEnabled = false; folder.mute = true;
    p.layers.insert(p.layers.begin(), folder);
    p.layers[1].parentId = "group";
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const auto left = run(e, 512);
    CHECK_NEAR(left[256], 0.0, 1e-7);
}

TEST(nested_folder_buses_route_child_audio_once) {
    ProjectSpec p = project({dc(0.8)});
    LayerSpec outer;
    outer.id = "outer"; outer.folder = true; outer.busEnabled = true; outer.volume = 0.5;
    LayerSpec inner;
    inner.id = "inner"; inner.folder = true; inner.busEnabled = true; inner.parentId = "outer"; inner.volume = 0.5;
    p.layers.insert(p.layers.begin(), outer);
    p.layers.insert(p.layers.begin() + 1, inner);
    p.layers[2].parentId = "inner";
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const auto left = run(e, 256);
    CHECK_NEAR(left[200], 0.8 * std::cos(kPi / 4.0) * 0.25, 1e-5);
}

// REAPER nests folders to any depth and "any action taken on a folder will effect its entire contents" (UG 5.13.5,
// p. 102): three levels, with an organization-only folder between two buses, sum once and follow solo and mute.
TEST(three_level_folders_sum_once_and_follow_folder_solo_and_mute) {
    ProjectSpec p = project({dc(0.8), dc(0.3)});
    LayerSpec outer;
    outer.id = "outer"; outer.folder = true; outer.busEnabled = true; outer.volume = 0.5;
    LayerSpec mid;
    mid.id = "mid"; mid.folder = true; mid.busEnabled = false; mid.parentId = "outer";
    LayerSpec inner;
    inner.id = "inner"; inner.folder = true; inner.busEnabled = true; inner.parentId = "mid"; inner.volume = 0.5;
    p.layers.insert(p.layers.begin(), {outer, mid, inner});
    p.layers[3].parentId = "inner";  // l0 plays 0.8 three folders down; l1 plays 0.3 at the top level
    const double c = std::cos(kPi / 4.0);
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    CHECK_NEAR(run(e, 256)[200], 0.8 * c * 0.25 + 0.3 * c, 1e-5);

    // Soloing the top folder solos everything inside it: the top-level track goes quiet.
    p.layers[0].solo = true;
    e.setProject(p);
    CHECK_NEAR(run(e, 4096)[4000], 0.8 * c * 0.25, 1e-5);

    // Soloing the grandchild alone keeps every bus above it open.
    p.layers[0].solo = false;
    p.layers[3].solo = true;
    e.setProject(p);
    CHECK_NEAR(run(e, 4096)[4000], 0.8 * c * 0.25, 1e-5);

    // Muting the organization-only folder in the middle mutes what is under it.
    p.layers[3].solo = false;
    p.layers[1].mute = true;
    e.setProject(p);
    CHECK_NEAR(run(e, 4096)[4000], 0.3 * c, 1e-5);
}

TEST(track_pan_automation_moves_between_stereo_channels) {
    ProjectSpec p = project({dc(1)});
    p.layers[0].automation.push_back({"pan", {{0, -1}, {16, 1}}});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    std::vector<float> right;
    const auto left = run(e, 16 * 6000 + 256, 64, &right);
    CHECK(left[0] > 0.99f);
    CHECK(std::fabs(right[0]) < 1e-6f);
    CHECK_NEAR(left[8 * 6000], right[8 * 6000], 2e-3);
    CHECK(right[16 * 6000 - 1] > 0.99f);
    CHECK(std::fabs(left[16 * 6000 - 1]) < 5e-5f);
}

TEST(track_volume_automation_is_sample_positioned) {
    ProjectSpec p = project({dc(1)});
    p.layers[0].lengthSteps = 8;  // the lane must follow song time, not this shorter track loop
    p.layers[0].automation.push_back({"volume", {{0, 0}, {16, 1}}});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const auto left = run(e, 16 * 6000 + 256);
    const double pan = std::cos(kPi / 4.0);
    CHECK(std::fabs(left[0]) < 1e-4);
    CHECK_NEAR(left[8 * 6000], 0.5 * pan, 2e-3);
    CHECK_NEAR(left[16 * 6000 - 1], pan, 2e-3);
}

TEST(folder_bus_volume_automation_is_sample_positioned) {
    ProjectSpec p = project({dc(0.8)}, 2);
    LayerSpec folder;
    folder.id = "bus";
    folder.folder = true;
    folder.busEnabled = true;
    folder.volume = 1.0;
    folder.automation.push_back({"volume", {{0, 0}, {16, 1}}});
    p.layers.insert(p.layers.begin(), folder);
    p.layers[1].parentId = "bus";

    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const auto left = run(e, 16 * 6000 + 256);
    const double pan = std::cos(kPi / 4.0);
    CHECK(std::fabs(left[0]) < 1e-6);
    CHECK_NEAR(left[8 * 6000], 0.4 * pan, 2e-3);
    CHECK_NEAR(left[16 * 6000], 0.8 * pan, 2e-3);
}

TEST(mute_overrides_volume_automation) {
    ProjectSpec p = project({dc(1)});
    p.layers[0].automation.push_back({"volume", {{0, 1}, {16, 1}}});
    p.layers[0].mute = true;
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const auto left = run(e, 512);
    CHECK_NEAR(left[256], 0.0, 1e-7);
}

TEST(project_parser_reads_folder_and_automation_metadata) {
    const std::string json = R"({"caw_project":1,"layers":[
      {"id":"g","folder":true,"bus":true,"volume":0.5},
      {"id":"t","parent":"g","automation":[{"target":"pan","points":[{"step":0,"value":-1},{"step":16,"value":1}]}]}
    ]})";
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(json, p, error));
    CHECK_EQ(p.layers.size(), size_t{2});
    CHECK(p.layers[0].folder);
    CHECK(p.layers[0].busEnabled);
    CHECK_EQ(p.layers[1].parentId, std::string("g"));
    CHECK_EQ(p.layers[1].automation.size(), size_t{1});
    CHECK_EQ(p.layers[1].automation[0].target, std::string("pan"));
    CHECK_NEAR(p.layers[1].automation[0].points[1].value, 1.0, 1e-9);
    const std::string cycle = R"({"caw_project":1,"layers":[
      {"id":"a","folder":true,"parent":"b"},{"id":"b","folder":true,"parent":"a"}
    ]})";
    ProjectSpec invalid;
    CHECK(!parseProject(cycle, invalid, error));
}

TEST(output_does_not_depend_on_block_size) {
    // Noise free-running, and a saw played by a pattern (notes off the block grid) through a filter.
    ProjectSpec p = project({{Shape::Noise, {{"level", 0.3}}}});
    p.modules.push_back({"pat", "---\nkind: pattern\nlength: 16\n---\n0 A2 1.3 1\n1.7 C3 2.1 0.7\n5 E3 3 0.9\n"});
    p.layers.push_back(cawtest::testSignalNotesLayer("b", Shape::Saw, "pat", {{"level", 0.4}},
                                                     {{"org.caw.filter", {}}}));
    std::vector<std::vector<float>> outs;
    for (int block : {64, 37, 512, 1}) {
        Engine e(48000);
        e.setProject(p);
        e.play();
        outs.push_back(run(e, 50000, block));
    }
    for (size_t i = 1; i < outs.size(); ++i) CHECK(outs[i] == outs[0]);
}

TEST(layers_loop_at_their_own_length) {
    // A 12-step pattern in a 16-step project restarts every 12 steps: its one-step note at 0 sounds again there,
    // and again when the project loop restarts every layer.
    ProjectSpec p = project({});
    p.modules.push_back({"pat", "---\nkind: pattern\nlength: 12\n---\n0 C4 1 1\n"});
    p.layers.push_back(cawtest::testSignalNotesLayer("l0", Shape::Dc, "pat", {{"level", 0.5}}));
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    // 120 BPM at 48 kHz: 6000 samples per 16th, so the layer loop is 72000 and the project loop 96000.
    std::vector<float> out = run(e, 200000);
    const double g = 0.5 * std::cos(kPi / 4.0);
    CHECK_EQ(e.loopLength(), int64_t{96000});
    CHECK_NEAR(out[0], g, 1e-6);
    CHECK_NEAR(out[5999], g, 1e-6);
    CHECK_NEAR(out[6000], 0.0, 1e-7);
    CHECK_NEAR(out[71999], 0.0, 1e-7);
    CHECK_NEAR(out[72000], g, 1e-6);    // layer restarts
    CHECK_NEAR(out[78000], 0.0, 1e-7);
    CHECK_NEAR(out[95999], 0.0, 1e-7);
    CHECK_NEAR(out[96000], g, 1e-6);    // project loop restarts every layer
    CHECK_NEAR(out[168000], g, 1e-6);
}

TEST(a_loop_range_loops_playback_inside_the_song) {
    // 120 BPM at 48 kHz: 6000 samples a step. The range is steps 4 to 8 (24000 to 48000) of a 16-step song.
    ProjectSpec p = project({dc(0.1)});
    p.loopRange = true;
    p.loopStartSteps = 4;
    p.loopEndSteps = 8;
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    run(e, 47999);
    CHECK_EQ(e.meters().position, int64_t{47999});
    run(e, 2);
    CHECK_EQ(e.meters().position, int64_t{24001});  // back to the range's start, not the song's
    run(e, 3 * 24000);
    CHECK_EQ(e.meters().position, int64_t{24001});  // and round again, never past its end
    // Played from after the range, the song plays to its end, then goes back to the range.
    e.play(12);
    run(e, 24000 + 10);
    CHECK_EQ(e.meters().position, int64_t{24010});
    // Off: the whole song loops, as projects without a range always have.
    p.loopRange = false;
    e.setProject(p);
    e.play(4);
    run(e, 96000);
    CHECK_EQ(e.meters().position, int64_t{24000});
}

TEST(project_file_loop_range_is_checked_and_reaches_the_song) {
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"loop_bars":1,"loop_range":true,"loop_start_steps":16,"loop_end_steps":40})",
        p, error));
    CHECK(p.loopRange);
    CHECK_EQ(p.loopStartSteps, 16);
    CHECK_EQ(p.loopEndSteps, 40);
    CHECK_EQ(p.loopBars, 3);  // the song reaches the range's end
    CHECK(!parseProject(R"({"caw_project":1,"loop_range":true,"loop_start_steps":8,"loop_end_steps":8})", p, error));
    CHECK(error.find("loop_start_steps") != std::string::npos);
    // Off, the range's numbers are not read: older projects have none.
    CHECK(parseProject(R"({"caw_project":1,"loop_start_steps":8})", p, error));
    CHECK(!p.loopRange);
    CHECK_EQ(p.loopBars, 4);
}

TEST(an_instrument_swap_crossfades_without_a_click) {
    Engine e(48000);
    e.setMasterBypass(true);
    ProjectSpec p = project({sine(220, 0.5)});
    e.setProject(p);
    e.play();
    std::vector<float> before = run(e, 10000);
    // Another instrument (with no notes to play): the sine crossfades out over 20 ms.
    p.layers[0].instrument = {"org.caw.synth.flagship", {}};
    std::string res = e.setProject(p);
    CHECK(res.find("\"ok\":true") != std::string::npos);
    std::vector<float> after = run(e, 10000);
    std::vector<float> all = before;
    all.insert(all.end(), after.begin(), after.end());
    CHECK(maxStep(all, 9990, 10010) < 0.05f);
    CHECK(maxStep(all, 9990, 11000) < 0.05f);
    // After the fade only the new instrument plays: silence.
    CHECK(maxStep(after, 2000, 9000) < 1e-6f);
}

TEST(a_broken_pattern_keeps_the_old_notes) {
    ProjectSpec p = project({});
    p.modules.push_back({"pat", "---\nkind: pattern\nlength: 16\n---\n0 A4 2 1\n4 C5 2 0.5\n"});
    p.layers.push_back(cawtest::testSignalNotesLayer("l0", Shape::Sine, "pat", {{"level", 0.5}}));
    Engine a(48000), b(48000);
    a.setProject(p);
    b.setProject(p);
    a.play();
    b.play();
    std::vector<float> a1 = run(a, 5000), b1 = run(b, 5000);
    ProjectSpec broken = p;
    broken.modules[0].source = "---\nkind: pattern\nlength: 16\n---\n0 A4 2 1\n4 Q9 2 0.5\n";
    std::string res = a.setProject(broken);
    CHECK(res.find("\"ok\":false") != std::string::npos);
    CHECK(res.find("\"line\":6") != std::string::npos);
    std::vector<float> a2 = run(a, 40000), b2 = run(b, 40000);
    CHECK(a1 == b1);
    CHECK(a2 == b2);
}

TEST(mute_and_solo) {
    ProjectSpec p = project({dc(0.25), dc(0.5)});
    Engine e(48000);
    e.setMasterBypass(true);
    p.layers[1].solo = true;
    e.setProject(p);
    e.play();
    const double g = std::cos(kPi / 4.0);
    std::vector<float> out = run(e, 1000);
    CHECK_NEAR(out[999], 0.5 * g, 1e-6);
    e.setLayerMix("l1", 1.0, 0.0, true, false);  // mute b, unsolo
    out = run(e, 5000);
    CHECK_NEAR(out[4999], 0.25 * g, 1e-5);
    e.setLayerMix("l0", 1.0, -1.0, false, false);  // pan a hard left
    std::vector<float> right;
    out = run(e, 5000, 64, &right);
    CHECK_NEAR(out[4999], 0.25, 1e-5);
    CHECK_NEAR(right[4999], 0.0, 1e-5);
}

TEST(track_and_master_faders_reach_plus_12_db) {
    // Owner, 2026-11-10 (feel pass): faders like REAPER's, up to +12 dB (a gain of 3.981) on tracks and the
    // master; the safety limiter stays last. They were clamped at 0 dB (gain 1).
    const double kPlus12 = std::pow(10.0, 12.0 / 20.0);
    ProjectSpec p = project({dc(0.05)});
    p.master = 1.0;
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const double g = std::cos(kPi / 4.0);
    e.setLayerMix("l0", 2.0, 0.0, false, false);
    std::vector<float> out = run(e, 5000);
    CHECK_NEAR(out[4999], 0.1 * g, 1e-5);
    e.setLayerMix("l0", 10.0, 0.0, false, false);  // past +12 dB: held there
    out = run(e, 5000);
    CHECK_NEAR(out[4999], 0.05 * kPlus12 * g, 1e-5);
    e.setLayerMix("l0", 1.0, 0.0, false, false);
    e.setMaster(2.0);
    out = run(e, 5000);
    CHECK_NEAR(out[4999], 0.1 * g, 1e-5);
    e.setMaster(10.0);
    out = run(e, 5000);
    CHECK_NEAR(out[4999], 0.05 * kPlus12 * g, 1e-5);
    // The project's own values too.
    ProjectSpec q;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"master":3,"layers":[{"id":"t","volume":2.5},{"id":"u","volume":9}]})", q, error));
    CHECK_NEAR(q.master, 3.0, 1e-12);
    CHECK_EQ(q.layers.size(), 2u);
    if (q.layers.size() == 2) {
        CHECK_NEAR(q.layers[0].volume, 2.5, 1e-12);
        CHECK_NEAR(q.layers[1].volume, kPlus12, 1e-12);
    }
}

TEST(overload_mutes_the_newest_layer) {
    ProjectSpec p = project({dc(0.25), dc(0.5)});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    run(e, 1000);
    for (int i = 0; i < 40; ++i) e.reportLoad(1.5, 512);
    std::vector<float> out = run(e, 5000);
    const Meters m = e.meters();
    CHECK_EQ(m.overloaded, 1);
    LayerMeter lm;
    CHECK(e.layerMeter(1, lm) && lm.overloaded);
    CHECK(e.layerMeter(0, lm) && !lm.overloaded);
    CHECK_NEAR(out[4999], 0.25 * std::cos(kPi / 4.0), 1e-5);
    e.clearOverload();
    out = run(e, 5000);
    CHECK_EQ(e.meters().overloaded, 0);
    CHECK_NEAR(out[4999], 0.75 * std::cos(kPi / 4.0), 1e-5);
}

TEST(the_test_tone_goes_through_the_safety_limiter) {
    // A song already at the limiter's ceiling: the tone on top must not push the output past it (it used to be
    // added after the limiter and hard-clipped at 1).
    ProjectSpec p = heldProject({Shape::Sine, {}});
    p.master = 3.0;  // +9.5 dB: well into the limiter
    Engine e(48000);
    e.setProject(p);
    e.play();
    run(e, 4800);
    e.testTone(0.5);
    std::vector<float> right;
    const std::vector<float> left = run(e, 9600, 64, &right);
    float peak = 0;
    for (size_t i = 0; i < left.size(); ++i) peak = std::max({peak, std::fabs(left[i]), std::fabs(right[i])});
    CHECK(peak <= 0.9771f);
    CHECK(peak > 0.9f);
    // The tone carries on through the stop's fade and after it, at its own level.
    e.stop();
    const std::vector<float> after = run(e, 4800);
    float tail = 0;
    for (size_t i = 2400; i < after.size(); ++i) tail = std::max(tail, std::fabs(after[i]));
    CHECK(std::fabs(tail - 0.25f) < 0.02f);
}

TEST(overload_shedding_goes_by_time_not_callbacks) {
    // The shedding was tuned at 512-frame callbacks: about 0.21 s over budget sheds a layer, then 1.07 s of rest.
    // Counting callbacks made 16-frame periods shed on a 7 ms hiccup and 8192-frame ones take 3.4 s.
    ProjectSpec p = project({dc(0.25), dc(0.5)});
    auto overloadedAfter = [&](int frames, double seconds) {
        Engine e(48000);
        e.setProject(p);
        e.play();
        run(e, 1000);
        const int calls = static_cast<int>(seconds * 48000 / frames + 0.5);
        for (int i = 0; i < calls; ++i) e.reportLoad(1.5, frames);
        run(e, 64);
        return e.meters().overloaded;
    };
    CHECK_EQ(overloadedAfter(16, 0.0083), 0);  // 25 tiny callbacks: a hiccup
    CHECK_EQ(overloadedAfter(16, 0.1), 0);
    CHECK_EQ(overloadedAfter(16, 0.35), 1);
    CHECK_EQ(overloadedAfter(512, 0.1), 0);
    CHECK_EQ(overloadedAfter(512, 0.35), 1);
    CHECK_EQ(overloadedAfter(8192, 0.35), 1);   // two callbacks, not twenty
    // The meter's average is weighted by time as well: one long callback at 1.5 reads far over budget.
    Engine e(48000);
    e.reportLoad(1.5, 8192);
    CHECK(e.meters().cpu > 1.0f);
    Engine f(48000);
    for (int i = 0; i < 32; ++i) f.reportLoad(1.5, 16);  // 10.7 ms: one 512-frame callback's worth
    CHECK_NEAR(f.meters().cpu, 0.15, 0.01);
    // The cooldown is time too: still overloaded after shedding, the next layer goes about 1.07 s later.
    Engine g(48000);
    g.setProject(p);
    g.play();
    run(g, 1000);
    for (int i = 0; i < 300; ++i) g.reportLoad(1.5, 64);  // 0.4 s: the first layer
    run(g, 64);
    CHECK_EQ(g.meters().overloaded, 1);
    for (int i = 0; i < 600; ++i) g.reportLoad(1.5, 64);  // 0.8 s more: still cooling down
    run(g, 64);
    CHECK_EQ(g.meters().overloaded, 1);
    for (int i = 0; i < 600; ++i) g.reportLoad(1.5, 64);
    run(g, 64);
    CHECK_EQ(g.meters().overloaded, 2);
}

TEST(stop_fades_to_silence_and_layers_can_be_removed) {
    ProjectSpec p = heldProject(dc(0.5));
    Engine e(48000);
    e.setMasterBypass(true);  // the master's DC blocker would ring on after the DC ends
    e.setProject(p);
    e.play();
    run(e, 2000);
    CHECK(e.meters().playing);
    e.stop();
    std::vector<float> out = run(e, 2000);
    CHECK_EQ(out[1999], 0.0f);
    CHECK(!e.meters().playing);
    // Removing every layer frees their slots for new ones.
    e.play();
    ProjectSpec empty = p;
    empty.layers.clear();
    e.setProject(empty);
    run(e, 5000);
    e.meters();
    ProjectSpec many;
    for (int i = 0; i < kInitialLayerCapacity; ++i)
        many.layers.push_back(cawtest::testSignalLayer("x" + std::to_string(i), Shape::Dc, {{"level", 0.001}}));
    e.setProject(many);
    run(e, 100);
    LayerMeter lm;
    CHECK(e.layerMeter(kInitialLayerCapacity - 1, lm) && lm.active);
}

TEST(effects_process_their_layer_only) {
    ProjectSpec p = project({dc(0.3), dc(0.3)});
    p.layers[0].components = {{"org.caw.utility", {{"gain", 20.0 * std::log10(2.0)}}}};
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    std::vector<float> out = run(e, 4000);
    CHECK_NEAR(out[3999], 0.9 * std::cos(kPi / 4.0), 1e-5);
}

TEST(a_track_runs_as_one_graph_node_with_its_inserts) {
    ProjectSpec p = project({dc(0.3)});
    p.layers[0].components = {{"org.caw.utility", {{"gain", 20.0 * std::log10(2.0)}}}, {"org.caw.utility", {}}};
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    std::vector<float> out = run(e, 4000);
    CHECK_NEAR(out[3999], 0.6 * std::cos(kPi / 4.0), 1e-5);
    CHECK_EQ(e.mixGraphNodesRun(), 2u);  // the track node (instrument and inserts) and master; idle slots never run
    CHECK_EQ(e.routingRejections(), 0u);
}

TEST(limiter_keeps_output_below_full_scale) {
    ProjectSpec p = project({{Shape::Saw, {{"freq", 110}}}, {Shape::Square, {{"freq", 170}}}, {Shape::Saw, {{"freq", 33}}}});
    Engine e(48000);
    e.setProject(p);
    e.play();
    std::vector<float> out = run(e, 48000);
    float peak = 0;
    for (float v : out) peak = std::max(peak, std::fabs(v));
    CHECK(peak <= 0.978f);
    CHECK(peak > 0.5f);
}

TEST(a_value_change_keeps_the_instrument_playing) {
    // Only the level changes: the same instrument takes the value and the sine keeps its phase, so the output is
    // exactly the new level times the same running sine, with no restart.
    ProjectSpec p = project({sine(220, 0.5)});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    run(e, 9000);
    p.layers[0].instrument.params = {{"shape", 0}, {"freq", 220}, {"level", 0.25}};
    e.setProject(p);
    std::vector<float> y = run(e, 4000);
    const double g = std::cos(kPi / 4.0);
    for (int i = 2000; i < 4000; i += 37) {
        const double n = 9000.0 + i;
        CHECK_NEAR(y[static_cast<size_t>(i)] / g, 0.25 * detSin(kTwoPi * 220.0 * n / 48000.0), 1e-4);
    }
}

TEST(arrangement_clips_schedule_reusable_patterns_on_the_project_timeline) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.modules.push_back({"phrase",
        "---\nkind: pattern\nlength: 4\n---\n0 A4 2 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
    layer.name = "Track";
    layer.volume = 1.0;
    layer.clips.push_back({"clip-a", "phrase", 2, 8, 0, true});
    p.layers.push_back(layer);

    Engine e(48000);
    e.setMasterBypass(true);
    const std::string result = e.setProject(p);
    CHECK(result.find("\"ok\":true") != std::string::npos);
    e.play();
    const std::vector<float> out = run(e, 70000);
    const double panGain = std::cos(kPi / 4.0);
    CHECK_NEAR(out[1000], 0.0, 1e-7);             // before the clip
    CHECK_NEAR(out[15000], 0.5 * panGain, 1e-5);  // first source pass
    CHECK_NEAR(out[27000], 0.0, 1e-5);            // source note has ended
    CHECK_NEAR(out[39000], 0.5 * panGain, 1e-5);  // clip loops its source
}


TEST(a_muted_arrangement_clip_plays_nothing_and_the_rest_still_play) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.modules.push_back({"phrase", "---\nkind: pattern\nlength: 4\n---\n0 A4 2 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
    layer.volume = 1.0;
    layer.clips.push_back({"heard", "phrase", 0, 4, 0, false});
    layer.clips.push_back({"muted", "phrase", 8, 4, 0, false, true});
    p.layers.push_back(layer);

    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 70000);
    CHECK_NEAR(out[3000], 0.5 * std::cos(kPi / 4.0), 1e-5);  // the first clip's note
    CHECK_NEAR(out[51000], 0.0, 1e-7);                         // the muted clip's note is silent

    // The project file carries it.
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"modules":[{"id":"p","source":"---\nkind: pattern\n---\n"}],
        "layers":[{"id":"t","clips":[{"id":"c","pattern":"p","mute":true},{"id":"d","pattern":"p"}]}]})", parsed, error));
    CHECK(parsed.layers.at(0).clips.at(0).mute);
    CHECK(!parsed.layers.at(0).clips.at(1).mute);
}

TEST(arrangement_clip_source_offset_trims_the_source_and_honors_non_looping) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 2;
    p.master = 1.0;
    p.modules.push_back({"phrase",
        "---\nkind: pattern\nlength: 4\n---\n0 A4 1 1\n2 C4 1 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
    layer.volume = 1.0;
    layer.clips.push_back({"trimmed", "phrase", 4, 2, 2, false});
    p.layers.push_back(layer);

    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("true") != std::string::npos);
    e.play();
    const auto out = run(e, 40000);
    const float expected = static_cast<float>(0.5 * std::cos(kPi / 4.0));
    CHECK_NEAR(out[18000], 0.0, 1e-7);            // before the trimmed clip
    CHECK_NEAR(out[27000], expected, 1e-5);       // source note at offset 2 starts at timeline step 4
    CHECK_NEAR(out[33000], 0.0, 1e-5);            // non-looping clip stops after its one source segment
}

TEST(arrangement_clip_source_offset_preserves_the_tail_of_a_sustained_note) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 2;
    p.master = 1.0;
    p.modules.push_back({"phrase",
        "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
    layer.volume = 1.0;
    layer.clips.push_back({"trimmed-sustain", "phrase", 4, 2, 2, false});
    p.layers.push_back(layer);

    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("true") != std::string::npos);
    e.play();
    const auto out = run(e, 40000);
    const float expected = static_cast<float>(0.5 * std::cos(kPi / 4.0));
    CHECK_NEAR(out[27000], expected, 1e-5); // source note began before the trim, but its tail remains
    CHECK_NEAR(out[39000], 0.0, 1e-5);      // the clip still ends at its arranged boundary
}

TEST(arrangement_clip_source_offset_preserves_remaining_ratchets) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 2;
    p.master = 1.0;
    p.modules.push_back({"phrase",
        "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1 ratchet 4\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Impulse, "", {});
    layer.volume = 1.0;
    layer.clips.push_back({"trimmed-ratchet", "phrase", 4, 2, 2, false});
    p.layers.push_back(layer);

    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("true") != std::string::npos);
    e.play();
    const auto out = run(e, 40000);
    CHECK(out[24000] > 0.5f); // third ratchet begins at the clip start
    CHECK(out[30000] > 0.5f); // fourth ratchet keeps its original spacing
    CHECK_NEAR(out[36000], 0.0, 1e-5); // clip boundary releases the final ratchet
}

TEST(arrangement_clips_can_overlap_on_one_track) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 2;
    p.master = 1.0;
    p.modules.push_back({"phrase", "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.25}});
    layer.volume = 1.0;
    layer.clips.push_back({"looping", "phrase", 0, 8, 0, true});
    layer.clips.push_back({"overlap", "phrase", 4, 4, 0, false});
    p.layers.push_back(layer);

    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("true") != std::string::npos);
    e.play();
    const auto out = run(e, 60000);
    const float oneVoice = static_cast<float>(0.25 * std::cos(kPi / 4.0));
    const float twoVoices = static_cast<float>(0.5 * std::cos(kPi / 4.0));
    CHECK_NEAR(out[18000], oneVoice, 1e-5);
    CHECK_NEAR(out[27000], twoVoices, 1e-5);       // both clips sound from step 4 to step 8
    CHECK_NEAR(out[51000], 0.0, 1e-5);             // both clips have ended
}


// A clip's own loop point (REAPER-like, owner 2026-11-11): the clip repeats its source from the offset every
// loop_steps, exactly as a pattern of that length would loop; 0 (the default) loops at the pattern's length.
TEST(arrangement_clip_loop_steps_repeat_the_source_at_the_clip_loop_point) {
    const auto render = [](const std::string& source, int loopSteps, int offset) {
        ProjectSpec p;
        p.bpm = 120;
        p.loopBars = 2;
        p.master = 1.0;
        p.modules.push_back({"phrase", source});
        LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
        layer.volume = 1.0;
        ClipSpec clip{"c", "phrase", 2, 24, offset, true};
        clip.loopSteps = loopSteps;
        layer.clips.push_back(clip);
        p.layers.push_back(layer);
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
        e.play();
        return run(e, 6000 * 30);
    };
    // An 8-step pattern looped at 4: the note at step 5 never plays, the one at 0 every 4 steps.
    const auto looped = render("---\nkind: pattern\nlength: 8\n---\n0 A4 1 1\n5 C4 2 1\n", 4, 0);
    const auto four = render("---\nkind: pattern\nlength: 4\n---\n0 A4 1 1\n", 0, 0);
    CHECK(looped == four);
    const float on = static_cast<float>(0.5 * std::cos(kPi / 4.0));
    CHECK_NEAR(looped[6000 * 6 + 3000], on, 1e-5);   // step 6: the second pass's note
    CHECK_NEAR(looped[6000 * 7 + 3000], 0.0, 1e-5);  // step 7 (source step 5): cut by the loop point

    // A loop point past the pattern's end plays silence up to it, as a longer pattern would.
    const auto longer = render("---\nkind: pattern\nlength: 4\n---\n0 A4 1 1\n", 6, 0);
    const auto six = render("---\nkind: pattern\nlength: 6\n---\n0 A4 1 1\n", 0, 0);
    CHECK(longer == six);

    // The offset counts inside the clip's loop, as it does inside a pattern.
    CHECK(render("---\nkind: pattern\nlength: 8\n---\n0 A4 1 1\n3 C4 1 1\n6 E4 1 1\n", 4, 3) ==
          render("---\nkind: pattern\nlength: 4\n---\n0 A4 1 1\n3 C4 1 1\n", 0, 3));

    // 0 and the pattern's own length play the same; existing projects (no loop_steps) are unchanged.
    CHECK(render("---\nkind: pattern\nlength: 4\n---\n0 A4 1 1\n", 4, 0) == four);

    // The project file carries it, and refuses what it can't be.
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"modules":[{"id":"p","source":"---\nkind: pattern\n---\n"}],
        "layers":[{"id":"t","clips":[{"id":"c","pattern":"p","loop_steps":12},{"id":"d","pattern":"p"}]}]})", parsed, error));
    CHECK_EQ(parsed.layers.at(0).clips.at(0).loopSteps, 12);
    CHECK_EQ(parsed.layers.at(0).clips.at(1).loopSteps, 0);
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","clips":[{"id":"c","pattern":"p","loop_steps":-1}]}]})",
        parsed, error));
    CHECK(error.find("clip 'c' of layer 't': loop_steps must be") != std::string::npos);
}

TEST(master_gain_updates_without_recompiling_and_ramps_smoothly) {
    ProjectSpec p = project({dc(0.5)});
    p.master = 1.0;
    Engine e(48000);
    e.setMasterBypass(true);
    const std::string projectResult = e.setProject(p);
    CHECK(projectResult.find("\"ok\":true") != std::string::npos);
    e.play();
    run(e, 256);

    e.setMaster(0.0);
    const auto faded = run(e, 512);
    CHECK_NEAR(faded.back(), 0.0, 1e-7);
    CHECK(maxStep(faded, 0, faded.size()) < 0.01f);

    e.setMaster(2.0); // up to +12 dB: louder than before the fade
    const auto restored = run(e, 512);
    CHECK(restored.back() > 0.34f);
}

TEST(project_parser_keeps_arrangements_past_64_bars) {
    // F7.2 (owner, 2026-11-04): nothing is moved or shortened; the old 64-bar song limit is gone.
    const std::string json = R"({"caw_project":1,"beats_per_bar":3,"loop_bars":1000,"layers":[
      {"id":"t","length_steps":200000,
       "clips":[{"id":"c","pattern":"p","start_steps":100000,"length_steps":50000,"source_offset_steps":900}],
       "automation":[{"target":"volume","points":[{"step":250000,"value":0.5}]}]}
    ],"automation":[{"target_type":"global","target":"swing","points":[{"step":300000,"value":1}]}],
    "audition":{"length_steps":400000}})";
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(json, p, error));
    CHECK_EQ(p.layers[0].lengthSteps, 200000);
    CHECK_EQ(p.layers[0].clips[0].startSteps, 100000);
    CHECK_EQ(p.layers[0].clips[0].lengthSteps, 50000);
    CHECK_EQ(p.layers[0].clips[0].sourceOffsetSteps, 900);
    CHECK_NEAR(p.layers[0].automation[0].points[0].step, 250000, 1e-9);
    CHECK_NEAR(p.automation[0].points[0].step, 300000, 1e-9);
    CHECK_EQ(p.auditionSteps, 400000);
    CHECK_EQ(p.loopBars, 25000);  // project automation lengthens the loop to reach its last point (300000 / 12)
}

TEST(project_parser_refuses_arrangement_values_it_cannot_represent) {
    // The step position is a 32-bit int, so a song holds whole bars up to 2^31 - 1 steps.
    const int maxBars3 = 2147483647 / 12;
    const int maxSteps3 = maxBars3 * 12;
    CHECK_EQ(maxLoopBars(3), maxBars3);
    CHECK_EQ(maxArrangementSteps(3), maxSteps3);
    const auto refused = [](const std::string& body, const std::string& message) {
        ProjectSpec p;
        std::string error;
        const bool ok = parseProject(R"({"caw_project":1,"beats_per_bar":3,)" + body + "}", p, error);
        CHECK(!ok);
        CHECK(error.find(message) != std::string::npos);
        if (ok || error.find(message) == std::string::npos) std::printf("    got: %s\n", error.c_str());
    };
    refused(R"("loop_bars":0)", "loop_bars must be a whole number from 1 to");
    refused(R"("loop_bars":)" + std::to_string(maxBars3 + 1), "loop_bars must be a whole number from 1 to");
    refused(R"("loop_bars":2.5)", "loop_bars must be a whole number from 1 to");
    refused(R"("layers":[{"id":"t","length_steps":-1}])", "layer 't': length_steps must be");
    refused(R"("layers":[{"id":"t","clips":[{"id":"c","pattern":"p","start_steps":-1}]}])",
        "clip 'c' of layer 't': start_steps must be");
    refused(R"("layers":[{"id":"t","clips":[{"id":"c","pattern":"p","length_steps":0}]}])",
        "clip 'c' of layer 't': length_steps must be");
    refused(R"("layers":[{"id":"t","clips":[{"id":"c","pattern":"p","start_steps":)" + std::to_string(maxSteps3 - 10) +
        R"(,"length_steps":11}]}])", "clip 'c' of layer 't' ends after step");
    refused(R"("layers":[{"id":"t","clips":[{"id":"c","pattern":"p","source_offset_steps":-3}]}])",
        "clip 'c' of layer 't': source_offset_steps must be");
    refused(R"("layers":[{"id":"t","automation":[{"target":"pan","points":[{"step":-1,"value":0}]}]}])",
        "layer 't': automation point steps must be");
    refused(R"("automation":[{"target_type":"global","target":"g","points":[{"step":)" + std::to_string(maxSteps3 + 1) +
        R"(,"value":0}]}])", "automation point steps must be");
    refused(R"("audition":{"length_steps":-5})", "audition length_steps must be");

    // The largest values are accepted, and the loop reaches the last automation point without overflowing.
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"beats_per_bar":3,"layers":[{"id":"t","clips":[{"id":"c","pattern":"p","start_steps":)" +
        std::to_string(maxSteps3 - 10) + R"(,"length_steps":10}]}],"automation":[{"target_type":"global","target":"g","points":[{"step":)" +
        std::to_string(maxSteps3) + R"(,"value":0}]}]})", p, error));
    CHECK_EQ(p.loopBars, maxBars3);
    CHECK_EQ(p.loopSteps(), maxSteps3);
}

TEST(play_from_a_position_resumes_mid_loop) {
    // As in layers_loop_at_their_own_length: a 12-step pattern (72000 samples) in a 96000-sample project loop, here
    // with a one-step note on every step, each louder than the one before (velocity (k + 1) / 12).
    std::string notes = "---\nkind: pattern\nlength: 12\n---\n";
    for (int k = 0; k < 12; ++k) notes += std::to_string(k) + " C4 1 " + std::to_string((k + 1) / 12.0) + "\n";
    ProjectSpec p = project({});
    p.modules.push_back({"pat", notes});
    p.layers.push_back(cawtest::testSignalNotesLayer("l0", Shape::Dc, "pat", {{"level", 0.5}}));
    const double g = 0.5 * std::cos(kPi / 4.0);
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play(80000.0 / 6000.0);  // step 13.33 (6000 samples a step): 1.33 steps into the layer's second pass
    std::vector<float> out = run(e, 20000);
    // The note under the playhead began before it, so the first heard is the next one, at layer step 2 (4000 on).
    CHECK_NEAR(out[1000], 0.0, 1e-7);
    CHECK_NEAR(out[5000], 3.0 / 12.0 * g, 1e-4);
    CHECK_NEAR(out[15999], 4.0 / 12.0 * g, 1e-4);
    CHECK_NEAR(out[16000], 1.0 / 12.0 * g, 1e-4);  // the project loop wraps as usual
    Meters m = e.meters();
    CHECK_EQ(m.position, int64_t{4000});
    for (double bad : {-5.0, 16.0, 1e30, std::nan(""), static_cast<double>(INFINITY)}) {
        e.play(bad);  // outside the loop: from the start
        run(e, 64);
        CHECK_EQ(e.meters().position, int64_t{64});
    }
    // A tempo change before the play: the step lands on the same beat at the new tempo (12000 samples a step).
    p.bpm = 60;
    e.setProject(p);
    e.play(13.0);
    out = run(e, 2000);
    CHECK_NEAR(out[1000], 2.0 / 12.0 * g, 1e-4);  // it fades in over 10 ms (480 samples), so the jump doesn't click
    CHECK(std::fabs(out[100]) < std::fabs(out[1000]));
}

TEST(play_during_a_stop_fade_fades_back_in) {
    ProjectSpec p = project({dc(0.5)});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    run(e, 4800);
    e.stop();
    std::vector<float> out = run(e, 240);  // halfway through the 480-sample stop fade
    const float half = out.back();
    e.play();
    out = run(e, 1000);
    CHECK(std::fabs(out[0]) <= std::fabs(half) + 1e-6f);  // no jump back to full level
    CHECK(maxStep(out, 0, 1000) < 0.01f);
    CHECK_NEAR(out[999], 0.5 * std::cos(kPi / 4.0), 1e-5);
}

TEST(play_from_a_position_reaches_a_later_clip_on_time) {
    ProjectSpec p;
    p.bpm = 400;
    p.loopBars = 80;
    p.master = 1.0;
    p.modules.push_back({"hit", "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
    layer.volume = 1.0;
    layer.clips.push_back({"late", "hit", 70 * 16, 4, 0, false});  // bar 71: sample 336000 at 8 kHz
    p.layers.push_back(std::move(layer));
    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play(330000.0 / 300.0);  // 300 samples a step
    const auto out = run(e, 6400);
    CHECK_NEAR(out[5900], 0.0, 1e-7);
    CHECK(out[6000 + 300] > 0.1f);
}

TEST(arrangement_plays_clips_past_bar_64) {
    ProjectSpec p;
    p.bpm = 400;  // a step is 0.0375 s
    p.loopBars = 80;
    p.master = 1.0;
    p.modules.push_back({"hit", "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
    layer.volume = 1.0;
    layer.clips.push_back({"late", "hit", 70 * 16, 4, 0, false});  // bar 71
    p.layers.push_back(std::move(layer));
    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 336000 + 400);  // 1120 steps * 0.0375 s * 8000 Hz
    CHECK_NEAR(out[330000], 0.0, 1e-7);
    CHECK(out[336000 + 300] > 0.1f);
}

TEST(arrangement_expansion_is_refused_above_the_project_state_budget) {
    // A looping clip of a one-step pattern over most of the int range would expand to billions of notes.
    HardwareProfile hardware;
    hardware.memoryBudgetMiB = 2;
    Engine e(8000, makeEngineResourceBudget(hardware));
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"tick", "---\nkind: pattern\nlength: 1\n---\n0 C4 1 1\n"});
    p.modules.push_back({"rest", "---\nkind: pattern\nlength: 1\n---\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {});
    layer.clips.push_back({"huge", "tick", 0, 2000000000, 0, true});
    p.layers.push_back(layer);
    const std::string result = e.setProject(p);
    CHECK(result.find("\"ok\":false") != std::string::npos);
    CHECK(result.find("arrangement") != std::string::npos);
    CHECK(result.find("project-state budget") != std::string::npos);

    // The check leaves room for building: growing vectors and the sort's buffer take about three times the result.
    const uint64_t perRepeat = sizeof(PatternNote) + 2 * sizeof(PatternEvent);
    p.layers[0].clips = {{"half", "tick", 0, static_cast<int>(e.resourceBudget().projectStateBytes / 2 / perRepeat), 0, true}};
    const std::string half = e.setProject(p);
    CHECK(half.find("\"ok\":false") != std::string::npos);
    CHECK(half.find("arrangement") != std::string::npos);
    p.layers[0].clips = {{"small", "tick", 0, static_cast<int>(e.resourceBudget().projectStateBytes / 8 / perRepeat), 0, true}};
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);

    // A looping clip of an empty pattern expands to nothing, and compiling it doesn't walk every repeat.
    p.layers[0].clips = {{"silent", "rest", 0, 2000000000, 0, true}};
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
}

TEST(project_parser_preserves_large_module_and_clip_lists) {
    std::string json = R"({"caw_project":1,"modules":[)";
    for (int i = 0; i < 300; ++i) {
        if (i) json += ",";
        json += R"({"id":"module_)" + std::to_string(i) + R"(","source":"0"})";
    }
    json += R"(],"layers":[{"id":"track","clips":[)";
    for (int i = 0; i < 520; ++i) {
        if (i) json += ",";
        json += R"({"id":"clip_)" + std::to_string(i) + R"(","pattern":"pattern","start_steps":0,"length_steps":1})";
    }
    json += R"(]}]})";
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(json, parsed, error));
    CHECK_EQ(parsed.modules.size(), size_t{300});
    CHECK_EQ(parsed.layers.size(), size_t{1});
    CHECK_EQ(parsed.layers[0].clips.size(), size_t{520});
    CHECK_EQ(parsed.layers[0].clips.back().id, std::string("clip_519"));
}

TEST(arrangement_compilation_keeps_notes_beyond_4096) {
    ProjectSpec p;
    p.bpm = 400;
    p.loopBars = 64;
    p.master = 1.0;
    p.modules.push_back({"chord",
        "---\nkind: pattern\nlength: 1\n---\n0 C3,D3,E3,F3,G3,A3,B3,C4,D4 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.1}});
    layer.volume = 1.0;
    for (int i = 0; i < 520; ++i)
        layer.clips.push_back({"clip_" + std::to_string(i), "chord", i, 1, 0, false});
    p.layers.push_back(std::move(layer));

    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 150100);
    CHECK(out[150000] > 0.05f); // clip 500 starts after the former 4096-note truncation point
}

TEST(project_parser_preserves_large_project_automation) {
    std::string json = R"({"caw_project":1,"automation":[)";
    for (int lane = 0; lane < 257; ++lane) {
        if (lane) json += ",";
        json += R"({"target_type":"global","target":"g)" + std::to_string(lane) + R"(","points":[)";
        for (int point = 0; point < 129; ++point) {
            if (point) json += ",";
            json += R"({"step":)" + std::to_string(point) + R"(,"value":0.5})";
        }
        json += "]}";
    }
    json += "]}";
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(json, parsed, error));
    CHECK_EQ(parsed.automation.size(), size_t{257});
    CHECK_EQ(parsed.automation.back().points.size(), size_t{129});
    CHECK_NEAR(parsed.automation.back().points.back().step, 128.0, 1e-9);
}

TEST(project_and_engine_preserve_layer_automation_beyond_128_points) {
    std::string json = R"({"caw_project":1,"bpm":400,"loop_bars":64,"master":1,
      "layers":[{"id":"track","instrument":{"id":"org.caw.test.osc","params":{"shape":4}},"volume":1,"automation":[
        {"target":"volume","points":[)";
    for (int point = 0; point < 129; ++point) {
        if (point) json += ",";
        const double value = point == 128 ? 0.1 : 1.0;
        json += R"({"step":)" + std::to_string(point) + R"(,"value":)" + std::to_string(value) + "}";
    }
    json += R"(]}]}]})";
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(json, parsed, error));
    CHECK_EQ(parsed.layers[0].automation[0].points.size(), size_t{129});

    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(parsed).find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 38500);
    const float unity = static_cast<float>(std::cos(kPi / 4.0));
    CHECK_NEAR(out[30000], unity, 1e-4); // automation point 100
    CHECK_NEAR(out[38400], 0.1 * unity, 1e-4); // point 128 must not be truncated
}

TEST(engine_rejects_project_state_above_hardware_budget) {
    HardwareProfile hardware;
    hardware.memoryBudgetMiB = 2;
    Engine e(8000, makeEngineResourceBudget(hardware));
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    // Each Flagship holds a resolver and a block of values for every one of its parameters.
    for (int i = 0; i < 16; ++i) {
        LayerSpec layer;
        layer.id = "track" + std::to_string(i);
        layer.hasInstrument = true;
        layer.instrument.id = "org.caw.synth.flagship";
        layer.components = {{"org.caw.reverb.pro", {}}, {"org.caw.delay.pro", {}}};
        p.layers.push_back(layer);
    }
    const std::string result = e.setProject(p);
    CHECK(result.find("\"ok\":false") != std::string::npos);
    CHECK(result.find("project-state memory budget") != std::string::npos);
}

TEST(engine_prepares_dynamic_note_curve_capacity_before_playback) {
    std::string pattern = "---\nkind: pattern\n---\n0 C4 1 bend";
    for (int i = 0; i < 20; ++i) {
        const double t = static_cast<double>(i) / 19.0;
        const double value = static_cast<double>(i) / 19.0;
        pattern += " " + std::to_string(t) + ":" + std::to_string(value);
    }
    pattern += "\n";
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"pattern", pattern});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Sine, "", {});
    layer.pattern = "pattern";
    p.layers.push_back(layer);
    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 2000);
    CHECK(std::any_of(out.begin(), out.end(), [](float sample) { return std::abs(sample) > 1e-5f; }));
}

TEST(track_removed_inside_folder_fades_out_like_a_root_track) {
    // Issue #76: a removed child kept its parent but was processed after the folder bus, so its fade
    // never reached the mix and it cut off with a step. It must fade like a removed root track.
    auto removalStep = [](bool inFolder) {
        ProjectSpec p = project({sine(110, 0.2),
                                 sine(220, 0.5)});
        if (inFolder) {
            LayerSpec bus;
            bus.id = "bus"; bus.name = "bus"; bus.folder = true; bus.busEnabled = true; bus.volume = 1.0;
            p.layers.insert(p.layers.begin(), bus);
            p.layers[2].parentId = "bus";  // "gone"
        }
        Engine e(48000);
        e.setMasterBypass(true);
        e.setProject(p);
        e.play();
        const auto before = run(e, 9655);  // a quarter period of 220 Hz past a zero crossing: near its peak
        p.layers.erase(p.layers.end() - 1);  // remove "gone"
        e.setProject(p);
        std::vector<float> after = run(e, 9600);
        after.insert(after.begin(), before.back());  // measure the step across the removal too
        return maxStep(after, 0, after.size());
    };
    const float root = removalStep(false);
    const float folder = removalStep(true);
    CHECK(folder <= root * 1.5f + 1e-4f);
}

TEST(engine_rejects_unsupported_sample_rates_with_an_exception) {
    // The mix graph accepts 8,000-192,000 Hz; outside that the Engine can't be built. The C API
    // checks the range and catches any construction failure, so it never crosses the C ABI.
    bool threw = false;
    try { Engine e(4000); } catch (const std::runtime_error&) { threw = true; }
    CHECK(threw);
    bool ok = true;
    try { Engine e(8000); Engine f(192000); } catch (...) { ok = false; }
    CHECK(ok);
}

TEST(mix_graph_routing_is_never_rejected_through_reparenting_and_removal) {
    ProjectSpec p = project({sine(220, 0.3), sine(330, 0.3),
                             sine(440, 0.3)});
    LayerSpec outer, inner;
    outer.id = "outer"; outer.name = "outer"; outer.folder = true; outer.busEnabled = true;
    inner.id = "inner"; inner.name = "inner"; inner.folder = true; inner.busEnabled = true; inner.parentId = "outer";
    p.layers.insert(p.layers.begin(), inner);
    p.layers.insert(p.layers.begin(), outer);
    p.layers[2].parentId = "inner";
    p.layers[3].parentId = "outer";
    Engine e(48000);
    e.setProject(p);
    e.play();
    run(e, 4800);
    p.layers[2].parentId = "outer";   // reparent a track
    p.layers[1].parentId.clear();     // detach the inner bus
    e.setProject(p);
    run(e, 4800);
    p.layers.erase(p.layers.begin()); // remove the outer folder
    e.setProject(p);
    run(e, 9600);
    p.layers.pop_back();              // remove a root track
    e.setProject(p);
    run(e, 9600);
    CHECK_EQ(e.routingRejections(), 0u);
}

// ---- F7.3 part B: the Engine grows past 64 layers, bounded by the memory budget ----

namespace {

// n layers, each playing DC at `level`, named g0..g(n-1).
ProjectSpec layersOf(int n, double level, double volume = 1.0) {
    std::vector<LayerSpec> layers;
    for (int i = 0; i < n; ++i) {
        layers.push_back(cawtest::testSignalLayer("g" + std::to_string(i), Shape::Dc, {{"level", level}}));
        layers.back().volume = volume;
    }
    return cawtest::testSignalProject(std::move(layers), 120, 1);
}

// n layer slots: a track playing DC at `level` (g0), then n - 1 empty bus folders. A project runs at most 256 native
// components (and each instrument holds a note list), so many slots are buses, which take a slot each.
ProjectSpec slotsOf(int n, double level) {
    ProjectSpec p = layersOf(1, level);
    for (int i = 1; i < n; ++i) {
        LayerSpec bus;
        bus.id = "b" + std::to_string(i);
        bus.name = bus.id;
        bus.folder = true;
        bus.busEnabled = true;
        p.layers.push_back(bus);
    }
    return p;
}

}  // namespace

TEST(engine_plays_more_than_64_layers_with_meters_and_folder_buses_above_slot_64) {
    for (int n : {65, 200}) {
        // A folder bus first (slot 0), then n tracks; tracks from project index 64 on route through
        // the bus, so the bus sums children whose slots are 64 and above.
        ProjectSpec p = layersOf(n, 0.0001);
        LayerSpec folder;
        folder.id = "bus";
        folder.name = "Group";
        folder.folder = true;
        folder.busEnabled = true;
        folder.volume = 0.5;
        int children = 0;
        for (int i = 64; i < n; ++i, ++children) p.layers[static_cast<size_t>(i)].parentId = "bus";
        p.layers.insert(p.layers.begin(), folder);
        Engine e(48000);
        e.setMasterBypass(true);
        const std::string result = e.setProject(p);
        CHECK(result.find("\"ok\":true") != std::string::npos);
        CHECK(e.layerCapacity() >= n + 1);
        CHECK_EQ(e.auditionSlot(), e.layerCapacity());
        e.play();
        const auto left = run(e, 2048);
        const double expected = 0.0001 * std::cos(kPi / 4.0) * ((n - children) + 0.5 * children);
        CHECK_NEAR(left[2000], expected, 1e-6);
        for (int i = 1; i <= n; ++i) {  // project index 0 is the bus
            LayerMeter lm;
            CHECK(e.layerMeter(i, lm));
            CHECK(lm.active);
            CHECK(lm.peak > 0.0f);
            float scope[16];
            CHECK_EQ(e.scope(i, scope, 16), 16);
            CHECK_NEAR(scope[15], 0.0001f, 1e-7);
        }
        CHECK_EQ(e.routingRejections(), 0u);
    }
}

TEST(engine_grows_during_playback_and_existing_layers_stay_bit_identical) {
    // Ten audible layers; the grown project adds 90 muted ones. The first ten must sound exactly
    // as they do in an Engine that never grows.
    ProjectSpec small;
    small.bpm = 120;
    small.loopBars = 1;
    small.master = 1.0;
    for (int i = 0; i < 10; ++i) {
        LayerSpec l = cawtest::testSignalLayer("l" + std::to_string(i), Shape::Sine, {{"freq", 110.0 * (i + 1)}, {"level", 0.05}});
        l.volume = 0.8;
        l.pan = -0.5 + 0.1 * i;
        small.layers.push_back(l);
    }
    ProjectSpec big = small;
    for (int i = 10; i < 100; ++i) {
        LayerSpec l = cawtest::testSignalLayer("l" + std::to_string(i), Shape::Sine, {{"freq", 77}, {"level", 0.5}});
        l.volume = 0.8;
        l.mute = true;
        big.layers.push_back(l);
    }
    Engine a(48000), b(48000);
    CHECK(a.setProject(small).find("\"ok\":true") != std::string::npos);
    CHECK(b.setProject(small).find("\"ok\":true") != std::string::npos);
    a.play();
    b.play();
    std::vector<float> ra, rb;
    const auto la = run(a, 4800, 64, &ra);
    const auto lb = run(b, 4800, 64, &rb);
    CHECK(la == lb);
    CHECK_EQ(b.layerCapacity(), 64);
    CHECK(a.setProject(small).find("\"ok\":true") != std::string::npos);
    CHECK(b.setProject(big).find("\"ok\":true") != std::string::npos);
    CHECK(b.layerCapacity() >= 100);
    CHECK_EQ(a.layerCapacity(), 64);
    const auto la2 = run(a, 9600, 64, &ra);
    const auto lb2 = run(b, 9600, 64, &rb);
    CHECK(la2.size() == lb2.size() && std::memcmp(la2.data(), lb2.data(), la2.size() * sizeof(float)) == 0);
    CHECK(ra.size() == rb.size() && std::memcmp(ra.data(), rb.data(), ra.size() * sizeof(float)) == 0);
    float peak = 0;
    for (float v : lb2) peak = std::max(peak, std::fabs(v));
    CHECK(peak > 0.05f);
    // The grown layers really are there: unmuting one makes it heard.
    big.layers[99].mute = false;
    CHECK(b.setProject(big).find("\"ok\":true") != std::string::npos);
    LayerMeter lm;
    run(b, 4800);
    CHECK(b.layerMeter(99, lm) && lm.active && lm.peak > 0.1f);
    CHECK_EQ(b.routingRejections(), 0u);
}

TEST(engine_refuses_more_layers_than_the_memory_budget_allows) {
    HardwareProfile hardware;
    hardware.memoryBudgetMiB = 2;
    Engine e(8000, makeEngineResourceBudget(hardware));
    CHECK_EQ(e.maxLayers(), 64);  // the initial capacity is always available
    e.setMasterBypass(true);
    CHECK(e.setProject(slotsOf(64, 0.001)).find("\"ok\":true") != std::string::npos);
    const std::string refused = e.setProject(slotsOf(65, 0.001));
    CHECK(refused.find("\"ok\":false") != std::string::npos);
    CHECK(refused.find("project has 65 layers; this device's memory budget allows at most 64") != std::string::npos);
    CHECK_EQ(e.layerCapacity(), 64);
    // The refused project changed nothing: the 64 layers play on.
    e.play();
    const auto out = run(e, 800);
    CHECK_NEAR(out[799], 0.001 * std::cos(kPi / 4.0), 1e-7);
    // The 128 MiB fallback budget (memory unknown) allows more than 64.
    Engine big(8000, makeEngineResourceBudget(HardwareProfile{}));
    CHECK(big.maxLayers() > 64);
}

TEST(engine_play_with_more_than_640_layers_retires_every_chain_without_stalling) {
    // Every bus replaces its volume lane twice: about 2 * 700 retirements, more than the retired queue holds at
    // once (the rest wait in the pending list); a Play after them must not wait for room.
    HardwareProfile hardware;
    hardware.memoryBudgetMiB = 1024;
    Engine e(48000, makeEngineResourceBudget(hardware));
    CHECK(e.maxLayers() >= 700);
    e.setMasterBypass(true);
    std::vector<float> l(64), r(64);
    // The audio thread is pumped with zero-frame callbacks: commands apply but time stands still,
    // so no fade finishes on its own.
    auto apply = [&](const ProjectSpec& p) {
        std::atomic<bool> done{false};
        std::string result;
        std::thread control([&] {
            result = e.setProject(p);
            done.store(true);
        });
        while (!done.load()) e.process(l.data(), r.data(), 0);
        control.join();
        e.process(l.data(), r.data(), 0);
        return result;
    };
    ProjectSpec p = slotsOf(700, 0.00001);
    CHECK(apply(p).find("\"ok\":true") != std::string::npos);
    CHECK(e.layerCapacity() >= 700);
    e.play();
    for (int k = 0; k < 4; ++k) e.process(l.data(), r.data(), 64);
    CHECK_NEAR(l[63], 0.00001 * std::cos(kPi / 4.0), 1e-8);
    for (double level : {1.0, 0.5, 1.0}) {  // the second and third rounds retire the lanes they replace
        for (size_t i = 1; i < p.layers.size(); ++i) p.layers[i].automation = {{"volume", {{0, level}, {16, level}}}};
        CHECK(apply(p).find("\"ok\":true") != std::string::npos);
    }
    CHECK(e.meters().position > 0);
    e.play();
    e.process(l.data(), r.data(), 0);
    CHECK_EQ(e.meters().position, 0);  // the Play was applied in the first callback: it did not wait for room
    for (int k = 0; k < 20; ++k) {
        e.process(l.data(), r.data(), 64);
        e.meters();  // drains the retired queue, so the overflow moves across
    }
    CHECK_NEAR(l[63], 0.00001 * std::cos(kPi / 4.0), 1e-8);
    CHECK_EQ(e.routingRejections(), 0u);
}

TEST(engine_per_chunk_work_follows_the_layers_in_use_not_the_capacity) {
    // #133 item 2: capacity never shrinks, so after a 700-layer project the per-chunk loops
    // (planning, solo, export clearing, routing) must visit only the slots in use, and sound the same.
    HardwareProfile hardware;
    hardware.memoryBudgetMiB = 1024;
    Engine e(48000, makeEngineResourceBudget(hardware));
    Engine fresh(48000, makeEngineResourceBudget(hardware));
    e.setMasterBypass(true);
    fresh.setMasterBypass(true);
    std::vector<float> l(64), r(64);
    auto apply = [&](Engine& to, const ProjectSpec& p) {
        std::atomic<bool> done{false};
        std::string result;
        std::thread control([&] {
            result = to.setProject(p);
            done.store(true);
        });
        while (!done.load()) to.process(l.data(), r.data(), 0);
        control.join();
        to.process(l.data(), r.data(), 0);
        return result;
    };
    const double tone = 0.01;
    CHECK(apply(e, slotsOf(700, tone)).find("\"ok\":true") != std::string::npos);
    CHECK(e.layerCapacity() >= 700);
    CHECK(apply(e, layersOf(4, tone)).find("\"ok\":true") != std::string::npos);
    CHECK(apply(fresh, layersOf(4, tone)).find("\"ok\":true") != std::string::npos);
    e.play();
    fresh.play();
    std::vector<float> er, fr;
    const auto el = run(e, 4800, 64, &er);
    const auto fl = run(fresh, 4800, 64, &fr);
    CHECK(el == fl);
    CHECK(er == fr);
    CHECK(e.slotsScannedPerChunk() <= 5);  // the 4 layers (and at most the audition)
    CHECK_EQ(e.slotsScannedPerChunk(), fresh.slotsScannedPerChunk());
    CHECK_EQ(e.routingRejections(), 0u);
}

TEST(project_parser_accepts_1000_layers) {
    std::string json = R"({"caw_project":1,"layers":[)";
    for (int i = 0; i < 1000; ++i) json += (i ? ",{\"id\":\"l" : "{\"id\":\"l") + std::to_string(i) + "\"}";
    json += "]}";
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(json, p, error));
    CHECK_EQ(p.layers.size(), size_t{1000});
}

TEST(audition_scope_follows_the_audition_slot_across_a_grow) {
    ProjectSpec p = layersOf(10, 0.001);
    p.hasAuditionInstrument = true;
    p.auditionInstrument = cawtest::testSignal(Shape::Dc, {{"level", 0.5}});
    p.auditionOnly = true;
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    run(e, 4800);
    float scope[64];
    CHECK_EQ(e.auditionSlot(), 64);
    CHECK_EQ(e.scope(kScopeAudition, scope, 64), 64);
    CHECK_NEAR(scope[63], 0.4f, 1e-4);
    // Grow while the audition plays: it keeps its sound, and its scope id moves to the new last slot.
    ProjectSpec big = layersOf(150, 0.001);
    big.hasAuditionInstrument = true;
    big.auditionInstrument = p.auditionInstrument;
    big.auditionOnly = true;
    CHECK(e.setProject(big).find("\"ok\":true") != std::string::npos);
    CHECK(e.layerCapacity() >= 150);
    CHECK_EQ(e.auditionSlot(), e.layerCapacity());
    const auto left = run(e, 4800);
    CHECK_NEAR(left.back(), static_cast<float>(0.8 * 0.5 * std::cos(kPi / 4.0)), 1e-5);
    CHECK_EQ(e.scope(kScopeAudition, scope, 64), 64);
    CHECK_NEAR(scope[63], 0.4f, 1e-4);
    // Leaving audition-only mode: the layers are heard and the audition is silent.
    big.auditionOnly = false;
    CHECK(e.setProject(big).find("\"ok\":true") != std::string::npos);
    CHECK_NEAR(run(e, 24000).back(), 150 * 0.001 * std::cos(kPi / 4.0), 1e-5);
    // Project layer 64 is a layer like any other: its scope is the layer's, not the audition's.
    CHECK_EQ(e.scope(64, scope, 64), 64);
    CHECK(scope[63] > 0.0f && scope[63] < 0.01f);
}

// ---- Note previews (#103) ----

namespace {
// A layer playing an empty pattern on the test signal in Notes mode at level 1: each held note outputs its
// velocity, so the level shows which notes are held (and a sum of two voices shows as a jump).
ProjectSpec previewProject() {
    ProjectSpec p = project({});
    p.modules.push_back({"phrase", "---\nkind: pattern\nlength: 16\n---\n"});
    p.layers.push_back(cawtest::testSignalNotesLayer("track", Shape::Dc, "phrase"));
    return p;
}
}  // namespace

TEST(a_preview_sounds_while_stopped_and_stops_at_its_note_off_without_moving_the_transport) {
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(previewProject()).find("\"ok\":true") != std::string::npos);
    const double pan = std::cos(kPi / 4.0);
    CHECK_NEAR(run(e, 2000).back(), 0.0, 1e-9);  // stopped and silent
    e.noteOn("track", 7, 64, 0.5);
    const std::vector<float> held = run(e, 4800);
    CHECK_NEAR(held.back(), 0.5 * pan, 1e-4);
    CHECK_EQ(e.meters().position, 0);  // the transport stays where it was
    e.noteOff(7);
    const std::vector<float> after = run(e, 4800);
    CHECK_NEAR(after.back(), 0.0, 1e-6);
    CHECK_EQ(e.meters().playing, false);
}

TEST(a_held_preview_glides_to_a_new_pitch_and_the_same_id_retriggers_instead_of_stacking) {
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(previewProject());
    const double pan = std::cos(kPi / 4.0);
    e.noteOn("track", 1, 60, 0.5);
    CHECK_NEAR(run(e, 2400).back(), 0.5 * pan, 1e-4);
    e.notePitch(1, 72);  // a bend being drawn: the same voice, a 5 ms glide
    CHECK_NEAR(run(e, 2400).back(), 0.5 * pan, 1e-4);
    e.noteOn("track", 1, 48, 0.25);  // the same id again: the old note ends, one voice sounds
    CHECK_NEAR(run(e, 4800).back(), 0.25 * pan, 1e-4);
    e.noteOn("track", 2, 50, 0.125);  // another id: a chord
    CHECK_NEAR(run(e, 2400).back(), 0.375 * pan, 1e-4);
    e.notesOff();
    CHECK_NEAR(run(e, 4800).back(), 0.0, 1e-6);
}

TEST(after_stop_a_preview_hears_neither_the_chord_that_was_playing_nor_a_jump_back_to_full_level) {
    Engine e(48000);
    e.setMasterBypass(true);
    ProjectSpec p = previewProject();
    p.modules[0].source = "---\nkind: pattern\nlength: 16\n---\n0 C4 16\n";  // a note held through the loop
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    const double pan = std::cos(kPi / 4.0);
    e.play();
    CHECK_NEAR(run(e, 2400).back(), 1.0 * pan, 1e-4);
    // A preview held across Stop: the stop fades out, then the preview alone fades back in, with no step.
    e.noteOn("track", 1, 72, 0.5);
    run(e, 2400);
    e.stop();
    const std::vector<float> across = run(e, 4800);
    float step = 0;
    for (size_t i = 1; i < across.size(); ++i) step = std::max(step, std::fabs(across[i] - across[i - 1]));
    CHECK(step < 0.01f);
    CHECK_NEAR(across.back(), 0.5 * pan, 1e-4);  // the pattern's C4 doesn't come back
    e.noteOff(1);
    CHECK_NEAR(run(e, 4800).back(), 0.0, 1e-6);
    e.noteOn("track", 2, 48, 0.25);  // a fresh preview while stopped: only its own note
    CHECK_NEAR(run(e, 2400).back(), 0.25 * pan, 1e-4);
    e.notesOff();
}

TEST(a_preview_held_across_play_keeps_its_instrument_running) {
    Engine e(48000);
    e.setMasterBypass(true);
    ProjectSpec p = previewProject();  // a reset at Play would end the held note: a drop to 0
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.noteOn("track", 1, 60, 1);
    std::vector<float> out = run(e, 4801);
    e.play();
    const std::vector<float> playing = run(e, 4800);
    out.insert(out.end(), playing.begin(), playing.end());
    float step = 0;
    for (size_t i = 2400; i < out.size(); ++i) step = std::max(step, std::fabs(out[i] - out[i - 1]));
    CHECK(step < 0.001f);
    CHECK(out.back() > 0.5f);
    e.notesOff();
}

TEST(previews_follow_the_layer_mix_and_play_on_top_of_playback) {
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(previewProject());
    const double pan = std::cos(kPi / 4.0);
    e.setLayerMix("track", 1.0, 0.0, true, false);  // muted: silent
    e.noteOn("track", 1, 64, 1);
    CHECK_NEAR(run(e, 4800).back(), 0.0, 1e-6);
    e.setLayerMix("track", 0.5, 0.0, false, false);  // a preview on a muted track ended: unmuting doesn't bring it back
    CHECK_NEAR(run(e, 4800).back(), 0.0, 1e-6);
    e.noteOn("track", 1, 64, 1);
    CHECK_NEAR(run(e, 9600).back(), 0.5 * pan, 1e-3);
    e.noteOff(1);
    e.play();
    run(e, 2400);
    e.noteOn("track", 2, 32, 0.5);  // while playing: heard, and the empty pattern adds nothing
    CHECK_NEAR(run(e, 4800).back(), 0.5 * 0.5 * pan, 1e-3);
    CHECK(e.meters().position > 0);
}

// ---- Metronome, count-in and released touches (the app's recording flow and automation Touch mode) ----

namespace {
float peakIn(const std::vector<float>& v, size_t from, size_t to) {
    float m = 0;
    for (size_t i = from; i < to && i < v.size(); ++i) m = std::max(m, std::fabs(v[i]));
    return m;
}
}  // namespace

TEST(count_in_clicks_each_beat_then_plays_on_the_sample_after_the_last) {
    // 120 BPM at 48 kHz: a sixteenth is 6000 samples, a beat 24000.
    ProjectSpec p = heldProject(dc(0.25));
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.playCountIn(0, 4);
    const auto out = run(e, 4 * 24000 + 4800);
    for (int beat = 0; beat < 4; ++beat) {
        const size_t at = static_cast<size_t>(beat) * 24000;
        CHECK(peakIn(out, at, at + 600) > 0.1f);              // a click on the beat
        CHECK(peakIn(out, at + 2000, at + 23990) == 0.0f);    // and silence until the next: the song waits
    }
    CHECK(peakIn(out, 0, 600) > peakIn(out, 24000, 24600));   // the bar's first beat is accented
    const double pan = std::cos(kPi / 4.0);
    CHECK_NEAR(out[4 * 24000 + 2000], 0.25 * pan, 1e-4);      // then the song, from step 0
    CHECK(e.meters().playing);
    // A stop during a count-in cancels it.
    e.stop();
    run(e, 4800);
    e.playCountIn(0, 2);
    run(e, 1000);
    e.stop();
    const auto after = run(e, 3 * 24000);
    CHECK(!e.meters().playing);
    CHECK(peakIn(after, 0, after.size()) == 0.0f);
}

TEST(metronome_clicks_on_every_beat_while_playing_and_not_when_off) {
    ProjectSpec p = project({dc(0)});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    CHECK(peakIn(run(e, 2 * 24000), 0, 2 * 24000) == 0.0f);  // off by default
    e.stop();
    run(e, 4800);
    e.setMetronome(true);
    e.play();
    const auto out = run(e, 2 * 24000 + 1200);
    CHECK(peakIn(out, 0, 600) > 0.1f);
    CHECK(peakIn(out, 24000, 24600) > 0.1f);
    CHECK(peakIn(out, 4000, 23990) == 0.0f);
}

TEST(released_touches_let_the_lanes_rule_again_while_playing) {
    // The test signal's level, automated by a flat lane at 0.3: a knob move is a touch over it until released.
    ProjectSpec p = project({dc(0.5)});
    ProjectAutomationLaneSpec lane;
    lane.targetType = "instrument";
    lane.moduleId = "l0";
    lane.component = 0;
    lane.target = "level";
    lane.points = {{0.0, 0.3}};
    p.automation.push_back(lane);
    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const double level = run(e, 512).back();
    CHECK(level > 0.05);
    CHECK(e.setComponentParam("l0", Engine::kInstrumentIndex, "level", 0.9));  // a touch overrides the lane
    CHECK_NEAR(run(e, 512).back() / level, 3.0, 1e-4);
    e.releaseTouches();  // let go: the lane again, without a restart
    CHECK_NEAR(run(e, 512).back() / level, 1.0, 1e-4);
    CHECK(e.meters().playing);
}

TEST(track_volume_lanes_reach_plus_12_db_as_the_faders) {
    const std::string json = R"({"caw_project":1,"bpm":120,"loop_bars":1,"master":1,
      "layers":[{"id":"track","volume":1,"automation":[
        {"target":"volume","points":[{"step":0,"value":3.0},{"step":16,"value":9.0}]}]}]})";
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(json, parsed, error));
    CHECK_NEAR(parsed.layers[0].automation[0].points[0].value, 3.0, 1e-9);
    CHECK_NEAR(parsed.layers[0].automation[0].points[1].value, kMaxMixGain, 1e-9);  // held at +12 dB
}
