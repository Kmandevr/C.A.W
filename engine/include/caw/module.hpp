// First-class native module contract. This is deliberately independent of Flutter and host audio APIs.
#pragma once
#include <cstddef>
#include <cstdint>
#include <string_view>
namespace caw {
enum class PortType : uint8_t { Audio, Control, Modulation, Event };
// Standard layouts use canonical speaker order. Discrete has an explicit channel count.
enum class ChannelLayout : uint8_t { None, Mono, Stereo, Quad, Surround51, Surround71, Discrete };
constexpr uint32_t channelCountForLayout(ChannelLayout layout, uint32_t discreteCount = 0) noexcept {
    switch (layout) {
        case ChannelLayout::Mono: return 1;
        case ChannelLayout::Stereo: return 2;
        case ChannelLayout::Quad: return 4;
        case ChannelLayout::Surround51: return 6;
        case ChannelLayout::Surround71: return 8;
        case ChannelLayout::Discrete: return discreteCount;
        case ChannelLayout::None: return 0;
    }
    return 0;
}
// Hard ceiling on channels per audio port, for every layout including Discrete. It bounds
// pointer tables and buffer sizes; hosts may set a lower limit in their graph budget.
inline constexpr uint32_t kMaxPortChannels = 64;
// Port types (F5): Audio carries planar channels (layout and channelCount); Modulation carries one
// float per frame (layout None); Control carries one float value per block (layout None), held
// until its source writes again; Event carries a list of timed Events per block (layout None).
// Parameters are not ports: F6 decides how ports bind to ParameterDescriptor values.
struct PortDescriptor {
    std::string_view id;
    PortType type = PortType::Audio;
    ChannelLayout layout = ChannelLayout::None;
    bool input = true;
    uint32_t channelCount = 0;
    // Audio, modulation and event inputs only: accepts any number of connections. Audio and
    // modulation are summed by the host in connection order starting from +0.0f (a mix bus, or
    // modulators adding); events are merged by frame, ties in connection order. A non-summing
    // input takes at most one connection.
    bool summing = false;
    // Control ports only: the value an unconnected input reads, and an output's value before its
    // processor first writes one. Finite.
    float defaultValue = 0.0f;
};
// Resolved channel count of a port: the layout's fixed count, or channelCount for Discrete.
constexpr uint32_t portChannelCount(const PortDescriptor& port) noexcept {
    return channelCountForLayout(port.layout, port.channelCount);
}
// One timed event (F5.2; owner decision 2026-11-04). `frame` is the offset in the block. `data`
// holds the raw MIDI 2.0 UMP words of the message (unused words 0), so MIDI 1.0 and 2.0 convert
// at the edges without loss. `noteId` is a host-assigned stable id of the note an event belongs
// to (0 = none): it tells two overlapping notes of the same pitch apart, which UMP alone cannot.
// `flags` is reserved and 0. The executor never interprets kind, flags, noteId or data.
enum class EventKind : uint16_t {
    Note,  // note on/off and per-note messages: noteId names the note
    Midi   // any other UMP message (controllers, channel pressure, pitch bend, system)
};
struct Event {
    uint32_t frame = 0;
    EventKind kind = EventKind::Midi;
    uint16_t flags = 0;
    uint32_t noteId = 0;
    uint32_t data[4] = {0, 0, 0, 0};
};
static_assert(sizeof(Event) == 28, "Event is a fixed 28-byte record");
// An event input: `count` events, frames non-decreasing and below the block's frame count.
struct EventInput {
    const Event* events = nullptr;
    uint32_t count = 0;
};
// An event output: the processor writes up to `capacity` events and sets `count` (the host sets
// it to 0 before each call). They must be in non-decreasing frame order, each frame below the
// block's frame count; otherwise, or with count > capacity, the block fails.
struct EventOutput {
    Event* events = nullptr;
    uint32_t capacity = 0;
    uint32_t count = 0;
};
// How a parameter's range maps to 0..1 (the normalized scale modulation depth is a fraction of).
// Exponential needs minimum > 0 and suits frequencies and times.
enum class ParameterCurve : uint8_t { Linear, Exponential };
inline constexpr uint32_t kMaxParameterSmoothingFrames = 1u << 20;  // about 22 s at 48 kHz
inline constexpr uint32_t kMaxParameterChoices = 4096;     // labels per choice parameter
inline constexpr double kMaxChoiceValue = 2147483648.0;    // |minimum| and |maximum| of a choice parameter (2^31)
struct ParameterDescriptor {
    std::string_view id;
    double defaultValue = 0.0;
    double minimum = 0.0;
    double maximum = 1.0;
    bool automatable = true;
    ParameterCurve curve = ParameterCurve::Linear;
    double step = 0.0;             // > 0: values snap to minimum + k * step; 0: continuous
    uint32_t smoothingFrames = 0;  // a manual or MIDI change ramps linearly over this many frames (at most kMaxParameterSmoothingFrames)
    std::string_view unit;         // display only ("Hz", "dB"); never interpreted or matched
    // Display name; empty shows the id.
    std::string_view name;
    // A choice parameter (a dropdown or a switch): `choiceCount` labels for the integer values
    // minimum, minimum + 1, ..., maximum. Requires step 1, an integer minimum and
    // maximum - minimum + 1 == choiceCount, the linear curve, at most kMaxParameterChoices labels and
    // |minimum|, |maximum| <= kMaxChoiceValue; every label non-empty. 0 = a plain numeric parameter.
    const std::string_view* choices = nullptr;
    uint32_t choiceCount = 0;
    // What may drive the parameter besides a manual value. Hosts refuse a modulation link, an
    // automation lane (`automatable`, above) or a MIDI CC mapping the parameter does not allow.
    bool modulatable = true;
    bool midiMappable = true;
    // Display only: where an editor files the parameter, as a slash path ("a1/body": pad A1's body layer; "kit/glue").
    // Built-in components set it (docs/engine.md); it is not part of the C interface, so a loaded component has none.
    std::string_view group;
};
enum class UiControlKind : uint8_t { Slider, Toggle, Dropdown, XYPad, Button, Curve };
struct UiControlDescriptor {
    std::string_view id;
    std::string_view label;
    std::string_view parameterId;
    UiControlKind kind = UiControlKind::Slider;
    double minimum = 0.0;
    double maximum = 1.0;
};
// What a component is for: where browsers list it and how a host may insert it. A component
// that fits several roles picks its main one.
enum class ModuleRole : uint8_t { Unspecified, Instrument, Generator, Effect, Utility, EventProcessor, Analyzer };
// tailFrames value of a component whose output may never fall silent after its input does
// (an oscillator, a feedback delay at full feedback).
inline constexpr uint32_t kInfiniteTail = UINT32_MAX;
// Processing domains (#120): where a host may run the component, as a bitmask. Every component runs whole
// (on a track, a bus or the master), so kDomainWhole is always set. The other bits add places:
// - kDomainPerChannel: one instance per channel of a wider signal (a mono-in, mono-out effect run as dual mono).
// - kDomainPerVoice, kDomainPerNote: an effect (one stereo audio input and one stereo audio output) may run
//   once per note, in a per-note FX slot (#127); an instrument (no audio input, one stereo audio output, an
//   event input) exposes a voice bus (ProcessBlock::voices). The beta treats PerVoice as PerNote.
// A component that keeps a sidechain, measures (an analyzer) or must see the whole mix (a limiter) opts out.
// Default: whole only, so a component runs per note only when its author says it can.
inline constexpr uint32_t kDomainWhole = 1u, kDomainPerChannel = 2u, kDomainPerVoice = 4u, kDomainPerNote = 8u;
inline constexpr uint32_t kKnownDomains = kDomainWhole | kDomainPerChannel | kDomainPerVoice | kDomainPerNote;
// What a component needs or offers (#120), as a bitmask; hosts list them and may refuse what they lack.
// NotesIn: plays notes from an event input. MidiIn: reads other MIDI (controllers) from an event input.
// EventsOut: writes events. SampleAssets: loads sample files. NeedsTransport: follows the song's tempo or
// position. ExportClap: may be exported as a CLAP plugin.
inline constexpr uint32_t kCapabilityNotesIn = 1u, kCapabilityMidiIn = 2u, kCapabilityEventsOut = 4u,
                          kCapabilitySampleAssets = 8u, kCapabilityNeedsTransport = 16u, kCapabilityExportClap = 32u;
inline constexpr uint32_t kKnownCapabilities = 63u;
// A rough cost hint (#120), so a host can warn before it runs many copies (per note, Eco quality).
enum class CpuClass : uint8_t { Unspecified, Light, Medium, Heavy };
struct ModuleDescriptor {
    std::string_view id;           // stable, unique identity (reverse-DNS style, "org.example.delay")
    uint32_t apiVersion = 1;       // the contract version this descriptor follows
    const PortDescriptor* ports = nullptr;
    uint32_t portCount = 0;
    const ParameterDescriptor* parameters = nullptr;
    uint32_t parameterCount = 0;
    const UiControlDescriptor* uiControls = nullptr;
    uint32_t uiControlCount = 0;
    std::string_view customUiId;
    std::string_view name;         // display name; empty shows the id
    uint32_t version = 1;          // the component's own version (at least 1), separate from apiVersion
    ModuleRole role = ModuleRole::Unspecified;
    uint32_t latencyFrames = 0;    // processing delay a host compensates for, in frames
    uint32_t tailFrames = 0;       // frames of output after the input goes silent, or kInfiniteTail
    uint32_t maxStateBytes = 0;    // most bytes saveState writes; hosts size the buffer from it
    // Appended in C interface revision 3.1 (#120). A component loaded from an older build reads whole-only.
    uint32_t domains = kDomainWhole;    // kDomain* bits; kDomainWhole always set
    uint32_t capabilities = 0;          // kCapability* bits
    CpuClass cpuClass = CpuClass::Unspecified;
};
// Audio ports with an explicit layout. Stereo is the ordinary default for audio in and out. Between connected
// ports the graph widens only mono into stereo (duplicated); any other layout change is refused, so stereo
// into mono goes through an explicit downmix (org.caw.downmix).
constexpr PortDescriptor audioPort(std::string_view id, bool input, ChannelLayout layout = ChannelLayout::Stereo,
                                   uint32_t discreteChannels = 0) noexcept {
    PortDescriptor port;
    port.id = id;
    port.type = PortType::Audio;
    port.layout = layout;
    port.input = input;
    port.channelCount = layout == ChannelLayout::Discrete ? discreteChannels : 0;
    return port;
}
constexpr PortDescriptor stereoInput(std::string_view id) noexcept { return audioPort(id, true); }
constexpr PortDescriptor stereoOutput(std::string_view id) noexcept { return audioPort(id, false); }
enum class ModuleValidation : uint8_t {
    Ok, MissingId, UnsupportedApiVersion, MissingPortArray, MissingParameterArray,
    EmptyPortId, DuplicatePortId, InvalidPortType, InvalidPortLayout, EmptyParameterId,
    DuplicateParameterId, InvalidParameterRange, DefaultOutsideRange, MissingUiControlArray,
    EmptyUiControlId, InvalidUiControlKind, DuplicateUiControlId, UiControlMissingParameter,
    InvalidUiControlRange, TooManyChannels, InvalidSummingPort, InvalidPortDefault,
    InvalidParameterStep, InvalidParameterCurve, InvalidParameterSmoothing,
    InvalidModuleVersion, InvalidModuleRole, InvalidParameterChoices, EmptyParameterChoice,
    // #120: an unknown domain bit, no kDomainWhole; a domain the ports cannot take (PerChannel needs one mono
    // audio input and one mono audio output; PerNote and PerVoice the effect or instrument shape above);
    // an unknown capability bit, a capability without the port it needs, or an unknown cpuClass.
    InvalidDomains, DomainPortMismatch, InvalidCapabilities
};
ModuleValidation validateModuleDescriptor(const ModuleDescriptor& descriptor) noexcept;
bool moduleDescriptorsMatch(const ModuleDescriptor& a, const ModuleDescriptor& b) noexcept;
// A resolved parameter for one block (F6): per-frame values, or one value for the whole block.
struct ParameterValue {
    const double* samples = nullptr;  // null: `value` holds for every frame
    double value = 0.0;               // the block's first frame (what one-value-per-block readers see)
};
struct ConstChannelBufferView {
    const float* const* channels = nullptr;
    uint32_t channelCount = 0;
    uint32_t frames = 0;
    bool valid() const noexcept {
        if (channelCount != 0 && !channels) return false;
        for (uint32_t c = 0; c < channelCount; ++c) if (!channels[c]) return false;
        return true;
    }
};
struct ChannelBufferView {
    float* const* channels = nullptr;
    uint32_t channelCount = 0;
    uint32_t frames = 0;
    bool valid() const noexcept {
        if (channelCount != 0 && !channels) return false;
        for (uint32_t c = 0; c < channelCount; ++c) if (!channels[c]) return false;
        return true;
    }
};
// Frames rule: `frames` is the number of frames to process in this call. Each view's `frames`
// is its per-channel capacity and must be at least `frames`; a view with no channels needs none.
// `parameters` lists the module's resolved parameters in descriptor order (parameterCount equals
// the descriptor's parameterCount when a host resolves them; 0 when it does not).
// The host's transport for a block (null while stopped): tempo and song position, to sync to the song.
struct Transport {
    double tempo = 120.0;      // beats (quarter notes) per minute
    double beat = 0.0;         // song position of the block's first frame, in beats
    uint32_t beatsPerBar = 4;
    bool playing = false;
};
struct AudioProcessBlock {
    ConstChannelBufferView input;
    ChannelBufferView output;
    uint32_t frames = 0;
    double sampleRate = 48000.0;
    const ParameterValue* parameters = nullptr;
    uint32_t parameterCount = 0;
    const Transport* transport = nullptr;
};
inline bool audioProcessBlockValid(const AudioProcessBlock& block) noexcept {
    if (block.frames == 0 || !block.input.valid() || !block.output.valid()) return false;
    if (block.input.channelCount != 0 && block.input.frames < block.frames) return false;
    if (block.output.channelCount != 0 && block.output.frames < block.frames) return false;
    return true;
}
// The voice bus (#127; the C interface's CawVoiceBus, caw_component.h, gives the protocol in full): lanes the
// host owns, each for one note id, that an instrument declaring kDomainPerNote renders matching voices into.
// The instrument clears an ASSIGNED lane's stretch, renders the note's voice there instead of its mix, calls
// run(hostData, offset, frames) so the host processes the stretch in place, then adds every ASSIGNED lane into
// its mix before its shared stage. It sets kLaneEnded on a lane whose note no voice plays at the block's end.
// caw::VoiceLanes (caw/instrument.hpp) does this bookkeeping.
// kLaneRest (host): the overflow lane, note id 0, that every voice without a lane of its own renders into.
inline constexpr uint32_t kLaneAssigned = 1u, kLaneWritten = 2u, kLaneEnded = 4u, kLaneRest = 8u;
struct VoiceLane {
    uint32_t structSize = sizeof(VoiceLane);
    uint32_t noteId = 0;
    uint32_t flags = 0;
    uint32_t channelCount = 2;
    float* channels[2] = {nullptr, nullptr};
};
struct VoiceBus {
    uint32_t structSize = sizeof(VoiceBus);
    uint32_t laneCount = 0;
    uint32_t laneStride = sizeof(VoiceLane);  // bytes from one lane to the next
    VoiceLane* lanes = nullptr;
    void* hostData = nullptr;
    void (*run)(void* hostData, uint32_t offset, uint32_t frames) = nullptr;
};
inline VoiceLane* voiceLaneAt(const VoiceBus& bus, uint32_t index) noexcept {
    return reinterpret_cast<VoiceLane*>(reinterpret_cast<unsigned char*>(bus.lanes) + static_cast<size_t>(bus.laneStride) * index);
}

// Every port of a node, by type, each list in descriptor order (the k-th audio input is the k-th
// input port of type Audio). Audio views follow the AudioProcessBlock frames rule. Modulation
// buffers hold `frames` floats. A control input is read as *controlIn[k]; a control output is
// written as *controlOut[k] and keeps that value until written again. Event inputs and outputs
// follow the EventInput and EventOutput rules.
struct ProcessBlock {
    uint32_t frames = 0;
    double sampleRate = 48000.0;
    const ConstChannelBufferView* audioIn = nullptr;
    uint32_t audioInCount = 0;
    const ChannelBufferView* audioOut = nullptr;
    uint32_t audioOutCount = 0;
    const float* const* modulationIn = nullptr;
    uint32_t modulationInCount = 0;
    float* const* modulationOut = nullptr;
    uint32_t modulationOutCount = 0;
    const float* const* controlIn = nullptr;
    uint32_t controlInCount = 0;
    float* const* controlOut = nullptr;
    uint32_t controlOutCount = 0;
    const EventInput* eventIn = nullptr;
    uint32_t eventInCount = 0;
    EventOutput* eventOut = nullptr;
    uint32_t eventOutCount = 0;
    const ParameterValue* parameters = nullptr;  // as in AudioProcessBlock
    uint32_t parameterCount = 0;
    const Transport* transport = nullptr;        // as in AudioProcessBlock
    // An instrument declaring kDomainPerNote: the host's per-note FX lanes for this block, or null (render as
    // without a bus). Others ignore it.
    const VoiceBus* voices = nullptr;
};
struct StereoProcessBlock {
    const float* inputLeft = nullptr;
    const float* inputRight = nullptr;
    float* outputLeft = nullptr;
    float* outputRight = nullptr;
    uint32_t frames = 0;
    double sampleRate = 48000.0;
};
// Implement process(const AudioProcessBlock&) for any channel count, or only the legacy stereo
// overload for a stereo module. Hosts call the generic overload; its default adapts a block whose
// input and output each have 0 or 2 channels to the stereo overload, passing null pointers for a
// side with no channels (a generator has no input, a sink no output). A processor that implements
// neither fails every call (false) instead of silently leaving its output untouched, so never call
// the base stereo overload from an override. Overriding one overload hides the other in the
// derived class; add `using ModuleProcessor::process;` if callers use the derived type.
// A module with more than one audio input or output, or any control, modulation or event port, overrides
// usesProcessPorts() to return true and implements processPorts(); hosts then call only that.
// Hosts reject such a module at prepare time if it does not, never on its first block.
class ModuleProcessor {
public:
    virtual ~ModuleProcessor() = default;
    virtual const ModuleDescriptor& descriptor() const noexcept = 0;
    virtual bool usesProcessPorts() const noexcept { return false; }
    virtual bool processPorts(const ProcessBlock&) noexcept { return false; }
    virtual void process(const StereoProcessBlock&) noexcept { stereoImplemented_ = false; }
    virtual bool process(const AudioProcessBlock& block) noexcept {
        const uint32_t in = block.input.channelCount, out = block.output.channelCount;
        if ((in != 0 && in != 2) || (out != 0 && out != 2) || !audioProcessBlockValid(block)) return false;
        const StereoProcessBlock stereo{in ? block.input.channels[0] : nullptr,
            in ? block.input.channels[1] : nullptr, out ? block.output.channels[0] : nullptr,
            out ? block.output.channels[1] : nullptr, block.frames, block.sampleRate};
        stereoImplemented_ = true;
        process(stereo);
        return stereoImplemented_;
    }
    // Control thread, before the first block and again after a deactivate: prepare for this sample
    // rate and blocks of at most maxFrames (allocate here, never in process). False refuses the
    // instance. Hosts call deactivate before activating again and before destroying it.
    virtual bool activate(double sampleRate, uint32_t maxFrames) noexcept {
        (void)sampleRate; (void)maxFrames; return true;
    }
    virtual void deactivate() noexcept {}
    virtual void reset() noexcept {}
    // Audio thread, right after a process that succeeded: true when the output from here on is silence (all
    // zeros) until an event arrives or an audio input is not silent, whatever the parameters and the transport
    // do: an instrument with no voice sounding, an effect whose tail has died out. A host may then skip process
    // until that changes and use silence instead (the component's time does not move meanwhile). Default:
    // never quiet, always run (a declared tail alone never puts a component to sleep, so its output doesn't
    // depend on the host's block size). Say quiet only when nothing timed is left running (see docs/native-module-sdk.md).
    virtual bool quiet() const noexcept { return false; }
    // Live display data for the component's UI (#173): any thread but the audio thread, at any time while the
    // instance exists (process() may be running): copies the latest display block the processor published into
    // out (at most max floats) and returns how many floats it copied, 0 when it has none. Never blocks, locks or
    // allocates. A processor that publishes keeps a caw::DisplayBuffer (caw/display.hpp) and forwards to its
    // read(); the layout of the floats is the component's own (documented beside it).
    virtual uint32_t readDisplay(float* out, uint32_t max) const noexcept {
        (void)out; (void)max; return 0;
    }
    virtual uint32_t stateVersion() const noexcept { return 1; }
    // Called on the control thread, possibly while process() runs: keep it safe against processing.
    virtual bool saveState(uint8_t* destination, uint32_t capacity, uint32_t& written) const noexcept {
        (void)destination; (void)capacity; written = 0; return true;
    }
    virtual bool loadState(const uint8_t* source, uint32_t size, uint32_t version) noexcept {
        (void)source; return size == 0 && version == stateVersion();
    }

private:
    bool stereoImplemented_ = true;  // cleared only by the default stereo overload
};
}  // namespace caw

// The C interface (caw_component.h) is the binary boundary; these C++ types must match it exactly,
// so the SDK and host can pass process blocks across it without converting each field.
#include <cstddef>
#include <type_traits>
#include "../caw_component.h"
namespace caw::detail {
static_assert(static_cast<uint32_t>(PortType::Event) == CAW_PORT_EVENT);
static_assert(static_cast<uint32_t>(ChannelLayout::Stereo) == CAW_LAYOUT_STEREO);
static_assert(static_cast<uint32_t>(ChannelLayout::Discrete) == CAW_LAYOUT_DISCRETE);
static_assert(static_cast<uint32_t>(ModuleRole::Analyzer) == CAW_ROLE_ANALYZER);
static_assert(static_cast<uint32_t>(ParameterCurve::Exponential) == CAW_CURVE_EXPONENTIAL);
static_assert(static_cast<uint32_t>(UiControlKind::Curve) == CAW_UI_CURVE);
static_assert(static_cast<uint32_t>(EventKind::Midi) == CAW_EVENT_MIDI);
static_assert(sizeof(Event) == sizeof(CawEvent) && offsetof(Event, frame) == offsetof(CawEvent, frame) &&
              offsetof(Event, kind) == offsetof(CawEvent, kind) && offsetof(Event, flags) == offsetof(CawEvent, flags) &&
              offsetof(Event, noteId) == offsetof(CawEvent, note_id) && offsetof(Event, data) == offsetof(CawEvent, data));
static_assert(kInfiniteTail == CAW_INFINITE_TAIL);
static_assert(kDomainWhole == CAW_DOMAIN_WHOLE && kDomainPerChannel == CAW_DOMAIN_PER_CHANNEL &&
              kDomainPerVoice == CAW_DOMAIN_PER_VOICE && kDomainPerNote == CAW_DOMAIN_PER_NOTE);
static_assert(kCapabilityNotesIn == CAW_CAPABILITY_NOTES_IN && kCapabilityMidiIn == CAW_CAPABILITY_MIDI_IN &&
              kCapabilityEventsOut == CAW_CAPABILITY_EVENTS_OUT && kCapabilitySampleAssets == CAW_CAPABILITY_SAMPLE_ASSETS &&
              kCapabilityNeedsTransport == CAW_CAPABILITY_NEEDS_TRANSPORT && kCapabilityExportClap == CAW_CAPABILITY_EXPORT_CLAP);
static_assert(static_cast<uint32_t>(CpuClass::Heavy) == CAW_CPU_HEAVY);
static_assert(kLaneAssigned == CAW_LANE_ASSIGNED && kLaneWritten == CAW_LANE_WRITTEN && kLaneEnded == CAW_LANE_ENDED &&
              kLaneRest == CAW_LANE_REST);
// The voice bus crosses the C interface as is (the host's lanes reach a component without copying).
static_assert(sizeof(VoiceLane) == sizeof(CawVoiceLane) && offsetof(VoiceLane, noteId) == offsetof(CawVoiceLane, note_id) &&
              offsetof(VoiceLane, flags) == offsetof(CawVoiceLane, flags) &&
              offsetof(VoiceLane, channelCount) == offsetof(CawVoiceLane, channel_count) &&
              offsetof(VoiceLane, channels) == offsetof(CawVoiceLane, channels));
static_assert(sizeof(VoiceBus) == sizeof(CawVoiceBus) && offsetof(VoiceBus, laneCount) == offsetof(CawVoiceBus, lane_count) &&
              offsetof(VoiceBus, laneStride) == offsetof(CawVoiceBus, lane_stride) &&
              offsetof(VoiceBus, lanes) == offsetof(CawVoiceBus, lanes) &&
              offsetof(VoiceBus, hostData) == offsetof(CawVoiceBus, host_data) && offsetof(VoiceBus, run) == offsetof(CawVoiceBus, run));
static_assert(std::is_standard_layout_v<VoiceLane> && std::is_standard_layout_v<VoiceBus>);
static_assert(alignof(Event) == alignof(CawEvent) && std::is_standard_layout_v<Event> &&
              std::is_trivially_copyable_v<Event> && std::is_standard_layout_v<CawEvent>);
}  // namespace caw::detail
