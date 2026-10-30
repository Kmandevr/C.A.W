// First-class native module contract. This is deliberately independent of Flutter and host audio APIs.
#pragma once

#include <cstdint>
#include <string_view>

namespace caw {

enum class PortType : uint8_t { Audio, Control, Modulation, Event };
enum class ChannelLayout : uint8_t { None, Mono, Stereo, Discrete };

struct PortDescriptor {
    std::string_view id;
    PortType type = PortType::Audio;
    ChannelLayout layout = ChannelLayout::None;
    bool input = true;
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
    std::string_view parameterId; // empty for action-only controls
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
    std::string_view customUiId; // optional host-rendered/custom view identifier
};

enum class ModuleValidation : uint8_t {
    Ok,
    MissingId,
    UnsupportedApiVersion,
    MissingPortArray,
    MissingParameterArray,
    EmptyPortId,
    DuplicatePortId,
    InvalidPortLayout,
    EmptyParameterId,
    DuplicateParameterId,
    InvalidParameterRange,
    DefaultOutsideRange,
    MissingUiControlArray,
    EmptyUiControlId,
    DuplicateUiControlId,
    UiControlMissingParameter,
    InvalidUiControlRange
};

// Validation is control-thread work. It never allocates and never runs in audio processing.
ModuleValidation validateModuleDescriptor(const ModuleDescriptor& descriptor) noexcept;

// A block is a borrowed view over host-owned buffers. Processing implementations must not
// allocate, lock, perform I/O, or retain these pointers. Stereo is the native processing shape.
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
    virtual void process(const StereoProcessBlock& block) noexcept = 0;
};

}  // namespace caw
