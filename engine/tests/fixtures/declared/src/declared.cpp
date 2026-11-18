// A test component that declares capabilities in its caw-component.json and uses one of them (a thread).
#include <cstdint>
#include <thread>

#include <caw/component.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {
    {"audio_in", caw::PortType::Audio, caw::ChannelLayout::Stereo, true, 0, false, 0.0f},
    {"audio_out", caw::PortType::Audio, caw::ChannelLayout::Stereo, false, 0, false, 0.0f},
};

const caw::ModuleDescriptor kDescriptor{"org.caw.tests.declared", 1, kPorts, 2, nullptr, 0, nullptr, 0, {}};

class Declared final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    void process(const caw::StereoProcessBlock& block) noexcept override {
        if (!block.inputLeft || !block.inputRight || !block.outputLeft || !block.outputRight) return;
        for (std::uint32_t frame = 0; frame < block.frames; ++frame) {
            block.outputLeft[frame] = block.inputLeft[frame];
            block.outputRight[frame] = block.inputRight[frame];
        }
    }
};

}  // namespace

// Starts a thread (never called by the tests): the binary imports thread creation, which it declares.
extern "C" void caw_tests_declared_worker() {
    std::thread t([] {});
    t.join();
}

CAW_EXPORT_COMPONENT(Declared, kDescriptor)
