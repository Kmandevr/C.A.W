// Kick: a sine kick with a fast pitch drop at the start of each hit; any note plays it.
#include <caw/component.hpp>
#include <caw/instrument.hpp>
#include <caw/library/envelope.hpp>
#include <caw/library/oscillator.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {
    {"notes", caw::PortType::Event, caw::ChannelLayout::None, true, 0, false, 0.0f},
    caw::stereoOutput("out"),
};

caw::ParameterDescriptor knob(std::string_view id, std::string_view name, double def, double lo, double hi,
                              std::string_view unit = {}) {
    caw::ParameterDescriptor p;
    p.id = id;
    p.name = name;
    p.defaultValue = def;
    p.minimum = lo;
    p.maximum = hi;
    p.unit = unit;
    p.smoothingFrames = 480;
    return p;
}
enum : uint32_t { kTune, kPunch, kDecay, kVolume };
const caw::ParameterDescriptor kParams[] = {
    knob("tune", "Tune", 45, 30, 90, "Hz"),        // the pitch the kick settles at
    knob("punch", "Punch", 0.6, 0, 1),             // how far and how long the pitch drops from
    knob("decay", "Decay", 0.35, 0.05, 1.5, "s"),  // seconds until it fades out
    knob("volume", "Volume", 0.8, 0, 1),
};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.starter.kick";
    d.name = "Kick";
    d.role = caw::ModuleRole::Instrument;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 4;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

// One voice is enough: a new hit restarts the kick (a drum machine's kick works the same way).
class Kick final : public caw::InstrumentProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        reset();
        return true;
    }
    void reset() noexcept override {
        level_.clear();
        drop_.clear();
        phase_ = 0;
    }

protected:
    void onNote(const caw::NoteMessage& m) noexcept override {
        if (m.type != caw::NoteMessageType::On) return;
        velocity_ = m.velocity;
        phase_ = 0;  // every hit starts at the same point of the sine: the same click each time
        level_.trigger();
        drop_.trigger();
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const caw::ProcessBlock& b) noexcept override {
        const double tune = caw::parameterAt(b, kTune, offset, 45);
        const double punch = caw::parameterAt(b, kPunch, offset, 0.6);
        level_.set(0.001, caw::parameterAt(b, kDecay, offset, 0.35), rate_);
        drop_.set(0.0005, 0.04 + punch * 0.08, rate_);
        const double gain = caw::parameterAt(b, kVolume, offset, 0.8) * velocity_;
        for (uint32_t i = 0; i < frames; ++i) {
            const double d = drop_.next();
            // The pitch starts up to 8 times higher and falls along the square of the drop envelope.
            const double hz = tune * (1.0 + 7.0 * punch * d * d);
            const double y = caw::lib::sineWave(phase_) * level_.next() * gain;
            phase_ = caw::lib::wrap01(phase_ + hz / rate_);
            left[i] = right[i] = static_cast<float>(y);
        }
    }

private:
    caw::lib::AdEnvelope level_, drop_;
    double phase_ = 0, velocity_ = 1, rate_ = 48000;
};

}  // namespace

CAW_EXPORT_COMPONENT(Kick, kDescriptor)
