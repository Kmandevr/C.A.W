// Typed graph validation and prepared planar N-channel execution. Build/prepare are control-thread operations.
#include "graph.h"
#include "midi2.h"
#include "route_math.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <limits>
#include <functional>
#include <queue>
#include <stdexcept>
#include <tuple>
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
        !addEstimatedBytes(total, nodeCount, sizeof(uint32_t)) ||
        !addEstimatedBytes(total, connectionCount, sizeof(std::size_t))) return false;  // summing-edge sort
    bytes = total;
    return true;
}

// Same layouts as GraphExecutor's private Port, NodeBlock and SumInput, for the byte estimate.
struct GraphExecutorSumInputBytes { uint32_t sourceBase, sourceCount, tableBase, channels; };
struct GraphExecutorPortBytes { PortType type; bool input, summing, host; uint32_t channels, table, sum; };
struct GraphExecutorNodeBlockBytes { uint32_t fields[22]; bool typed; };
struct GraphExecutorEventMergeBytes { uint32_t sourceBase, sourceCount, input; std::size_t storage; };

struct ExecutorShape {
    std::size_t nodes = 0;
    std::size_t inputChannels = 0;   // sum over nodes of audio input channels
    std::size_t outputChannels = 0;  // sum over nodes of audio output channels
    std::size_t hostInputSlots = 0;  // input channels fed by the host input
    // Fan-in upper bounds, known before allocation without temporaries.
    std::size_t sumInputs = 0;       // summing input ports
    std::size_t sumChannels = 0;     // channels of summing input ports
    std::size_t sumSources = 0;      // connections (any of them may feed a summing input)
    std::size_t ports = 0;           // every port of every node
    std::size_t audioInputPorts = 0, audioOutputPorts = 0;  // one prepared view each
    std::size_t controlInputs = 0, controlOutputs = 0;      // one value and one pointer each
    std::size_t eventInputs = 0, eventOutputs = 0;          // one table entry each (inputs: and a source)
    std::size_t eventMergeInputs = 0;                       // summing event inputs: a buffer and a merge each
    std::size_t eventMergeSources = 0;                      // connections into summing event inputs
    std::size_t eventCapacity = 0;                          // events per buffer
    std::size_t parameters = 0;                             // descriptor parameters of every node
};

bool estimateExecutorWorkingBytes(const ExecutorShape& shape, uint32_t maxFrames,
                                  std::size_t& bytes) noexcept {
    std::size_t total = 0;
    // Fixed vector headers: processors, channel, control, zero and sum storage, five pointer
    // tables, host-input slots, per-node metadata arrays, sum sources, the port, node-block,
    // view and sum-input lists, the execution order, and the event storage, tables, sources,
    // merges, merge sources and merge cursors, and the parameter resolvers, values and storage.
    if (!addEstimatedBytes(total, 1, sizeof(std::vector<ModuleProcessor*>)) ||
        !addEstimatedBytes(total, 4, sizeof(std::vector<float>)) ||
        !addEstimatedBytes(total, 3, sizeof(std::vector<float*>)) ||
        !addEstimatedBytes(total, 2, sizeof(std::vector<const float*>)) ||
        !addEstimatedBytes(total, 13, sizeof(std::vector<uint32_t>)) ||
        !addEstimatedBytes(total, 1, sizeof(std::vector<Event>)) ||
        !addEstimatedBytes(total, 1, sizeof(std::vector<EventOutput>)) ||
        !addEstimatedBytes(total, 1, sizeof(std::vector<EventInput>)) ||
        !addEstimatedBytes(total, 1, sizeof(std::vector<GraphExecutorEventMergeBytes>)) ||
        !addEstimatedBytes(total, 1, sizeof(std::vector<ParameterResolver>)) ||
        !addEstimatedBytes(total, 1, sizeof(std::vector<ParameterValue>)) ||
        !addEstimatedBytes(total, 6, sizeof(std::vector<double>)) ||
        !addEstimatedBytes(total, 1, sizeof(std::vector<GraphExecutorPortBytes>)) ||
        !addEstimatedBytes(total, 1, sizeof(std::vector<GraphExecutorNodeBlockBytes>)) ||
        !addEstimatedBytes(total, 2, sizeof(std::vector<ChannelBufferView>)) ||
        !addEstimatedBytes(total, 1, sizeof(std::vector<GraphExecutorSumInputBytes>))) return false;
    // Ports, prepared audio views and control values with their pointers.
    if (!addEstimatedBytes(total, shape.ports, sizeof(GraphExecutorPortBytes)) ||
        !addEstimatedBytes(total, shape.audioInputPorts, sizeof(ConstChannelBufferView)) ||
        !addEstimatedBytes(total, shape.audioOutputPorts, sizeof(ChannelBufferView)) ||
        !addEstimatedBytes(total, shape.controlInputs + shape.controlOutputs, sizeof(float) + sizeof(float*)))
        return false;
    // Event tables, merges with their sources and cursors, and every event buffer.
    std::size_t eventBuffers = 0;
    if (!addEstimatedBytes(total, shape.eventOutputs, sizeof(EventOutput)) ||
        !addEstimatedBytes(total, shape.eventInputs, sizeof(EventInput) + sizeof(uint32_t)) ||
        !addEstimatedBytes(total, shape.eventMergeInputs, sizeof(GraphExecutorEventMergeBytes)) ||
        !addEstimatedBytes(total, shape.eventMergeSources, 2u * sizeof(uint32_t)) ||
        !addEstimatedBytes(eventBuffers, shape.eventOutputs + shape.eventMergeInputs, shape.eventCapacity) ||
        !addEstimatedBytes(total, eventBuffers, sizeof(Event)))
        return false;
    // Parameters: a resolver, a resolved value and maxFrames doubles each.
    std::size_t parameterFrames = 0;
    if (!addEstimatedBytes(total, shape.parameters, sizeof(ParameterResolver) + sizeof(ParameterValue) + sizeof(uint64_t) +
                                                        kMaxParameterLinks * sizeof(const float*) +
                                                        sizeof(const AutomationPoint*) + sizeof(uint32_t) +
                                                        sizeof(uint32_t)) ||  // lane slot, then CC key
        (shape.parameters && !addEstimatedBytes(total, maxFrames, sizeof(double))) ||  // the lane scratch
        !addEstimatedBytes(parameterFrames, shape.parameters, maxFrames) ||
        !addEstimatedBytes(total, parameterFrames, sizeof(double)))
        return false;
    // Per node: processor pointer, first input/output base and count, port base and node block.
    // The execution order is the retained plan, which prepare() counts separately.
    constexpr std::size_t perNodeMetadata =
        sizeof(ModuleProcessor*) + sizeof(uint32_t) * 5u + sizeof(GraphExecutorNodeBlockBytes);
    std::size_t channelFrames = 0, sumFrames = 0;
    if (!addEstimatedBytes(channelFrames, shape.outputChannels, maxFrames)) return false;
    if (!addEstimatedBytes(sumFrames, shape.sumChannels, maxFrames)) return false;
    if (!addEstimatedBytes(total, sumFrames, sizeof(float)) ||
        !addEstimatedBytes(total, shape.sumChannels, sizeof(float*)) ||
        !addEstimatedBytes(total, shape.sumSources, sizeof(uint32_t)) ||
        !addEstimatedBytes(total, shape.sumInputs, sizeof(GraphExecutorSumInputBytes))) return false;
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
            if (!destinationPort.summing && connected[connection.destinationNode][connection.destinationPort]) {
                fail(GraphError::InputAlreadyConnected);
                return out;
            }
            connected[connection.destinationNode][connection.destinationPort] = 1;
            ++indegree[connection.destinationNode];
            ++outdegree[connection.sourceNode];
        }

        // A summing input may take many connections, but never the same one twice: that would
        // sum one source twice (+6 dB) silently. Sorting keeps this O(E log E).
        std::vector<std::size_t> summingEdges;
        summingEdges.reserve(connections.size());
        for (std::size_t i = 0; i < connections.size(); ++i) {
            const GraphConnection& c = connections[i];
            if (nodes[c.destinationNode].module->ports[c.destinationPort].summing) summingEdges.push_back(i);
        }
        auto key = [&](std::size_t i) {
            const GraphConnection& c = connections[i];
            return std::make_tuple(c.destinationNode, c.destinationPort, c.sourceNode, c.sourcePort, i);
        };
        std::sort(summingEdges.begin(), summingEdges.end(),
                  [&](std::size_t a, std::size_t b) { return key(a) < key(b); });
        std::size_t firstDuplicate = static_cast<std::size_t>(-1);
        for (std::size_t k = 1; k < summingEdges.size(); ++k) {
            const GraphConnection& a = connections[summingEdges[k - 1]];
            const GraphConnection& b = connections[summingEdges[k]];
            if (a.destinationNode == b.destinationNode && a.destinationPort == b.destinationPort &&
                a.sourceNode == b.sourceNode && a.sourcePort == b.sourcePort)
                firstDuplicate = std::min(firstDuplicate, summingEdges[k]);
        }
        if (firstDuplicate != static_cast<std::size_t>(-1)) {
            out.error = GraphError::DuplicateConnection;
            out.errorConnection = firstDuplicate;
            return out;
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
    ports_.clear();
    nodePortBase_.clear();
    blocks_.clear();
    audioInViews_.clear();
    audioOutViews_.clear();
    channelStorage_.clear();
    outputTable_.clear();
    inputTable_.clear();
    controlStorage_.clear();
    controlOutTable_.clear();
    controlInTable_.clear();
    hostInputSlots_.clear();
    inputBase_.clear();
    inputCount_.clear();
    outputBase_.clear();
    outputCount_.clear();
    zero_.clear();
    sumInputs_.clear();
    sumSources_.clear();
    sumTable_.clear();
    sumStorage_.clear();
    eventStorage_.clear();
    eventOutTable_.clear();
    eventInTable_.clear();
    eventInSource_.clear();
    eventMerges_.clear();
    eventMergeSources_.clear();
    mergeCursor_.clear();
    eventCapacity_ = 0;
    resolvers_.clear();
    parameterValues_.clear();
    parameterStorage_.clear();
    touchEpoch_.clear();
    clearEpoch_ = 0;
    linkSignals_.clear();
    linkCount_ = 0;
    lanePoints_.clear();
    laneCount_.clear();
    ccKey_.clear();
    hostEvents_ = EventInput{};
    automationScratch_.clear();
    transportSample_ = 0;
    samplesPerStep_ = 1.0;
    playing_ = false;
    order_.clear();
    routePosition_.clear();
    routeCount_.clear();
    routeStaging_.clear();
    directStaging_.clear();
    routePlain_ = false;
    preparedBytes_ = 0;
    staticConnections_ = 0;
    routingCapacity_ = 0;
    runCount_ = 0;
    outputNode_ = UINT32_MAX;
    hostInputChannels_ = 0;
    outputChannels_ = 0;
    maxFrames_ = 0;
    sampleRate_ = 48000.0;
    failedNode_.store(UINT32_MAX, std::memory_order_relaxed);
    failures_.store(0, std::memory_order_relaxed);
    eventsDropped_.store(0, std::memory_order_relaxed);
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

    // Descriptors are validated now. Count every port by type.
    const std::size_t nodeCount = nodes.size();
    ExecutorShape shape;
    shape.nodes = nodeCount;
    for (std::size_t n = 0; n < nodeCount; ++n) {
        if (!processors[n]) return GraphError::MissingProcessor;
        const ModuleDescriptor& descriptor = processors[n]->descriptor();
        if (!moduleDescriptorsMatch(descriptor, *nodes[n].module)) return GraphError::ProcessorDescriptorMismatch;
        uint32_t audioInputs = 0, audioOutputs = 0, others = 0;
        for (uint32_t p = 0; p < descriptor.portCount; ++p) {
            const PortDescriptor& port = descriptor.ports[p];
            const uint32_t channels = port.type == PortType::Audio ? portChannelCount(port) : 1u;
            switch (port.type) {
                case PortType::Event:
                    ++others;
                    ++(port.input ? shape.eventInputs : shape.eventOutputs);
                    if (port.input && port.summing) ++shape.eventMergeInputs;
                    break;
                case PortType::Control:
                    ++others;
                    ++(port.input ? shape.controlInputs : shape.controlOutputs);
                    break;
                case PortType::Audio:
                case PortType::Modulation:
                    if (port.type == PortType::Audio) {
                        ++(port.input ? audioInputs : audioOutputs);
                        ++(port.input ? shape.audioInputPorts : shape.audioOutputPorts);
                    } else {
                        ++others;
                    }
                    if (port.input) {
                        shape.inputChannels += channels;
                        if (port.summing) { ++shape.sumInputs; shape.sumChannels += channels; }
                    } else {
                        shape.outputChannels += channels;
                    }
                    break;
            }
        }
        shape.ports += descriptor.portCount;
        shape.parameters += descriptor.parameterCount;
        const bool typed = audioInputs > 1 || audioOutputs > 1 || others > 0;
        if (typed && !processors[n]->usesProcessPorts())
            return others > 0 ? GraphError::RuntimeUnsupportedPortType : GraphError::RuntimeUnsupportedPortCount;
    }
    // Host events are bounded by the same capacity even without event ports (CC mappings read
    // them); buffers are sized by port counts, so the capacity alone costs nothing.
    shape.eventCapacity = budget.maxEventsPerPort;
    if (shape.eventInputs + shape.eventOutputs != 0) {
        if (budget.maxEventsPerPort == 0) return GraphError::InvalidResourceBudget;
        for (const GraphConnection& edge : connections) {  // compileGraph checked every index
            const PortDescriptor& to = nodes[edge.destinationNode].module->ports[edge.destinationPort];
            if (to.type == PortType::Event && to.summing) ++shape.eventMergeSources;
        }
    }

    std::size_t executorBytes = 0, retainedPlanBytes = 0;
    try {
        // Host-input slots are known only after connections are resolved; bound them by every
        // input channel so the budget check happens before any executor allocation.
        shape.hostInputSlots = shape.inputChannels;
        shape.sumSources = connections.size();
        if (!estimateExecutorWorkingBytes(shape, maxFrames, executorBytes)) return GraphError::SizeOverflow;
        // Graph compilation has already checked its own peak. Its temporary adjacency and
        // scheduling storage is gone now; only the returned execution order remains live while
        // prepared buffers are allocated. Account for that retained plan plus executor storage.
        if (!addEstimatedBytes(retainedPlanBytes, compiled.executionOrder.capacity(), sizeof(uint32_t)))
            return GraphError::SizeOverflow;
        if (executorBytes > budget.maxWorkingBytes ||
            retainedPlanBytes > budget.maxWorkingBytes - executorBytes)
            return GraphError::ResourceBudgetExceeded;

        // Every allocation below is counted in executorBytes; no uncounted temporaries.
        // Ports are laid out node by node; within a node, audio entries come before modulation.
        ports_.resize(shape.ports);
        nodePortBase_.assign(nodeCount, 0);
        blocks_.assign(nodeCount, NodeBlock{});
        inputBase_.assign(nodeCount, 0);
        inputCount_.assign(nodeCount, 0);
        outputBase_.assign(nodeCount, 0);
        outputCount_.assign(nodeCount, 0);
        uint32_t portCursor = 0, inputCursor = 0, outputCursor = 0, controlInCursor = 0, controlOutCursor = 0;
        uint32_t eventInCursor = 0, eventOutCursor = 0, paramCursor = 0;
        uint32_t audioInViews = 0, audioOutViews = 0;
        for (std::size_t n = 0; n < nodeCount; ++n) {
            const ModuleDescriptor& descriptor = *nodes[n].module;
            nodePortBase_[n] = portCursor;
            NodeBlock& b = blocks_[n];
            b.audioIn = audioInViews;
            b.audioOut = audioOutViews;
            for (int pass = 0; pass < 2; ++pass) {  // audio, then modulation
                const PortType type = pass == 0 ? PortType::Audio : PortType::Modulation;
                if (pass == 1) { b.modIn = inputCursor; b.modOut = outputCursor; }
                for (uint32_t p = 0; p < descriptor.portCount; ++p) {
                    const PortDescriptor& port = descriptor.ports[p];
                    if (port.type != type) continue;
                    const uint32_t channels = type == PortType::Audio ? portChannelCount(port) : 1u;
                    Port& out = ports_[portCursor + p];
                    out = Port{type, port.input, port.summing, false, channels, port.input ? inputCursor : outputCursor,
                               UINT32_MAX};
                    if (port.input) {
                        if (type == PortType::Audio && inputCount_[n] == 0) { inputBase_[n] = inputCursor; inputCount_[n] = channels; }
                        inputCursor += channels;
                        if (type == PortType::Audio) { ++audioInViews; ++b.audioInCount; } else ++b.modInCount;
                    } else {
                        if (type == PortType::Audio && outputCount_[n] == 0) { outputBase_[n] = outputCursor; outputCount_[n] = channels; }
                        outputCursor += channels;
                        if (type == PortType::Audio) { ++audioOutViews; ++b.audioOutCount; } else ++b.modOutCount;
                    }
                }
            }
            b.controlIn = controlInCursor;
            b.controlOut = controlOutCursor;
            for (uint32_t p = 0; p < descriptor.portCount; ++p) {
                const PortDescriptor& port = descriptor.ports[p];
                if (port.type != PortType::Control) continue;
                ports_[portCursor + p] = Port{PortType::Control, port.input, false, false, 1,
                                              port.input ? controlInCursor++ : controlOutCursor++, UINT32_MAX};
                ++(port.input ? b.controlInCount : b.controlOutCount);
            }
            b.eventIn = eventInCursor;
            b.eventOut = eventOutCursor;
            for (uint32_t p = 0; p < descriptor.portCount; ++p) {
                const PortDescriptor& port = descriptor.ports[p];
                if (port.type != PortType::Event) continue;
                ports_[portCursor + p] = Port{PortType::Event, port.input, port.summing, false, 1,
                                              port.input ? eventInCursor++ : eventOutCursor++, UINT32_MAX};
                ++(port.input ? b.eventInCount : b.eventOutCount);
            }
            b.paramBase = paramCursor;
            b.paramCount = descriptor.parameterCount;
            paramCursor += descriptor.parameterCount;
            b.typed = b.audioInCount > 1 || b.audioOutCount > 1 || b.modInCount || b.modOutCount ||
                      b.controlInCount || b.controlOutCount || b.eventInCount || b.eventOutCount;
            portCursor += descriptor.portCount;
        }
        if (outputCount_[outputNode] == 0) { reset(); return GraphError::InvalidOutputNode; }

        channelStorage_.assign(static_cast<std::size_t>(outputCursor) * maxFrames, 0.0f);
        zero_.assign(maxFrames, 0.0f);
        outputTable_.resize(outputCursor);
        for (uint32_t c = 0; c < outputCursor; ++c)
            outputTable_[c] = channelStorage_.data() + static_cast<std::size_t>(c) * maxFrames;
        // Null marks an input channel no connection feeds yet; resolved to host or silence below.
        inputTable_.assign(inputCursor, nullptr);
        // Control storage: outputs, then the inputs' defaults. Sized once, so pointers stay valid.
        controlStorage_.assign(static_cast<std::size_t>(controlOutCursor) + controlInCursor, 0.0f);
        controlOutTable_.resize(controlOutCursor);
        controlInTable_.resize(controlInCursor);
        audioInViews_.resize(audioInViews);
        audioOutViews_.resize(audioOutViews);
        // Event buffers: outputs first, then one per summing event input (bound to merges below).
        eventCapacity_ = static_cast<uint32_t>(shape.eventCapacity);
        eventStorage_.resize((shape.eventOutputs + shape.eventMergeInputs) * shape.eventCapacity);
        eventOutTable_.resize(eventOutCursor);
        for (uint32_t k = 0; k < eventOutCursor; ++k)
            eventOutTable_[k] = EventOutput{eventStorage_.data() + static_cast<std::size_t>(k) * eventCapacity_, eventCapacity_, 0};
        eventInTable_.assign(eventInCursor, EventInput{});
        eventInSource_.assign(eventInCursor, kEventNone);
        // Parameters start at their defaults, untouched, unlinked.
        resolvers_.resize(paramCursor);
        parameterValues_.assign(paramCursor, ParameterValue{});
        parameterStorage_.assign(static_cast<std::size_t>(paramCursor) * maxFrames, 0.0);
        touchEpoch_.assign(paramCursor, 0);
        clearEpoch_ = 0;
        linkSignals_.assign(static_cast<std::size_t>(paramCursor) * kMaxParameterLinks, nullptr);
        lanePoints_.assign(paramCursor, nullptr);
        laneCount_.assign(paramCursor, 0);
        ccKey_.assign(paramCursor, kNoCc);
        automationScratch_.assign(paramCursor ? maxFrames : 0u, 0.0);
        for (std::size_t n = 0; n < nodeCount; ++n) {
            const ModuleDescriptor& descriptor = *nodes[n].module;
            for (uint32_t k = 0; k < descriptor.parameterCount; ++k)
                if (!resolvers_[blocks_[n].paramBase + k].configure(descriptor.parameters[k])) {
                    reset(); return GraphError::InvalidModule;  // validated already; keep the executor safe on its own
                }
        }
        // The audio thread is not running during prepare(): drop commands meant for the old graph.
        for (ParameterCommand stale; parameterQueue_.pop(stale);) {}
        for (std::size_t n = 0; n < nodeCount; ++n) {
            const ModuleDescriptor& descriptor = *nodes[n].module;
            const NodeBlock& b = blocks_[n];
            uint32_t ai = b.audioIn, ao = b.audioOut;
            for (uint32_t p = 0; p < descriptor.portCount; ++p) {
                const Port& port = ports_[nodePortBase_[n] + p];
                if (port.type == PortType::Audio && port.input)
                    audioInViews_[ai++] = ConstChannelBufferView{inputTable_.data() + port.table, port.channels, maxFrames};
                else if (port.type == PortType::Audio)
                    audioOutViews_[ao++] = ChannelBufferView{outputTable_.data() + port.table, port.channels, maxFrames};
                else if (port.type == PortType::Control && port.input) {
                    float* value = controlStorage_.data() + controlOutCursor + port.table;
                    *value = descriptor.ports[p].defaultValue;
                    controlInTable_[port.table] = value;
                } else if (port.type == PortType::Control) {
                    float* value = controlStorage_.data() + port.table;
                    *value = descriptor.ports[p].defaultValue;
                    controlOutTable_[port.table] = value;
                }
            }
        }

        // Plain connections bind directly; summing inputs only count their sources here (`sum`
        // counts, then becomes the sumInputs_ index), in O(nodes + edges).
        for (Port& port : ports_)
            if (port.input && port.summing) port.sum = 0;
        for (const GraphConnection& edge : connections) {
            const Port& from = ports_[nodePortBase_[edge.sourceNode] + edge.sourcePort];
            Port& to = ports_[nodePortBase_[edge.destinationNode] + edge.destinationPort];
            // compileGraph already checks direction, type and channels; keep the executor safe on its own.
            if (from.input || !to.input || from.type != to.type || from.channels != to.channels) {
                reset(); return GraphError::ChannelLayoutMismatch;
            }
            if (to.summing) { ++to.sum; continue; }
            if (to.type == PortType::Event) {
                eventInSource_[to.table] = from.table;
                continue;
            }
            if (to.type == PortType::Control) {
                controlInTable_[to.table] = controlOutTable_[from.table];
                continue;
            }
            for (uint32_t c = 0; c < to.channels; ++c) inputTable_[to.table + c] = outputTable_[from.table + c];
        }
        uint32_t sumChannels = 0, sumCount = 0, sourceTotal = 0;
        for (const Port& port : ports_) {
            if (port.sum == UINT32_MAX || port.sum == 0 || port.type == PortType::Event) continue;
            sumChannels += port.channels;
            sourceTotal += port.sum;
            ++sumCount;
        }
        sumInputs_.reserve(sumCount);
        sumSources_.assign(sourceTotal, 0);
        sumStorage_.assign(static_cast<std::size_t>(sumChannels) * maxFrames, 0.0f);
        sumTable_.resize(sumChannels);
        eventMerges_.reserve(shape.eventMergeInputs);
        eventMergeSources_.assign(shape.eventMergeSources, 0);
        mergeCursor_.assign(shape.eventMergeSources, 0);
        uint32_t tableCursor = 0, sourceCursor = 0, mergeSourceCursor = 0;
        for (std::size_t n = 0; n < nodeCount; ++n) {
            NodeBlock& b = blocks_[n];
            b.sumBase = static_cast<uint32_t>(sumInputs_.size());
            b.mergeBase = static_cast<uint32_t>(eventMerges_.size());
            const uint32_t portEnd = n + 1 < nodeCount ? nodePortBase_[n + 1] : static_cast<uint32_t>(ports_.size());
            for (uint32_t g = nodePortBase_[n]; g < portEnd; ++g) {
                Port& port = ports_[g];
                if (port.sum == UINT32_MAX) continue;
                if (port.sum == 0) { port.sum = UINT32_MAX; continue; }  // unconnected: host or silence
                const uint32_t sources = port.sum;
                if (port.type == PortType::Event) {
                    port.sum = static_cast<uint32_t>(eventMerges_.size());
                    const std::size_t storage = (static_cast<std::size_t>(eventOutCursor) + port.sum) * eventCapacity_;
                    eventMerges_.push_back(EventMerge{mergeSourceCursor, 0, port.table, storage});
                    mergeSourceCursor += sources;
                    eventInSource_[port.table] = kEventMerged;
                    continue;
                }
                port.sum = static_cast<uint32_t>(sumInputs_.size());
                sumInputs_.push_back(SumInput{sourceCursor, 0, tableCursor, port.channels});  // sourceCount fills below
                sourceCursor += sources;
                for (uint32_t c = 0; c < port.channels; ++c, ++tableCursor) {
                    sumTable_[tableCursor] = sumStorage_.data() + static_cast<std::size_t>(tableCursor) * maxFrames;
                    inputTable_[port.table + c] = sumTable_[tableCursor];
                }
            }
            b.sumCount = static_cast<uint32_t>(sumInputs_.size()) - b.sumBase;
            b.mergeCount = static_cast<uint32_t>(eventMerges_.size()) - b.mergeBase;
        }
        // Connection order within each summing input is the summation (or merge tie) order.
        for (const GraphConnection& edge : connections) {
            const Port& to = ports_[nodePortBase_[edge.destinationNode] + edge.destinationPort];
            if (!to.summing || to.sum == UINT32_MAX) continue;
            if (to.type == PortType::Event) {
                EventMerge& merge = eventMerges_[to.sum];
                eventMergeSources_[merge.sourceBase + merge.sourceCount++] =
                    ports_[nodePortBase_[edge.sourceNode] + edge.sourcePort].table;
                continue;
            }
            SumInput& sum = sumInputs_[to.sum];
            sumSources_[sum.sourceBase + sum.sourceCount++] = nodePortBase_[edge.sourceNode] + edge.sourcePort;
        }

        // A node's first audio input, when unconnected, reads the host input.
        uint32_t hostChannels = 0;
        std::size_t hostSlots = 0;
        for (std::size_t n = 0; n < nodeCount; ++n) {
            if (inputCount_[n] == 0 || inputTable_[inputBase_[n]] != nullptr) continue;
            if (!deferHostCheck_ && hostSlots != 0 && inputCount_[n] != hostChannels) {
                reset(); return GraphError::RuntimeHostInputMismatch;
            }
            hostChannels = inputCount_[n];
            hostSlots += inputCount_[n];
        }
        hostInputSlots_.reserve(hostSlots);
        for (std::size_t n = 0; n < nodeCount; ++n) {
            if (inputCount_[n] == 0 || inputTable_[inputBase_[n]] != nullptr) continue;
            const uint32_t portEnd = n + 1 < nodeCount ? nodePortBase_[n + 1] : static_cast<uint32_t>(ports_.size());
            for (uint32_t g = nodePortBase_[n]; g < portEnd; ++g)
                if (ports_[g].input && ports_[g].type == PortType::Audio && ports_[g].table == inputBase_[n])
                    ports_[g].host = true;
            for (uint32_t c = 0; c < inputCount_[n]; ++c) hostInputSlots_.push_back(inputBase_[n] + c);
        }
        // A node's first event input, when unconnected, reads the host events; others read none.
        for (std::size_t n = 0; n < nodeCount; ++n)
            if (blocks_[n].eventInCount && eventInSource_[blocks_[n].eventIn] == kEventNone)
                eventInSource_[blocks_[n].eventIn] = kEventHost;
        // Everything still unbound (host slots until process() binds them, unconnected
        // sidechains and modulation inputs) reads silence.
        for (const float*& entry : inputTable_)
            if (!entry) entry = zero_.data();
        processors_.assign(processors.begin(), processors.end());
        order_ = std::move(compiled.executionOrder);
        preparedBytes_ = executorBytes + retainedPlanBytes;
        runCount_ = static_cast<uint32_t>(order_.size());
        staticConnections_ = static_cast<uint32_t>(connections.size());
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

GraphError GraphExecutor::prepareRouted(const std::vector<GraphNode>& nodes,
                                        const std::vector<ModuleProcessor*>& processors, uint32_t outputNode,
                                        uint32_t maxFrames, double sampleRate, const GraphResourceBudget& budget,
                                        uint32_t maxSourcesPerInput) {
    deferHostCheck_ = true;
    GraphError error = prepare(nodes, {}, processors, outputNode, maxFrames, sampleRate, budget);
    deferHostCheck_ = false;
    if (error == GraphError::Ok) error = reserveRouting(maxSourcesPerInput, budget, true);
    if (error != GraphError::Ok) reset();
    return error;
}

GraphError GraphExecutor::reserveRouting(uint32_t maxSourcesPerInput, const GraphResourceBudget& budget,
                                         bool routePlainInputs) {
    if (!ready_ || staticConnections_ != 0 || linkCount_ != 0) return GraphError::RoutingUnavailable;
    if (maxSourcesPerInput == 0 || budget.maxWorkingBytes == 0) return GraphError::InvalidResourceBudget;
    const std::size_t nodeCount = processors_.size();
    std::size_t summing = 0, channels = 0;
    for (const Port& port : ports_)
        if (port.input && port.summing && port.type == PortType::Audio) { ++summing; channels += port.channels; }
    // Sum buffers, tables and SumInput entries were already counted by prepare() for every summing
    // port; routing adds the source lists (live and staging), per-input counts and node positions.
    std::size_t extra = 0, slots = 0;
    if (!addEstimatedBytes(slots, summing, maxSourcesPerInput) ||
        !addEstimatedBytes(extra, slots, 2u * sizeof(uint32_t)) ||
        !addEstimatedBytes(extra, summing, sizeof(uint32_t)) ||
        !addEstimatedBytes(extra, nodeCount, sizeof(uint32_t)) ||
        (routePlainInputs && !addEstimatedBytes(extra, ports_.size(), sizeof(uint32_t)))) return GraphError::SizeOverflow;
    if (preparedBytes_ > budget.maxWorkingBytes || extra > budget.maxWorkingBytes - preparedBytes_)
        return GraphError::ResourceBudgetExceeded;
    try {
        sumInputs_.clear();
        sumInputs_.reserve(summing);
        sumSources_.assign(slots, 0);
        routeStaging_.assign(slots, 0);
        routeCount_.assign(summing, 0);
        routePosition_.assign(nodeCount, 0);
        if (routePlainInputs) directStaging_.assign(ports_.size(), UINT32_MAX);
        sumStorage_.assign(channels * maxFrames_, 0.0f);
        sumTable_.resize(channels);
        uint32_t tableCursor = 0;
        for (std::size_t n = 0; n < nodeCount; ++n) {
            NodeBlock& b = blocks_[n];
            b.sumBase = static_cast<uint32_t>(sumInputs_.size());
            const uint32_t portEnd = n + 1 < nodeCount ? nodePortBase_[n + 1] : static_cast<uint32_t>(ports_.size());
            for (uint32_t g = nodePortBase_[n]; g < portEnd; ++g) {
                Port& port = ports_[g];
                if (!port.input || !port.summing) continue;
                port.sum = UINT32_MAX;  // summing modulation inputs have no static sources: silence
                if (port.type != PortType::Audio) continue;
                port.sum = static_cast<uint32_t>(sumInputs_.size());
                sumInputs_.push_back(SumInput{port.sum * maxSourcesPerInput, 0, tableCursor, port.channels});
                for (uint32_t c = 0; c < port.channels; ++c, ++tableCursor) {
                    sumTable_[tableCursor] = sumStorage_.data() + static_cast<std::size_t>(tableCursor) * maxFrames_;
                    inputTable_[port.table + c] = sumTable_[tableCursor];
                }
            }
            b.sumCount = static_cast<uint32_t>(sumInputs_.size()) - b.sumBase;
        }
    } catch (...) {
        reset();
        return GraphError::OutOfMemory;
    }
    // Routed inputs never read the host: drop their host slots in place (ports and host slots
    // are both in node order, so the kept slots stay in their original order).
    std::size_t kept = 0;
    for (Port& port : ports_) {
        if (!port.host) continue;
        if (routePlainInputs || port.summing) {
            port.host = false;
            // A plain one may still hold the last host buffer a process() call bound: unbind it.
            if (!port.summing)
                for (uint32_t c = 0; c < port.channels; ++c) inputTable_[port.table + c] = zero_.data();
            continue;
        }
        for (uint32_t c = 0; c < port.channels; ++c) hostInputSlots_[kept++] = port.table + c;
    }
    hostInputSlots_.resize(kept);
    if (kept == 0) hostInputChannels_ = 0;
    routePlain_ = routePlainInputs;
    routingCapacity_ = maxSourcesPerInput;
    return GraphError::Ok;
}

bool GraphExecutor::setRouting(const GraphConnection* edges, uint32_t edgeCount, const uint32_t* order,
                               uint32_t orderCount) noexcept {
    const std::size_t nodeCount = processors_.size();
    if (!ready_ || routingCapacity_ == 0 || !order || orderCount == 0 || orderCount > nodeCount ||
        (edgeCount && !edges)) return false;
    std::fill(routePosition_.begin(), routePosition_.end(), UINT32_MAX);
    for (uint32_t k = 0; k < orderCount; ++k) {
        const uint32_t n = order[k];
        if (n >= nodeCount || routePosition_[n] != UINT32_MAX) return false;
        routePosition_[n] = k;
    }
    if (routePosition_[outputNode_] == UINT32_MAX) return false;
    std::fill(routeCount_.begin(), routeCount_.end(), 0u);
    if (routePlain_) std::fill(directStaging_.begin(), directStaging_.end(), UINT32_MAX);
    for (uint32_t e = 0; e < edgeCount; ++e) {
        const GraphConnection& edge = edges[e];
        if (edge.sourceNode >= nodeCount || edge.destinationNode >= nodeCount) return false;
        if (edge.sourcePort >= processors_[edge.sourceNode]->descriptor().portCount ||
            edge.destinationPort >= processors_[edge.destinationNode]->descriptor().portCount) return false;
        const uint32_t source = nodePortBase_[edge.sourceNode] + edge.sourcePort;
        const uint32_t destination = nodePortBase_[edge.destinationNode] + edge.destinationPort;
        const Port& from = ports_[source];
        const Port& to = ports_[destination];
        if (from.input || from.type != PortType::Audio || !to.input || to.type != PortType::Audio ||
            from.channels != to.channels) return false;
        if (to.summing ? to.sum == UINT32_MAX : !routePlain_) return false;
        // Both ends must run, the source first (an unlisted node's position is UINT32_MAX).
        if (routePosition_[edge.destinationNode] == UINT32_MAX ||
            routePosition_[edge.sourceNode] >= routePosition_[edge.destinationNode]) return false;
        if (!to.summing) {
            uint32_t& direct = directStaging_[destination];
            if (direct != UINT32_MAX) return false;  // a plain input takes one route
            direct = source;
            continue;
        }
        uint32_t& count = routeCount_[to.sum];
        if (count >= routingCapacity_) return false;
        const uint32_t base = sumInputs_[to.sum].sourceBase;
        for (uint32_t s = 0; s < count; ++s)
            if (routeStaging_[base + s] == source) return false;  // duplicate route
        routeStaging_[base + count++] = source;
    }
    // Valid: commit in one step. Swapping vectors never allocates.
    sumSources_.swap(routeStaging_);
    for (std::size_t k = 0; k < sumInputs_.size(); ++k) sumInputs_[k].sourceCount = routeCount_[k];
    if (routePlain_)
        for (std::size_t g = 0; g < ports_.size(); ++g) {
            const Port& port = ports_[g];
            if (!port.input || port.summing || port.type != PortType::Audio) continue;
            const uint32_t source = directStaging_[g];
            for (uint32_t c = 0; c < port.channels; ++c)
                inputTable_[port.table + c] =
                    source == UINT32_MAX ? zero_.data() : outputTable_[ports_[source].table + c];
        }
    std::copy_n(order, orderCount, order_.begin());
    runCount_ = orderCount;
    return true;
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
    if (hostInputChannels_ == 0) return processValidated(ConstChannelBufferView{}, output, frames, EventInput{});
    if (input.channelCount != 0 &&
        (input.channelCount != hostInputChannels_ || !input.valid() || input.frames < frames)) return false;
    return processValidated(input, output, frames, EventInput{});
}

namespace {
// The EventInput/EventOutput order rule: frames non-decreasing, each below `frames`.
bool eventsOrdered(const Event* events, uint32_t count, uint32_t frames) noexcept {
    uint32_t previous = 0;
    for (uint32_t e = 0; e < count; ++e) {
        if (events[e].frame >= frames || events[e].frame < previous) return false;
        previous = events[e].frame;
    }
    return true;
}
}  // namespace

bool GraphExecutor::process(const ConstChannelBufferView& input, const ChannelBufferView& output,
                            uint32_t frames, const EventInput& events) noexcept {
    if (!ready_ || frames == 0 || frames > maxFrames_) return false;
    // Bounded like every event list, checked before any event is read.
    if (events.count != 0 && (events.count > eventCapacity_ || !events.events ||
                              !eventsOrdered(events.events, events.count, frames))) return false;
    if (output.channelCount != outputChannels_ || !output.valid() || output.frames < frames) return false;
    if (hostInputChannels_ == 0) return processValidated(ConstChannelBufferView{}, output, frames, events);
    if (input.channelCount != 0 &&
        (input.channelCount != hostInputChannels_ || !input.valid() || input.frames < frames)) return false;
    return processValidated(input, output, frames, events);
}

void GraphExecutor::mergeEvents(const EventMerge& merge) noexcept {
    // Stable k-way merge of sorted sources: the earliest frame first, ties in connection order.
    // Cost O(events kept x sources), as each kept event rescans the sources; at most
    // maxEventsPerPort x fan-in per merge. Once the buffer is full the rest are counted, not copied.
    Event* out = eventStorage_.data() + merge.storage;
    const uint32_t* sources = eventMergeSources_.data() + merge.sourceBase;
    uint32_t* cursor = mergeCursor_.data() + merge.sourceBase;
    std::fill_n(cursor, merge.sourceCount, 0u);
    uint32_t count = 0;
    for (;;) {
        uint32_t best = UINT32_MAX, bestFrame = 0;
        for (uint32_t s = 0; s < merge.sourceCount; ++s) {
            const EventOutput& source = eventOutTable_[sources[s]];
            if (cursor[s] < source.count && (best == UINT32_MAX || source.events[cursor[s]].frame < bestFrame)) {
                best = s;
                bestFrame = source.events[cursor[s]].frame;
            }
        }
        if (best == UINT32_MAX) break;
        if (count == eventCapacity_) {
            uint64_t dropped = 0;
            for (uint32_t s = 0; s < merge.sourceCount; ++s) dropped += eventOutTable_[sources[s]].count - cursor[s];
            eventsDropped_.fetch_add(dropped, std::memory_order_relaxed);
            break;
        }
        out[count++] = eventOutTable_[sources[best]].events[cursor[best]++];
    }
    eventInTable_[merge.input] = EventInput{out, count};
}

bool GraphExecutor::processValidated(const ConstChannelBufferView& input, const ChannelBufferView& output,
                                     uint32_t frames, const EventInput& events) noexcept {
    applyParameterCommands();
    hostEvents_ = events;
    // Positions stay where doubles are exact (and int64 cannot overflow); a song that would run
    // past that stops its lanes instead.
    if (transportSample_ > kMaxTransportSample - static_cast<int64_t>(frames)) playing_ = false;
    blockStart_ = transportSample_;
    if (playing_) transportSample_ += frames;
    // Bind this call's host channels (or silence) into the prepared input table.
    const std::size_t slots = hostInputSlots_.size();
    for (std::size_t s = 0; s < slots; ++s)
        inputTable_[hostInputSlots_[s]] =
            input.channelCount ? input.channels[s % hostInputChannels_] : zero_.data();

    for (uint32_t k = 0; k < runCount_; ++k) {
        const uint32_t node = order_[k];
        const NodeBlock& b = blocks_[node];
        for (uint32_t si = b.sumBase; si < b.sumBase + b.sumCount; ++si) {
            const SumInput& sum = sumInputs_[si];
            for (uint32_t c = 0; c < sum.channels; ++c) {
                float* destination = sumTable_[sum.tableBase + c];
                std::fill_n(destination, frames, 0.0f);
                for (uint32_t s = 0; s < sum.sourceCount; ++s) {
                    const float* source = outputTable_[ports_[sumSources_[sum.sourceBase + s]].table + c];
                    for (uint32_t i = 0; i < frames; ++i) destination[i] = routeAdd(destination[i], routeSample(source[i]));
                }
            }
        }
        bool ok;
        if (b.paramCount) resolveParameters(b, frames);
        const ParameterValue* parameters = b.paramCount ? parameterValues_.data() + b.paramBase : nullptr;
        if (!b.typed) {
            const AudioProcessBlock block{
                {inputTable_.data() + inputBase_[node], inputCount_[node], frames},
                {outputTable_.data() + outputBase_[node], outputCount_[node], frames},
                frames, sampleRate_, parameters, b.paramCount};
            ok = processors_[node]->process(block);
        } else {
            // Views carry this block's capacity: host input buffers may be shorter than maxFrames.
            for (uint32_t v = 0; v < b.audioInCount; ++v) audioInViews_[b.audioIn + v].frames = frames;
            for (uint32_t v = 0; v < b.audioOutCount; ++v) audioOutViews_[b.audioOut + v].frames = frames;
            // Event inputs read this block's source lists (sources ran earlier and were checked).
            for (uint32_t v = b.eventIn; v < b.eventIn + b.eventInCount; ++v) {
                const uint32_t source = eventInSource_[v];
                if (source == kEventHost) eventInTable_[v] = events;
                else if (source < eventOutTable_.size())
                    eventInTable_[v] = EventInput{eventOutTable_[source].events, eventOutTable_[source].count};
            }
            for (uint32_t m = b.mergeBase; m < b.mergeBase + b.mergeCount; ++m) mergeEvents(eventMerges_[m]);
            for (uint32_t v = b.eventOut; v < b.eventOut + b.eventOutCount; ++v) eventOutTable_[v].count = 0;
            const ProcessBlock block{frames, sampleRate_,
                audioInViews_.data() + b.audioIn, b.audioInCount, audioOutViews_.data() + b.audioOut, b.audioOutCount,
                inputTable_.data() + b.modIn, b.modInCount, outputTable_.data() + b.modOut, b.modOutCount,
                controlInTable_.data() + b.controlIn, b.controlInCount,
                controlOutTable_.data() + b.controlOut, b.controlOutCount,
                eventInTable_.data() + b.eventIn, b.eventInCount, eventOutTable_.data() + b.eventOut, b.eventOutCount,
                parameters, b.paramCount};
            ok = processors_[node]->processPorts(block);
            // A processor's events must be in order and in range, or later nodes would misread them.
            for (uint32_t v = b.eventOut; v < b.eventOut + b.eventOutCount; ++v) {
                EventOutput& out = eventOutTable_[v];
                if (out.count > eventCapacity_ || out.events != eventStorage_.data() + static_cast<std::size_t>(v) * eventCapacity_ ||
                    out.capacity != eventCapacity_ || !eventsOrdered(out.events, out.count, frames)) {
                    out = EventOutput{eventStorage_.data() + static_cast<std::size_t>(v) * eventCapacity_, eventCapacity_, 0};
                    ok = false;
                }
            }
            // Control values are held across blocks, so a NaN or inf must not latch: same rule as routing.
            for (uint32_t v = 0; v < b.controlOutCount; ++v) {
                float& value = *controlOutTable_[b.controlOut + v];
                value = routeSample(value);
            }
        }
        if (!ok) { fail(node, output, frames); return false; }
    }
    float* const* result = outputTable_.data() + outputBase_[outputNode_];
    for (uint32_t c = 0; c < outputChannels_; ++c) std::copy_n(result[c], frames, output.channels[c]);
    return true;
}

bool GraphExecutor::queueParameter(uint32_t node, uint32_t parameter, double value) noexcept {
    if (!ready_ || node >= blocks_.size() || parameter >= blocks_[node].paramCount || !std::isfinite(value))
        return false;
    return parameterQueue_.push(ParameterCommand{node, parameter, value, false});
}

bool GraphExecutor::queueClearTouch() noexcept {
    return ready_ && parameterQueue_.push(ParameterCommand{0, 0, 0.0, true});
}

GraphError GraphExecutor::setModulationLinks(const ParameterLink* links, uint32_t count) try {
    if (!ready_) return GraphError::InvalidOutputNode;
    if (routingCapacity_ != 0) return GraphError::RoutingUnavailable;
    if (count && !links) return GraphError::InvalidParameterLink;
    // Validate everything first (no allocation: counts per parameter fit in the fixed table).
    std::vector<uint32_t> position(blocks_.size(), UINT32_MAX);
    for (uint32_t k = 0; k < order_.size(); ++k) position[order_[k]] = k;
    std::vector<uint32_t> perParameter(resolvers_.size(), 0);
    for (uint32_t k = 0; k < count; ++k) {
        const ParameterLink& link = links[k];
        if (link.sourceNode >= blocks_.size() || link.destinationNode >= blocks_.size()) return GraphError::NodeIndexOutOfRange;
        if (link.sourcePort >= processors_[link.sourceNode]->descriptor().portCount ||
            link.parameter >= blocks_[link.destinationNode].paramCount) return GraphError::PortIndexOutOfRange;
        const Port& from = ports_[nodePortBase_[link.sourceNode] + link.sourcePort];
        if (from.input || from.type != PortType::Modulation) return GraphError::PortTypeMismatch;
        if (position[link.sourceNode] >= position[link.destinationNode]) return GraphError::Cycle;
        if (++perParameter[blocks_[link.destinationNode].paramBase + link.parameter] > kMaxParameterLinks)
            return GraphError::InvalidParameterLink;
    }
    // Per parameter: its links sorted by id, checked by the resolver's rules (ids, ops, depths).
    std::vector<std::pair<uint32_t, uint32_t>> byParameter;  // (parameter, link index)
    byParameter.reserve(count);
    for (uint32_t k = 0; k < count; ++k)
        byParameter.emplace_back(blocks_[links[k].destinationNode].paramBase + links[k].parameter, k);
    std::sort(byParameter.begin(), byParameter.end(), [&](const auto& a, const auto& b) {
        return a.first != b.first ? a.first < b.first : links[a.second].id < links[b.second].id;
    });
    ParameterResolver probe;  // dry run, so an invalid list changes nothing
    for (std::size_t s = 0; s < byParameter.size();) {
        const uint32_t p = byParameter[s].first;
        ModulationLink group[kMaxParameterLinks];
        uint32_t n = 0;
        for (; s < byParameter.size() && byParameter[s].first == p; ++s) {
            const ParameterLink& link = links[byParameter[s].second];
            group[n++] = ModulationLink{link.id, link.op, link.depth};
        }
        if (!probe.setLinks(group, n)) return GraphError::InvalidParameterLink;
    }
    // Commit: every parameter's links (none for those not listed) and their signal pointers.
    std::fill(linkSignals_.begin(), linkSignals_.end(), nullptr);
    for (std::size_t p = 0; p < resolvers_.size(); ++p) resolvers_[p].setLinks(nullptr, 0);
    for (std::size_t s = 0; s < byParameter.size();) {
        const uint32_t p = byParameter[s].first;
        ModulationLink group[kMaxParameterLinks];
        uint32_t n = 0;
        for (; s < byParameter.size() && byParameter[s].first == p; ++s, ++n) {
            const ParameterLink& link = links[byParameter[s].second];
            group[n] = ModulationLink{link.id, link.op, link.depth};
            linkSignals_[static_cast<std::size_t>(p) * kMaxParameterLinks + n] =
                outputTable_[ports_[nodePortBase_[link.sourceNode] + link.sourcePort].table];
        }
        resolvers_[p].setLinks(group, n);
    }
    linkCount_ = count;
    return GraphError::Ok;
} catch (...) {
    return GraphError::OutOfMemory;  // control-thread scratch (O(nodes + parameters + links)); nothing changed
}

namespace {
// The mapping key of a host event, or false when it is not a Control Change.
bool ccOf(const Event& event, uint32_t& key, double& value) noexcept {
    UmpControlChange cc;
    if (event.kind != EventKind::Midi || !decodeControlChange(event.data, cc)) return false;
    key = static_cast<uint32_t>(cc.group) << 11 | static_cast<uint32_t>(cc.channel) << 7 | cc.controller;
    value = cc.value;
    return true;
}
}  // namespace

ParameterValue GraphExecutor::resolveWithCc(uint32_t p, uint32_t frames, const double* automation,
                                            const float* const* signals, double* out) noexcept {
    // Resolve in segments split at each matching CC, so it takes effect at its own frame. Without
    // a match this is the plain resolve (and keeps its constant fast path).
    ParameterResolver& resolver = resolvers_[p];
    const uint32_t key = ccKey_[p];
    uint32_t start = 0;
    bool matched = false;
    const float* shifted[kMaxParameterLinks];
    auto segment = [&](uint32_t end) noexcept {
        if (end <= start) return;
        for (uint32_t k = 0; k < kMaxParameterLinks; ++k) shifted[k] = signals[k] ? signals[k] + start : nullptr;
        const ParameterValue v = resolver.resolve(end - start, automation ? automation + start : nullptr, shifted, out + start);
        if (!v.samples) std::fill(out + start, out + end, v.value);
        start = end;
    };
    for (uint32_t e = 0; e < hostEvents_.count; ++e) {
        uint32_t eventKey = 0;
        double value = 0.0;
        if (!ccOf(hostEvents_.events[e], eventKey, value) || eventKey != key) continue;
        matched = true;
        segment(hostEvents_.events[e].frame);
        resolver.setBase(denormalizeParameter(resolver.descriptor(), value));
    }
    if (!matched) return resolver.resolve(frames, automation, signals, out);
    segment(frames);
    return ParameterValue{out, out[0]};
}

GraphError GraphExecutor::setCcMappings(const ParameterCcMapping* mappings, uint32_t count) try {
    if (!ready_) return GraphError::InvalidOutputNode;
    if (count && !mappings) return GraphError::InvalidCcMapping;
    std::vector<uint32_t> keys(resolvers_.size(), kNoCc);
    for (uint32_t k = 0; k < count; ++k) {
        const ParameterCcMapping& m = mappings[k];
        if (m.node >= blocks_.size()) return GraphError::NodeIndexOutOfRange;
        if (m.parameter >= blocks_[m.node].paramCount) return GraphError::PortIndexOutOfRange;
        if (m.group >= 16 || m.channel >= 16 || m.controller >= 128) return GraphError::InvalidCcMapping;
        uint32_t& key = keys[blocks_[m.node].paramBase + m.parameter];
        if (key != kNoCc) return GraphError::InvalidCcMapping;
        key = static_cast<uint32_t>(m.group) << 11 | static_cast<uint32_t>(m.channel) << 7 | m.controller;
    }
    std::copy(keys.begin(), keys.end(), ccKey_.begin());
    return GraphError::Ok;
} catch (...) {
    return GraphError::OutOfMemory;
}

GraphError GraphExecutor::setAutomationLanes(const ParameterLane* lanes, uint32_t count) try {
    if (!ready_) return GraphError::InvalidOutputNode;
    if (count && !lanes) return GraphError::InvalidAutomationLane;
    std::vector<uint8_t> seen(resolvers_.size(), 0);
    for (uint32_t k = 0; k < count; ++k) {
        const ParameterLane& lane = lanes[k];
        if (lane.node >= blocks_.size()) return GraphError::NodeIndexOutOfRange;
        if (lane.parameter >= blocks_[lane.node].paramCount) return GraphError::PortIndexOutOfRange;
        if (!lane.points || lane.pointCount == 0) return GraphError::InvalidAutomationLane;
        for (uint32_t i = 0; i < lane.pointCount; ++i) {
            const AutomationPoint& point = lane.points[i];
            if (!std::isfinite(point.step) || !std::isfinite(point.value) || (i && point.step < lane.points[i - 1].step))
                return GraphError::InvalidAutomationLane;
        }
        uint8_t& once = seen[blocks_[lane.node].paramBase + lane.parameter];
        if (once) return GraphError::InvalidAutomationLane;
        once = 1;
    }
    std::fill(lanePoints_.begin(), lanePoints_.end(), nullptr);
    std::fill(laneCount_.begin(), laneCount_.end(), 0u);
    for (uint32_t k = 0; k < count; ++k) {
        const uint32_t p = blocks_[lanes[k].node].paramBase + lanes[k].parameter;
        lanePoints_[p] = lanes[k].points;
        laneCount_[p] = lanes[k].pointCount;
    }
    return GraphError::Ok;
} catch (...) {
    return GraphError::OutOfMemory;  // control-thread scratch; nothing changed
}

bool GraphExecutor::setTransport(int64_t sample, double samplesPerStep, bool playing) noexcept {
    if (sample <= -kMaxTransportSample || sample >= kMaxTransportSample || !std::isfinite(samplesPerStep) ||
        !(samplesPerStep > 0.0)) {
        playing_ = false;
        return false;
    }
    transportSample_ = sample;
    samplesPerStep_ = samplesPerStep;
    playing_ = playing;
    return true;
}

bool GraphExecutor::setInitialParameter(uint32_t node, uint32_t parameter, double value) noexcept {
    if (!ready_ || node >= blocks_.size() || parameter >= blocks_[node].paramCount || !std::isfinite(value))
        return false;
    resolvers_[blocks_[node].paramBase + parameter].setInitial(value);
    return true;
}

bool GraphExecutor::parameterTouched(uint32_t node, uint32_t parameter) const noexcept {
    if (node >= blocks_.size() || parameter >= blocks_[node].paramCount) return false;
    const uint32_t p = blocks_[node].paramBase + parameter;
    return touchEpoch_[p] == clearEpoch_ && resolvers_[p].touched();
}

void GraphExecutor::syncTouch(uint32_t p) noexcept {
    if (touchEpoch_[p] == clearEpoch_) return;
    resolvers_[p].clearTouch();
    touchEpoch_[p] = clearEpoch_;
}

double GraphExecutor::parameterTarget(uint32_t node, uint32_t parameter) const noexcept {
    if (node >= blocks_.size() || parameter >= blocks_[node].paramCount) return 0.0;
    return resolvers_[blocks_[node].paramBase + parameter].target();
}

void GraphExecutor::applyParameterCommands() noexcept {
    // Bounded by the queue capacity; indices were checked when queued, for this prepared graph.
    for (ParameterCommand command; parameterQueue_.pop(command);) {
        if (command.clearTouch) {
            ++clearEpoch_;  // O(1); resolvers catch up lazily (syncTouch)
            continue;
        }
        if (command.node < blocks_.size() && command.parameter < blocks_[command.node].paramCount) {
            const uint32_t p = blocks_[command.node].paramBase + command.parameter;
            syncTouch(p);  // a clear queued before this set must not undo it
            resolvers_[p].setBase(command.value);
        }
    }
}

void GraphExecutor::resolveParameters(const NodeBlock& b, uint32_t frames) noexcept {
    // Modulation signals are this block's source outputs (sources ran earlier). The lane scratch is
    // shared: the resolver reads it only inside resolve().
    for (uint32_t k = 0; k < b.paramCount; ++k) {
        const uint32_t p = b.paramBase + k;
        syncTouch(p);
        const double* automation = nullptr;
        if (playing_ && laneCount_[p]) {
            // The Engine's expression, so values match it bit for bit (F6.6).
            for (uint32_t i = 0; i < frames; ++i)
                automationScratch_[i] = automationLaneValue(lanePoints_[p], laneCount_[p],
                    static_cast<double>(blockStart_ + i) / samplesPerStep_, lanePoints_[p][0].value);
            automation = automationScratch_.data();
        }
        const float* const* signals = linkSignals_.data() + static_cast<std::size_t>(p) * kMaxParameterLinks;
        double* out = parameterStorage_.data() + static_cast<std::size_t>(p) * maxFrames_;
        parameterValues_[p] = ccKey_[p] != kNoCc && hostEvents_.count
            ? resolveWithCc(p, frames, automation, signals, out)
            : resolvers_[p].resolve(frames, automation, signals, out);
    }
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
    // The wrapper has checked everything the generic entry point would.
    return processValidated(in, ChannelBufferView{outputs, 2, frames}, frames, EventInput{});
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
