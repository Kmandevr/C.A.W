// Real-time checks on the whole Engine and its parameter resolver: the audio path never allocates or frees.
#include <cstring>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "capi_internal.h"
#include "engine.h"
#include "native_component_test_path.h"
#include "params.h"
#include "test.h"

using namespace caw;

namespace {
std::string templateSource(const char* file) {
    for (int i = 0; i < kTemplateCount; ++i)
        if (std::strcmp(kTemplateFiles[i], file) == 0) return kTemplateSources[i];
    return {};
}

LayerSpec layer(const std::string& id, std::vector<std::string> chain) {
    LayerSpec l;
    l.id = id;
    l.name = id;
    l.chain = std::move(chain);
    return l;
}
}  // namespace

TEST(engine_process_never_allocates_through_seams_and_code_swaps) {
    ProjectSpec p;
    p.bpm = 140;
    p.loopBars = 1;
    for (const char* file : {"bass.caw", "acid-synth.caw", "bytebeat-loop.caw", "fold.caw", "glitch-fx.caw",
                             "bitcrush.caw", "acid-line.caw"}) {
        std::string id(file);
        id.resize(id.size() - 4);
        p.modules.push_back({id, templateSource(file), {}});
    }
    p.layers = {layer("b", {"bass", "fold", "glitch-fx"}), layer("a", {"acid-synth", "bitcrush"}),
                layer("y", {"bytebeat-loop", "fold"})};
    p.layers[1].pattern = "acid-line";
    p.layers[2].lengthSteps = 3;  // a seam crossfade every 3 sixteenths
    Engine e(48000);
    e.setProject(p);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 250; ++k) e.process(l.data(), r.data(), 192);  // warm up: one second
    // New code with different chain lengths, swapped in at once: the old chains fade on their lane.
    p.layers[0].chain = {"bass"};
    p.layers[1].chain = {"acid-synth", "glitch-fx", "fold"};
    p.layers[2].chain = {"bytebeat-loop", "bitcrush", "glitch-fx", "fold"};
    e.setProject(p);
    std::size_t operations = 0;
    float peak = 0.0f;
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 500; ++k) {  // two seconds: loop wraps, seams, the swap and its retirement
            e.process(l.data(), r.data(), 192);
            for (float v : l) peak = v > peak ? v : peak;
        }
        operations = scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
    CHECK_EQ(e.routingRejections(), 0u);
}

TEST(engine_grow_never_allocates_or_frees_on_the_audio_thread) {
    // Ten layers play; the project grows to 100 (a new slot table and mix graph, built on the
    // control thread). Swapping them in, and retiring the old ones, must not allocate or free.
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"bass", templateSource("bass.caw"), {}});
    p.modules.push_back({"fold", templateSource("fold.caw"), {}});
    for (int i = 0; i < 10; ++i) p.layers.push_back(layer("l" + std::to_string(i), {"bass", "fold"}));
    Engine e(48000);
    e.setProject(p);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 50; ++k) e.process(l.data(), r.data(), 192);
    for (int i = 10; i < 100; ++i) p.layers.push_back(layer("l" + std::to_string(i), {"bass"}));
    e.setProject(p);
    CHECK(e.layerCapacity() >= 100);
    std::size_t operations = 0;
    float peak = 0.0f;
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 100; ++k) {
            e.process(l.data(), r.data(), 192);
            for (float v : l) peak = v > peak ? v : peak;
        }
        operations = scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
    LayerMeter lm;
    CHECK(e.layerMeter(99, lm) && lm.active);
    CHECK_EQ(e.routingRejections(), 0u);
}

TEST(parameter_resolver_never_allocates_on_the_audio_thread) {
    ParameterDescriptor p;
    p.id = "cutoff";
    p.defaultValue = 1000.0;
    p.minimum = 20.0;
    p.maximum = 20000.0;
    p.curve = ParameterCurve::Exponential;
    p.step = 0.5;
    p.smoothingFrames = 48;
    ParameterResolver r;
    CHECK(r.configure(p));
    const ModulationLink links[] = {{1, ModulationOp::Add, 0.25}, {2, ModulationOp::Multiply, 0.5}};
    CHECK(r.setLinks(links, 2));
    float lfo[64], env[64];
    double lane[64], out[64];
    for (int i = 0; i < 64; ++i) {
        lfo[i] = static_cast<float>(i) / 64.0f;
        env[i] = 1.0f - lfo[i];
        lane[i] = 100.0 + i;
    }
    const float* signals[] = {lfo, env};
    double sum = 0.0;
    std::size_t operations = 0;
    {
        cawtest::AllocationScope scope;
        r.setBase(5000.0);
        for (int block = 0; block < 4; ++block) {
            sum += r.resolve(64, nullptr, signals, out).value;
            sum += r.resolve(64, block % 2 ? lane : nullptr, nullptr, out).value;
            r.clearTouch();
        }
        operations = scope.count();
    }
    CHECK(sum > 0.0);
    CHECK_EQ(operations, 0u);
}

TEST(note_previews_never_allocate_on_the_audio_thread_playing_or_stopped) {
    ProjectSpec p;
    p.bpm = 140;
    p.loopBars = 1;
    for (const char* file : {"acid-synth.caw", "bitcrush.caw", "acid-line.caw"}) {
        std::string id(file);
        id.resize(id.size() - 4);
        p.modules.push_back({id, templateSource(file), {}});
    }
    p.layers = {layer("a", {"acid-synth", "bitcrush"})};
    p.layers[0].pattern = "acid-line";
    Engine e(48000);
    e.setProject(p);
    std::vector<float> l(192), r(192);
    // The control-side map grows here, off the audio thread.
    for (int id = 0; id < 8; ++id) e.noteOn("a", id, 48 + id, 0.8);
    e.notesOff();
    double sum = 0.0;
    std::size_t operations = 0;
    for (int pass = 0; pass < 2; ++pass) {
        if (pass == 1) e.play();
        e.noteOn("a", 1, 50, 0.8);
        e.noteOn("a", 2, 57, 0.8);
        e.notePitch(2, 59);
        // Held, then released (the offs are control-thread calls, outside the measured audio path).
        for (int half = 0; half < 2; ++half) {
            if (half == 1) {
                e.noteOff(1);
                e.noteOff(2);
            }
            cawtest::AllocationScope scope;
            for (int k = 0; k < 50; ++k) {
                e.process(l.data(), r.data(), 192);
                for (float v : l) sum += std::fabs(v);
            }
            operations += scope.count();
        }
    }
    CHECK(sum > 0.0);
    CHECK_EQ(operations, 0u);
}

TEST(engine_process_never_allocates_with_native_inserts_and_live_parameter_changes) {
    const char* path = caw::test::nativeComponentPath();
    CHECK(path != nullptr);
    if (!path) return;
    Engine e(48000);
    const char* gain = "org.caw.tests.native-loader.gain";
    CHECK(e.loadNativeComponent(path, gain, NativeModuleTrust::Trusted).success);
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"bass", templateSource("bass.caw"), {}});
    p.layers = {layer("b", {"bass"})};
    p.layers[0].components = {{gain, {{"left", 2.0}}}};
    p.masterComponents = {{gain, {{"right", 0.5}}}};
    ProjectAutomationLaneSpec lane;  // a lane on the track's component: resolved per sample
    lane.targetType = "component";
    lane.moduleId = "b";
    lane.component = 0;
    lane.target = "right";
    lane.points = {{0, 0.0}, {8, 2.0}, {16, 0.5}};
    p.automation.push_back(lane);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 50; ++k) e.process(l.data(), r.data(), 192);
    std::size_t operations = 0;
    for (int round = 0; round < 10; ++round) {
        e.setComponentParam("b", 0, "left", 0.5 + 0.1 * round);  // control thread, outside the count
        e.setComponentParam("", 0, "right", 0.1 * round);
        e.setComponentBypass("b", 0, round % 2 == 1);  // crossfades in and out on the audio thread
        if (round == 5) {
            p.automation[0].points = {{0, 1.0}};  // a new lane table, swapped in and the old one retired
            e.setProject(p);
        }
        cawtest::AllocationScope scope;
        for (int k = 0; k < 20; ++k) e.process(l.data(), r.data(), 192);  // the ramps run in here
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
}
