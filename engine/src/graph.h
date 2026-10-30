// Typed, deterministic DSP graph validation and compilation order. Control-thread only.
#pragma once

#include <cstdint>
#include <string_view>
#include <vector>

#include "module.h"

namespace caw {

constexpr uint32_t kMaxGraphNodes = 1024;
constexpr uint32_t kMaxGraphConnections = 8192;

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

enum class GraphError : uint8_t {
    Ok,
    TooManyNodes,
    TooManyConnections,
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
    Cycle
};

struct CompiledGraph {
    GraphError error = GraphError::Ok;
    uint32_t errorConnection = UINT32_MAX;
    std::vector<uint32_t> executionOrder;
    explicit operator bool() const noexcept { return error == GraphError::Ok; }
};

// Produces a stable topological order. Call on a control/build thread, never from process().
CompiledGraph compileGraph(const std::vector<GraphNode>& nodes,
                           const std::vector<GraphConnection>& connections);

// Prepared native stereo executor. prepare() allocates on a control thread; process() performs
// no allocation, locking, I/O or graph traversal and is suitable for a bounded audio callback.
class GraphExecutor {
public:
    GraphError prepare(const std::vector<GraphNode>& nodes,
                       const std::vector<GraphConnection>& connections,
                       const std::vector<ModuleProcessor*>& processors,
                       uint32_t outputNode,
                       uint32_t maxFrames,
                       double sampleRate);
    void reset() noexcept;
    bool process(const float* inputLeft, const float* inputRight,
                 float* outputLeft, float* outputRight, uint32_t frames) noexcept;
    bool ready() const noexcept { return ready_; }

private:
    std::vector<ModuleProcessor*> processors_;
    std::vector<std::vector<float>> left_, right_;
    std::vector<int32_t> inputSource_;
    std::vector<uint8_t> hasInput_, hasOutput_;
    std::vector<uint32_t> order_;
    uint32_t outputNode_ = UINT32_MAX;
    uint32_t maxFrames_ = 0;
    double sampleRate_ = 48000.0;
    bool ready_ = false;
};

}  // namespace caw
