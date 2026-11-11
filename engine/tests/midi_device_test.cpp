// MIDI device input (API 13): MIDI 1.0 to UMP at the edge, device notes on an instrument, frame-accurate timing, drops.
#include <cstring>
#include <string>
#include <vector>

#include "caw.h"
#include "caw/instrument.hpp"
#include "engine.h"
#include "json.h"
#include "midi_device.h"
#include "native_component_test_path.h"
#include "note_events.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

constexpr const char* kRecorder = "org.caw.tests.native-loader.recorder";

bool loadRecorder(Engine& e) {
    const char* path = caw::test::nativeComponentPath();
    return path && e.loadNativeComponent(path, kRecorder, NativeModuleTrust::Trusted).success;
}

ProjectSpec recorderTrack() {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    LayerSpec l;
    l.id = "t";
    l.name = "t";
    l.volume = 1.0;
    l.hasInstrument = true;
    l.instrument.id = kRecorder;
    p.layers.push_back(l);
    return p;
}

struct Rec {
    uint64_t frame;
    uint32_t noteId;
    uint32_t type;
    float pitch, velocity;
};

std::vector<Rec> records(Engine& e) {
    Json root;
    std::string error;
    std::vector<uint8_t> bytes;
    if (!parseJson(e.componentStatesJson("t"), root, error)) return {};
    if (const Json* list = root.get("components"))
        for (const Json& c : list->arr)
            if (c.number("index", -1) == 4294967295.0) base64Decode(c.string("state"), bytes);
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

Midi2Event fromMidi1(uint8_t status, uint8_t d1, uint8_t d2) {
    uint32_t w[2] = {0, 0};
    Midi2Event e;
    if (!midi1ToUmp2(status, d1, d2, 0, w) || !decodeMidi2ChannelVoice(w[0], w[1], e)) return e;
    e.ump[0] = w[0];
    e.ump[1] = w[1];
    return e;
}

}  // namespace

TEST(midi_scale_up_keeps_zero_centre_and_top) {
    CHECK_EQ(midiScaleUp(0, 7, 16), 0u);
    CHECK_EQ(midiScaleUp(64, 7, 16), 0x8000u);
    CHECK_EQ(midiScaleUp(127, 7, 16), 0xFFFFu);
    CHECK_EQ(midiScaleUp(64, 7, 32), 0x80000000u);
    CHECK_EQ(midiScaleUp(127, 7, 32), 0xFFFFFFFFu);
    CHECK_EQ(midiScaleUp(0x2000, 14, 32), 0x80000000u);
    CHECK_EQ(midiScaleUp(0x3FFF, 14, 32), 0xFFFFFFFFu);
    CHECK(midiScaleUp(100, 7, 16) > midiScaleUp(99, 7, 16));  // monotonic above the centre
}

TEST(midi1_channel_voice_converts_to_midi2_ump) {
    uint32_t w[2];
    CHECK(midi1ToUmp2(0x99, 36, 127, 0, w));  // note on, channel 10, C2, full velocity
    CHECK_EQ(w[0], 0x40993C00u - 0x3C00u + (36u << 8));
    CHECK_EQ(w[1], 0xFFFF0000u);
    CHECK(midi1ToUmp2(0x90, 60, 0, 0, w));  // velocity 0: an off
    CHECK_EQ(w[0] >> 20 & 0xF, 0x8u);
    CHECK(midi1ToUmp2(0xA3, 60, 64, 0, w));  // poly pressure keeps the key
    CHECK_EQ(w[0], 0x40A33C00u);
    CHECK_EQ(w[1], 0x80000000u);
    CHECK(midi1ToUmp2(0xC0, 5, 0, 0, w));
    Midi2Event e;
    CHECK(decodeMidi2ChannelVoice(w[0], w[1], e));
    CHECK(e.type == Midi2EventType::ProgramChange);
    CHECK_EQ(e.index, 5);
    CHECK(midi1ToUmp2(0xE1, 0x00, 0x40, 0, w));  // bend centre
    CHECK(decodeMidi2ChannelVoice(w[0], w[1], e));
    CHECK(e.type == Midi2EventType::PitchBend);
    CHECK_EQ(e.channel, 1);
    CHECK_NEAR(e.value, 0.0, 1e-9);
    CHECK(!midi1ToUmp2(0xF8, 0, 0, 0, w));
    CHECK(ump1ToUmp2(0x20903C40u, w));  // a MIDI 1.0 UMP note on, velocity 64
    CHECK_EQ(w[0], 0x40903C00u);
    CHECK_EQ(w[1], 0x80000000u);
    CHECK_EQ(umpWordCount(0x00200000u), 1);  // JR timestamp
    CHECK_EQ(umpWordCount(0x40903C00u), 2);
    CHECK_EQ(umpWordCount(0x30000000u), 2);  // SysEx 7
    CHECK_EQ(umpWordCount(0x50000000u), 4);
}

TEST(device_midi_frames_keep_the_played_spacing_one_callback_late) {
    const int64_t now = 1'000'000'000;
    CHECK_EQ(deviceMidiFrame(now - 10'000'000, now, 480, 48000, 0), 0);  // the window's start
    CHECK_EQ(deviceMidiFrame(now - 5'000'000, now, 480, 48000, 0), 240);
    CHECK_EQ(deviceMidiFrame(now, now, 480, 48000, 0), 480);              // the next callback's first frame
    CHECK_EQ(deviceMidiFrame(now - 50'000'000, now, 480, 48000, 0), 0);  // late: at once
    CHECK_EQ(deviceMidiFrame(now - 10'000'000, now, 480, 48000, 5'000'000), 240);  // the steady-timing delay
}

TEST(device_notes_keep_key_channel_and_pressure_for_a_pad) {
    NoteEvents notes;
    DeviceNotes dev;
    DeviceMidiOptions o;
    dev.apply(notes, fromMidi1(0x99, 38, 100), 5, o);  // a pad on channel 10
    dev.apply(notes, fromMidi1(0xA9, 38, 90), 9, o);   // its poly aftertouch
    dev.apply(notes, fromMidi1(0x89, 38, 0), 12, o);
    CHECK_EQ(notes.count(), 3u);
    NoteMessage on, press, off;
    CHECK(readNote(notes.events()[0], on));
    CHECK(readNote(notes.events()[1], press));
    CHECK(readNote(notes.events()[2], off));
    CHECK(on.type == NoteMessageType::On);
    CHECK_EQ(on.key, 38);
    CHECK_EQ(on.channel, 9);
    CHECK_NEAR(on.pitch, 38.0, 1e-9);
    CHECK_NEAR(on.velocity, midiScaleUp(100, 7, 16) / 65535.0, 1e-9);
    CHECK_EQ(notes.events()[0].frame, 5u);
    CHECK(press.type == NoteMessageType::Pressure);
    CHECK_EQ(press.noteId, on.noteId);
    CHECK_EQ(press.channel, 9);
    CHECK_NEAR(press.value, midiScaleUp(90, 7, 32) / 4294967295.0, 1e-9);
    CHECK(off.type == NoteMessageType::Off);
    CHECK_EQ(off.noteId, on.noteId);
    CHECK_EQ(off.channel, 9);
    CHECK_EQ(notes.activeCount(), 0u);
}

TEST(device_notes_sustain_bend_and_controllers) {
    NoteEvents notes;
    DeviceNotes dev;
    DeviceMidiOptions o;
    dev.apply(notes, fromMidi1(0xB0, 64, 127), 0, o);  // pedal down
    dev.apply(notes, fromMidi1(0x90, 60, 100), 1, o);
    dev.apply(notes, fromMidi1(0x80, 60, 0), 2, o);    // key up: the pedal holds it
    CHECK_EQ(notes.activeCount(), 1u);
    dev.apply(notes, fromMidi1(0xE0, 0x7F, 0x7F), 3, o);  // full bend up: +2 semitones
    dev.apply(notes, fromMidi1(0xD0, 80, 0), 4, o);        // channel pressure
    dev.apply(notes, fromMidi1(0xC0, 7, 0), 5, o);         // program change
    dev.apply(notes, fromMidi1(0xB0, 64, 0), 6, o);        // pedal up: the note ends
    CHECK_EQ(notes.activeCount(), 0u);
    bool sawPitch = false, sawPress = false, sawOff = false;
    int raw = 0;
    for (uint32_t i = 0; i < notes.count(); ++i) {
        const Event& ev = notes.events()[i];
        NoteMessage m;
        if (readNote(ev, m)) {
            if (m.type == NoteMessageType::Pitch) sawPitch = std::abs(m.pitch - 62.0) < 1e-6;
            if (m.type == NoteMessageType::Pressure) sawPress = m.noteId != 0;
            if (m.type == NoteMessageType::Off) sawOff = ev.frame == 6;
        } else {
            CHECK(ev.kind == EventKind::Midi);
            CHECK_EQ(ev.noteId, 0u);
            ++raw;  // the two CC 64s, channel pressure and the program change, as themselves
        }
    }
    CHECK(sawPitch);
    CHECK(sawPress);
    CHECK(sawOff);
    CHECK_EQ(raw, 4);
}

TEST(device_notes_mpe_member_channels_bend_their_own_note) {
    NoteEvents notes;
    DeviceNotes dev;
    DeviceMidiOptions o;
    o.mpe = true;
    dev.apply(notes, fromMidi1(0x91, 60, 100), 0, o);  // member channel 2
    dev.apply(notes, fromMidi1(0x92, 64, 100), 0, o);  // member channel 3
    dev.apply(notes, fromMidi1(0xE1, 0x00, 0x60), 1, o);  // channel 2 bends half up: +24 of 48
    dev.apply(notes, fromMidi1(0xB2, 74, 127), 2, o);     // channel 3's timbre
    int pitches = 0, timbres = 0;
    for (uint32_t i = 0; i < notes.count(); ++i) {
        NoteMessage m;
        if (!readNote(notes.events()[i], m)) continue;
        if (m.type == NoteMessageType::Pitch) {
            ++pitches;
            CHECK_EQ(m.channel, 1);
            CHECK_NEAR(m.pitch, 60.0 + 24.0, 0.01);
        }
        if (m.type == NoteMessageType::Timbre) {
            ++timbres;
            CHECK_EQ(m.channel, 2);
        }
    }
    CHECK_EQ(pitches, 1);
    CHECK_EQ(timbres, 1);
}

TEST(device_midi_reaches_the_instrument_on_its_frame_while_stopped) {
    Engine e(48000);
    CHECK(loadRecorder(e));
    CHECK(e.setProject(recorderTrack()).find("\"ok\":true") != std::string::npos);
    std::vector<float> l(480), r(480);
    const int64_t now = 2'000'000'000;
    e.setMidiClockForTest(now);
    e.process(l.data(), r.data(), 480);  // the instrument is idle and stays so
    // Played 5 ms and 2.5 ms before the next callback starts: frames 240 and 360 of it.
    const uint8_t on[3] = {0x90, 60, 100}, off[3] = {0x80, 60, 0};
    CHECK_EQ(e.midiBytes("t", on, 3, now + 5'000'000), 1);
    CHECK_EQ(e.midiBytes("t", off, 3, now + 7'500'000), 1);
    e.setMidiClockForTest(now + 10'000'000);
    e.process(l.data(), r.data(), 480);
    const std::vector<Rec> rec = records(e);
    CHECK_EQ(rec.size(), 2u);
    if (rec.size() == 2) {
        CHECK_EQ(rec[0].type, kOn);
        CHECK_EQ(rec[0].frame, 240u);
        CHECK_NEAR(rec[0].pitch, 60.0, 1e-6);
        CHECK_EQ(rec[1].type, kOff);
        CHECK_EQ(rec[1].frame, 360u);
        CHECK_EQ(rec[1].noteId, rec[0].noteId);
    }
    CHECK_EQ(e.midiDropped(), 0u);
}

// A hardware pad (the drum machine's case): its poly aftertouch reaches the instrument as that note's pressure, at
// its frame; the channel and key the instrument sees are covered by device_notes_keep_key_channel_and_pressure_for_a_pad.
TEST(device_midi_poly_pressure_reaches_the_instrument_as_the_notes_pressure) {
    Engine e(48000);
    CHECK(loadRecorder(e));
    CHECK(e.setProject(recorderTrack()).find("\"ok\":true") != std::string::npos);
    std::vector<float> l(480), r(480);
    const int64_t now = 4'000'000'000;
    e.setMidiClockForTest(now);
    e.process(l.data(), r.data(), 480);
    const uint8_t pad[9] = {0x99, 38, 120, 0xA9, 38, 64, 0x89, 38, 0};
    CHECK_EQ(e.midiBytes("t", pad, 3, now + 1'000'000), 1);
    CHECK_EQ(e.midiBytes("t", pad + 3, 3, now + 2'000'000), 1);
    CHECK_EQ(e.midiBytes("t", pad + 6, 3, now + 3'000'000), 1);
    e.setMidiClockForTest(now + 10'000'000);
    e.process(l.data(), r.data(), 480);
    const std::vector<Rec> rec = records(e);
    CHECK_EQ(rec.size(), 3u);
    if (rec.size() == 3) {
        CHECK_EQ(rec[0].type, kOn);
        CHECK_NEAR(rec[0].pitch, 38.0, 1e-6);
        CHECK_EQ(rec[1].type, static_cast<uint32_t>(NoteMessageType::Pressure));
        CHECK_EQ(rec[1].noteId, rec[0].noteId);
        CHECK_EQ(rec[1].frame - rec[0].frame, 48u);  // 1 ms apart, as played
        CHECK_EQ(rec[2].type, kOff);
        CHECK_EQ(rec[2].frame - rec[0].frame, 96u);
    }
}

// The app's own previews ending (its notes-off backstop) leave a device's held keys sounding.
TEST(device_notes_outlive_the_apps_notes_off) {
    Engine e(48000);
    CHECK(loadRecorder(e));
    CHECK(e.setProject(recorderTrack()).find("\"ok\":true") != std::string::npos);
    std::vector<float> l(128), r(128);
    e.setMidiClockForTest(1'000'000'000);
    const uint8_t on[3] = {0x90, 64, 100};
    CHECK_EQ(e.midiBytes("t", on, 3, 1), 1);
    e.process(l.data(), r.data(), 128);
    e.notesOff();
    e.process(l.data(), r.data(), 128);
    CHECK_EQ(records(e).size(), 1u);  // still held
    e.midiRelease("t");
    e.process(l.data(), r.data(), 128);
    const std::vector<Rec> rec = records(e);
    CHECK_EQ(rec.size(), 2u);
    if (rec.size() == 2) CHECK_EQ(rec[1].type, kOff);
}

TEST(device_midi_ump_and_a_later_callbacks_message_wait_their_turn) {
    Engine e(48000);
    CHECK(loadRecorder(e));
    CHECK(e.setProject(recorderTrack()).find("\"ok\":true") != std::string::npos);
    std::vector<float> l(256), r(256);
    const int64_t now = 3'000'000'000;
    e.setMidiClockForTest(now);
    // MIDI 2.0 note on with an exact pitch (attribute 3: 60.5), then a bend as a UMP, in the callback after next.
    // A JR timestamp (utility, skipped), then the note on.
    const uint32_t ump[] = {0x00200000u, 0x40903C03u, 0xFFFF0000u | static_cast<uint32_t>(60.5 * 512)};
    CHECK_EQ(e.midiUmp("t", ump, 3, now + 1'000'000), 1);
    e.setMidiClockForTest(now + 2'000'000);  // a callback's 5.33 ms window ends before the note's time + one callback
    e.process(l.data(), r.data(), 256);
    // The window was [now + 2 ms - 5.33 ms, now + 2 ms): the note (now + 1 ms) is at frame 256 - 48 = 208.
    std::vector<Rec> rec = records(e);
    CHECK_EQ(rec.size(), 2u);  // its on, then its exact pitch
    if (rec.size() >= 2) {
        CHECK_EQ(rec[0].type, kOn);
        CHECK_EQ(rec[0].frame, 208u);
        CHECK_EQ(rec[1].type, kPitch);
        CHECK_NEAR(rec[1].pitch, 60.5, 1e-3);
    }
    // A message for later than this callback waits for its own.
    const uint32_t offUmp[] = {0x40803C00u, 0x00000000u};
    CHECK_EQ(e.midiUmp("t", offUmp, 2, now + 2'000'000 + 2'000'000), 1);
    e.process(l.data(), r.data(), 256);  // the clock did not move: the off is in the next window
    CHECK_EQ(records(e).size(), 2u);
    e.setMidiClockForTest(now + 2'000'000 + 5'333'333);
    e.process(l.data(), r.data(), 256);
    rec = records(e);
    CHECK_EQ(rec.size(), 3u);
    if (rec.size() == 3) CHECK_EQ(rec[2].type, kOff);
}

TEST(device_midi_release_ends_held_notes_and_a_full_queue_counts_drops) {
    Engine e(48000);
    CHECK(loadRecorder(e));
    CHECK(e.setProject(recorderTrack()).find("\"ok\":true") != std::string::npos);
    std::vector<float> l(128), r(128);
    e.setMidiClockForTest(1'000'000'000);
    const uint8_t on[3] = {0x90, 64, 100};
    CHECK_EQ(e.midiBytes("t", on, 3, 1), 1);
    e.process(l.data(), r.data(), 128);
    e.midiRelease("");
    e.process(l.data(), r.data(), 128);
    std::vector<Rec> rec = records(e);
    CHECK_EQ(rec.size(), 2u);
    if (rec.size() == 2) CHECK_EQ(rec[1].type, kOff);
    CHECK_EQ(e.midiBytes("nope", on, 3, 0), 0);  // no such track
    // 1,100 messages before a callback: the queue takes 1,024.
    std::vector<uint8_t> many;
    for (int i = 0; i < 1100; ++i) many.insert(many.end(), {0xB0, 1, static_cast<uint8_t>(i & 0x7F)});
    CHECK_EQ(e.midiBytes("t", many.data(), static_cast<int>(many.size()), 1), 1024);
    CHECK_EQ(e.midiDropped(), 76u);
    e.process(l.data(), r.data(), 128);
}

TEST(device_midi_capi_and_position_at) {
    CawEngine* ce = caw_engine_create(48000);
    CHECK(ce != nullptr);
    CHECK(caw_midi_clock_ns() > 0);
    CHECK_EQ(caw_engine_position_at(ce, caw_midi_clock_ns()), -1);  // no callback yet
    const uint8_t on[3] = {0x90, 60, 100};
    CHECK_EQ(caw_engine_midi_bytes(ce, "missing", on, 3, 0), 0);
    CHECK_EQ(caw_engine_midi_bytes(ce, nullptr, on, 3, 0), 0);
    caw_engine_set_midi_options(ce, CAW_MIDI_MPE, 2, 48, 0);
    caw_engine_midi_release(ce, nullptr);
    CHECK_EQ(caw_engine_midi_dropped(ce), 0);
    caw_engine_destroy(ce);
}
