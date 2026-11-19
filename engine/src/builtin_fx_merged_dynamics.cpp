// Merged devices, part A (Compressor, Gate, Ducker, Limiter, Transient): their variants, the old dynamics classes unchanged and 1.1.0's new ones (the Talon/Hatch/Duck split).
#include "fx_dyn_common.h"
#include "fx_merged.h"

// 1.1.0's split (owner, 2026-11-19; the private sound plan's "Talon / Hatch / Duck split"):
// Compressor (org.caw.compressor): Down (0, the old compressor class: its 1.0.8 parameters, `variant`, then the key's
//   low-pass, character and output, which at their defaults leave the old path), Dynamics (1, unchanged), Up (2) and
//   Bus (3) (builtin_fx_talon.cpp). Every variant ends with the hidden talon_layout marker (fx_dyn_common.h): an
//   entry without it is from 1.0.8 or 1.0.9, whose variants 2 (Gate), 3 (Shape) and 4 (Duck) moved
//   (fx_migrate_dynamics.cpp).
// Gate (org.caw.gate, the old id reused again): Gate (0, the old gate class unchanged), Expand (1) and Pedal gate (2)
//   (builtin_fx_hatch.cpp).
// Ducker (org.caw.duck, new): Duck (0, 1.0.8's Duck class unchanged, builtin_fx_duck.cpp), Level (1) and Carve (2)
//   (builtin_fx_duck_level_carve.cpp).
// Shape (the drawn-shape ducker) is Tremolo/Pan's variant 2 (builtin_fx_merged_stereomod.cpp).
// Limiter replaces org.caw.limiter; Transient org.caw.transient (optional ports transient/sustain).
// Not merged: org.caw.multiband, org.caw.deesser (builtin_fx_dynamics.cpp).

namespace caw::fx {

// The classes (their own source files).
const ModuleDescriptor& legacyCompressorDescriptor();  // builtin_effects_dynamics.cpp
const ParamTable& talonDownExtraParams();
const ModuleDescriptor& legacyLimiterDescriptor();
const ModuleDescriptor& legacyGateDescriptor();
const ModuleDescriptor& legacyTransientDescriptor();
ModuleProcessor* makeCompressorAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeLimiterAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeGateAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeTransientAs(const ModuleDescriptor& variant) noexcept;  // with the transient/sustain outputs
const ModuleDescriptor& legacyDynamicsDescriptor();  // builtin_fx_dynamics.cpp
ModuleProcessor* makeDynamicsAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& talonUpBaseDescriptor();  // builtin_fx_talon.cpp
const ModuleDescriptor& talonBusBaseDescriptor();
ModuleProcessor* makeTalonUpAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeTalonBusAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& hatchExpandBaseDescriptor();  // builtin_fx_hatch.cpp
const ModuleDescriptor& hatchPedalBaseDescriptor();
ModuleProcessor* makeHatchExpandAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeHatchPedalAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& duckBaseVariantDescriptor();  // builtin_fx_duck.cpp
ModuleProcessor* makeDuckAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& duckLevelBaseDescriptor();  // builtin_fx_duck_level_carve.cpp
const ModuleDescriptor& duckCarveBaseDescriptor();
ModuleProcessor* makeDuckLevelAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeDuckCarveAs(const ModuleDescriptor& variant) noexcept;

namespace {

constexpr std::string_view kCompressorId = "org.caw.compressor";
constexpr std::string_view kCompressorName = "Compressor";
constexpr std::string_view kCompressorVariants[] = {"Down", "Dynamics", "Up", "Bus"};
constexpr std::string_view kGateId = "org.caw.gate";
constexpr std::string_view kGateName = "Gate";
constexpr std::string_view kGateVariants[] = {"Gate", "Expand", "Pedal gate"};
constexpr std::string_view kDuckId = "org.caw.duck";
constexpr std::string_view kDuckName = "Ducker";
constexpr std::string_view kDuckVariants[] = {"Duck", "Level", "Carve"};
constexpr std::string_view kLimiterId = "org.caw.limiter";
constexpr std::string_view kLimiterName = "Limiter";
constexpr std::string_view kLimiterVariants[] = {"Limiter"};
constexpr std::string_view kTransientId = "org.caw.transient";
constexpr std::string_view kTransientName = "Transient";
constexpr std::string_view kTransientVariants[] = {"Transient"};

const ParameterDescriptor* marker() {
    static const ParameterDescriptor p = dyn::talonLayoutParameter();
    return &p;
}
const std::vector<ParameterDescriptor>& downAfter() {
    static const std::vector<ParameterDescriptor> v = [] {
        const ParamTable& t = talonDownExtraParams();
        std::vector<ParameterDescriptor> out(t.data(), t.data() + t.size());
        out.push_back(*marker());
        return out;
    }();
    return v;
}

// A Talon variant: its class's table, `variant`, then (Down) its extras and the talon_layout marker.
template <uint32_t Index, const ModuleDescriptor& (*Base)(), ModuleProcessor* (*MakeAs)(const ModuleDescriptor&) noexcept>
struct Talon {
    static const ModuleDescriptor& descriptor() {
        static const ModuleDescriptor& d =
            Index == 0 ? extendedVariantDescriptor(Base(), kCompressorId, kCompressorName, kCompressorVariants, 0, downAfter())
                       : extendedVariantDescriptor(Base(), kCompressorId, kCompressorName, kCompressorVariants, Index,
                                                   std::span<const ParameterDescriptor>(marker(), 1));
        return d;
    }
    static ModuleProcessor* create() noexcept { return MakeAs(descriptor()); }
    static constexpr Variant variant() { return {kCompressorVariants[Index], &descriptor, &create}; }
};

// Any other variant: its class's table, then `variant`.
template <const std::string_view& Id, const std::string_view& Name, const auto& Labels, uint32_t Index,
          const ModuleDescriptor& (*Base)(), ModuleProcessor* (*MakeAs)(const ModuleDescriptor&) noexcept>
struct Plain {
    static const ModuleDescriptor& descriptor() {
        static const ModuleDescriptor& d = legacyVariantDescriptor(Base(), Id, Name, Labels, Index);
        return d;
    }
    static ModuleProcessor* create() noexcept { return MakeAs(descriptor()); }
    static constexpr Variant variant() { return {Labels[Index], &descriptor, &create}; }
};

const Variant kCompressor[] = {Talon<0, &legacyCompressorDescriptor, &makeCompressorAs>::variant(),
                               Talon<1, &legacyDynamicsDescriptor, &makeDynamicsAs>::variant(),
                               Talon<2, &talonUpBaseDescriptor, &makeTalonUpAs>::variant(),
                               Talon<3, &talonBusBaseDescriptor, &makeTalonBusAs>::variant()};
const Variant kGate[] = {Plain<kGateId, kGateName, kGateVariants, 0, &legacyGateDescriptor, &makeGateAs>::variant(),
                         Plain<kGateId, kGateName, kGateVariants, 1, &hatchExpandBaseDescriptor, &makeHatchExpandAs>::variant(),
                         Plain<kGateId, kGateName, kGateVariants, 2, &hatchPedalBaseDescriptor, &makeHatchPedalAs>::variant()};
const Variant kDuck[] = {Plain<kDuckId, kDuckName, kDuckVariants, 0, &duckBaseVariantDescriptor, &makeDuckAs>::variant(),
                         Plain<kDuckId, kDuckName, kDuckVariants, 1, &duckLevelBaseDescriptor, &makeDuckLevelAs>::variant(),
                         Plain<kDuckId, kDuckName, kDuckVariants, 2, &duckCarveBaseDescriptor, &makeDuckCarveAs>::variant()};
const Variant kLimiter[] = {
    Plain<kLimiterId, kLimiterName, kLimiterVariants, 0, &legacyLimiterDescriptor, &makeLimiterAs>::variant()};
const Variant kTransient[] = {
    Plain<kTransientId, kTransientName, kTransientVariants, 0, &legacyTransientDescriptor, &makeTransientAs>::variant()};

const MergedDevice kDevices[] = {{kCompressorId, kCompressorName, kCompressor},
                                 {kLimiterId, kLimiterName, kLimiter},
                                 {kTransientId, kTransientName, kTransient},
                                 {kGateId, kGateName, kGate},
                                 {kDuckId, kDuckName, kDuck}};

}  // namespace

std::span<const MergedDevice> mergedDynamicsDevices() { return kDevices; }

}  // namespace caw::fx
