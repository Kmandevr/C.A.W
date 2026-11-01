// Tests for the public C ABI execution planner used by app and add-on hosts.
#include "test.h"
#include "caw.h"

TEST(execution_c_api_exposes_shared_host_policy) {
    CawHardwareProfile hw{8, 8192, 1, 1};
    CawExecutionRequest req{CAW_WORK_OFFLINE_RENDER, CAW_PRESSURE_NORMAL, 0, 1};
    CawExecutionPlan out{};
    CHECK_EQ(caw_execution_plan(&hw, &req, &out), 0);
    CHECK_EQ(out.worker_threads, 8);
    CHECK_EQ(out.max_concurrent_jobs, 8);
    CHECK_EQ(out.preferred_batch_frames, 4096u);
    CHECK(out.use_simd);
    CHECK(out.allow_gpu);
}

TEST(execution_c_api_accepts_unknown_pressure_without_enabling_gpu) {
    CawHardwareProfile hw{8, 8192, 1, 1};
    CawExecutionRequest req{CAW_WORK_OFFLINE_RENDER, CAW_PRESSURE_UNKNOWN, 0, 1};
    CawExecutionPlan out{};
    CHECK_EQ(caw_execution_plan(&hw, &req, &out), 0);
    CHECK_EQ(out.worker_threads, 7);
    CHECK_EQ(out.max_concurrent_jobs, 7);
    CHECK_EQ(out.yield_to_foreground, 1);
    CHECK_EQ(out.allow_gpu, 0);
}

TEST(execution_c_api_rejects_invalid_inputs) {
    CawHardwareProfile hw{4, 2048, 1, 0};
    CawExecutionRequest req{99, CAW_PRESSURE_NORMAL, 0, 1};
    CawExecutionPlan out{};
    CHECK_EQ(caw_execution_plan(&hw, &req, &out), 2);
    CHECK_EQ(caw_execution_plan(nullptr, &req, &out), 1);
    CHECK_EQ(caw_execution_plan(&hw, nullptr, &out), 1);
    CHECK_EQ(caw_execution_plan(&hw, &req, nullptr), 1);
}

TEST(hardware_profile_c_api_detects_bounded_host_capabilities) {
    CawHardwareProfile profile{};
    CHECK_EQ(caw_hardware_profile_detect(&profile), 0);
    CHECK(profile.logical_cores >= 1);
    CHECK(profile.memory_budget_mib <= 8192);
    CHECK(profile.memory_budget_mib <= 8192);
    CHECK(profile.supports_simd == 0 || profile.supports_simd == 1);
    CHECK_EQ(profile.supports_gpu_compute, 0);
    CHECK_EQ(caw_hardware_profile_detect(nullptr), 1);
}
