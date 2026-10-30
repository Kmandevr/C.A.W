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
            const int32_t signedValue = static_cast<int32_t>(w1);
            event.value = signedValue < 0
                ? static_cast<double>(signedValue) / 2147483648.0
                : static_cast<double>(signedValue) / 2147483647.0;
            event.index = index;
            break;
        }
        case 0xA:
            event.type = Midi2EventType::PolyPressure;
            event.value = static_cast<double>(w1) / 4294967295.0;
            break;
        case 0xB:
            event.type = Midi2EventType::ControlChange;
            event.index = index;
            event.value = static_cast<double>(w1) / 4294967295.0;
            break;
        case 0xD:
            event.type = Midi2EventType::ChannelPressure;
            event.value = static_cast<double>(w1) / 4294967295.0;
            break;
        case 0xE: {
            event.type = Midi2EventType::PitchBend;
            const int32_t signedValue = static_cast<int32_t>(w1);
            event.value = signedValue < 0
                ? static_cast<double>(signedValue) / 2147483648.0
                : static_cast<double>(signedValue) / 2147483647.0;
            break;
        }
        default:
            return false;
    }
    out = event;
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
