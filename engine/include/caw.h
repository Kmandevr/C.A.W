// C API of the C.A.W engine, the only way the app (via dart:ffi) and other hosts talk to it. Version 1.
#ifndef CAW_H
#define CAW_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define CAW_API __declspec(dllexport)
#else
#define CAW_API __attribute__((visibility("default")))
#endif

#define CAW_API_VERSION 1

typedef struct CawEngine CawEngine;

typedef struct CawMeters {
    float cpu;
    float peak_l;
    float peak_r;
    int32_t playing;
    int32_t overloaded;
    int64_t position;
    int64_t loop_length;
} CawMeters;

typedef struct CawLayerMeter {
    float peak;
    float progress;
    int32_t active;
    int32_t overloaded;
} CawLayerMeter;

enum { CAW_EXPORT_LOOP = 0, CAW_EXPORT_FREE = 1, CAW_EXPORT_ONESHOT = 2, CAW_EXPORT_WAVETABLE = 3 };

typedef struct CawRenderOptions {
    int32_t kind;
    int32_t sample_rate;
    int32_t float32;
    int32_t frames;
    double seconds;
    const char* target;
    const char* param;
} CawRenderOptions;

/* Workload identifiers shared by the app, project tools and native add-ons. */
enum {
    CAW_WORK_INTERACTIVE_AUDITION = 0,
    CAW_WORK_INTERACTIVE_PREVIEW = 1,
    CAW_WORK_BACKGROUND_GENERATION = 2,
    CAW_WORK_OFFLINE_RENDER = 3,
    CAW_WORK_IDLE = 4
};
enum {
    CAW_PRESSURE_NORMAL = 0,
    CAW_PRESSURE_BATTERY_SAVER = 1,
    CAW_PRESSURE_THERMAL_WARM = 2,
    CAW_PRESSURE_THERMAL_HOT = 3,
    CAW_PRESSURE_THERMAL_CRITICAL = 4
};

typedef struct CawHardwareProfile {
    uint16_t logical_cores;
    uint32_t memory_budget_mib;
    int32_t supports_simd;
    int32_t supports_gpu_compute;
} CawHardwareProfile;

typedef struct CawExecutionRequest {
    int32_t workload;
    int32_t pressure;
    int32_t foreground_busy;
    int32_t allow_gpu;
} CawExecutionRequest;

typedef struct CawExecutionPlan {
    uint16_t worker_threads;
    uint16_t max_concurrent_jobs;
    uint32_t preferred_batch_frames;
    int32_t latency_sensitive;
    int32_t use_simd;
    int32_t allow_gpu;
    int32_t yield_to_foreground;
} CawExecutionPlan;

CAW_API int32_t caw_api_version(void);
CAW_API void caw_free(char* s);
CAW_API char* caw_check(const char* source);

CAW_API CawEngine* caw_engine_create(int32_t sample_rate);
CAW_API void caw_engine_destroy(CawEngine* e);
CAW_API char* caw_engine_set_project(CawEngine* e, const char* project_json);
CAW_API void caw_engine_set_param(CawEngine* e, const char* module_id, const char* name, double value);
CAW_API void caw_engine_set_global(CawEngine* e, const char* name, double value);
CAW_API void caw_engine_set_layer_mix(CawEngine* e, const char* layer_id, double volume, double pan, int32_t mute,
                                      int32_t solo);
CAW_API void caw_engine_play(CawEngine* e);
CAW_API void caw_engine_stop(CawEngine* e);
CAW_API void caw_engine_clear_overload(CawEngine* e);
CAW_API void caw_engine_meters(CawEngine* e, CawMeters* out);
CAW_API int32_t caw_engine_layer_meter(CawEngine* e, int32_t index, CawLayerMeter* out);
CAW_API int32_t caw_engine_scope(CawEngine* e, int32_t layer_index, float* out, int32_t n);
CAW_API void caw_engine_process(CawEngine* e, float* left, float* right, int32_t frames);
CAW_API int32_t caw_audio_start(CawEngine* e, char* error, int32_t error_len);
CAW_API void caw_audio_stop(CawEngine* e);
CAW_API int32_t caw_render(const char* project_json, const CawRenderOptions* options, const char* out_path,
                           int32_t* progress, int32_t* cancel, char* error, int32_t error_len);
CAW_API char* caw_library(void);
CAW_API char* caw_pattern_from_midi(const uint8_t* data, int32_t size);
enum { CAW_MIDI_SMF = 0, CAW_MIDI_CLIP = 1 };
CAW_API int32_t caw_pattern_export(const char* pattern_source, double bpm, int32_t beats_per_bar, int32_t format,
                                   const char* out_path, char* error, int32_t error_len);
CAW_API int32_t caw_template_count(void);
CAW_API const char* caw_template_file(int32_t index);
CAW_API const char* caw_template_source(int32_t index);

/* Pure workload policy shared by the app and add-ons. Hosts supply observed capabilities;
   this does not query OS APIs, start workers, or alter the real-time audio callback. */
CAW_API int32_t caw_execution_plan(const CawHardwareProfile* hardware, const CawExecutionRequest* request,
                                   CawExecutionPlan* out);

#ifdef __cplusplus
}
#endif
#endif /* CAW_H */
