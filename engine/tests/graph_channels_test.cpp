// Tests for the planar N-channel graph executor: real per-channel signals, isolation, lifetimes and no allocation.
#include "test.h"

#include "alloc_counter.h"
#include "graph.h"

#include <cmath>
#include <limits>
#include <memory>
#include <string>
#include <vector>

using namespace caw;

namespace {
constexpr GraphResourceBudget kBudget{
    std::numeric_limits<std::size_t>::max(),
    std::numeric_limits<std::size_t>::max(),
    64u * 1024u * 1024u,
};

// One module shape per channel layout: a generator (out only) and an effect (in + out).
struct ChannelModules {
    ChannelModules(ChannelLayout layout, uint32_t discrete)
        : sourcePorts{{"out", PortType::Audio, layout, false, discrete}},
          effectPorts{{"in", PortType::Audio, layout, true, discrete},
                      {"out", PortType::Audio, layout, false, discrete}},
          source{"test.channels.source", 1, sourcePorts, 1, nullptr, 0},
          effect{"test.channels.effect", 1, effectPorts, 2, nullptr, 0},
          channels(channelCountForLayout(layout, discrete)) {}
    ChannelModules(const ChannelModules&) = delete;
    ChannelModules& operator=(const ChannelModules&) = delete;
    PortDescriptor sourcePorts[1];
    PortDescriptor effectPorts[2];
    ModuleDescriptor source;
    ModuleDescriptor effect;
    uint32_t channels;
};

// Distinct, deterministic signal per channel: a channel-specific sine plus a channel tag.
float signal(uint32_t channel, uint32_t frame) noexcept {
    const double phase = static_cast<double>(frame) * 0.01 * static_cast<double>(channel + 1);
    return static_cast<float>(std::sin(phase) * 0.5 + static_cast<double>(channel) * 0.0625);
}

float gainFor(uint32_t channel) noexcept { return 0.5f + 0.25f * static_cast<float>(channel); }

class Generator final : public ModuleProcessor {
public:
    explicit Generator(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock& block) noexcept override {
        if (block.input.channelCount != 0) return false;
        for (uint32_t c = 0; c < block.output.channelCount; ++c)
            for (uint32_t i = 0; i < block.frames; ++i) block.output.channels[c][i] = signal(c, i);
        return true;
    }
private:
    const ModuleDescriptor& d_;
};

class ChannelGain final : public ModuleProcessor {
public:
    explicit ChannelGain(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock& block) noexcept override {
        if (block.input.channelCount != block.output.channelCount) return false;
        for (uint32_t c = 0; c < block.output.channelCount; ++c)
            for (uint32_t i = 0; i < block.frames; ++i)
                block.output.channels[c][i] = block.input.channels[c][i] * gainFor(c);
        return true;
    }
private:
    const ModuleDescriptor& d_;
};

// Negates exactly one channel and copies the others; proves channels never alias.
class TouchOneChannel final : public ModuleProcessor {
public:
    TouchOneChannel(const ModuleDescriptor& d, uint32_t channel) : d_(d), channel_(channel) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock& block) noexcept override {
        for (uint32_t c = 0; c < block.output.channelCount; ++c)
            for (uint32_t i = 0; i < block.frames; ++i)
                block.output.channels[c][i] = c == channel_ ? -block.input.channels[c][i]
                                                            : block.input.channels[c][i];
        return true;
    }
private:
    const ModuleDescriptor& d_;
    uint32_t channel_;
};

class Failing final : public ModuleProcessor {
public:
    explicit Failing(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock&) noexcept override { return false; }
private:
    const ModuleDescriptor& d_;
};

// Implements neither process overload: must fail loudly instead of leaving its buffer as-is.
class Unimplemented final : public ModuleProcessor {
public:
    explicit Unimplemented(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
private:
    const ModuleDescriptor& d_;
};

struct Planar {
    Planar(uint32_t channels, uint32_t frames, float fill = 0.0f)
        : data(channels, std::vector<float>(frames, fill)) {
        for (auto& channel : data) { pointers.push_back(channel.data()); constPointers.push_back(channel.data()); }
    }
    ChannelBufferView view(uint32_t frames) { return {pointers.data(), static_cast<uint32_t>(pointers.size()), frames}; }
    ConstChannelBufferView constView(uint32_t frames) const {
        return {constPointers.data(), static_cast<uint32_t>(constPointers.size()), frames};
    }
    std::vector<std::vector<float>> data;
    std::vector<float*> pointers;
    std::vector<const float*> constPointers;
};

struct LayoutCase { ChannelLayout layout; uint32_t discrete; uint32_t channels; };
const LayoutCase kLayouts[] = {
    {ChannelLayout::Mono, 0, 1},       {ChannelLayout::Stereo, 0, 2},
    {ChannelLayout::Quad, 0, 4},       {ChannelLayout::Surround51, 0, 6},
    {ChannelLayout::Surround71, 0, 8}, {ChannelLayout::Discrete, 3, 3},
};
}  // namespace

TEST(graph_executor_runs_distinct_generated_signals_per_channel_for_every_layout) {
    for (const LayoutCase& layout : kLayouts) {
        ChannelModules modules(layout.layout, layout.discrete);
        CHECK_EQ(modules.channels, layout.channels);
        Generator generator(modules.source);
        ChannelGain gain(modules.effect);
        const std::vector<GraphNode> nodes{{"gen", &modules.source}, {"gain", &modules.effect}};
        const std::vector<GraphConnection> edges{{0, 0, 1, 0}};
        GraphExecutor executor;
        CHECK(executor.prepare(nodes, edges, {&generator, &gain}, 1, 128, 48000.0, kBudget) == GraphError::Ok);
        CHECK_EQ(executor.outputChannels(), layout.channels);
        CHECK_EQ(executor.inputChannels(), 0u);
        constexpr uint32_t frames = 96;
        Planar out(layout.channels, frames, 99.0f);
        CHECK(executor.process(ConstChannelBufferView{}, out.view(frames), frames));
        for (uint32_t c = 0; c < layout.channels; ++c)
            for (uint32_t i = 0; i < frames; ++i) CHECK_EQ(out.data[c][i], signal(c, i) * gainFor(c));
    }
}

TEST(graph_executor_routes_host_input_channels_through_n_channel_chain) {
    for (const LayoutCase& layout : kLayouts) {
        ChannelModules modules(layout.layout, layout.discrete);
        ChannelGain first(modules.effect), second(modules.effect);
        const std::vector<GraphNode> nodes{{"a", &modules.effect}, {"b", &modules.effect}};
        const std::vector<GraphConnection> edges{{0, 1, 1, 0}};
        GraphExecutor executor;
        CHECK(executor.prepare(nodes, edges, {&first, &second}, 1, 64, 48000.0, kBudget) == GraphError::Ok);
        CHECK_EQ(executor.inputChannels(), layout.channels);
        constexpr uint32_t frames = 64;
        Planar in(layout.channels, frames);
        for (uint32_t c = 0; c < layout.channels; ++c)
            for (uint32_t i = 0; i < frames; ++i) in.data[c][i] = signal(c, i + 17);
        Planar out(layout.channels, frames);
        CHECK(executor.process(in.constView(frames), out.view(frames), frames));
        for (uint32_t c = 0; c < layout.channels; ++c)
            for (uint32_t i = 0; i < frames; ++i)
                CHECK_EQ(out.data[c][i], (signal(c, i + 17) * gainFor(c)) * gainFor(c));
        // A missing host input is silence on every channel, not stale data.
        CHECK(executor.process(ConstChannelBufferView{}, out.view(frames), frames));
        for (uint32_t c = 0; c < layout.channels; ++c) CHECK_EQ(out.data[c][frames - 1], 0.0f);
    }
}

TEST(graph_executor_keeps_channels_isolated) {
    for (const LayoutCase& layout : kLayouts) {
        for (uint32_t touched = 0; touched < layout.channels; ++touched) {
            ChannelModules modules(layout.layout, layout.discrete);
            Generator generator(modules.source);
            TouchOneChannel touch(modules.effect, touched);
            const std::vector<GraphNode> nodes{{"gen", &modules.source}, {"touch", &modules.effect}};
            const std::vector<GraphConnection> edges{{0, 0, 1, 0}};
            GraphExecutor executor;
            CHECK(executor.prepare(nodes, edges, {&generator, &touch}, 1, 32, 48000.0, kBudget) == GraphError::Ok);
            Planar out(layout.channels, 32);
            CHECK(executor.process(ConstChannelBufferView{}, out.view(32), 32));
            for (uint32_t c = 0; c < layout.channels; ++c)
                for (uint32_t i = 0; i < 32; ++i)
                    CHECK_EQ(out.data[c][i], c == touched ? -signal(c, i) : signal(c, i));
        }
    }
}

TEST(graph_executor_process_never_allocates_for_any_layout) {
    for (const LayoutCase& layout : kLayouts) {
        ChannelModules modules(layout.layout, layout.discrete);
        ChannelGain first(modules.effect), second(modules.effect), third(modules.effect);
        const std::vector<GraphNode> nodes{{"a", &modules.effect}, {"b", &modules.effect}, {"c", &modules.effect}};
        const std::vector<GraphConnection> edges{{0, 1, 1, 0}, {1, 1, 2, 0}};
        GraphExecutor executor;
        CHECK(executor.prepare(nodes, edges, {&first, &second, &third}, 2, 256, 48000.0, kBudget) == GraphError::Ok);
        Planar in(layout.channels, 256, 0.5f), out(layout.channels, 256);
        const ConstChannelBufferView inView = in.constView(256);
        const ChannelBufferView outView = out.view(256);
        std::size_t allocations = 0;
        {
            cawtest::AllocationScope scope;
            for (uint32_t block = 0; block < 16; ++block) {
                if (!executor.process(inView, outView, 256 - block)) break;
            }
            allocations = scope.count();
        }
        CHECK_EQ(allocations, 0u);
        CHECK_EQ(out.data[0][0], 0.5f * gainFor(0) * gainFor(0) * gainFor(0));
    }
}

TEST(graph_executor_stereo_wrapper_never_allocates) {
    ChannelModules modules(ChannelLayout::Stereo, 0);
    ChannelGain gain(modules.effect);
    const std::vector<GraphNode> nodes{{"gain", &modules.effect}};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, {}, {&gain}, 0, 64, 48000.0, kBudget) == GraphError::Ok);
    float l[64], r[64], outL[64], outR[64];
    for (int i = 0; i < 64; ++i) { l[i] = 1.0f; r[i] = -1.0f; }
    std::size_t allocations = 0;
    bool ok = false;
    {
        cawtest::AllocationScope scope;
        ok = executor.process(l, r, outL, outR, 64);
        allocations = scope.count();
    }
    CHECK(ok);
    CHECK_EQ(allocations, 0u);
    CHECK_EQ(outL[63], gainFor(0));
    CHECK_EQ(outR[63], -gainFor(1));
}

TEST(graph_executor_reports_processor_failure_and_silences_output) {
    ChannelModules modules(ChannelLayout::Quad, 0);
    Generator generator(modules.source);
    Failing failing(modules.effect);
    const std::vector<GraphNode> nodes{{"gen", &modules.source}, {"fail", &modules.effect}};
    const std::vector<GraphConnection> edges{{0, 0, 1, 0}};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, edges, {&generator, &failing}, 1, 32, 48000.0, kBudget) == GraphError::Ok);
    CHECK_EQ(executor.lastFailedNode(), std::numeric_limits<uint32_t>::max());
    Planar out(4, 32, 7.0f);
    CHECK(!executor.process(ConstChannelBufferView{}, out.view(32), 32));
    CHECK_EQ(executor.lastFailedNode(), 1u);
    CHECK_EQ(executor.failureCount(), 1u);
    for (uint32_t c = 0; c < 4; ++c)
        for (uint32_t i = 0; i < 32; ++i) CHECK_EQ(out.data[c][i], 0.0f);
}

TEST(graph_executor_fails_loudly_for_processor_implementing_neither_process) {
    ChannelModules modules(ChannelLayout::Stereo, 0);
    Unimplemented node(modules.effect);
    const std::vector<GraphNode> nodes{{"none", &modules.effect}};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, {}, {&node}, 0, 16, 48000.0, kBudget) == GraphError::Ok);
    float in[16] = {}, outL[16], outR[16];
    for (int i = 0; i < 16; ++i) { in[i] = 0.25f; outL[i] = outR[i] = 3.0f; }
    CHECK(!executor.process(in, in, outL, outR, 16));
    CHECK_EQ(executor.lastFailedNode(), 0u);
    CHECK_EQ(outL[0], 0.0f);
    CHECK_EQ(outR[15], 0.0f);
}

TEST(graph_executor_rejects_host_buffers_with_wrong_channel_count) {
    ChannelModules modules(ChannelLayout::Surround51, 0);
    ChannelGain gain(modules.effect);
    const std::vector<GraphNode> nodes{{"gain", &modules.effect}};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, {}, {&gain}, 0, 32, 48000.0, kBudget) == GraphError::Ok);
    Planar in6(6, 32), in2(2, 32), out6(6, 32), out8(8, 32), out2(2, 32);
    CHECK(executor.process(in6.constView(32), out6.view(32), 32));
    CHECK(!executor.process(in2.constView(32), out6.view(32), 32));  // never truncated or padded
    CHECK(!executor.process(in6.constView(32), out8.view(32), 32));
    CHECK(!executor.process(in6.constView(32), out2.view(32), 32));
    CHECK(!executor.process(in6.constView(16), out6.view(32), 32));  // capacity below the block
    CHECK(!executor.process(in6.constView(32), out6.view(32), 33));  // above prepared maximum
    float l[32] = {}, r[32] = {};
    CHECK(!executor.process(l, r, l, r, 32));  // stereo wrapper on a 5.1 graph
}

TEST(graph_executor_rejects_unconnected_inputs_with_different_channel_counts) {
    ChannelModules stereo(ChannelLayout::Stereo, 0), quad(ChannelLayout::Quad, 0);
    ChannelGain a(stereo.effect), b(quad.effect);
    const std::vector<GraphNode> nodes{{"stereo", &stereo.effect}, {"quad", &quad.effect}};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, {}, {&a, &b}, 1, 32, 48000.0, kBudget) == GraphError::RuntimeHostInputMismatch);
    CHECK(!executor.ready());
}

TEST(graph_compiler_rejects_discrete_channel_count_mismatch) {
    ChannelModules three(ChannelLayout::Discrete, 3), five(ChannelLayout::Discrete, 5);
    const std::vector<GraphNode> mismatched{{"three", &three.source}, {"five", &five.effect}};
    const std::vector<GraphConnection> edge{{0, 0, 1, 0}};
    const CompiledGraph rejected = compileGraph(mismatched, edge, kBudget);
    CHECK(rejected.error == GraphError::ChannelLayoutMismatch);
    CHECK_EQ(rejected.errorConnection, 0u);
    ChannelModules threeAgain(ChannelLayout::Discrete, 3);
    const std::vector<GraphNode> matched{{"three", &three.source}, {"three.fx", &threeAgain.effect}};
    CHECK(compileGraph(matched, edge, kBudget).error == GraphError::Ok);
}

TEST(graph_compiler_enforces_budgeted_channel_limit) {
    ChannelModules six(ChannelLayout::Surround51, 0);
    const std::vector<GraphNode> nodes{{"six", &six.effect}};
    GraphResourceBudget budget = kBudget;
    CHECK_EQ(budget.maxChannelsPerPort, kMaxPortChannels);
    budget.maxChannelsPerPort = 4;
    CHECK(compileGraph(nodes, {}, budget).error == GraphError::TooManyChannels);
    budget.maxChannelsPerPort = 6;
    CHECK(compileGraph(nodes, {}, budget).error == GraphError::Ok);
    budget.maxChannelsPerPort = 0;
    CHECK(compileGraph(nodes, {}, budget).error == GraphError::InvalidResourceBudget);
}

TEST(graph_executor_counts_channel_storage_in_working_memory_budget) {
    ChannelModules stereo(ChannelLayout::Stereo, 0), eight(ChannelLayout::Surround71, 0);
    ChannelGain stereoGain(stereo.effect), eightGain(eight.effect);
    const std::vector<GraphNode> stereoNodes{{"gain", &stereo.effect}};
    const std::vector<GraphNode> eightNodes{{"gain", &eight.effect}};
    constexpr uint32_t frames = 4096;
    // Enough for one stereo node's buffers plus metadata, far short of eight channels' worth.
    GraphResourceBudget budget = kBudget;
    budget.maxWorkingBytes = 4u * frames * sizeof(float) + 4096u;
    GraphExecutor executor;
    CHECK(executor.prepare(stereoNodes, {}, {&stereoGain}, 0, frames, 48000.0, budget) == GraphError::Ok);
    CHECK(executor.prepare(eightNodes, {}, {&eightGain}, 0, frames, 48000.0, budget) ==
          GraphError::ResourceBudgetExceeded);
    CHECK(!executor.ready());
}

TEST(graph_executor_rejects_non_audio_ports_until_typed_runtime_ports_exist) {
    const PortDescriptor ports[] = {
        {"in", PortType::Audio, ChannelLayout::Stereo, true},
        {"out", PortType::Audio, ChannelLayout::Stereo, false},
        {"cutoff", PortType::Control, ChannelLayout::None, true},
    };
    const ModuleDescriptor withControl{"test.channels.control", 1, ports, 3, nullptr, 0};
    ChannelGain gain(withControl);
    GraphExecutor executor;
    CHECK(executor.prepare({{"c", &withControl}}, {}, {&gain}, 0, 32, 48000.0, kBudget) ==
          GraphError::RuntimeUnsupportedPortType);
}

TEST(graph_executor_reprepare_and_reset_release_previous_channel_storage) {
    ChannelModules eight(ChannelLayout::Surround71, 0), mono(ChannelLayout::Mono, 0);
    Generator eightGen(eight.source), monoGen(mono.source);
    GraphExecutor executor;
    CHECK(executor.prepare({{"g", &eight.source}}, {}, {&eightGen}, 0, 64, 48000.0, kBudget) == GraphError::Ok);
    Planar out8(8, 64);
    CHECK(executor.process(ConstChannelBufferView{}, out8.view(64), 64));
    CHECK(executor.prepare({{"g", &mono.source}}, {}, {&monoGen}, 0, 64, 48000.0, kBudget) == GraphError::Ok);
    CHECK_EQ(executor.outputChannels(), 1u);
    Planar out1(1, 64);
    CHECK(!executor.process(ConstChannelBufferView{}, out8.view(64), 64));
    CHECK(executor.process(ConstChannelBufferView{}, out1.view(64), 64));
    CHECK_EQ(out1.data[0][63], signal(0, 63));
    executor.reset();
    CHECK(!executor.ready());
    CHECK_EQ(executor.outputChannels(), 0u);
    CHECK(!executor.process(ConstChannelBufferView{}, out1.view(64), 64));
}

TEST(graph_runtime_publishes_and_retires_n_channel_graphs) {
    ChannelModules six(ChannelLayout::Surround51, 0);
    auto prepare = [&]() {
        auto graph = std::make_unique<PreparedGraph>();
        std::vector<std::unique_ptr<ModuleProcessor>> processors;
        processors.push_back(std::make_unique<Generator>(six.source));
        processors.push_back(std::make_unique<ChannelGain>(six.effect));
        CHECK(graph->prepare({{"gen", &six.source}, {"gain", &six.effect}}, {{0, 0, 1, 0}},
                             std::move(processors), 1, 64, 48000.0, kBudget) == GraphError::Ok);
        return graph;
    };
    GraphRuntime runtime;
    PreparedGraph* first = prepare().release();
    CHECK(runtime.publish(first));
    Planar out(6, 64);
    CHECK(runtime.process(ConstChannelBufferView{}, out.view(64), 64));
    CHECK_EQ(out.data[5][10], signal(5, 10) * gainFor(5));
    PreparedGraph* second = prepare().release();
    CHECK(runtime.publish(second));
    CHECK(runtime.process(ConstChannelBufferView{}, out.view(64), 64));
    delete runtime.collectRetired();
    Planar wrong(2, 64, 5.0f);
    CHECK(!runtime.process(ConstChannelBufferView{}, wrong.view(64), 64));
    CHECK_EQ(wrong.data[1][0], 0.0f);  // a failed block is silence
    delete runtime.takeActiveAfterStop();
    CHECK(runtime.takePendingAfterStop() == nullptr);
}
