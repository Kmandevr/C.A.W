// VST3 wrapper: exposes every C.A.W component of the library it is linked into as a VST3 plug-in.
//
// Built by caw_add_vst3_plugin (engine/cmake/CAWVst3.cmake) together with a component's own sources, so the
// component's caw_get_component_v3 entry (caw_component.h) is linked in statically and this file exports what a
// VST3 host looks for: GetPluginFactory, plus ModuleEntry/ModuleExit (Linux) or InitDll/ExitDll (Windows). It reads
// the component only through the plain-C interface, like any other C.A.W host, and uses only the VST3 interface
// headers (steinbergmedia/vst3_pluginterfaces, MIT), not the SDK's helper classes.
//
// Mapping (docs/native-module-sdk.md, "Export as a VST3 plug-in"); it follows the CLAP wrapper where VST3 allows:
// - factory: one class per component of the bundle ("Audio Module Class"), class id = a hash of the component id,
//   sub-categories by role;
// - one object is the component, the processor and the edit controller (a "single component" plug-in:
//   getControllerClassId says there is no separate controller, so hosts query IEditController on it);
// - audio buses: the component's audio ports (first of each side is main); event buses: one per event port.
//   Note on/off and poly pressure become CawEvents (MIDI 2.0 UMP words) with note ids; the component's output
//   notes go back as VST3 notes;
// - parameters: id = a stable hash of the parameter id (31 bits; VST3 keeps the top half for hosts), normalized
//   0..1 on the parameter's curve (linear, or exponential when the minimum is above 0), steps for a step or
//   choices. Each queue point is a change at its sample offset, ramping over the parameter's smoothing frames,
//   as the C.A.W engine does for a manual change;
// - state: the same versioned blob as the CLAP wrapper (parameter values by id, then the component's own state);
// - latency, tail, transport (only while playing, as the C.A.W contract says).
// Control and modulation ports have no VST3 equivalent: inputs read their default (control) or 0 (modulation) and
// outputs go to scratch buffers.
//
// process never allocates, locks or does I/O; everything is allocated in setActive(true).
#include <pluginterfaces/base/ibstream.h>
#include <pluginterfaces/base/ipluginbase.h>
#include <pluginterfaces/vst/ivstaudioprocessor.h>
#include <pluginterfaces/vst/ivstcomponent.h>
#include <pluginterfaces/vst/ivsteditcontroller.h>
#include <pluginterfaces/vst/ivstevents.h>
#include <pluginterfaces/vst/ivstparameterchanges.h>
#include <pluginterfaces/vst/ivstprocesscontext.h>
#include <pluginterfaces/vst/vstspeaker.h>

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

// Plug-in metadata from caw_add_vst3_plugin; empty means "not given".
#ifndef CAW_VST3_VENDOR
#define CAW_VST3_VENDOR ""
#endif
#ifndef CAW_VST3_URL
#define CAW_VST3_URL ""
#endif
#ifndef CAW_VST3_EMAIL
#define CAW_VST3_EMAIL ""
#endif
#ifndef CAW_VST3_VERSION
#define CAW_VST3_VERSION ""
#endif

using namespace Steinberg;

namespace {

constexpr uint32_t kMaxComponents = 256;
constexpr uint32_t kMaxPorts = 256;
constexpr uint32_t kMaxParameters = 4096;
constexpr uint32_t kMaxChannels = 64;
constexpr uint32_t kMaxChunkFrames = 4096;      // longer host blocks are processed in pieces
constexpr uint32_t kEventCapacity = 1024;       // events per event port per piece; more are dropped
constexpr uint32_t kParamEventCapacity = 4096;  // parameter points per block; more are dropped
constexpr uint32_t kMaxNotes = 256;             // notes tracked per event port; past it the oldest ends
constexpr uint32_t kStateMagic = 0x53574143u;   // "CAWS" little-endian: the CLAP wrapper's format
constexpr uint32_t kStateFormat = 1;
constexpr uint64_t kMaxStateBlob = 64ull << 20;
constexpr Vst::ParamID kParamIdMask = 0x7FFFFFFFu;

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
Vst::SpeakerArrangement arrangementOf(const CawPortInfo& p) {
    switch (p.layout) {
        case CAW_LAYOUT_MONO: return Vst::SpeakerArr::kMono;
        case CAW_LAYOUT_STEREO: return Vst::SpeakerArr::kStereo;
        case CAW_LAYOUT_QUAD: return Vst::SpeakerArr::k40Music;
        case CAW_LAYOUT_SURROUND_5_1: return Vst::SpeakerArr::k51;
        case CAW_LAYOUT_SURROUND_7_1: return Vst::SpeakerArr::k71CineFullFront;
        default: {
            const uint32_t n = channelsOf(p);
            return n >= 64 ? ~Vst::SpeakerArrangement(0) : (Vst::SpeakerArrangement(1) << n) - 1;  // n speakers
        }
    }
}
const char* text(const char* s) { return s ? s : ""; }

bool tableUsable(const CawComponentV3* t) {
    if (!t || t->struct_size < sizeof(CawComponentV3) || t->abi_version != CAW_COMPONENT_ABI_VERSION) return false;
    if (!t->create || !t->destroy || !t->activate || !t->deactivate || !t->reset || !t->process || !t->save_state ||
        !t->load_state)
        return false;
    const CawComponentDescriptor* d = t->descriptor;
    if (!d || d->struct_size < CAW_COMPONENT_DESCRIPTOR_SIZE_3_0 || d->abi_version != CAW_COMPONENT_ABI_VERSION) return false;
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

uint32_t fnv32(const char* s) {
    uint32_t h = 2166136261u;
    for (; *s; ++s) h = (h ^ static_cast<unsigned char>(*s)) * 16777619u;
    return h;
}
uint64_t fnv64(const std::string& s, uint64_t h) {
    for (const char c : s) h = (h ^ static_cast<unsigned char>(c)) * 1099511628211ull;
    return h;
}

// ---- UTF-8 and UTF-16 (VST3 strings are UTF-16)

void toUtf16(const char* in, Vst::TChar* out, size_t capacity) {
    size_t n = 0;
    const auto* s = reinterpret_cast<const unsigned char*>(text(in));
    while (*s && n + 1 < capacity) {
        uint32_t c = *s++;
        int more = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
        if (more) c &= (0x3Fu >> more);
        for (; more > 0 && (*s & 0xC0) == 0x80; --more) c = (c << 6) | (*s++ & 0x3Fu);
        if (more) c = 0xFFFD;  // a broken sequence
        if (c >= 0x10000) {
            if (n + 2 >= capacity) break;
            c -= 0x10000;
            out[n++] = static_cast<Vst::TChar>(0xD800 + (c >> 10));
            out[n++] = static_cast<Vst::TChar>(0xDC00 + (c & 0x3FF));
        } else {
            out[n++] = static_cast<Vst::TChar>(c);
        }
    }
    out[n] = 0;
}
std::string toUtf8(const Vst::TChar* in) {
    std::string s;
    for (; in && *in; ++in) {
        uint32_t c = static_cast<uint16_t>(*in);
        if (c >= 0xD800 && c < 0xDC00 && in[1] >= 0xDC00 && in[1] < 0xE000) {
            c = 0x10000 + ((c - 0xD800) << 10) + (static_cast<uint16_t>(in[1]) - 0xDC00);
            ++in;
        }
        if (c < 0x80) {
            s += static_cast<char>(c);
        } else if (c < 0x800) {
            s += static_cast<char>(0xC0 | (c >> 6));
            s += static_cast<char>(0x80 | (c & 0x3F));
        } else if (c < 0x10000) {
            s += static_cast<char>(0xE0 | (c >> 12));
            s += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
            s += static_cast<char>(0x80 | (c & 0x3F));
        } else {
            s += static_cast<char>(0xF0 | (c >> 18));
            s += static_cast<char>(0x80 | ((c >> 12) & 0x3F));
            s += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
            s += static_cast<char>(0x80 | (c & 0x3F));
        }
    }
    return s;
}
void copyText(char* out, size_t capacity, const char* in) { std::snprintf(out, capacity, "%s", text(in)); }

// ---- The bundle, read once (ModuleEntry / InitDll, or the first GetPluginFactory)

struct Entry {
    const CawComponentV3* table = nullptr;
    std::string id, name, version, subCategories;
    TUID cid{};
    std::vector<Vst::ParamID> paramIds;  // descriptor order
};

struct Bundle {
    std::vector<std::unique_ptr<Entry>> entries;
    bool read = false;
};
Bundle& bundle() {
    static Bundle b;
    return b;
}

void describe(Entry& e) {
    const CawComponentDescriptor& d = *e.table->descriptor;
    e.id = d.id;
    e.name = d.name && d.name[0] ? d.name : d.id;
    e.version = CAW_VST3_VERSION[0] ? std::string(CAW_VST3_VERSION) : std::to_string(d.version);
    bool audioIn = false, audioOut = false, eventIn = false, mono = false, stereo = false;
    for (uint32_t k = 0; k < d.port_count; ++k) {
        const CawPortInfo& p = portAt(d, k);
        if (p.type == CAW_PORT_AUDIO) {
            (p.is_input ? audioIn : audioOut) = true;
            mono = mono || p.layout == CAW_LAYOUT_MONO;
            stereo = stereo || p.layout == CAW_LAYOUT_STEREO;
        }
        if (p.type == CAW_PORT_EVENT && p.is_input) eventIn = true;
    }
    // The category by role, else by ports (as the CLAP wrapper's features).
    switch (d.role) {
        case CAW_ROLE_INSTRUMENT: e.subCategories = Vst::PlugType::kInstrumentSynth; break;
        case CAW_ROLE_GENERATOR: e.subCategories = audioIn ? Vst::PlugType::kFxGenerator : Vst::PlugType::kInstrumentSynth; break;
        case CAW_ROLE_EFFECT: e.subCategories = Vst::PlugType::kFx; break;
        case CAW_ROLE_UTILITY: e.subCategories = Vst::PlugType::kFxTools; break;
        case CAW_ROLE_EVENT_PROCESSOR: e.subCategories = Vst::PlugType::kFx; break;
        case CAW_ROLE_ANALYZER: e.subCategories = Vst::PlugType::kFxAnalyzer; break;
        default:
            e.subCategories = audioIn || !(eventIn && audioOut) ? Vst::PlugType::kFx : Vst::PlugType::kInstrumentSynth;
            break;
    }
    if (stereo) e.subCategories += std::string("|") + Vst::PlugType::kStereo;
    else if (mono) e.subCategories += std::string("|") + Vst::PlugType::kMono;

    // A class id from the component id: two 64-bit FNV-1a hashes with different starts.
    const uint64_t a = fnv64("caw.vst3:" + e.id, 14695981039346656037ull);
    const uint64_t b = fnv64("caw.vst3:" + e.id, 0x9E3779B97F4A7C15ull);
    for (int i = 0; i < 8; ++i) {
        e.cid[i] = static_cast<char>(a >> (8 * i));
        e.cid[8 + i] = static_cast<char>(b >> (8 * i));
    }

    for (uint32_t k = 0; k < d.parameter_count; ++k) {
        Vst::ParamID id = fnv32(parameterAt(d, k).id) & kParamIdMask;
        while (std::find(e.paramIds.begin(), e.paramIds.end(), id) != e.paramIds.end()) id = (id + 1) & kParamIdMask;
        e.paramIds.push_back(id);
    }
}

bool readBundle() {
    Bundle& b = bundle();
    if (b.read) return true;
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
        return false;
    }
    b.read = true;
    return true;
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
int32 stepCountOf(const CawParameterInfo& p) {
    if (p.choice_count) return static_cast<int32>(p.choice_count > 1 ? p.choice_count - 1 : 0);
    if (p.step > 0.0 && p.maximum > p.minimum) {
        const double n = std::round((p.maximum - p.minimum) / p.step);
        return n >= 1.0 && n <= 1e6 ? static_cast<int32>(n) : 0;
    }
    return 0;
}
bool exponential(const CawParameterInfo& p) { return p.curve == CAW_CURVE_EXPONENTIAL && p.minimum > 0.0; }
// Normalized to plain: steps as the VST3 SDK's RangeParameter counts them (n * (steps + 1), floored), else the curve.
double toPlain(const CawParameterInfo& p, double n) {
    n = std::isnan(n) ? 0.0 : std::clamp(n, 0.0, 1.0);
    if (!(p.maximum > p.minimum)) return p.minimum;
    const int32 steps = stepCountOf(p);
    if (steps > 0) {
        const double k = std::min<double>(steps, std::floor(n * (steps + 1)));
        return k >= steps ? p.maximum : p.minimum + k * (p.maximum - p.minimum) / steps;
    }
    if (n <= 0.0) return p.minimum;
    if (n >= 1.0) return p.maximum;  // endpoints exact on every curve
    if (exponential(p)) return clampTo(p, p.minimum * std::exp(n * std::log(p.maximum / p.minimum)));
    return clampTo(p, p.minimum + n * (p.maximum - p.minimum));
}
double toNormalized(const CawParameterInfo& p, double plain) {
    const double v = clampTo(p, plain);
    if (!(p.maximum > p.minimum)) return 0.0;
    const int32 steps = stepCountOf(p);
    if (steps > 0) return std::round((v - p.minimum) / (p.maximum - p.minimum) * steps) / steps;
    if (exponential(p)) return std::clamp(std::log(v / p.minimum) / std::log(p.maximum / p.minimum), 0.0, 1.0);
    return (v - p.minimum) / (p.maximum - p.minimum);
}

struct Param {
    const CawParameterInfo* info = nullptr;
    Vst::ParamID id = 0;
    // Audio side (or the host's thread while inactive).
    double current = 0.0, target = 0.0, increment = 0.0;
    uint32_t rampLeft = 0;
    // The plain value the processor last took: what getState saves.
    std::atomic<double> shown{0.0};
    // The controller's value (setParamNormalized and state loads): what the host's generic editor shows.
    std::atomic<double> edited{0.0};
    // A value from a state load while active: applied at the next process.
    std::atomic<double> pendingValue{0.0};
    std::atomic<bool> pending{false};

    void jump(double v) {
        current = target = clampTo(*info, v);
        rampLeft = 0;
        increment = 0.0;
        shown.store(target, std::memory_order_relaxed);
        edited.store(target, std::memory_order_relaxed);
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
    double value() const { return constrain(*info, current); }
};

struct ParamEvent {
    uint32_t frame;
    uint32_t index;
    double value;  // plain
};

// ---- MIDI 2.0 UMP helpers (MIDI 2.0 Channel Voice, message type 0x4, group 0)

uint32_t unit32(double v) {
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

struct Note {
    uint32_t slot;  // channel * 128 + key
    uint32_t id;    // the C.A.W note id: host id + 1, or a wrapper id with the top bit set
};

struct EventPort {
    std::vector<CawEvent> events;  // kEventCapacity, allocated in setActive
    std::vector<Note> notes;       // kMaxNotes, the oldest first
    uint32_t noteCount = 0;
};

// ---- State blob helpers (the CLAP wrapper's format)

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

bool readStream(IBStream* stream, std::vector<uint8_t>& b) {
    uint8_t buffer[4096];
    for (;;) {
        int32 n = 0;
        if (stream->read(buffer, sizeof(buffer), &n) != kResultOk && n == 0) break;  // the end, or nothing more
        if (n < 0 || n > static_cast<int32>(sizeof(buffer))) return false;  // a host over-reporting its read
        if (n == 0) break;
        b.insert(b.end(), buffer, buffer + n);
        if (b.size() > kMaxStateBlob) return false;
    }
    return true;
}

// ---- The plug-in instance: component, processor and edit controller in one object

class Plugin final : public Vst::IComponent, public Vst::IAudioProcessor, public Vst::IEditController,
                     public Vst::IProcessContextRequirements {
public:
    explicit Plugin(const Entry* entry) : entry_(entry), table_(entry->table), d_(entry->table->descriptor) {
        cawHost_ = {sizeof(CawHost), CAW_COMPONENT_ABI_VERSION, "C.A.W VST3 wrapper", CAW_VST3_VERSION, this,
                    [](const CawHost*, const char*) -> const void* { return nullptr; }};
        for (uint32_t k = 0; k < d_->port_count; ++k) {
            const CawPortInfo& port = portAt(*d_, k);
            switch (port.type) {
                case CAW_PORT_AUDIO:
                    (port.is_input ? audioIn_ : audioOut_).push_back(k);
                    (port.is_input ? inChannels_ : outChannels_) += channelsOf(port);
                    break;
                case CAW_PORT_EVENT: (port.is_input ? eventIn_ : eventOut_).push_back(k); break;
                case CAW_PORT_CONTROL: (port.is_input ? controlIn_ : controlOut_).push_back(k); break;
                case CAW_PORT_MODULATION: (port.is_input ? modIn_ : modOut_).push_back(k); break;
                default: break;
            }
        }
        paramCount_ = d_->parameter_count;
        params_.reset(new Param[paramCount_ ? paramCount_ : 1]);
        for (uint32_t k = 0; k < paramCount_; ++k) {
            Param& prm = params_[k];
            prm.info = &parameterAt(*d_, k);
            prm.id = entry->paramIds[k];
            prm.jump(prm.info->default_value);
        }
    }
    ~Plugin() {
        if (active_) deactivate();
        if (instance_) table_->destroy(instance_);
        if (handler_) handler_->release();
    }
    Plugin(const Plugin&) = delete;
    Plugin& operator=(const Plugin&) = delete;

    // ---- FUnknown
    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (!obj) return kInvalidArgument;
        if (FUnknownPrivate::iidEqual(iid, FUnknown::iid) || FUnknownPrivate::iidEqual(iid, IPluginBase::iid) ||
            FUnknownPrivate::iidEqual(iid, Vst::IComponent::iid))
            *obj = static_cast<Vst::IComponent*>(this);
        else if (FUnknownPrivate::iidEqual(iid, Vst::IAudioProcessor::iid))
            *obj = static_cast<Vst::IAudioProcessor*>(this);
        else if (FUnknownPrivate::iidEqual(iid, Vst::IEditController::iid))
            *obj = static_cast<Vst::IEditController*>(this);
        else if (FUnknownPrivate::iidEqual(iid, Vst::IProcessContextRequirements::iid))
            *obj = static_cast<Vst::IProcessContextRequirements*>(this);
        else {
            *obj = nullptr;
            return kNoInterface;
        }
        addRef();
        return kResultOk;
    }
    uint32 PLUGIN_API addRef() override { return refs_.fetch_add(1, std::memory_order_relaxed) + 1; }
    uint32 PLUGIN_API release() override {
        const uint32 left = refs_.fetch_sub(1, std::memory_order_acq_rel) - 1;
        if (left == 0) delete this;
        return left;
    }

    // ---- IPluginBase (shared by the component and the controller)
    tresult PLUGIN_API initialize(FUnknown*) override {
        if (instance_) return kResultOk;  // the controller side of an initialized component
        instance_ = table_->create(&cawHost_);
        if (instance_ && table_->get_extension) {
            const auto* q = static_cast<const CawQuietExtension*>(table_->get_extension(instance_, CAW_EXTENSION_QUIET));
            if (q && q->struct_size >= sizeof(CawQuietExtension)) quiet_ = q->quiet;
        }
        return instance_ ? kResultOk : kResultFalse;
    }
    tresult PLUGIN_API terminate() override {
        if (active_) deactivate();
        return kResultOk;
    }

    // ---- IComponent
    tresult PLUGIN_API getControllerClassId(TUID) override { return kNotImplemented; }  // a single component
    tresult PLUGIN_API setIoMode(Vst::IoMode) override { return kNotImplemented; }
    int32 PLUGIN_API getBusCount(Vst::MediaType type, Vst::BusDirection dir) override {
        if (type == Vst::kAudio) return static_cast<int32>(dir == Vst::kInput ? audioIn_.size() : audioOut_.size());
        if (type == Vst::kEvent) return static_cast<int32>(dir == Vst::kInput ? eventIn_.size() : eventOut_.size());
        return 0;
    }
    tresult PLUGIN_API getBusInfo(Vst::MediaType type, Vst::BusDirection dir, int32 index, Vst::BusInfo& bus) override {
        const std::vector<uint32_t>* ports = nullptr;
        if (type == Vst::kAudio) ports = dir == Vst::kInput ? &audioIn_ : &audioOut_;
        else if (type == Vst::kEvent) ports = dir == Vst::kInput ? &eventIn_ : &eventOut_;
        if (!ports || index < 0 || static_cast<size_t>(index) >= ports->size()) return kInvalidArgument;
        const CawPortInfo& p = portAt(*d_, (*ports)[index]);
        bus.mediaType = type;
        bus.direction = dir;
        bus.channelCount = type == Vst::kAudio ? static_cast<int32>(channelsOf(p)) : 16;
        toUtf16(p.id && p.id[0] ? p.id : (type == Vst::kAudio ? "audio" : "events"), bus.name, 128);
        bus.busType = index == 0 ? Vst::kMain : Vst::kAux;
        bus.flags = Vst::BusInfo::kDefaultActive;
        return kResultOk;
    }
    tresult PLUGIN_API getRoutingInfo(Vst::RoutingInfo&, Vst::RoutingInfo&) override { return kNotImplemented; }
    tresult PLUGIN_API activateBus(Vst::MediaType, Vst::BusDirection, int32, TBool) override { return kResultOk; }
    tresult PLUGIN_API setActive(TBool state) override {
        if (!state) {
            if (active_) deactivate();
            return kResultOk;
        }
        if (active_) return kResultOk;
        return activate() ? kResultOk : kResultFalse;
    }
    tresult PLUGIN_API setState(IBStream* stream) override { return loadState(stream, true) ? kResultOk : kResultFalse; }
    tresult PLUGIN_API getState(IBStream* stream) override { return saveState(stream) ? kResultOk : kResultFalse; }

    // ---- IAudioProcessor
    tresult PLUGIN_API setBusArrangements(Vst::SpeakerArrangement* inputs, int32 numIns, Vst::SpeakerArrangement* outputs,
                                          int32 numOuts) override {
        // The component's buses are fixed: only arrangements with their channel counts are taken.
        if (numIns != static_cast<int32>(audioIn_.size()) || numOuts != static_cast<int32>(audioOut_.size()))
            return kResultFalse;
        for (int32 k = 0; k < numIns; ++k)
            if (!inputs || Vst::SpeakerArr::getChannelCount(inputs[k]) != int32(channelsOf(portAt(*d_, audioIn_[k]))))
                return kResultFalse;
        for (int32 k = 0; k < numOuts; ++k)
            if (!outputs || Vst::SpeakerArr::getChannelCount(outputs[k]) != int32(channelsOf(portAt(*d_, audioOut_[k]))))
                return kResultFalse;
        return kResultTrue;
    }
    tresult PLUGIN_API getBusArrangement(Vst::BusDirection dir, int32 index, Vst::SpeakerArrangement& arr) override {
        const std::vector<uint32_t>& ports = dir == Vst::kInput ? audioIn_ : audioOut_;
        if (index < 0 || static_cast<size_t>(index) >= ports.size()) return kInvalidArgument;
        arr = arrangementOf(portAt(*d_, ports[index]));
        return kResultOk;
    }
    tresult PLUGIN_API canProcessSampleSize(int32 size) override {
        return size == Vst::kSample32 ? kResultTrue : kResultFalse;  // 32-bit float only
    }
    uint32 PLUGIN_API getLatencySamples() override { return d_->latency_frames; }
    tresult PLUGIN_API setupProcessing(Vst::ProcessSetup& setup) override {
        if (active_ || setup.symbolicSampleSize != Vst::kSample32 || setup.maxSamplesPerBlock <= 0 ||
            !(setup.sampleRate > 0.0))
            return kResultFalse;
        sampleRate_ = setup.sampleRate;
        maxFrames_ = static_cast<uint32_t>(setup.maxSamplesPerBlock);
        return kResultOk;
    }
    tresult PLUGIN_API setProcessing(TBool) override { return kResultOk; }
    tresult PLUGIN_API process(Vst::ProcessData& data) override;
    uint32 PLUGIN_API getTailSamples() override {
        return d_->tail_frames == CAW_INFINITE_TAIL ? Vst::kInfiniteTail : d_->tail_frames;
    }

    // ---- IProcessContextRequirements: tempo, the position in beats, the time signature
    uint32 PLUGIN_API getProcessContextRequirements() override {
        return kNeedTempo | kNeedProjectTimeMusic | kNeedTimeSignature | kNeedTransportState;
    }

    // ---- IEditController
    tresult PLUGIN_API setComponentState(IBStream* stream) override {
        return loadState(stream, false) ? kResultOk : kResultFalse;  // the controller's values only
    }
    int32 PLUGIN_API getParameterCount() override { return static_cast<int32>(paramCount_); }
    tresult PLUGIN_API getParameterInfo(int32 index, Vst::ParameterInfo& info) override {
        if (index < 0 || static_cast<uint32_t>(index) >= paramCount_) return kInvalidArgument;
        const CawParameterInfo& c = *params_[index].info;
        std::memset(&info, 0, sizeof(info));
        info.id = params_[index].id;
        toUtf16(c.name && c.name[0] ? c.name : c.id, info.title, 128);
        toUtf16(c.name && c.name[0] ? c.name : c.id, info.shortTitle, 128);
        toUtf16(c.unit, info.units, 128);
        info.stepCount = stepCountOf(c);
        info.defaultNormalizedValue = toNormalized(c, c.default_value);
        info.unitId = 0;  // the root unit
        info.flags = 0;
        if (c.flags & CAW_PARAMETER_AUTOMATABLE) info.flags |= Vst::ParameterInfo::kCanAutomate;
        if (c.choice_count) info.flags |= Vst::ParameterInfo::kIsList;
        return kResultOk;
    }
    tresult PLUGIN_API getParamStringByValue(Vst::ParamID id, Vst::ParamValue normalized, Vst::String128 out) override {
        const int k = paramIndex(id);
        if (k < 0 || !out) return kInvalidArgument;
        char buffer[256];
        if (!valueText(*params_[k].info, toPlain(*params_[k].info, normalized), buffer, sizeof(buffer))) return kResultFalse;
        toUtf16(buffer, out, 128);
        return kResultOk;
    }
    tresult PLUGIN_API getParamValueByString(Vst::ParamID id, Vst::TChar* string, Vst::ParamValue& normalized) override {
        const int k = paramIndex(id);
        if (k < 0 || !string) return kInvalidArgument;
        const CawParameterInfo& c = *params_[k].info;
        const std::string in = toUtf8(string);
        for (uint32_t i = 0; i < c.choice_count; ++i)
            if (c.choices[i] && in == c.choices[i]) {
                normalized = toNormalized(c, c.minimum + i);
                return kResultOk;
            }
        char* end = nullptr;
        const double v = std::strtod(in.c_str(), &end);
        if (end == in.c_str() || !std::isfinite(v)) return kResultFalse;
        normalized = toNormalized(c, constrain(c, v));
        return kResultOk;
    }
    Vst::ParamValue PLUGIN_API normalizedParamToPlain(Vst::ParamID id, Vst::ParamValue normalized) override {
        const int k = paramIndex(id);
        return k < 0 ? normalized : toPlain(*params_[k].info, normalized);
    }
    Vst::ParamValue PLUGIN_API plainParamToNormalized(Vst::ParamID id, Vst::ParamValue plain) override {
        const int k = paramIndex(id);
        return k < 0 ? plain : toNormalized(*params_[k].info, plain);
    }
    Vst::ParamValue PLUGIN_API getParamNormalized(Vst::ParamID id) override {
        const int k = paramIndex(id);
        return k < 0 ? 0.0 : toNormalized(*params_[k].info, params_[k].edited.load(std::memory_order_relaxed));
    }
    tresult PLUGIN_API setParamNormalized(Vst::ParamID id, Vst::ParamValue normalized) override {
        // The controller's value only: the host sends the processor its changes through process.
        const int k = paramIndex(id);
        if (k < 0) return kInvalidArgument;
        params_[k].edited.store(toPlain(*params_[k].info, normalized), std::memory_order_relaxed);
        return kResultOk;
    }
    tresult PLUGIN_API setComponentHandler(Vst::IComponentHandler* handler) override {
        if (handler) handler->addRef();
        if (handler_) handler_->release();
        handler_ = handler;
        return kResultOk;
    }
    IPlugView* PLUGIN_API createView(FIDString) override { return nullptr; }  // hosts show generic controls

private:
    int paramIndex(Vst::ParamID id) const {
        for (uint32_t k = 0; k < paramCount_; ++k)
            if (params_[k].id == id) return static_cast<int>(k);
        return -1;
    }
    static bool valueText(const CawParameterInfo& c, double value, char* out, size_t capacity) {
        const double v = constrain(c, value);
        if (c.choice_count) {
            const double at = std::round(v - c.minimum);
            if (at < 0 || at >= c.choice_count) return false;
            std::snprintf(out, capacity, "%s", text(c.choices[static_cast<uint32_t>(at)]));
            return true;
        }
        int decimals;
        if (c.step > 0.0) {
            decimals = std::clamp(static_cast<int>(std::ceil(-std::log10(c.step) - 1e-9)), 0, 6);
        } else {
            const double a = std::fabs(v);
            decimals = a >= 100.0 ? 1 : a >= 10.0 ? 2 : 3;
        }
        const char* unit = text(c.unit);
        if (unit[0]) std::snprintf(out, capacity, "%.*f %s", decimals, v, unit);
        else std::snprintf(out, capacity, "%.*f", decimals, v);
        return true;
    }

    bool activate();
    void deactivate() {
        if (!active_) return;
        table_->deactivate(instance_);
        active_ = false;
        applyPending();
    }
    void applyPending() {
        for (uint32_t k = 0; k < paramCount_; ++k) {
            Param& prm = params_[k];
            if (prm.pending.load(std::memory_order_acquire)) {
                prm.jump(prm.pendingValue.load(std::memory_order_relaxed));
                prm.pending.store(false, std::memory_order_release);
            }
        }
    }
    bool saveState(IBStream* stream);
    bool loadState(IBStream* stream, bool component);

    // Events in.
    uint32_t freshNoteId() {
        nextNoteId_ = (nextNoteId_ + 1) & 0x7FFFFFFFu;
        return 0x80000000u | nextNoteId_;
    }
    void pushEvent(uint32_t port, uint32_t frame, uint32_t noteId, uint32_t w0, uint32_t w1, bool isOff = false);
    void endNote(uint32_t port, uint32_t frame, uint32_t i, uint16_t velocity);
    void noteOn(uint32_t port, uint32_t frame, const Vst::NoteOnEvent& e);
    void noteOff(uint32_t port, uint32_t frame, const Vst::NoteOffEvent& e);
    void pressure(uint32_t port, uint32_t frame, const Vst::PolyPressureEvent& e);
    void takeEvent(const Vst::Event& e, uint32_t frame);
    void sendEvents(Vst::IEventList* out, uint32_t offset, uint32_t frames);
    uint32_t collectParams(Vst::IParameterChanges* changes, uint32_t frames);
    void resolveParams(const ParamEvent* events, uint32_t count, uint32_t start, uint32_t frames);
    static void silence(Vst::ProcessData& data);

    std::atomic<uint32> refs_{1};
    const Entry* entry_;
    const CawComponentV3* table_;
    const CawComponentDescriptor* d_;
    CawHost cawHost_{};
    void* instance_ = nullptr;
    int32_t (*quiet_)(void*) = nullptr;
    Vst::IComponentHandler* handler_ = nullptr;

    std::vector<uint32_t> audioIn_, audioOut_, eventIn_, eventOut_, controlIn_, controlOut_, modIn_, modOut_;
    uint32_t inChannels_ = 0, outChannels_ = 0;
    std::unique_ptr<Param[]> params_;
    uint32_t paramCount_ = 0;

    double sampleRate_ = 48000.0;
    uint32_t maxFrames_ = 1024;
    // Allocated in activate.
    uint32_t chunk_ = 0;
    std::vector<double> paramFrames_;
    std::vector<CawParameterValue> values_;
    std::vector<uint32_t> needed_;
    std::vector<uint8_t> isNeeded_;
    std::vector<ParamEvent> paramEvents_;
    std::vector<float> zeros_, scratch_;
    std::vector<const float*> inPtrs_;
    std::vector<float*> outPtrs_;
    std::vector<CawConstAudio> inAudio_;
    std::vector<CawAudio> outAudio_;
    std::vector<const float*> modInPtrs_;
    std::vector<float*> modOutPtrs_;
    std::vector<float> modOutBuffers_;
    std::vector<float> controlInValues_, controlOutValues_;
    std::vector<const float*> controlInPtrs_;
    std::vector<float*> controlOutPtrs_;
    std::vector<EventPort> eventInPorts_;
    std::vector<CawEventInput> eventInputs_;
    std::vector<CawEvent> eventOutBuffer_;
    std::vector<CawEventOutput> eventOutputs_;
    uint32_t nextNoteId_ = 0;

    bool active_ = false;
    // A state load while active waits for the audio thread to leave process (no lock on that side).
    std::atomic<bool> inProcess_{false};
    std::atomic<bool> loadRequested_{false};
};

bool Plugin::activate() {
    if (!instance_) return false;
    const uint32_t chunk = std::min(std::max(maxFrames_, 1u), kMaxChunkFrames);
    if (!table_->activate(instance_, sampleRate_, chunk)) return false;
    try {
        chunk_ = chunk;
        paramFrames_.assign(size_t(paramCount_) * chunk, 0.0);
        values_.assign(paramCount_, CawParameterValue{nullptr, 0.0});
        needed_.assign(paramCount_, 0);
        isNeeded_.assign(paramCount_, 0);
        paramEvents_.assign(kParamEventCapacity, ParamEvent{});
        zeros_.assign(chunk, 0.0f);
        scratch_.assign(size_t(outChannels_) * chunk, 0.0f);
        inPtrs_.assign(inChannels_, nullptr);
        outPtrs_.assign(outChannels_, nullptr);
        inAudio_.assign(audioIn_.size(), CawConstAudio{});
        outAudio_.assign(audioOut_.size(), CawAudio{});
        modInPtrs_.assign(modIn_.size(), zeros_.data());
        modOutBuffers_.assign(modOut_.size() * size_t(chunk), 0.0f);
        modOutPtrs_.assign(modOut_.size(), nullptr);
        for (size_t k = 0; k < modOut_.size(); ++k) modOutPtrs_[k] = modOutBuffers_.data() + k * chunk;
        controlInValues_.assign(controlIn_.size(), 0.0f);
        controlInPtrs_.assign(controlIn_.size(), nullptr);
        for (size_t k = 0; k < controlIn_.size(); ++k) {
            controlInValues_[k] = portAt(*d_, controlIn_[k]).default_value;
            controlInPtrs_[k] = &controlInValues_[k];
        }
        controlOutValues_.assign(controlOut_.size(), 0.0f);
        controlOutPtrs_.assign(controlOut_.size(), nullptr);
        for (size_t k = 0; k < controlOut_.size(); ++k) {
            controlOutValues_[k] = portAt(*d_, controlOut_[k]).default_value;
            controlOutPtrs_[k] = &controlOutValues_[k];
        }
        eventInPorts_.assign(eventIn_.size(), EventPort{});
        for (EventPort& port : eventInPorts_) {
            port.events.assign(kEventCapacity, CawEvent{});
            port.notes.assign(kMaxNotes, Note{0, 0});
        }
        eventInputs_.assign(eventIn_.size(), CawEventInput{});
        eventOutBuffer_.assign(eventOut_.size() * size_t(kEventCapacity), CawEvent{});
        eventOutputs_.assign(eventOut_.size(), CawEventOutput{});
    } catch (...) {
        table_->deactivate(instance_);
        return false;
    }
    // A fresh start: the component and the notes begin again (VST3 has no separate reset).
    table_->reset(instance_);
    for (uint32_t k = 0; k < paramCount_; ++k) {
        params_[k].current = params_[k].target;
        params_[k].rampLeft = 0;
    }
    active_ = true;
    return true;
}

bool Plugin::saveState(IBStream* stream) {
    if (!stream || !instance_) return false;
    try {
        std::vector<uint8_t> state(d_->max_state_bytes ? d_->max_state_bytes : 1);
        uint32_t written = 0, version = 0;
        // Safe while processing (caw_component.h: save_state may run alongside process).
        if (!table_->save_state(instance_, state.data(), d_->max_state_bytes, &written, &version) ||
            written > d_->max_state_bytes)
            return false;
        std::vector<uint8_t> b;
        putU32(b, kStateMagic);
        putU32(b, kStateFormat);
        putText(b, d_->id);
        putU32(b, version);
        putU32(b, paramCount_);
        for (uint32_t k = 0; k < paramCount_; ++k) {
            putText(b, params_[k].info->id);
            putF64(b, params_[k].shown.load(std::memory_order_relaxed));
        }
        putU32(b, written);
        b.insert(b.end(), state.begin(), state.begin() + written);
        size_t at = 0;
        while (at < b.size()) {
            int32 n = 0;
            const size_t left = std::min<size_t>(b.size() - at, 1u << 30);
            if (stream->write(b.data() + at, static_cast<int32>(left), &n) != kResultOk || n <= 0) return false;
            at += static_cast<size_t>(n);
        }
        return true;
    } catch (...) {
        return false;
    }
}

// component: the component's setState (loads the component and the values); else the controller's
// setComponentState (the values the generic editor shows).
bool Plugin::loadState(IBStream* stream, bool component) {
    if (!stream || !instance_) return false;
    try {
        std::vector<uint8_t> b;
        if (!readStream(stream, b)) return false;
        Reader r{b};
        if (r.u32() != kStateMagic || r.u32() != kStateFormat || r.str() != d_->id || !r.ok) return false;
        const uint32_t version = r.u32();
        const uint32_t count = r.u32();
        if (!r.ok || count > kMaxParameters) return false;
        std::vector<double> values(paramCount_);
        for (uint32_t k = 0; k < paramCount_; ++k) values[k] = params_[k].info->default_value;
        for (uint32_t i = 0; i < count; ++i) {
            const std::string id = r.str();
            const double v = r.f64();
            if (!r.ok) return false;
            if (!std::isfinite(v)) continue;  // a damaged value keeps the default
            for (uint32_t k = 0; k < paramCount_; ++k)
                if (id == params_[k].info->id) values[k] = v;  // unknown ids (older versions) are ignored
        }
        const uint32_t size = r.u32();
        if (!r.ok || size > d_->max_state_bytes || b.size() - r.at != size) return false;
        if (!component) {
            for (uint32_t k = 0; k < paramCount_; ++k)
                params_[k].edited.store(clampTo(*params_[k].info, values[k]), std::memory_order_relaxed);
            return true;
        }
        static const uint8_t kNone = 0;
        const uint8_t* bytes = size ? b.data() + r.at : &kNone;
        bool ok;
        if (!active_) {
            ok = table_->load_state(instance_, bytes, size, version) != 0;
            if (ok)
                for (uint32_t k = 0; k < paramCount_; ++k) params_[k].jump(values[k]);
        } else {
            // The component never loads while it processes: park the audio thread (it outputs silence
            // meanwhile; it never waits), load, then hand the values over.
            loadRequested_.store(true, std::memory_order_seq_cst);
            const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (inProcess_.load(std::memory_order_seq_cst)) {
                if (std::chrono::steady_clock::now() > until) {
                    loadRequested_.store(false, std::memory_order_seq_cst);
                    return false;
                }
                std::this_thread::yield();
            }
            ok = table_->load_state(instance_, bytes, size, version) != 0;
            if (ok)
                for (uint32_t k = 0; k < paramCount_; ++k) {
                    const double v = clampTo(*params_[k].info, values[k]);
                    params_[k].pendingValue.store(v, std::memory_order_relaxed);
                    params_[k].shown.store(v, std::memory_order_relaxed);
                    params_[k].edited.store(v, std::memory_order_relaxed);
                    params_[k].pending.store(true, std::memory_order_release);
                }
            loadRequested_.store(false, std::memory_order_seq_cst);
        }
        return ok;
    } catch (...) {
        return false;
    }
}

// ---- Events in

// Room for the tracked notes' offs (up to half the list) is kept back from everything but an off, so a full list
// drops an on or a pressure, never the off of a note it delivered.
void Plugin::pushEvent(uint32_t port, uint32_t frame, uint32_t noteId, uint32_t w0, uint32_t w1, bool isOff) {
    CawEventInput& in = eventInputs_[port];
    const uint32_t keep = isOff ? 0u : std::min(eventInPorts_[port].noteCount, kEventCapacity / 2);
    if (in.count + keep >= kEventCapacity) return;  // full: dropped
    CawEvent& e = eventInPorts_[port].events[in.count++];
    e.frame = frame;
    e.kind = CAW_EVENT_NOTE;
    e.flags = 0;
    e.note_id = noteId;
    e.data[0] = w0;
    e.data[1] = w1;
    e.data[2] = 0;
    e.data[3] = 0;
}

void Plugin::endNote(uint32_t port, uint32_t frame, uint32_t i, uint16_t velocity) {
    EventPort& e = eventInPorts_[port];
    const Note n = e.notes[i];
    for (uint32_t j = i + 1; j < e.noteCount; ++j) e.notes[j - 1] = e.notes[j];
    --e.noteCount;
    pushEvent(port, frame, n.id, voiceWord(0x8, n.slot / 128, n.slot % 128, 0), uint32_t(velocity) << 16, true);
}

void Plugin::noteOn(uint32_t port, uint32_t frame, const Vst::NoteOnEvent& on) {
    if (on.channel < 0 || on.channel > 15 || on.pitch < 0 || on.pitch > 127) return;
    const uint32_t slot = uint32_t(on.channel) * 128 + uint32_t(on.pitch);
    const uint32_t id = on.noteId >= 0 ? uint32_t(on.noteId) + 1u : freshNoteId();
    EventPort& e = eventInPorts_[port];
    // A note on this key that no later off could name ends first: one without a host id, or any note when this one
    // has none. Notes with host ids on one key are kept apart, so an off by id ends the right one.
    for (uint32_t i = e.noteCount; i-- > 0;)
        if (e.notes[i].slot == slot && (on.noteId < 0 || (e.notes[i].id & 0x80000000u) || e.notes[i].id == id))
            endNote(port, frame, i, 0);
    if (e.noteCount == kMaxNotes) endNote(port, frame, 0, 0);  // the oldest
    e.notes[e.noteCount++] = {slot, id};
    pushEvent(port, frame, id, voiceWord(0x9, uint32_t(on.channel), uint32_t(on.pitch), 0),
              uint32_t(unit16(on.velocity)) << 16);
}

void Plugin::noteOff(uint32_t port, uint32_t frame, const Vst::NoteOffEvent& off) {
    if (off.channel < 0 || off.channel > 15 || off.pitch < 0 || off.pitch > 127) return;
    const uint32_t slot = uint32_t(off.channel) * 128 + uint32_t(off.pitch);
    const uint16_t velocity = unit16(off.velocity);
    EventPort& e = eventInPorts_[port];
    bool ended = false;
    if (off.noteId >= 0) {
        const uint32_t id = uint32_t(off.noteId) + 1u;
        for (uint32_t i = e.noteCount; i-- > 0;)
            if (e.notes[i].id == id) {
                endNote(port, frame, i, velocity);
                ended = true;
            }
        if (!ended)  // not seen starting: passed on with its id
            pushEvent(port, frame, id, voiceWord(0x8, slot / 128, slot % 128, 0), uint32_t(velocity) << 16, true);
        return;
    }
    for (uint32_t i = e.noteCount; i-- > 0;)  // no id: every note on the key
        if (e.notes[i].slot == slot) {
            endNote(port, frame, i, velocity);
            ended = true;
        }
    if (!ended) pushEvent(port, frame, 0, voiceWord(0x8, slot / 128, slot % 128, 0), uint32_t(velocity) << 16, true);
}

void Plugin::pressure(uint32_t port, uint32_t frame, const Vst::PolyPressureEvent& p) {
    if (p.channel < 0 || p.channel > 15 || p.pitch < 0 || p.pitch > 127) return;
    const uint32_t slot = uint32_t(p.channel) * 128 + uint32_t(p.pitch);
    const EventPort& e = eventInPorts_[port];
    uint32_t id = p.noteId >= 0 ? uint32_t(p.noteId) + 1u : 0u;
    if (id == 0)
        for (uint32_t i = e.noteCount; i-- > 0 && id == 0;)
            if (e.notes[i].slot == slot) id = e.notes[i].id;  // the latest note on the key
    pushEvent(port, frame, id, voiceWord(0xA, uint32_t(p.channel), uint32_t(p.pitch), 0),
              unit32(std::isfinite(p.pressure) ? p.pressure : 0.0f));
}

void Plugin::takeEvent(const Vst::Event& e, uint32_t frame) {
    if (eventIn_.empty() || e.busIndex < 0 || static_cast<size_t>(e.busIndex) >= eventIn_.size()) return;
    const uint32_t port = static_cast<uint32_t>(e.busIndex);
    switch (e.type) {
        case Vst::Event::kNoteOnEvent:
            if (e.noteOn.velocity > 0.0f) noteOn(port, frame, e.noteOn);
            else {  // a velocity-0 note on is an off, as in MIDI
                Vst::NoteOffEvent off{};
                off.channel = e.noteOn.channel;
                off.pitch = e.noteOn.pitch;
                off.noteId = e.noteOn.noteId;
                noteOff(port, frame, off);
            }
            return;
        case Vst::Event::kNoteOffEvent: noteOff(port, frame, e.noteOff); return;
        case Vst::Event::kPolyPressureEvent: pressure(port, frame, e.polyPressure); return;
        default: return;  // sysex, note expression, chords and scales are not passed on
    }
}

// ---- Events out: the component's notes and poly pressure as VST3 events

void Plugin::sendEvents(Vst::IEventList* out, uint32_t offset, uint32_t frames) {
    if (!out) return;
    for (size_t port = 0; port < eventOutputs_.size(); ++port) {
        const CawEventOutput& o = eventOutputs_[port];
        for (uint32_t i = 0; i < o.count && i < o.capacity; ++i) {
            const CawEvent& c = o.events[i];
            if (c.frame >= frames || c.kind != CAW_EVENT_NOTE || (c.data[0] >> 28) != 0x4) continue;
            const uint32_t status = (c.data[0] >> 20) & 0xFu;
            Vst::Event e{};
            e.busIndex = static_cast<int32>(port);
            e.sampleOffset = static_cast<int32>(offset + c.frame);
            const int16 channel = int16((c.data[0] >> 16) & 0xFu), key = int16((c.data[0] >> 8) & 0x7Fu);
            const int32 noteId = c.note_id >= 1 && c.note_id <= 0x7FFFFFFFu ? int32(c.note_id - 1) : -1;
            if (status == 0x9) {
                e.type = Vst::Event::kNoteOnEvent;
                e.noteOn.channel = channel;
                e.noteOn.pitch = key;
                e.noteOn.velocity = float((c.data[1] >> 16) / 65535.0);
                e.noteOn.noteId = noteId;
            } else if (status == 0x8) {
                e.type = Vst::Event::kNoteOffEvent;
                e.noteOff.channel = channel;
                e.noteOff.pitch = key;
                e.noteOff.velocity = float((c.data[1] >> 16) / 65535.0);
                e.noteOff.noteId = noteId;
            } else if (status == 0xA) {
                e.type = Vst::Event::kPolyPressureEvent;
                e.polyPressure.channel = channel;
                e.polyPressure.pitch = key;
                e.polyPressure.pressure = float(c.data[1] / 4294967295.0);
                e.polyPressure.noteId = noteId;
            } else {
                continue;  // other MIDI 2.0 messages have no VST3 event
            }
            out->addEvent(e);
        }
    }
}

// ---- Parameters

// Every queue point of the block as a change at its frame, sorted by frame (stable: a queue's points stay in order).
uint32_t Plugin::collectParams(Vst::IParameterChanges* changes, uint32_t frames) {
    uint32_t count = 0;
    if (!changes) return 0;
    const int32 queues = changes->getParameterCount();
    for (int32 q = 0; q < queues; ++q) {
        Vst::IParamValueQueue* queue = changes->getParameterData(q);
        if (!queue) continue;
        const int k = paramIndex(queue->getParameterId());
        if (k < 0) continue;
        const int32 points = queue->getPointCount();
        for (int32 i = 0; i < points && count < kParamEventCapacity; ++i) {
            int32 offset = 0;
            Vst::ParamValue v = 0.0;
            if (queue->getPoint(i, offset, v) != kResultOk) continue;
            const uint32_t frame = frames == 0 ? 0u : uint32_t(std::clamp<int32>(offset, 0, int32(frames) - 1));
            ParamEvent pe{frame, uint32_t(k), toPlain(*params_[k].info, v)};
            uint32_t at = count++;
            for (; at > 0 && paramEvents_[at - 1].frame > frame; --at) paramEvents_[at] = paramEvents_[at - 1];
            paramEvents_[at] = pe;
        }
    }
    return count;
}

// Per-frame values for the parameters that change in this piece; one value for the rest.
void Plugin::resolveParams(const ParamEvent* events, uint32_t count, uint32_t start, uint32_t frames) {
    uint32_t neededCount = 0;
    for (uint32_t k = 0; k < paramCount_; ++k) isNeeded_[k] = params_[k].rampLeft != 0;
    for (uint32_t e = 0; e < count; ++e) isNeeded_[events[e].index] = 1;
    for (uint32_t k = 0; k < paramCount_; ++k) {
        if (isNeeded_[k]) needed_[neededCount++] = k;
        else values_[k] = {nullptr, params_[k].value()};
    }
    if (neededCount == 0) return;
    uint32_t e = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        // A change at frame i takes effect from frame i, as if the host split the block there.
        for (; e < count && events[e].frame - start <= i; ++e) params_[events[e].index].set(events[e].value);
        for (uint32_t n = 0; n < neededCount; ++n) {
            const uint32_t k = needed_[n];
            params_[k].advance();
            paramFrames_[size_t(k) * chunk_ + i] = params_[k].value();
        }
    }
    for (uint32_t n = 0; n < neededCount; ++n) {
        const uint32_t k = needed_[n];
        const double* frame0 = paramFrames_.data() + size_t(k) * chunk_;
        values_[k] = {frame0, frame0[0]};
    }
}

// ---- Process

void Plugin::silence(Vst::ProcessData& data) {
    for (int32 k = 0; k < data.numOutputs && data.outputs; ++k) {
        Vst::AudioBusBuffers& b = data.outputs[k];
        if (!b.channelBuffers32) continue;
        for (int32 c = 0; c < b.numChannels; ++c)
            if (b.channelBuffers32[c]) std::memset(b.channelBuffers32[c], 0, sizeof(float) * size_t(data.numSamples));
    }
}

tresult PLUGIN_API Plugin::process(Vst::ProcessData& data) {
    if (!active_) return kResultFalse;
    if (data.symbolicSampleSize != Vst::kSample32 || data.numSamples < 0) return kResultFalse;
    inProcess_.store(true, std::memory_order_seq_cst);
    if (loadRequested_.load(std::memory_order_seq_cst)) {  // a state is loading on another thread
        inProcess_.store(false, std::memory_order_seq_cst);
        silence(data);
        return kResultOk;
    }
    applyPending();
    const uint32_t frames = static_cast<uint32_t>(data.numSamples);
    // Bus lists the host did not give count as none (a missing input reads silence, a missing output goes to scratch).
    if (!data.inputs) data.numInputs = 0;
    if (!data.outputs) data.numOutputs = 0;

    // A block of 0 frames only carries parameter changes (a flush): they apply at once.
    const uint32_t paramEventCount = collectParams(data.inputParameterChanges, frames);
    if (frames == 0) {
        for (uint32_t e = 0; e < paramEventCount; ++e) params_[paramEvents_[e].index].set(paramEvents_[e].value);
        inProcess_.store(false, std::memory_order_seq_cst);
        return kResultOk;
    }
    // The host's buffers must match the buses; a missing input reads silence and a missing output goes to scratch.
    for (int32 k = 0; k < data.numInputs && size_t(k) < audioIn_.size(); ++k) {
        const Vst::AudioBusBuffers& b = data.inputs[k];
        if (!b.channelBuffers32 || b.numChannels != int32(channelsOf(portAt(*d_, audioIn_[k])))) {
            inProcess_.store(false, std::memory_order_seq_cst);
            silence(data);
            return kResultFalse;
        }
    }
    for (int32 k = 0; k < data.numOutputs && size_t(k) < audioOut_.size(); ++k) {
        const Vst::AudioBusBuffers& b = data.outputs[k];
        if (!b.channelBuffers32 || b.numChannels != int32(channelsOf(portAt(*d_, audioOut_[k])))) {
            inProcess_.store(false, std::memory_order_seq_cst);
            silence(data);
            return kResultFalse;
        }
    }

    const Vst::ProcessContext* t = data.processContext;
    const bool playing = t && (t->state & Vst::ProcessContext::kPlaying);
    CawTransport transport{};
    double startBeat = 0.0;
    if (playing) {
        transport.struct_size = sizeof(CawTransport);
        transport.flags = CAW_TRANSPORT_PLAYING;
        transport.tempo = (t->state & Vst::ProcessContext::kTempoValid) && t->tempo > 0.0 ? t->tempo : 120.0;
        transport.beats_per_bar = 4;
        if ((t->state & Vst::ProcessContext::kTimeSigValid) && t->timeSigNumerator > 0 && t->timeSigDenominator > 0)
            transport.beats_per_bar = std::max(1u, (uint32_t(t->timeSigNumerator) * 4u + uint32_t(t->timeSigDenominator) / 2u) /
                                                       uint32_t(t->timeSigDenominator));  // in quarter notes
        if (t->state & Vst::ProcessContext::kProjectTimeMusicValid) startBeat = t->projectTimeMusic;
    }

    Vst::IEventList* in = data.inputEvents;
    const int32 eventCount = in ? in->getEventCount() : 0;
    int32 next = 0;
    uint32_t nextParam = 0;
    bool ok = true;

    for (uint32_t start = 0; start < frames && ok; start += chunk_) {
        const uint32_t len = std::min(chunk_, frames - start);
        const bool last = start + len >= frames;
        for (size_t k = 0; k < eventInputs_.size(); ++k) eventInputs_[k] = {eventInPorts_[k].events.data(), 0};
        for (; next < eventCount; ++next) {
            Vst::Event e{};
            if (in->getEvent(next, e) != kResultOk) continue;
            // Events are sorted by time; one past the block lands on its last frame.
            uint32_t time = uint32_t(std::clamp<int32>(e.sampleOffset, 0, int32(frames) - 1));
            if (time >= start + len && !last) break;
            time = std::max(time, start);
            takeEvent(e, std::min(time - start, len - 1));
        }
        // Keep each list non-decreasing (the C.A.W contract) even if a host sent events out of order.
        for (size_t k = 0; k < eventInputs_.size(); ++k) {
            CawEvent* events = eventInPorts_[k].events.data();
            for (uint32_t i = 1; i < eventInputs_[k].count; ++i)
                events[i].frame = std::max(events[i].frame, events[i - 1].frame);
        }
        const uint32_t firstParam = nextParam;
        while (nextParam < paramEventCount && (last || paramEvents_[nextParam].frame < start + len)) ++nextParam;
        resolveParams(paramEvents_.data() + firstParam, nextParam - firstParam, start, len);

        uint32_t ch = 0;
        for (size_t k = 0; k < audioIn_.size(); ++k) {
            const uint32_t n = channelsOf(portAt(*d_, audioIn_[k]));
            const bool given = int32(k) < data.numInputs;
            for (uint32_t c = 0; c < n; ++c) inPtrs_[ch + c] = given ? data.inputs[k].channelBuffers32[c] + start : zeros_.data();
            inAudio_[k] = {inPtrs_.data() + ch, n, len};
            ch += n;
        }
        ch = 0;
        for (size_t k = 0; k < audioOut_.size(); ++k) {
            const uint32_t n = channelsOf(portAt(*d_, audioOut_[k]));
            const bool given = int32(k) < data.numOutputs;
            for (uint32_t c = 0; c < n; ++c)
                outPtrs_[ch + c] = given ? data.outputs[k].channelBuffers32[c] + start : scratch_.data() + size_t(ch + c) * chunk_;
            outAudio_[k] = {outPtrs_.data() + ch, n, len};
            ch += n;
        }
        for (size_t k = 0; k < eventOutputs_.size(); ++k)
            eventOutputs_[k] = {eventOutBuffer_.data() + k * kEventCapacity, kEventCapacity, 0};

        CawTransport pieceTransport = transport;
        if (playing) pieceTransport.beat = startBeat + double(start) * transport.tempo / 60.0 / sampleRate_;

        CawProcessBlock block{};
        block.struct_size = sizeof(CawProcessBlock);
        block.frames = len;
        block.sample_rate = sampleRate_;
        block.audio_in = inAudio_.data();
        block.audio_in_count = static_cast<uint32_t>(inAudio_.size());
        block.audio_out = outAudio_.data();
        block.audio_out_count = static_cast<uint32_t>(outAudio_.size());
        block.modulation_in = modInPtrs_.data();
        block.modulation_in_count = static_cast<uint32_t>(modInPtrs_.size());
        block.modulation_out = modOutPtrs_.data();
        block.modulation_out_count = static_cast<uint32_t>(modOutPtrs_.size());
        block.control_in = controlInPtrs_.data();
        block.control_in_count = static_cast<uint32_t>(controlInPtrs_.size());
        block.control_out = controlOutPtrs_.data();
        block.control_out_count = static_cast<uint32_t>(controlOutPtrs_.size());
        block.event_in = eventInputs_.data();
        block.event_in_count = static_cast<uint32_t>(eventInputs_.size());
        block.event_out = eventOutputs_.data();
        block.event_out_count = static_cast<uint32_t>(eventOutputs_.size());
        block.parameters = values_.data();
        block.parameter_count = paramCount_;
        block.transport = playing ? &pieceTransport : nullptr;
        ok = table_->process(instance_, &block) != 0;
        if (ok) sendEvents(data.outputEvents, start, len);
    }
    inProcess_.store(false, std::memory_order_seq_cst);
    if (!ok) {  // the component's outputs are undefined after a failure (caw_component.h)
        silence(data);
        return kResultFalse;
    }
    // A component that has fallen silent says so through the silence flags.
    if (quiet_ && quiet_(instance_) == 1)
        for (int32 k = 0; k < data.numOutputs; ++k) {
            Vst::AudioBusBuffers& b = data.outputs[k];
            b.silenceFlags = b.numChannels >= 64 ? ~uint64(0) : (uint64(1) << b.numChannels) - 1;
        }
    else
        for (int32 k = 0; k < data.numOutputs; ++k) data.outputs[k].silenceFlags = 0;
    return kResultOk;
}

// ---- The factory

class Factory final : public IPluginFactory2 {
public:
    tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
        if (!obj) return kInvalidArgument;
        if (FUnknownPrivate::iidEqual(iid, FUnknown::iid) || FUnknownPrivate::iidEqual(iid, IPluginFactory::iid) ||
            FUnknownPrivate::iidEqual(iid, IPluginFactory2::iid)) {
            *obj = this;
            return kResultOk;
        }
        *obj = nullptr;
        return kNoInterface;
    }
    uint32 PLUGIN_API addRef() override { return 1; }   // static: lives as long as the library
    uint32 PLUGIN_API release() override { return 1; }

    tresult PLUGIN_API getFactoryInfo(PFactoryInfo* info) override {
        if (!info) return kInvalidArgument;
        *info = {};
        copyText(info->vendor, PFactoryInfo::kNameSize, CAW_VST3_VENDOR);
        copyText(info->url, PFactoryInfo::kURLSize, CAW_VST3_URL);
        copyText(info->email, PFactoryInfo::kEmailSize, CAW_VST3_EMAIL);
        info->flags = PFactoryInfo::kUnicode;
        return kResultOk;
    }
    int32 PLUGIN_API countClasses() override { return static_cast<int32>(bundle().entries.size()); }
    tresult PLUGIN_API getClassInfo(int32 index, PClassInfo* info) override {
        const Entry* e = at(index);
        if (!e || !info) return kInvalidArgument;
        *info = {};
        std::memcpy(info->cid, e->cid, sizeof(TUID));
        info->cardinality = PClassInfo::kManyInstances;
        copyText(info->category, PClassInfo::kCategorySize, kVstAudioEffectClass);
        copyText(info->name, PClassInfo::kNameSize, e->name.c_str());
        return kResultOk;
    }
    tresult PLUGIN_API getClassInfo2(int32 index, PClassInfo2* info) override {
        const Entry* e = at(index);
        if (!e || !info) return kInvalidArgument;
        *info = {};
        std::memcpy(info->cid, e->cid, sizeof(TUID));
        info->cardinality = PClassInfo::kManyInstances;
        copyText(info->category, PClassInfo::kCategorySize, kVstAudioEffectClass);
        copyText(info->name, PClassInfo::kNameSize, e->name.c_str());
        info->classFlags = 0;
        copyText(info->subCategories, PClassInfo2::kSubCategoriesSize, e->subCategories.c_str());
        copyText(info->vendor, PClassInfo2::kVendorSize, CAW_VST3_VENDOR);
        copyText(info->version, PClassInfo2::kVersionSize, e->version.c_str());
        copyText(info->sdkVersion, PClassInfo2::kVersionSize, kVstVersionString);
        return kResultOk;
    }
    tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void** obj) override {
        if (!obj) return kInvalidArgument;
        *obj = nullptr;
        if (!cid || !iid) return kInvalidArgument;
        const Entry* entry = nullptr;
        for (const auto& e : bundle().entries)
            if (FUnknownPrivate::iidEqual(e->cid, cid)) entry = e.get();
        if (!entry) return kInvalidArgument;
        Plugin* p = new (std::nothrow) Plugin(entry);
        if (!p) return kOutOfMemory;
        const tresult r = p->queryInterface(iid, obj);
        p->release();  // the query's reference keeps it, or it goes
        return r;
    }

private:
    static const Entry* at(int32 index) {
        const auto& entries = bundle().entries;
        return index >= 0 && static_cast<size_t>(index) < entries.size() ? entries[index].get() : nullptr;
    }
};

Factory& factory() {
    static Factory f;
    return f;
}

}  // namespace

// ---- The module's exports

extern "C" {
SMTG_EXPORT_SYMBOL IPluginFactory* PLUGIN_API GetPluginFactory() {
    if (!readBundle()) return nullptr;
    return &factory();
}
#if SMTG_OS_WINDOWS
SMTG_EXPORT_SYMBOL bool InitDll() { return readBundle(); }
SMTG_EXPORT_SYMBOL bool ExitDll() { return true; }
#elif SMTG_OS_MACOS
SMTG_EXPORT_SYMBOL bool bundleEntry(void*) { return readBundle(); }
SMTG_EXPORT_SYMBOL bool bundleExit() { return true; }
#else
SMTG_EXPORT_SYMBOL bool ModuleEntry(void*) { return readBundle(); }
SMTG_EXPORT_SYMBOL bool ModuleExit() { return true; }
#endif
}
