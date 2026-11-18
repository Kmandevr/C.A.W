// Merged effect devices (FX consolidation, 1.0.8): the family list, variant descriptors and instance creation.
#include "fx_merged.h"

#include <cmath>
#include <deque>
#include <mutex>

#include "builtin_fx_racks.h"

namespace caw {
namespace fx {

const std::vector<const MergedDevice*>& mergedDevices() {
    static const std::vector<const MergedDevice*> all = [] {
        std::vector<const MergedDevice*> v;
        for (std::span<const MergedDevice> family : {mergedDynamicsDevices(), mergedDriveDevices(), mergedEqFilterDevices(),
                                                     mergedStereoModDevices(), mergedSpaceDevices()})
            for (const MergedDevice& d : family) v.push_back(&d);
        return v;
    }();
    return all;
}

const MergedDevice* findMergedDevice(std::string_view id) noexcept {
    for (const MergedDevice* d : mergedDevices())
        if (d->id == id) return d;
    return nullptr;
}

void registerMergedDevices(ModuleRegistry& registry) {
    for (const MergedDevice* d : mergedDevices())
        if (!d->variants.empty()) registry.add(d->variants[0].descriptor(), d->variants[0].create);
}

uint32_t variantIndex(const MergedDevice& device, const std::vector<std::pair<std::string, double>>& params) noexcept {
    double v = 0.0;
    for (const auto& [name, value] : params)
        if (name == kVariantParam) v = value;  // the last one given wins, as for any value
    if (!std::isfinite(v) || v < 0.0 || device.variants.empty()) return 0;
    const double last = static_cast<double>(device.variants.size() - 1);
    return static_cast<uint32_t>(std::floor((v > last ? last : v) + 0.5));
}

ParameterDescriptor variantParameter(std::span<const std::string_view> labels, uint32_t index) noexcept {
    ParameterDescriptor p;
    p.id = kVariantParam;
    p.name = "Variant";
    p.defaultValue = static_cast<double>(index);
    p.minimum = 0.0;
    p.maximum = labels.empty() ? 0.0 : static_cast<double>(labels.size() - 1);
    p.step = 1.0;
    p.choices = labels.data();
    p.choiceCount = static_cast<uint32_t>(labels.size());
    p.smoothingFrames = 0;
    p.automatable = false;
    p.modulatable = false;
    p.midiMappable = false;
    return p;
}

const ModuleDescriptor& legacyVariantDescriptor(const ModuleDescriptor& legacy, std::string_view id,
                                                std::string_view name, std::span<const std::string_view> labels,
                                                uint32_t index) {
    struct Built {
        std::vector<ParameterDescriptor> params;
        ModuleDescriptor desc;
    };
    static std::deque<Built> store;  // start-up only (each variant's descriptor function holds its result)
    static std::mutex guard;         // two variants' first calls may come from two threads (two registries)
    const std::lock_guard<std::mutex> lock(guard);
    Built& b = store.emplace_back();
    b.params.assign(legacy.parameters, legacy.parameters + legacy.parameterCount);
    b.params.push_back(variantParameter(labels, index));
    b.desc = legacy;
    b.desc.id = id;
    b.desc.name = name;
    b.desc.parameters = b.params.data();
    b.desc.parameterCount = static_cast<uint32_t>(b.params.size());
    return b.desc;
}

}  // namespace fx

std::unique_ptr<ModuleProcessor> createComponent(const ModuleRegistry& registry, std::string_view id,
                                                 const std::vector<std::pair<std::string, double>>& params) noexcept {
    const fx::MergedDevice* d = registry.isBuiltin(id) ? fx::findMergedDevice(id) : nullptr;
    if (!d || d->variants.empty()) return registry.create(id);
    return std::unique_ptr<ModuleProcessor>(d->variants[fx::variantIndex(*d, params)].create());
}

std::string componentStructure(const ComponentSpec& spec) {
    if (isRackId(spec.id)) return rackStructure(spec);
    if (const fx::MergedDevice* d = fx::findMergedDevice(spec.id))
        return std::string(fx::kVariantParam) + "=" + std::to_string(fx::variantIndex(*d, spec.params));
    return {};
}

bool isOtherVariantParameter(std::string_view id, std::string_view param) noexcept {
    const fx::MergedDevice* d = fx::findMergedDevice(id);
    if (!d) return false;
    for (const fx::Variant& v : d->variants) {
        const ModuleDescriptor& desc = v.descriptor();
        for (uint32_t k = 0; k < desc.parameterCount; ++k)
            if (desc.parameters[k].id == param) return true;
    }
    return false;
}

}  // namespace caw
