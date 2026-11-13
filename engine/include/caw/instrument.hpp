// C++ instrument helpers: note events (MIDI 2.0 UMP with host note ids) to note on/off, pitch and velocity.
#pragma once

#include <cmath>
#include <cstdint>

#include "module.hpp"

// An instrument is a component with one event input and one stereo audio output (and no audio input).
// The host sends it the track's notes as timed Events (kind Note, MIDI 2.0 Channel Voice UMP words,
// a host note id per note); the instrument owns its polyphony, as a CLAP instrument does. Derive from
// caw::InstrumentProcessor and implement onNote() and render(): the base splits each block at its
// events, so a note starts on its exact frame. caw::VoicePool allocates voices by note id.
//
// What the host sends (C.A.W. 2026-11-10; the UMP field meanings follow the MIDI 2.0 UMP
// specification, M2-104-UM, not re-checked against it this session):
// - Note On (status 0x9) with attribute type 3 (Pitch 7.9): the key is the nearest semitone and the
//   attribute holds the exact pitch, so microtones arrive exactly. Velocity is 16-bit, at least 1.
// - Note Off (status 0x8) with the same key and note id.
// - Registered Per-Note Controller 3 (Pitch 7.25): the note's absolute pitch now (glides, bends, vibrato).
// - Poly Pressure (status 0xA): the note's pressure 0..1. Registered Per-Note Controller 74: its timbre 0..1.
// Read events with caw::readNote, which decodes these into a NoteMessage.
namespace caw {

enum class NoteMessageType : uint8_t { On, Off, Pitch, Pressure, Timbre, Other };

struct NoteMessage {
    NoteMessageType type = NoteMessageType::Other;
    uint32_t frame = 0;   // offset in the block
    uint32_t noteId = 0;  // the host's id for the note: an off, pitch or pressure names the same id as its on
    uint8_t group = 0, channel = 0, key = 60;
    double velocity = 0;  // On, Off: 0..1
    double pitch = 60;    // On, Pitch: MIDI note number with fraction (60.5 is a quarter tone above middle C)
    double value = 0;     // Pressure, Timbre: 0..1
};

namespace notes {

constexpr uint32_t kStatusNoteOff = 0x8, kStatusNoteOn = 0x9, kStatusPolyPressure = 0xA,
                   kStatusRegisteredPerNote = 0x0;
constexpr uint32_t kAttributePitch79 = 3;     // Note On/Off attribute: Pitch 7.9
constexpr uint32_t kControllerPitch725 = 3;   // Registered Per-Note Controller: absolute pitch 7.25
constexpr uint32_t kControllerTimbre = 74;    // Registered Per-Note Controller: timbre (brightness)

// The key a pitch sounds nearest: 0..127.
constexpr uint8_t keyOf(double pitch) noexcept {
    if (!(pitch > 0.0)) return 0;
    if (pitch >= 127.0) return 127;
    return static_cast<uint8_t>(static_cast<int>(pitch + 0.5));
}

constexpr uint32_t word0(uint32_t status, uint8_t channel, uint8_t key, uint32_t index) noexcept {
    return (0x4u << 28) | (static_cast<uint32_t>(status & 0xF) << 20) | (static_cast<uint32_t>(channel & 0xF) << 16) |
           (static_cast<uint32_t>(key & 0x7F) << 8) | (index & 0xFF);
}

inline uint32_t unit32(double v) noexcept {
    if (!(v > 0.0)) return 0;
    if (v >= 1.0) return 0xFFFFFFFFu;
    return static_cast<uint32_t>(v * 4294967295.0 + 0.5);
}

inline Event noteOn(uint32_t frame, uint32_t noteId, double pitch, double velocity, uint8_t channel = 0) noexcept {
    if (!std::isfinite(pitch)) pitch = 60.0;
    const double p = pitch < 0.0 ? 0.0 : pitch > 127.998 ? 127.998 : pitch;
    const double v = std::isfinite(velocity) ? velocity : 1.0;
    uint32_t vel = v <= 0.0 ? 1u : v >= 1.0 ? 0xFFFFu : static_cast<uint32_t>(v * 65535.0 + 0.5);
    if (vel == 0) vel = 1;  // a velocity of 0 would read as an off on MIDI 1.0 paths
    Event e;
    e.frame = frame;
    e.kind = EventKind::Note;
    e.noteId = noteId;
    e.data[0] = word0(kStatusNoteOn, channel, keyOf(p), kAttributePitch79);
    e.data[1] = (vel << 16) | (static_cast<uint32_t>(p * 512.0 + 0.5) & 0xFFFFu);
    return e;
}

inline Event noteOff(uint32_t frame, uint32_t noteId, uint8_t key, double velocity = 0.0, uint8_t channel = 0) noexcept {
    const double v = std::isfinite(velocity) ? velocity : 0.0;
    const uint32_t vel = v <= 0.0 ? 0u : v >= 1.0 ? 0xFFFFu : static_cast<uint32_t>(v * 65535.0 + 0.5);
    Event e;
    e.frame = frame;
    e.kind = EventKind::Note;
    e.noteId = noteId;
    e.data[0] = word0(kStatusNoteOff, channel, key, 0);
    e.data[1] = vel << 16;
    return e;
}

// The note's absolute pitch now (Pitch 7.25: 7 bits of note number, 25 of fraction).
inline Event notePitch(uint32_t frame, uint32_t noteId, uint8_t key, double pitch, uint8_t channel = 0) noexcept {
    if (!std::isfinite(pitch)) pitch = 60.0;
    const double p = pitch < 0.0 ? 0.0 : pitch >= 128.0 ? 127.99999997 : pitch;
    Event e;
    e.frame = frame;
    e.kind = EventKind::Note;
    e.noteId = noteId;
    e.data[0] = word0(kStatusRegisteredPerNote, channel, key, kControllerPitch725);
    e.data[1] = static_cast<uint32_t>(p * 33554432.0);  // 2^25
    return e;
}

inline Event notePressure(uint32_t frame, uint32_t noteId, uint8_t key, double value, uint8_t channel = 0) noexcept {
    Event e;
    e.frame = frame;
    e.kind = EventKind::Note;
    e.noteId = noteId;
    e.data[0] = word0(kStatusPolyPressure, channel, key, 0);
    e.data[1] = unit32(value);
    return e;
}

inline Event noteTimbre(uint32_t frame, uint32_t noteId, uint8_t key, double value, uint8_t channel = 0) noexcept {
    Event e;
    e.frame = frame;
    e.kind = EventKind::Note;
    e.noteId = noteId;
    e.data[0] = word0(kStatusRegisteredPerNote, channel, key, kControllerTimbre);
    e.data[1] = unit32(value);
    return e;
}

}  // namespace notes

// Decodes a note event the host sent (see the top of this file). Anything else: type Other, false.
inline bool readNote(const Event& e, NoteMessage& out) noexcept {
    out = NoteMessage{};
    out.frame = e.frame;
    out.noteId = e.noteId;
    const uint32_t w0 = e.data[0], w1 = e.data[1];
    if ((w0 >> 28) != 0x4) return false;  // only MIDI 2.0 Channel Voice messages carry notes
    const uint32_t status = (w0 >> 20) & 0xF, index = w0 & 0xFF;
    out.group = static_cast<uint8_t>((w0 >> 24) & 0xF);
    out.channel = static_cast<uint8_t>((w0 >> 16) & 0xF);
    out.key = static_cast<uint8_t>((w0 >> 8) & 0x7F);
    switch (status) {
        case notes::kStatusNoteOn:
        case notes::kStatusNoteOff:
            out.type = status == notes::kStatusNoteOn ? NoteMessageType::On : NoteMessageType::Off;
            out.velocity = static_cast<double>(w1 >> 16) / 65535.0;
            out.pitch = index == notes::kAttributePitch79 ? static_cast<double>(w1 & 0xFFFF) / 512.0 : out.key;
            return true;
        case notes::kStatusPolyPressure:
            out.type = NoteMessageType::Pressure;
            out.value = static_cast<double>(w1) / 4294967295.0;
            return true;
        case notes::kStatusRegisteredPerNote:
            if (index == notes::kControllerPitch725) {
                out.type = NoteMessageType::Pitch;
                out.pitch = static_cast<double>(w1) / 33554432.0;
                return true;
            }
            if (index == notes::kControllerTimbre) {
                out.type = NoteMessageType::Timbre;
                out.value = static_cast<double>(w1) / 4294967295.0;
                return true;
            }
            return false;
        default:
            return false;
    }
}

// A resolved parameter at one frame of the block (per frame while it ramps or is automated).
inline double parameterAt(const ProcessBlock& b, uint32_t index, uint32_t frame, double fallback) noexcept {
    if (index >= b.parameterCount || !b.parameters) return fallback;
    const ParameterValue& p = b.parameters[index];
    return p.samples ? p.samples[frame] : p.value;
}

// The base of a C++ instrument: one event input, one stereo audio output. processPorts() renders the
// block in pieces split at its events: render() up to an event's frame, onNote() for each event
// there, then on. A block with more than kMaxSplits distinct event frames starts the rest together
// at the last split, so a dense block never costs more than kMaxSplits render calls.
class InstrumentProcessor : public ModuleProcessor {
public:
    static constexpr uint32_t kMaxSplits = 64;
    bool usesProcessPorts() const noexcept final { return true; }
    bool processPorts(const ProcessBlock& b) noexcept final {
        if (b.frames == 0 || b.audioOutCount != 1 || !b.audioOut || b.audioOut[0].channelCount != 2 ||
            !b.audioOut[0].valid() || b.audioOut[0].frames < b.frames)
            return false;
        float* left = b.audioOut[0].channels[0];
        float* right = b.audioOut[0].channels[1];
        const Event* events = b.eventInCount > 0 && b.eventIn ? b.eventIn[0].events : nullptr;
        const uint32_t count = events ? b.eventIn[0].count : 0;
        uint32_t done = 0, e = 0, splits = 0;
        beginBlock(b);
        auto dispatch = [&](const Event& event) noexcept {
            NoteMessage m;
            if (readNote(event, m)) {
                m.frame = done;
                onNote(m);
            } else {
                onEvent(event);
            }
        };
        for (;;) {
            while (e < count && events[e].frame <= done) dispatch(events[e++]);
            if (done >= b.frames) break;
            uint32_t next = e < count && events[e].frame < b.frames ? events[e].frame : b.frames;
            if (++splits >= kMaxSplits)  // the rest start together here
                while (e < count && events[e].frame < b.frames) dispatch(events[e++]);
            if (splits >= kMaxSplits) next = b.frames;
            render(left + done, right + done, next - done, done, b);
            done = next;
        }
        endBlock(b);
        return true;
    }

protected:
    // Once at the start of each block, before its first event or render(): a place to read the block's knob
    // values that note handling needs (a voice mode, a glide time). Does nothing unless overridden.
    virtual void beginBlock(const ProcessBlock&) noexcept {}
    // A note message, on the frame render() continues from.
    virtual void onNote(const NoteMessage& message) noexcept = 0;
    // Any other event (a controller, pitch bend): ignored unless overridden.
    virtual void onEvent(const Event&) noexcept {}
    // Once at the end of each block, after its last render(): where VoiceLanes::endBlock marks the ended notes.
    virtual void endBlock(const ProcessBlock&) noexcept {}
    // Writes `frames` frames to left and right (which start at frame `offset` of the block; read a
    // parameter with parameterAt(block, k, offset + i, fallback)).
    virtual void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& block) noexcept = 0;
};

// The voice bus from the instrument's side (#127; the protocol is CawVoiceBus in caw_component.h). An instrument
// declaring kDomainPerNote binds it in beginBlock() and, for each stretch [offset, offset + n) of the block it
// renders:
//     if (lanes.any()) {
//         lanes.begin(offset, n);                        // clears the assigned lanes' stretch
//         for each voice:
//             if (VoiceLane* lane = lanes.laneFor(voice.noteId)) render into lane->channels[c] + offset;
//             else render into the mix;
//         lanes.runAndSum(mixL, mixR, offset, n);        // the host's per-note FX, then every lane into the mix
//     }
// before its shared stage, and in endBlock() calls lanes.endBlock(playing), playing(noteId) saying whether a
// voice still plays that note. Every frame of the block goes through exactly one run(), also while no voice
// sounds (a lane's FX tail): an instrument that rests while idle keeps running while any() is true. Without a
// bus (voices null) any() is false and the instrument renders exactly as without this helper.
class VoiceLanes {
public:
    static constexpr uint32_t kMaxLanes = 64;  // lanes past this are left alone (their notes play in the mix)
    // The block's bus (b.voices), or none. Lanes the host has not assigned, or without two channels, are skipped.
    void bind(const ProcessBlock& b) noexcept {
        count_ = 0;
        bus_ = nullptr;
        rest_ = nullptr;
        const VoiceBus* bus = b.voices;
        if (!bus || bus->structSize < sizeof(VoiceBus) || bus->laneStride < sizeof(VoiceLane) || !bus->run ||
            bus->laneCount == 0 || !bus->lanes)
            return;
        for (uint32_t i = 0; i < bus->laneCount && count_ < kMaxLanes; ++i) {
            VoiceLane* lane = voiceLaneAt(*bus, i);
            if (lane->structSize < sizeof(VoiceLane) || !(lane->flags & kLaneAssigned) || lane->channelCount < 2 ||
                !lane->channels[0] || !lane->channels[1])
                continue;
            lane->flags &= kLaneAssigned | kLaneRest;  // the out bits are this block's
            if (lane->flags & kLaneRest) {
                if (!rest_) rest_ = lane;  // the overflow lane (one): voices without a lane of their own
            }
            lanes_[count_++] = lane;
        }
        if (count_) bus_ = bus;
    }
    bool any() const noexcept { return count_ != 0; }
    uint32_t count() const noexcept { return count_; }
    VoiceLane& lane(uint32_t k) const noexcept { return *lanes_[k]; }
    // The k (0..count()-1) of the lane for this note, or -1: a voice with none plays in the mix.
    int indexOf(uint32_t noteId) const noexcept {
        if (noteId == 0) return -1;
        for (uint32_t k = 0; k < count_; ++k)
            if (lanes_[k]->noteId == noteId) return static_cast<int>(k);
        return -1;
    }
    // The lane a voice playing this note renders into (marked written): its own, else the host's overflow lane
    // (kLaneRest) unless `rest` is false; null: the voice plays in the mix.
    VoiceLane* laneFor(uint32_t noteId, bool rest = true) noexcept {
        const int k = indexOf(noteId);
        VoiceLane* lane = k >= 0 ? lanes_[k] : rest ? rest_ : nullptr;
        if (lane) lane->flags |= kLaneWritten;
        return lane;
    }
    // Clears the stretch [offset, offset + n) of every lane, before voices render into it.
    void begin(uint32_t offset, uint32_t n) noexcept {
        for (uint32_t k = 0; k < count_; ++k)
            for (int c = 0; c < 2; ++c)
                for (uint32_t i = 0; i < n; ++i) lanes_[k]->channels[c][offset + i] = 0.0f;
    }
    // The host processes the lanes' stretch in place.
    void run(uint32_t offset, uint32_t n) noexcept {
        if (bus_) bus_->run(bus_->hostData, offset, n);
    }
    // Adds every lane's stretch into the mix, in lane order (left and right start at the stretch's first frame).
    void sumInto(float* left, float* right, uint32_t offset, uint32_t n) const noexcept {
        for (uint32_t k = 0; k < count_; ++k) {
            const float* l = lanes_[k]->channels[0] + offset;
            const float* r = lanes_[k]->channels[1] + offset;
            for (uint32_t i = 0; i < n; ++i) left[i] += l[i], right[i] += r[i];
        }
    }
    void runAndSum(float* left, float* right, uint32_t offset, uint32_t n) noexcept {
        run(offset, n);
        sumInto(left, right, offset, n);
    }
    // The note's voice stopped (it was stolen, say): its lane, if any, ends now.
    void end(uint32_t noteId) noexcept {
        const int k = indexOf(noteId);
        if (k >= 0) lanes_[k]->flags |= kLaneEnded;
    }
    // At the block's end: every lane whose note no voice plays (playing(noteId) false) has ended.
    template <class Playing>
    void endBlock(Playing&& playing) noexcept {
        for (uint32_t k = 0; k < count_; ++k)
            if (!(lanes_[k]->flags & kLaneRest) && !playing(lanes_[k]->noteId)) lanes_[k]->flags |= kLaneEnded;
    }

private:
    const VoiceBus* bus_ = nullptr;
    VoiceLane* rest_ = nullptr;
    VoiceLane* lanes_[kMaxLanes] = {};
    uint32_t count_ = 0;
};

// Fixed voices assigned by note id: a free voice, else the oldest released, else the oldest held
// (stolen). Voice needs the members `bool active`, `bool held`, `uint32_t noteId` and `uint64_t age`;
// start() sets them, the instrument clears `held` on its off and `active` when the voice is silent.
//
// N is the instrument's own polyphony: the host sets no limit of its own (owner, 2026-11-10), so a pool of
// hundreds of voices is fine. forEachActive() and find() walk only the voices sounding (start() lists a
// voice; one found silent is dropped from the list), so a large N costs memory, not time.
template <class Voice, uint32_t N>
class VoicePool {
public:
    static_assert(N > 0, "a pool needs at least one voice");
    static_assert(N <= 65535, "a pool holds up to 65535 voices");
    // With `lanes`, a voice stolen from a note that has a voice-bus lane ends that lane (VoiceLanes::end).
    Voice& start(uint32_t noteId, VoiceLanes* lanes = nullptr) noexcept {
        Voice* pick = nullptr;
        prune();
        if (live_ < N) {  // a free voice: one not sounding (the list holds every voice that is)
            pick = &voices_[free()];
        } else {
            for (int pass = 0; pass < 2 && !pick; ++pass)
                for (Voice& v : voices_)
                    if ((pass == 1 || !v.held) && (!pick || v.age < pick->age)) pick = &v;
        }
        const uint32_t index = static_cast<uint32_t>(pick - voices_);
        if (index >= touched_) touched_ = index + 1;
        if (!pick->active) list_[live_++] = static_cast<uint16_t>(index);
        else if (lanes && pick->noteId != noteId) lanes->end(pick->noteId);  // stolen
        pick->active = true;
        pick->held = true;
        pick->noteId = noteId;
        pick->age = ++clock_;
        return *pick;
    }
    // The voice playing note `noteId` (held or releasing), or null.
    Voice* find(uint32_t noteId) noexcept {
        prune();
        for (uint32_t i = 0; i < live_; ++i) {
            Voice& v = voices_[list_[i]];
            if (v.noteId == noteId) return &v;
        }
        return nullptr;
    }
    // f(voice) for each sounding voice, in the order they started; f may clear `active` (the voice is
    // then dropped from the list).
    template <class F>
    void forEachActive(F&& f) noexcept {
        uint32_t keep = 0;
        for (uint32_t i = 0; i < live_; ++i) {
            Voice& v = voices_[list_[i]];
            if (v.active) f(v);
            if (v.active) list_[keep++] = list_[i];
        }
        live_ = keep;
    }
    uint32_t activeCount() noexcept {
        prune();
        return live_;
    }
    // Drops the voices found silent from the list now. For an instrument that clears `active` after
    // forEachActive() has returned (a voice whose work it finished later in the period); never call it from
    // inside forEachActive(). Real-time safe: one pass over the sounding voices.
    void dropSilent() noexcept { prune(); }
    // The list's length as it stands, voices found silent but not yet dropped included (activeCount() drops
    // them first): what forEachActive() would walk.
    uint32_t listed() const noexcept { return live_; }
    Voice* begin() noexcept { return voices_; }
    Voice* end() noexcept { return voices_ + N; }
    // Only the voices started since the last clear are not as new (a free voice is the first by index, so they
    // are the first touched_): a Play doesn't rewrite the whole pool.
    void clear() noexcept {
        for (uint32_t i = 0; i < touched_; ++i) voices_[i] = Voice{};
        live_ = 0;
        touched_ = 0;
    }

private:
    void prune() noexcept {
        uint32_t keep = 0;
        for (uint32_t i = 0; i < live_; ++i)
            if (voices_[list_[i]].active) list_[keep++] = list_[i];
        live_ = keep;
    }
    // A voice not sounding, the first by index (with the list pruned, live_ < N means one exists).
    uint32_t free() noexcept {
        for (uint32_t i = 0; i < N; ++i)
            if (!voices_[i].active) return i;
        return 0;
    }
    Voice voices_[N]{};
    uint16_t list_[N]{};  // the sounding voices (and some found silent since), in the order they started
    uint32_t live_ = 0;
    uint32_t touched_ = N;  // voices_[touched_..N) are as new (Voice{}); unknown at first
    uint64_t clock_ = 0;
};

}  // namespace caw
