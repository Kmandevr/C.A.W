// Glitch: flips bits of the incoming sound and holds it at a lower rate on the last 16th of each beat, in time with the song.
#include <caw/component.hpp>
#include <caw/library/glitch.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {caw::stereoInput("in"), caw::stereoOutput("out")};

caw::ParameterDescriptor knob(std::string_view id, std::string_view name, double def, double lo, double hi,
                              double step = 0, std::string_view unit = {}) {
    caw::ParameterDescriptor p;
    p.id = id;
    p.name = name;
    p.defaultValue = def;
    p.minimum = lo;
    p.maximum = hi;
    p.step = step;
    p.unit = unit;
    p.curve = unit == "Hz" ? caw::ParameterCurve::Exponential : caw::ParameterCurve::Linear;
    return p;
}
enum : uint32_t { kMask, kRate, kMix };
const caw::ParameterDescriptor kParams[] = {
    knob("mask", "Mask", 240, 0, 4095, 1),               // which bits flip on the glitch step
    knob("rate", "Hold rate", 4000, 200, 48000, 0, "Hz"),  // how often the held value is picked up
    knob("mix", "Mix", 1, 0, 1),
};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.starter.glitch-fx";
    d.name = "Glitch";
    d.role = caw::ModuleRole::Effect;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 3;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

// A parameter's value at a frame (per frame while it ramps or is automated).
double param(const caw::AudioProcessBlock& b, uint32_t k, uint32_t frame, double fallback) noexcept {
    if (k >= b.parameterCount || !b.parameters) return fallback;
    return b.parameters[k].samples ? b.parameters[k].samples[frame] : b.parameters[k].value;
}

class Glitch final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        reset();
        return true;
    }
    void reset() noexcept override {
        hold_[0].reset();
        hold_[1].reset();
        freeBeat_ = 0;
    }

    bool process(const caw::AudioProcessBlock& b) noexcept override {
        if (!caw::audioProcessBlockValid(b) || b.input.channelCount != 2 || b.output.channelCount != 2) return false;
        // The song position and tempo; with no transport (an audition), a free-running 120 BPM.
        const double tempo = b.transport && b.transport->tempo > 0 ? b.transport->tempo : 120.0;
        const double start = b.transport ? b.transport->beat : freeBeat_;
        const double perFrame = tempo / 60.0 / rate_;
        const uint32_t mask = static_cast<uint32_t>(param(b, kMask, 0, 240));
        const double hz = param(b, kRate, 0, 4000);
        for (uint32_t i = 0; i < b.frames; ++i) {
            const double beat = start + i * perFrame;
            const double mix = param(b, kMix, i, 1);
            const bool glitch = beat - static_cast<double>(static_cast<int64_t>(beat)) >= 0.75;  // the 4th 16th
            for (int c = 0; c < 2; ++c) {
                const double x = b.input.channels[c][i];
                // The hold runs all the time, so it picks up the beat's sound the moment the glitch step starts.
                const double held = hold_[c].process(x, hz, rate_);
                const double wet = glitch ? caw::lib::bitMask(held, mask) : x;
                b.output.channels[c][i] = static_cast<float>(x + (wet - x) * mix);
            }
        }
        freeBeat_ = start + b.frames * perFrame;
        return true;
    }

private:
    caw::lib::SampleHold hold_[2];
    double freeBeat_ = 0, rate_ = 48000;
};

}  // namespace

CAW_EXPORT_COMPONENT(Glitch, kDescriptor)
