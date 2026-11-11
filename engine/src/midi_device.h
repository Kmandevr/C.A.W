// MIDI from hardware devices: MIDI 1.0 bytes and UMP words to MIDI 2.0 Channel Voice messages at the edge, the
// device clock's time to a frame of the audio callback, and each message applied to an instrument's notes.
#pragma once

#include <cstdint>

#include "midi2.h"
#include "note_events.h"

namespace caw {

// The MIDI 1.0 to 2.0 translation follows the min-centre-max upscaling of the UMP specification (M2-104-UM,
// "Translation"; written from the published algorithm, not re-checked against the PDF this session): values at
// or below the source's centre shift up, values above it repeat their low bits, so 0, the centre and the top map to
// 0, the exact centre and the top.
uint32_t midiScaleUp(uint32_t value, unsigned srcBits, unsigned dstBits) noexcept;

// One MIDI 1.0 Channel Voice message (status 0x80..0xEF and its data bytes) as a MIDI 2.0 Channel Voice UMP in
// group `group`. Note On velocity 0 becomes a Note Off. False for anything else (system messages, SysEx).
bool midi1ToUmp2(uint8_t status, uint8_t data1, uint8_t data2, uint8_t group, uint32_t out[2]) noexcept;

// A MIDI 1.0 Channel Voice UMP (message type 0x2) as MIDI 2.0 (type 0x4). False for other words.
bool ump1ToUmp2(uint32_t word0, uint32_t out[2]) noexcept;

// The words in the UMP whose first word is `word0`, by its message type (1, 2, 3 or 4).
int umpWordCount(uint32_t word0) noexcept;

// The bytes a MIDI 1.0 message with this status carries after it (0 for an unknown or system status).
int midi1DataBytes(uint8_t status) noexcept;

// How device MIDI plays notes (set by caw_engine_set_midi_options).
struct DeviceMidiOptions {
    bool mpe = false;          // MPE: channels 2..16 are one note each, channel 1 the master
    double bendRange = 2;      // semitones a full channel pitch bend moves (MPE: the master channel's)
    double noteBendRange = 48; // semitones of an MPE member channel's bend and of a MIDI 2.0 per-note pitch bend
};

// The preview id a device note holds on an instrument: the top 32,768 ids, far above the app's (a counter from 1).
// Positive, so everything that treats a preview id of 0 or more as a preview (a .caw voice chain's voices) does here.
constexpr int32_t kDevicePreviewBase = 0x7FFF8000;
constexpr int32_t devicePreviewId(uint8_t group, uint8_t channel, uint8_t key) noexcept {
    return kDevicePreviewBase + ((group & 0xF) << 11 | (channel & 0xF) << 7 | (key & 0x7F));
}
constexpr bool isDevicePreview(int32_t id) noexcept { return id >= kDevicePreviewBase; }

// The frame in a callback of `frames` frames at `sampleRate` that an event at `timeNs` plays at, for a callback
// that started at `nowNs`: the callback stands for the `frames` frames before now (plus `delayNs`), so an event
// keeps its spacing to the others, one callback (and the delay) late. An event before that window plays at frame 0;
// one after it at `frames` or later (a later callback's).
int64_t deviceMidiFrame(int64_t timeNs, int64_t nowNs, int frames, double sampleRate, int64_t delayNs) noexcept;

// One track's device state on the audio thread: each channel's bend, sustain pedal and MPE expression. The held
// notes themselves are previews in the instrument's NoteEvents (ids from devicePreviewId), so everything that ends
// previews (Stop's fade, mute, a rebuild) ends them too.
class DeviceNotes {
public:
    // Applies `e` (a device message) at `frame` of the current block. Notes, poly pressure, per-note pitch,
    // channel bend and pressure, sustain (CC 64), All Sound Off and All Notes Off (CC 120, 123) and MPE's CC 74
    // become the notes' own events; every Control Change, Program Change and Channel Pressure also goes to the
    // instrument as itself (an EventKind::Midi event, MIDI 2.0 words, note id 0) for onEvent().
    void apply(NoteEvents& notes, const Midi2Event& e, uint32_t frame, const DeviceMidiOptions& o) noexcept;
    // Forgets the channels' state (the instrument was reset or the device went away).
    void reset() noexcept;

private:
    double channelBend(uint8_t ch, const DeviceMidiOptions& o) const noexcept;
    void repitch(NoteEvents& notes, uint32_t frame, NoteEvents::Held& h, const DeviceMidiOptions& o) noexcept;
    float bend_[16] = {};      // -1..1 (float: one of these sits in every track slot, within its memory budget)
    bool sustain_[16] = {};
};

}  // namespace caw
