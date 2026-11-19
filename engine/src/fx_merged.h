// Merged effect devices (FX consolidation, 1.0.8): one id per family, its `variant` choosing the class that runs.
#pragma once

#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "module_registry.h"
#include "project.h"

// A merged device (Pitch/Shift, Drive, EQ...) is one component id whose reserved parameter `variant` picks which of
// its variants runs. Each variant is its own EffectBase class with its own descriptor (the merged id and name, its
// own parameters, latency and tail, `variant` among them): the chain creates the variant's class directly
// (createComponent), so a variant runs only its own path, with no per-sample branch and no extra virtual call. A
// changed `variant` is a different structure (componentStructure): the chain is rebuilt on the control thread and
// crossfaded, as for a rack's slot. `variant` is set by hand only: not automatable, modulatable or MIDI-mappable
// (owner, 2026-11-18). The registry lists a merged id with its first variant's descriptor; caw_engine_components
// adds every variant's ("variants"). The old ids it replaces migrate to it (fx_migrate.h).

namespace caw {
struct BuiltinPreset;  // presets.h
namespace fx {

inline constexpr std::string_view kVariantParam = "variant";

// One variant of a merged device.
struct Variant {
    std::string_view name;                    // its choice label ("Pitch")
    const ModuleDescriptor& (*descriptor)();  // its own descriptor (the merged id; `variant` defaults to its index)
    ModuleFactory create;                     // a new instance of its class, whose descriptor() is descriptor()
};

// A merged device: its id, name and variants (the first is the default: an entry with no `variant` runs it).
struct MergedDevice {
    std::string_view id, name;
    std::span<const Variant> variants;
};

// The families' tables (the stubs return none until their part is built). Each family file defines its own.
std::span<const MergedDevice> mergedDynamicsDevices();  // builtin_fx_merged_dynamics.cpp: Compressor, Limiter, Transient
std::span<const MergedDevice> mergedDriveDevices();     // builtin_fx_merged_drive.cpp: Drive, Bit distortion
std::span<const MergedDevice> mergedEqFilterDevices();  // builtin_fx_merged_eqfilter.cpp: EQ, Filter
std::span<const MergedDevice> mergedStereoModDevices(); // builtin_fx_merged_stereomod.cpp: Utility/Stereo, Chorus/Flanger, Phaser, Tremolo/Pan
std::span<const MergedDevice> mergedSpaceDevices();     // builtin_fx_merged_space.cpp: Delay, Reverb, Pitch/Shift

// Presets of a merged device's variants that are new DSP (no old effect to migrate them from), appended after its
// old effects' (fx::mergedPresets): the Compressor's Duck (builtin_fx_duck.cpp). Each names its `variant`.
std::span<const BuiltinPreset> newVariantPresets(std::string_view id);
// The same for the EQ's and the Filter's 1.1.0 modes (Bands' dynamics, Linear, Match; Wah): builtin_fx_eq_plume.cpp.
std::span<const BuiltinPreset> newEqFilterVariantPresets(std::string_view id);

// Every merged device, in family order.
const std::vector<const MergedDevice*>& mergedDevices();
const MergedDevice* findMergedDevice(std::string_view id) noexcept;

// Registers every merged id (with its first variant's descriptor and class), replacing the old effect's
// registration where a merged device reuses its id (org.caw.utility...), and retires every other old id
// (fx_migrate.h: its registration goes, so it is no longer listed, found or made; a project, preset, rack or C API
// call naming one is migrated first). registerBuiltinEffects calls it last.
void registerMergedDevices(ModuleRegistry& registry);

// The variant `params` choose for `device` (its `variant` value rounded and held to the list; 0 when absent).
uint32_t variantIndex(const MergedDevice& device, const std::vector<std::pair<std::string, double>>& params) noexcept;

// A variant's descriptor made from a legacy class's own: the merged id and name, the legacy parameters in their
// order (so the class's parameter indices hold) and `variant` appended (a choice of `labels`, default `index`),
// everything else (ports, latency, tail, state, cost) kept. Lives for the program: call it once per variant (from
// the variant's descriptor function, in a function-local static).
const ModuleDescriptor& legacyVariantDescriptor(const ModuleDescriptor& legacy, std::string_view id,
                                                std::string_view name, std::span<const std::string_view> labels,
                                                uint32_t index);

// legacyVariantDescriptor with `after` appended after `variant` (1.1.0: Talon's Down extras and its talon_layout
// marker), so the base's indices and `variant`'s place hold for older racks' routes.
const ModuleDescriptor& extendedVariantDescriptor(const ModuleDescriptor& base, std::string_view id,
                                                  std::string_view name, std::span<const std::string_view> labels,
                                                  uint32_t index, std::span<const ParameterDescriptor> after);

// The `variant` parameter itself, for a variant that builds its own table: a choice of `labels`, default `index`,
// structural (no automation, modulation or MIDI mapping, no smoothing).
ParameterDescriptor variantParameter(std::span<const std::string_view> labels, uint32_t index) noexcept;

// A legacy class shown as a variant: the same DSP under the variant's descriptor. The class must not be final.
template <class T>
class AsVariant final : public T {
public:
    explicit AsVariant(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

private:
    const ModuleDescriptor& d_;
};

}  // namespace fx

// A new instance for a chain entry or a rack slot (control thread): a merged id makes the class of the variant its
// `params` choose; any other id is registry.create(id). Null when the id is unknown or the instance can't be made.
std::unique_ptr<ModuleProcessor> createComponent(const ModuleRegistry& registry, std::string_view id,
                                                 const std::vector<std::pair<std::string, double>>& params) noexcept;

// A component's descriptor as its `params` choose it: a merged device's variant's (its ports, latency and tail),
// else registry.find(id). Null for an unknown id.
const ModuleDescriptor* findComponentDescriptor(const ModuleRegistry& registry, std::string_view id,
                                                const std::vector<std::pair<std::string, double>>& params) noexcept;

// What a component's structure is, from its spec ("" for one with none): a rack's children (rackStructure) or a
// merged device's variant. Two specs with the same structure keep the running instance; another rebuilds it.
std::string componentStructure(const ComponentSpec& spec);

// Whether `param` of a merged device's spec is another variant's parameter (left over after a variant change, as
// a rack's `s2.cutoff` after its slot changed): the chain ignores it instead of refusing the entry.
bool isOtherVariantParameter(std::string_view id, std::string_view param) noexcept;

}  // namespace caw
