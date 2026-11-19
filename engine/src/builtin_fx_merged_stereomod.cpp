// Merged devices, part D (Utility/Stereo, Chorus/Flanger, Phaser, Tremolo/Pan): their variants, each an old effect's class unchanged.
#include "builtin_fx_merged_stereomod.h"

// The ids this part replaces (retired: no longer registered, migrated to these; fx_migrate_stereomod.cpp):
// Utility/Stereo ("org.caw.utility", the Utility's id reused): Utility (variant 0, builtin_effects_kit.cpp, with
//   optional mid and side outputs), Width (org.caw.stereo.width) and Balance (org.caw.stereo.balance,
//   builtin_components.cpp), Imager, Haas and Mixer (org.caw.imager, org.caw.haas, org.caw.channelmixer,
//   builtin_fx_space_stereo.cpp). org.caw.downmix stays its own device (owner).
// Chorus/Flanger ("org.caw.chorus", reused): Chorus (variant 0, builtin_components.cpp), Ensemble, Doubler
//   (builtin_fx_space_mod.cpp), Flanger (builtin_effects_kit.cpp), Vibrato and Rotary (builtin_fx_space_mod.cpp).
// Phaser ("org.caw.phaser", reused): Phaser (builtin_effects_kit.cpp), its only variant for now.
// Tremolo/Pan ("org.caw.tremolo", reused): Tremolo (variant 0) and Pan (org.caw.autopan), builtin_fx_space_mod.cpp;
// Shape (2, 1.1.0: the drawn-shape ducker, builtin_ducker.cpp).
// No new DSP here: the plan's new modes (M/S and the like) come in a later part.

namespace caw::fx {

namespace {

// A variant that is an old class unchanged: its descriptor made once from the old one (the old parameters in their
// order, `variant` last, latency, tail, ports and cost kept), its factory the class under that descriptor.
template <const std::string_view& Id, const std::string_view& Name, const auto& Labels, uint32_t Index,
          const ModuleDescriptor& (*Legacy)(), ModuleProcessor* (*MakeAs)(const ModuleDescriptor&) noexcept>
struct Wrapped {
    static const ModuleDescriptor& descriptor() {
        static const ModuleDescriptor& d = legacyVariantDescriptor(Legacy(), Id, Name, Labels, Index);
        return d;
    }
    static ModuleProcessor* create() noexcept { return MakeAs(descriptor()); }
    static constexpr Variant variant() { return {Labels[Index], &descriptor, &create}; }
};

// ---------- Utility/Stereo ----------

constexpr std::string_view kUtilityId = "org.caw.utility";
constexpr std::string_view kUtilityName = "Utility/Stereo";
constexpr std::string_view kUtilityVariants[] = {"Utility", "Width", "Balance", "Imager", "Haas", "Mixer"};
template <uint32_t I, const ModuleDescriptor& (*L)(), ModuleProcessor* (*M)(const ModuleDescriptor&) noexcept>
using UtilityV = Wrapped<kUtilityId, kUtilityName, kUtilityVariants, I, L, M>;
const Variant kUtility[] = {
    UtilityV<0, &legacyUtilityDescriptor, &makeUtilityAs>::variant(),
    UtilityV<1, &legacyWidthDescriptor, &makeWidthAs>::variant(),
    UtilityV<2, &legacyBalanceDescriptor, &makeBalanceAs>::variant(),
    UtilityV<3, &legacyImagerDescriptor, &makeImagerAs>::variant(),
    UtilityV<4, &legacyHaasDescriptor, &makeHaasAs>::variant(),
    UtilityV<5, &legacyChannelMixerDescriptor, &makeChannelMixerAs>::variant(),
};

// ---------- Chorus/Flanger ----------

constexpr std::string_view kChorusId = "org.caw.chorus";
constexpr std::string_view kChorusName = "Chorus/Flanger";
constexpr std::string_view kChorusVariants[] = {"Chorus", "Ensemble", "Doubler", "Flanger", "Vibrato", "Rotary"};
template <uint32_t I, const ModuleDescriptor& (*L)(), ModuleProcessor* (*M)(const ModuleDescriptor&) noexcept>
using ChorusV = Wrapped<kChorusId, kChorusName, kChorusVariants, I, L, M>;
const Variant kChorus[] = {
    ChorusV<0, &legacyChorusDescriptor, &makeChorusAs>::variant(),
    ChorusV<1, &legacyEnsembleDescriptor, &makeEnsembleAs>::variant(),
    ChorusV<2, &legacyDoublerDescriptor, &makeDoublerAs>::variant(),
    ChorusV<3, &legacyFlangerDescriptor, &makeFlangerAs>::variant(),
    ChorusV<4, &legacyVibratoDescriptor, &makeVibratoAs>::variant(),
    ChorusV<5, &legacyRotaryDescriptor, &makeRotaryAs>::variant(),
};

// ---------- Phaser ----------

constexpr std::string_view kPhaserId = "org.caw.phaser";
constexpr std::string_view kPhaserName = "Phaser";
constexpr std::string_view kPhaserVariants[] = {"Phaser"};
const Variant kPhaser[] = {
    Wrapped<kPhaserId, kPhaserName, kPhaserVariants, 0, &legacyPhaserDescriptor, &makePhaserAs>::variant(),
};

// ---------- Tremolo/Pan ----------

constexpr std::string_view kTremoloId = "org.caw.tremolo";
constexpr std::string_view kTremoloName = "Tremolo/Pan";
constexpr std::string_view kTremoloVariants[] = {"Tremolo", "Pan", "Shape"};
const Variant kTremolo[] = {
    Wrapped<kTremoloId, kTremoloName, kTremoloVariants, 0, &legacyTremoloDescriptor, &makeTremoloAs>::variant(),
    Wrapped<kTremoloId, kTremoloName, kTremoloVariants, 1, &legacyAutopanDescriptor, &makeAutopanAs>::variant(),
    // 1.1.0: the drawn-shape ducker (org.caw.ducker; 1.0.8-1.0.9 the Compressor's variant 3), periodic volume.
    Wrapped<kTremoloId, kTremoloName, kTremoloVariants, 2, &legacyDuckerDescriptor, &makeDuckerAs>::variant(),
};

const MergedDevice kDevices[] = {
    {kUtilityId, kUtilityName, kUtility},
    {kChorusId, kChorusName, kChorus},
    {kPhaserId, kPhaserName, kPhaser},
    {kTremoloId, kTremoloName, kTremolo},
};

}  // namespace

std::span<const MergedDevice> mergedStereoModDevices() { return kDevices; }

}  // namespace caw::fx
