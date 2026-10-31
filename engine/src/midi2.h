// Realtime-safe decoder for two-word MIDI 2.0 Channel Voice UMP messages.
#pragma once

#include <array>
#include <atomic>
#include <cstdint>

namespace caw {

enum class Midi2EventType : uint8_t {
    NoteOff, NoteOn, PolyPressure, PerNotePitch, ControlChange, ChannelPressure, PitchBend
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
};

// Decodes one MIDI 2.0 Channel Voice (message type 0x4) UMP.
// Returns false for other message types or unsupported statuses. No allocation.
bool decodeMidi2ChannelVoice(uint32_t word0, uint32_t word1, Midi2Event& out) noexcept;

class Midi2InputQueue {
public:
    static constexpr uint32_t kCapacity = 1024;
    static_assert((kCapacity & (kCapacity - 1)) == 0, "MIDI queue capacity must be a power of two");

    // One platform MIDI producer, one audio-thread consumer. Full queues drop newest events.
    bool push(const Midi2Event& event) noexcept;
    bool pop(Midi2Event& event) noexcept;
    uint32_t dropped() const noexcept { return dropped_.load(std::memory_order_relaxed); }

private:
    std::array<Midi2Event, kCapacity> events_{};
    alignas(64) std::atomic<uint32_t> write_{0};
    alignas(64) std::atomic<uint32_t> read_{0};
    std::atomic<uint32_t> dropped_{0};
};

}  // namespace caw
