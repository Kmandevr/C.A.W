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
    MissingEntryPoint,   // no caw_get_component_v2 export, or it returned nothing
    IncompatibleAbi,     // another C interface version, or structs smaller than v2's
    IncompleteTable,     // a required function pointer is missing
    InvalidDescriptor,
    ComponentIdMismatch,
    DuplicateId,
};

struct ModuleLoadResult {
    bool success = false;
    ModuleLoadError error = ModuleLoadError::None;
    std::string componentId;
    std::string message;
};

struct NativeLibrary;
struct LoadedComponent;  // a component's C table plus the engine-owned copy of its descriptor

struct ModuleRegistration {
    const ModuleDescriptor* descriptor = nullptr;
    ModuleFactory factory = nullptr;
    ModuleDestroy destroy = nullptr;
    std::shared_ptr<NativeLibrary> library;
    std::shared_ptr<const LoadedComponent> component;  // set for dynamically loaded components
};

class ModuleRegistry {
public:
    // Static registrations use host-side delete. Dynamic components must export their own destroy function.
    bool add(const ModuleDescriptor& descriptor, ModuleFactory factory, ModuleDestroy destroy = nullptr);

    // Trust is mandatory. Blocked never opens the library; Isolated is rejected until a real process sandbox exists.
    // The library must export caw_get_component_v2 (caw_component.h); its descriptor is copied into
    // engine-owned storage and validated before anything else of it runs.
    ModuleLoadResult loadSharedLibrary(const std::string& path, std::string_view expectedId, NativeModuleTrust trust);
    // A dynamic library cannot unload while a created processor still holds it.
    bool unload(std::string_view id);

    const ModuleDescriptor* find(std::string_view id) const noexcept;
    // Descriptors of the dynamically loaded components, in load order.
    std::vector<const ModuleDescriptor*> loadedComponents() const;
    // A new instance. A loaded component's instance is not yet activated: the host calls
    // activate(sampleRate, maxFrames) before processing and destroys it off the audio thread.
    std::unique_ptr<ModuleProcessor> create(std::string_view id) const noexcept;
    std::size_t size() const noexcept { return registrations_.size(); }

private:
    std::vector<ModuleRegistration> registrations_;
};

// One descriptor as JSON for hosts (the app): identity, role, timing, ports, parameters with their
// choices and capability flags, and UI controls. Field names are stable (snake_case).
std::string moduleDescriptorJson(const ModuleDescriptor& descriptor);

}  // namespace caw
