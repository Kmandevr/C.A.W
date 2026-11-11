// Validation for the shared, typed module contract.
#include "module.h"

#include <algorithm>
#include <cmath>
#include <string_view>
#include <vector>

namespace caw {

namespace {
constexpr uint32_t kQuadraticLimit = 256;  // up to this many parameters, the plain pairwise duplicate check

// The domains and capabilities against the ports (#120); the ports themselves are already valid.
ModuleValidation validateDomains(const ModuleDescriptor& d) noexcept {
    if ((d.domains & ~kKnownDomains) != 0 || (d.domains & kDomainWhole) == 0) return ModuleValidation::InvalidDomains;
    uint32_t audioIn = 0, audioOut = 0, eventIn = 0, eventOut = 0;
    const PortDescriptor* in = nullptr;
    const PortDescriptor* out = nullptr;
    for (uint32_t i = 0; i < d.portCount; ++i) {
        const PortDescriptor& p = d.ports[i];
        if (p.type == PortType::Audio) {
            if (p.input) in = &p, ++audioIn;
            else out = &p, ++audioOut;
        } else if (p.type == PortType::Event) {
            ++(p.input ? eventIn : eventOut);
        }
    }
    if ((d.domains & kDomainPerChannel) &&
        !(audioIn == 1 && audioOut == 1 && in->layout == ChannelLayout::Mono && out->layout == ChannelLayout::Mono))
        return ModuleValidation::DomainPortMismatch;
    if (d.domains & (kDomainPerNote | kDomainPerVoice)) {
        const bool effect = audioIn == 1 && audioOut == 1 && in->layout == ChannelLayout::Stereo &&
                            out->layout == ChannelLayout::Stereo;
        const bool instrument = audioIn == 0 && audioOut == 1 && out->layout == ChannelLayout::Stereo && eventIn > 0;
        if (!effect && !instrument) return ModuleValidation::DomainPortMismatch;
    }
    if ((d.capabilities & ~kKnownCapabilities) != 0 ||
        ((d.capabilities & (kCapabilityNotesIn | kCapabilityMidiIn)) && eventIn == 0) ||
        ((d.capabilities & kCapabilityEventsOut) && eventOut == 0))
        return ModuleValidation::InvalidCapabilities;
    switch (d.cpuClass) {
        case CpuClass::Unspecified:
        case CpuClass::Light:
        case CpuClass::Medium:
        case CpuClass::Heavy: break;
        default: return ModuleValidation::InvalidCapabilities;
    }
    return ModuleValidation::Ok;
}
}  // namespace

ModuleValidation validateModuleDescriptor(const ModuleDescriptor& d) noexcept {
    if (d.id.empty()) return ModuleValidation::MissingId;
    if (d.apiVersion != 1) return ModuleValidation::UnsupportedApiVersion;
    if (d.version == 0) return ModuleValidation::InvalidModuleVersion;
    switch (d.role) {
        case ModuleRole::Unspecified:
        case ModuleRole::Instrument:
        case ModuleRole::Generator:
        case ModuleRole::Effect:
        case ModuleRole::Utility:
        case ModuleRole::EventProcessor:
        case ModuleRole::Analyzer: break;
        default: return ModuleValidation::InvalidModuleRole;
    }
    if (d.portCount && !d.ports) return ModuleValidation::MissingPortArray;
    if (d.parameterCount && !d.parameters) return ModuleValidation::MissingParameterArray;

    for (uint32_t i = 0; i < d.portCount; ++i) {
        const PortDescriptor& p = d.ports[i];
        if (p.id.empty()) return ModuleValidation::EmptyPortId;
        switch (p.type) {
            case PortType::Audio:
            case PortType::Control:
            case PortType::Modulation:
            case PortType::Event:
                break;
            default:
                return ModuleValidation::InvalidPortType;
        }
        switch (p.layout) {
            case ChannelLayout::None:
            case ChannelLayout::Mono:
            case ChannelLayout::Stereo:
            case ChannelLayout::Quad:
            case ChannelLayout::Surround51:
            case ChannelLayout::Surround71:
            case ChannelLayout::Discrete: break;
            default: return ModuleValidation::InvalidPortLayout;
        }
        if (p.type == PortType::Audio) {
            if (p.layout == ChannelLayout::None ||
                channelCountForLayout(p.layout, p.channelCount) == 0)
                return ModuleValidation::InvalidPortLayout;
            if (p.layout == ChannelLayout::Discrete) {
                if (p.channelCount == 0) return ModuleValidation::InvalidPortLayout;
            } else if (p.channelCount != 0) return ModuleValidation::InvalidPortLayout;
            if (portChannelCount(p) > kMaxPortChannels) return ModuleValidation::TooManyChannels;
            if (p.summing && !p.input) return ModuleValidation::InvalidSummingPort;
        } else if (p.layout != ChannelLayout::None || p.channelCount != 0) {
            return ModuleValidation::InvalidPortLayout;
        } else if (p.summing && !((p.type == PortType::Modulation || p.type == PortType::Event) && p.input)) {
            return ModuleValidation::InvalidSummingPort;
        }
        if (p.type == PortType::Control ? !std::isfinite(p.defaultValue) : p.defaultValue != 0.0f)
            return ModuleValidation::InvalidPortDefault;
        for (uint32_t j = 0; j < i; ++j)
            if (d.ports[j].id == p.id) return ModuleValidation::DuplicatePortId;
    }

    for (uint32_t i = 0; i < d.parameterCount; ++i) {
        const ParameterDescriptor& p = d.parameters[i];
        if (p.id.empty()) return ModuleValidation::EmptyParameterId;
        if (!std::isfinite(p.minimum) || !std::isfinite(p.maximum) || p.minimum > p.maximum)
            return ModuleValidation::InvalidParameterRange;
        if (!std::isfinite(p.defaultValue) || p.defaultValue < p.minimum || p.defaultValue > p.maximum)
            return ModuleValidation::DefaultOutsideRange;
        if (!std::isfinite(p.step) || p.step < 0.0) return ModuleValidation::InvalidParameterStep;
        if (p.smoothingFrames > kMaxParameterSmoothingFrames) return ModuleValidation::InvalidParameterSmoothing;
        switch (p.curve) {
            case ParameterCurve::Linear: break;
            case ParameterCurve::Exponential:
                if (!(p.minimum > 0.0)) return ModuleValidation::InvalidParameterCurve;
                break;
            default: return ModuleValidation::InvalidParameterCurve;
        }
        if (p.choiceCount != 0) {
            // Labels for minimum, minimum + 1, ..., maximum (so the range is small and exact).
            // Bounded so every value is an exact double and the label checks stay cheap; on the
            // linear curve so modulation and snapping step evenly through the choices.
            if (!p.choices || p.choiceCount > kMaxParameterChoices || p.step != 1.0 ||
                p.curve != ParameterCurve::Linear || std::floor(p.minimum) != p.minimum ||
                std::fabs(p.minimum) > kMaxChoiceValue || std::fabs(p.maximum) > kMaxChoiceValue ||
                p.maximum - p.minimum + 1.0 != static_cast<double>(p.choiceCount))
                return ModuleValidation::InvalidParameterChoices;
            for (uint32_t c = 0; c < p.choiceCount; ++c)
                if (p.choices[c].empty()) return ModuleValidation::EmptyParameterChoice;
        } else if (p.choices) {
            return ModuleValidation::InvalidParameterChoices;
        }
        if (d.parameterCount <= kQuadraticLimit)
            for (uint32_t j = 0; j < i; ++j)
                if (d.parameters[j].id == p.id) return ModuleValidation::DuplicateParameterId;
    }
    // A large list (org.caw.drums has thousands): sorted, so the check is n log n instead of n^2.
    if (d.parameterCount > kQuadraticLimit) {
        try {
            std::vector<std::string_view> ids(d.parameterCount);
            for (uint32_t i = 0; i < d.parameterCount; ++i) ids[i] = d.parameters[i].id;
            std::sort(ids.begin(), ids.end());
            if (std::adjacent_find(ids.begin(), ids.end()) != ids.end()) return ModuleValidation::DuplicateParameterId;
        } catch (...) {
            return ModuleValidation::DuplicateParameterId;  // out of memory: refuse rather than guess
        }
    }
    if (d.uiControlCount && !d.uiControls) return ModuleValidation::MissingUiControlArray;
    for (uint32_t i = 0; i < d.uiControlCount; ++i) {
        const UiControlDescriptor& ui = d.uiControls[i];
        if (ui.id.empty()) return ModuleValidation::EmptyUiControlId;
        switch (ui.kind) {
            case UiControlKind::Slider:
            case UiControlKind::Toggle:
            case UiControlKind::Dropdown:
            case UiControlKind::XYPad:
            case UiControlKind::Button:
            case UiControlKind::Curve:
                break;
            default:
                return ModuleValidation::InvalidUiControlKind;
        }
        if (!std::isfinite(ui.minimum) || !std::isfinite(ui.maximum) || ui.minimum > ui.maximum)
            return ModuleValidation::InvalidUiControlRange;
        for (uint32_t j = 0; j < i; ++j)
            if (d.uiControls[j].id == ui.id) return ModuleValidation::DuplicateUiControlId;
        if (!ui.parameterId.empty()) {
            const ParameterDescriptor* parameter = nullptr;
            for (uint32_t j = 0; j < d.parameterCount; ++j)
                if (d.parameters[j].id == ui.parameterId) parameter = &d.parameters[j];
            if (!parameter) return ModuleValidation::UiControlMissingParameter;
            if (ui.minimum < parameter->minimum || ui.maximum > parameter->maximum)
                return ModuleValidation::InvalidUiControlRange;
        }
    }
    return validateDomains(d);
}

bool moduleDescriptorsMatch(const ModuleDescriptor& a, const ModuleDescriptor& b) noexcept {
    if (&a == &b) return validateModuleDescriptor(a) == ModuleValidation::Ok;  // a built-in's own descriptor
    if (validateModuleDescriptor(a) != ModuleValidation::Ok ||
        validateModuleDescriptor(b) != ModuleValidation::Ok)
        return false;
    if (a.id != b.id || a.apiVersion != b.apiVersion ||
        a.portCount != b.portCount || a.parameterCount != b.parameterCount ||
        a.uiControlCount != b.uiControlCount || a.customUiId != b.customUiId ||
        a.version != b.version || a.role != b.role || a.latencyFrames != b.latencyFrames ||
        a.tailFrames != b.tailFrames || a.maxStateBytes != b.maxStateBytes || a.domains != b.domains ||
        a.capabilities != b.capabilities || a.cpuClass != b.cpuClass)
        return false;

    for (uint32_t i = 0; i < a.portCount; ++i) {
        const PortDescriptor& x = a.ports[i];
        const PortDescriptor& y = b.ports[i];
        if (x.id != y.id || x.type != y.type || x.layout != y.layout || x.input != y.input || x.channelCount != y.channelCount ||
            x.summing != y.summing || !(x.defaultValue == y.defaultValue))
            return false;
    }
    for (uint32_t i = 0; i < a.parameterCount; ++i) {
        const ParameterDescriptor& x = a.parameters[i];
        const ParameterDescriptor& y = b.parameters[i];
        if (x.id != y.id || x.defaultValue != y.defaultValue || x.minimum != y.minimum ||
            x.maximum != y.maximum || x.automatable != y.automatable || x.curve != y.curve ||
            x.step != y.step || x.smoothingFrames != y.smoothingFrames ||
            x.modulatable != y.modulatable || x.midiMappable != y.midiMappable || x.choiceCount != y.choiceCount)
            return false;  // unit, name and choice labels are display text: not part of the match
    }
    for (uint32_t i = 0; i < a.uiControlCount; ++i) {
        const UiControlDescriptor& x = a.uiControls[i];
        const UiControlDescriptor& y = b.uiControls[i];
        if (x.id != y.id || x.label != y.label || x.parameterId != y.parameterId ||
            x.kind != y.kind || x.minimum != y.minimum || x.maximum != y.maximum)
            return false;
    }
    return true;
}

}  // namespace caw
