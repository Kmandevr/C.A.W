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
   11 (2026-11-11): org.caw.drums (64 pads; the old org.caw.drum.* migrate to it through caw_migrate_instrument):
   caw_drums_info, caw_drums_randomize, caw_drums_explode; a component entry's "samples" ([{"slot", "path"} or
   {"slot", "builtin"}]) fills its sample slots; a parameter in caw_engine_components may carry "group".
   12 (2026-11-11, roadmap 2.6): live loudness and correlation meters (caw_engine_loudness,
   caw_engine_loudness_reset, caw_engine_layer_correlation). Nothing else changes.
   13 (2026-11-11): 11 and 12 together (the drums branch and the meters branch merged).
   14 (2026-11-11): caw_engine_set_component_state (a playing component's new saved state: the convolver's WAV
   impulse). Nothing else changes.
   15 (2026-11-11): MIDI device input, frame-accurate: caw_midi_clock_ns, caw_engine_midi_ump, caw_engine_midi_bytes,
   caw_engine_midi_release, caw_engine_set_midi_options, caw_engine_midi_dropped and caw_engine_position_at.
   Nothing else changes.
   16 (2026-11-11): song renders and stems: caw_render_song and caw_worker_pool_submit_song (aligned mix, track,
   bus and region renders; bounds, tail, normalise, 16-bit dither). Nothing else changes.
   17 (2026-11-11): C++ in place of .caw (#160 prep), no new functions: the project JSON's "audition" takes a C++
   "instrument" and native "components" as a track does (the preview needs no .caw chain); caw_render's wavetable
   target may be a layer with a C++ instrument or a built-in instrument's id (its parameter swept), and a one-shot of
   a C++ instrument layer with no notes plays one C4 for 0.5 s to its tail.
   18 (2026-11-11, WP-J): audio assets (caw_asset_*), audio clips on tracks (a layer's "audio_clips" and the
   project's "assets"), the sampler org.caw.sampler with SFZ import and export (caw_sfz_*), audio input
   (caw_audio_input_devices, caw_audio_configure_input, a layer's "input", caw_engine_input_peaks), recording
   (caw_record_*), input latency (caw_engine_set_input_latency, caw_engine_input_latency, caw_latency_ping_*).
   Nothing else changes.
   19 (2026-11-11, #161): project modulation. The project JSON's "modulators" (components with modulation outputs:
   org.caw.mod.lfo, .envelope, .follower, .steps, .random, .macros, .midi, or a user's C++ modulator) and
   "modulation" links (any modulator output to any parameter of a layer's or the master's component or instrument,
   another modulator's parameter, or a layer's volume, pan or send level; docs/engine.md, "Modulation");
   caw_engine_set_modulator_param, caw_engine_set_modulator_bypass, caw_engine_set_modulation_amount,
   caw_engine_modulator_outputs and caw_engine_modulation_offset. Nothing else changes.
   20: not used (the .caw removal took 21 and the per-note FX host 22 while they were built in parallel).
   21 (2026-11-11, #160): the .caw language is gone. Removed: caw_check, caw_library, caw_template_count,
   caw_template_file, caw_template_source, caw_engine_set_param, caw_engine_set_global and
   caw_worker_pool_submit_check. A project's "modules" are patterns (note clips) only: any other module reports
   an error in its result entry; layers' "chain" and the project's "globals" are not read.
   22 (2026-11-11, #127): per-note FX. A layer's "noteComponents" (effects run once per note, between its
   instrument's voices and its shared stage) and "noteVoices" (1..16, default 8); component indices with CAW_NOTE_COMPONENT address them (knobs and bypass fan
   out to every slot, the display reads the newest note's slot); automation lanes and modulation links of kind
   "noteComponent"; the link sources "note.pitch", "note.velocity", "note.pressure", "note.timbre", "note.gate" and
   "note.age"; caw_engine_note_fx_stats. The voice bus (caw_component.h) gains CAW_LANE_REST. Nothing else changes.
   23 (2026-11-11): caw_audio_latency, the running device's output and input latency (AAudio's timestamps where it
   has them, else the queued buffers), the routed device's id and, on WASAPI, its kind. Nothing else changes.
   24 (2026-11-12, speed phase 5d, branch speed-parallel): caw_audio_threads, the audio callback's core, its clock
   and kind, the scheduling the platform gave the callback and the mix pool's workers, and the pool's size. Built
   beside 25 to 27 and merged after them, so a library has it from 28.
   25 (2026-11-12, beta plan B4.8): caw_engine_layer_meters reads every project layer's stereo meter in one call
   into a caller's array of CawLayerMeterStereo (the app's meter poll made one call per track). Nothing else
   changes.
   26 (2026-11-12, audio-resilience): caw_audio_set_background (a larger AAudio output buffer behind the app, without
   reopening); the input is a capture device of its own (caw_audio_configure_input no longer reopens the output),
   and caw_audio_status's "input" gains "state", "underruns", "dropped_frames", "missing_frames" and "drift_ppm"
   and the top level "stopped_by_system". Nothing else changes.
   27 (2026-11-13, branch bt-clicks, 26 on its branch): caw_engine_shedding_stats, how many layers the engine shed
   because the device ran out of time and how many came back on their own. Shed layers now come back by themselves
   once the load has stayed low (CawMeters.overloaded falls again), and caw_engine_clear_overload also forgets the
   load history. Nothing else changes.
   28 (2026-11-13): branch speed-parallel merged: caw_audio_threads (24 above) is in the library beside 25 to 27.
   Nothing else changes.
   29 (2026-11-13, beta plan C; 27 on branch benchmark): the Benchmark (stress test). caw_stress_scenarios lists its
   scenarios; caw_worker_pool_submit_stress runs a CawStressRequest (a scenario timed, a ramp, a sustained or a
   profiled run, on a worker or through the device with the output muted) as a CawJob (status, cancel, wait, result
   and release as for every job); caw_stress_progress, caw_stress_history, caw_stress_result and caw_stress_costs
   read it. Nothing else changes. */
#define CAW_API_VERSION 29
/* The component index that names a layer's native instrument rather than one of its "components". */
#define CAW_INSTRUMENT_INDEX 0xFFFFFFFFu
/* A component index with this bit (API version 22) names component (index & ~CAW_NOTE_COMPONENT) of the layer's
   "noteComponents" (per-note FX, #127). */
#define CAW_NOTE_COMPONENT 0x40000000u

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

/* One layer's meter with each side's peak (caw_engine_layer_meters, API version 25). */
typedef struct CawLayerMeterStereo {
    float peak;      /* the louder side's, since the last read */
    float peak_l;
    float peak_r;
    float progress;  /* 0..1 through this layer's own loop */
    int32_t active;
    int32_t overloaded;
} CawLayerMeterStereo;

enum { CAW_EXPORT_LOOP = 0, CAW_EXPORT_FREE = 1, CAW_EXPORT_ONESHOT = 2, CAW_EXPORT_WAVETABLE = 3 };

typedef struct CawRenderOptions {
    int32_t kind;         /* CAW_EXPORT_* */
    int32_t sample_rate;  /* 44100 or 48000 */
    int32_t float32;      /* 1 = 32-bit float, 0 = 24-bit PCM (wavetables are always float) */
    int32_t frames;       /* wavetable frames, 1..256 */
    double seconds;       /* free-length duration */
    const char* target;   /* one-shot: layer id; wavetable: a layer with a C++ instrument, or a built-in
                             instrument's id */
    const char* param;    /* wavetable: the parameter to sweep, or NULL */
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

/* Engine for live playback. */
CAW_API CawEngine* caw_engine_create(int32_t sample_rate);
CAW_API void caw_engine_destroy(CawEngine* e);
/* Replaces the whole project (JSON, see docs/architecture.md). Unchanged layers keep playing; a changed instrument
   or chain crossfades in; a pattern that fails to parse keeps its last good version. Returns result JSON with one
   entry per pattern module ({"ok", "kind":"pattern", "error", "line", "col", "notes", ...; docs/engine.md}). */
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
   infinite),"max_state_bytes","custom_ui_id","domains" (["whole","per_channel","per_voice","per_note"], the ones
   declared),"capabilities" (["notes_in","midi_in","events_out","sample_assets","needs_transport","export_clap"]),
   "cpu_class" ("unspecified","light","medium","heavy"),"ports":[{"id","type","input","layout","channels",
   "summing"}],"parameters":[{"id","name","unit","default","min","max","step","curve",
   "smoothing_frames","automatable","modulatable","midi_mappable","choices":[...]}],
   "ui_controls":[{"id","label","parameter_id","kind","min","max"}]}]} */
CAW_API char* caw_engine_components(CawEngine* e);
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
/* A new saved state for a playing component (API version 14), addressed as in caw_engine_set_component_param:
   [size] bytes at [data] (0: an empty state) as save_state would write them, at state [version]. The convolver
   (org.caw.convolver) also takes a WAV file's bytes as its state: its impulse response (checked as untrusted, at
   most 10 s). The flagship (org.caw.synth.flagship) takes its User wavetable: an import ("CWTI", a frame split,
   a WAV's bytes) or its saved form ("CWT1"), laid out in docs/engine.md; no new function, the same version. The component's chain is rebuilt off the audio thread with every component's current values and
   states, this one's replaced, and crossfaded in. Returns 1, or 0 (nothing changes) when there is no such component
   or it refuses the state. It can take a while (a WAV decoded, a chain prepared): call it off the UI thread. Store
   the state in the project's entry as well ("state", base64, and "state_version") so a reload starts from it. */
CAW_API int32_t caw_engine_set_component_state(CawEngine* e, const char* layer_id, uint32_t index, const uint8_t* data,
                                               int32_t size, uint32_t version);
/* A send while it plays (API version 9): send `index` (0-based) of the layer's project "sends" gets `level`
   (linear gain 0..3.981, +12 dB), pre-fader (pre != 0: after the layer's effects, before its volume and pan) or
   post-fader, and mute; the level glides over 5 ms. 1 on success, 0 if the layer has no such send. A later
   project update sets the values it names again, so write the new values into the project too. */
CAW_API int32_t caw_engine_set_send(CawEngine* e, const char* layer_id, uint32_t index, double level, int32_t pre,
                                    int32_t mute);
/* Project modulation (API version 19, #161). A knob of a running modulator (its project "id"), ramped like a
   component's; bypass (its outputs hold 0); a link's amount (-1..1 of its target's travel) while it plays, as during
   a ring drag. 1 on success, 0 for an unknown modulator, parameter or link. A later project update sets the values
   it names again, so write the new values into the project too. */
CAW_API int32_t caw_engine_set_modulator_param(CawEngine* e, const char* modulator_id, const char* param, double value);
CAW_API int32_t caw_engine_set_modulator_bypass(CawEngine* e, const char* modulator_id, int32_t bypass);
CAW_API int32_t caw_engine_set_modulation_amount(CawEngine* e, uint32_t link_id, double amount);
/* A modulator's outputs (0..1 each) at the last audio chunk, at most `max` into out: the count, 0 while the
   engine is busy with a project update (never waits; a UI polls it every frame), -1 for an unknown modulator. */
CAW_API int32_t caw_engine_modulator_outputs(CawEngine* e, const char* modulator_id, float* out, int32_t max);
/* Link `link_id`'s target's summed offset (normalized travel, every link into that target together) at the last
   chunk, into *out: 1, or 0 for an unknown link or while busy. */
CAW_API int32_t caw_engine_modulation_offset(CawEngine* e, uint32_t link_id, float* out);
/* Per-note FX (API version 22, #127): what a layer's per-note slots are doing. Set struct_size to
   sizeof(CawNoteFxStats) first; fields past a smaller struct_size are not written. 1 on success, 0 when the layer
   has no per-note FX or the engine is busy with a project update (it never waits; a UI polls it). */
typedef struct CawNoteFxStats {
    uint32_t struct_size;
    uint32_t voices;       /* the layer's "noteVoices" */
    uint32_t budget;       /* slots notes may hold now: Eco min(voices, 4), Normal voices, High min(voices, 16) */
    uint32_t active;       /* slots holding a note (held, released or ringing out) */
    uint32_t active_mask;  /* bit k: slot k holds a note */
    uint32_t overflowing;  /* 1 while the overflow chain runs (notes past the budget, sharing one chain) */
    uint32_t overflowed;   /* notes that went to the overflow chain since the per-note FX started */
    uint32_t stolen;       /* released or ringing slots handed to a new note */
} CawNoteFxStats;
CAW_API int32_t caw_engine_note_fx_stats(CawEngine* e, const char* layer_id, CawNoteFxStats* out);
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
/* Layers shed since the engine was made (the telemetry's dropouts), how many came back on their own, and how many
   are shed now (as CawMeters.overloaded). Any thread; never blocks. API version 26. */
typedef struct CawSheddingStats {
    int64_t shed;
    int64_t restored;
    int32_t muted_now;
} CawSheddingStats;
CAW_API void caw_engine_shedding_stats(CawEngine* e, CawSheddingStats* out);
CAW_API void caw_engine_meters(CawEngine* e, CawMeters* out);
CAW_API int32_t caw_engine_layer_meter(CawEngine* e, int32_t layer_index, CawLayerMeter* out);
/* The same, with each side's sample peak since the last read in *peak_l and *peak_r (either may be NULL); the
   meter's peak is the louder of the two. Either call resets both sides. API version 5. */
CAW_API int32_t caw_engine_layer_meter_stereo(CawEngine* e, int32_t layer_index, CawLayerMeter* out, float* peak_l,
                                              float* peak_r);
/* Every project layer's meter at once, as caw_engine_layer_meter_stereo reads one (and resets it): the first
   min(count, capacity) layers go into out[0..]. Returns the project's layer count (0 for a NULL engine), so a
   caller with too small an array can grow it; out may be NULL with capacity 0. API version 25. */
CAW_API int32_t caw_engine_layer_meters(CawEngine* e, CawLayerMeterStereo* out, int32_t capacity);
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

/* MIDI files for note patterns. caw_pattern_from_midi reads a Standard MIDI File (format 0 or 1) or a MIDI 2.0 Clip
   File and returns JSON {"ok":..., "error":..., "pattern":"<pattern module text>"}; free it with caw_free.
   caw_pattern_export writes a pattern module (its source text) to out_path: format 0 = Standard MIDI File (.mid),
   1 = MIDI 2.0 Clip File (.midi2). bpm 20..400, beats_per_bar 1..16. Returns 0 on success. */
enum { CAW_MIDI_SMF = 0, CAW_MIDI_CLIP = 1 };
CAW_API char* caw_pattern_from_midi(const uint8_t* data, int32_t size);
CAW_API int32_t caw_pattern_export(const char* pattern_source, double bpm, int32_t beats_per_bar, int32_t format,
                                   const char* out_path, char* error, int32_t error_len);


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
/* Cancels queued jobs; a running render is interruptible, a running project update finishes. */
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

/* Drums (API version 11; docs/engine.md "Drums"). Pure functions: no engine needed; free each result with caw_free.
   caw_drums_info: the instrument's layout as JSON: {"ok", "banks", "pads_per_bank", "pads", "parameters", "globals",
   "layers": [{"id", "name", "params": [suffix]}], "types": [name], "sounds": [{"name", "type", "description",
   "params": {suffix: value}}], "kits": [{"name", "preset", "description", "pads": {pad: sound}}], "samples": [built-in
   sample names], "gm": [{"note", "name", "pad"}], "display": {offsets}}. A sound's params are a pad's values
   ("body_freq"); prefix them with the pad ("a1_") to set them.
   caw_drums_randomize: a random (current_json NULL or with no "params") or mutated sound of drum `type` (an index of
   "types"; -1 keeps the current sound's type) for pad `pad` (0 = A1 .. 63 = D16): the same type, seed, amount and
   current values always give the same result. amount 0..1 is how far each knob moves toward its random target
   (a fresh sound uses 1 when amount is 0); every drawn knob stays inside the type's range (a random kick is still a
   kick). current_json: {"params": {id: value}} with ids prefixed for that pad or bare suffixes. Returns {"ok",
   "type", "pad", "params": {"a1_...": value}} with every one of the pad's parameters.
   caw_drums_explode: for a Drums instrument entry ({"id", "params", "samples"}), one track per used pad:
   {"ok", "tracks": [{"pad", "name", "notes": [key] | "other" | "all" | {"channel": n}, "choke", "instrument":
   {"id", "params", "samples"}}], "kit": {the kit effects' values}}: each track's instrument plays that pad's sound
   alone (Single mode, pad A1); the caller moves the pad's notes to it. */
CAW_API char* caw_drums_info(void);
CAW_API char* caw_drums_randomize(int32_t type, uint32_t seed, double amount, int32_t pad, const char* current_json);
CAW_API char* caw_drums_explode(const char* entry_json);

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
/* API version 26. Behind the app ([background] != 0) the AAudio output's buffer size is raised to the stream's
   capacity (more latency, fewer dropouts while Android schedules a background app less), and 0 restores the size
   it had; no reopen. Call it only while nothing monitors the input. Returns the buffer size now in frames (0 where
   the backend has no such size, or nothing runs); caw_audio_latency reports the new latency. */
CAW_API int32_t caw_audio_set_background(CawEngine* e, int32_t background);

/* API version 10. The playback devices the platform's audio backend lists, as JSON: {"backend": name,
   "exclusive": whether this backend takes an exclusive-mode request (WASAPI, AAudio), "devices": [{"name",
   "id": the backend's id as text ("" where it has none worth keeping; WASAPI's endpoint id tells two identical
   interfaces apart), "default": bool, "rates": [native sample rates; 0 means any], "exclusive_rates": [rates
   offered in exclusive mode]}]}. AAudio lists only the system default (Android routes it). Opens and closes the backend, so it can take
   tens of milliseconds: call it off the UI thread, never from the audio thread. Free with caw_free. */
CAW_API char* caw_audio_devices(void);
/* How the device opens: on the playback device whose "id" (caw_audio_devices) is [device_id], else the one named
   [device_name] (both NULL or empty: the system default; one not found also opens the default; AAudio always
   opens the default, which Android routes), with a callback of [period_frames] frames (16..8192; 0: as the buffer
   mode chooses; AAudio on Android 11 and older ignores it), and [flags]. CAW_AUDIO_EXCLUSIVE asks for exclusive
   mode (AAudio's exclusive sharing, its MMAP path where the phone has one; WASAPI exclusive), falling back to
   shared when the device refuses. A running device reopens with the new choice (a short gap, under a lock: call it
   off the UI thread). When the choice does not open, the system default opens shared at its own size instead.
   Returns 0 (running as chosen, or not running), 2 (running on the default instead: caw_audio_status has
   "fallback" and why) or 1 (the device was running and nothing reopened: it is closed). The same choice again
   returns 0 or 2 as it runs. caw_audio_start falls back the same way and returns 0. */
#define CAW_AUDIO_EXCLUSIVE 1
CAW_API int32_t caw_audio_configure(CawEngine* e, const char* device_id, const char* device_name,
                                    int32_t period_frames, int32_t flags);
/* The device as it runs, as JSON: {"running", "backend", "device", "device_id", "sample_rate", "period_frames"
   (the callback size the device gave), "periods", "exclusive", "low_latency", "modes_read_back", "fallback",
   "fallback_reason"} and the request ("requested_device", "requested_device_id", "requested_frames",
   "exclusive_requested"); with no device running, {"running": false} and the request. On AAudio "exclusive" and
   "low_latency" (the fast path) are read from the stream at open ("modes_read_back": true; a later reroute may
   change them); on WASAPI "exclusive" is what opened (it refuses rather than share); elsewhere they are what was
   asked. Free with caw_free. */
CAW_API char* caw_audio_status(CawEngine* e);
/* API version 23. How late the running device is, as JSON: {"running", "sample_rate" (the engine's), "output":
   {"running", "frames" (engine frames from a sample leaving the engine to the speaker), "ms", "source", "device_id"},
   "input": the same for the microphone (to the engine reading it; miniaudio's duplex ring buffer included), running
   only while input is open}. "source": "timestamp" (AAudio: AAudioStream_getTimestamp's presentation or capture
   time against the frames written or read, read now), "buffers" (every queued period: WASAPI, ALSA, PulseAudio,
   or AAudio before its first timestamp) or "none". "device_id": AAudio's routed device (AudioDeviceInfo.getId()
   on Android), 0 elsewhere. "kind": the endpoint's link where the backend says ("bluetooth", "bluetoothLe", "usb",
   "hdmi", "wired", "builtIn", "remote"; WASAPI's bus and form factor), else "unknown". A Bluetooth or other link may add delay no backend reports: the app keeps a
   per-device offset on top. Takes the device lock: call it off the audio thread. Free with caw_free. */
CAW_API char* caw_audio_latency(CawEngine* e);
/* The audio thread and the mix pool (API 24; free with caw_free), JSON: "callback_cpu" (the core the callback ran on,
   sampled every 32 callbacks; -1 unknown or no device), "core_kind" ("big", "little", "other" when every core is one
   kind, "unknown"), "clock_khz" and "max_khz" (that core's clock now and its top, -1 where unreadable),
   "hint" (an Android performance hint session covers the callback and the workers), "mmcss" (the callback is in
   MMCSS "Pro Audio", Windows), "callback_tuning" and "worker_tuning" (what the platform granted: "priority",
   "realtime", "fast_cores", "mmcss", "no_power_throttling"), "workers", "active_workers" (those Auto lets take
   work), "wait_share" (the callback's averaged wait for workers, as a share of its budget), "cores", "fast_cores",
   "hybrid" and "core_source" ("cpu_capacity", "cpuinfo_max_freq", "EfficiencyClass", "none"). Reads the clock from
   the system: call it every second or so, not per frame. */
CAW_API char* caw_audio_threads(CawEngine* e);
/* The metronome's (and count-in's) click: [volume] 0..1 (1 the default) and its CAW_CLICK_* sound. */
#define CAW_CLICK_CLASSIC 0
#define CAW_CLICK_WOOD 1
#define CAW_CLICK_TICK 2
CAW_API void caw_engine_set_metronome_sound(CawEngine* e, double volume, int32_t sound);
/* A test tone: [seconds] (up to 10) of a 440 Hz sine at -12 dBFS, mixed after the master volume and the transport's
   fades and before the safety limiter, whether or not the song plays, with 10 ms fades; 0 ends one early.
   caw_engine_test_tone_sounding says whether one is asked for or still sounds (as the audio thread last saw it);
   opening or closing the device drops it. */
CAW_API void caw_engine_test_tone(CawEngine* e, double seconds);
CAW_API int32_t caw_engine_test_tone_sounding(CawEngine* e);

/* Live loudness and correlation meters (API version 12, roadmap 2.6), read from the UI at 10 Hz or more. The
   master's loudness is measured on what the device plays (after the master chain and the safety limiter, the test
   tone included) per ITU-R BS.1770-5 (11/2023) and EBU Tech 3341 V4 (11/2023): K-weighted,
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
/* API version 15. MIDI from devices (USB, Bluetooth, Windows ports), into a track's instrument at the frame it was
   played. Messages are queued (1,024 at most between two audio callbacks; more are dropped and counted) and the
   audio thread plays each one a callback (plus the options' delay) after its time, so the spacing between messages
   is kept as played; one that comes later than that plays at the start of the next callback.
   The clock: monotonic nanoseconds (steady_clock: CLOCK_MONOTONIC on Android and Linux, the same clock as Android's
   System.nanoTime and so MidiReceiver timestamps; QueryPerformanceCounter on Windows). */
CAW_API int64_t caw_midi_clock_ns(void);
/* [count] UMP words for [layer_id]'s instrument, all at [time_ns] on that clock (0 or less: now). MIDI 2.0 Channel
   Voice messages (type 4) and MIDI 1.0 Channel Voice ones (type 2, upscaled to MIDI 2.0 as the UMP specification's
   translation does) play; utility (JR timestamps), system, SysEx and data messages are skipped by their length.
   Returns the messages queued. Any thread but the audio callback's. */
CAW_API int32_t caw_engine_midi_ump(CawEngine* e, const char* layer_id, const uint32_t* words, int32_t count,
                                    int64_t time_ns);
/* The same for a MIDI 1.0 byte stream (running status within the call; real-time bytes, system messages and SysEx
   skipped), converted to MIDI 2.0 at the edge, in group 0. */
CAW_API int32_t caw_engine_midi_bytes(CawEngine* e, const char* layer_id, const uint8_t* bytes, int32_t count,
                                      int64_t time_ns);
/* What the instrument hears: a Note On holds a note (a preview, with the device's key and channel, so Stop's fade
   and mute end it too, but not caw_engine_notes_off, which ends the app's own previews); its Note Off ends it, or
   the sustain pedal (CC 64) holds it until the pedal is up;
   Poly Pressure and MIDI 2.0 per-note pitch reach that note; Pitch Bend becomes the pitch of the channel's notes
   (bend_range semitones); Channel Pressure the pressure of the channel's notes; CC 120 and 123 end the channel's
   notes. Every Control Change, Program Change and Channel Pressure also reaches the instrument as itself (a MIDI
   event, MIDI 2.0 words, note id 0). With CAW_MIDI_MPE, channel 1 is the master (its bend and pressure apply to
   every note, its bend over bend_range) and channels 2..16 each carry one note (their bend over note_bend_range,
   their CC 74 the note's timbre). note_bend_range is also a MIDI 2.0 per-note pitch bend's range. */
#define CAW_MIDI_MPE 1
CAW_API void caw_engine_set_midi_options(CawEngine* e, int32_t flags, double bend_range, double note_bend_range,
                                         double delay_ms);
/* Ends every device note on [layer_id] (NULL or empty: on every track) and forgets their channels' bend and pedal,
   at the next callback: a device was unplugged with keys down. */
CAW_API void caw_engine_midi_release(CawEngine* e, const char* layer_id);
/* Device messages dropped since the engine was made (a full queue). */
CAW_API int64_t caw_engine_midi_dropped(CawEngine* e);
/* The transport position (samples into the project loop, not wrapped at its end) the audio thread renders at
   [time_ns] on the MIDI clock, worked out from the last callback's start; -1 while stopped. Recording places a
   played note with it. */
CAW_API int64_t caw_engine_position_at(CawEngine* e, int64_t time_ns);

/* Song renders for the Export sheet (API version 15, roadmap 0.3, 6.4, 6.5): the mix and aligned stems (a file per
   track and per folder bus: what it sends to its parent or the master, after its effects, volume and pan) over the
   song, the loop range, a time selection or each region, with a tail (none, seconds, or until silent), peak or
   loudness (BS.1770-5) normalisation, 16/24-bit PCM (TPDF dither at 16) or 32-bit float, and names from a pattern.
   One engine pass per range renders every file of it, so they start on the same frame and have the same length.
   request_json is described in docs/engine.md ("Song renders"); every file goes into its existing "out_dir". The
   result is JSON {"ok", "error", "files":[{"path", "name", "kind", "layer", "region", "frames", "gain_db",
   "peak_db", "lufs"}]}; free it with caw_free. progress gets 0..1000 and a non-zero *cancel stops it (either may be
   NULL); on failure or cancel no file of the request is left. Blocks the caller for the whole render: call it from
   a worker, never the UI or audio thread. caw_worker_pool_submit_song runs it as a cancellable job whose
   caw_job_result is that JSON (caw_job_error the message when it fails). */
CAW_API char* caw_render_song(const char* project_json, const char* request_json, int32_t* progress, int32_t* cancel);
CAW_API CawJob* caw_worker_pool_submit_song(CawWorkerPool* pool, const char* project_json, const char* request_json,
                                            int32_t priority);

/* ---- API version 18 (WP-J; docs/engine.md "Audio assets", "Audio clips", "Sampler", "Audio input and recording").
   Audio assets: files decoded (WAV, FLAC, MP3: miniaudio's dr_wav, dr_flac, dr_mp3) and resampled to the engine's
   rate once, shared by every clip and sampler zone that names the same path, within a memory budget (1 GiB by
   default; the least recently used asset nothing plays is dropped first). Decoding a long file takes a while: call
   these from a worker isolate, never the UI or audio thread.
   caw_asset_load: {"ok", "error", "path", "frames", "channels" (1 or 2), "sample_rate" (the engine's), "source_rate",
   "source_channels", "source_frames", "seconds", "bytes"}. Free with caw_free. */
CAW_API char* caw_asset_load(CawEngine* e, const char* path);
/* Waveform overview: [buckets] (1..65536) equal parts of [start_seconds, end_seconds) of the asset's channel
   (0 or 1; 1 on a mono file reads 0), each a (min, max) pair into out_min_max (2 * buckets floats). Loads the file if
   it isn't loaded. Returns the buckets written, or -1 when the file can't be loaded. */
CAW_API int32_t caw_asset_peaks(CawEngine* e, const char* path, double start_seconds, double end_seconds,
                                int32_t buckets, int32_t channel, float* out_min_max);
/* The store: {"bytes", "budget", "count", "assets": [{"path", "rate", "bytes", "in_use"}]}. Free with caw_free. */
CAW_API char* caw_asset_store_status(void);
CAW_API void caw_asset_store_set_budget(int64_t bytes);
/* Drops every asset nothing plays (a project closed). */
CAW_API void caw_asset_store_purge(void);
/* SFZ for org.caw.sampler (docs/engine.md "SFZ support"). Import: {"ok", "error", "zones" (count), "warnings":
   [text], "state": the sampler's state JSON ({"zones": [...]}, sample paths made absolute)}; put the state in the
   instrument entry's "state" (base64) or give it to caw_engine_set_component_state. Export: writes [sfz_path]
   from a state JSON, sample paths relative to its folder where they are inside it; copy_samples copies every
   sample into a "samples" folder beside it first. {"ok", "error", "files": [paths]}. Free with caw_free. */
CAW_API char* caw_sfz_import(const char* sfz_path);
CAW_API char* caw_sfz_export(const char* state_json, const char* sfz_path, int32_t copy_samples);
/* Audio input. The capture devices, as caw_audio_devices lists playback ones, plus "channels" (the most the
   device offers; 0 unknown). On Android the app needs the RECORD_AUDIO permission before input opens. */
CAW_API char* caw_audio_input_devices(void);
/* Opens (enabled != 0) or closes the input: a capture device of its own beside the output (API 26; never duplex),
   whose frames reach the output callback through a lock-free bridge that follows the two clocks' drift; a missing
   input is silence and the output never waits for it. [device_id]/[device_name] as caw_audio_configure (both
   empty: the default input), [channels] 1..32 (0: 2). Only the input opens or closes (the output plays on), and
   the device opens outside the lock caw_audio_status takes. Returns as caw_audio_configure. caw_audio_status gains
   "input": {"enabled", "running", "state" ("off", "open", "stalled", "stopped", "failed"), "device", "device_id",
   "channels", "sample_rate", "period_frames", "duplex_buffer_frames" (the bridge's fill), "latency_frames" (the
   device's own estimate, input plus output buffers plus that fill), "underruns", "dropped_frames",
   "missing_frames" (output frames the input was missing since it first delivered), "drift_ppm", "error"}. */
CAW_API int32_t caw_audio_configure_input(CawEngine* e, int32_t enabled, const char* device_id,
                                          const char* device_name, int32_t channels);
/* Each input channel's peak (0..1+) since the last call; returns the channels written (at most max). */
CAW_API int32_t caw_engine_input_peaks(CawEngine* e, float* out, int32_t max);
/* Recording armed tracks (request JSON: {"dir": an existing folder, "bpm": the tempo (start_steps), "tracks":
   [{"layer", "channel": first input channel from 0, "channels": 1 or 2}], "bits": 32 (float, default) or 24,
   optional "punch_in_steps", "punch_out_steps"}). From the next played chunk, each track's input goes through a
   lock-free ring to a writer thread that writes "<layer>-take<n>.wav" (".wav.part" until the take ends, the header
   counted about every second) and a "<file>.json" sidecar. A take starts where recording (or the punch range)
   begins and ends at a jump: a loop wrap starts the next take, so loop recording gives one take per pass. Takes
   land latency-compensated: frame 0 of a take is the song frame that was heard when it was played
   ("start_frame", "start_steps"; it can be before 0, so trim that much off the clip's offset). Stopping waits for
   the writer to finish. Results: {"ok", "error", "recording", "dropped_frames", "latency": {...}, "takes":
   [{"layer", "path", "take", "start_frame", "start_steps", "frames", "seconds", "channels", "sample_rate", "bpm",
   "complete", "error"}]}. Free each with caw_free. */
CAW_API char* caw_record_start(CawEngine* e, const char* request_json);
CAW_API char* caw_record_stop(CawEngine* e);
CAW_API char* caw_record_status(CawEngine* e);
/* At start-up: finalises takes a crash left in [dir] (".wav.part": the header is fixed to the frames written, the
   file renamed) and lists them as above with "recovered": true. Free with caw_free. */
CAW_API char* caw_record_recover(const char* dir);
/* Recording latency compensation in frames: [frames] >= 0 overrides; -1 uses the last good ping, else the
   device's estimate. caw_engine_input_latency: {"frames", "ms", "source": "override"|"measured"|"device",
   "override", "measured", "device"}. Free with caw_free. */
CAW_API void caw_engine_set_input_latency(CawEngine* e, int64_t frames);
CAW_API char* caw_engine_input_latency(CawEngine* e);
/* A loopback ping: a short noise burst (-12 dBFS) is played and found again in the input (a loopback cable, or
   the speaker into the mic in a quiet room), giving the round trip. Start it (0 if one runs or no engine), then
   poll the result after about a second: {"state": "running"|"idle"} or {"state": "done", "ok", "frames", "ms",
   "confidence"}; an "ok" result becomes the measured latency. Free with caw_free. */
CAW_API int32_t caw_latency_ping_start(CawEngine* e);
CAW_API char* caw_latency_ping_result(CawEngine* e);

/* ---- API version 29 (beta plan C; docs/engine.md "The Benchmark"): the Benchmark (the app's stress test).
   Every run has its own engine and project (the caller's engine is never touched), sheds no layer, and times
   callbacks as caw_bench's suite does. caw_stress_scenarios: {"version": 1, "scenarios": [{"id", "name", "tier":
   "normal"|"heavy"|"extreme"|"idle", "memory_mib"}], "ramps": [{"kind": "tracks"|"voices"|"effects", "counts":
   [...]}], "hold_p99": 1.0}; free it with caw_free. */
CAW_API char* caw_stress_scenarios(void);

enum {
    CAW_STRESS_PLAIN = 0,         /* the scenario for `seconds` */
    CAW_STRESS_RAMP_TRACKS = 1,   /* more tracks (the typical song's, repeated) until a step's p99 callback is over
                                     budget; the last count that held is the limit. `scenario` is ignored */
    CAW_STRESS_RAMP_VOICES = 2,   /* more held Flagship voices (its default patch), up to 64 */
    CAW_STRESS_RAMP_EFFECTS = 3,  /* more effects on one Flagship track, up to 64 */
    CAW_STRESS_SUSTAINED = 4,     /* the scenario for a long `seconds` (the load over time; a rise shows heat) */
    CAW_STRESS_PROFILE = 5        /* the scenario with each component's time (caw_stress_costs) */
};
enum { CAW_STRESS_DSP = 0, CAW_STRESS_LIVE = 1 };

typedef struct CawStressRequest {
    uint32_t struct_size;  /* sizeof(CawStressRequest) */
    const char* scenario;  /* a caw_stress_scenarios id (PLAIN, SUSTAINED, PROFILE) */
    int32_t kind;          /* CAW_STRESS_PLAIN ... */
    int32_t mode;          /* CAW_STRESS_DSP: timed on the worker, repeatable. CAW_STRESS_LIVE (PLAIN and SUSTAINED
                              only): through the default output device, muted, its real callbacks timed; the
                              caller stops its own engine's audio first, since starting this device closes any
                              other engine's (one output per process); while it runs, caw_audio_start on another
                              engine is refused, and a run whose device stops calling back for a second fails */
    double seconds;        /* audio per run, a ramp's per step: 0.05..600 */
    int32_t frames;        /* DSP: the callback size timed, 16..8192 (0: 256). LIVE: the size asked of the device
                              with the low-latency profile (1024: as Auto while not recording; 0: Low latency, the
                              device's own callback sizes) */
    int32_t threads;       /* 0, the only value accepted: PLAIN, SUSTAINED and the ramps run the mix pool on Auto as
                              a live device does (MixPool::defaultWorkers()); PROFILE runs on one thread */
    int32_t quality;       /* the engine's quality (CAW quality 0 Eco, 1 Normal, 2 High) */
    const char* work_dir;  /* an existing folder the run may write two small WAVs into (song8_extras), or NULL */
} CawStressRequest;
/* NULL if the request is refused (struct_size, kind, mode, seconds, frames, threads, quality) or the pool closes.
   caw_job_result is the run's JSON when it succeeds: {"ok", "mode": "dsp"|"live", "kind", "scenario", "frames",
   "sample_rate", "budget_us", "mean_us", "p99_us", "worst_us", "worst_at_s", "mean_first_us", "mean_last_us",
   "mean_pct", "p99_pct", "worst_pct", "callbacks", "over_budget", "dropouts", "xruns", "limit", "first_failed",
   "steps", "seconds", "stop_reason": "done"|"over_budget"|"cancelled"|"error", "error", "callback_core",
   "requested_frames", "warmup_s", "first_callback_us", "slope_pct_per_min", "core_start", "core_end",
   "core_khz_start", "core_khz_end", "core_max_khz", "mix_workers", "mix_active_workers", "warmup_xruns",
   "device_sizes", "budget_basis", "costs": [{"id", "ns", "pct", "ran_pct", "instances", "modulator"}]}. After Play an untimed
   warm-up (0.5 s; 1.7 s with the mix pool, Auto's decision and settle) comes before the timed span; "worst_at_s"
   counts from Play. A cancelled job's error is "cancelled".
   "dropouts": live, the platform's underrun count where it has one (AAudio), else callbacks over budget; DSP,
   callbacks over budget (what would have been dropouts). */
CAW_API CawJob* caw_worker_pool_submit_stress(CawWorkerPool* pool, const CawStressRequest* request, int32_t priority);

typedef struct CawStressProgress {
    uint32_t struct_size;  /* sizeof(CawStressProgress) */
    int32_t permille;      /* 0..1000 of the whole run */
    int32_t step;          /* ramps: steps run */
    int32_t count;         /* ramps: the count the current step plays */
    int32_t held;          /* ramps: the largest count that held so far */
    float load;            /* the last 100 ms's load, a share of the budget (1 = all of it) */
    int64_t callbacks;     /* timed so far */
    int64_t over_budget;   /* of them, over budget */
} CawStressProgress;
/* Any thread, while the job runs or after: 0 on success, 1 not a stress job, 2 struct_size too small. */
CAW_API int32_t caw_stress_progress(CawJob* job, CawStressProgress* out);
/* The load every 100 ms of audio (a share of the budget), from point `from` on: copies at most `max` into out
   (the oldest still kept first; 8192 are kept) and sets *next to the point after the last copied. Returns the
   count, or -1 if not a stress job. Poll it with the last *next. */
CAW_API int32_t caw_stress_history(CawJob* job, uint32_t from, float* out, int32_t max, uint32_t* next);

typedef struct CawStressResult {
    uint32_t struct_size;  /* sizeof(CawStressResult) */
    int32_t ok;
    int32_t mode;          /* CAW_STRESS_DSP or CAW_STRESS_LIVE */
    int32_t frames;        /* the callback size timed (live: the device's) */
    int32_t sample_rate;
    int32_t limit;         /* ramps: the last count that held (0 none; -1 not a ramp) */
    int32_t first_failed;  /* ramps: the smallest count over budget (-1 none) */
    int32_t steps;
    int32_t xruns;         /* live: the platform's underruns during the run (-1 unknown) */
    int32_t callback_core; /* live: the core the last callback ran on (-1 unknown) */
    double budget_us, mean_us, p99_us, worst_us, worst_at_s, mean_first_us, mean_last_us;
    double seconds;        /* audio timed */
    int64_t callbacks;
    int64_t over_budget;
    int64_t dropouts;      /* as the result JSON's "dropouts" */
    char stop_reason[16];  /* "done", "over_budget", "cancelled", "error" */
    char error[256];
} CawStressResult;
/* Once the job has finished (any state): 0 and the result; 1 not a stress job; 2 struct_size too small; 3 not
   finished yet. */
CAW_API int32_t caw_stress_result(CawJob* job, CawStressResult* out);

typedef struct CawStressCost {
    char id[64];           /* a component id, or "host" (everything Engine::process does outside components) */
    uint64_t ns;           /* per callback */
    float pct;             /* of the whole callback */
    float ran_pct;         /* of the blocks it was in, the share it processed (the rest it slept) */
    int32_t instances;
    int32_t modulator;     /* 1: a project modulator */
} CawStressCost;
/* A finished PROFILE job's costs, largest first: writes at most `max` and returns how many there are (so a call
   with max 0 sizes the array); -1 if not a stress job or not finished. */
CAW_API int32_t caw_stress_costs(CawJob* job, CawStressCost* out, int32_t max);

#ifdef __cplusplus
}
#endif
#endif /* CAW_H */
