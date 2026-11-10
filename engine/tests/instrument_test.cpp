// Native instruments on tracks: notes reach them on their frames, previews, stop, values, state, reloads, the built-in synth.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "caw.h"
#include "caw/instrument.hpp"
#include "engine.h"
#include "json.h"
#include "native_component_test_path.h"
#include "note_events.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

constexpr const char* kRecorder = "org.caw.tests.native-loader.recorder";
constexpr const char* kSynth = "org.caw.synth.basic";
const double kCentre = std::cos(3.14159265358979323846 / 4.0);  // the pan law at centre

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

bool loadFixture(Engine& e, const char* id) {
    const char* path = caw::test::nativeComponentPath();
    return path && e.loadNativeComponent(path, id, NativeModuleTrust::Trusted).success;
}

std::string pattern(const std::string& notes, int length = 16) {
    return "---\nkind: pattern\nname: P\nlength: " + std::to_string(length) + "\n---\n" + notes;
}

// One track at 120 BPM (6000 samples a step at 48 kHz, a 96000-sample bar) whose instrument plays `notes`.
ProjectSpec instrumentTrack(const std::string& instrument, const std::string& notes) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.modules.push_back({"pat", pattern(notes), {}});
    LayerSpec l;
    l.id = "t";
    l.name = "t";
    l.pattern = notes.empty() ? "" : "pat";
    l.volume = 1.0;
    l.hasInstrument = true;
    l.instrument.id = instrument;
    p.layers.push_back(l);
    return p;
}

// What the fixture recorder saves (its state): one entry per note event it received.
struct Rec {
    uint64_t frame;
    uint32_t noteId;
    uint32_t type;
    float pitch, velocity;
};
static_assert(sizeof(Rec) == 24);

std::vector<uint8_t> instrumentState(Engine& e, const std::string& layer) {
    Json root;
    std::string error;
    std::vector<uint8_t> bytes;
    if (!parseJson(e.componentStatesJson(layer), root, error)) return bytes;
    if (const Json* list = root.get("components"))
        for (const Json& c : list->arr)
            if (c.number("index", -1) == 4294967295.0) base64Decode(c.string("state"), bytes);
    return bytes;
}

std::vector<Rec> records(Engine& e, const std::string& layer = "t") {
    const std::vector<uint8_t> bytes = instrumentState(e, layer);
    std::vector<Rec> out;
    if (bytes.size() < 4) return out;
    uint32_t n = 0;
    std::memcpy(&n, bytes.data(), 4);
    out.resize(n);
    if (bytes.size() >= 4 + n * sizeof(Rec)) std::memcpy(out.data(), bytes.data() + 4, n * sizeof(Rec));
    return out;
}

constexpr uint32_t kOn = static_cast<uint32_t>(NoteMessageType::On);
constexpr uint32_t kOff = static_cast<uint32_t>(NoteMessageType::Off);
constexpr uint32_t kPitch = static_cast<uint32_t>(NoteMessageType::Pitch);

// Runs `frames` frames in blocks of `block`; returns the last left and right samples.
void run(Engine& e, int frames, int block, float* left = nullptr, float* right = nullptr) {
    std::vector<float> l(static_cast<size_t>(block)), r(static_cast<size_t>(block));
    for (int done = 0; done < frames;) {
        const int n = std::min(block, frames - done);
        e.process(l.data(), r.data(), n);
        done += n;
        if (left) *left = l[static_cast<size_t>(n - 1)];
        if (right) *right = r[static_cast<size_t>(n - 1)];
    }
}

}  // namespace

TEST(project_json_reads_a_layers_native_instrument_and_its_lanes) {
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,
        "layers":[{"id":"t","chain":["fx"],"instrument":{"id":"org.caw.synth.basic","params":{"cutoff":900},"bypass":true}},
                  {"id":"u","instrument":"org.caw.synth.basic"},{"id":"v"}],
        "automation":[{"target_type":"instrument","layer":"t","target":"cutoff","points":[{"step":0,"value":500}]}]})",
                       p, error));
    CHECK_EQ(p.layers.size(), 3u);
    CHECK(p.layers[0].hasInstrument);
    CHECK_EQ(p.layers[0].instrument.id, std::string(kSynth));
    CHECK(p.layers[0].instrument.bypass);
    CHECK_EQ(p.layers[0].instrument.params.size(), 1u);
    CHECK(p.layers[1].hasInstrument);
    CHECK(!p.layers[2].hasInstrument);
    CHECK_EQ(p.automation.size(), 1u);
    CHECK_EQ(p.automation[0].targetType, std::string("instrument"));
    CHECK_EQ(p.automation[0].moduleId, std::string("t"));
    CHECK_EQ(p.automation[0].component, 0);
    ProjectSpec bad;
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","instrument":42}]})", bad, error));
    CHECK(error.find("instrument") != std::string::npos);
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","instrument":{"params":{}}}]})", bad, error));
    CHECK(error.find("needs an id") != std::string::npos);
}

TEST(note_events_encode_and_decode_pitch_velocity_and_ids) {
    NoteMessage m;
    CHECK(readNote(notes::noteOn(5, 9, 60.25, 0.5), m));
    CHECK(m.type == NoteMessageType::On);
    CHECK_EQ(m.frame, 5u);
    CHECK_EQ(m.noteId, 9u);
    CHECK_EQ(static_cast<int>(m.key), 60);
    CHECK_NEAR(m.pitch, 60.25, 1.0 / 512);
    CHECK_NEAR(m.velocity, 0.5, 1e-4);
    CHECK(readNote(notes::noteOn(0, 1, 30.0, 0.0), m));
    CHECK(m.velocity > 0.0);  // an on is never velocity 0
    CHECK(readNote(notes::noteOff(3, 9, 60), m));
    CHECK(m.type == NoteMessageType::Off);
    CHECK(readNote(notes::notePitch(0, 9, 60, 61.123456), m));
    CHECK(m.type == NoteMessageType::Pitch);
    CHECK_NEAR(m.pitch, 61.123456, 1e-6);
    CHECK(readNote(notes::notePressure(0, 9, 60, 0.25), m));
    CHECK(m.type == NoteMessageType::Pressure);
    CHECK_NEAR(m.value, 0.25, 1e-6);
    CHECK(readNote(notes::noteTimbre(0, 9, 60, 0.75), m));
    CHECK(m.type == NoteMessageType::Timbre);
    Event other;
    other.data[0] = 0x20903C40u;  // a MIDI 1.0 note on: not a C.A.W note event
    CHECK(!readNote(other, m));
}

TEST(a_note_list_is_bounded_and_sorted_and_counts_what_overflows) {
    auto notes = std::make_unique<NoteEvents>();
    for (uint32_t i = 0; i < NoteEvents::kCapacity + 10; ++i) notes->push(notes::noteOn(63 - i % 64, i + 1, 60, 1));
    CHECK_EQ(notes->count(), NoteEvents::kCapacity);
    CHECK_EQ(notes->overflow(), 10u);
    notes->sort();
    for (uint32_t i = 1; i < notes->count(); ++i) CHECK(notes->events()[i - 1].frame <= notes->events()[i].frame);
    notes->clearEvents();
    // More held notes than it can hold: the oldest ends.
    for (uint32_t i = 0; i < NoteEvents::kMaxHeld + 1; ++i)
        notes->on(0, NoteEvents::Source::Preview, 0, 0, static_cast<int32_t>(i), 60, 1);
    CHECK(notes->findPreview(0) == nullptr);
    CHECK(notes->findPreview(1) != nullptr);
}

TEST(pattern_notes_reach_an_instrument_on_their_frames_across_loop_wraps) {
    Engine e(48000);
    CHECK(loadFixture(e, kRecorder));
    CHECK(ok(e.setProject(instrumentTrack(kRecorder, "0 C4 2 1\n8 62.5 4 0.5\n"))));
    e.play();
    run(e, 96000 * 2 - 100, 100);  // odd blocks: notes land mid-block
    const std::vector<Rec> rec = records(e);
    CHECK_EQ(rec.size(), 8u);
    if (rec.size() < 8) return;
    const uint64_t at[] = {0, 12000, 48000, 72000, 96000, 108000, 144000, 168000};
    const uint32_t type[] = {kOn, kOff, kOn, kOff, kOn, kOff, kOn, kOff};
    for (size_t i = 0; i < 8; ++i) {
        CHECK_EQ(rec[i].frame, at[i]);
        CHECK_EQ(rec[i].type, type[i]);
    }
    CHECK_NEAR(rec[0].pitch, 60.0, 1e-6);
    CHECK_NEAR(rec[2].pitch, 62.5, 1e-6);
    CHECK_NEAR(rec[2].velocity, 0.5, 1e-4);
    CHECK_EQ(rec[1].noteId, rec[0].noteId);  // the off names its on
    CHECK(rec[2].noteId != rec[0].noteId);
    CHECK(rec[4].noteId != rec[0].noteId);   // each pass is a new note
}

TEST(a_looping_clip_plays_its_notes_on_every_repeat) {
    Engine e(48000);
    CHECK(loadFixture(e, kRecorder));
    ProjectSpec p = instrumentTrack(kRecorder, "");
    p.modules[0].source = pattern("0 C4 1 1\n", 4);
    p.layers[0].clips.push_back({"c", "pat", 0, 16, 0, true});
    CHECK(ok(e.setProject(p)));
    e.play();
    run(e, 96000, 64);
    const std::vector<Rec> rec = records(e);
    CHECK_EQ(rec.size(), 8u);
    for (size_t i = 0; i + 1 < rec.size(); i += 2) {
        CHECK_EQ(rec[i].type, kOn);
        CHECK_EQ(rec[i].frame, static_cast<uint64_t>(24000 * (i / 2)));
        CHECK_EQ(rec[i + 1].frame, static_cast<uint64_t>(24000 * (i / 2) + 6000));
    }
}

TEST(a_slide_glides_the_held_note_without_a_new_on) {
    Engine e(48000);
    CHECK(loadFixture(e, kRecorder));
    CHECK(ok(e.setProject(instrumentTrack(kRecorder, "0 C4 2 1 slide\n2 D4 2 1\n"))));
    e.play();
    run(e, 30000, 64);
    const std::vector<Rec> rec = records(e);
    int ons = 0;
    double lastPitch = 0;
    for (const Rec& r : rec) {
        ons += r.type == kOn;
        if (r.type == kPitch) lastPitch = r.pitch;
    }
    CHECK_EQ(ons, 1);
    CHECK_NEAR(lastPitch, 62.0, 1e-6);  // it ended the glide on D4
    CHECK(!rec.empty() && rec.back().type == kOff && rec.back().frame == 24000u);
}

TEST(previews_play_an_instrument_while_stopped_with_their_own_ids_and_glides) {
    Engine e(48000);
    CHECK(loadFixture(e, kRecorder));
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(instrumentTrack(kRecorder, ""))));
    float l = 0, r = 0;
    run(e, 640, 64, &l, &r);
    CHECK_EQ(l, 0.0f);
    e.noteOn("t", 7, 64.25, 0.8);
    run(e, 2048, 64, &l, &r);
    CHECK_NEAR(l, 0.1 * kCentre, 1e-5);  // one held note
    e.notePitch(7, 66.0);
    run(e, 2048, 64);
    e.noteOff(7);
    run(e, 640, 64, &l, &r);
    CHECK_NEAR(l, 0.0, 1e-6);
    const std::vector<Rec> rec = records(e);
    CHECK(rec.size() >= 3);
    if (rec.size() < 3) return;
    CHECK_EQ(rec.front().type, kOn);
    CHECK_NEAR(rec.front().pitch, 64.25, 1.0 / 512);
    CHECK_NEAR(rec.front().velocity, 0.8, 1e-4);
    CHECK_EQ(rec.back().type, kOff);
    CHECK_EQ(rec.back().noteId, rec.front().noteId);
    CHECK_EQ(rec[rec.size() - 2].type, kPitch);
    CHECK_NEAR(rec[rec.size() - 2].pitch, 66.0, 1e-6);
    // Two previews at once, and notesOff ends both.
    e.noteOn("t", 1, 60, 1);
    e.noteOn("t", 2, 67, 1);
    run(e, 640, 64, &l, &r);
    CHECK_NEAR(l, 0.2 * kCentre, 1e-5);
    e.notesOff();
    run(e, 640, 64, &l, &r);
    CHECK_NEAR(l, 0.0, 1e-6);
}

TEST(stop_ends_an_instruments_notes_and_play_starts_it_from_silence) {
    Engine e(48000);
    CHECK(loadFixture(e, kRecorder));
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(instrumentTrack(kRecorder, "0 C4 16 1\n"))));
    e.play();
    float l = 0, r = 0;
    run(e, 30000, 64, &l, &r);
    CHECK_NEAR(l, 0.1 * kCentre, 1e-5);
    e.stop();
    run(e, 4800, 64, &l, &r);
    const std::vector<Rec> rec = records(e);
    CHECK_EQ(rec.size(), 2u);
    if (rec.size() == 2) {
        CHECK_EQ(rec[1].type, kOff);
        CHECK_EQ(rec[1].noteId, rec[0].noteId);
    }
    CHECK_NEAR(l, 0.0, 1e-6);  // its release rang out (this one has none)
    e.play();
    run(e, 640, 64, &l, &r);
    CHECK_NEAR(l, 0.1 * kCentre, 1e-5);  // the note starts again with the loop, nothing left over
}

TEST(play_after_stop_fades_a_ringing_instrument_out_instead_of_cutting_it) {
    // Audio review fix 3: Play reset an instrument still ringing out after Stop in one sample (a click).
    Engine e(48000);
    e.setMasterBypass(true);
    // A sine (so a step stands out from the wave's own), and the loop starts silent: only the tail sounds at Play.
    ProjectSpec p = instrumentTrack("org.caw.synth.morph", "8 C4 4 1\n");
    p.layers[0].instrument.params = {{"release", 3.0}, {"sustain", 1.0}, {"shape", 0.0}, {"drift", 0.0}, {"unison", 1}, {"attack", 0.01}};
    CHECK(ok(e.setProject(p)));
    e.play();
    std::vector<float> l(64), r(64);
    for (int i = 0; i < 62400 / 64; ++i) e.process(l.data(), r.data(), 64);  // 1.3 s: into the note (step 8 = 1 s)
    e.stop();
    float before = 0;
    for (int i = 0; i < 4800 / 64; ++i) {  // the stop fade, then the release rings on
        e.process(l.data(), r.data(), 64);
        before = 0;
        for (float v : l) before = std::max(before, std::fabs(v));
    }
    CHECK(before > 0.01f);
    e.play();
    float jump = 0, last = l[63];
    for (int i = 0; i < 8; ++i) {
        e.process(l.data(), r.data(), 64);
        for (float v : l) {
            jump = std::max(jump, std::fabs(v - last));
            last = v;
        }
    }
    CHECK_NEAR(l[63], 0.0, 1e-6);  // then silence: the new pass starts from it, as an export does
    CHECK(jump < 0.25f * before);    // no step: the tail fades over a few milliseconds
}

TEST(an_instruments_values_bypass_and_automation_work_as_for_an_effect) {
    Engine e(48000);
    CHECK(loadFixture(e, kRecorder));
    e.setMasterBypass(true);
    ProjectSpec p = instrumentTrack(kRecorder, "0 C4 16 1\n");
    p.layers[0].instrument.params = {{"level", 2.0}};
    CHECK(ok(e.setProject(p)));
    e.play();
    float l = 0, r = 0;
    run(e, 6400, 64, &l, &r);
    CHECK_NEAR(l, 0.2 * kCentre, 1e-5);
    CHECK(e.setComponentParam("t", Engine::kInstrumentIndex, "level", 3.0));
    run(e, 640, 64, &l, &r);
    CHECK_NEAR(l, 0.3 * kCentre, 1e-5);
    CHECK(!e.setComponentParam("t", Engine::kInstrumentIndex, "nothing", 3.0));
    CHECK(!e.setComponentParam("t", 0, "level", 3.0));  // index 0 is the (empty) inserts
    CHECK(e.setComponentBypass("t", Engine::kInstrumentIndex, true));
    run(e, 640, 64, &l, &r);
    CHECK_NEAR(l, 0.0, 1e-6);  // a bypassed instrument crossfades to silence
    CHECK(e.setComponentBypass("t", Engine::kInstrumentIndex, false));
    run(e, 640, 64, &l, &r);
    // A lane drives it from the next Play.
    ProjectSpec laned = p;
    laned.automation.push_back({"instrument", "t", 0, "level", {{0, 4.0}, {16, 4.0}}});
    CHECK(ok(e.setProject(laned)));
    e.play();
    run(e, 6400, 64, &l, &r);
    CHECK_NEAR(l, 0.4 * kCentre, 1e-5);
}

TEST(an_instruments_state_is_saved_and_restored_through_the_project) {
    Engine e(48000);
    CHECK(loadFixture(e, kRecorder));
    ProjectSpec p = instrumentTrack(kRecorder, "0 C4 2 1\n");
    CHECK(ok(e.setProject(p)));
    e.play();
    run(e, 20000, 64);
    const std::vector<uint8_t> saved = instrumentState(e, "t");
    CHECK_EQ(saved.size(), 4 + 2 * sizeof(Rec));
    ProjectSpec restored = p;
    restored.layers[0].instrument.hasState = true;
    restored.layers[0].instrument.state = saved;
    Engine fresh(48000);
    CHECK(loadFixture(fresh, kRecorder));
    CHECK(ok(fresh.setProject(restored)));
    CHECK_EQ(records(fresh).size(), 2u);
}

TEST(a_rebuilt_instrument_takes_over_its_held_notes_while_playing) {
    const char* path = caw::test::nativeComponentPath();
    CHECK(path != nullptr);
    if (!path) return;
    const std::string rebuild = std::string(path) + ".instrument-rebuild-test";
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
    CHECK(loadFixture(e, kRecorder));
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(instrumentTrack(kRecorder, "0 C4 16 1\n"))));
    e.play();
    float l = 0, r = 0;
    run(e, 6400, 64);
    CHECK(e.setComponentParam("t", Engine::kInstrumentIndex, "level", 2.0));
    run(e, 640, 64);
    CHECK(e.reloadNativeComponent(rebuild, kRecorder, NativeModuleTrust::Trusted).success);
    run(e, 4096, 64, &l, &r);  // past the 20 ms crossfade
    CHECK_NEAR(l, 0.2 * kCentre, 1e-5);  // the note sounds on in the new build, at the value set live
    const std::vector<Rec> rec = records(e);  // the state carried over, then the held note started again
    CHECK_EQ(rec.size(), 2u);
    if (rec.size() == 2) {
        CHECK_EQ(rec[1].type, kOn);
        CHECK_EQ(rec[1].noteId, rec[0].noteId);
    }
    std::remove(rebuild.c_str());
}

TEST(two_instrument_swaps_within_the_crossfade_keep_the_held_notes) {
    // Audio review fix 1: a second swap while the first still crossfades kept the side heard more (the old
    // instrument, whose notes had been let go) and took over from it, so every held note stopped.
    Engine e(48000);
    CHECK(loadFixture(e, kRecorder));
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(instrumentTrack(kRecorder, "0 C4 16 1\n"))));
    e.play();
    float l = 0, r = 0;
    run(e, 6400, 64);
    CHECK(ok(e.setProject(instrumentTrack(kSynth, "0 C4 16 1\n"))));
    run(e, 64, 64);  // 1.3 ms: the first crossfade has barely started
    CHECK(ok(e.setProject(instrumentTrack(kRecorder, "0 C4 16 1\n"))));
    run(e, 4096, 64, &l, &r);  // past the second crossfade
    CHECK_NEAR(l, 0.1 * kCentre, 1e-5);  // the held note sounds on in the recorder again
    const std::vector<Rec> rec = records(e);
    CHECK_EQ(rec.size(), 1u);  // a new recorder, which heard the held note start again
    if (!rec.empty()) CHECK_EQ(rec[0].type, kOn);
}

TEST(an_instrument_is_followed_by_the_tracks_caw_effects_and_replaces_its_generator) {
    Engine e(48000);
    CHECK(loadFixture(e, kRecorder));
    e.setMasterBypass(true);
    ProjectSpec p = instrumentTrack(kRecorder, "0 C4 16 1\n");
    p.modules.push_back({"half", "---\nkind: effect\n---\nin * 0.5", {}});
    p.modules.push_back({"dc", "---\nmode: float\n---\n0.5", {}});
    p.layers[0].chain = {"dc", "half"};
    const std::string result = e.setProject(p);
    CHECK(result.find("plays the native instrument") != std::string::npos);  // the generator is left out
    e.play();
    float l = 0, r = 0;
    run(e, 6400, 64, &l, &r);
    const double mid = 0.5 * (0.1 + 60.0 / 128.0);  // .caw effects are mono: they take the instrument's mid
    CHECK_NEAR(l, 0.5 * mid * kCentre, 1e-5);
    CHECK_NEAR(r, 0.5 * mid * kCentre, 1e-5);
}

TEST(an_instrument_and_an_effect_each_refuse_the_others_place) {
    Engine e(48000);
    CHECK(loadFixture(e, kRecorder));
    CHECK(loadFixture(e, "org.caw.tests.native-loader.gain"));
    ProjectSpec p = instrumentTrack("org.caw.tests.native-loader.gain", "");
    CHECK(e.setProject(p).find("can't be an instrument") != std::string::npos);
    p = instrumentTrack(kSynth, "");
    p.layers[0].components = {{kRecorder, {}}};
    CHECK(e.setProject(p).find("is an instrument") != std::string::npos);
    p.layers[0].components.clear();
    p.layers[0].instrument.id = "org.caw.tests.not-loaded";
    CHECK(e.setProject(p).find("not loaded") != std::string::npos);
}

TEST(the_built_in_synth_is_listed_as_an_instrument_and_starts_on_its_frame) {
    Engine e(48000);
    const std::string list = e.nativeComponentsJson();
    const size_t at = list.find("\"id\":\"org.caw.synth.basic\"");
    CHECK(at != std::string::npos);
    CHECK(list.find("\"role\":\"instrument\"", at) != std::string::npos);
    std::unique_ptr<ModuleProcessor> synth = e.createNativeComponent(kSynth);
    CHECK(synth != nullptr);
    if (!synth) return;
    CHECK(synth->activate(48000, 64));
    float left[64], right[64];
    float* out[2] = {left, right};
    const ChannelBufferView audio{out, 2, 64};
    const Event on = notes::noteOn(10, 1, 69, 1);
    const EventInput events{&on, 1};
    ProcessBlock b;
    b.frames = 64;
    b.audioOut = &audio;
    b.audioOutCount = 1;
    b.eventIn = &events;
    b.eventInCount = 1;
    CHECK(synth->usesProcessPorts());
    CHECK(synth->processPorts(b));
    for (int i = 0; i < 10; ++i) CHECK_EQ(left[i], 0.0f);
    float energy = 0;
    for (int i = 10; i < 64; ++i) energy += std::fabs(left[i]);
    CHECK(energy > 0.0f);
    synth->deactivate();
}

// FNV-1a over the float bits of an interleaved render.
uint64_t renderHash(const ProjectSpec& p, int64_t frames, float* peak) {
    Engine e(48000);
    if (!ok(e.setProjectOffline(p))) return 0;
    e.play();
    uint64_t h = 1469598103934665603ull;
    std::vector<float> l(256), r(256);
    for (int64_t done = 0; done < frames; done += 256) {
        e.process(l.data(), r.data(), 256);
        for (int i = 0; i < 256; ++i)
            for (float v : {l[static_cast<size_t>(i)], r[static_cast<size_t>(i)]}) {
                if (peak) *peak = std::max(*peak, std::fabs(v));
                uint32_t bits = 0;
                std::memcpy(&bits, &v, 4);
                for (int k = 0; k < 4; ++k) {
                    h ^= (bits >> (8 * k)) & 0xFF;
                    h *= 1099511628211ull;
                }
            }
    }
    return h;
}

TEST(the_built_in_synth_matches_its_golden_render) {
    // Chords, a slide, a ratchet and a quarter tone, two oscillators through the filter, into a ping-pong delay.
    ProjectSpec p = instrumentTrack(kSynth, "0 C3 4 1\n0 G3 4 0.8\n4 51 2 0.9 slide\n6 F3 2 0.9\n8 60.5 4 0.7 ratchet 3\n"
                                           "12 60 4 0.6\n12 63 4 0.6\n12 67 4 0.6\n");
    p.bpm = 140;
    p.master = 0.8;
    p.layers[0].instrument.params = {{"wave2", 1}, {"cutoff", 1200}, {"resonance", 0.4}, {"release", 0.4}};
    p.layers[0].components = {{"org.caw.delay.pingpong", {{"sync", 3}, {"mix", 0.3}}}};
    float peak = 0;
    const uint64_t h = renderHash(p, 48000 * 2, &peak);
    CHECK(peak > 0.05f);
    CHECK(peak <= 1.0f);
    constexpr uint64_t kGolden = 0xa00fa2d9ae2c8b6bull;
    if (h != kGolden) {
        char buf[96];
        std::snprintf(buf, sizeof buf, "the basic synth renders 0x%016llxull", static_cast<unsigned long long>(h));
        cawtest::fail(__FILE__, __LINE__, buf);
    }
    CHECK_EQ(renderHash(p, 48000 * 2, nullptr), h);  // the same bits from a second engine
}

TEST(c_api_plays_and_addresses_a_layers_instrument) {
    CawEngine* engine = caw_engine_create(48000);
    CHECK(engine != nullptr);
    if (!engine) return;
    CHECK_EQ(caw_api_version(), 4);
    char* result = caw_engine_set_project(engine,
        R"({"caw_project":1,"bpm":120,"modules":[{"id":"p","source":"---\nkind: pattern\nname: P\nlength: 16\n---\n0 C4 4 1\n"}],
            "layers":[{"id":"t","pattern":"p","instrument":{"id":"org.caw.synth.basic","params":{"cutoff":900}}}]})");
    CHECK(result && std::string(result).find("\"ok\":true") != std::string::npos);
    caw_free(result);
    CHECK_EQ(caw_engine_set_component_param(engine, "t", CAW_INSTRUMENT_INDEX, "cutoff", 1500), 1);
    CHECK_EQ(caw_engine_set_component_param(engine, "t", 0, "cutoff", 1500), 0);
    CHECK_EQ(caw_engine_set_component_bypass(engine, "t", CAW_INSTRUMENT_INDEX, 0), 1);
    char* states = caw_engine_component_states(engine, "t");
    CHECK(states && std::string(states).find("\"index\":4294967295") != std::string::npos);
    caw_free(states);
    caw_engine_destroy(engine);
}
