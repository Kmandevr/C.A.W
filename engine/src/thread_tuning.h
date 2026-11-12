// Audio-thread scheduling and core-aware pool sizing (speed phase 5d): the portable face of engine/platform/thread_tuning_*.
#pragma once

#include <cstddef>
#include <cstdint>

// Everything here is best effort: a call the system refuses, or one it does not have (an older Android, Windows or
// kernel), changes nothing and reports nothing applied; the engine runs as before. The platform parts load what
// they use at run time (dlopen, GetProcAddress), so one build runs on every supported system version.
namespace caw::tuning {

// How fast a core is next to the machine's fastest: Big (the fast tier of a hybrid machine: Arm big and prime cores,
// Intel P-cores), Little (Arm little cores, Intel E-cores), Other (every core is the same kind), Unknown.
enum class CoreKind : uint8_t { Unknown = 0, Big = 1, Little = 2, Other = 3 };
const char* coreKindName(CoreKind kind) noexcept;

struct Topology {
    uint32_t cores = 0;     // logical processors the process can use (0: unknown)
    uint32_t fast = 0;      // of them, Big (hybrid) or every one (not hybrid)
    bool hybrid = false;    // more than one kind of core was read
    uint64_t fastMask = 0;  // the fast cores' numbers (the first 64), for worker affinity
    // How the kinds were read: "cpu_capacity", "cpuinfo_max_freq", "EfficiencyClass" or "none".
    const char* source = "none";
};
// Read once (sysfs, GetSystemCpuSetInformation) on first use, then cached; any thread, not the audio callback.
const Topology& topology() noexcept;
CoreKind coreKind(int cpu) noexcept;  // from topology(); Unknown for a core it does not know

// Portable (thread_tuning.cpp), for the platform parts and tests: sorts cores into kinds from one number per core
// (cpu_capacity, a top clock or an EfficiencyClass: larger is faster). Cores within 15% of the slowest are Little
// and the rest Big when they differ by more than that; otherwise every core is Other. kinds[i] gets cpus[i]'s.
Topology classifyCores(const int* cpus, const int64_t* values, size_t count, const char* source,
                       CoreKind* kinds) noexcept;

// The mix pool's workers for this machine (callback included in the count of busy cores): the fast cores less one
// (the callback's), at most cores - 2 on a machine of 4 or fewer cores (one core left for the system and the app),
// at most `cap`, and 0 where the count is unknown or 1.
uint32_t poolWorkers(const Topology& t, uint32_t cap) noexcept;

// Callback-safe (no allocation, lock or blocking call): the core the calling thread runs on now, -1 if unknown.
int currentCpu() noexcept;

// A core's clock now and its top clock, in kHz (-1 where unreadable: no cpufreq, or the system denies it).
// Reads files (sysfs) or asks the power API: never on the audio thread.
struct CoreClock {
    int64_t currentKHz = -1;
    int64_t maxKHz = -1;
};
CoreClock coreClock(int cpu) noexcept;

// What a tuning call managed, as bits.
enum : uint32_t {
    kAppliedPriority = 1u << 0,   // a higher time-sharing priority (nice, THREAD_PRIORITY_*)
    kAppliedRealtime = 1u << 1,   // a real-time policy (SCHED_FIFO)
    kAppliedAffinity = 1u << 2,   // kept to the fast cores (sched_setaffinity, CPU sets)
    kAppliedMmcss = 1u << 3,      // MMCSS "Pro Audio" (AvSetMmThreadCharacteristicsW)
    kAppliedNoThrottle = 1u << 4, // opted out of power throttling (Windows ThreadPowerThrottling)
};

// The audio callback's thread as the callback itself sees it: read once per thread (cheap, non-blocking calls:
// its id, policy and priority) and again only when the system moves the stream to another thread. Workers are
// never given a priority above it (a spinning worker above the callback could starve it on a shared core).
struct CallbackThread {
    bool known = false;
    int32_t tid = 0;        // the kernel's thread id (Linux, Android), else 0
    int policy = 0;         // SCHED_* (POSIX), else 0
    int priority = 0;       // its real-time priority (POSIX), or its THREAD_PRIORITY_* (Windows)
    int nice = 0;           // its nice value (Linux, Android)
    bool mmcss = false;     // in MMCSS "Pro Audio" (Windows; the platform layer says so: miniaudio's handle)
    uint32_t applied = 0;   // what describeCallbackThread did to it (kAppliedNoThrottle on Windows)
};
// On the callback thread, once per thread. Also opts it out of power throttling on Windows.
CallbackThread describeCallbackThread() noexcept;

// A worker's own tuning, on the worker, outside any task: priority relative to the callback's (never above it),
// affinity to the fast cores on a hybrid machine, MMCSS and no power throttling on Windows. untuneWorker undoes
// what needs undoing (MMCSS) before the worker ends.
struct WorkerState {
    void* mmcss = nullptr;
    uint32_t applied = 0;
};
uint32_t tuneWorker(const CallbackThread& callback, WorkerState& state) noexcept;
void untuneWorker(WorkerState& state) noexcept;
int32_t currentThreadId() noexcept;  // the kernel's id of the calling thread (Linux, Android), else 0

// A performance hint session (Android 13+: ADPF APerformanceHint) for the callback and the workers, with the
// callback period as its target. The system calls (create, set threads, report) run on the hint's own thread,
// never on the callback or a worker: the callback only stores numbers (hintReport). Null where there is none.
struct Hint;
Hint* hintOpen() noexcept;                    // control thread: starts the hint's thread (the session comes later)
void hintClose(Hint* hint) noexcept;          // control thread: closes the session and joins its thread
void hintThreads(Hint* hint, const int32_t* tids, size_t count) noexcept;  // any thread, no allocation
void hintReport(Hint* hint, int64_t actualNs, int64_t targetNs) noexcept;  // callback-safe: atomics only
bool hintActive(const Hint* hint) noexcept;   // a session is open on the threads last given

}  // namespace caw::tuning
