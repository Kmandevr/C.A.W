// Realtime-safe decoder for two-word MIDI 2.0 Channel Voice UMP messages.
#pragma once

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

}  // namespace caw
