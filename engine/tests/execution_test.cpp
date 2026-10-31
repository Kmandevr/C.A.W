// Tests for workload-aware execution planning on small and large hardware profiles.
#include "test.h"

#include "execution.h"

using namespace caw;

TEST(execution_audition_is_latency_sensitive_and_bounded) {
    HardwareProfile hw{8, 8192, true, true};
    ExecutionRequest req;
    req.workload = WorkloadClass::InteractiveAudition;
    const ExecutionPlan p = makeExecutionPlan(hw, req);
    CHECK_EQ(p.workerThreads, 1);
    CHECK_EQ(p.preferredBatchFrames, 64u);
    CHECK(p.latencySensitive);
    CHECK(!p.allowGpu);
    CHECK(p.yieldToForeground);
}

TEST(execution_background_leaves_capacity_for_foreground) {
    HardwareProfile hw{8, 8192, true, false};
    ExecutionRequest req;
    req.workload = WorkloadClass::BackgroundGeneration;
    req.pressure = DevicePressure::Normal;
    const ExecutionPlan normal = makeExecutionPlan(hw, req);
    CHECK_EQ(normal.workerThreads, 7);
    req.foregroundBusy = true;
    const ExecutionPlan busy = makeExecutionPlan(hw, req);
    CHECK_EQ(busy.workerThreads, 6);
    CHECK(busy.yieldToForeground);
}

TEST(execution_offline_uses_available_hardware) {
    HardwareProfile hw{12, 16384, true, true};
    ExecutionRequest req;
    req.workload = WorkloadClass::OfflineRender;
    req.pressure = DevicePressure::Normal;
    const ExecutionPlan p = makeExecutionPlan(hw, req);
    CHECK_EQ(p.workerThreads, 12);
    CHECK_EQ(p.preferredBatchFrames, 4096u);
    CHECK(p.allowGpu);
    CHECK(p.useSimd);
}

TEST(execution_small_device_never_oversubscribes_memory_or_cores) {
    HardwareProfile hw{2, 64, false, true};
    ExecutionRequest req;
    req.workload = WorkloadClass::OfflineRender;
    const ExecutionPlan p = makeExecutionPlan(hw, req);
    CHECK_EQ(p.workerThreads, 1);
    CHECK_EQ(p.maxConcurrentJobs, 1);
    CHECK(!p.allowGpu);
    CHECK(!p.useSimd);
}

TEST(execution_thermal_and_battery_pressure_reduce_background_work) {
    HardwareProfile hw{8, 8192, true, true};
    ExecutionRequest req;
    req.workload = WorkloadClass::OfflineRender;
    req.pressure = DevicePressure::BatterySaver;
    const ExecutionPlan battery = makeExecutionPlan(hw, req);
    CHECK_EQ(battery.workerThreads, 4);
    CHECK(!battery.allowGpu);
    req.pressure = DevicePressure::ThermalCritical;
    const ExecutionPlan hot = makeExecutionPlan(hw, req);
    CHECK_EQ(hot.workerThreads, 1);
    CHECK(!hot.allowGpu);
    CHECK(hot.yieldToForeground);
}

TEST(execution_unknown_pressure_reserves_one_host_core_for_offline_work) {
    HardwareProfile hw{8, 8192, true, false};
    ExecutionRequest req;
    req.workload = WorkloadClass::OfflineRender;
    req.pressure = DevicePressure::Unknown;
    const ExecutionPlan p = makeExecutionPlan(hw, req);
    CHECK_EQ(p.workerThreads, 7);
    CHECK(p.yieldToForeground);
    CHECK(!p.allowGpu);

    req.workload = WorkloadClass::InteractivePreview;
    req.foregroundBusy = true;
    const ExecutionPlan preview = makeExecutionPlan(hw, req);
    CHECK_EQ(preview.workerThreads, 1);
    CHECK(preview.yieldToForeground);
}

TEST(execution_idle_releases_worker_budget) {
    HardwareProfile hw{8, 8192, true, true};
    ExecutionRequest req;
    req.workload = WorkloadClass::Idle;
    const ExecutionPlan p = makeExecutionPlan(hw, req);
    CHECK_EQ(p.workerThreads, 0);
    CHECK_EQ(p.maxConcurrentJobs, 0);
    CHECK_EQ(p.preferredBatchFrames, 0u);
    CHECK(!p.useSimd);
}
