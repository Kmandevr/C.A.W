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
