// The Benchmark's timed runs (beta plan C): plain, ramps, sustained and profiled, on a worker thread, no device.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "stress_scenarios.h"

namespace caw {
class Engine;
struct ChainProfile;
}

namespace caw::stress {

// What a run does (CAW_STRESS_* in caw.h keep these numbers).
enum class Kind : int32_t { Plain = 0, RampTracks = 1, RampVoices = 2, RampEffects = 3, Sustained = 4, Profile = 5 };

struct RunRequest {
    std::string scenario;     // a benchmarkScenarios() id (ramps ignore it)
    Kind kind = Kind::Plain;
    double seconds = 2.0;     // audio per run; a ramp's per step (0.05..600)
    int frames = 256;         // the callback size timed (16..8192)
    int quality = 1;          // the engine's quality (0 Eco, 1 Normal, 2 High)
    int rate = 48000;
    std::string workDir;      // an existing folder for typicalSong's WAVs ("" : scenarios that need one fail)
};

// Read by any thread while the run goes (caw_stress_progress).
struct Progress {
    std::atomic<int32_t> permille{0};   // 0..1000 of the whole run
    std::atomic<int32_t> step{0};       // ramps: steps run so far
    std::atomic<int32_t> count{0};      // ramps: the count the current step plays (tracks, voices, effects)
    std::atomic<int32_t> held{0};       // ramps: the largest count that held so far
    std::atomic<int64_t> callbacks{0};  // callbacks timed so far
    std::atomic<int64_t> overBudget{0}; // of them, over budget
    std::atomic<float> load{0};         // the last 100 ms's load (share of the budget)
    int32_t spanFrom = 0, spanTo = 1000;  // the run's own: the permille the current timed stretch goes between
};

// The load every 100 ms of audio (DSP runs play faster than real time where they can, so their points come
// faster), in a fixed ring: one writer (the run), readers on any thread. No allocation after construction.
class LoadHistory {
public:
    static constexpr uint32_t kCapacity = 8192;  // 819 s of points
    void push(float load) noexcept;
    // Copies points [from, written()) (at most `max`, the oldest still kept first) into out; returns how many and
    // sets *next to the index after the last one copied.
    int32_t read(uint32_t from, float* out, int32_t max, uint32_t* next) const noexcept;
    uint32_t written() const noexcept { return written_.load(std::memory_order_acquire); }
    void clear() noexcept { written_.store(0, std::memory_order_release); }

private:
    std::atomic<float> points_[kCapacity] = {};
    std::atomic<uint32_t> written_{0};
};

struct CostRow {
    std::string id;       // a component id, or "host" (everything Engine::process does outside components)
    uint64_t ns = 0;      // per callback
    double pct = 0;       // of Engine::process's whole time
    double ranPct = 0;    // of the blocks it was seen in, the share it actually processed
    int instances = 0;
    bool modulator = false;
};

struct RunResult {
    bool ok = false;
    std::string error;
    std::string stopReason = "done";  // "done", "cancelled", "over_budget" (a ramp's end), "error"
    double budgetUs = 0, meanUs = 0, p99Us = 0, worstUs = 0, worstAtS = 0;
    double meanFirstUs = 0, meanLastUs = 0;  // sustained: the first and last tenth's means (heat shows as a rise)
    int64_t callbacks = 0, overBudget = 0;   // DSP: over budget is what would have been a dropout
    int32_t limit = -1;      // ramps: the last count that held (0: not even the first)
    int32_t firstFailed = -1;  // ramps: the smallest count seen over budget (-1: none, the cap held)
    int32_t steps = 0;
    double seconds = 0;      // audio timed
    std::vector<CostRow> costs;  // profile: sorted by time, the host row among them
};

// A step holds when its 99th-percentile callback is within the budget (at most 1 in 100 callbacks over).
constexpr double kHoldP99 = 1.0;

// Times `calls` callbacks of `frames` into us[0, calls) (microseconds), pushing the load every 100 ms of audio into
// history (may be null) and counting progress; stops early when *cancel is non-zero (checked every callback).
// Returns the callbacks timed. Allocates nothing (caw_rt_tests): l, r and us are the caller's.
int64_t timeCallbacks(Engine& e, int frames, int64_t calls, double* us, float* l, float* r, Progress* progress,
                      LoadHistory* history, const std::atomic<int32_t>* cancel) noexcept;

// The ramp's search, apart from timing so it can be tested: counts go up (counts) until the first that does not
// hold, then halve the gap between the last that held and it, never above it. `step(n)` plays count n and says
// whether it held, or returns -1 to stop (cancelled, failed). Returns the last count that held (0: none).
struct RampOutcome {
    int32_t limit = 0;
    int32_t firstFailed = -1;
    int32_t steps = 0;
    bool stopped = false;  // step returned -1
};
RampOutcome rampSearch(const std::vector<int32_t>& counts, const std::function<int(int32_t)>& step);
// The counts each ramp tries (tracks up to 128, voices to 64, effects to 64).
std::vector<int32_t> rampCounts(Kind kind);
// The project a ramp plays at count n.
ProjectSpec rampProject(Kind kind, int32_t n);

// Runs one request to the end (or cancel) on the calling thread: its own Engine, shedding off, the profile its own.
RunResult run(const RunRequest& request, Progress& progress, LoadHistory* history, const std::atomic<int32_t>* cancel);

// Profile totals of one run: per component id (instances added), the host's share, sorted by time.
std::vector<CostRow> profileCosts(const ChainProfile& profile, uint64_t totalNs, int64_t callbacks);

}  // namespace caw::stress
