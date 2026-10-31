// Control-thread registry for native module factories. Descriptors must have static lifetime.
#pragma once

#include <cstddef>
#include <memory>
#include <string_view>
#include <vector>

#include "module.h"

namespace caw {

using ModuleFactory = ModuleProcessor* (*)() noexcept;

struct ModuleRegistration {
    const ModuleDescriptor* descriptor = nullptr;
    ModuleFactory factory = nullptr;
};

class ModuleRegistry {
public:
    // Returns false for invalid descriptors, missing factories, or duplicate stable IDs.
    bool add(const ModuleDescriptor& descriptor, ModuleFactory factory);
    const ModuleDescriptor* find(std::string_view id) const noexcept;
    std::unique_ptr<ModuleProcessor> create(std::string_view id) const noexcept;
    std::size_t size() const noexcept { return registrations_.size(); }

private:
    std::vector<ModuleRegistration> registrations_;
};

}  // namespace caw
