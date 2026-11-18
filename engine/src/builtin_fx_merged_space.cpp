// Merged devices, part E: Delay, Reverb and Pitch/Shift, each variant an old class unchanged (Pitch/Shift was the template).
#include "builtin_fx_creative.h"
#include "fx_merged.h"

// The ids this part replaces (the old ones stay registered until part F retires them):
// Pitch/Shift ("org.caw.shift", built): org.caw.pitchshift (variant 0 "Pitch", builtin_fx_creative_pitchshift.cpp)
//   and org.caw.freqshift (variant 1 "Frequency", builtin_fx_creative_freqshift.cpp).
// Delay ("org.caw.delay", built): org.caw.delay.pro (variant 0 "Digital", builtin_effects_space.cpp) and
//   org.caw.delay.pingpong (variant 1 "Ping-pong", builtin_components.cpp). Tape echo (wow and flutter) is new DSP
//   for later: it will be variant 2.
// Reverb ("org.caw.reverb", built): org.caw.reverb.pro (variant 0 "Hall", builtin_effects_space.cpp) and
//   org.caw.shimmer (variant 1 "Shimmer", builtin_fx_space_reverb.cpp). Room, Plate and Spring are new DSP for later
//   and will follow as variants 2 on (a saved index never moves). org.caw.convolver stays its own device.
//
// How to build a family, as Pitch/Shift here: per variant a descriptor function (legacyVariantDescriptor of the old
// class's descriptor, or a table of its own with variantParameter) and a factory (AsVariant<OldClass>, the class made
// non-final, or a new class); a Variant[] per device and the MergedDevice[] the family function returns (fx_merged.h);
// a LegacyEffect per old id in fx_migrate_<family>.cpp (fx_migrate.h); tests as fx_merged_test.cpp's for Pitch/Shift.

namespace caw::fx {

// The old classes' own descriptors and their instances under a variant's (builtin_effects_space.cpp,
// builtin_components.cpp, builtin_fx_space_reverb.cpp; fx_migrate_space.cpp declares the descriptors too).
const ModuleDescriptor& delayProDescriptor();
ModuleProcessor* makeDelayProAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& pingPongDelayDescriptor();
ModuleProcessor* makePingPongDelayAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& reverbProDescriptor();
ModuleProcessor* makeReverbProAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& shimmerReverbDescriptor();
ModuleProcessor* makeShimmerAs(const ModuleDescriptor& variant) noexcept;

namespace {

constexpr std::string_view kShiftId = "org.caw.shift";
constexpr std::string_view kShiftName = "Pitch/Shift";
constexpr std::string_view kShiftVariants[] = {"Pitch", "Frequency"};

// Each variant is the old class unchanged under its own descriptor: the old parameters (so its indices hold), its
// own latency (Pitch: half a grain, reported per instance; Frequency: none) and tail, and `variant` last.
const ModuleDescriptor& pitchVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(pitchShiftDescriptor(), kShiftId, kShiftName, kShiftVariants, 0);
    return d;
}
const ModuleDescriptor& frequencyVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(freqShiftDescriptor(), kShiftId, kShiftName, kShiftVariants, 1);
    return d;
}
ModuleProcessor* makePitch() noexcept { return makePitchShiftAs(pitchVariant()); }
ModuleProcessor* makeFrequency() noexcept { return makeFreqShiftAs(frequencyVariant()); }

const Variant kShift[] = {{kShiftVariants[0], &pitchVariant, &makePitch}, {kShiftVariants[1], &frequencyVariant, &makeFrequency}};

// Delay: the old classes unchanged, as Pitch/Shift's (both with an infinite tail and no latency).
constexpr std::string_view kDelayId = "org.caw.delay";
constexpr std::string_view kDelayName = "Delay";
constexpr std::string_view kDelayVariants[] = {"Digital", "Ping-pong"};

const ModuleDescriptor& digitalVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(delayProDescriptor(), kDelayId, kDelayName, kDelayVariants, 0);
    return d;
}
const ModuleDescriptor& pingPongVariant() {
    static const ModuleDescriptor& d =
        legacyVariantDescriptor(pingPongDelayDescriptor(), kDelayId, kDelayName, kDelayVariants, 1);
    return d;
}
ModuleProcessor* makeDigital() noexcept { return makeDelayProAs(digitalVariant()); }
ModuleProcessor* makePingPong() noexcept { return makePingPongDelayAs(pingPongVariant()); }

const Variant kDelay[] = {{kDelayVariants[0], &digitalVariant, &makeDigital}, {kDelayVariants[1], &pingPongVariant, &makePingPong}};

// Reverb: the same.
constexpr std::string_view kReverbId = "org.caw.reverb";
constexpr std::string_view kReverbName = "Reverb";
constexpr std::string_view kReverbVariants[] = {"Hall", "Shimmer"};

const ModuleDescriptor& hallVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(reverbProDescriptor(), kReverbId, kReverbName, kReverbVariants, 0);
    return d;
}
const ModuleDescriptor& shimmerVariant() {
    static const ModuleDescriptor& d =
        legacyVariantDescriptor(shimmerReverbDescriptor(), kReverbId, kReverbName, kReverbVariants, 1);
    return d;
}
ModuleProcessor* makeHall() noexcept { return makeReverbProAs(hallVariant()); }
ModuleProcessor* makeShimmer() noexcept { return makeShimmerAs(shimmerVariant()); }

const Variant kReverb[] = {{kReverbVariants[0], &hallVariant, &makeHall}, {kReverbVariants[1], &shimmerVariant, &makeShimmer}};

const MergedDevice kDevices[] = {{kDelayId, kDelayName, kDelay}, {kReverbId, kReverbName, kReverb}, {kShiftId, kShiftName, kShift}};

}  // namespace

std::span<const MergedDevice> mergedSpaceDevices() { return kDevices; }

}  // namespace caw::fx
