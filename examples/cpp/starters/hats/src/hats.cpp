// Hats: high-passed noise hi-hats, closed on most notes and open on A#2 (46); an open hat is choked by the next hit.
#include <caw/component.hpp>
#include <caw/instrument.hpp>
#include <caw/library/envelope.hpp>
#include <caw/library/filter.hpp>
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
    p.curve = unit == "Hz" || unit == "s" ? caw::ParameterCurve::Exponential : caw::ParameterCurve::Linear;
    p.smoothingFrames = 480;
    return p;
}
enum : uint32_t { kTone, kClosed, kOpen, kVolume };
const caw::ParameterDescriptor kParams[] = {
    knob("tone", "Tone", 7000, 2000, 12000, "Hz"),    // lowest frequency let through: higher is thinner
    knob("closed", "Closed decay", 0.04, 0.01, 0.2, "s"),
    knob("open", "Open decay", 0.25, 0.05, 1.0, "s"),
    knob("volume", "Volume", 0.5, 0, 1),
};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.starter.hats";
    d.name = "Hats";
    d.role = caw::ModuleRole::Instrument;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 4;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

constexpr int kOpenKey = 46;  // A#2, the General MIDI open hi-hat

class Hats final : public caw::InstrumentProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        reset();
        return true;
    }
    void reset() noexcept override {
        env_.clear();
        filter_ = {};
        noise_.reset();
    }

protected:
    void onNote(const caw::NoteMessage& m) noexcept override {
        if (m.type != caw::NoteMessageType::On) return;
        open_ = m.key == kOpenKey;
        velocity_ = m.velocity;
        env_.trigger();  // one voice: a closed hat cuts an open one off, as on a real kit
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const caw::ProcessBlock& b) noexcept override {
        filter_.set(caw::parameterAt(b, kTone, offset, 7000), 1.2, rate_);
        env_.set(0.0005, open_ ? caw::parameterAt(b, kOpen, offset, 0.25) : caw::parameterAt(b, kClosed, offset, 0.04), rate_);
        const double gain = caw::parameterAt(b, kVolume, offset, 0.5) * velocity_;
        for (uint32_t i = 0; i < frames; ++i) {
            // The noise runs on between hits, so each hit sounds slightly different (and the same on every render).
            const double y = filter_.process(noise_.next()).high * env_.next() * gain;
            left[i] = right[i] = static_cast<float>(y);
        }
    }

private:
    caw::lib::AdEnvelope env_;
    caw::lib::Svf filter_;
    caw::lib::Noise noise_{7};
    bool open_ = false;
    double velocity_ = 1, rate_ = 48000;
};

}  // namespace

CAW_EXPORT_COMPONENT(Hats, kDescriptor)
