// An example modulator (#161): a Euclidean rhythm as a gate and a ramp per hit, on caw/modulator.hpp; route its outputs to any knob.
#include <cmath>
#include <cstdint>

#include <caw/component.hpp>
#include <caw/modulator.hpp>

namespace {

// Two outputs: "gate" (1 on a hit's first half, else 0) and "ramp" (falls from 1 to 0 across each hit's step).
constexpr caw::PortDescriptor kPorts[] = {caw::mod::output("gate"), caw::mod::output("ramp")};

caw::ParameterDescriptor param(const char* id, const char* name, double def, double lo, double hi, double step) {
    caw::ParameterDescriptor p;
    p.id = id;
    p.name = name;
    p.defaultValue = def;
    p.minimum = lo;
    p.maximum = hi;
    p.step = step;
    return p;
}

const caw::ParameterDescriptor kParams[] = {
    param("steps", "Steps", 16, 1, 32, 1),
    param("hits", "Hits", 5, 0, 32, 1),
    param("rotate", "Rotate", 0, 0, 31, 1),
    param("beats", "Beats per step", 0.25, 0.0625, 4, 0),  // 0.25: sixteenth notes
};

caw::ModuleDescriptor makeDescriptor() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.examples.euclid";
    d.name = "Euclidean gate";
    d.role = caw::ModuleRole::Utility;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 4;
    return d;
}
const caw::ModuleDescriptor kDescriptor = makeDescriptor();

class EuclidModulator final : public caw::mod::Modulator {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    void reset() noexcept override {
        position_ = 0.0;
        gate_.reset();
        ramp_.reset();
    }

protected:
    bool render(const caw::mod::Block& b) noexcept override {
        const int steps = static_cast<int>(b.param(0, 16));
        const int hits = static_cast<int>(b.param(1, 5));
        const int rotate = static_cast<int>(b.param(2, 0));
        const double beats = b.param(3, 0.25);
        // Where the song is (in steps) at the block's end; while stopped, run on at the tempo.
        double beat = 0.0;
        if (b.beatAt(b.frames, beat)) position_ = beat / beats;
        else position_ += b.frames * b.tempo() / (60.0 * b.sampleRate * beats);
        const double whole = std::floor(position_);
        const int step = (static_cast<int>(std::fmod(whole, steps > 0 ? steps : 1)) + rotate) % (steps > 0 ? steps : 1);
        // Bjorklund's pattern by the bresenham rule: step k is a hit when floor((k+1) h / n) > floor(k h / n).
        const bool hit = steps > 0 && hits > 0 && (step + 1) * hits / steps > step * hits / steps;
        const double into = position_ - whole;
        gate_.ramp(b.outputs[0], b.frames, hit && into < 0.5 ? 1.0 : 0.0);
        if (b.outputCount > 1) ramp_.ramp(b.outputs[1], b.frames, hit ? 1.0 - into : 0.0);
        return true;
    }

private:
    double position_ = 0.0;
    caw::mod::Ramp gate_, ramp_;
};

}  // namespace

CAW_EXPORT_COMPONENT(EuclidModulator, kDescriptor)
