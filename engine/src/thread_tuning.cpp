// Speed phase 5d, portable part: sorting cores into kinds and the mix pool's worker count (thread_tuning.h).
#include "thread_tuning.h"

#include <algorithm>

namespace caw::tuning {

const char* coreKindName(CoreKind kind) noexcept {
    switch (kind) {
        case CoreKind::Big: return "big";
        case CoreKind::Little: return "little";
        case CoreKind::Other: return "other";
        case CoreKind::Unknown: break;
    }
    return "unknown";
}

Topology classifyCores(const int* cpus, const int64_t* values, size_t count, const char* source,
                       CoreKind* kinds) noexcept {
    Topology t;
    t.cores = static_cast<uint32_t>(count);
    t.source = source;
    int64_t lo = 0, hi = 0;
    bool any = false;
    for (size_t i = 0; i < count; ++i) {
        if (values[i] <= 0) continue;
        lo = any ? std::min(lo, values[i]) : values[i];
        hi = any ? std::max(hi, values[i]) : values[i];
        any = true;
    }
    // Hybrid when the fastest is more than 15% faster than the slowest; each core within 15% of the slowest is Little.
    t.hybrid = any && hi * 100 > lo * 115;
    for (size_t i = 0; i < count; ++i) {
        CoreKind k = CoreKind::Other;
        if (!any || values[i] <= 0) k = t.hybrid ? CoreKind::Unknown : CoreKind::Other;
        else if (t.hybrid) k = values[i] * 100 > lo * 115 ? CoreKind::Big : CoreKind::Little;
        if (kinds) kinds[i] = k;
        const bool fast = t.hybrid ? k == CoreKind::Big : true;
        if (fast) {
            ++t.fast;
            if (cpus[i] >= 0 && cpus[i] < 64) t.fastMask |= uint64_t{1} << cpus[i];
        }
    }
    if (!any) t.source = "none";
    return t;
}

uint32_t poolWorkers(const Topology& t, uint32_t cap) noexcept {
    if (t.cores <= 1) return 0;
    uint32_t fast = t.fast == 0 ? t.cores : t.fast;
    uint32_t w = fast - 1;                     // the callback takes one fast core
    if (t.cores <= 4) w = std::min(w, t.cores - 2);  // leave one core to the system and the app's other threads
    return std::min(w, cap);
}

}  // namespace caw::tuning
