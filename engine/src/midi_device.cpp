// MIDI from hardware devices: edge conversion to MIDI 2.0, callback timing and the per-track device note state.
#include "midi_device.h"

#include <cmath>

namespace caw {

uint32_t midiScaleUp(uint32_t value, unsigned srcBits, unsigned dstBits) noexcept {
    if (srcBits == 0 || dstBits <= srcBits || dstBits > 32) return value;
    const uint32_t srcMax = srcBits >= 32 ? 0xFFFFFFFFu : (1u << srcBits) - 1u;
    value &= srcMax;
    const unsigned scaleBits = dstBits - srcBits;
    uint64_t shifted = static_cast<uint64_t>(value) << scaleBits;
    const uint32_t centre = 1u << (srcBits - 1);
    if (value <= centre) return static_cast<uint32_t>(shifted);
    const unsigned repeatBits = srcBits - 1;
    const uint32_t repeatMask = (1u << repeatBits) - 1u;
    uint64_t repeat = value & repeatMask;
    repeat = scaleBits > repeatBits ? repeat << (scaleBits - repeatBits) : repeat >> (repeatBits - scaleBits);
    while (repeat != 0) {
        shifted |= repeat;
        repeat >>= repeatBits;
    }
    return static_cast<uint32_t>(shifted);
}

int midi1DataBytes(uint8_t status) noexcept {
    switch (status & 0xF0) {
        case 0x80: case 0x90: case 0xA0: case 0xB0: case 0xE0: return 2;
        case 0xC0: case 0xD0: return 1;
        default: return 0;
    }
}

bool midi1ToUmp2(uint8_t status, uint8_t d1, uint8_t d2, uint8_t group, uint32_t out[2]) noexcept {
    if (status < 0x80 || status >= 0xF0) return false;
    uint8_t kind = status & 0xF0;
    const uint8_t ch = status & 0x0F;
    d1 &= 0x7F;
    d2 &= 0x7F;
    if (kind == 0x90 && d2 == 0) kind = 0x80;  // a Note On at velocity 0 is a Note Off
    uint32_t w0 = (0x4u << 28) | (static_cast<uint32_t>(group & 0xF) << 24) | (static_cast<uint32_t>(kind) << 16) |
                  (static_cast<uint32_t>(ch) << 16);
    uint32_t w1 = 0;
    switch (kind) {
        case 0x80:
        case 0x90:
            w0 |= static_cast<uint32_t>(d1) << 8;
            w1 = midiScaleUp(d2, 7, 16) << 16;
            break;
        case 0xA0:
            w0 |= static_cast<uint32_t>(d1) << 8;
            w1 = midiScaleUp(d2, 7, 32);
            break;
        case 0xB0:
            w0 |= static_cast<uint32_t>(d1) << 8;
            w1 = midiScaleUp(d2, 7, 32);
            break;
        case 0xC0:
            w1 = static_cast<uint32_t>(d1) << 24;
            break;
        case 0xD0:
            w1 = midiScaleUp(d1, 7, 32);
            break;
        case 0xE0:
            w1 = midiScaleUp(static_cast<uint32_t>(d2) << 7 | d1, 14, 32);
            break;
        default:
            return false;
    }
    out[0] = w0;
    out[1] = w1;
    return true;
}

bool ump1ToUmp2(uint32_t w0, uint32_t out[2]) noexcept {
    if ((w0 >> 28) != 0x2) return false;
    return midi1ToUmp2(static_cast<uint8_t>(w0 >> 16), static_cast<uint8_t>(w0 >> 8), static_cast<uint8_t>(w0),
                       static_cast<uint8_t>((w0 >> 24) & 0xF), out);
}

int umpWordCount(uint32_t w0) noexcept {
    switch (w0 >> 28) {
        case 0x0: case 0x1: case 0x2: case 0x6: case 0x7: return 1;
        case 0x3: case 0x4: case 0x8: case 0x9: case 0xA: return 2;
        case 0xB: case 0xC: return 3;
        default: return 4;
    }
}

int64_t deviceMidiFrame(int64_t timeNs, int64_t nowNs, int frames, double sampleRate, int64_t delayNs) noexcept {
    if (frames <= 0 || !(sampleRate > 0)) return 0;
    const double windowNs = frames * 1e9 / sampleRate;
    const double since = static_cast<double>(timeNs + delayNs) - (static_cast<double>(nowNs) - windowNs);
    if (!(since > 0)) return 0;
    const double f = std::floor(since * sampleRate / 1e9);
    return f > 1e12 ? static_cast<int64_t>(1e12) : static_cast<int64_t>(f);
}

void DeviceNotes::reset() noexcept {
    for (int c = 0; c < 16; ++c) {
        bend_[c] = 0;
        sustain_[c] = false;
    }
}

double DeviceNotes::channelBend(uint8_t ch, const DeviceMidiOptions& o) const noexcept {
    if (!o.mpe) return bend_[ch & 0xF] * o.bendRange;
    // MPE: the master channel (1) bends every note; a member channel bends its own note too.
    return bend_[0] * o.bendRange + (ch == 0 ? 0.0 : bend_[ch & 0xF] * o.noteBendRange);
}

void DeviceNotes::repitch(NoteEvents& notes, uint32_t frame, NoteEvents::Held& h, const DeviceMidiOptions& o) noexcept {
    const double p = h.pitch + channelBend(h.channel, o) + h.bend;
    notes.pitch(frame, h, p < 0 ? 0 : p > 127.99 ? 127.99 : p);
}

void DeviceNotes::apply(NoteEvents& notes, const Midi2Event& e, uint32_t frame, const DeviceMidiOptions& o) noexcept {
    const uint8_t ch = e.channel & 0xF;
    auto raw = [&] {
        Event ev;
        ev.frame = frame;
        ev.kind = EventKind::Midi;
        ev.noteId = 0;
        ev.data[0] = e.ump[0];
        ev.data[1] = e.ump[1];
        notes.push(ev);
    };
    auto each = [&](bool allChannels, auto&& f) {
        for (NoteEvents::Held& h : notes.held())
            if (h.active && h.source == NoteEvents::Source::Preview && isDevicePreview(h.preview) &&
                (allChannels || h.channel == ch))
                f(h);
    };
    auto release = [&](bool allChannels) {
        each(allChannels, [&](NoteEvents::Held& h) { notes.off(frame, h); });
    };
    switch (e.type) {
        case Midi2EventType::NoteOn: {
            const int32_t id = devicePreviewId(e.group, ch, e.note);
            // The key stays the device's (a drum pad learns it); an exact pitch (MIDI 2.0 attribute 3) or a bend
            // follows as the note's pitch.
            NoteEvents::Held& h = notes.on(frame, NoteEvents::Source::Preview, 0, 0, id, e.note, e.value, ch);
            if (!h.active) return;
            h.sentPress = -1;  // the first pressure the device sends is always heard
            if (e.attributeType == 3) h.bend = e.attributeData / 512.0 - e.note;
            if (h.bend != 0 || channelBend(ch, o) != 0) repitch(notes, frame, h, o);
            return;
        }
        case Midi2EventType::NoteOff: {
            NoteEvents::Held* h = notes.findPreview(devicePreviewId(e.group, ch, e.note));
            if (!h) return;
            if (sustain_[ch]) h->pedal = true;
            else notes.off(frame, *h);
            return;
        }
        case Midi2EventType::PolyPressure:
            if (NoteEvents::Held* h = notes.findPreview(devicePreviewId(e.group, ch, e.note)))
                notes.pressure(frame, *h, e.value);
            return;
        case Midi2EventType::PerNotePitch:
            if (NoteEvents::Held* h = notes.findPreview(devicePreviewId(e.group, ch, e.note))) {
                h->bend = e.value * o.noteBendRange;
                repitch(notes, frame, *h, o);
            }
            return;
        case Midi2EventType::PitchBend:
            bend_[ch] = e.value;
            each(o.mpe && ch == 0, [&](NoteEvents::Held& h) { repitch(notes, frame, h, o); });
            return;
        case Midi2EventType::ChannelPressure:
            raw();
            each(o.mpe && ch == 0, [&](NoteEvents::Held& h) { notes.pressure(frame, h, e.value); });
            return;
        case Midi2EventType::ControlChange:
            raw();
            if (e.index == 64) {
                sustain_[ch] = e.value >= 0.5;
                if (!sustain_[ch])
                    each(false, [&](NoteEvents::Held& h) {
                        if (h.pedal) notes.off(frame, h);
                    });
            } else if (e.index == 120 || e.index == 123) {
                sustain_[ch] = false;
                release(false);
            } else if (e.index == 74 && o.mpe && ch != 0) {
                each(false, [&](NoteEvents::Held& h) { notes.timbre(frame, h, e.value); });
            }
            return;
        case Midi2EventType::ProgramChange:
            raw();
            return;
        case Midi2EventType::AllOff:
            release(true);
            reset();
            return;
    }
}

}  // namespace caw
