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

/* Starter templates bundled with the engine (the files in examples/). Strings are static; don't free them. */
CAW_API int32_t caw_template_count(void);
CAW_API const char* caw_template_file(int32_t index);
CAW_API const char* caw_template_source(int32_t index);

#ifdef __cplusplus
}
#endif

#endif /* CAW_H */
