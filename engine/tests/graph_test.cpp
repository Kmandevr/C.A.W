// Tests for typed DSP graph wiring, deterministic order and cycle rejection.
#include "test.h"

#include "graph.h"

using namespace caw;

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
}

TEST(graph_compiles_stereo_chain_in_dependency_order) {
    const std::vector<GraphNode> nodes{{"sink", &sink}, {"effect", &effect}, {"source", &source}};
    const std::vector<GraphConnection> edges{{2, 0, 1, 0}, {1, 1, 0, 0}};
    const CompiledGraph graph = compileGraph(nodes, edges);
    CHECK(graph);
    CHECK_EQ(graph.executionOrder.size(), 3u);
    CHECK_EQ(graph.executionOrder[0], 2u);
    CHECK_EQ(graph.executionOrder[1], 1u);
    CHECK_EQ(graph.executionOrder[2], 0u);
}

TEST(graph_rejects_mono_stereo_mismatch) {
    const PortDescriptor monoOut[] = {{"out", PortType::Audio, ChannelLayout::Mono, false}};
    const ModuleDescriptor mono{"test.mono", 1, monoOut, 1, nullptr, 0};
    const std::vector<GraphNode> nodes{{"mono", &mono}, {"stereo", &sink}};
    const CompiledGraph graph = compileGraph(nodes, {{0, 0, 1, 0}});
    CHECK(graph.error == GraphError::ChannelLayoutMismatch);
    CHECK_EQ(graph.errorConnection, 0u);
}

TEST(graph_rejects_control_audio_connection) {
    const PortDescriptor controlOut[] = {{"out", PortType::Control, ChannelLayout::None, false}};
    const ModuleDescriptor control{"test.control", 1, controlOut, 1, nullptr, 0};
    const std::vector<GraphNode> nodes{{"control", &control}, {"audio", &sink}};
    CHECK(compileGraph(nodes, {{0, 0, 1, 0}}).error == GraphError::PortTypeMismatch);
}

TEST(graph_rejects_duplicate_drivers) {
    const std::vector<GraphNode> nodes{{"a", &source}, {"b", &source}, {"sink", &sink}};
    CHECK_EQ(compileGraph(nodes, {{0, 0, 2, 0}, {1, 0, 2, 0}}).error,
             GraphError::InputAlreadyConnected);
}

TEST(graph_rejects_cycles) {
    const std::vector<GraphNode> nodes{{"a", &effect}, {"b", &effect}};
    CHECK(compileGraph(nodes, {{0, 1, 1, 0}, {1, 1, 0, 0}}).error == GraphError::Cycle);
}

TEST(graph_rejects_duplicate_node_ids) {
    const std::vector<GraphNode> nodes{{"same", &source}, {"same", &sink}};
    CHECK(compileGraph(nodes, {}).error == GraphError::DuplicateNodeId);
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
}

TEST(graph_executor_processes_prepared_stereo_chain_without_changing_block_size) {
    const std::vector<GraphNode> nodes{{"input", &effect}, {"gain", &effect}};
    const std::vector<GraphConnection> edges{{0, 1, 1, 0}};
    PassThrough pass;
    GainProcessor gain;
    const std::vector<ModuleProcessor*> processors{&pass, &gain};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, edges, processors, 1, 64, 48000) == GraphError::Ok);
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

TEST(graph_executor_rejects_mono_runtime_layout_until_adapter_exists) {
    const PortDescriptor monoPorts[] = {
        {"in", PortType::Audio, ChannelLayout::Mono, true},
        {"out", PortType::Audio, ChannelLayout::Mono, false},
    };
    const ModuleDescriptor mono{"test.mono.runtime", 1, monoPorts, 2, nullptr, 0};
    class MonoProcessor final : public ModuleProcessor {
    public:
        const ModuleDescriptor& descriptor() const noexcept override { return mono; }
        void process(const StereoProcessBlock&) noexcept override {}
    } processor;
    const std::vector<GraphNode> nodes{{"mono", &mono}};
    const std::vector<ModuleProcessor*> processors{&processor};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, {}, processors, 0, 64, 48000) == GraphError::RuntimeUnsupportedPortLayout);
    CHECK(!executor.ready());
}
