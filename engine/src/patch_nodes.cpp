// The patch model's graph nodes: Input/Output passes, wire gains, latency delays, feedback send/return pairs, adapters.
#include "patch_nodes.h"

#include <algorithm>
#include <cmath>
#include <utility>

#include "caw/library/fastmath.hpp"
#include "route_math.h"

namespace caw::patch_detail {

NodeInstance::~NodeInstance() {
    if (processor) processor->deactivate();
}

void OwnNode::describe(std::string_view id, std::vector<PortDescriptor> ports) {
    ports_ = std::move(ports);
    desc_ = ModuleDescriptor{};
    desc_.id = id;
    desc_.name = id;
    desc_.role = ModuleRole::Utility;
    desc_.ports = ports_.data();
    desc_.portCount = static_cast<uint32_t>(ports_.size());
}

PortDescriptor shapedPort(const PortDescriptor& like, std::string_view id, bool input, bool summing) {
    PortDescriptor p;
    p.id = id;
    p.type = like.type;
    p.layout = like.layout;
    p.channelCount = like.channelCount;
    p.input = input;
    p.summing = input && summing;
    return p;
}

namespace {

PortDescriptor stereoPort(std::string_view id, bool input, bool summing = false) {
    PortDescriptor p = audioPort(id, input);
    p.summing = input && summing;
    return p;
}

// One signal in and one out of the same shape; audio through process(), modulation through processPorts().
class Through : public OwnNode {
public:
    bool usesProcessPorts() const noexcept override { return modulation_; }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        const uint32_t channels = b.output.channelCount;
        if (channels == 0 || channels > kMaxPortChannels) return false;
        for (uint32_t c = 0; c < channels; ++c)
            run(c, b.input.channelCount ? b.input.channels[c % b.input.channelCount] : nullptr, b.output.channels[c],
                b.frames);
        return true;
    }
    bool processPorts(const ProcessBlock& b) noexcept override {
        if (!modulation_ || b.modulationInCount != 1 || b.modulationOutCount != 1) return false;
        run(0, b.modulationIn[0], b.modulationOut[0], b.frames);
        return true;
    }

protected:
    void shape(std::string_view id, const PortDescriptor& like, bool summingInput = false) {
        modulation_ = like.type == PortType::Modulation;
        describe(id, {shapedPort(like, "in", true, summingInput), shapedPort(like, "out", false)});
    }
    // Channel c: frames from in (null: silence) to out.
    virtual void run(uint32_t c, const float* in, float* out, uint32_t frames) noexcept = 0;
    bool modulation_ = false;
};

class Pass final : public Through {
public:
    Pass(bool summing, bool sanitize) : sanitize_(sanitize) {
        describe(sanitize ? "patch.output" : "patch.input", {stereoPort("in", true, summing), stereoPort("out", false)});
    }

private:
    void run(uint32_t, const float* in, float* out, uint32_t frames) noexcept override {
        if (!in) std::fill_n(out, frames, 0.0f);
        else if (sanitize_) for (uint32_t i = 0; i < frames; ++i) out[i] = routeSample(in[i]);
        else std::copy_n(in, frames, out);
    }
    bool sanitize_;
};

class Gain final : public Through {
public:
    Gain(const PortDescriptor& like, float gain) : gain_(gain) { shape("patch.gain", like); }

private:
    void run(uint32_t, const float* in, float* out, uint32_t frames) noexcept override {
        if (!in) std::fill_n(out, frames, 0.0f);
        else for (uint32_t i = 0; i < frames; ++i) out[i] = routeSample(in[i] * gain_);
    }
    float gain_;
};

class Delay final : public Through {
public:
    Delay(const PortDescriptor& like, uint32_t frames) : frames_(frames) {
        shape("patch.delay", like);
        const uint32_t channels = like.type == PortType::Audio ? portChannelCount(like) : 1u;
        line_.assign(static_cast<std::size_t>(channels) * frames, 0.0f);
        at_.assign(channels, 0);
    }
    void reset() noexcept override {
        std::fill(line_.begin(), line_.end(), 0.0f);
        std::fill(at_.begin(), at_.end(), 0u);
    }

private:
    void run(uint32_t c, const float* in, float* out, uint32_t frames) noexcept override {
        if (c >= at_.size()) {
            std::fill_n(out, frames, 0.0f);
            return;
        }
        float* line = line_.data() + static_cast<std::size_t>(c) * frames_;
        uint32_t at = at_[c];
        for (uint32_t i = 0; i < frames; ++i) {
            out[i] = line[at];
            line[at] = in ? in[i] : 0.0f;
            at = at + 1 == frames_ ? 0 : at + 1;
        }
        at_[c] = at;
    }
    uint32_t frames_;
    std::vector<float> line_;
    std::vector<uint32_t> at_;
};

class Silence final : public OwnNode {
public:
    explicit Silence(const PortDescriptor& like) { describe("patch.silence", {shapedPort(like, "out", false)}); }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        for (uint32_t c = 0; c < b.output.channelCount; ++c) std::fill_n(b.output.channels[c], b.frames, 0.0f);
        return true;
    }
};

class Send final : public OwnNode {
public:
    Send(const PortDescriptor& like, float gain, FeedbackRing& ring, const uint64_t& clock)
        : gain_(gain), ring_(ring), clock_(clock) {
        describe("patch.send", {shapedPort(like, "in", true)});
    }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        if (b.frames > patch::kSubBlock) return false;
        constexpr uint32_t mask = FeedbackRing::kRingFrames - 1;
        for (uint32_t c = 0; c < ring_.channels; ++c) {
            float* ring = ring_.data.data() + static_cast<std::size_t>(c) * FeedbackRing::kRingFrames;
            const float* in = b.input.channelCount ? b.input.channels[c % b.input.channelCount] : nullptr;
            for (uint32_t i = 0; i < b.frames; ++i)
                ring[(clock_ + i) & mask] = in ? routeSample(in[i] * gain_) : 0.0f;
        }
        return true;
    }

private:
    float gain_;
    FeedbackRing& ring_;
    const uint64_t& clock_;
};

class Return final : public OwnNode {
public:
    Return(const PortDescriptor& like, bool limiter, double sampleRate, FeedbackRing& ring, const uint64_t& clock)
        : limiter_(limiter), ring_(ring), clock_(clock), state_(ring.channels) {
        describe("patch.return", {shapedPort(like, "out", false)});
        // A one-pole DC block at 10 Hz (the mixer's feedback sends' own).
        pole_ = std::exp(-2.0 * 3.14159265358979323846 * 10.0 / (sampleRate > 0.0 ? sampleRate : 48000.0));
    }
    void reset() noexcept override {
        std::fill(ring_.data.begin(), ring_.data.end(), 0.0f);
        std::fill(state_.begin(), state_.end(), Dc{});
    }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        if (b.frames > patch::kSubBlock) return false;
        constexpr uint32_t mask = FeedbackRing::kRingFrames - 1;
        const uint64_t from = clock_ - patch::kSubBlock;  // wraps below 0 like the ring: its first frames are silence
        for (uint32_t c = 0; c < b.output.channelCount; ++c) {
            const float* ring = ring_.data.data() + static_cast<std::size_t>(c % ring_.channels) * FeedbackRing::kRingFrames;
            float* out = b.output.channels[c];
            if (!limiter_) {
                for (uint32_t i = 0; i < b.frames; ++i) {
                    float x = ring[(from + i) & mask];
                    x = x == x ? x : 0.0f;
                    out[i] = std::clamp(x, -patch::kFeedbackClamp, patch::kFeedbackClamp);
                }
                continue;
            }
            Dc& s = state_[c % state_.size()];
            for (uint32_t i = 0; i < b.frames; ++i) {
                const float x = ring[(from + i) & mask];
                const double in = x == x ? x : 0.0;
                double y = in - s.x1 + pole_ * s.y1;
                if (std::fabs(y) < 1e-20) y = 0.0;  // its decay on silence never sits on subnormals
                s.x1 = in;
                s.y1 = y;
                out[i] = static_cast<float>(softClip(y));
            }
        }
        return true;
    }

private:
    // The mixer's feedback-send clip (engine.cpp, feedbackClip), so a send mapped to a wire sounds the same: unity
    // below 0.5, then a tanh knee that never reaches 1 (0 dBFS).
    static double softClip(double x) noexcept {
        const double a = std::fabs(x);
        if (!(a > 0.5)) return a == a ? x : 0.0;
        const double y = 0.5 + 0.5 * lib::tanhApprox((a - 0.5) * 2.0);
        return x < 0 ? -y : y;
    }
    struct Dc {
        double x1 = 0.0, y1 = 0.0;
    };
    bool limiter_;
    FeedbackRing& ring_;
    const uint64_t& clock_;
    std::vector<Dc> state_;
    double pole_ = 0.0;
};

class ChainNode final : public OwnNode {
public:
    ChainNode(ComponentChain& chain, bool summing, double sampleRate, const ChainTime* const& time)
        : chain_(chain), rate_(sampleRate), time_(time) {
        describe("patch.chain", {stereoPort("in", true, summing), stereoPort("out", false)});
        desc_.latencyFrames = static_cast<uint32_t>(std::min<uint64_t>(chain.latencyFrames(), UINT32_MAX));
    }
    void reset() noexcept override { chain_.reset(); }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        if (b.output.channelCount != 2 || b.frames > ComponentChain::kMaxFrames) return false;
        float* l = b.output.channels[0];
        float* r = b.output.channels[1];
        if (b.input.channelCount == 2) {
            std::copy_n(b.input.channels[0], b.frames, l);
            std::copy_n(b.input.channels[1], b.frames, r);
        } else {
            std::fill_n(l, b.frames, 0.0f);
            std::fill_n(r, b.frames, 0.0f);
        }
        chain_.process(l, r, b.frames, rate_, time_);
        return true;
    }

private:
    ComponentChain& chain_;
    double rate_;
    const ChainTime* const& time_;
};

class OptionalAdapter final : public OwnNode {
public:
    OptionalAdapter(fx::EffectBase& effect, std::vector<WiredOptional> wired) : effect_(effect), wired_(std::move(wired)) {
        const ModuleDescriptor& inner = effect.descriptor();
        std::vector<PortDescriptor> ports(inner.ports, inner.ports + inner.portCount);
        for (uint32_t k = 0; k < inner.portCount; ++k)
            if (inner.ports[k].type == PortType::Audio) ++(inner.ports[k].input ? innerIns_ : innerOuts_);
        const auto offered = effect.optionalPorts();
        for (const WiredOptional& w : wired_) ports.push_back(stereoPort(offered[w.index].id, w.input));
        describe(inner.id, std::move(ports));
        desc_.name = inner.name;
        desc_.version = inner.version;
        desc_.role = inner.role;
        desc_.parameters = inner.parameters;
        desc_.parameterCount = inner.parameterCount;
        desc_.latencyFrames = inner.latencyFrames;
        desc_.tailFrames = inner.tailFrames;
        desc_.maxStateBytes = inner.maxStateBytes;
    }
    void reset() noexcept override { effect_.reset(); }
    bool quiet() const noexcept override { return effect_.quiet(); }
    bool usesProcessPorts() const noexcept override { return !wired_.empty() || effect_.usesProcessPorts(); }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        disconnectAll();
        return effect_.process(b);
    }
    bool processPorts(const ProcessBlock& b) noexcept override {
        disconnectAll();
        uint32_t in = innerIns_, out = innerOuts_;
        for (const WiredOptional& w : wired_) {
            if (w.input) {
                if (in >= b.audioInCount || b.audioIn[in].channelCount != 2) return false;
                effect_.connectOptionalPort(w.index, const_cast<float*>(b.audioIn[in].channels[0]),
                                            const_cast<float*>(b.audioIn[in].channels[1]));
                ++in;
            } else {
                if (out >= b.audioOutCount || b.audioOut[out].channelCount != 2) return false;
                effect_.connectOptionalPort(w.index, b.audioOut[out].channels[0], b.audioOut[out].channels[1]);
                ++out;
            }
        }
        if (effect_.usesProcessPorts()) {
            ProcessBlock inner = b;
            inner.audioInCount = innerIns_;
            inner.audioOutCount = innerOuts_;
            return effect_.processPorts(inner);
        }
        AudioProcessBlock block;
        if (innerIns_) block.input = b.audioIn[0];
        if (innerOuts_) block.output = b.audioOut[0];
        block.frames = b.frames;
        block.sampleRate = b.sampleRate;
        block.parameters = b.parameters;
        block.parameterCount = b.parameterCount;
        block.transport = b.transport;
        return effect_.process(block);
    }

private:
    void disconnectAll() noexcept {
        const uint32_t n = static_cast<uint32_t>(effect_.optionalPorts().size());
        for (uint32_t k = 0; k < n; ++k) effect_.connectOptionalPort(k, nullptr, nullptr);
    }
    fx::EffectBase& effect_;
    std::vector<WiredOptional> wired_;
    uint32_t innerIns_ = 0, innerOuts_ = 0;
};

}  // namespace

std::unique_ptr<ModuleProcessor> makePass(bool summingInput, bool sanitize) {
    return std::make_unique<Pass>(summingInput, sanitize);
}
std::unique_ptr<ModuleProcessor> makeSilence(const PortDescriptor& like) { return std::make_unique<Silence>(like); }
std::unique_ptr<ModuleProcessor> makeGain(const PortDescriptor& like, float gain) {
    return std::make_unique<Gain>(like, gain);
}
std::unique_ptr<ModuleProcessor> makeDelay(const PortDescriptor& like, uint32_t frames) {
    return std::make_unique<Delay>(like, frames);
}
std::unique_ptr<ModuleProcessor> makeSend(const PortDescriptor& like, float gain, FeedbackRing& ring,
                                          const uint64_t& clock) {
    return std::make_unique<Send>(like, gain, ring, clock);
}
std::unique_ptr<ModuleProcessor> makeReturn(const PortDescriptor& like, bool limiter, double sampleRate,
                                            FeedbackRing& ring, const uint64_t& clock) {
    return std::make_unique<Return>(like, limiter, sampleRate, ring, clock);
}
std::unique_ptr<ModuleProcessor> makeChainNode(ComponentChain& chain, bool summingInput, double sampleRate,
                                               const ChainTime* const& time) {
    return std::make_unique<ChainNode>(chain, summingInput, sampleRate, time);
}
std::unique_ptr<ModuleProcessor> makeOptionalAdapter(fx::EffectBase& effect, std::vector<WiredOptional> wired) {
    return std::make_unique<OptionalAdapter>(effect, std::move(wired));
}

}  // namespace caw::patch_detail
