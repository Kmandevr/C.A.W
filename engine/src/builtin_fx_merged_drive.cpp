// Merged devices, part B (Drive, Bit distortion): their variants, each an old class unchanged under the merged id (FX consolidation, 1.0.8).
#include "fx_merged.h"

// The ids this part replaces (retired: no longer registered, migrated to these):
// Drive ("org.caw.drive"): org.caw.distortion (variant 0 "Distortion", builtin_components.cpp), org.caw.saturator
//   (1 "Saturate", builtin_effects_saturator.cpp; its own "mode" stays a parameter of that variant),
//   org.caw.clipper (2 "Clip") and org.caw.phasedist (3 "Phase", both builtin_fx_drive.cpp).
// Bit distortion ("org.caw.bits"): org.caw.bitcrush (variant 0 "Crush", builtin_fx_creative_bitcrush.cpp).
// Not here yet (new DSP, a later part): Drive's amp modes (Clean, Crunch, Lead, High gain), pedal modes (Overdrive,
// Distortion, Fuzz) and Bands mode; Bit distortion's bitwise modes (shift, XOR, AND masks).

namespace caw::fx {

// The old classes' own descriptors, and an instance of each under a variant's descriptor (AsVariant), defined next
// to each class.
const ModuleDescriptor& distortionDescriptor();  // builtin_components.cpp
ModuleProcessor* makeDistortionAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& saturatorDescriptor();  // builtin_effects_saturator.cpp
ModuleProcessor* makeSaturatorAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& clipperDescriptor();  // builtin_fx_drive.cpp
ModuleProcessor* makeClipperAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& phaseDistDescriptor();  // builtin_fx_drive.cpp
ModuleProcessor* makePhaseDistAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& bitcrushDescriptor();  // builtin_fx_creative_bitcrush.cpp
ModuleProcessor* makeBitcrushAs(const ModuleDescriptor& variant) noexcept;

namespace {

constexpr std::string_view kDriveId = "org.caw.drive";
constexpr std::string_view kDriveName = "Drive";
constexpr std::string_view kDriveVariants[] = {"Distortion", "Saturate", "Clip", "Phase"};

constexpr std::string_view kBitsId = "org.caw.bits";
constexpr std::string_view kBitsName = "Bit distortion";
constexpr std::string_view kBitsVariants[] = {"Crush"};

// Each variant is the old class unchanged under its own descriptor: the old parameters (so its indices hold), its
// own latency (Phase: its delay line's centre, 48 frames; the others none: the IIR oversamplers add none) and tail,
// and `variant` last.
const ModuleDescriptor& distortionVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(distortionDescriptor(), kDriveId, kDriveName, kDriveVariants, 0);
    return d;
}
const ModuleDescriptor& saturateVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(saturatorDescriptor(), kDriveId, kDriveName, kDriveVariants, 1);
    return d;
}
const ModuleDescriptor& clipVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(clipperDescriptor(), kDriveId, kDriveName, kDriveVariants, 2);
    return d;
}
const ModuleDescriptor& phaseVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(phaseDistDescriptor(), kDriveId, kDriveName, kDriveVariants, 3);
    return d;
}
const ModuleDescriptor& crushVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(bitcrushDescriptor(), kBitsId, kBitsName, kBitsVariants, 0);
    return d;
}
ModuleProcessor* makeDistortion() noexcept { return makeDistortionAs(distortionVariant()); }
ModuleProcessor* makeSaturate() noexcept { return makeSaturatorAs(saturateVariant()); }
ModuleProcessor* makeClip() noexcept { return makeClipperAs(clipVariant()); }
ModuleProcessor* makePhase() noexcept { return makePhaseDistAs(phaseVariant()); }
ModuleProcessor* makeCrush() noexcept { return makeBitcrushAs(crushVariant()); }

const Variant kDrive[] = {{kDriveVariants[0], &distortionVariant, &makeDistortion},
                          {kDriveVariants[1], &saturateVariant, &makeSaturate},
                          {kDriveVariants[2], &clipVariant, &makeClip},
                          {kDriveVariants[3], &phaseVariant, &makePhase}};
const Variant kBits[] = {{kBitsVariants[0], &crushVariant, &makeCrush}};

const MergedDevice kDevices[] = {{kDriveId, kDriveName, kDrive}, {kBitsId, kBitsName, kBits}};

}  // namespace

std::span<const MergedDevice> mergedDriveDevices() { return kDevices; }

}  // namespace caw::fx
