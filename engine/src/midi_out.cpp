// MIDI-out layers: a block's note events (MIDI 2.0 UMP with host note ids) to MIDI 1.0 bytes on one channel.
#include "midi_out.h"

#include <algorithm>
#include <cmath>

namespace caw {

namespace {
constexpr uint32_t kStatusNoteOff = 0x8, kStatusNoteOn = 0x9, kStatusPolyPressure = 0xA, kStatusCc = 0xB,
                   kStatusProgram = 0xC, kStatusChannelPressure = 0xD, kStatusBend = 0xE, kStatusPerNoteReg = 0x0;
constexpr uint32_t kPitch79 = 3, kPitch725 = 3, kTimbre = 74;
inline uint8_t top7(uint32_t v32) noexcept { return static_cast<uint8_t>(v32 >> 25); }
}  // namespace

void MidiOutLane::configure(const MidiOutConfig& c) noexcept {
    MidiOutConfig next = c;
    next.port = std::clamp(next.port, 0, kMidiOutPorts - 1);
    next.channel = std::clamp(next.channel, 1, 16);
    next.program = std::clamp(next.program, -1, 127);
    if (!(next.bendRange >= 1.0 && next.bendRange <= 48.0)) next.bendRange = 2.0;
    const bool moved = next.port != config_.port || next.channel != config_.channel;
    if (moved && (sounding() || bend_ != 8192)) allOff(0);  // the old port and channel's notes end there
    config_ = next;
    channel_ = static_cast<uint8_t>(next.channel - 1);
}

void MidiOutLane::stage(uint32_t frame, uint8_t a, uint8_t b, uint8_t c, uint8_t size) noexcept {
    if (stagedCount_ >= kStaged) {
        ++overflow_;
        return;
    }
    MidiOutStaged& s = staged_[stagedCount_++];
    s.frame = frame;
    s.size = size;
    s.data[0] = a;
    s.data[1] = b;
    s.data[2] = c;
}

void MidiOutLane::bendTo(uint32_t frame, double semitones) noexcept {
    double v = 8192.0 + semitones / config_.bendRange * 8192.0;
    if (!std::isfinite(v)) v = 8192.0;
    const uint16_t bend = static_cast<uint16_t>(std::clamp(std::lround(v), 0L, 16383L));
    if (bend == bend_) return;
    bend_ = bend;
    stage(frame, static_cast<uint8_t>(0xE0 | channel_), static_cast<uint8_t>(bend & 0x7F),
          static_cast<uint8_t>(bend >> 7), 3);
}

void MidiOutLane::convert(const Event* events, uint32_t count, bool notesOn) noexcept {
    const uint8_t ch = channel_;
    for (uint32_t i = 0; i < count; ++i) {
        const Event& e = events[i];
        const uint32_t w0 = e.data[0], w1 = e.data[1];
        if (e.kind != EventKind::Note) {
            const uint32_t st = (w0 >> 20) & 0xF;
            if (st == kStatusNoteOn || st == kStatusNoteOff) continue;  // notes come as Note events (counted keys)
            uint8_t b[9];
            const int n = umpToMidi1(e.data, ch, b);
            for (int k = 0; k < n;) {  // whole messages: bank selects (3 each), then the message
                const uint8_t status = b[k];
                const int len = (status & 0xF0) == 0xC0 || (status & 0xF0) == 0xD0 ? 2 : 3;
                if (k + len > n) break;
                stage(e.frame, b[k], b[k + 1], len == 3 ? b[k + 2] : 0, static_cast<uint8_t>(len));
                k += len;
            }
            continue;
        }
        if ((w0 >> 28) != 0x4) continue;
        const uint32_t status = (w0 >> 20) & 0xF, index = w0 & 0xFF;
        const uint8_t key = static_cast<uint8_t>((w0 >> 8) & 0x7F);
        switch (status) {
            case kStatusNoteOn: {
                if (!notesOn) break;
                const double pitch = index == kPitch79 ? static_cast<double>(w1 & 0xFFFF) / 512.0 : key;
                bendTo(e.frame, pitch - key);
                uint8_t vel = static_cast<uint8_t>((w1 >> 16) >> 9);
                if (vel == 0) vel = 1;  // 0 would be an off
                if (keyCount_[key] > 0) {  // a retrigger: the key's sounding note ends first
                    stage(e.frame, static_cast<uint8_t>(0x80 | ch), key, 0, 3);
                } else {
                    ++soundingKeys_;
                }
                if (keyCount_[key] < 0xFFFF) ++keyCount_[key];
                stage(e.frame, static_cast<uint8_t>(0x90 | ch), key, vel, 3);
                break;
            }
            case kStatusNoteOff: {
                if (keyCount_[key] == 0) break;  // not sounding here (already ended by allOff, or never sent)
                if (--keyCount_[key] > 0) break;
                --soundingKeys_;
                stage(e.frame, static_cast<uint8_t>(0x80 | ch), key, static_cast<uint8_t>((w1 >> 16) >> 9), 3);
                break;
            }
            case kStatusPerNoteReg:
                if (keyCount_[key] == 0) break;
                if (index == kPitch725) bendTo(e.frame, static_cast<double>(w1) / 33554432.0 - key);
                else if (index == kTimbre) stage(e.frame, static_cast<uint8_t>(0xB0 | ch), 74, top7(w1), 3);
                break;
            case kStatusPolyPressure:
                if (keyCount_[key] > 0) stage(e.frame, static_cast<uint8_t>(0xA0 | ch), key, top7(w1), 3);
                break;
            default: break;
        }
    }
}

void MidiOutLane::allOff(uint32_t frame) noexcept {
    for (int k = 0; k < 128 && soundingKeys_ > 0; ++k) {
        if (keyCount_[k] == 0) continue;
        keyCount_[k] = 0;
        --soundingKeys_;
        stage(frame, static_cast<uint8_t>(0x80 | channel_), static_cast<uint8_t>(k), 0, 3);
    }
    soundingKeys_ = 0;
    bendTo(frame, 0.0);
}

void MidiOutLane::sendProgram(uint32_t frame) noexcept {
    if (config_.program >= 0) stage(frame, static_cast<uint8_t>(0xC0 | channel_), static_cast<uint8_t>(config_.program), 0, 2);
}

int MidiOutLane::umpToMidi1(const uint32_t* words, uint8_t channel, uint8_t* out) noexcept {
    const uint32_t w0 = words[0], w1 = words[1];
    const uint32_t type = w0 >> 28, status = (w0 >> 20) & 0xF;
    const uint8_t ch = channel & 0xF;
    if (type == 0x2) {  // MIDI 1.0 Channel Voice: the bytes as they are, on our channel
        const uint8_t d1 = (w0 >> 8) & 0x7F, d2 = w0 & 0x7F;
        out[0] = static_cast<uint8_t>(status << 4 | ch);
        if (status < 0x8) return 0;
        out[1] = d1;
        if (status == kStatusProgram || status == kStatusChannelPressure) return 2;
        out[2] = d2;
        return 3;
    }
    if (type != 0x4) return 0;
    switch (status) {
        case kStatusNoteOn:
        case kStatusNoteOff: {
            uint8_t vel = static_cast<uint8_t>((w1 >> 16) >> 9);
            if (status == kStatusNoteOn && vel == 0) vel = 1;
            out[0] = static_cast<uint8_t>(status << 4 | ch);
            out[1] = (w0 >> 8) & 0x7F;
            out[2] = vel;
            return 3;
        }
        case kStatusPolyPressure:
        case kStatusCc:
            out[0] = static_cast<uint8_t>(status << 4 | ch);
            out[1] = (w0 >> 8) & 0x7F;
            out[2] = top7(w1);
            return 3;
        case kStatusProgram: {
            int n = 0;
            if (w0 & 1) {  // bank valid: Bank Select MSB (CC 0) and LSB (CC 32) first
                out[n++] = static_cast<uint8_t>(0xB0 | ch);
                out[n++] = 0;
                out[n++] = (w1 >> 8) & 0x7F;
                out[n++] = static_cast<uint8_t>(0xB0 | ch);
                out[n++] = 32;
                out[n++] = w1 & 0x7F;
            }
            out[n++] = static_cast<uint8_t>(0xC0 | ch);
            out[n++] = (w1 >> 24) & 0x7F;
            return n;
        }
        case kStatusChannelPressure:
            out[0] = static_cast<uint8_t>(0xD0 | ch);
            out[1] = top7(w1);
            return 2;
        case kStatusBend: {
            const uint32_t v = w1 >> 18;  // 14 bits
            out[0] = static_cast<uint8_t>(0xE0 | ch);
            out[1] = v & 0x7F;
            out[2] = (v >> 7) & 0x7F;
            return 3;
        }
        default: return 0;  // per-note controllers and management have no MIDI 1.0 form here
    }
}

}  // namespace caw
