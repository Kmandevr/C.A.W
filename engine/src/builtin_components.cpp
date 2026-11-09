// Built-in stereo components (the C.A.W. Library, #121), registered in every Engine like a loaded component.
#include "builtin_components.h"

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

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

}  // namespace

void registerBuiltinComponents(ModuleRegistry& registry) {
    registry.add(kBalance, &make<Balance>);
    registry.add(kWidth, &make<Width>);
}

}  // namespace caw
