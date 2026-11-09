// Shared-library fixture for the explicit-trust ModuleRegistry loading tests.
#include <new>

#include <caw/component.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {
    {"audio_in", caw::PortType::Audio, caw::ChannelLayout::Stereo, true, 0, false, 0.0f},
    {"audio_out", caw::PortType::Audio, caw::ChannelLayout::Stereo, false, 0, false, 0.0f},
};

const caw::ModuleDescriptor kDescriptor{
    "org.caw.tests.native-loader",
    1,
    kPorts,
    2,
    nullptr,
    0,
    nullptr,
    0,
    {},
};

class TestNativeProcessor final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }

    void process(const caw::StereoProcessBlock& block) noexcept override {
        if (!block.outputLeft || !block.outputRight) return;
        for (uint32_t frame = 0; frame < block.frames; ++frame) {
            block.outputLeft[frame] = block.inputLeft ? block.inputLeft[frame] * 2.0f : 0.0f;
            block.outputRight[frame] = block.inputRight ? block.inputRight[frame] * 2.0f : 0.0f;
        }
    }
};

}  // namespace

#ifndef CAW_TEST_OMIT_ENTRY  // the second fixture plays a library without the v2 entry point
CAW_EXPORT_COMPONENT(TestNativeProcessor, kDescriptor)
#endif
