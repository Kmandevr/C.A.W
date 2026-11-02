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
    // Caller-owned GraphNode/GraphConnection storage and processor instances are excluded.
    std::size_t maxWorkingBytes = 0;
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
    bool process(const float* inputLeft, const float* inputRight,
                 float* outputLeft, float* outputRight, uint32_t frames) noexcept;
    bool ready() const noexcept { return executor_.ready(); }

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
    bool process(const float* inputLeft, const float* inputRight,
                 float* outputLeft, float* outputRight, uint32_t frames) noexcept;
    PreparedGraph* collectRetired() noexcept;
    // Call only after the audio callback has stopped.
    PreparedGraph* takeActiveAfterStop() noexcept;
    PreparedGraph* takePendingAfterStop() noexcept;

private:
    PreparedGraph* active_ = nullptr; // audio-thread only except after stop
    std::atomic<PreparedGraph*> pending_{nullptr};
    std::atomic<PreparedGraph*> retired_{nullptr};
};

}  // namespace caw
