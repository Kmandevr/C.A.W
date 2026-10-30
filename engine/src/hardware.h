// Platform capability snapshot for workload planning. Thermal/battery pressure remains host supplied.
#pragma once

#include "execution.h"

namespace caw {

// Best-effort snapshot: online logical cores, a conservative memory budget and SIMD support.
// GPU compute is false until a concrete, tested CAW compute backend is available.
HardwareProfile detectHardwareProfile() noexcept;

}  // namespace caw
