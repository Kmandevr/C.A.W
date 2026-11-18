// The patch model's graph nodes: Input/Output passes, wire gains, latency delays, feedback send/return pairs, adapters.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "builtin_effects.h"
#include "component_chain.h"
#include "patch.h"

namespace caw::patch_detail {

// What a Chain or Module node holds, shared between a patch and the next one that keeps it. Destroyed on the
// control thread, with the last patch holding it.
struct NodeInstance {
    PatchNodeKind kind = PatchNodeKind::Module;
    std::string component;  // Module: its component id
    std::string structure;  // Module: componentStructure (a merged device's variant, a rack's slots)
    double sampleRate = 0.0;
    std::unique_ptr<ModuleProcessor> processor;  // Module (activated)
    std::unique_ptr<ComponentChain> chain;       // Chain
    ~NodeInstance();
};

// A feedback wire's ring: the send writes frame t at t % kRingFrames, the return reads frame t - kSubBlock, so a
// sub-block of at most kSubBlock frames never reads what the same sub-block writes, in whichever order they run.
struct FeedbackRing {
    static constexpr uint32_t kRingFrames = 2 * patch::kSubBlock;
    uint32_t channels = 0;
    std::vector<float> data;  // channels x kRingFrames
};

// A node of the compiled graph that owns its descriptor and ports.
class OwnNode : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return desc_; }

protected:
    // Ports first, then the descriptor pointing at them (the node is never copied or moved).
    void describe(std::string_view id, std::vector<PortDescriptor> ports);
    OwnNode() = default;
    OwnNode(const OwnNode&) = delete;
    OwnNode& operator=(const OwnNode&) = delete;
    ModuleDescriptor desc_;
    std::vector<PortDescriptor> ports_;
};

// An audio port shaped like `like` (its layout and channel count), named and directed.
PortDescriptor shapedPort(const PortDescriptor& like, std::string_view id, bool input, bool summing = false);

// Input and Output: in to out, stereo; Output (sanitize) turns NaN into 0 and saturates at +/-FLT_MAX.
std::unique_ptr<ModuleProcessor> makePass(bool summingInput, bool sanitize);
// Silence of `like`'s shape, for a first audio input no wire feeds (it would read the patch's input otherwise).
std::unique_ptr<ModuleProcessor> makeSilence(const PortDescriptor& like);
// A wire's gain, audio or modulation of `like`'s shape.
std::unique_ptr<ModuleProcessor> makeGain(const PortDescriptor& like, float gain);
// A wire's latency compensation: `frames` (> 0) of delay, audio or modulation of `like`'s shape.
std::unique_ptr<ModuleProcessor> makeDelay(const PortDescriptor& like, uint32_t frames);
// A feedback wire's send (its gain applied) and return (limiter or clamp). `clock` is the patch's frame position.
std::unique_ptr<ModuleProcessor> makeSend(const PortDescriptor& like, float gain, FeedbackRing& ring,
                                          const uint64_t& clock);
std::unique_ptr<ModuleProcessor> makeReturn(const PortDescriptor& like, bool limiter, double sampleRate,
                                            FeedbackRing& ring, const uint64_t& clock);
// A Chain node: stereo in (summing or not) to out through the chain, with the patch's sub-block transport.
std::unique_ptr<ModuleProcessor> makeChainNode(ComponentChain& chain, bool summingInput, double sampleRate,
                                               const ChainTime* const& time);

// A Module node whose effect offers optional ports: its descriptor's ports, then the wired optional ones (stereo
// audio, in `wired` order), the same parameters. Each block it connects the wired ones and disconnects the rest
// (so a stale buffer from an earlier patch is never written), then runs the effect.
struct WiredOptional {
    uint32_t index = 0;  // in effect.optionalPorts()
    bool input = false;
};
std::unique_ptr<ModuleProcessor> makeOptionalAdapter(fx::EffectBase& effect, std::vector<WiredOptional> wired);

}  // namespace caw::patch_detail
