// Lightweight platform capability probe. It does not allocate, start threads or initialize GPU APIs.
#include "hardware.h"

#include <algorithm>
#include <cstdint>
#include <limits>

#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#elif defined(__APPLE__)
#include <sys/types.h>
#include <sys/sysctl.h>
#include <unistd.h>
#elif defined(__linux__) || defined(__ANDROID__)
    const long cores = sysconf(_SC_NPROCESSORS_ONLN);
    if (cores > 0) profile.logicalCores = clampCores(static_cast<uint64_t>(cores));
    uint64_t availableBytes = 0;
#if defined(_SC_AVPHYS_PAGES)
    const long availablePages = sysconf(_SC_AVPHYS_PAGES);
    const long pageSize = sysconf(_SC_PAGESIZE);
    if (availablePages > 0 && pageSize > 0)
        availableBytes = static_cast<uint64_t>(availablePages) * static_cast<uint64_t>(pageSize);
#endif
#if defined(__linux__) && !defined(__ANDROID__)
    if (availableBytes == 0) {
        struct sysinfo info{};
        if (sysinfo(&info) == 0)
            availableBytes = static_cast<uint64_t>(info.freeram + info.bufferram) * info.mem_unit;
    }
#endif
    if (availableBytes > 0) profile.memoryBudgetMiB = conservativeBudgetMiB(availableBytes);
#endif
    return profile;
}

}  // namespace caw
