// First-class native module contract. This is deliberately independent of Flutter and host audio APIs.
#pragma once
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
struct PortDescriptor {
    std::string_view id;
    PortType type = PortType::Audio;
    ChannelLayout layout = ChannelLayout::None;
    bool input = true;
    uint32_t channelCount = 0;
};
// Resolved channel count of a port: the layout's fixed count, or channelCount for Discrete.
constexpr uint32_t portChannelCount(const PortDescriptor& port) noexcept {
    return channelCountForLayout(port.layout, port.channelCount);
}
struct ParameterDescriptor {
    std::string_view id;
    double defaultValue = 0.0;
    double minimum = 0.0;
    double maximum = 1.0;
    bool automatable = true;
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
struct ModuleDescriptor {
    std::string_view id;
    uint32_t apiVersion = 1;
    const PortDescriptor* ports = nullptr;
    uint32_t portCount = 0;
    const ParameterDescriptor* parameters = nullptr;
    uint32_t parameterCount = 0;
    const UiControlDescriptor* uiControls = nullptr;
    uint32_t uiControlCount = 0;
    std::string_view customUiId;
};
enum class ModuleValidation : uint8_t {
    Ok, MissingId, UnsupportedApiVersion, MissingPortArray, MissingParameterArray,
    EmptyPortId, DuplicatePortId, InvalidPortType, InvalidPortLayout, EmptyParameterId,
    DuplicateParameterId, InvalidParameterRange, DefaultOutsideRange, MissingUiControlArray,
    EmptyUiControlId, InvalidUiControlKind, DuplicateUiControlId, UiControlMissingParameter,
    InvalidUiControlRange, TooManyChannels
};
ModuleValidation validateModuleDescriptor(const ModuleDescriptor& descriptor) noexcept;
bool moduleDescriptorsMatch(const ModuleDescriptor& a, const ModuleDescriptor& b) noexcept;
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
struct AudioProcessBlock {
    ConstChannelBufferView input;
    ChannelBufferView output;
    uint32_t frames = 0;
    double sampleRate = 48000.0;
};
inline bool audioProcessBlockValid(const AudioProcessBlock& block) noexcept {
    if (block.frames == 0 || !block.input.valid() || !block.output.valid()) return false;
    if (block.input.channelCount != 0 && block.input.frames < block.frames) return false;
    if (block.output.channelCount != 0 && block.output.frames < block.frames) return false;
    return true;
}
struct StereoProcessBlock {
    const float* inputLeft = nullptr;
    const float* inputRight = nullptr;
    float* outputLeft = nullptr;
    float* outputRight = nullptr;
    uint32_t frames = 0;
    double sampleRate = 48000.0;
};
// Implement process(const AudioProcessBlock&) for any channel count, or only the legacy stereo
// overload for a 2-in/2-out module. Hosts call the generic overload; its default adapts a stereo
// block to the stereo overload. A processor that implements neither fails every call (false)
// instead of silently leaving its output untouched. Overriding one overload hides the other in
// the derived class; add `using ModuleProcessor::process;` if callers use the derived type.
class ModuleProcessor {
public:
    virtual ~ModuleProcessor() = default;
    virtual const ModuleDescriptor& descriptor() const noexcept = 0;
    virtual void process(const StereoProcessBlock&) noexcept { stereoImplemented_ = false; }
    virtual bool process(const AudioProcessBlock& block) noexcept {
        if (block.input.channelCount != 2 || block.output.channelCount != 2 ||
            !audioProcessBlockValid(block)) return false;
        const StereoProcessBlock stereo{block.input.channels[0], block.input.channels[1],
            block.output.channels[0], block.output.channels[1], block.frames, block.sampleRate};
        stereoImplemented_ = true;
        process(stereo);
        return stereoImplemented_;
    }
    virtual void reset() noexcept {}
    virtual uint32_t stateVersion() const noexcept { return 1; }
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
