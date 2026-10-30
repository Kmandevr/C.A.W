// Typed graph validation. No graph traversal, allocation or sorting occurs on the audio thread.
#include "graph.h"

#include <algorithm>\n#include <cmath>\n#include <new>
#include <limits>

namespace caw {

CompiledGraph compileGraph(const std::vector<GraphNode>& nodes,
                           const std::vector<GraphConnection>& connections) {
    CompiledGraph out;
    if (nodes.size() > kMaxGraphNodes) { out.error = GraphError::TooManyNodes; return out; }
    if (connections.size() > kMaxGraphConnections) { out.error = GraphError::TooManyConnections; return out; }

    for (size_t i = 0; i < nodes.size(); ++i) {
        const GraphNode& node = nodes[i];
        if (node.id.empty()) { out.error = GraphError::EmptyNodeId; return out; }
        if (!node.module) { out.error = GraphError::MissingModule; return out; }
        if (validateModuleDescriptor(*node.module) != ModuleValidation::Ok) {
            out.error = GraphError::InvalidModule; return out;
        }
        for (size_t j = 0; j < i; ++j) {
            if (nodes[j].id == node.id) { out.error = GraphError::DuplicateNodeId; return out; }
        }
    }

    std::vector<uint32_t> indegree(nodes.size(), 0);
    std::vector<std::vector<uint32_t>> outgoing(nodes.size());
    std::vector<std::vector<uint8_t>> connected;
    connected.reserve(nodes.size());
    for (const GraphNode& n : nodes) connected.emplace_back(n.module->portCount, 0);

    for (uint32_t i = 0; i < connections.size(); ++i) {
        const GraphConnection& c = connections[i];
        auto fail = [&](GraphError e) {
            out.error = e;
            out.errorConnection = i;
        };
        if (c.sourceNode >= nodes.size() || c.destinationNode >= nodes.size()) {
            fail(GraphError::NodeIndexOutOfRange); return out;
        }
        const ModuleDescriptor& src = *nodes[c.sourceNode].module;
        const ModuleDescriptor& dst = *nodes[c.destinationNode].module;
        if (c.sourcePort >= src.portCount || c.destinationPort >= dst.portCount) {
            fail(GraphError::PortIndexOutOfRange); return out;
        }
        const PortDescriptor& sp = src.ports[c.sourcePort];
        const PortDescriptor& dp = dst.ports[c.destinationPort];
        if (sp.input || !dp.input) { fail(GraphError::DirectionMismatch); return out; }
        if (sp.type != dp.type) { fail(GraphError::PortTypeMismatch); return out; }
        if (sp.layout != dp.layout) { fail(GraphError::ChannelLayoutMismatch); return out; }
        if (connected[c.destinationNode][c.destinationPort]) {
            fail(GraphError::InputAlreadyConnected); return out;
        }
        connected[c.destinationNode][c.destinationPort] = 1;
        outgoing[c.sourceNode].push_back(c.destinationNode);
        ++indegree[c.destinationNode];
    }

    // Stable Kahn ordering: among currently-ready nodes, preserve authored node order.
    std::vector<uint8_t> emitted(nodes.size(), 0);
    out.executionOrder.reserve(nodes.size());
    while (out.executionOrder.size() < nodes.size()) {
        uint32_t next = UINT32_MAX;
        for (uint32_t i = 0; i < nodes.size(); ++i) {
            if (!emitted[i] && indegree[i] == 0) { next = i; break; }
        }
        if (next == UINT32_MAX) { out.error = GraphError::Cycle; out.executionOrder.clear(); return out; }
        emitted[next] = 1;
        out.executionOrder.push_back(next);
        for (uint32_t dst : outgoing[next]) --indegree[dst];
    }
    return out;
}

}  // namespace caw
