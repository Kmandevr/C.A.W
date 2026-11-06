// Minimal stereo pass-through component used to verify the external SDK build contract.
#include <new>

#include <caw/component.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {
    {"audio_in", caw::PortType::Audio, caw::ChannelLayout::Stereo, true, 2, false, 0.0f},
    {"audio_out", caw::PortType::Audio, caw::ChannelLayout::Stereo, false, 2, false, 0.0f},
};

const caw::ModuleDescriptor kDescriptor{
    "org.caw.examples.minimal",
    1,
    kPorts,
    2,
    nullptr,
    0,
    nullptr,
    0,
    {},
};

class MinimalComponent final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override {
        return kDescriptor;
    }

    void process(const caw::StereoProcessBlock& block) noexcept override {
        if (!block.inputLeft || !block.inputRight || !block.outputLeft || !block.outputRight)
            return;
        for (uint32_t frame = 0; frame < block.frames; ++frame) {
            block.outputLeft[frame] = block.inputLeft[frame];
            block.outputRight[frame] = block.inputRight[frame];
        }
    }
};

}  // namespace

extern "C" CAW_COMPONENT_EXPORT const caw::ModuleDescriptor*
caw_component_descriptor() noexcept {
    return &kDescriptor;
}

extern "C" CAW_COMPONENT_EXPORT caw::ModuleProcessor*
caw_component_create() noexcept {
    return new (std::nothrow) MinimalComponent();
}
