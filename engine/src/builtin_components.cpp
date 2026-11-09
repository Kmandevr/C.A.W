// Built-in stereo components (the C.A.W. Library, #121), registered in every Engine like a loaded component.
#include "builtin_components.h"

#include "caw/library/distortion.hpp"
#include "caw/library/stereo.hpp"

namespace caw {

namespace {

constexpr PortDescriptor kStereoPorts[] = {stereoInput("in"), stereoOutput("out")};

ParameterDescriptor parameter(std::string_view id, std::string_view name, double def, double lo, double hi) {
    ParameterDescriptor p;
    p.id = id;
    p.name = name;
    p.defaultValue = def;
    p.minimum = lo;
    p.maximum = hi;
    p.smoothingFrames = 480;  // 10 ms at 48 kHz: a knob move doesn't click
    return p;
}

ModuleDescriptor descriptor(std::string_view id, std::string_view name, const ParameterDescriptor* params) {
    ModuleDescriptor d;
    d.id = id;
    d.name = name;
    d.role = ModuleRole::Utility;
    d.ports = kStereoPorts;
    d.portCount = 2;
    d.parameters = params;
    d.parameterCount = 1;
    return d;
}

const ParameterDescriptor kBalanceParams[] = {parameter("pan", "Pan", 0.0, -1.0, 1.0)};
const ParameterDescriptor kWidthParams[] = {parameter("width", "Width", 1.0, 0.0, 2.0)};
const ModuleDescriptor kBalance = descriptor("org.caw.stereo.balance", "Balance", kBalanceParams);
const ModuleDescriptor kWidth = descriptor("org.caw.stereo.width", "Width", kWidthParams);

// The block's value of parameter 0 at frame i (per frame while it ramps or is automated).
double valueAt(const AudioProcessBlock& b, uint32_t i, double fallback) noexcept {
    if (b.parameterCount == 0 || !b.parameters) return fallback;
    return b.parameters[0].samples ? b.parameters[0].samples[i] : b.parameters[0].value;
}

bool stereo(const AudioProcessBlock& b) noexcept { return b.input.channelCount == 2 && b.output.channelCount == 2; }

class Balance final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kBalance; }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        if (!stereo(b)) return false;
        for (uint32_t i = 0; i < b.frames; ++i) {
            const lib::PanGains g = lib::balanceGains(valueAt(b, i, 0.0));
            b.output.channels[0][i] = static_cast<float>(b.input.channels[0][i] * g.left);
            b.output.channels[1][i] = static_cast<float>(b.input.channels[1][i] * g.right);
        }
        return true;
    }
};

class Width final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kWidth; }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        if (!stereo(b)) return false;
        for (uint32_t i = 0; i < b.frames; ++i) {
            double l = b.input.channels[0][i], r = b.input.channels[1][i];
            lib::applyWidth(valueAt(b, i, 1.0), l, r);
            b.output.channels[0][i] = static_cast<float>(l);
            b.output.channels[1][i] = static_cast<float>(r);
        }
        return true;
    }
};

// Distortion: one of four shapes per channel (so a stereo signal stays stereo), then a dry/wet mix and
// an output level.
constexpr std::string_view kShapes[] = {"Drive", "Hard clip", "Fold", "Crush"};
ParameterDescriptor shapeParameter() {
    ParameterDescriptor p = parameter("shape", "Shape", 0.0, 0.0, 3.0);
    p.step = 1.0;
    p.choices = kShapes;
    p.choiceCount = 4;
    p.smoothingFrames = 0;  // a choice jumps
    return p;
}
const ParameterDescriptor kDistortionParams[] = {
    shapeParameter(),
    parameter("drive", "Drive", 4.0, 1.0, 20.0),
    parameter("bits", "Bits", 8.0, 1.0, 24.0),
    parameter("mix", "Mix", 1.0, 0.0, 1.0),
    parameter("output", "Output", 1.0, 0.0, 2.0),
};
ModuleDescriptor distortionDescriptor() {
    ModuleDescriptor d = descriptor("org.caw.distortion", "Distortion", kDistortionParams);
    d.role = ModuleRole::Effect;
    d.parameterCount = 5;
    return d;
}
const ModuleDescriptor kDistortion = distortionDescriptor();

double paramAt(const AudioProcessBlock& b, uint32_t k, uint32_t i, double fallback) noexcept {
    if (k >= b.parameterCount || !b.parameters) return fallback;
    return b.parameters[k].samples ? b.parameters[k].samples[i] : b.parameters[k].value;
}

class Distortion final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kDistortion; }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        if (!stereo(b)) return false;
        for (uint32_t i = 0; i < b.frames; ++i) {
            const int shape = static_cast<int>(paramAt(b, 0, i, 0.0));
            const double amount = paramAt(b, 1, i, 4.0), bits = paramAt(b, 2, i, 8.0);
            const double mix = paramAt(b, 3, i, 1.0), out = paramAt(b, 4, i, 1.0);
            for (uint32_t c = 0; c < 2; ++c) {
                const double x = b.input.channels[c][i];
                double y = 0.0;
                switch (shape) {
                    case 1: y = lib::hardClip(x, amount); break;
                    case 2: y = lib::fold(x, amount); break;
                    case 3: y = lib::crush(x, bits); break;
                    default: y = lib::drive(x, amount); break;
                }
                b.output.channels[c][i] = static_cast<float>((x + (y - x) * mix) * out);
            }
        }
        return true;
    }
};

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

}  // namespace

void registerBuiltinComponents(ModuleRegistry& registry) {
    registry.add(kBalance, &make<Balance>);
    registry.add(kWidth, &make<Width>);
    registry.add(kDistortion, &make<Distortion>);
}

}  // namespace caw
