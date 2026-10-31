// Platform capability snapshot for workload planning. Thermal/battery pressure remains host supplied.
#pragma once

#include <cstdint>
#include "execution.h"

namespace caw {

// Best-effort snapshot: online logical cores, a conservative memory budget and SIMD support.
// GPU compute is false until a concrete, tested CAW compute backend is available.
HardwareProfile detectHardwareProfile() noexcept;

// Converts a measured available-memory byte count into a conservative scheduler budget.
// Zero means the measurement is unavailable; positive low-memory measurements are not rounded up to 16 MiB.
uint32_t conservativeMemoryBudgetMiB(uint64_t availableBytes) noexcept;

}  // namespace caw
