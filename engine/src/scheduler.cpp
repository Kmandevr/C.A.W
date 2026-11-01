// Bounded scheduler for compilation, rendering, analysis and asset work. Audio never calls into this class.
#include "scheduler.h"

#include <algorithm>

namespace caw {

WorkerPool::WorkerPool(uint32_t workers, std::chrono::milliseconds idleTimeout)
    : idleTimeout_(std::max(idleTimeout, std::chrono::milliseconds::zero())) {
    capacity_ = std::clamp<uint32_t>(workers, 1, kMaxWorkers);
    workerLimit_ = capacity_;
    // Thread handles occupy fixed slots; actual OS threads are started on demand.
}

WorkerPool::~WorkerPool() {
    std::array<Job, kQueueCapacity> pending{};
    uint32_t pendingCount = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        workerLimit_ = capacity_;
        // If policy kept the pool at zero workers, drain already accepted work here.
        // Destruction is non-real-time and may safely execute these jobs synchronously.
        if (liveWorkerCount_ == 0) {
            pendingCount = queueCount_;
            for (uint32_t i = 0; i < pendingCount; ++i) pending[i] = queue_[i];
            for (uint32_t i = 0; i < queueCount_; ++i) queue_[i] = Job{};
            queueCount_ = 0;
        }
    }
    for (uint32_t i = 0; i < pendingCount; ++i)
        if (pending[i].function) pending[i].function(pending[i].context);
    wake_.notify_all();
    for (std::thread& worker : workers_) if (worker.joinable()) worker.join();
}

bool WorkerPool::ensureWorkersLocked(uint32_t desired) noexcept {
    desired = std::min<uint32_t>(desired, std::min(workerLimit_, capacity_));
    // A worker marks its slot exited while holding mutex_. Joining here is safe:
    // an exited worker has released that mutex and will not touch the pool again.
    for (uint32_t i = 0; i < capacity_; ++i) {
        if (exited_[i]) {
            if (workers_[i].joinable()) workers_[i].join();
            workers_[i] = std::thread{};
            exited_[i] = false;
        }
    }
    try {
        while (liveWorkerCount_ < desired) {
            uint32_t slot = 0;
            while (slot < capacity_ && workers_[slot].joinable()) ++slot;
            if (slot == capacity_) break;
            workers_[slot] = std::thread([this, slot] { workerLoop(slot); });
            ++liveWorkerCount_;
        }
    } catch (...) {
        return false;
    }
    return liveWorkerCount_ >= desired;
}

bool WorkerPool::submit(JobPriority priority, JobFunction function, void* context) noexcept {
    if (!function) return false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_ || queueCount_ == kQueueCapacity) return false;
        // Start only enough workers for the outstanding demand. Threads are reused
        // after the queue drains; no per-job thread creation or eager hardware fan-out.
        const uint32_t demand = activeCount_ + queueCount_ + 1;
        if (!ensureWorkersLocked(demand) && liveWorkerCount_ == 0) return false;
        queue_[queueCount_++] = {function, context, priority, nextSequence_++};
    }
    wake_.notify_all();
    return true;
}

void WorkerPool::setWorkerLimit(uint32_t activeWorkers) noexcept {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        workerLimit_ = std::min<uint32_t>(activeWorkers, capacity_);
        ensureWorkersLocked(activeCount_ + queueCount_);
    }
    wake_.notify_all();
}

uint32_t WorkerPool::cancelPending() noexcept {
    uint32_t cancelled = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        cancelled = queueCount_;
        for (uint32_t i = 0; i < queueCount_; ++i) queue_[i] = Job{};
        queueCount_ = 0;
        if (activeCount_ == 0) idle_.notify_all();
    }
    return cancelled;
}

void WorkerPool::waitIdle() {
    std::unique_lock<std::mutex> lock(mutex_);
    idle_.wait(lock, [this] { return queueCount_ == 0 && activeCount_ == 0; });
}

uint32_t WorkerPool::queued() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return queueCount_;
}

uint32_t WorkerPool::active() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return activeCount_;
}

uint32_t WorkerPool::workerCount() const noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    return liveWorkerCount_;
}

bool WorkerPool::takeJob(Job& out) noexcept {
    if (!queueCount_) return false;
    uint32_t best = 0;
    for (uint32_t i = 1; i < queueCount_; ++i) {
        const Job& candidate = queue_[i];
        const Job& current = queue_[best];
        if (candidate.priority > current.priority ||
            (candidate.priority == current.priority && candidate.sequence < current.sequence))
            best = i;
    }
    out = queue_[best];
    queue_[best] = queue_[--queueCount_];
    queue_[queueCount_] = Job{};
    return true;
}

void WorkerPool::workerLoop(uint32_t index) noexcept {
    for (;;) {
        Job job;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            const bool signalled = wake_.wait_for(lock, idleTimeout_, [this, index] {
                return stopping_ || (index < workerLimit_ && queueCount_ > 0);
            });
            if (!signalled && queueCount_ == 0 && !stopping_) {
                exited_[index] = true;
                --liveWorkerCount_;
                return;
            }
            if (stopping_ && queueCount_ == 0) {
                exited_[index] = true;
                --liveWorkerCount_;
                return;
            }
            if (index >= workerLimit_ || !takeJob(job)) continue;
            ++activeCount_;
        }

        job.function(job.context);

        {
            std::lock_guard<std::mutex> lock(mutex_);
            --activeCount_;
            if (queueCount_ == 0 && activeCount_ == 0) idle_.notify_all();
        }
        wake_.notify_all();
    }
}

AdaptiveWorkerPool::AdaptiveWorkerPool(HardwareProfile hardware, uint32_t maxWorkers)
    : hardware_(hardware),
      capacity_(std::clamp<uint32_t>(maxWorkers, 1, WorkerPool::kMaxWorkers)),
      pool_(capacity_) {
    ExecutionRequest initial;
    initial.workload = WorkloadClass::BackgroundGeneration;
    apply(initial);
}

ExecutionPlan AdaptiveWorkerPool::apply(const ExecutionRequest& request) noexcept {
    plan_ = makeExecutionPlan(hardware_, request);
    pool_.setWorkerLimit(std::min<uint32_t>(capacity_, plan_.workerThreads));
    return plan_;
}

}  // namespace caw
