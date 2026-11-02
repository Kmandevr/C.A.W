// Typed graph validation and prepared stereo execution. Build/prepare are control-thread operations.
#include "graph.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <limits>
#include <functional>
#include <queue>
#include <stdexcept>
#include <utility>

namespace caw {

namespace {
bool addEstimatedBytes(std::size_t& total, std::size_t count, std::size_t elementBytes) noexcept {
    const std::size_t maximum = std::numeric_limits<std::size_t>::max();
    if (count != 0 && elementBytes > (maximum - total) / count) return false;
    total += count * elementBytes;
    return true;
}

bool estimateGraphWorkingBytes(std::size_t nodeCount, std::size_t connectionCount,
                               std::size_t portCount, std::size_t& bytes) noexcept {
    std::size_t total = 0;
    // node IDs, indegree/outdegree, adjacency/port-vector headers, adjacency entries,
    // connected-port flags, stable ready heap and the returned execution order.
    if (!addEstimatedBytes(total, nodeCount, sizeof(std::string_view)) ||
        !addEstimatedBytes(total, nodeCount, sizeof(std::size_t)) ||
        !addEstimatedBytes(total, nodeCount, sizeof(std::size_t)) ||
        !addEstimatedBytes(total, nodeCount, sizeof(std::vector<uint32_t>)) ||
        !addEstimatedBytes(total, nodeCount, sizeof(std::vector<uint8_t>)) ||
        !addEstimatedBytes(total, connectionCount, sizeof(uint32_t)) ||
        !addEstimatedBytes(total, portCount, sizeof(uint8_t)) ||
        !addEstimatedBytes(total, nodeCount, sizeof(uint32_t)) ||
        !addEstimatedBytes(total, nodeCount, sizeof(uint32_t))) return false;
    bytes = total;
    return true;
}

bool estimateExecutorWorkingBytes(std::size_t nodeCount, uint32_t maxFrames,
                                  std::size_t& bytes) noexcept {
    std::size_t total = 0;
    const std::size_t perNodeBuffer = static_cast<std::size_t>(maxFrames) * 2u * sizeof(float);
    if (maxFrames != 0 && perNodeBuffer / maxFrames != 2u * sizeof(float)) return false;
    // Per-node metadata: two vector headers, processor pointer, input source, port flags,
    // and execution-order index. Buffer payloads and the shared zero-input block follow.
    constexpr std::size_t perNodeMetadata =
        sizeof(std::vector<float>) * 2u + sizeof(ModuleProcessor*) +
        sizeof(uint32_t) + sizeof(uint8_t) * 2u + sizeof(uint32_t);
    if (!addEstimatedBytes(total, nodeCount, perNodeMetadata) ||
        !addEstimatedBytes(total, nodeCount, perNodeBuffer) ||
        !addEstimatedBytes(total, maxFrames, sizeof(float))) return false;
    bytes = total;
    return true;
}
}  // namespace

GraphResourceBudget makeGraphResourceBudget(const EngineResourceBudget& engineBudget) noexcept {
    GraphResourceBudget budget;
    const uint64_t maximum = static_cast<uint64_t>(std::numeric_limits<std::size_t>::max());
    budget.maxWorkingBytes = static_cast<std::size_t>(std::min(engineBudget.graphWorkingBytes, maximum));
    return budget;
}

CompiledGraph compileGraph(const std::vector<GraphNode>& nodes,
                           const std::vector<GraphConnection>& connections,
                           const GraphResourceBudget& budget) {
    CompiledGraph out;
    try {
        if (budget.maxWorkingBytes == 0) {
            out.error = GraphError::InvalidResourceBudget;
            return out;
        }
        if (nodes.size() > budget.maxNodes || connections.size() > budget.maxConnections) {
            out.error = GraphError::ResourceBudgetExceeded;
            return out;
        }
        // Node references are uint32_t in the graph ABI. This is the representational
        // limit, not a product cap; connection count is bounded by the caller's budget.
        if (nodes.size() > std::numeric_limits<uint32_t>::max()) {
            out.error = GraphError::TooManyNodes;
            return out;
        }

        std::size_t portCount = 0;
        for (const GraphNode& node : nodes) {
            if (node.id.empty()) { out.error = GraphError::EmptyNodeId; return out; }
            if (!node.module) { out.error = GraphError::MissingModule; return out; }
            if (validateModuleDescriptor(*node.module) != ModuleValidation::Ok) {
                out.error = GraphError::InvalidModule;
                return out;
            }
            if (node.module->portCount > std::numeric_limits<std::size_t>::max() - portCount) {
                out.error = GraphError::SizeOverflow;
                return out;
            }
            portCount += node.module->portCount;
        }

        std::size_t estimatedBytes = 0;
        if (!estimateGraphWorkingBytes(nodes.size(), connections.size(), portCount, estimatedBytes)) {
            out.error = GraphError::SizeOverflow;
            return out;
        }
        if (estimatedBytes > budget.maxWorkingBytes) {
            out.error = GraphError::ResourceBudgetExceeded;
            return out;
        }

        // Sorting gives deterministic duplicate detection without hash-table worst cases.
        std::vector<std::string_view> nodeIds;
        nodeIds.reserve(nodes.size());
        for (const GraphNode& node : nodes) nodeIds.push_back(node.id);
        std::sort(nodeIds.begin(), nodeIds.end());
        if (std::adjacent_find(nodeIds.begin(), nodeIds.end()) != nodeIds.end()) {
            out.error = GraphError::DuplicateNodeId;
            return out;
        }

        std::vector<std::size_t> indegree(nodes.size(), 0);
        std::vector<std::size_t> outdegree(nodes.size(), 0);
        std::vector<std::vector<uint32_t>> outgoing(nodes.size());
        std::vector<std::vector<uint8_t>> connected;
        connected.reserve(nodes.size());
        for (const GraphNode& node : nodes) connected.emplace_back(node.module->portCount, 0);

        for (std::size_t i = 0; i < connections.size(); ++i) {
            const GraphConnection& connection = connections[i];
            auto fail = [&](GraphError error) {
                out.error = error;
                out.errorConnection = i;
            };
            if (connection.sourceNode >= nodes.size() || connection.destinationNode >= nodes.size()) {
                fail(GraphError::NodeIndexOutOfRange);
                return out;
            }
            const ModuleDescriptor& source = *nodes[connection.sourceNode].module;
            const ModuleDescriptor& destination = *nodes[connection.destinationNode].module;
            if (connection.sourcePort >= source.portCount || connection.destinationPort >= destination.portCount) {
                fail(GraphError::PortIndexOutOfRange);
                return out;
            }
            const PortDescriptor& sourcePort = source.ports[connection.sourcePort];
            const PortDescriptor& destinationPort = destination.ports[connection.destinationPort];
            if (sourcePort.input || !destinationPort.input) { fail(GraphError::DirectionMismatch); return out; }
            if (sourcePort.type != destinationPort.type) { fail(GraphError::PortTypeMismatch); return out; }
            if (sourcePort.layout != destinationPort.layout) { fail(GraphError::ChannelLayoutMismatch); return out; }
            if (connected[connection.destinationNode][connection.destinationPort]) {
                fail(GraphError::InputAlreadyConnected);
                return out;
            }
            connected[connection.destinationNode][connection.destinationPort] = 1;
            ++indegree[connection.destinationNode];
            ++outdegree[connection.sourceNode];
        }

        for (std::size_t i = 0; i < outgoing.size(); ++i) outgoing[i].reserve(outdegree[i]);
        for (const GraphConnection& connection : connections)
            outgoing[connection.sourceNode].push_back(connection.destinationNode);

        // Stable Kahn ordering with a min-heap preserves authored order among ready nodes.
        std::vector<uint32_t> readyStorage;
        readyStorage.reserve(nodes.size());
        std::priority_queue<uint32_t, std::vector<uint32_t>, std::greater<uint32_t>>
            ready(std::greater<uint32_t>{}, std::move(readyStorage));
        for (std::size_t i = 0; i < nodes.size(); ++i)
            if (indegree[i] == 0) ready.push(static_cast<uint32_t>(i));
        out.executionOrder.reserve(nodes.size());
        while (!ready.empty()) {
            const uint32_t next = ready.top();
            ready.pop();
            out.executionOrder.push_back(next);
            for (uint32_t destination : outgoing[next])
                if (--indegree[destination] == 0) ready.push(destination);
        }
        if (out.executionOrder.size() != nodes.size()) {
            out.error = GraphError::Cycle;
            out.executionOrder.clear();
        }
    } catch (const std::bad_alloc&) {
        out.error = GraphError::OutOfMemory;
        out.executionOrder.clear();
    } catch (const std::length_error&) {
        out.error = GraphError::OutOfMemory;
        out.executionOrder.clear();
    } catch (...) {
        out.error = GraphError::OutOfMemory;
        out.executionOrder.clear();
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
                                  double sampleRate,
                                  const GraphResourceBudget& budget) {
    reset();
    if (budget.maxWorkingBytes == 0) return GraphError::InvalidResourceBudget;
    if (nodes.size() > budget.maxNodes || connections.size() > budget.maxConnections)
        return GraphError::ResourceBudgetExceeded;
    if (nodes.empty() || processors.size() != nodes.size()) return GraphError::ProcessorCountMismatch;
    if (outputNode >= nodes.size()) return GraphError::InvalidOutputNode;
    if (maxFrames == 0 || !std::isfinite(sampleRate) ||
        sampleRate < 8000.0 || sampleRate > 192000.0) return GraphError::InvalidBlockSize;

    std::size_t executorBytes = 0;
    if (!estimateExecutorWorkingBytes(nodes.size(), maxFrames, executorBytes))
        return GraphError::SizeOverflow;
    if (executorBytes > budget.maxWorkingBytes) return GraphError::ResourceBudgetExceeded;

    CompiledGraph compiled = compileGraph(nodes, connections, budget);
    if (!compiled) return compiled.error;

    // The compiled plan remains alive while prepared buffers are allocated. Enforce the
    // peak working-set budget across both phases, not merely each phase independently.
    std::size_t portCount = 0;
    for (const GraphNode& node : nodes) {
        if (node.module->portCount > std::numeric_limits<std::size_t>::max() - portCount)
            return GraphError::SizeOverflow;
        portCount += node.module->portCount;
    }
    std::size_t compileBytes = 0;
    if (!estimateGraphWorkingBytes(nodes.size(), connections.size(), portCount, compileBytes))
        return GraphError::SizeOverflow;
    if (compileBytes > budget.maxWorkingBytes - executorBytes)
        return GraphError::ResourceBudgetExceeded;

    try {
        processors_.reserve(nodes.size());
        left_.resize(nodes.size());
        right_.resize(nodes.size());
        zero_.assign(maxFrames, 0.0f);
        inputSource_.assign(nodes.size(), UINT32_MAX);
        hasInput_.assign(nodes.size(), 0);
        hasOutput_.assign(nodes.size(), 0);
        for (size_t n = 0; n < nodes.size(); ++n) {
            if (!processors[n]) { reset(); return GraphError::MissingProcessor; }
            const ModuleDescriptor& descriptor = processors[n]->descriptor();
            if (!moduleDescriptorsMatch(descriptor, *nodes[n].module)) {
                reset(); return GraphError::ProcessorDescriptorMismatch;
            }
            uint32_t audioInputs = 0, audioOutputs = 0;
            for (uint32_t p = 0; p < descriptor.portCount; ++p) {
                const PortDescriptor& port = descriptor.ports[p];
                if (port.type != PortType::Audio) { reset(); return GraphError::RuntimeUnsupportedPortType; }
                if (port.layout != ChannelLayout::Stereo) { reset(); return GraphError::RuntimeUnsupportedPortLayout; }
                if (port.input) ++audioInputs; else ++audioOutputs;
            }
            if (audioInputs > 1 || audioOutputs > 1) { reset(); return GraphError::RuntimeUnsupportedPortCount; }
            hasInput_[n] = audioInputs ? 1 : 0;
            hasOutput_[n] = audioOutputs ? 1 : 0;
            if (audioInputs) {
                for (std::size_t e = 0; e < connections.size(); ++e)
                    if (connections[e].destinationNode == n) inputSource_[n] = connections[e].sourceNode;
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
        order_ = std::move(compiled.executionOrder);
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
            const uint32_t source = inputSource_[nodeIndex];
            if (source != UINT32_MAX) {
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

GraphError PreparedGraph::prepare(const std::vector<GraphNode>& nodes,
                                  const std::vector<GraphConnection>& connections,
                                  std::vector<std::unique_ptr<ModuleProcessor>> processors,
                                  uint32_t outputNode,
                                  uint32_t maxFrames,
                                  double sampleRate,
                                  const GraphResourceBudget& budget) {
    reset();
    try {
        std::vector<ModuleProcessor*> borrowed;
        borrowed.reserve(processors.size());
        for (const auto& processor : processors) borrowed.push_back(processor.get());
        const GraphError result = executor_.prepare(nodes, connections, borrowed, outputNode,
                                                    maxFrames, sampleRate, budget);
        if (result != GraphError::Ok) return result;
        // Moving unique_ptrs preserves processor addresses already borrowed by executor_.
        processors_ = std::move(processors);
        return GraphError::Ok;
    } catch (const std::bad_alloc&) {
        reset();
        return GraphError::OutOfMemory;
    } catch (...) {
        reset();
        return GraphError::OutOfMemory;
    }
}

void PreparedGraph::reset() noexcept {
    // Drop borrowed pointers before destroying the processors they reference.
    executor_.reset();
    processors_.clear();
}

bool PreparedGraph::process(const float* inputLeft, const float* inputRight,
                            float* outputLeft, float* outputRight, uint32_t frames) noexcept {
    return executor_.process(inputLeft, inputRight, outputLeft, outputRight, frames);
}

bool GraphRuntime::publish(PreparedGraph* prepared) noexcept {
    if (!prepared || !prepared->ready()) return false;
    PreparedGraph* expected = nullptr;
    return pending_.compare_exchange_strong(expected, prepared, std::memory_order_release,
                                            std::memory_order_relaxed);
}

bool GraphRuntime::process(const float* inputLeft, const float* inputRight,
                           float* outputLeft, float* outputRight, uint32_t frames) noexcept {
    if (!outputLeft || !outputRight || frames == 0) return false;
    if (retired_.load(std::memory_order_acquire) == nullptr) {
        PreparedGraph* next = pending_.exchange(nullptr, std::memory_order_acq_rel);
        if (next) {
            PreparedGraph* previous = active_;
            active_ = next;
            if (previous) retired_.store(previous, std::memory_order_release);
        }
    }
    if (!active_ || !active_->process(inputLeft, inputRight, outputLeft, outputRight, frames)) {
        std::fill_n(outputLeft, frames, 0.0f);
        std::fill_n(outputRight, frames, 0.0f);
        return false;
    }
    return true;
}

PreparedGraph* GraphRuntime::collectRetired() noexcept {
    return retired_.exchange(nullptr, std::memory_order_acq_rel);
}

PreparedGraph* GraphRuntime::takeActiveAfterStop() noexcept {
    PreparedGraph* result = active_;
    active_ = nullptr;
    return result;
}

PreparedGraph* GraphRuntime::takePendingAfterStop() noexcept {
    return pending_.exchange(nullptr, std::memory_order_acq_rel);
}

}  // namespace caw
