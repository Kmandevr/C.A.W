// Platform probe returns conservative bounded capabilities without requiring a device backend.
#include "test.h"

#include "hardware.h"

using namespace caw;

TEST(hardware_probe_returns_safe_nonzero_resource_limits) {
    const HardwareProfile hw = detectHardwareProfile();
    CHECK(hw.logicalCores >= 1);
    CHECK(hw.logicalCores <= 256);
    CHECK(hw.memoryBudgetMiB >= 64);
    CHECK(hw.memoryBudgetMiB <= 8192);
}
