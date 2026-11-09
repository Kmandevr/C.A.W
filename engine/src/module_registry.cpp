#include "module_registry.h"

#include <filesystem>
#include <new>
#include <utility>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace caw {

namespace {

void destroyWithDelete(ModuleProcessor* processor) noexcept {
    delete processor;
}

using DescriptorFn = const ModuleDescriptor* (*)() noexcept;
using CreateFn = ModuleProcessor* (*)() noexcept;

class LoadedProcessor final : public ModuleProcessor {
public:
    LoadedProcessor(std::shared_ptr<NativeLibrary> library, ModuleProcessor* processor, ModuleDestroy destroy) noexcept
        : library_(std::move(library)), processor_(processor), destroy_(destroy) {}
    ~LoadedProcessor() override {
        if (processor_ && destroy_) destroy_(processor_);
    }

    const ModuleDescriptor& descriptor() const noexcept override { return processor_->descriptor(); }
    bool usesProcessPorts() const noexcept override { return processor_->usesProcessPorts(); }
    bool processPorts(const ProcessBlock& block) noexcept override { return processor_->processPorts(block); }
    void process(const StereoProcessBlock& block) noexcept override { processor_->process(block); }
    bool process(const AudioProcessBlock& block) noexcept override { return processor_->process(block); }
    void reset() noexcept override { processor_->reset(); }
    uint32_t stateVersion() const noexcept override { return processor_->stateVersion(); }
    bool saveState(uint8_t* destination, uint32_t capacity, uint32_t& written) const noexcept override {
        return processor_->saveState(destination, capacity, written);
    }
    bool loadState(const uint8_t* source, uint32_t size, uint32_t version) noexcept override {
        return processor_->loadState(source, size, version);
    }

private:
    // Keep the library alive until after the plugin-owned processor has been destroyed.
    std::shared_ptr<NativeLibrary> library_;
    ModuleProcessor* processor_ = nullptr;
    ModuleDestroy destroy_ = nullptr;
};

}  // namespace

struct NativeLibrary {
#ifdef _WIN32
    HMODULE handle = nullptr;
#else
    void* handle = nullptr;
#endif

    ~NativeLibrary() {
#ifdef _WIN32
        if (handle) FreeLibrary(handle);
#else
        if (handle) dlclose(handle);
#endif
    }

    bool open(const std::string& path, std::string& error) {
#ifdef _WIN32
        const std::filesystem::path nativePath = std::filesystem::u8path(path);
        handle = LoadLibraryW(nativePath.c_str());
        if (!handle) {
            error = "LoadLibrary failed with Windows error " + std::to_string(GetLastError());
            return false;
        }
#else
        dlerror();
        handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            const char* detail = dlerror();
            error = detail ? detail : "dlopen failed";
            return false;
        }
#endif
        return true;
    }

    template <class Function>
    Function resolve(const char* name) const noexcept {
#ifdef _WIN32
        return handle ? reinterpret_cast<Function>(GetProcAddress(handle, name)) : nullptr;
#else
        return handle ? reinterpret_cast<Function>(dlsym(handle, name)) : nullptr;
#endif
    }
};

bool ModuleRegistry::add(const ModuleDescriptor& descriptor, ModuleFactory factory, ModuleDestroy destroy) {
    if (!factory || validateModuleDescriptor(descriptor) != ModuleValidation::Ok || find(descriptor.id))
        return false;
    registrations_.push_back({&descriptor, factory, destroy ? destroy : &destroyWithDelete, {}});
    return true;
}

ModuleLoadResult ModuleRegistry::loadSharedLibrary(
    const std::string& path, std::string_view expectedId, NativeModuleTrust trust) {
    if (trust == NativeModuleTrust::Blocked)
        return {false, ModuleLoadError::Blocked, std::string(expectedId), "Native component is blocked by the user's trust setting."};
    if (trust == NativeModuleTrust::Isolated)
        return {false, ModuleLoadError::IsolationUnavailable, std::string(expectedId),
                "Isolated native execution is not available in this host; choose Trusted explicitly or keep the component Blocked."};
    if (trust != NativeModuleTrust::Trusted)
        return {false, ModuleLoadError::InvalidArgument, std::string(expectedId), "Unknown native component trust level."};
    if (path.empty() || expectedId.empty())
        return {false, ModuleLoadError::InvalidArgument, {}, "A component path and expected stable component ID are required."};

    auto library = std::make_shared<NativeLibrary>();
    std::string loadError;
    if (!library->open(path, loadError))
        return {false, ModuleLoadError::LoadFailed, std::string(expectedId), std::move(loadError)};

    const DescriptorFn descriptorFn = library->resolve<DescriptorFn>("caw_component_descriptor");
    if (!descriptorFn)
        return {false, ModuleLoadError::MissingDescriptor, std::string(expectedId),
                "The shared library does not export caw_component_descriptor."};
    const ModuleFactory factory = library->resolve<ModuleFactory>("caw_component_create");
    if (!factory)
        return {false, ModuleLoadError::MissingFactory, std::string(expectedId),
                "The shared library does not export caw_component_create."};
    const ModuleDestroy destroy = library->resolve<ModuleDestroy>("caw_component_destroy");
    if (!destroy)
        return {false, ModuleLoadError::MissingDestroy, std::string(expectedId),
                "The shared library does not export caw_component_destroy; the host will not delete plugin-owned memory across runtimes."};

    const ModuleDescriptor* descriptor = descriptorFn();
    if (!descriptor || validateModuleDescriptor(*descriptor) != ModuleValidation::Ok)
        return {false, ModuleLoadError::InvalidDescriptor, std::string(expectedId),
                "The component's exported descriptor is missing or invalid."};
    if (descriptor->id != expectedId)
        return {false, ModuleLoadError::ComponentIdMismatch, std::string(expectedId),
                "The built component ID does not match the project manifest ID."};
    if (find(descriptor->id))
        return {false, ModuleLoadError::DuplicateId, std::string(descriptor->id),
                "A component with this stable ID is already loaded."};

    registrations_.push_back({descriptor, factory, destroy, std::move(library)});
    return {true, ModuleLoadError::None, std::string(descriptor->id), {}};
}

bool ModuleRegistry::unload(std::string_view id) {
    for (auto it = registrations_.begin(); it != registrations_.end(); ++it) {
        if (!it->descriptor || it->descriptor->id != id || !it->library) continue;
        if (it->library.use_count() != 1) return false;
        registrations_.erase(it);
        return true;
    }
    return false;
}

const ModuleDescriptor* ModuleRegistry::find(std::string_view id) const noexcept {
    for (const ModuleRegistration& registration : registrations_)
        if (registration.descriptor && registration.descriptor->id == id)
            return registration.descriptor;
    return nullptr;
}

std::unique_ptr<ModuleProcessor> ModuleRegistry::create(std::string_view id) const noexcept {
    for (const ModuleRegistration& registration : registrations_) {
        if (!registration.descriptor || registration.descriptor->id != id || !registration.factory)
            continue;
        ModuleProcessor* processor = registration.factory();
        if (!processor) return {};
        const ModuleDescriptor& actual = processor->descriptor();
        if (!moduleDescriptorsMatch(actual, *registration.descriptor)) {
            if (registration.destroy) registration.destroy(processor);
            else destroyWithDelete(processor);
            return {};
        }
        processor->reset();
        if (registration.library) {
            auto* wrapped = new (std::nothrow) LoadedProcessor(registration.library, processor, registration.destroy);
            if (!wrapped) {
                if (registration.destroy) registration.destroy(processor);
                else destroyWithDelete(processor);
                return {};
            }
            return std::unique_ptr<ModuleProcessor>(wrapped);
        }
        return std::unique_ptr<ModuleProcessor>(processor);
    }
    return {};
}

}  // namespace caw
