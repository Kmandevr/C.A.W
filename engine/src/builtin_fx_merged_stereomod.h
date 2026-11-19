// Merged devices, part D: the old effects' descriptors and classes the Utility/Stereo, Chorus/Flanger, Phaser and Tremolo/Pan variants wrap.
#pragma once

#include "fx_merged.h"

namespace caw::fx {

// Per old effect: its own descriptor (the old id's, as it was registered before it was retired) and its class, unchanged,
// under a variant's descriptor (fx::AsVariant). Defined beside each class.
// builtin_components.cpp: org.caw.stereo.width, org.caw.stereo.balance, org.caw.chorus.
const ModuleDescriptor& legacyWidthDescriptor();
ModuleProcessor* makeWidthAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyBalanceDescriptor();
ModuleProcessor* makeBalanceAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyChorusDescriptor();
ModuleProcessor* makeChorusAs(const ModuleDescriptor& variant) noexcept;
// builtin_fx_space_stereo.cpp: org.caw.imager, org.caw.haas, org.caw.channelmixer.
const ModuleDescriptor& legacyImagerDescriptor();
ModuleProcessor* makeImagerAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyHaasDescriptor();
ModuleProcessor* makeHaasAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyChannelMixerDescriptor();
ModuleProcessor* makeChannelMixerAs(const ModuleDescriptor& variant) noexcept;
// builtin_fx_space_mod.cpp: org.caw.ensemble, org.caw.doubler, org.caw.vibrato, org.caw.rotary, org.caw.tremolo,
// org.caw.autopan.
const ModuleDescriptor& legacyEnsembleDescriptor();
ModuleProcessor* makeEnsembleAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyDoublerDescriptor();
ModuleProcessor* makeDoublerAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyVibratoDescriptor();
ModuleProcessor* makeVibratoAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyRotaryDescriptor();
ModuleProcessor* makeRotaryAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyTremoloDescriptor();
ModuleProcessor* makeTremoloAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyAutopanDescriptor();
ModuleProcessor* makeAutopanAs(const ModuleDescriptor& variant) noexcept;
// builtin_effects_kit.cpp: org.caw.phaser, org.caw.flanger, org.caw.utility (its class with optional mid and side
// outputs, unconnected by default).
// builtin_ducker.cpp: org.caw.ducker (Shape, 1.1.0).
const ModuleDescriptor& legacyDuckerDescriptor();
ModuleProcessor* makeDuckerAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyPhaserDescriptor();
ModuleProcessor* makePhaserAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyFlangerDescriptor();
ModuleProcessor* makeFlangerAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyUtilityDescriptor();
ModuleProcessor* makeUtilityAs(const ModuleDescriptor& variant) noexcept;

}  // namespace caw::fx
