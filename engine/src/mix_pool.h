// The mixer's real-time worker pool (speed phases 5c, 5d): threads that run one level of the mix graph with the callback.
#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <memory>
#include <thread>
#include <vector>

#include "graph.h"
#include "thread_tuning.h"

namespace caw {

// Worker threads, made and joined on the control thread (start, stop), that run the tasks of one level alongside
// the thread that calls it (the audio callback). Portable: std::thread and std::atomic, with the platform's tuning
// behind thread_tuning.h.
//
// begin() publishes a level through an epoch in one claim word; finish() claims tasks on the caller as the workers
// do, then spins until every task has finished (never waiting on a sleeping worker; no system call unless one
// sleeps). Around each callback (Engine::process): beginCallback(true) wakes sleeping workers before the callback
// plans its first chunk (the Engine asks when its last callback used the pool), and from then, or from the first
// level begin() publishes, they spin through the callback's levels and chunks (a pause instruction between loads);
// endCallback() lets them spin kGraceMicros more, then sleep in std::atomic<uint32_t>::wait. A spinning worker
// yields its core every 64 pauses (to the system's threads, which then need not preempt a node). A worker never
// spins more than kMaxSpinMicros without work. Each task must write only its own state: which thread runs which
// task, and when, is not fixed.
class MixPool final : public ParallelRunner {
public:
    static constexpr uint32_t kMaxWorkers = 4;
    // This machine's workers (thread_tuning.h, poolWorkers): its fast cores less the callback's, at most cores - 2
    // on 4 or fewer cores, at most kMaxWorkers; 0 where the count is unknown.
    static uint32_t defaultWorkers() noexcept;
    // The calling thread's lane: 0 off the pool (the callback, the control thread), 1..workers on a worker. Per-lane
    // scratch (ModulationHost's) uses it, as two lanes can run at once and one lane runs one task at a time.
    static uint32_t lane() noexcept;
    static constexpr uint32_t kLanes = kMaxWorkers + 1;
    static constexpr uint32_t kGraceMicros = 50;      // spin after a callback ends (the next process() of a long one)
    static constexpr uint32_t kMaxSpinMicros = 3000;  // the longest idle spin, whatever the callback does

    // Offline: as made (renders, the bench, tests). Live: the workers tune themselves to the device's callback
    // thread once it has run (thread_tuning.h), and a performance hint follows the callback where there is one.
    enum class Kind : uint8_t { Offline, Live };

    MixPool() = default;
    ~MixPool();
    MixPool(const MixPool&) = delete;
    MixPool& operator=(const MixPool&) = delete;

    // Control thread, while no run is in progress: stops any workers, then makes `workers` (at most kMaxWorkers).
    // False if a thread could not be made: then the pool has none, and every task runs on its caller.
    bool start(uint32_t workers, Kind kind = Kind::Offline);
    void stop() noexcept;
    uint32_t workers() const noexcept { return count_; }
    Kind kind() const noexcept { return kind_; }

    // Any thread: parked, idle workers sleep at once instead of spinning (the transport is stopped).
    void park(bool parked) noexcept { parked_.store(parked, std::memory_order_relaxed); }
    bool parked() const noexcept { return parked_.load(std::memory_order_relaxed); }
    // Any thread: the workers that take tasks (lanes 1..n; the rest sleep), at most workers(). Auto's choice.
    // Wakes a worker set aside only when the count changes (a system call then, rarely: Auto's steps).
    void setActive(uint32_t n) noexcept {
        n = std::min(n, kMaxWorkers);
        if (active_.exchange(n, std::memory_order_acq_rel) != n) active_.notify_all();
    }
    uint32_t active() const noexcept { return std::min(active_.load(std::memory_order_relaxed), count_); }

    // Audio thread, around one callback's work (Engine::process). `wake`: the callback will use the workers (else
    // only the Live bookkeeping: the callback thread's description, its core every 32 callbacks).
    void beginCallback(bool wake) noexcept;
    void endCallback() noexcept;
    // Audio thread: the time finish() spent waiting for workers' tasks, and the time workers spent running tasks,
    // since the last call (nanoseconds). Auto weighs one against the other (Engine::reportLoad).
    void takeTimes(int64_t& waitNs, int64_t& workerNs) noexcept;
    // Audio thread: the callback's duration and period, for the performance hint (atomics only).
    void reportWork(int64_t actualNs, int64_t targetNs) noexcept { tuning::hintReport(hint_, actualNs, targetNs); }
    // The platform layer, once the device runs: whether the callback thread is in MMCSS "Pro Audio" (Windows).
    void setCallbackMmcss(bool mmcss) noexcept;

    // Audio thread: task(context, i) for every i in [0, count), on this thread and the workers. begin() publishes
    // (the caller may then do other work), finish() claims what is left and returns once every task has run. With
    // no workers, or fewer than two tasks, finish() runs every task here in index order.
    void begin(Task task, void* context, uint32_t count) noexcept override;
    void finish() noexcept override;

    // Diagnostics (any thread): the callback's last core (-1 unknown), the tuning the workers managed (OR of
    // tuning::kApplied*), whether the callback is in MMCSS, and whether a performance hint session is open.
    int callbackCpu() const noexcept { return callbackCpu_.load(std::memory_order_relaxed); }
    uint32_t workerTuning() const noexcept { return tuned_.load(std::memory_order_relaxed); }
    uint32_t callbackTuning() const noexcept { return callbackApplied_.load(std::memory_order_relaxed); }
    bool callbackMmcss() const noexcept { return mmcss_.load(std::memory_order_relaxed); }
    bool hintActive() const noexcept { return tuning::hintActive(hint_); }

    // Tests only: each worker waits a pseudo-random 0..maxMicros microseconds before each task it claims (and
    // before claiming), so the order and overlap of tasks vary from run to run.
    void setDelayForTest(uint32_t maxMicros) noexcept { delayMicros_.store(maxMicros, std::memory_order_relaxed); }
    // Tests only: each worker waits `micros` after it claims a task and before it runs it, and the caller lets a
    // worker claim first, so the caller waits for the workers (Auto's measure of a pool that costs more than it gives).
    void setHoldForTest(uint32_t micros) noexcept { holdMicros_.store(micros, std::memory_order_relaxed); }
    // Tests only: tasks the workers (not the caller) have run since start().
    uint64_t workerTasksForTest() const noexcept { return workerTasks_.load(std::memory_order_relaxed); }

private:
    void loop(uint32_t lane) noexcept;
    bool claimOne(uint32_t lane) noexcept;  // claims and runs one task of the current run; false when none is left
    void publishWake() noexcept;
    void noteCallbackThread() noexcept;

    std::vector<std::thread> threads_;
    uint32_t count_ = 0;
    Kind kind_ = Kind::Offline;
    uint64_t startId_ = 0;  // unique per start(): a callback thread notes itself once per start
    // The current run: its epoch (high 32 bits), task count (next 16) and next unclaimed index (low 16), in one word
    // so a claim from an earlier run can never take an index of this one.
    std::atomic<uint64_t> claim_{0};
    std::atomic<uint32_t> done_{0};      // tasks of the current run that have finished
    std::atomic<uint32_t> wake_{0};      // bumped for each run and each callback; the workers wait on it
    std::atomic<uint32_t> sleepers_{0};
    std::atomic<int64_t> spinUntil_{0};  // steady-clock ns: workers spin until then (INT64_MAX in a callback)
    std::atomic<bool> stop_{false};
    std::atomic<bool> parked_{false};
    std::atomic<uint32_t> active_{kMaxWorkers};
    std::atomic<uint32_t> delayMicros_{0};
    std::atomic<uint32_t> holdMicros_{0};
    std::atomic<uint64_t> workerTasks_{0};
    std::atomic<int64_t> workerNs_{0};   // task time on the workers since takeTimes
    int64_t waitNs_ = 0;                 // audio thread: finish()'s wait since takeTimes
    uint32_t epoch_ = 0;                 // audio thread: the last run's epoch
    uint32_t pending_ = 0;               // audio thread: the task count begin() was given
    bool published_ = false;             // audio thread: begin() handed them to the workers
    static constexpr uint32_t kStopping = 0xFFFFu;  // active_ while stop() joins
    uint32_t callbacks_ = 0;             // audio thread: callbacks since start, for the core sample
    // Read by a worker only after it claimed an index of the run (the claim acquires what begin() wrote before
    // publishing), and written by begin() only after every task of the last run finished.
    Task task_ = nullptr;
    void* context_ = nullptr;
    // Tuning (Live): the callback thread as it described itself, published by a generation; the workers' ids.
    std::atomic<uint32_t> callbackGen_{0};
    std::atomic<int32_t> cbTid_{0};
    std::atomic<int> cbPolicy_{0}, cbPriority_{0}, cbNice_{0};
    std::atomic<bool> mmcss_{false};
    std::atomic<uint32_t> callbackApplied_{0};
    std::atomic<int32_t> workerTids_[kMaxWorkers] = {};
    std::atomic<uint32_t> tidsReady_{0};
    std::atomic<uint32_t> tuned_{0};
    std::atomic<int> callbackCpu_{-1};
    tuning::Hint* hint_ = nullptr;
};

}  // namespace caw
