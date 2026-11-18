// Merged devices, part E (Delay, Reverb, Pitch/Shift): their variants; Pitch/Shift is built and is the template the other families copy.
#include "builtin_fx_creative.h"
#include "fx_merged.h"

// The ids this part replaces (the old ones stay registered until part F retires them):
// Pitch/Shift ("org.caw.shift", built): org.caw.pitchshift (variant 0 "Pitch", builtin_fx_creative_pitchshift.cpp)
//   and org.caw.freqshift (variant 1 "Frequency", builtin_fx_creative_freqshift.cpp).
// Delay (Digital, Ping-pong, Tape echo with wow and flutter; part E) replaces org.caw.delay.pingpong
//   (builtin_components.cpp) and org.caw.delay.pro (builtin_effects_space.cpp).
// Reverb (Hall, Room, Plate, Spring, Shimmer; part E) replaces org.caw.reverb.pro (builtin_effects_space.cpp) and
//   org.caw.shimmer (builtin_fx_space_reverb.cpp). org.caw.convolver stays its own device.
//
// How to build a family, as Pitch/Shift here: per variant a descriptor function (legacyVariantDescriptor of the old
// class's descriptor, or a table of its own with variantParameter) and a factory (AsVariant<OldClass>, the class made
// non-final, or a new class); a Variant[] per device and the MergedDevice[] the family function returns (fx_merged.h);
// a LegacyEffect per old id in fx_migrate_<family>.cpp (fx_migrate.h); tests as fx_merged_test.cpp's for Pitch/Shift.

namespace caw::fx {

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

const MergedDevice kDevices[] = {{kShiftId, kShiftName, kShift}};

}  // namespace

std::span<const MergedDevice> mergedSpaceDevices() { return kDevices; }

}  // namespace caw::fx
