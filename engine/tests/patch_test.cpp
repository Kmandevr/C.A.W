// The patch model (routing plan step 3): nulls against the chain, block-size identity, feedback, latency, optional ports, limits.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <caw/instrument.hpp>

#include "builtin_components.h"
#include "builtin_test_signal.h"
#include "component_chain.h"
#include "patch.h"
#include "test.h"
#include "test_signal.h"
#include "tolerance.h"

using namespace caw;

namespace {

const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        return x;
    }();
    return r;
}

ComponentSpec component(std::string id, std::vector<std::pair<std::string, double>> params = {}) {
    ComponentSpec c;
    c.id = std::move(id);
    c.params = std::move(params);
    return c;
}

PatchNodeSpec node(std::string id, PatchNodeKind kind, std::vector<ComponentSpec> components = {}) {
    return {std::move(id), kind, std::move(components)};
}
PatchNodeSpec module(std::string id, ComponentSpec c) { return node(std::move(id), PatchNodeKind::Module, {std::move(c)}); }

PatchWireSpec wire(std::string from, std::string to, double gain = 1.0, bool feedback = false, bool limiter = true) {
    auto split = [](const std::string& s) {
        const auto dot = s.find('.');
        return PatchEnd{s.substr(0, dot), s.substr(dot + 1)};
    };
    PatchWireSpec w;
    w.from = split(from);
    w.to = split(to);
    w.gain = gain;
    w.feedback = feedback;
    w.limiter = limiter;
    return w;
}

// The test signal (Free mode) through an instrument chain: a deterministic, busy stereo input.
cawtest::Audio signal(cawtest::Shape shape, uint32_t frames, cawtest::Params params = {}) {
    std::string error;
    auto chain = ComponentChain::buildInstrument(registry(), cawtest::testSignal(shape, std::move(params)), 48000, error);
    cawtest::Audio a{std::vector<float>(frames), std::vector<float>(frames)};
    CHECK(chain != nullptr);
    if (!chain) return a;
    for (uint32_t at = 0; at < frames; at += 64) {
        const uint32_t n = std::min<uint32_t>(64, frames - at);
        chain->process(a.l.data() + at, a.r.data() + at, n, 48000, nullptr);
    }
    return a;
}

// A music-like input: a saw, noise bursts and silence between them (sleep and wake).
cawtest::Audio music(uint32_t frames) {
    cawtest::Audio saw = signal(cawtest::Shape::Saw, frames, {{"freq", 110}, {"level", 0.5}});
    const cawtest::Audio noise = signal(cawtest::Shape::Noise, frames, {{"level", 0.3}});
    for (uint32_t i = 0; i < frames; ++i) {
        const bool on = (i / 6000) % 3 != 2;  // two parts sound, one is silent
        saw.l[i] = on ? saw.l[i] + ((i / 1500) % 2 ? noise.l[i] : 0.0f) : 0.0f;
        saw.r[i] = on ? saw.r[i] + ((i / 1500) % 2 ? noise.r[i] : 0.0f) : 0.0f;
    }
    return saw;
}

cawtest::Audio renderChain(const std::vector<ComponentSpec>& specs, const cawtest::Audio& in) {
    std::string error;
    auto chain = ComponentChain::build(registry(), specs, 48000, error);
    cawtest::Audio out = in;
    CHECK(chain != nullptr);
    if (!chain) return out;
    for (size_t at = 0; at < in.frames(); at += 64) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(64, in.frames() - at));
        chain->process(out.l.data() + at, out.r.data() + at, n, 48000, nullptr);
    }
    return out;
}

std::unique_ptr<CompiledPatch> compile(const PatchSpec& spec, const CompiledPatch* previous = nullptr) {
    std::string error;
    auto p = compilePatch(registry(), spec, 48000, previous, error);
    if (!p) cawtest::fail(__FILE__, __LINE__, "compile: " + error);
    return p;
}

// Renders `in` (null: silence of `frames`) through the patch in host blocks of `block` frames.
cawtest::Audio renderPatch(CompiledPatch& p, const cawtest::Audio* in, size_t frames, uint32_t block,
                           const std::vector<Event>& events = {}) {
    cawtest::Audio out{std::vector<float>(frames), std::vector<float>(frames)};
    size_t next = 0;
    std::vector<Event> local;
    for (size_t at = 0; at < frames; at += block) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(block, frames - at));
        local.clear();
        for (; next < events.size() && events[next].frame < at + n; ++next) {
            Event e = events[next];
            e.frame -= static_cast<uint32_t>(at);
            local.push_back(e);
        }
        const EventInput ev{local.data(), static_cast<uint32_t>(local.size())};
        CHECK(p.process(in ? in->l.data() + at : nullptr, in ? in->r.data() + at : nullptr, out.l.data() + at,
                        out.r.data() + at, n, &ev));
    }
    return out;
}

bool sameBits(const cawtest::Audio& a, const cawtest::Audio& b) {
    return a.l.size() == b.l.size() && std::memcmp(a.l.data(), b.l.data(), a.l.size() * sizeof(float)) == 0 &&
           std::memcmp(a.r.data(), b.r.data(), a.r.size() * sizeof(float)) == 0;
}

double peak(const cawtest::Audio& a) {
    double m = 0;
    for (size_t i = 0; i < a.frames(); ++i) m = std::max({m, std::fabs(double(a.l[i])), std::fabs(double(a.r[i]))});
    return m;
}

std::string refused(const PatchSpec& spec) {
    std::string error;
    auto p = compilePatch(registry(), spec, 48000, nullptr, error);
    CHECK(p == nullptr);
    return error;
}

// Effects of every family, with values off their defaults, in today's chain order.
std::vector<ComponentSpec> linearEffects() {
    return {component("org.caw.eq"),
            component("org.caw.compressor"),
            component("org.caw.drive"),
            component("org.caw.chorus"),
            component("org.caw.utility", {{"width", 1.3}, {"pan", 0.2}}),
            component("org.caw.delay"),
            component("org.caw.reverb", {{"mix", 0.3}})};
}

PatchSpec linearModules(const std::vector<ComponentSpec>& effects) {
    PatchSpec s;
    s.nodes.push_back(node("in", PatchNodeKind::Input));
    std::string last = "in.out";
    for (size_t k = 0; k < effects.size(); ++k) {
        const std::string id = "fx" + std::to_string(k);
        s.nodes.push_back(module(id, effects[k]));
        s.wires.push_back(wire(last, id + ".in"));
        last = id + ".out";
    }
    s.nodes.push_back(node("out", PatchNodeKind::Output));
    s.wires.push_back(wire(last, "out.in"));
    return s;
}

}  // namespace

TEST(a_linear_patch_of_module_nodes_nulls_against_todays_chain) {
    const cawtest::Audio in = music(48000 * 3);
    const auto effects = linearEffects();
    const cawtest::Audio chain = renderChain(effects, in);
    auto p = compile(linearModules(effects));
    if (!p) return;
    CHECK_EQ(p->subBlockFrames(), patch::kWideSubBlock);  // no feedback: the Engine's block
    std::string error;
    CHECK_EQ(p->latencyFrames(), ComponentChain::build(registry(), effects, 48000, error)->latencyFrames());
    const cawtest::Audio patched = renderPatch(*p, &in, in.frames(), 64);
    CHECK(peak(chain) > 0.05);
    CHECK_EQ(cawtest::compareStable(chain, patched), std::string());
    CHECK(cawtest::nullResidualDbfs(chain, patched) < cawtest::tol::kNullPeakDbfs);
}

TEST(a_patch_holding_the_chain_as_one_node_nulls_against_it) {
    const cawtest::Audio in = music(48000 * 2);
    const auto effects = linearEffects();
    const cawtest::Audio chain = renderChain(effects, in);
    PatchSpec s;
    s.nodes = {node("in", PatchNodeKind::Input), node("inserts", PatchNodeKind::Chain, effects),
               node("out", PatchNodeKind::Output)};
    s.wires = {wire("in.out", "inserts.in"), wire("inserts.out", "out.in")};
    auto p = compile(s);
    if (!p) return;
    CHECK(cawtest::nullResidualDbfs(chain, renderPatch(*p, &in, in.frames(), 64)) < cawtest::tol::kNullPeakDbfs);
}

namespace {
// A patch that uses everything at once: parallel paths with latency (the limiter), wire gains, two feedback wires
// (one with its limiter, one clamped), a Chain node, an optional output and the test signal played by notes.
PatchSpec busyPatch() {
    PatchSpec s;
    s.nodes = {node("in", PatchNodeKind::Input),
               module("lim", component("org.caw.limiter")),
               node("pre", PatchNodeKind::Chain),
               module("split", component("org.caw.utility", {{"width", 1.5}})),
               node("bus", PatchNodeKind::Chain, {component("org.caw.chorus"), component("org.caw.delay")}),
               module("drive", component("org.caw.drive")),
               module("synth", cawtest::testSignal(cawtest::Shape::Square, {{"mode", 1}, {"level", 0.2}})),
               node("out", PatchNodeKind::Output)};
    s.wires = {wire("in.out", "lim.in"),
               wire("in.out", "pre.in", 0.7),
               wire("pre.out", "split.in"),
               wire("lim.out", "bus.in"),
               wire("split.side", "bus.in", -0.5),
               wire("split.out", "drive.in"),
               wire("synth.out", "bus.in", 0.8),
               wire("bus.out", "out.in"),
               wire("drive.out", "out.in", 0.5),
               wire("bus.out", "bus.in", 0.6, true),             // limited feedback
               wire("drive.out", "pre.in", 0.4, true, false)};  // clamped feedback
    return s;
}
std::vector<Event> played() {
    return {notes::noteOn(100, 1, 60, 0.9), notes::noteOn(5000, 2, 67, 0.7), notes::noteOff(20000, 1, 60), notes::noteOn(30011, 3, 72, 1.0),
            notes::noteOff(40000, 2, 67), notes::noteOff(47000, 3, 72)};
}
}  // namespace

TEST(a_patch_renders_the_same_bits_at_any_host_block_size) {
    const cawtest::Audio in = music(48000);
    auto first = compile(busyPatch());
    if (!first) return;
    CHECK(first->latencyFrames() > 0u);  // the limiter's look-ahead, compensated on the other paths
    CHECK_EQ(first->subBlockFrames(), patch::kSubBlock);  // it has feedback wires
    const cawtest::Audio reference = renderPatch(*first, &in, in.frames(), 64, played());
    CHECK(peak(reference) > 0.05);
    for (uint32_t block : {1u, 7u, 16u, 17u, 256u, 333u, 1024u, 4096u}) {
        auto p = compile(busyPatch());
        if (!p) return;
        const bool same = sameBits(reference, renderPatch(*p, &in, in.frames(), block, played()));
        if (!same) cawtest::fail(__FILE__, __LINE__, "block size " + std::to_string(block) + " changed the render");
    }
}

TEST(a_feedback_wire_delays_by_one_sub_block_and_its_clamp_or_limiter_bounds_it) {
    // in -> mix (an empty chain, summing) -> out, and mix.out back into mix.in at 0.5: an impulse echoes every 16
    // frames at half the level before (the limiter off: exact).
    PatchSpec s;
    s.nodes = {node("in", PatchNodeKind::Input), node("mix", PatchNodeKind::Chain), node("out", PatchNodeKind::Output)};
    s.wires = {wire("in.out", "mix.in"), wire("mix.out", "out.in"), wire("mix.out", "mix.in", 0.5, true, false)};
    auto p = compile(s);
    if (!p) return;
    cawtest::Audio impulse{std::vector<float>(256), std::vector<float>(256)};
    impulse.l[0] = impulse.r[0] = 1.0f;
    const cawtest::Audio out = renderPatch(*p, &impulse, 256, 5);
    bool exact = true;
    for (uint32_t i = 0; i < 256; ++i) {
        const float expected = i % 16 == 0 ? std::ldexp(1.0f, -static_cast<int>(i / 16)) : 0.0f;
        exact = exact && out.l[i] == expected && out.r[i] == expected;
    }
    CHECK(exact);
    CHECK_EQ(p->latencyFrames(), 0u);  // feedback wires are not compensated

    // A runaway loop (gain 16 on DC): clamped to +/-16 without the limiter; held to +/-1 (and its DC removed) with it.
    cawtest::Audio dc{std::vector<float>(48000, 0.5f), std::vector<float>(48000, 0.5f)};
    for (bool limiter : {false, true}) {
        s.wires[2] = wire("mix.out", "mix.in", 16.0, true, limiter);
        auto q = compile(s);
        if (!q) return;
        const cawtest::Audio o = renderPatch(*q, &dc, dc.frames(), 64);
        bool finite = true;
        for (size_t i = 0; i < o.frames(); ++i) finite = finite && std::isfinite(o.l[i]) && std::isfinite(o.r[i]);
        CHECK(finite);
        CHECK(peak(o) <= 0.5 + (limiter ? 1.0 : patch::kFeedbackClamp) + 1e-6);
        CHECK(peak(o) >= (limiter ? 1.0 : 16.0));  // it did run away into the bound
    }
    // A stable loop (0.5) on DC: without the limiter it settles at 0.5 / (1 - 0.5); with it, the return's DC block
    // takes the DC out of the loop and the output settles back at the input.
    for (bool limiter : {false, true}) {
        s.wires[2] = wire("mix.out", "mix.in", 0.5, true, limiter);
        auto q = compile(s);
        if (!q) return;
        const cawtest::Audio o = renderPatch(*q, &dc, dc.frames(), 64);
        CHECK_NEAR(o.l.back(), limiter ? 0.5 : 1.0, 1e-3);
    }
}

TEST(latency_is_compensated_per_wire_but_not_on_feedback_wires) {
    const ModuleDescriptor* lim = registry().find("org.caw.limiter");
    CHECK(lim != nullptr && lim->latencyFrames > 0);
    if (!lim) return;
    const uint32_t latency = lim->latencyFrames;
    // in -> out directly and through the limiter (at gain 0): the direct path is delayed to meet the limiter's.
    PatchSpec s;
    s.nodes = {node("in", PatchNodeKind::Input), node("pre", PatchNodeKind::Chain),
               module("lim", component("org.caw.limiter")), node("out", PatchNodeKind::Output)};
    s.wires = {wire("in.out", "pre.in"), wire("pre.out", "lim.in"), wire("lim.out", "out.in", 0.0),
               wire("in.out", "out.in")};
    auto p = compile(s);
    if (!p) return;
    CHECK_EQ(p->latencyFrames(), static_cast<uint64_t>(latency));
    cawtest::Audio impulse{std::vector<float>(latency + 64), std::vector<float>(latency + 64)};
    impulse.l[3] = 1.0f;
    impulse.r[3] = -0.5f;
    const cawtest::Audio out = renderPatch(*p, &impulse, impulse.frames(), 13);
    bool exact = true;
    for (uint32_t i = 0; i < out.frames(); ++i)
        exact = exact && out.l[i] == (i == latency + 3 ? 1.0f : 0.0f) && out.r[i] == (i == latency + 3 ? -0.5f : 0.0f);
    CHECK(exact);
    // A feedback wire from the limiter back to its input's chain changes no node's time.
    s.wires.push_back(wire("lim.out", "pre.in", 0.1, true));
    auto q = compile(s);
    if (q) CHECK_EQ(q->latencyFrames(), static_cast<uint64_t>(latency));
}

TEST(an_optional_output_wired_in_a_patch_splits_the_effect_and_unwired_costs_nothing) {
    const cawtest::Audio in = music(48000);
    const ComponentSpec utility = component("org.caw.utility", {{"width", 1.3}, {"pan", 0.2}, {"bass_mono", 1}});
    // Unwired, the effect runs as it does in a chain (same bits) and its optional ports are not even declared.
    PatchSpec plain = linearModules({utility});
    auto a = compile(plain);
    if (!a) return;
    const cawtest::Audio main = renderPatch(*a, &in, in.frames(), 64);
    CHECK(sameBits(main, renderChain({utility}, in)));
    CHECK_EQ(a->executor().inputChannels(), 2u);
    // Mid and side wired to the output (summing): they add up to the main output.
    PatchSpec split;
    split.nodes = {node("in", PatchNodeKind::Input), module("u", utility), node("out", PatchNodeKind::Output)};
    split.wires = {wire("in.out", "u.in"), wire("u.mid", "out.in"), wire("u.side", "out.in")};
    auto b = compile(split);
    if (!b) return;
    const cawtest::Audio sum = renderPatch(*b, &in, in.frames(), 64);
    double err = 0;
    for (size_t i = 0; i < in.frames(); ++i)
        err = std::max({err, std::fabs(double(sum.l[i]) - main.l[i]), std::fabs(double(sum.r[i]) - main.r[i])});
    CHECK(err < 1e-6);
    // Mid alone: the same on both sides, and not the whole output.
    split.wires = {wire("in.out", "u.in"), wire("u.mid", "out.in")};
    auto c = compile(split);
    if (!c) return;
    const cawtest::Audio mid = renderPatch(*c, &in, in.frames(), 64);
    bool mono = true;
    for (size_t i = 0; i < in.frames(); ++i) mono = mono && mid.l[i] == mid.r[i];
    CHECK(mono);
    CHECK(!sameBits(mid, main));
    // The transient designer's two outputs, each into its own chain, sum back to its output too.
    const ComponentSpec transient = component("org.caw.transient", {{"attack", 0.7}, {"sustain", -0.4}});
    PatchSpec t;
    t.nodes = {node("in", PatchNodeKind::Input), module("t", transient), node("a", PatchNodeKind::Chain),
               node("b", PatchNodeKind::Chain), node("out", PatchNodeKind::Output)};
    t.wires = {wire("in.out", "t.in"), wire("t.transient", "a.in"), wire("t.sustain", "b.in"), wire("a.out", "out.in"),
               wire("b.out", "out.in")};
    auto d = compile(t);
    if (!d) return;
    const cawtest::Audio parts = renderPatch(*d, &in, in.frames(), 64);
    const cawtest::Audio whole = renderChain({transient}, in);
    err = 0;
    for (size_t i = 0; i < in.frames(); ++i)
        err = std::max({err, std::fabs(double(parts.l[i]) - whole.l[i]), std::fabs(double(parts.r[i]) - whole.r[i])});
    CHECK(err < 1e-6);
    CHECK(peak(whole) > 0.05);
}

namespace {
// Typed ports for the test: a ramp on a modulation output, and a gain driven by a modulation input.
constexpr PortDescriptor kRampPorts[] = {{"mod", PortType::Modulation, ChannelLayout::None, false}};
constexpr PortDescriptor kVcaPorts[] = {stereoInput("in"), {"amount", PortType::Modulation, ChannelLayout::None, true},
                                        stereoOutput("out")};
ModuleDescriptor typedDescriptor(std::string_view id, const PortDescriptor* ports, uint32_t count) {
    ModuleDescriptor d;
    d.id = id;
    d.name = id;
    d.role = ModuleRole::Utility;
    d.ports = ports;
    d.portCount = count;
    return d;
}
const ModuleDescriptor& rampDescriptor() {
    static const ModuleDescriptor d = typedDescriptor("test.ramp", kRampPorts, 1);
    return d;
}
const ModuleDescriptor& vcaDescriptor() {
    static const ModuleDescriptor d = typedDescriptor("test.vca", kVcaPorts, 3);
    return d;
}
class Ramp final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return rampDescriptor(); }
    bool usesProcessPorts() const noexcept override { return true; }
    bool processPorts(const ProcessBlock& b) noexcept override {
        for (uint32_t i = 0; i < b.frames; ++i) b.modulationOut[0][i] = static_cast<float>((at_++ % 1000) / 1000.0);
        return true;
    }
    void reset() noexcept override { at_ = 0; }

private:
    uint64_t at_ = 0;
};
class Vca final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return vcaDescriptor(); }
    bool usesProcessPorts() const noexcept override { return true; }
    bool processPorts(const ProcessBlock& b) noexcept override {
        for (uint32_t c = 0; c < 2; ++c)
            for (uint32_t i = 0; i < b.frames; ++i)
                b.audioOut[0].channels[c][i] = b.audioIn[0].channels[c][i] * b.modulationIn[0][i];
        return true;
    }
};
// Nine ports: one more than a node may have.
constexpr PortDescriptor kWidePorts[] = {
    {"m0", PortType::Modulation, ChannelLayout::None, false}, {"m1", PortType::Modulation, ChannelLayout::None, false},
    {"m2", PortType::Modulation, ChannelLayout::None, false}, {"m3", PortType::Modulation, ChannelLayout::None, false},
    {"m4", PortType::Modulation, ChannelLayout::None, false}, {"m5", PortType::Modulation, ChannelLayout::None, false},
    {"m6", PortType::Modulation, ChannelLayout::None, false}, {"m7", PortType::Modulation, ChannelLayout::None, false},
    {"m8", PortType::Modulation, ChannelLayout::None, false}};
const ModuleDescriptor& wideDescriptor() {
    static const ModuleDescriptor d = typedDescriptor("test.wide", kWidePorts, 9);
    return d;
}
class Wide final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return wideDescriptor(); }
    bool usesProcessPorts() const noexcept override { return true; }
    bool processPorts(const ProcessBlock&) noexcept override { return true; }
};
const ModuleRegistry& typedRegistry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        x.add(rampDescriptor(), []() noexcept -> ModuleProcessor* { return new Ramp(); });
        x.add(vcaDescriptor(), []() noexcept -> ModuleProcessor* { return new Vca(); });
        x.add(wideDescriptor(), []() noexcept -> ModuleProcessor* { return new Wide(); });
        return x;
    }();
    return r;
}
}  // namespace

TEST(a_modulation_wire_carries_its_gain_and_latency_compensation_per_frame) {
    // ramp.mod -> vca.amount at 0.5; the audio reaches the vca through a limiter, so the modulation wire is delayed
    // by the limiter's latency to meet it.
    const uint32_t latency = registry().find("org.caw.limiter")->latencyFrames;
    PatchSpec s;
    s.nodes = {node("in", PatchNodeKind::Input), module("lim", component("org.caw.limiter")),
               module("ramp", component("test.ramp")), module("vca", component("test.vca")),
               node("out", PatchNodeKind::Output)};
    s.wires = {wire("in.out", "lim.in"), wire("lim.out", "vca.in"), wire("ramp.mod", "vca.amount", 0.5),
               wire("vca.out", "out.in")};
    std::string error;
    auto p = compilePatch(typedRegistry(), s, 48000, nullptr, error);
    CHECK_EQ(error, std::string());
    if (!p) return;
    CHECK_EQ(p->latencyFrames(), static_cast<uint64_t>(latency));
    // A constant 0.25 (below the limiter's threshold, so it passes unchanged once its look-ahead is through).
    cawtest::Audio dc{std::vector<float>(4000, 0.25f), std::vector<float>(4000, 0.25f)};
    const cawtest::Audio out = renderPatch(*p, &dc, dc.frames(), 7);
    double err = 0;
    for (uint32_t i = latency + 64; i < 4000; ++i) {
        const double ramp = ((i - latency) % 1000) / 1000.0;
        err = std::max(err, std::fabs(out.l[i] - 0.25 * 0.5 * ramp));
    }
    CHECK(err < 2e-3);
    // A gain on a modulation wire is fine; on an event wire it is refused (events have none).
    PatchSpec bad = s;
    bad.wires[2] = wire("ramp.mod", "vca.in");
    std::string why;
    CHECK(compilePatch(typedRegistry(), bad, 48000, nullptr, why) == nullptr);
    CHECK(why.find("different types") != std::string::npos);
    // A node with more ports than a node may have.
    PatchSpec wide;
    wide.nodes = {module("w", component("test.wide")), node("out", PatchNodeKind::Output)};
    CHECK(compilePatch(typedRegistry(), wide, 48000, nullptr, why) == nullptr);
    CHECK(why.find("9 ports, more than the 8") != std::string::npos);
}

TEST(a_patch_keeps_unchanged_nodes_and_their_state_across_a_recompile) {
    // A delay holds its echoes: a recompile that keeps it plays them on; a fresh one starts silent.
    PatchSpec s;
    s.nodes = {node("in", PatchNodeKind::Input), module("echo", component("org.caw.delay")),
               node("out", PatchNodeKind::Output)};
    s.wires = {wire("in.out", "echo.in"), wire("echo.out", "out.in")};
    auto a = compile(s);
    if (!a) return;
    const cawtest::Audio burst = music(12000);
    renderPatch(*a, &burst, burst.frames(), 64);
    PatchSpec t = s;
    t.wires[1].gain = 0.5;  // a new gain node: the graph changes, the delay node doesn't
    auto kept = compile(t, a.get());
    auto fresh = compile(t);
    if (!kept || !fresh) return;
    CHECK_EQ(kept->keptNodes(), 1u);
    CHECK_EQ(fresh->keptNodes(), 0u);
    a.reset();  // the old patch goes; the kept instance lives on in the new one
    const cawtest::Audio tail = renderPatch(*kept, nullptr, 24000, 64);
    const cawtest::Audio none = renderPatch(*fresh, nullptr, 24000, 64);
    CHECK(peak(tail) > 1e-3);
    CHECK_EQ(peak(none), 0.0);
    // A changed component (another variant) is a new instance.
    PatchSpec u = t;
    u.nodes[1] = module("echo", component("org.caw.reverb"));
    auto other = compile(u, kept.get());
    if (other) CHECK_EQ(other->keptNodes(), 0u);
}

TEST(a_patch_sets_values_of_module_and_chain_nodes) {
    PatchSpec s;
    s.nodes = {node("in", PatchNodeKind::Input), module("u", component("org.caw.utility")),
               node("c", PatchNodeKind::Chain, {component("org.caw.utility")}), node("out", PatchNodeKind::Output)};
    s.wires = {wire("in.out", "u.in"), wire("u.out", "c.in"), wire("c.out", "out.in")};
    auto p = compile(s);
    if (!p) return;
    CHECK(p->setParameter("u", 0, "gain", -6.0));
    CHECK(p->setParameter("c", 0, "gain", -6.0));
    CHECK(!p->setParameter("u", 0, "no_such", 1.0));
    CHECK(!p->setParameter("u", 1, "gain", 1.0));
    CHECK(!p->setParameter("nobody", 0, "gain", 1.0));
    CHECK(!p->setParameter("u", 0, "gain", std::nan("")));
    cawtest::Audio dc{std::vector<float>(48000, 0.5f), std::vector<float>(48000, 0.5f)};
    const cawtest::Audio out = renderPatch(*p, &dc, dc.frames(), 64);
    CHECK_NEAR(out.l.back(), 0.5 * std::pow(10.0, -12.0 / 20.0), 1e-3);  // both ramped to -6 dB
}

TEST(a_patch_spec_is_refused_with_an_error_naming_the_problem) {
    auto has = [](const std::string& error, const char* text) {
        if (error.find(text) == std::string::npos)
            cawtest::fail(__FILE__, __LINE__, "error \"" + error + "\" lacks \"" + text + "\"");
    };
    const PatchSpec good = linearModules({component("org.caw.drive")});
    CHECK(compile(good) != nullptr);
    PatchSpec s = good;
    s.nodes.push_back(node("c1", PatchNodeKind::Chain));
    s.nodes.push_back(node("c2", PatchNodeKind::Chain));
    s.wires.push_back(wire("c1.out", "c2.in"));
    s.wires.push_back(wire("c2.out", "c1.in"));
    has(refused(s), "loop through node \"c1\"");
    s = good;
    s.wires.push_back(wire("ghost.out", "out.in"));
    has(refused(s), "\"ghost\", which is not a node");
    s = good;
    s.wires.push_back(wire("fx0.wet", "out.in"));
    has(refused(s), "no output port \"wet\"");
    s = good;
    s.nodes.push_back(node("c", PatchNodeKind::Chain));
    s.wires.push_back(wire("c.out", "fx0.in"));
    has(refused(s), "is not summing and already has wire 0");
    s = good;
    s.wires.push_back(wire("fx0.out", "out.in"));
    has(refused(s), "repeats wire 1");
    s = good;
    s.wires[0].gain = std::nan("");
    has(refused(s), "gain is not finite");
    s = good;
    s.wires[0].gain = 17;
    has(refused(s), "beyond");
    s = good;
    s.nodes.pop_back();
    s.wires.pop_back();
    has(refused(s), "no output node");
    s = good;
    s.nodes.push_back(node("in", PatchNodeKind::Chain));
    has(refused(s), "two nodes have the id \"in\"");
    s = good;
    s.nodes.push_back(node("in2", PatchNodeKind::Input));
    has(refused(s), "second input node");
    s = good;
    s.nodes.push_back(node(std::string(65, 'x'), PatchNodeKind::Chain));
    has(refused(s), "longer than 64 bytes");
    s = good;
    s.nodes[1] = module("fx0", component("org.caw.nothing"));
    has(refused(s), "no such component");
    s = good;
    s.nodes[1] = module("fx0", component("org.caw.drive", {{"nonsense", 1}}));
    has(refused(s), "has no parameter \"nonsense\"");
    s = good;
    s.nodes[1].components.push_back(component("org.caw.drive"));
    has(refused(s), "exactly one component");
    s = good;
    s.nodes[1].components[0].bypass = true;
    has(refused(s), "no bypass");
    // Limits: nodes, wires, feedback wires.
    s = good;
    for (int k = 0; k < 61; ++k) s.nodes.push_back(node("c" + std::to_string(k), PatchNodeKind::Chain));
    CHECK(compile(s) != nullptr);  // 64 nodes
    s.nodes.push_back(node("c61", PatchNodeKind::Chain));
    has(refused(s), "65 nodes, more than the 64 a patch may have");
    s = good;
    for (int k = 0; k < 16; ++k) {
        const std::string id = "c" + std::to_string(k);
        s.nodes.push_back(node(id, PatchNodeKind::Chain));
        s.wires.push_back(wire(id + ".out", id + ".in", 0.5, true));
    }
    CHECK(compile(s) != nullptr);  // 16 feedback wires
    s.nodes.push_back(node("c16", PatchNodeKind::Chain));
    s.wires.push_back(wire("c16.out", "c16.in", 0.5, true));
    has(refused(s), "more than 16 feedback wires");
    s = good;
    for (int k = 0; k < 255; ++k) s.wires.push_back(wire("in.out", "out.in", 0.001));
    has(refused(s), "257 wires, more than the 256");
    s = good;
    s.wires.push_back(wire("fx0.out", "out.in", 0.5, true));
    has(refused(s), "repeats wire 1");  // a feedback wire beside a plain one on the same ports
}
