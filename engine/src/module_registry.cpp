#include "module_registry.h"

namespace caw {

bool ModuleRegistry::add(const ModuleDescriptor& descriptor, ModuleFactory factory) {
    if (!factory || validateModuleDescriptor(descriptor) != ModuleValidation::Ok || find(descriptor.id))
        return false;
    registrations_.push_back({&descriptor, factory});
    return true;
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
        if (actual.id != registration.descriptor->id ||
            actual.apiVersion != registration.descriptor->apiVersion ||
            validateModuleDescriptor(actual) != ModuleValidation::Ok) {
            delete processor;
            return {};
        }
        return std::unique_ptr<ModuleProcessor>(processor);
    }
    return {};
}

}  // namespace caw
