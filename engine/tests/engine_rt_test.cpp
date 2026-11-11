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
    p.layers[0].components = {{gain, {{"left", 2.0}}}, {"org.caw.distortion", {{"shape", 2}}},
                              {"org.caw.delay.pingpong", {{"sync", 2}}}, {"org.caw.stereo.width", {{"width", 1.5}}}};
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

TEST(publishing_and_reading_display_data_never_allocates) {
    // #173: the fixture's gain component publishes display data every block; reading it through the Engine (as
    // the UI does) and publishing it on the audio thread must neither allocate nor free.
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
    p.layers[0].components = {{gain, {}}};
    p.masterComponents = {{gain, {}}};
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 20; ++k) e.process(l.data(), r.data(), 192);
    float out[16];
    int32_t got = 0;
    std::size_t operations = 0;
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 100; ++k) {
            e.process(l.data(), r.data(), 192);
            got += e.componentDisplay("b", 0, out, 16) + e.componentDisplay("", 0, out, 16);
        }
        operations = scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK_EQ(got, 400);
}

TEST(the_built_in_effects_suite_never_allocates_on_the_audio_thread) {
    // #173: every effect of the suite on a track (and the limiter on the master), at busy settings, with knob moves,
    // display reads, a stop and a restart: no allocation or free on the audio thread.
    const char* ids[] = {"org.caw.eq",       "org.caw.compressor", "org.caw.reverb.pro", "org.caw.delay.pro",
                         "org.caw.saturator", "org.caw.gate",      "org.caw.transient",  "org.caw.filter",
                         "org.caw.phaser",    "org.caw.flanger",   "org.caw.utility"};
    ProjectSpec p;
    p.bpm = 128;
    p.loopBars = 1;
    p.modules.push_back({"bass", templateSource("bass.caw"), {}});
    p.layers = {layer("b", {"bass"})};
    for (const char* id : ids) p.layers[0].components.push_back({id, {}});
    p.layers[0].components[0].params = {{"b4_gain", 6}, {"b1_on", 1}, {"b1_type", 5}};
    p.layers[0].components[3].params = {{"mode", 1}, {"freeze", 0}};
    p.masterComponents = {{"org.caw.limiter", {{"gain", 6}}}};
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 100; ++k) e.process(l.data(), r.data(), 192);
    std::size_t operations = 0;
    float shown[1024];
    for (int round = 0; round < 6; ++round) {
        e.setComponentParam("b", 0, "b4_freq", 300 + 400 * round);
        e.setComponentParam("b", 0, "b2_type", round);
        e.setComponentParam("b", 2, "freeze", round % 2);
        e.setComponentParam("b", 3, "sync", round);
        e.setComponentParam("b", 4, "mode", round % 6);
        e.setComponentParam("b", 7, "type", round);
        if (round == 4) e.stop();
        if (round == 5) e.play();
        cawtest::AllocationScope scope;
        for (int k = 0; k < 60; ++k) {
            e.process(l.data(), r.data(), 192);
            for (uint32_t i = 0; i < 11; ++i) e.componentDisplay("b", i, shown, 1024);
            e.componentDisplay("", 0, shown, 1024);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
}

TEST(a_native_instrument_never_allocates_on_the_audio_thread) {
    // The built-in synth plays a pattern (loop wraps, a slide, a ratchet, chords) through a .caw effect and a
    // native delay; mid-way it is swapped for another instrument (its held notes move over), previews play and
    // it is stopped: the audio thread must not allocate or free through any of it.
    ProjectSpec p;
    p.bpm = 160;
    p.loopBars = 1;
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n0 C3 4 1\n0 G3 4 1\n4 D3 2 1 slide\n"
                                "6 F3 2 1\n8 A3 4 1 ratchet 4\n12 C4 4 1\n", {}});
    p.modules.push_back({"fold", templateSource("fold.caw"), {}});
    LayerSpec l = layer("s", {"fold"});
    l.pattern = "pat";
    l.hasInstrument = true;
    l.instrument.id = "org.caw.synth.flagship";
    l.components = {{"org.caw.delay.pingpong", {}}};
    p.layers = {l, layer("t", {})};
    p.layers[1].pattern = "pat";
    p.layers[1].hasInstrument = true;
    p.layers[1].instrument.id = "org.caw.synth.flagship";
    Engine e(48000);
    const char* path = caw::test::nativeComponentPath();
    const bool recorder = path && e.loadNativeComponent(path, "org.caw.tests.native-loader.recorder", NativeModuleTrust::Trusted).success;
    CHECK(recorder);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l2(192), r2(192);
    for (int k = 0; k < 250; ++k) e.process(l2.data(), r2.data(), 192);  // warm up
    if (recorder) p.layers[1].instrument.id = "org.caw.tests.native-loader.recorder";
    p.layers[0].instrument.params = {{"flt1_cutoff", 800}};
    e.setProject(p);
    e.noteOn("s", 1, 64, 1);
    e.setComponentParam("s", Engine::kInstrumentIndex, "resonance", 0.8);
    std::size_t operations = 0;
    float peak = 0.0f;
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 500; ++k) {
            e.process(l2.data(), r2.data(), 192);
            for (float v : l2) peak = v > peak ? v : peak;
        }
        operations = scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
    e.noteOff(1);
    e.stop();
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 250; ++k) e.process(l2.data(), r2.data(), 192);  // the stop, the release tails
        operations = scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK_EQ(e.routingRejections(), 0u);
}

TEST(the_built_in_instruments_never_allocate_on_the_audio_thread) {
    // Every built-in instrument (#157), and Flagship with each retired synth's preset, on its own track plays a dense pattern (drum keys, chords, a slide, a
    // ratchet), takes knob moves and previews, and stops: no allocation or free on the audio thread.
    ProjectSpec p;
    p.bpm = 150;
    p.loopBars = 1;
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n0 C2 2 1\n0 F#2 1 0.7\n2 A#2 2 0.8\n"
                                "4 D2 2 1 slide\n4 D#2 1 1\n6 A1 2 0.9\n8 E2 4 1 ratchet 4\n8 C4 4 0.7\n8 E4 4 0.7\n"
                                "12 G#2 2 0.6\n12 B1 4 1\n", {}});
    const char* ids[] = {"org.caw.drum.kick", "org.caw.drum.snare", "org.caw.drum.hats", "org.caw.drum.kit",
                         "org.caw.bass",      "org.caw.synth.acid", "org.caw.synth.morph", "org.caw.synth.flagship",
                         "org.caw.synth.basic"};
    for (const char* id : ids) {
        LayerSpec l = layer(id, {});
        l.pattern = "pat";
        l.hasInstrument = true;
        l.instrument.id = id;
        p.layers.push_back(l);
    }
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 250; ++k) e.process(l.data(), r.data(), 192);  // warm up
    std::size_t operations = 0;
    float peak = 0.0f;
    for (int round = 0; round < 5; ++round) {
        // The retired synths' tracks play Flagship presets (the layers keep the old ids as their names).
        e.setComponentParam("org.caw.synth.morph", Engine::kInstrumentIndex, "osc1_unison", 1 + 3 * round);
        e.setComponentParam("org.caw.synth.acid", Engine::kInstrumentIndex, "flt1_cutoff", 300 + 200 * round);
        e.setComponentParam("org.caw.bass", Engine::kInstrumentIndex, "voice_mode", round % 3);
        e.setComponentParam("org.caw.drum.hats", Engine::kInstrumentIndex, "mode", round % 3);
        // The flagship: more copies, every filter type, the oscillators and effects switched on as it plays.
        e.setComponentParam("org.caw.synth.flagship", Engine::kInstrumentIndex, "osc1_unison", 1 + 3 * round);
        e.setComponentParam("org.caw.synth.flagship", Engine::kInstrumentIndex, "flt1_type", 2 * round);
        e.setComponentParam("org.caw.synth.flagship", Engine::kInstrumentIndex, "osc2_on", round % 2);
        e.setComponentParam("org.caw.synth.flagship", Engine::kInstrumentIndex, "fx_delay_on", round % 2);
        e.setComponentParam("org.caw.synth.flagship", Engine::kInstrumentIndex, "fx_chorus_on", 1);
        e.setComponentParam("org.caw.synth.flagship", Engine::kInstrumentIndex, "mod2_src", round + 3);
        e.setComponentParam("org.caw.synth.flagship", Engine::kInstrumentIndex, "mod2_dst", 3);
        e.setComponentParam("org.caw.synth.flagship", Engine::kInstrumentIndex, "mod2_amt", 0.5);
        e.noteOn("org.caw.synth.flagship", 200 + round, 60 + round, 1);
        e.noteOn("org.caw.bass", 100 + round, 40 + round, 1);
        cawtest::AllocationScope scope;
        for (int k = 0; k < 100; ++k) {
            e.process(l.data(), r.data(), 192);
            for (float v : l) peak = v > peak ? v : peak;
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
    e.notesOff();
    e.stop();
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 250; ++k) e.process(l.data(), r.data(), 192);  // the stop, the release tails
        operations = scope.count();
    }
    CHECK_EQ(operations, 0u);
}

TEST(drums_never_allocate_on_the_audio_thread) {
    // org.caw.drums with a full kit (glue, drive, room), a pad with every layer on and a sample, plays a busy
    // pattern while knobs move, the quality changes, its sample is swapped and previews play: no allocation or free.
    ProjectSpec p;
    p.bpm = 150;
    p.loopBars = 1;
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n0 C2 1 1\n0 F#2 1 0.8\n1 F#2 1 0.5\n"
                                "2 E3 1 0.9\n3 F#2 1 0.6\n4 D2 1 1\n4 D#2 1 0.8\n5 A#2 1 0.7\n6 C#3 1 0.9\n7 G2 1 0.7\n"
                                "8 C2 1 1\n8 E3 2 1\n10 D#3 1 0.8\n11 B2 1 0.7\n12 D2 1 1\n13 A2 1 0.7\n14 C3 1 0.8\n15 F#2 1 0.6\n", {}});
    LayerSpec l = layer("drums", {});
    l.pattern = "pat";
    l.hasInstrument = true;
    l.instrument.id = "org.caw.drums";
    // Pad B1 (E3 = 52): every layer, the effects, a built-in sample.
    l.instrument.params = {{"glue", 0.5}, {"kit_drive_type", 1}, {"room", 0.3}, {"b1_type", 13}, {"b1_body_on", 1},
                           {"b1_click_on", 1}, {"b1_noise_on", 1}, {"b1_noise_mode", 1}, {"b1_metal_on", 1},
                           {"b1_metal_mode", 1}, {"b1_res_on", 1}, {"b1_smp_on", 1}, {"b1_drive_type", 1},
                           {"b1_flt", 2}, {"b1_eq_low", 3}, {"b1_tr_attack", 0.5}, {"b1_comp", 0.5}, {"b1_rnd_pitch", 30},
                           {"b1_poly", 4}, {"b1_level", -6}};
    l.instrument.samples = {{16, "", "Clap"}};
    p.layers.push_back(l);
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> L(192), R(192);
    for (int k = 0; k < 250; ++k) e.process(L.data(), R.data(), 192);  // warm up
    std::size_t operations = 0;
    float peak = 0.0f;
    for (int round = 0; round < 6; ++round) {
        e.setQuality(round % 3);
        e.setComponentParam("drums", Engine::kInstrumentIndex, "a1_body_decay", 0.2 + 0.3 * round);
        e.setComponentParam("drums", Engine::kInstrumentIndex, "b1_metal_mode", round % 3);
        e.setComponentParam("drums", Engine::kInstrumentIndex, "b1_res_model", round % 6);
        e.setComponentParam("drums", Engine::kInstrumentIndex, "a7_metal_open", 0.2 * round);
        e.setComponentParam("drums", Engine::kInstrumentIndex, "a1_punch", round % 2 ? 0.8 : -0.5);
        e.setComponentParam("drums", Engine::kInstrumentIndex, "view_pad", round * 3);
        e.noteOn("drums", 300 + round, 52 + round, 1);
        if (round == 3) {  // a sample swap: decoded here, on the control thread; the audio thread only exchanges
            ProjectSpec q = p;
            q.layers[0].instrument.samples = {{16, "", "Crash"}};
            CHECK(e.setProject(q).find("\"ok\":true") != std::string::npos);
        }
        cawtest::AllocationScope scope;
        for (int k = 0; k < 100; ++k) {
            e.process(L.data(), R.data(), 192);
            for (float v : L) peak = v > peak ? v : peak;
        }
        operations += scope.count();
        float display[1024];
        e.componentDisplay("drums", Engine::kInstrumentIndex, display, 1024);
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
    e.notesOff();
    e.stop();
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 500; ++k) e.process(L.data(), R.data(), 192);  // the tails, the room, then sleep
        operations = scope.count();
    }
    CHECK_EQ(operations, 0u);
}

TEST(a_pattern_edit_while_notes_sound_never_allocates_on_the_audio_thread) {
    // #170: held notes carried across a pattern edit (a native instrument's and a .caw voice's) take their new
    // note's curve on the audio thread: the match is worked out on the control thread, the curve copy fits.
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"bass", templateSource("bass.caw"), {}});
    auto pattern = [](int k) {
        return "---\nkind: pattern\nname: P\nlength: 16\n---\n0 C3 16 1  bend 0:0 " + std::to_string(0.3 + 0.05 * k) +
               ":" + std::to_string(k - 6) + " 1:12\n" + (k % 2 ? "0 E3 16 1\n" : "") + "4 G3 8 1  bend 0:0 1:-3\n";
    };
    p.modules.push_back({"pat", pattern(0), {}});
    LayerSpec inst = layer("i", {});
    inst.pattern = "pat";
    inst.hasInstrument = true;
    inst.instrument.id = "org.caw.synth.morph";
    LayerSpec voices = layer("v", {"bass"});
    voices.pattern = "pat";
    p.layers = {inst, voices};
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 50; ++k) e.process(l.data(), r.data(), 192);
    std::size_t operations = 0;
    for (int k = 1; k < 12; ++k) {
        p.modules[1].source = pattern(k);
        CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
        cawtest::AllocationScope scope;
        for (int b = 0; b < 20; ++b) e.process(l.data(), r.data(), 192);
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
}

TEST(count_in_metronome_and_released_touches_never_allocate_on_the_audio_thread) {
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
    e.noteOn("a", 1, 50, 0.8);  // a preview over the count-in (the control-side map grows here)
    e.setMetronome(true);
    e.playCountIn(0, 2);
    std::size_t operations = 0;
    double sum = 0.0;
    {
        cawtest::AllocationScope scope;
        // Two beats of count-in at 140 BPM (about 0.86 s), then playback with the metronome: 2 s in all.
        for (int k = 0; k < 500; ++k) {
            e.process(l.data(), r.data(), 192);
            for (float v : l) sum += std::fabs(v);
        }
        operations = scope.count();
    }
    CHECK(e.meters().playing);
    e.releaseTouches();
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 50; ++k) e.process(l.data(), r.data(), 192);
        operations += scope.count();
    }
    e.noteOff(1);
    CHECK(sum > 0.0);
    CHECK_EQ(operations, 0u);
}
