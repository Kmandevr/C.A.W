// Speed phase 5d on Windows: P/E cores from CPU sets, MMCSS "Pro Audio", no power throttling, workers off E-cores.
#include "thread_tuning.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <vector>

namespace caw::tuning {

namespace {

constexpr int kMaxCpus = 256;

// Looked up at run time, so older Windows runs without them: GetSystemCpuSetInformation and
// SetThreadSelectedCpuSets (Windows 10), SetThreadInformation (Windows 8; ThreadPowerThrottling in newer SDKs),
// AvSetMmThreadCharacteristicsW and AvRevertMmThreadCharacteristics (avrt.dll), CallNtPowerInformation (powrprof).
using GetCpuSetsFn = BOOL(WINAPI*)(void*, ULONG, PULONG, HANDLE, ULONG);
using SetThreadCpuSetsFn = BOOL(WINAPI*)(HANDLE, const ULONG*, ULONG);
using SetThreadInfoFn = BOOL(WINAPI*)(HANDLE, int, LPVOID, DWORD);
using AvSetFn = HANDLE(WINAPI*)(LPCWSTR, LPDWORD);
using AvRevertFn = BOOL(WINAPI*)(HANDLE);
using PowerInfoFn = LONG(WINAPI*)(int, PVOID, ULONG, PVOID, ULONG);

template <typename F>
F kernel32(const char* name) noexcept {
    HMODULE k = GetModuleHandleW(L"kernel32.dll");
    return k ? reinterpret_cast<F>(reinterpret_cast<void*>(GetProcAddress(k, name))) : nullptr;
}

struct Avrt {
    AvSetFn set = nullptr;
    AvRevertFn revert = nullptr;
};
const Avrt& avrt() noexcept {
    static const Avrt a = [] {
        Avrt r;
        HMODULE lib = LoadLibraryW(L"avrt.dll");
        if (!lib) return r;
        r.set = reinterpret_cast<AvSetFn>(reinterpret_cast<void*>(GetProcAddress(lib, "AvSetMmThreadCharacteristicsW")));
        r.revert = reinterpret_cast<AvRevertFn>(reinterpret_cast<void*>(GetProcAddress(lib, "AvRevertMmThreadCharacteristics")));
        if (!r.set || !r.revert) r = Avrt{};
        return r;
    }();
    return a;
}

// The fields of SYSTEM_CPU_SET_INFORMATION's CpuSet (winnt.h) this file reads, at their documented offsets.
struct CpuSetRecord {
    DWORD Size;
    DWORD Type;  // CPU_SET_INFORMATION_TYPE: 0 is CpuSetInformation
    DWORD Id;
    WORD Group;
    BYTE LogicalProcessorIndex;
    BYTE CoreIndex;
    BYTE LastLevelCacheIndex;
    BYTE NumaNodeIndex;
    BYTE EfficiencyClass;
    BYTE AllFlags;
};

struct Cores {
    Topology topology;
    CoreKind kinds[kMaxCpus] = {};
    ULONG fastSets[kMaxCpus] = {};  // the CPU set ids of the fast cores, for SetThreadSelectedCpuSets
    ULONG fastSetCount = 0;
};

Cores readCores() noexcept {
    Cores c;
    int cpus[kMaxCpus];
    int64_t eff[kMaxCpus];
    ULONG ids[kMaxCpus];
    size_t n = 0;
    if (auto get = kernel32<GetCpuSetsFn>("GetSystemCpuSetInformation")) {
        ULONG bytes = 0;
        get(nullptr, 0, &bytes, GetCurrentProcess(), 0);
        if (bytes > 0) {
            std::vector<unsigned char> buf(bytes);
            if (get(buf.data(), bytes, &bytes, GetCurrentProcess(), 0)) {
                for (ULONG at = 0; at + sizeof(DWORD) * 2 <= bytes && n < kMaxCpus;) {
                    const auto* r = reinterpret_cast<const CpuSetRecord*>(buf.data() + at);
                    if (r->Size == 0) break;
                    if (r->Type == 0 && r->Group == 0 && at + sizeof(CpuSetRecord) <= bytes) {
                        cpus[n] = r->LogicalProcessorIndex;
                        eff[n] = static_cast<int64_t>(r->EfficiencyClass) + 1;  // > 0: classifyCores' "known"
                        ids[n] = r->Id;
                        ++n;
                    }
                    at += r->Size;
                }
            }
        }
    }
    CoreKind kinds[kMaxCpus];
    if (n > 0) {
        c.topology = classifyCores(cpus, eff, n, "EfficiencyClass", kinds);
        for (size_t i = 0; i < n; ++i) {
            if (cpus[i] < kMaxCpus) c.kinds[cpus[i]] = kinds[i];
            if (c.topology.hybrid && kinds[i] == CoreKind::Big) c.fastSets[c.fastSetCount++] = ids[i];
        }
    } else {
        const DWORD count = std::min<DWORD>(GetActiveProcessorCount(0), kMaxCpus);
        for (DWORD i = 0; i < count; ++i) cpus[i] = static_cast<int>(i), eff[i] = -1;
        c.topology = classifyCores(cpus, eff, count, "none", kinds);
        for (DWORD i = 0; i < count; ++i) c.kinds[i] = kinds[i];
    }
    return c;
}

const Cores& cores() noexcept {
    static const Cores c = readCores();
    return c;
}

constexpr int kThreadPowerThrottling = 3;  // THREAD_INFORMATION_CLASS ThreadPowerThrottling (processthreadsapi.h)
struct PowerThrottlingState {               // THREAD_POWER_THROTTLING_STATE
    ULONG Version;                          // THREAD_POWER_THROTTLING_CURRENT_VERSION (1)
    ULONG ControlMask;
    ULONG StateMask;
};

// HighQoS: execution-speed throttling controlled and off (the documented SetThreadInformation example).
bool noPowerThrottling() noexcept {
    auto set = kernel32<SetThreadInfoFn>("SetThreadInformation");
    if (!set) return false;
    PowerThrottlingState s{1, 0x1 /* THREAD_POWER_THROTTLING_EXECUTION_SPEED */, 0};
    return set(GetCurrentThread(), kThreadPowerThrottling, &s, sizeof s) != 0;
}

}  // namespace

const Topology& topology() noexcept { return cores().topology; }

CoreKind coreKind(int cpu) noexcept {
    if (cpu < 0 || cpu >= kMaxCpus) return CoreKind::Unknown;
    return cores().kinds[cpu];
}

int currentCpu() noexcept { return static_cast<int>(GetCurrentProcessorNumber()); }

CoreClock coreClock(int cpu) noexcept {
    CoreClock c;
    static const PowerInfoFn info = [] {
        HMODULE lib = LoadLibraryW(L"powrprof.dll");
        return lib ? reinterpret_cast<PowerInfoFn>(reinterpret_cast<void*>(GetProcAddress(lib, "CallNtPowerInformation")))
                   : nullptr;
    }();
    if (!info || cpu < 0) return c;
    struct ProcessorPowerInformation {  // PROCESSOR_POWER_INFORMATION (powerbase.h)
        ULONG Number, MaxMhz, CurrentMhz, MhzLimit, MaxIdleState, CurrentIdleState;
    };
    const DWORD count = GetActiveProcessorCount(0);
    if (static_cast<DWORD>(cpu) >= count) return c;
    std::vector<ProcessorPowerInformation> all(count);
    // ProcessorInformation (11): one record per processor of the current group.
    if (info(11, nullptr, 0, all.data(), static_cast<ULONG>(all.size() * sizeof(ProcessorPowerInformation))) != 0)
        return c;
    c.currentKHz = static_cast<int64_t>(all[static_cast<size_t>(cpu)].CurrentMhz) * 1000;
    c.maxKHz = static_cast<int64_t>(all[static_cast<size_t>(cpu)].MaxMhz) * 1000;
    return c;
}

int32_t currentThreadId() noexcept { return static_cast<int32_t>(GetCurrentThreadId()); }

CallbackThread describeCallbackThread() noexcept {
    CallbackThread t;
    t.known = true;
    t.tid = static_cast<int32_t>(GetCurrentThreadId());
    t.priority = GetThreadPriority(GetCurrentThread());
    if (noPowerThrottling()) t.applied |= kAppliedNoThrottle;
    return t;
}

uint32_t tuneWorker(const CallbackThread& cb, WorkerState& state) noexcept {
    if (!cb.known) return state.applied;
    const Avrt& av = avrt();
    if (cb.mmcss && !state.mmcss && av.set) {
        DWORD index = 0;
        if (HANDLE h = av.set(L"Pro Audio", &index)) {
            state.mmcss = h;
            state.applied |= kAppliedMmcss;
        }
    } else if (!cb.mmcss && state.mmcss) {  // the callback left MMCSS: so do the workers
        av.revert(static_cast<HANDLE>(state.mmcss));
        state.mmcss = nullptr;
        state.applied &= ~kAppliedMmcss;
    }
    if (!state.mmcss) {
        // No higher than the callback's (miniaudio's own audio thread is THREAD_PRIORITY_HIGHEST), at most HIGHEST.
        const int want = std::min(cb.priority == THREAD_PRIORITY_ERROR_RETURN ? THREAD_PRIORITY_NORMAL : cb.priority,
                                  THREAD_PRIORITY_HIGHEST);
        state.applied &= ~kAppliedPriority;
        if (want > THREAD_PRIORITY_NORMAL && SetThreadPriority(GetCurrentThread(), want)) state.applied |= kAppliedPriority;
    }
    if (!(state.applied & kAppliedNoThrottle) && noPowerThrottling()) state.applied |= kAppliedNoThrottle;
    const Cores& c = cores();
    if (!(state.applied & kAppliedAffinity) && c.fastSetCount > 0 && c.fastSetCount < c.topology.cores) {
        if (auto set = kernel32<SetThreadCpuSetsFn>("SetThreadSelectedCpuSets"))
            if (set(GetCurrentThread(), c.fastSets, c.fastSetCount)) state.applied |= kAppliedAffinity;
    }
    return state.applied;
}

void untuneWorker(WorkerState& state) noexcept {
    if (state.mmcss && avrt().revert) avrt().revert(static_cast<HANDLE>(state.mmcss));
    state.mmcss = nullptr;
    state.applied = 0;
}

// Windows has no performance hint API of this kind.
struct Hint {};
Hint* hintOpen() noexcept { return nullptr; }
void hintClose(Hint*) noexcept {}
void hintThreads(Hint*, const int32_t*, size_t) noexcept {}
void hintReport(Hint*, int64_t, int64_t) noexcept {}
bool hintActive(const Hint*) noexcept { return false; }

}  // namespace caw::tuning
