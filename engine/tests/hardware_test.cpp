// Platform probe returns conservative bounded capabilities without requiring a device backend.
#include "test.h"

#include "hardware.h"

using namespace caw;

TEST(hardware_memory_budget_does_not_overstate_low_available_memory) {
    CHECK_EQ(conservativeMemoryBudgetMiB(0), 0u);
    CHECK_EQ(conservativeMemoryBudgetMiB(1ull * 1024ull * 1024ull), 1u);
    CHECK_EQ(conservativeMemoryBudgetMiB(64ull * 1024ull * 1024ull), 16u);
    CHECK_EQ(conservativeMemoryBudgetMiB(1024ull * 1024ull * 1024ull), 256u);
    CHECK_EQ(conservativeMemoryBudgetMiB(65536ull * 1024ull * 1024ull), 8192u);
}

TEST(hardware_probe_returns_safe_bounded_capabilities_without_device_backend) {
    const HardwareProfile hw = detectHardwareProfile();
    CHECK(hw.logicalCores >= 1);
    CHECK(hw.logicalCores <= 256);
    // A zero memory budget means unavailable; a positive value is always conservative and bounded.
    CHECK(hw.memoryBudgetMiB <= 8192);
}
