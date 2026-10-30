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

}  // namespace caw
