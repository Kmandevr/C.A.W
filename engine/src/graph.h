// Typed, deterministic DSP graph validation and compilation order. Control-thread only.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>
#include <vector>

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
    // Required: maximum internal working memory for compile or prepared execution.
    // Caller-owned GraphNode/GraphConnection storage and processor instances are excluded.
    std::size_t maxWorkingBytes = 0;
};

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
    OutOfMemory
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

// Prepared native stereo executor. Processor instances and descriptors are borrowed and must outlive the executor.
// reset() never destroys processors. prepare() allocates on a control thread; process() performs
// no allocation, locking, I/O or graph traversal and is suitable for a bounded audio callback.
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
    bool process(const float* inputLeft, const float* inputRight,
                 float* outputLeft, float* outputRight, uint32_t frames) noexcept;
    bool ready() const noexcept { return ready_; }

private:
    std::vector<ModuleProcessor*> processors_;
    std::vector<std::vector<float>> left_, right_;
    std::vector<float> zero_;
    std::vector<uint32_t> inputSource_;
    std::vector<uint8_t> hasInput_, hasOutput_;
    std::vector<uint32_t> order_;
    uint32_t outputNode_ = UINT32_MAX;
    uint32_t maxFrames_ = 0;
    double sampleRate_ = 48000.0;
    bool ready_ = false;
};

// Single-producer control-thread publication and single audio-thread adoption.
// The control thread owns published executors until publish succeeds, then reclaims
// replaced executors with collectRetired(). Never destroy an executor on the audio thread.
class GraphRuntime {
public:
    bool publish(GraphExecutor* prepared) noexcept;
    bool process(const float* inputLeft, const float* inputRight,
                 float* outputLeft, float* outputRight, uint32_t frames) noexcept;
    GraphExecutor* collectRetired() noexcept;
    // Call only after the audio callback has stopped.
    GraphExecutor* takeActiveAfterStop() noexcept;
    GraphExecutor* takePendingAfterStop() noexcept;

private:
    GraphExecutor* active_ = nullptr; // audio-thread only except after stop
    std::atomic<GraphExecutor*> pending_{nullptr};
    std::atomic<GraphExecutor*> retired_{nullptr};
};

}  // namespace caw
