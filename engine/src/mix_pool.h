// The mixer's real-time worker pool (speed phase 5c): threads that run one level of the mix graph with the callback.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <thread>
#include <vector>

#include "graph.h"

namespace caw {

// Worker threads, made and joined on the control thread (start, stop), that run the tasks of one run() call
// alongside the thread that calls it (the audio callback). Portable: std::thread and std::atomic only.
//
// run() publishes the call by bumping an epoch, then claims task indices from one atomic word itself, as the workers
// do, and returns once every task has finished, spinning on a counter (it never waits on a sleeping worker, and it
// makes no system call unless a worker sleeps). A worker spins briefly after each run (a pause instruction between
// loads), then sleeps in std::atomic<uint32_t>::wait on the epoch; run() calls notify_all only while one sleeps.
// Each task must write only its own state: which thread runs which task, and when, is not fixed.
class MixPool final : public ParallelRunner {
public:
    static constexpr uint32_t kMaxWorkers = 4;
    // min(hardware threads - 1, 3), and 0 where the count is unknown.
    static uint32_t defaultWorkers() noexcept;
    // The calling thread's lane: 0 off the pool (the callback, the control thread), 1..workers on a worker. Per-lane
    // scratch (ModulationHost's) uses it, as two lanes can run at once and one lane runs one task at a time.
    static uint32_t lane() noexcept;
    static constexpr uint32_t kLanes = kMaxWorkers + 1;

    MixPool() = default;
    ~MixPool();
    MixPool(const MixPool&) = delete;
    MixPool& operator=(const MixPool&) = delete;

    // Control thread, while no run() is in progress: stops any workers, then makes `workers` (at most kMaxWorkers).
    // False if a thread could not be made: then the pool has none, and run() runs every task on its caller.
    bool start(uint32_t workers);
    void stop() noexcept;
    uint32_t workers() const noexcept { return count_; }

    // Any thread: parked, idle workers sleep at once instead of spinning first (the transport is stopped).
    void park(bool parked) noexcept { parked_.store(parked, std::memory_order_relaxed); }
    bool parked() const noexcept { return parked_.load(std::memory_order_relaxed); }

    // Audio thread: task(context, i) for every i in [0, count), then returns. With no workers, or fewer than two
    // tasks, every task runs here in index order.
    void run(Task task, void* context, uint32_t count) noexcept override;

    // Tests only: each worker waits a pseudo-random 0..maxMicros microseconds before each task it claims (and
    // before claiming), so the order and overlap of tasks vary from run to run.
    void setDelayForTest(uint32_t maxMicros) noexcept { delayMicros_.store(maxMicros, std::memory_order_relaxed); }
    // Tests only: tasks the workers (not the caller) have run since start().
    uint64_t workerTasksForTest() const noexcept { return workerTasks_.load(std::memory_order_relaxed); }

private:
    void loop(uint32_t lane) noexcept;
    bool claimOne(bool worker) noexcept;  // claims and runs one task of the current run; false when none is left

    std::vector<std::thread> threads_;
    uint32_t count_ = 0;
    // The current run: its epoch (high 32 bits), task count (next 16) and next unclaimed index (low 16), in one word
    // so a claim from an earlier run can never take an index of this one.
    std::atomic<uint64_t> claim_{0};
    std::atomic<uint32_t> done_{0};    // tasks of the current run that have finished
    std::atomic<uint32_t> wake_{0};    // the epoch the workers wait on
    std::atomic<uint32_t> sleepers_{0};
    std::atomic<bool> stop_{false};
    std::atomic<bool> parked_{false};
    std::atomic<uint32_t> delayMicros_{0};
    std::atomic<uint64_t> workerTasks_{0};
    uint32_t epoch_ = 0;               // audio thread: the last run's epoch
    // Read by a worker only after it claimed an index of the run (the claim acquires what run() wrote before
    // publishing), and written by run() only after every task of the last run finished.
    Task task_ = nullptr;
    void* context_ = nullptr;
};

}  // namespace caw
