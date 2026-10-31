// Public C ABI for bounded native jobs used by the app and other hosts.
#include "caw.h"
#include "capi_internal.h"
#include "hardware.h"
#include "scheduler.h"

#include <algorithm>
#include <chrono>
#include <atomic>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <string>

namespace {
enum class TaskKind { Check, Project, Render };
enum class State : int32_t { Queued = 0, Running = 1, Succeeded = 2, Failed = 3, Cancelled = 4 };

struct JobState {
    std::atomic<int32_t> state{static_cast<int32_t>(State::Queued)};
    TaskKind kind = TaskKind::Check;
    alignas(4) int32_t progress = 0;
    alignas(4) int32_t cancel = 0;
    std::atomic<int32_t> resultCode{0};
    std::mutex mutex;
    std::mutex waitMutex;
    std::condition_variable waitCv;
    std::string result;
    std::string error;
};

struct WorkItem {
    std::shared_ptr<JobState> state;
    TaskKind kind = TaskKind::Check;
    std::string source;
    std::string projectJson;
    std::string outPath;
    std::string target;
    std::string param;
    CawRenderOptions options{};
    CawEngine* engine = nullptr;
    ~WorkItem() { if (engine) engine->releaseAsync(); }
};

char* duplicate(const std::string& value) {
    auto* result = static_cast<char*>(std::malloc(value.size() + 1));
    if (result) std::memcpy(result, value.c_str(), value.size() + 1);
    return result;
}

int32_t atomicLoad(int32_t* value) {
#if defined(__cpp_lib_atomic_ref)
    return std::atomic_ref<int32_t>(*value).load(std::memory_order_acquire);
#else
    return __atomic_load_n(value, __ATOMIC_ACQUIRE);
#endif
}

void atomicStore(int32_t* value, int32_t next) {
#if defined(__cpp_lib_atomic_ref)
    std::atomic_ref<int32_t>(*value).store(next, std::memory_order_release);
#else
    __atomic_store_n(value, next, __ATOMIC_RELEASE);
#endif
}

void finish(const std::shared_ptr<JobState>& state, State result) noexcept {
    try {
        std::lock_guard<std::mutex> lock(state->waitMutex);
        state->state.store(static_cast<int32_t>(result), std::memory_order_release);
    } catch (...) {
        state->state.store(static_cast<int32_t>(result), std::memory_order_release);
    }
    state->waitCv.notify_all();
}

void execute(void* raw) noexcept {
    std::unique_ptr<WorkItem> item(static_cast<WorkItem*>(raw));
    const auto state = item->state;
    int32_t expected = static_cast<int32_t>(State::Queued);
    if (!state->state.compare_exchange_strong(expected, static_cast<int32_t>(State::Running),
                                              std::memory_order_acq_rel)) return;
    if (item->kind == TaskKind::Render && atomicLoad(&state->cancel) != 0) {
        finish(state, State::Cancelled);
        return;
    }
    try {
        if (item->kind == TaskKind::Check) {
            char* output = caw_check(item->source.c_str());
            if (!output) {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->error = "native module check could not allocate its result";
                state->resultCode.store(1, std::memory_order_relaxed);
                finish(state, State::Failed);
                return;
            }
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->result = output;
            }
            caw_free(output);
            finish(state, State::Succeeded);
            return;
        }

        if (item->kind == TaskKind::Project) {
            char* output = caw_engine_set_project(item->engine, item->projectJson.c_str());
            if (!output) {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->error = "native project compilation could not allocate its result";
                state->resultCode.store(1, std::memory_order_relaxed);
                finish(state, State::Failed);
                return;
            }
            {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->result = output;
            }
            caw_free(output);
            finish(state, State::Succeeded);
            return;
        }

        item->options.target = item->target.empty() ? nullptr : item->target.c_str();
        item->options.param = item->param.empty() ? nullptr : item->param.c_str();
        char error[512] = {};
        const int32_t code = caw_render(item->projectJson.c_str(), &item->options, item->outPath.c_str(),
                                        &state->progress, &state->cancel, error, sizeof(error));
        state->resultCode.store(code, std::memory_order_relaxed);
        if (code != 0) {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->error = error[0] ? error : "native render failed";
            finish(state, atomicLoad(&state->cancel) != 0 ? State::Cancelled : State::Failed);
            return;
        }
        finish(state, State::Succeeded);
    } catch (...) {
        try {
            std::lock_guard<std::mutex> lock(state->mutex);
            state->error = "native worker job failed unexpectedly";
            state->resultCode.store(1, std::memory_order_relaxed);
        } catch (...) {
            state->resultCode.store(1, std::memory_order_relaxed);
        }
        finish(state, State::Failed);
    }
}

caw::JobPriority priorityFrom(int32_t value) {
    return value == CAW_JOB_FOREGROUND ? caw::JobPriority::Foreground
         : value == CAW_JOB_OFFLINE ? caw::JobPriority::Offline
                                    : caw::JobPriority::Background;
}

bool validPriority(int32_t value) {
    return value >= CAW_JOB_BACKGROUND && value <= CAW_JOB_FOREGROUND;
}

CawJob* submit(CawWorkerPool* pool, std::unique_ptr<WorkItem> item, int32_t priority);
}  // namespace

struct CawWorkerPool {
    explicit CawWorkerPool(uint32_t maxWorkers)
        : adaptive(caw::detectHardwareProfile(), maxWorkers ? maxWorkers : caw::WorkerPool::kMaxWorkers) {}
    caw::AdaptiveWorkerPool adaptive;
    std::mutex apiMutex;
    bool closing = false;
};

struct CawJob {
    explicit CawJob(std::shared_ptr<JobState> value) : state(std::move(value)) {}
    std::shared_ptr<JobState> state;
};

namespace {
CawJob* submit(CawWorkerPool* pool, std::unique_ptr<WorkItem> item, int32_t priority) {
    if (!pool || !item || !validPriority(priority)) return nullptr;
    std::lock_guard<std::mutex> lock(pool->apiMutex);
    if (pool->closing || pool->adaptive.currentPlan().maxConcurrentJobs == 0) return nullptr;
    auto state = item->state;
    state->kind = item->kind;
    auto* context = item.release();
    auto* handle = new (std::nothrow) CawJob(state);
    if (!handle) {
        delete context;
        return nullptr;
    }
    if (!pool->adaptive.submit(priorityFrom(priority), execute, context)) {
        delete context;
        delete handle;
        return nullptr;
    }
    return handle;
}
}  // namespace

extern "C" {
CawWorkerPool* caw_worker_pool_create(uint32_t max_workers) try {
    return new CawWorkerPool(max_workers);
} catch (...) {
    return nullptr;
}

void caw_worker_pool_destroy(CawWorkerPool* pool) {
    if (!pool) return;
    try {
        std::lock_guard<std::mutex> lock(pool->apiMutex);
        pool->closing = true;
        pool->adaptive.waitIdle();
    } catch (...) {
        // Destruction still releases the handle; the worker-pool destructor drains accepted work.
    }
    delete pool;
}

int32_t caw_worker_pool_apply(CawWorkerPool* pool, const CawExecutionRequest* request, CawExecutionPlan* out) try {
    if (!pool || !request || !out) return 1;
    if (request->workload < CAW_WORK_INTERACTIVE_AUDITION || request->workload > CAW_WORK_IDLE ||
        request->pressure < CAW_PRESSURE_NORMAL || request->pressure > CAW_PRESSURE_THERMAL_CRITICAL) return 2;
    std::lock_guard<std::mutex> lock(pool->apiMutex);
    if (pool->closing) return 4;
    if (request->workload == CAW_WORK_IDLE && pool->adaptive.queued() != 0) return 3;

    caw::ExecutionRequest native;
    native.workload = static_cast<caw::WorkloadClass>(request->workload);
    native.pressure = static_cast<caw::DevicePressure>(request->pressure);
    native.foregroundBusy = request->foreground_busy != 0;
    native.allowGpu = request->allow_gpu != 0;
    const caw::ExecutionPlan plan = pool->adaptive.apply(native);
    out->worker_threads = plan.workerThreads;
    out->max_concurrent_jobs = plan.maxConcurrentJobs;
    out->preferred_batch_frames = plan.preferredBatchFrames;
    out->latency_sensitive = plan.latencySensitive ? 1 : 0;
    out->use_simd = plan.useSimd ? 1 : 0;
    out->allow_gpu = plan.allowGpu ? 1 : 0;
    out->yield_to_foreground = plan.yieldToForeground ? 1 : 0;
    return 0;
} catch (...) {
    return 5;
}

CawJob* caw_worker_pool_submit_check(CawWorkerPool* pool, const char* source, int32_t priority) try {
    if (!pool || !source) return nullptr;
    auto item = std::make_unique<WorkItem>();
    item->state = std::make_shared<JobState>();
    item->kind = TaskKind::Check;
    item->source = source;
    return submit(pool, std::move(item), priority);
} catch (...) {
    return nullptr;
}

CawJob* caw_worker_pool_submit_project(CawWorkerPool* pool, CawEngine* engine, const char* project_json,
                                         int32_t priority) try {
    if (!pool || !engine || !project_json) return nullptr;
    auto item = std::make_unique<WorkItem>();
    item->state = std::make_shared<JobState>();
    item->kind = TaskKind::Project;
    item->projectJson = project_json;
    if (!engine->retainAsync()) return nullptr;
    item->engine = engine;
    return submit(pool, std::move(item), priority);
} catch (...) {
    return nullptr;
}

CawJob* caw_worker_pool_submit_render(CawWorkerPool* pool, const char* project_json,
                                       const CawRenderOptions* options, const char* out_path,
                                       int32_t priority) try {
    if (!pool || !project_json || !options || !out_path) return nullptr;
    auto item = std::make_unique<WorkItem>();
    item->state = std::make_shared<JobState>();
    item->kind = TaskKind::Render;
    item->projectJson = project_json;
    item->outPath = out_path;
    item->options = *options;
    if (options->target) item->target = options->target;
    if (options->param) item->param = options->param;
    return submit(pool, std::move(item), priority);
} catch (...) {
    return nullptr;
}

int32_t caw_job_get_status(CawJob* job, CawJobStatus* out) try {
    if (!job || !out || !job->state) return 1;
    constexpr size_t minimumSize = offsetof(CawJobStatus, result_code) + sizeof(int32_t);
    if (out->struct_size < minimumSize) return 2;
    out->state = job->state->state.load(std::memory_order_acquire);
    out->progress = atomicLoad(&job->state->progress);
    out->result_code = job->state->resultCode.load(std::memory_order_relaxed);
    return 0;
} catch (...) {
    return 3;
}

char* caw_job_result(CawJob* job) try {
    if (!job || !job->state ||
        job->state->state.load(std::memory_order_acquire) != static_cast<int32_t>(State::Succeeded)) return nullptr;
    std::lock_guard<std::mutex> lock(job->state->mutex);
    return duplicate(job->state->result);
} catch (...) {
    return nullptr;
}

char* caw_job_error(CawJob* job) try {
    if (!job || !job->state) return nullptr;
    const int32_t state = job->state->state.load(std::memory_order_acquire);
    if (state != static_cast<int32_t>(State::Failed) && state != static_cast<int32_t>(State::Cancelled)) return nullptr;
    std::lock_guard<std::mutex> lock(job->state->mutex);
    if (!job->state->error.empty()) return duplicate(job->state->error);
    return duplicate(state == static_cast<int32_t>(State::Cancelled) ? "cancelled" : "native job failed");
} catch (...) {
    return nullptr;
}

int32_t caw_job_wait(CawJob* job, uint32_t timeout_ms) try {
    if (!job || !job->state) return 1;
    std::unique_lock<std::mutex> lock(job->state->waitMutex);
    const auto done = [&] { return job->state->state.load(std::memory_order_acquire) >= static_cast<int32_t>(State::Succeeded); };
    if (timeout_ms == 0xffffffffu) {
        job->state->waitCv.wait(lock, done);
        return 0;
    }
    return job->state->waitCv.wait_for(lock, std::chrono::milliseconds(timeout_ms), done) ? 0 : 2;
} catch (...) {
    return 3;
}

void caw_job_cancel(CawJob* job) {
    if (!job || !job->state) return;
    int32_t current = job->state->state.load(std::memory_order_acquire);
    bool cancelledWhileQueued = false;
    try {
        std::lock_guard<std::mutex> lock(job->state->waitMutex);
        while (current == static_cast<int32_t>(State::Queued)) {
            if (job->state->state.compare_exchange_weak(current, static_cast<int32_t>(State::Cancelled),
                                                         std::memory_order_acq_rel)) {
                cancelledWhileQueued = true;
                break;
            }
        }
    } catch (...) {
        return;
    }
    if (cancelledWhileQueued) {
        job->state->waitCv.notify_all();
        return;
    }
    // A running render checks its cancellation flag between render blocks. Running
    // compilation/check jobs are intentionally non-interruptible; queued jobs can cancel.
    if (current == static_cast<int32_t>(State::Running) && job->state->kind == TaskKind::Render)
        atomicStore(&job->state->cancel, 1);
}

void caw_job_release(CawJob* job) { delete job; }

void caw_worker_pool_wait_idle(CawWorkerPool* pool) {
    if (!pool) return;
    try {
        std::lock_guard<std::mutex> lock(pool->apiMutex);
        pool->adaptive.waitIdle();
    } catch (...) {
    }
}
}  // extern "C"
