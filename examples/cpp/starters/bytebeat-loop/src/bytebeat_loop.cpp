// Bytebeat loop: a shifting bytebeat riff that plays while a note is held (C4 plays it at 8 kHz, other notes transpose it); slide shift to change the rhythm.
#include <cstdint>

#include <caw/component.hpp>
#include <caw/instrument.hpp>
#include <caw/library/oscillator.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {
    {"notes", caw::PortType::Event, caw::ChannelLayout::None, true, 0, false, 0.0f},
    caw::stereoOutput("out"),
};

caw::ParameterDescriptor shift() {
    caw::ParameterDescriptor p;
    p.id = "shift";
    p.name = "Shift";  // which bits of t drive the rhythm
    p.defaultValue = 6;
    p.minimum = 1;
    p.maximum = 12;
    p.step = 1;
    return p;
}
caw::ParameterDescriptor volume() {
    caw::ParameterDescriptor p;
    p.id = "volume";
    p.name = "Volume";
    p.defaultValue = 0.4;
    p.smoothingFrames = 480;
    return p;
}
enum : uint32_t { kShift, kVolume };
const caw::ParameterDescriptor kParams[] = {shift(), volume()};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.starter.bytebeat-loop";
    d.name = "Bytebeat loop";
    d.role = caw::ModuleRole::Instrument;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 2;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

// The formula: a melody from t times a slowly changing multiplier, and a rhythm from two shifted copies of t.
// Every value is cut to its low 8 bits, as in classic bytebeat. (Original to C.A.W.)
uint8_t formula(uint32_t t, uint32_t shift) noexcept {
    const uint32_t melody = (t * (2 + ((t >> 11) & 3))) >> ((t >> 13) & 1);
    const uint32_t rhythm = (t >> shift) & (t >> 3);
    return static_cast<uint8_t>((melody & 160) + (rhythm & 63));
}

class BytebeatLoop final : public caw::InstrumentProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        reset();
        return true;
    }
    void reset() noexcept override {
        held_ = 0;
        level_ = 0;
        position_ = 0;
    }

protected:
    void onNote(const caw::NoteMessage& m) noexcept override {
        if (m.type == caw::NoteMessageType::On) {
            if (held_++ == 0) position_ = 0;  // the riff starts from t = 0 on the first note
            step_ = 8000.0 * caw::lib::noteHz(m.pitch) / caw::lib::noteHz(60) / rate_;
            velocity_ = m.velocity;
        } else if (m.type == caw::NoteMessageType::Off && held_ > 0) {
            --held_;
        }
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const caw::ProcessBlock& b) noexcept override {
        const uint32_t sh = static_cast<uint32_t>(caw::parameterAt(b, kShift, offset, 6));
        const double gain = caw::parameterAt(b, kVolume, offset, 0.4) * velocity_;
        const double fade = 1.0 / (0.005 * rate_);  // 5 ms in and out: no click at the note's edges
        for (uint32_t i = 0; i < frames; ++i) {
            level_ = held_ > 0 ? (level_ + fade < 1 ? level_ + fade : 1) : (level_ - fade > 0 ? level_ - fade : 0);
            if (level_ <= 0) {
                left[i] = right[i] = 0.0f;
                continue;
            }
            // t counts at the bytebeat rate and holds between counts: the stair steps are the sound.
            const uint32_t t = static_cast<uint32_t>(static_cast<uint64_t>(position_));
            position_ += step_;
            const double y = (formula(t, sh < 1 ? 1 : (sh > 12 ? 12 : sh)) / 128.0 - 1.0) * level_ * gain;
            left[i] = right[i] = static_cast<float>(y);
        }
    }

private:
    int held_ = 0;
    double position_ = 0, step_ = 1.0 / 6.0, level_ = 0, velocity_ = 1, rate_ = 48000;
};

}  // namespace

CAW_EXPORT_COMPONENT(BytebeatLoop, kDescriptor)
