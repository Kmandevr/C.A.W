// Tests for the public native worker-pool job API.
#include "test.h"

#include "caw.h"

#include <chrono>
#include <cstring>
#include <thread>

namespace {
bool waitFor(CawJob* job, CawJobStatus& status) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (std::chrono::steady_clock::now() < deadline) {
        status.struct_size = sizeof(status);
        if (caw_job_get_status(job, &status) != 0) return false;
        if (status.state >= 2) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    return false;
}
}

TEST(worker_api_submits_checks_and_returns_owned_results) {
    CawWorkerPool* pool = caw_worker_pool_create(2);
    CHECK(pool != nullptr);
    if (!pool) return;

    CawExecutionRequest request{};
    request.workload = CAW_WORK_INTERACTIVE_PREVIEW;
    request.pressure = CAW_PRESSURE_NORMAL;
    CawExecutionPlan plan{};
    CHECK_EQ(caw_worker_pool_apply(pool, &request, &plan), 0);
    CHECK(plan.worker_threads >= 1);
    CHECK(plan.max_concurrent_jobs >= 1);

    CawJob* good = caw_worker_pool_submit_check(pool, "sin(t)", CAW_JOB_FOREGROUND);
    CHECK(good != nullptr);
    if (good) {
        CawJobStatus tooSmall{};
        CHECK_EQ(caw_job_get_status(good, &tooSmall), 2);
        CawJobStatus status{};
        CHECK(waitFor(good, status));
        CHECK_EQ(status.state, CAW_JOB_SUCCEEDED);
        char* result = caw_job_result(good);
        CHECK(result != nullptr);
        if (result) {
            CHECK(std::strstr(result, "\"ok\":true") != nullptr);
            caw_free(result);
        }
        caw_job_release(good);
    }

    CawJob* invalid = caw_worker_pool_submit_check(pool, "t >>", CAW_JOB_BACKGROUND);
    CHECK(invalid != nullptr);
    if (invalid) {
        CawJobStatus status{};
        CHECK(waitFor(invalid, status));
        CHECK_EQ(status.state, CAW_JOB_SUCCEEDED);
        char* result = caw_job_result(invalid);
        CHECK(result != nullptr);
        if (result) {
            CHECK(std::strstr(result, "\"ok\":false") != nullptr);
            caw_free(result);
        }
        caw_job_release(invalid);
    }
    caw_worker_pool_wait_idle(pool);
    caw_worker_pool_destroy(pool);
}

TEST(worker_api_rejects_submission_when_idle) {
    CawWorkerPool* pool = caw_worker_pool_create(1);
    CHECK(pool != nullptr);
    if (!pool) return;
    CawExecutionRequest idle{};
    idle.workload = CAW_WORK_IDLE;
    idle.pressure = CAW_PRESSURE_NORMAL;
    CawExecutionPlan plan{};
    CHECK_EQ(caw_worker_pool_apply(pool, &idle, &plan), 0);
    CHECK_EQ(plan.max_concurrent_jobs, 0);
    CHECK(caw_worker_pool_submit_check(pool, "sin(t)", CAW_JOB_FOREGROUND) == nullptr);
    caw_worker_pool_destroy(pool);
}

TEST(worker_api_project_jobs_keep_engine_alive_until_completion) {
    CawWorkerPool* pool = caw_worker_pool_create(2);
    CHECK(pool != nullptr);
    if (!pool) return;
    CawExecutionRequest request{};
    request.workload = CAW_WORK_INTERACTIVE_AUDITION;
    request.pressure = CAW_PRESSURE_NORMAL;
    CawExecutionPlan plan{};
    CHECK_EQ(caw_worker_pool_apply(pool, &request, &plan), 0);

    CawEngine* engine = caw_engine_create(48000);
    CHECK(engine != nullptr);
    if (!engine) {
        caw_worker_pool_destroy(pool);
        return;
    }
    const char* project = R"({"caw_project":1,"name":"worker test","bpm":120,"beats_per_bar":4,"loop_bars":1,"modules":[{"id":"tone","name":"Tone","source":"---\nmode: float\n---\n0.2"}],"layers":[{"id":"track","name":"Tone","chain":["tone"],"length_steps":16}]})CAW";
    CawJob* job = caw_worker_pool_submit_project(pool, engine, project, CAW_JOB_FOREGROUND);
    CHECK(job != nullptr);
    // Destroy waits for the retained project job instead of invalidating its engine pointer.
    caw_engine_destroy(engine);
    if (job) {
        CawJobStatus status{};
        CHECK(waitFor(job, status));
        CHECK_EQ(status.state, CAW_JOB_SUCCEEDED);
        char* result = caw_job_result(job);
        CHECK(result != nullptr);
        if (result) {
            CHECK(std::strstr(result, "\"modules\"") != nullptr);
            caw_free(result);
        }
        caw_job_release(job);
    }
    caw_worker_pool_destroy(pool);
}

TEST(worker_api_cancels_offline_render_and_keeps_released_handles_safe) {
    CawWorkerPool* pool = caw_worker_pool_create(2);
    CHECK(pool != nullptr);
    if (!pool) return;
    CawExecutionRequest request{};
    request.workload = CAW_WORK_BACKGROUND_GENERATION;
    request.pressure = CAW_PRESSURE_NORMAL;
    CawExecutionPlan plan{};
    CHECK_EQ(caw_worker_pool_apply(pool, &request, &plan), 0);

    const char* project = R"CAW({"caw_project":1,"name":"cancel test","bpm":120,"beats_per_bar":4,"loop_bars":1,"modules":[{"id":"tone","name":"Tone","source":"---\nmode: float\n---\nsin(220)"}],"layers":[{"id":"track","name":"Tone","chain":["tone"],"length_steps":16}]})CAW";
    CawRenderOptions options{};
    options.kind = CAW_EXPORT_FREE;
    options.sample_rate = 48000;
    options.float32 = 1;
    options.seconds = 30.0;
    CawJob* render = caw_worker_pool_submit_render(pool, project, &options,
                                                   "caw-worker-api-cancel-test.wav", CAW_JOB_OFFLINE);
    CHECK(render != nullptr);
    if (render) {
        caw_job_cancel(render);
        CawJobStatus status{};
        CHECK(waitFor(render, status));
        CHECK_EQ(status.state, CAW_JOB_CANCELLED);
        char* error = caw_job_error(render);
        CHECK(error != nullptr);
        if (error) {
            CHECK(std::strstr(error, "cancelled") != nullptr);
            caw_free(error);
        }
        caw_job_release(render);
    }

    CawJob* released = caw_worker_pool_submit_check(pool, "sin(t)", CAW_JOB_BACKGROUND);
    CHECK(released != nullptr);
    caw_job_release(released);  // The worker owns its context independently of the public handle.
    caw_worker_pool_wait_idle(pool);
    caw_worker_pool_destroy(pool);
}
