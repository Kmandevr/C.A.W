// The plug-in benchmark's section table (CAW_PROFILE_SCOPE's host side): fixed slots, filled on the bench's thread only.
#include "component_profile.h"

#include <atomic>
#include <chrono>
#include <cstring>
#include <thread>

#include "caw/profile.hpp"

namespace caw::profile {

namespace {

struct Slot {
    const char* key = nullptr;  // the name pointer a scope passed (a literal: compared first)
    char name[48] = {};
    uint64_t ns = 0, calls = 0;
};

struct Table {
    alignas(4) int32_t active = 0;  // read by any thread through the extension (relaxed atomic loads)
    std::atomic<std::thread::id> thread{};
    Slot slots[CAW_PROFILE_MAX_SECTIONS];
    uint32_t used = 0;
};
Table gTable;

uint64_t nowNs() noexcept {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
}

// Audio thread (any): only the bench's thread records, so a project playing the same library elsewhere adds nothing.
uint32_t begin(void*, const char* name) noexcept {
    if (!name || std::this_thread::get_id() != gTable.thread.load(std::memory_order_relaxed)) return CAW_PROFILE_NO_SECTION;
    for (uint32_t k = 0; k < gTable.used; ++k)
        if (gTable.slots[k].key == name) return k;
    for (uint32_t k = 0; k < gTable.used; ++k)
        if (std::strncmp(gTable.slots[k].name, name, sizeof gTable.slots[k].name - 1) == 0) return k;
    if (gTable.used == CAW_PROFILE_MAX_SECTIONS) return CAW_PROFILE_NO_SECTION;
    Slot& s = gTable.slots[gTable.used];
    s.key = name;
    std::strncpy(s.name, name, sizeof s.name - 1);
    s.name[sizeof s.name - 1] = '\0';
    s.ns = s.calls = 0;
    return gTable.used++;
}

void end(void*, uint32_t section, uint64_t startNs) noexcept {
    if (section >= gTable.used || std::this_thread::get_id() != gTable.thread.load(std::memory_order_relaxed)) return;
    const uint64_t t = nowNs();
    gTable.slots[section].ns += t > startNs ? t - startNs : 0;
    ++gTable.slots[section].calls;
}

const CawProfileExtension kExtension{sizeof(CawProfileExtension), &gTable.active, nullptr, &begin, &end, &nowNs};

void setActive(int32_t v) noexcept { std::atomic_ref<int32_t>(gTable.active).store(v, std::memory_order_relaxed); }

// The engine's own components (built-ins) were made without a CawHost: point this library's copy at the table.
const bool gAttached = [] {
    profile_detail::host.store(&kExtension, std::memory_order_release);
    profile_detail::active.store(&gTable.active, std::memory_order_release);
    return true;
}();

}  // namespace

const void* hostExtension(const CawHost*, const char* id) noexcept {
    return id && std::strcmp(id, CAW_HOST_EXTENSION_PROFILE) == 0 ? &kExtension : nullptr;
}

void start() noexcept {
    (void)gAttached;
    gTable.used = 0;
    gTable.thread.store(std::this_thread::get_id(), std::memory_order_relaxed);
    setActive(1);
}

void stop() noexcept {
    setActive(0);
    gTable.thread.store(std::thread::id{}, std::memory_order_relaxed);
}

std::vector<Section> sections() {
    std::vector<Section> out;
    for (uint32_t k = 0; k < gTable.used; ++k) out.push_back({gTable.slots[k].name, gTable.slots[k].ns, gTable.slots[k].calls});
    return out;
}

}  // namespace caw::profile
