// Tests for the graph's parameters: queued values, modulation links, automation lanes and CC mappings.
#include "test.h"

#include "alloc_counter.h"
#include "graph.h"

#include <algorithm>
#include <bit>
#include <cstdint>
#include <cmath>
#include <limits>
#include <memory>
#include <string>
#include <vector>

#include "graph_channels_harness.h"

using namespace caw;
using namespace graph_channels_test;

namespace {
// F6.2 parameters: a gain whose `gain` parameter scales its input, per frame when it varies.
class ParamGain final : public ModuleProcessor {
public:
    explicit ParamGain(const ModuleDescriptor& d, bool typed = false) : d_(d), typed_(typed) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool usesProcessPorts() const noexcept override { return typed_; }
    bool process(const AudioProcessBlock& b) noexcept override {
        if (b.parameterCount != 1) return false;
        apply(b.input, b.output, b.frames, b.parameters[0]);
        return true;
    }
    bool processPorts(const ProcessBlock& b) noexcept override {
        if (b.parameterCount != 1 || b.audioInCount != 1 || b.audioOutCount != 1) return false;
        apply(b.audioIn[0], b.audioOut[0], b.frames, b.parameters[0]);
        return true;
    }
    uint32_t variedBlocks = 0;
private:
    void apply(const ConstChannelBufferView& in, const ChannelBufferView& out, uint32_t frames,
               const ParameterValue& gain) noexcept {
        if (gain.samples) ++variedBlocks;
        for (uint32_t c = 0; c < out.channelCount; ++c)
            for (uint32_t i = 0; i < frames; ++i)
                out.channels[c][i] = in.channels[c][i] * static_cast<float>(gain.samples ? gain.samples[i] : gain.value);
    }
    const ModuleDescriptor& d_;
    bool typed_;
};

struct ParamModules {
    explicit ParamModules(uint32_t smoothing = 0) {
        gain.id = "gain";
        gain.defaultValue = 0.5;
        gain.minimum = 0.0;
        gain.maximum = 2.0;
        gain.smoothingFrames = smoothing;
    }
    PortDescriptor ports[2] = {{"in", PortType::Audio, ChannelLayout::Stereo, true},
                               {"out", PortType::Audio, ChannelLayout::Stereo, false}};
    PortDescriptor typedPorts[3] = {{"in", PortType::Audio, ChannelLayout::Stereo, true},
                                    {"lfo", PortType::Modulation, ChannelLayout::None, true},
                                    {"out", PortType::Audio, ChannelLayout::Stereo, false}};
    ParameterDescriptor gain;
    ModuleDescriptor plain{"test.param.gain", 1, ports, 2, &gain, 1};
    ModuleDescriptor typed{"test.param.typed", 1, typedPorts, 3, &gain, 1};
};
}  // namespace

TEST(graph_parameters_start_at_their_defaults_on_both_process_paths) {
    ParamModules m;
    ParamGain plain(m.plain), typed(m.typed, true);
    for (int k = 0; k < 2; ++k) {
        GraphExecutor executor;
        CHECK(executor.prepare({{"g", k ? &m.typed : &m.plain}}, {}, {k ? static_cast<ModuleProcessor*>(&typed) : &plain}, 0,
                               16, 48000.0, kBudget) == GraphError::Ok);
        Planar host(2, 16, 0.5f), out(2, 16);
        CHECK(executor.process(host.constView(16), out.view(16), 16));
        CHECK_EQ(out.data[0][3], 0.25f);
        CHECK_EQ(out.data[1][15], 0.25f);
    }
}

TEST(graph_parameters_queued_values_apply_at_the_next_block_and_smooth) {
    ParamModules m(4);
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
    Planar host(2, 8, 1.0f), out(2, 8);
    CHECK(executor.queueParameter(0, 0, 1.5));
    CHECK(executor.process(host.constView(8), out.view(8), 8));
    // 0.5 -> 1.5 over 4 frames, then held.
    const float expected[] = {0.75f, 1.0f, 1.25f, 1.5f, 1.5f, 1.5f, 1.5f, 1.5f};
    for (uint32_t i = 0; i < 8; ++i) CHECK_EQ(out.data[0][i], expected[i]);
    CHECK_EQ(gain.variedBlocks, 1u);
    CHECK(executor.process(host.constView(8), out.view(8), 8));
    CHECK_EQ(gain.variedBlocks, 1u);  // settled: one constant value again
    CHECK_EQ(out.data[1][0], 1.5f);
    CHECK_EQ(executor.parameterTarget(0, 0), 1.5);
    // Queue order is application order; values are clamped to the range.
    CHECK(executor.queueParameter(0, 0, 0.25));
    CHECK(executor.queueParameter(0, 0, 9.0));
    CHECK(executor.queueClearTouch());
    CHECK(executor.process(host.constView(8), out.view(8), 8));
    CHECK_EQ(executor.parameterTarget(0, 0), 2.0);
}

TEST(graph_parameters_reject_bad_commands_and_a_full_queue) {
    ParamModules m;
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(!executor.queueParameter(0, 0, 1.0));  // not prepared
    CHECK(!executor.queueClearTouch());
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
    CHECK(!executor.queueParameter(1, 0, 1.0));
    CHECK(!executor.queueParameter(0, 1, 1.0));
    CHECK(!executor.queueParameter(0, 0, std::numeric_limits<double>::quiet_NaN()));
    CHECK(!executor.queueParameter(0, 0, std::numeric_limits<double>::infinity()));
    for (std::size_t k = 0; k < GraphExecutor::kParameterQueueCapacity; ++k) CHECK(executor.queueParameter(0, 0, 1.0));
    CHECK(!executor.queueParameter(0, 0, 2.0));  // full: refused, never blocks
    Planar host(2, 8, 1.0f), out(2, 8);
    CHECK(executor.process(host.constView(8), out.view(8), 8));  // drains every command
    CHECK_EQ(out.data[0][0], 1.0f);
    CHECK(executor.queueParameter(0, 0, 2.0));
}

TEST(graph_parameters_prepare_drops_commands_meant_for_the_previous_graph) {
    ParamModules m;
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
    CHECK(executor.queueParameter(0, 0, 2.0));
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
    Planar host(2, 8, 1.0f), out(2, 8);
    CHECK(executor.process(host.constView(8), out.view(8), 8));
    CHECK_EQ(out.data[0][0], 0.5f);  // the default, not the stale 2.0
}

TEST(graph_parameters_count_in_the_working_memory_budget) {
    ParamModules m;
    ParamGain gain(m.plain);
    GraphExecutor executor;
    GraphResourceBudget fits = kBudget;
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 1u << 16, 48000.0, fits) == GraphError::Ok);
    // A budget that holds the audio buffers but not the 2^20 x 8-byte parameter buffer as well.
    GraphResourceBudget tight = kBudget;
    tight.maxWorkingBytes = (1u << 20) * 4u * sizeof(float) + (1u << 20) * sizeof(double) / 2u;
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 1u << 20, 48000.0, tight) ==
          GraphError::ResourceBudgetExceeded);
}

TEST(graph_parameters_resolve_and_apply_commands_without_allocating) {
    ParamModules m(16);
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 64, 48000.0, kBudget) == GraphError::Ok);
    Planar host(2, 64, 1.0f), out(2, 64);
    bool ok = true;
    std::size_t operations = 0;
    {
        cawtest::AllocationScope scope;
        for (uint32_t frames : {64u, 17u, 1u, 64u}) {
            ok = executor.queueParameter(0, 0, frames / 64.0) && ok;
            ok = executor.queueClearTouch() && ok;
            ok = executor.process(host.constView(frames), out.view(frames), frames) && ok;
        }
        operations = scope.count();
    }
    CHECK(ok);
    CHECK_EQ(operations, 0u);
}

TEST(graph_parameters_initial_values_survive_a_re_prepare_without_a_ramp_or_a_touch) {
    // A rebuild restores the user's values directly: no ramp from the default, and not a touch
    // (which would block automation until playback restarts).
    ParamModules m(4);
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
    CHECK(executor.setInitialParameter(0, 0, 1.5));
    CHECK(!executor.setInitialParameter(0, 1, 1.5));
    CHECK(!executor.setInitialParameter(0, 0, std::numeric_limits<double>::quiet_NaN()));
    CHECK(!executor.parameterTouched(0, 0));
    Planar host(2, 8, 1.0f), out(2, 8);
    CHECK(executor.process(host.constView(8), out.view(8), 8));
    CHECK_EQ(out.data[0][0], 1.5f);
    CHECK_EQ(gain.variedBlocks, 0u);
}

TEST(graph_parameters_clear_touch_keeps_queue_order) {
    // A set after a clear touches again; a clear after a set ends that touch.
    ParamModules m;
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"g", &m.plain}, {"h", &m.plain}}, {{0, 1, 1, 0}}, {&gain, &gain}, 1, 8, 48000.0, kBudget) ==
          GraphError::Ok);
    Planar host(2, 8, 1.0f), out(2, 8);
    CHECK(executor.queueParameter(0, 0, 1.0));
    CHECK(executor.queueParameter(1, 0, 1.0));
    CHECK(executor.queueClearTouch());
    CHECK(executor.queueParameter(1, 0, 1.25));
    CHECK(executor.process(host.constView(8), out.view(8), 8));
    CHECK(!executor.parameterTouched(0, 0));
    CHECK(executor.parameterTouched(1, 0));
    for (int k = 0; k < 3; ++k) CHECK(executor.queueClearTouch());
    CHECK(executor.process(host.constView(8), out.view(8), 8));
    CHECK(!executor.parameterTouched(1, 0));
}

namespace {
// F6.3 modulation links: modulation sources (TypedModules::mod, one output) into ParamGain's gain.
struct LinkGraph {
    TypedModules t;
    ParamModules m;
};
float run(GraphExecutor& executor, uint32_t frames, uint32_t frame) {
    Planar host(2, frames, 1.0f), out(2, frames);
    if (!executor.process(host.constView(frames), out.view(frames), frames)) return -1.0f;
    return out.data[0][frame];
}
}  // namespace

TEST(graph_modulation_links_drive_a_parameter_per_frame_like_the_resolver) {
    LinkGraph g;
    ModSource lfo(g.t.mod, 0);
    ParamGain gain(g.m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"lfo", &g.t.mod}, {"g", &g.m.plain}}, {}, {&lfo, &gain}, 1, 32, 48000.0, kBudget) ==
          GraphError::Ok);
    const ParameterLink link{7, 0, 0, 1, 0, ModulationOp::Add, 0.25};
    CHECK(executor.setModulationLinks(&link, 1) == GraphError::Ok);
    Planar host(2, 32, 1.0f), out(2, 32);
    CHECK(executor.process(host.constView(32), out.view(32), 32));
    // The same parameter through a standalone resolver gives the same per-frame values.
    ParameterResolver reference;
    CHECK(reference.configure(g.m.gain));
    const ModulationLink same{7, ModulationOp::Add, 0.25};
    CHECK(reference.setLinks(&same, 1));
    float signalBuffer[32];
    for (uint32_t i = 0; i < 32; ++i) signalBuffer[i] = signal(0, i);
    const float* signals[] = {signalBuffer};
    double expected[32];
    reference.resolve(32, nullptr, signals, expected);
    for (uint32_t i = 0; i < 32; ++i) CHECK_EQ(out.data[0][i], static_cast<float>(expected[i]));
    CHECK(gain.variedBlocks == 1u);
    // No links: back to the plain manual value.
    CHECK(executor.setModulationLinks(nullptr, 0) == GraphError::Ok);
    CHECK_EQ(run(executor, 32, 5), 0.5f);
}

TEST(graph_modulation_links_give_the_same_output_whatever_the_list_or_node_order) {
    // Add 0.5 (id 1) then Replace by 0.5 (id 2): the order matters, so only id order may decide it.
    LinkGraph g;
    ModSource a(g.t.mod, 0, 0.5f, true), b(g.t.mod, 0, 1.0f, true);
    ParamGain gain(g.m.plain);
    float results[4];
    for (int k = 0; k < 4; ++k) {
        const bool swapNodes = k & 1, swapList = k & 2;
        // Nodes: two sources (in either order) then the gain.
        const uint32_t na = swapNodes ? 1 : 0, nb = swapNodes ? 0 : 1;
        std::vector<GraphNode> nodes(3);
        std::vector<ModuleProcessor*> processors(3);
        nodes[na] = {"a", &g.t.mod};
        nodes[nb] = {"b", &g.t.mod};
        nodes[2] = {"g", &g.m.plain};
        processors[na] = &a;
        processors[nb] = &b;
        processors[2] = &gain;
        GraphExecutor executor;
        CHECK(executor.prepare(nodes, {}, processors, 2, 8, 48000.0, kBudget) == GraphError::Ok);
        const ParameterLink add{1, na, 0, 2, 0, ModulationOp::Add, 0.5};
        const ParameterLink replace{2, nb, 0, 2, 0, ModulationOp::Replace, 0.5};
        const ParameterLink list[] = {swapList ? replace : add, swapList ? add : replace};
        CHECK(executor.setModulationLinks(list, 2) == GraphError::Ok);
        results[k] = run(executor, 8, 3);
    }
    // gain 0.5 of 0..2 -> n 0.25; + 0.5 * 0.5 -> 0.5; Replace by 0.5 toward 1 -> 0.75; x 2 = 1.5.
    CHECK_EQ(results[0], 1.5f);
    for (int k = 1; k < 4; ++k) CHECK_EQ(results[k], results[0]);
}

TEST(graph_modulation_links_reject_bad_links_and_keep_the_previous_ones) {
    LinkGraph g;
    ModSource lfo(g.t.mod, 0, 1.0f, true);
    OffsetGenerator mono(g.t.mono, 0);
    ParamGain gain(g.m.plain);
    ParamGain after(g.m.plain);
    GraphExecutor executor;
    // Nodes: 0 lfo, 1 gain, 2 mono generator, 3 a second gain fed by the first.
    CHECK(executor.prepare({{"lfo", &g.t.mod}, {"g", &g.m.plain}, {"mono", &g.t.mono}, {"h", &g.m.plain}}, {{1, 1, 3, 0}},
                           {&lfo, &gain, &mono, &after}, 3, 8, 48000.0, kBudget) == GraphError::Ok);
    const ParameterLink good{1, 0, 0, 3, 0, ModulationOp::Replace, 1.0};
    CHECK(executor.setModulationLinks(&good, 1) == GraphError::Ok);
    CHECK_EQ(run(executor, 8, 0), 0.5f * 2.0f);  // first gain 0.5; second replaced to the top (2.0)
    const ParameterLink outOfRange{1, 9, 0, 3, 0, ModulationOp::Add, 0.1};
    const ParameterLink badPort{1, 0, 5, 3, 0, ModulationOp::Add, 0.1};
    const ParameterLink badParameter{1, 0, 0, 3, 1, ModulationOp::Add, 0.1};
    const ParameterLink audioSource{1, 2, 0, 3, 0, ModulationOp::Add, 0.1};
    const ParameterLink backwards{1, 3, 0, 1, 0, ModulationOp::Add, 0.1};  // node 3 has no modulation output either
    const ParameterLink deep{1, 0, 0, 3, 0, ModulationOp::Add, 2.0};
    const ParameterLink twice[] = {{4, 0, 0, 3, 0, ModulationOp::Add, 0.1}, {4, 0, 0, 3, 0, ModulationOp::Max, 0.1}};
    CHECK(executor.setModulationLinks(&outOfRange, 1) == GraphError::NodeIndexOutOfRange);
    CHECK(executor.setModulationLinks(&badPort, 1) == GraphError::PortIndexOutOfRange);
    CHECK(executor.setModulationLinks(&badParameter, 1) == GraphError::PortIndexOutOfRange);
    CHECK(executor.setModulationLinks(&audioSource, 1) == GraphError::PortTypeMismatch);
    CHECK(executor.setModulationLinks(&deep, 1) == GraphError::InvalidParameterLink);
    CHECK(executor.setModulationLinks(twice, 2) == GraphError::InvalidParameterLink);
    CHECK(executor.setModulationLinks(nullptr, 1) == GraphError::InvalidParameterLink);
    ParameterLink many[kMaxParameterLinks + 1];
    for (uint32_t k = 0; k <= kMaxParameterLinks; ++k) many[k] = {k, 0, 0, 3, 0, ModulationOp::Add, 0.0};
    CHECK(executor.setModulationLinks(many, kMaxParameterLinks + 1) == GraphError::InvalidParameterLink);
    CHECK(executor.setModulationLinks(&backwards, 1) == GraphError::PortTypeMismatch);
    CHECK_EQ(run(executor, 8, 0), 0.5f * 2.0f);  // the good link still holds
    // A source that runs after its destination: build the order with the gain first.
    GraphExecutor late;
    CHECK(late.prepare({{"g", &g.m.plain}, {"lfo", &g.t.mod}}, {}, {&gain, &lfo}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
    const ParameterLink fromLater{1, 1, 0, 0, 0, ModulationOp::Add, 0.1};
    CHECK(late.setModulationLinks(&fromLater, 1) == GraphError::Cycle);
    // Not with dynamic routing, whose order can change.
    GraphExecutor routed;
    CHECK(routed.prepare({{"lfo", &g.t.mod}, {"g", &g.m.plain}}, {}, {&lfo, &gain}, 1, 8, 48000.0, kBudget) == GraphError::Ok);
    CHECK(routed.reserveRouting(1, kBudget) == GraphError::Ok);
    const ParameterLink link{1, 0, 0, 1, 0, ModulationOp::Add, 0.1};
    CHECK(routed.setModulationLinks(&link, 1) == GraphError::RoutingUnavailable);
    GraphExecutor unprepared;
    CHECK(unprepared.setModulationLinks(&link, 1) != GraphError::Ok);
}

TEST(graph_modulation_links_process_without_allocating) {
    LinkGraph g;
    ModSource a(g.t.mod, 0), b(g.t.mod, 100);
    ParamGain gain(g.m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"a", &g.t.mod}, {"b", &g.t.mod}, {"g", &g.m.plain}}, {}, {&a, &b, &gain}, 2, 64, 48000.0,
                           kBudget) == GraphError::Ok);
    const ParameterLink links[] = {{1, 0, 0, 2, 0, ModulationOp::Add, 0.3}, {2, 1, 0, 2, 0, ModulationOp::Multiply, 0.5}};
    CHECK(executor.setModulationLinks(links, 2) == GraphError::Ok);
    Planar host(2, 64, 1.0f), out(2, 64);
    bool ok = true;
    std::size_t operations = 0;
    {
        cawtest::AllocationScope scope;
        for (uint32_t frames : {64u, 17u, 1u, 64u}) {
            ok = executor.queueParameter(2, 0, 0.75) && ok;
            ok = executor.process(host.constView(frames), out.view(frames), frames) && ok;
        }
        operations = scope.count();
    }
    CHECK(ok);
    CHECK_EQ(operations, 0u);
}

TEST(graph_reserve_routing_refuses_while_modulation_links_are_set) {
    // Routing can reorder or skip nodes, so a live link could read a source that ran late or not
    // at all: reserving routing must fail closed while links exist, and work again once cleared.
    LinkGraph g;
    ModSource lfo(g.t.mod, 0, 1.0f, true);
    ParamGain gain(g.m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"lfo", &g.t.mod}, {"g", &g.m.plain}}, {}, {&lfo, &gain}, 1, 8, 48000.0, kBudget) ==
          GraphError::Ok);
    const ParameterLink link{1, 0, 0, 1, 0, ModulationOp::Add, 0.25};
    CHECK(executor.setModulationLinks(&link, 1) == GraphError::Ok);
    CHECK(executor.reserveRouting(1, kBudget) == GraphError::RoutingUnavailable);
    CHECK_EQ(run(executor, 8, 0), 1.0f);  // the links still hold
    CHECK(executor.setModulationLinks(nullptr, 0) == GraphError::Ok);
    CHECK(executor.reserveRouting(1, kBudget) == GraphError::Ok);
}

namespace {
// F6.4 automation lanes: a ramp 0 -> 2 over steps 0..4, a jump at step 6 (two points), then 0.25.
const AutomationPoint kLane[] = {{0.0, 0.0}, {4.0, 2.0}, {6.0, 2.0}, {6.0, 0.25}};
// What the Engine computes for frame i of a block starting at `start`: lane value, then constrained.
double engineValue(const ParameterDescriptor& p, int64_t start, uint32_t i, double samplesPerStep) {
    const double at = static_cast<double>(start + i) / samplesPerStep;
    return constrainParameter(p, automationLaneValue(kLane, 4, at, kLane[0].value));
}
}  // namespace

TEST(graph_automation_lanes_match_the_engine_sample_for_sample_across_blocks_and_seeks) {
    ParamModules m;
    m.gain.step = 0.125;  // quantized, like a .caw param with a step
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 16, 48000.0, kBudget) == GraphError::Ok);
    const ParameterLane lane{0, 0, kLane, 4};
    CHECK(executor.setAutomationLanes(&lane, 1) == GraphError::Ok);
    const double samplesPerStep = 5.5;
    CHECK(executor.setTransport(3, samplesPerStep, true));
    int64_t start = 3;
    Planar host(2, 16, 1.0f), out(2, 16);
    for (int block = 0; block < 4; ++block) {
        if (block == 2) {  // a seek
            CHECK(executor.setTransport(30, samplesPerStep, true));
            start = 30;
        }
        const uint32_t frames = block == 1 ? 7 : 16;
        CHECK(executor.process(host.constView(frames), out.view(frames), frames));
        for (uint32_t i = 0; i < frames; ++i)
            CHECK_EQ(out.data[0][i], static_cast<float>(engineValue(m.gain, start, i, samplesPerStep)));
        start += frames;
    }
}

TEST(graph_automation_lanes_apply_only_while_playing_and_yield_to_a_touch) {
    ParamModules m;
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
    const ParameterLane lane{0, 0, kLane + 3, 1};  // a flat 0.25
    CHECK(executor.setAutomationLanes(&lane, 1) == GraphError::Ok);
    CHECK_EQ(run(executor, 8, 0), 0.5f);  // stopped: the manual default
    CHECK(executor.setTransport(0, 10.0, true));
    CHECK_EQ(run(executor, 8, 0), 0.25f);
    CHECK(executor.queueParameter(0, 0, 1.5));  // a touch wins while the lane plays on
    CHECK_EQ(run(executor, 8, 0), 1.5f);
    CHECK(executor.queueClearTouch());  // playback restart: the lane again
    CHECK_EQ(run(executor, 8, 0), 0.25f);
    CHECK(!executor.setTransport(int64_t{1} << 53, 10.0, true));  // past exact doubles: refused
    CHECK_EQ(run(executor, 8, 0), 0.25f);  // lanes off, the last played value held
    CHECK(!executor.setTransport(-(int64_t{1} << 53), 10.0, true));
    CHECK(executor.setTransport(GraphExecutor::kMaxTransportSample - 4, 10.0, true));
    CHECK_EQ(run(executor, 8, 0), 0.25f);  // a block at the limit stops the lanes (no overflow)
    CHECK(executor.setTransport(0, 10.0, true));
    CHECK(!executor.setTransport(0, 0.0, true));  // a bad tempo stops lanes
    CHECK_EQ(run(executor, 8, 0), 0.25f);  // stopping holds what played, no jump
    CHECK_EQ(executor.parameterTarget(0, 0), 0.25);
    CHECK(executor.setAutomationLanes(nullptr, 0) == GraphError::Ok);
    CHECK(executor.setTransport(0, 10.0, true));
    CHECK(executor.queueParameter(0, 0, 1.5));
    CHECK_EQ(run(executor, 8, 0), 1.5f);  // no lane: the manual value
}

TEST(graph_automation_lanes_reject_bad_lanes_and_keep_the_previous_ones) {
    ParamModules m;
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(executor.setAutomationLanes(nullptr, 0) != GraphError::Ok);  // not prepared
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
    const ParameterLane good{0, 0, kLane + 3, 1};
    CHECK(executor.setAutomationLanes(&good, 1) == GraphError::Ok);
    const AutomationPoint unsorted[] = {{2.0, 0.1}, {1.0, 0.2}};
    const AutomationPoint nan[] = {{0.0, std::numeric_limits<double>::quiet_NaN()}};
    const ParameterLane badNode{1, 0, kLane, 4}, badParameter{0, 1, kLane, 4}, empty{0, 0, kLane, 0},
        noPoints{0, 0, nullptr, 2}, backwards{0, 0, unsorted, 2}, notFinite{0, 0, nan, 1};
    const ParameterLane twice[] = {{0, 0, kLane, 4}, {0, 0, kLane, 4}};
    CHECK(executor.setAutomationLanes(&badNode, 1) == GraphError::NodeIndexOutOfRange);
    CHECK(executor.setAutomationLanes(&badParameter, 1) == GraphError::PortIndexOutOfRange);
    for (const ParameterLane* bad : {&empty, &noPoints, &backwards, &notFinite})
        CHECK(executor.setAutomationLanes(bad, 1) == GraphError::InvalidAutomationLane);
    CHECK(executor.setAutomationLanes(twice, 2) == GraphError::InvalidAutomationLane);
    CHECK(executor.setAutomationLanes(nullptr, 1) == GraphError::InvalidAutomationLane);
    CHECK(executor.setTransport(0, 10.0, true));
    CHECK_EQ(run(executor, 8, 0), 0.25f);  // the good lane still holds
}

TEST(graph_automation_lanes_resolve_without_allocating) {
    ParamModules m;
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 64, 48000.0, kBudget) == GraphError::Ok);
    const ParameterLane lane{0, 0, kLane, 4};
    CHECK(executor.setAutomationLanes(&lane, 1) == GraphError::Ok);
    Planar host(2, 64, 1.0f), out(2, 64);
    bool ok = true;
    std::size_t operations = 0;
    {
        cawtest::AllocationScope scope;
        ok = executor.setTransport(0, 12.0, true);
        for (uint32_t frames : {64u, 17u, 1u, 64u}) ok = executor.process(host.constView(frames), out.view(frames), frames) && ok;
        operations = scope.count();
    }
    CHECK(ok);
    CHECK_EQ(operations, 0u);
}

namespace {
// F6.5: a host MIDI event holding one UMP.
Event umpEvent(uint32_t frame, uint32_t w0, uint32_t w1 = 0) {
    Event e;
    e.frame = frame;
    e.kind = EventKind::Midi;
    e.data[0] = w0;
    e.data[1] = w1;
    return e;
}
std::vector<float> runEvents(GraphExecutor& executor, uint32_t frames, const Event* events, uint32_t count) {
    Planar host(2, frames, 1.0f), out(2, frames);
    if (!executor.process(host.constView(frames), out.view(frames), frames, EventInput{events, count})) return {};
    return std::vector<float>(out.data[0].begin(), out.data[0].begin() + frames);
}
}  // namespace

TEST(graph_cc_mappings_set_the_base_at_the_event_frame) {
    ParamModules m;
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 16, 48000.0, kBudget) == GraphError::Ok);
    const ParameterCcMapping mapping{0, 0, 0, 2, 74};  // group 0, channel 2, CC 74
    CHECK(executor.setCcMappings(&mapping, 1) == GraphError::Ok);
    const Event events[] = {
        umpEvent(3, 0x20B24A7Fu),               // MIDI 1.0 CC 74 = 127: the maximum, 2.0
        umpEvent(5, 0x20B34A00u),               // another channel: ignored
        umpEvent(5, 0x20B2077Fu),               // another controller: ignored
        umpEvent(8, 0x40B24A00u, 0x80000000u),  // MIDI 2.0 CC 74, about half: 1.0000000002
        umpEvent(8, 0x20924A7Fu),               // a note-on: ignored
    };
    const std::vector<float> out = runEvents(executor, 12, events, 5);
    CHECK_EQ(out.size(), 12u);
    const float half = static_cast<float>(2.0 * (0x80000000u / 4294967295.0));
    for (uint32_t i = 0; i < 12; ++i) CHECK_EQ(out[i], i < 3 ? 0.5f : i < 8 ? 2.0f : half);
    CHECK_EQ(run(executor, 8, 7), half);  // the base stays after the block
    CHECK(gain.variedBlocks == 1u);       // a block without CCs is one constant again
}

TEST(graph_cc_mappings_follow_the_curve_smooth_and_drive_several_parameters) {
    ParamModules m(4);  // 4 frames of smoothing
    ParamGain first(m.plain), second(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"a", &m.plain}, {"b", &m.plain}}, {{0, 1, 1, 0}}, {&first, &second}, 1, 16, 48000.0,
                           kBudget) == GraphError::Ok);
    const ParameterCcMapping both[] = {{0, 0, 1, 0, 7}, {1, 0, 1, 0, 7}};  // one CC, two parameters
    CHECK(executor.setCcMappings(both, 2) == GraphError::Ok);
    const Event cc[] = {umpEvent(2, 0x21B0077Fu)};  // group 1, channel 0, CC 7 = 127
    const std::vector<float> out = runEvents(executor, 8, cc, 1);
    CHECK_EQ(out.size(), 8u);
    // Each gain ramps 0.5 -> 2.0 over 4 frames from frame 2; the output is their product.
    const double g[8] = {0.5, 0.5, 0.875, 1.25, 1.625, 2.0, 2.0, 2.0};
    for (uint32_t i = 0; i < 8; ++i) CHECK_EQ(out[i], static_cast<float>(g[i]) * static_cast<float>(g[i]));
}

TEST(graph_cc_mappings_are_a_touch_over_automation) {
    ParamModules m;
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
    const AutomationPoint flat[] = {{0.0, 0.25}};
    const ParameterLane lane{0, 0, flat, 1};
    const ParameterCcMapping mapping{0, 0, 0, 0, 1};
    CHECK(executor.setAutomationLanes(&lane, 1) == GraphError::Ok);
    CHECK(executor.setCcMappings(&mapping, 1) == GraphError::Ok);
    CHECK(executor.setTransport(0, 10.0, true));
    const Event cc[] = {umpEvent(4, 0x20B0017Fu)};
    const std::vector<float> out = runEvents(executor, 8, cc, 1);
    CHECK_EQ(out.size(), 8u);
    CHECK_EQ(out[3], 0.25f);
    CHECK_EQ(out[4], 2.0f);  // the CC wins from its frame on
    CHECK_EQ(run(executor, 8, 0), 2.0f);
    CHECK(executor.queueClearTouch());  // playback restart: the lane again
    CHECK_EQ(run(executor, 8, 0), 0.25f);
}

TEST(graph_cc_mappings_reject_bad_mappings_and_keep_the_previous_ones) {
    ParamModules m;
    ParamGain gain(m.plain);
    GraphExecutor executor;
    const ParameterCcMapping good{0, 0, 0, 0, 1};
    CHECK(executor.setCcMappings(&good, 1) == GraphError::InvalidOutputNode);  // not prepared
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
    CHECK(executor.setCcMappings(&good, 1) == GraphError::Ok);
    const ParameterCcMapping badNode{1, 0, 0, 0, 1}, badParameter{0, 1, 0, 0, 1}, badGroup{0, 0, 16, 0, 1},
        badChannel{0, 0, 0, 16, 1}, badController{0, 0, 0, 0, 128};
    const ParameterCcMapping twice[] = {{0, 0, 0, 0, 1}, {0, 0, 0, 0, 2}};
    CHECK(executor.setCcMappings(&badNode, 1) == GraphError::NodeIndexOutOfRange);
    CHECK(executor.setCcMappings(&badParameter, 1) == GraphError::PortIndexOutOfRange);
    for (const ParameterCcMapping* bad : {&badGroup, &badChannel, &badController})
        CHECK(executor.setCcMappings(bad, 1) == GraphError::InvalidCcMapping);
    CHECK(executor.setCcMappings(twice, 2) == GraphError::InvalidCcMapping);
    CHECK(executor.setCcMappings(nullptr, 1) == GraphError::InvalidCcMapping);
    const Event cc[] = {umpEvent(0, 0x20B0017Fu)};
    CHECK_EQ(runEvents(executor, 8, cc, 1).at(0), 2.0f);  // the good mapping still holds
    CHECK(executor.setCcMappings(nullptr, 0) == GraphError::Ok);
    const Event low[] = {umpEvent(0, 0x20B00100u)};
    CHECK_EQ(runEvents(executor, 8, low, 1).at(0), 2.0f);  // unmapped: no change
}

TEST(graph_cc_mappings_resolve_without_allocating) {
    ParamModules m(3);
    ParamGain gain(m.plain);
    GraphExecutor executor;
    CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 64, 48000.0, kBudget) == GraphError::Ok);
    const ParameterCcMapping mapping{0, 0, 0, 0, 1};
    CHECK(executor.setCcMappings(&mapping, 1) == GraphError::Ok);
    const Event events[] = {umpEvent(0, 0x20B00110u), umpEvent(10, 0x20B00170u), umpEvent(10, 0x40B00100u, 7u),
                            umpEvent(63, 0x20B0017Fu)};
    Planar host(2, 64, 1.0f), out(2, 64);
    bool ok = true;
    std::size_t operations = 0;
    {
        cawtest::AllocationScope scope;
        for (uint32_t block = 0; block < 4; ++block)
            ok = executor.process(host.constView(64), out.view(64), 64, EventInput{events, 4}) && ok;
        operations = scope.count();
    }
    CHECK(ok);
    CHECK_EQ(operations, 0u);
}

TEST(graph_refuses_modulation_automation_or_cc_a_parameter_does_not_allow) {
    // CP.2: one parameter definition carries its capability flags; the executor enforces them.
    {
        LinkGraph g;
        g.m.gain.modulatable = false;
        ModSource lfo(g.t.mod, 0, 1.0f, true);
        OffsetGenerator mono(g.t.mono, 0);
        ParamGain gain(g.m.plain), after(g.m.plain);
        GraphExecutor executor;
        CHECK(executor.prepare({{"lfo", &g.t.mod}, {"g", &g.m.plain}, {"mono", &g.t.mono}, {"h", &g.m.plain}},
                               {{1, 1, 3, 0}}, {&lfo, &gain, &mono, &after}, 3, 8, 48000.0, kBudget) == GraphError::Ok);
        const ParameterLink link{1, 0, 0, 3, 0, ModulationOp::Replace, 1.0};
        CHECK(executor.setModulationLinks(&link, 1) == GraphError::ParameterNotModulatable);
        CHECK_EQ(run(executor, 8, 0), 0.5f * 0.5f);  // nothing changed: both gains at their default
    }
    const AutomationPoint flat[] = {{0.0, 0.25}};
    const ParameterLane lane{0, 0, flat, 1};
    const ParameterCcMapping mapping{0, 0, 0, 0, 1};
    {
        ParamModules m;
        m.gain.automatable = false;
        ParamGain gain(m.plain);
        GraphExecutor executor;
        CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
        CHECK(executor.setAutomationLanes(&lane, 1) == GraphError::ParameterNotAutomatable);
        CHECK(executor.setCcMappings(&mapping, 1) == GraphError::Ok);  // only automation is refused
    }
    {
        ParamModules m;
        m.gain.midiMappable = false;
        ParamGain gain(m.plain);
        GraphExecutor executor;
        CHECK(executor.prepare({{"g", &m.plain}}, {}, {&gain}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
        CHECK(executor.setCcMappings(&mapping, 1) == GraphError::ParameterNotMidiMappable);
        CHECK(executor.setAutomationLanes(&lane, 1) == GraphError::Ok);
        const Event cc[] = {umpEvent(0, 0x20B0017Fu)};
        CHECK_EQ(runEvents(executor, 8, cc, 1).at(0), 0.5f);  // the CC has no effect
    }
}
