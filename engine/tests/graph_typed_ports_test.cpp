// Tests for the graph's typed ports: sidechain, modulation and control ports, and event ports.
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
    // Event ports, like every typed port, need a processor that uses processPorts.
    const PortDescriptor eventPorts[] = {{"notes", PortType::Event, ChannelLayout::None, true},
                                         {"out", PortType::Audio, ChannelLayout::Stereo, false}};
    const ModuleDescriptor withEvents{"test.typed.events", 1, eventPorts, 2, nullptr, 0};
    Generator plainEventProc(withEvents);
    CHECK(executor.prepare({{"e", &withEvents}}, {}, {&plainEventProc}, 0, 8, 48000.0, kBudget) ==
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

namespace {
// F5.2 event ports.
Event note(uint32_t frame, uint32_t noteId) noexcept {
    Event e;
    e.frame = frame;
    e.kind = EventKind::Note;
    e.noteId = noteId;
    e.data[0] = 0x40903C00u;  // MIDI 2.0 note on, group 0, channel 0, key 60
    e.data[1] = 0xFFFF0000u;
    return e;
}

// Writes a fixed list of events each block (only the first block when `once`).
class EventSource final : public Typed {
public:
    EventSource(const ModuleDescriptor& d, std::initializer_list<Event> events, bool once = false)
        : Typed(d), once_(once) {
        for (const Event& e : events) events_[count_++] = e;
    }
    bool processPorts(const ProcessBlock& b) noexcept override {
        if (b.eventOutCount != 1) return false;
        EventOutput& out = b.eventOut[0];
        if (out.count != 0) return false;  // the host empties outputs before each call
        const uint32_t n = once_ && blocks_ > 0 ? 0 : count_;
        for (uint32_t k = 0; k < n && k < out.capacity; ++k) out.events[k] = events_[k];
        out.count = overrun_ ? out.capacity + 1 : n;
        ++blocks_;
        return true;
    }
    bool overrun_ = false;
private:
    Event events_[16];
    uint32_t count_ = 0, blocks_ = 0;
    bool once_;
};

// Records what each of its event inputs received in the last block, and writes a click per
// event of input 0 into its mono audio output at the event's frame (noteId as the value).
class EventSink final : public Typed {
public:
    using Typed::Typed;
    bool processPorts(const ProcessBlock& b) noexcept override {
        if (b.audioOutCount != 1 || b.eventInCount == 0 || b.eventInCount > 2) return false;
        for (uint32_t i = 0; i < b.frames; ++i) b.audioOut[0].channels[0][i] = 0.0f;
        for (uint32_t v = 0; v < b.eventInCount; ++v) {
            counts[v] = b.eventIn[v].count;
            for (uint32_t k = 0; k < b.eventIn[v].count && k < 16; ++k) received[v][k] = b.eventIn[v].events[k];
        }
        for (uint32_t k = 0; k < b.eventIn[0].count; ++k)
            b.audioOut[0].channels[0][b.eventIn[0].events[k].frame] += static_cast<float>(b.eventIn[0].events[k].noteId);
        return true;
    }
    Event received[2][16];
    uint32_t counts[2] = {0, 0};
};

struct EventModules {
    EventModules()
        : sourcePorts{{"out", PortType::Event, ChannelLayout::None, false}},
          sinkPorts{{"notes", PortType::Event, ChannelLayout::None, true, 0, true},
                    {"aux", PortType::Event, ChannelLayout::None, true},
                    {"out", PortType::Audio, ChannelLayout::Mono, false}},
          source{"test.events.source", 1, sourcePorts, 1, nullptr, 0},
          sink{"test.events.sink", 1, sinkPorts, 3, nullptr, 0} {}
    PortDescriptor sourcePorts[1], sinkPorts[3];
    ModuleDescriptor source, sink;
};
constexpr uint32_t kNotes = 0, kAux = 1;

bool sameEvent(const Event& a, const Event& b) noexcept {
    return a.frame == b.frame && a.kind == b.kind && a.flags == b.flags && a.noteId == b.noteId &&
           std::equal(a.data, a.data + 4, b.data);
}
}  // namespace

TEST(graph_event_ports_pass_events_unchanged_and_feed_the_first_input_from_the_host) {
    EventModules m;
    Event midi;  // a non-note message keeps every field
    midi.frame = 3;
    midi.flags = 0;
    midi.data[0] = 0x40B00700u;
    midi.data[1] = 0x12345678u;
    EventSource source(m.source, {note(1, 7), midi});
    EventSink sink(m.sink);
    GraphExecutor executor;
    // The source feeds `aux`; `notes`, the first event input, is unconnected and reads the host.
    CHECK(executor.prepare({{"src", &m.source}, {"sink", &m.sink}}, {{0, 0, 1, kAux}}, {&source, &sink}, 1, 16, 48000.0,
                           kBudget) == GraphError::Ok);
    const Event host[] = {note(0, 2), note(0, 3), note(9, 4)};
    float buffer[16];
    float* channels[] = {buffer};
    CHECK(executor.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 16}, 16, EventInput{host, 3}));
    CHECK_EQ(sink.counts[0], 3u);
    for (uint32_t k = 0; k < 3; ++k) CHECK(sameEvent(sink.received[0][k], host[k]));
    CHECK_EQ(sink.counts[1], 2u);
    CHECK(sameEvent(sink.received[1][0], note(1, 7)));
    CHECK(sameEvent(sink.received[1][1], midi));
    CHECK_EQ(buffer[0], 5.0f);  // notes 2 and 3 at frame 0
    CHECK_EQ(buffer[9], 4.0f);
    CHECK_EQ(buffer[1], 0.0f);
    // Without host events (either process overload) the first input reads none.
    CHECK(executor.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 16}, 16));
    CHECK_EQ(sink.counts[0], 0u);
    CHECK_EQ(sink.counts[1], 2u);
}

TEST(graph_event_merge_orders_by_frame_with_ties_in_connection_order) {
    EventModules m;
    EventSource a(m.source, {note(0, 1), note(2, 2), note(2, 3), note(5, 4)});
    EventSource b(m.source, {note(1, 10), note(2, 11), note(7, 12)});
    EventSink sink(m.sink);
    GraphExecutor executor;
    // Connection order is b, then a: at frame 2 b's event comes first.
    CHECK(executor.prepare({{"a", &m.source}, {"b", &m.source}, {"sink", &m.sink}}, {{1, 0, 2, kNotes}, {0, 0, 2, kNotes}},
                           {&a, &b, &sink}, 2, 16, 48000.0, kBudget) == GraphError::Ok);
    float buffer[16];
    float* channels[] = {buffer};
    CHECK(executor.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 16}, 16));
    const uint32_t expected[] = {1, 10, 11, 2, 3, 4, 12};
    CHECK_EQ(sink.counts[0], 7u);
    for (uint32_t k = 0; k < 7; ++k) CHECK_EQ(sink.received[0][k].noteId, expected[k]);
    CHECK_EQ(sink.counts[1], 0u);  // an unconnected second event input reads none, never the host
    CHECK_EQ(executor.eventsDropped(), 0u);
}

TEST(graph_event_merge_keeps_the_earliest_events_and_counts_the_rest) {
    EventModules m;
    EventSource a(m.source, {note(0, 1), note(4, 2), note(6, 3)});
    EventSource b(m.source, {note(1, 10), note(5, 11), note(8, 12)});
    EventSink sink(m.sink);
    GraphResourceBudget budget = kBudget;
    budget.maxEventsPerPort = 4;
    GraphExecutor executor;
    CHECK(executor.prepare({{"a", &m.source}, {"b", &m.source}, {"sink", &m.sink}}, {{0, 0, 2, kNotes}, {1, 0, 2, kNotes}},
                           {&a, &b, &sink}, 2, 16, 48000.0, budget) == GraphError::Ok);
    float buffer[16];
    float* channels[] = {buffer};
    for (int block = 1; block <= 2; ++block) {
        CHECK(executor.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 16}, 16));
        const uint32_t expected[] = {1, 10, 2, 11};
        CHECK_EQ(sink.counts[0], 4u);
        for (uint32_t k = 0; k < 4; ++k) CHECK_EQ(sink.received[0][k].noteId, expected[k]);
        CHECK_EQ(executor.eventsDropped(), 2u * static_cast<uint64_t>(block));
    }
}

TEST(graph_event_outputs_are_emptied_each_block) {
    EventModules m;
    EventSource once(m.source, {note(2, 9)}, true);
    EventSink sink(m.sink);
    GraphExecutor executor;
    CHECK(executor.prepare({{"src", &m.source}, {"sink", &m.sink}}, {{0, 0, 1, kNotes}}, {&once, &sink}, 1, 8, 48000.0,
                           kBudget) == GraphError::Ok);
    float buffer[8];
    float* channels[] = {buffer};
    CHECK(executor.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 8}, 8));
    CHECK_EQ(sink.counts[0], 1u);
    CHECK(executor.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 8}, 8));
    CHECK_EQ(sink.counts[0], 0u);
    CHECK_EQ(buffer[2], 0.0f);
}

TEST(graph_event_outputs_out_of_order_out_of_range_or_over_capacity_fail_the_block) {
    EventModules m;
    float buffer[8];
    float* channels[] = {buffer};
    for (int k = 0; k < 3; ++k) {
        EventSource unsorted(m.source, {note(3, 1), note(2, 2)});
        EventSource late(m.source, {note(8, 1)});  // frame 8 of an 8-frame block
        EventSource over(m.source, {note(0, 1)});
        over.overrun_ = true;
        EventSource* source = k == 0 ? &unsorted : k == 1 ? &late : &over;
        EventSink sink(m.sink);
        GraphExecutor executor;
        CHECK(executor.prepare({{"src", &m.source}, {"sink", &m.sink}}, {{0, 0, 1, kNotes}}, {source, &sink}, 1, 8,
                               48000.0, kBudget) == GraphError::Ok);
        std::fill_n(buffer, 8, 9.0f);
        CHECK(!executor.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 8}, 8));
        CHECK_EQ(executor.lastFailedNode(), 0u);
        CHECK_EQ(buffer[0], 0.0f);  // the failed block is silent
    }
}

TEST(graph_event_host_events_must_be_ordered_and_in_range) {
    EventModules m;
    EventSink sink(m.sink);
    GraphExecutor executor;
    CHECK(executor.prepare({{"sink", &m.sink}}, {}, {&sink}, 0, 8, 48000.0, kBudget) == GraphError::Ok);
    float buffer[8];
    float* channels[] = {buffer};
    const Event unsorted[] = {note(4, 1), note(3, 2)};
    const Event late[] = {note(6, 1)};
    CHECK(!executor.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 8}, 8, EventInput{unsorted, 2}));
    CHECK(!executor.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 6}, 6, EventInput{late, 1}));
    CHECK(!executor.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 8}, 8, EventInput{nullptr, 1}));
    CHECK(executor.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 8}, 8, EventInput{late, 1}));
    CHECK_EQ(sink.counts[0], 1u);
    // Host lists are bounded like every other event list: more than maxEventsPerPort is refused
    // before any of them is read (a bad count must not become a long walk on the audio thread).
    GraphResourceBudget small = kBudget;
    small.maxEventsPerPort = 2;
    GraphExecutor bounded;
    CHECK(bounded.prepare({{"sink", &m.sink}}, {}, {&sink}, 0, 8, 48000.0, small) == GraphError::Ok);
    const Event three[] = {note(0, 1), note(1, 2), note(2, 3)};
    CHECK(!bounded.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 8}, 8, EventInput{three, 3}));
    CHECK(bounded.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, 8}, 8, EventInput{three, 2}));
    CHECK_EQ(sink.counts[0], 2u);
}

TEST(graph_event_ports_validate_types_fan_in_and_budget) {
    EventModules m;
    EventSource a(m.source, {}), b(m.source, {});
    EventSink sink(m.sink);
    GraphExecutor executor;
    // A plain event input takes one source; the merging one takes many, but never the same twice.
    CHECK(executor.prepare({{"a", &m.source}, {"b", &m.source}, {"sink", &m.sink}}, {{0, 0, 2, kAux}, {1, 0, 2, kAux}},
                           {&a, &b, &sink}, 2, 8, 48000.0, kBudget) == GraphError::InputAlreadyConnected);
    CHECK(executor.prepare({{"a", &m.source}, {"sink", &m.sink}}, {{0, 0, 1, kNotes}, {0, 0, 1, kNotes}}, {&a, &sink}, 1, 8,
                           48000.0, kBudget) == GraphError::DuplicateConnection);
    // Events never feed audio.
    const PortDescriptor audioIn[] = {{"in", PortType::Audio, ChannelLayout::Mono, true},
                                      {"out", PortType::Audio, ChannelLayout::Mono, false}};
    const ModuleDescriptor effect{"test.events.effect", 1, audioIn, 2, nullptr, 0};
    ChannelGain gain(effect);
    CHECK(executor.prepare({{"a", &m.source}, {"g", &effect}}, {{0, 0, 1, 0}}, {&a, &gain}, 1, 8, 48000.0, kBudget) ==
          GraphError::PortTypeMismatch);
    // A graph with event ports needs room for events.
    GraphResourceBudget none = kBudget;
    none.maxEventsPerPort = 0;
    CHECK(executor.prepare({{"sink", &m.sink}}, {}, {&sink}, 0, 8, 48000.0, none) == GraphError::InvalidResourceBudget);
    // Event buffers count in the working-memory budget.
    GraphResourceBudget huge = kBudget;
    huge.maxEventsPerPort = 4u * 1024u * 1024u;
    CHECK(executor.prepare({{"sink", &m.sink}}, {}, {&sink}, 0, 8, 48000.0, huge) == GraphError::ResourceBudgetExceeded);
    // Descriptor rules: event inputs may merge; event outputs never sum.
    const PortDescriptor summingOut[] = {{"e", PortType::Event, ChannelLayout::None, false, 0, true}};
    const PortDescriptor eventLayout[] = {{"e", PortType::Event, ChannelLayout::Mono, true}};
    CHECK(validateModuleDescriptor({"x", 1, summingOut, 1, nullptr, 0}) == ModuleValidation::InvalidSummingPort);
    CHECK(validateModuleDescriptor({"x", 1, eventLayout, 1, nullptr, 0}) == ModuleValidation::InvalidPortLayout);
    CHECK(validateModuleDescriptor(m.sink) == ModuleValidation::Ok);
}

TEST(graph_event_ports_process_without_allocating) {
    EventModules m;
    EventSource a(m.source, {note(0, 1), note(4, 2), note(6, 3)});
    EventSource b(m.source, {note(1, 10), note(5, 11)});
    EventSink sink(m.sink);
    GraphResourceBudget budget = kBudget;
    budget.maxEventsPerPort = 4;  // drops events too
    GraphExecutor executor;
    CHECK(executor.prepare({{"a", &m.source}, {"b", &m.source}, {"sink", &m.sink}}, {{0, 0, 2, kNotes}, {1, 0, 2, kAux}},
                           {&a, &b, &sink}, 2, 64, 48000.0, budget) == GraphError::Ok);
    float buffer[64];
    float* channels[] = {buffer};
    const Event host[] = {note(0, 5)};
    bool ok = true;
    std::size_t operations = 0;
    {
        cawtest::AllocationScope scope;
        for (uint32_t frames : {64u, 17u, 8u, 64u})
            ok = executor.process(ConstChannelBufferView{}, ChannelBufferView{channels, 1, frames}, frames, EventInput{host, 1}) && ok;
        operations = scope.count();
    }
    CHECK(ok);
    CHECK_EQ(operations, 0u);
}
