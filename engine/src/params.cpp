// Parameter resolution (F6): normalize/denormalize, modulation ops, smoothing and the per-block resolve.
#include "params.h"

#include <algorithm>
#include <cmath>

#include "detmath.h"

namespace caw {

namespace {
double clampToRange(const ParameterDescriptor& p, double plain) noexcept {
    if (std::isnan(plain)) return p.minimum;
    return std::clamp(plain, p.minimum, p.maximum);
}
double sanitize(float m) noexcept { return std::isfinite(m) ? static_cast<double>(m) : 0.0; }
}  // namespace

double normalizeParameter(const ParameterDescriptor& p, double plain) noexcept {
    const double v = clampToRange(p, plain);
    if (!(p.maximum > p.minimum)) return 0.0;
    if (p.curve == ParameterCurve::Exponential)
        return std::clamp(detLog(v / p.minimum) / detLog(p.maximum / p.minimum), 0.0, 1.0);
    return (v - p.minimum) / (p.maximum - p.minimum);
}

double denormalizeParameter(const ParameterDescriptor& p, double normalized) noexcept {
    const double n = std::isnan(normalized) ? 0.0 : std::clamp(normalized, 0.0, 1.0);
    if (!(p.maximum > p.minimum) || n <= 0.0) return p.minimum;
    if (n >= 1.0) return p.maximum;  // endpoints exact on every curve
    if (p.curve == ParameterCurve::Exponential)
        return clampToRange(p, p.minimum * detExp(n * detLog(p.maximum / p.minimum)));
    return clampToRange(p, p.minimum + n * (p.maximum - p.minimum));
}

double constrainParameter(const ParameterDescriptor& p, double plain) noexcept {
    double v = clampToRange(p, plain);
    // The same steps as the Engine's automation path, so values match it bit for bit.
    if (p.step > 0.0) v = std::clamp(p.minimum + std::round((v - p.minimum) / p.step) * p.step, p.minimum, p.maximum);
    return v;
}

double applyModulation(ModulationOp op, double d, double n, double m) noexcept {
    switch (op) {
        case ModulationOp::Add: return n + d * m;
        case ModulationOp::Multiply: return n + d * (n * m - n);
        case ModulationOp::Min: return n + d * (std::min(n, m) - n);
        case ModulationOp::Max: return n + d * (std::max(n, m) - n);
        case ModulationOp::Replace: return n + d * (m - n);
    }
    return n;
}

bool ParameterResolver::configure(const ParameterDescriptor& parameter) noexcept {
    const ModuleDescriptor probe{"caw.parameter", 1, nullptr, 0, &parameter, 1};
    if (validateModuleDescriptor(probe) != ModuleValidation::Ok) return false;
    parameter_ = parameter;
    linkCount_ = 0;
    current_ = target_ = parameter.defaultValue;
    increment_ = 0.0;
    rampLeft_ = 0;
    touched_ = false;
    return true;
}

bool ParameterResolver::setLinks(const ModulationLink* links, uint32_t count) noexcept {
    if (count > kMaxParameterLinks || (count && !links)) return false;
    ModulationLink sorted[kMaxParameterLinks];
    for (uint32_t k = 0; k < count; ++k) {
        const ModulationLink& link = links[k];
        if (!(link.depth >= -1.0 && link.depth <= 1.0)) return false;
        switch (link.op) {
            case ModulationOp::Add: case ModulationOp::Multiply: case ModulationOp::Min:
            case ModulationOp::Max: case ModulationOp::Replace: break;
            default: return false;
        }
        sorted[k] = link;
    }
    std::sort(sorted, sorted + count, [](const ModulationLink& a, const ModulationLink& b) { return a.id < b.id; });
    for (uint32_t k = 1; k < count; ++k)
        if (sorted[k].id == sorted[k - 1].id) return false;
    std::copy_n(sorted, count, links_);
    linkCount_ = count;
    return true;
}

void ParameterResolver::setBase(double plain) noexcept {
    const double value = clampToRange(parameter_, plain);
    touched_ = true;
    target_ = value;
    if (parameter_.smoothingFrames == 0) {
        current_ = value;
        rampLeft_ = 0;
        return;
    }
    rampLeft_ = parameter_.smoothingFrames;
    increment_ = (value - current_) / static_cast<double>(rampLeft_);
}

double ParameterResolver::frameValue(double base, const float* const* modulation, uint32_t frame) const noexcept {
    if (linkCount_ == 0) return constrainParameter(parameter_, base);
    double n = normalizeParameter(parameter_, base);
    for (uint32_t k = 0; k < linkCount_; ++k) {
        const double m = modulation && modulation[k] ? sanitize(modulation[k][frame]) : 0.0;
        n = applyModulation(links_[k].op, links_[k].depth, n, m);
    }
    return constrainParameter(parameter_, denormalizeParameter(parameter_, n));
}

ParameterValue ParameterResolver::resolve(uint32_t frames, const double* automation, const float* const* modulation,
                                          double* out) noexcept {
    const bool automated = automation && !touched_;
    bool modulated = false;
    for (uint32_t k = 0; k < linkCount_; ++k) modulated = modulated || (modulation && modulation[k]);
    if (!automated && !modulated && rampLeft_ == 0)
        return ParameterValue{nullptr, frameValue(current_, nullptr, 0)};
    if (frames == 0 || !out) return ParameterValue{nullptr, frameValue(current_, nullptr, 0)};
    for (uint32_t i = 0; i < frames; ++i) {
        if (rampLeft_ != 0) {
            current_ = --rampLeft_ == 0 ? target_ : current_ + increment_;  // lands exactly on the target
        }
        out[i] = frameValue(automated ? automation[i] : current_, modulation, i);
    }
    return ParameterValue{out, out[0]};
}

}  // namespace caw
