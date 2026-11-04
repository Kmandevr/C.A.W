// Tests for typed DSP graph wiring, deterministic order and cycle rejection.
#include "test.h"

#include "graph.h"

#include <string>
#include <limits>

using namespace caw;

namespace {
constexpr GraphResourceBudget kTestBudget{
    std::numeric_limits<std::size_t>::max(),
    std::numeric_limits<std::size_t>::max(),
    64u * 1024u * 1024u,
};
}

namespace {
const PortDescriptor sourcePorts[] = {
    {"out", PortType::Audio, ChannelLayout::Stereo, false},
};
const PortDescriptor effectPorts[] = {
    {"in", PortType::Audio, ChannelLayout::Stereo, true},
    {"out", PortType::Audio, ChannelLayout::Stereo, false},
};
const PortDescriptor sinkPorts[] = {
    {"in", PortType::Audio, ChannelLayout::Stereo, true},
};
const ModuleDescriptor source{"test.source", 1, sourcePorts, 1, nullptr, 0};
const ModuleDescriptor effect{"test.effect", 1, effectPorts, 2, nullptr, 0};
const ModuleDescriptor sink{"test.sink", 1, sinkPorts, 1, nullptr, 0};
const PortDescriptor monoRuntimePorts[] = {
    {"in", PortType::Audio, ChannelLayout::Mono, true},
    {"out", PortType::Audio, ChannelLayout::Mono, false},
};
const ModuleDescriptor monoRuntime{"test.mono.runtime", 1, monoRuntimePorts, 2, nullptr, 0};
}

TEST(graph_compiles_stereo_chain_in_dependency_order) {
    const std::vector<GraphNode> nodes{{"sink", &sink}, {"effect", &effect}, {"source", &source}};
    const std::vector<GraphConnection> edges{{2, 0, 1, 0}, {1, 1, 0, 0}};
    const CompiledGraph graph = compileGraph(nodes, edges, kTestBudget);
    CHECK(graph);
    CHECK_EQ(graph.executionOrder.size(), 3u);
    CHECK_EQ(graph.executionOrder[0], 2u);
    CHECK_EQ(graph.executionOrder[1], 1u);
    CHECK_EQ(graph.executionOrder[2], 0u);
}

TEST(graph_compiler_requires_explicit_working_memory_budget) {
    const std::vector<GraphNode> nodes{{"source", &source}};
    CHECK(compileGraph(nodes, {}, GraphResourceBudget{}).error == GraphError::InvalidResourceBudget);
}

TEST(graph_compiler_enforces_optional_count_budgets) {
    const std::vector<GraphNode> nodes{{"source", &source}, {"sink", &sink}};
    const GraphResourceBudget nodeBudget{1, std::numeric_limits<std::size_t>::max(), 1024u * 1024u};
    CHECK(compileGraph(nodes, {}, nodeBudget).error == GraphError::ResourceBudgetExceeded);
    const GraphResourceBudget connectionBudget{2, 0, 1024u * 1024u};
    CHECK(compileGraph(nodes, {{0, 0, 1, 0}}, connectionBudget).error == GraphError::ResourceBudgetExceeded);
    const GraphResourceBudget tinyMemoryBudget{
        std::numeric_limits<std::size_t>::max(),
        std::numeric_limits<std::size_t>::max(),
        1,
    };
    CHECK(compileGraph(nodes, {}, tinyMemoryBudget).error == GraphError::ResourceBudgetExceeded);
}

TEST(graph_compiler_has_no_arbitrary_node_or_connection_cap) {
    constexpr uint32_t nodeCount = 8195;
    std::vector<std::string> ids;
    std::vector<GraphNode> nodes;
    std::vector<GraphConnection> edges;
    ids.reserve(nodeCount);
    nodes.reserve(nodeCount);
    edges.reserve(nodeCount - 1);
    for (uint32_t i = 0; i < nodeCount; ++i) ids.push_back("node-" + std::to_string(i));
    for (uint32_t i = 0; i < nodeCount; ++i) nodes.push_back({ids[i], &effect});
    for (uint32_t i = 0; i + 1 < nodeCount; ++i) edges.push_back({i, 1, i + 1, 0});

    const CompiledGraph graph = compileGraph(nodes, edges, kTestBudget);
    CHECK(graph);
    CHECK_EQ(graph.executionOrder.size(), static_cast<std::size_t>(nodeCount));
    CHECK_EQ(graph.executionOrder.front(), 0u);
    CHECK_EQ(graph.executionOrder.back(), nodeCount - 1);
}

TEST(graph_rejects_mono_stereo_mismatch) {
    const PortDescriptor monoOut[] = {{"out", PortType::Audio, ChannelLayout::Mono, false}};
    const ModuleDescriptor mono{"test.mono", 1, monoOut, 1, nullptr, 0};
    const std::vector<GraphNode> nodes{{"mono", &mono}, {"stereo", &sink}};
    const CompiledGraph graph = compileGraph(nodes, {{0, 0, 1, 0}}, kTestBudget);
    CHECK(graph.error == GraphError::ChannelLayoutMismatch);
    CHECK_EQ(graph.errorConnection, 0u);
}

TEST(graph_rejects_control_audio_connection) {
    const PortDescriptor controlOut[] = {{"out", PortType::Control, ChannelLayout::None, false}};
    const ModuleDescriptor control{"test.control", 1, controlOut, 1, nullptr, 0};
    const std::vector<GraphNode> nodes{{"control", &control}, {"audio", &sink}};
    CHECK(compileGraph(nodes, {{0, 0, 1, 0}}, kTestBudget).error == GraphError::PortTypeMismatch);
}

TEST(graph_rejects_duplicate_drivers) {
    const std::vector<GraphNode> nodes{{"a", &source}, {"b", &source}, {"sink", &sink}};
    CHECK(compileGraph(nodes, {{0, 0, 2, 0}, {1, 0, 2, 0}}, kTestBudget).error == GraphError::InputAlreadyConnected);
}

TEST(graph_rejects_cycles) {
    const std::vector<GraphNode> nodes{{"a", &effect}, {"b", &effect}};
    CHECK(compileGraph(nodes, {{0, 1, 1, 0}, {1, 1, 0, 0}}, kTestBudget).error == GraphError::Cycle);
}

TEST(graph_rejects_duplicate_node_ids) {
    const std::vector<GraphNode> nodes{{"same", &source}, {"same", &sink}};
    CHECK(compileGraph(nodes, {}, kTestBudget).error == GraphError::DuplicateNodeId);
}

namespace {
class PassThrough final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return effect; }
    void process(const StereoProcessBlock& block) noexcept override {
        for (uint32_t i = 0; i < block.frames; ++i) {
            block.outputLeft[i] = block.inputLeft ? block.inputLeft[i] : 0.0f;
            block.outputRight[i] = block.inputRight ? block.inputRight[i] : 0.0f;
        }
    }
};
class GainProcessor final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return effect; }
    void process(const StereoProcessBlock& block) noexcept override {
        for (uint32_t i = 0; i < block.frames; ++i) {
            block.outputLeft[i] = (block.inputLeft ? block.inputLeft[i] : 0.0f) * 0.25f;
            block.outputRight[i] = (block.inputRight ? block.inputRight[i] : 0.0f) * 0.25f;
        }
    }
};
class TrackedPassThrough final : public ModuleProcessor {
public:
    explicit TrackedPassThrough(bool& destroyed) : destroyed_(destroyed) {}
    ~TrackedPassThrough() override { destroyed_ = true; }
    const ModuleDescriptor& descriptor() const noexcept override { return effect; }
    void process(const StereoProcessBlock& block) noexcept override {
        for (uint32_t i = 0; i < block.frames; ++i) {
            block.outputLeft[i] = block.inputLeft ? block.inputLeft[i] : 0.0f;
            block.outputRight[i] = block.inputRight ? block.inputRight[i] : 0.0f;
        }
    }
private:
    bool& destroyed_;
};
}

TEST(graph_executor_processes_prepared_stereo_chain_without_changing_block_size) {
    const std::vector<GraphNode> nodes{{"input", &effect}, {"gain", &effect}};
    const std::vector<GraphConnection> edges{{0, 1, 1, 0}};
    PassThrough pass;
    GainProcessor gain;
    const std::vector<ModuleProcessor*> processors{&pass, &gain};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, edges, processors, 1, 64, 48000, kTestBudget) == GraphError::Ok);
    CHECK(executor.ready());
    const float inL[] = {1, 2, 3, 4};
    const float inR[] = {-1, -2, -3, -4};
    float outL[4] = {}, outR[4] = {};
    CHECK(executor.process(inL, inR, outL, outR, 4));
    for (int i = 0; i < 4; ++i) {
        CHECK_NEAR(outL[i], inL[i] * 0.25, 1e-7);
        CHECK_NEAR(outR[i], inR[i] * 0.25, 1e-7);
    }
    CHECK(!executor.process(inL, inR, outL, outR, 65));
}

TEST(graph_executor_rejects_prepared_buffers_over_working_memory_budget) {
    const std::vector<GraphNode> nodes{{"processor", &effect}};
    PassThrough pass;
    const std::vector<ModuleProcessor*> processors{&pass};
    const GraphResourceBudget tinyBudget{1, 0, 1024};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, {}, processors, 0, 8193, 48000.0, tinyBudget) ==
          GraphError::ResourceBudgetExceeded);
    CHECK(!executor.ready());
}

TEST(graph_executor_enforces_combined_compile_and_runtime_peak_budget) {
    const std::vector<GraphNode> nodes{{"input", &effect}, {"gain", &effect}};
    const std::vector<GraphConnection> edges{{0, 1, 1, 0}};
    PassThrough pass;
    GainProcessor gain;
    const std::vector<ModuleProcessor*> processors{&pass, &gain};
    // Planar executor storage for two stereo in/out nodes at 64 frames: fixed vector headers,
    // per-node metadata, four ports with one prepared audio view each, four output channels,
    // both pointer tables, the host-input slot bound (every input channel) and the shared zero
    // block. Mirrors of the executor's private Port and NodeBlock layouts give their sizes; the
    // private lists' headers are counted like any std::vector header.
    struct PortBytes { PortType type; bool input, summing, host; uint32_t channels, table, sum; };
    struct NodeBlockBytes { uint32_t fields[22]; bool typed; };
    // The event storage, tables, sources, merges, merge sources and cursors, and the parameter
    // resolvers, values and storage have headers too (vector headers do not depend on the
    // element type). These modules have no parameters, so they add nothing else.
    constexpr std::size_t fixedHeaders =
        sizeof(std::vector<ModuleProcessor*>) + sizeof(std::vector<float>) * 4u +
        sizeof(std::vector<float*>) * 3u + sizeof(std::vector<const float*>) * 2u +
        sizeof(std::vector<uint32_t>) * 12u + sizeof(std::vector<ChannelBufferView>) * 2u +
        sizeof(std::vector<Event>) * 4u + sizeof(std::vector<uint32_t>) * 3u + sizeof(std::vector<double>) * 3u;
    constexpr std::size_t perNodeMetadata = sizeof(ModuleProcessor*) + sizeof(uint32_t) * 5u + sizeof(NodeBlockBytes);
    constexpr std::size_t portBytes =
        4u * sizeof(PortBytes) + 2u * sizeof(ConstChannelBufferView) + 2u * sizeof(ChannelBufferView);
    constexpr std::size_t executorBytes =
        fixedHeaders + 2u * perNodeMetadata + portBytes + 4u * 64u * sizeof(float) +
        4u * sizeof(float*) + 4u * sizeof(const float*) + 4u * sizeof(uint32_t) + 64u * sizeof(float) +
        1u * sizeof(uint32_t);  // sum-source bound: one per connection
    constexpr std::size_t retainedPlanBytes = 2u * sizeof(uint32_t);
    // Each phase fits independently, but the live execution order plus prepared
    // executor storage exceeds the budget by one byte; the exact total fits.
    const GraphResourceBudget budget{2, 1, executorBytes + retainedPlanBytes - 1u};
    const GraphResourceBudget exact{2, 1, executorBytes + retainedPlanBytes};
    {
        GraphExecutor fits;
        CHECK(fits.prepare(nodes, edges, processors, 1, 64, 48000, exact) == GraphError::Ok);
    }
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, edges, processors, 1, 64, 48000, budget) ==
          GraphError::ResourceBudgetExceeded);
    CHECK(!executor.ready());
}

TEST(graph_executor_accepts_block_sizes_above_legacy_fixed_cap) {
    const std::vector<GraphNode> nodes{{"processor", &effect}};
    PassThrough pass;
    const std::vector<ModuleProcessor*> processors{&pass};
    constexpr uint32_t frames = 8193;
    std::vector<float> input(frames, 0.375f);
    std::vector<float> outputLeft(frames, 0.0f), outputRight(frames, 0.0f);
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, {}, processors, 0, frames, 48000.0, kTestBudget) == GraphError::Ok);
    CHECK(executor.process(input.data(), input.data(), outputLeft.data(), outputRight.data(), frames));
    CHECK_NEAR(outputLeft.front(), 0.375, 1e-7);
    CHECK_NEAR(outputRight.back(), 0.375, 1e-7);
}

TEST(graph_executor_runs_mono_layout_and_fails_stereo_only_mono_processor) {
    // Mono now runs through the planar path. A processor that only implements the legacy
    // stereo overload cannot serve a mono port, and says so instead of outputting nothing.
    class MonoProcessor final : public ModuleProcessor {
    public:
        const ModuleDescriptor& descriptor() const noexcept override { return monoRuntime; }
        bool process(const AudioProcessBlock& block) noexcept override {
            if (block.input.channelCount != 1 || block.output.channelCount != 1) return false;
            for (uint32_t i = 0; i < block.frames; ++i) block.output.channels[0][i] = block.input.channels[0][i] * 2.0f;
            return true;
        }
    } mono;
    class StereoOnly final : public ModuleProcessor {
    public:
        const ModuleDescriptor& descriptor() const noexcept override { return monoRuntime; }
        void process(const StereoProcessBlock&) noexcept override {}
    } stereoOnly;
    const std::vector<GraphNode> nodes{{"mono", &monoRuntime}};
    const float in[] = {0.25f, -0.5f};
    const float* inputs[] = {in};
    float out[2] = {};
    float* outputs[] = {out};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, {}, {&mono}, 0, 64, 48000, kTestBudget) == GraphError::Ok);
    CHECK_EQ(executor.inputChannels(), 1u);
    CHECK_EQ(executor.outputChannels(), 1u);
    CHECK(executor.process(ConstChannelBufferView{inputs, 1, 2}, ChannelBufferView{outputs, 1, 2}, 2));
    CHECK_EQ(out[0], 0.5f);
    CHECK_EQ(out[1], -1.0f);
    CHECK(executor.prepare(nodes, {}, {&stereoOnly}, 0, 64, 48000, kTestBudget) == GraphError::Ok);
    CHECK(!executor.process(ConstChannelBufferView{inputs, 1, 2}, ChannelBufferView{outputs, 1, 2}, 2));
    CHECK_EQ(executor.lastFailedNode(), 0u);
}

TEST(graph_runtime_publishes_owned_processors_and_retires_them_off_thread) {
    const std::vector<GraphNode> nodes{{"input", &effect}, {"gain", &effect}};
    const std::vector<GraphConnection> edges{{0, 1, 1, 0}};
    bool firstDestroyed = false, secondDestroyed = false;
    auto prepare = [&](bool& destroyed) {
        auto graph = std::make_unique<PreparedGraph>();
        std::vector<std::unique_ptr<ModuleProcessor>> processors;
        processors.push_back(std::make_unique<TrackedPassThrough>(destroyed));
        processors.push_back(std::make_unique<GainProcessor>());
        CHECK(graph->prepare(nodes, edges, std::move(processors), 1, 64, 48000, kTestBudget) ==
              GraphError::Ok);
        return graph;
    };

    GraphRuntime runtime;
    auto first = prepare(firstDestroyed);
    PreparedGraph* firstRaw = first.release();
    CHECK(runtime.publish(firstRaw));
    CHECK(!runtime.publish(firstRaw));
    const float in[] = {4, 8};
    float outL[2] = {}, outR[2] = {};
    CHECK(runtime.process(in, in, outL, outR, 2));
    CHECK_NEAR(outL[0], 1.0, 1e-7);
    CHECK(runtime.collectRetired() == nullptr);
    CHECK(!firstDestroyed);

    auto second = prepare(secondDestroyed);
    PreparedGraph* secondRaw = second.release();
    CHECK(runtime.publish(secondRaw));
    CHECK(runtime.process(in, in, outL, outR, 2));
    PreparedGraph* retired = runtime.collectRetired();
    CHECK(retired == firstRaw);
    CHECK(!firstDestroyed);
    delete retired;
    CHECK(firstDestroyed);

    PreparedGraph* active = runtime.takeActiveAfterStop();
    CHECK(active == secondRaw);
    delete active;
    CHECK(secondDestroyed);
    CHECK(runtime.takePendingAfterStop() == nullptr);
}

TEST(graph_budget_uses_engine_hardware_share) {
    HardwareProfile hardware;
    hardware.memoryBudgetMiB = 16;
    const EngineResourceBudget engine = makeEngineResourceBudget(hardware);
    const GraphResourceBudget graph = makeGraphResourceBudget(engine);
    CHECK_EQ(graph.maxWorkingBytes, engine.graphWorkingBytes);
    CHECK_EQ(graph.maxWorkingBytes, 4ull * 1024ull * 1024ull);
}
