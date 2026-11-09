// Prove a C++ component can consume the public SDK without internal engine headers.
#include "test.h"

#include <caw/module.hpp>
#include <caw/detmath.hpp>
#include <caw/library/stereo.hpp>

namespace {
using namespace caw;

const PortDescriptor kPorts[] = {
    {"in", PortType::Audio, ChannelLayout::Stereo, true},
    {"out", PortType::Audio, ChannelLayout::Stereo, false},
};
const ParameterDescriptor kParameters[] = {
    {"gain", 0.5, 0.0, 1.0, true, ParameterCurve::Linear, 0.0, 0, ""},
};
const ModuleDescriptor kDescriptor{
    "caw.test.public-cpp-sdk", 1, kPorts, 2, kParameters, 1
};

class PublicSdkProcessor final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }

    bool process(const AudioProcessBlock& block) noexcept override {
        if (!audioProcessBlockValid(block) || block.input.channelCount != 2 ||
            block.output.channelCount != 2 || block.parameterCount > 1)
            return false;
        const double gain = block.parameterCount ? block.parameters[0].value : 0.5;
        for (uint32_t channel = 0; channel < 2; ++channel)
            for (uint32_t frame = 0; frame < block.frames; ++frame)
                block.output.channels[channel][frame] =
                    static_cast<float>(block.input.channels[channel][frame] * gain);
        return true;
    }
};
}  // namespace

TEST(public_cpp_sdk_component_uses_typed_contract_and_state) {
    CHECK(validateModuleDescriptor(kDescriptor) == ModuleValidation::Ok);
    PublicSdkProcessor processor;
    CHECK(processor.descriptor().id == kDescriptor.id);

    const float left[] = {2.0f, 4.0f};
    const float right[] = {-2.0f, -4.0f};
    const float* inputs[] = {left, right};
    float outputLeft[2] = {}, outputRight[2] = {};
    float* outputs[] = {outputLeft, outputRight};
    const ParameterValue values[] = {{nullptr, 0.25}};
    const AudioProcessBlock block{
        {inputs, 2, 2}, {outputs, 2, 2}, 2, 48000.0, values, 1
    };

    CHECK(processor.process(block));
    CHECK_NEAR(outputLeft[0], 0.5, 1e-7);
    CHECK_NEAR(outputRight[1], -1.0, 1e-7);
    CHECK_EQ(processor.stateVersion(), 1u);
    uint32_t written = 99;
    CHECK(processor.saveState(nullptr, 0, written));
    CHECK_EQ(written, 0u);
    CHECK(processor.loadState(nullptr, 0, 1));
}

TEST(public_cpp_sdk_library_pan_law_is_constant_power_and_deterministic) {
    // The Library's pan law is the mixer's (caw/library/stereo.hpp): equal gains at the centre,
    // one side only at the ends, constant power everywhere, from the SDK's deterministic maths.
    const caw::lib::PanGains centre = caw::lib::constantPowerPan(0.0);
    CHECK_NEAR(centre.left, centre.right, 1e-15);
    CHECK_NEAR(centre.left, 0.70710678118654752, 1e-15);
    const caw::lib::PanGains left = caw::lib::constantPowerPan(-1.0);
    CHECK_NEAR(left.left, 1.0, 1e-15);
    CHECK_NEAR(left.right, 0.0, 1e-15);
    const caw::lib::PanGains right = caw::lib::constantPowerPan(1.0);
    CHECK_NEAR(right.left, 0.0, 1e-15);
    CHECK_NEAR(right.right, 1.0, 1e-15);
    for (double pan = -1.0; pan <= 1.0; pan += 0.125) {
        const caw::lib::PanGains g = caw::lib::constantPowerPan(pan);
        CHECK_NEAR(g.left * g.left + g.right * g.right, 1.0, 1e-14);
    }
    CHECK_EQ(caw::detSin(0.5), caw::detCos(0.5 - caw::kPi / 2.0));
}
