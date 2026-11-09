// Export macros and entry points for independently built C.A.W. components.
#pragma once

#include "module.hpp"

#if defined(_WIN32)
#define CAW_COMPONENT_EXPORT __declspec(dllexport)
#else
#define CAW_COMPONENT_EXPORT __attribute__((visibility("default")))
#endif


// Defines caw_component_header_revision(). Put it in exactly one source file of the component.
#define CAW_COMPONENT_DEFINE_HEADER_REVISION()                                                   \
    extern "C" CAW_COMPONENT_EXPORT uint32_t caw_component_header_revision() noexcept {        \
        return caw::kComponentHeaderRevision;                                                    \
    }

// Each component shared library exports these functions (the header revision through
// CAW_COMPONENT_DEFINE_HEADER_REVISION). The destroy function keeps allocation and deallocation inside the component's runtime. The host must validate the
// descriptor and apply its explicit native-code trust policy before calling the factory.
extern "C" {
CAW_COMPONENT_EXPORT uint32_t caw_component_header_revision() noexcept;
CAW_COMPONENT_EXPORT const caw::ModuleDescriptor* caw_component_descriptor() noexcept;
CAW_COMPONENT_EXPORT caw::ModuleProcessor* caw_component_create() noexcept;
CAW_COMPONENT_EXPORT void caw_component_destroy(caw::ModuleProcessor* processor) noexcept;
}
