// Mixer tests: project-state budgets, automation and note capacity, and more than 64 layers.
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
