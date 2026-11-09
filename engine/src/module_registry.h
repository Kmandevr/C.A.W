// Control-thread registry for native module factories and explicitly trusted component libraries.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "module.h"

namespace caw {

using ModuleFactory = ModuleProcessor* (*)() noexcept;
using ModuleDestroy = void (*)(ModuleProcessor*) noexcept;

enum class NativeModuleTrust : uint8_t {
    Blocked = 0,
    Isolated = 1,
    Trusted = 2,
};

enum class ModuleLoadError : uint8_t {
    None,
    Blocked,
    IsolationUnavailable,
    InvalidArgument,
    LoadFailed,
    MissingDescriptor,
    MissingFactory,
    MissingDestroy,
    InvalidDescriptor,
    ComponentIdMismatch,
    DuplicateId,
    IncompatibleHeader,  // built against another component header revision (or before revisions)
};

struct ModuleLoadResult {
    bool success = false;
    ModuleLoadError error = ModuleLoadError::None;
    std::string componentId;
    std::string message;
};

struct NativeLibrary;

struct ModuleRegistration {
    const ModuleDescriptor* descriptor = nullptr;
    ModuleFactory factory = nullptr;
    ModuleDestroy destroy = nullptr;
    std::shared_ptr<NativeLibrary> library;
};

class ModuleRegistry {
public:
    // Static registrations use host-side delete. Dynamic components must export their own destroy function.
    bool add(const ModuleDescriptor& descriptor, ModuleFactory factory, ModuleDestroy destroy = nullptr);

    // Trust is mandatory. Blocked never opens the library; Isolated is rejected until a real process sandbox exists.
    ModuleLoadResult loadSharedLibrary(const std::string& path, std::string_view expectedId, NativeModuleTrust trust);
    // A dynamic library cannot unload while a created processor still holds it.
    bool unload(std::string_view id);

    const ModuleDescriptor* find(std::string_view id) const noexcept;
    std::unique_ptr<ModuleProcessor> create(std::string_view id) const noexcept;
    std::size_t size() const noexcept { return registrations_.size(); }

private:
    std::vector<ModuleRegistration> registrations_;
};

}  // namespace caw
