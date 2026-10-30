// Tests for bounded scheduling, priority ordering, worker limits and cancellation.
#include "test.h"

#include "scheduler.h"

#include <atomic>
#include <chrono>
#include <thread>

using namespace caw;

namespace {
struct TaskState { std::atomic<int>* value; int add; };
void addTask(void* p) noexcept {
    auto* state = static_cast<TaskState*>(p);
    state->value->fetch_add(state->add, std::memory_order_relaxed);
}
}

TEST(scheduler_runs_jobs_and_waits_for_idle) {
    WorkerPool pool(2);
    std::atomic<int> value{0};
    TaskState a{&value, 2}, b{&value, 3}, c{&value, 5};
    CHECK(pool.submit(JobPriority::Background, addTask, &a));
    CHECK(pool.submit(JobPriority::Foreground, addTask, &b));
    CHECK(pool.submit(JobPriority::Offline, addTask, &c));
    pool.waitIdle();
    CHECK_EQ(value.load(), 10);
    CHECK_EQ(pool.queued(), 0u);
    CHECK_EQ(pool.active(), 0u);
}

TEST(scheduler_respects_worker_limit_and_cancels_queued_work) {
    WorkerPool pool(2);
    pool.setWorkerLimit(0);
    std::atomic<int> value{0};
    TaskState a{&value, 1}, b{&value, 10};
    CHECK(pool.submit(JobPriority::Background, addTask, &a));
    CHECK(pool.submit(JobPriority::Background, addTask, &b));
    CHECK_EQ(pool.cancelPending(), 2u);
    pool.waitIdle();
    CHECK_EQ(value.load(), 0);
}

TEST(scheduler_rejects_null_jobs_and_caps_worker_count) {
    WorkerPool pool(WorkerPool::kMaxWorkers + 10);
    pool.setWorkerLimit(0);
    CHECK(!pool.submit(JobPriority::Foreground, nullptr, nullptr));
    std::atomic<int> value{0};
    TaskState a{&value, 1};
    for (uint32_t i = 0; i < WorkerPool::kQueueCapacity; ++i)
        CHECK(pool.submit(JobPriority::Background, addTask, &a));
    CHECK(!pool.submit(JobPriority::Background, addTask, &a));
    pool.setWorkerLimit(WorkerPool::kMaxWorkers);
    pool.waitIdle();
    CHECK_EQ(value.load(), static_cast<int>(WorkerPool::kQueueCapacity));
}

TEST(scheduler_shutdown_drains_accepted_jobs_even_when_budget_is_zero) {
    std::atomic<int> value{0};
    TaskState state{&value, 7};
    {
        WorkerPool pool(2);
        pool.setWorkerLimit(0);
        CHECK(pool.submit(JobPriority::Offline, addTask, &state));
    }
    CHECK_EQ(value.load(), 7);
}

namespace {
struct OrderTask { int* output; std::atomic<int>* cursor; int value; };
void recordOrder(void* p) noexcept {
    auto* task = static_cast<OrderTask*>(p);
    const int at = task->cursor->fetch_add(1, std::memory_order_relaxed);
    task->output[at] = task->value;
}
}

TEST(scheduler_runs_higher_priority_jobs_first_and_preserves_fifo_within_priority) {
    WorkerPool pool(1);
    pool.setWorkerLimit(0);
    int order[4] = {};
    std::atomic<int> cursor{0};
    OrderTask background{order, &cursor, 1}, offline{order, &cursor, 2};
    OrderTask foregroundA{order, &cursor, 3}, foregroundB{order, &cursor, 4};
    CHECK(pool.submit(JobPriority::Background, recordOrder, &background));
    CHECK(pool.submit(JobPriority::Offline, recordOrder, &offline));
    CHECK(pool.submit(JobPriority::Foreground, recordOrder, &foregroundA));
    CHECK(pool.submit(JobPriority::Foreground, recordOrder, &foregroundB));
    pool.setWorkerLimit(1);
    pool.waitIdle();
    CHECK(order[0] == 3);
    CHECK(order[1] == 4);
    CHECK(order[2] == 2);
    CHECK(order[3] == 1);
}
