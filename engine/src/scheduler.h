// Bounded non-real-time worker pool. Never submit or wait from the audio callback.
#pragma once

#include <array>
#include "execution.h"
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

namespace caw {

enum class JobPriority : uint8_t { Background = 0, Offline = 1, Foreground = 2 };
using JobFunction = void (*)(void*) noexcept;

class WorkerPool {
public:
    static constexpr uint32_t kQueueCapacity = 256;
    static constexpr uint32_t kMaxWorkers = 16;

    explicit WorkerPool(uint32_t workers);
    ~WorkerPool();
    WorkerPool(const WorkerPool&) = delete;
    WorkerPool& operator=(const WorkerPool&) = delete;

    // Non-blocking with respect to job completion. Returns false if stopped/full/invalid.
    // The context must remain valid until the job runs or is cancelled.
    bool submit(JobPriority priority, JobFunction function, void* context) noexcept;
    void setWorkerLimit(uint32_t activeWorkers) noexcept;
    uint32_t cancelPending() noexcept;
    void waitIdle();

    uint32_t queued() const noexcept;
    uint32_t active() const noexcept;

private:
    struct Job {
        JobFunction function = nullptr;
        void* context = nullptr;
        JobPriority priority = JobPriority::Background;
        uint64_t sequence = 0;
    };

    void workerLoop(uint32_t index) noexcept;
    bool takeJob(Job& out) noexcept;

    mutable std::mutex mutex_;
    std::condition_variable wake_, idle_;
    std::array<Job, kQueueCapacity> queue_{};
    uint32_t queueCount_ = 0;
    uint32_t activeCount_ = 0;
    uint32_t workerLimit_ = 0;
    uint64_t nextSequence_ = 0;
    bool stopping_ = false;
    std::vector<std::thread> workers_;
};

 // Applies deterministic hardware/pressure policy to a bounded worker pool.
 // This wrapper is for control/background work only, never the audio callback.
class AdaptiveWorkerPool {
public:
    explicit AdaptiveWorkerPool(HardwareProfile hardware, uint32_t maxWorkers = WorkerPool::kMaxWorkers);
    ExecutionPlan apply(const ExecutionRequest& request) noexcept;
    const ExecutionPlan& currentPlan() const noexcept { return plan_; }
    bool submit(JobPriority priority, JobFunction function, void* context) noexcept {
        return pool_.submit(priority, function, context);
    }
    uint32_t cancelPending() noexcept { return pool_.cancelPending(); }
    void waitIdle() { pool_.waitIdle(); }
    uint32_t queued() const noexcept { return pool_.queued(); }
    uint32_t active() const noexcept { return pool_.active(); }

private:
    HardwareProfile hardware_;
    uint32_t capacity_ = 1;
    WorkerPool pool_;
    ExecutionPlan plan_;
};

}  // namespace caw
