/* C.A.W component interface v3 (revision 3.1): the stable C boundary between the host and a compiled component.
 *
 * Plain C: no C++ types, exceptions or STL cross it, so a component built with one compiler or C++
 * standard library loads into a host built with another. Component authors normally write C++
 * against caw/module.hpp and export with CAW_EXPORT_COMPONENT (caw/component.hpp), which builds
 * these structs; hosts read only this header.
 *
 * Growth rules (so new fields need no v3):
 * - Every top-level struct starts with struct_size. A reader accepts struct_size >= the size it
 *   knows and ignores what follows; it refuses a smaller one.
 * - Arrays of ports, parameters and UI controls are read with the strides the descriptor gives
 *   (port_info_size, ...), each at least the sizeof() in this header; extra trailing fields are
 *   ignored.
 * - Fields appended to a struct under these rules raise CAW_COMPONENT_ABI_REVISION (3.0, then 3.1), not
 *   CAW_COMPONENT_ABI_VERSION: the entry symbol and every older component keep working. Each appended field
 *   says the revision it arrived in; a reader reads it only when struct_size covers it, and otherwise uses the
 *   default it documents.
 * - New capabilities arrive as extensions: CawHost.get_extension (host to component) and
 *   CawComponentV3.get_extension (component to host), each looked up by a string id. An unknown id
 *   returns NULL.
 *
 * Threads:
 * - The host calls create, activate, deactivate, save_state, load_state, get_extension and destroy
 *   on a control thread, never concurrently for one instance.
 * - process and reset run on the audio thread, only between activate and deactivate, and never at
 *   the same time as a control-thread call on the same instance, except save_state: the host may
 *   save state while the instance processes (to store a playing project), so a component that
 *   keeps state makes save_state safe against process (as CLAP plugins do).
 * - process must not allocate, lock, block or do I/O. A component allocates in create or activate.
 *
 * Bundles: one library may export several components through the same entry point, by index.
 *
 * Return codes: process, activate, save_state and load_state return 1 for success and 0 for failure.
 * A process that fails leaves its outputs undefined; the host substitutes its own (the master chain
 * passes the input through). */
#ifndef CAW_COMPONENT_H
#define CAW_COMPONENT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CAW_COMPONENT_ABI_VERSION 3u
#define CAW_COMPONENT_ENTRY_SYMBOL "caw_get_component_v3"
/* 0: the v3 structs as first shipped. 1 (3.1, 2026-11-11, #120 and #127): CawComponentDescriptor.domains,
   capabilities and cpu_class; CawProcessBlock.voices (the voice bus, CawVoiceBus). */
#define CAW_COMPONENT_ABI_REVISION 1u

/* Numeric values match the C++ enums in caw/module.hpp (checked there with static_assert). */
enum {
    CAW_PORT_AUDIO = 0,
    CAW_PORT_CONTROL = 1,
    CAW_PORT_MODULATION = 2,
    CAW_PORT_EVENT = 3
};
enum {
    CAW_LAYOUT_NONE = 0,
    CAW_LAYOUT_MONO = 1,
    CAW_LAYOUT_STEREO = 2,
    CAW_LAYOUT_QUAD = 3,
    CAW_LAYOUT_SURROUND_5_1 = 4,
    CAW_LAYOUT_SURROUND_7_1 = 5,
    CAW_LAYOUT_DISCRETE = 6 /* channel_count gives the count */
};
enum {
    CAW_ROLE_UNSPECIFIED = 0,
    CAW_ROLE_INSTRUMENT = 1,
    CAW_ROLE_GENERATOR = 2,
    CAW_ROLE_EFFECT = 3,
    CAW_ROLE_UTILITY = 4,
    CAW_ROLE_EVENT_PROCESSOR = 5,
    CAW_ROLE_ANALYZER = 6
};
enum { CAW_CURVE_LINEAR = 0, CAW_CURVE_EXPONENTIAL = 1 };
enum {
    CAW_UI_SLIDER = 0,
    CAW_UI_TOGGLE = 1,
    CAW_UI_DROPDOWN = 2,
    CAW_UI_XY_PAD = 3,
    CAW_UI_BUTTON = 4,
    CAW_UI_CURVE = 5
};
enum { CAW_EVENT_NOTE = 0, CAW_EVENT_MIDI = 1 };

/* CawParameterInfo.flags */
#define CAW_PARAMETER_AUTOMATABLE 1u
#define CAW_PARAMETER_MODULATABLE 2u
#define CAW_PARAMETER_MIDI_MAPPABLE 4u

#define CAW_INFINITE_TAIL 0xFFFFFFFFu

/* CawComponentDescriptor.domains (3.1, #120): where a host may run the component. CAW_DOMAIN_WHOLE is always set.
   PER_CHANNEL: a mono-in, mono-out effect run once per channel (dual mono). PER_NOTE (and PER_VOICE, the same in
   this host): an effect with one stereo input and one stereo output may run once per note; an instrument (no
   audio input, one stereo output, an event input) reads the voice bus (CawProcessBlock.voices). 0, or a
   descriptor older than 3.1, reads as CAW_DOMAIN_WHOLE. */
#define CAW_DOMAIN_WHOLE 1u
#define CAW_DOMAIN_PER_CHANNEL 2u
#define CAW_DOMAIN_PER_VOICE 4u
#define CAW_DOMAIN_PER_NOTE 8u
/* CawComponentDescriptor.capabilities (3.1): what the component needs or offers. NOTES_IN and MIDI_IN need an
   event input, EVENTS_OUT an event output. */
#define CAW_CAPABILITY_NOTES_IN 1u
#define CAW_CAPABILITY_MIDI_IN 2u
#define CAW_CAPABILITY_EVENTS_OUT 4u
#define CAW_CAPABILITY_SAMPLE_ASSETS 8u
#define CAW_CAPABILITY_NEEDS_TRANSPORT 16u
#define CAW_CAPABILITY_EXPORT_CLAP 32u
/* CawComponentDescriptor.cpu_class (3.1): a rough cost hint. */
enum { CAW_CPU_UNSPECIFIED = 0, CAW_CPU_LIGHT = 1, CAW_CPU_MEDIUM = 2, CAW_CPU_HEAVY = 3 };

/* Strings are UTF-8, NUL-terminated, owned by the component and valid while its library is loaded.
 * NULL means empty. */
typedef struct CawPortInfo {
    const char* id;
    uint32_t type;          /* CAW_PORT_* */
    uint32_t layout;        /* CAW_LAYOUT_*; NONE for non-audio ports */
    uint32_t channel_count; /* Discrete only; 0 otherwise */
    uint32_t is_input;      /* 1 input, 0 output */
    uint32_t summing;       /* 1: accepts several connections (audio/modulation summed, events merged) */
    float default_value;    /* control ports: the value an unconnected input reads */
} CawPortInfo;

typedef struct CawParameterInfo {
    const char* id;
    const char* name; /* display name */
    const char* unit; /* display only */
    double default_value;
    double minimum;
    double maximum;
    double step;               /* > 0: snaps to minimum + k * step; 0: continuous */
    uint32_t curve;            /* CAW_CURVE_* */
    uint32_t smoothing_frames; /* a manual or MIDI change ramps over this many frames */
    uint32_t flags;            /* CAW_PARAMETER_* */
    uint32_t choice_count;     /* labels for minimum, minimum + 1, ..., maximum; 0: numeric */
    const char* const* choices;
} CawParameterInfo;

typedef struct CawUiControlInfo {
    const char* id;
    const char* label;
    const char* parameter_id; /* NULL or empty: an action-only control */
    uint32_t kind;            /* CAW_UI_* */
    double minimum;
    double maximum;
} CawUiControlInfo;

typedef struct CawComponentDescriptor {
    uint32_t struct_size;
    uint32_t abi_version; /* CAW_COMPONENT_ABI_VERSION */
    const char* id;       /* stable, unique, reverse-DNS style */
    const char* name;
    uint32_t version;     /* the component's own version, at least 1 */
    uint32_t role;        /* CAW_ROLE_* */
    uint32_t latency_frames;
    uint32_t tail_frames; /* or CAW_INFINITE_TAIL */
    uint32_t max_state_bytes;
    uint32_t port_count;
    uint32_t port_info_size; /* stride of ports, >= sizeof(CawPortInfo) */
    const CawPortInfo* ports;
    uint32_t parameter_count;
    uint32_t parameter_info_size; /* >= sizeof(CawParameterInfo) */
    const CawParameterInfo* parameters;
    uint32_t ui_control_count;
    uint32_t ui_control_info_size; /* >= sizeof(CawUiControlInfo) */
    const CawUiControlInfo* ui_controls;
    const char* custom_ui_id;
    /* 3.1 (#120). Read only when struct_size covers them; an older descriptor (CAW_COMPONENT_DESCRIPTOR_SIZE_3_0)
       reads as domains CAW_DOMAIN_WHOLE, capabilities 0, cpu_class CAW_CPU_UNSPECIFIED. */
    uint32_t domains;      /* CAW_DOMAIN_* bits */
    uint32_t capabilities; /* CAW_CAPABILITY_* bits */
    uint32_t cpu_class;    /* CAW_CPU_* */
    uint32_t reserved;     /* 0 */
} CawComponentDescriptor;
/* The smallest descriptor a host accepts: the 3.0 struct, up to custom_ui_id. */
#define CAW_COMPONENT_DESCRIPTOR_SIZE_3_0 ((uint32_t)offsetof(CawComponentDescriptor, domains))

/* Process block. Every pointer is borrowed for this call only; never keep it. Lists are per port
 * type, each in descriptor order (the k-th audio input is the k-th input port of type audio). */
typedef struct CawConstAudio {
    const float* const* channels;
    uint32_t channel_count;
    uint32_t frames; /* per-channel capacity, at least the block's frames */
} CawConstAudio;
typedef struct CawAudio {
    float* const* channels;
    uint32_t channel_count;
    uint32_t frames;
} CawAudio;
/* One timed event: frame offset in the block, raw MIDI 2.0 UMP words, a host-assigned note id. */
typedef struct CawEvent {
    uint32_t frame;
    uint16_t kind; /* CAW_EVENT_* */
    uint16_t flags; /* reserved, 0 */
    uint32_t note_id;
    uint32_t data[4];
} CawEvent;
typedef struct CawEventInput {
    const CawEvent* events;
    uint32_t count; /* frames non-decreasing, each below the block's frames */
} CawEventInput;
typedef struct CawEventOutput {
    CawEvent* events;
    uint32_t capacity;
    uint32_t count; /* the host sets it to 0; the component writes up to capacity, in frame order */
} CawEventOutput;
typedef struct CawParameterValue {
    const double* samples; /* NULL: value holds for every frame */
    double value;
} CawParameterValue;

/* The host's transport for a block, as a CLAP host gives it: tempo and position, so a component can
 * sync to the song (a tempo-synced delay, an LFO). */
#define CAW_TRANSPORT_PLAYING 1u
typedef struct CawTransport {
    uint32_t struct_size;
    uint32_t flags;          /* CAW_TRANSPORT_* */
    double tempo;            /* beats (quarter notes) per minute */
    double beat;             /* song position of the block's first frame, in beats */
    uint32_t beats_per_bar;
    uint32_t reserved;       /* 0 */
} CawTransport;

/* The voice bus (3.1, #127): per-note FX lanes an instrument that declares CAW_DOMAIN_PER_NOTE renders into.
 * The host owns every lane and buffer; it sets each lane's note_id and flags (CAW_LANE_ASSIGNED, the out bits
 * clear) before each process call. channels[c] holds at least the block's frames, frame 0 being the block's
 * first frame.
 * The instrument, for each stretch [offset, offset + frames) it renders (a control period, say):
 * 1. clears that stretch of every ASSIGNED lane;
 * 2. renders each voice whose note id matches an ASSIGNED lane into that lane (and sets CAW_LANE_WRITTEN on it)
 *    instead of its mix; a voice with no lane goes to its mix as before;
 * 3. calls run(host_data, offset, frames): the host processes the lanes' stretch in place (on the audio thread;
 *    it never allocates, locks or blocks);
 * 4. adds every ASSIGNED lane's stretch into its mix, in lane order, BEFORE its own shared stage (its effects,
 *    its volume), so per-note FX sit between the voices and the instrument's shared sound.
 * Every frame of the block is covered by exactly one run() call, in order, also while the instrument has no
 * voice (a lane's FX tail). An instrument sets CAW_LANE_ENDED on a lane whose note no voice plays at the end of
 * the block (the note finished, was stolen or never started); the host then lets the lane's FX ring out and
 * frees it. A mono or legato voice renders into the lane of the note it plays now. A host that has no lanes for
 * a block passes voices NULL, and the instrument renders exactly as it would without a bus. */
#define CAW_LANE_ASSIGNED 1u /* host: the lane is in use for note_id */
#define CAW_LANE_WRITTEN 2u  /* instrument: a voice rendered into the lane in this block */
#define CAW_LANE_ENDED 4u    /* instrument: no voice plays note_id at the end of this block */
/* host (3.1, #127 step 4): the overflow lane. Every voice whose note has no lane of its own renders here (note_id
 * is 0); the host runs its shared per-note chain over them. An instrument that doesn't know this bit sees a lane
 * no voice matches and renders those voices into its mix, as before. Never ENDED. */
#define CAW_LANE_REST 8u
typedef struct CawVoiceLane {
    uint32_t struct_size;
    uint32_t note_id;       /* the host note id (CawEvent.note_id) */
    uint32_t flags;         /* CAW_LANE_* */
    uint32_t channel_count; /* 2 */
    float* channels[2];
} CawVoiceLane;
typedef struct CawVoiceBus {
    uint32_t struct_size;
    uint32_t lane_count;
    uint32_t lane_stride; /* bytes from one lane to the next, >= sizeof(CawVoiceLane) */
    CawVoiceLane* lanes;
    void* host_data;
    void (*run)(void* host_data, uint32_t offset, uint32_t frames);
} CawVoiceBus;

typedef struct CawProcessBlock {
    uint32_t struct_size;
    uint32_t frames;
    double sample_rate;
    const CawConstAudio* audio_in;
    uint32_t audio_in_count;
    const CawAudio* audio_out;
    uint32_t audio_out_count;
    const float* const* modulation_in; /* `frames` floats each */
    uint32_t modulation_in_count;
    float* const* modulation_out;
    uint32_t modulation_out_count;
    const float* const* control_in; /* one value each, read as *control_in[k] */
    uint32_t control_in_count;
    float* const* control_out;
    uint32_t control_out_count;
    const CawEventInput* event_in;
    uint32_t event_in_count;
    CawEventOutput* event_out;
    uint32_t event_out_count;
    const CawParameterValue* parameters; /* descriptor order */
    uint32_t parameter_count;
    /* NULL when there is none (stopped, or a host without one). Read it only when struct_size covers it. */
    const CawTransport* transport;
    /* 3.1 (#127): the voice bus, or NULL. Read it only when struct_size covers it. */
    const CawVoiceBus* voices;
} CawProcessBlock;

typedef struct CawHost {
    uint32_t struct_size;
    uint32_t abi_version;
    const char* name;    /* "C.A.W" */
    const char* version; /* the host's version text */
    void* host_data;     /* passed back to get_extension */
    const void* (*get_extension)(const struct CawHost* host, const char* id); /* NULL if unknown */
} CawHost;

typedef struct CawComponentV3 {
    uint32_t struct_size;
    uint32_t abi_version;
    const CawComponentDescriptor* descriptor;
    /* Returns a new instance, or NULL. `host` stays valid until destroy. */
    void* (*create)(const CawHost* host);
    void (*destroy)(void* instance);
    /* Prepare for processing at this sample rate with blocks of at most max_frames. The host
     * calls deactivate before a second activate and before destroy. */
    int32_t (*activate)(void* instance, double sample_rate, uint32_t max_frames);
    void (*deactivate)(void* instance);
    void (*reset)(void* instance);
    int32_t (*process)(void* instance, const CawProcessBlock* block);
    /* State: save writes at most max_state_bytes, its byte count to *written and its format
     * version to *version; load gets a saved state back with that version. */
    int32_t (*save_state)(void* instance, uint8_t* destination, uint32_t capacity, uint32_t* written,
                          uint32_t* version);
    int32_t (*load_state)(void* instance, const uint8_t* source, uint32_t size, uint32_t version);
    const void* (*get_extension)(void* instance, const char* id); /* NULL if unknown */
} CawComponentV3;

/* Extension CAW_EXTENSION_QUIET (CawComponentV3.get_extension, asked once per instance after create): a
 * component that knows when it has fallen silent says so, and the host may skip its process calls while it
 * stays that way. quiet() runs on the audio thread right after a process that returned 1, and returns 1 when the
 * output from then on is silence until an event arrives or an audio input is not silent (whatever the
 * parameters and the transport do), else 0. A skipped component's time does not move. */
#define CAW_EXTENSION_QUIET "caw.quiet.v1"
typedef struct CawQuietExtension {
    uint32_t struct_size;
    int32_t (*quiet)(void* instance);
} CawQuietExtension;

/* Extension CAW_EXTENSION_DISPLAY (CawComponentV3.get_extension, asked once per instance after create): live
 * display data for the component's UI (#173), such as a spectrum, gain reduction or levels. read() copies the
 * latest block of floats the component published into destination (at most capacity floats) and returns how
 * many it copied, 0 when it has none. The host calls it from a thread that is not the audio thread, at any time
 * between create and destroy, while process may run on the audio thread: it must never block, lock or allocate
 * (the C++ SDK's caw::DisplayBuffer, caw/display.hpp, is a double-buffered seqlock that does this). max_floats is
 * the most read ever returns. The layout of the floats is the component's own. */
#define CAW_EXTENSION_DISPLAY "caw.display.v1"
typedef struct CawDisplayExtension {
    uint32_t struct_size;
    uint32_t max_floats;
    uint32_t (*read)(void* instance, float* destination, uint32_t capacity);
} CawDisplayExtension;

/* The one symbol a component library exports. A library may hold several components (a bundle):
   index 0, 1, ... returns each, and NULL past the last. Hosts stop at the first NULL. */
typedef const CawComponentV3* (*CawGetComponentV3Fn)(uint32_t index);

#ifdef __cplusplus
}
#endif
#endif
