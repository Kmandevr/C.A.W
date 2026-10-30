// C ABI adapter for the portable execution policy. Host code owns capability detection and worker scheduling.
#include "caw.h"
#include "execution.h"
#include "hardware.h"

#include <algorithm>

extern "C" CAW_API int32_t caw_execution_plan(const CawHardwareProfile* hardware,
                                               const CawExecutionRequest* request,
                                               CawExecutionPlan* out) {
    if (!hardware || !request || !out) return 1;
    if (request->workload < CAW_WORK_INTERACTIVE_AUDITION || request->workload > CAW_WORK_IDLE ||
        request->pressure < CAW_PRESSURE_NORMAL || request->pressure > CAW_PRESSURE_THERMAL_CRITICAL) {
        return 2;
    }

    caw::HardwareProfile hw;
    hw.logicalCores = std::max<uint16_t>(1, hardware->logical_cores);
    hw.memoryBudgetMiB = std::max<uint32_t>(1, hardware->memory_budget_mib);
    hw.supportsSimd = hardware->supports_simd != 0;
    hw.supportsGpuCompute = hardware->supports_gpu_compute != 0;

    caw::ExecutionRequest req;
    req.workload = static_cast<caw::WorkloadClass>(request->workload);
    req.pressure = static_cast<caw::DevicePressure>(request->pressure);
    req.foregroundBusy = request->foreground_busy != 0;
    req.allowGpu = request->allow_gpu != 0;

    const caw::ExecutionPlan plan = caw::makeExecutionPlan(hw, req);
    out->worker_threads = plan.workerThreads;
    out->max_concurrent_jobs = plan.maxConcurrentJobs;
    out->preferred_batch_frames = plan.preferredBatchFrames;
    out->latency_sensitive = plan.latencySensitive ? 1 : 0;
    out->use_simd = plan.useSimd ? 1 : 0;
    out->allow_gpu = plan.allowGpu ? 1 : 0;
    out->yield_to_foreground = plan.yieldToForeground ? 1 : 0;
    return 0;
}


extern "C" CAW_API int32_t caw_hardware_profile_detect(CawHardwareProfile* out) {
    if (!out) return 1;
    const caw::HardwareProfile profile = caw::detectHardwareProfile();
    out->logical_cores = profile.logicalCores;
    out->memory_budget_mib = profile.memoryBudgetMiB;
    out->supports_simd = profile.supportsSimd ? 1 : 0;
    out->supports_gpu_compute = profile.supportsGpuCompute ? 1 : 0;
    return 0;
}
