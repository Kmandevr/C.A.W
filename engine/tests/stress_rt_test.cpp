// The Benchmark's timed loop allocates nothing: timing, progress and the load history are all preallocated.
#include <atomic>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "stress_run.h"
#include "stress_scenarios.h"
#include "test.h"

using namespace caw;
using namespace caw::stress;

TEST(stress_timed_loop_never_allocates) {
    for (const char* id : {"three_tracks", "drums_kit", "flagship_heavy16"}) {
        Engine e(48000);
        e.setShedding(false);
        const std::vector<SuiteScenario> all = benchmarkScenarios();
        CHECK(e.setProject(findScenario(all, id)->make("")).find("\"ok\":true") != std::string::npos);
        constexpr int kFrames = 256;
        std::vector<float> l(kFrames), r(kFrames);
        for (int c = 0; c < 48000 / 4 / kFrames; ++c) e.process(l.data(), r.data(), kFrames);
        e.play();
        for (int c = 0; c < 20; ++c) e.process(l.data(), r.data(), kFrames);  // first notes: voices start
        const int64_t calls = 48000 / kFrames;
        std::vector<double> us(static_cast<size_t>(calls));
        Progress p;
        LoadHistory h;
        std::atomic<int32_t> cancel{0};
        int64_t n = 0;
        size_t count = 0;
        {
            cawtest::AllocationScope scope;
            n = timeCallbacks(e, kFrames, calls, us.data(), l.data(), r.data(), &p, &h, &cancel);
            count = scope.count();
        }
        CHECK_EQ(n, calls);
        CHECK_EQ(count, size_t{0});
        CHECK(h.written() > 0);
    }
}
