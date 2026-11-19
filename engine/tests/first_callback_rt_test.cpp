// The first callbacks after Play are not cold: no allocation and no lazy initialisation in any Benchmark scenario's.
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "stress_scenarios.h"
#include "test.h"

using namespace caw;
using namespace caw::stress;

namespace {

std::string firstCallbackDir() {
    const std::string d = (std::filesystem::temp_directory_path() / "caw_first_callback_test").string();
    std::filesystem::create_directories(d);
    return d;
}

// A function-local static with a dynamic initialiser, for the counter's own test.
int lazyValue(int seed) {
    static const int v = std::rand() % 2 + seed;
    return v;
}

}  // namespace

// The counter sees what the test below looks for (where it can: Linux), so a pass there means something.
TEST(lazy_init_counter_sees_a_function_local_static) {
    const long long before = cawtest::threadLazyInits();
    if (before < 0) return;  // not countable on this platform
    CHECK(lazyValue(1) >= 1);
    CHECK(lazyValue(2) >= 1);  // already initialised: no second call
    CHECK_EQ(cawtest::threadLazyInits() - before, 1LL);
}

// The Benchmark's runs (stress_run.cpp) set a project, play a quarter second stopped, then Play: every callback
// from the first stopped one through the first second after Play runs with no allocation and no function-local
// static initialised on the audio thread (a table built on first use would be the "cold first callback"). Each
// scenario on a fresh engine, as the Benchmark plays it.
TEST(first_callbacks_after_play_allocate_nothing_and_initialise_nothing_lazily) {
    const std::string dir = firstCallbackDir();
    const std::vector<SuiteScenario> all = benchmarkScenarios();
    constexpr int kFrames = 256;
    std::vector<float> l(kFrames), r(kFrames);
    for (const SuiteScenario& s : all) {
        if (s.tier == Tier::Extreme) continue;  // their memory (up to 1 GiB) is a phone's budget, not a test's
        Engine e(48000);
        e.setShedding(false);
        ProjectSpec p;
        std::string error;
        CHECK(makeScenario(s, dir, p, error));
        CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
        size_t allocs = 0;
        long long lazyBefore = cawtest::threadLazyInits(), lazy = 0;
        {
            cawtest::AllocationScope scope;
            for (int c = 0; c < 48000 / 4 / kFrames; ++c) e.process(l.data(), r.data(), kFrames);
            allocs += scope.count();
        }
        e.play();  // control thread: the command is queued (its allocation is the control thread's)
        lazyBefore = cawtest::threadLazyInits();
        {
            cawtest::AllocationScope scope;
            for (int c = 0; c < 48000 / kFrames; ++c) e.process(l.data(), r.data(), kFrames);
            allocs += scope.count();
        }
        if (lazyBefore >= 0) lazy = cawtest::threadLazyInits() - lazyBefore;
        if (allocs != 0 || lazy != 0) std::printf("  %s: %zu allocations, %lld lazy inits\n", s.id, allocs, lazy);
        CHECK_EQ(allocs, size_t{0});
        CHECK_EQ(lazy, 0LL);
    }
}
