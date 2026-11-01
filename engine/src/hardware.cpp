// Lightweight platform capability probe. It does not allocate, start threads or initialize GPU APIs.
#include "hardware.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

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
#include <sched.h>
#endif
#endif

namespace caw {

uint32_t conservativeMemoryBudgetMiB(uint64_t availableBytes) noexcept {
    if (availableBytes == 0) return 0; // Unknown remains distinct from a measured low budget.
    const uint64_t mib = availableBytes / (1024ull * 1024ull);
    // Reserve most available memory for the OS, app, project assets and audio buffers.
    // Do not impose a 16 MiB floor: that overstated capacity on constrained devices.
    return static_cast<uint32_t>(std::clamp<uint64_t>(mib / 4, 1, 8192));
}

namespace {

uint16_t clampCores(uint64_t value) noexcept {
    return static_cast<uint16_t>(std::clamp<uint64_t>(value ? value : 1, 1, 256));
}

#if defined(__linux__) || defined(__ANDROID__)
uint64_t readUnsignedFile(const char* path) noexcept {
    FILE* file = std::fopen(path, "r");
    if (!file) return 0;
    char text[96]{};
    const bool read = std::fgets(text, sizeof(text), file) != nullptr;
    std::fclose(file);
    if (!read || text[0] == '-') return 0;
    char* end = nullptr;
    const unsigned long long value = std::strtoull(text, &end, 10);
    return end == text ? 0 : static_cast<uint64_t>(value);
}

uint16_t cgroupCpuLimit() noexcept {
    FILE* file = std::fopen("/sys/fs/cgroup/cpu.max", "r");
    if (file) {
        char quotaText[32]{}, periodText[32]{};
        const bool read = std::fscanf(file, "%31s %31s", quotaText, periodText) == 2;
        std::fclose(file);
        if (read && std::strcmp(quotaText, "max") != 0) {
            const uint64_t quota = std::strtoull(quotaText, nullptr, 10);
            const uint64_t period = std::strtoull(periodText, nullptr, 10);
            if (quota > 0 && period > 0)
                return clampCores(std::max<uint64_t>(1, quota / period));
        }
    }
    const uint64_t quota = readUnsignedFile("/sys/fs/cgroup/cpu/cpu.cfs_quota_us");
    const uint64_t period = readUnsignedFile("/sys/fs/cgroup/cpu/cpu.cfs_period_us");
    if (quota > 0 && quota < (1ull << 60) && period > 0)
        return clampCores(std::max<uint64_t>(1, quota / period));
    return 0;
}

// Returns false only when no finite cgroup memory limit is available. A true
// result with zero bytes means the finite limit is exhausted, not "unknown".
bool cgroupAvailableMemory(uint64_t& availableBytes) noexcept {
    uint64_t limit = 0, used = 0;
    FILE* file = std::fopen("/sys/fs/cgroup/memory.max", "r");
    if (file) {
        char text[96]{};
        const bool read = std::fgets(text, sizeof(text), file) != nullptr;
        std::fclose(file);
        if (read && std::strncmp(text, "max", 3) != 0) {
            limit = std::strtoull(text, nullptr, 10);
            used = readUnsignedFile("/sys/fs/cgroup/memory.current");
        }
    }
    if (limit == 0) {
        limit = readUnsignedFile("/sys/fs/cgroup/memory/memory.limit_in_bytes");
        used = readUnsignedFile("/sys/fs/cgroup/memory/memory.usage_in_bytes");
        if (limit >= (1ull << 60)) limit = 0; // v1 uses a very large sentinel for unlimited.
    }
    if (limit == 0) return false;
    availableBytes = limit > used ? limit - used : 0;
    return true;
}
#endif

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
    profile.logicalCores = 0;
    profile.memoryBudgetMiB = 0;
    profile.supportsSimd = cpuHasSimd();
    profile.supportsGpuCompute = false; // no generic GPU kernel backend is currently shipped

#if defined(_WIN32)
    SYSTEM_INFO info{};
    GetSystemInfo(&info);
    profile.logicalCores = clampCores(info.dwNumberOfProcessors);
    DWORD_PTR processMask = 0, systemMask = 0;
    if (GetProcessAffinityMask(GetCurrentProcess(), &processMask, &systemMask)) {
        uint32_t allowed = 0;
        for (DWORD_PTR mask = processMask; mask; mask &= (mask - 1)) ++allowed;
        if (allowed) profile.logicalCores = std::min<uint16_t>(profile.logicalCores, clampCores(allowed));
    }
    MEMORYSTATUSEX memory{};
    memory.dwLength = sizeof(memory);
    if (GlobalMemoryStatusEx(&memory))
        profile.memoryBudgetMiB = conservativeMemoryBudgetMiB(memory.ullAvailPhys);
#elif defined(__APPLE__)
    uint32_t cores = 0;
    size_t coresSize = sizeof(cores);
    if (sysctlbyname("hw.activecpu", &cores, &coresSize, nullptr, 0) != 0) {
        coresSize = sizeof(cores);
        sysctlbyname("hw.logicalcpu", &cores, &coresSize, nullptr, 0);
    }
    if (cores > 0) profile.logicalCores = clampCores(cores);
    uint64_t memoryBytes = 0;
    size_t memorySize = sizeof(memoryBytes);
    if (sysctlbyname("hw.memsize", &memoryBytes, &memorySize, nullptr, 0) == 0)
        profile.memoryBudgetMiB = conservativeMemoryBudgetMiB(memoryBytes / 2);
#elif defined(__linux__) || defined(__ANDROID__)
    const long cores = sysconf(_SC_NPROCESSORS_ONLN);
    if (cores > 0) profile.logicalCores = clampCores(static_cast<uint64_t>(cores));
#if defined(__linux__) && !defined(__ANDROID__)
    cpu_set_t allowed;
    CPU_ZERO(&allowed);
    if (sched_getaffinity(0, sizeof(allowed), &allowed) == 0) {
        const int count = CPU_COUNT(&allowed);
        if (count > 0) profile.logicalCores = profile.logicalCores
            ? std::min<uint16_t>(profile.logicalCores, clampCores(static_cast<uint64_t>(count)))
            : clampCores(static_cast<uint64_t>(count));
    }
#endif
    const uint16_t quotaCores = cgroupCpuLimit();
    if (quotaCores > 0) profile.logicalCores = profile.logicalCores
        ? std::min(profile.logicalCores, quotaCores) : quotaCores;
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
    uint64_t cgroupBytes = 0;
    if (cgroupAvailableMemory(cgroupBytes)) {
        availableBytes = availableBytes > 0 ? std::min(availableBytes, cgroupBytes) : cgroupBytes;
        if (availableBytes == 0) profile.memoryBudgetMiB = 1; // Known exhausted limit: choose the smallest budget.
    }
    if (availableBytes > 0) profile.memoryBudgetMiB = conservativeMemoryBudgetMiB(availableBytes);
#endif
    return profile;
}

}  // namespace caw
