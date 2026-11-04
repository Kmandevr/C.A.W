// Typed, deterministic DSP graph validation and compilation order. Control-thread only.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <string_view>
#include <vector>

#include "execution.h"
#include "module.h"
#include "params.h"
#include "spsc.h"

namespace caw {

struct GraphNode {
    std::string_view id;
    const ModuleDescriptor* module = nullptr;
};

struct GraphConnection {
    uint32_t sourceNode = 0;
    uint32_t sourcePort = 0;
    uint32_t destinationNode = 0;
    uint32_t destinationPort = 0;
};

struct GraphResourceBudget {
    // Count ceilings are optional host policy. By default there is no arbitrary object-count cap.
    std::size_t maxNodes = std::numeric_limits<std::size_t>::max();
    std::size_t maxConnections = std::numeric_limits<std::size_t>::max();
    // Required: maximum estimated internal working memory. Graph compilation checks its
    // own peak; GraphExecutor preparation checks the combined compile + prepared-runtime peak.
    // Caller-owned GraphNode/GraphConnection storage, processor instances and the caller's
    // processor-pointer list (PreparedGraph's borrowed list) are excluded.
    std::size_t maxWorkingBytes = 0;
    // Host limit on channels per audio port (1..kMaxPortChannels); larger ports fail with TooManyChannels.
    uint32_t maxChannelsPerPort = kMaxPortChannels;
    // Events each event output, and each merging (summing) event input, holds per block. Required
    // (nonzero) for a graph with event ports; its storage counts in maxWorkingBytes.
    uint32_t maxEventsPerPort = 1024;
};

// Converts the Engine's hardware-derived graph working-set share to the graph compiler/executor budget.
GraphResourceBudget makeGraphResourceBudget(const EngineResourceBudget& engineBudget) noexcept;

enum class GraphError : uint8_t {
    Ok,
    TooManyNodes,
    InvalidResourceBudget,
    ResourceBudgetExceeded,
    SizeOverflow,
    MissingModule,
    InvalidModule,
    EmptyNodeId,
    DuplicateNodeId,
    NodeIndexOutOfRange,
    PortIndexOutOfRange,
    DirectionMismatch,
    PortTypeMismatch,
    ChannelLayoutMismatch,
    InputAlreadyConnected,
    Cycle,
    ProcessorCountMismatch,
    MissingProcessor,
    ProcessorDescriptorMismatch,
    RuntimeUnsupportedPortType,
    RuntimeUnsupportedPortLayout,
    RuntimeUnsupportedPortCount,
    InvalidOutputNode,
    InvalidBlockSize,
    OutOfMemory,
    TooManyChannels,
    RuntimeHostInputMismatch,
    DuplicateConnection,
    RoutingUnavailable
};

struct CompiledGraph {
    GraphError error = GraphError::Ok;
    std::size_t errorConnection = static_cast<std::size_t>(-1);
    std::vector<uint32_t> executionOrder;
    explicit operator bool() const noexcept { return error == GraphError::Ok; }
};

// Produces a stable topological order. Call on a control/build thread, never from process().
CompiledGraph compileGraph(const std::vector<GraphNode>& nodes,
                           const std::vector<GraphConnection>& connections,
                           const GraphResourceBudget& budget);

// Prepared planar N-channel executor. Processor instances and descriptors are borrowed and must
// outlive the executor. reset() never destroys processors. prepare() allocates every channel buffer
// and pointer table on a control thread, sized from the validated port descriptors and counted in
// the working-memory budget. process() performs no allocation, locking, I/O or graph traversal and
// is suitable for a bounded audio callback.
//
// Ports (F5): a node may have any number of audio, modulation, control and event ports. A node
// with at most one audio input and one audio output and no other ports is called through
// process(const AudioProcessBlock&); any
// other node through processPorts(const ProcessBlock&), and prepare() rejects it unless its
// processor's usesProcessPorts() is true. Audio views' capacity is the block's frame count.
// A summing input (audio or modulation, PortDescriptor::summing) takes any number of
// connections: before the node runs, the executor sums them into a prepared buffer per channel,
// in connection order, starting from +0.0f, in float, saturating at +/-FLT_MAX with NaN as 0
// (route_math.h). A summing event input instead merges its sources' events by frame, ties in
// connection order, into a buffer of maxEventsPerPort events; events past that are dropped and
// counted (eventsDropped()). Any other input takes at most one connection; a plain event input
// reads its source's events directly.
// Unconnected inputs: a node's first audio input reads the host input (so all of those must have
// the same channel count); any other audio input (a sidechain) and every modulation input reads
// silence; a control input reads its port's defaultValue. A node's first event input reads the
// host events passed to process(), any other event input none. Each event output is emptied
// before its node runs and checked after it (EventOutput rules). Control outputs saturate after each
// block (NaN reads 0, beyond float range +/-FLT_MAX); plain audio and modulation connections pass
// bits unchanged. Graph output is the output node's first
// audio output. Values are never converted between port types.
// Parameters (F6.2): every node's descriptor parameters get a ParameterResolver, configured at
// prepare() to their defaults, with a per-frame buffer of maxFrames values each (counted in the
// budget). Before a node runs, each of its parameters is resolved for the block and passed in
// descriptor order (AudioProcessBlock/ProcessBlock::parameters). Values come from the
// control thread through queueParameter() and queueClearTouch(), which process() applies at the
// start of the next block, in queue order.
// If a processor returns false the block fails: process() returns false, zeroes the host output
// and records the failing node. process() rebinds host channels into the prepared input table,
// so one executor must never be processed by two threads (e.g. playback and export).
class GraphExecutor {
public:
    GraphError prepare(const std::vector<GraphNode>& nodes,
                       const std::vector<GraphConnection>& connections,
                       const std::vector<ModuleProcessor*>& processors,
                       uint32_t outputNode,
                       uint32_t maxFrames,
                       double sampleRate,
                       const GraphResourceBudget& budget);
    void reset() noexcept;
    // `input` may have no channels (silence). If inputChannels() is 0 the input is ignored;
    // otherwise its channel count must equal inputChannels(). `output` must have exactly
    // outputChannels(). Counts are never adapted, truncated or padded.
    bool process(const ConstChannelBufferView& input, const ChannelBufferView& output,
                 uint32_t frames) noexcept;
    // The same, with host events for the graph's unconnected first event inputs. They must follow
    // the EventInput rules for this block (frames non-decreasing, each below `frames`) and hold at
    // most maxEventsPerPort events, else false. A graph without event inputs ignores them.
    bool process(const ConstChannelBufferView& input, const ChannelBufferView& output,
                 uint32_t frames, const EventInput& events) noexcept;
    // Dynamic routing (control thread, audio ports only): for a graph prepared without
    // connections, give every summing audio input room for maxSourcesPerInput routed sources,
    // counted against the budget. Summing inputs then never read the host input; with no routes
    // they are silence. With routePlainInputs, every plain (non-summing) audio input becomes
    // routable too: it takes at most one route, reads that source's buffer directly (no copy,
    // bits unchanged) and is silence without one; the graph then reads no host input at all.
    // Modulation, control and event inputs keep their unconnected values (silence, default, the
    // first event input the host events).
    GraphError reserveRouting(uint32_t maxSourcesPerInput, const GraphResourceBudget& budget,
                              bool routePlainInputs = false);
    // prepare() with no connections plus reserveRouting(maxSourcesPerInput, budget, true) in one
    // step: every input is routed and none reads the host, so unconnected inputs may differ in
    // channel count (prepare() alone rejects that, as host input could not feed them all).
    GraphError prepareRouted(const std::vector<GraphNode>& nodes, const std::vector<ModuleProcessor*>& processors,
                             uint32_t outputNode, uint32_t maxFrames, double sampleRate,
                             const GraphResourceBudget& budget, uint32_t maxSourcesPerInput);
    // Audio-thread safe once reserveRouting() succeeded: replaces every dynamic route and the
    // execution order in one step. `order` lists the nodes to run, each at most once, and must
    // include the output node; nodes left out are not run at all. Every edge goes from a listed
    // node's audio output to the summing input (or, if reserved, the plain input) of a node later
    // in `order`, with equal channel counts, no duplicates, at most the reserved number per summing
    // input and one per plain input. Edge order is summation order. A rejected call returns false
    // and leaves the previous routing in effect.
    bool setRouting(const GraphConnection* edges, uint32_t edgeCount, const uint32_t* order,
                    uint32_t orderCount) noexcept;
    // Control thread, one producer, lock-free: set a parameter's manual value (a knob, a typed
    // value or a mapped MIDI CC; F6.1 rules: clamped, smoothed, a touch while automated), applied
    // at the start of the next process(). False if the executor is not ready, the node or
    // parameter index is out of range, the value is not finite, or the queue is full
    // (kParameterQueueCapacity commands); a false call has no effect.
    bool queueParameter(uint32_t node, uint32_t parameter, double value) noexcept;
    // The same queue: ends every touch (call when playback starts or restarts), so automation
    // rules again.
    bool queueClearTouch() noexcept;
    static constexpr std::size_t kParameterQueueCapacity = 1024;
    // The manual value a parameter is heading to (audio-thread state; read it from the control
    // thread only while process() is not running, e.g. in tests or after stop).
    double parameterTarget(uint32_t node, uint32_t parameter) const noexcept;
    // Thin stereo wrapper over the planar path. Null inputs are silence.
    bool process(const float* inputLeft, const float* inputRight,
                 float* outputLeft, float* outputRight, uint32_t frames) noexcept;
    bool ready() const noexcept { return ready_; }
    uint32_t runCount() const noexcept { return runCount_; }  // nodes process() runs (audio-thread value)
    uint32_t inputChannels() const noexcept { return hostInputChannels_; }
    uint32_t outputChannels() const noexcept { return outputChannels_; }
    // Failure reporting for the control thread (relaxed atomics; values, not synchronization).
    uint32_t lastFailedNode() const noexcept { return failedNode_.load(std::memory_order_relaxed); }
    uint64_t failureCount() const noexcept { return failures_.load(std::memory_order_relaxed); }
    // Events dropped because a merging event input was full, since prepare().
    uint64_t eventsDropped() const noexcept { return eventsDropped_.load(std::memory_order_relaxed); }

private:
    void fail(uint32_t node, const ChannelBufferView& output, uint32_t frames) noexcept;
    // Runs the graph; the caller has checked ready_, frames and both host views.
    bool processValidated(const ConstChannelBufferView& input, const ChannelBufferView& output,
                          uint32_t frames, const EventInput& events) noexcept;
    struct EventMerge { uint32_t sourceBase, sourceCount, input; std::size_t storage; };
    void mergeEvents(const EventMerge& merge) noexcept;

    std::vector<ModuleProcessor*> processors_;
    // Every port, at nodePortBase_[node] + its descriptor index. `table` indexes inputTable_ or
    // outputTable_ (audio, modulation), controlInTable_ or controlOutTable_ (control),
    // eventInTable_ or eventOutTable_ (event).
    struct Port {
        PortType type;
        bool input, summing, host;  // host: this input's channels are bound to the host input
        uint32_t channels;          // audio: channel count; modulation and control: 1
        uint32_t table;
        uint32_t sum;               // summing inputs: index into sumInputs_ (events: eventMerges_), or UINT32_MAX
    };
    std::vector<Port> ports_;
    std::vector<uint32_t> nodePortBase_;
    // Per node: where its ports' entries start in each table (each node's are contiguous, audio
    // before modulation), and whether it is called through processPorts.
    struct NodeBlock {
        uint32_t audioIn, audioInCount, audioOut, audioOutCount;    // into the view arrays
        uint32_t modIn, modInCount, modOut, modOutCount;            // into inputTable_/outputTable_
        uint32_t controlIn, controlInCount, controlOut, controlOutCount;
        uint32_t eventIn, eventInCount, eventOut, eventOutCount;
        uint32_t sumBase, sumCount;                                 // its summing inputs in sumInputs_
        uint32_t mergeBase, mergeCount;                             // its merging event inputs in eventMerges_
        uint32_t paramBase, paramCount;                             // its parameters in resolvers_
        bool typed;
    };
    std::vector<NodeBlock> blocks_;
    std::vector<ConstChannelBufferView> audioInViews_;
    std::vector<ChannelBufferView> audioOutViews_;
    std::vector<float> channelStorage_;           // every audio and modulation output channel, maxFrames each
    std::vector<float*> outputTable_;             // output channel pointers, concatenated per node
    std::vector<const float*> inputTable_;        // input channel pointers, concatenated per node
    std::vector<float> controlStorage_;           // control output values, then control input defaults
    std::vector<float*> controlOutTable_;
    std::vector<const float*> controlInTable_;
    std::vector<uint32_t> hostInputSlots_;        // inputTable_ entries fed by the host input
    // Per node: its first audio input and output (table base and channel count; 0 = none).
    std::vector<uint32_t> inputBase_, inputCount_, outputBase_, outputCount_;
    std::vector<float> zero_;
    // Fan-in: one entry per summing input that has connections (all of them once routing is reserved).
    struct SumInput { uint32_t sourceBase, sourceCount, tableBase, channels; };
    std::vector<SumInput> sumInputs_;
    std::vector<uint32_t> sumSources_;            // source output ports (global index) per summing input, in order
    std::vector<float*> sumTable_;                // summed channel buffers, per summing input
    std::vector<float> sumStorage_;
    // Events: every output's buffer, then every merging input's, eventCapacity_ events each.
    std::vector<Event> eventStorage_;
    std::vector<EventOutput> eventOutTable_;
    std::vector<EventInput> eventInTable_;        // refreshed before each node runs
    // Per event input: its source event output, or one of the k* markers below.
    static constexpr uint32_t kEventNone = UINT32_MAX, kEventHost = UINT32_MAX - 1, kEventMerged = UINT32_MAX - 2;
    std::vector<uint32_t> eventInSource_;
    std::vector<EventMerge> eventMerges_;
    std::vector<uint32_t> eventMergeSources_;     // source event outputs per merge, in connection order
    std::vector<uint32_t> mergeCursor_;           // merge scratch: one read position per source
    uint32_t eventCapacity_ = 0;
    // Parameters: one resolver, resolved value and maxFrames-sample buffer each, node by node.
    std::vector<ParameterResolver> resolvers_;
    std::vector<ParameterValue> parameterValues_;
    std::vector<double> parameterStorage_;
    struct ParameterCommand { uint32_t node, parameter; double value; bool clearTouch; };
    Spsc<ParameterCommand, kParameterQueueCapacity> parameterQueue_;
    void applyParameterCommands() noexcept;
    void resolveParameters(const NodeBlock& block, uint32_t frames) noexcept;
    std::vector<uint32_t> order_;
    // Dynamic routing scratch, preallocated by reserveRouting().
    std::vector<uint32_t> routePosition_, routeCount_, routeStaging_;
    std::vector<uint32_t> directStaging_;         // per port: a plain input's routed source port, or UINT32_MAX
    bool routePlain_ = false;
    bool deferHostCheck_ = false;                 // set only inside prepareRouted()
    std::size_t preparedBytes_ = 0;
    uint32_t staticConnections_ = 0;
    uint32_t routingCapacity_ = 0;
    uint32_t runCount_ = 0;  // leading entries of order_ that process() runs
    uint32_t outputNode_ = UINT32_MAX;
    uint32_t hostInputChannels_ = 0;
    uint32_t outputChannels_ = 0;
    uint32_t maxFrames_ = 0;
    double sampleRate_ = 48000.0;
    bool ready_ = false;
    std::atomic<uint32_t> failedNode_{UINT32_MAX};
    std::atomic<uint64_t> failures_{0};
    std::atomic<uint64_t> eventsDropped_{0};
};

// Owns every processor referenced by its prepared executor. Build and destroy on a
// control thread; once published, process() is callback-safe and the owner must be
// reclaimed only after GraphRuntime returns it from collectRetired()/take*AfterStop().
class PreparedGraph {
public:
    PreparedGraph() = default;
    ~PreparedGraph() = default;
    PreparedGraph(const PreparedGraph&) = delete;
    PreparedGraph& operator=(const PreparedGraph&) = delete;
    PreparedGraph(PreparedGraph&&) = delete;
    PreparedGraph& operator=(PreparedGraph&&) = delete;

    GraphError prepare(const std::vector<GraphNode>& nodes,
                       const std::vector<GraphConnection>& connections,
                       std::vector<std::unique_ptr<ModuleProcessor>> processors,
                       uint32_t outputNode,
                       uint32_t maxFrames,
                       double sampleRate,
                       const GraphResourceBudget& budget);
    void reset() noexcept;
    bool process(const ConstChannelBufferView& input, const ChannelBufferView& output,
                 uint32_t frames) noexcept;
    bool process(const float* inputLeft, const float* inputRight,
                 float* outputLeft, float* outputRight, uint32_t frames) noexcept;
    bool ready() const noexcept { return executor_.ready(); }
    const GraphExecutor& executor() const noexcept { return executor_; }

private:
    // Declaration order is intentional: executor_ is destroyed before processors_.
    std::vector<std::unique_ptr<ModuleProcessor>> processors_;
    GraphExecutor executor_;
};

// Single-producer control-thread publication and single audio-thread adoption.
// The control thread owns published executors until publish succeeds, then reclaims
// replaced executors with collectRetired(). Never destroy an executor on the audio thread.
class GraphRuntime {
public:
    bool publish(PreparedGraph* prepared) noexcept;
    // Both overloads output silence and return false when no graph is active or the block fails.
    bool process(const ConstChannelBufferView& input, const ChannelBufferView& output,
                 uint32_t frames) noexcept;
    bool process(const float* inputLeft, const float* inputRight,
                 float* outputLeft, float* outputRight, uint32_t frames) noexcept;
    PreparedGraph* collectRetired() noexcept;
    // Call only after the audio callback has stopped.
    PreparedGraph* takeActiveAfterStop() noexcept;
    PreparedGraph* takePendingAfterStop() noexcept;

private:
    PreparedGraph* adopt() noexcept;
    PreparedGraph* active_ = nullptr; // audio-thread only except after stop
    std::atomic<PreparedGraph*> pending_{nullptr};
    std::atomic<PreparedGraph*> retired_{nullptr};
};

}  // namespace caw
