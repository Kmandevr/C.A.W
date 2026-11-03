// Replaces the global allocation functions in the test binary so tests can prove a call never allocates.
#include "alloc_counter.h"

#include <cstdlib>
#include <new>

namespace {
thread_local bool counting = false;
thread_local std::size_t allocations = 0;

void* allocate(std::size_t size) {
    if (counting) ++allocations;
    if (size == 0) size = 1;
    for (;;) {
        if (void* p = std::malloc(size)) return p;
        std::new_handler handler = std::get_new_handler();
        if (!handler) throw std::bad_alloc();
        handler();
    }
}

void* allocateAligned(std::size_t size, std::size_t alignment) {
    if (counting) ++allocations;
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
#if defined(_MSC_VER)
    _aligned_free(p);
#else
    std::free(p);
#endif
}
}  // namespace

namespace cawtest {
AllocationScope::AllocationScope() noexcept { allocations = 0; counting = true; }
AllocationScope::~AllocationScope() { counting = false; }
std::size_t AllocationScope::count() const noexcept { return allocations; }
}  // namespace cawtest

void* operator new(std::size_t size) { return allocate(size); }
void* operator new[](std::size_t size) { return allocate(size); }
void* operator new(std::size_t size, const std::nothrow_t&) noexcept {
    try { return allocate(size); } catch (...) { return nullptr; }
}
void* operator new[](std::size_t size, const std::nothrow_t&) noexcept {
    try { return allocate(size); } catch (...) { return nullptr; }
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }
void operator delete(void* p, const std::nothrow_t&) noexcept { std::free(p); }
void operator delete[](void* p, const std::nothrow_t&) noexcept { std::free(p); }

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
