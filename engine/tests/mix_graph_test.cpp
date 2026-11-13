// Speed phases 5a and 5b, the serial groundwork for a parallel mixer: per-node scratch, pulled sends and keys,
// per-slot modulation output, gain factor at construction, and the mix graph run level by level.
#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "builtin_components.h"
#include "component_chain.h"
#include "detmath.h"
#include "engine.h"
#include "graph.h"
#include "modulation_links.h"
#include "module_registry.h"
#include "project.h"
#include "route_math.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;
using cawtest::Shape;

namespace {

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

// A small deterministic generator (the standard distributions differ between libraries).
struct Rng {
    uint64_t s;
    explicit Rng(uint64_t seed) : s(seed * 0x9E3779B97F4A7C15ull + 1) {}
    uint32_t next() {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return static_cast<uint32_t>(s >> 11);
    }
    int below(int n) { return static_cast<int>(next() % static_cast<uint32_t>(n)); }
    double unit() { return static_cast<double>(next() % 1000001u) / 1000000.0; }
};

// ---- the executor's levels over random graphs ----

// A node of the random graphs: its summed input times a gain, its own tone, and what it pulls from the nodes it
// depends on (their last output, as the mixer's pulled sends read their sources' route buffers).
struct PullNet {
    std::vector<std::array<float, 2 * 64>> last;
    std::vector<std::vector<uint32_t>> pulls;
};

const PortDescriptor kBusPorts[2] = {{"in", PortType::Audio, ChannelLayout::Stereo, true, 0, true},
                                     {"out", PortType::Audio, ChannelLayout::Stereo, false}};
const ModuleDescriptor kBusModule{"test.mix.node", 1, kBusPorts, 2, nullptr, 0};

class PullNode final : public ModuleProcessor {
public:
    PullNode(PullNet& net, uint32_t index) : net_(net), index_(index) {}
    const ModuleDescriptor& descriptor() const noexcept override { return kBusModule; }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        const float gain = 0.5f + 0.125f * static_cast<float>(index_ % 5);
        for (uint32_t c = 0; c < 2; ++c)
            for (uint32_t i = 0; i < b.frames; ++i) {
                float v = b.input.channels[c][i] * gain +
                          static_cast<float>(std::sin(0.01 * static_cast<double>(frame_ + i) * (index_ + 1 + c)));
                for (uint32_t p : net_.pulls[index_]) v += 0.25f * net_.last[p][c * 64 + i];
                b.output.channels[c][i] = v;
                net_.last[index_][c * 64 + i] = v;
            }
        frame_ += b.frames;
        return true;
    }
private:
    PullNet& net_;
    uint32_t index_;
    uint64_t frame_ = 0;
};

struct RandomGraph {
    uint32_t nodes = 0, output = 0;
    std::vector<uint32_t> order;
    std::vector<GraphConnection> edges;
    std::vector<GraphDependency> dependencies;
};

RandomGraph randomGraph(Rng& rng) {
    RandomGraph g;
    g.nodes = 2 + static_cast<uint32_t>(rng.below(40));
    g.output = static_cast<uint32_t>(rng.below(static_cast<int>(g.nodes)));
    std::vector<uint32_t> all(g.nodes);
    for (uint32_t n = 0; n < g.nodes; ++n) all[n] = n;
    for (uint32_t n = g.nodes - 1; n > 0; --n) std::swap(all[n], all[static_cast<uint32_t>(rng.below(static_cast<int>(n + 1)))]);
    for (uint32_t n : all)
        if (n == g.output || rng.below(8) != 0) g.order.push_back(n);  // some nodes left out
    const uint32_t count = static_cast<uint32_t>(g.order.size());
    for (uint32_t a = 0; a < count; ++a)
        for (uint32_t b = a + 1; b < count; ++b) {
            const uint32_t from = g.order[a], to = g.order[b];
            if (from == g.output) continue;  // the output feeds nothing
            const int roll = rng.below(10);
            if (roll == 0) g.edges.push_back(GraphConnection{from, 1, to, 0});
            else if (roll == 1) g.dependencies.push_back(GraphDependency{from, to});
        }
    return g;
}

struct Executor {
    PullNet net;
    std::vector<std::unique_ptr<PullNode>> owned;
    std::vector<std::string> ids;
    GraphExecutor exec;
    bool prepare(const RandomGraph& g, bool levels) {
        net.last.assign(g.nodes, {});
        net.pulls.assign(g.nodes, {});
        for (const GraphDependency& d : g.dependencies) net.pulls[d.after].push_back(d.before);
        std::vector<GraphNode> nodes;
        std::vector<ModuleProcessor*> processors;
        ids.reserve(g.nodes);
        for (uint32_t n = 0; n < g.nodes; ++n) {
            ids.push_back("n" + std::to_string(n));
            owned.push_back(std::make_unique<PullNode>(net, n));
        }
        for (uint32_t n = 0; n < g.nodes; ++n) {
            nodes.push_back({ids[n], &kBusModule});
            processors.push_back(owned[n].get());
        }
        GraphResourceBudget budget;
        budget.maxWorkingBytes = 64u * 1024u * 1024u;
        if (exec.prepareRouted(nodes, processors, g.output, 64, 48000.0, budget, g.nodes,
                               static_cast<uint32_t>(g.dependencies.size()) + 1) != GraphError::Ok) return false;
        exec.setLevelOrderForTest(levels);
        return exec.setRouting(g.edges.data(), static_cast<uint32_t>(g.edges.size()), g.order.data(),
                               static_cast<uint32_t>(g.order.size()), g.dependencies.data(),
                               static_cast<uint32_t>(g.dependencies.size()));
    }
};

uint32_t bitsOf(float x) { return std::bit_cast<uint32_t>(x); }

}  // namespace

TEST(mix_graph_levels_are_a_valid_topological_order_over_random_graphs) {
    Rng rng(5);
    int deep = 0;
    for (int trial = 0; trial < 300; ++trial) {
        const RandomGraph g = randomGraph(rng);
        Executor x;
        CHECK(x.prepare(g, true));
        const GraphExecutor& e = x.exec;
        const uint32_t count = static_cast<uint32_t>(g.order.size());
        CHECK_EQ(e.runCount(), count);
        CHECK(e.levelCount() >= 1);
        // Every listed node once, in exactly one level; within a level in the given order.
        std::vector<uint32_t> level(g.nodes, UINT32_MAX), position(g.nodes, UINT32_MAX);
        for (uint32_t k = 0; k < count; ++k) position[g.order[k]] = k;
        CHECK_EQ(e.levelStart(0), 0u);
        CHECK_EQ(e.levelStart(e.levelCount()), count);
        for (uint32_t l = 0; l < e.levelCount(); ++l) {
            CHECK(e.levelStart(l) < e.levelStart(l + 1));  // no empty level
            for (uint32_t k = e.levelStart(l); k < e.levelStart(l + 1); ++k) {
                const uint32_t n = e.orderedNode(k);
                CHECK(n < g.nodes && position[n] != UINT32_MAX && level[n] == UINT32_MAX);
                if (n < g.nodes) level[n] = l;
                if (k > e.levelStart(l)) CHECK(position[e.orderedNode(k - 1)] < position[n]);
            }
        }
        // Every edge and dependency goes to a later level; the output is alone in the last one.
        for (const GraphConnection& c : g.edges) CHECK(level[c.sourceNode] < level[c.destinationNode]);
        for (const GraphDependency& d : g.dependencies) CHECK(level[d.before] < level[d.after]);
        const uint32_t last = e.levelCount() - 1;
        CHECK_EQ(level[g.output], last);
        CHECK(count == 1 || e.levelStart(last) + 1 == count);
        // Levels are as shallow as the graph allows: each node above 0 (but the output) reads one a level down.
        for (uint32_t n : g.order) {
            if (n == g.output || level[n] == 0) continue;
            bool below = false;
            for (const GraphConnection& c : g.edges) below = below || (c.destinationNode == n && level[c.sourceNode] + 1 == level[n]);
            for (const GraphDependency& d : g.dependencies) below = below || (d.after == n && level[d.before] + 1 == level[n]);
            CHECK(below);
        }
        if (e.levelCount() >= 4) ++deep;
    }
    CHECK(deep > 50);  // the trials reach several levels
}

TEST(mix_graph_level_by_level_output_is_bit_identical_to_the_given_order) {
    Rng rng(11);
    for (int trial = 0; trial < 60; ++trial) {
        const RandomGraph g = randomGraph(rng);
        Executor a, b;
        CHECK(a.prepare(g, true));
        CHECK(b.prepare(g, false));
        CHECK_EQ(b.exec.levelCount(), 1u);
        float la[64], ra[64], lb[64], rb[64];
        bool same = true;
        for (int block = 0; block < 8; ++block) {
            const uint32_t frames = 1 + static_cast<uint32_t>((block * 23) % 64);
            CHECK(a.exec.process(nullptr, nullptr, la, ra, frames));
            CHECK(b.exec.process(nullptr, nullptr, lb, rb, frames));
            for (uint32_t i = 0; i < frames; ++i)
                same = same && bitsOf(la[i]) == bitsOf(lb[i]) && bitsOf(ra[i]) == bitsOf(rb[i]);
        }
        CHECK(same);
    }
}

TEST(mix_graph_routing_refuses_bad_dependencies_and_keeps_the_previous_levels) {
    Rng rng(3);
    RandomGraph g;
    g.nodes = 4;
    g.output = 3;
    g.order = {0, 1, 2, 3};
    g.edges = {{0, 1, 3, 0}};
    g.dependencies = {{0, 1}, {1, 2}};
    Executor x;
    CHECK(x.prepare(g, true));
    CHECK_EQ(x.exec.levelCount(), 4u);  // 0, then 1, then 2, then the output
    const GraphDependency backwards[] = {{2, 1}};
    const GraphDependency unlisted[] = {{0, 2}};
    const GraphDependency fromOutput[] = {{3, 2}};
    const GraphConnection outOfOutput[] = {{3, 1, 2, 0}};
    const uint32_t without1[] = {0, 2, 3};
    CHECK(!x.exec.setRouting(nullptr, 0, g.order.data(), 4, backwards, 1));
    CHECK(!x.exec.setRouting(nullptr, 0, without1, 3, g.dependencies.data(), 1));  // 0 -> 1, 1 unlisted
    CHECK(x.exec.setRouting(nullptr, 0, without1, 3, unlisted, 1));
    CHECK_EQ(x.exec.levelCount(), 3u);
    CHECK(!x.exec.setRouting(nullptr, 0, g.order.data(), 4, fromOutput, 1));
    CHECK(!x.exec.setRouting(outOfOutput, 1, g.order.data(), 4, nullptr, 0));
    CHECK(!x.exec.setRouting(nullptr, 0, g.order.data(), 4, g.dependencies.data(), 99));  // over the reserve
    CHECK_EQ(x.exec.levelCount(), 3u);  // the last accepted routing still holds
    (void)rng;
}

// ---- the Engine ----

namespace {

ComponentSpec ducker(const std::string& key, Rng& rng) {
    ComponentSpec d;
    d.id = "org.caw.ducker";
    d.params = {{"mode", static_cast<double>(rng.below(2))}, {"depth", 0.5 + 0.5 * rng.unit()}, {"attack", 1.0},
                {"hold", 5.0}, {"release", 40.0 + 100.0 * rng.unit()}};
    d.hasKey = true;
    d.key.layer = key;
    d.key.pre = rng.below(2) == 0;
    d.key.level = 0.5 + 1.5 * rng.unit();
    return d;
}

ComponentSpec latent() {  // a transparent compressor: 240 frames of latency, so routes get compensation delays
    ComponentSpec c;
    c.id = "org.caw.compressor";
    c.params = {{"ratio", 1.0}, {"auto_makeup", 0.0}, {"makeup", 0.0}, {"threshold", 0.0}};
    return c;
}

// A random mix with no routing loop: buses b0.. (a bus's parent and its sends go to lower-numbered buses), tracks
// t0.. under any bus or none, sending to any bus, keying later tracks' and any bus's duckers (a bus is keyed only by
// tracks), some playing notes (the ducker's Notes mode), some muted (still keying).
ProjectSpec randomMix(uint64_t seed) {
    Rng rng(seed);
    ProjectSpec p;
    p.bpm = 100 + rng.below(60);
    p.loopBars = 1;
    p.master = 0.8;
    p.modules.push_back({"beats", "---\nkind: pattern\n---\n0 C4 1\n3 E4 0.8\n4 G4 1\n8 C4 1\n11 D4 0.5\n12 C5 1\n"});
    const int buses = 1 + rng.below(5), tracks = 2 + rng.below(9);
    for (int j = 0; j < buses; ++j) {
        LayerSpec b;
        b.id = b.name = "b" + std::to_string(j);
        b.folder = true;
        b.busEnabled = true;
        b.volume = 0.5 + 0.7 * rng.unit();
        b.pan = rng.unit() * 2.0 - 1.0;
        if (j > 0 && rng.below(2)) b.parentId = "b" + std::to_string(rng.below(j));
        if (rng.below(3) == 0) b.components.push_back(latent());
        if (rng.below(3) == 0) b.components.push_back(ducker("t" + std::to_string(rng.below(tracks)), rng));
        if (j > 0)
            for (int k = rng.below(3); k > 0; --k)
                b.sends.push_back({"b" + std::to_string(rng.below(j)), 0.2 + rng.unit(), rng.below(2) == 0, rng.below(6) == 0});
        p.layers.push_back(b);
    }
    const Shape shapes[] = {Shape::Sine, Shape::Saw, Shape::Square, Shape::Noise};
    for (int i = 0; i < tracks; ++i) {
        const std::string id = "t" + std::to_string(i);
        const Shape shape = shapes[rng.below(4)];
        const cawtest::Params params = {{"level", 0.1 + 0.4 * rng.unit()}, {"freq", 60.0 + 600.0 * rng.unit()}};
        LayerSpec t = rng.below(2) ? cawtest::testSignalNotesLayer(id, shape, "beats", params)
                                   : cawtest::testSignalLayer(id, shape, params);
        t.volume = 0.3 + 0.8 * rng.unit();
        t.pan = rng.unit() * 2.0 - 1.0;
        t.mute = rng.below(6) == 0;
        if (rng.below(2)) t.parentId = "b" + std::to_string(rng.below(buses));
        if (rng.below(4) == 0) t.components.push_back(latent());
        if (i > 0 && rng.below(3) == 0) t.components.push_back(ducker("t" + std::to_string(rng.below(i)), rng));
        for (int k = rng.below(4); k > 0; --k)
            t.sends.push_back({"b" + std::to_string(rng.below(buses)), 0.2 + rng.unit(), rng.below(2) == 0, rng.below(6) == 0});
        p.layers.push_back(t);
    }
    return p;
}

// Renders `p` (with a send's level, a mute and a whole project change part way, so ramps, crossfades and a removed
// bus are heard) in uneven blocks.
std::vector<float> renderMix(const ProjectSpec& p, bool levels, uint32_t* levelCount = nullptr) {
    Engine e(48000);
    if (!levels) e.setMixLevelsForTest(false);
    CHECK(ok(e.setProject(p)));
    e.play();
    static const int sizes[] = {64, 37, 1, 64, 13, 100, 7, 256};
    std::vector<float> out;
    float l[256], r[256];
    for (int k = 0; k < 160; ++k) {
        const int n = sizes[k % 8];
        e.process(l, r, n);
        out.insert(out.end(), l, l + n);
        out.insert(out.end(), r, r + n);
        if (k == 0 && levelCount) *levelCount = e.mixGraphLevelsForTest();
        if (k == 40)
            for (const LayerSpec& layer : p.layers)
                if (!layer.sends.empty()) {
                    e.setSend(layer.id, 0, 0.1, !layer.sends[0].pre, false);
                    break;
                }
        if (k == 60) e.setLayerMix(p.layers.back().id, 0.9, 0.3, true, false);
        if (k == 90) {
            ProjectSpec q = p;  // the first bus goes (its children and sends then go elsewhere or nowhere)
            const std::string gone = q.layers.front().id;
            q.layers.erase(q.layers.begin());
            for (LayerSpec& layer : q.layers) {
                if (layer.parentId == gone) layer.parentId.clear();
                std::erase_if(layer.sends, [&](const SendSpec& s) { return s.to == gone; });
                for (ComponentSpec& c : layer.components)
                    if (c.hasKey && c.key.layer == gone) c.hasKey = false;
            }
            CHECK(ok(e.setProject(q)));
        }
    }
    CHECK_EQ(e.routingRejections(), 0u);
    return out;
}

}  // namespace

TEST(mix_graph_engine_level_by_level_is_bit_identical_to_the_old_order) {
    int deep = 0;
    for (uint64_t seed = 1; seed <= 24; ++seed) {
        const ProjectSpec p = randomMix(seed);
        uint32_t levels = 0;
        const std::vector<float> a = renderMix(p, true, &levels);
        const std::vector<float> b = renderMix(p, false);
        CHECK_EQ(a.size(), b.size());
        bool same = a.size() == b.size();
        float peak = 0;
        for (size_t i = 0; same && i < a.size(); ++i) {
            same = bitsOf(a[i]) == bitsOf(b[i]);
            peak = std::max(peak, std::fabs(a[i]));
        }
        CHECK(same);
        CHECK(peak > 1e-3f);  // it sounds
        if (levels >= 4) ++deep;
    }
    CHECK(deep > 0);  // some mixes nest (tracks, buses, sends and keys over several levels)
}

TEST(mix_graph_a_bus_sums_its_sends_in_the_order_its_sources_run) {
    // a (a large DC) then b and c (each about a third of a's float step) send into "fx": in that order b and c are
    // each lost under a; summed the other way round they would add up to a step. The bus must give the first.
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("a", Shape::Dc, {{"level", 1000.0}}),
                                                cawtest::testSignalLayer("b", Shape::Dc, {{"level", 0x1p-15}}),
                                                cawtest::testSignalLayer("c", Shape::Dc, {{"level", 0x1p-15}})});
    LayerSpec fx;
    fx.id = fx.name = "fx";
    fx.folder = true;
    fx.volume = 1.0;
    p.layers.push_back(fx);
    for (int i = 0; i < 3; ++i) p.layers[static_cast<size_t>(i)].sends.push_back({"fx", 1.0, false, false});
    Engine e(48000);
    e.setMasterBypass(true);
    constexpr int kFrames = 64 * 20;
    std::vector<float> tap[4][2];
    const char* ids[] = {"a", "b", "c", "fx"};
    CHECK(ok(e.setProject(p)));
    for (int k = 0; k < 4; ++k) {
        tap[k][0].assign(kFrames, 0.0f);
        tap[k][1].assign(kFrames, 0.0f);
        CHECK(e.setOutputTap(ids[k], tap[k][0].data(), tap[k][1].data()));
    }
    e.play();
    std::vector<float> l(kFrames), r(kFrames);
    e.process(l.data(), r.data(), kFrames);
    bool inOrder = true, orderMatters = false;
    for (int i = 64 * 10; i < kFrames; ++i) {  // the sends' ramps are over
        const float forward = routeAdd(routeAdd(routeAdd(0.0f, tap[0][0][i]), tap[1][0][i]), tap[2][0][i]);
        const float backward = routeAdd(routeAdd(routeAdd(0.0f, tap[2][0][i]), tap[1][0][i]), tap[0][0][i]);
        inOrder = inOrder && bitsOf(tap[3][0][i]) == bitsOf(forward);
        orderMatters = orderMatters || bitsOf(forward) != bitsOf(backward);
    }
    CHECK(inOrder);
    CHECK(orderMatters);
}

TEST(mix_graph_tracks_crossfading_chains_in_one_chunk_keep_to_their_own_scratch) {
    // a and b each swap their inserts (both crossfading in the same chunks); a's stem is the same bits as when it
    // plays alone, so no node's scratch reaches another's.
    auto project = [](bool withB, bool swapped) {
        ComponentSpec first;
        first.id = "org.caw.utility";
        first.params = {{"gain", swapped ? -6.0 : 3.0}, {"width", 0.5}};
        ComponentSpec second;  // no latency either: a's timing must not depend on b's (latency compensation)
        second.id = "org.caw.filter";
        std::vector<LayerSpec> layers{cawtest::testSignalLayer("a", Shape::Saw, {{"level", 0.3}},
                                                               {swapped ? second : first})};
        if (withB)
            layers.push_back(cawtest::testSignalLayer("b", Shape::Noise, {{"level", 0.4}}, {swapped ? first : second}));
        return cawtest::testSignalProject(layers);
    };
    auto stem = [&](bool withB) {
        Engine e(48000);
        CHECK(ok(e.setProject(project(withB, false))));
        constexpr int kFrames = 64 * 60;
        std::vector<float> l(kFrames, 0.0f), r(kFrames, 0.0f), outL(64), outR(64);
        CHECK(e.setOutputTap("a", l.data(), r.data()));
        e.play();
        for (int k = 0; k < 20; ++k) e.process(outL.data(), outR.data(), 64);
        CHECK(ok(e.setProject(project(withB, true))));  // both chains change: 20 ms crossfades
        CHECK(e.setOutputTap("a", l.data() + 64 * 20, r.data() + 64 * 20));
        for (int k = 20; k < 60; ++k) e.process(outL.data(), outR.data(), 64);
        l.insert(l.end(), r.begin(), r.end());
        return l;
    };
    const std::vector<float> alone = stem(false), mixed = stem(true);
    bool same = alone.size() == mixed.size();
    for (size_t i = 0; same && i < alone.size(); ++i) same = bitsOf(alone[i]) == bitsOf(mixed[i]);
    CHECK(same);
}

TEST(mix_graph_the_track_gain_factor_is_set_with_the_engine) {
    for (double rate : {44100.0, 48000.0, 96000.0}) {
        Engine e(rate);
        CHECK_EQ(e.trackGainCoefForTest(), 1.0 - detExp(-1.0 / (0.005 * rate)));  // before any callback
    }
}

TEST(mix_graph_each_slot_gets_its_own_modulation_output) {
    // Two slots' inserts moved by one LFO: the second slot's call must not overwrite what the first returned (the
    // mixer may run both before either chain reads it).
    ModuleRegistry reg;
    registerBuiltinComponents(reg);
    ComponentSpec utility;
    utility.id = "org.caw.utility";
    std::string error;
    auto chainA = ComponentChain::build(reg, {utility}, 48000.0, error);
    auto chainB = ComponentChain::build(reg, {utility, utility}, 48000.0, error);
    CHECK(chainA && chainB);
    if (!chainA || !chainB) return;
    ProjectSpec p;
    ModulatorSpec lfo;
    lfo.id = "lfo";
    lfo.component.id = "org.caw.mod.lfo";
    p.modulators.push_back(lfo);
    auto link = [](uint32_t id, const std::string& layer, int index, const std::string& param) {
        ModLinkSpec l;
        l.id = id;
        l.source = "lfo";
        l.target = {"component", layer, param, index};
        l.amount = 0.5;
        return l;
    };
    p.modulation = {link(1, "a", 0, "gain"), link(2, "b", 1, "width"), link(3, "b", 0, "pan")};
    ModulationHost host;
    std::vector<std::string> warnings;
    const ModulationHost::LayerLookup lookup = [&](const std::string& id) {
        ModulationHost::LayerInfo info;
        if (id == "a") { info.slot = 0; info.inserts = chainA.get(); }
        if (id == "b") { info.slot = 1; info.inserts = chainB.get(); }
        return info;
    };
    CHECK_EQ(host.update(reg, p, 48000.0, lookup, warnings), std::string());
    host.beginChunk(64, 0, 6000.0, 120.0, 4, true, 1, 0);
    const ChainModulation* a = host.forChain(0, ModChainKind::Inserts, chainA.get(), 0);
    const ChainModulation* b = host.forChain(1, ModChainKind::Inserts, chainB.get(), 0);
    const ChainModulation* bFading = host.forChain(1, ModChainKind::Inserts, chainB.get(), 1);
    CHECK(a && b && bFading);
    if (!a || !b || !bFading) return;
    CHECK(a != b && b != bFading);
    CHECK_EQ(a->count, 1u);
    CHECK_EQ(b->count, 2u);
    CHECK_EQ(a->bindings[0].entry, 0u);
    CHECK_EQ(a->bindings[0].param, static_cast<uint32_t>(chainA->parameterIndexOf(0, "gain")));
    CHECK(a->bindings[0].offset != b->bindings[0].offset && a->bindings[0].offset != b->bindings[1].offset);
    // b's bindings in the plan's target order, the same in both of its outputs.
    for (uint32_t k = 0; k < 2; ++k) {
        CHECK_EQ(b->bindings[k].entry, bFading->bindings[k].entry);
        CHECK_EQ(b->bindings[k].param, bFading->bindings[k].param);
    }
    CHECK(host.forChain(2, ModChainKind::Inserts, chainB.get(), 0) == nullptr);  // a slot with no links
    CHECK(host.forChain(-1, ModChainKind::Master, chainA.get(), 0) == nullptr);  // nothing moves the master
}
