// The patch model (routing plan step 3, 1.0.8): compiles a patch spec onto GraphExecutor and runs it in sub-blocks.
#include "patch.h"

#include <algorithm>
#include <cmath>
#include <exception>
#include <limits>
#include <new>
#include <utility>

#include "builtin_fx_racks.h"
#include "fx_merged.h"
#include "params.h"
#include "patch_nodes.h"

namespace caw {

using patch_detail::FeedbackRing;
using patch_detail::NodeInstance;
using patch_detail::WiredOptional;

static_assert(patch::kWideSubBlock <= ComponentChain::kMaxFrames && patch::kWideSubBlock % patch::kSubBlock == 0);

namespace {

std::string quoted(std::string_view s) { return "\"" + std::string(s) + "\""; }

const char* graphErrorText(GraphError e) noexcept {
    switch (e) {
        case GraphError::Ok: return "ok";
        case GraphError::ResourceBudgetExceeded: return "it needs more working memory than a patch may use";
        case GraphError::InvalidModule: return "a component's descriptor is invalid";
        case GraphError::PortTypeMismatch: return "a wire joins ports of different types";
        case GraphError::ChannelLayoutMismatch: return "a wire joins audio ports of different channel layouts";
        case GraphError::InputAlreadyConnected: return "an input that is not summing has two wires";
        case GraphError::Cycle: return "its wires form a loop";
        case GraphError::RuntimeUnsupportedPortType:
        case GraphError::RuntimeUnsupportedPortCount:
            return "a component has typed or extra ports but does not process ports";
        case GraphError::RuntimeHostInputMismatch: return "the patch input's channels do not match";
        case GraphError::TooManyChannels: return "a port has too many channels";
        case GraphError::DuplicateConnection: return "two wires join the same ports";
        case GraphError::OutOfMemory: return "out of memory";
        default: return "the graph executor refused it";
    }
}

const char* kindName(PatchNodeKind k) noexcept {
    switch (k) {
        case PatchNodeKind::Input: return "input";
        case PatchNodeKind::Output: return "output";
        case PatchNodeKind::Chain: return "chain";
        case PatchNodeKind::Module: return "module";
    }
    return "?";
}

constexpr PortDescriptor kStereoIn = audioPort("in", true);
constexpr PortDescriptor kStereoOut = audioPort("out", false);

uint32_t channelsOf(const PortDescriptor& p) noexcept { return p.type == PortType::Audio ? portChannelCount(p) : 1u; }

// One endpoint of a wire, resolved against its node: a descriptor port (index) or an optional port (optional).
struct Endpoint {
    uint32_t node = 0;
    uint32_t index = 0;       // descriptor port, or the effect's optional port
    bool optional = false;
    PortDescriptor shape;     // the port (an optional port as a stereo audio port)
};

// A node of the spec while it compiles.
struct Building {
    const PatchNodeSpec* spec = nullptr;
    std::shared_ptr<NodeInstance> instance;
    bool kept = false;
    const ModuleDescriptor* descriptor = nullptr;  // Module: its component's
    fx::EffectBase* effect = nullptr;              // Module: a built-in effect offering optional ports
    std::vector<std::pair<uint32_t, double>> values;  // Module: parameter index, constrained value
    std::vector<double> all;                          // Module: every parameter's value (the spec's or default)
    const std::vector<double>* oldValues = nullptr;   // Module, kept: the playing patch's values of it
    std::vector<uint32_t> wiredOptional;              // Module: optional ports some wire names, ascending
    uint32_t graph = UINT32_MAX;
    uint64_t latency = 0, time = 0;
    uint32_t wiresIn = 0;  // wires into the Chain or Output input (summing past one)
};

}  // namespace

CompiledPatch::~CompiledPatch() = default;

std::unique_ptr<CompiledPatch> compilePatch(const ModuleRegistry& registry, const PatchSpec& spec, double sampleRate,
                                            const CompiledPatch* previous, std::string& error) try {
    error.clear();
    auto fail = [&](std::string why) {
        error = "patch: " + std::move(why);
        return std::unique_ptr<CompiledPatch>();
    };
    if (!(sampleRate > 0.0) || !std::isfinite(sampleRate)) return fail("the sample rate is not positive");
    if (spec.nodes.size() > patch::kMaxNodes)
        return fail(std::to_string(spec.nodes.size()) + " nodes, more than the " + std::to_string(patch::kMaxNodes) +
                    " a patch may have");
    if (spec.wires.size() > patch::kMaxWires)
        return fail(std::to_string(spec.wires.size()) + " wires, more than the " + std::to_string(patch::kMaxWires) +
                    " a patch may have");
    const uint32_t nodeCount = static_cast<uint32_t>(spec.nodes.size());
    {  // every Chain node within its own kMaxChainComponents, and all of them together within the patch's cap
        std::size_t total = 0;
        for (const PatchNodeSpec& ns : spec.nodes)
            if (ns.kind == PatchNodeKind::Chain) total += ns.components.size();
        if (total > patch::kMaxPatchChainComponents)
            return fail(std::to_string(total) + " components in its chain nodes, more than the " +
                        std::to_string(patch::kMaxPatchChainComponents) + " a patch may have");
    }

    // ---- Nodes: ids, kinds, components (kept from `previous` where unchanged).
    std::vector<Building> nodes(nodeCount);
    uint32_t inputNode = UINT32_MAX, outputNode = UINT32_MAX;
    for (uint32_t n = 0; n < nodeCount; ++n) {
        const PatchNodeSpec& ns = spec.nodes[n];
        Building& b = nodes[n];
        b.spec = &ns;
        const std::string name = "node " + quoted(ns.id);
        if (ns.id.empty()) return fail("node " + std::to_string(n) + " has no id");
        if (ns.id.size() > patch::kMaxIdLength)
            return fail("node " + std::to_string(n) + "'s id is longer than " + std::to_string(patch::kMaxIdLength) +
                        " bytes");
        for (uint32_t m = 0; m < n; ++m)
            if (spec.nodes[m].id == ns.id) return fail("two nodes have the id " + quoted(ns.id));
        const CompiledPatch::Node* old = nullptr;
        if (previous)
            for (const auto& p : previous->nodes_)
                if (p.id == ns.id && p.kind == ns.kind && p.instance) old = &p;
        switch (ns.kind) {
            case PatchNodeKind::Input:
            case PatchNodeKind::Output: {
                uint32_t& slot = ns.kind == PatchNodeKind::Input ? inputNode : outputNode;
                if (slot != UINT32_MAX)
                    return fail(name + " is a second " + kindName(ns.kind) + " node; a patch has at most one");
                if (!ns.components.empty()) return fail(name + " is an " + kindName(ns.kind) + " and holds no components");
                slot = n;
                break;
            }
            case PatchNodeKind::Chain: {
                if (ns.components.size() > patch::kMaxChainComponents)
                    return fail(name + " holds " + std::to_string(ns.components.size()) + " components, more than " +
                                std::to_string(patch::kMaxChainComponents));
                if (old && old->instance->chain && old->instance->chain->sameComponents(ns.components, sampleRate)) {
                    b.instance = old->instance;
                    b.kept = true;
                    break;
                }
                std::string why;
                auto chain = ComponentChain::build(registry, ns.components, sampleRate, why);
                if (!chain) return fail(name + ": " + why);
                b.instance = std::make_shared<NodeInstance>();
                b.instance->kind = PatchNodeKind::Chain;
                b.instance->sampleRate = sampleRate;
                b.instance->chain = std::move(chain);
                break;
            }
            case PatchNodeKind::Module: {
                if (ns.components.size() != 1) return fail(name + " is a module and holds exactly one component");
                const ComponentSpec& c = ns.components[0];
                const std::string what = name + " (" + quoted(c.id) + ")";
                if (c.bypass) return fail(what + " is bypassed; a module node has no bypass (use a chain node)");
                if (!c.samples.empty() || c.audioTrack)
                    return fail(what + " has samples or audio clips; use a chain node");
                if (!findComponentDescriptor(registry, c.id, c.params))
                    return fail(what + ": no such component is loaded");
                const std::string structure = componentStructure(c);
                if (old && old->instance->processor && old->instance->component == c.id &&
                    old->instance->structure == structure && old->instance->sampleRate == sampleRate) {
                    b.instance = old->instance;
                    b.kept = true;
                } else {
                    auto processor = createComponent(registry, c.id, c.params);
                    if (!processor) return fail(what + ": its processor could not be made");
                    if (auto* rack = dynamic_cast<RackContainer*>(processor.get())) {
                        std::string why;
                        if (!rack->configure(registry, c.params, c.lenient, why)) return fail(what + ": " + why);
                    }
                    if (!processor->activate(sampleRate, patch::kWideSubBlock))
                        return fail(what + " could not prepare for playback");
                    b.instance = std::make_shared<NodeInstance>();
                    b.instance->kind = PatchNodeKind::Module;
                    b.instance->component = c.id;
                    b.instance->structure = structure;
                    b.instance->sampleRate = sampleRate;
                    b.instance->processor = std::move(processor);
                    if (c.hasState) {
                        const ModuleDescriptor& d = b.instance->processor->descriptor();
                        const bool fits = c.state.size() <= d.maxStateBytes;
                        if (!(fits && b.instance->processor->loadState(c.state.data(),
                                                                       static_cast<uint32_t>(c.state.size()),
                                                                       c.stateVersion)) &&
                            !c.lenient)
                            return fail(what + (fits ? " refused its saved state" : "'s saved state is too large"));
                    }
                }
                ModuleProcessor& p = *b.instance->processor;
                b.descriptor = &p.descriptor();
                if (validateModuleDescriptor(*b.descriptor) != ModuleValidation::Ok)
                    return fail(what + " has an invalid descriptor");
                if (b.descriptor->portCount > patch::kMaxPortsPerNode)
                    return fail(what + " has " + std::to_string(b.descriptor->portCount) + " ports, more than the " +
                                std::to_string(patch::kMaxPortsPerNode) + " a node may have");
                if (auto* e = dynamic_cast<fx::EffectBase*>(&p); e && !e->optionalPorts().empty()) b.effect = e;
                // Values: every named one must exist (a merged device's other variants' and a rack's left-over
                // children's are ignored, as a chain does).
                const ModuleDescriptor& d = *b.descriptor;
                std::vector<double> all(d.parameterCount);
                for (uint32_t k = 0; k < d.parameterCount; ++k) all[k] = d.parameters[k].defaultValue;
                for (const auto& [id, value] : c.params) {
                    uint32_t k = 0;
                    while (k < d.parameterCount && d.parameters[k].id != id) ++k;
                    if (k == d.parameterCount) {
                        if (c.lenient || isOtherVariantParameter(c.id, id) ||
                            (!structure.empty() && id.find('.') != std::string::npos))
                            continue;
                        return fail(what + " has no parameter " + quoted(id));
                    }
                    if (!std::isfinite(value)) return fail(what + "'s parameter " + quoted(id) + " is not finite");
                    all[k] = constrainParameter(d.parameters[k], value);
                    b.values.emplace_back(k, all[k]);
                }
                if (b.kept) b.oldValues = &old->values;
                b.all = all;
                if (const auto* v = dynamic_cast<const VariableLatency*>(&p))
                    b.latency = v->latencyFor(all.data(), d.parameterCount);
                else
                    b.latency = d.latencyFrames;
                break;
            }
        }
        if (ns.kind == PatchNodeKind::Chain) b.latency = b.instance->chain->latencyFrames();
    }
    if (outputNode == UINT32_MAX) return fail("there is no output node");

    // ---- Wires: endpoints, types, gains, counts.
    auto findNode = [&](const std::string& id) -> uint32_t {
        for (uint32_t n = 0; n < nodeCount; ++n)
            if (spec.nodes[n].id == id) return n;
        return UINT32_MAX;
    };
    // The port `name` of node n, as an output (input = false) or an input.
    auto findPort = [&](uint32_t n, const std::string& name, bool input, Endpoint& out) -> bool {
        const Building& b = nodes[n];
        out.node = n;
        out.optional = false;
        switch (b.spec->kind) {
            case PatchNodeKind::Input:
                if (input || name != "out") return false;
                out.index = 1;
                out.shape = kStereoOut;
                return true;
            case PatchNodeKind::Output:
                if (!input || name != "in") return false;
                out.index = 0;
                out.shape = kStereoIn;
                return true;
            case PatchNodeKind::Chain:
                if (name != (input ? "in" : "out")) return false;
                out.index = input ? 0 : 1;
                out.shape = input ? kStereoIn : kStereoOut;
                return true;
            case PatchNodeKind::Module: {
                const ModuleDescriptor& d = *b.descriptor;
                for (uint32_t k = 0; k < d.portCount; ++k)
                    if (d.ports[k].id == name) {
                        if (d.ports[k].input != input) return false;
                        out.index = k;
                        out.shape = d.ports[k];
                        return true;
                    }
                if (!b.effect) return false;
                const auto offered = b.effect->optionalPorts();
                for (uint32_t k = 0; k < offered.size() && k < fx::EffectBase::kMaxOptionalPorts; ++k)
                    if (offered[k].id == name) {
                        if (offered[k].input != input) return false;
                        out.index = k;
                        out.optional = true;
                        out.shape = audioPort(offered[k].id, input);
                        return true;
                    }
                return false;
            }
        }
        return false;
    };
    struct Wire {
        Endpoint from, to;
        float gain = 1.0f;
        bool feedback = false, limiter = true, compensated = false;
        uint64_t delay = 0;
    };
    std::vector<Wire> wires(spec.wires.size());
    uint32_t feedbackWires = 0;
    for (std::size_t w = 0; w < spec.wires.size(); ++w) {
        const PatchWireSpec& ws = spec.wires[w];
        const std::string name = "wire " + std::to_string(w) + " (" + ws.from.node + "." + ws.from.port + " -> " +
                                 ws.to.node + "." + ws.to.port + ")";
        if (ws.from.port.size() > patch::kMaxIdLength || ws.to.port.size() > patch::kMaxIdLength)
            return fail(name + " names a port longer than " + std::to_string(patch::kMaxIdLength) + " bytes");
        const uint32_t a = findNode(ws.from.node), z = findNode(ws.to.node);
        if (a == UINT32_MAX) return fail(name + " starts at " + quoted(ws.from.node) + ", which is not a node");
        if (z == UINT32_MAX) return fail(name + " ends at " + quoted(ws.to.node) + ", which is not a node");
        Wire& wire = wires[w];
        if (!findPort(a, ws.from.port, false, wire.from))
            return fail(name + ": node " + quoted(ws.from.node) + " has no output port " + quoted(ws.from.port));
        if (!findPort(z, ws.to.port, true, wire.to))
            return fail(name + ": node " + quoted(ws.to.node) + " has no input port " + quoted(ws.to.port));
        const PortDescriptor& f = wire.from.shape;
        const PortDescriptor& t = wire.to.shape;
        if (f.type != t.type) return fail(name + " joins ports of different types");
        if (f.type == PortType::Audio && !(portChannelCount(f) == portChannelCount(t) && f.layout == t.layout) &&
            !(f.layout == ChannelLayout::Mono && t.layout == ChannelLayout::Stereo))
            return fail(name + " joins audio ports of different channel layouts (only mono widens into stereo)");
        if (!std::isfinite(ws.gain) || std::fabs(ws.gain) > patch::kMaxWireGain)
            return fail(name + "'s gain is not finite or beyond +/-" + std::to_string(patch::kMaxWireGain));
        if (ws.gain != 1.0 && f.type != PortType::Audio && f.type != PortType::Modulation)
            return fail(name + " has a gain, which only audio and modulation wires take");
        if (ws.feedback && f.type != PortType::Audio) return fail(name + " is a feedback wire but not audio");
        if (ws.feedback && ++feedbackWires > patch::kMaxFeedbackWires)
            return fail("more than " + std::to_string(patch::kMaxFeedbackWires) + " feedback wires (" + name + ")");
        wire.gain = static_cast<float>(ws.gain);
        wire.feedback = ws.feedback;
        wire.limiter = ws.limiter;
        wire.compensated = !ws.feedback && (f.type == PortType::Audio || f.type == PortType::Modulation) &&
                           t.id != "sidechain";
        for (std::size_t v = 0; v < w; ++v) {
            const Wire& o = wires[v];
            if (o.from.node == a && o.from.index == wire.from.index && o.from.optional == wire.from.optional &&
                o.to.node == z && o.to.index == wire.to.index && o.to.optional == wire.to.optional)
                return fail(name + " repeats wire " + std::to_string(v));
        }
        // An input takes one wire unless it sums: the Chain and Output inputs and summing descriptor ports.
        const PatchNodeKind zk = spec.nodes[z].kind;
        const bool sums = zk == PatchNodeKind::Output || zk == PatchNodeKind::Chain || (!wire.to.optional && t.summing);
        if (!sums)
            for (std::size_t v = 0; v < w; ++v)
                if (wires[v].to.node == z && wires[v].to.index == wire.to.index && wires[v].to.optional == wire.to.optional)
                    return fail(name + ": input " + quoted(ws.to.node + "." + ws.to.port) +
                                " is not summing and already has wire " + std::to_string(v));
        if (zk == PatchNodeKind::Output || zk == PatchNodeKind::Chain) ++nodes[z].wiresIn;
        for (const Endpoint* e : {&wire.from, &wire.to})
            if (e->optional) {
                auto& list = nodes[e->node].wiredOptional;
                if (std::find(list.begin(), list.end(), e->index) == list.end()) list.push_back(e->index);
            }
    }
    for (uint32_t n = 0; n < nodeCount; ++n) {
        Building& b = nodes[n];
        std::sort(b.wiredOptional.begin(), b.wiredOptional.end());
        if (b.descriptor && b.descriptor->portCount + b.wiredOptional.size() > patch::kMaxPortsPerNode)
            return fail("node " + quoted(b.spec->id) + " would have more than " +
                        std::to_string(patch::kMaxPortsPerNode) + " ports with its wired optional ports");
    }

    // ---- Order (every loop must hold a feedback wire) and latency compensation.
    std::vector<uint32_t> order;
    {
        std::vector<uint32_t> indegree(nodeCount, 0);
        for (const Wire& w : wires)
            if (!w.feedback) ++indegree[w.to.node];
        std::vector<uint8_t> done(nodeCount, 0);
        for (uint32_t step = 0; step < nodeCount; ++step) {
            uint32_t next = UINT32_MAX;
            for (uint32_t n = 0; n < nodeCount && next == UINT32_MAX; ++n)
                if (!done[n] && indegree[n] == 0) next = n;
            if (next == UINT32_MAX) {
                uint32_t stuck = 0;
                while (done[stuck]) ++stuck;
                return fail("wires form a loop through node " + quoted(spec.nodes[stuck].id) +
                            " with no feedback wire in it; mark one of its wires as feedback");
            }
            done[next] = 1;
            order.push_back(next);
            for (const Wire& w : wires)
                if (!w.feedback && w.from.node == next) --indegree[w.to.node];
        }
    }
    for (uint32_t n : order) {
        uint64_t t = 0;
        for (const Wire& w : wires)
            if (w.compensated && w.to.node == n)
                t = std::max(t, nodes[w.from.node].time + nodes[w.from.node].latency);
        nodes[n].time = t;
    }
    std::size_t delayBytes = 0;  // every compensation delay's line together (patch::kMaxDelayLineBytes)
    for (std::size_t w = 0; w < wires.size(); ++w) {
        Wire& wire = wires[w];
        if (!wire.compensated) continue;
        wire.delay = nodes[wire.to.node].time - (nodes[wire.from.node].time + nodes[wire.from.node].latency);
        if (wire.delay > patch::kMaxCompensationFrames)
            return fail("wire " + std::to_string(w) + " would need " + std::to_string(wire.delay) +
                        " frames of latency compensation, more than " + std::to_string(patch::kMaxCompensationFrames));
        delayBytes += static_cast<std::size_t>(wire.delay) * channelsOf(wire.from.shape) * sizeof(float);
        if (delayBytes > patch::kMaxDelayLineBytes)
            return fail("its latency compensation would need more than the " +
                        std::to_string(patch::kMaxDelayLineBytes >> 20) + " MiB of delay lines a patch may use (" +
                        std::to_string(delayBytes) + " bytes by wire " + std::to_string(w) + ")");
    }

    // ---- The graph: the spec's nodes first, in spec order, then what the wires add.
    std::unique_ptr<CompiledPatch> out(new CompiledPatch());
    CompiledPatch& p = *out;
    p.sampleRate_ = sampleRate;
    std::vector<ModuleProcessor*> processors;
    std::vector<GraphConnection> connections;
    std::vector<std::string> ids;
    auto addOwn = [&](std::unique_ptr<ModuleProcessor> node, std::string id) {
        processors.push_back(node.get());
        p.processors_.push_back(std::move(node));
        ids.push_back(std::move(id));
        return static_cast<uint32_t>(processors.size() - 1);
    };
    for (uint32_t n = 0; n < nodeCount; ++n) {
        Building& b = nodes[n];
        const std::string id = "node:" + b.spec->id;
        switch (b.spec->kind) {
            case PatchNodeKind::Input: b.graph = addOwn(patch_detail::makePass(false, false), id); break;
            case PatchNodeKind::Output: b.graph = addOwn(patch_detail::makePass(b.wiresIn > 1, true), id); break;
            case PatchNodeKind::Chain:
                b.graph = addOwn(patch_detail::makeChainNode(*b.instance->chain, b.wiresIn > 1, sampleRate, p.time_), id);
                break;
            case PatchNodeKind::Module:
                if (b.effect) {
                    std::vector<WiredOptional> wired;
                    for (uint32_t k : b.wiredOptional) wired.push_back({k, b.effect->optionalPorts()[k].input});
                    b.graph = addOwn(patch_detail::makeOptionalAdapter(*b.effect, std::move(wired)), id);
                } else {
                    processors.push_back(b.instance->processor.get());
                    ids.push_back(id);
                    b.graph = static_cast<uint32_t>(processors.size() - 1);
                }
                break;
        }
        if (b.instance) p.instances_.push_back(b.instance);
        p.nodes_.push_back({b.spec->id, b.spec->kind, b.instance, b.graph, b.all});
        if (b.kept) ++p.kept_;
    }
    // A graph port of an endpoint: a wired optional port follows its node's descriptor ports, in wiredOptional order.
    auto graphPort = [&](const Endpoint& e) -> uint32_t {
        if (!e.optional) return e.index;
        const Building& b = nodes[e.node];
        const auto at = std::find(b.wiredOptional.begin(), b.wiredOptional.end(), e.index);
        return b.descriptor->portCount + static_cast<uint32_t>(at - b.wiredOptional.begin());
    };
    uint32_t added = 0;
    auto tag = [&](const char* what) { return std::string("~") + what + std::to_string(added++); };
    for (const Wire& w : wires) {
        const uint32_t to = nodes[w.to.node].graph, toPort = graphPort(w.to);
        if (w.feedback) {
            auto ring = std::make_unique<FeedbackRing>();
            ring->channels = channelsOf(w.from.shape);
            ring->data.assign(static_cast<std::size_t>(ring->channels) * FeedbackRing::kRingFrames, 0.0f);
            const uint32_t send = addOwn(patch_detail::makeSend(w.from.shape, w.gain, *ring, p.clock_), tag("send"));
            const uint32_t ret =
                addOwn(patch_detail::makeReturn(w.from.shape, w.limiter, sampleRate, *ring, p.clock_), tag("return"));
            p.rings_.push_back(std::move(ring));
            connections.push_back({nodes[w.from.node].graph, graphPort(w.from), send, 0});
            connections.push_back({ret, 0, to, toPort});
            continue;
        }
        uint32_t node = nodes[w.from.node].graph, port = graphPort(w.from);
        if (w.delay) {
            const uint32_t d = addOwn(patch_detail::makeDelay(w.from.shape, static_cast<uint32_t>(w.delay)), tag("delay"));
            connections.push_back({node, port, d, 0});
            node = d;
            port = 1;
        }
        if (w.gain != 1.0f) {
            const uint32_t g = addOwn(patch_detail::makeGain(w.from.shape, w.gain), tag("gain"));
            connections.push_back({node, port, g, 0});
            node = g;
            port = 1;
        }
        connections.push_back({node, port, to, toPort});
    }
    // A first audio input no wire feeds would read the patch's input (the executor's host input): give it silence,
    // one source per shape. The Input node alone reads the patch's input.
    std::vector<std::pair<PortDescriptor, uint32_t>> silences;
    const std::size_t graphCount = processors.size();
    for (uint32_t g = 0; g < graphCount; ++g) {
        if (inputNode != UINT32_MAX && g == nodes[inputNode].graph) continue;
        const ModuleDescriptor& d = processors[g]->descriptor();
        uint32_t first = UINT32_MAX;
        for (uint32_t k = 0; k < d.portCount && first == UINT32_MAX; ++k)
            if (d.ports[k].input && d.ports[k].type == PortType::Audio) first = k;
        if (first == UINT32_MAX) continue;
        bool fed = false;
        for (const GraphConnection& c : connections) fed = fed || (c.destinationNode == g && c.destinationPort == first);
        if (fed) continue;
        const PortDescriptor& shape = d.ports[first];
        uint32_t source = UINT32_MAX;
        for (const auto& [s, node] : silences)
            if (s.layout == shape.layout && portChannelCount(s) == portChannelCount(shape)) source = node;
        if (source == UINT32_MAX) {
            source = addOwn(patch_detail::makeSilence(shape), tag("silence"));
            silences.emplace_back(shape, source);
        }
        connections.push_back({source, 0, g, first});
    }

    // ---- Prepare the executor.
    p.graphIds_ = std::move(ids);
    std::vector<GraphNode> graphNodes;
    graphNodes.reserve(processors.size());
    for (std::size_t g = 0; g < processors.size(); ++g)
        graphNodes.push_back({p.graphIds_[g], &processors[g]->descriptor()});
    GraphResourceBudget budget;
    budget.maxWorkingBytes = std::size_t{64} << 20;
    budget.maxEventsPerPort = patch::kMaxEvents;
    const GraphError prepared = p.executor_.prepare(graphNodes, connections, processors, nodes[outputNode].graph,
                                                    patch::kWideSubBlock, sampleRate, budget);
    if (prepared != GraphError::Ok)
        return fail(std::string("the compiled graph was refused: ") + graphErrorText(prepared));
    for (uint32_t n = 0; n < nodeCount; ++n) {
        const Building& b = nodes[n];
        if (b.oldValues && b.oldValues->size() == b.all.size()) {
            // A kept module starts where the playing patch has it (its values, knob moves included), so nothing jumps
            // at the swap, and ramps from there to the spec's values (unnamed: defaults, as a fresh build has them).
            for (uint32_t k = 0; k < b.all.size(); ++k) {
                const double from = (*b.oldValues)[k];
                if (!p.executor_.setInitialParameter(b.graph, k, from))
                    return fail("node " + quoted(spec.nodes[n].id) + " refused a value");
                // The queue full (more moves than kParameterQueueCapacity): that value jumps instead.
                if (from != b.all[k] && !p.executor_.queueParameter(b.graph, k, b.all[k]))
                    p.executor_.setInitialParameter(b.graph, k, b.all[k]);
            }
            continue;
        }
        for (const auto& [k, value] : b.values)
            if (!p.executor_.setInitialParameter(b.graph, k, value))
                return fail("node " + quoted(spec.nodes[n].id) + " refused a value");
    }
    p.pieceEvents_.resize(patch::kMaxEvents);
    p.graph_ = std::move(processors);
    p.latency_ = nodes[outputNode].time;
    p.subBlock_ = feedbackWires ? patch::kSubBlock : patch::kWideSubBlock;
    // Last, once nothing can fail: a kept chain takes the spec's values (it plays on meanwhile; they ramp).
    for (uint32_t n = 0; n < nodeCount; ++n)
        if (nodes[n].kept && nodes[n].instance->chain) nodes[n].instance->chain->setValues(spec.nodes[n].components);
    return out;
} catch (const std::bad_alloc&) {
    error = "patch: out of memory";
    return nullptr;
} catch (const std::exception& e) {
    error = std::string("patch: ") + e.what();
    return nullptr;
}

bool CompiledPatch::process(const float* inLeft, const float* inRight, float* outLeft, float* outRight,
                            uint32_t frames, const EventInput* events, const ChainTime* time) noexcept {
    if (!outLeft || !outRight || frames == 0) return false;
    const EventInput none{};
    const EventInput& ev = events ? *events : none;
    bool ordered = ev.count <= patch::kMaxEvents && (ev.count == 0 || ev.events);
    for (uint32_t e = 0; ordered && e < ev.count; ++e)
        ordered = ev.events[e].frame < frames && (e == 0 || ev.events[e - 1].frame <= ev.events[e].frame);
    if (!ordered || !executor_.ready()) {
        std::fill_n(outLeft, frames, 0.0f);
        std::fill_n(outRight, frames, 0.0f);
        return false;
    }
    const bool hasInput = executor_.inputChannels() == 2;
    bool ok = true;
    uint32_t done = 0, e = 0;
    while (done < frames) {
        const uint32_t n = std::min<uint32_t>(frames - done, subBlock_ - static_cast<uint32_t>(sincePlay_ % subBlock_));
        uint32_t count = 0;
        for (; e < ev.count && ev.events[e].frame < done + n; ++e) {
            pieceEvents_[count] = ev.events[e];
            pieceEvents_[count++].frame -= done;
        }
        if (time) {
            pieceTime_ = *time;
            pieceTime_.start += done;
            if (time->steps) pieceTime_.steps = time->steps + done;
            time_ = &pieceTime_;
        } else {
            time_ = nullptr;
        }
        const float* in[2] = {inLeft ? inLeft + done : zero_, inRight ? inRight + done : zero_};
        float* outs[2] = {outLeft + done, outRight + done};
        const ConstChannelBufferView input{in, hasInput ? 2u : 0u, n};
        const ChannelBufferView output{outs, 2, n};
        ok = executor_.process(input, output, n, EventInput{pieceEvents_.data(), count}) && ok;
        clock_ += n;
        sincePlay_ += n;
        done += n;
    }
    time_ = nullptr;
    return ok;
}

void CompiledPatch::reset() noexcept {
    for (ModuleProcessor* node : graph_) node->reset();  // a Chain node resets its chain, an adapter its effect
    sincePlay_ = 0;
}

bool CompiledPatch::setParameter(std::string_view node, uint32_t component, std::string_view parameter,
                                 double value) noexcept {
    if (!std::isfinite(value)) return false;
    for (Node& n : nodes_) {
        if (n.id != node || !n.instance) continue;
        if (n.instance->chain) {
            try {
                return n.instance->chain->setValue(component, std::string(parameter), value);
            } catch (...) {
                return false;
            }
        }
        if (component != 0 || !n.instance->processor) return false;
        const ModuleDescriptor& d = n.instance->processor->descriptor();
        for (uint32_t k = 0; k < d.parameterCount; ++k)
            if (d.parameters[k].id == parameter) {
                if (!executor_.queueParameter(n.graphNode, k, value)) return false;
                if (k < n.values.size()) n.values[k] = constrainParameter(d.parameters[k], value);
                return true;
            }
        return false;
    }
    return false;
}

bool PatchRuntime::publish(CompiledPatch* next) noexcept {
    if (!next) return false;
    CompiledPatch* expected = nullptr;
    return pending_.compare_exchange_strong(expected, next, std::memory_order_release, std::memory_order_relaxed);
}

bool PatchRuntime::process(const float* inLeft, const float* inRight, float* outLeft, float* outRight,
                           uint32_t frames, const EventInput* events, const ChainTime* time) noexcept {
    if (retired_.load(std::memory_order_acquire) == nullptr) {
        if (CompiledPatch* next = pending_.exchange(nullptr, std::memory_order_acq_rel)) {
            if (active_) {
                next->sincePlay_ = active_->sincePlay_;  // the sub-block grid carries on
                retired_.store(active_, std::memory_order_release);
            }
            active_ = next;
        }
    }
    if (active_ && playMarked_) {
        active_->markPlay();
        playMarked_ = false;
    }
    if (!active_) {
        if (outLeft && outRight) {
            std::fill_n(outLeft, frames, 0.0f);
            std::fill_n(outRight, frames, 0.0f);
        }
        return false;
    }
    return active_->process(inLeft, inRight, outLeft, outRight, frames, events, time);
}

CompiledPatch* PatchRuntime::collectRetired() noexcept { return retired_.exchange(nullptr, std::memory_order_acq_rel); }

CompiledPatch* PatchRuntime::takeActiveAfterStop() noexcept {
    CompiledPatch* result = active_;
    active_ = nullptr;
    return result;
}

CompiledPatch* PatchRuntime::takePendingAfterStop() noexcept {
    return pending_.exchange(nullptr, std::memory_order_acq_rel);
}

}  // namespace caw
