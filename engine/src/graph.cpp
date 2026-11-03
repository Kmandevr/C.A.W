// Typed graph validation and prepared planar N-channel execution. Build/prepare are control-thread operations.
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

struct ExecutorShape {
    std::size_t nodes = 0;
    std::size_t inputChannels = 0;   // sum over nodes of audio input channels
    std::size_t outputChannels = 0;  // sum over nodes of audio output channels
    std::size_t hostInputSlots = 0;  // input channels fed by the host input
};

bool estimateExecutorWorkingBytes(const ExecutorShape& shape, uint32_t maxFrames,
                                  std::size_t& bytes) noexcept {
    std::size_t total = 0;
    // Fixed vector headers: processors, channel storage, zero block, two pointer tables,
    // host-input slots, four per-node metadata arrays and the execution order.
    if (!addEstimatedBytes(total, 1, sizeof(std::vector<ModuleProcessor*>)) ||
        !addEstimatedBytes(total, 2, sizeof(std::vector<float>)) ||
        !addEstimatedBytes(total, 1, sizeof(std::vector<float*>)) ||
        !addEstimatedBytes(total, 1, sizeof(std::vector<const float*>)) ||
        !addEstimatedBytes(total, 6, sizeof(std::vector<uint32_t>))) return false;
    // Per node: processor pointer, input/output base and count, execution-order index.
    constexpr std::size_t perNodeMetadata = sizeof(ModuleProcessor*) + sizeof(uint32_t) * 5u;
    std::size_t channelFrames = 0;
    if (!addEstimatedBytes(channelFrames, shape.outputChannels, maxFrames)) return false;
    if (!addEstimatedBytes(total, shape.nodes, perNodeMetadata) ||
        !addEstimatedBytes(total, channelFrames, sizeof(float)) ||
        !addEstimatedBytes(total, shape.outputChannels, sizeof(float*)) ||
        !addEstimatedBytes(total, shape.inputChannels, sizeof(const float*)) ||
        !addEstimatedBytes(total, shape.hostInputSlots, sizeof(uint32_t)) ||
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
        if (budget.maxWorkingBytes == 0 || budget.maxChannelsPerPort == 0 ||
            budget.maxChannelsPerPort > kMaxPortChannels) {
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
            for (uint32_t p = 0; p < node.module->portCount; ++p)
                if (portChannelCount(node.module->ports[p]) > budget.maxChannelsPerPort) {
                    out.error = GraphError::TooManyChannels;
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
            // Discrete ports share one layout value, so compare resolved channel counts too:
            // routing is never truncated or padded.
            if (sourcePort.layout != destinationPort.layout ||
                portChannelCount(sourcePort) != portChannelCount(destinationPort)) {
                fail(GraphError::ChannelLayoutMismatch);
                return out;
            }
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
    channelStorage_.clear();
    outputTable_.clear();
    inputTable_.clear();
    hostInputSlots_.clear();
    inputBase_.clear();
    inputCount_.clear();
    outputBase_.clear();
    outputCount_.clear();
    zero_.clear();
    order_.clear();
    outputNode_ = UINT32_MAX;
    hostInputChannels_ = 0;
    outputChannels_ = 0;
    maxFrames_ = 0;
    sampleRate_ = 48000.0;
    failedNode_.store(UINT32_MAX, std::memory_order_relaxed);
    failures_.store(0, std::memory_order_relaxed);
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

    CompiledGraph compiled = compileGraph(nodes, connections, budget);
    if (!compiled) return compiled.error;

    // Descriptors are validated now. Resolve each node's single audio input/output port and
    // its channel count; the runtime does not execute other port types yet (roadmap F5).
    const std::size_t nodeCount = nodes.size();
    ExecutorShape shape;
    shape.nodes = nodeCount;
    for (std::size_t n = 0; n < nodeCount; ++n) {
        if (!processors[n]) return GraphError::MissingProcessor;
        const ModuleDescriptor& descriptor = processors[n]->descriptor();
        if (!moduleDescriptorsMatch(descriptor, *nodes[n].module)) return GraphError::ProcessorDescriptorMismatch;
        uint32_t audioInputs = 0, audioOutputs = 0;
        for (uint32_t p = 0; p < descriptor.portCount; ++p) {
            const PortDescriptor& port = descriptor.ports[p];
            if (port.type != PortType::Audio) return GraphError::RuntimeUnsupportedPortType;
            if (port.input) { ++audioInputs; shape.inputChannels += portChannelCount(port); }
            else { ++audioOutputs; shape.outputChannels += portChannelCount(port); }
        }
        if (audioInputs > 1 || audioOutputs > 1) return GraphError::RuntimeUnsupportedPortCount;
    }

    std::size_t executorBytes = 0, retainedPlanBytes = 0;
    try {
        // Host-input slots are known only after connections are resolved; bound them by every
        // input channel so the budget check happens before any executor allocation.
        shape.hostInputSlots = shape.inputChannels;
        if (!estimateExecutorWorkingBytes(shape, maxFrames, executorBytes)) return GraphError::SizeOverflow;
        // Graph compilation has already checked its own peak. Its temporary adjacency and
        // scheduling storage is gone now; only the returned execution order remains live while
        // prepared buffers are allocated. Account for that retained plan plus executor storage.
        if (!addEstimatedBytes(retainedPlanBytes, compiled.executionOrder.capacity(), sizeof(uint32_t)))
            return GraphError::SizeOverflow;
        if (executorBytes > budget.maxWorkingBytes ||
            retainedPlanBytes > budget.maxWorkingBytes - executorBytes)
            return GraphError::ResourceBudgetExceeded;

        inputBase_.assign(nodeCount, 0);
        inputCount_.assign(nodeCount, 0);
        outputBase_.assign(nodeCount, 0);
        outputCount_.assign(nodeCount, 0);
        std::vector<uint8_t> hasInput(nodeCount, 0), hasOutput(nodeCount, 0);
        uint32_t inputCursor = 0, outputCursor = 0;
        for (std::size_t n = 0; n < nodeCount; ++n) {
            const ModuleDescriptor& descriptor = *nodes[n].module;
            for (uint32_t p = 0; p < descriptor.portCount; ++p) {
                const PortDescriptor& port = descriptor.ports[p];
                const uint32_t channels = portChannelCount(port);
                if (port.input) { hasInput[n] = 1; inputBase_[n] = inputCursor; inputCount_[n] = channels; inputCursor += channels; }
                else { hasOutput[n] = 1; outputBase_[n] = outputCursor; outputCount_[n] = channels; outputCursor += channels; }
            }
        }
        if (!hasOutput[outputNode]) { reset(); return GraphError::InvalidOutputNode; }

        std::vector<uint32_t> inputSource(nodeCount, UINT32_MAX);
        for (const GraphConnection& edge : connections) {
            if (!hasOutput[edge.sourceNode] || !hasInput[edge.destinationNode]) {
                reset(); return GraphError::ProcessorDescriptorMismatch;
            }
            // compileGraph already rejects this; keep the executor safe on its own.
            if (outputCount_[edge.sourceNode] != inputCount_[edge.destinationNode]) {
                reset(); return GraphError::ChannelLayoutMismatch;
            }
            inputSource[edge.destinationNode] = edge.sourceNode;
        }

        uint32_t hostChannels = 0;
        std::size_t hostSlots = 0;
        for (std::size_t n = 0; n < nodeCount; ++n) {
            if (!hasInput[n] || inputSource[n] != UINT32_MAX) continue;
            if (hostSlots != 0 && inputCount_[n] != hostChannels) {
                reset(); return GraphError::RuntimeHostInputMismatch;
            }
            hostChannels = inputCount_[n];
            hostSlots += inputCount_[n];
        }

        channelStorage_.assign(static_cast<std::size_t>(outputCursor) * maxFrames, 0.0f);
        zero_.assign(maxFrames, 0.0f);
        outputTable_.resize(outputCursor);
        for (uint32_t c = 0; c < outputCursor; ++c)
            outputTable_[c] = channelStorage_.data() + static_cast<std::size_t>(c) * maxFrames;
        inputTable_.assign(inputCursor, zero_.data());
        hostInputSlots_.reserve(hostSlots);
        for (std::size_t n = 0; n < nodeCount; ++n) {
            if (!hasInput[n]) continue;
            for (uint32_t c = 0; c < inputCount_[n]; ++c) {
                const uint32_t slot = inputBase_[n] + c;
                if (inputSource[n] != UINT32_MAX)
                    inputTable_[slot] = outputTable_[outputBase_[inputSource[n]] + c];
                else
                    hostInputSlots_.push_back(slot);
            }
        }
        processors_.assign(processors.begin(), processors.end());
        order_ = std::move(compiled.executionOrder);
        outputNode_ = outputNode;
        hostInputChannels_ = hostChannels;
        outputChannels_ = outputCount_[outputNode];
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

void GraphExecutor::fail(uint32_t node, const ChannelBufferView& output, uint32_t frames) noexcept {
    failedNode_.store(node, std::memory_order_relaxed);
    failures_.fetch_add(1, std::memory_order_relaxed);
    for (uint32_t c = 0; c < output.channelCount; ++c) std::fill_n(output.channels[c], frames, 0.0f);
}

bool GraphExecutor::process(const ConstChannelBufferView& input, const ChannelBufferView& output,
                            uint32_t frames) noexcept {
    if (!ready_ || frames == 0 || frames > maxFrames_) return false;
    if (output.channelCount != outputChannels_ || !output.valid() || output.frames < frames) return false;
    if (input.channelCount != 0 &&
        (input.channelCount != hostInputChannels_ || !input.valid() || input.frames < frames)) return false;

    // Bind this call's host channels (or silence) into the prepared input table.
    const std::size_t slots = hostInputSlots_.size();
    for (std::size_t s = 0; s < slots; ++s)
        inputTable_[hostInputSlots_[s]] =
            input.channelCount ? input.channels[s % hostInputChannels_] : zero_.data();

    for (uint32_t node : order_) {
        const AudioProcessBlock block{
            {inputTable_.data() + inputBase_[node], inputCount_[node], frames},
            {outputTable_.data() + outputBase_[node], outputCount_[node], maxFrames_},
            frames, sampleRate_};
        if (!processors_[node]->process(block)) { fail(node, output, frames); return false; }
    }
    float* const* result = outputTable_.data() + outputBase_[outputNode_];
    for (uint32_t c = 0; c < outputChannels_; ++c) std::copy_n(result[c], frames, output.channels[c]);
    return true;
}

bool GraphExecutor::process(const float* inputLeft, const float* inputRight,
                            float* outputLeft, float* outputRight, uint32_t frames) noexcept {
    if (!ready_ || !outputLeft || !outputRight || outputChannels_ != 2) return false;
    if (frames == 0 || frames > maxFrames_) return false;
    const bool hasHostInput = inputLeft || inputRight;
    if (hasHostInput && hostInputChannels_ != 0 && hostInputChannels_ != 2) return false;
    const float* inputs[2] = {inputLeft ? inputLeft : zero_.data(), inputRight ? inputRight : zero_.data()};
    float* outputs[2] = {outputLeft, outputRight};
    const ConstChannelBufferView in = hasHostInput && hostInputChannels_ == 2
        ? ConstChannelBufferView{inputs, 2, frames} : ConstChannelBufferView{};
    return process(in, ChannelBufferView{outputs, 2, frames}, frames);
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

bool PreparedGraph::process(const ConstChannelBufferView& input, const ChannelBufferView& output,
                            uint32_t frames) noexcept {
    return executor_.process(input, output, frames);
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

PreparedGraph* GraphRuntime::adopt() noexcept {
    if (retired_.load(std::memory_order_acquire) == nullptr) {
        PreparedGraph* next = pending_.exchange(nullptr, std::memory_order_acq_rel);
        if (next) {
            PreparedGraph* previous = active_;
            active_ = next;
            if (previous) retired_.store(previous, std::memory_order_release);
        }
    }
    return active_;
}

bool GraphRuntime::process(const ConstChannelBufferView& input, const ChannelBufferView& output,
                           uint32_t frames) noexcept {
    if (frames == 0 || !output.valid() || output.frames < frames) return false;
    PreparedGraph* active = adopt();
    if (!active || !active->process(input, output, frames)) {
        for (uint32_t c = 0; c < output.channelCount; ++c) std::fill_n(output.channels[c], frames, 0.0f);
        return false;
    }
    return true;
}

bool GraphRuntime::process(const float* inputLeft, const float* inputRight,
                           float* outputLeft, float* outputRight, uint32_t frames) noexcept {
    if (!outputLeft || !outputRight || frames == 0) return false;
    PreparedGraph* active = adopt();
    if (!active || !active->process(inputLeft, inputRight, outputLeft, outputRight, frames)) {
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
