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
    float cpu;        /* smoothed share of the audio callback's time budget, 0..1+ */
    float peak_l;     /* peak since the last call */
    float peak_r;
    int32_t playing;
    int32_t overloaded; /* layers the engine muted because the device ran out of time */
    int64_t position;   /* samples into the project loop */
    int64_t loop_length;
} CawMeters;

typedef struct CawLayerMeter {
    float peak;      /* since the last call */
    float progress;  /* 0..1 through this layer's own loop */
    int32_t active;
    int32_t overloaded;
} CawLayerMeter;

enum { CAW_EXPORT_LOOP = 0, CAW_EXPORT_FREE = 1, CAW_EXPORT_ONESHOT = 2, CAW_EXPORT_WAVETABLE = 3 };

typedef struct CawRenderOptions {
    int32_t kind;         /* CAW_EXPORT_* */
    int32_t sample_rate;  /* 44100 or 48000 */
    int32_t float32;      /* 1 = 32-bit float, 0 = 24-bit PCM (wavetables are always float) */
    int32_t frames;       /* wavetable frames, 1..256 */
    double seconds;       /* free-length duration */
    const char* target;   /* one-shot: layer id; wavetable: module id */
    const char* param;    /* wavetable: param to sweep, or NULL */
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
    CAW_PRESSURE_THERMAL_CRITICAL = 4,
    CAW_PRESSURE_UNKNOWN = 5
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

/* Strings returned by the engine are allocated; release them with caw_free. */
CAW_API void caw_free(char* s);

/* Compiles one module and returns JSON: {"ok":..., "error":..., "line":..., "col":..., "kind":..., "params":[...],
   "exports":[...], "imports":[...], "functions":[...]} (docs/engine.md describes every field). */
CAW_API char* caw_check(const char* source);

/* Engine for live playback. */
CAW_API CawEngine* caw_engine_create(int32_t sample_rate);
CAW_API void caw_engine_destroy(CawEngine* e);
/* Replaces the whole project (JSON, see docs/architecture.md). Unchanged layers keep playing; changed modules
   hot-swap with a crossfade; a module that fails to compile keeps its last good version. Returns result JSON. */
CAW_API char* caw_engine_set_project(CawEngine* e, const char* project_json);
CAW_API void caw_engine_set_param(CawEngine* e, const char* module_id, const char* name, double value);
/* Sets a project-wide `global` control; every module declaring it reads the new value. */
CAW_API void caw_engine_set_global(CawEngine* e, const char* name, double value);
CAW_API void caw_engine_set_layer_mix(CawEngine* e, const char* layer_id, double volume, double pan, int32_t mute,
                                      int32_t solo);
CAW_API void caw_engine_play(CawEngine* e);
CAW_API void caw_engine_stop(CawEngine* e);
CAW_API void caw_engine_clear_overload(CawEngine* e);
CAW_API void caw_engine_meters(CawEngine* e, CawMeters* out);
CAW_API int32_t caw_engine_layer_meter(CawEngine* e, int32_t layer_index, CawLayerMeter* out);
/* Latest n (<= 1024) output samples of a layer (by project index), the audition (64) or the master (-1). */
CAW_API int32_t caw_engine_scope(CawEngine* e, int32_t layer_index, float* out, int32_t n);
/* For hosts that drive the audio themselves (plugin, tests). Real-time safe. */
CAW_API void caw_engine_process(CawEngine* e, float* left, float* right, int32_t frames);

/* Audio output through the platform's device. Returns 0 on success. */
CAW_API int32_t caw_audio_start(CawEngine* e, char* error, int32_t error_len);
CAW_API void caw_audio_stop(CawEngine* e);

/* Offline export to a WAV file. progress gets 0..1000; set *cancel non-zero to stop. Returns 0 on success. */
CAW_API int32_t caw_render(const char* project_json, const CawRenderOptions* options, const char* out_path,
                           int32_t* progress, int32_t* cancel, char* error, int32_t error_len);

/* Every built-in and library function with its docs, arguments and example, plus the named constants, as JSON
   ({"functions":[{"name","category","signature","doc","example","args":[{"name","doc","optional"}]}],
   "constants":[...]}). Free with caw_free. */
CAW_API char* caw_library(void);

/* MIDI files for note patterns. caw_pattern_from_midi reads a Standard MIDI File (format 0 or 1) or a MIDI 2.0 Clip
   File and returns JSON {"ok":..., "error":..., "pattern":"<pattern module text>"}; free it with caw_free.
   caw_pattern_export writes a pattern module (its source text) to out_path: format 0 = Standard MIDI File (.mid),
   1 = MIDI 2.0 Clip File (.midi2). bpm 20..400, beats_per_bar 1..16. Returns 0 on success. */
enum { CAW_MIDI_SMF = 0, CAW_MIDI_CLIP = 1 };
CAW_API char* caw_pattern_from_midi(const uint8_t* data, int32_t size);
CAW_API int32_t caw_pattern_export(const char* pattern_source, double bpm, int32_t beats_per_bar, int32_t format,
                                   const char* out_path, char* error, int32_t error_len);

/* Starter templates bundled with the engine (the files in examples/). Strings are static; don't free them. */
CAW_API int32_t caw_template_count(void);
CAW_API const char* caw_template_file(int32_t index);
CAW_API const char* caw_template_source(int32_t index);


/* Pure workload policy shared by the app and add-ons. Hosts supply observed capabilities;
   this does not query OS APIs, start workers, or alter the real-time audio callback. */
CAW_API int32_t caw_execution_plan(const CawHardwareProfile* hardware, const CawExecutionRequest* request,
                                   CawExecutionPlan* out);
CAW_API int32_t caw_hardware_profile_detect(CawHardwareProfile* out);

/* Native non-real-time job execution. Job handles own their results until caw_job_release. */
typedef struct CawWorkerPool CawWorkerPool;
typedef struct CawJob CawJob;
enum { CAW_JOB_BACKGROUND = 0, CAW_JOB_OFFLINE = 1, CAW_JOB_FOREGROUND = 2 };
enum { CAW_JOB_QUEUED = 0, CAW_JOB_RUNNING = 1, CAW_JOB_SUCCEEDED = 2, CAW_JOB_FAILED = 3, CAW_JOB_CANCELLED = 4 };
typedef struct CawJobStatus { uint32_t struct_size; int32_t state; int32_t progress; int32_t result_code; } CawJobStatus;
CAW_API CawWorkerPool* caw_worker_pool_create(uint32_t max_workers);
CAW_API void caw_worker_pool_destroy(CawWorkerPool* pool);
CAW_API int32_t caw_worker_pool_apply(CawWorkerPool* pool, const CawExecutionRequest* request, CawExecutionPlan* out);
CAW_API CawJob* caw_worker_pool_submit_check(CawWorkerPool* pool, const char* source, int32_t priority);
CAW_API CawJob* caw_worker_pool_submit_project(CawWorkerPool* pool, CawEngine* engine, const char* project_json,
                                                int32_t priority);
CAW_API CawJob* caw_worker_pool_submit_render(CawWorkerPool* pool, const char* project_json,
                                               const CawRenderOptions* options, const char* out_path,
                                               int32_t priority);
/* Set status->struct_size to sizeof(CawJobStatus) before calling. */
/* Blocks the calling thread until terminal; never call on the audio callback or UI thread.
   timeout_ms == UINT32_MAX waits indefinitely; returns 0 complete, 2 timeout, 1 invalid handle, 3 wait error. */
CAW_API int32_t caw_job_wait(CawJob* job, uint32_t timeout_ms);
CAW_API int32_t caw_job_get_status(CawJob* job, CawJobStatus* out);
CAW_API char* caw_job_result(CawJob* job);
CAW_API char* caw_job_error(CawJob* job);
/* Cancels queued jobs; a running render is interruptible, running checks/compiles finish. */
CAW_API void caw_job_cancel(CawJob* job);
CAW_API void caw_job_release(CawJob* job);
CAW_API void caw_worker_pool_wait_idle(CawWorkerPool* pool);

#ifdef __cplusplus
}
#endif
#endif /* CAW_H */
