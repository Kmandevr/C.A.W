// MIDI 2.0 Universal MIDI Packet decoding and conversion to MIDI 1.0 events for device input (#31).
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

bool Midi2InputQueue::releases(const Midi2Event& e) noexcept {
    if (e.type == Midi2EventType::NoteOff || e.type == Midi2EventType::AllOff) return true;
    if (e.type != Midi2EventType::ControlChange) return false;
    return e.index == 120 || e.index == 123 || (e.index == 64 && e.value < 0.5);  // as DeviceNotes reads the pedal
}

bool Midi2InputQueue::mergeable(const Midi2Event& e) noexcept {
    switch (e.type) {
        case Midi2EventType::PolyPressure:
        case Midi2EventType::PerNotePitch:
        case Midi2EventType::ChannelPressure:
        case Midi2EventType::PitchBend: return true;
        case Midi2EventType::ControlChange:
            switch (e.index) {
                case 0: case 32:                                   // bank select: goes with a program change
                case 6: case 38: case 96: case 97:                 // RPN/NRPN data entry, increment, decrement
                case 98: case 99: case 100: case 101: return false;  // NRPN/RPN select
                default: return e.index < 120 && !releases(e);  // channel mode messages are not values
            }
        default: return false;
    }
}

bool Midi2InputQueue::sameKey(const Midi2Event& a, const Midi2Event& b) noexcept {
    const bool perNote = a.type == Midi2EventType::PolyPressure || a.type == Midi2EventType::PerNotePitch;
    return a.type == b.type && a.target == b.target && a.group == b.group && a.channel == b.channel &&
           (!perNote || a.note == b.note) && (a.type != Midi2EventType::ControlChange || a.index == b.index);
}

bool Midi2InputQueue::put(const Midi2Event& event, uint32_t limit) noexcept {
    const uint32_t write = write_.load(std::memory_order_relaxed);
    if (write - read_.load(std::memory_order_acquire) >= limit) return false;
    events_[write & (kCapacity - 1)] = event;
    write_.store(write + 1, std::memory_order_release);
    return true;
}

void Midi2InputQueue::removeMerged(uint32_t i) noexcept {
    for (uint32_t k = i + 1; k < mergedCount_; ++k) merged_[k - 1] = merged_[k];
    --mergedCount_;
}

void Midi2InputQueue::flush() noexcept {
    uint32_t moved = 0;
    while (moved < mergedCount_ && put(merged_[moved], kCapacity - kReserved)) ++moved;
    if (moved == 0) return;
    for (uint32_t k = moved; k < mergedCount_; ++k) merged_[k - moved] = merged_[k];
    mergedCount_ -= moved;
}

bool Midi2InputQueue::push(const Midi2Event& event) noexcept {
    Midi2Event e = event;
    e.seq = seq_++;
    bool ok = false;
    if (releases(e)) {
        // A sustain off supersedes a sustain on still waiting here, which would otherwise land after it.
        if (e.type == Midi2EventType::ControlChange)
            for (uint32_t i = 0; i < mergedCount_; ++i)
                if (sameKey(merged_[i], e)) {
                    removeMerged(i);
                    break;
                }
        ok = put(e, kCapacity);
    } else {
        flush();
        const bool pressure = mergedCount_ > 0 || write_.load(std::memory_order_relaxed) -
                                                          read_.load(std::memory_order_acquire) >= kCapacity - kReserved;
        if (pressure && mergeable(e)) {
            // The key's latest value, moved to the end (it is now the newest).
            uint32_t i = 0;
            while (i < mergedCount_ && !sameKey(merged_[i], e)) ++i;
            if (i < mergedCount_) removeMerged(i);
            if (mergedCount_ < kMergeSlots) {
                merged_[mergedCount_++] = e;
                ok = true;
            }
        } else if (!pressure) {
            ok = put(e, kCapacity - kReserved);
        }
    }
    if (!ok) dropped_.fetch_add(1, std::memory_order_relaxed);
    return ok;
}

bool Midi2InputQueue::pop(Midi2Event& event) noexcept {
    const uint32_t read = read_.load(std::memory_order_relaxed);
    if (read == write_.load(std::memory_order_acquire)) return false;
    event = events_[read & (kCapacity - 1)];
    read_.store(read + 1, std::memory_order_release);
    return true;
}

}  // namespace caw
