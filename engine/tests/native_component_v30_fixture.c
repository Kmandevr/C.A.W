/* Test components in plain C: entry 0 is built as against the 3.0 interface (its descriptor ends at
   custom_ui_id), entry 1 is a 3.1 instrument that reads the voice bus (CawProcessBlock.voices). */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "caw_component.h"

#if defined(_WIN32)
#define FIXTURE_EXPORT __declspec(dllexport)
#else
#define FIXTURE_EXPORT __attribute__((visibility("default")))
#endif

static int dummy;

static void* create(const CawHost* host) {
    (void)host;
    return &dummy;
}
static void destroy(void* instance) { (void)instance; }
static int32_t activate(void* instance, double sample_rate, uint32_t max_frames) {
    (void)instance;
    (void)sample_rate;
    return max_frames > 0 ? 1 : 0;
}
static void deactivate(void* instance) { (void)instance; }
static void reset(void* instance) { (void)instance; }
static int32_t save_state(void* instance, uint8_t* destination, uint32_t capacity, uint32_t* written, uint32_t* version) {
    (void)instance;
    (void)destination;
    (void)capacity;
    *written = 0;
    *version = 1;
    return 1;
}
static int32_t load_state(void* instance, const uint8_t* source, uint32_t size, uint32_t version) {
    (void)instance;
    (void)source;
    return size == 0 && version == 1 ? 1 : 0;
}
static const void* get_extension(void* instance, const char* id) {
    (void)instance;
    (void)id;
    return NULL;
}

/* Entry 0: a stereo pass-through at half gain. */
static int32_t process_half(void* instance, const CawProcessBlock* block) {
    uint32_t c, i;
    (void)instance;
    if (!block || block->audio_in_count != 1 || block->audio_out_count != 1) return 0;
    for (c = 0; c < 2; ++c)
        for (i = 0; i < block->frames; ++i) block->audio_out[0].channels[c][i] = 0.5f * block->audio_in[0].channels[c][i];
    return 1;
}
static const CawPortInfo kEffectPorts[] = {
    {"in", CAW_PORT_AUDIO, CAW_LAYOUT_STEREO, 0, 1, 0, 0.0f},
    {"out", CAW_PORT_AUDIO, CAW_LAYOUT_STEREO, 0, 0, 0, 0.0f},
};
/* The 3.1 fields hold values a 3.1 host would refuse (an unknown domain bit): a host that read them past
   struct_size would fail to load this component. */
static const CawComponentDescriptor kOld = {
    0 /* struct_size: set in the entry */, CAW_COMPONENT_ABI_VERSION, "org.caw.test.v30", "Old half", 1, CAW_ROLE_EFFECT,
    0, 0, 0, 2, sizeof(CawPortInfo), kEffectPorts, 0, sizeof(CawParameterInfo), NULL, 0, sizeof(CawUiControlInfo), NULL,
    NULL, 0xFFu, 0xFFFFu, 77u, 0u};

/* Entry 1: an instrument that renders 0.25 on every assigned lane, runs the host, then adds the lanes to its
   output; with no bus it writes 0.25 to its output. */
static int32_t process_lanes(void* instance, const CawProcessBlock* block) {
    uint32_t c, i, k;
    const CawVoiceBus* bus = NULL;
    (void)instance;
    if (!block || block->audio_out_count != 1) return 0;
    if (block->struct_size >= offsetof(CawProcessBlock, voices) + sizeof(block->voices)) bus = block->voices;
    if (!bus) {
        for (c = 0; c < 2; ++c)
            for (i = 0; i < block->frames; ++i) block->audio_out[0].channels[c][i] = 0.25f;
        return 1;
    }
    for (c = 0; c < 2; ++c)
        for (i = 0; i < block->frames; ++i) block->audio_out[0].channels[c][i] = 0.0f;
    for (k = 0; k < bus->lane_count; ++k) {
        CawVoiceLane* lane = (CawVoiceLane*)((unsigned char*)bus->lanes + (size_t)bus->lane_stride * k);
        if (!(lane->flags & CAW_LANE_ASSIGNED)) continue;
        for (c = 0; c < 2; ++c)
            for (i = 0; i < block->frames; ++i) lane->channels[c][i] = 0.25f;
        lane->flags |= CAW_LANE_WRITTEN;
    }
    bus->run(bus->host_data, 0, block->frames);
    for (k = 0; k < bus->lane_count; ++k) {
        CawVoiceLane* lane = (CawVoiceLane*)((unsigned char*)bus->lanes + (size_t)bus->lane_stride * k);
        if (!(lane->flags & CAW_LANE_ASSIGNED)) continue;
        for (c = 0; c < 2; ++c)
            for (i = 0; i < block->frames; ++i) block->audio_out[0].channels[c][i] += lane->channels[c][i];
    }
    return 1;
}
static const CawPortInfo kInstrumentPorts[] = {
    {"notes", CAW_PORT_EVENT, CAW_LAYOUT_NONE, 0, 1, 1, 0.0f},
    {"out", CAW_PORT_AUDIO, CAW_LAYOUT_STEREO, 0, 0, 0, 0.0f},
};
static const CawComponentDescriptor kLanes = {
    sizeof(CawComponentDescriptor), CAW_COMPONENT_ABI_VERSION, "org.caw.test.lanes", "Lanes", 1, CAW_ROLE_INSTRUMENT,
    0, 0, 0, 2, sizeof(CawPortInfo), kInstrumentPorts, 0, sizeof(CawParameterInfo), NULL, 0, sizeof(CawUiControlInfo),
    NULL, NULL, CAW_DOMAIN_WHOLE | CAW_DOMAIN_PER_NOTE, CAW_CAPABILITY_NOTES_IN, CAW_CPU_LIGHT, 0u};

static CawComponentDescriptor oldDescriptor;
static CawComponentV3 tables[2];

FIXTURE_EXPORT const CawComponentV3* caw_get_component_v3(uint32_t index) {
    uint32_t k;
    if (index > 1) return NULL;
    oldDescriptor = kOld;
    oldDescriptor.struct_size = CAW_COMPONENT_DESCRIPTOR_SIZE_3_0;
    for (k = 0; k < 2; ++k) {
        CawComponentV3* t = &tables[k];
        t->struct_size = sizeof(CawComponentV3);
        t->abi_version = CAW_COMPONENT_ABI_VERSION;
        t->descriptor = k == 0 ? &oldDescriptor : &kLanes;
        t->create = create;
        t->destroy = destroy;
        t->activate = activate;
        t->deactivate = deactivate;
        t->reset = reset;
        t->process = k == 0 ? process_half : process_lanes;
        t->save_state = save_state;
        t->load_state = load_state;
        t->get_extension = get_extension;
    }
    return &tables[index];
}
