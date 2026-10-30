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
    return ModuleValidation::Ok;
}

}  // namespace caw
