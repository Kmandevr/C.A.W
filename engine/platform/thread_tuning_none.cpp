// Speed phase 5d elsewhere (macOS, iOS, WebAssembly): no tuning yet; every core one kind, from the C++ library.
#include "thread_tuning.h"

#include <thread>

namespace caw::tuning {

namespace {

const Topology& readTopology() noexcept {
    static const Topology t = [] {
        Topology r;
        r.cores = std::thread::hardware_concurrency();
        r.fast = r.cores;
        for (uint32_t c = 0; c < r.cores && c < 64; ++c) r.fastMask |= uint64_t{1} << c;
        return r;
    }();
    return t;
}

}  // namespace

const Topology& topology() noexcept { return readTopology(); }
CoreKind coreKind(int cpu) noexcept {
    return cpu >= 0 && static_cast<uint32_t>(cpu) < readTopology().cores ? CoreKind::Other : CoreKind::Unknown;
}
int currentCpu() noexcept { return -1; }
CoreClock coreClock(int) noexcept { return {}; }
int32_t currentThreadId() noexcept { return 0; }
CallbackThread describeCallbackThread() noexcept {
    CallbackThread t;
    t.known = true;
    return t;
}
uint32_t tuneWorker(const CallbackThread&, WorkerState& state) noexcept { return state.applied; }
void untuneWorker(WorkerState& state) noexcept { state.applied = 0; }
struct Hint {};
Hint* hintOpen() noexcept { return nullptr; }
void hintClose(Hint*) noexcept {}
void hintThreads(Hint*, const int32_t*, size_t) noexcept {}
void hintReport(Hint*, int64_t, int64_t) noexcept {}
bool hintActive(const Hint*) noexcept { return false; }

}  // namespace caw::tuning
