// The patch model (routing plan step 3, 1.0.8): typed nodes and wires compiled onto GraphExecutor. Built, not yet used.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "component_chain.h"
#include "graph.h"
#include "module_registry.h"
#include "project.h"

namespace caw {

// A patch is a graph of nodes joined by wires, port to port, compiled into one GraphExecutor that runs as one outer
// node (docs/engine.md, "Patches"). Nothing in the engine calls it yet: the mixer still runs chains.
//
// - Nodes: Input (the patch's stereo input, port "out"), Output (its stereo output, port "in"; exactly one), Chain (a
//   ComponentChain of effects, as a track's inserts are today: ports "in" and "out") and Module (one component: its
//   descriptor's typed ports by id, audio, modulation, control and events, plus a built-in effect's optional ports,
//   EffectBase::optionalPorts, by id). An optional port that no wire names is not even declared: it costs nothing.
// - Wires: an output port to an input port of the same type, with a gain (audio and modulation; 1 adds no work) and a
//   feedback flag (audio only). Audio channel counts match, or mono widens into stereo. An input that is not summing
//   takes one wire; the Chain and Output inputs sum any number.
// - Feedback: a feedback wire compiles to a send/return pair sharing a small ring, so the graph stays acyclic; it
//   delays by kSubBlock frames. Its return has the mixer's feedback limiter (a 10 Hz DC block, then a soft clip:
//   unity below 0.5, a tanh knee short of 1), on by default; with `limiter` off, the return only clamps to
//   +/-kFeedbackClamp. NaN becomes 0 either way. Every loop of wires must hold a feedback wire, or it is refused.
// - Time: a patch with a feedback wire runs in sub-blocks of kSubBlock frames counted from Play (markPlay), whatever
//   the host's block; one without runs in sub-blocks of kWideSubBlock (the Engine's block) on the same grid, since
//   nothing in it waits on a sub-block, and so costs what today's chain costs. Everything the patch adds (gains,
//   delays, feedback rings, limiters) works per frame, so a render is the same bits at any host block size whenever
//   its components are (the built-ins are: their control grid and sleep rules).
// - Latency: each node's input time is the latest of its compensated wires' sources (their time plus their
//   latency); a delay is inserted on every earlier wire. Audio and modulation wires are compensated; feedback wires,
//   wires into a "sidechain" input (a key), control and event wires are not. latencyFrames() is the Output's time.
// - Limits (per patch, untrusted input): kMaxNodes nodes, kMaxWires wires, kMaxFeedbackWires feedback wires,
//   kMaxPortsPerNode ports per node; a bad spec fails closed with an error that names the node, wire or port.
// - Changes compile off the audio thread (compilePatch) and swap whole (PatchRuntime); a crossfade is the caller's.
//   Given the patch that plays, a compile keeps the instance (and so the running state: a reverb's tail) of every
//   node whose id, kind and components are unchanged and only sets its values: they ramp from where the playing
//   patch has them (a kept Module from its last values, knob moves included; a Chain as setValues does) to the
//   spec's, a value the spec does not name to its default, so a kept node sounds as a fresh build would.
// - Memory (untrusted input): every wire's compensation delay within kMaxCompensationFrames, and all of a patch's
//   delay lines together within kMaxDelayLineBytes; its Chain nodes' components within kMaxPatchChainComponents.
namespace patch {
inline constexpr uint32_t kMaxNodes = 64;
inline constexpr uint32_t kMaxWires = 256;
inline constexpr uint32_t kMaxFeedbackWires = 16;
inline constexpr uint32_t kMaxPortsPerNode = 8;
inline constexpr uint32_t kMaxChainComponents = 64;    // components in one Chain node
inline constexpr std::size_t kMaxIdLength = 64;        // node ids and port names, bytes
inline constexpr double kMaxWireGain = 16.0;           // |gain| (+24 dB)
inline constexpr uint32_t kMaxCompensationFrames = 1u << 20;  // one wire's latency compensation
inline constexpr std::size_t kMaxDelayLineBytes = std::size_t{64} << 20;  // all its compensation delays together
inline constexpr uint32_t kMaxPatchChainComponents = 256;  // components in all its Chain nodes together
inline constexpr uint32_t kSubBlock = 16;              // frames per sub-block with feedback; a feedback wire's delay
inline constexpr uint32_t kWideSubBlock = 64;          // frames per sub-block without (a multiple of kSubBlock)
inline constexpr float kFeedbackClamp = 16.0f;         // a feedback return without its limiter
inline constexpr uint32_t kMaxEvents = 1024;           // events per process() call (and per event port)
}  // namespace patch

enum class PatchNodeKind : uint8_t { Input, Output, Chain, Module };

struct PatchNodeSpec {
    std::string id;
    PatchNodeKind kind = PatchNodeKind::Module;
    // Chain: its effects in order (as ComponentChain::build takes them). Module: exactly one component, its id and
    // values (a merged device's variant, a rack's slots, a saved state); no bypass, samples or audio track.
    std::vector<ComponentSpec> components;
};

struct PatchEnd {
    std::string node, port;
};

struct PatchWireSpec {
    PatchEnd from, to;
    double gain = 1.0;
    bool feedback = false;
    bool limiter = true;  // feedback wires only: the return's limiter
};

struct PatchSpec {
    std::vector<PatchNodeSpec> nodes;
    std::vector<PatchWireSpec> wires;
};

namespace patch_detail {
struct NodeInstance;
struct FeedbackRing;
}  // namespace patch_detail

// A compiled patch. Built on the control thread (compilePatch), then run by one audio thread; destroyed on the
// control thread (PatchRuntime retires it there).
class CompiledPatch {
public:
    ~CompiledPatch();
    CompiledPatch(const CompiledPatch&) = delete;
    CompiledPatch& operator=(const CompiledPatch&) = delete;

    // Audio thread: `frames` (any count) from the input (null: silence) to the output, run as sub-blocks. `events`
    // (null: none) reach every Module whose first event input no wire feeds, frames in this call, non-decreasing,
    // below `frames`, at most patch::kMaxEvents. `time` (null: stopped, no transport) is the transport for the
    // Chain nodes, as ComponentChain::process takes it, at this call's first frame. False (the output silent where it
    // failed) for bad arguments or a node that failed a sub-block.
    bool process(const float* inLeft, const float* inRight, float* outLeft, float* outRight, uint32_t frames,
                 const EventInput* events = nullptr, const ChainTime* time = nullptr) noexcept;
    // Audio thread: Play. Sub-blocks count from the next frame.
    void markPlay() noexcept { sincePlay_ = 0; }
    // Audio thread: every node back to silence (tails, delay lines, feedback rings, limiters), as after a build.
    void reset() noexcept;

    // Control thread: a Module's parameter (a knob: it ramps), or a Chain's component `component` parameter. False
    // for a node, component or parameter the patch does not have, or a value that is not finite.
    bool setParameter(std::string_view node, uint32_t component, std::string_view parameter, double value) noexcept;

    uint64_t latencyFrames() const noexcept { return latency_; }
    // Nodes of the spec, and of the compiled graph (with the gains, delays, feedback pairs and silences it added).
    uint32_t nodeCount() const noexcept { return static_cast<uint32_t>(nodes_.size()); }
    uint32_t graphNodeCount() const noexcept { return static_cast<uint32_t>(graphIds_.size()); }
    // Frames per sub-block: kSubBlock with a feedback wire, else kWideSubBlock.
    uint32_t subBlockFrames() const noexcept { return subBlock_; }
    // Nodes that kept the previous patch's instance.
    uint32_t keptNodes() const noexcept { return kept_; }
    const GraphExecutor& executor() const noexcept { return executor_; }

private:
    friend std::unique_ptr<CompiledPatch> compilePatch(const ModuleRegistry&, const PatchSpec&, double,
                                                       const CompiledPatch*, std::string&);
    friend class PatchRuntime;
    CompiledPatch() = default;

    struct Node {
        std::string id;
        PatchNodeKind kind = PatchNodeKind::Module;
        std::shared_ptr<patch_detail::NodeInstance> instance;  // Chain and Module (shared with a kept patch)
        uint32_t graphNode = UINT32_MAX;                       // its node in the executor
        // Module: every parameter's value as the control thread last set it (the spec's, then setParameter's), so
        // a recompile that keeps the node starts there.
        std::vector<double> values;
    };
    std::vector<Node> nodes_;
    // Declaration order matters: the executor (borrowing the processors) goes first, then the processors, then the
    // rings and node instances they point into.
    std::vector<std::shared_ptr<patch_detail::NodeInstance>> instances_;
    std::vector<std::unique_ptr<patch_detail::FeedbackRing>> rings_;
    std::vector<std::unique_ptr<ModuleProcessor>> processors_;  // the graph's own nodes (adapters, gains, ...)
    std::vector<std::string> graphIds_;
    std::vector<ModuleProcessor*> graph_;  // every node of the executor, in its order (reset)
    GraphExecutor executor_;

    std::vector<Event> pieceEvents_;  // patch::kMaxEvents
    float zero_[patch::kWideSubBlock] = {};
    ChainTime pieceTime_{};
    const ChainTime* time_ = nullptr;  // this sub-block's transport for the Chain nodes (null: none)
    uint64_t clock_ = 0;               // frames run since the build: where the feedback rings are
    uint64_t sincePlay_ = 0;           // frames since Play: the sub-block grid
    uint32_t subBlock_ = patch::kWideSubBlock;
    uint64_t latency_ = 0;
    uint32_t kept_ = 0;
    double sampleRate_ = 48000.0;
};

// Control thread: compiles `spec` at `sampleRate`. With `previous` (the patch that plays, or null), every node with
// the same id, kind and components keeps that patch's instance and takes the spec's values; the result must then
// replace `previous` whole, never play beside it (two patches would run one instance). Null and `error` for a spec
// the limits or rules refuse, or a component that can't be made.
std::unique_ptr<CompiledPatch> compilePatch(const ModuleRegistry& registry, const PatchSpec& spec, double sampleRate,
                                            const CompiledPatch* previous, std::string& error);

// Single-producer publication from the control thread, adoption by one audio thread, as GraphRuntime: the swap is a
// pointer exchange at the start of process() (nothing allocated or freed there), the new patch taking over the old
// one's sub-block position. Destroy retired patches on the control thread.
class PatchRuntime {
public:
    // Control thread: false while an earlier patch is still pending.
    bool publish(CompiledPatch* next) noexcept;
    // Audio thread: silence and false with no patch.
    bool process(const float* inLeft, const float* inRight, float* outLeft, float* outRight, uint32_t frames,
                 const EventInput* events = nullptr, const ChainTime* time = nullptr) noexcept;
    void markPlay() noexcept { playMarked_ = true; }
    CompiledPatch* collectRetired() noexcept;
    // Only after the audio thread has stopped.
    CompiledPatch* takeActiveAfterStop() noexcept;
    CompiledPatch* takePendingAfterStop() noexcept;

private:
    CompiledPatch* active_ = nullptr;  // audio thread
    bool playMarked_ = false;          // audio thread (markPlay is called there)
    std::atomic<CompiledPatch*> pending_{nullptr};
    std::atomic<CompiledPatch*> retired_{nullptr};
};

}  // namespace caw
