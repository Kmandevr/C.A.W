#include "midi2.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace caw {

bool decodeMidi2ChannelVoice(uint32_t w0, uint32_t w1, Midi2Event& out) noexcept {
    if ((w0 >> 28) != 0x4) return false;
    const uint8_t status = static_cast<uint8_t>((w0 >> 20) & 0x0F);
    Midi2Event event;
    event.group = static_cast<uint8_t>((w0 >> 24) & 0x0F);
    event.channel = static_cast<uint8_t>((w0 >> 16) & 0x0F);
    event.note = static_cast<uint8_t>((w0 >> 8) & 0x7F);
    const uint8_t index = static_cast<uint8_t>(w0 & 0x7F);
    switch (status) {
        case 0x8:
            event.type = Midi2EventType::NoteOff;
            event.value = static_cast<double>(w1 >> 16) / 65535.0;
            event.attributeType = index;
            event.attributeData = static_cast<uint16_t>(w1 & 0xFFFF);
            break;
        case 0x9:
            event.type = Midi2EventType::NoteOn;
            event.value = static_cast<double>(w1 >> 16) / 65535.0;
            event.attributeType = index;
            event.attributeData = static_cast<uint16_t>(w1 & 0xFFFF);
            if (event.value <= 0.0) event.type = Midi2EventType::NoteOff;
            break;
        case 0x6: {
            event.type = Midi2EventType::PerNotePitch;
            event.value = (static_cast<double>(w1) - 2147483648.0) / 2147483648.0;
            event.index = index;
            break;
        }
        case 0xA:
            event.type = Midi2EventType::PolyPressure;
            event.value = static_cast<double>(w1) / 4294967295.0;
            break;
        case 0xB:
            // Control Change: the index is byte 3 (byte 4 is reserved), unlike per-note messages.
            event.type = Midi2EventType::ControlChange;
            event.index = event.note;
            event.note = 0;
            event.value = static_cast<double>(w1) / 4294967295.0;
            break;
        case 0xD:
            event.type = Midi2EventType::ChannelPressure;
            event.value = static_cast<double>(w1) / 4294967295.0;
            break;
        case 0xC:
            // Program Change: the program is byte 1 of word 1 (the bank, when its flag is set, is not used).
            event.type = Midi2EventType::ProgramChange;
            event.note = 0;
            event.index = static_cast<uint8_t>((w1 >> 24) & 0x7F);
            event.value = static_cast<double>(event.index) / 127.0;
            break;
        case 0xE: {
            event.type = Midi2EventType::PitchBend;
            event.value = (static_cast<double>(w1) - 2147483648.0) / 2147483648.0;
            break;
        }
        default:
            return false;
    }
    out = event;
    return true;
}

bool decodeControlChange(const uint32_t* words, UmpControlChange& out) noexcept {
    const uint32_t w0 = words[0];
    const uint32_t type = w0 >> 28;
    if ((type != 0x2 && type != 0x4) || ((w0 >> 20) & 0x0F) != 0xB) return false;
    out.group = static_cast<uint8_t>((w0 >> 24) & 0x0F);
    out.channel = static_cast<uint8_t>((w0 >> 16) & 0x0F);
    out.controller = static_cast<uint8_t>((w0 >> 8) & 0x7F);
    out.value = type == 0x2 ? static_cast<double>(w0 & 0x7F) / 127.0 : static_cast<double>(words[1]) / 4294967295.0;
    return true;
}

bool Midi2InputQueue::push(const Midi2Event& event) noexcept {
    const uint32_t write = write_.load(std::memory_order_relaxed);
    const uint32_t next = write + 1;
    if (next - read_.load(std::memory_order_acquire) > kCapacity) {
        dropped_.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    events_[write & (kCapacity - 1)] = event;
    write_.store(next, std::memory_order_release);
    return true;
}

bool Midi2InputQueue::pop(Midi2Event& event) noexcept {
    const uint32_t read = read_.load(std::memory_order_relaxed);
    if (read == write_.load(std::memory_order_acquire)) return false;
    event = events_[read & (kCapacity - 1)];
    read_.store(read + 1, std::memory_order_release);
    return true;
}

}  // namespace caw
