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

#include "detmath.h"
#include "engine.h"
#include "native_component_test_path.h"
#include "test.h"

using namespace caw;

namespace {

const char* kFloat = "---\nmode: float\n---\n";

ProjectSpec project(std::vector<std::pair<std::string, std::string>> mods, int bars = 1, double bpm = 120) {
    ProjectSpec p;
    p.bpm = bpm;
    p.loopBars = bars;
    p.master = 1.0;
    int i = 0;
    for (auto& [id, src] : mods) {
        p.modules.push_back({id, src, {}});
        LayerSpec l;
        l.id = "l" + std::to_string(i++);
        l.name = l.id;
        l.chain = {id};
        l.volume = 1.0;
        p.layers.push_back(l);
    }
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

    ProjectSpec p = project({{"tone", std::string(kFloat) + "sine(220) * 0.8"}});
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
    p.modules.push_back({"tone", std::string(kFloat) + "0.5", {}});
    LayerSpec folder;
    folder.id = "folder";
    folder.name = "Folder";
    folder.folder = true;
    folder.volume = 0.5;
    p.layers.push_back(folder);
    LayerSpec centre;  // centred: each channel gets 0.5 * cos(pi/4)
    centre.id = "centre";
    centre.name = "Centre";
    centre.chain = {"tone"};
    centre.volume = 1.0;
    centre.parentId = "folder";
    p.layers.push_back(centre);
    LayerSpec left;  // hard left, at half volume: 0.25 on the left only
    left.id = "left";
    left.name = "Left";
    left.chain = {"tone"};
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

TEST(audition_only_uses_the_dedicated_audition_slot) {
    ProjectSpec p = project({{"tone", std::string(kFloat) + "0.5"}});
    p.layers.clear();
    p.auditionChain = {"tone"};
    p.auditionOnly = true;

    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const auto left = run(e, 256);
    CHECK_NEAR(left[200], static_cast<float>(0.8 * 0.5 * std::cos(kPi / 4.0)), 1e-5);
}

TEST(audition_slot_follows_the_last_layer_slot_and_both_play) {
    Engine e(48000);
    CHECK_EQ(e.layerCapacity(), kInitialLayerCapacity);
    CHECK_EQ(e.auditionSlot(), e.layerCapacity());
    std::vector<std::pair<std::string, std::string>> mods;
    for (int i = 0; i < kInitialLayerCapacity; ++i)
        mods.push_back({"m" + std::to_string(i), std::string(kFloat) + (i == kInitialLayerCapacity - 1 ? "0.25" : "0")});
    ProjectSpec p = project(mods);
    p.modules.push_back({"tone", std::string(kFloat) + "0.5", {}});
    p.auditionChain = {"tone"};
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
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.8"}});
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
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.8"}});
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
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.8"}});
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
    ProjectSpec p = project({{"a", std::string(kFloat) + "1"}});
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
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.8"}});
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

TEST(track_pan_automation_moves_between_stereo_channels) {
    ProjectSpec p = project({{"a", std::string(kFloat) + "1"}});
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
    ProjectSpec p = project({{"a", std::string(kFloat) + "1"}});
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
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.8"}}, 2);
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
    ProjectSpec p = project({{"a", std::string(kFloat) + "1"}});
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
    ProjectSpec p = project({{"a", "t*(t>>5|t>>8)"}, {"b", std::string(kFloat) + "lpf(saw(110), 800, 3) * ad(step%4==0)"}});
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
    // A 12-step layer in a 16-step project restarts every 12 steps; pos shows where each loop starts.
    ProjectSpec p = project({{"a", std::string(kFloat) + "pos * 0.5"}});
    p.seamCrossfade = false;
    p.layers[0].lengthSteps = 12;
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    // 120 BPM at 48 kHz: 6000 samples per 16th, so the layer loop is 72000 and the project loop 96000.
    std::vector<float> out = run(e, 200000);
    const double g = std::cos(kPi / 4.0);
    CHECK_EQ(e.loopLength(), int64_t{96000});
    CHECK_NEAR(out[0], 0.0, 1e-7);
    CHECK_NEAR(out[71999], 71999.0 / 72000.0 * 0.5 * g, 1e-6);
    CHECK_NEAR(out[72000], 0.0, 1e-7);   // layer restarts
    CHECK_NEAR(out[95999], 23999.0 / 72000.0 * 0.5 * g, 1e-6);
    CHECK_NEAR(out[96000], 0.0, 1e-7);   // project loop restarts every layer
    CHECK_NEAR(out[168000], 0.0, 1e-7);
}

TEST(seam_crossfade_removes_the_click) {
    ProjectSpec p = project({{"a", std::string(kFloat) + "pos * 0.8"}});
    p.layers[0].lengthSteps = 4;
    Engine hard(48000), soft(48000);
    p.seamCrossfade = false;
    hard.setMasterBypass(true);
    hard.setProject(p);
    hard.play();
    p.seamCrossfade = true;
    soft.setMasterBypass(true);
    soft.setProject(p);
    soft.play();
    std::vector<float> h = run(hard, 30000), s = run(soft, 30000);
    CHECK(maxStep(h, 23990, 24010) > 0.5f);
    CHECK(maxStep(s, 23990, 24200) < 0.01f);
}

TEST(hot_swap_crossfades_without_a_click) {
    Engine e(48000);
    e.setMasterBypass(true);
    ProjectSpec p = project({{"a", std::string(kFloat) + "sine(220) * 0.5"}});
    e.setProject(p);
    e.play();
    std::vector<float> before = run(e, 10000);
    p.modules[0].source = std::string(kFloat) + "square(330) * 0.5";
    std::string res = e.setProject(p);
    CHECK(res.find("\"ok\":true") != std::string::npos);
    std::vector<float> after = run(e, 10000);
    std::vector<float> all = before;
    all.insert(all.end(), after.begin(), after.end());
    CHECK(maxStep(all, 9990, 10010) < 0.05f);
    // After the fade only the new sound plays: a square wave has big steps.
    CHECK(maxStep(after, 2000, 9000) > 0.3f);
}

TEST(broken_code_keeps_the_old_sound) {
    ProjectSpec p = project({{"a", "t*(t>>5|t>>8)"}});
    Engine a(48000), b(48000);
    a.setProject(p);
    b.setProject(p);
    a.play();
    b.play();
    std::vector<float> a1 = run(a, 5000), b1 = run(b, 5000);
    ProjectSpec broken = p;
    broken.modules[0].source = "t*(t>>5|";
    std::string res = a.setProject(broken);
    CHECK(res.find("\"ok\":false") != std::string::npos);
    CHECK(res.find("line 1") != std::string::npos);
    std::vector<float> a2 = run(a, 20000), b2 = run(b, 20000);
    CHECK(a1 == b1);
    CHECK(a2 == b2);
}

TEST(mute_and_solo) {
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.25"}, {"b", std::string(kFloat) + "0.5"}});
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
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.05"}});
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
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.25"}, {"b", std::string(kFloat) + "0.5"}});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    run(e, 1000);
    for (int i = 0; i < 40; ++i) e.reportLoad(1.5);
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

TEST(stop_fades_to_silence_and_layers_can_be_removed) {
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.5"}});
    Engine e(48000);
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
    for (int i = 0; i < kInitialLayerCapacity; ++i) {
        many.modules.push_back({"m" + std::to_string(i), std::string(kFloat) + "0.001", {}});
        LayerSpec l;
        l.id = "x" + std::to_string(i);
        l.chain = {"m" + std::to_string(i)};
        many.layers.push_back(l);
    }
    e.setProject(many);
    run(e, 100);
    LayerMeter lm;
    CHECK(e.layerMeter(kInitialLayerCapacity - 1, lm) && lm.active);
}

TEST(effects_process_their_layer_only) {
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.3"}, {"b", std::string(kFloat) + "0.3"}});
    p.modules.push_back({"fx", "---\nkind: effect\n---\nin * 2", {}});
    p.layers[0].chain.push_back("fx");
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    std::vector<float> out = run(e, 1000);
    CHECK_NEAR(out[999], 0.9 * std::cos(kPi / 4.0), 1e-6);
}

TEST(each_module_of_a_track_runs_as_its_own_graph_node) {
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.3"}});
    p.modules.push_back({"fx", "---\nkind: effect\n---\nin * 2", {}});
    p.modules.push_back({"fx2", "---\nkind: effect\n---\nin * 0.5", {}});
    p.layers[0].chain = {"a", "fx", "fx2", "fx"};
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    std::vector<float> out = run(e, 1000);
    CHECK_NEAR(out[999], 0.6 * std::cos(kPi / 4.0), 1e-6);
    CHECK_EQ(e.mixGraphNodesRun(), 6u);  // four module nodes, the track node and master; idle slots never run
    CHECK_EQ(e.routingRejections(), 0u);
}

TEST(track_chain_longer_than_its_module_nodes_is_refused_with_an_error) {
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.25"}});
    p.modules.push_back({"fx", "---\nkind: effect\n---\nin", {}});
    for (int i = 1; i < kMaxTrackModules; ++i) p.layers[0].chain.push_back("fx");
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("a track runs at most") == std::string::npos);
    e.play();
    std::vector<float> out = run(e, 500);
    CHECK_NEAR(out[499], 0.25 * std::cos(kPi / 4.0), 1e-6);  // exactly the limit still plays
    p.layers[0].chain.push_back("fx");
    const std::string result = e.setProject(p);
    CHECK(result.find("layer not installed: its chain has 33 modules and a track runs at most 32") != std::string::npos);
    out = run(e, 4800);
    CHECK_EQ(out[4799], 0.0f);  // refused, never played cut short
    CHECK_EQ(e.routingRejections(), 0u);
}

TEST(params_reach_the_audio) {
    ProjectSpec p = project({{"a", std::string(kFloat) + "param level = 0.2\nlevel"}});
    p.modules[0].params["level"] = 0.4;
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    std::vector<float> out = run(e, 100);
    CHECK_NEAR(out[99], 0.4 * std::cos(kPi / 4.0), 1e-6);
    e.setParam("a", "level", 0.1);
    out = run(e, 100);
    CHECK_NEAR(out[99], 0.1 * std::cos(kPi / 4.0), 1e-6);
    e.setParam("a", "level", 5.0);  // clamped to the declared range
    out = run(e, 100);
    CHECK_NEAR(out[99], 1.0 * std::cos(kPi / 4.0), 1e-6);
}

TEST(limiter_keeps_output_below_full_scale) {
    ProjectSpec p = project({{"a", "t*7"}, {"b", "t*13"}, {"c", "t*3"}});
    Engine e(48000);
    e.setProject(p);
    e.play();
    std::vector<float> out = run(e, 48000);
    float peak = 0;
    for (float v : out) peak = std::max(peak, std::fabs(v));
    CHECK(peak <= 0.978f);
    CHECK(peak > 0.5f);
}

TEST(unchanged_calls_keep_playing_across_a_code_swap) {
    // Only the volume changes: the sine keeps its phase, so after the 20 ms crossfade the output is exactly the
    // new volume times the same running sine, with no restart.
    ProjectSpec p = project({{"m", std::string(kFloat) + "sine(220) * 0.5"}});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    run(e, 9000);
    p.modules[0].source = std::string(kFloat) + "sine(220) * 0.25";
    e.setProject(p);
    std::vector<float> y = run(e, 4000);
    const double g = std::cos(kPi / 4.0);
    for (int i = 2000; i < 4000; i += 37) {
        const double n = 9000.0 + i;
        CHECK_NEAR(y[static_cast<size_t>(i)] / g, 0.25 * detSin(kTwoPi * 220.0 * n / 48000.0), 1e-4);
    }
}

TEST(code_swaps_can_wait_for_the_next_bar) {
    ProjectSpec p = project({{"m", std::string(kFloat) + "0.1"}}, 2);
    p.swapMode = 2;  // next bar: 96000 samples at 120 BPM
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    run(e, 1024);
    p.modules[0].source = std::string(kFloat) + "0.2";
    e.setProject(p);
    std::vector<float> y = run(e, 100000 - 1024);
    const double g = std::cos(kPi / 4.0);
    CHECK_NEAR(y[50000] / g, 0.1, 1e-6);
    CHECK_NEAR(y[96000 - 1024 - 1] / g, 0.1, 1e-6);
    CHECK_NEAR(y[96000 - 1024 + 2000] / g, 0.2, 1e-6);
}

TEST(arrangement_clips_schedule_reusable_patterns_on_the_project_timeline) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.seamCrossfade = false;
    p.modules.push_back({"tone", std::string(kFloat) + "gate * vel * 0.5", {}});
    p.modules.push_back({"phrase",
        "---\nkind: pattern\nlength: 4\n---\n0 A4 2 1\n", {}});
    LayerSpec layer;
    layer.id = "track";
    layer.name = "Track";
    layer.chain = {"tone"};
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


TEST(arrangement_clip_source_offset_trims_the_source_and_honors_non_looping) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 2;
    p.master = 1.0;
    p.seamCrossfade = false;
    p.modules.push_back({"tone", std::string(kFloat) + "gate * vel * 0.5", {}});
    p.modules.push_back({"phrase",
        "---\nkind: pattern\nlength: 4\n---\n0 A4 1 1\n2 C4 1 1\n", {}});
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone"};
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
    p.seamCrossfade = false;
    p.modules.push_back({"tone", std::string(kFloat) + "gate * vel * 0.5", {}});
    p.modules.push_back({"phrase",
        "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1\n", {}});
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone"};
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
    p.seamCrossfade = false;
    p.modules.push_back({"tone", std::string(kFloat) + "trig", {}});
    p.modules.push_back({"phrase",
        "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1 ratchet 4\n", {}});
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone"};
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
    p.seamCrossfade = false;
    p.modules.push_back({"tone", std::string(kFloat) + "gate * vel * 0.25", {}});
    p.modules.push_back({"phrase", "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1\n", {}});
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone"};
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


TEST(master_gain_updates_without_recompiling_and_ramps_smoothly) {
    ProjectSpec p = project({{"tone", std::string(kFloat) + "0.5"}});
    p.master = 1.0;
    Engine e(48000);
    e.setMasterBypass(true);
    const std::string projectResult = e.setProject(p);
    CHECK(projectResult.find("\"ok\":true") != std::string::npos);
    CHECK(projectResult.find("nothing exports") == std::string::npos);
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
    "audition":{"chain":["m"],"length_steps":400000}})";
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
    refused(R"("audition":{"chain":["m"],"length_steps":-5})", "audition length_steps must be");

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
    // As in layers_loop_at_their_own_length: a 12-step layer (72000 samples) in a 96000-sample project loop.
    ProjectSpec p = project({{"a", std::string(kFloat) + "pos * 0.5"}});
    p.seamCrossfade = false;
    p.layers[0].lengthSteps = 12;
    const double g = std::cos(kPi / 4.0);
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play(80000.0 / 6000.0);  // step 13.33 (6000 samples a step): in the layer's second pass
    std::vector<float> out = run(e, 20000);
    // It fades in over 10 ms (480 samples) so the jump from silence doesn't click, then plays the layer from there.
    CHECK_NEAR(out[0], 0.0, 1e-7);
    CHECK(std::fabs(out[100]) < std::fabs(out[1000]));
    CHECK_NEAR(out[1000], 9000.0 / 72000.0 * 0.5 * g, 1e-6);
    CHECK_NEAR(out[15999], 23999.0 / 72000.0 * 0.5 * g, 1e-6);
    CHECK_NEAR(out[16000], 0.0, 1e-7);  // the project loop wraps as usual
    Meters m = e.meters();
    CHECK_EQ(m.position, int64_t{4000});
    for (double bad : {-5.0, 16.0, 1e30, std::nan(""), static_cast<double>(INFINITY)}) {
        e.play(bad);  // outside the loop: from the start
        out = run(e, 64);
        CHECK_NEAR(out[0], 0.0, 1e-7);
    }
    // A tempo change before the play: the step lands on the same beat at the new tempo (12000 samples a step).
    p.bpm = 60;
    e.setProject(p);
    e.play(13.0);
    out = run(e, 2000);
    CHECK_NEAR(out[1000], (13.0 * 12000.0 - 144000.0 + 1000.0) / 144000.0 * 0.5 * g, 1e-6);
}

TEST(play_during_a_stop_fade_fades_back_in) {
    ProjectSpec p = project({{"a", std::string(kFloat) + "0.5"}});
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
    p.seamCrossfade = false;
    p.modules.push_back({"tone", std::string(kFloat) + "gate * 0.5", {}});
    p.modules.push_back({"hit", "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1\n", {}});
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone"};
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
    p.seamCrossfade = false;
    p.modules.push_back({"tone", std::string(kFloat) + "gate * 0.5", {}});
    p.modules.push_back({"hit", "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1\n", {}});
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone"};
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
    p.modules.push_back({"tone", std::string(kFloat) + "gate", {}});
    p.modules.push_back({"tick", "---\nkind: pattern\nlength: 1\n---\n0 C4 1 1\n", {}});
    p.modules.push_back({"rest", "---\nkind: pattern\nlength: 1\n---\n", {}});
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone"};
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

TEST(project_parser_preserves_long_module_chains) {
    std::string chain = "[";
    for (int i = 0; i < 12; ++i) {
        if (i) chain += ",";
        chain += "\"module_" + std::to_string(i) + "\"";
    }
    chain += "]";
    const std::string json = R"({"caw_project":1,"layers":[{"id":"track","chain":)" + chain + R"(}]})";
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(json, parsed, error));
    CHECK_EQ(parsed.layers.size(), size_t{1});
    CHECK_EQ(parsed.layers[0].chain.size(), size_t{12});
    CHECK_EQ(parsed.layers[0].chain.back(), std::string("module_11"));
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
    p.seamCrossfade = false;
    p.voices = 32;
    p.modules.push_back({"tone", std::string(kFloat) + "gate * 0.1", {}});
    p.modules.push_back({"chord",
        "---\nkind: pattern\nlength: 1\n---\n0 C3,D3,E3,F3,G3,A3,B3,C4,D4 1\n", {}});
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone"};
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
      "modules":[{"id":"tone","source":"---\nmode: float\n---\n1"}],
      "layers":[{"id":"track","chain":["tone"],"volume":1,"automation":[
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

TEST(engine_automates_parameters_beyond_32) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.seamCrossfade = false;
    std::string source = "---\nmode: float\n---\n";
    for (int i = 0; i < 40; ++i)
        source += "param p" + std::to_string(i) + " = 0.5 in 0..2\n";
    source += "p39 * 0.5";
    p.modules.push_back({"tone", source, {}});
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone"};
    layer.volume = 1.0;
    p.layers.push_back(layer);
    ProjectAutomationLaneSpec lane;
    lane.targetType = "param";
    lane.moduleId = "tone";
    lane.target = "p39";
    lane.points = {{0.0, 0.5}, {1.0, 1.5}};
    p.automation.push_back(lane);

    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 1100);
    const float pan = static_cast<float>(std::cos(kPi / 4.0));
    CHECK_NEAR(out[0], 0.25 * pan, 1e-4);
    CHECK_NEAR(out[1000], 0.75 * pan, 1e-4);
}

TEST(engine_rejects_project_state_above_hardware_budget) {
    HardwareProfile hardware;
    hardware.memoryBudgetMiB = 2;
    Engine e(8000, makeEngineResourceBudget(hardware));
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"tone", std::string(kFloat) + "1", {}});
    const std::string delay = "---\nkind: effect\nmode: float\n---\nfx.delay(in, 0.5, 0.3, 0.5)";
    p.modules.push_back({"delay_a", delay, {}});
    p.modules.push_back({"delay_b", delay, {}});
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone", "delay_a", "delay_b"};
    p.layers.push_back(layer);
    const std::string result = e.setProject(p);
    CHECK(result.find("\"ok\":false") != std::string::npos);
    CHECK(result.find("project-state budget") != std::string::npos);
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
    p.modules.push_back({"tone", std::string(kFloat) + "sin(2*pi*freq*t)", {}});
    p.modules.push_back({"pattern", pattern, {}});
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone"};
    layer.pattern = "pattern";
    p.layers.push_back(layer);
    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 2000);
    CHECK(std::any_of(out.begin(), out.end(), [](float sample) { return std::abs(sample) > 1e-5f; }));
}

// Within one layer a module reads exports only from modules before it in the chain: those have
// run this chunk on every lane. A later (or its own) module is refused, so no import's delay
// depends on how chunks happen to be split.
TEST(module_reads_exports_only_from_earlier_modules_of_its_own_chain) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.modules.push_back({"gen", "---\nmode: float\n---\nexport let level = 0.25\n0.5", {}, "gen"});
    p.modules.push_back({"early", "---\nkind: effect\nmode: float\n---\nin + late.boost", {}, "early"});
    p.modules.push_back({"late", "---\nkind: effect\nmode: float\n---\nexport let boost = 1\nin + gen.level", {}, "late"});
    LayerSpec l;
    l.id = "t";
    l.chain = {"gen", "early", "late"};
    l.volume = 1.0;
    p.layers = {l};
    Engine e(48000);
    e.setMasterBypass(true);
    const std::string result = e.setProject(p);
    CHECK(result.find("'late.boost' comes from a later module in this layer's chain (it reads 0)") != std::string::npos);
    CHECK(result.find("'gen.level'") == std::string::npos);  // an earlier module's export is fine, no warning
    e.play();
    const std::vector<float> out = run(e, 4800);
    CHECK_NEAR(out[4799], 0.75 * std::cos(kPi / 4.0), 1e-6);  // 0.5 + 0 + 0.25
}

TEST(engine_routes_more_than_16_module_exports) {
    std::string source = "---\nmode: float\n---\n";
    for (int i = 0; i < 20; ++i)
        source += "export let value" + std::to_string(i) + " = " + std::to_string(i + 1) + "\n";
    source += "0";
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.modules.push_back({"source", source, {}, "src"});
    p.modules.push_back({"consumer", "---\nkind: effect\nmode: float\n---\nsrc.value19 / 20", {}});
    LayerSpec sourceLayer;
    sourceLayer.id = "source_track";
    sourceLayer.chain = {"source"};
    sourceLayer.volume = 1.0;
    LayerSpec consumerLayer;
    consumerLayer.id = "consumer_track";
    consumerLayer.chain = {"consumer"};
    consumerLayer.volume = 1.0;
    p.layers = {sourceLayer, consumerLayer};

    HardwareProfile hardware;
    hardware.memoryBudgetMiB = 16;
    Engine e(8000, makeEngineResourceBudget(hardware));
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 1024);
    CHECK_NEAR(out[out.size() - 2], std::cos(kPi / 4.0), 1e-3);
}

TEST(engine_rejects_export_layout_above_memory_budget) {
    std::string source = "---\nmode: float\n---\n";
    for (int i = 0; i < 20; ++i)
        source += "export let value" + std::to_string(i) + " = " + std::to_string(i + 1) + "\n";
    source += "1";
    ProjectSpec p;
    p.modules.push_back({"source", source, {}, "source"});
    LayerSpec layer;
    layer.id = "source_track";
    layer.chain = {"source"};
    p.layers.push_back(layer);
    HardwareProfile hardware;
    hardware.memoryBudgetMiB = 1;
    Engine e(8000, makeEngineResourceBudget(hardware));
    const std::string result = e.setProject(p);
    CHECK(result.find("\"ok\":false") != std::string::npos);
    // The layer is skipped (#133: refused per layer, before its slot is kept), and the result says why.
    CHECK(result.find("exports more values than one layer may hold") != std::string::npos);
}

TEST(engine_bounds_total_export_buffers_by_the_budget_across_layers) {
    // #133 (from #94): each layer may hold exportBuffersPerLayer() buffers, but the whole project
    // only exportBufferBudget(), so a project that uses the per-layer allowance on many layers is
    // refused before allocating past the budget, instead of using several times its memory.
    EngineResourceBudget budget;
    budget.graphWorkingBytes = 24ull << 20;
    budget.projectStateBytes = 64ull << 20;
    budget.compileWorkingBytes = 64ull << 20;
    budget.retirementBytes = 64ull << 20;
    budget.totalBytes = budget.graphWorkingBytes + budget.projectStateBytes + budget.compileWorkingBytes +
                        budget.retirementBytes;
    Engine e(8000, budget);
    const size_t perLayer = e.exportBuffersPerLayer();
    CHECK(perLayer > 0);
    CHECK_EQ(e.exportBufferBudget(), perLayer * static_cast<size_t>(kExportBudgetSlots));
    CHECK(e.maxLayers() > kExportBudgetSlots);
    std::string source = "---\nmode: float\n---\n";
    for (size_t i = 0; i < perLayer; ++i) source += "export let v" + std::to_string(i) + " = 1\n";
    source += "1";
    auto project = [&](int layers) {
        ProjectSpec p;
        p.modules.push_back({"wide", source, {}, "wide"});
        for (int l = 0; l < layers; ++l) {
            LayerSpec layer;
            layer.id = "t" + std::to_string(l);
            layer.chain = {"wide"};
            p.layers.push_back(layer);
        }
        return p;
    };
    // Exactly the budget: accepted.
    CHECK(e.setProject(project(kExportBudgetSlots)).find("\"ok\":true") != std::string::npos);
    // One layer more needs perLayer buffers past it: refused, naming the budget.
    const std::string over = e.setProject(project(kExportBudgetSlots + 1));
    CHECK(over.find("\"ok\":false") != std::string::npos);
    CHECK(over.find("export buffer budget") != std::string::npos);
    // Only that layer was skipped, and its slot was not kept: the fitting project still installs,
    // and the same refusal repeats instead of the slots running out.
    CHECK(e.setProject(project(kExportBudgetSlots)).find("\"ok\":true") != std::string::npos);
    const std::string again = e.setProject(project(kExportBudgetSlots + 1));
    CHECK(again.find("export buffer budget") != std::string::npos);
    CHECK(again.find("no free engine layer slot") == std::string::npos);
    // A playing layer whose new chain exports more than one layer may hold is stopped, not left
    // playing outside the plan (stale routing and exports).
    CHECK(e.setProject(project(kExportBudgetSlots)).find("\"ok\":true") != std::string::npos);
    ProjectSpec grown = project(kExportBudgetSlots);
    grown.modules.push_back({"extra", "---\nmode: float\n---\nexport let more = 1\n1", {}, "extra"});
    grown.layers[0].chain = {"wide", "extra"};
    const std::string stopped = e.setProject(grown);
    CHECK(stopped.find("\"ok\":false") != std::string::npos);
    CHECK(stopped.find("layer 't0' not installed: its chain exports more values than one layer may hold") != std::string::npos);
    CHECK(stopped.find("it was stopped") != std::string::npos);
}

TEST(routing_saturates_out_of_float_range_tracks_instead_of_silencing_the_mix) {
    // A runaway module can output finite doubles beyond float range. Routing carries float (F4.2),
    // so those samples must saturate at the largest float: inf (or NaN after a zero gain) would make
    // the master drop the whole mix. The limiter then holds the output near its ceiling.
    // Dropped samples show up as exact zeros where the master zeroed a non-finite mix.
    auto dropouts = [](const std::vector<float>& v, bool& finite) {
        int zeros = 0;
        finite = true;
        for (size_t i = 2400; i < v.size(); ++i) {
            if (!std::isfinite(v[i])) finite = false;
            if (v[i] == 0.0f) ++zeros;
        }
        return zeros;
    };
    ProjectSpec p = project({{"huge", std::string(kFloat) + "sine(220) * 1e39"}, {"ok", std::string(kFloat) + "sine(330) * 0.5"}});
    Engine e(48000);
    e.setProject(p);
    e.play();
    bool finite = false;
    CHECK_EQ(dropouts(run(e, 4800), finite), 0);
    CHECK(finite);
    // Inside a muted-by-gain folder (volume 0) the saturated value must give 0, not NaN, so the
    // root track still plays.
    ProjectSpec q = project({{"huge", std::string(kFloat) + "sine(220) * 1e39"}, {"ok", std::string(kFloat) + "sine(330) * 0.5"}});
    LayerSpec bus;
    bus.id = "bus"; bus.name = "bus"; bus.folder = true; bus.busEnabled = true; bus.volume = 0.0;
    q.layers.insert(q.layers.begin(), bus);
    q.layers[1].parentId = "bus";
    Engine f(48000);
    f.setProject(q);
    f.play();
    CHECK_EQ(dropouts(run(f, 4800), finite), 0);
    CHECK(finite);
}

TEST(track_removed_inside_folder_fades_out_like_a_root_track) {
    // Issue #76: a removed child kept its parent but was processed after the folder bus, so its fade
    // never reached the mix and it cut off with a step. It must fade like a removed root track.
    auto removalStep = [](bool inFolder) {
        ProjectSpec p = project({{"keep", std::string(kFloat) + "sine(110) * 0.2"},
                                 {"gone", std::string(kFloat) + "sine(220) * 0.5"}});
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
    ProjectSpec p = project({{"a", std::string(kFloat) + "sine(220) * 0.3"}, {"b", std::string(kFloat) + "sine(330) * 0.3"},
                             {"c", std::string(kFloat) + "sine(440) * 0.3"}});
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

namespace {
// One automated param g (0..2, step 0.25) with a flat lane at 0.25 (0.3 stepped).
ProjectSpec touchProject(const std::string& source = "param g = 0.5 in 0..2 step 0.25\ng", double stored = -1.0) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"tone", std::string(kFloat) + source, {}});
    if (stored >= 0.0) p.modules[0].params["g"] = stored;
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone"};
    layer.volume = 1.0;
    p.layers.push_back(layer);
    ProjectAutomationLaneSpec lane;
    lane.targetType = "param";
    lane.moduleId = "tone";
    lane.target = "g";
    lane.points = {{0.0, 0.3}};
    p.automation.push_back(lane);
    return p;
}
}  // namespace

TEST(engine_param_moved_while_stopped_is_not_a_touch_after_play) {
    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(touchProject()).find("\"ok\":true") != std::string::npos);
    e.play();
    const double lane = run(e, 512).back();
    CHECK(lane > 0.05);
    e.stop();
    run(e, 4096);
    e.setParam("tone", "g", 0.8);
    e.play();  // a (re)start: the lane rules
    CHECK_NEAR(run(e, 512).back() / lane, 1.0, 1e-4);
}

TEST(engine_param_restore_is_not_a_touch_but_a_rebuild_keeps_one) {
    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(touchProject()).find("\"ok\":true") != std::string::npos);
    e.play();
    const double lane = run(e, 512).back();
    CHECK(lane > 0.05);
    // A project update that stores another value is a restore, not a knob move: the lane still rules.
    CHECK(e.setProject(touchProject("param g = 0.5 in 0..2 step 0.25\ng", 1.0)).find("\"ok\":true") != std::string::npos);
    CHECK_NEAR(run(e, 512).back() / lane, 1.0, 1e-4);
    // A touch survives a code edit that rebuilds the chain (the stored value follows the knob).
    e.setParam("tone", "g", 0.8);
    CHECK_NEAR(run(e, 512).back() / lane, 3.0, 1e-4);
    CHECK(e.setProject(touchProject("param g = 0.5 in 0..2 step 0.25\ng + 0", 0.8)).find("\"ok\":true") != std::string::npos);
    CHECK_NEAR(run(e, 8192).back() / lane, 3.0, 1e-4);
    e.play();
    CHECK_NEAR(run(e, 512).back() / lane, 1.0, 1e-4);
}

TEST(engine_param_touch_overrides_automation_until_playback_restarts) {
    // F6.6: the Engine's .caw params resolve through the shared parameter model (owner, 2026-11-04).
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"tone", std::string(kFloat) + "param g = 0.5 in 0..2 step 0.25\ng", {}});
    LayerSpec layer;
    layer.id = "track";
    layer.chain = {"tone"};
    layer.volume = 1.0;
    p.layers.push_back(layer);
    ProjectAutomationLaneSpec lane;
    lane.targetType = "param";
    lane.moduleId = "tone";
    lane.target = "g";
    lane.points = {{0.0, 0.3}};  // stepped to 0.25
    p.automation.push_back(lane);
    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    // Compared with the lane's level, so the layer's gain and pan law cancel out.
    const double lane025 = run(e, 512).back();
    CHECK(lane025 > 0.05);
    e.setParam("tone", "g", 0.8);  // a touch: the manual value (stepped to 0.75) wins over the lane
    CHECK_NEAR(run(e, 512).back() / lane025, 3.0, 1e-4);
    CHECK_NEAR(run(e, 512).back() / lane025, 3.0, 1e-4);
    e.play();  // playback restarts: the lane rules again
    CHECK_NEAR(run(e, 512).back() / lane025, 1.0, 1e-4);
}

TEST(engine_param_moved_right_after_play_is_a_touch) {
    // The knob moves before the audio thread has handled the Play command: still a touch.
    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(touchProject()).find("\"ok\":true") != std::string::npos);
    e.play();
    const double lane = run(e, 512).back();
    CHECK(lane > 0.05);
    e.play();
    e.setParam("tone", "g", 0.8);
    CHECK_NEAR(run(e, 512).back() / lane, 3.0, 1e-4);
}

// ---- F7.3 part B: the Engine grows past 64 layers, bounded by the memory budget ----

namespace {

// n layers, each playing `module` (one shared module), named g0..g(n-1).
ProjectSpec layersOf(int n, const std::string& source, double volume = 1.0) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.modules.push_back({"tone", source, {}});
    for (int i = 0; i < n; ++i) {
        LayerSpec l;
        l.id = "g" + std::to_string(i);
        l.name = l.id;
        l.chain = {"tone"};
        l.volume = volume;
        p.layers.push_back(l);
    }
    return p;
}

}  // namespace

TEST(engine_plays_more_than_64_layers_with_meters_and_folder_buses_above_slot_64) {
    for (int n : {65, 200}) {
        // A folder bus first (slot 0), then n tracks; tracks from project index 64 on route through
        // the bus, so the bus sums children whose slots are 64 and above.
        ProjectSpec p = layersOf(n, std::string(kFloat) + "0.0001");
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
        const std::string id = "s" + std::to_string(i);
        small.modules.push_back({id, std::string(kFloat) + "sine(" + std::to_string(110 * (i + 1)) + ") * 0.05", {}});
        LayerSpec l;
        l.id = "l" + std::to_string(i);
        l.chain = {id};
        l.volume = 0.8;
        l.pan = -0.5 + 0.1 * i;
        small.layers.push_back(l);
    }
    ProjectSpec big = small;
    big.modules.push_back({"loud", std::string(kFloat) + "sine(77) * 0.5", {}});
    for (int i = 10; i < 100; ++i) {
        LayerSpec l;
        l.id = "l" + std::to_string(i);
        l.chain = {"loud"};
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
    CHECK(e.setProject(layersOf(64, std::string(kFloat) + "0.001")).find("\"ok\":true") != std::string::npos);
    const std::string refused = e.setProject(layersOf(65, std::string(kFloat) + "0.001"));
    CHECK(refused.find("\"ok\":false") != std::string::npos);
    CHECK(refused.find("project has 65 layers; this device's memory budget allows at most 64") != std::string::npos);
    CHECK_EQ(e.layerCapacity(), 64);
    // The refused project changed nothing: the 64 layers play on.
    e.play();
    const auto out = run(e, 800);
    CHECK_NEAR(out[799], 64 * 0.001 * std::cos(kPi / 4.0), 1e-5);
    // The 128 MiB fallback budget (memory unknown) allows more than 64.
    Engine big(8000, makeEngineResourceBudget(HardwareProfile{}));
    CHECK(big.maxLayers() > 64);
}

TEST(engine_play_with_more_than_640_layers_retires_every_chain_without_stalling) {
    // Play retires up to two chains per slot (the one fading out after a swap and the one a
    // pending swap replaces): 2 * 701 entries, more than the retired queue holds at once.
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
    ProjectSpec p = layersOf(700, std::string(kFloat) + "0.00001");
    CHECK(apply(p).find("\"ok\":true") != std::string::npos);
    CHECK(e.layerCapacity() >= 700);
    e.play();
    for (int k = 0; k < 4; ++k) e.process(l.data(), r.data(), 64);
    CHECK_NEAR(l[63], 700 * 0.00001 * std::cos(kPi / 4.0), 1e-5);
    p.modules[0].source = std::string(kFloat) + "0.00002";  // swapped at once: every slot has a chain fading out
    CHECK(apply(p).find("\"ok\":true") != std::string::npos);
    p.swapMode = 2;
    p.modules[0].source = std::string(kFloat) + "0.00003";  // waits for the next bar: every slot has a pending chain
    CHECK(apply(p).find("\"ok\":true") != std::string::npos);
    CHECK(e.meters().position > 0);
    e.play();
    e.process(l.data(), r.data(), 0);
    CHECK_EQ(e.meters().position, 0);  // the Play was applied in the first callback: it did not wait for room
    for (int k = 0; k < 20; ++k) {
        e.process(l.data(), r.data(), 64);
        e.meters();  // drains the retired queue, so the overflow moves across
    }
    CHECK_NEAR(l[63], 700 * 0.00003 * std::cos(kPi / 4.0), 1e-5);  // the pending code took over at Play
    CHECK_EQ(e.routingRejections(), 0u);
}

TEST(engine_export_buffers_stay_valid_across_a_grow) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.modules.push_back({"src", "---\nmode: float\n---\nexport let level = 0.25\n0", {}, "src"});
    p.modules.push_back({"reader", "---\nmode: float\n---\nsrc.level", {}, "reader"});
    LayerSpec a;
    a.id = "a";
    a.chain = {"src"};
    a.volume = 1.0;
    LayerSpec b = a;
    b.id = "b";
    b.chain = {"reader"};
    p.layers = {a, b};
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    CHECK_NEAR(run(e, 960).back(), 0.25 * std::cos(kPi / 4.0), 1e-6);
    // Grow to 100 layers: 96 muted fillers, then an exporter and a reader in slots above 64.
    p.modules.push_back({"filler", std::string(kFloat) + "0.5", {}, "filler"});
    p.modules.push_back({"hi", "---\nmode: float\n---\nexport let level = 0.125\n0", {}, "hi"});
    p.modules.push_back({"hireader", "---\nmode: float\n---\nhi.level + src.level", {}, "hireader"});
    for (int i = 0; i < 96; ++i) {
        LayerSpec f = a;
        f.id = "f" + std::to_string(i);
        f.chain = {"filler"};
        f.mute = true;
        p.layers.push_back(f);
    }
    LayerSpec hi = a;
    hi.id = "hi";
    hi.chain = {"hi"};
    LayerSpec hr = a;
    hr.id = "hr";
    hr.chain = {"hireader"};
    p.layers.push_back(hr);  // slot 98 reads slot 99, so the order puts the exporter first
    p.layers.push_back(hi);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    CHECK(e.layerCapacity() >= 100);
    // The old reader still reads the old exporter's buffer, and the new pair works too.
    CHECK_NEAR(run(e, 960).back(), (0.25 + 0.375) * std::cos(kPi / 4.0), 1e-6);
    // Moving the reader's source keeps working after the grow (the wiring is rebuilt).
    p.modules[1].source = "---\nmode: float\n---\nsrc.level + hi.level";
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    CHECK_NEAR(run(e, 4800).back(), (0.375 + 0.375) * std::cos(kPi / 4.0), 1e-6);
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
    ProjectSpec p = layersOf(10, std::string(kFloat) + "0.001");
    p.modules.push_back({"aud", std::string(kFloat) + "0.5", {}});
    p.auditionChain = {"aud"};
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
    ProjectSpec big = layersOf(150, std::string(kFloat) + "0.001");
    big.modules.push_back(p.modules.back());
    big.auditionChain = {"aud"};
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
// A layer playing an empty pattern through a tone that outputs gate * vel * note / 128, so the level shows which
// pitch and velocity are held (and a sum of two voices would show as a jump).
ProjectSpec previewProject() {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.seamCrossfade = false;
    p.modules.push_back({"tone", std::string(kFloat) + "gate * vel * note / 128", {}});
    p.modules.push_back({"phrase", "---\nkind: pattern\nlength: 16\n---\n", {}});
    p.modules.push_back({"drone", std::string(kFloat) + "0.25", {}});
    LayerSpec layer;
    layer.id = "track";
    layer.name = "Track";
    layer.chain = {"tone"};
    layer.pattern = "phrase";
    layer.volume = 1.0;
    p.layers.push_back(layer);
    LayerSpec free;  // no pattern: it can't preview
    free.id = "free";
    free.name = "Free";
    free.chain = {"drone"};
    free.volume = 1.0;
    free.mute = true;
    p.layers.push_back(free);
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
    CHECK_NEAR(held.back(), 0.5 * 64 / 128.0 * pan, 1e-4);
    CHECK_EQ(e.meters().position, 0);  // the transport stays where it was
    e.noteOff(7);
    const std::vector<float> after = run(e, 4800);
    CHECK_NEAR(after.back(), 0.0, 1e-6);
    CHECK_EQ(e.meters().playing, false);
    // A preview on a layer without a pattern does nothing.
    e.noteOn("free", 8, 60, 1);
    CHECK_NEAR(run(e, 2400).back(), 0.0, 1e-9);
}

TEST(a_held_preview_glides_to_a_new_pitch_and_the_same_id_retriggers_instead_of_stacking) {
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(previewProject());
    const double pan = std::cos(kPi / 4.0);
    e.noteOn("track", 1, 60, 1);
    CHECK_NEAR(run(e, 2400).back(), 60 / 128.0 * pan, 1e-4);
    e.notePitch(1, 72);  // a bend being drawn: the same voice, a 5 ms glide
    CHECK_NEAR(run(e, 2400).back(), 72 / 128.0 * pan, 1e-4);
    e.noteOn("track", 1, 48, 1);  // the same id again: the old note ends, one voice sounds
    CHECK_NEAR(run(e, 4800).back(), 48 / 128.0 * pan, 1e-4);
    e.noteOn("track", 2, 50, 1);  // another id: a chord
    CHECK_NEAR(run(e, 2400).back(), (48 + 50) / 128.0 * pan, 1e-4);
    e.notesOff();
    CHECK_NEAR(run(e, 4800).back(), 0.0, 1e-6);
}

TEST(after_stop_a_preview_hears_neither_the_chord_that_was_playing_nor_a_jump_back_to_full_level) {
    Engine e(48000);
    e.setMasterBypass(true);
    ProjectSpec p = previewProject();
    p.modules[1].source = "---\nkind: pattern\nlength: 16\n---\n0 C4 16\n";  // a note held through the loop
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    const double pan = std::cos(kPi / 4.0);
    e.play();
    CHECK_NEAR(run(e, 2400).back(), 60 / 128.0 * pan, 1e-4);
    // A preview held across Stop: the stop fades out, then the preview alone fades back in, with no step.
    e.noteOn("track", 1, 72, 1);
    run(e, 2400);
    e.stop();
    const std::vector<float> across = run(e, 4800);
    float step = 0;
    for (size_t i = 1; i < across.size(); ++i) step = std::max(step, std::fabs(across[i] - across[i - 1]));
    CHECK(step < 0.01f);
    CHECK_NEAR(across.back(), 72 / 128.0 * pan, 1e-4);  // the pattern's C4 doesn't come back
    e.noteOff(1);
    CHECK_NEAR(run(e, 4800).back(), 0.0, 1e-6);
    e.noteOn("track", 2, 48, 1);  // a fresh preview while stopped: only its own note
    CHECK_NEAR(run(e, 2400).back(), 48 / 128.0 * pan, 1e-4);
    e.notesOff();
}

TEST(a_preview_held_across_play_keeps_its_instrument_running) {
    Engine e(48000);
    e.setMasterBypass(true);
    ProjectSpec p = previewProject();
    p.modules[0].source = std::string(kFloat) + "gate * lpf(0.5, 4, 0.7)";  // a slow rise that a reset would restart
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.noteOn("track", 1, 60, 1);
    std::vector<float> out = run(e, 4801);
    e.play();
    const std::vector<float> playing = run(e, 4800);
    out.insert(out.end(), playing.begin(), playing.end());
    float step = 0;
    for (size_t i = 2400; i < out.size(); ++i) step = std::max(step, std::fabs(out[i] - out[i - 1]));
    CHECK(step < 0.001f);  // the filter rises smoothly; a reset would drop it to 0
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
    CHECK_NEAR(run(e, 9600).back(), 0.5 * 64 / 128.0 * pan, 1e-3);
    e.noteOff(1);
    e.play();
    run(e, 2400);
    e.noteOn("track", 2, 32, 1);  // while playing: heard, and the empty pattern adds nothing
    CHECK_NEAR(run(e, 4800).back(), 0.5 * 32 / 128.0 * pan, 1e-3);
    CHECK(e.meters().position > 0);
}
