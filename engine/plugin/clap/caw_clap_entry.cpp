// CLAP wrapper: exposes every C.A.W component of the library it is linked into as a CLAP plug-in.
//
// Built by caw_add_clap_plugin (engine/cmake/CAWClap.cmake) together with a component's own sources,
// so the component's caw_get_component_v3 entry (caw_component.h) is linked in statically and this
// file exports the one symbol a CLAP host looks for, clap_entry. It reads the component only through
// the plain-C interface, like any other C.A.W host.
//
// Mapping (docs/native-module-sdk.md, "Export as a CLAP plug-in"):
// - factory: one CLAP plug-in per component of the bundle, in bundle order, id = component id;
// - audio ports: the component's audio ports with their channel counts (first of each side is main);
// - note ports: one per event port. CLAP notes and MIDI become CawEvents (MIDI 2.0 UMP words) with
//   note ids, and the component's output events become CLAP notes, MIDI or MIDI 2 events;
// - params: id = a stable hash of the parameter id, plain ranges, stepped/enum for steps and choices,
//   value text with the unit. Values change sample-accurately (per-frame values while a change ramps
//   over the parameter's smoothing frames, as the C.A.W engine does for a manual change);
// - state: a small versioned blob holding the parameter values and the component's own state;
// - latency, tail, transport (only while playing, as the C.A.W contract says).
// Control and modulation ports have no CLAP equivalent: inputs read their default (control) or 0
// (modulation) and outputs go to scratch buffers.
//
// Threads follow CLAP: process, reset and (while active) flush on the audio thread, the rest on the
// main thread. process never allocates, locks or does I/O; everything is allocated in activate.
#include <clap/clap.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <new>
#include <string>
#include <thread>
#include <vector>

#include <caw_component.h>

// Defined by the component's CAW_EXPORT_COMPONENT / CAW_EXPORT_COMPONENTS (caw/component.hpp).
extern "C" const CawComponentV3* caw_get_component_v3(uint32_t index);

// Plug-in metadata from caw_add_clap_plugin; empty means "not given".
#ifndef CAW_CLAP_VENDOR
#define CAW_CLAP_VENDOR ""
#endif
#ifndef CAW_CLAP_URL
#define CAW_CLAP_URL ""
#endif
#ifndef CAW_CLAP_VERSION
#define CAW_CLAP_VERSION ""
#endif
#ifndef CAW_CLAP_DESCRIPTION
#define CAW_CLAP_DESCRIPTION ""
#endif

namespace {

constexpr uint32_t kMaxComponents = 256;       // bundle entries read
constexpr uint32_t kMaxPorts = 256;
constexpr uint32_t kMaxParameters = 4096;
constexpr uint32_t kMaxChannels = 64;          // caw::kMaxPortChannels
constexpr uint32_t kMaxChunkFrames = 4096;     // longer host blocks are processed in pieces
constexpr uint32_t kEventCapacity = 1024;      // events per event port per piece; more are dropped
constexpr uint32_t kParamEventCapacity = 4096; // timed parameter changes per piece; more apply at once
constexpr uint32_t kStateMagic = 0x53574143u;  // "CAWS" little-endian
constexpr uint32_t kStateFormat = 1;
constexpr uint64_t kMaxStateBlob = 64ull << 20;

// ---- Reading the component descriptor (strides from the descriptor, caw_component.h growth rules)

const CawPortInfo& portAt(const CawComponentDescriptor& d, uint32_t k) {
    return *reinterpret_cast<const CawPortInfo*>(reinterpret_cast<const char*>(d.ports) + size_t(k) * d.port_info_size);
}
const CawParameterInfo& parameterAt(const CawComponentDescriptor& d, uint32_t k) {
    return *reinterpret_cast<const CawParameterInfo*>(reinterpret_cast<const char*>(d.parameters) +
                                                      size_t(k) * d.parameter_info_size);
}
uint32_t channelsOf(const CawPortInfo& p) {
    switch (p.layout) {
        case CAW_LAYOUT_MONO: return 1;
        case CAW_LAYOUT_STEREO: return 2;
        case CAW_LAYOUT_QUAD: return 4;
        case CAW_LAYOUT_SURROUND_5_1: return 6;
        case CAW_LAYOUT_SURROUND_7_1: return 8;
        case CAW_LAYOUT_DISCRETE: return p.channel_count;
        default: return 0;
    }
}
const char* text(const char* s) { return s ? s : ""; }

bool tableUsable(const CawComponentV3* t) {
    if (!t || t->struct_size < sizeof(CawComponentV3) || t->abi_version != CAW_COMPONENT_ABI_VERSION) return false;
    if (!t->create || !t->destroy || !t->activate || !t->deactivate || !t->reset || !t->process || !t->save_state ||
        !t->load_state)
        return false;
    const CawComponentDescriptor* d = t->descriptor;
    if (!d || d->struct_size < sizeof(CawComponentDescriptor) || d->abi_version != CAW_COMPONENT_ABI_VERSION) return false;
    if (!d->id || !d->id[0] || d->port_count > kMaxPorts || d->parameter_count > kMaxParameters) return false;
    if (d->port_count && (!d->ports || d->port_info_size < sizeof(CawPortInfo))) return false;
    if (d->parameter_count && (!d->parameters || d->parameter_info_size < sizeof(CawParameterInfo))) return false;
    for (uint32_t k = 0; k < d->port_count; ++k) {
        const CawPortInfo& p = portAt(*d, k);
        if (p.type == CAW_PORT_AUDIO && (channelsOf(p) == 0 || channelsOf(p) > kMaxChannels)) return false;
        if (p.type > CAW_PORT_EVENT) return false;
    }
    for (uint32_t k = 0; k < d->parameter_count; ++k) {
        const CawParameterInfo& p = parameterAt(*d, k);
        if (!p.id || !p.id[0] || !std::isfinite(p.minimum) || !std::isfinite(p.maximum) || !(p.maximum >= p.minimum) ||
            !std::isfinite(p.default_value))
            return false;
        if (p.choice_count && !p.choices) return false;
    }
    return true;
}

// FNV-1a: a parameter's CLAP id comes from its stable C.A.W id, so reordering parameters in a new
// version keeps automation. A collision moves to the next free id, in descriptor order.
uint32_t hashId(const char* s) {
    uint32_t h = 2166136261u;
    for (; *s; ++s) h = (h ^ static_cast<unsigned char>(*s)) * 16777619u;
    return h == CLAP_INVALID_ID ? 0u : h;
}

// ---- The bundle, read once at clap_entry.init

struct Entry {
    const CawComponentV3* table = nullptr;
    std::string id, name, version;
    std::vector<const char*> features;
    std::vector<clap_id> paramIds;  // descriptor order
    clap_plugin_descriptor_t desc{};
};

struct Bundle {
    std::vector<std::unique_ptr<Entry>> entries;
    int refs = 0;
};
Bundle& bundle() {
    static Bundle b;
    return b;
}

void describe(Entry& e) {
    const CawComponentDescriptor& d = *e.table->descriptor;
    e.id = d.id;
    e.name = d.name && d.name[0] ? d.name : d.id;
    e.version = CAW_CLAP_VERSION[0] ? std::string(CAW_CLAP_VERSION) : std::to_string(d.version);
    bool audioIn = false, audioOut = false, eventIn = false, eventOut = false, mono = false, stereo = false;
    for (uint32_t k = 0; k < d.port_count; ++k) {
        const CawPortInfo& p = portAt(d, k);
        if (p.type == CAW_PORT_AUDIO) {
            (p.is_input ? audioIn : audioOut) = true;
            mono = mono || p.layout == CAW_LAYOUT_MONO;
            stereo = stereo || p.layout == CAW_LAYOUT_STEREO;
        }
        if (p.type == CAW_PORT_EVENT) (p.is_input ? eventIn : eventOut) = true;
    }
    // The main category by role, else by ports.
    switch (d.role) {
        case CAW_ROLE_INSTRUMENT: e.features.push_back(CLAP_PLUGIN_FEATURE_INSTRUMENT); break;
        case CAW_ROLE_GENERATOR:
            e.features.push_back(audioIn ? CLAP_PLUGIN_FEATURE_AUDIO_EFFECT : CLAP_PLUGIN_FEATURE_INSTRUMENT);
            break;
        case CAW_ROLE_EFFECT: e.features.push_back(CLAP_PLUGIN_FEATURE_AUDIO_EFFECT); break;
        case CAW_ROLE_UTILITY:
            e.features.push_back(CLAP_PLUGIN_FEATURE_AUDIO_EFFECT);
            e.features.push_back(CLAP_PLUGIN_FEATURE_UTILITY);
            break;
        case CAW_ROLE_EVENT_PROCESSOR: e.features.push_back(CLAP_PLUGIN_FEATURE_NOTE_EFFECT); break;
        case CAW_ROLE_ANALYZER:
            e.features.push_back(CLAP_PLUGIN_FEATURE_ANALYZER);
            if (audioIn) e.features.push_back(CLAP_PLUGIN_FEATURE_AUDIO_EFFECT);
            break;
        default:
            if (audioIn) e.features.push_back(CLAP_PLUGIN_FEATURE_AUDIO_EFFECT);
            else if (eventIn && audioOut) e.features.push_back(CLAP_PLUGIN_FEATURE_INSTRUMENT);
            else if (eventIn || eventOut) e.features.push_back(CLAP_PLUGIN_FEATURE_NOTE_EFFECT);
            else e.features.push_back(CLAP_PLUGIN_FEATURE_INSTRUMENT);
            break;
    }
    if (stereo) e.features.push_back(CLAP_PLUGIN_FEATURE_STEREO);
    if (mono) e.features.push_back(CLAP_PLUGIN_FEATURE_MONO);
    e.features.push_back(nullptr);

    for (uint32_t k = 0; k < d.parameter_count; ++k) {
        clap_id id = hashId(parameterAt(d, k).id);
        while (std::find(e.paramIds.begin(), e.paramIds.end(), id) != e.paramIds.end())
            id = (id + 1 == CLAP_INVALID_ID) ? 0 : id + 1;
        e.paramIds.push_back(id);
    }

    e.desc.clap_version = CLAP_VERSION_INIT;
    e.desc.id = e.id.c_str();
    e.desc.name = e.name.c_str();
    e.desc.vendor = CAW_CLAP_VENDOR;
    e.desc.url = CAW_CLAP_URL;
    e.desc.manual_url = "";
    e.desc.support_url = "";
    e.desc.version = e.version.c_str();
    e.desc.description = CAW_CLAP_DESCRIPTION;
    e.desc.features = e.features.data();
}

// ---- Parameter values (the same rules as the engine's manual path, engine/src/params.cpp)

double clampTo(const CawParameterInfo& p, double v) {
    if (std::isnan(v)) return p.minimum;
    return std::clamp(v, p.minimum, p.maximum);
}
double constrain(const CawParameterInfo& p, double v) {
    v = clampTo(p, v);
    if (p.step > 0.0) v = std::clamp(p.minimum + std::round((v - p.minimum) / p.step) * p.step, p.minimum, p.maximum);
    return v;
}

struct Param {
    const CawParameterInfo* info = nullptr;
    clap_id id = CLAP_INVALID_ID;
    // Audio side (or main thread while inactive).
    double current = 0.0, target = 0.0, increment = 0.0, mod = 0.0;
    uint32_t rampLeft = 0;
    // Main thread reads; written by whoever changes the value.
    std::atomic<double> shown{0.0};
    // A value from the main thread while active (a loaded state): applied at the next process.
    std::atomic<double> pendingValue{0.0};
    std::atomic<bool> pending{false};

    void jump(double v) {
        current = target = clampTo(*info, v);
        rampLeft = 0;
        increment = 0.0;
        shown.store(target, std::memory_order_relaxed);
    }
    void set(double v) {  // a host change: ramps over the parameter's smoothing frames
        const double value = clampTo(*info, v);
        target = value;
        if (info->smoothing_frames == 0) {
            current = value;
            rampLeft = 0;
        } else {
            rampLeft = info->smoothing_frames;
            increment = (value - current) / static_cast<double>(rampLeft);
        }
        shown.store(target, std::memory_order_relaxed);
    }
    void advance() {
        if (rampLeft != 0) current = --rampLeft == 0 ? target : current + increment;  // lands exactly on target
    }
    double value() const { return constrain(*info, current + mod); }
};

struct ParamEvent {
    uint32_t frame;
    uint32_t index;
    bool isMod;
    double value;
};

// ---- MIDI 2.0 UMP helpers (MIDI 2.0 Channel Voice, message type 0x4, group 0)

uint32_t unit32(double v) {  // 0..1 to a 32-bit controller value
    if (!(v > 0.0)) return 0;
    if (v >= 1.0) return 0xFFFFFFFFu;
    return static_cast<uint32_t>(std::llround(v * 4294967295.0));
}
uint16_t unit16(double v) {
    if (!(v > 0.0)) return 0;
    if (v >= 1.0) return 0xFFFF;
    return static_cast<uint16_t>(std::lround(v * 65535.0));
}
uint32_t voiceWord(uint32_t status, uint32_t channel, uint32_t key, uint32_t index) {
    return (0x4u << 28) | ((status & 0xFu) << 20) | ((channel & 0xFu) << 16) | ((key & 0x7Fu) << 8) | (index & 0xFFu);
}

// ---- The plug-in instance

constexpr uint32_t kNoteSlots = 16 * 128;

struct EventPort {
    std::vector<CawEvent> events;    // kEventCapacity, allocated in activate
    std::vector<uint32_t> noteIds;   // [channel * 128 + key]: the sounding note's C.A.W id, 0 none
};

struct Plugin {
    clap_plugin_t plugin{};
    const clap_host_t* host = nullptr;
    const Entry* entry = nullptr;
    const CawComponentV3* table = nullptr;
    const CawComponentDescriptor* d = nullptr;
    CawHost cawHost{};
    void* instance = nullptr;

    // Port indices into the descriptor, per type and direction, in descriptor order.
    std::vector<uint32_t> audioIn, audioOut, eventIn, eventOut, controlIn, controlOut, modIn, modOut;
    uint32_t inChannels = 0, outChannels = 0;

    std::unique_ptr<Param[]> params;
    uint32_t paramCount = 0;

    // Allocated in activate.
    double sampleRate = 48000.0;
    uint32_t chunk = 0;
    std::vector<double> paramFrames;      // paramCount * chunk
    std::vector<CawParameterValue> values;
    std::vector<uint32_t> needed;         // parameter indices with per-frame values this piece
    std::vector<uint8_t> isNeeded;
    std::vector<ParamEvent> paramEvents;
    uint32_t paramEventCount = 0;
    std::vector<float> zeros, scratch;    // a silent input; outputs the host did not give
    std::vector<const float*> inPtrs;
    std::vector<float*> outPtrs;
    std::vector<CawConstAudio> inAudio;
    std::vector<CawAudio> outAudio;
    std::vector<const float*> modInPtrs;
    std::vector<float*> modOutPtrs;
    std::vector<float> modOutBuffers;
    std::vector<float> controlInValues, controlOutValues;
    std::vector<const float*> controlInPtrs;
    std::vector<float*> controlOutPtrs;
    std::vector<EventPort> eventInPorts;
    std::vector<CawEventInput> eventInputs;
    std::vector<CawEvent> eventOutBuffer;  // eventOut.size() * kEventCapacity
    std::vector<CawEventOutput> eventOutputs;
    uint32_t nextNoteId = 0;

    bool active = false;
    // A state load while active waits for the audio thread to leave process (no lock on that side).
    std::atomic<bool> inProcess{false};
    std::atomic<bool> loadRequested{false};
};

Plugin* self(const clap_plugin_t* p) { return static_cast<Plugin*>(p->plugin_data); }

// ---- Audio ports

uint32_t audioPortsCount(const clap_plugin_t* p, bool isInput) {
    const Plugin* s = self(p);
    return static_cast<uint32_t>((isInput ? s->audioIn : s->audioOut).size());
}
bool audioPortsGet(const clap_plugin_t* p, uint32_t index, bool isInput, clap_audio_port_info_t* info) {
    const Plugin* s = self(p);
    const auto& list = isInput ? s->audioIn : s->audioOut;
    if (!info || index >= list.size()) return false;
    const CawPortInfo& port = portAt(*s->d, list[index]);
    std::memset(info, 0, sizeof(*info));
    info->id = index;
    std::snprintf(info->name, sizeof(info->name), "%s", text(port.id));
    info->flags = index == 0 ? CLAP_AUDIO_PORT_IS_MAIN : 0;
    info->channel_count = channelsOf(port);
    info->port_type = port.layout == CAW_LAYOUT_MONO ? CLAP_PORT_MONO
                      : port.layout == CAW_LAYOUT_STEREO ? CLAP_PORT_STEREO
                                                         : nullptr;
    info->in_place_pair = CLAP_INVALID_ID;
    return true;
}
const clap_plugin_audio_ports_t kAudioPorts = {audioPortsCount, audioPortsGet};

// ---- Note ports

uint32_t notePortsCount(const clap_plugin_t* p, bool isInput) {
    const Plugin* s = self(p);
    return static_cast<uint32_t>((isInput ? s->eventIn : s->eventOut).size());
}
bool notePortsGet(const clap_plugin_t* p, uint32_t index, bool isInput, clap_note_port_info_t* info) {
    const Plugin* s = self(p);
    const auto& list = isInput ? s->eventIn : s->eventOut;
    if (!info || index >= list.size()) return false;
    std::memset(info, 0, sizeof(*info));
    info->id = index;
    info->supported_dialects = CLAP_NOTE_DIALECT_CLAP | CLAP_NOTE_DIALECT_MIDI | CLAP_NOTE_DIALECT_MIDI2;
    info->preferred_dialect = CLAP_NOTE_DIALECT_CLAP;
    std::snprintf(info->name, sizeof(info->name), "%s", text(portAt(*s->d, list[index]).id));
    return true;
}
const clap_plugin_note_ports_t kNotePorts = {notePortsCount, notePortsGet};

// ---- Params

int paramIndex(const Plugin* s, clap_id id) {
    for (uint32_t k = 0; k < s->paramCount; ++k)
        if (s->params[k].id == id) return static_cast<int>(k);
    return -1;
}
uint32_t paramsCount(const clap_plugin_t* p) { return self(p)->paramCount; }
bool paramsGetInfo(const clap_plugin_t* p, uint32_t index, clap_param_info_t* info) {
    const Plugin* s = self(p);
    if (!info || index >= s->paramCount) return false;
    const CawParameterInfo& c = *s->params[index].info;
    std::memset(info, 0, sizeof(*info));
    info->id = s->params[index].id;
    info->flags = 0;
    if (c.flags & CAW_PARAMETER_AUTOMATABLE) info->flags |= CLAP_PARAM_IS_AUTOMATABLE;
    if (c.flags & CAW_PARAMETER_MODULATABLE) info->flags |= CLAP_PARAM_IS_MODULATABLE;
    if (c.step > 0.0 || c.choice_count) info->flags |= CLAP_PARAM_IS_STEPPED;
    if (c.choice_count) info->flags |= CLAP_PARAM_IS_ENUM;
    info->cookie = nullptr;
    std::snprintf(info->name, sizeof(info->name), "%s", c.name && c.name[0] ? c.name : c.id);
    info->module[0] = '\0';
    info->min_value = c.minimum;
    info->max_value = c.maximum;
    info->default_value = c.default_value;
    return true;
}
bool paramsGetValue(const clap_plugin_t* p, clap_id id, double* out) {
    const Plugin* s = self(p);
    const int k = paramIndex(s, id);
    if (k < 0 || !out) return false;
    *out = s->params[k].shown.load(std::memory_order_relaxed);
    return true;
}
bool paramsValueToText(const clap_plugin_t* p, clap_id id, double value, char* out, uint32_t capacity) {
    const Plugin* s = self(p);
    const int k = paramIndex(s, id);
    if (k < 0 || !out || capacity == 0) return false;
    const CawParameterInfo& c = *s->params[k].info;
    const double v = constrain(c, value);
    if (c.choice_count) {
        const double at = std::round(v - c.minimum);
        if (at < 0 || at >= c.choice_count) return false;
        std::snprintf(out, capacity, "%s", text(c.choices[static_cast<uint32_t>(at)]));
        return true;
    }
    int decimals;
    if (c.step > 0.0) {
        decimals = static_cast<int>(std::ceil(-std::log10(c.step) - 1e-9));
        decimals = std::clamp(decimals, 0, 6);
    } else {
        const double a = std::fabs(v);
        decimals = a >= 100.0 ? 1 : a >= 10.0 ? 2 : 3;
    }
    const char* unit = text(c.unit);
    if (unit[0]) std::snprintf(out, capacity, "%.*f %s", decimals, v, unit);
    else std::snprintf(out, capacity, "%.*f", decimals, v);
    return true;
}
bool paramsTextToValue(const clap_plugin_t* p, clap_id id, const char* textIn, double* out) {
    const Plugin* s = self(p);
    const int k = paramIndex(s, id);
    if (k < 0 || !textIn || !out) return false;
    const CawParameterInfo& c = *s->params[k].info;
    for (uint32_t i = 0; i < c.choice_count; ++i)
        if (c.choices[i] && std::strcmp(c.choices[i], textIn) == 0) {
            *out = c.minimum + i;
            return true;
        }
    char* end = nullptr;
    const double v = std::strtod(textIn, &end);
    if (end == textIn || !std::isfinite(v)) return false;
    *out = constrain(c, v);
    return true;
}

void applyPending(Plugin* s) {
    for (uint32_t k = 0; k < s->paramCount; ++k) {
        Param& prm = s->params[k];
        if (prm.pending.load(std::memory_order_acquire)) {
            prm.jump(prm.pendingValue.load(std::memory_order_relaxed));
            prm.pending.store(false, std::memory_order_release);
        }
    }
}

void applyParamNow(Plugin* s, const clap_event_header_t* h) {
    if (h->space_id != CLAP_CORE_EVENT_SPACE_ID) return;
    if (h->type == CLAP_EVENT_PARAM_VALUE) {
        const auto* e = reinterpret_cast<const clap_event_param_value_t*>(h);
        const int k = paramIndex(s, e->param_id);
        if (k < 0) return;
        if (s->active) s->params[k].set(e->value);
        else s->params[k].jump(e->value);
    } else if (h->type == CLAP_EVENT_PARAM_MOD) {
        const auto* e = reinterpret_cast<const clap_event_param_mod_t*>(h);
        const int k = paramIndex(s, e->param_id);
        if (k < 0 || e->note_id >= 0 || e->key >= 0) return;  // per-voice modulation is not offered
        s->params[k].mod = std::isfinite(e->amount) ? e->amount : 0.0;
    }
}

void paramsFlush(const clap_plugin_t* p, const clap_input_events_t* in, const clap_output_events_t*) {
    Plugin* s = self(p);
    if (s->active) applyPending(s);
    if (!in) return;
    const uint32_t n = in->size(in);
    for (uint32_t i = 0; i < n; ++i)
        if (const clap_event_header_t* h = in->get(in, i)) applyParamNow(s, h);
}
const clap_plugin_params_t kParams = {paramsCount,       paramsGetInfo,     paramsGetValue,
                                      paramsValueToText, paramsTextToValue, paramsFlush};

// ---- Latency and tail

uint32_t latencyGet(const clap_plugin_t* p) { return self(p)->d->latency_frames; }
const clap_plugin_latency_t kLatency = {latencyGet};
uint32_t tailGet(const clap_plugin_t* p) {
    const uint32_t t = self(p)->d->tail_frames;
    return t >= static_cast<uint32_t>(INT32_MAX) ? static_cast<uint32_t>(INT32_MAX) : t;  // >= INT32_MAX: infinite
}
const clap_plugin_tail_t kTail = {tailGet};

// ---- State: "CAWS", format, component id, state version, parameter values by id, component bytes.

void putU32(std::vector<uint8_t>& b, uint32_t v) {
    for (int i = 0; i < 4; ++i) b.push_back(static_cast<uint8_t>(v >> (8 * i)));
}
void putText(std::vector<uint8_t>& b, const char* s) {
    const size_t n = std::strlen(s);
    putU32(b, static_cast<uint32_t>(n));
    b.insert(b.end(), s, s + n);
}
void putF64(std::vector<uint8_t>& b, double v) {
    uint64_t bits;
    std::memcpy(&bits, &v, 8);
    for (int i = 0; i < 8; ++i) b.push_back(static_cast<uint8_t>(bits >> (8 * i)));
}
struct Reader {
    const std::vector<uint8_t>& b;
    size_t at = 0;
    bool ok = true;
    uint32_t u32() {
        if (b.size() - at < 4) { ok = false; return 0; }
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) v |= uint32_t(b[at + i]) << (8 * i);
        at += 4;
        return v;
    }
    double f64() {
        if (b.size() - at < 8) { ok = false; return 0; }
        uint64_t v = 0;
        for (int i = 0; i < 8; ++i) v |= uint64_t(b[at + i]) << (8 * i);
        at += 8;
        double d;
        std::memcpy(&d, &v, 8);
        return d;
    }
    std::string str() {
        const uint32_t n = u32();
        if (!ok || b.size() - at < n) { ok = false; return {}; }
        std::string s(reinterpret_cast<const char*>(b.data() + at), n);
        at += n;
        return s;
    }
};

bool stateSave(const clap_plugin_t* p, const clap_ostream_t* stream) {
    Plugin* s = self(p);
    if (!stream) return false;
    try {
        std::vector<uint8_t> state(s->d->max_state_bytes ? s->d->max_state_bytes : 1);
        uint32_t written = 0, version = 0;
        // Safe while processing (caw_component.h: save_state may run alongside process).
        if (!s->table->save_state(s->instance, state.data(), s->d->max_state_bytes, &written, &version) ||
            written > s->d->max_state_bytes)
            return false;
        std::vector<uint8_t> b;
        putU32(b, kStateMagic);
        putU32(b, kStateFormat);
        putText(b, s->d->id);
        putU32(b, version);
        putU32(b, s->paramCount);
        for (uint32_t k = 0; k < s->paramCount; ++k) {
            putText(b, s->params[k].info->id);
            putF64(b, s->params[k].shown.load(std::memory_order_relaxed));
        }
        putU32(b, written);
        b.insert(b.end(), state.begin(), state.begin() + written);
        size_t at = 0;
        while (at < b.size()) {
            const int64_t n = stream->write(stream, b.data() + at, b.size() - at);
            if (n <= 0) return false;
            at += static_cast<size_t>(n);
        }
        return true;
    } catch (...) {
        return false;
    }
}

bool stateLoad(const clap_plugin_t* p, const clap_istream_t* stream) {
    Plugin* s = self(p);
    if (!stream) return false;
    try {
        std::vector<uint8_t> b;
        uint8_t buffer[4096];
        for (;;) {
            const int64_t n = stream->read(stream, buffer, sizeof(buffer));
            if (n < 0) return false;
            if (n == 0) break;
            b.insert(b.end(), buffer, buffer + n);
            if (b.size() > kMaxStateBlob) return false;
        }
        Reader r{b};
        if (r.u32() != kStateMagic || r.u32() != kStateFormat || r.str() != s->d->id || !r.ok) return false;
        const uint32_t version = r.u32();
        const uint32_t count = r.u32();
        if (!r.ok || count > kMaxParameters) return false;
        std::vector<double> values(s->paramCount);
        for (uint32_t k = 0; k < s->paramCount; ++k) values[k] = s->params[k].info->default_value;
        for (uint32_t i = 0; i < count; ++i) {
            const std::string id = r.str();
            const double v = r.f64();
            if (!r.ok) return false;
            for (uint32_t k = 0; k < s->paramCount; ++k)
                if (id == s->params[k].info->id) values[k] = v;  // unknown ids (older versions) are ignored
        }
        const uint32_t size = r.u32();
        if (!r.ok || size > s->d->max_state_bytes || b.size() - r.at != size) return false;
        const uint8_t* bytes = size ? b.data() + r.at : buffer;

        bool ok;
        if (!s->active) {
            ok = s->table->load_state(s->instance, bytes, size, version) != 0;
            if (ok)
                for (uint32_t k = 0; k < s->paramCount; ++k) s->params[k].jump(values[k]);
        } else {
            // The component never loads while it processes: park the audio thread (it outputs silence
            // meanwhile; it never waits), load, then hand the values over.
            s->loadRequested.store(true, std::memory_order_seq_cst);
            const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (s->inProcess.load(std::memory_order_seq_cst)) {
                if (std::chrono::steady_clock::now() > until) {
                    s->loadRequested.store(false, std::memory_order_seq_cst);
                    return false;
                }
                std::this_thread::yield();
            }
            ok = s->table->load_state(s->instance, bytes, size, version) != 0;
            if (ok)
                for (uint32_t k = 0; k < s->paramCount; ++k) {
                    s->params[k].pendingValue.store(values[k], std::memory_order_relaxed);
                    s->params[k].shown.store(clampTo(*s->params[k].info, values[k]), std::memory_order_relaxed);
                    s->params[k].pending.store(true, std::memory_order_release);
                }
            s->loadRequested.store(false, std::memory_order_seq_cst);
        }
        if (ok && s->host && s->host->get_extension) {
            const auto* hp = static_cast<const clap_host_params_t*>(s->host->get_extension(s->host, CLAP_EXT_PARAMS));
            if (hp && hp->rescan) hp->rescan(s->host, CLAP_PARAM_RESCAN_VALUES);
        }
        return ok;
    } catch (...) {
        return false;
    }
}
const clap_plugin_state_t kState = {stateSave, stateLoad};

// ---- Lifecycle

bool pluginInit(const clap_plugin_t* p) {
    Plugin* s = self(p);
    s->instance = s->table->create(&s->cawHost);
    return s->instance != nullptr;
}

void pluginDeactivate(const clap_plugin_t* p);

void pluginDestroy(const clap_plugin_t* p) {
    Plugin* s = self(p);
    if (s->active) pluginDeactivate(p);
    if (s->instance) s->table->destroy(s->instance);
    delete s;
}

bool pluginActivate(const clap_plugin_t* p, double sampleRate, uint32_t, uint32_t maxFrames) {
    Plugin* s = self(p);
    if (s->active || maxFrames == 0 || !(sampleRate > 0.0)) return false;
    const uint32_t chunk = std::min(maxFrames, kMaxChunkFrames);
    if (!s->table->activate(s->instance, sampleRate, chunk)) return false;
    try {
        s->sampleRate = sampleRate;
        s->chunk = chunk;
        s->paramFrames.assign(size_t(s->paramCount) * chunk, 0.0);
        s->values.assign(s->paramCount, CawParameterValue{nullptr, 0.0});
        s->needed.assign(s->paramCount, 0);
        s->isNeeded.assign(s->paramCount, 0);
        s->paramEvents.assign(kParamEventCapacity, ParamEvent{});
        s->zeros.assign(chunk, 0.0f);
        s->scratch.assign(size_t(s->outChannels) * chunk, 0.0f);
        s->inPtrs.assign(s->inChannels, nullptr);
        s->outPtrs.assign(s->outChannels, nullptr);
        s->inAudio.assign(s->audioIn.size(), CawConstAudio{});
        s->outAudio.assign(s->audioOut.size(), CawAudio{});
        s->modInPtrs.assign(s->modIn.size(), s->zeros.data());
        s->modOutBuffers.assign(s->modOut.size() * size_t(chunk), 0.0f);
        s->modOutPtrs.assign(s->modOut.size(), nullptr);
        for (size_t k = 0; k < s->modOut.size(); ++k) s->modOutPtrs[k] = s->modOutBuffers.data() + k * chunk;
        s->controlInValues.assign(s->controlIn.size(), 0.0f);
        s->controlInPtrs.assign(s->controlIn.size(), nullptr);
        for (size_t k = 0; k < s->controlIn.size(); ++k) {
            s->controlInValues[k] = portAt(*s->d, s->controlIn[k]).default_value;
            s->controlInPtrs[k] = &s->controlInValues[k];
        }
        s->controlOutValues.assign(s->controlOut.size(), 0.0f);
        s->controlOutPtrs.assign(s->controlOut.size(), nullptr);
        for (size_t k = 0; k < s->controlOut.size(); ++k) {
            s->controlOutValues[k] = portAt(*s->d, s->controlOut[k]).default_value;
            s->controlOutPtrs[k] = &s->controlOutValues[k];
        }
        s->eventInPorts.assign(s->eventIn.size(), EventPort{});
        for (EventPort& port : s->eventInPorts) {
            port.events.assign(kEventCapacity, CawEvent{});
            port.noteIds.assign(kNoteSlots, 0);
        }
        s->eventInputs.assign(s->eventIn.size(), CawEventInput{});
        s->eventOutBuffer.assign(s->eventOut.size() * size_t(kEventCapacity), CawEvent{});
        s->eventOutputs.assign(s->eventOut.size(), CawEventOutput{});
    } catch (...) {
        s->table->deactivate(s->instance);
        return false;
    }
    s->active = true;
    return true;
}

void pluginDeactivate(const clap_plugin_t* p) {
    Plugin* s = self(p);
    if (!s->active) return;
    s->table->deactivate(s->instance);
    s->active = false;
    // Values the audio thread had not picked up yet.
    applyPending(s);
}

bool pluginStartProcessing(const clap_plugin_t*) { return true; }
void pluginStopProcessing(const clap_plugin_t*) {}

void pluginReset(const clap_plugin_t* p) {
    Plugin* s = self(p);
    s->table->reset(s->instance);
    for (EventPort& port : s->eventInPorts) std::fill(port.noteIds.begin(), port.noteIds.end(), 0u);
    for (uint32_t k = 0; k < s->paramCount; ++k) {
        Param& prm = s->params[k];
        prm.current = prm.target;
        prm.rampLeft = 0;
    }
}

// ---- Events in

uint32_t freshNoteId(Plugin* s) {
    // Host ids n >= 0 become n + 1 (so 0 stays "none"); ids the wrapper makes have the top bit set.
    s->nextNoteId = (s->nextNoteId + 1) & 0x7FFFFFFFu;
    return 0x80000000u | s->nextNoteId;
}
uint32_t hostNoteId(int32_t id) { return static_cast<uint32_t>(id) + 1u; }

void pushEvent(Plugin* s, uint32_t port, uint32_t frame, uint16_t kind, uint32_t noteId, uint32_t w0, uint32_t w1,
               uint32_t w2 = 0, uint32_t w3 = 0) {
    CawEventInput& in = s->eventInputs[port];
    if (in.count >= kEventCapacity) return;  // full: dropped
    CawEvent& e = s->eventInPorts[port].events[in.count++];
    e.frame = frame;
    e.kind = kind;
    e.flags = 0;
    e.note_id = noteId;
    e.data[0] = w0;
    e.data[1] = w1;
    e.data[2] = w2;
    e.data[3] = w3;
}

uint32_t eventPortFor(const Plugin* s, int32_t portIndex) {
    return portIndex >= 0 && static_cast<size_t>(portIndex) < s->eventIn.size() ? static_cast<uint32_t>(portIndex) : 0u;
}

void noteOn(Plugin* s, uint32_t port, uint32_t frame, int32_t clapId, uint32_t channel, uint32_t key, uint16_t velocity) {
    const uint32_t id = clapId >= 0 ? hostNoteId(clapId) : freshNoteId(s);
    s->eventInPorts[port].noteIds[channel * 128 + key] = id;
    pushEvent(s, port, frame, CAW_EVENT_NOTE, id, voiceWord(0x9, channel, key, 0), uint32_t(velocity) << 16);
}

// Ends the matching notes (-1 is a wildcard, as in CLAP); a fully specified note with a host id ends
// even if the wrapper never saw it start.
void noteOff(Plugin* s, uint32_t port, uint32_t frame, int32_t clapId, int32_t channel, int32_t key, uint16_t velocity) {
    std::vector<uint32_t>& ids = s->eventInPorts[port].noteIds;
    if (channel >= 0 && key >= 0 && channel < 16 && key < 128) {
        uint32_t& slot = ids[uint32_t(channel) * 128 + uint32_t(key)];
        const uint32_t id = clapId >= 0 ? hostNoteId(clapId) : slot;
        if (clapId < 0 || slot == id) slot = 0;
        pushEvent(s, port, frame, CAW_EVENT_NOTE, id, voiceWord(0x8, channel, key, 0), uint32_t(velocity) << 16);
        return;
    }
    for (uint32_t c = 0; c < 16; ++c) {
        if (channel >= 0 && uint32_t(channel) != c) continue;
        for (uint32_t k = 0; k < 128; ++k) {
            if (key >= 0 && uint32_t(key) != k) continue;
            uint32_t& slot = ids[c * 128 + k];
            if (!slot || (clapId >= 0 && slot != hostNoteId(clapId))) continue;
            pushEvent(s, port, frame, CAW_EVENT_NOTE, slot, voiceWord(0x8, c, k, 0), uint32_t(velocity) << 16);
            slot = 0;
        }
    }
}

bool findNote(const Plugin* s, uint32_t port, uint32_t id, uint32_t& channel, uint32_t& key) {
    const std::vector<uint32_t>& ids = s->eventInPorts[port].noteIds;
    for (uint32_t i = 0; i < kNoteSlots; ++i)
        if (ids[i] == id) {
            channel = i / 128;
            key = i % 128;
            return true;
        }
    return false;
}

// CLAP note expressions as MIDI 2.0 per-note messages. Pressure is Poly Pressure. The others are
// Registered Per-Note Controllers (status 0x0): Pitch 7.25 (#3, the absolute pitch key + tuning),
// Volume (#7, CLAP's 0..4 scaled to 0..1), Pan (#10), Modulation (#1, vibrato), Expression (#11) and
// Brightness (#74). [Assumption, from the MIDI 2.0 registered per-note controller list; not checked
// against the specification text.]
void noteExpression(Plugin* s, uint32_t port, uint32_t frame, const clap_event_note_expression_t& e) {
    uint32_t channel = e.channel >= 0 && e.channel < 16 ? uint32_t(e.channel) : 0;
    uint32_t key = e.key >= 0 && e.key < 128 ? uint32_t(e.key) : 128;
    uint32_t id = 0;
    if (e.note_id >= 0) {
        id = hostNoteId(e.note_id);
        if ((e.key < 0 || e.channel < 0) && !findNote(s, port, id, channel, key)) return;
    } else if (key < 128) {
        id = s->eventInPorts[port].noteIds[channel * 128 + key];
    }
    if (key >= 128) return;  // a channel-wide expression has no per-note message
    const double v = std::isfinite(e.value) ? e.value : 0.0;
    switch (e.expression_id) {
        case CLAP_NOTE_EXPRESSION_PRESSURE:
            pushEvent(s, port, frame, CAW_EVENT_NOTE, id, voiceWord(0xA, channel, key, 0), unit32(v));
            return;
        case CLAP_NOTE_EXPRESSION_TUNING: {
            const double pitch = std::clamp(double(key) + v, 0.0, 127.99999997);
            const uint32_t word = static_cast<uint32_t>(std::llround(pitch * 33554432.0));  // 7.25 fixed point
            pushEvent(s, port, frame, CAW_EVENT_NOTE, id, voiceWord(0x0, channel, key, 3), word);
            return;
        }
        case CLAP_NOTE_EXPRESSION_VOLUME:
            pushEvent(s, port, frame, CAW_EVENT_NOTE, id, voiceWord(0x0, channel, key, 7), unit32(v / 4.0));
            return;
        case CLAP_NOTE_EXPRESSION_PAN:
            pushEvent(s, port, frame, CAW_EVENT_NOTE, id, voiceWord(0x0, channel, key, 10), unit32(v));
            return;
        case CLAP_NOTE_EXPRESSION_VIBRATO:
            pushEvent(s, port, frame, CAW_EVENT_NOTE, id, voiceWord(0x0, channel, key, 1), unit32(v));
            return;
        case CLAP_NOTE_EXPRESSION_EXPRESSION:
            pushEvent(s, port, frame, CAW_EVENT_NOTE, id, voiceWord(0x0, channel, key, 11), unit32(v));
            return;
        case CLAP_NOTE_EXPRESSION_BRIGHTNESS:
            pushEvent(s, port, frame, CAW_EVENT_NOTE, id, voiceWord(0x0, channel, key, 74), unit32(v));
            return;
        default: return;
    }
}

uint16_t velocity7to16(uint32_t v7) {  // endpoints exact: 0 -> 0, 127 -> 65535
    return static_cast<uint16_t>((std::min(v7, 127u) * 65535u + 63u) / 127u);
}

void midi1(Plugin* s, uint32_t port, uint32_t frame, const uint8_t data[3]) {
    const uint32_t status = data[0], d1 = data[1] & 0x7Fu, d2 = data[2] & 0x7Fu;
    if (status < 0x80) return;
    if (status >= 0xF0) {  // system common / real time: a MIDI 1.0 UMP system message (type 0x1)
        pushEvent(s, port, frame, CAW_EVENT_MIDI, 0, (0x1u << 28) | (status << 16) | (d1 << 8) | d2, 0);
        return;
    }
    const uint32_t type = status & 0xF0u, channel = status & 0x0Fu;
    if (type == 0x90 && d2 > 0) {
        noteOn(s, port, frame, -1, channel, d1, velocity7to16(d2));
    } else if (type == 0x80 || type == 0x90) {
        noteOff(s, port, frame, -1, int32_t(channel), int32_t(d1), type == 0x80 ? velocity7to16(d2) : 0);
    } else {
        // Everything else stays MIDI 1.0, as a MIDI 1.0 channel voice UMP (type 0x2), losslessly.
        pushEvent(s, port, frame, CAW_EVENT_MIDI, 0, (0x2u << 28) | (status << 16) | (d1 << 8) | d2, 0);
    }
}

void midi2(Plugin* s, uint32_t port, uint32_t frame, const uint32_t data[4]) {
    const uint32_t mt = data[0] >> 28;
    if (mt == 0x4) {
        const uint32_t status = (data[0] >> 20) & 0xFu, channel = (data[0] >> 16) & 0xFu, key = (data[0] >> 8) & 0x7Fu;
        std::vector<uint32_t>& ids = s->eventInPorts[port].noteIds;
        if (status == 0x9) {
            const uint32_t id = freshNoteId(s);
            ids[channel * 128 + key] = id;
            pushEvent(s, port, frame, CAW_EVENT_NOTE, id, data[0], data[1], data[2], data[3]);
            return;
        }
        if (status == 0x8) {
            const uint32_t id = ids[channel * 128 + key];
            ids[channel * 128 + key] = 0;
            pushEvent(s, port, frame, CAW_EVENT_NOTE, id, data[0], data[1], data[2], data[3]);
            return;
        }
        // Per-note messages: registered/assignable per-note controllers, per-note pitch bend,
        // poly pressure, per-note management.
        if (status == 0x0 || status == 0x1 || status == 0x6 || status == 0xA || status == 0xF) {
            pushEvent(s, port, frame, CAW_EVENT_NOTE, ids[channel * 128 + key], data[0], data[1], data[2], data[3]);
            return;
        }
    }
    pushEvent(s, port, frame, CAW_EVENT_MIDI, 0, data[0], data[1], data[2], data[3]);
}

void takeEvent(Plugin* s, const clap_event_header_t* h, uint32_t frame) {
    if (h->space_id != CLAP_CORE_EVENT_SPACE_ID) return;
    switch (h->type) {
        case CLAP_EVENT_PARAM_VALUE:
        case CLAP_EVENT_PARAM_MOD: {
            if (s->paramEventCount >= kParamEventCapacity) {  // full: applies now instead of at its frame
                applyParamNow(s, h);
                return;
            }
            uint32_t id;
            double value;
            if (h->type == CLAP_EVENT_PARAM_VALUE) {
                const auto* e = reinterpret_cast<const clap_event_param_value_t*>(h);
                id = e->param_id;
                value = e->value;
            } else {
                const auto* e = reinterpret_cast<const clap_event_param_mod_t*>(h);
                if (e->note_id >= 0 || e->key >= 0) return;
                id = e->param_id;
                value = std::isfinite(e->amount) ? e->amount : 0.0;
            }
            const int k = paramIndex(s, id);
            if (k < 0) return;
            s->paramEvents[s->paramEventCount++] = {frame, uint32_t(k), h->type == CLAP_EVENT_PARAM_MOD, value};
            return;
        }
        default: break;
    }
    if (s->eventIn.empty()) return;
    switch (h->type) {
        case CLAP_EVENT_NOTE_ON: {
            const auto* e = reinterpret_cast<const clap_event_note_t*>(h);
            if (e->key < 0 || e->key > 127) return;
            const uint32_t channel = e->channel >= 0 && e->channel < 16 ? uint32_t(e->channel) : 0;
            noteOn(s, eventPortFor(s, e->port_index), frame, e->note_id, channel, uint32_t(e->key),
                   std::max<uint16_t>(1, unit16(e->velocity)));  // velocity 0 would read as a note off in MIDI 1.0
            return;
        }
        case CLAP_EVENT_NOTE_OFF:
        case CLAP_EVENT_NOTE_CHOKE: {
            const auto* e = reinterpret_cast<const clap_event_note_t*>(h);
            noteOff(s, eventPortFor(s, e->port_index), frame, e->note_id, e->channel, e->key,
                    h->type == CLAP_EVENT_NOTE_OFF ? unit16(e->velocity) : 0);
            return;
        }
        case CLAP_EVENT_NOTE_EXPRESSION: {
            const auto* e = reinterpret_cast<const clap_event_note_expression_t*>(h);
            noteExpression(s, eventPortFor(s, e->port_index), frame, *e);
            return;
        }
        case CLAP_EVENT_MIDI: {
            const auto* e = reinterpret_cast<const clap_event_midi_t*>(h);
            midi1(s, eventPortFor(s, e->port_index), frame, e->data);
            return;
        }
        case CLAP_EVENT_MIDI2: {
            const auto* e = reinterpret_cast<const clap_event_midi2_t*>(h);
            midi2(s, eventPortFor(s, e->port_index), frame, e->data);
            return;
        }
        default: return;  // sysex, transport changes and other spaces are not passed on
    }
}

// ---- Events out

void sendEvents(Plugin* s, const clap_output_events_t* out, uint32_t offset, uint32_t frames) {
    if (!out) return;
    for (size_t port = 0; port < s->eventOutputs.size(); ++port) {
        const CawEventOutput& o = s->eventOutputs[port];
        for (uint32_t i = 0; i < o.count && i < o.capacity; ++i) {
            const CawEvent& e = o.events[i];
            if (e.frame >= frames) continue;  // outside the block: not passed on
            const uint32_t time = offset + e.frame;
            const uint32_t mt = e.data[0] >> 28, status = (e.data[0] >> 20) & 0xFu;
            if (e.kind == CAW_EVENT_NOTE && mt == 0x4 && (status == 0x9 || status == 0x8)) {
                clap_event_note_t n{};
                n.header = {sizeof(n), time, CLAP_CORE_EVENT_SPACE_ID,
                            uint16_t(status == 0x9 ? CLAP_EVENT_NOTE_ON : CLAP_EVENT_NOTE_OFF), 0};
                n.note_id = e.note_id >= 1 && e.note_id <= 0x7FFFFFFFu ? int32_t(e.note_id - 1) : -1;
                n.port_index = int16_t(port);
                n.channel = int16_t((e.data[0] >> 16) & 0xFu);
                n.key = int16_t((e.data[0] >> 8) & 0x7Fu);
                n.velocity = double(e.data[1] >> 16) / 65535.0;
                out->try_push(out, &n.header);
            } else if (mt == 0x2) {
                clap_event_midi_t m{};
                m.header = {sizeof(m), time, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_MIDI, 0};
                m.port_index = uint16_t(port);
                m.data[0] = uint8_t(e.data[0] >> 16);
                m.data[1] = uint8_t((e.data[0] >> 8) & 0x7F);
                m.data[2] = uint8_t(e.data[0] & 0x7F);
                out->try_push(out, &m.header);
            } else {
                clap_event_midi2_t m{};
                m.header = {sizeof(m), time, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_MIDI2, 0};
                m.port_index = uint16_t(port);
                std::memcpy(m.data, e.data, sizeof(m.data));
                out->try_push(out, &m.header);
            }
        }
    }
}

// ---- Process

void silence(const clap_process_t* proc) {
    for (uint32_t k = 0; k < proc->audio_outputs_count; ++k) {
        const clap_audio_buffer_t& b = proc->audio_outputs[k];
        if (!b.data32) continue;
        for (uint32_t c = 0; c < b.channel_count; ++c)
            if (b.data32[c]) std::memset(b.data32[c], 0, sizeof(float) * proc->frames_count);
    }
}

// Per-frame values for the parameters that change in this piece; one value for the rest.
void resolveParams(Plugin* s, uint32_t frames) {
    uint32_t neededCount = 0;
    for (uint32_t k = 0; k < s->paramCount; ++k) s->isNeeded[k] = s->params[k].rampLeft != 0;
    for (uint32_t e = 0; e < s->paramEventCount; ++e) s->isNeeded[s->paramEvents[e].index] = 1;
    for (uint32_t k = 0; k < s->paramCount; ++k) {
        if (s->isNeeded[k]) s->needed[neededCount++] = k;
        else s->values[k] = {nullptr, s->params[k].value()};
    }
    if (neededCount == 0) return;
    uint32_t e = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        // A change at frame i takes effect from frame i, as if the host split the block there.
        for (; e < s->paramEventCount && s->paramEvents[e].frame <= i; ++e) {
            const ParamEvent& pe = s->paramEvents[e];
            if (pe.isMod) s->params[pe.index].mod = pe.value;
            else s->params[pe.index].set(pe.value);
        }
        for (uint32_t n = 0; n < neededCount; ++n) {
            const uint32_t k = s->needed[n];
            s->params[k].advance();
            s->paramFrames[size_t(k) * s->chunk + i] = s->params[k].value();
        }
    }
    for (uint32_t n = 0; n < neededCount; ++n) {
        const uint32_t k = s->needed[n];
        const double* frame0 = s->paramFrames.data() + size_t(k) * s->chunk;
        s->values[k] = {frame0, frame0[0]};
    }
}

clap_process_status pluginProcess(const clap_plugin_t* p, const clap_process_t* proc) {
    Plugin* s = self(p);
    if (!proc || !s->active) return CLAP_PROCESS_ERROR;
    s->inProcess.store(true, std::memory_order_seq_cst);
    if (s->loadRequested.load(std::memory_order_seq_cst)) {  // a state is loading on the main thread
        s->inProcess.store(false, std::memory_order_seq_cst);
        silence(proc);
        return CLAP_PROCESS_CONTINUE;
    }
    applyPending(s);

    const uint32_t frames = proc->frames_count;
    // The host's buffers must match the declared ports; a missing input reads silence and a missing
    // output goes to scratch.
    for (uint32_t k = 0; k < proc->audio_inputs_count && k < s->audioIn.size(); ++k) {
        const clap_audio_buffer_t& b = proc->audio_inputs[k];
        if (!b.data32 || b.channel_count != channelsOf(portAt(*s->d, s->audioIn[k]))) {
            s->inProcess.store(false, std::memory_order_seq_cst);
            silence(proc);
            return CLAP_PROCESS_ERROR;
        }
    }
    for (uint32_t k = 0; k < proc->audio_outputs_count && k < s->audioOut.size(); ++k) {
        const clap_audio_buffer_t& b = proc->audio_outputs[k];
        if (!b.data32 || b.channel_count != channelsOf(portAt(*s->d, s->audioOut[k]))) {
            s->inProcess.store(false, std::memory_order_seq_cst);
            silence(proc);
            return CLAP_PROCESS_ERROR;
        }
    }

    const clap_event_transport_t* t = proc->transport;
    const bool playing = t && (t->flags & CLAP_TRANSPORT_IS_PLAYING);
    CawTransport transport{};
    if (playing) {
        transport.struct_size = sizeof(CawTransport);
        transport.flags = CAW_TRANSPORT_PLAYING;
        transport.tempo = (t->flags & CLAP_TRANSPORT_HAS_TEMPO) && t->tempo > 0.0 ? t->tempo : 120.0;
        transport.beats_per_bar = 4;
        if ((t->flags & CLAP_TRANSPORT_HAS_TIME_SIGNATURE) && t->tsig_num > 0 && t->tsig_denom > 0)  // in quarter notes
            transport.beats_per_bar = std::max(1u, (uint32_t(t->tsig_num) * 4u + t->tsig_denom / 2u) / t->tsig_denom);
    }
    const double startBeat =
        playing && (t->flags & CLAP_TRANSPORT_HAS_BEATS_TIMELINE) ? double(t->song_pos_beats) / double(CLAP_BEATTIME_FACTOR) : 0.0;

    const clap_input_events_t* in = proc->in_events;
    const uint32_t eventCount = in ? in->size(in) : 0;
    uint32_t next = 0;
    bool ok = true;

    for (uint32_t start = 0; start < frames && ok; start += s->chunk) {
        const uint32_t len = std::min(s->chunk, frames - start);
        const bool last = start + len >= frames;
        for (CawEventInput& e : s->eventInputs) e.count = 0;
        for (size_t k = 0; k < s->eventInputs.size(); ++k) s->eventInputs[k].events = s->eventInPorts[k].events.data();
        s->paramEventCount = 0;
        for (; next < eventCount; ++next) {
            const clap_event_header_t* h = in->get(in, next);
            if (!h) continue;
            // Events are sorted by time; one past the block lands on its last frame.
            uint32_t time = std::min(h->time, frames - 1);
            if (time >= start + len && !last) break;
            time = std::max(time, start);
            takeEvent(s, h, std::min(time - start, len - 1));
        }
        // Keep each list non-decreasing (the C.A.W contract) even if a host sent events out of order.
        for (size_t k = 0; k < s->eventInputs.size(); ++k) {
            CawEvent* events = s->eventInPorts[k].events.data();
            for (uint32_t i = 1; i < s->eventInputs[k].count; ++i)
                events[i].frame = std::max(events[i].frame, events[i - 1].frame);
        }
        // Parameter changes too: resolveParams applies them in list order.
        for (uint32_t i = 1; i < s->paramEventCount; ++i)
            s->paramEvents[i].frame = std::max(s->paramEvents[i].frame, s->paramEvents[i - 1].frame);
        resolveParams(s, len);

        // Audio views for this piece.
        uint32_t ch = 0;
        for (size_t k = 0; k < s->audioIn.size(); ++k) {
            const uint32_t n = channelsOf(portAt(*s->d, s->audioIn[k]));
            const bool given = k < proc->audio_inputs_count;
            for (uint32_t c = 0; c < n; ++c)
                s->inPtrs[ch + c] = given ? proc->audio_inputs[k].data32[c] + start : s->zeros.data();
            s->inAudio[k] = {s->inPtrs.data() + ch, n, len};
            ch += n;
        }
        ch = 0;
        for (size_t k = 0; k < s->audioOut.size(); ++k) {
            const uint32_t n = channelsOf(portAt(*s->d, s->audioOut[k]));
            const bool given = k < proc->audio_outputs_count;
            for (uint32_t c = 0; c < n; ++c)
                s->outPtrs[ch + c] = given ? proc->audio_outputs[k].data32[c] + start
                                           : s->scratch.data() + size_t(ch + c) * s->chunk;
            s->outAudio[k] = {s->outPtrs.data() + ch, n, len};
            ch += n;
        }
        for (size_t k = 0; k < s->eventOutputs.size(); ++k)
            s->eventOutputs[k] = {s->eventOutBuffer.data() + k * kEventCapacity, kEventCapacity, 0};

        CawTransport pieceTransport = transport;
        if (playing) pieceTransport.beat = startBeat + double(start) * transport.tempo / 60.0 / s->sampleRate;

        CawProcessBlock block{};
        block.struct_size = sizeof(CawProcessBlock);
        block.frames = len;
        block.sample_rate = s->sampleRate;
        block.audio_in = s->inAudio.data();
        block.audio_in_count = static_cast<uint32_t>(s->inAudio.size());
        block.audio_out = s->outAudio.data();
        block.audio_out_count = static_cast<uint32_t>(s->outAudio.size());
        block.modulation_in = s->modInPtrs.data();
        block.modulation_in_count = static_cast<uint32_t>(s->modInPtrs.size());
        block.modulation_out = s->modOutPtrs.data();
        block.modulation_out_count = static_cast<uint32_t>(s->modOutPtrs.size());
        block.control_in = s->controlInPtrs.data();
        block.control_in_count = static_cast<uint32_t>(s->controlInPtrs.size());
        block.control_out = s->controlOutPtrs.data();
        block.control_out_count = static_cast<uint32_t>(s->controlOutPtrs.size());
        block.event_in = s->eventInputs.data();
        block.event_in_count = static_cast<uint32_t>(s->eventInputs.size());
        block.event_out = s->eventOutputs.data();
        block.event_out_count = static_cast<uint32_t>(s->eventOutputs.size());
        block.parameters = s->values.data();
        block.parameter_count = s->paramCount;
        block.transport = playing ? &pieceTransport : nullptr;
        ok = s->table->process(s->instance, &block) != 0;
        if (ok) sendEvents(s, proc->out_events, start, len);
    }
    s->inProcess.store(false, std::memory_order_seq_cst);
    if (!ok) {  // the component's outputs are undefined after a failure (caw_component.h)
        silence(proc);
        return CLAP_PROCESS_ERROR;
    }
    return CLAP_PROCESS_CONTINUE;
}

const void* pluginGetExtension(const clap_plugin_t* p, const char* id) {
    const Plugin* s = self(p);
    if (!id) return nullptr;
    if (!std::strcmp(id, CLAP_EXT_AUDIO_PORTS)) return &kAudioPorts;
    if (!std::strcmp(id, CLAP_EXT_NOTE_PORTS)) return s->eventIn.empty() && s->eventOut.empty() ? nullptr : &kNotePorts;
    if (!std::strcmp(id, CLAP_EXT_PARAMS)) return &kParams;
    if (!std::strcmp(id, CLAP_EXT_STATE)) return &kState;
    if (!std::strcmp(id, CLAP_EXT_LATENCY)) return &kLatency;
    if (!std::strcmp(id, CLAP_EXT_TAIL)) return &kTail;
    return nullptr;
}

void pluginOnMainThread(const clap_plugin_t*) {}

// The component asks its host for extensions; none are offered through CLAP yet.
const void* cawHostExtension(const CawHost*, const char*) { return nullptr; }

// ---- Factory and entry

uint32_t factoryCount(const clap_plugin_factory_t*) { return static_cast<uint32_t>(bundle().entries.size()); }
const clap_plugin_descriptor_t* factoryDescriptor(const clap_plugin_factory_t*, uint32_t index) {
    const auto& entries = bundle().entries;
    return index < entries.size() ? &entries[index]->desc : nullptr;
}
const clap_plugin_t* factoryCreate(const clap_plugin_factory_t*, const clap_host_t* host, const char* id) {
    if (!host || !id || !clap_version_is_compatible(host->clap_version)) return nullptr;
    const Entry* entry = nullptr;
    for (const auto& e : bundle().entries)
        if (e->id == id) entry = e.get();
    if (!entry) return nullptr;
    try {
        auto s = std::make_unique<Plugin>();
        s->host = host;
        s->entry = entry;
        s->table = entry->table;
        s->d = entry->table->descriptor;
        s->cawHost = {sizeof(CawHost), CAW_COMPONENT_ABI_VERSION, "C.A.W CLAP wrapper", CAW_CLAP_VERSION, s.get(),
                      cawHostExtension};
        for (uint32_t k = 0; k < s->d->port_count; ++k) {
            const CawPortInfo& port = portAt(*s->d, k);
            switch (port.type) {
                case CAW_PORT_AUDIO:
                    (port.is_input ? s->audioIn : s->audioOut).push_back(k);
                    (port.is_input ? s->inChannels : s->outChannels) += channelsOf(port);
                    break;
                case CAW_PORT_EVENT: (port.is_input ? s->eventIn : s->eventOut).push_back(k); break;
                case CAW_PORT_CONTROL: (port.is_input ? s->controlIn : s->controlOut).push_back(k); break;
                case CAW_PORT_MODULATION: (port.is_input ? s->modIn : s->modOut).push_back(k); break;
                default: break;
            }
        }
        s->paramCount = s->d->parameter_count;
        s->params.reset(new Param[s->paramCount ? s->paramCount : 1]);
        for (uint32_t k = 0; k < s->paramCount; ++k) {
            Param& prm = s->params[k];
            prm.info = &parameterAt(*s->d, k);
            prm.id = entry->paramIds[k];
            prm.jump(prm.info->default_value);
        }
        s->plugin.desc = &entry->desc;
        s->plugin.plugin_data = s.get();
        s->plugin.init = pluginInit;
        s->plugin.destroy = pluginDestroy;
        s->plugin.activate = pluginActivate;
        s->plugin.deactivate = pluginDeactivate;
        s->plugin.start_processing = pluginStartProcessing;
        s->plugin.stop_processing = pluginStopProcessing;
        s->plugin.reset = pluginReset;
        s->plugin.process = pluginProcess;
        s->plugin.get_extension = pluginGetExtension;
        s->plugin.on_main_thread = pluginOnMainThread;
        return &s.release()->plugin;
    } catch (...) {
        return nullptr;
    }
}
const clap_plugin_factory_t kFactory = {factoryCount, factoryDescriptor, factoryCreate};

bool entryInit(const char*) {
    Bundle& b = bundle();
    if (b.refs++ > 0) return true;
    try {
        for (uint32_t i = 0; i < kMaxComponents; ++i) {
            const CawComponentV3* t = caw_get_component_v3(i);
            if (!t) break;
            if (!tableUsable(t)) continue;  // a component this wrapper cannot read is not listed
            auto e = std::make_unique<Entry>();
            e->table = t;
            describe(*e);
            bool duplicate = false;
            for (const auto& other : b.entries) duplicate = duplicate || other->id == e->id;
            if (!duplicate) b.entries.push_back(std::move(e));
        }
    } catch (...) {
        b.entries.clear();
        b.refs = 0;
        return false;
    }
    return true;
}
void entryDeinit() {
    Bundle& b = bundle();
    if (b.refs > 0 && --b.refs == 0) b.entries.clear();
}
const void* entryGetFactory(const char* id) {
    return id && !std::strcmp(id, CLAP_PLUGIN_FACTORY_ID) ? &kFactory : nullptr;
}

}  // namespace

extern "C" CLAP_EXPORT const clap_plugin_entry_t clap_entry = {CLAP_VERSION_INIT, entryInit, entryDeinit, entryGetFactory};
