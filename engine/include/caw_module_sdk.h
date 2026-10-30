// C.A.W native module SDK v1. C ABI only: no STL, exceptions, or C++ ABI crosses the boundary.
#ifndef CAW_MODULE_SDK_H
#define CAW_MODULE_SDK_H

#include <stdint.h>

#if defined(_WIN32)
#define CAW_MODULE_EXPORT __declspec(dllexport)
#else
#define CAW_MODULE_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define CAW_MODULE_ABI_VERSION 1u

typedef enum CawModulePortType {
    CAW_PORT_AUDIO = 0,
    CAW_PORT_CONTROL = 1,
    CAW_PORT_MODULATION = 2,
    CAW_PORT_EVENT = 3
} CawModulePortType;

typedef enum CawModuleChannelLayout {
    CAW_LAYOUT_NONE = 0,
    CAW_LAYOUT_MONO = 1,
    CAW_LAYOUT_STEREO = 2,
    CAW_LAYOUT_DISCRETE = 3
} CawModuleChannelLayout;

typedef struct CawModulePortInfo {
    const char* id;
    uint32_t type;
    uint32_t channel_layout;
    uint32_t is_input;
} CawModulePortInfo;

typedef struct CawModuleParameterInfo {
    const char* id;
    double default_value;
    double minimum;
    double maximum;
    uint32_t flags; /* bit 0: automatable */
} CawModuleParameterInfo;

typedef struct CawModuleDescriptorV1 {
    uint32_t struct_size;
    uint32_t abi_version;
    const char* stable_id;
    const char* display_name;
    const CawModulePortInfo* ports;
    uint32_t port_count;
    const CawModuleParameterInfo* parameters;
    uint32_t parameter_count;
    uint32_t maximum_state_bytes;
    uint32_t flags; /* reserved; must be zero in v1 */
} CawModuleDescriptorV1;

/* Borrowed buffers are valid only for this call. Never retain pointers. Frames are bounded by host. */
typedef struct CawModuleProcessBlockV1 {
    const float* input_left;
    const float* input_right;
    float* output_left;
    float* output_right;
    uint32_t frames;
    double sample_rate;
    const double* parameter_values;
    uint32_t parameter_count;
} CawModuleProcessBlockV1;

typedef void* (*CawModuleCreateFn)(double sample_rate);
typedef void (*CawModuleDestroyFn)(void* instance);
typedef int32_t (*CawModuleProcessFn)(void* instance, const CawModuleProcessBlockV1* block);
typedef uint32_t (*CawModuleStateSizeFn)(void* instance);
typedef int32_t (*CawModuleSaveStateFn)(void* instance, uint8_t* destination, uint32_t capacity);
typedef int32_t (*CawModuleLoadStateFn)(void* instance, const uint8_t* source, uint32_t size);

typedef struct CawNativeModuleV1 {
    uint32_t struct_size;
    uint32_t abi_version;
    const CawModuleDescriptorV1* descriptor;
    CawModuleCreateFn create;
    CawModuleDestroyFn destroy;
    CawModuleProcessFn process;
    CawModuleStateSizeFn state_size;
    CawModuleSaveStateFn save_state;
    CawModuleLoadStateFn load_state;
} CawNativeModuleV1;

/* A native module exports this exact symbol returning a static descriptor/table. */
typedef const CawNativeModuleV1* (*CawGetNativeModuleV1Fn)(void);
#define CAW_MODULE_ENTRY_SYMBOL "caw_get_native_module_v1"

#ifdef __cplusplus
}
#endif
#endif
