// Native module registry: static factories, and components loaded through the C interface (caw_component.h).
#include "module_registry.h"

#include <charconv>
#include <cstring>
#include <deque>
#include <filesystem>
#include <new>
#include <utility>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include "caw_component.h"
#include "json.h"

namespace caw {

struct NativeLibrary {
#ifdef _WIN32
    HMODULE handle = nullptr;
#else
    void* handle = nullptr;
#endif

    ~NativeLibrary() {
#ifdef _WIN32
        if (handle) FreeLibrary(handle);
#else
        if (handle) dlclose(handle);
#endif
    }

    bool open(const std::string& path, std::string& error) {
#ifdef _WIN32
        const std::filesystem::path nativePath = std::filesystem::u8path(path);
        handle = LoadLibraryW(nativePath.c_str());
        if (!handle) {
            error = "LoadLibrary failed with Windows error " + std::to_string(GetLastError());
            return false;
        }
#else
        dlerror();
        handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            const char* detail = dlerror();
            error = detail ? detail : "dlopen failed";
            return false;
        }
#endif
        return true;
    }

    template <class Function>
    Function resolve(const char* name) const noexcept {
#ifdef _WIN32
        return handle ? reinterpret_cast<Function>(GetProcAddress(handle, name)) : nullptr;
#else
        return handle ? reinterpret_cast<Function>(dlsym(handle, name)) : nullptr;
#endif
    }
};

// The engine-owned copy of a component's descriptor (the C one is only the wire format: the engine
// works with caw::ModuleDescriptor, backed by these strings and arrays), plus its C table and the
// host struct handed to its instances. Shared by the registration and every instance, so it
// outlives them all; the library is released after it.
struct LoadedComponent {
    std::shared_ptr<NativeLibrary> library;
    const CawComponentV3* table = nullptr;
    CawHost host{};
    std::deque<std::string> strings;  // stable addresses for the string_views below
    std::vector<PortDescriptor> ports;
    std::vector<ParameterDescriptor> parameters;
    std::vector<std::vector<std::string_view>> choices;
    std::vector<UiControlDescriptor> uiControls;
    ModuleDescriptor descriptor;

    // Copies a component string, at most kMaxComponentText bytes (a longer one is refused, so a
    // missing terminator cannot run far). False for an over-long string.
    bool text(const char* value, std::string_view& out) {
        const size_t length = value ? strnlen(value, kMaxComponentText + 1) : 0;
        if (length > kMaxComponentText) return false;
        strings.emplace_back(value ? value : "", length);
        out = strings.back();
        return true;
    }
    static constexpr size_t kMaxComponentText = 4096;
};

namespace {

// Upper bounds checked before a component's arrays are read, so a bad count is refused rather
// than walked past the end of its array.
constexpr uint32_t kMaxComponentsPerLibrary = 4096;  // entries a bundle may list
constexpr uint32_t kMaxComponentPorts = 1024;
constexpr uint32_t kMaxComponentParameters = 4096;
constexpr uint32_t kMaxComponentUiControls = 4096;

void destroyWithDelete(ModuleProcessor* processor) noexcept {
    delete processor;
}

// An enum field from the C side, kept out of range (so validation refuses it) instead of being
// truncated into a valid value.
template <class Enum>
Enum enumFrom(uint32_t value) noexcept {
    return static_cast<Enum>(value > 255u ? 255u : value);
}

template <class Info>
const Info* element(const void* base, uint32_t stride, uint32_t index) noexcept {
    return reinterpret_cast<const Info*>(static_cast<const unsigned char*>(base) + static_cast<size_t>(stride) * index);
}

// Copies a component's C descriptor into engine-owned storage. False (with a message) when its
// sizes or pointers are unusable; field values are left to validateModuleDescriptor.
bool copyDescriptor(const CawComponentDescriptor& c, LoadedComponent& out, std::string& error) {
    if (c.struct_size < sizeof(CawComponentDescriptor) || c.abi_version != CAW_COMPONENT_ABI_VERSION) {
        error = "The component descriptor is from another C interface version.";
        return false;
    }
    if ((c.port_count && (!c.ports || c.port_info_size < sizeof(CawPortInfo))) ||
        (c.parameter_count && (!c.parameters || c.parameter_info_size < sizeof(CawParameterInfo))) ||
        (c.ui_control_count && (!c.ui_controls || c.ui_control_info_size < sizeof(CawUiControlInfo)))) {
        error = "The component descriptor has a missing array or an element stride smaller than this interface's.";
        return false;
    }
    if (c.port_count > kMaxComponentPorts || c.parameter_count > kMaxComponentParameters ||
        c.ui_control_count > kMaxComponentUiControls) {
        error = "The component declares more ports, parameters or UI controls than the host accepts.";
        return false;
    }
    bool textOk = true;
    auto text = [&](const char* value) {
        std::string_view view;
        if (!out.text(value, view)) textOk = false;
        return view;
    };
    out.ports.reserve(c.port_count);
    for (uint32_t i = 0; i < c.port_count; ++i) {
        const CawPortInfo& p = *element<CawPortInfo>(c.ports, c.port_info_size, i);
        PortDescriptor d;
        d.id = text(p.id);
        d.type = enumFrom<PortType>(p.type);
        d.layout = enumFrom<ChannelLayout>(p.layout);
        d.input = p.is_input != 0;
        d.channelCount = p.channel_count;
        d.summing = p.summing != 0;
        d.defaultValue = p.default_value;
        out.ports.push_back(d);
    }
    out.parameters.reserve(c.parameter_count);
    out.choices.resize(c.parameter_count);
    for (uint32_t i = 0; i < c.parameter_count; ++i) {
        const CawParameterInfo& p = *element<CawParameterInfo>(c.parameters, c.parameter_info_size, i);
        ParameterDescriptor d;
        d.id = text(p.id);
        d.name = text(p.name);
        d.unit = text(p.unit);
        d.defaultValue = p.default_value;
        d.minimum = p.minimum;
        d.maximum = p.maximum;
        d.step = p.step;
        d.curve = enumFrom<ParameterCurve>(p.curve);
        d.smoothingFrames = p.smoothing_frames;
        d.automatable = (p.flags & CAW_PARAMETER_AUTOMATABLE) != 0;
        d.modulatable = (p.flags & CAW_PARAMETER_MODULATABLE) != 0;
        d.midiMappable = (p.flags & CAW_PARAMETER_MIDI_MAPPABLE) != 0;
        if (p.choice_count) {
            // Bounded before reading so a bad count cannot walk far past the array.
            if (!p.choices || p.choice_count > kMaxParameterChoices) {
                error = "A choice parameter has no labels or more than the limit.";
                return false;
            }
            for (uint32_t k = 0; k < p.choice_count; ++k) out.choices[i].push_back(text(p.choices[k]));
            d.choices = out.choices[i].data();
            d.choiceCount = p.choice_count;
        }
        out.parameters.push_back(d);
    }
    out.uiControls.reserve(c.ui_control_count);
    for (uint32_t i = 0; i < c.ui_control_count; ++i) {
        const CawUiControlInfo& u = *element<CawUiControlInfo>(c.ui_controls, c.ui_control_info_size, i);
        UiControlDescriptor d;
        d.id = text(u.id);
        d.label = text(u.label);
        d.parameterId = text(u.parameter_id);
        d.kind = enumFrom<UiControlKind>(u.kind);
        d.minimum = u.minimum;
        d.maximum = u.maximum;
        out.uiControls.push_back(d);
    }
    ModuleDescriptor& d = out.descriptor;
    d.id = text(c.id);
    d.apiVersion = 1;
    d.ports = out.ports.empty() ? nullptr : out.ports.data();
    d.portCount = c.port_count;
    d.parameters = out.parameters.empty() ? nullptr : out.parameters.data();
    d.parameterCount = c.parameter_count;
    d.uiControls = out.uiControls.empty() ? nullptr : out.uiControls.data();
    d.uiControlCount = c.ui_control_count;
    d.customUiId = text(c.custom_ui_id);
    d.name = text(c.name);
    d.version = c.version;
    d.role = enumFrom<ModuleRole>(c.role);
    d.latencyFrames = c.latency_frames;
    d.tailFrames = c.tail_frames;
    d.maxStateBytes = c.max_state_bytes;
    if (!textOk) {
        error = "A component string is longer than the host accepts.";
        return false;
    }
    return true;
}

// A loaded component's instance as a ModuleProcessor. Its C views are sized from the descriptor
// here, on the control thread, so process() only copies a few small structs.
class ComponentProcessor final : public ModuleProcessor {
public:
    ComponentProcessor(std::shared_ptr<const LoadedComponent> component, void* instance)
        : component_(std::move(component)), instance_(instance) {
        const ModuleDescriptor& d = component_->descriptor;
        uint32_t audioIn = 0, audioOut = 0, eventIn = 0, eventOut = 0, other = 0;
        for (uint32_t p = 0; p < d.portCount; ++p) {
            const PortDescriptor& port = d.ports[p];
            if (port.type == PortType::Audio) ++(port.input ? audioIn : audioOut);
            else if (port.type == PortType::Event) ++(port.input ? eventIn : eventOut), ++other;
            else ++other;
        }
        audioIn_.resize(audioIn);
        audioOut_.resize(audioOut);
        eventIn_.resize(eventIn);
        eventOut_.resize(eventOut);
        parameters_.resize(d.parameterCount);
        portsPath_ = other != 0 || audioIn > 1 || audioOut > 1;
        for (uint32_t p = 0; p < d.portCount; ++p)
            if (d.ports[p].type == PortType::Audio) (d.ports[p].input ? inChannels_ : outChannels_) = portChannelCount(d.ports[p]);
        // Control thread: whether the component can say it has fallen silent (CAW_EXTENSION_QUIET).
        const CawComponentV3& t = *component_->table;
        if (t.get_extension) {
            const auto* q = static_cast<const CawQuietExtension*>(t.get_extension(instance_, CAW_EXTENSION_QUIET));
            if (q && q->struct_size >= sizeof(CawQuietExtension) && q->quiet) quiet_ = q->quiet;
            const auto* v = static_cast<const CawDisplayExtension*>(t.get_extension(instance_, CAW_EXTENSION_DISPLAY));
            if (v && v->struct_size >= sizeof(CawDisplayExtension) && v->read) display_ = v->read;
        }
    }
    ~ComponentProcessor() override {
        const CawComponentV3& t = *component_->table;
        if (active_) t.deactivate(instance_);
        t.destroy(instance_);
    }

    const ModuleDescriptor& descriptor() const noexcept override { return component_->descriptor; }
    bool usesProcessPorts() const noexcept override { return portsPath_; }

    bool activate(double sampleRate, uint32_t maxFrames) noexcept override {
        const CawComponentV3& t = *component_->table;
        if (active_) t.deactivate(instance_);
        active_ = maxFrames > 0 && t.activate(instance_, sampleRate, maxFrames) == 1;
        maxFrames_ = active_ ? maxFrames : 0;
        return active_;
    }
    void deactivate() noexcept override {
        if (active_) component_->table->deactivate(instance_);
        active_ = false;
    }
    void reset() noexcept override {
        if (active_) component_->table->reset(instance_);
    }
    bool quiet() const noexcept override { return active_ && quiet_ && quiet_(instance_) == 1; }
    // Any thread but the audio thread (CAW_EXTENSION_DISPLAY): never more than `max`, whatever the component says.
    uint32_t readDisplay(float* out, uint32_t max) const noexcept override {
        if (!display_ || !out || max == 0) return 0;
        const uint32_t n = display_(instance_, out, max);
        return n > max ? max : n;
    }

    bool process(const AudioProcessBlock& block) noexcept override {
        if (!active_ || portsPath_ || !audioProcessBlockValid(block) || block.frames > maxFrames_) return false;
        // A side the component has is passed with exactly its port's channels, or not at all.
        if ((block.input.channelCount && (audioIn_.empty() || block.input.channelCount != inChannels_)) ||
            (block.output.channelCount && (audioOut_.empty() || block.output.channelCount != outChannels_)))
            return false;
        CawProcessBlock c = baseBlock(block.frames, block.sampleRate, block.parameters, block.parameterCount, block.transport);
        if (!audioIn_.empty() && block.input.channelCount) {
            audioIn_[0] = {block.input.channels, block.input.channelCount, block.input.frames};
            c.audio_in = audioIn_.data();
            c.audio_in_count = 1;
        }
        if (!audioOut_.empty() && block.output.channelCount) {
            audioOut_[0] = {block.output.channels, block.output.channelCount, block.output.frames};
            c.audio_out = audioOut_.data();
            c.audio_out_count = 1;
        }
        return component_->table->process(instance_, &c) == 1;
    }
    void process(const StereoProcessBlock& block) noexcept override {
        const float* in[2] = {block.inputLeft, block.inputRight};
        float* out[2] = {block.outputLeft, block.outputRight};
        const bool hasIn = block.inputLeft && block.inputRight, hasOut = block.outputLeft && block.outputRight;
        AudioProcessBlock audio;
        audio.input = {hasIn ? in : nullptr, hasIn ? 2u : 0u, block.frames};
        audio.output = {hasOut ? out : nullptr, hasOut ? 2u : 0u, block.frames};
        audio.frames = block.frames;
        audio.sampleRate = block.sampleRate;
        process(audio);
    }

    bool processPorts(const ProcessBlock& block) noexcept override {
        if (!active_ || block.frames == 0 || block.frames > maxFrames_ || block.audioInCount > audioIn_.size() ||
            block.audioOutCount > audioOut_.size() ||
            block.eventInCount > eventIn_.size() || block.eventOutCount > eventOut_.size())
            return false;
        CawProcessBlock c = baseBlock(block.frames, block.sampleRate, block.parameters, block.parameterCount, block.transport);
        for (uint32_t k = 0; k < block.audioInCount; ++k)
            audioIn_[k] = {block.audioIn[k].channels, block.audioIn[k].channelCount, block.audioIn[k].frames};
        for (uint32_t k = 0; k < block.audioOutCount; ++k)
            audioOut_[k] = {block.audioOut[k].channels, block.audioOut[k].channelCount, block.audioOut[k].frames};
        // Event records have the same layout on both sides (checked in caw/module.hpp).
        for (uint32_t k = 0; k < block.eventInCount; ++k)
            eventIn_[k] = {reinterpret_cast<const CawEvent*>(block.eventIn[k].events), block.eventIn[k].count};
        for (uint32_t k = 0; k < block.eventOutCount; ++k)
            eventOut_[k] = {reinterpret_cast<CawEvent*>(block.eventOut[k].events), block.eventOut[k].capacity, 0};
        c.audio_in = audioIn_.data();
        c.audio_in_count = block.audioInCount;
        c.audio_out = audioOut_.data();
        c.audio_out_count = block.audioOutCount;
        c.modulation_in = block.modulationIn;
        c.modulation_in_count = block.modulationInCount;
        c.modulation_out = block.modulationOut;
        c.modulation_out_count = block.modulationOutCount;
        c.control_in = block.controlIn;
        c.control_in_count = block.controlInCount;
        c.control_out = block.controlOut;
        c.control_out_count = block.controlOutCount;
        c.event_in = eventIn_.data();
        c.event_in_count = block.eventInCount;
        c.event_out = eventOut_.data();
        c.event_out_count = block.eventOutCount;
        bool ok = component_->table->process(instance_, &c) == 1;
        // The EventOutput rule (caw/module.hpp): at most capacity, frames in order and inside the
        // block; anything else fails the block (and reports no events).
        for (uint32_t k = 0; k < block.eventOutCount; ++k) {
            const CawEventOutput& out = eventOut_[k];
            bool valid = out.count <= out.capacity;
            for (uint32_t e = 0; valid && e < out.count; ++e)
                valid = out.events[e].frame < block.frames && (e == 0 || out.events[e].frame >= out.events[e - 1].frame);
            if (!valid) ok = false;
            block.eventOut[k].count = valid ? out.count : 0;
        }
        return ok;
    }

    uint32_t stateVersion() const noexcept override { return stateVersion_; }
    bool saveState(uint8_t* destination, uint32_t capacity, uint32_t& written) const noexcept override {
        uint32_t version = 1;
        written = 0;
        const bool ok = component_->table->save_state(instance_, destination, capacity, &written, &version) == 1;
        if (!ok || written > capacity) {
            written = 0;
            return false;
        }
        stateVersion_ = version;
        return true;
    }
    bool loadState(const uint8_t* source, uint32_t size, uint32_t version) noexcept override {
        return component_->table->load_state(instance_, source, size, version) == 1;
    }

private:
    CawProcessBlock baseBlock(uint32_t frames, double sampleRate, const ParameterValue* parameters,
                              uint32_t parameterCount, const Transport* transport) noexcept {
        CawProcessBlock c{};
        c.struct_size = sizeof(CawProcessBlock);
        c.frames = frames;
        c.sample_rate = sampleRate;
        uint32_t count = parameterCount < parameters_.size() ? parameterCount : static_cast<uint32_t>(parameters_.size());
        if (!parameters) count = 0;
        for (uint32_t k = 0; k < count; ++k) parameters_[k] = {parameters[k].samples, parameters[k].value};
        c.parameters = parameters_.data();
        c.parameter_count = count;
        if (transport) {
            transport_ = {sizeof(CawTransport), transport->playing ? CAW_TRANSPORT_PLAYING : 0u, transport->tempo,
                          transport->beat, transport->beatsPerBar, 0};
            c.transport = &transport_;
        }
        return c;
    }

    std::shared_ptr<const LoadedComponent> component_;  // keeps the table and library alive
    void* instance_ = nullptr;
    bool active_ = false;
    int32_t (*quiet_)(void*) = nullptr;  // CAW_EXTENSION_QUIET, when the component offers it
    uint32_t (*display_)(void*, float*, uint32_t) = nullptr;  // CAW_EXTENSION_DISPLAY, when offered
    bool portsPath_ = false;
    uint32_t maxFrames_ = 0;  // the block size the component prepared for at activate
    uint32_t inChannels_ = 0, outChannels_ = 0;  // the single audio in/out port's channels (non-port path)
    mutable uint32_t stateVersion_ = 1;  // the version the component last saved with
    CawTransport transport_{};           // the block's transport as the C interface carries it
    std::vector<CawConstAudio> audioIn_;
    std::vector<CawAudio> audioOut_;
    std::vector<CawEventInput> eventIn_;
    std::vector<CawEventOutput> eventOut_;
    std::vector<CawParameterValue> parameters_;
};

const void* noHostExtension(const CawHost*, const char*) { return nullptr; }

}  // namespace

bool ModuleRegistry::add(const ModuleDescriptor& descriptor, ModuleFactory factory, ModuleDestroy destroy) {
    if (!factory || validateModuleDescriptor(descriptor) != ModuleValidation::Ok || find(descriptor.id))
        return false;
    registrations_.push_back({&descriptor, factory, destroy ? destroy : &destroyWithDelete, {}, {}});
    return true;
}

ModuleLoadResult ModuleRegistry::loadSharedLibrary(
    const std::string& path, std::string_view expectedId, NativeModuleTrust trust, bool replace) {
    if (trust == NativeModuleTrust::Blocked)
        return {false, ModuleLoadError::Blocked, std::string(expectedId), "Native component is blocked by the user's trust setting."};
    if (trust == NativeModuleTrust::Isolated)
        return {false, ModuleLoadError::IsolationUnavailable, std::string(expectedId),
                "Isolated native execution is not available in this host; choose Trusted explicitly or keep the component Blocked."};
    if (trust != NativeModuleTrust::Trusted)
        return {false, ModuleLoadError::InvalidArgument, std::string(expectedId), "Unknown native component trust level."};
    if (path.empty() || expectedId.empty())
        return {false, ModuleLoadError::InvalidArgument, {}, "A component path and expected stable component ID are required."};

    try {
        auto library = std::make_shared<NativeLibrary>();
        std::string loadError;
        if (!library->open(path, loadError))
            return {false, ModuleLoadError::LoadFailed, std::string(expectedId), std::move(loadError)};

        const auto entry = library->resolve<CawGetComponentV3Fn>(CAW_COMPONENT_ENTRY_SYMBOL);
        if (!entry)
            return {false, ModuleLoadError::MissingEntryPoint, std::string(expectedId),
                    "The library does not export caw_get_component_v3 (build it with this C.A.W. SDK)."};
        // A library may be a bundle: take the component with the expected id, checking each entry's
        // version and sizes before reading its id.
        const CawComponentV3* table = nullptr;
        // Entries from another interface version are skipped (a bundle may mix them); the
        // expected id must appear exactly once among the usable ones.
        bool listsAny = false, skippedIncompatible = false, duplicate = false;
        for (uint32_t index = 0; index < kMaxComponentsPerLibrary; ++index) {
            const CawComponentV3* candidate = entry(index);
            if (!candidate) break;
            listsAny = true;
            if (candidate->struct_size < sizeof(CawComponentV3) || candidate->abi_version != CAW_COMPONENT_ABI_VERSION ||
                !candidate->descriptor || candidate->descriptor->struct_size < sizeof(CawComponentDescriptor) ||
                candidate->descriptor->abi_version != CAW_COMPONENT_ABI_VERSION) {
                skippedIncompatible = true;
                continue;
            }
            const char* id = candidate->descriptor->id;
            if (id && strnlen(id, expectedId.size() + 1) == expectedId.size() &&
                std::memcmp(id, expectedId.data(), expectedId.size()) == 0) {
                if (table) duplicate = true;
                else table = candidate;
            }
        }
        if (!listsAny)
            return {false, ModuleLoadError::MissingEntryPoint, std::string(expectedId),
                    "The library's caw_get_component_v3 lists no components."};
        if (duplicate)
            return {false, ModuleLoadError::InvalidDescriptor, std::string(expectedId),
                    "The library lists this component ID more than once."};
        if (!table)
            return {false, skippedIncompatible ? ModuleLoadError::IncompatibleAbi : ModuleLoadError::ComponentIdMismatch,
                    std::string(expectedId),
                    skippedIncompatible ? "The library has no usable component with this ID: some entries use another C "
                                          "interface version (rebuild with this C.A.W. SDK)."
                                        : "The library has no component with the project manifest ID."};
        if (!table->create || !table->destroy || !table->activate || !table->deactivate || !table->reset ||
            !table->process || !table->save_state || !table->load_state)
            return {false, ModuleLoadError::IncompleteTable, std::string(expectedId),
                    "The component's function table is missing a required entry."};

        auto component = std::make_shared<LoadedComponent>();
        std::string copyError;
        if (!copyDescriptor(*table->descriptor, *component, copyError))
            return {false,
                    table->descriptor->abi_version != CAW_COMPONENT_ABI_VERSION ||
                            table->descriptor->struct_size < sizeof(CawComponentDescriptor)
                        ? ModuleLoadError::IncompatibleAbi
                        : ModuleLoadError::InvalidDescriptor,
                    std::string(expectedId), std::move(copyError)};
        if (validateModuleDescriptor(component->descriptor) != ModuleValidation::Ok)
            return {false, ModuleLoadError::InvalidDescriptor, std::string(expectedId),
                    "The component's exported descriptor is invalid."};
        if (component->descriptor.id != expectedId)
            return {false, ModuleLoadError::ComponentIdMismatch, std::string(expectedId),
                    "The built component ID does not match the project manifest ID."};
        ModuleRegistration* existing = nullptr;
        for (ModuleRegistration& r : registrations_)
            if (r.descriptor && r.descriptor->id == component->descriptor.id) existing = &r;
        if (existing && (!replace || !existing->component))
            return {false, ModuleLoadError::DuplicateId, std::string(component->descriptor.id),
                    "A component with this stable ID is already loaded."};

        component->table = table;
        component->host = CawHost{sizeof(CawHost), CAW_COMPONENT_ABI_VERSION, "C.A.W", "1", nullptr, &noHostExtension};
        component->library = std::move(library);
        const std::string id(component->descriptor.id);
        if (existing) {
            *existing = {&component->descriptor, nullptr, nullptr, component->library, std::move(component)};
        } else {
            registrations_.push_back({&component->descriptor, nullptr, nullptr, component->library, std::move(component)});
        }
        return {true, ModuleLoadError::None, id, {}};
    } catch (const std::bad_alloc&) {
        return {false, ModuleLoadError::LoadFailed, std::string(expectedId), "Out of memory while loading the component."};
    }
}

bool ModuleRegistry::unload(std::string_view id) {
    for (auto it = registrations_.begin(); it != registrations_.end(); ++it) {
        if (!it->descriptor || it->descriptor->id != id || !it->component) continue;
        // The registration's own reference is the only one: no instance still uses the component.
        if (it->component.use_count() != 1) return false;
        registrations_.erase(it);
        return true;
    }
    return false;
}

const ModuleDescriptor* ModuleRegistry::find(std::string_view id) const noexcept {
    for (const ModuleRegistration& registration : registrations_)
        if (registration.descriptor && registration.descriptor->id == id)
            return registration.descriptor;
    return nullptr;
}

std::vector<const ModuleDescriptor*> ModuleRegistry::loadedComponents() const {
    std::vector<const ModuleDescriptor*> out;
    for (const ModuleRegistration& registration : registrations_)
        if (registration.component && registration.descriptor) out.push_back(registration.descriptor);
    return out;
}

std::vector<const ModuleDescriptor*> ModuleRegistry::builtinComponents() const {
    std::vector<const ModuleDescriptor*> out;
    for (const ModuleRegistration& registration : registrations_)
        if (!registration.component && registration.factory && registration.descriptor) out.push_back(registration.descriptor);
    return out;
}

namespace {
const char* layoutName(ChannelLayout layout) noexcept {
    switch (layout) {
        case ChannelLayout::None: return "none";
        case ChannelLayout::Mono: return "mono";
        case ChannelLayout::Stereo: return "stereo";
        case ChannelLayout::Quad: return "quad";
        case ChannelLayout::Surround51: return "5.1";
        case ChannelLayout::Surround71: return "7.1";
        case ChannelLayout::Discrete: return "discrete";
    }
    return "none";
}
const char* portTypeName(PortType type) noexcept {
    switch (type) {
        case PortType::Audio: return "audio";
        case PortType::Control: return "control";
        case PortType::Modulation: return "modulation";
        case PortType::Event: return "event";
    }
    return "audio";
}
const char* roleName(ModuleRole role) noexcept {
    switch (role) {
        case ModuleRole::Unspecified: return "unspecified";
        case ModuleRole::Instrument: return "instrument";
        case ModuleRole::Generator: return "generator";
        case ModuleRole::Effect: return "effect";
        case ModuleRole::Utility: return "utility";
        case ModuleRole::EventProcessor: return "event_processor";
        case ModuleRole::Analyzer: return "analyzer";
    }
    return "unspecified";
}
const char* uiKindName(UiControlKind kind) noexcept {
    switch (kind) {
        case UiControlKind::Slider: return "slider";
        case UiControlKind::Toggle: return "toggle";
        case UiControlKind::Dropdown: return "dropdown";
        case UiControlKind::XYPad: return "xy_pad";
        case UiControlKind::Button: return "button";
        case UiControlKind::Curve: return "curve";
    }
    return "slider";
}
// Valid UTF-8 kept; any invalid byte becomes U+FFFD, so one component's text can't break the list.
std::string validUtf8(std::string_view text) {
    std::string out;
    out.reserve(text.size());
    const auto* p = reinterpret_cast<const unsigned char*>(text.data());
    const size_t n = text.size();
    for (size_t i = 0; i < n;) {
        const unsigned char c = p[i];
        size_t len = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : (c >> 3) == 0x1E ? 4 : 0;
        bool ok = len != 0 && i + len <= n;
        for (size_t k = 1; ok && k < len; ++k) ok = (p[i + k] & 0xC0) == 0x80;
        if (ok && len == 2) ok = c >= 0xC2;                                   // no overlong forms
        if (ok && len == 3) ok = !(c == 0xE0 && p[i + 1] < 0xA0) && !(c == 0xED && p[i + 1] >= 0xA0);
        if (ok && len == 4) ok = c <= 0xF4 && !(c == 0xF0 && p[i + 1] < 0x90) && !(c == 0xF4 && p[i + 1] >= 0x90);
        if (ok) {
            out.append(text.data() + i, len);
            i += len;
        } else {
            out += "\xEF\xBF\xBD";
            ++i;
        }
    }
    return out;
}
std::string quoted(std::string_view text) { return "\"" + jsonEscape(validUtf8(text)) + "\""; }
// The shortest text that reads back as the same double, independent of the C locale.
std::string number(double value) {
    char text[32];
    const auto result = std::to_chars(text, text + sizeof text, value);
    return std::string(text, result.ptr);
}
}  // namespace

std::string moduleDescriptorJson(const ModuleDescriptor& d) {
    std::string j = "{\"id\":" + quoted(d.id) + ",\"name\":" + quoted(d.name) +
                    ",\"version\":" + std::to_string(d.version) + ",\"role\":\"" + roleName(d.role) +
                    "\",\"latency_frames\":" + std::to_string(d.latencyFrames) +
                    ",\"tail_frames\":" + (d.tailFrames == kInfiniteTail ? std::string("null") : std::to_string(d.tailFrames)) +
                    ",\"max_state_bytes\":" + std::to_string(d.maxStateBytes) + ",\"custom_ui_id\":" + quoted(d.customUiId) +
                    ",\"ports\":[";
    for (uint32_t i = 0; i < d.portCount; ++i) {
        const PortDescriptor& p = d.ports[i];
        j += std::string(i ? "," : "") + "{\"id\":" + quoted(p.id) + ",\"type\":\"" + portTypeName(p.type) +
             "\",\"input\":" + (p.input ? "true" : "false") + ",\"layout\":\"" + layoutName(p.layout) +
             "\",\"channels\":" + std::to_string(portChannelCount(p)) + ",\"summing\":" + (p.summing ? "true" : "false") + "}";
    }
    j += "],\"parameters\":[";
    for (uint32_t i = 0; i < d.parameterCount; ++i) {
        const ParameterDescriptor& p = d.parameters[i];
        j += std::string(i ? "," : "") + "{\"id\":" + quoted(p.id) + ",\"name\":" + quoted(p.name) +
             ",\"unit\":" + quoted(p.unit) + ",\"default\":" + number(p.defaultValue) +
             ",\"min\":" + number(p.minimum) + ",\"max\":" + number(p.maximum) + ",\"step\":" + number(p.step) +
             ",\"curve\":\"" + (p.curve == ParameterCurve::Exponential ? "exponential" : "linear") +
             "\",\"smoothing_frames\":" + std::to_string(p.smoothingFrames) +
             ",\"automatable\":" + (p.automatable ? "true" : "false") +
             ",\"modulatable\":" + (p.modulatable ? "true" : "false") +
             ",\"midi_mappable\":" + (p.midiMappable ? "true" : "false") +
             (p.group.empty() ? std::string() : ",\"group\":" + quoted(p.group)) + ",\"choices\":[";
        for (uint32_t c = 0; c < p.choiceCount; ++c) j += std::string(c ? "," : "") + quoted(p.choices[c]);
        j += "]}";
    }
    j += "],\"ui_controls\":[";
    for (uint32_t i = 0; i < d.uiControlCount; ++i) {
        const UiControlDescriptor& u = d.uiControls[i];
        j += std::string(i ? "," : "") + "{\"id\":" + quoted(u.id) + ",\"label\":" + quoted(u.label) +
             ",\"parameter_id\":" + quoted(u.parameterId) + ",\"kind\":\"" + uiKindName(u.kind) +
             "\",\"min\":" + number(u.minimum) + ",\"max\":" + number(u.maximum) + "}";
    }
    return j + "]}";
}

std::unique_ptr<ModuleProcessor> ModuleRegistry::create(std::string_view id) const noexcept {
    for (const ModuleRegistration& registration : registrations_) {
        if (!registration.descriptor || registration.descriptor->id != id) continue;
        if (registration.component) {
            const LoadedComponent& c = *registration.component;
            void* instance = c.table->create(&c.host);
            if (!instance) return {};
            try {
                return std::make_unique<ComponentProcessor>(registration.component, instance);
            } catch (...) {  // its view arrays could not be allocated
                c.table->destroy(instance);
                return {};
            }
        }
        if (!registration.factory) continue;
        ModuleProcessor* processor = registration.factory();
        if (!processor) return {};
        if (!moduleDescriptorsMatch(processor->descriptor(), *registration.descriptor)) {
            registration.destroy(processor);
            return {};
        }
        processor->reset();
        return std::unique_ptr<ModuleProcessor>(processor);
    }
    return {};
}

}  // namespace caw
