// Bounded scheduler for compilation, rendering, analysis and asset work. Audio never calls into this class.
#include "scheduler.h"

#include <algorithm>

namespace caw {

WorkerPool::WorkerPool(uint32_t workers) {
    const uint32_t count = std::clamp<uint32_t>(workers, 1, kMaxWorkers);
    workerLimit_ = count;
    workers_.reserve(count);
    try {
        for (uint32_t i = 0; i < count; ++i)
            workers_.emplace_back([this, i] { workerLoop(i); });
    } catch (...) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
        }
        wake_.notify_all();
        for (std::thread& worker : workers_) if (worker.joinable()) worker.join();
        throw;
    }
}

WorkerPool::~WorkerPool() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        workerLimit_ = static_cast<uint32_t>(workers_.size()); // drain accepted work during orderly shutdown
    }
    wake_.notify_all();
    for (std::thread& worker : workers_) if (worker.joinable()) worker.join();
}

bool WorkerPool::submit(JobPriority priority, JobFunction function, void* context) noexcept {
    if (!function) return false;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_ || queueCount_ == kQueueCapacity) return false;
        queue_[queueCount_++] = {function, context, priority, nextSequence_++};
    }
    wake_.notify_all();
    return true;
}

void WorkerPool::setWorkerLimit(uint32_t activeWorkers) noexcept {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        workerLimit_ = std::min<uint32_t>(activeWorkers, static_cast<uint32_t>(workers_.size()));
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
            wake_.wait(lock, [this, index] {
                return stopping_ || (index < workerLimit_ && queueCount_ > 0);
            });
            if (stopping_ && queueCount_ == 0) return;
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

}  // namespace caw
