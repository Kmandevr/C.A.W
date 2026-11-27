// MIDI to external hardware and apps: a MIDI-out layer's notes as MIDI 1.0 bytes, and the timed queue the audio
// thread fills for a platform sender to drain (caw.h API 47, caw_engine_midi_out_drain).
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>

#include "note_events.h"
#include "project.h"
#include "spsc.h"

namespace caw {

constexpr int kMidiOutPorts = 16;  // ports 0..15 (a platform sender maps them to its devices)

// One outbound message, laid out as caw.h's CawMidiOutEvent (16 bytes): when it should reach the port, on the MIDI
// clock (caw_midi_clock_ns), which port, and a MIDI 1.0 channel or system message (1..3 bytes, never SysEx).
// reserved[0] carries kEssential inside the engine (the C API hands out zeros there).
struct MidiOutMessage {
    int64_t timeNs = 0;
    uint8_t port = 0;
    uint8_t size = 0;
    uint8_t data[3] = {0, 0, 0};
    uint8_t reserved[3] = {0, 0, 0};
};
static_assert(sizeof(MidiOutMessage) == 16, "MidiOutMessage is caw.h's 16-byte CawMidiOutEvent");
// A message that ends something (a note-off, the bend back to the centre, the clock's Stop): never dropped for
// being late, and it may use the room the queue keeps back, so no note is left hanging on a receiver.
constexpr uint8_t kMidiEssential = 1;

// The engine's outbound queue: written by the audio callback's thread only (after each chunk's graph, so tracks the
// mix pool runs at once never write it), read by one platform thread at a time. Preallocated.
// - A message that starts something (a note-on, a controller, a tick) takes at most kPerCallback places a callback and
//   none of the last kReserve, which ending messages alone may use (sixteen layers' worth of every key's note-off);
//   past either it is dropped and counted.
// - The consumer drops a starting message older than kMaxAgeNs when it drains (a sender that fell behind gets no
//   stale note-ons or ticks); an ending one is always handed out, however late.
class MidiOutQueue {
public:
    static constexpr size_t kCapacity = 8192;
    static constexpr size_t kReserve = 2048;
    static constexpr uint32_t kPerCallback = 1024;
    static constexpr int64_t kMaxAgeNs = 250'000'000;
    // Audio thread.
    void beginCallback() noexcept { thisCallback_ = 0; }
    bool push(const MidiOutMessage& m) noexcept {
        const bool essential = m.reserved[0] & kMidiEssential;
        if (!essential && (thisCallback_ >= kPerCallback || ring_.writable() <= kReserve)) {
            dropped_.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        if (!ring_.push(m)) {
            dropped_.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        if (!essential) ++thisCallback_;
        return true;
    }
    // The consumer (one thread at a time): up to `cap` messages in the order they were queued, those that start
    // something and are older than kMaxAgeNs at `nowNs` left out (and counted).
    int32_t drain(MidiOutMessage* out, int32_t cap, int64_t nowNs) noexcept {
        int32_t n = 0;
        MidiOutMessage m;
        while (n < cap && ring_.pop(m)) {
            if (!(m.reserved[0] & kMidiEssential) && m.timeNs < nowNs - kMaxAgeNs) {
                stale_.fetch_add(1, std::memory_order_relaxed);
                continue;
            }
            out[n++] = m;
        }
        return n;
    }
    // The consumer: everything queued goes (a sender attaching starts from now).
    void clear() noexcept {
        MidiOutMessage m;
        while (ring_.pop(m)) {}
    }
    uint64_t dropped() const noexcept {
        return dropped_.load(std::memory_order_relaxed) + stale_.load(std::memory_order_relaxed);
    }
    void countDropped(uint64_t n) noexcept { dropped_.fetch_add(n, std::memory_order_relaxed); }

private:
    Spsc<MidiOutMessage, kCapacity> ring_;
    std::atomic<uint64_t> dropped_{0}, stale_{0};
    uint32_t thisCallback_ = 0;
};

// A message waiting in a lane for the end of its chunk: its frame in the chunk, the port it was meant for when it
// was made (a port change's note-offs go to the old port), its bytes and whether it ends something.
struct MidiOutStaged {
    uint32_t frame = 0;
    uint8_t port = 0;
    uint8_t size = 0;
    uint8_t data[3] = {0, 0, 0};
    bool essential = false;
};

// The time of a callback's frame 0, smoothed: a delay-locked loop (after F. Adriaensen, "Using a DLL to filter
// time", 2005; written from the published method, not re-checked this session) driven by the frames each callback
// plays, fitted to the callbacks' wake-ups, so the scheduling jitter of a wake-up (milliseconds on Android) stays
// out of every message's time. A wake-up more than kResetNs from the prediction (a device restart, a stall) starts
// it again from that wake-up. Pure arithmetic: the audio thread.
class CallbackClock {
public:
    static constexpr int64_t kResetNs = 20'000'000;
    static constexpr double kBandwidthHz = 0.2;
    // This callback's frame 0 time for a wake-up at `wakeNs` of a callback of `frames` frames.
    int64_t anchor(int64_t wakeNs, int frames, double sampleRate) noexcept;
    void reset() noexcept { started_ = false; }

private:
    bool started_ = false;
    double pred_ = 0;          // the predicted wake-up of this callback, ns
    double nsPerFrame_ = 0;    // the estimated length of a frame, ns
    double nominal_ = 0;       // 1e9 / rate
    int lastFrames_ = 0;
};

using MidiOutConfig = MidiOutSpec;  // project.h: port, channel, program, bend range

// One MIDI-out layer on the audio thread: its notes (as an instrument's, so pattern notes, previews and device MIDI
// all arrive the same way) and the conversion of a block's events to MIDI 1.0 bytes on its channel. Made on the
// control thread (the NoteEvents storage), never freed while the Engine lives.
//
// MIDI 1.0 has one pitch bend per channel: a note's own pitch away from its key (a microtone, a glide, a bend)
// becomes the channel's bend, the last note's winning. Two notes on the same key overlap as a retrigger: the second
// on ends the first first, and the key's off goes out with the last one's off. Every key that sounds is counted,
// so allOff() can end each one (no stuck notes on stop, seek, mute, removal or a port change).
class MidiOutLane {
public:
    static constexpr uint32_t kStaged = 512;  // messages a lane holds in one chunk; more are dropped and counted
    MidiOutLane() = default;
    MidiOutLane(const MidiOutLane&) = delete;
    MidiOutLane& operator=(const MidiOutLane&) = delete;

    NoteEvents& notes() noexcept { return notes_; }
    const MidiOutConfig& config() const noexcept { return config_; }
    // Audio thread: a new configuration (allOff on the old one first when it sounds).
    void configure(const MidiOutConfig& c) noexcept;
    // Audio thread: this block's events (frame order, below `frames`) as bytes, staged. With `notesOn` false, note
    // ons are dropped (stopping, muted); offs and controllers still go.
    void convert(const Event* events, uint32_t count, bool notesOn) noexcept;
    // Audio thread: an off for every sounding key, the bend back to centre if it moved, at `frame`.
    void allOff(uint32_t frame) noexcept;
    // Audio thread: the program change, if it has one, at `frame` (Play and a changed program send it).
    void sendProgram(uint32_t frame) noexcept;
    bool sounding() const noexcept { return soundingKeys_ > 0; }
    // The chunk's staged messages, then cleared by the engine.
    const MidiOutStaged* staged() const noexcept { return staged_; }
    uint32_t stagedCount() const noexcept { return stagedCount_; }
    void clearStaged() noexcept { stagedCount_ = 0; }
    // Messages a full chunk dropped since the last call (the engine adds them to the queue's count).
    uint64_t takeOverflow() noexcept {
        const uint64_t n = overflow_;
        overflow_ = 0;
        return n;
    }
    // Bytes for one MIDI 2.0 (type 4) or MIDI 1.0 (type 2) Channel Voice UMP on `channel` (0..15), downscaled as the
    // UMP specification's translation does (the top bits). The count (0: nothing MIDI 1.0 carries); a program
    // change with its bank-valid bit writes the bank select CCs first (up to 9 bytes).
    static int umpToMidi1(const uint32_t* words, uint8_t channel, uint8_t* out) noexcept;

private:
    // Starting messages need room left for every sounding key's off and the bend's reset (`need`: places taken,
    // counting the off a new note will owe); ending ones always fit.
    bool room(uint32_t need) const noexcept {
        return stagedCount_ + need + static_cast<uint32_t>(soundingKeys_) + 1 <= kStaged;
    }
    void stage(uint32_t frame, uint8_t a, uint8_t b, uint8_t c, uint8_t size, bool essential = false) noexcept;
    void bendTo(uint32_t frame, double semitones, bool essential = false) noexcept;
    NoteEvents notes_;
    MidiOutConfig config_;
    uint8_t channel_ = 0;          // config_.channel - 1
    uint16_t keyCount_[128] = {};  // notes sounding on each key
    int soundingKeys_ = 0;         // keys with a count above 0
    uint16_t bend_ = 8192;         // the channel's 14-bit bend now
    MidiOutStaged staged_[kStaged];
    uint32_t stagedCount_ = 0;
    uint64_t overflow_ = 0;
};

// MIDI 1.0 system real-time and common bytes the clock sends.
namespace midibyte {
constexpr uint8_t kClock = 0xF8, kStart = 0xFA, kContinue = 0xFB, kStop = 0xFC, kSongPosition = 0xF2;
}

}  // namespace caw
