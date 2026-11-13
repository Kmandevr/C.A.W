// The Benchmark's job (API 27), between worker_api.cpp's CawJob and capi_stress.cpp's runs.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

#include "caw.h"
#include "stress_run.h"

namespace caw::stress {

// One caw_worker_pool_submit_stress job: the request, what the run shows while it goes, and its result.
struct Job {
    RunRequest request;
    int32_t mode = CAW_STRESS_DSP;
    std::string scenarioId;  // as asked (ramps: "")
    Progress progress;
    LoadHistory history;
    std::atomic<int32_t> cancel{0};
    std::mutex mutex;  // guards the rest
    bool finished = false;
    RunResult result;
    int32_t deviceFrames = 0, deviceRate = 0;  // live: the callback size and rate the device ran at
    int32_t xruns = -1;                        // live: underruns the platform reported during the timed span (-1: none)
    int32_t warmupXruns = -1;                  // live: those during the warm-up after Play (-1: none)
    int32_t callbackCore = -1;                 // live: the core the last callback ran on (-1: unknown)
};

// A job for a request, or null with `error` (bad struct_size, kind, mode, seconds, frames, threads or quality).
std::shared_ptr<Job> makeJob(const CawStressRequest* request, std::string& error);
// Runs it on the calling worker to the end or cancel and returns its result JSON (caw_job_result).
std::string runJob(Job& job);
// The job a CawJob carries (null: not a stress job). worker_api.cpp.
std::shared_ptr<Job> jobOf(CawJob* job);

}  // namespace caw::stress
