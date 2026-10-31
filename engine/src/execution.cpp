// Deterministic, hardware-aware execution policy for non-real-time CAW workloads.
#include "execution.h"

#include <algorithm>

namespace caw {
namespace {

uint16_t boundedWorkers(uint16_t wanted, const HardwareProfile& hw) noexcept {
    const uint16_t cores = std::max<uint16_t>(1, hw.logicalCores);
    const uint32_t memoryWorkers = std::max<uint32_t>(1, hw.memoryBudgetMiB / 64);
    return static_cast<uint16_t>(std::max<uint32_t>(1, std::min<uint32_t>(wanted, std::min<uint32_t>(cores, memoryWorkers))));
}

}  // namespace

ExecutionPlan makeExecutionPlan(const HardwareProfile& hardware, const ExecutionRequest& request) noexcept {
    const uint16_t cores = std::max<uint16_t>(1, hardware.logicalCores);
    ExecutionPlan plan;
    plan.useSimd = hardware.supportsSimd;

    switch (request.workload) {
        case WorkloadClass::InteractiveAudition:
            // Audio itself stays on the host's real-time callback. This worker is for
            // compilation/graph preparation and must not compete with the UI.
            plan.workerThreads = 1;
            plan.preferredBatchFrames = 64;
            plan.latencySensitive = true;
            plan.yieldToForeground = true;
            break;
        case WorkloadClass::InteractivePreview:
            plan.workerThreads = cores > 1 ? 2 : 1;
            plan.preferredBatchFrames = 256;
            plan.yieldToForeground = true;
            break;
        case WorkloadClass::BackgroundGeneration:
            plan.workerThreads = cores > 1 ? static_cast<uint16_t>(cores - 1) : 1;
            plan.preferredBatchFrames = 1024;
            plan.yieldToForeground = true;
            break;
        case WorkloadClass::OfflineRender:
            plan.workerThreads = cores;
            plan.preferredBatchFrames = 4096;
            break;
        case WorkloadClass::Idle:
            plan.workerThreads = 0;
            plan.maxConcurrentJobs = 0;
            plan.preferredBatchFrames = 0;
            plan.useSimd = false;
            return plan;
    }

    if (request.foregroundBusy && request.workload == WorkloadClass::InteractivePreview) {
        plan.workerThreads = 1;
        plan.yieldToForeground = true;
    } else if (request.foregroundBusy && request.workload != WorkloadClass::InteractiveAudition &&
               request.pressure != DevicePressure::Unknown) {
        plan.workerThreads = std::max<uint16_t>(1, static_cast<uint16_t>(plan.workerThreads - 1));
        plan.yieldToForeground = true;
    }

    switch (request.pressure) {
        case DevicePressure::Unknown:
            // No verified pressure feed: reserve one core for the host/audio/UI when possible.
            if (request.workload != WorkloadClass::InteractiveAudition &&
                request.workload != WorkloadClass::InteractivePreview) {
                plan.workerThreads = std::max<uint16_t>(1, std::min<uint16_t>(plan.workerThreads,
                    cores > 1 ? static_cast<uint16_t>(cores - 1) : 1));
            }
            plan.yieldToForeground = true;
            break;
        case DevicePressure::Normal:
            break;
        case DevicePressure::BatterySaver:
            plan.workerThreads = std::max<uint16_t>(1, static_cast<uint16_t>((plan.workerThreads + 1) / 2));
            plan.yieldToForeground = true;
            break;
        case DevicePressure::ThermalWarm:
            plan.workerThreads = std::max<uint16_t>(1, static_cast<uint16_t>(plan.workerThreads - 1));
            plan.yieldToForeground = true;
            break;
        case DevicePressure::ThermalHot:
        case DevicePressure::ThermalCritical:
            plan.workerThreads = 1;
            plan.yieldToForeground = true;
            break;
    }

    plan.workerThreads = boundedWorkers(plan.workerThreads, hardware);
    plan.maxConcurrentJobs = plan.workerThreads;

    // GPU startup/transfer costs make it inappropriate for short interactive work.
    // The host still decides whether a supported GPU kernel exists for a given task.
    const bool gpuWorkload = request.workload == WorkloadClass::BackgroundGeneration ||
                             request.workload == WorkloadClass::OfflineRender;
    plan.allowGpu = request.allowGpu && hardware.supportsGpuCompute && gpuWorkload &&
                    hardware.memoryBudgetMiB >= 1024 &&
                    request.pressure != DevicePressure::ThermalHot &&
                    request.pressure != DevicePressure::ThermalCritical &&
                    request.pressure != DevicePressure::BatterySaver &&
                    request.pressure != DevicePressure::Unknown;
    return plan;
}

}  // namespace caw
