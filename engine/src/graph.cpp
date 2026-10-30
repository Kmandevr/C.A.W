// Typed graph validation and prepared stereo execution. Build/prepare are control-thread operations.
#include "graph.h"

#include <algorithm>
#include <cmath>
#include <new>
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
        auto fail = [&](GraphError e) { out.error = e; out.errorConnection = i; };
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
        for (uint32_t i = 0; i < nodes.size(); ++i)
            if (!emitted[i] && indegree[i] == 0) { next = i; break; }
        if (next == UINT32_MAX) { out.error = GraphError::Cycle; out.executionOrder.clear(); return out; }
        emitted[next] = 1;
        out.executionOrder.push_back(next);
        for (uint32_t dst : outgoing[next]) --indegree[dst];
    }
    return out;
}

void GraphExecutor::reset() noexcept {
    ready_ = false;
    processors_.clear();
    left_.clear();
    right_.clear();
    zero_.clear();
    inputSource_.clear();
    hasInput_.clear();
    hasOutput_.clear();
    order_.clear();
    outputNode_ = UINT32_MAX;
    maxFrames_ = 0;
    sampleRate_ = 48000.0;
}

GraphError GraphExecutor::prepare(const std::vector<GraphNode>& nodes,
                                  const std::vector<GraphConnection>& connections,
                                  const std::vector<ModuleProcessor*>& processors,
                                  uint32_t outputNode,
                                  uint32_t maxFrames,
                                  double sampleRate) {
    reset();
    if (nodes.empty() || processors.size() != nodes.size()) return GraphError::ProcessorCountMismatch;
    if (outputNode >= nodes.size()) return GraphError::InvalidOutputNode;
    if (maxFrames == 0 || maxFrames > 8192 || !std::isfinite(sampleRate) ||
        sampleRate < 8000.0 || sampleRate > 192000.0) return GraphError::InvalidBlockSize;

    const CompiledGraph compiled = compileGraph(nodes, connections);
    if (!compiled) return compiled.error;

    try {
        processors_.reserve(nodes.size());
        left_.resize(nodes.size());
        right_.resize(nodes.size());
        zero_.assign(maxFrames, 0.0f);
        inputSource_.assign(nodes.size(), -1);
        hasInput_.assign(nodes.size(), 0);
        hasOutput_.assign(nodes.size(), 0);
        for (size_t n = 0; n < nodes.size(); ++n) {
            if (!processors[n]) { reset(); return GraphError::MissingProcessor; }
            const ModuleDescriptor& descriptor = processors[n]->descriptor();
            if (descriptor.id != nodes[n].module->id || descriptor.apiVersion != nodes[n].module->apiVersion) {
                reset(); return GraphError::ProcessorDescriptorMismatch;
            }
            uint32_t audioInputs = 0, audioOutputs = 0;
            for (uint32_t p = 0; p < descriptor.portCount; ++p) {
                const PortDescriptor& port = descriptor.ports[p];
                if (port.type != PortType::Audio) return GraphError::RuntimeUnsupportedPortType;
                if (port.layout != ChannelLayout::Stereo) return GraphError::RuntimeUnsupportedPortLayout;
                if (port.input) ++audioInputs; else ++audioOutputs;
            }
            if (audioInputs > 1 || audioOutputs > 1) return GraphError::RuntimeUnsupportedPortCount;
            hasInput_[n] = audioInputs ? 1 : 0;
            hasOutput_[n] = audioOutputs ? 1 : 0;
            if (audioInputs) {
                for (uint32_t e = 0; e < connections.size(); ++e)
                    if (connections[e].destinationNode == n) inputSource_[n] = static_cast<int32_t>(connections[e].sourceNode);
            }
            left_[n].assign(maxFrames, 0.0f);
            right_[n].assign(maxFrames, 0.0f);
            processors_.push_back(processors[n]);
        }
        if (!hasOutput_[outputNode]) { reset(); return GraphError::InvalidOutputNode; }
        for (const GraphConnection& edge : connections)
            if (!hasOutput_[edge.sourceNode] || !hasInput_[edge.destinationNode]) {
                reset(); return GraphError::ProcessorDescriptorMismatch;
            }
        order_ = compiled.executionOrder;
        outputNode_ = outputNode;
        maxFrames_ = maxFrames;
        sampleRate_ = sampleRate;
        ready_ = true;
        return GraphError::Ok;
    } catch (const std::bad_alloc&) {
        reset();
        return GraphError::OutOfMemory;
    } catch (...) {
        reset();
        return GraphError::OutOfMemory;
    }
}

bool GraphExecutor::process(const float* inputLeft, const float* inputRight,
                            float* outputLeft, float* outputRight, uint32_t frames) noexcept {
    if (!ready_ || !outputLeft || !outputRight || frames == 0 || frames > maxFrames_) return false;
    for (uint32_t nodeIndex : order_) {
        float* inL = nullptr;
        float* inR = nullptr;
        if (hasInput_[nodeIndex]) {
            const int32_t source = inputSource_[nodeIndex];
            if (source >= 0) {
                inL = left_[static_cast<size_t>(source)].data();
                inR = right_[static_cast<size_t>(source)].data();
            } else {
                inL = const_cast<float*>(inputLeft ? inputLeft : zero_.data());
                inR = const_cast<float*>(inputRight ? inputRight : zero_.data());
            }
        }
        float* outL = hasOutput_[nodeIndex] ? left_[nodeIndex].data() : nullptr;
        float* outR = hasOutput_[nodeIndex] ? right_[nodeIndex].data() : nullptr;
        StereoProcessBlock block{inL, inR, outL, outR, frames, sampleRate_};
        processors_[nodeIndex]->process(block);
    }
    const float* finalL = left_[outputNode_].data();
    const float* finalR = right_[outputNode_].data();
    std::copy_n(finalL, frames, outputLeft);
    std::copy_n(finalR, frames, outputRight);
    return true;
}

}  // namespace caw
