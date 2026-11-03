// Test-only allocation counter: counts global operator new and delete calls on this thread inside a scope.
#pragma once

#include <cstddef>

namespace cawtest {

// While a scope is alive, every global operator new and delete on the constructing thread is
// counted (freeing on the audio thread is forbidden too). Scopes do not nest. Only the separate
// caw_rt_tests binary links this, because replacing the global allocation functions turns off
// AddressSanitizer's new/delete mismatch checks; caw_tests keeps them.
class AllocationScope {
public:
    AllocationScope() noexcept;
    ~AllocationScope();
    AllocationScope(const AllocationScope&) = delete;
    AllocationScope& operator=(const AllocationScope&) = delete;
    std::size_t count() const noexcept;        // allocations + deallocations
    std::size_t allocations() const noexcept;
    std::size_t deallocations() const noexcept;
};

}  // namespace cawtest
