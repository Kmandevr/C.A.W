// Real-time checks on the whole Engine and its parameter resolver: the audio path never allocates or frees.
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "block_fifo.h"
#include "engine.h"
#include "native_component_test_path.h"
#include "params.h"
#include "test.h"

using namespace caw;

namespace {
// One bar of acid (examples/acid-line.caw's notes): slides, a ratchet and a note that plays half the time.
const char* kAcidLine = "---\nkind: pattern\nname: Acid line\nlength: 16\n---\n0 A1 2 1\n2 A2 1 0.7\n3 A1 1 0.8 slide\n"
                        "4 C2 2 0.9\n6 A1 1 0.6 prob 0.5\n8 E2 2 1 ratchet 2\n10 G1 1 0.7\n11 A1 1 0.8 slide\n"
                        "12 A2 2 0.9\n14 G2 1 0.6\n15 E2 1 0.8\n";

// A track playing `instrument` (its notes from `pattern`, if any) through `components`.
LayerSpec layer(const std::string& id, const std::string& instrument = "", const std::string& pattern = "",
                std::vector<ComponentSpec> components = {}) {
    LayerSpec l;
    l.id = id;
    l.name = id;
    l.pattern = pattern;
    l.hasInstrument = !instrument.empty();
    l.instrument.id = instrument;
    l.components = std::move(components);
    return l;
}
}  // namespace

TEST(engine_process_never_allocates_through_loop_wraps_and_chain_swaps) {
    // Tracks loop at their own lengths (one every 3 sixteenths); then their instruments and inserts are swapped
    // in while playing: the replaced ones crossfade out and are retired, all without allocating or freeing.
    ProjectSpec p;
    p.bpm = 140;
    p.loopBars = 1;
    p.modules.push_back({"acid", kAcidLine});
    p.layers = {layer("b", "org.caw.synth.flagship", "acid", {{"org.caw.distortion", {}}, {"org.caw.chorus", {}}}),
                layer("a", "org.caw.test.osc", "acid", {{"org.caw.bitcrush", {}}}),
                layer("y", "org.caw.test.osc", "acid")};
    p.layers[1].instrument.params = {{"mode", 1}, {"shape", 1}};
    p.layers[2].instrument.params = {{"mode", 1}};
    p.layers[2].lengthSteps = 3;  // a loop wrap every 3 sixteenths
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 250; ++k) e.process(l.data(), r.data(), 192);  // warm up: one second
    // New chains of different lengths and a new instrument, swapped in at once: the old ones crossfade out.
    p.layers[0].components = {{"org.caw.chorus", {}}};
    p.layers[1].components = {{"org.caw.distortion", {}}, {"org.caw.bitcrush", {}}, {"org.caw.chorus", {}}};
    p.layers[2].instrument = {"org.caw.synth.flagship", {}};
    p.layers[2].components = {{"org.caw.delay.pingpong", {}}};
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    std::size_t operations = 0;
    float peak = 0.0f;
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 500; ++k) {  // two seconds: loop wraps, the swaps and their retirement
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
    for (int i = 0; i < 10; ++i)
        p.layers.push_back(layer("l" + std::to_string(i), "org.caw.test.osc", "", {{"org.caw.distortion", {}}}));
    Engine e(48000);
    e.setProject(p);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 50; ++k) e.process(l.data(), r.data(), 192);
    for (int i = 10; i < 100; ++i) p.layers.push_back(layer("l" + std::to_string(i), "org.caw.test.osc"));
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

TEST(slot_list_changes_never_allocate_on_the_audio_thread) {
    // #133: layers added and removed join and leave the in-use slot list without allocating.
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.layers = {layer("a", "org.caw.test.osc"), layer("b", "org.caw.test.osc")};
    p.layers[1].instrument.params = {{"freq", 330}};
    Engine e(48000);
    e.setProject(p);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 50; ++k) e.process(l.data(), r.data(), 192);
    for (int i = 0; i < 8; ++i) p.layers.push_back(layer("c" + std::to_string(i), "org.caw.test.osc"));
    e.setProject(p);
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
    p.layers.resize(2);  // the eight others fade out and leave the slot list
    e.setProject(p);
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 100; ++k) e.process(l.data(), r.data(), 192);
        operations = scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
    CHECK(e.slotsScannedPerChunk() <= 3);
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
    p.modules.push_back({"acid-line", kAcidLine});
    p.layers = {layer("a", "org.caw.synth.flagship", "acid-line", {{"org.caw.bitcrush", {}}})};
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
    p.modules.push_back({"acid", kAcidLine});
    p.layers = {layer("b", "org.caw.synth.flagship", "acid")};
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
    p.modules.push_back({"acid", kAcidLine});
    p.layers = {layer("b", "org.caw.synth.flagship", "acid")};
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
    p.modules.push_back({"acid", kAcidLine});
    p.layers = {layer("b", "org.caw.synth.flagship", "acid")};
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
    // The built-in synth plays a pattern (loop wraps, a slide, a ratchet, chords) through native effects; mid-way it is swapped for another instrument (its held notes move over), previews play and
    // it is stopped: the audio thread must not allocate or free through any of it.
    ProjectSpec p;
    p.bpm = 160;
    p.loopBars = 1;
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n0 C3 4 1\n0 G3 4 1\n4 D3 2 1 slide\n"
                                "6 F3 2 1\n8 A3 4 1 ratchet 4\n12 C4 4 1\n"});
    p.layers = {layer("s", "org.caw.synth.flagship", "pat", {{"org.caw.distortion", {}}, {"org.caw.delay.pingpong", {}}}),
                layer("t", "org.caw.synth.flagship", "pat")};
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
                                "12 G#2 2 0.6\n12 B1 4 1\n"});
    const char* ids[] = {"org.caw.drum.kick", "org.caw.drum.snare", "org.caw.drum.hats", "org.caw.drum.kit",
                         "org.caw.bass",      "org.caw.synth.acid", "org.caw.synth.morph", "org.caw.synth.flagship",
                         "org.caw.synth.basic"};
    for (const char* id : ids) {
        p.layers.push_back(layer(id, id, "pat"));
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
                                "8 C2 1 1\n8 E3 2 1\n10 D#3 1 0.8\n11 B2 1 0.7\n12 D2 1 1\n13 A2 1 0.7\n14 C3 1 0.8\n15 F#2 1 0.6\n"});
    LayerSpec l = layer("drums", "org.caw.drums", "pat");
    // Pad B1 (E3 = 52): every layer, the effects, a built-in sample.
    l.instrument.params = {{"glue", 0.5}, {"kit_drive_type", 1}, {"room", 0.3}, {"b1_type", 13}, {"b1_body_on", 1},
                           {"b1_click_on", 1}, {"b1_noise_on", 1}, {"b1_noise_mode", 1}, {"b1_metal_on", 1},
                           {"b1_metal_mode", 1}, {"b1_res_on", 1}, {"b1_smp_on", 1}, {"b1_drive_type", 1},
                           {"b1_flt", 2}, {"b1_eq_low", 3}, {"b1_tr_attack", 0.5}, {"b1_comp", 0.5}, {"b1_rnd_pitch", 30},
                           {"b1_poly", 4}, {"b1_level", -6}, {"b1_sub_on", 1}, {"b1_sub_wave", 2}, {"b1_sub_drive", 0.5},
                           {"b1_sub_lp", 300}, {"b1_sub_follow", 0.5}, {"b1_penv_mode", 1}, {"b1_drive_lo", 100},
                           {"b1_drive_hi", 6000}, {"b1_drive_mix", 0.6}, {"b1_clip", 2}, {"b1_clip_gain", 6},
                           {"b1_width", 0.7}, {"b1_room_send", 0.5}, {"b1_press_tone", 0.5}, {"b1_rnd_pos", 0.5},
                           {"kit_low", 3}, {"kit_high", -2}, {"kit_clip", 1}, {"kit_clip_gain", 4}, {"room_predelay", 20}};
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
        e.setComponentParam("drums", Engine::kInstrumentIndex, "b1_drive_type", round + 3);  // fold .. asymmetric
        e.setComponentParam("drums", Engine::kInstrumentIndex, "b1_penv_p2", 4.0 * round);
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
    // #170: held notes carried across a pattern edit take their new note's curve on the audio thread: the match is
    // worked out on the control thread, the curve copy fits.
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    auto pattern = [](int k) {
        return "---\nkind: pattern\nname: P\nlength: 16\n---\n0 C3 16 1  bend 0:0 " + std::to_string(0.3 + 0.05 * k) +
               ":" + std::to_string(k - 6) + " 1:12\n" + (k % 2 ? "0 E3 16 1\n" : "") + "4 G3 8 1  bend 0:0 1:-3\n";
    };
    p.modules.push_back({"pat", pattern(0)});
    p.layers = {layer("i", "org.caw.synth.morph", "pat"), layer("v", "org.caw.test.osc", "pat")};
    p.layers[1].instrument.params = {{"mode", 1}};
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 50; ++k) e.process(l.data(), r.data(), 192);
    std::size_t operations = 0;
    for (int k = 1; k < 12; ++k) {
        p.modules[0].source = pattern(k);
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
    p.modules.push_back({"acid-line", kAcidLine});
    p.layers = {layer("a", "org.caw.synth.flagship", "acid-line", {{"org.caw.bitcrush", {}}})};
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

TEST(the_test_signal_never_allocates_on_the_audio_thread) {
    // org.caw.test.osc (the internal test signal) free-running and played by chords, with shape and mode changes.
    ProjectSpec p;
    p.bpm = 150;
    p.loopBars = 1;
    p.modules.push_back({"pat", "---\nkind: pattern\nlength: 16\n---\n0 C4,E4,G4 2 1\n4 D2 1 1 slide\n8 E2 4 1 ratchet 4\n"});
    for (const char* id : {"free", "notes"}) {
        LayerSpec l = layer(id, "org.caw.test.osc");
        if (std::strcmp(id, "notes") == 0) {
            l.pattern = "pat";
            l.instrument.params = {{"mode", 1}};
        }
        p.layers.push_back(l);
    }
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 50; ++k) e.process(l.data(), r.data(), 192);
    std::size_t operations = 0;
    for (int round = 0; round < 7; ++round) {
        e.setComponentParam("free", Engine::kInstrumentIndex, "shape", round);
        e.setComponentParam("notes", Engine::kInstrumentIndex, "shape", 6 - round);
        e.setComponentParam("free", Engine::kInstrumentIndex, "mode", round % 2);
        cawtest::AllocationScope scope;
        for (int k = 0; k < 60; ++k) e.process(l.data(), r.data(), 192);
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
}

TEST(device_midi_never_allocates_on_the_audio_thread) {
    // MIDI from a device (API 15), stopped and playing, on two native instruments: notes, poly and channel pressure, bend, sustain, CCs, MPE and a release, all played from the queue without allocating.
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"acid-line", kAcidLine});
    p.layers = {layer("s", "org.caw.synth.flagship"), layer("v", "org.caw.test.osc", "acid-line")};
    p.layers[1].instrument.params = {{"mode", 1}};
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 20; ++k) e.process(l.data(), r.data(), 192);
    const uint8_t played[] = {0x90, 60, 100, 0x91, 64, 90, 0xA0, 60, 70, 0xD1, 50, 0xE0, 0, 80, 0xB0, 64, 127,
                              0xB0, 1, 40, 0xC0, 5, 0x80, 60, 0, 0xB0, 64, 0, 0x81, 64, 0};
    std::size_t operations = 0;
    float peak = 0.0f;
    for (int pass = 0; pass < 4; ++pass) {
        if (pass == 1) e.play();
        e.setMidiOptions(pass == 2, 2, 48, pass == 3 ? 5 : 0);
        // Queued off the audio thread, a little apart, as a player would.
        const int64_t t = Engine::midiClockNs();
        for (int i = 0; i < static_cast<int>(sizeof played);) {
            const int n = (played[i] & 0xF0) == 0xC0 || (played[i] & 0xF0) == 0xD0 ? 2 : 3;
            e.midiBytes("s", played + i, n, t + i * 100'000);
            e.midiBytes("v", played + i, n, t + i * 100'000);
            i += n;
        }
        cawtest::AllocationScope scope;
        for (int k = 0; k < 40; ++k) {
            e.process(l.data(), r.data(), 192);
            for (float v : l) peak = std::max(peak, std::fabs(v));
        }
        operations += scope.count();
        e.midiRelease("");
        cawtest::AllocationScope release;
        for (int k = 0; k < 4; ++k) e.process(l.data(), r.data(), 192);
        operations += release.count();
    }
    CHECK(peak > 0.0f);
    CHECK_EQ(operations, 0u);
    CHECK_EQ(e.midiDropped(), 0u);
}

TEST(the_flagship_s_user_wavetable_and_twice_rate_warps_never_allocate_on_the_audio_thread) {
    // A flagship playing its user wavetable (the state, a sine and a square frame) through Osc FM, FM and fold,
    // its warps and table switched as it plays and its state replaced between rounds: no allocation or free.
    std::vector<uint8_t> state = {'C', 'W', 'T', '1', 2, 0, 0, 0, 0, 8, 0, 0};
    for (int f = 0; f < 2; ++f)
        for (int i = 0; i < 2048; ++i) {
            const double v = f == 0 ? std::sin(6.283185307179586 * i / 2048) : (i < 1024 ? 1.0 : -1.0);
            const auto x = static_cast<uint16_t>(static_cast<int16_t>(v * 32767.0));
            state.push_back(static_cast<uint8_t>(x & 0xFF));
            state.push_back(static_cast<uint8_t>(x >> 8));
        }
    ProjectSpec p;
    p.bpm = 150;
    p.loopBars = 1;
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n0 C3 4 1\n0 G3 4 0.8\n4 D3 4 1\n8 E2 4 1\n12 A3 4 1\n"});
    LayerSpec l = layer("f", "org.caw.synth.flagship", "pat");
    l.instrument.params = {{"osc1_table", 5}, {"osc1_warp", 7}, {"osc1_warp_amt", 0.5}, {"osc2_on", 1}, {"osc2_warp", 6},
                           {"osc2_warp_amt", 0.8}, {"osc2_unison", 5}, {"osc3_on", 1}, {"osc3_table", 5}, {"osc3_warp", 5},
                           {"osc3_warp_amt", 0.6}};
    l.instrument.hasState = true;
    l.instrument.stateVersion = 1;
    l.instrument.state = state;
    p.layers.push_back(l);
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> L(192), R(192);
    for (int k = 0; k < 250; ++k) e.process(L.data(), R.data(), 192);  // warm up
    std::size_t operations = 0;
    float peak = 0.0f;
    for (int round = 0; round < 6; ++round) {
        if (round == 3) {  // a new table: the chain is rebuilt off the audio thread and crossfaded in
            state[4] = 1;
            state.resize(12 + 4096);
            CHECK(e.setComponentState("f", Engine::kInstrumentIndex, state.data(), state.size(), 1));
            for (int k = 0; k < 50; ++k) e.process(L.data(), R.data(), 192);  // the old chain retires
        }
        e.setComponentParam("f", Engine::kInstrumentIndex, "osc1_warp", 5 + round % 3);
        e.setComponentParam("f", Engine::kInstrumentIndex, "osc2_warp", 7 - round % 3);
        e.setComponentParam("f", Engine::kInstrumentIndex, "osc2_table", round % 6);
        e.setComponentParam("f", Engine::kInstrumentIndex, "osc3_warp_amt", 0.2 * round);
        e.noteOn("f", 300 + round, 48 + round, 1);
        cawtest::AllocationScope scope;
        for (int k = 0; k < 100; ++k) {
            e.process(L.data(), R.data(), 192);
            for (float v : L) peak = v > peak ? v : peak;
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
}

TEST(the_block_fifo_never_allocates_on_the_audio_thread) {
    // The device callback's fixed-block FIFO (block_fifo.h) with odd callback sizes, rendering a playing engine.
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"acid", kAcidLine});
    p.layers = {layer("a", "org.caw.synth.flagship", "acid", {{"org.caw.delay.pingpong", {}}})};
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(2048), r(2048);
    BlockFifo<kBlock> fifo;
    auto render = [&](float* bl, float* br, int m) { e.process(bl, br, m); };
    for (int k = 0; k < 50; ++k) fifo.pull(l.data(), r.data(), 441, 512, render);  // warm up
    std::size_t operations = 0;
    {
        cawtest::AllocationScope scope;
        for (const int n : {441, 1, 1023, 960, 1920, 480, 37, 2048, 441, 63, 65})
            for (int k = 0; k < 20; ++k) fifo.pull(l.data(), r.data(), n, 512, render);
        operations = scope.count();
    }
    CHECK_EQ(operations, std::size_t{0});
}

TEST(shedding_and_its_recovery_never_allocate_on_the_audio_thread) {
    // reportLoad sheds a layer under load, brings it back once the load drops, and a reset brings all back.
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"acid", kAcidLine});
    p.layers = {layer("a", "org.caw.test.osc", "acid"), layer("b", "org.caw.test.osc", "acid")};
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(512), r(512);
    for (int k = 0; k < 20; ++k) e.process(l.data(), r.data(), 512);
    std::size_t operations = 0;
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 1500; ++k) {  // 16 s: hot for 1.5 s, then cool
            e.process(l.data(), r.data(), 512);
            e.reportLoad(k < 140 ? 1.4 : 0.1, 512);
        }
        e.requestSheddingReset();
        e.process(l.data(), r.data(), 512);
        operations = scope.count();
    }
    CHECK_EQ(operations, std::size_t{0});
    CHECK(e.sheddingStats().shed >= 1);
    CHECK_EQ(e.sheddingStats().restored, e.sheddingStats().shed);
}
