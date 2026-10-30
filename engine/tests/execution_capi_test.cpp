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

TEST(execution_c_api_rejects_invalid_inputs) {
    CawHardwareProfile hw{4, 2048, 1, 0};
    CawExecutionRequest req{99, CAW_PRESSURE_NORMAL, 0, 1};
    CawExecutionPlan out{};
    CHECK_EQ(caw_execution_plan(&hw, &req, &out), 2);
    CHECK_EQ(caw_execution_plan(nullptr, &req, &out), 1);
    CHECK_EQ(caw_execution_plan(&hw, nullptr, &out), 1);
    CHECK_EQ(caw_execution_plan(&hw, &req, nullptr), 1);
}
