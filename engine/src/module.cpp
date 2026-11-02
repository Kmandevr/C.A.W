// Validation for the shared, typed module contract.
#include "module.h"

#include <cmath>

namespace caw {

ModuleValidation validateModuleDescriptor(const ModuleDescriptor& d) noexcept {
    if (d.id.empty()) return ModuleValidation::MissingId;
    if (d.apiVersion != 1) return ModuleValidation::UnsupportedApiVersion;
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
            case ChannelLayout::Discrete:
                break;
            default:
                return ModuleValidation::InvalidPortLayout;
        }
        if (p.type == PortType::Audio && p.layout == ChannelLayout::None)
            return ModuleValidation::InvalidPortLayout;
        if (p.type != PortType::Audio && p.layout != ChannelLayout::None)
            return ModuleValidation::InvalidPortLayout;
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
        for (uint32_t j = 0; j < i; ++j)
            if (d.parameters[j].id == p.id) return ModuleValidation::DuplicateParameterId;
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
    return ModuleValidation::Ok;
}

bool moduleDescriptorsMatch(const ModuleDescriptor& a, const ModuleDescriptor& b) noexcept {
    if (validateModuleDescriptor(a) != ModuleValidation::Ok ||
        validateModuleDescriptor(b) != ModuleValidation::Ok)
        return false;
    if (a.id != b.id || a.apiVersion != b.apiVersion ||
        a.portCount != b.portCount || a.parameterCount != b.parameterCount ||
        a.uiControlCount != b.uiControlCount || a.customUiId != b.customUiId)
        return false;

    for (uint32_t i = 0; i < a.portCount; ++i) {
        const PortDescriptor& x = a.ports[i];
        const PortDescriptor& y = b.ports[i];
        if (x.id != y.id || x.type != y.type || x.layout != y.layout || x.input != y.input)
            return false;
    }
    for (uint32_t i = 0; i < a.parameterCount; ++i) {
        const ParameterDescriptor& x = a.parameters[i];
        const ParameterDescriptor& y = b.parameters[i];
        if (x.id != y.id || x.defaultValue != y.defaultValue || x.minimum != y.minimum ||
            x.maximum != y.maximum || x.automatable != y.automatable)
            return false;
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
