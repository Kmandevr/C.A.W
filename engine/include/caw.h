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

/* 2 (2026-11-09): scope() indexes 0..n-1 are project layers at any capacity; the master and the
   audition are CAW_SCOPE_MASTER and CAW_SCOPE_AUDITION, not fixed slot numbers (F7.3).
   3 (2026-11-09): native components on tracks ("components" per layer) and parameter values in
   both chains ({"id","params","bypass","state","state_version"} entries), component automation
   lanes ("target_type":"component"); caw_engine_set_component_param, _bypass and _states.
   4 (2026-11-10): native instruments: a layer's "instrument" entry (same shape as a component entry)
   plays its notes instead of a .caw generator; component index CAW_INSTRUMENT_INDEX addresses it in
   _set_component_param, _bypass and _states; automation lanes "target_type":"instrument". Older
   fields work as before.
   5 (2026-11-10): caw_engine_layer_meter_stereo (each side's peak per track); track and master volume up to
   +12 dB. CawLayerMeter is unchanged.
   6 (2026-11-10): caw_engine_component_display (live display data a component publishes for its UI: spectra,
   gain reduction, levels; #173). Nothing else changes.
   7 (2026-11-10): caw_engine_play_count_in, caw_engine_set_metronome (a built-in click) and
   caw_engine_release_touches; track volume lanes up to +12 dB, as the faders.
   8 (2026-11-10): built-in presets ("presets" in caw_engine_components, "preset" in a component entry),
   caw_migrate_instrument (the retired synths as Flagship presets), caw_engine_set_quality and
   caw_audio_set_buffer_mode.
   9 (2026-11-10, #175): routing. A layer's "sends" ([{"to": bus folder id, "level", "pre", "mute"}], at most 8),
   caw_engine_set_send; bus folders run their "components"; a component entry's "key" ({"layer", "tap": "pre" |
   "post", "level"}) feeds a component's sidechain input (org.caw.ducker, the compressor, the gate); routing
   loops are refused; latency compensation covers buses and sends.
   10 (2026-11-11): the audio device's choice and state (caw_audio_devices, caw_audio_configure,
   caw_audio_status), the metronome's sound and volume (caw_engine_set_metronome_sound) and a test tone
   (caw_engine_test_tone). Nothing else changes.
   12 (2026-11-11, roadmap 2.6): live loudness and correlation meters (caw_engine_loudness,
   caw_engine_loudness_reset, caw_engine_layer_correlation). Nothing else changes. (11 is another branch's.) */
#define CAW_API_VERSION 12
/* The component index that names a layer's native instrument rather than one of its "components". */
#define CAW_INSTRUMENT_INDEX 0xFFFFFFFFu

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
/* Native component loading is never implied by a successful build. The caller must pass an explicit
   per-component trust level. Isolated is rejected until a separate-process audio host exists. */
enum { CAW_NATIVE_TRUST_BLOCKED = 0, CAW_NATIVE_TRUST_ISOLATED = 1, CAW_NATIVE_TRUST_TRUSTED = 2 };
CAW_API char* caw_engine_load_component(CawEngine* e, const char* library_path,
                                        const char* expected_component_id, int32_t trust_level);
CAW_API int32_t caw_engine_unload_component(CawEngine* e, const char* component_id);
/* A rebuild of a loaded component, from a new file (the same path would return the old library).
   It replaces the old build, and every chain using it switches to it, crossfaded, keeping each
   instance's values, bypass and (if the new build accepts it) state. JSON as for load. */
CAW_API char* caw_engine_reload_component(CawEngine* e, const char* library_path, const char* expected_component_id,
                                          int32_t trust_level);
/* The loaded native components' descriptors as JSON (free with caw_free):
   {"ok":true,"components":[{"id","name","version","role","latency_frames","tail_frames" (null =
   infinite),"max_state_bytes","custom_ui_id","ports":[{"id","type","input","layout","channels",
   "summing"}],"parameters":[{"id","name","unit","default","min","max","step","curve",
   "smoothing_frames","automatable","modulatable","midi_mappable","choices":[...]}],
   "ui_controls":[{"id","label","parameter_id","kind","min","max"}]}]} */
CAW_API char* caw_engine_components(CawEngine* e);
CAW_API void caw_engine_set_param(CawEngine* e, const char* module_id, const char* name, double value);
/* A playing native component's parameter: component `index` (0-based) of a layer's "components"
   chain, or of "master_components" when layer_id is NULL or empty; CAW_INSTRUMENT_INDEX: the layer's
   "instrument". It ramps over the parameter's
   smoothing. 1 on success, 0 if there is no such component or parameter, or value is not finite. */
CAW_API int32_t caw_engine_set_component_param(CawEngine* e, const char* layer_id, uint32_t index,
                                               const char* param_id, double value);
/* Bypasses (bypass != 0) or brings back component `index` of the chain, crossfaded over 5 ms; a
   bypassed component is not run. 1 on success, 0 if there is no such component. */
CAW_API int32_t caw_engine_set_component_bypass(CawEngine* e, const char* layer_id, uint32_t index, int32_t bypass);
/* Live display data (API version 6, #173): copies the latest block of floats component `index` published for
   its UI (addressed as in caw_engine_set_component_param: NULL or empty layer_id is the master chain,
   CAW_INSTRUMENT_INDEX the layer's instrument) into out, at most max floats. Returns the count copied; 0 when
   the component publishes nothing (yet) or the engine is busy with a project update (call again next frame);
   -1 when there is no such component. Never blocks and never allocates; call it from the UI thread as often as
   the screen refreshes (components publish about 60 times a second). Each component's float layout is in
   docs/engine.md ("Display data"). */
CAW_API int32_t caw_engine_component_display(CawEngine* e, const char* layer_id, uint32_t index, float* out,
                                             int32_t max);
/* Each component's state as it saves it now, as JSON (free with caw_free):
   {"ok":true,"components":[{"index","ok","version","state" (base64)}]} (the layer's instrument has
   index CAW_INSTRUMENT_INDEX). Store "state" and
   "version" (as "state_version") in the project's entry so a reload or an export starts from it. */
CAW_API char* caw_engine_component_states(CawEngine* e, const char* layer_id);
/* A send while it plays (API version 9): send `index` (0-based) of the layer's project "sends" gets `level`
   (linear gain 0..3.981, +12 dB), pre-fader (pre != 0: after the layer's effects, before its volume and pan) or
   post-fader, and mute; the level glides over 5 ms. 1 on success, 0 if the layer has no such send. A later
   project update sets the values it names again, so write the new values into the project too. */
CAW_API int32_t caw_engine_set_send(CawEngine* e, const char* layer_id, uint32_t index, double level, int32_t pre,
                                    int32_t mute);
/* Sets a project-wide `global` control; every module declaring it reads the new value. */
CAW_API void caw_engine_set_global(CawEngine* e, const char* name, double value);
/* Track and master volume: linear gain 0..3.981 (+12 dB; more is held there). Pan -1..1. */
CAW_API void caw_engine_set_layer_mix(CawEngine* e, const char* layer_id, double volume, double pan, int32_t mute,
                                      int32_t solo);
CAW_API void caw_engine_set_master(CawEngine* e, double volume);
/* Note previews: a held note on a layer's instrument, heard through the layer's effects and mix (mute and solo
   apply), while playing or stopped; stopped, the transport stays where it is. `id` is the caller's handle: a second
   note on with the same id ends the first. Pitch is a MIDI note number (fractions allowed), velocity 0..1. Only a
   layer that plays a pattern, or has a native instrument, can preview; a native instrument gets them as note
   events with their own note ids (a MIDI keyboard plays through these too). note_pitch glides a held preview to a new pitch without a new attack. */
CAW_API void caw_engine_note_on(CawEngine* e, const char* layer_id, int32_t id, double pitch, double velocity);
CAW_API void caw_engine_note_pitch(CawEngine* e, int32_t id, double pitch);
CAW_API void caw_engine_note_off(CawEngine* e, int32_t id);
CAW_API void caw_engine_notes_off(CawEngine* e);
CAW_API void caw_engine_play(CawEngine* e);
/* Plays from `step` sixteenth steps into the project loop (fractions allowed), so a pause resumes where it stopped,
   on the same beat even if the tempo changed meanwhile; outside the loop (or not finite) it starts at 0. It fades in
   over 10 ms. Notes that began before it are not heard, and a module's trig fires at its next pass, not here. */
CAW_API void caw_engine_play_at(CawEngine* e, double step);
/* Clicks `beats` (0..64) beats at the tempo, accented on each bar, then plays from `step` as caw_engine_play_at does,
   on the sample after the last beat; previews play during it. While playing, or with 0 beats, it is play_at. A stop
   during the count-in cancels it. */
CAW_API void caw_engine_play_count_in(CawEngine* e, double step, int32_t beats);
/* The metronome (on != 0): a short click on every beat while playing, accented on the bar, mixed before the safety
   limiter. Off by default; offline renders never click. */
CAW_API void caw_engine_set_metronome(CawEngine* e, int32_t on);
/* Ends every knob touch (a parameter set while playing overrides its lane until the next play), so the lanes rule
   again at once: the host's automation Touch mode calls it when a written control is let go. */
CAW_API void caw_engine_release_touches(CawEngine* e);
CAW_API void caw_engine_stop(CawEngine* e);
CAW_API void caw_engine_clear_overload(CawEngine* e);
CAW_API void caw_engine_meters(CawEngine* e, CawMeters* out);
CAW_API int32_t caw_engine_layer_meter(CawEngine* e, int32_t layer_index, CawLayerMeter* out);
/* The same, with each side's sample peak since the last read in *peak_l and *peak_r (either may be NULL); the
   meter's peak is the louder of the two. Either call resets both sides. API version 5. */
CAW_API int32_t caw_engine_layer_meter_stereo(CawEngine* e, int32_t layer_index, CawLayerMeter* out, float* peak_l,
                                              float* peak_r);
/* Latest n (<= 1024) output samples of a layer (by project index), the audition (CAW_SCOPE_AUDITION) or the
   master (CAW_SCOPE_MASTER). */
#define CAW_SCOPE_MASTER (-1)
#define CAW_SCOPE_AUDITION (-2)
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

/* Component testing suite (#163): renders one C++ effect offline (never on the audio thread, no
   device) with a test signal and returns its measurements as JSON. The request is JSON, e.g.
   {"component":{"id":"org.caw.distortion","params":{"drive":8}},"signal":{"type":"sine","frequency":1000}};
   a built library needs "library"; its trust is [trust_level] (CAW_NATIVE_TRUST_*: the user's own choice for that
   library), and a request naming a "trust" is refused. "write_wav"/"write_input_wav" are plain file names written
   inside [output_dir] (NULL: no files) and a WAV test signal's "path" a plain name inside [input_dir] (NULL: none).
   Keys of the request and the result: docs/engine.md, "Component testing". The result always has
   "ok" and "error". Blocks the caller for the render; call it from a worker, never the UI or audio
   thread. Free the result with caw_free. */
CAW_API char* caw_component_test(const char* request_json, int32_t trust_level, const char* output_dir,
                                 const char* input_dir);

/* Sample-pack maker (#164): renders an instrument (and an optional effect chain) offline over a grid of
   notes x velocities x parameter steps, each a note held then released until its tail is quiet, and writes
   named WAV files (16/24-bit PCM or 32-bit float, smpl chunk with root note and optional loop), a manifest
   JSON and optionally SFZ files, all directly inside the request's "output_dir". Request and result keys:
   docs/engine.md, "Sample packs". trust_level (CAW_NATIVE_TRUST_*) applies to every library the request
   names; only TRUSTED loads one, and a "trust" key in the request is refused. progress gets 0..1000 and a
   non-zero *cancel stops it (either may be NULL). Blocks the caller for the whole render: call it from a
   worker, never the UI or audio thread. The result always has "ok" and "error"; free it with caw_free. */
CAW_API char* caw_sample_pack_render(const char* request_json, int32_t trust_level, int32_t* progress,
                                     int32_t* cancel);

/* The retired synths (org.caw.synth.morph, org.caw.bass, org.caw.synth.acid, org.caw.synth.basic) are Flagship
   presets. For an instrument entry {"id": ..., "params": {...}} returns {"ok": true, "migrated": bool, "id": ...,
   "params": {...}} and, when migrated, "preset" (its name) and "lanes" ({old knob: Flagship knob} for automation
   lanes; a knob not listed has no Flagship knob in its units). Another entry comes back with "migrated": false,
   and, when it names a "preset", that preset's values under its own params (an unknown preset: "ok": false).
   Needs no engine; free with caw_free. The engine migrates a project it is given too. */
CAW_API char* caw_migrate_instrument(const char* entry_json);

/* Sound quality, for the device's budget: Eco lowers oversampling, caps unison copies at 4, halves display
   updates and thins the built-in reverbs; High raises oversampling where a built-in has it. Takes effect at
   the next block (settings that size memory, such as oversampling, at the next project update). */
#define CAW_QUALITY_ECO 0
#define CAW_QUALITY_NORMAL 1
#define CAW_QUALITY_HIGH 2
CAW_API void caw_engine_set_quality(CawEngine* e, int32_t quality);
CAW_API int32_t caw_engine_quality(CawEngine* e);

/* The device buffer: Auto uses a larger one (about 21 ms) while not recording and the smallest the device
   gives while recording; Low latency always the smallest; Battery always the larger, on the power-saving path.
   A running device reopens when the size changes (a short gap). */
#define CAW_BUFFER_AUTO 0
#define CAW_BUFFER_LOW_LATENCY 1
#define CAW_BUFFER_BATTERY 2
CAW_API void caw_audio_set_buffer_mode(CawEngine* e, int32_t mode, int32_t recording);
/* The device's callback size in frames while it runs (0 when stopped or unknown). */
CAW_API int32_t caw_audio_buffer_frames(CawEngine* e);

/* API version 10. The playback devices the platform's audio backend lists, as JSON: {"backend": name,
   "exclusive": whether this backend takes an exclusive-mode request (WASAPI, AAudio), "devices": [{"name",
   "default": bool, "rates": [native sample rates; 0 means any], "exclusive_rates": [rates offered in exclusive
   mode]}]}. AAudio lists only the system default (Android routes it). Opens and closes the backend, so it can take
   tens of milliseconds: call it off the UI thread, never from the audio thread. Free with caw_free. */
CAW_API char* caw_audio_devices(void);
/* How the device opens: on the playback device named [device_name] (NULL or empty: the system default; a name not
   found also opens the default), with a callback of [period_frames] frames (16..8192; 0: as the buffer mode
   chooses), and [flags]. CAW_AUDIO_EXCLUSIVE asks for exclusive mode (AAudio's exclusive sharing, its MMAP path
   where the phone has one; WASAPI exclusive), falling back to shared when the device refuses. A running device
   reopens with the new choice (a short gap). Returns 0, or 1 when the device was running and did not reopen. */
#define CAW_AUDIO_EXCLUSIVE 1
CAW_API int32_t caw_audio_configure(CawEngine* e, const char* device_name, int32_t period_frames, int32_t flags);
/* The device as it runs, as JSON: {"running", "backend", "device", "sample_rate", "period_frames", "periods",
   "exclusive" (granted at open), "low_latency" (the low-latency profile)} and the request ("requested_device",
   "requested_frames", "exclusive_requested"); with no device running, {"running": false} and the request. AAudio
   may still give a shared stream for an exclusive request without saying so. Free with caw_free. */
CAW_API char* caw_audio_status(CawEngine* e);
/* The metronome's (and count-in's) click: [volume] 0..1 (1 the default) and its CAW_CLICK_* sound. */
#define CAW_CLICK_CLASSIC 0
#define CAW_CLICK_WOOD 1
#define CAW_CLICK_TICK 2
CAW_API void caw_engine_set_metronome_sound(CawEngine* e, double volume, int32_t sound);
/* A test tone: [seconds] (up to 10) of a 440 Hz sine at -12 dBFS, mixed after the master whether or not the song
   plays, with 10 ms fades; 0 ends one early. caw_engine_test_tone_sounding says whether one still sounds. */
CAW_API void caw_engine_test_tone(CawEngine* e, double seconds);
CAW_API int32_t caw_engine_test_tone_sounding(CawEngine* e);

/* Live loudness and correlation meters (API version 12, roadmap 2.6), read from the UI at 10 Hz or more. The
   master's loudness is measured on what the device plays (after the master chain and the safety limiter; the test
   tone and nothing else is left out) per ITU-R BS.1770-5 (11/2023) and EBU Tech 3341 V4 (11/2023): K-weighted,
   left and right weighted 1. Momentary is the last 400 ms, short-term the last 3 s (both ungated), integrated the
   gated loudness (400 ms blocks every 100 ms, the -70 LUFS absolute gate and the relative gate 10 LU below) since
   the last Play or caw_engine_loudness_reset. True peak is 4x oversampled with BS.1770-5 Annex 2's interpolating
   filter (2x at 96 kHz, none from 192 kHz). A value with no reading yet, or of silence, is CAW_METER_NONE. */
#define CAW_METER_NONE (-200.0f)
typedef struct CawLoudness {
    float momentary_lufs;
    float short_term_lufs;
    float integrated_lufs;
    float momentary_max_lufs;   /* the loudest since the last reset (EBU Mode's maxima) */
    float short_term_max_lufs;
    float true_peak_l_dbtp;     /* each side's true peak since the last read */
    float true_peak_r_dbtp;
    float true_peak_max_dbtp;   /* the louder side's, since the last reset */
    float correlation;          /* the master's stereo correlation: 1 mono, 0 unrelated or silent, -1 opposite */
    float integrated_seconds;   /* audio the integrated loudness has measured */
} CawLoudness;
CAW_API void caw_engine_loudness(CawEngine* e, CawLoudness* out);
/* Starts the integrated loudness, the maxima and the true-peak maximum again (Play does this too). */
CAW_API void caw_engine_loudness_reset(CawEngine* e);
/* A project layer's stereo correlation (a track or a folder bus, of what it sends on after volume and pan),
   over about 300 ms: 1 identical sides, 0 unrelated or silent, -1 opposite. 1 on success, 0 if layer_index is not a
   project layer. */
CAW_API int32_t caw_engine_layer_correlation(CawEngine* e, int32_t layer_index, float* out);

#ifdef __cplusplus
}
#endif
#endif /* CAW_H */
