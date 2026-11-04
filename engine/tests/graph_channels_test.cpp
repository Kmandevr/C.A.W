// Tests for the planar N-channel graph executor: real per-channel signals, isolation, lifetimes and no allocation.
#include "test.h"

#include "alloc_counter.h"
#include "graph.h"

#include <algorithm>
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

TEST(graph_executor_rejects_typed_ports_on_processors_without_process_ports) {
    // Decided at prepare time, never on the first block: a processor must opt in to processPorts().
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
    const PortDescriptor twoInputs[] = {
        {"in", PortType::Audio, ChannelLayout::Stereo, true},
        {"side", PortType::Audio, ChannelLayout::Stereo, true},
        {"out", PortType::Audio, ChannelLayout::Stereo, false},
    };
    const ModuleDescriptor sidechained{"test.channels.side", 1, twoInputs, 3, nullptr, 0};
    ChannelGain legacy(sidechained);
    CHECK(executor.prepare({{"s", &sidechained}}, {}, {&legacy}, 0, 32, 48000.0, kBudget) ==
          GraphError::RuntimeUnsupportedPortCount);
    CHECK(!executor.ready());
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

TEST(graph_executor_runs_legacy_stereo_generator_and_sink_without_input_or_output) {
    // Legacy stereo-only modules with no input port (generators) or no output port (sinks)
    // ran with null left/right pointers before F3 and must keep running.
    ChannelModules stereo(ChannelLayout::Stereo, 0);
    const PortDescriptor sinkPorts[] = {{"in", PortType::Audio, ChannelLayout::Stereo, true}};
    const ModuleDescriptor sink{"test.channels.sink", 1, sinkPorts, 1, nullptr, 0};
    class LegacyGenerator final : public ModuleProcessor {
    public:
        explicit LegacyGenerator(const ModuleDescriptor& d) : d_(d) {}
        const ModuleDescriptor& descriptor() const noexcept override { return d_; }
        void process(const StereoProcessBlock& b) noexcept override {
            if (b.inputLeft || b.inputRight) return;
            for (uint32_t i = 0; i < b.frames; ++i) { b.outputLeft[i] = signal(0, i); b.outputRight[i] = signal(1, i); }
        }
    private: const ModuleDescriptor& d_;
    } generator(stereo.source);
    class LegacySink final : public ModuleProcessor {
    public:
        explicit LegacySink(const ModuleDescriptor& d) : d_(d) {}
        const ModuleDescriptor& descriptor() const noexcept override { return d_; }
        void process(const StereoProcessBlock& b) noexcept override {
            if (!b.outputLeft && !b.outputRight) last = b.inputLeft[b.frames - 1];
        }
        float last = 0.0f;
    private: const ModuleDescriptor& d_;
    } legacySink(sink);
    ChannelGain gain(stereo.effect);
    const std::vector<GraphNode> nodes{{"gen", &stereo.source}, {"gain", &stereo.effect}, {"sink", &sink}};
    const std::vector<GraphConnection> edges{{0, 0, 1, 0}, {1, 1, 2, 0}};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, edges, {&generator, &gain, &legacySink}, 1, 32, 48000.0, kBudget) == GraphError::Ok);
    float outL[32] = {}, outR[32] = {};
    CHECK(executor.process(nullptr, nullptr, outL, outR, 32));
    CHECK_EQ(outL[31], signal(0, 31) * gainFor(0));
    CHECK_EQ(outR[31], signal(1, 31) * gainFor(1));
    CHECK_EQ(legacySink.last, signal(0, 31) * gainFor(0));
}

TEST(graph_executor_ignores_host_input_when_graph_has_no_host_fed_inputs) {
    // A host may always pass its capture channels; a generator graph ignores them.
    ChannelModules quad(ChannelLayout::Quad, 0);
    Generator generator(quad.source);
    GraphExecutor executor;
    CHECK(executor.prepare({{"gen", &quad.source}}, {}, {&generator}, 0, 32, 48000.0, kBudget) == GraphError::Ok);
    CHECK_EQ(executor.inputChannels(), 0u);
    Planar capture(2, 32, 0.75f), out(4, 32);
    CHECK(executor.process(capture.constView(32), out.view(32), 32));
    CHECK_EQ(out.data[3][5], signal(3, 5));
}

TEST(allocation_counter_detects_allocations_and_frees) {
    // Proves the zero counts above are real: direct operator calls cannot be elided.
    std::size_t allocations = 0, deallocations = 0;
    {
        cawtest::AllocationScope scope;
        void* p = ::operator new(16);
        ::operator delete(p);
        allocations = scope.allocations();
        deallocations = scope.deallocations();
    }
    CHECK_EQ(allocations, 1u);
    CHECK_EQ(deallocations, 1u);
}

namespace {
// A 6-channel mix-bus shape: a summing input (fan-in) and one output.
struct BusModule {
    BusModule()
        : ports{{"in", PortType::Audio, ChannelLayout::Surround51, true, 0, true},
                {"out", PortType::Audio, ChannelLayout::Surround51, false}},
          bus{"test.channels.bus", 1, ports, 2, nullptr, 0} {}
    PortDescriptor ports[2];
    ModuleDescriptor bus;
};

// Generator with a per-instance offset so every source is distinct.
class OffsetGenerator final : public ModuleProcessor {
public:
    OffsetGenerator(const ModuleDescriptor& d, uint32_t offset) : d_(d), offset_(offset) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock& block) noexcept override {
        for (uint32_t c = 0; c < block.output.channelCount; ++c)
            for (uint32_t i = 0; i < block.frames; ++i) block.output.channels[c][i] = signal(c, i + offset_);
        return true;
    }
private:
    const ModuleDescriptor& d_;
    uint32_t offset_;
};

class Copy final : public ModuleProcessor {
public:
    explicit Copy(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock& block) noexcept override {
        for (uint32_t c = 0; c < block.output.channelCount; ++c)
            for (uint32_t i = 0; i < block.frames; ++i) block.output.channels[c][i] = block.input.channels[c][i];
        return true;
    }
private:
    const ModuleDescriptor& d_;
};
}  // namespace

TEST(graph_executor_sums_fan_in_in_connection_order_bit_exactly) {
    ChannelModules six(ChannelLayout::Surround51, 0);
    BusModule bus;
    OffsetGenerator a(six.source, 0), b(six.source, 1000), c(six.source, 2000);
    Copy busCopy(bus.bus);
    // Connection order (c, a, b) differs from node order on purpose: summation follows connections.
    const std::vector<GraphNode> nodes{{"a", &six.source}, {"b", &six.source}, {"c", &six.source}, {"bus", &bus.bus}};
    const std::vector<GraphConnection> edges{{2, 0, 3, 0}, {0, 0, 3, 0}, {1, 0, 3, 0}};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, edges, {&a, &b, &c, &busCopy}, 3, 64, 48000.0, kBudget) == GraphError::Ok);
    Planar out(6, 64);
    CHECK(executor.process(ConstChannelBufferView{}, out.view(64), 64));
    for (uint32_t ch = 0; ch < 6; ++ch)
        for (uint32_t i = 0; i < 64; ++i) {
            float expected = 0.0f;
            expected += signal(ch, i + 2000);
            expected += signal(ch, i);
            expected += signal(ch, i + 1000);
            CHECK_EQ(out.data[ch][i], expected);
        }
}

TEST(graph_executor_summing_input_with_one_source_still_starts_from_positive_zero) {
    // A mix bus always accumulates from +0.0f, so a lone -0.0f source arrives as +0.0f,
    // exactly as an accumulating mixer behaves.
    const PortDescriptor monoOut[] = {{"out", PortType::Audio, ChannelLayout::Mono, false}};
    const PortDescriptor monoBus[] = {{"in", PortType::Audio, ChannelLayout::Mono, true, 0, true},
                                      {"out", PortType::Audio, ChannelLayout::Mono, false}};
    const ModuleDescriptor source{"test.negzero", 1, monoOut, 1, nullptr, 0};
    const ModuleDescriptor bus{"test.monobus", 1, monoBus, 2, nullptr, 0};
    class NegativeZero final : public ModuleProcessor {
    public:
        explicit NegativeZero(const ModuleDescriptor& d) : d_(d) {}
        const ModuleDescriptor& descriptor() const noexcept override { return d_; }
        bool process(const AudioProcessBlock& b) noexcept override {
            for (uint32_t i = 0; i < b.frames; ++i) b.output.channels[0][i] = -0.0f;
            return true;
        }
    private: const ModuleDescriptor& d_;
    } negative(source);
    Copy copy(bus);
    GraphExecutor executor;
    CHECK(executor.prepare({{"s", &source}, {"bus", &bus}}, {{0, 0, 1, 0}}, {&negative, &copy}, 1, 8, 48000.0, kBudget) ==
          GraphError::Ok);
    Planar out(1, 8, 5.0f);
    CHECK(executor.process(ConstChannelBufferView{}, out.view(8), 8));
    CHECK(!std::signbit(out.data[0][0]));
}

TEST(graph_compiler_allows_multiple_drivers_only_on_summing_inputs) {
    ChannelModules six(ChannelLayout::Surround51, 0);
    BusModule bus;
    const std::vector<GraphNode> toBus{{"a", &six.source}, {"b", &six.source}, {"bus", &bus.bus}};
    CHECK(compileGraph(toBus, {{0, 0, 2, 0}, {1, 0, 2, 0}}, kBudget).error == GraphError::Ok);
    const std::vector<GraphNode> toEffect{{"a", &six.source}, {"b", &six.source}, {"fx", &six.effect}};
    const CompiledGraph rejected = compileGraph(toEffect, {{0, 0, 2, 0}, {1, 0, 2, 0}}, kBudget);
    CHECK(rejected.error == GraphError::InputAlreadyConnected);
    CHECK_EQ(rejected.errorConnection, 1u);
}

TEST(graph_executor_fan_in_never_allocates) {
    ChannelModules six(ChannelLayout::Surround51, 0);
    BusModule bus;
    OffsetGenerator a(six.source, 0), b(six.source, 7);
    Copy busCopy(bus.bus);
    GraphExecutor executor;
    CHECK(executor.prepare({{"a", &six.source}, {"b", &six.source}, {"bus", &bus.bus}},
                           {{0, 0, 2, 0}, {1, 0, 2, 0}}, {&a, &b, &busCopy}, 2, 192, 48000.0, kBudget) ==
          GraphError::Ok);
    Planar out(6, 192);
    const ChannelBufferView view = out.view(192);
    std::size_t operations = 0;
    bool ok = true;
    {
        cawtest::AllocationScope scope;
        for (int block = 0; block < 8; ++block) ok = executor.process(ConstChannelBufferView{}, view, 192) && ok;
        operations = scope.count();
    }
    CHECK(ok);
    CHECK_EQ(operations, 0u);
}

TEST(graph_compiler_rejects_duplicate_edge_into_summing_input) {
    // The same source routed twice into one mix bus would play 6 dB louder; reject it.
    ChannelModules six(ChannelLayout::Surround51, 0);
    BusModule bus;
    const std::vector<GraphNode> nodes{{"a", &six.source}, {"b", &six.source}, {"bus", &bus.bus}};
    const CompiledGraph duplicate = compileGraph(nodes, {{0, 0, 2, 0}, {1, 0, 2, 0}, {0, 0, 2, 0}}, kBudget);
    CHECK(duplicate.error == GraphError::DuplicateConnection);
    CHECK_EQ(duplicate.errorConnection, 2u);
}

TEST(graph_executor_prepares_wide_fan_in_in_linear_time) {
    // 8,192 sources into one bus plus a 2,048-bus chain: prepare must stay O(nodes + edges).
    const PortDescriptor monoOut[] = {{"out", PortType::Audio, ChannelLayout::Mono, false}};
    const PortDescriptor monoBus[] = {{"in", PortType::Audio, ChannelLayout::Mono, true, 0, true},
                                      {"out", PortType::Audio, ChannelLayout::Mono, false}};
    const ModuleDescriptor source{"test.wide.src", 1, monoOut, 1, nullptr, 0};
    const ModuleDescriptor bus{"test.wide.bus", 1, monoBus, 2, nullptr, 0};
    constexpr uint32_t sources = 8192, buses = 2048;
    std::vector<std::string> ids;
    ids.reserve(sources + buses);
    std::vector<GraphNode> nodes;
    std::vector<GraphConnection> edges;
    std::vector<std::unique_ptr<ModuleProcessor>> owned;
    std::vector<ModuleProcessor*> processors;
    for (uint32_t i = 0; i < sources; ++i) {
        ids.push_back("s" + std::to_string(i));
        owned.push_back(std::make_unique<OffsetGenerator>(source, i));
    }
    for (uint32_t i = 0; i < buses; ++i) {
        ids.push_back("b" + std::to_string(i));
        owned.push_back(std::make_unique<Copy>(bus));
    }
    for (uint32_t i = 0; i < sources + buses; ++i) {
        nodes.push_back({ids[i], i < sources ? &source : &bus});
        processors.push_back(owned[i].get());
    }
    for (uint32_t i = 0; i < sources; ++i) edges.push_back({i, 0, sources, 0});
    for (uint32_t i = 1; i < buses; ++i) edges.push_back({sources + i - 1, 1, sources + i, 0});
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, edges, processors, sources + buses - 1, 16, 48000.0, kBudget) == GraphError::Ok);
    Planar out(1, 16);
    CHECK(executor.process(ConstChannelBufferView{}, out.view(16), 16));
    float expected = 0.0f;
    for (uint32_t i = 0; i < sources; ++i) expected += signal(0, 3 + i);
    CHECK_EQ(out.data[0][3], expected);
}

TEST(graph_fan_in_saturates_non_finite_sources) {
    // Same rule as the mixer's float routing: inf saturates at +/-FLT_MAX, NaN counts as 0.
    const PortDescriptor monoOut[] = {{"out", PortType::Audio, ChannelLayout::Mono, false}};
    const PortDescriptor monoBus[] = {{"in", PortType::Audio, ChannelLayout::Mono, true, 0, true},
                                      {"out", PortType::Audio, ChannelLayout::Mono, false}};
    const ModuleDescriptor source{"test.nonfinite", 1, monoOut, 1, nullptr, 0};
    const ModuleDescriptor bus{"test.satbus", 1, monoBus, 2, nullptr, 0};
    class Constant final : public ModuleProcessor {
    public:
        Constant(const ModuleDescriptor& d, float v) : d_(d), v_(v) {}
        const ModuleDescriptor& descriptor() const noexcept override { return d_; }
        bool process(const AudioProcessBlock& b) noexcept override {
            for (uint32_t i = 0; i < b.frames; ++i) b.output.channels[0][i] = v_;
            return true;
        }
    private: const ModuleDescriptor& d_; float v_;
    };
    Constant inf(source, std::numeric_limits<float>::infinity()), nan(source, std::numeric_limits<float>::quiet_NaN()),
        big(source, std::numeric_limits<float>::max());
    Copy copy(bus);
    GraphExecutor executor;
    CHECK(executor.prepare({{"inf", &source}, {"nan", &source}, {"big", &source}, {"bus", &bus}},
                           {{0, 0, 3, 0}, {1, 0, 3, 0}, {2, 0, 3, 0}}, {&inf, &nan, &big, &copy}, 3, 8, 48000.0, kBudget) ==
          GraphError::Ok);
    Planar out(1, 8);
    CHECK(executor.process(ConstChannelBufferView{}, out.view(8), 8));
    CHECK_EQ(out.data[0][0], std::numeric_limits<float>::max());
}

namespace {
// Stereo shapes for dynamic-routing tests: a generator and a summing bus.
struct StereoRoutingModules {
    StereoRoutingModules()
        : sourcePorts{{"out", PortType::Audio, ChannelLayout::Stereo, false}},
          busPorts{{"in", PortType::Audio, ChannelLayout::Stereo, true, 0, true},
                   {"out", PortType::Audio, ChannelLayout::Stereo, false}},
          plainPorts{{"in", PortType::Audio, ChannelLayout::Stereo, true},
                     {"out", PortType::Audio, ChannelLayout::Stereo, false}},
          source{"test.route.src", 1, sourcePorts, 1, nullptr, 0},
          bus{"test.route.bus", 1, busPorts, 2, nullptr, 0},
          plain{"test.route.plain", 1, plainPorts, 2, nullptr, 0} {}
    PortDescriptor sourcePorts[1], busPorts[2], plainPorts[2];
    ModuleDescriptor source, bus, plain;
};
}  // namespace

TEST(graph_dynamic_routing_matches_the_same_static_fan_in_bit_exactly) {
    StereoRoutingModules m;
    OffsetGenerator a(m.source, 0), b(m.source, 100), c(m.source, 200);
    Copy inner(m.bus), outer(m.bus);
    const std::vector<GraphNode> nodes{{"a", &m.source}, {"b", &m.source}, {"c", &m.source},
                                       {"inner", &m.bus}, {"outer", &m.bus}};
    const std::vector<ModuleProcessor*> processors{&a, &b, &c, &inner, &outer};
    const std::vector<GraphConnection> edges{{0, 0, 3, 0}, {1, 0, 3, 0}, {3, 1, 4, 0}, {2, 0, 4, 0}};
    GraphExecutor fixed;
    CHECK(fixed.prepare(nodes, edges, processors, 4, 64, 48000.0, kBudget) == GraphError::Ok);
    Planar expected(2, 64);
    CHECK(fixed.process(ConstChannelBufferView{}, expected.view(64), 64));

    GraphExecutor dynamic;
    CHECK(dynamic.prepare(nodes, {}, processors, 4, 64, 48000.0, kBudget) == GraphError::Ok);
    CHECK(dynamic.reserveRouting(8, kBudget) == GraphError::Ok);
    const uint32_t order[] = {0, 1, 2, 3, 4};
    CHECK(dynamic.setRouting(edges.data(), static_cast<uint32_t>(edges.size()), order, 5));
    Planar out(2, 64);
    CHECK(dynamic.process(ConstChannelBufferView{}, out.view(64), 64));
    for (uint32_t ch = 0; ch < 2; ++ch)
        for (uint32_t i = 0; i < 64; ++i) CHECK_EQ(out.data[ch][i], expected.data[ch][i]);
}

TEST(graph_dynamic_routing_rejects_invalid_routes_and_keeps_the_previous_one) {
    StereoRoutingModules m;
    OffsetGenerator a(m.source, 0), b(m.source, 50);
    Copy bus(m.bus), plain(m.plain);
    const std::vector<GraphNode> nodes{{"a", &m.source}, {"b", &m.source}, {"bus", &m.bus}, {"plain", &m.plain}};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, {}, {&a, &b, &bus, &plain}, 2, 16, 48000.0, kBudget) == GraphError::Ok);
    CHECK(executor.reserveRouting(1, kBudget) == GraphError::Ok);
    const uint32_t order[] = {0, 1, 2, 3};
    const GraphConnection good[] = {{0, 0, 2, 0}};
    CHECK(executor.setRouting(good, 1, order, 4));
    Planar before(2, 16);
    CHECK(executor.process(ConstChannelBufferView{}, before.view(16), 16));

    const uint32_t duplicate[] = {0, 0, 2, 3};
    const uint32_t withoutOutput[] = {0, 1, 3};    // the output node (2) must run
    const uint32_t withoutSource[] = {1, 2, 3};    // edge 0 -> 2 needs node 0 to run
    const uint32_t busFirst[] = {2, 0, 1, 3};
    const GraphConnection intoPlain[] = {{0, 0, 3, 0}};
    const GraphConnection overCapacity[] = {{0, 0, 2, 0}, {1, 0, 2, 0}};
    const GraphConnection badNode[] = {{9, 0, 2, 0}};
    CHECK(!executor.setRouting(good, 1, duplicate, 4));
    CHECK(!executor.setRouting(good, 1, withoutOutput, 3));
    CHECK(!executor.setRouting(good, 1, withoutSource, 3));
    CHECK(!executor.setRouting(good, 1, busFirst, 4));       // a source must run before its bus
    CHECK(!executor.setRouting(intoPlain, 1, order, 4));     // only summing inputs are routable
    CHECK(!executor.setRouting(overCapacity, 2, order, 4));  // reserved capacity is 1
    CHECK(!executor.setRouting(badNode, 1, order, 4));
    Planar after(2, 16);
    CHECK(executor.process(ConstChannelBufferView{}, after.view(16), 16));
    for (uint32_t i = 0; i < 16; ++i) CHECK_EQ(after.data[0][i], before.data[0][i]);
}

TEST(graph_dynamic_routing_switches_sources_between_blocks_without_allocating) {
    StereoRoutingModules m;
    OffsetGenerator a(m.source, 0), b(m.source, 500);
    Copy bus(m.bus);
    GraphExecutor executor;
    CHECK(executor.prepare({{"a", &m.source}, {"b", &m.source}, {"bus", &m.bus}}, {}, {&a, &b, &bus}, 2, 32,
                           48000.0, kBudget) == GraphError::Ok);
    CHECK(executor.reserveRouting(2, kBudget) == GraphError::Ok);
    const uint32_t order[] = {0, 1, 2};
    const GraphConnection toA[] = {{0, 0, 2, 0}};
    const GraphConnection toB[] = {{1, 0, 2, 0}};
    const GraphConnection both[] = {{1, 0, 2, 0}, {0, 0, 2, 0}};
    Planar out(2, 32);
    const ChannelBufferView view = out.view(32);
    std::size_t operations = 0;
    bool ok = true;
    float first = 0, second = 0, third = 0, empty = 1;
    {
        cawtest::AllocationScope scope;
        ok = executor.setRouting(toA, 1, order, 3) && executor.process(ConstChannelBufferView{}, view, 32) && ok;
        first = out.data[0][3];
        ok = executor.setRouting(toB, 1, order, 3) && executor.process(ConstChannelBufferView{}, view, 32) && ok;
        second = out.data[0][3];
        ok = executor.setRouting(both, 2, order, 3) && executor.process(ConstChannelBufferView{}, view, 32) && ok;
        third = out.data[0][3];
        ok = executor.setRouting(nullptr, 0, order, 3) && executor.process(ConstChannelBufferView{}, view, 32) && ok;
        empty = out.data[0][3];
        operations = scope.count();
    }
    CHECK(ok);
    CHECK_EQ(operations, 0u);
    CHECK_EQ(first, signal(0, 3));
    CHECK_EQ(second, signal(0, 503));
    float sum = 0.0f;
    sum += signal(0, 503);
    sum += signal(0, 3);
    CHECK_EQ(third, sum);
    CHECK_EQ(empty, 0.0f);  // a summing input with no routes is silence, not host input
}

TEST(graph_dynamic_routing_requires_a_graph_without_static_connections) {
    StereoRoutingModules m;
    OffsetGenerator a(m.source, 0);
    Copy bus(m.bus);
    GraphExecutor executor;
    CHECK(executor.prepare({{"a", &m.source}, {"bus", &m.bus}}, {{0, 0, 1, 0}}, {&a, &bus}, 1, 16, 48000.0, kBudget) ==
          GraphError::Ok);
    CHECK(executor.reserveRouting(4, kBudget) == GraphError::RoutingUnavailable);
    GraphExecutor unprepared;
    CHECK(unprepared.reserveRouting(4, kBudget) == GraphError::RoutingUnavailable);
}

TEST(graph_dynamic_routing_skips_nodes_left_out_of_the_order) {
    // Nodes not listed in the order are not run at all, so idle nodes cost nothing.
    StereoRoutingModules m;
    class Counting final : public ModuleProcessor {
    public:
        explicit Counting(const ModuleDescriptor& d) : d_(d) {}
        const ModuleDescriptor& descriptor() const noexcept override { return d_; }
        bool process(const AudioProcessBlock& b) noexcept override {
            ++calls;
            for (uint32_t c = 0; c < b.output.channelCount; ++c)
                for (uint32_t i = 0; i < b.frames; ++i) b.output.channels[c][i] = 0.25f;
            return true;
        }
        int calls = 0;
    private: const ModuleDescriptor& d_;
    } used(m.source), idle(m.source);
    Copy bus(m.bus);
    GraphExecutor executor;
    CHECK(executor.prepare({{"used", &m.source}, {"idle", &m.source}, {"bus", &m.bus}}, {}, {&used, &idle, &bus}, 2, 16,
                           48000.0, kBudget) == GraphError::Ok);
    CHECK(executor.reserveRouting(2, kBudget) == GraphError::Ok);
    const uint32_t order[] = {0, 2};
    const GraphConnection edges[] = {{0, 0, 2, 0}};
    CHECK(executor.setRouting(edges, 1, order, 2));
    Planar out(2, 16);
    CHECK(executor.process(ConstChannelBufferView{}, out.view(16), 16));
    CHECK(executor.process(ConstChannelBufferView{}, out.view(16), 16));
    CHECK_EQ(used.calls, 2);
    CHECK_EQ(idle.calls, 0);
    CHECK_EQ(out.data[1][15], 0.25f);
    // Listing it again runs it again.
    const uint32_t all[] = {0, 1, 2};
    CHECK(executor.setRouting(edges, 1, all, 3));
    CHECK(executor.process(ConstChannelBufferView{}, out.view(16), 16));
    CHECK_EQ(idle.calls, 1);
}

TEST(graph_dynamic_routing_routes_plain_inputs_directly_when_reserved) {
    // A plain input reads its one source's buffer as-is: -0.0f and +/-FLT_MAX keep their bits (no
    // summing from +0.0f). Unrouted, it is silence even when host input is offered.
    StereoRoutingModules m;
    class Edges final : public ModuleProcessor {
    public:
        explicit Edges(const ModuleDescriptor& d) : d_(d) {}
        const ModuleDescriptor& descriptor() const noexcept override { return d_; }
        bool process(const AudioProcessBlock& b) noexcept override {
            const float v[] = {-0.0f, std::numeric_limits<float>::max(), -std::numeric_limits<float>::max(), 0.375f};
            for (uint32_t c = 0; c < b.output.channelCount; ++c)
                for (uint32_t i = 0; i < b.frames; ++i) b.output.channels[c][i] = v[(i + c) % 4];
            return true;
        }
    private: const ModuleDescriptor& d_;
    } edges(m.source);
    OffsetGenerator other(m.source, 40);
    Copy plain(m.plain);
    // Nodes: 0 edges, 1 other, 2 plain (the output node).
    GraphExecutor executor;
    CHECK(executor.prepare({{"edges", &m.source}, {"other", &m.source}, {"plain", &m.plain}}, {}, {&edges, &other, &plain},
                           2, 16, 48000.0, kBudget) == GraphError::Ok);
    CHECK_EQ(executor.inputChannels(), 2u);  // the plain input is host-fed until routing is reserved
    CHECK(executor.reserveRouting(1, kBudget, true) == GraphError::Ok);
    CHECK_EQ(executor.inputChannels(), 0u);
    const uint32_t order[] = {0, 1, 2};
    const GraphConnection fromEdges[] = {{0, 0, 2, 0}};
    const GraphConnection fromOther[] = {{1, 0, 2, 0}};
    const GraphConnection twoIntoPlain[] = {{0, 0, 2, 0}, {1, 0, 2, 0}};
    Planar host(2, 16, 0.5f);
    Planar out(2, 16);
    bool ok = true;
    std::size_t operations = 0;
    float routed[2][16] = {}, switched = 0, silent = 1;
    {
        cawtest::AllocationScope scope;
        ok = executor.setRouting(fromEdges, 1, order, 3) && executor.process(host.constView(16), out.view(16), 16) && ok;
        for (uint32_t c = 0; c < 2; ++c)
            for (uint32_t i = 0; i < 16; ++i) routed[c][i] = out.data[c][i];
        ok = !executor.setRouting(twoIntoPlain, 2, order, 3) && ok;  // rejected; the previous route stays
        ok = executor.process(host.constView(16), out.view(16), 16) && ok;
        ok = out.data[0][0] == routed[0][0] && std::signbit(out.data[0][0]) && ok;
        ok = executor.setRouting(fromOther, 1, order, 3) && executor.process(host.constView(16), out.view(16), 16) && ok;
        switched = out.data[0][3];
        ok = executor.setRouting(nullptr, 0, order, 3) && executor.process(host.constView(16), out.view(16), 16) && ok;
        silent = out.data[1][5];
        operations = scope.count();
    }
    CHECK(ok);
    CHECK_EQ(operations, 0u);
    for (uint32_t c = 0; c < 2; ++c)
        for (uint32_t i = 0; i < 16; ++i) {
            const float v[] = {-0.0f, std::numeric_limits<float>::max(), -std::numeric_limits<float>::max(), 0.375f};
            CHECK_EQ(routed[c][i], v[(i + c) % 4]);
            CHECK_EQ(std::signbit(routed[c][i]), std::signbit(v[(i + c) % 4]));
        }
    CHECK_EQ(switched, signal(0, 43));
    CHECK_EQ(silent, 0.0f);  // no route: silence, not the host's 0.5
}

TEST(graph_reserve_routing_keeps_plain_inputs_host_fed_without_the_opt_in) {
    // Without routePlainInputs, plain inputs still read the host and summing inputs do not; checked
    // across many nodes, some without inputs, so the host-slot walk must find every slot's node.
    StereoRoutingModules m;
    constexpr uint32_t pairs = 4096;
    std::vector<std::string> ids;
    ids.reserve(2 * pairs + 1);  // nodes keep pointers to these ids
    std::vector<std::unique_ptr<ModuleProcessor>> owned;
    std::vector<GraphNode> nodes;
    std::vector<ModuleProcessor*> processors;
    for (uint32_t i = 0; i < pairs; ++i) {
        ids.push_back("g" + std::to_string(i));
        owned.push_back(std::make_unique<OffsetGenerator>(m.source, i));
        nodes.push_back({ids.back(), &m.source});
        ids.push_back("p" + std::to_string(i));
        owned.push_back(std::make_unique<Copy>(m.plain));
        nodes.push_back({ids.back(), &m.plain});
    }
    ids.push_back("bus");
    owned.push_back(std::make_unique<Copy>(m.bus));
    nodes.push_back({ids.back(), &m.bus});
    for (auto& p : owned) processors.push_back(p.get());
    const uint32_t bus = 2 * pairs;
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, {}, processors, bus, 16, 48000.0, kBudget) == GraphError::Ok);
    CHECK(executor.reserveRouting(2, kBudget) == GraphError::Ok);
    CHECK_EQ(executor.inputChannels(), 2u);
    const uint32_t last = 2 * pairs - 1;  // the last plain node
    const uint32_t order[] = {last, bus};
    const GraphConnection edges[] = {{last, 1, bus, 0}};
    CHECK(executor.setRouting(edges, 1, order, 2));
    Planar host(2, 16, 0.25f), out(2, 16);
    CHECK(executor.process(host.constView(16), out.view(16), 16));
    CHECK_EQ(out.data[0][7], 0.25f);
    CHECK_EQ(out.data[1][7], 0.25f);
}

namespace {
// F5.1 typed ports: processors that opt in to processPorts().
class Typed : public ModuleProcessor {
public:
    explicit Typed(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool usesProcessPorts() const noexcept override { return true; }
private:
    const ModuleDescriptor& d_;
};

// Mono modulation source: signal(channel tag, frame + offset) scaled, or a fixed value when set.
class ModSource final : public Typed {
public:
    ModSource(const ModuleDescriptor& d, uint32_t offset, float fixed = 0.0f, bool useFixed = false)
        : Typed(d), offset_(offset), fixed_(fixed), useFixed_(useFixed) {}
    bool processPorts(const ProcessBlock& b) noexcept override {
        if (b.modulationOutCount != 1 || b.audioInCount || b.audioOutCount) return false;
        for (uint32_t i = 0; i < b.frames; ++i) b.modulationOut[0][i] = useFixed_ ? fixed_ : signal(0, i + offset_);
        return true;
    }
private:
    uint32_t offset_;
    float fixed_;
    bool useFixed_;
};

// Audio in x modulation in -> audio out, plus a mono sidechain added at x10 and a control level.
class Processor final : public Typed {
public:
    using Typed::Typed;
    bool processPorts(const ProcessBlock& b) noexcept override {
        if (b.audioInCount != 2 || b.audioOutCount != 1 || b.modulationInCount != 1 || b.controlInCount != 1)
            return false;
        const ConstChannelBufferView& in = b.audioIn[0];
        const ConstChannelBufferView& side = b.audioIn[1];
        const float level = *b.controlIn[0];
        for (uint32_t c = 0; c < b.audioOut[0].channelCount; ++c)
            for (uint32_t i = 0; i < b.frames; ++i)
                b.audioOut[0].channels[c][i] =
                    (in.channels[c][i] * b.modulationIn[0][i] + side.channels[0][i] * 10.0f) * level;
        return true;
    }
};

// Writes its control output once (the first block) and never again: the value must hold.
class ControlSource final : public Typed {
public:
    ControlSource(const ModuleDescriptor& d, float value) : Typed(d), value_(value) {}
    bool processPorts(const ProcessBlock& b) noexcept override {
        if (b.controlOutCount != 1) return false;
        if (!written_) *b.controlOut[0] = value_;
        written_ = true;
        return true;
    }
private:
    float value_;
    bool written_ = false;
};

struct TypedModules {
    TypedModules()
        : modPorts{{"lfo", PortType::Modulation, ChannelLayout::None, false}},
          procPorts{{"in", PortType::Audio, ChannelLayout::Stereo, true},
                    {"amount", PortType::Modulation, ChannelLayout::None, true, 0, true},
                    {"side", PortType::Audio, ChannelLayout::Mono, true},
                    {"level", PortType::Control, ChannelLayout::None, true, 0, false, 0.75f},
                    {"out", PortType::Audio, ChannelLayout::Stereo, false}},
          monoPorts{{"out", PortType::Audio, ChannelLayout::Mono, false}},
          controlPorts{{"set", PortType::Control, ChannelLayout::None, false, 0, false, 0.5f}},
          mod{"test.typed.lfo", 1, modPorts, 1, nullptr, 0},
          proc{"test.typed.proc", 1, procPorts, 5, nullptr, 0},
          mono{"test.typed.mono", 1, monoPorts, 1, nullptr, 0},
          control{"test.typed.control", 1, controlPorts, 1, nullptr, 0} {}
    PortDescriptor modPorts[1], procPorts[5], monoPorts[1], controlPorts[1];
    ModuleDescriptor mod, proc, mono, control;
};
// Port indexes on `proc`.
constexpr uint32_t kIn = 0, kAmount = 1, kSide = 2, kLevel = 3, kOut = 4;
}  // namespace

TEST(graph_typed_ports_unconnected_inputs_read_silence_or_their_default_never_the_host) {
    // Only a node's first audio input reads the host. The sidechain and the modulation input read
    // silence, the control input its default (0.75).
    TypedModules m;
    Processor proc(m.proc);
    GraphExecutor executor;
    CHECK(executor.prepare({{"p", &m.proc}}, {}, {&proc}, 0, 16, 48000.0, kBudget) == GraphError::Ok);
    CHECK_EQ(executor.inputChannels(), 2u);
    Planar host(2, 16, 0.5f), out(2, 16, 9.0f);
    CHECK(executor.process(host.constView(16), out.view(16), 16));
    CHECK_EQ(out.data[0][3], 0.0f);  // in (0.5) x amount (silence) + side (silence) x 10, all x 0.75
    CHECK_EQ(out.data[1][15], 0.0f);
}

TEST(graph_typed_ports_carry_sidechain_modulation_and_control) {
    TypedModules m;
    ModSource lfoA(m.mod, 0), lfoB(m.mod, 300);
    OffsetGenerator side(m.mono, 7);
    ControlSource control(m.control, 0.25f);
    Processor proc(m.proc);
    // Nodes: 0 lfoA, 1 lfoB, 2 side, 3 control, 4 proc. Both LFOs sum on `amount`.
    const std::vector<GraphNode> nodes{{"a", &m.mod}, {"b", &m.mod}, {"side", &m.mono}, {"ctl", &m.control}, {"p", &m.proc}};
    const std::vector<GraphConnection> edges{{0, 0, 4, kAmount}, {1, 0, 4, kAmount}, {2, 0, 4, kSide}, {3, 0, 4, kLevel}};
    GraphExecutor executor;
    CHECK(executor.prepare(nodes, edges, {&lfoA, &lfoB, &side, &control, &proc}, 4, 32, 48000.0, kBudget) ==
          GraphError::Ok);
    Planar host(2, 32), out(2, 32);
    for (uint32_t c = 0; c < 2; ++c)
        for (uint32_t i = 0; i < 32; ++i) host.data[c][i] = signal(c, i + 50);
    for (int block = 0; block < 2; ++block) {  // the second block reads the held control value
        CHECK(executor.process(host.constView(32), out.view(32), 32));
        for (uint32_t c = 0; c < 2; ++c)
            for (uint32_t i = 0; i < 32; ++i) {
                float amount = 0.0f;
                amount += signal(0, i);
                amount += signal(0, i + 300);
                const float expected = (signal(c, i + 50) * amount + signal(0, i + 7) * 10.0f) * 0.25f;
                CHECK_EQ(out.data[c][i], expected);
            }
    }
}

TEST(graph_typed_control_output_starts_at_its_default) {
    // A control source that has not written yet reads as its port default (0.5), not 0.
    TypedModules m;
    class Silent final : public Typed {
    public:
        using Typed::Typed;
        bool processPorts(const ProcessBlock& b) noexcept override { return b.controlOutCount == 1; }
    } control(m.control);
    ModSource ones(m.mod, 0, 1.0f, true);
    Processor proc(m.proc);
    GraphExecutor executor;
    CHECK(executor.prepare({{"ctl", &m.control}, {"one", &m.mod}, {"p", &m.proc}},
                           {{0, 0, 2, kLevel}, {1, 0, 2, kAmount}}, {&control, &ones, &proc}, 2, 8, 48000.0, kBudget) ==
          GraphError::Ok);
    Planar host(2, 8, 2.0f), out(2, 8);
    CHECK(executor.process(host.constView(8), out.view(8), 8));
    CHECK_EQ(out.data[0][0], 1.0f);  // 2 x 1 x 0.5
}

TEST(graph_typed_modulation_sum_saturates_like_audio) {
    TypedModules m;
    ModSource inf(m.mod, 0, std::numeric_limits<float>::infinity(), true);
    ModSource nan(m.mod, 0, std::numeric_limits<float>::quiet_NaN(), true);
    Processor proc(m.proc);
    GraphExecutor executor;
    CHECK(executor.prepare({{"inf", &m.mod}, {"nan", &m.mod}, {"p", &m.proc}},
                           {{0, 0, 2, kAmount}, {1, 0, 2, kAmount}}, {&inf, &nan, &proc}, 2, 8, 48000.0, kBudget) ==
          GraphError::Ok);
    Planar host(2, 8, 1.0f), out(2, 8);
    CHECK(executor.process(host.constView(8), out.view(8), 8));
    CHECK_EQ(out.data[0][0], std::numeric_limits<float>::max() * 0.75f);  // inf -> FLT_MAX, NaN -> 0
}

TEST(graph_typed_ports_validate_types_defaults_and_fan_in) {
    TypedModules m;
    ModSource lfo(m.mod, 0);
    ControlSource a(m.control, 1.0f), b(m.control, 2.0f);
    OffsetGenerator mono(m.mono, 0);
    Processor proc(m.proc);
    GraphExecutor executor;
    // Modulation never feeds audio, and audio never feeds modulation: no implicit conversion.
    CHECK(executor.prepare({{"l", &m.mod}, {"p", &m.proc}}, {{0, 0, 1, kSide}}, {&lfo, &proc}, 1, 8, 48000.0, kBudget) ==
          GraphError::PortTypeMismatch);
    CHECK(executor.prepare({{"m", &m.mono}, {"p", &m.proc}}, {{0, 0, 1, kAmount}}, {&mono, &proc}, 1, 8, 48000.0, kBudget) ==
          GraphError::PortTypeMismatch);
    // A control input takes one source.
    CHECK(executor.prepare({{"a", &m.control}, {"b", &m.control}, {"p", &m.proc}}, {{0, 0, 2, kLevel}, {1, 0, 2, kLevel}},
                           {&a, &b, &proc}, 2, 8, 48000.0, kBudget) == GraphError::InputAlreadyConnected);
    // Event ports wait for F5.2, even on a processor that uses processPorts.
    const PortDescriptor eventPorts[] = {{"notes", PortType::Event, ChannelLayout::None, true},
                                         {"out", PortType::Audio, ChannelLayout::Stereo, false}};
    const ModuleDescriptor withEvents{"test.typed.events", 1, eventPorts, 2, nullptr, 0};
    Processor eventProc(withEvents);
    CHECK(executor.prepare({{"e", &withEvents}}, {}, {&eventProc}, 0, 8, 48000.0, kBudget) ==
          GraphError::RuntimeUnsupportedPortType);
    // Descriptor rules: only control ports have defaults (finite); only audio and modulation inputs sum.
    const PortDescriptor audioDefault[] = {{"out", PortType::Audio, ChannelLayout::Stereo, false, 0, false, 1.0f}};
    const PortDescriptor nanDefault[] = {{"c", PortType::Control, ChannelLayout::None, true, 0, false,
                                          std::numeric_limits<float>::quiet_NaN()}};
    const PortDescriptor summingControl[] = {{"c", PortType::Control, ChannelLayout::None, true, 0, true}};
    const PortDescriptor summingModOut[] = {{"m", PortType::Modulation, ChannelLayout::None, false, 0, true}};
    CHECK(validateModuleDescriptor({"x", 1, audioDefault, 1, nullptr, 0}) == ModuleValidation::InvalidPortDefault);
    CHECK(validateModuleDescriptor({"x", 1, nanDefault, 1, nullptr, 0}) == ModuleValidation::InvalidPortDefault);
    CHECK(validateModuleDescriptor({"x", 1, summingControl, 1, nullptr, 0}) == ModuleValidation::InvalidSummingPort);
    CHECK(validateModuleDescriptor({"x", 1, summingModOut, 1, nullptr, 0}) == ModuleValidation::InvalidSummingPort);
    CHECK(validateModuleDescriptor(m.proc) == ModuleValidation::Ok);
}

TEST(graph_typed_ports_process_without_allocating) {
    TypedModules m;
    ModSource lfoA(m.mod, 0), lfoB(m.mod, 300);
    OffsetGenerator side(m.mono, 7);
    ControlSource control(m.control, 0.25f);
    Processor proc(m.proc);
    GraphExecutor executor;
    CHECK(executor.prepare({{"a", &m.mod}, {"b", &m.mod}, {"side", &m.mono}, {"ctl", &m.control}, {"p", &m.proc}},
                           {{0, 0, 4, kAmount}, {1, 0, 4, kAmount}, {2, 0, 4, kSide}, {3, 0, 4, kLevel}},
                           {&lfoA, &lfoB, &side, &control, &proc}, 4, 64, 48000.0, kBudget) == GraphError::Ok);
    Planar host(2, 64, 0.5f), out(2, 64);
    bool ok = true;
    std::size_t operations = 0;
    {
        cawtest::AllocationScope scope;
        for (uint32_t frames : {64u, 17u, 1u, 64u}) ok = executor.process(host.constView(frames), out.view(frames), frames) && ok;
        operations = scope.count();
    }
    CHECK(ok);
    CHECK_EQ(operations, 0u);
}

TEST(graph_dynamic_routing_stays_audio_only_beside_typed_ports) {
    // Routing never targets modulation or control inputs; they keep their unconnected values.
    TypedModules m;
    ModSource lfo(m.mod, 0);
    OffsetGenerator mono(m.mono, 0);
    Processor proc(m.proc);
    GraphExecutor executor;
    CHECK(executor.prepare({{"l", &m.mod}, {"m", &m.mono}, {"p", &m.proc}}, {}, {&lfo, &mono, &proc}, 2, 16, 48000.0,
                           kBudget) == GraphError::Ok);
    CHECK(executor.reserveRouting(2, kBudget, true) == GraphError::Ok);
    const uint32_t order[] = {0, 1, 2};
    const GraphConnection intoModulation[] = {{0, 0, 2, kAmount}};
    const GraphConnection intoSidechain[] = {{1, 0, 2, kSide}};
    CHECK(!executor.setRouting(intoModulation, 1, order, 3));
    CHECK(executor.setRouting(intoSidechain, 1, order, 3));
    Planar out(2, 16, 9.0f);
    CHECK(executor.process(ConstChannelBufferView{}, out.view(16), 16));
    // in (routed: silence) x amount (silence) + side x 10, all x the 0.75 default
    CHECK_EQ(out.data[0][5], signal(0, 5) * 10.0f * 0.75f);
}

TEST(graph_reserve_routing_after_processing_drops_the_previous_host_buffer) {
    // A plain input that was host-fed, then made routable, must read silence, never the last
    // host buffer it was bound to (which the host may have freed).
    StereoRoutingModules m;
    Copy plain(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"plain", &m.plain}}, {}, {&plain}, 0, 16, 48000.0, kBudget) == GraphError::Ok);
    Planar host(2, 16, 0.5f), out(2, 16);
    CHECK(executor.process(host.constView(16), out.view(16), 16));
    CHECK_EQ(out.data[0][3], 0.5f);
    CHECK(executor.reserveRouting(1, kBudget, true) == GraphError::Ok);
    for (auto& channel : host.data) std::fill(channel.begin(), channel.end(), 0.9f);
    CHECK(executor.process(ConstChannelBufferView{}, out.view(16), 16));
    CHECK_EQ(out.data[0][3], 0.0f);
    CHECK_EQ(out.data[1][15], 0.0f);
}

TEST(graph_typed_control_values_saturate_like_routing) {
    // A held control value must not latch NaN or inf: NaN reads 0, inf reads FLT_MAX.
    TypedModules m;
    ControlSource nan(m.control, std::numeric_limits<float>::quiet_NaN());
    ControlSource inf(m.control, -std::numeric_limits<float>::infinity());
    ModSource ones(m.mod, 0, 1.0f, true);
    Processor a(m.proc), b(m.proc);
    for (int k = 0; k < 2; ++k) {
        GraphExecutor executor;
        ControlSource& source = k == 0 ? nan : inf;
        Processor& proc = k == 0 ? a : b;
        CHECK(executor.prepare({{"ctl", &m.control}, {"one", &m.mod}, {"p", &m.proc}},
                               {{0, 0, 2, kLevel}, {1, 0, 2, kAmount}}, {&source, &ones, &proc}, 2, 8, 48000.0, kBudget) ==
              GraphError::Ok);
        Planar host(2, 8, 1.0f), out(2, 8);
        CHECK(executor.process(host.constView(8), out.view(8), 8));
        CHECK_EQ(out.data[0][0], k == 0 ? 0.0f : -std::numeric_limits<float>::max());
    }
}
