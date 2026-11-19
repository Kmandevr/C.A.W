// Realtime-safe decoder for two-word MIDI 2.0 Channel Voice UMP messages.
#pragma once

#include <array>
#include <atomic>
#include <cstdint>

namespace caw {

enum class Midi2EventType : uint8_t {
    NoteOff, NoteOn, PolyPressure, PerNotePitch, ControlChange, ChannelPressure, PitchBend, ProgramChange,
    AllOff  // the host's own: every device note on the target ends (a device went away); never decoded
};

struct Midi2Event {
    Midi2EventType type = Midi2EventType::NoteOn;
    uint8_t group = 0;
    uint8_t channel = 0;
    uint8_t note = 0;
    uint8_t index = 0;
    uint8_t attributeType = 0;
    uint16_t attributeData = 0;
    double value = 0.0; // normalized 0..1, or signed -1..1 for pitch bend
    // Set by the host's device input (midi_device.h), not by the decoder: the message's MIDI 2.0 Channel Voice
    // words (a MIDI 1.0 message arrives upscaled), its time on the MIDI clock (ns) and the slot it is for.
    uint32_t ump[2] = {0, 0};
    int64_t timeNs = 0;
    int32_t target = -1;
    uint32_t seq = 0;  // set by Midi2InputQueue::push: the producer's order (the consumer sorts by frame, then this)
};

// Decodes one MIDI 2.0 Channel Voice (message type 0x4) UMP.
// Returns false for other message types or unsupported statuses. No allocation. Program Change (0xC) puts the
// program in index (value = program / 127).
bool decodeMidi2ChannelVoice(uint32_t word0, uint32_t word1, Midi2Event& out) noexcept;

// A Control Change from a UMP: MIDI 1.0 Channel Voice (type 0x2, 7-bit value) or MIDI 2.0 Channel
// Voice (type 0x4, 32-bit value). value is normalized 0..1 (v / 127 or v / 0xFFFFFFFF). words
// holds the UMP's words (at least two readable). False for anything that is not a Control Change.
struct UmpControlChange {
    uint8_t group = 0;
    uint8_t channel = 0;
    uint8_t controller = 0;
    double value = 0.0;
};
bool decodeControlChange(const uint32_t* words, UmpControlChange& out) noexcept;

// Device MIDI from one producer at a time (the caller's mutex) to the audio thread: one SPSC ring whose last
// kReserved slots only releases (note offs, sustain off, All Sound Off, All Notes Off, the host's AllOff) may take,
// so a flood never loses a note off. Every message gets a sequence number. Under pressure (the shared slots full),
// continuous values (controllers, bend, pressure, per-note pitch) merge on the producer side by (target, group,
// channel, note or none, kind, index) into a small fixed table that flush() and later pushes move into the ring,
// oldest first, as space returns; note ons, program changes, RPN/NRPN and bank select never merge and drop when
// full. pop never allocates or locks.
class Midi2InputQueue {
public:
    static constexpr uint32_t kCapacity = 1024;
    static constexpr uint32_t kReserved = 128;  // the ring's last slots: releases only
    static constexpr uint32_t kMergeSlots = 256;
    static_assert((kCapacity & (kCapacity - 1)) == 0, "MIDI queue capacity must be a power of two");
    static_assert(kReserved < kCapacity, "the reserve leaves shared slots");

    // Producer side (never the audio thread). True when queued or merged; false when dropped (counted).
    bool push(const Midi2Event& event) noexcept;
    void flush() noexcept;  // merged values into the ring while shared slots are free
    uint32_t mergedCount() const noexcept { return mergedCount_; }
    // Consumer side (the audio thread).
    bool pop(Midi2Event& event) noexcept;
    uint32_t dropped() const noexcept { return dropped_.load(std::memory_order_relaxed); }

    static bool releases(const Midi2Event& event) noexcept;   // may take the reserve
    static bool mergeable(const Midi2Event& event) noexcept;  // a continuous value

private:
    bool put(const Midi2Event& event, uint32_t limit) noexcept;
    void removeMerged(uint32_t i) noexcept;
    static bool sameKey(const Midi2Event& a, const Midi2Event& b) noexcept;

    std::array<Midi2Event, kCapacity> events_{};
    alignas(64) std::atomic<uint32_t> write_{0};
    alignas(64) std::atomic<uint32_t> read_{0};
    std::atomic<uint32_t> dropped_{0};
    // Producer only: merged values, oldest (lowest sequence) first, and the next sequence number.
    std::array<Midi2Event, kMergeSlots> merged_{};
    uint32_t mergedCount_ = 0;
    uint32_t seq_ = 0;
};

}  // namespace caw
