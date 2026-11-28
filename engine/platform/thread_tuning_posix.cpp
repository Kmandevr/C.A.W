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
#include <android/api-level.h>
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
    // The fast cores only, on a hybrid desktop (a mask of cores, never one core: the kernel can still move a
    // worker the callback preempts). The callback itself is never pinned. Not on Android since 1.1.2: [Fact,
    // source.android.com "Performance Hint API", read 2026-11-24] "Your app shouldn't try to set the CPU core
    // affinity ... devices often ignore an app's processor affinity"; placement is the scheduler's (and the hint
    // session's), the nice above is the documented lever.
#if !defined(__ANDROID__)
    const Topology& t = topology();
    if (!(state.applied & kAppliedAffinity) && t.hybrid && t.fastMask != 0 && t.fast < t.cores) {
        cpu_set_t set;
        CPU_ZERO(&set);
        for (int cpu = 0; cpu < 64; ++cpu)
            if (t.fastMask & (uint64_t{1} << cpu)) CPU_SET(cpu, &set);
        if (sched_setaffinity(0, sizeof set, &set) == 0) state.applied |= kAppliedAffinity;
    }
#endif
    return state.applied;
}

void untuneWorker(WorkerState& state) noexcept { state.applied = 0; }

// ---- the utilization clamp ----

namespace {

// The kernel's struct sched_attr up to its utilization clamps (SCHED_ATTR_SIZE_VER1, 56 bytes; include/uapi/linux/
// sched/types.h): glibc and older NDKs have no declaration of it, so it is spelled out here.
struct SchedAttr {
    uint32_t size;
    uint32_t policy;
    uint64_t flags;
    int32_t nice;
    uint32_t priority;
    uint64_t runtime, deadline, period;
    uint32_t utilMin, utilMax;
};
static_assert(sizeof(SchedAttr) == 56, "SCHED_ATTR_SIZE_VER1");
// include/uapi/linux/sched.h
constexpr uint64_t kFlagResetOnFork = 0x01, kFlagKeepPolicy = 0x08, kFlagKeepParams = 0x10, kFlagUtilClampMin = 0x20;

}  // namespace

namespace {

#if defined(SYS_sched_getattr) && defined(SYS_sched_setattr)
bool clampUnsupported(int e) noexcept { return e == ENOSYS || e == EOPNOTSUPP || e == E2BIG; }

// The thread's attributes, or the reason there are none (c filled in).
bool readAttr(int32_t tid, SchedAttr& a, UtilClamp& c) noexcept {
    a = SchedAttr{};
    if (::syscall(SYS_sched_getattr, static_cast<pid_t>(tid), &a, sizeof a, 0) != 0) {
        c.error = errno;
        c.state = clampUnsupported(c.error) ? ClampState::Unsupported : ClampState::Refused;
        return false;
    }
    if (a.size < sizeof a) {  // a kernel from before the clamps (it fills only the fields it has)
        c.state = ClampState::Unsupported;
        return false;
    }
    return true;
}

// Only the floor: the policy, its priority and nice as they are (KEEP_*), reset-on-fork as it was.
bool writeUtilMin(int32_t tid, const SchedAttr& a, uint32_t utilMin, UtilClamp& c) noexcept {
    SchedAttr want = a;
    want.size = sizeof want;
    want.flags = kFlagKeepPolicy | kFlagKeepParams | kFlagUtilClampMin | (a.flags & kFlagResetOnFork);
    want.utilMin = utilMin;
    if (::syscall(SYS_sched_setattr, static_cast<pid_t>(tid), &want, 0) != 0) {
        c.error = errno;
        c.state = clampUnsupported(c.error) ? ClampState::Unsupported : ClampState::Refused;
        return false;
    }
    return true;
}

void readBack(int32_t tid, UtilClamp& c) noexcept {
    SchedAttr now{};
    if (::syscall(SYS_sched_getattr, static_cast<pid_t>(tid), &now, sizeof now, 0) == 0 && now.size >= sizeof now)
        c.utilMin = static_cast<int32_t>(now.utilMin);
}
#endif

}  // namespace

UtilClamp raiseUtilMin(int32_t tid, uint32_t utilMin) noexcept {
    UtilClamp c;
#if defined(SYS_sched_getattr) && defined(SYS_sched_setattr)
    SchedAttr a;
    if (!readAttr(tid, a, c)) return c;
    if (a.utilMin >= utilMin) {
        c.state = ClampState::Kept;
        c.utilMin = static_cast<int32_t>(a.utilMin);
        return c;
    }
    if (!writeUtilMin(tid, a, utilMin, c)) return c;
    c.state = ClampState::Applied;
    readBack(tid, c);
#else
    (void)tid, (void)utilMin;
    c.state = ClampState::Unsupported;
#endif
    return c;
}

UtilClamp resetUtilMin(int32_t tid) noexcept {
    UtilClamp c;
#if defined(SYS_sched_getattr) && defined(SYS_sched_setattr)
    SchedAttr a;
    if (!readAttr(tid, a, c)) return c;
    // -1: the system default again (docs.kernel.org "Utilization Clamping"; [Assumption] from Linux 5.11); a kernel
    // that refuses it (EINVAL) gets the real-time default instead.
    if (!writeUtilMin(tid, a, 0xFFFFFFFFu, c)) {
        if (c.error != EINVAL) return c;
        c = UtilClamp{};
        if (!writeUtilMin(tid, a, 1024, c)) return c;
    }
    c.state = ClampState::Reset;
    readBack(tid, c);
#else
    (void)tid;
    c.state = ClampState::Unsupported;
#endif
    return c;
}

UtilClamp probeUtilMin(int32_t tid, bool realtime, bool clamped) noexcept {
#if defined(__ANDROID__)
    if (!realtime) return raiseUtilMin(tid, kUtilMinRequest);
    if (clamped) return resetUtilMin(tid);
    return {};
#else
    (void)tid, (void)realtime, (void)clamped;
    return {};  // desktop Linux: not asked (the phone's problem; a desktop's callback is not on a slow little core)
#endif
}

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
    bool (*isFeatureSupported)(int32_t) = nullptr;  // API 36
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
        a.isFeatureSupported = reinterpret_cast<bool (*)(int32_t)>(dlsym(lib, "APerformanceHint_isFeatureSupported"));
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
    // Each callback's duration, in order (the callback writes, the hint's thread reports every one: the system
    // compares each cycle with its target, so the longest of several would overstate the work, and a mean hide a
    // late one). Only the newest kRing are kept when the hint's thread falls behind.
    static constexpr uint32_t kRing = 64;
    std::atomic<int64_t> ring[kRing] = {};
    std::atomic<uint64_t> written{0};
    uint64_t reported = 0;                 // the hint's thread's own
    std::atomic<int64_t> target{0};
    std::atomic<bool> active{false};
    std::atomic<uint8_t> state{static_cast<uint8_t>(HintState::Waiting)};
    std::atomic<int> feature{-1};             // hintDiagnostics: what isFeatureSupported said (-1: not asked)
    std::atomic<int64_t> preferred{-1};       // ... and the raw preferred update rate
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
        int64_t rate = 20'000'000, preferred = -1;
        if (manager && api.preferredRate) {
            preferred = api.preferredRate(manager);
            if (preferred > 0) rate = std::clamp<int64_t>(preferred, 10'000'000, 100'000'000);
        }
        // APERF_HINT_SESSIONS is 0 in APerformanceHintFeature (NDK r30, android/performance_hint.h).
        const int feature = api.isFeatureSupported ? (api.isFeatureSupported(0) ? 1 : 0) : -1;
        this->feature.store(feature, std::memory_order_relaxed);
        this->preferred.store(preferred, std::memory_order_relaxed);
        if (!manager) state.store(static_cast<uint8_t>(HintState::Unsupported), std::memory_order_relaxed);
        // A refused session is asked for again after hintRetryNs (it used to wait for the callback's thread to
        // change, which on one stream it never does), unless the system says it has none.
        uint32_t failures = 0;
        auto retryAt = std::chrono::steady_clock::time_point{};
        const bool unsupported = hintUnsupported(feature, preferred);
        std::unique_lock<std::mutex> hold(lock);
        while (!stop) {
            wake.wait_for(hold, std::chrono::nanoseconds(rate));
            if (stop || !manager) continue;
            hold.unlock();
            const int64_t want = target.load(std::memory_order_relaxed);
            const uint32_t g = tidGen.load(std::memory_order_acquire);
            const bool retry = !session && failures > 0 && !unsupported && std::chrono::steady_clock::now() >= retryAt;
            if (want > 0 && (g & 1u) == 0 && (g != gen || retry)) {
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
                        // The callback alone (it is first) if the system refused the group: a worker it won't take
                        // must not cost the callback its hint.
                        if (!session && used > 1) session = api.createSession(manager, ids, 1, want);
                        sessionTarget = want;
                        if (session) {
                            failures = 0;
                        } else {
                            ++failures;
                            retryAt = std::chrono::steady_clock::now() + std::chrono::nanoseconds(hintRetryNs(failures));
                        }
                    }
                    active.store(session != nullptr, std::memory_order_relaxed);
                    const HintState st = session ? HintState::On
                                                 : (unsupported ? HintState::Unsupported : HintState::Failed);
                    state.store(static_cast<uint8_t>(st), std::memory_order_relaxed);
                }
            }
            if (session) {
                if (want > 0 && want != sessionTarget && api.updateTarget(session, want) == 0) sessionTarget = want;
                const uint64_t w = written.load(std::memory_order_acquire);
                if (w - reported > kRing) reported = w - kRing;
                for (; reported < w; ++reported) {
                    const int64_t a = ring[reported % kRing].load(std::memory_order_relaxed);
                    if (a > 0) api.reportActual(session, a);
                }
            } else {
                reported = written.load(std::memory_order_acquire);  // none kept for a session not yet open
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
    // One writer, the callback (Engine::reportLoad): a plain store and a release of the count.
    const uint64_t w = h->written.load(std::memory_order_relaxed);
    h->ring[w % Hint::kRing].store(actualNs, std::memory_order_relaxed);
    h->written.store(w + 1, std::memory_order_release);
}

bool hintActive(const Hint* h) noexcept { return h && h->active.load(std::memory_order_relaxed); }

HintState hintState(const Hint* h) noexcept {
    return h ? static_cast<HintState>(h->state.load(std::memory_order_relaxed)) : HintState::None;
}

HintDiagnostics hintDiagnostics(const Hint* h) noexcept {
    HintDiagnostics d;
    d.sdk = android_get_device_api_level();
    d.featureCall = hintApi().isFeatureSupported != nullptr;
    if (h) {
        d.feature = h->feature.load(std::memory_order_relaxed);
        d.preferredRateNs = h->preferred.load(std::memory_order_relaxed);
    }
    return d;
}

#else  // Linux: no performance hint API

struct Hint {};
Hint* hintOpen() noexcept { return nullptr; }
void hintClose(Hint*) noexcept {}
void hintThreads(Hint*, const int32_t*, size_t) noexcept {}
void hintReport(Hint*, int64_t, int64_t) noexcept {}
bool hintActive(const Hint*) noexcept { return false; }
HintState hintState(const Hint*) noexcept { return HintState::None; }
HintDiagnostics hintDiagnostics(const Hint*) noexcept { return {}; }

#endif

}  // namespace caw::tuning
