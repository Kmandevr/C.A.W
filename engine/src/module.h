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
struct PortDescriptor {
    std::string_view id;
    PortType type = PortType::Audio;
    ChannelLayout layout = ChannelLayout::None;
    bool input = true;
    uint32_t channelCount = 0;
};
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
    InvalidUiControlRange
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
struct AudioProcessBlock {
    ConstChannelBufferView input;
    ChannelBufferView output;
    uint32_t frames = 0;
    double sampleRate = 48000.0;
};
struct StereoProcessBlock {
    const float* inputLeft = nullptr;
    const float* inputRight = nullptr;
    float* outputLeft = nullptr;
    float* outputRight = nullptr;
    uint32_t frames = 0;
    double sampleRate = 48000.0;
};
class ModuleProcessor {
public:
    virtual ~ModuleProcessor() = default;
    virtual const ModuleDescriptor& descriptor() const noexcept = 0;
    virtual void process(const StereoProcessBlock&) noexcept {}
    virtual bool process(const AudioProcessBlock& block) noexcept {
        if (block.input.channelCount != 2 || block.output.channelCount != 2 ||
            !block.input.valid() || !block.output.valid() ||
            block.input.frames < block.frames || block.output.frames < block.frames) return false;
        const StereoProcessBlock stereo{block.input.channels[0], block.input.channels[1],
            block.output.channels[0], block.output.channels[1], block.frames, block.sampleRate};
        process(stereo);
        return true;
    }
    virtual void reset() noexcept {}
    virtual uint32_t stateVersion() const noexcept { return 1; }
    virtual bool saveState(uint8_t* destination, uint32_t capacity, uint32_t& written) const noexcept {
        (void)destination; (void)capacity; written = 0; return true;
    }
    virtual bool loadState(const uint8_t* source, uint32_t size, uint32_t version) noexcept {
        (void)source; return size == 0 && version == stateVersion();
    }
};
}  // namespace caw
