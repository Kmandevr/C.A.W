// Merged devices, part C (EQ, Filter): their variants, each an old effect's class unchanged (FX consolidation, 1.0.8).
#include "fx_merged.h"

// The ids this part replaces (the old ones stay registered until part F retires them):
// EQ ("org.caw.eq", the old parametric EQ's id reused) replaces org.caw.eq (variant 0 "Bands",
//   builtin_effects_eq.cpp), org.caw.geq (1 "Graphic"), org.caw.eq.dj (2 "DJ") and org.caw.tilt (3 "Tilt")
//   (builtin_fx_filters_eq.cpp). Dynamic EQ and M/S are new DSP, for a later part.
// Filter ("org.caw.filter", the old multimode filter's id reused) replaces org.caw.filter (variant 0 "Multimode",
//   builtin_effects_kit.cpp), org.caw.ladder (1 "Ladder") and org.caw.nlfilter (2 "Nonlinear")
//   (builtin_fx_filters.cpp). Auto-filter and envelope wah are new DSP, for a later part.
// Optional ports: none yet. The plan names a filter's low and high outputs, but none of the three old classes makes
//   them alongside the response it plays (the 24 dB, ladder and nonlinear paths compute only the chosen tap), so
//   offering them is new DSP in a variant class of its own, for the part that adds the routing.
// Not merged: org.caw.comb, .resonator, .formant, .disperser.

namespace caw::fx {

// The old classes' own descriptors and their instances under a variant's descriptor (in their own files).
const ModuleDescriptor& legacyEqDescriptor();
ModuleProcessor* makeEqAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyGeqDescriptor();
ModuleProcessor* makeGeqAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyEq3Descriptor();
ModuleProcessor* makeEq3As(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyTiltDescriptor();
ModuleProcessor* makeTiltAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyFilterDescriptor();
ModuleProcessor* makeFilterAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyLadderDescriptor();
ModuleProcessor* makeLadderAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyNlFilterDescriptor();
ModuleProcessor* makeNlFilterAs(const ModuleDescriptor& variant) noexcept;

namespace {

constexpr std::string_view kEqId = "org.caw.eq";
constexpr std::string_view kEqName = "EQ";
constexpr std::string_view kEqVariants[] = {"Bands", "Graphic", "DJ", "Tilt"};
constexpr std::string_view kFilterId = "org.caw.filter";
constexpr std::string_view kFilterName = "Filter";
constexpr std::string_view kFilterVariants[] = {"Multimode", "Ladder", "Nonlinear"};

// Each variant is the old class unchanged under its own descriptor: the old parameters in their order (so its
// indices hold), its latency (none), tail and cost, and `variant` last. Parameter ids are kept verbatim.
template <const ModuleDescriptor& (*Legacy)(), uint32_t Index>
const ModuleDescriptor& eqVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(Legacy(), kEqId, kEqName, kEqVariants, Index);
    return d;
}
template <const ModuleDescriptor& (*Legacy)(), uint32_t Index>
const ModuleDescriptor& filterVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(Legacy(), kFilterId, kFilterName, kFilterVariants, Index);
    return d;
}
template <const ModuleDescriptor& (*Descriptor)(), ModuleProcessor* (*Make)(const ModuleDescriptor&) noexcept>
ModuleProcessor* make() noexcept {
    return Make(Descriptor());
}

constexpr auto kBands = &eqVariant<&legacyEqDescriptor, 0>;
constexpr auto kGraphic = &eqVariant<&legacyGeqDescriptor, 1>;
constexpr auto kDj = &eqVariant<&legacyEq3Descriptor, 2>;
constexpr auto kTilt = &eqVariant<&legacyTiltDescriptor, 3>;
constexpr auto kMultimode = &filterVariant<&legacyFilterDescriptor, 0>;
constexpr auto kLadder = &filterVariant<&legacyLadderDescriptor, 1>;
constexpr auto kNonlinear = &filterVariant<&legacyNlFilterDescriptor, 2>;

const Variant kEq[] = {
    {kEqVariants[0], kBands, &make<kBands, &makeEqAs>},
    {kEqVariants[1], kGraphic, &make<kGraphic, &makeGeqAs>},
    {kEqVariants[2], kDj, &make<kDj, &makeEq3As>},
    {kEqVariants[3], kTilt, &make<kTilt, &makeTiltAs>},
};
const Variant kFilter[] = {
    {kFilterVariants[0], kMultimode, &make<kMultimode, &makeFilterAs>},
    {kFilterVariants[1], kLadder, &make<kLadder, &makeLadderAs>},
    {kFilterVariants[2], kNonlinear, &make<kNonlinear, &makeNlFilterAs>},
};

const MergedDevice kDevices[] = {{kEqId, kEqName, kEq}, {kFilterId, kFilterName, kFilter}};

}  // namespace

std::span<const MergedDevice> mergedEqFilterDevices() { return kDevices; }

}  // namespace caw::fx
