// Speed phase 5c: the mix pool's claim loop, parking and restarts, parallel graph levels against one thread, the
// Engine's random routed mixes on 0 to 4 workers (with injected delays and graph changes), the serial lane for
// third-party components, the Auto mode's hysteresis and a long stress run (the ThreadSanitizer job's).
#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "engine.h"
#include "graph.h"
#include "mix_pool.h"
#include "native_component_test_path.h"
#include "project.h"
#include "test.h"
#include "thread_tuning.h"
#include "test_signal.h"

using namespace caw;
using cawtest::Shape;

namespace {

// `caw_tests --mix-threads N` (test_main.cpp): every Engine made from then on runs its graph with N workers.
const bool kHookSet = (cawtest::mixThreadsHook = [](int workers) { Engine::setMixThreadsForTest(workers); }, true);

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

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

// ---- the pool alone ----

struct Tally {
    std::vector<std::atomic<uint32_t>> hits;
    std::atomic<uint32_t> offCaller{0};
    std::thread::id caller;
    explicit Tally(uint32_t n) : hits(n) {}
};

void tallyTask(void* context, uint32_t index) noexcept {
    Tally& t = *static_cast<Tally*>(context);
    t.hits[index].fetch_add(1, std::memory_order_relaxed);
    if (std::this_thread::get_id() != t.caller) t.offCaller.fetch_add(1, std::memory_order_relaxed);
    volatile double x = 0;  // a little work, so the workers get a share
    for (int i = 0; i < 2000; ++i) x = x + std::sqrt(static_cast<double>(i + index));
}

}  // namespace

TEST(mix_pool_runs_every_task_exactly_once_on_several_threads) {
    for (uint32_t workers = 1; workers <= MixPool::kMaxWorkers; ++workers)
        for (uint32_t delay : {0u, 30u}) {
            MixPool pool;
            CHECK(pool.start(workers));
            CHECK_EQ(pool.workers(), workers);
            pool.setDelayForTest(delay);
            Rng rng(workers * 7 + delay);
            uint32_t offCaller = 0;
            // 300 runs, and on until a worker has taken a task (a loaded machine may leave them all to the caller for
            // a while).
            const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(10);
            for (int run = 0; run < 300 || (offCaller == 0 && std::chrono::steady_clock::now() < until); ++run) {
                const uint32_t n = 1 + static_cast<uint32_t>(rng.below(24));
                Tally t(n);
                t.caller = std::this_thread::get_id();
                pool.run(&tallyTask, &t, n);
                bool once = true;
                for (uint32_t i = 0; i < n; ++i) once = once && t.hits[i].load() == 1;
                CHECK(once);
                offCaller += t.offCaller.load();
            }
            CHECK(offCaller > 0);  // the workers took part
            CHECK(pool.workerTasksForTest() == offCaller);
        }
}

TEST(mix_pool_with_no_workers_runs_every_task_on_the_caller_in_order) {
    MixPool pool;
    CHECK(pool.start(0));
    CHECK_EQ(pool.workers(), 0u);
    struct Order {
        std::vector<uint32_t> seen;
        std::thread::id caller;
        bool elsewhere = false;
    } order;
    order.caller = std::this_thread::get_id();
    order.seen.reserve(16);
    pool.run([](void* c, uint32_t i) noexcept {
        Order& o = *static_cast<Order*>(c);
        o.seen.push_back(i);
        o.elsewhere = o.elsewhere || std::this_thread::get_id() != o.caller;
    }, &order, 16);
    CHECK_EQ(order.seen.size(), 16u);
    for (uint32_t i = 0; i < order.seen.size(); ++i) CHECK_EQ(order.seen[i], i);
    CHECK(!order.elsewhere);
}

TEST(mix_pool_parks_stops_and_starts_again) {
    MixPool pool;
    CHECK(pool.start(3));
    for (int round = 0; round < 6; ++round) {
        pool.park(round % 2 == 0);  // parked workers sleep at once; the next run wakes them all the same
        std::this_thread::sleep_for(std::chrono::milliseconds(2));  // let them fall asleep
        Tally t(12);
        t.caller = std::this_thread::get_id();
        pool.run(&tallyTask, &t, 12);
        bool once = true;
        for (uint32_t i = 0; i < 12; ++i) once = once && t.hits[i].load() == 1;
        CHECK(once);
        if (round == 2) {
            pool.stop();
            CHECK_EQ(pool.workers(), 0u);
            Tally s(5);
            s.caller = std::this_thread::get_id();
            pool.run(&tallyTask, &s, 5);  // no workers: all on the caller
            CHECK_EQ(s.offCaller.load(), 0u);
            CHECK(pool.start(2));
            CHECK_EQ(pool.workers(), 2u);
        }
    }
    // The machine's fast cores less the callback's, at most cores - 2 on 4 or fewer, at most kMaxWorkers (5d).
    CHECK_EQ(MixPool::defaultWorkers(), tuning::poolWorkers(tuning::topology(), MixPool::kMaxWorkers));
    CHECK(MixPool::defaultWorkers() <= MixPool::kMaxWorkers);
}

// Speed phase 5d (the 5c audio review): a restarted pool's workers took part in its first run only from its second
// on (stop() left the wake word one ahead of the epoch the next run published).
TEST(mix_pool_a_restarted_pool_uses_its_workers_from_its_first_run) {
    MixPool pool;
    for (int round = 0; round < 4; ++round) {
        CHECK(pool.start(2));
        std::this_thread::sleep_for(std::chrono::milliseconds(2));  // the workers asleep
        struct Wait {
            std::thread::id caller;
            std::atomic<uint32_t> off{0};
        } w;
        w.caller = std::this_thread::get_id();
        // Each task waits (up to 2 s) until some task ran off the caller: only workers that join this first run end it.
        pool.run([](void* c, uint32_t) noexcept {
            Wait& x = *static_cast<Wait*>(c);
            if (std::this_thread::get_id() != x.caller) {
                x.off.fetch_add(1);
                return;
            }
            const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (x.off.load() == 0 && std::chrono::steady_clock::now() < until) std::this_thread::yield();
        }, &w, 8);
        CHECK(w.off.load() > 0);
        pool.stop();
    }
}

// Speed phase 5d: core kinds and the worker count from per-core numbers.
TEST(mix_pool_sizes_from_core_kinds) {
    using tuning::CoreKind;
    // A Galaxy S22+-like phone by cpu_capacity [Assumption: the values are illustrative]: four little cores, three
    // big, one prime.
    const int cpus[8] = {0, 1, 2, 3, 4, 5, 6, 7};
    const int64_t phone[8] = {280, 280, 280, 280, 750, 750, 750, 1024};
    CoreKind kinds[8];
    tuning::Topology t = tuning::classifyCores(cpus, phone, 8, "cpu_capacity", kinds);
    CHECK(t.hybrid);
    CHECK_EQ(t.cores, 8u);
    CHECK_EQ(t.fast, 4u);
    CHECK_EQ(t.fastMask, 0xF0ull);
    for (int i = 0; i < 4; ++i) CHECK(kinds[i] == CoreKind::Little);
    for (int i = 4; i < 8; ++i) CHECK(kinds[i] == CoreKind::Big);
    CHECK_EQ(tuning::poolWorkers(t, MixPool::kMaxWorkers), 3u);  // the big cores less the callback's
    // Every core the same: Other, all fast.
    const int64_t same[8] = {1024, 1024, 1024, 1024, 1024, 1024, 1024, 1024};
    t = tuning::classifyCores(cpus, same, 8, "cpu_capacity", kinds);
    CHECK(!t.hybrid);
    CHECK_EQ(t.fast, 8u);
    CHECK(kinds[3] == CoreKind::Other);
    CHECK_EQ(tuning::poolWorkers(t, MixPool::kMaxWorkers), 4u);  // capped
    // 4 cores (the CI runners): at most cores - 2.
    t = tuning::classifyCores(cpus, same, 4, "cpu_capacity", kinds);
    CHECK_EQ(tuning::poolWorkers(t, MixPool::kMaxWorkers), 2u);
    t = tuning::classifyCores(cpus, same, 2, "cpu_capacity", kinds);
    CHECK_EQ(tuning::poolWorkers(t, MixPool::kMaxWorkers), 0u);
    t = tuning::classifyCores(cpus, same, 1, "cpu_capacity", kinds);
    CHECK_EQ(tuning::poolWorkers(t, MixPool::kMaxWorkers), 0u);
    // A hybrid laptop by EfficiencyClass (+1): 2 P-cores (4 threads), 8 E-cores.
    const int cpus12[12] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
    const int64_t laptop[12] = {2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1};
    CoreKind k12[12];
    t = tuning::classifyCores(cpus12, laptop, 12, "EfficiencyClass", k12);
    CHECK(t.hybrid);
    CHECK_EQ(t.fast, 4u);
    CHECK_EQ(tuning::poolWorkers(t, MixPool::kMaxWorkers), 3u);
    // Nothing known: every core Other.
    const int64_t none[4] = {-1, -1, -1, -1};
    t = tuning::classifyCores(cpus, none, 4, "none", kinds);
    CHECK(!t.hybrid);
    CHECK_EQ(t.fast, 4u);
    CHECK(std::string(t.source) == "none");
    CHECK(std::string(tuning::coreKindName(CoreKind::Big)) == "big");
}

// Speed phase 5d: a live pool notes the callback thread (its core, its tuning for the workers) and runs as before.
TEST(mix_pool_live_pool_notes_the_callback_and_runs) {
    MixPool pool;
    CHECK(pool.start(2, MixPool::Kind::Live));
    CHECK(pool.kind() == MixPool::Kind::Live);
    for (int cb = 0; cb < 50; ++cb) {
        pool.beginCallback(true);
        Tally t(10);
        t.caller = std::this_thread::get_id();
        pool.run(&tallyTask, &t, 10);
        bool once = true;
        for (uint32_t i = 0; i < 10; ++i) once = once && t.hits[i].load() == 1;
        CHECK(once);
        pool.endCallback();
    }
    CHECK_EQ(pool.callbackCpu() >= 0, tuning::currentCpu() >= 0);
    pool.setActive(1);
    CHECK_EQ(pool.active(), 1u);
    Tally t(10);
    t.caller = std::this_thread::get_id();
    pool.run(&tallyTask, &t, 10);
    CHECK(pool.workers() == 2u);
    pool.stop();
}

// ---- the executor's levels on the pool ----

namespace {

struct PullNet {
    std::vector<std::array<float, 2 * 64>> last;
    std::vector<std::vector<uint32_t>> pulls;
    std::vector<std::atomic<uint32_t>>* offCaller = nullptr;
    std::thread::id caller;
    int failing = -1;                          // this node's process() fails
    std::vector<std::atomic<uint32_t>>* runs = nullptr;  // each node's process() calls
    int waiter = -1;                           // this node waits (up to 2 s) until another ran off the caller
    std::atomic<uint32_t> waiterSaw{0};        // ... and it saw one
};

const PortDescriptor kBusPorts[2] = {{"in", PortType::Audio, ChannelLayout::Stereo, true, 0, true},
                                     {"out", PortType::Audio, ChannelLayout::Stereo, false}};
const ModuleDescriptor kBusModule{"test.pool.node", 1, kBusPorts, 2, nullptr, 0};

// Its summed input times a gain, its own tone, and its dependencies' last output (as the mixer's pulled routes).
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
        if (net_.offCaller && std::this_thread::get_id() != net_.caller) (*net_.offCaller)[index_].fetch_add(1);
        if (net_.runs) (*net_.runs)[index_].fetch_add(1);
        if (net_.waiter == static_cast<int>(index_) && net_.offCaller) {
            const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            for (;;) {
                uint32_t other = 0;
                for (size_t n = 0; n < net_.offCaller->size(); ++n)
                    if (n != index_) other += (*net_.offCaller)[n].load();
                if (other > 0) {
                    net_.waiterSaw.fetch_add(1);
                    break;
                }
                if (std::chrono::steady_clock::now() >= until) break;
                std::this_thread::yield();
            }
        }
        return net_.failing != static_cast<int>(index_);
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
        if (n == g.output || rng.below(8) != 0) g.order.push_back(n);
    const uint32_t count = static_cast<uint32_t>(g.order.size());
    for (uint32_t a = 0; a < count; ++a)
        for (uint32_t b = a + 1; b < count; ++b) {
            const uint32_t from = g.order[a], to = g.order[b];
            if (from == g.output) continue;
            const int roll = rng.below(14);
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
    bool prepare(const RandomGraph& g) {
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
        return exec.setRouting(g.edges.data(), static_cast<uint32_t>(g.edges.size()), g.order.data(),
                               static_cast<uint32_t>(g.order.size()), g.dependencies.data(),
                               static_cast<uint32_t>(g.dependencies.size()));
    }
};

uint32_t bitsOf(float x) { return std::bit_cast<uint32_t>(x); }

}  // namespace

TEST(mix_pool_graph_levels_on_the_pool_are_bit_identical_to_one_thread) {
    Rng rng(17);
    uint32_t parallelLevels = 0;
    for (uint32_t workers = 1; workers <= MixPool::kMaxWorkers; ++workers) {
        MixPool pool;
        CHECK(pool.start(workers));
        for (int trial = 0; trial < 25; ++trial) {
            pool.setDelayForTest(trial % 3 == 0 ? 20u : 0u);
            const RandomGraph g = randomGraph(rng);
            Executor a, b;
            CHECK(a.prepare(g));
            CHECK(b.prepare(g));
            b.exec.setParallelRunner(&pool);
            float la[64], ra[64], lb[64], rb[64];
            bool same = true;
            for (int block = 0; block < 12; ++block) {
                const uint32_t frames = 1 + static_cast<uint32_t>((block * 23) % 64);
                CHECK(a.exec.process(nullptr, nullptr, la, ra, frames));
                CHECK(b.exec.process(nullptr, nullptr, lb, rb, frames));
                parallelLevels += b.exec.parallelLevelsRun();
                for (uint32_t i = 0; i < frames; ++i)
                    same = same && bitsOf(la[i]) == bitsOf(lb[i]) && bitsOf(ra[i]) == bitsOf(rb[i]);
            }
            CHECK(same);
        }
    }
    CHECK(parallelLevels > 200);  // the levels did go to the pool
}

TEST(mix_pool_a_serial_node_runs_on_the_calling_thread) {
    MixPool pool;
    CHECK(pool.start(3));
    pool.setDelayForTest(5);
    RandomGraph g;
    g.nodes = 9;
    g.output = 8;
    for (uint32_t n = 0; n < 9; ++n) g.order.push_back(n);
    for (uint32_t n = 0; n < 8; ++n) g.edges.push_back(GraphConnection{n, 1, 8, 0});  // eight nodes, one level
    Executor x;
    CHECK(x.prepare(g));
    std::vector<std::atomic<uint32_t>> offCaller(9);
    x.net.offCaller = &offCaller;
    x.net.caller = std::this_thread::get_id();
    x.exec.setParallelRunner(&pool);
    x.exec.setNodeSerial(3, true);
    x.exec.setNodeSerial(5, true);
    float l[64], r[64];
    // Until a worker has taken some parallel node (on a loaded machine the caller may take them all for a while).
    uint32_t elsewhere = 0;
    const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    for (int block = 0; block < 200 || (elsewhere == 0 && std::chrono::steady_clock::now() < until); ++block) {
        CHECK(x.exec.process(nullptr, nullptr, l, r, 64));
        elsewhere = 0;
        for (uint32_t n : {0u, 1u, 2u, 4u, 6u, 7u}) elsewhere += offCaller[n].load();
    }
    CHECK_EQ(offCaller[3].load(), 0u);
    CHECK_EQ(offCaller[5].load(), 0u);
    CHECK_EQ(offCaller[8].load(), 0u);  // the output, alone in its level
    CHECK(elsewhere > 0);
}

// Speed phase 5d (the 5c audio review): a level's serial nodes run once its parallel ones are published, so the
// workers start on them meanwhile (5c ran the serial ones first, the workers idle). Node 3 is serial and waits for a
// parallel node of its level to run on a worker.
TEST(mix_pool_serial_nodes_run_while_the_workers_start_the_level) {
    MixPool pool;
    CHECK(pool.start(3));
    RandomGraph g;
    g.nodes = 9;
    g.output = 8;
    for (uint32_t n = 0; n < 9; ++n) g.order.push_back(n);
    for (uint32_t n = 0; n < 8; ++n) g.edges.push_back(GraphConnection{n, 1, 8, 0});
    Executor x;
    CHECK(x.prepare(g));
    std::vector<std::atomic<uint32_t>> offCaller(9);
    x.net.offCaller = &offCaller;
    x.net.caller = std::this_thread::get_id();
    x.net.waiter = 3;
    x.exec.setParallelRunner(&pool);
    x.exec.setNodeSerial(3, true);
    float l[64], r[64];
    for (int block = 0; block < 5 && x.net.waiterSaw.load() == 0; ++block) {
        for (auto& o : offCaller) o.store(0);
        CHECK(x.exec.process(nullptr, nullptr, l, r, 64));
    }
    CHECK(x.net.waiterSaw.load() > 0);
    CHECK_EQ(offCaller[3].load(), 0u);
}

// Speed phase 5d (the 5c audio review): one rule for a failing node with and without the pool: its whole level runs,
// the graph stops after it (the first failure in level order is reported), and the next block runs again.
TEST(mix_pool_a_failing_node_has_one_rule_on_and_off_the_pool) {
    RandomGraph g;
    g.nodes = 10;
    g.output = 9;
    for (uint32_t n = 0; n < 10; ++n) g.order.push_back(n);
    for (uint32_t n = 0; n < 6; ++n) g.edges.push_back(GraphConnection{n, 1, 6 + n % 3, 0});  // level 0: 0..5
    for (uint32_t n = 6; n < 9; ++n) g.edges.push_back(GraphConnection{n, 1, 9, 0});          // level 1: 6..8
    std::vector<uint32_t> counts[2];
    for (int pass = 0; pass < 2; ++pass) {
        MixPool pool;
        CHECK(pool.start(3));
        Executor x;
        CHECK(x.prepare(g));
        std::vector<std::atomic<uint32_t>> runs(10);
        x.net.runs = &runs;
        x.net.failing = 2;
        if (pass == 1) x.exec.setParallelRunner(&pool);
        float l[64], r[64];
        for (int block = 0; block < 20; ++block) {
            for (int i = 0; i < 64; ++i) l[i] = r[i] = 1.0f;
            CHECK(!x.exec.process(nullptr, nullptr, l, r, 64));
            bool silent = true;
            for (int i = 0; i < 64; ++i) silent = silent && l[i] == 0.0f && r[i] == 0.0f;
            CHECK(silent);
            CHECK_EQ(x.exec.lastFailedNode(), 2u);
        }
        for (auto& c : runs) counts[pass].push_back(c.load());
    }
    for (uint32_t n = 0; n < 6; ++n) CHECK_EQ(counts[0][n], 20u);  // the failing node's whole level ran
    for (uint32_t n = 6; n < 10; ++n) CHECK_EQ(counts[0][n], 0u);  // nothing after it
    CHECK(counts[0] == counts[1]);
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

ComponentSpec latent() {  // a transparent compressor with latency, so routes get compensation delays
    ComponentSpec c;
    c.id = "org.caw.compressor";
    c.params = {{"ratio", 1.0}, {"auto_makeup", 0.0}, {"makeup", 0.0}, {"threshold", 0.0}};
    return c;
}

ComponentSpec colour(Rng& rng) {  // some built-in work per node
    ComponentSpec c;
    c.id = rng.below(2) ? "org.caw.eq" : "org.caw.saturator";
    return c;
}

// A random mix with no routing loop: buses (nested, with sends to lower buses), tracks under any bus or none, sends,
// keys into duckers (audio and notes), mutes, latency compensation.
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
        if (rng.below(3) == 0) t.components.push_back(colour(rng));
        if (i > 0 && rng.below(3) == 0) t.components.push_back(ducker("t" + std::to_string(rng.below(i)), rng));
        for (int k = rng.below(4); k > 0; --k)
            t.sends.push_back({"b" + std::to_string(rng.below(buses)), 0.2 + rng.unit(), rng.below(2) == 0, rng.below(6) == 0});
        p.layers.push_back(t);
    }
    return p;
}

ProjectSpec withoutFirstLayer(const ProjectSpec& p) {
    ProjectSpec q = p;
    const std::string gone = q.layers.front().id;
    q.layers.erase(q.layers.begin());
    for (LayerSpec& layer : q.layers) {
        if (layer.parentId == gone) layer.parentId.clear();
        std::erase_if(layer.sends, [&](const SendSpec& s) { return s.to == gone; });
        for (ComponentSpec& c : layer.components)
            if (c.hasKey && c.key.layer == gone) c.hasKey = false;
    }
    return q;
}

struct Mode {
    int workers = -1;    // -1: Never (one thread); 0..4: the pool, Always
    uint32_t delay = 0;  // injected worker delay, microseconds
};

// The mix's raw output over `calls` callbacks of varied sizes, with changes while it plays: a send's level and tap,
// a mute, a layer (a bus or a track) removed, a stop and a play. Counts the levels the pool ran.
std::vector<float> renderMix(const ProjectSpec& p, Mode mode, int calls, uint64_t* parallelLevels = nullptr) {
    Engine e(48000);
    if (mode.workers >= 0) {
        CHECK(e.startMixPool(static_cast<uint32_t>(mode.workers)));
        e.setMixParallel(Engine::MixParallel::Always);
        if (MixPool* pool = e.mixPoolForTest()) pool->setDelayForTest(mode.delay);
    } else {
        e.setMixParallel(Engine::MixParallel::Never);
    }
    CHECK(ok(e.setProject(p)));
    e.play();
    static const int sizes[] = {64, 37, 1, 64, 13, 100, 7, 256};
    std::vector<float> out;
    out.reserve(static_cast<size_t>(calls) * 2 * 256);
    float l[256], r[256];
    for (int k = 0; k < calls; ++k) {
        const int n = sizes[k % 8];
        e.process(l, r, n);
        if (parallelLevels) *parallelLevels += e.mixParallelLevelsForTest();
        out.insert(out.end(), l, l + n);
        out.insert(out.end(), r, r + n);
        if (k == 40)
            for (const LayerSpec& layer : p.layers)
                if (!layer.sends.empty()) { e.setSend(layer.id, 0, 0.1, !layer.sends[0].pre, false); break; }
        if (k == 60) e.setLayerMix(p.layers.back().id, 0.9, 0.3, true, false);
        if (k == 90) CHECK(ok(e.setProject(withoutFirstLayer(p))));
        if (k == 200) e.stop();
        if (k == 260) e.play();
    }
    CHECK_EQ(e.routingRejections(), 0u);
    return out;
}

bool sameBits(const std::vector<float>& a, const std::vector<float>& b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}

}  // namespace

TEST(mix_pool_engine_random_mixes_on_one_to_four_workers_are_bit_identical_to_one_thread) {
    uint64_t levels = 0;
    for (uint64_t seed = 1; seed <= 24; ++seed) {
        const ProjectSpec p = randomMix(seed);
        const std::vector<float> serial = renderMix(p, Mode{-1, 0}, 320);
        const int workers = 1 + static_cast<int>(seed % 4);
        CHECK(sameBits(serial, renderMix(p, Mode{workers, 0}, 320, &levels)));
        CHECK(sameBits(serial, renderMix(p, Mode{workers, 25}, 320, &levels)));  // delays injected in the workers
    }
    CHECK(levels > 1000);
}

TEST(mix_pool_engine_with_zero_workers_is_the_serial_mix) {
    for (uint64_t seed = 31; seed <= 36; ++seed) {
        const ProjectSpec p = randomMix(seed);
        uint64_t levels = 0;
        CHECK(sameBits(renderMix(p, Mode{-1, 0}, 300), renderMix(p, Mode{0, 0}, 300, &levels)));
        CHECK(levels > 0);  // the levels went through the pool's run, on the callback thread
    }
}

TEST(mix_pool_engine_keeps_third_party_components_in_the_serial_lane) {
    constexpr const char* componentId = "org.caw.tests.native-loader";
    const char* path = caw::test::nativeComponentPath();
    CHECK(path && path[0]);
    if (!path || !path[0]) return;
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"beats", "---\nkind: pattern\n---\n0 C4 1\n4 G4 1\n8 C4 1\n12 E4 1\n"});
    for (int i = 0; i < 6; ++i) {
        LayerSpec t = cawtest::testSignalNotesLayer("t" + std::to_string(i), Shape::Saw, "beats",
                                                    {{"level", 0.2}, {"freq", 110.0 * (i + 1)}});
        if (i % 2 == 0) t.components.push_back({componentId, {}});
        p.layers.push_back(t);
    }
    std::vector<float> outs[2];
    for (int pass = 0; pass < 2; ++pass) {
        Engine e(48000);
        CHECK(e.loadNativeComponent(path, componentId, NativeModuleTrust::Trusted).success);
        if (pass == 1) {
            CHECK(e.startMixPool(3));
            e.setMixParallel(Engine::MixParallel::Always);
        } else {
            e.setMixParallel(Engine::MixParallel::Never);
        }
        CHECK(ok(e.setProject(p)));
        e.play();
        float l[128], r[128];
        for (int k = 0; k < 200; ++k) {
            e.process(l, r, 128);
            outs[pass].insert(outs[pass].end(), l, l + 128);
            outs[pass].insert(outs[pass].end(), r, r + 128);
        }
        if (pass == 1) {
            CHECK(e.mixParallelForTest());
            for (int i = 0; i < 6; ++i) CHECK_EQ(e.mixLayerSerialForTest("t" + std::to_string(i)), i % 2 == 0);
        }
    }
    CHECK(sameBits(outs[0], outs[1]));
}

TEST(mix_pool_engine_auto_goes_parallel_under_load_and_back_with_hysteresis) {
    Engine e(48000);
    CHECK(e.startMixPool(2));
    e.setMixParallel(Engine::MixParallel::Auto);  // the default (set here: --mix-threads makes it Always)
    CHECK(ok(e.setProject(randomMix(3))));
    e.play();
    float l[256], r[256];
    auto callbacks = [&](double load, double seconds) {
        for (int k = 0; k < static_cast<int>(seconds * 48000 / 256); ++k) {
            e.process(l, r, 256);
            e.reportLoad(load, 256);
        }
    };
    callbacks(0.2, 2.0);
    CHECK(!e.mixParallelForTest());  // light: one thread
    callbacks(0.9, 0.2);
    CHECK(!e.mixParallelForTest());  // not yet: the average has to stay up for a while
    callbacks(0.9, 1.0);
    e.process(l, r, 256);
    CHECK(e.mixParallelForTest());
    callbacks(0.2, 10.0);
    CHECK(e.mixParallelForTest());  // a lighter load while parallel keeps it
    callbacks(0.01, 2.0);
    CHECK(e.mixParallelForTest());  // and a very light one for a short while
    callbacks(0.01, 6.0);
    e.process(l, r, 256);
    CHECK(!e.mixParallelForTest());  // back to one thread
    e.setMixParallel(Engine::MixParallel::Always);
    e.process(l, r, 256);
    CHECK(e.mixParallelForTest());
    e.setMixParallel(Engine::MixParallel::Never);
    e.process(l, r, 256);
    CHECK(!e.mixParallelForTest());
}

// The bt-clicks and speed-parallel merge (2026-11-13): while Auto turns the pool on, its first callbacks' cost is
// the pool starting, not the song, so for kMixSettleSeconds they don't count toward shedding; a load that stays
// over the budget after that still sheds. Shedding's reset forgets the pool's averages too.
TEST(mix_pool_auto_turning_on_holds_shedding_off_while_it_settles) {
    Engine e(48000);
    CHECK(e.startMixPool(2));
    e.setMixParallel(Engine::MixParallel::Auto);
    CHECK(ok(e.setProject(randomMix(3))));
    e.play();
    float l[256], r[256];
    const double tick = 256.0 / 48000.0;
    auto callbacks = [&](double load, double seconds) {
        for (int k = 0; k < static_cast<int>(seconds / tick + 0.5); ++k) {
            e.process(l, r, 256);
            e.reportLoad(load, 256, 256);
        }
    };
    // Above Auto's threshold, under the overload: Auto turns on after kMixParallelSeconds.
    for (int k = 0; k < 2000 && !e.mixParallelForTest(); ++k) callbacks(0.6, tick);
    CHECK(e.mixParallelForTest());
    CHECK_EQ(e.sheddingStats().shed, 0u);
    // The pool's start-up costs every callback its whole budget. Counted from the first, 0.6 s of that would shed
    // (about 0.3 s does); held off for kMixSettleSeconds (0.7 s), nothing is.
    callbacks(1.2, 0.6);
    CHECK_EQ(e.sheddingStats().shed, 0u);
    // Still over after it has settled: that is the song, and it sheds (after turning the pool off first, if the
    // callback was waiting on its workers).
    callbacks(1.2, 1.2);
    CHECK(e.sheddingStats().shed >= 1u);
    // A shedding reset (a device open, the app going behind) with Auto still on settles again: its averages
    // start from zero, so nothing sheds until they show the load again.
    callbacks(0.6, Engine::kMixRetrySeconds + 2.0);  // past Auto's retry wait, if the shed above turned it off
    e.requestSheddingReset();
    e.process(l, r, 256);
    e.reportLoad(0.6, 256, 256);
    if (e.mixParallelForTest()) {
        const uint64_t before = e.sheddingStats().shed;
        callbacks(1.2, 0.6);
        CHECK_EQ(e.sheddingStats().shed, before);
    }
}

// The audio review of the merge (2026-11-13): shedding and Auto must not fight. When the callback is over its
// budget while it waits on the pool's workers, the pool may be the overload: Auto goes to one thread first (and
// waits kMixRetrySeconds before trying again), and only a song still over on one thread loses a layer.
TEST(mix_pool_overload_while_waiting_on_workers_turns_auto_off_before_shedding) {
    Engine e(48000);
    CHECK(e.startMixPool(2));
    e.setMixParallel(Engine::MixParallel::Auto);
    CHECK(ok(e.setProject(randomMix(3))));
    e.play();
    float l[256], r[256];
    auto one = [&](double load) {
        e.process(l, r, 256);
        e.reportLoad(load, 256, 256);
    };
    for (int k = 0; k < 2000 && !e.mixParallelForTest(); ++k) one(0.6);
    CHECK(e.mixParallelForTest());
    if (e.mixParallelLevelsForTest() == 0) return;  // nothing handed to the workers: nothing to wait on
    e.mixPoolForTest()->setHoldForTest(3000);  // each worker's node takes 3 ms more: the callback waits on it
    int k = 0;
    while (e.mixParallelForTest() && e.sheddingStats().shed == 0 && k++ < 2000) one(1.2);
    CHECK(!e.mixParallelForTest());
    CHECK_EQ(e.sheddingStats().shed, 0u);  // one thread first, no layer lost for it
    e.mixPoolForTest()->setHoldForTest(0);
    for (k = 0; k < 2 * 48000 / 256; ++k) one(1.2);  // still over on one thread: now a layer goes
    CHECK(e.sheddingStats().shed >= 1u);
    CHECK(!e.mixParallelForTest());  // and Auto waits before it tries the pool again
}

// The audio review of the merge (2026-11-13): a device reopen keeps the Engine, so Auto starts serial again on the
// new device instead of carrying the old one's choice with no averages behind it.
TEST(mix_pool_a_new_live_device_starts_auto_serial_again) {
    Engine e(48000);
    if (e.mixPoolForTest()) return;  // --mix-threads N: the test's pool stays, and startLiveMixPool keeps it
    e.startLiveMixPool();
    if (e.mixWorkers() == 0) {  // a machine too small for workers
        e.stopLiveMixPool();
        return;
    }
    CHECK(ok(e.setProject(randomMix(3))));
    e.play();
    float l[256], r[256];
    for (int k = 0; k < 2000 && !e.mixParallelForTest(); ++k) {
        e.process(l, r, 256);
        e.reportLoad(0.6, 256, 256);
    }
    CHECK(e.mixParallelForTest());
    e.stopLiveMixPool();  // as a reopen does
    e.startLiveMixPool();
    e.process(l, r, 256);
    CHECK(!e.mixParallelForTest());
    e.stopLiveMixPool();
}

// Speed phase 5d (the 5c audio review): Auto weighs the time the callback waits for workers. While the pool costs
// more than it gives (workers held after they claim a node), Auto drops workers one by one, then goes back to one
// thread and stays there for kMixRetrySeconds whatever the load; a pool that waits little keeps every worker.
TEST(mix_pool_engine_auto_drops_workers_that_cost_more_than_they_give) {
    Engine e(48000);
    CHECK(e.startMixPool(2));
    e.setMixParallel(Engine::MixParallel::Auto);
    ProjectSpec p;  // six tracks holding notes: one level of six busy nodes every chunk
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"held", "---\nkind: pattern\nlength: 16\n---\n0 C4 16 1\n"});
    for (int i = 0; i < 6; ++i)
        p.layers.push_back(cawtest::testSignalNotesLayer("t" + std::to_string(i), Shape::Saw, "held", {{"level", 0.1}}));
    CHECK(ok(e.setProject(p)));
    e.play();
    float l[256], r[256];
    auto callbacks = [&](double load, double seconds) {
        for (int k = 0; k < static_cast<int>(seconds * 48000 / 256); ++k) {
            e.process(l, r, 256);
            e.reportLoad(load, 256);
        }
    };
    // 0.8: above Auto's threshold, below the 0.85 at which the engine mutes a layer (which would empty the levels).
    auto one = [&] {
        e.process(l, r, 256);
        e.reportLoad(0.8, 256);
    };
    callbacks(0.8, 1.0);
    e.process(l, r, 256);
    CHECK(e.mixParallelForTest());
    CHECK(e.mixParallelLevelsForTest() > 0);
    callbacks(0.8, 3.0);
    CHECK(e.mixParallelForTest());  // a pool that barely waits keeps going, with every worker
    CHECK_EQ(e.mixActiveWorkers(), 2u);
    e.mixPoolForTest()->setHoldForTest(3000);  // each worker's node takes 3 ms more: the callback waits for it
    // One worker fewer after a while, then none and one thread (each step kMixWaitSeconds once the average is up).
    int steps = 0;
    while (e.mixActiveWorkers() == 2u && steps++ < 2000) one();
    CHECK_EQ(e.mixActiveWorkers(), 1u);
    CHECK(e.mixParallelForTest());
    steps = 0;
    while (e.mixParallelForTest() && steps++ < 2000) one();
    CHECK(!e.mixParallelForTest());
    e.mixPoolForTest()->setHoldForTest(0);
    callbacks(0.8, 5.0);
    e.process(l, r, 256);
    CHECK(!e.mixParallelForTest());  // not again before kMixRetrySeconds
    callbacks(0.8, 6.0);
    e.process(l, r, 256);
    CHECK(e.mixParallelForTest());  // tried again, with every worker
    CHECK_EQ(e.mixActiveWorkers(), 2u);
}

// Speed phase 5d (the 5c audio review): an offline render's pool goes serial while a live device runs, checked
// every callback (5c checked once, when the render started).
TEST(mix_pool_engine_offline_pool_steps_aside_for_a_live_device) {
    Engine a(48000);
    if (a.mixPoolForTest()) return;  // --mix-threads N: every Engine has the test's pool, and renders keep it
    a.useOfflineMixPool();
    if (a.mixWorkers() == 0) return;  // a machine too small for workers
    CHECK(ok(a.setProject(randomMix(4))));
    a.play();
    float l[256], r[256];
    a.process(l, r, 256);
    CHECK(a.mixParallelForTest());
    {
        Engine live(48000);
        live.startLiveMixPool();
        a.process(l, r, 256);
        CHECK(!a.mixParallelForTest());
        CHECK(a.mixPoolForTest()->parked());
        live.stopLiveMixPool();
    }
    a.process(l, r, 256);
    CHECK(a.mixParallelForTest());
}

// Speed phase 5d: the diagnostics the C API returns (caw_audio_threads).
TEST(mix_pool_engine_reports_its_audio_threads) {
    Engine e(48000);
    CHECK(e.startMixPool(2, true));
    float l[256], r[256];
    for (int k = 0; k < 40; ++k) e.process(l, r, 256);
    const std::string j = e.audioThreadsJson();
    for (const char* key : {"\"callback_cpu\":", "\"core_kind\":", "\"clock_khz\":", "\"max_khz\":", "\"hint\":",
                            "\"mmcss\":", "\"worker_tuning\":", "\"workers\":2", "\"active_workers\":2", "\"wait_share\":",
                            "\"cores\":", "\"fast_cores\":", "\"hybrid\":", "\"core_source\":"})
        CHECK(j.find(key) != std::string::npos);
}

TEST(mix_pool_engine_stopped_parks_the_pool_and_play_wakes_it) {
    Engine e(48000);
    CHECK(e.startMixPool(2));
    e.setMixParallel(Engine::MixParallel::Always);
    ProjectSpec p;  // notes only (a free-running test signal sounds while stopped, as a monitored input does)
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"beats", "---\nkind: pattern\n---\n0 C4 1\n8 G4 1\n"});
    for (int i = 0; i < 4; ++i)
        p.layers.push_back(cawtest::testSignalNotesLayer("t" + std::to_string(i), Shape::Sine, "beats", {{"level", 0.2}}));
    CHECK(ok(e.setProject(p)));
    float l[256], r[256];
    e.process(l, r, 256);
    CHECK(e.mixPoolForTest()->parked());
    e.play();
    e.process(l, r, 256);
    CHECK(!e.mixPoolForTest()->parked());
    e.stop();
    // The stop fade, then the tails ringing out (stopped chunks still run the graph), then nothing plays.
    for (int k = 0; k < 2000; ++k) e.process(l, r, 256);
    CHECK(e.mixPoolForTest()->parked());
    e.stopMixPool();
    CHECK_EQ(e.mixWorkers(), 0u);
    e.play();
    e.process(l, r, 256);  // no pool: one thread
    CHECK(!e.mixParallelForTest());
    CHECK(e.startMixPool(3));
    e.process(l, r, 256);
    CHECK(e.mixParallelForTest());
    CHECK_EQ(e.mixWorkers(), 3u);
}

// The ThreadSanitizer job's run (engine.yml): many chunks of random graphs with sends, keys and buses, on 3 workers
// with injected delays, and the project changed while it plays (layers removed and back, a new mix), each output
// against one thread's. CAW_POOL_STRESS_CHUNKS sets the callbacks per mix (default 2000).
TEST(mix_pool_stress_random_graphs_with_changes_while_playing) {
    const char* env = std::getenv("CAW_POOL_STRESS_CHUNKS");
    const int calls = env ? std::max(400, std::atoi(env)) : 2000;
    for (uint64_t seed = 101; seed <= 105; ++seed) {
        const ProjectSpec a = randomMix(seed), b = randomMix(seed + 50);
        std::vector<float> outs[2];
        for (int pass = 0; pass < 2; ++pass) {
            Engine e(48000);
            if (pass == 1) {
                CHECK(e.startMixPool(3));
                e.setMixParallel(Engine::MixParallel::Always);
                e.mixPoolForTest()->setDelayForTest(10);
            } else {
                e.setMixParallel(Engine::MixParallel::Never);
            }
            CHECK(ok(e.setProject(a)));
            e.play();
            float l[256], r[256];
            for (int k = 0; k < calls; ++k) {
                const int n = 1 + (k * 37) % 256;
                e.process(l, r, n);
                outs[pass].insert(outs[pass].end(), l, l + n);
                outs[pass].insert(outs[pass].end(), r, r + n);
                const int phase = k % 400;
                if (phase == 100) CHECK(ok(e.setProject(withoutFirstLayer(a))));
                if (phase == 200) CHECK(ok(e.setProject(b)));
                if (phase == 300) CHECK(ok(e.setProject(a)));
                if (phase == 350) e.setLayerMix(a.layers.back().id, 0.7, -0.4, (k / 400) % 2 == 0, false);
            }
            CHECK_EQ(e.routingRejections(), 0u);
        }
        CHECK(sameBits(outs[0], outs[1]));
    }
}
