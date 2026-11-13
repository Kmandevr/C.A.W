// Speed phase 5d on Linux and Android: core kinds from sysfs, worker priority and affinity, ADPF hints (Android 13+).
#include "thread_tuning.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <thread>

#if defined(__ANDROID__)
#include <dlfcn.h>
#endif

namespace caw::tuning {

namespace {

constexpr int kMaxCpus = 256;

// A small sysfs number (kHz, a capacity), or -1. Plain open/read: no allocation.
int64_t readNumber(const char* path) noexcept {
    const int fd = ::open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    char buf[32];
    const ssize_t n = ::read(fd, buf, sizeof buf - 1);
    ::close(fd);
    if (n <= 0) return -1;
    buf[n] = '\0';
    char* end = nullptr;
    const long long v = std::strtoll(buf, &end, 10);
    return end == buf || v < 0 ? -1 : static_cast<int64_t>(v);
}

int64_t readCpuNumber(int cpu, const char* leaf) noexcept {
    char path[96];
    std::snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%d/%s", cpu, leaf);
    return readNumber(path);
}

struct Cores {
    Topology topology;
    CoreKind kinds[kMaxCpus] = {};
};

Cores readCores() noexcept {
    Cores c;
    int cpus[kMaxCpus];
    int64_t capacity[kMaxCpus], maxFreq[kMaxCpus];
    size_t n = 0;
    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof set, &set) == 0) {
        for (int cpu = 0; cpu < kMaxCpus && cpu < CPU_SETSIZE; ++cpu)
            if (CPU_ISSET(cpu, &set)) cpus[n++] = cpu;
    } else {
        const long online = sysconf(_SC_NPROCESSORS_ONLN);
        for (int cpu = 0; cpu < kMaxCpus && cpu < online; ++cpu) cpus[n++] = cpu;
    }
    bool haveCapacity = n > 0, haveFreq = n > 0;
    for (size_t i = 0; i < n; ++i) {
        capacity[i] = readCpuNumber(cpus[i], "cpu_capacity");
        maxFreq[i] = readCpuNumber(cpus[i], "cpufreq/cpuinfo_max_freq");
        haveCapacity = haveCapacity && capacity[i] > 0;
        haveFreq = haveFreq && maxFreq[i] > 0;
    }
    CoreKind kinds[kMaxCpus];
    if (haveCapacity) c.topology = classifyCores(cpus, capacity, n, "cpu_capacity", kinds);
    else if (haveFreq) c.topology = classifyCores(cpus, maxFreq, n, "cpuinfo_max_freq", kinds);
    else c.topology = classifyCores(cpus, capacity, n, "none", kinds);  // every value -1: every core Other
    for (size_t i = 0; i < n; ++i) c.kinds[cpus[i]] = kinds[i];
    return c;
}

const Cores& cores() noexcept {
    static const Cores c = readCores();
    return c;
}

int32_t tidNow() noexcept { return static_cast<int32_t>(::syscall(SYS_gettid)); }

// Android's THREAD_PRIORITY_URGENT_AUDIO (android.os.Process; the nice value of its audio threads).
constexpr int kUrgentAudioNice = -19;

}  // namespace

const Topology& topology() noexcept { return cores().topology; }

CoreKind coreKind(int cpu) noexcept {
    if (cpu < 0 || cpu >= kMaxCpus) return CoreKind::Unknown;
    return cores().kinds[cpu];
}

int currentCpu() noexcept { return sched_getcpu(); }

CoreClock coreClock(int cpu) noexcept {
    CoreClock c;
    if (cpu < 0 || cpu >= kMaxCpus) return c;
    c.currentKHz = readCpuNumber(cpu, "cpufreq/scaling_cur_freq");
    c.maxKHz = readCpuNumber(cpu, "cpufreq/cpuinfo_max_freq");
    if (c.maxKHz < 0) c.maxKHz = readCpuNumber(cpu, "cpufreq/scaling_max_freq");
    return c;
}

int32_t currentThreadId() noexcept { return tidNow(); }

CallbackThread describeCallbackThread() noexcept {
    CallbackThread t;
    t.known = true;
    t.tid = tidNow();
    t.policy = sched_getscheduler(0) & ~SCHED_RESET_ON_FORK;
    sched_param p{};
    if (sched_getparam(0, &p) == 0) t.priority = p.sched_priority;
    errno = 0;
    const int nice = getpriority(PRIO_PROCESS, 0);  // Linux: the calling thread's
    t.nice = errno == 0 ? nice : 0;
    return t;
}

uint32_t tuneWorker(const CallbackThread& cb, WorkerState& state) noexcept {
    if (!cb.known) return state.applied;
    const bool callbackRealtime = cb.policy == SCHED_FIFO || cb.policy == SCHED_RR;
    const id_t self = static_cast<id_t>(tidNow());
    // Real time only below a real-time callback (one step lower, so the callback always preempts a worker on its
    // core and the kernel pushes the worker to another). Android apps can't: their callback's SCHED_FIFO comes
    // from the audio server, and an app's own request is refused.
    bool realtime = false;
#if !defined(__ANDROID__)
    if (callbackRealtime && cb.priority > 1) {
        sched_param p{};
        p.sched_priority = cb.priority - 1;
        realtime = sched_setscheduler(0, SCHED_FIFO | SCHED_RESET_ON_FORK, &p) == 0;
    }
#endif
    if (!realtime && (state.applied & kAppliedRealtime)) {  // the callback is no longer real-time: back down
        sched_param p{};
        sched_setscheduler(0, SCHED_OTHER, &p);
    }
    state.applied &= ~(kAppliedRealtime | kAppliedPriority);
    if (realtime) {
        state.applied |= kAppliedRealtime;
    } else {
        // Time-sharing: any nice is below a real-time callback (urgent audio, as Android's own audio threads),
        // else no better than the callback's nice. Raising a nice is always allowed; lowering may be refused.
        const int target = callbackRealtime ? kUrgentAudioNice : cb.nice;
        errno = 0;
        int now = getpriority(PRIO_PROCESS, self);
        if (errno != 0) now = 0;
        if (now < target) {
            setpriority(PRIO_PROCESS, self, target);
        } else if (now > target) {
            for (int n : {target, -16, -10, -8, -4, -2}) {
                if (n < target || n >= now) continue;
                if (setpriority(PRIO_PROCESS, self, n) == 0) {
                    state.applied |= kAppliedPriority;
                    break;
                }
            }
        }
    }
    // The fast cores only, on a hybrid machine (a mask of cores, never one core: the kernel can still move a
    // worker the callback preempts). The callback itself is never pinned.
    const Topology& t = topology();
    if (!(state.applied & kAppliedAffinity) && t.hybrid && t.fastMask != 0 && t.fast < t.cores) {
        cpu_set_t set;
        CPU_ZERO(&set);
        for (int cpu = 0; cpu < 64; ++cpu)
            if (t.fastMask & (uint64_t{1} << cpu)) CPU_SET(cpu, &set);
        if (sched_setaffinity(0, sizeof set, &set) == 0) state.applied |= kAppliedAffinity;
    }
    return state.applied;
}

void untuneWorker(WorkerState& state) noexcept { state.applied = 0; }

// ---- the performance hint ----

#if defined(__ANDROID__)

namespace {

// The NDK's APerformanceHint (android/performance_hint.h), looked up in libandroid.so: getManager, createSession,
// updateTargetWorkDuration, reportActualWorkDuration, closeSession from API 33, setThreads from API 34.
struct HintApi {
    void* (*getManager)() = nullptr;
    void* (*createSession)(void*, const int32_t*, size_t, int64_t) = nullptr;
    int64_t (*preferredRate)(void*) = nullptr;
    int (*updateTarget)(void*, int64_t) = nullptr;
    int (*reportActual)(void*, int64_t) = nullptr;
    void (*closeSession)(void*) = nullptr;
    int (*setThreads)(void*, const pid_t*, size_t) = nullptr;
    bool ok = false;
};

const HintApi& hintApi() noexcept {
    static const HintApi api = [] {
        HintApi a;
        void* lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
        if (!lib) return a;
        a.getManager = reinterpret_cast<void* (*)()>(dlsym(lib, "APerformanceHint_getManager"));
        a.createSession = reinterpret_cast<void* (*)(void*, const int32_t*, size_t, int64_t)>(
            dlsym(lib, "APerformanceHint_createSession"));
        a.preferredRate = reinterpret_cast<int64_t (*)(void*)>(dlsym(lib, "APerformanceHint_getPreferredUpdateRateNanos"));
        a.updateTarget = reinterpret_cast<int (*)(void*, int64_t)>(dlsym(lib, "APerformanceHint_updateTargetWorkDuration"));
        a.reportActual = reinterpret_cast<int (*)(void*, int64_t)>(dlsym(lib, "APerformanceHint_reportActualWorkDuration"));
        a.closeSession = reinterpret_cast<void (*)(void*)>(dlsym(lib, "APerformanceHint_closeSession"));
        a.setThreads = reinterpret_cast<int (*)(void*, const pid_t*, size_t)>(dlsym(lib, "APerformanceHint_setThreads"));
        a.ok = a.getManager && a.createSession && a.updateTarget && a.reportActual && a.closeSession;
        return a;  // libandroid.so stays loaded (it is the app's anyway)
    }();
    return api;
}

}  // namespace

struct Hint {
    static constexpr size_t kMaxThreads = 8;
    std::atomic<int32_t> tids[kMaxThreads] = {};
    std::atomic<uint32_t> tidCount{0};
    std::atomic<uint32_t> tidGen{0};       // bumped after each hintThreads (odd while one writes)
    std::atomic<int64_t> actualMax{0};     // the longest callback since the hint's thread last reported
    std::atomic<int64_t> target{0};
    std::atomic<bool> active{false};
    std::mutex lock;                       // the hint's thread's sleep (never taken on the audio thread)
    std::condition_variable wake;
    bool stop = false;
    std::thread thread;

    void loop() noexcept {
        const HintApi& api = hintApi();
        void* manager = api.ok ? api.getManager() : nullptr;
        void* session = nullptr;
        uint32_t gen = 0;
        int64_t sessionTarget = 0;
        // The system's preferred rate between reports, kept between 10 and 100 ms; 20 ms before it is known.
        int64_t rate = 20'000'000;
        if (manager && api.preferredRate) {
            const int64_t r = api.preferredRate(manager);
            if (r > 0) rate = std::clamp<int64_t>(r, 10'000'000, 100'000'000);
        }
        std::unique_lock<std::mutex> hold(lock);
        while (!stop) {
            wake.wait_for(hold, std::chrono::nanoseconds(rate));
            if (stop || !manager) continue;
            hold.unlock();
            const int64_t want = target.load(std::memory_order_relaxed);
            const uint32_t g = tidGen.load(std::memory_order_acquire);
            if (want > 0 && (g & 1u) == 0 && g != gen) {
                int32_t ids[kMaxThreads];
                const uint32_t n = std::min<uint32_t>(tidCount.load(std::memory_order_relaxed), kMaxThreads);
                uint32_t used = 0;
                for (uint32_t i = 0; i < n; ++i) {
                    const int32_t t = tids[i].load(std::memory_order_relaxed);
                    if (t > 0) ids[used++] = t;
                }
                if (tidGen.load(std::memory_order_acquire) == g && used > 0) {
                    gen = g;
                    if (session && api.setThreads) {
                        if (api.setThreads(session, ids, used) != 0) {
                            api.closeSession(session);
                            session = nullptr;
                        }
                    } else if (session) {
                        api.closeSession(session);
                        session = nullptr;
                    }
                    if (!session) {
                        session = api.createSession(manager, ids, used, want);
                        sessionTarget = want;
                    }
                    active.store(session != nullptr, std::memory_order_relaxed);
                }
            }
            if (session) {
                if (want > 0 && want != sessionTarget && api.updateTarget(session, want) == 0) sessionTarget = want;
                const int64_t a = actualMax.exchange(0, std::memory_order_relaxed);
                if (a > 0) api.reportActual(session, a);
            }
            hold.lock();
        }
        hold.unlock();
        if (session) api.closeSession(session);
        active.store(false, std::memory_order_relaxed);
    }
};

Hint* hintOpen() noexcept {
    if (!hintApi().ok) return nullptr;
    Hint* h = nullptr;
    try {
        h = new Hint();
        h->thread = std::thread([h] { h->loop(); });
    } catch (...) {
        delete h;
        return nullptr;
    }
    return h;
}

void hintClose(Hint* h) noexcept {
    if (!h) return;
    {
        std::lock_guard<std::mutex> hold(h->lock);
        h->stop = true;
    }
    h->wake.notify_all();
    if (h->thread.joinable()) h->thread.join();
    delete h;
}

void hintThreads(Hint* h, const int32_t* tids, size_t count) noexcept {
    if (!h) return;
    const uint32_t n = static_cast<uint32_t>(std::min(count, Hint::kMaxThreads));
    uint32_t g = h->tidGen.load(std::memory_order_relaxed);
    // One writer at a time in practice (the pool's control and callback steps); odd while writing.
    if ((g & 1u) != 0 || !h->tidGen.compare_exchange_strong(g, g + 1, std::memory_order_acq_rel)) return;
    for (uint32_t i = 0; i < n; ++i) h->tids[i].store(tids[i], std::memory_order_relaxed);
    h->tidCount.store(n, std::memory_order_relaxed);
    h->tidGen.store(g + 2, std::memory_order_release);
}

void hintReport(Hint* h, int64_t actualNs, int64_t targetNs) noexcept {
    if (!h) return;
    h->target.store(targetNs, std::memory_order_relaxed);
    int64_t cur = h->actualMax.load(std::memory_order_relaxed);
    while (actualNs > cur && !h->actualMax.compare_exchange_weak(cur, actualNs, std::memory_order_relaxed)) {
    }
}

bool hintActive(const Hint* h) noexcept { return h && h->active.load(std::memory_order_relaxed); }

#else  // Linux: no performance hint API

struct Hint {};
Hint* hintOpen() noexcept { return nullptr; }
void hintClose(Hint*) noexcept {}
void hintThreads(Hint*, const int32_t*, size_t) noexcept {}
void hintReport(Hint*, int64_t, int64_t) noexcept {}
bool hintActive(const Hint*) noexcept { return false; }

#endif

}  // namespace caw::tuning
