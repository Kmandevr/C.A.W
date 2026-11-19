// The migration table of part D (Utility/Stereo, Chorus/Flanger, Phaser, Tremolo/Pan): old effect ids to their merged devices.
#include "builtin_fx_merged_stereomod.h"
#include "fx_migrate.h"

// The merged devices live in builtin_fx_merged_stereomod.cpp. Each reuses one old id (org.caw.utility,
// org.caw.chorus, org.caw.phaser, org.caw.tremolo) as its variant 0, which needs no entry here.

namespace caw::fx {

namespace {

// Every variant wraps its old class unchanged: every parameter keeps its id and value, no value is added, and the
// state carries over.
const LegacyEffect kEffects[] = {
    {"org.caw.stereo.width", "org.caw.utility", 1, {}, {}, true, &legacyWidthDescriptor},
    {"org.caw.stereo.balance", "org.caw.utility", 2, {}, {}, true, &legacyBalanceDescriptor},
    {"org.caw.imager", "org.caw.utility", 3, {}, {}, true, &legacyImagerDescriptor},
    {"org.caw.haas", "org.caw.utility", 4, {}, {}, true, &legacyHaasDescriptor},
    {"org.caw.channelmixer", "org.caw.utility", 5, {}, {}, true, &legacyChannelMixerDescriptor},
    {"org.caw.ensemble", "org.caw.chorus", 1, {}, {}, true, &legacyEnsembleDescriptor},
    {"org.caw.doubler", "org.caw.chorus", 2, {}, {}, true, &legacyDoublerDescriptor},
    {"org.caw.flanger", "org.caw.chorus", 3, {}, {}, true, &legacyFlangerDescriptor},
    {"org.caw.vibrato", "org.caw.chorus", 4, {}, {}, true, &legacyVibratoDescriptor},
    {"org.caw.rotary", "org.caw.chorus", 5, {}, {}, true, &legacyRotaryDescriptor},
    {"org.caw.autopan", "org.caw.tremolo", 1, {}, {}, true, &legacyAutopanDescriptor},
};

}  // namespace

std::span<const LegacyEffect> legacyStereoModEffects() { return kEffects; }

}  // namespace caw::fx
