// C.A.W. SDK: helpers for writing a modulator (#161): modulation-output ports, a base class, note decoding, held notes and control-rate ramps; header-only.
#pragma once

#include <cmath>
#include <cstdint>
#include <string_view>

#include "module.hpp"

namespace caw::mod {

// A modulator is a component whose outputs are CAW_PORT_MODULATION ports (one float per frame, 0..1), with at most
// one event input (the notes of the track it listens to) and at most one audio input (that track's audio). The
// project's modulation links route each output to any knob, track volume, pan or send level (docs/engine.md,
// "Modulation"). The host runs modulators in blocks of 16 frames on a fixed grid, so their output does not depend
// on the device's buffer size; it clamps outputs to 0..1 and turns NaN into 0.
inline constexpr uint32_t kMaxOutputs = 8;

// Port descriptors for a modulator's descriptor.
constexpr PortDescriptor output(std::string_view id) noexcept {
    PortDescriptor p;
    p.id = id;
    p.type = PortType::Modulation;
    p.layout = ChannelLayout::None;
    p.input = false;
    return p;
}
constexpr PortDescriptor notesInput(std::string_view id = "notes") noexcept {
    PortDescriptor p;
    p.id = id;
    p.type = PortType::Event;
    p.layout = ChannelLayout::None;
    p.input = true;
    return p;
}
constexpr PortDescriptor audioInput(std::string_view id = "audio", ChannelLayout layout = ChannelLayout::Stereo) noexcept {
    return audioPort(id, true, layout);
}

// One decoded MIDI 2.0 channel-voice message from an Event (UMP message type 4).
struct NoteMessage {
    enum class Kind : uint8_t { None, NoteOn, NoteOff, PolyPressure, ChannelPressure, PitchBend, Controller };
    Kind kind = Kind::None;
    uint32_t frame = 0;
    uint32_t noteId = 0;
    uint8_t channel = 0;
    uint8_t key = 0;        // note number, or controller number
    double velocity = 0.0;  // note on/off: 0..1
    double value = 0.0;     // pressure and controllers: 0..1; pitch bend: -1..1
};

inline NoteMessage decode(const Event& e) noexcept {
    NoteMessage m;
    m.frame = e.frame;
    m.noteId = e.noteId;
    const uint32_t w0 = e.data[0], w1 = e.data[1];
    if (((w0 >> 28) & 0xFu) != 0x4u) return m;
    const uint32_t status = (w0 >> 20) & 0xFu;
    m.channel = static_cast<uint8_t>((w0 >> 16) & 0xFu);
    m.key = static_cast<uint8_t>((w0 >> 8) & 0x7Fu);
    switch (status) {
        case 0x9: m.kind = NoteMessage::Kind::NoteOn; m.velocity = static_cast<double>(w1 >> 16) / 65535.0; break;
        case 0x8: m.kind = NoteMessage::Kind::NoteOff; m.velocity = static_cast<double>(w1 >> 16) / 65535.0; break;
        case 0xA: m.kind = NoteMessage::Kind::PolyPressure; m.value = static_cast<double>(w1) / 4294967295.0; break;
        case 0xD: m.kind = NoteMessage::Kind::ChannelPressure; m.value = static_cast<double>(w1) / 4294967295.0; break;
        case 0xB: m.kind = NoteMessage::Kind::Controller; m.value = static_cast<double>(w1) / 4294967295.0; break;
        case 0xE: m.kind = NoteMessage::Kind::PitchBend; m.value = static_cast<double>(w1) / 2147483648.0 - 1.0; break;
        default: break;
    }
    return m;
}

// The notes held now (up to kMax; a new one past it replaces the oldest), in the order they started.
class HeldNotes {
public:
    static constexpr uint32_t kMax = 32;
    struct Note {
        uint8_t key = 0;
        double velocity = 0.0;
    };
    // Updates from one message; true when it changed which notes are held.
    bool apply(const NoteMessage& m) noexcept {
        if (m.kind == NoteMessage::Kind::NoteOn) {
            remove(m.key);
            if (count_ == kMax) shift(0);
            notes_[count_++] = {m.key, m.velocity};
            return true;
        }
        if (m.kind == NoteMessage::Kind::NoteOff) return remove(m.key);
        return false;
    }
    void clear() noexcept { count_ = 0; }
    uint32_t count() const noexcept { return count_; }
    bool any() const noexcept { return count_ > 0; }
    const Note* last() const noexcept { return count_ ? &notes_[count_ - 1] : nullptr; }
    const Note* highest() const noexcept { return pick(true); }
    const Note* lowest() const noexcept { return pick(false); }

private:
    bool remove(uint8_t key) noexcept {
        for (uint32_t i = 0; i < count_; ++i)
            if (notes_[i].key == key) {
                shift(i);
                return true;
            }
        return false;
    }
    void shift(uint32_t i) noexcept {
        for (uint32_t k = i + 1; k < count_; ++k) notes_[k - 1] = notes_[k];
        --count_;
    }
    const Note* pick(bool high) const noexcept {
        const Note* best = nullptr;
        for (uint32_t i = 0; i < count_; ++i)
            if (!best || (high ? notes_[i].key > best->key : notes_[i].key < best->key)) best = &notes_[i];
        return best;
    }
    Note notes_[kMax] = {};
    uint32_t count_ = 0;
};

// Control-rate output with smoothing: work a value out once per block and let ramp() draw a straight line to it
// from where the last block ended, so the output has no steps.
class Ramp {
public:
    void ramp(float* out, uint32_t frames, double target) noexcept {
        const double t = std::isfinite(target) ? target : 0.0;
        if (fresh_) value_ = t, fresh_ = false;
        const double step = frames ? (t - value_) / static_cast<double>(frames) : 0.0;
        for (uint32_t i = 0; i < frames; ++i) out[i] = static_cast<float>(value_ += step);
        value_ = t;
    }
    void reset() noexcept { fresh_ = true; }
    double value() const noexcept { return value_; }

private:
    double value_ = 0.0;
    bool fresh_ = true;
};

// What a modulator sees each block.
struct Block {
    uint32_t frames = 0;
    double sampleRate = 48000.0;
    EventInput notes;                            // empty without an event input
    const ConstChannelBufferView* audio = nullptr;  // null without an audio input
    float* const* outputs = nullptr;             // `outputCount` buffers of `frames` floats
    uint32_t outputCount = 0;
    const ParameterValue* parameters = nullptr;
    uint32_t parameterCount = 0;
    const Transport* transport = nullptr;        // null while the host has none

    // Parameter k at the block's first frame (`fallback` when the host resolved none).
    double param(uint32_t k, double fallback = 0.0) const noexcept {
        return parameters && k < parameterCount ? parameters[k].value : fallback;
    }
    // The song position in beats at frame `at`, while it plays.
    bool beatAt(uint32_t at, double& beat) const noexcept {
        if (!transport || !transport->playing) return false;
        beat = transport->beat + static_cast<double>(at) * transport->tempo / (60.0 * sampleRate);
        return true;
    }
    double tempo() const noexcept { return transport && transport->tempo > 0.0 ? transport->tempo : 120.0; }
};

// Base class: derive, give a descriptor with modulation outputs (mod::output), and implement render().
class Modulator : public ModuleProcessor {
public:
    bool usesProcessPorts() const noexcept override { return true; }
    bool activate(double sampleRate, uint32_t maxFrames) noexcept override {
        (void)maxFrames;
        sampleRate_ = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
        reset();
        return true;
    }
    bool processPorts(const ProcessBlock& b) noexcept override {
        if (b.frames == 0 || !b.modulationOut || b.modulationOutCount == 0) return false;
        Block block;
        block.frames = b.frames;
        block.sampleRate = b.sampleRate > 0.0 ? b.sampleRate : sampleRate_;
        if (b.eventIn && b.eventInCount > 0) block.notes = b.eventIn[0];
        if (b.audioIn && b.audioInCount > 0) block.audio = &b.audioIn[0];
        block.outputs = b.modulationOut;
        block.outputCount = b.modulationOutCount;
        block.parameters = b.parameters;
        block.parameterCount = b.parameterCount;
        block.transport = b.transport;
        return render(block);
    }

protected:
    // Fill every output with `frames` values 0..1. False fails the block (the host then outputs 0).
    virtual bool render(const Block& block) noexcept = 0;
    double sampleRate() const noexcept { return sampleRate_; }

private:
    double sampleRate_ = 48000.0;
};

}  // namespace caw::mod
