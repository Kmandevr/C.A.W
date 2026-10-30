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
#include <unistd.h>
#if defined(__linux__) && !defined(__ANDROID__)
#include <sys/sysinfo.h>
#endif
#endif

namespace caw {
namespace {

uint16_t clampCores(uint64_t value) noexcept {
    return static_cast<uint16_t>(std::clamp<uint64_t>(value ? value : 1, 1, 256));
}

uint32_t conservativeBudgetMiB(uint64_t availableBytes) noexcept {
    const uint64_t mib = availableBytes / (1024ull * 1024ull);
    // Reserve most memory for the OS, app, project assets and audio buffers.
    return static_cast<uint32_t>(std::clamp<uint64_t>(mib / 4, 64, 8192));
}

bool cpuHasSimd() noexcept {
#if defined(__x86_64__) || defined(_M_X64)
#if defined(_MSC_VER)
    return true; // SSE2 is mandatory on x64.
#elif defined(__GNUC__) || defined(__clang__)
    __builtin_cpu_init();
    return __builtin_cpu_supports("sse2");
#else
    return true;
#endif
#elif defined(__aarch64__) || defined(_M_ARM64) || defined(__ARM_NEON)
    return true;
#else
    return false;
#endif
}

}  // namespace

HardwareProfile detectHardwareProfile() noexcept {
    HardwareProfile profile;
    profile.logicalCores = 1;
    profile.memoryBudgetMiB = 256;
    profile.supportsSimd = cpuHasSimd();
    profile.supportsGpuCompute = false; // no generic GPU kernel backend is currently shipped

#if defined(_WIN32)
    SYSTEM_INFO info{};
    GetSystemInfo(&info);
    profile.logicalCores = clampCores(info.dwNumberOfProcessors);
    MEMORYSTATUSEX memory{};
    memory.dwLength = sizeof(memory);
    if (GlobalMemoryStatusEx(&memory))
        profile.memoryBudgetMiB = conservativeBudgetMiB(memory.ullAvailPhys);
#elif defined(__APPLE__)
    uint32_t cores = 1;
    size_t coresSize = sizeof(cores);
    if (sysctlbyname("hw.logicalcpu", &cores, &coresSize, nullptr, 0) == 0)
        profile.logicalCores = clampCores(cores);
    uint64_t memoryBytes = 0;
    size_t memorySize = sizeof(memoryBytes);
    if (sysctlbyname("hw.memsize", &memoryBytes, &memorySize, nullptr, 0) == 0)
        profile.memoryBudgetMiB = conservativeBudgetMiB(memoryBytes / 2);
#elif defined(__linux__) || defined(__ANDROID__)
    const long cores = sysconf(_SC_NPROCESSORS_ONLN);
    if (cores > 0) profile.logicalCores = clampCores(static_cast<uint64_t>(cores));
#if defined(_SC_AVPHYS_PAGES)
    const long availablePages = sysconf(_SC_AVPHYS_PAGES);
    const long pageSize = sysconf(_SC_PAGESIZE);
    if (availablePages > 0 && pageSize > 0) {
        const uint64_t bytes = static_cast<uint64_t>(availablePages) * static_cast<uint64_t>(pageSize);
        profile.memoryBudgetMiB = conservativeBudgetMiB(bytes);
    } else
#endif
#if defined(__linux__) && !defined(__ANDROID__)
    {
        struct sysinfo info{};
        if (sysinfo(&info) == 0) {
            const uint64_t bytes = static_cast<uint64_t>(info.freeram + info.bufferram) * info.mem_unit;
            profile.memoryBudgetMiB = conservativeBudgetMiB(bytes);
        }
    }
#endif
#endif
    return profile;
}

}  // namespace caw
