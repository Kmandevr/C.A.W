// Shared-library fixture for the plug-in benchmark (#197): an effect that allocates in process() and runs on subnormals at silence.
#include <new>

#include <caw/component.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {
    {"audio_in", caw::PortType::Audio, caw::ChannelLayout::Stereo, true, 0, false, 0.0f},
    {"audio_out", caw::PortType::Audio, caw::ChannelLayout::Stereo, false, 0, false, 0.0f},
};

caw::ParameterDescriptor gainParameter() {
    caw::ParameterDescriptor p;
    p.id = "gain";
    p.defaultValue = 0.5;
    p.minimum = 0.0;
    p.maximum = 1.0;
    return p;
}
const caw::ParameterDescriptor kParameters[] = {gainParameter()};
const caw::ModuleDescriptor kDescriptor{"org.caw.tests.bench-bad", 1, kPorts, 2, kParameters, 1, nullptr, 0, {}};

void* volatile gSink = nullptr;

// What a component must never do: allocate and free on every block (a new-expression's pair may be elided, so
// ::operator new and delete directly), and decay through a chain of one-pole filters whose input never quite
// reaches 0: at silence each stage settles around 2e-40, a subnormal, which a CPU without flush-to-zero computes
// many times slower and which comes out as subnormal output.
class BadProcessor final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    using caw::ModuleProcessor::process;
    bool process(const caw::AudioProcessBlock& b) noexcept override {
        if (b.input.channelCount != 2 || b.output.channelCount != 2) return false;
        {
            CAW_PROFILE_SCOPE("alloc");
            void* p = ::operator new(256);
            gSink = p;
            ::operator delete(p);
        }
        const float gain = b.parameters && b.parameterCount ? static_cast<float>(b.parameters[0].value) : 0.5f;
        CAW_PROFILE_SCOPE("decay");
        for (uint32_t c = 0; c < 2; ++c) {
            const float* in = b.input.channels[c];
            float* out = b.output.channels[c];
            for (uint32_t i = 0; i < b.frames; ++i) {
                float x = in[i] * gain + tiny_;
                for (float& y : state_[c]) {
                    y = 0.5f * y + 0.5f * x;
                    x = y + tiny_;
                }
                out[i] = x;
            }
        }
        return true;
    }
    void reset() noexcept override {
        for (auto& s : state_)
            for (float& y : s) y = 0.0f;
    }

private:
    float state_[2][8] = {};
    volatile float tinyStore_ = 1e-40f;  // read once: a subnormal the compiler can't fold away
    const float tiny_ = tinyStore_;
};

}  // namespace

CAW_EXPORT_COMPONENT(BadProcessor, kDescriptor)
