// Native instruments on tracks: notes reach them on their frames, previews, stop, values, state, reloads, the built-in synth.
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "caw.h"
#include "caw/instrument.hpp"
#include "component_chain.h"
#include "engine.h"
#include "json.h"
#include "module_registry.h"
#include "native_component_test_path.h"
#include "note_events.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

constexpr const char* kRecorder = "org.caw.tests.native-loader.recorder";
constexpr const char* kSynth = "org.caw.synth.flagship";
constexpr const char* kBasic = "org.caw.synth.basic";  // retired: an old project's plays Flagship's Basic preset
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
        "layers":[{"id":"t","chain":["fx"],"instrument":{"id":"org.caw.synth.flagship","params":{"flt1_cutoff":900},"bypass":true}},
                  {"id":"u","instrument":"org.caw.synth.flagship"},{"id":"v"}],
        "automation":[{"target_type":"instrument","layer":"t","target":"flt1_cutoff","points":[{"step":0,"value":500}]}]})",
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

TEST(a_note_list_holds_plenty_of_notes_in_little_memory) {
    // Second audio review, fix 4: 4,096 held notes and 2 x 16,384 events came to about 1.5 MB per instrument
    // track (about 94 MB at 64 tracks, and twice that for a track during a rebuild). No practical polyphony cap
    // stays (owner, 2026-11-10): a thousand notes at once on one track, room for all their offs and ons again
    // in one block, in a few hundred KB.
    CHECK(NoteEvents::kMaxHeld >= 1024u);
    CHECK(NoteEvents::kCapacity >= 3u * NoteEvents::kMaxHeld);  // every held note ends and starts again in one block
    CHECK(NoteEvents::kBytes <= 512u * 1024u);
    // Every held note ends and a new one starts in the same block: every off and every on arrives.
    auto notes = std::make_unique<NoteEvents>();
    for (uint32_t i = 0; i < NoteEvents::kMaxHeld; ++i)
        notes->on(0, NoteEvents::Source::Preview, 0, 0, static_cast<int32_t>(i), 60, 1);
    notes->clearEvents();
    for (uint32_t i = 0; i < NoteEvents::kMaxHeld; ++i)
        notes->on(1, NoteEvents::Source::Preview, 0, 0, static_cast<int32_t>(i), 62, 1);
    CHECK_EQ(notes->count(), 2u * NoteEvents::kMaxHeld);
    CHECK_EQ(notes->overflow(), 0u);
}

TEST(a_full_note_list_still_delivers_every_off) {
    // Audio review fix 5: a block whose list filled up (with per-note motion) dropped a note-off: a stuck note.
    // Room for every held note's off is now kept back from note-ons and motion.
    auto notes = std::make_unique<NoteEvents>();
    std::vector<NoteEvents::Held*> held;
    for (int32_t i = 0; i < 8; ++i) held.push_back(&notes->on(0, NoteEvents::Source::Preview, 0, 0, i, 60 + i, 1));
    for (uint32_t i = 0; i < NoteEvents::kCapacity; ++i) notes->pitch(i % 64, *held[i % 8], 60.0 + 0.001 * i);
    CHECK(notes->overflow() > 0u);  // motion past the room left was dropped
    for (NoteEvents::Held* h : held) notes->off(63, *h);
    CHECK_EQ(notes->count(), NoteEvents::kCapacity);
    uint32_t offs = 0;
    for (uint32_t i = 0; i < notes->count(); ++i) {
        NoteMessage m;
        offs += readNote(notes->events()[i], m) && m.type == NoteMessageType::Off;
    }
    CHECK_EQ(offs, 8u);
    CHECK(!notes->holdsAny());
}

TEST(a_note_list_sorts_many_runs_in_frame_order_and_keeps_their_order) {
    // Audio review fix 6: the insertion sort was O(n^2) with many expressive notes. A natural merge sort keeps
    // it O(n log runs), stable: here 1,024 runs of motion, each in frame order.
    auto notes = std::make_unique<NoteEvents>();
    uint32_t id = 0;
    for (uint32_t run = 0; run < 1024; ++run)
        for (uint32_t f = run % 7; f < 64; f += 8) notes->push(notes::notePitch(f, ++id, 60, 60.0 + run));
    const uint32_t n = notes->count();
    notes->sort();
    CHECK_EQ(notes->count(), n);
    for (uint32_t i = 1; i < n; ++i) {
        const Event& a = notes->events()[i - 1];
        const Event& b = notes->events()[i];
        CHECK(a.frame <= b.frame);
        if (a.frame == b.frame) CHECK(a.noteId < b.noteId);  // stable: same-frame events keep their order
    }
}

TEST(an_instrument_can_hold_a_thousand_notes) {
    // Owner, 2026-11-10: no practical polyphony cap from the host; a program sets its own. A track holds 1,024
    // notes at once (4,096 before the second audio review's memory fix, which took 1.5 MB per track).
    auto notes = std::make_unique<NoteEvents>();
    for (uint32_t i = 0; i < 1000; ++i) notes->on(0, NoteEvents::Source::Pattern, i, 0, -1, 40 + i % 60, 1);
    CHECK_EQ(notes->activeCount(), 1000u);
    CHECK(notes->findPattern(0, 0) != nullptr);  // the first is still held
    CHECK_EQ(notes->overflow(), 0u);
    notes->clearEvents();
    notes->releaseAll(0, false);
    CHECK_EQ(notes->count(), 1000u);
    notes->clearEvents();
    CHECK_EQ(notes->activeCount(), 0u);
    uint32_t left = 0;
    for (const NoteEvents::Held& h : notes->held()) left += h.active;  // packed away: nothing left to walk
    CHECK_EQ(left, 0u);
    CHECK(notes->held().begin() == notes->held().end());
}

namespace {

// A note sounds for 100 frames; then the instrument says it is quiet. Counts its render calls.
constexpr PortDescriptor kSleepyPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};
ModuleDescriptor sleepyDescriptor() {
    ModuleDescriptor d;
    d.id = "org.caw.tests.sleepy";
    d.role = ModuleRole::Instrument;
    d.ports = kSleepyPorts;
    d.portCount = 2;
    return d;
}
const ModuleDescriptor kSleepy = sleepyDescriptor();
int gSleepyRenders = 0;
class Sleepy final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kSleepy; }
    bool quiet() const noexcept override { return left_ == 0; }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        if (m.type == NoteMessageType::On) left_ = 100;
    }
    void render(float* l, float* r, uint32_t frames, uint32_t, const ProcessBlock&) noexcept override {
        ++gSleepyRenders;
        for (uint32_t i = 0; i < frames; ++i) {
            l[i] = r[i] = left_ > 0 ? 0.5f : 0.0f;
            if (left_ > 0) --left_;
        }
    }

private:
    uint32_t left_ = 0;
};

// An effect that passes its input on, with a 128-frame declared tail, quiet() when gTailQuiet. Counts its calls.
constexpr PortDescriptor kTailPorts[] = {stereoInput("in"), stereoOutput("out")};
ModuleDescriptor tailDescriptor() {
    ModuleDescriptor d;
    d.id = "org.caw.tests.tail";
    d.role = ModuleRole::Effect;
    d.ports = kTailPorts;
    d.portCount = 2;
    d.tailFrames = 128;
    return d;
}
const ModuleDescriptor kTail = tailDescriptor();
int gTailCalls = 0;
bool gTailQuiet = false;
class Tail final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kTail; }
    bool quiet() const noexcept override { return gTailQuiet; }
    void process(const StereoProcessBlock& b) noexcept override {
        ++gTailCalls;
        for (uint32_t i = 0; i < b.frames; ++i) {
            b.outputLeft[i] = b.inputLeft[i];
            b.outputRight[i] = b.inputRight[i];
        }
    }
};

}  // namespace

TEST(a_quiet_instrument_sleeps_until_its_next_note) {
    // Owner, 2026-11-10: the host skips what has fallen silent, so a plug-in that says so costs nothing then.
    ModuleRegistry registry;
    CHECK(registry.add(kSleepy, []() noexcept -> ModuleProcessor* { return new Sleepy; }));
    std::string error;
    ComponentSpec spec;
    spec.id = kSleepy.id;
    auto chain = ComponentChain::buildInstrument(registry, spec, 48000, error);
    CHECK(chain != nullptr);
    if (!chain) return;
    float l[64], r[64];
    gSleepyRenders = 0;
    chain->notes()->on(0, NoteEvents::Source::Preview, 0, 0, 1, 60, 1);
    chain->process(l, r, 64, 48000, nullptr);
    chain->process(l, r, 64, 48000, nullptr);  // frames 64..127: the note ends at 100, then it is quiet
    const int awake = gSleepyRenders;
    CHECK(awake > 0);
    for (int k = 0; k < 10; ++k) chain->process(l, r, 64, 48000, nullptr);
    CHECK_EQ(gSleepyRenders, awake);  // asleep: not run, and silence out
    CHECK_EQ(l[0], 0.0f);
    CHECK_EQ(r[63], 0.0f);
    chain->notes()->on(10, NoteEvents::Source::Preview, 0, 0, 2, 62, 1);  // an event wakes it, on its frame
    chain->process(l, r, 64, 48000, nullptr);
    CHECK(gSleepyRenders > awake);
    CHECK_EQ(l[9], 0.0f);
    CHECK_EQ(l[10], 0.5f);
}

TEST(an_effect_sleeps_only_when_it_says_it_is_quiet_not_when_its_tail_has_passed) {
    // Second audio review, fix 1: the host used to put an effect to sleep once its input had been silent past its
    // declared tail. It fell asleep on a block boundary with its timed state frozen, so the output depended on
    // the device's buffer size. A declared tail alone now keeps it running; quiet() still puts it to sleep.
    ModuleRegistry registry;
    CHECK(registry.add(kTail, []() noexcept -> ModuleProcessor* { return new Tail; }));
    std::string error;
    ComponentSpec spec;
    spec.id = kTail.id;
    auto chain = ComponentChain::build(registry, {spec}, 48000, error);
    CHECK(chain != nullptr);
    if (!chain) return;
    float l[64], r[64];
    gTailCalls = 0;
    for (int k = 0; k < 8; ++k) {  // 512 silent frames, four times its tail: still run
        std::fill_n(l, 64, 0.0f);
        std::fill_n(r, 64, 0.0f);
        chain->process(l, r, 64, 48000, nullptr);
    }
    CHECK_EQ(gTailCalls, 8);
    gTailQuiet = true;  // now it says it is quiet: run once more (it says so after a block), then asleep
    for (int k = 0; k < 4; ++k) {
        std::fill_n(l, 64, 0.0f);
        std::fill_n(r, 64, 0.0f);
        chain->process(l, r, 64, 48000, nullptr);
    }
    CHECK_EQ(gTailCalls, 9);
    std::fill_n(l, 64, 0.25f);  // input again: it runs
    std::fill_n(r, 64, 0.0f);
    chain->process(l, r, 64, 48000, nullptr);
    CHECK_EQ(gTailCalls, 10);
    CHECK_EQ(l[5], 0.25f);
    gTailQuiet = false;
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

TEST(a_note_played_again_while_held_gets_its_motion_up_to_its_end_at_any_block_size) {
    // Second audio review, fix 5: NoteEvents::on() ends a pattern note still held without the pitch points due
    // before its end, so its last pitch could depend on where the block split fell. The Engine now ends it first
    // with its motion, as an off and a slide do. Today a pattern's restart ends its notes before
    // they start again (here a bent note longer than its 3-step pattern, restarting mid-chunk), so this checks
    // that the motion up to a note's end and its new start land on the same frames at any block size.
    auto recordAt = [](int block) {
        Engine e(48000);
        std::vector<Rec> rec;
        if (!loadFixture(e, kRecorder)) return rec;
        ProjectSpec p = instrumentTrack(kRecorder, "");
        p.modules[0].source = pattern("0 C4 7/2 1 bend 0:0 0.8:0 1:12\n", 3);
        p.layers[0].pattern = "pat";
        if (!ok(e.setProject(p))) return rec;
        e.play();
        run(e, 6000 * 3 + 7001, block);  // past the restart at step 3 (mid-chunk), ending mid-block
        return records(e);
    };
    const std::vector<Rec> a = recordAt(64), b = recordAt(37);
    CHECK(a.size() > 4u);
    uint32_t ons = 0;
    for (const Rec& r : a) ons += r.type == kOn;
    CHECK(ons >= 2u);
    CHECK_EQ(a.size(), b.size());
    for (size_t i = 0; i < a.size() && i < b.size(); ++i) {
        CHECK_EQ(a[i].frame, b[i].frame);
        CHECK_EQ(a[i].type, b[i].type);
        CHECK_EQ(a[i].pitch, b[i].pitch);
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

TEST(play_after_stop_caps_the_tail_work_when_many_instruments_ring) {
    // Second audio review, fix 3: Play rendered 5 ms of every instrument still ringing, all inside one callback,
    // so with many tracks Play itself could overrun on a phone. The tails now share a fixed budget of frames
    // (Engine::kPlayTailBudgetFrames): one or two ringing instruments still fade over 5 ms, many over less each.
    auto ringing = [](int tracks) {
        ProjectSpec p = instrumentTrack("org.caw.synth.morph", "8 C4 4 1\n");
        p.layers[0].instrument.params = {{"release", 3.0}, {"sustain", 1.0}, {"shape", 0.0}, {"drift", 0.0}, {"unison", 1}, {"attack", 0.01}};
        p.layers[0].volume = 1.0 / tracks;
        for (int k = 1; k < tracks; ++k) {
            LayerSpec l = p.layers[0];
            l.id = l.name = "t" + std::to_string(k);
            p.layers.push_back(l);
        }
        return p;
    };
    // The frames after Play that still carry a tail (the new pass starts silent).
    auto tailFrames = [](const ProjectSpec& p) {
        Engine e(48000);
        e.setMasterBypass(true);
        if (!ok(e.setProject(p))) return -1;
        e.play();
        std::vector<float> l(64), r(64);
        for (int i = 0; i < 62400 / 64; ++i) e.process(l.data(), r.data(), 64);
        e.stop();
        for (int i = 0; i < 4800 / 64; ++i) e.process(l.data(), r.data(), 64);
        e.play();
        int last = -1;
        for (int i = 0; i < 8; ++i) {
            e.process(l.data(), r.data(), 64);
            for (int k = 0; k < 64; ++k)
                if (l[static_cast<size_t>(k)] != 0.0f) last = i * 64 + k;
        }
        return last + 1;
    };
    const int one = tailFrames(ringing(1)), many = tailFrames(ringing(16));
    CHECK(one >= 200);  // 5 ms: 240 frames
    CHECK(one <= 240);
    CHECK(many > 0);    // still a fade, not a cut
    CHECK(many * 16 <= Engine::kPlayTailBudgetFrames);
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
    const size_t at = list.find("\"id\":\"org.caw.synth.flagship\"");
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

TEST(the_basic_preset_matches_its_golden_render) {
    // Chords, a slide, a ratchet and a quarter tone, two oscillators through the filter, into a ping-pong delay:
    // an old project's basic synth, which now plays Flagship's Basic preset with its knobs mapped.
    ProjectSpec p = instrumentTrack(kBasic, "0 C3 4 1\n0 G3 4 0.8\n4 51 2 0.9 slide\n6 F3 2 0.9\n8 60.5 4 0.7 ratchet 3\n"
                                           "12 60 4 0.6\n12 63 4 0.6\n12 67 4 0.6\n");
    p.bpm = 140;
    p.master = 0.8;
    p.layers[0].instrument.params = {{"wave2", 1}, {"cutoff", 1200}, {"resonance", 0.4}, {"release", 0.4}};
    p.layers[0].components = {{"org.caw.delay.pingpong", {{"sync", 3}, {"mix", 0.3}}}};
    float peak = 0;
    const uint64_t h = renderHash(p, 48000 * 2, &peak);
    CHECK(peak > 0.05f);
    CHECK(peak <= 1.0f);
    // Re-recorded: voice summing order (engine pass), the ping-pong fix, and a released voice stopping on its own
    // frame rather than at the end of a render call (second audio review, fix 1: at most 15 frames below -100 dB),
    // and the ping-pong's left line taking the mono average at full cross, not the sum (fix 2: 6 dB quieter echoes).
    // Re-recorded (one synth, 2026-11-10): the basic synth is now Flagship's Basic preset (perceptually the same,
    // builtin_instruments_test.cpp).
    // And again: the fixed-point oscillator phase; and (second performance pass) the poly voices' shared filter 1
    // and the phases moving on in fixed point.
    constexpr uint64_t kGolden = 0xaa03efa87235874aull;
    if (h != kGolden) {
        char buf[96];
        std::snprintf(buf, sizeof buf, "the Basic preset renders 0x%016llxull", static_cast<unsigned long long>(h));
        cawtest::fail(__FILE__, __LINE__, buf);
    }
    CHECK_EQ(renderHash(p, 48000 * 2, nullptr), h);  // the same bits from a second engine
}

TEST(c_api_plays_and_addresses_a_layers_instrument) {
    CawEngine* engine = caw_engine_create(48000);
    CHECK(engine != nullptr);
    if (!engine) return;
    CHECK_EQ(caw_api_version(), 8);  // 8: presets, quality, buffer mode (7 count-in, 6 component display, 5 stereo meters)
    char* result = caw_engine_set_project(engine,
        R"({"caw_project":1,"bpm":120,"modules":[{"id":"p","source":"---\nkind: pattern\nname: P\nlength: 16\n---\n0 C4 4 1\n"}],
            "layers":[{"id":"t","pattern":"p","instrument":{"id":"org.caw.synth.flagship","params":{"flt1_cutoff":900}}}]})");
    CHECK(result && std::string(result).find("\"ok\":true") != std::string::npos);
    caw_free(result);
    CHECK_EQ(caw_engine_set_component_param(engine, "t", CAW_INSTRUMENT_INDEX, "flt1_cutoff", 1500), 1);
    CHECK_EQ(caw_engine_set_component_param(engine, "t", 0, "flt1_cutoff", 1500), 0);
    CHECK_EQ(caw_engine_set_component_bypass(engine, "t", CAW_INSTRUMENT_INDEX, 0), 1);
    char* states = caw_engine_component_states(engine, "t");
    CHECK(states && std::string(states).find("\"index\":4294967295") != std::string::npos);
    caw_free(states);
    caw_engine_destroy(engine);
}

// Owner (2026-11-10): during playback a Morph synth note with a bend went silent. Live playback, device-sized
// blocks: the bent note must sound like an unbent one.
TEST(live_playback_plays_a_bent_note_on_a_builtin_instrument) {
    for (const char* inst : {"org.caw.synth.morph", "org.caw.synth.basic", "org.caw.synth.flagship"}) {
        double level[2] = {0, 0};
        const char* patterns[2] = {"0 C3 8 1\n", "0 C3 8 1  bend 0:0~0.6 1:-12\n"};
        for (int k = 0; k < 2; ++k) {
            Engine e(48000);
            CHECK(ok(e.setProject(instrumentTrack(inst, patterns[k]))));
            e.play();
            std::vector<float> l(256), r(256);
            double sum = 0;
            for (int done = 0; done < 24000; done += 256) {
                e.process(l.data(), r.data(), 256);
                if (done >= 4800)
                    for (float x : l) sum += static_cast<double>(x) * x;
            }
            level[k] = sum;
        }
        CHECK(level[1] > level[0] * 0.25);
    }
}

// Owner (2026-11-10, #170): a note's bend in a clip never played. Laying the clips out into the song copied each
// note but not its expression, so a clip's note lost its bend (and vibrato, pressure and timbre).
TEST(a_clips_note_keeps_its_bend_when_the_clips_are_laid_out) {
    Engine e(48000);
    CHECK(loadFixture(e, kRecorder));
    ProjectSpec p = instrumentTrack(kRecorder, "0 C4 4 1  bend 0:0 1:-12\n");
    p.layers[0].pattern.clear();
    p.layers[0].clips.push_back(ClipSpec{"c", "pat", 0, 16, 0, true});
    CHECK(ok(e.setProject(p)));
    e.play();
    run(e, 30000, 256);
    double lowest = 1000;
    for (const Rec& r : records(e))
        if (r.type == kPitch) lowest = std::min(lowest, static_cast<double>(r.pitch));
    // The recorder keeps its first 256 events (about 4,000 frames of pitch steps): the bend has begun.
    CHECK(lowest < 59.0);
}

// Owner (2026-11-10, #170): editing the piano roll while the song plays froze a sounding bent note ("the note bend
// kind of wigs out or pauses where it's at"). A pattern edit made every held note an orphan without its curve, so
// its pitch stopped where it was until the old pattern's end. A note still in the new pattern now keeps sounding
// (no new on, no off) and follows its new curve from the playhead, gliding there over a few ms; a note the edit
// deletes, or moves off the playhead, ends with a release.
namespace {

// Plays `before` on the recorder for `at` frames, swaps in `after` through setProject, and plays `total` frames in
// all. Returns the held-note count (left) and the pitch heard (right) per frame, and the recorded events.
struct EditTrace {
    std::vector<double> held, pitch;
    std::vector<Rec> rec;
};
EditTrace playEdit(const std::string& before, const std::string& after, int at, int total, int block = 64) {
    EditTrace t;
    Engine e(48000);
    if (!loadFixture(e, kRecorder)) return t;
    e.setMasterBypass(true);
    if (!ok(e.setProject(instrumentTrack(kRecorder, before)))) return t;
    e.play();
    std::vector<float> l(static_cast<size_t>(block)), r(static_cast<size_t>(block));
    for (int done = 0; done < total;) {
        if (done == at && !ok(e.setProject(instrumentTrack(kRecorder, after)))) return t;
        const int n = std::min({block, total - done, done < at ? at - done : block});
        e.process(l.data(), r.data(), n);
        for (int i = 0; i < n; ++i) {
            t.held.push_back(l[static_cast<size_t>(i)] / (0.1 * kCentre));
            t.pitch.push_back(r[static_cast<size_t>(i)] / kCentre * 128.0);
        }
        done += n;
    }
    t.rec = records(e);
    return t;
}

uint32_t countOf(const std::vector<Rec>& rec, uint32_t type) {
    uint32_t n = 0;
    for (const Rec& r : rec) n += r.type == type;
    return n;
}

}  // namespace

TEST(a_pattern_edit_rebinds_a_sounding_bent_note_to_its_new_curve) {
    // A long note bending up 24 semitones over the bar; 2,000 frames in, its curve point is dragged down to -24.
    const std::string before = "0 C4 16 1  bend 0:0 1:24\n", after = "0 C4 16 1  bend 0:0 1:-24\n";
    const int at = 2000, glide = 480;  // the glide is a few ms (5 ms here, 240 frames): 480 is safely past it
    for (int block : {64, 37}) {
        const EditTrace t = playEdit(before, after, at, 3800, block);  // few enough events for the recorder's log
        CHECK_EQ(t.pitch.size(), size_t{3800});
        if (t.pitch.size() != 3800u) continue;
        CHECK_EQ(countOf(t.rec, kOn), 1u);   // no retrigger
        CHECK_EQ(countOf(t.rec, kOff), 0u);  // and no off
        for (size_t f = 0; f < t.held.size(); f += 50) CHECK_NEAR(t.held[f], 1.0, 1e-4);
        CHECK_NEAR(t.pitch[at - 1], 60.0 + 24.0 * (at - 1) / 96000.0, 0.02);
        // It glides, never jumps: no step between frames larger than a grid point's share of the glide.
        for (int f = at; f < at + glide; ++f) CHECK(std::fabs(t.pitch[f] - t.pitch[f - 1]) < 0.1);
        // Then it follows the new curve, still moving.
        for (int f = at + glide; f < 3800; f += 100) CHECK_NEAR(t.pitch[f], 60.0 - 24.0 * f / 96000.0, 0.02);
        CHECK(t.pitch[3799] < t.pitch[at + glide] - 0.3);
    }
}

TEST(a_pattern_edit_that_moves_or_stretches_a_sounding_note_keeps_it_sounding) {
    // The note moves a little later, a whole tone up and gets shorter (12 steps), still covering the playhead.
    const std::string before = "0 C4 16 1  bend 0:0 1:24\n", after = "1/16 D4 12 1  bend 0:0 1:-24\n";
    const int at = 2000, glide = 480, start = 375, len = 72000;
    const EditTrace t = playEdit(before, after, at, 80000);
    CHECK_EQ(t.pitch.size(), size_t{80000});
    if (t.pitch.size() != 80000u) return;
    CHECK_EQ(countOf(t.rec, kOn), 1u);
    for (int f = at; f < at + glide; ++f) CHECK(std::fabs(t.pitch[f] - t.pitch[f - 1]) < 0.1);
    for (int f = at + glide; f < start + len - 100; f += 997)
        CHECK_NEAR(t.pitch[f], 62.0 - 24.0 * (f - start) / len, 0.02);
    // It ends where the edited note ends, not where the old one did.
    CHECK_NEAR(t.held[start + len - 10], 1.0, 1e-4);
    CHECK_NEAR(t.held[start + len + 10], 0.0, 1e-4);
}

TEST(a_pattern_edit_ends_a_sounding_note_it_deletes_or_moves_off_the_playhead) {
    const std::string before = "0 C4 16 1  bend 0:0 1:24\n";
    const int at = 2000;
    {  // deleted (another note is left in the pattern)
        const EditTrace t = playEdit(before, "8 E4 2 1\n", at, 3000);
        CHECK_EQ(t.held.size(), size_t{3000});
        if (t.held.size() != 3000u) return;
        CHECK_NEAR(t.held[at - 1], 1.0, 1e-4);
        CHECK_NEAR(t.held[at + 1], 0.0, 1e-4);
        CHECK_EQ(countOf(t.rec, kOff), 1u);
        CHECK(!t.rec.empty() && t.rec.back().type == kOff && t.rec.back().frame == static_cast<uint64_t>(at));
    }
    {  // moved later, off the playhead: it ends now and plays again from its new start
        const EditTrace t = playEdit(before, "8 C4 4 1  bend 0:0 1:24\n", at, 49000);
        CHECK_EQ(t.held.size(), size_t{49000});
        if (t.held.size() != 49000u) return;
        CHECK_NEAR(t.held[at + 1], 0.0, 1e-4);
        CHECK_NEAR(t.held[47990], 0.0, 1e-4);
        CHECK_NEAR(t.held[48010], 1.0, 1e-4);
        CHECK_NEAR(t.pitch[48010], 60.0, 0.02);
    }
}

TEST(a_pattern_edit_keeps_a_builtin_synths_bent_note_sounding_and_releases_a_deleted_one) {
    for (const char* inst : {"org.caw.synth.morph", "org.caw.synth.flagship"}) {
        auto energy = [&](const std::string& after) {
            Engine e(48000);
            e.setMasterBypass(true);
            std::vector<double> win(4, 0.0);  // before the edit, just after it, and two later windows
            if (!ok(e.setProject(instrumentTrack(inst, "0 C3 16 1  bend 0:0 1:12\n")))) return win;
            e.play();
            std::vector<float> l(64), r(64);
            for (int done = 0; done < 48000; done += 64) {
                if (done == 24000 && !ok(e.setProject(instrumentTrack(inst, after)))) return win;
                e.process(l.data(), r.data(), 64);
                const int w = done < 19200 ? -1 : done < 24000 ? 0 : done < 24000 + 1920 ? 1 : done < 38400 ? -1 : done < 43200 ? 2 : 3;
                if (w >= 0)
                    for (float x : l) win[static_cast<size_t>(w)] += static_cast<double>(x) * x;
            }
            return win;
        };
        const std::vector<double> kept = energy("0 C3 16 1  bend 0:0 1:-12\n"), gone = energy("12 C3 1 1\n");
        CHECK(kept[0] > 0.0);
        CHECK(kept[2] > kept[0] * 0.25);  // still sounding long after the edit, at the same strength
        CHECK(gone[1] > 0.0);             // the deleted note releases (its tail), not cut to silence at once
        CHECK(gone[2] < kept[2] * 0.01);  // and then it is gone
    }
}
