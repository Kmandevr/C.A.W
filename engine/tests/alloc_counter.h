// Test-only allocation counter: counts global operator new calls on this thread inside a scope.
#pragma once

#include <cstddef>

namespace cawtest {

// While a scope is alive, every global operator new on the constructing thread is counted.
// Scopes do not nest; the test binary replaces the global allocation functions to do this.
class AllocationScope {
public:
    AllocationScope() noexcept;
    ~AllocationScope();
    AllocationScope(const AllocationScope&) = delete;
    AllocationScope& operator=(const AllocationScope&) = delete;
    std::size_t count() const noexcept;
};

}  // namespace cawtest
