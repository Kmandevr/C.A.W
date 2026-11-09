// Minimal stereo pass-through component used to verify the external SDK build contract.
#include <cstdint>

#include <caw/component.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {
    {"audio_in", caw::PortType::Audio, caw::ChannelLayout::Stereo, true, 0, false, 0.0f},
    {"audio_out", caw::PortType::Audio, caw::ChannelLayout::Stereo, false, 0, false, 0.0f},
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
        for (std::uint32_t frame = 0; frame < block.frames; ++frame) {
            block.outputLeft[frame] = block.inputLeft[frame];
            block.outputRight[frame] = block.inputRight[frame];
        }
    }
};

}  // namespace

CAW_EXPORT_COMPONENT(MinimalComponent, kDescriptor)
