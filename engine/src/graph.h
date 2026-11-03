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
    DuplicateConnection
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
// Each node has at most one audio input and one audio output port, of any layout; control,
// modulation and event ports are rejected until the typed runtime ports exist (roadmap F5).
// A summing input (PortDescriptor::summing) takes any number of connections: before the node
// runs, the executor sums them into a prepared buffer per channel, in connection order,
// starting from +0.0f, in float, saturating at +/-FLT_MAX with NaN as 0 (route_math.h). Any other input
// takes at most one connection.
// Unconnected audio inputs read the host input, so they must all have the same channel count.
// Processors are called only through process(const AudioProcessBlock&); both views' capacity is
// the block's frame count. If one returns false the block fails: process() returns false, zeroes
// the host output and records the failing node. process() rebinds host channels into the prepared
// input table, so one executor must never be processed by two threads (e.g. playback and export).
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
    // Thin stereo wrapper over the planar path. Null inputs are silence.
    bool process(const float* inputLeft, const float* inputRight,
                 float* outputLeft, float* outputRight, uint32_t frames) noexcept;
    bool ready() const noexcept { return ready_; }
    uint32_t inputChannels() const noexcept { return hostInputChannels_; }
    uint32_t outputChannels() const noexcept { return outputChannels_; }
    // Failure reporting for the control thread (relaxed atomics; values, not synchronization).
    uint32_t lastFailedNode() const noexcept { return failedNode_.load(std::memory_order_relaxed); }
    uint64_t failureCount() const noexcept { return failures_.load(std::memory_order_relaxed); }

private:
    void fail(uint32_t node, const ChannelBufferView& output, uint32_t frames) noexcept;
    // Runs the graph; the caller has checked ready_, frames and both host views.
    bool processValidated(const ConstChannelBufferView& input, const ChannelBufferView& output,
                          uint32_t frames) noexcept;

    std::vector<ModuleProcessor*> processors_;
    std::vector<float> channelStorage_;           // every node output channel, planar, maxFrames each
    std::vector<float*> outputTable_;             // per-node output channel pointers, concatenated
    std::vector<const float*> inputTable_;        // per-node input channel pointers, concatenated
    std::vector<uint32_t> hostInputSlots_;        // inputTable_ entries fed by the host input
    std::vector<uint32_t> inputBase_, inputCount_, outputBase_, outputCount_;
    std::vector<float> zero_;
    // Fan-in: one entry per summing input that has connections.
    struct SumInput { uint32_t sourceBase, sourceCount, tableBase; };
    std::vector<SumInput> sumInputs_;
    std::vector<uint32_t> sumIndex_;              // per node: index into sumInputs_, or UINT32_MAX
    std::vector<uint32_t> sumSources_;            // source nodes per summing input, connection order
    std::vector<float*> sumTable_;                // summed channel buffers, per summing input
    std::vector<float> sumStorage_;
    std::vector<uint32_t> order_;
    uint32_t outputNode_ = UINT32_MAX;
    uint32_t hostInputChannels_ = 0;
    uint32_t outputChannels_ = 0;
    uint32_t maxFrames_ = 0;
    double sampleRate_ = 48000.0;
    bool ready_ = false;
    std::atomic<uint32_t> failedNode_{UINT32_MAX};
    std::atomic<uint64_t> failures_{0};
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
