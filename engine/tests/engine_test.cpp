// Mixer tests: block-size independence, per-layer loop lengths, hot swap, broken code, mute/solo, overload, stop.
#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "detmath.h"
#include "engine.h"
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
    const std::string bounded = R"({"caw_project":1,"beats_per_bar":3,"layers":[
      {"id":"g","folder":true,"automation":[{"target":"volume","points":[{"step":5000,"value":0.5}]}]},
      {"id":"t","parent":"g","clips":[{"id":"c","pattern":"p","start_steps":5000,"length_steps":20}]}
    ]})";
    ProjectSpec boundedProject;
    CHECK(parseProject(bounded, boundedProject, error));
    CHECK_EQ(boundedProject.layers[1].clips[0].startSteps, 767);
    CHECK_EQ(boundedProject.layers[1].clips[0].lengthSteps, 1);
    CHECK_NEAR(boundedProject.layers[0].automation[0].points[0].step, 768, 1e-9);
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
    for (int i = 0; i < kMaxLayers; ++i) {
        many.modules.push_back({"m" + std::to_string(i), std::string(kFloat) + "0.001", {}});
        LayerSpec l;
        l.id = "x" + std::to_string(i);
        l.chain = {"m" + std::to_string(i)};
        many.layers.push_back(l);
    }
    e.setProject(many);
    run(e, 100);
    LayerMeter lm;
    CHECK(e.layerMeter(kMaxLayers - 1, lm) && lm.active);
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


TEST(project_parser_clamps_clips_to_the_meter_aware_song_limit) {
    const std::string json = R"({"caw_project":1,"beats_per_bar":3,"loop_bars":64,"layers":[
      {"id":"t","clips":[{"id":"c","pattern":"p","start_steps":760,"length_steps":64,"source_offset_steps":900}]}
    ]})";
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(json, p, error));
    CHECK_EQ(p.layers[0].clips.size(), size_t{1});
    CHECK_EQ(p.layers[0].clips[0].startSteps, 760);
    CHECK_EQ(p.layers[0].clips[0].lengthSteps, 8);
    CHECK_EQ(p.layers[0].clips[0].sourceOffsetSteps, 768);
}
