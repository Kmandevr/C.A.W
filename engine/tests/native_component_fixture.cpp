// Shared-library fixture for the explicit-trust ModuleRegistry loading tests.
#include <atomic>
#include <cstring>
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

// The bundle's second component: halves its input.
const caw::ModuleDescriptor kHalfDescriptor{"org.caw.tests.native-loader.half", 1, kPorts, 2, nullptr, 0, nullptr, 0, {}};

class HalfProcessor final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kHalfDescriptor; }

    void process(const caw::StereoProcessBlock& block) noexcept override {
        if (!block.outputLeft || !block.outputRight) return;
        for (uint32_t frame = 0; frame < block.frames; ++frame) {
            block.outputLeft[frame] = block.inputLeft ? block.inputLeft[frame] * 0.5f : 0.0f;
            block.outputRight[frame] = block.inputRight ? block.inputRight[frame] * 0.5f : 0.0f;
        }
    }
};

// The bundle's third component: separate left and right gains, so tests can tell the sides apart
// and set parameters. "left" ramps over 8 frames; "right" jumps.
caw::ParameterDescriptor gainParameter(std::string_view id, uint32_t smoothing) {
    caw::ParameterDescriptor p;
    p.id = id;
    p.defaultValue = 1.0;
    p.minimum = 0.0;
    p.maximum = 4.0;
    p.smoothingFrames = smoothing;
    return p;
}
const caw::ParameterDescriptor kGainParameters[] = {gainParameter("left", 8), gainParameter("right", 0)};
caw::ModuleDescriptor gainDescriptor() {
    caw::ModuleDescriptor d{"org.caw.tests.native-loader.gain", 1, kPorts, 2, kGainParameters, 2, nullptr, 0, {}};
    d.maxStateBytes = 8;  // its state: how many blocks it has processed (a stand-in for a tail or a buffer)
    return d;
}
const caw::ModuleDescriptor kGainDescriptor = gainDescriptor();

class GainProcessor final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kGainDescriptor; }
    using caw::ModuleProcessor::process;
    bool process(const caw::AudioProcessBlock& block) noexcept override {
        if (block.input.channelCount != 2 || block.output.channelCount != 2) return false;
        for (uint32_t c = 0; c < 2; ++c) {
            double fixed = 1.0;
            const double* samples = nullptr;
            if (block.parameterCount == 2) {
                fixed = block.parameters[c].value;
                samples = block.parameters[c].samples;
            }
            for (uint32_t i = 0; i < block.frames; ++i)
                block.output.channels[c][i] =
                    static_cast<float>(block.input.channels[c][i] * (samples ? samples[i] : fixed));
        }
        blocks_.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
    void reset() noexcept override { blocks_.store(0, std::memory_order_relaxed); }
    uint32_t stateVersion() const noexcept override { return 7; }
    // Safe while processing: the count is atomic.
    bool saveState(uint8_t* destination, uint32_t capacity, uint32_t& written) const noexcept override {
        if (capacity < 8) return false;
        const uint64_t n = blocks_.load(std::memory_order_relaxed);
        std::memcpy(destination, &n, 8);
        written = 8;
        return true;
    }
    bool loadState(const uint8_t* source, uint32_t size, uint32_t version) noexcept override {
        if (size != 8 || version != 7) return false;
        uint64_t n = 0;
        std::memcpy(&n, source, 8);
        blocks_.store(n, std::memory_order_relaxed);
        return true;
    }

private:
    std::atomic<uint64_t> blocks_{0};
};

}  // namespace

#ifndef CAW_TEST_OMIT_ENTRY  // the second fixture plays a library without the v2 entry point
// A bundle of two components (owner, 2026-11-09: a package may hold several).
CAW_EXPORT_COMPONENTS(TestNativeProcessor, HalfProcessor, GainProcessor)
#endif
