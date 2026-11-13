// Public C ABI for bounded native jobs used by the app and other hosts.
#include "caw.h"
#include "capi_internal.h"
#include "capi_stress.h"
#include "component_bench.h"
#include "hardware.h"
#include "json.h"
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
enum class TaskKind { Project, Render, Song, Stress, ComponentBench };
enum class State : int32_t { Queued = 0, Running = 1, Succeeded = 2, Failed = 3, Cancelled = 4 };

struct JobState {
    std::atomic<int32_t> state{static_cast<int32_t>(State::Queued)};
    TaskKind kind = TaskKind::Project;
    alignas(4) int32_t progress = 0;
    alignas(4) int32_t cancel = 0;
    std::atomic<int32_t> resultCode{0};
    std::mutex mutex;
    std::mutex waitMutex;
    std::condition_variable waitCv;
    std::string result;
    std::string error;
    std::shared_ptr<caw::stress::Job> stress;  // Stress: the run's progress, history and result (capi_stress.cpp)
};

struct WorkItem {
    std::shared_ptr<JobState> state;
    TaskKind kind = TaskKind::Project;
    std::string projectJson;
    std::string outPath;
    std::string target;
    std::string param;
    std::string request;  // Song: the render request JSON
    CawRenderOptions options{};
    CawEngine* engine = nullptr;
    std::shared_ptr<caw::stress::Job> stress;
    caw::bench::Request bench;  // ComponentBench
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

// A stress job that never ran (cancelled while queued): its result says so, so caw_stress_result answers.
void stressNeverRan(const std::shared_ptr<JobState>& state) noexcept {
    if (!state->stress) return;
    try {
        std::lock_guard<std::mutex> lock(state->stress->mutex);
        state->stress->finished = true;
        state->stress->result.stopReason = "cancelled";
    } catch (...) {
    }
}

void execute(void* raw) noexcept {
    std::unique_ptr<WorkItem> item(static_cast<WorkItem*>(raw));
    const auto state = item->state;
    int32_t expected = static_cast<int32_t>(State::Queued);
    if (!state->state.compare_exchange_strong(expected, static_cast<int32_t>(State::Running),
                                              std::memory_order_acq_rel)) return;
    if ((item->kind == TaskKind::Render || item->kind == TaskKind::Song || item->kind == TaskKind::Stress ||
         item->kind == TaskKind::ComponentBench) &&
        atomicLoad(&state->cancel) != 0) {
        stressNeverRan(state);
        finish(state, State::Cancelled);
        return;
    }
    try {
        if (item->kind == TaskKind::Project) {
            char* output = caw_engine_set_project(item->engine, item->projectJson.c_str());
            if (!output) {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->error = "native project update could not allocate its result";
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

        if (item->kind == TaskKind::Stress) {
            const std::string text = caw::stress::runJob(*item->stress);
            bool ok = false, wasCancelled = false;
            std::string message;
            {
                std::lock_guard<std::mutex> jobLock(item->stress->mutex);
                ok = item->stress->result.ok || item->stress->result.stopReason == "over_budget";
                wasCancelled = item->stress->result.stopReason == "cancelled";
                message = item->stress->result.error;
            }
            std::lock_guard<std::mutex> lock(state->mutex);
            state->result = text;
            if (!ok) {
                state->error = wasCancelled ? "cancelled" : message.empty() ? "native stress run failed" : message;
                state->resultCode.store(1, std::memory_order_relaxed);
            }
            atomicStore(&state->progress, 1000);
            finish(state, ok ? State::Succeeded : wasCancelled ? State::Cancelled : State::Failed);
            return;
        }

        if (item->kind == TaskKind::ComponentBench) {
            const std::string text = caw::bench::run(item->bench, &state->progress, &state->cancel);
            caw::Json parsed;
            std::string parseError;
            const bool read = caw::parseJson(text, parsed, parseError);
            const bool ok = read && parsed.boolean("ok", false);
            std::lock_guard<std::mutex> lock(state->mutex);
            state->result = text;
            if (!ok) {
                state->error = read ? parsed.string("error", "native component bench failed") : "native component bench failed";
                state->resultCode.store(1, std::memory_order_relaxed);
            }
            const bool wasCancelled = atomicLoad(&state->cancel) != 0;
            if (wasCancelled && !ok) state->error = "cancelled";
            finish(state, ok ? State::Succeeded : wasCancelled ? State::Cancelled : State::Failed);
            return;
        }

        if (item->kind == TaskKind::Song) {
            char* output = caw_render_song(item->projectJson.c_str(), item->request.c_str(), &state->progress,
                                           &state->cancel);
            const std::string text = output ? output : "";
            caw_free(output);
            caw::Json parsed;
            std::string parseError;
            const bool read = caw::parseJson(text, parsed, parseError);
            const bool ok = read && parsed.boolean("ok", false);
            std::lock_guard<std::mutex> lock(state->mutex);
            state->result = text;
            if (!ok) {  // the message, as caw_job_error gives it; the whole JSON stays the result
                state->error = read ? parsed.string("error", "native song render failed") : "native song render failed";
                state->resultCode.store(1, std::memory_order_relaxed);
            }
            finish(state, ok ? State::Succeeded : atomicLoad(&state->cancel) != 0 ? State::Cancelled : State::Failed);
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
    state->stress = item->stress;
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
        request->pressure < CAW_PRESSURE_NORMAL || request->pressure > CAW_PRESSURE_UNKNOWN) return 2;
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

CawJob* caw_worker_pool_submit_song(CawWorkerPool* pool, const char* project_json, const char* request_json,
                                    int32_t priority) try {
    if (!pool || !project_json || !request_json) return nullptr;
    auto item = std::make_unique<WorkItem>();
    item->state = std::make_shared<JobState>();
    item->kind = TaskKind::Song;
    item->projectJson = project_json;
    item->request = request_json;
    return submit(pool, std::move(item), priority);
} catch (...) {
    return nullptr;
}

CawJob* caw_worker_pool_submit_stress(CawWorkerPool* pool, const CawStressRequest* request, int32_t priority) try {
    if (!pool || !request) return nullptr;
    std::string error;
    auto job = caw::stress::makeJob(request, error);
    if (!job) return nullptr;
    auto item = std::make_unique<WorkItem>();
    item->state = std::make_shared<JobState>();
    item->kind = TaskKind::Stress;
    item->stress = std::move(job);
    return submit(pool, std::move(item), priority);
} catch (...) {
    return nullptr;
}

CawJob* caw_worker_pool_submit_component_bench(CawWorkerPool* pool, const CawComponentBenchRequest* request) try {
    constexpr size_t minimumSize = offsetof(CawComponentBenchRequest, seconds) + sizeof(double);
    if (!pool || !request || request->struct_size < minimumSize || !request->component_id) return nullptr;
    const double seconds = request->seconds == 0 ? 1.0 : request->seconds;
    if (!(seconds >= 0.1 && seconds <= 10)) return nullptr;
    if (request->library && request->trust_level != CAW_NATIVE_TRUST_TRUSTED) return nullptr;  // never opened otherwise
    auto item = std::make_unique<WorkItem>();
    item->state = std::make_shared<JobState>();
    item->kind = TaskKind::ComponentBench;
    item->bench.id = std::string(request->component_id).substr(0, 256);
    item->bench.library = request->library ? std::string(request->library).substr(0, 4096) : std::string();
    item->bench.trust = request->library ? caw::NativeModuleTrust::Trusted : caw::NativeModuleTrust::Blocked;
    item->bench.seconds = seconds;
    return submit(pool, std::move(item), CAW_JOB_FOREGROUND);
} catch (...) {
    return nullptr;
}

int32_t caw_job_get_status(CawJob* job, CawJobStatus* out) try {
    if (!job || !out || !job->state) return 1;
    constexpr size_t minimumSize = offsetof(CawJobStatus, result_code) + sizeof(int32_t);
    if (out->struct_size < minimumSize) return 2;
    out->state = job->state->state.load(std::memory_order_acquire);
    out->progress = job->state->stress && out->state <= static_cast<int32_t>(State::Running)
                        ? job->state->stress->progress.permille.load(std::memory_order_relaxed)
                        : atomicLoad(&job->state->progress);
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
        stressNeverRan(job->state);
        job->state->waitCv.notify_all();
        return;
    }
    // A running render checks its cancellation flag between render blocks. Running
    // compilation/check jobs are intentionally non-interruptible; queued jobs can cancel.
    if (current == static_cast<int32_t>(State::Running) &&
        (job->state->kind == TaskKind::Render || job->state->kind == TaskKind::Song))
        atomicStore(&job->state->cancel, 1);
    // A stress run checks its own flag at every callback (DSP) or every 100 ms (live).
    if (current == static_cast<int32_t>(State::Running) && job->state->stress)
        job->state->stress->cancel.store(1, std::memory_order_relaxed);
}

void caw_job_release(CawJob* job) { delete job; }

}  // extern "C"

std::shared_ptr<caw::stress::Job> caw::stress::jobOf(CawJob* job) {
    return job && job->state ? job->state->stress : nullptr;
}

extern "C" {

void caw_worker_pool_wait_idle(CawWorkerPool* pool) {
    if (!pool) return;
    try {
        std::lock_guard<std::mutex> lock(pool->apiMutex);
        pool->adaptive.waitIdle();
    } catch (...) {
    }
}
}  // extern "C"
