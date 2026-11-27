// Tests for the graph executor's fan-in (summing inputs) and dynamic routing between blocks.
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
            volatile float expected = 0.0f;  // in connection order, kept from reassociation (this file's flags)
            expected = expected + signal(ch, i + 2000);
            expected = expected + signal(ch, i);
            expected = expected + signal(ch, i + 1000);
            CHECK_EQ(out.data[ch][i], static_cast<float>(expected));
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
    CHECK(!signBit(out.data[0][0]));
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
    // Summed in connection order, through a volatile: this file builds with -fassociative-math, under which Clang
    // would otherwise vectorize the sum in another order.
    volatile float expected = 0.0f;
    for (uint32_t i = 0; i < sources; ++i) expected = expected + signal(0, 3 + i);
    CHECK_EQ(out.data[0][3], static_cast<float>(expected));
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
        ok = std::bit_cast<uint32_t>(out.data[0][0]) == std::bit_cast<uint32_t>(routed[0][0]) && signBit(out.data[0][0]) && ok;
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
            CHECK_EQ(std::bit_cast<uint32_t>(routed[c][i]), std::bit_cast<uint32_t>(v[(i + c) % 4]));
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
