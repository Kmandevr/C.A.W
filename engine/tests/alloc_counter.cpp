// Replaces the global allocation functions in the test binary so tests can prove a call never allocates.
#include "alloc_counter.h"

#include <cstdlib>
#include <new>

#if defined(__linux__) && !defined(__ANDROID__) && (defined(__GLIBCXX__) || defined(_LIBCPP_VERSION))
#include <dlfcn.h>

#include <atomic>
#define CAW_COUNT_LAZY_INITS 1
#endif

namespace {
thread_local bool gCounting = false;
thread_local std::size_t gAllocations = 0;
thread_local std::size_t gDeallocations = 0;
thread_local unsigned long long gTotal = 0;  // every call, counting or not

void release(void* p) noexcept {
    if (p) ++gTotal;
    if (p && gCounting) ++gDeallocations;
    std::free(p);
}

void* allocate(std::size_t size) {
    ++gTotal;
    if (gCounting) ++gAllocations;
    if (size == 0) size = 1;
    for (;;) {
        if (void* p = std::malloc(size)) return p;
        std::new_handler handler = std::get_new_handler();
        if (!handler) throw std::bad_alloc();
        handler();
    }
}

void* allocateAligned(std::size_t size, std::size_t alignment) {
    ++gTotal;
    if (gCounting) ++gAllocations;
    if (size == 0) size = 1;
    // Round up so aligned_alloc's size-multiple rule holds on every libc.
    size = (size + alignment - 1) / alignment * alignment;
#if defined(_MSC_VER)
    void* p = _aligned_malloc(size, alignment);
#else
    void* p = std::aligned_alloc(alignment, size);
#endif
    if (!p) throw std::bad_alloc();
    return p;
}

void releaseAligned(void* p) noexcept {
    if (p) ++gTotal;
    if (p && gCounting) ++gDeallocations;
#if defined(_MSC_VER)
    _aligned_free(p);
#else
    std::free(p);
#endif
}
}  // namespace

namespace cawtest {
AllocationScope::AllocationScope() noexcept { gAllocations = 0; gDeallocations = 0; gCounting = true; }
AllocationScope::~AllocationScope() { gCounting = false; }
std::size_t AllocationScope::count() const noexcept { return gAllocations + gDeallocations; }
std::size_t AllocationScope::allocations() const noexcept { return gAllocations; }
std::size_t AllocationScope::deallocations() const noexcept { return gDeallocations; }
unsigned long long threadAllocationsAndFrees() noexcept { return gTotal; }
}  // namespace cawtest

#if defined(CAW_COUNT_LAZY_INITS)
namespace {
thread_local long long gLazyInits = 0;
}
namespace cawtest {
long long threadLazyInits() noexcept { return gLazyInits; }
}  // namespace cawtest
// The C++ runtime's guard for function-local statics (Itanium C++ ABI 3.3.2), counted and passed on: the binary's
// own definition is found before the shared runtime's, which RTLD_NEXT then reaches.
extern "C" int __cxa_guard_acquire(long long* guard) {
    using Acquire = int (*)(long long*);
    // Not a guarded static (that would call this again): a constant-initialised atomic, looked up on first use.
    static std::atomic<Acquire> next{nullptr};
    Acquire f = next.load(std::memory_order_acquire);
    if (!f) {
        f = reinterpret_cast<Acquire>(dlsym(RTLD_NEXT, "__cxa_guard_acquire"));
        next.store(f, std::memory_order_release);
    }
    ++gLazyInits;
    return f(guard);
}
#else
namespace cawtest {
long long threadLazyInits() noexcept { return -1; }
}  // namespace cawtest
#endif

void* operator new(std::size_t size) { return allocate(size); }
void* operator new[](std::size_t size) { return allocate(size); }
void* operator new(std::size_t size, const std::nothrow_t&) noexcept {
    try { return allocate(size); } catch (...) { return nullptr; }
}
void* operator new[](std::size_t size, const std::nothrow_t&) noexcept {
    try { return allocate(size); } catch (...) { return nullptr; }
}
void operator delete(void* p) noexcept { release(p); }
void operator delete[](void* p) noexcept { release(p); }
void operator delete(void* p, std::size_t) noexcept { release(p); }
void operator delete[](void* p, std::size_t) noexcept { release(p); }
void operator delete(void* p, const std::nothrow_t&) noexcept { release(p); }
void operator delete[](void* p, const std::nothrow_t&) noexcept { release(p); }

void* operator new(std::size_t size, std::align_val_t a) {
    return allocateAligned(size, static_cast<std::size_t>(a));
}
void* operator new[](std::size_t size, std::align_val_t a) {
    return allocateAligned(size, static_cast<std::size_t>(a));
}
void operator delete(void* p, std::align_val_t) noexcept { releaseAligned(p); }
void operator delete[](void* p, std::align_val_t) noexcept { releaseAligned(p); }
void operator delete(void* p, std::size_t, std::align_val_t) noexcept { releaseAligned(p); }
void operator delete[](void* p, std::size_t, std::align_val_t) noexcept { releaseAligned(p); }
void* operator new(std::size_t size, std::align_val_t a, const std::nothrow_t&) noexcept {
    try { return allocateAligned(size, static_cast<std::size_t>(a)); } catch (...) { return nullptr; }
}
void* operator new[](std::size_t size, std::align_val_t a, const std::nothrow_t&) noexcept {
    try { return allocateAligned(size, static_cast<std::size_t>(a)); } catch (...) { return nullptr; }
}
void operator delete(void* p, std::align_val_t, const std::nothrow_t&) noexcept { releaseAligned(p); }
void operator delete[](void* p, std::align_val_t, const std::nothrow_t&) noexcept { releaseAligned(p); }
