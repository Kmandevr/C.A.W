// Portable workload policy: maps task classes and host-reported hardware pressure to bounded execution advice.
#pragma once

#include <cstdint>

namespace caw {

enum class WorkloadClass : uint8_t {
    InteractiveAudition,
    InteractivePreview,
    BackgroundGeneration,
    OfflineRender,
    Idle
};

enum class DevicePressure : uint8_t {
    Normal,
    BatterySaver,
    ThermalWarm,
    ThermalHot,
    ThermalCritical
};

// Supplied by the platform host from supported OS APIs and measured probes.
// This type deliberately performs no OS queries and is safe to use in tests.
struct HardwareProfile {
    uint16_t logicalCores = 1;
    uint32_t memoryBudgetMiB = 256;
    bool supportsSimd = false;
    bool supportsGpuCompute = false;
};

struct ExecutionRequest {
    WorkloadClass workload = WorkloadClass::InteractivePreview;
    DevicePressure pressure = DevicePressure::Normal;
    bool foregroundBusy = false;
    bool allowGpu = true;
};

struct ExecutionPlan {
    uint16_t workerThreads = 1;
    uint16_t maxConcurrentJobs = 1;
    uint32_t preferredBatchFrames = 256;
    bool latencySensitive = false;
    bool useSimd = false;
    bool allowGpu = false;
    bool yieldToForeground = false;
};

// Pure, deterministic policy selection. This is advice for non-callback work;
// it never changes audio callback behavior or sound quality.
ExecutionPlan makeExecutionPlan(const HardwareProfile& hardware, const ExecutionRequest& request) noexcept;

}  // namespace caw
