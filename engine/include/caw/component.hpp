// Export macros and entry points for independently built C.A.W. components.
#pragma once

#include "module.hpp"

#if defined(_WIN32)
#define CAW_COMPONENT_EXPORT __declspec(dllexport)
#else
#define CAW_COMPONENT_EXPORT __attribute__((visibility("default")))
#endif

// Each component shared library exports these three functions. The destroy function keeps allocation and deallocation inside the component's runtime. The host must validate the
// descriptor and apply its explicit native-code trust policy before calling the factory.
extern "C" {
CAW_COMPONENT_EXPORT const caw::ModuleDescriptor* caw_component_descriptor() noexcept;
CAW_COMPONENT_EXPORT caw::ModuleProcessor* caw_component_create() noexcept;
CAW_COMPONENT_EXPORT void caw_component_destroy(caw::ModuleProcessor* processor) noexcept;
}
