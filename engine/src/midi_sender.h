// The platform MIDI-out sender's portable part (caw.h API 48): drains an engine's MIDI-out queue (API 47), holds each
// message until its time, hands it to a platform send, and remembers each port's channels for the all-notes-off.
#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include <mutex>
#include <vector>

#include "midi_out.h"

namespace caw {

class Engine;

// Messages waiting for their time, earliest first; at one time in the order they came (the engine's order: a
// retrigger's note-off before its note-on). A binary heap of fixed capacity: no allocation after construction.
class MidiSendSchedule {
public:
    explicit MidiSendSchedule(size_t capacity) : heap_(capacity) {}
    bool push(const MidiOutMessage& m) noexcept;  // false when full (the message is not kept)
    bool empty() const noexcept { return size_ == 0; }
    size_t size() const noexcept { return size_; }
    size_t capacity() const noexcept { return heap_.size(); }
    // The earliest message's time; INT64_MAX when none.
    int64_t nextTime() const noexcept { return size_ ? heap_[0].m.timeNs : std::numeric_limits<int64_t>::max(); }
    // Takes the earliest message into [out] if its time is at or before [until].
    bool popDue(int64_t until, MidiOutMessage& out) noexcept;
    void clear() noexcept { size_ = 0; }

private:
    struct Item {
        MidiOutMessage m;
        uint64_t seq = 0;
    };
    static bool before(const Item& a, const Item& b) noexcept {
        return a.m.timeNs != b.m.timeNs ? a.m.timeNs < b.m.timeNs : a.seq < b.seq;
    }
    std::vector<Item> heap_;
    size_t size_ = 0;
    uint64_t seq_ = 0;
};

// Which of a port's 16 channels carried a channel message since the last all-notes-off, so a detach or a port's
// close sends CC 123 (All Notes Off) on just those.
class MidiChannelsUsed {
public:
    void note(const MidiOutMessage& m) noexcept {
        if (m.port < kMidiOutPorts && m.size >= 1 && m.data[0] >= 0x80 && m.data[0] < 0xF0)
            mask_[m.port] = static_cast<uint16_t>(mask_[m.port] | (1u << (m.data[0] & 0x0F)));
    }
    uint16_t mask(int port) const noexcept { return port >= 0 && port < kMidiOutPorts ? mask_[port] : 0; }
    // CC 123 at [timeNs] for each channel [port] used, into [out] (room for 16); forgets them. Returns the count.
    int takeNotesOff(int port, int64_t timeNs, MidiOutMessage* out) noexcept;

private:
    uint16_t mask_[kMidiOutPorts] = {};
};

// The Windows sender waits on QueryPerformanceCounter, and caw_midi_clock_ns is std::chrono::steady_clock, which
// MSVC's STL (clang-cl links it) computes from the counter as whole seconds plus the remainder's nanoseconds:
// ns = ticks / freq * 1e9 + ticks % freq * 1e9 / freq (its <chrono>; the 10 MHz and 24 MHz fast paths give the same
// values). The sender also measures the two clocks' offset once at start, so another STL's steady_clock would still
// line up.
int64_t qpcTicksToNs(int64_t ticks, int64_t freq) noexcept;
// The first counter tick whose time (qpcTicksToNs) is at or after [ns] (ns >= 0, freq > 0).
int64_t nsToQpcTicks(int64_t ns, int64_t freq) noexcept;

// How a sender thread waits after a pump: until [next] if that comes within [pollNs] (precisely: the message's
// time), else [pollNs] (coarsely: new messages may have been queued meanwhile).
struct MidiSendWait {
    int64_t untilNs;
    bool precise;
};
MidiSendWait midiSendWait(int64_t nowNs, int64_t nextNs, int64_t pollNs) noexcept;

// The process's one sender (caw_midi_out_start / _stop). Every member is thread-safe; never the audio thread.
class MidiSender {
public:
    static constexpr int64_t kStopped = -1;
    static constexpr size_t kCapacity = 8192 + 256;  // the engine queue's 8,192 and every port's notes-off
    using SendFn = void (*)(void* ctx, const MidiOutMessage& m);

    // Attaches [e]: its queue starts empty and fills from now (Engine::setMidiOutActive). True when attached (also
    // when it already was); false with no engine. Another engine attached is detached first, as detach(nowNs) does
    // (its owner may be gone: an Android activity made again in the same process).
    bool attach(Engine* e, int64_t nowNs) noexcept;
    // Detaches: the engine queues nothing more, held messages are dropped, and CC 123 goes on every channel each port
    // used, at endTime (after anything already handed out for the port); the next pumps send those, then report
    // kStopped.
    void detach(int64_t nowNs) noexcept;
    // detach(nowNs) if [e] is the attached engine (its destruction: no pump can reach it afterwards), in one hold of
    // the lock, so a concurrent stop and start can't make it detach another engine.
    void detachIf(Engine* e, int64_t nowNs) noexcept;
    bool attached() const noexcept;
    bool attachedTo(const Engine* e) const noexcept;
    // Drains the attached engine into the schedule, then sends every held message due by [nowNs] + [leadNs] (lead
    // clamped to 0..1 s), in time order, at most [maxSend] of them. Returns the next held message's time (INT64_MAX:
    // none; at or before now: maxSend stopped it), or kStopped once detached with nothing left to send.
    int64_t pump(int64_t nowNs, int64_t leadNs, SendFn send, void* ctx, int maxSend = 1 << 30) noexcept;
    // A port is closing or going to another device: CC 123 for each channel it used, into [out] (room for 16), at
    // endTime, to send to the old device before it closes. Its held messages stay for the next device.
    int takeNotesOff(int port, int64_t nowNs, MidiOutMessage* out) noexcept;
    // When a port's CC 123 goes: just after now + the last lead and after the last message handed out for the port,
    // so a receiver that schedules by timestamp never plays it before a note-on it already holds.
    int64_t endTime(int port, int64_t nowNs) const noexcept;
    // Messages the schedule had no room for.
    uint64_t dropped() const noexcept;

private:
    void detachLocked(int64_t nowNs) noexcept;
    int64_t endTimeLocked(int port, int64_t nowNs) const noexcept;
    mutable std::mutex lock_;
    Engine* engine_ = nullptr;
    MidiSendSchedule schedule_{kCapacity};
    MidiChannelsUsed used_;
    uint64_t dropped_ = 0;
    int64_t lead_ = 0;                        // the last pump's lead
    int64_t last_[kMidiOutPorts] = {};        // each port's latest time handed out (0: none)
};

MidiSender& midiSender();

}  // namespace caw
