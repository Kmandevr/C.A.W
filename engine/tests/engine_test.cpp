// Mixer tests: a native master effect, meters, audition, folder buses, routing and automation.
#include <algorithm>
#include <functional>
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
#include "device_render.h"
#include "buffer_tuner.h"
#include "device_choice.h"
#include "device_period.h"
#include "engine.h"
#include "native_component_test_path.h"
#include "test.h"
#include "test_signal.h"
#include "engine_test_harness.h"

using namespace caw;
using namespace engine_test;

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

TEST(project_parser_reads_point_curves_bounded) {
    const std::string json = R"({"caw_project":1,"layers":[
      {"id":"t","automation":[{"target":"volume","points":[
        {"step":0,"value":0,"curve":"slow","tension":0.5},{"step":4,"value":1,"curve":"fast","tension":9},
        {"step":8,"value":0,"curve":"s"},{"step":12,"value":1,"curve":"step","tension":0.7},
        {"step":16,"value":0,"curve":"spiral","tension":-0.2},{"step":20,"value":1}]}]}
    ],"automation":[{"target_type":"instrument","layer":"t","target":"cutoff",
        "points":[{"step":0,"value":0,"curve":"fast","tension":-3},{"step":4,"value":1}]}]})";
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(json, p, error));
    const auto& pts = p.layers[0].automation[0].points;
    CHECK_EQ(int{pts[0].curve}, 1);
    CHECK_EQ(pts[0].tension, 0.5);
    CHECK_EQ(int{pts[1].curve}, 2);
    CHECK_EQ(pts[1].tension, 1.0);  // clamped
    CHECK_EQ(int{pts[2].curve}, 3);
    CHECK_EQ(int{pts[3].curve}, 4);
    CHECK_EQ(pts[3].tension, 0.0);  // a step has no bend
    CHECK_EQ(int{pts[4].curve}, 0);  // an unknown name reads linear
    CHECK_EQ(pts[4].tension, 0.0);
    CHECK_EQ(int{pts[5].curve}, 0);
    CHECK_EQ(int{p.automation[0].points[0].curve}, 2);
    CHECK_EQ(p.automation[0].points[0].tension, -1.0);
}

TEST(track_volume_automation_follows_curved_segments) {
    ProjectSpec p = project({dc(1)}, 4);  // four bars: the song doesn't loop before the lane ends
    p.layers[0].automation.push_back({"volume", {{0, 0, 1, 0.0}, {16, 1, 4, 0.0}, {32, 0}}});  // slow, then a step
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const auto left = run(e, 32 * 6000 + 256);
    const double pan = std::cos(kPi / 4.0);
    CHECK_NEAR(left[8 * 6000], 0.28125 * pan, 2e-3);  // slow, tension 0: 9/32 at half way
    CHECK_NEAR(left[24 * 6000], 1.0 * pan, 2e-3);   // a step holds
    CHECK_NEAR(left[31 * 6000], 1.0 * pan, 2e-3);
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
