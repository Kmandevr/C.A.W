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
