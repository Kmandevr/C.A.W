// Exports a C++ ModuleProcessor as a C.A.W component through the stable C interface (caw_component.h).
#pragma once

#include <cstddef>
#include <deque>
#include <new>
#include <string>
#include <string_view>
#include <vector>

#include "display.hpp"
#include "module.hpp"

#if defined(_WIN32)
#define CAW_COMPONENT_EXPORT __declspec(dllexport)
#else
#define CAW_COMPONENT_EXPORT __attribute__((visibility("default")))
#endif

// Usage, in exactly one source file of the component library:
//
//     CAW_EXPORT_COMPONENT(MyProcessor, kMyDescriptor)
//
// MyProcessor derives from caw::ModuleProcessor and is default-constructible; kMyDescriptor is the
// caw::ModuleDescriptor its descriptor() returns, alive as long as the library. The macro defines
// the one exported symbol, caw_get_component_v3, whose table forwards every call to MyProcessor
// and catches any exception at the boundary (it reports failure instead).
#define CAW_EXPORT_COMPONENT(Type, descriptorExpr)                                                  \
    extern "C" CAW_COMPONENT_EXPORT const CawComponentV3* caw_get_component_v3(uint32_t index) {   \
        if (index != 0) return nullptr;                                                              \
        /* A static in the library: built on the first call, destroyed when the library unloads. */ \
        static ::caw::component_detail::Exported exported;                                          \
        static const bool ready = ::caw::component_detail::exportComponent<Type>(descriptorExpr, exported); \
        return ready ? &exported.table : nullptr;                                                   \
    }

// A bundle: several components in one library, in this order (index 0, 1, ...). Each Type's
// descriptor() must return a descriptor that lives as long as the library.
// Listing builds one temporary instance of each Type up to the one a host asks for, so keep
// constructors cheap: allocate large buffers in activate(), not in the constructor.
#define CAW_EXPORT_COMPONENTS(...)                                                                  \
    extern "C" CAW_COMPONENT_EXPORT const CawComponentV3* caw_get_component_v3(uint32_t index) {   \
        return ::caw::component_detail::bundleAt<__VA_ARGS__>(index);                               \
    }

namespace caw::component_detail {

// The C descriptor and table, built once from the C++ descriptor and kept for the library's life.
struct Exported {
    std::deque<std::string> strings;  // a deque keeps each string's address stable as it grows
    std::vector<CawPortInfo> ports;
    std::vector<CawParameterInfo> parameters;
    std::vector<std::vector<const char*>> choices;
    std::vector<CawUiControlInfo> uiControls;
    CawComponentDescriptor descriptor{};
    CawComponentV3 table{};

    const char* text(std::string_view value) {
        strings.emplace_back(value);
        return strings.back().c_str();
    }
};

// One instance: the processor plus the C++ views the host's C block is copied into each call,
// sized from the descriptor at create so process never allocates.
template <class Type>
struct Instance {
    Type processor;
    std::vector<ConstChannelBufferView> audioIn;
    std::vector<ChannelBufferView> audioOut;
    std::vector<EventInput> eventIn;
    std::vector<EventOutput> eventOut;
    std::vector<ParameterValue> parameters;
    Transport transport;  // the block's transport, converted (preallocated with the instance)
    uint32_t maxFrames = 0;  // from activate; longer blocks are refused
};

template <class Type>
Instance<Type>* instance(void* p) noexcept { return static_cast<Instance<Type>*>(p); }

template <class Type>
void* create(const CawHost* host) noexcept {
    profile_detail::attach(host);  // the plug-in benchmark's sections (CAW_PROFILE_SCOPE), when the host has them
    try {
        auto* made = new Instance<Type>();
        const ModuleDescriptor& d = made->processor.descriptor();
        uint32_t audioIn = 0, audioOut = 0, eventIn = 0, eventOut = 0;
        for (uint32_t p = 0; p < d.portCount; ++p) {
            if (d.ports[p].type == PortType::Audio) ++(d.ports[p].input ? audioIn : audioOut);
            if (d.ports[p].type == PortType::Event) ++(d.ports[p].input ? eventIn : eventOut);
        }
        made->audioIn.resize(audioIn);
        made->audioOut.resize(audioOut);
        made->eventIn.resize(eventIn);
        made->eventOut.resize(eventOut);
        made->parameters.resize(d.parameterCount);
        return made;
    } catch (...) {
        return nullptr;
    }
}

template <class Type>
void destroy(void* p) noexcept {
    try {
        delete instance<Type>(p);
    } catch (...) {
    }
}

template <class Type>
int32_t activate(void* p, double sampleRate, uint32_t maxFrames) noexcept {
    try {
        Instance<Type>& self = *instance<Type>(p);
        const bool ok = maxFrames > 0 && self.processor.activate(sampleRate, maxFrames);
        self.maxFrames = ok ? maxFrames : 0;
        return ok ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

template <class Type>
void deactivate(void* p) noexcept {
    try {
        instance<Type>(p)->processor.deactivate();
    } catch (...) {
    }
}

template <class Type>
void reset(void* p) noexcept {
    try {
        instance<Type>(p)->processor.reset();
    } catch (...) {
    }
}

template <class Type>
int32_t process(void* p, const CawProcessBlock* block) noexcept {
    try {
        // The fields up to the transport are required; a host without the transport field is fine.
        if (!p || !block || block->struct_size < offsetof(CawProcessBlock, transport)) return 0;
        Instance<Type>& self = *instance<Type>(p);
        if (block->frames == 0 || block->frames > self.maxFrames || block->audio_in_count > self.audioIn.size() || block->audio_out_count > self.audioOut.size() ||
            block->event_in_count > self.eventIn.size() || block->event_out_count > self.eventOut.size() ||
            block->parameter_count > self.parameters.size())
            return 0;
        for (uint32_t k = 0; k < block->audio_in_count; ++k) {
            const CawConstAudio& a = block->audio_in[k];
            self.audioIn[k] = {a.channels, a.channel_count, a.frames};
        }
        for (uint32_t k = 0; k < block->audio_out_count; ++k) {
            const CawAudio& a = block->audio_out[k];
            self.audioOut[k] = {a.channels, a.channel_count, a.frames};
        }
        // Event records have the same layout on both sides (checked in module.hpp).
        for (uint32_t k = 0; k < block->event_in_count; ++k)
            self.eventIn[k] = {reinterpret_cast<const Event*>(block->event_in[k].events), block->event_in[k].count};
        for (uint32_t k = 0; k < block->event_out_count; ++k)
            self.eventOut[k] = {reinterpret_cast<Event*>(block->event_out[k].events), block->event_out[k].capacity, 0};
        for (uint32_t k = 0; k < block->parameter_count; ++k)
            self.parameters[k] = {block->parameters[k].samples, block->parameters[k].value};
        const Transport* transport = nullptr;
        if (block->struct_size >= offsetof(CawProcessBlock, transport) + sizeof(block->transport) && block->transport &&
            block->transport->struct_size >= sizeof(CawTransport)) {
            const CawTransport& t = *block->transport;
            self.transport = {t.tempo, t.beat, t.beats_per_bar, (t.flags & CAW_TRANSPORT_PLAYING) != 0};
            transport = &self.transport;
        }

        ModuleProcessor& processor = self.processor;
        bool ok;
        if (processor.usesProcessPorts()) {
            ProcessBlock ports;
            ports.frames = block->frames;
            ports.sampleRate = block->sample_rate;
            ports.audioIn = self.audioIn.data();
            ports.audioInCount = block->audio_in_count;
            ports.audioOut = self.audioOut.data();
            ports.audioOutCount = block->audio_out_count;
            ports.modulationIn = block->modulation_in;
            ports.modulationInCount = block->modulation_in_count;
            ports.modulationOut = block->modulation_out;
            ports.modulationOutCount = block->modulation_out_count;
            ports.controlIn = block->control_in;
            ports.controlInCount = block->control_in_count;
            ports.controlOut = block->control_out;
            ports.controlOutCount = block->control_out_count;
            ports.eventIn = self.eventIn.data();
            ports.eventInCount = block->event_in_count;
            ports.eventOut = self.eventOut.data();
            ports.eventOutCount = block->event_out_count;
            ports.parameters = self.parameters.data();
            ports.parameterCount = block->parameter_count;
            ports.transport = transport;
            // 3.1: the voice bus, when the host's block has the field (the C and C++ structs share a layout).
            if (block->struct_size >= offsetof(CawProcessBlock, voices) + sizeof(block->voices) && block->voices &&
                block->voices->struct_size >= sizeof(CawVoiceBus) && block->voices->lane_stride >= sizeof(CawVoiceLane) &&
                (block->voices->lane_count == 0 || block->voices->lanes) && block->voices->run)
                ports.voices = reinterpret_cast<const VoiceBus*>(block->voices);
            ok = processor.processPorts(ports);
        } else {
            if (block->audio_in_count > 1 || block->audio_out_count > 1) return 0;
            AudioProcessBlock audio;
            if (block->audio_in_count) audio.input = self.audioIn[0];
            if (block->audio_out_count) audio.output = self.audioOut[0];
            audio.frames = block->frames;
            audio.sampleRate = block->sample_rate;
            audio.parameters = self.parameters.data();
            audio.parameterCount = block->parameter_count;
            audio.transport = transport;
            ok = processor.process(audio);
        }
        for (uint32_t k = 0; k < block->event_out_count; ++k) block->event_out[k].count = self.eventOut[k].count;
        return ok ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

template <class Type>
int32_t saveState(void* p, uint8_t* destination, uint32_t capacity, uint32_t* written, uint32_t* version) noexcept {
    try {
        if (!written || !version) return 0;
        ModuleProcessor& processor = instance<Type>(p)->processor;
        *version = processor.stateVersion();
        return processor.saveState(destination, capacity, *written) ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

template <class Type>
int32_t loadState(void* p, const uint8_t* source, uint32_t size, uint32_t version) noexcept {
    try {
        return instance<Type>(p)->processor.loadState(source, size, version) ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

template <class Type>
int32_t quiet(void* p) noexcept {
    try {
        return instance<Type>(p)->processor.quiet() ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

template <class Type>
uint32_t readDisplay(void* p, float* destination, uint32_t capacity) noexcept {
    try {
        if (!p || !destination || capacity == 0) return 0;
        const uint32_t n = instance<Type>(p)->processor.readDisplay(destination, capacity);
        return n > capacity ? capacity : n;
    } catch (...) {
        return 0;
    }
}

// The extensions every exported component offers: CAW_EXTENSION_QUIET (from ModuleProcessor::quiet()) and
// CAW_EXTENSION_DISPLAY (from ModuleProcessor::readDisplay(); 0 floats unless the processor publishes).
template <class Type>
const void* extension(void*, const char* id) noexcept {
    static const CawQuietExtension kQuiet{sizeof(CawQuietExtension), &quiet<Type>};
    static const CawDisplayExtension kDisplay{sizeof(CawDisplayExtension), kMaxDisplayFloats, &readDisplay<Type>};
    if (id && std::string_view(id) == CAW_EXTENSION_QUIET) return &kQuiet;
    if (id && std::string_view(id) == CAW_EXTENSION_DISPLAY) return &kDisplay;
    return nullptr;
}

template <class Type>
bool exportComponent(const ModuleDescriptor& d, Exported& exported) noexcept {
    try {
        Exported* e = &exported;
        e->ports.reserve(d.portCount);
        for (uint32_t i = 0; i < d.portCount; ++i) {
            const PortDescriptor& p = d.ports[i];
            CawPortInfo c{};
            c.id = e->text(p.id);
            c.type = static_cast<uint32_t>(p.type);
            c.layout = static_cast<uint32_t>(p.layout);
            c.channel_count = p.channelCount;
            c.is_input = p.input ? 1u : 0u;
            c.summing = p.summing ? 1u : 0u;
            c.default_value = p.defaultValue;
            e->ports.push_back(c);
        }
        e->parameters.reserve(d.parameterCount);
        e->choices.resize(d.parameterCount);
        for (uint32_t i = 0; i < d.parameterCount; ++i) {
            const ParameterDescriptor& p = d.parameters[i];
            CawParameterInfo c{};
            c.id = e->text(p.id);
            c.name = e->text(p.name);
            c.unit = e->text(p.unit);
            c.default_value = p.defaultValue;
            c.minimum = p.minimum;
            c.maximum = p.maximum;
            c.step = p.step;
            c.curve = static_cast<uint32_t>(p.curve);
            c.smoothing_frames = p.smoothingFrames;
            c.flags = (p.automatable ? CAW_PARAMETER_AUTOMATABLE : 0u) | (p.modulatable ? CAW_PARAMETER_MODULATABLE : 0u) |
                      (p.midiMappable ? CAW_PARAMETER_MIDI_MAPPABLE : 0u);
            for (uint32_t k = 0; k < p.choiceCount && p.choices; ++k) e->choices[i].push_back(e->text(p.choices[k]));
            c.choice_count = static_cast<uint32_t>(e->choices[i].size());
            c.choices = e->choices[i].empty() ? nullptr : e->choices[i].data();
            e->parameters.push_back(c);
        }
        e->uiControls.reserve(d.uiControlCount);
        for (uint32_t i = 0; i < d.uiControlCount; ++i) {
            const UiControlDescriptor& u = d.uiControls[i];
            CawUiControlInfo c{};
            c.id = e->text(u.id);
            c.label = e->text(u.label);
            c.parameter_id = e->text(u.parameterId);
            c.kind = static_cast<uint32_t>(u.kind);
            c.minimum = u.minimum;
            c.maximum = u.maximum;
            e->uiControls.push_back(c);
        }
        CawComponentDescriptor& c = e->descriptor;
        c.struct_size = sizeof(CawComponentDescriptor);
        c.abi_version = CAW_COMPONENT_ABI_VERSION;
        c.id = e->text(d.id);
        c.name = e->text(d.name);
        c.version = d.version;
        c.role = static_cast<uint32_t>(d.role);
        c.latency_frames = d.latencyFrames;
        c.tail_frames = d.tailFrames;
        c.max_state_bytes = d.maxStateBytes;
        c.port_count = static_cast<uint32_t>(e->ports.size());
        c.port_info_size = sizeof(CawPortInfo);
        c.ports = e->ports.empty() ? nullptr : e->ports.data();
        c.parameter_count = static_cast<uint32_t>(e->parameters.size());
        c.parameter_info_size = sizeof(CawParameterInfo);
        c.parameters = e->parameters.empty() ? nullptr : e->parameters.data();
        c.ui_control_count = static_cast<uint32_t>(e->uiControls.size());
        c.ui_control_info_size = sizeof(CawUiControlInfo);
        c.ui_controls = e->uiControls.empty() ? nullptr : e->uiControls.data();
        c.custom_ui_id = e->text(d.customUiId);
        c.domains = d.domains;
        c.capabilities = d.capabilities;
        c.cpu_class = static_cast<uint32_t>(d.cpuClass);
        c.reserved = 0;

        CawComponentV3& t = e->table;
        t.struct_size = sizeof(CawComponentV3);
        t.abi_version = CAW_COMPONENT_ABI_VERSION;
        t.descriptor = &e->descriptor;
        t.create = &create<Type>;
        t.destroy = &destroy<Type>;
        t.activate = &activate<Type>;
        t.deactivate = &deactivate<Type>;
        t.reset = &reset<Type>;
        t.process = &process<Type>;
        t.save_state = &saveState<Type>;
        t.load_state = &loadState<Type>;
        t.get_extension = &extension<Type>;
        return true;
    } catch (...) {
        return false;
    }
}

// One bundle entry: its table, built on first use from a temporary instance's descriptor.
template <class Type>
const CawComponentV3* bundled() noexcept {
    static Exported exported;
    static const bool ready = [] {
        try {
            Type probe;
            return exportComponent<Type>(probe.descriptor(), exported);
        } catch (...) {
            return false;
        }
    }();
    return ready ? &exported.table : nullptr;
}

template <class... Types>
const CawComponentV3* bundleAt(uint32_t index) noexcept {
    const CawComponentV3* (*const entries[])() noexcept = {&bundled<Types>...};
    return index < sizeof...(Types) ? entries[index]() : nullptr;
}

}  // namespace caw::component_detail

extern "C" CAW_COMPONENT_EXPORT const CawComponentV3* caw_get_component_v3(uint32_t index);
