// Merged devices, part E: Delay, Reverb and Pitch/Shift, each variant an old class unchanged (Pitch/Shift was the template).
#include "builtin_fx_creative.h"
#include "builtin_fx_voice.h"
#include "fx_merged.h"

// The ids this part replaces (retired: no longer registered, migrated to these):
// Pitch/Shift ("org.caw.shift", built): org.caw.pitchshift (variant 0 "Pitch", builtin_fx_creative_pitchshift.cpp)
//   and org.caw.freqshift (variant 1 "Frequency", builtin_fx_creative_freqshift.cpp). 1.1.0 appends new DSP: 2
//   "Harmonizer" and 3 "Octaver" (builtin_fx_shift_voices.cpp).
// Delay ("org.caw.delay", built): org.caw.delay.pro (variant 0 "Digital", builtin_effects_space.cpp) and
//   org.caw.delay.pingpong (variant 1 "Ping-pong", builtin_components.cpp). 1.1.0 appends new DSP: 2 "Tape", 3 "Reverse"
//   and 4 "Multi-tap" (builtin_fx_delay_modes.cpp).
// Reverb ("org.caw.reverb", built): org.caw.reverb.pro (variant 0 "Hall", builtin_effects_space.cpp) and
//   org.caw.shimmer (variant 1 "Shimmer", builtin_fx_space_reverb.cpp). 1.1.0 appends new DSP: 2 "Room", 3 "Plate",
//   4 "Spring", 5 "Gated", 6 "Reverse" (builtin_fx_reverb_modes.cpp; a saved index never moves). org.caw.convolver is merged in 1.1.0 (its id reused, variant 0 the convolver, 1 "Cab").
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
// 1.1.0's new Delay modes (builtin_fx_delay_modes.cpp): their own tables, `variant` appended.
const ModuleDescriptor& tapeDelayDescriptor(std::span<const std::string_view> labels, uint32_t index);
const ModuleDescriptor& reverseDelayDescriptor(std::span<const std::string_view> labels, uint32_t index);
const ModuleDescriptor& multiTapDelayDescriptor(std::span<const std::string_view> labels, uint32_t index);
ModuleProcessor* makeTapeDelayAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeReverseDelayAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeMultiTapDelayAs(const ModuleDescriptor& variant) noexcept;
// 1.1.0's new Reverb modes (builtin_fx_reverb_modes.cpp).
const ModuleDescriptor& roomReverbDescriptor(std::span<const std::string_view> labels, uint32_t index);
const ModuleDescriptor& plateReverbDescriptor(std::span<const std::string_view> labels, uint32_t index);
const ModuleDescriptor& springReverbDescriptor(std::span<const std::string_view> labels, uint32_t index);
const ModuleDescriptor& gatedReverbDescriptor(std::span<const std::string_view> labels, uint32_t index);
const ModuleDescriptor& reverseReverbDescriptor(std::span<const std::string_view> labels, uint32_t index);
ModuleProcessor* makeRoomReverbAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makePlateReverbAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeSpringReverbAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeGatedReverbAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeReverseReverbAs(const ModuleDescriptor& variant) noexcept;
// The Convolver (1.1.0: merged, its id reused): the convolver as it was (builtin_fx_space_reverb.cpp) and Cab
// (builtin_fx_cab.cpp).
const ModuleDescriptor& convolverDescriptor();
ModuleProcessor* makeConvolverAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& cabDescriptor(std::span<const std::string_view> labels, uint32_t index);
ModuleProcessor* makeCabAs(const ModuleDescriptor& variant) noexcept;

namespace {

constexpr std::string_view kShiftId = "org.caw.shift";
constexpr std::string_view kShiftName = "Pitch/Shift";
constexpr std::string_view kShiftVariants[] = {"Pitch", "Frequency", "Harmonizer", "Octaver"};  // 1.1.0: 2, 3 appended

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

const ModuleDescriptor& harmonizerVariant() { return harmonizerDescriptor(kShiftVariants, 2); }
const ModuleDescriptor& octaverVariant() { return octaverDescriptor(kShiftVariants, 3); }
ModuleProcessor* makeHarmonizer() noexcept { return makeHarmonizerAs(harmonizerVariant()); }
ModuleProcessor* makeOctaver() noexcept { return makeOctaverAs(octaverVariant()); }

const Variant kShift[] = {{kShiftVariants[0], &pitchVariant, &makePitch},
                          {kShiftVariants[1], &frequencyVariant, &makeFrequency},
                          {kShiftVariants[2], &harmonizerVariant, &makeHarmonizer},
                          {kShiftVariants[3], &octaverVariant, &makeOctaver}};

// Delay: the old classes unchanged, as Pitch/Shift's (both with an infinite tail and no latency).
constexpr std::string_view kDelayId = "org.caw.delay";
constexpr std::string_view kDelayName = "Delay";
constexpr std::string_view kDelayVariants[] = {"Digital", "Ping-pong", "Tape", "Reverse", "Multi-tap"};

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
const ModuleDescriptor& tapeVariant() { return tapeDelayDescriptor(kDelayVariants, 2); }
const ModuleDescriptor& reverseVariant() { return reverseDelayDescriptor(kDelayVariants, 3); }
const ModuleDescriptor& multiTapVariant() { return multiTapDelayDescriptor(kDelayVariants, 4); }
ModuleProcessor* makeTape() noexcept { return makeTapeDelayAs(tapeVariant()); }
ModuleProcessor* makeReverse() noexcept { return makeReverseDelayAs(reverseVariant()); }
ModuleProcessor* makeMultiTap() noexcept { return makeMultiTapDelayAs(multiTapVariant()); }

const Variant kDelay[] = {{kDelayVariants[0], &digitalVariant, &makeDigital},
                          {kDelayVariants[1], &pingPongVariant, &makePingPong},
                          {kDelayVariants[2], &tapeVariant, &makeTape},
                          {kDelayVariants[3], &reverseVariant, &makeReverse},
                          {kDelayVariants[4], &multiTapVariant, &makeMultiTap}};

// Reverb: the same.
constexpr std::string_view kReverbId = "org.caw.reverb";
constexpr std::string_view kReverbName = "Reverb";
constexpr std::string_view kReverbVariants[] = {"Hall", "Shimmer", "Room", "Plate", "Spring", "Gated", "Reverse"};

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
const ModuleDescriptor& roomVariant() { return roomReverbDescriptor(kReverbVariants, 2); }
const ModuleDescriptor& plateVariant() { return plateReverbDescriptor(kReverbVariants, 3); }
const ModuleDescriptor& springVariant() { return springReverbDescriptor(kReverbVariants, 4); }
const ModuleDescriptor& gatedVariant() { return gatedReverbDescriptor(kReverbVariants, 5); }
const ModuleDescriptor& reverseReverbVariant() { return reverseReverbDescriptor(kReverbVariants, 6); }
ModuleProcessor* makeRoom() noexcept { return makeRoomReverbAs(roomVariant()); }
ModuleProcessor* makePlate() noexcept { return makePlateReverbAs(plateVariant()); }
ModuleProcessor* makeSpring() noexcept { return makeSpringReverbAs(springVariant()); }
ModuleProcessor* makeGated() noexcept { return makeGatedReverbAs(gatedVariant()); }
ModuleProcessor* makeReverseReverb() noexcept { return makeReverseReverbAs(reverseReverbVariant()); }

const Variant kReverb[] = {{kReverbVariants[0], &hallVariant, &makeHall},
                           {kReverbVariants[1], &shimmerVariant, &makeShimmer},
                           {kReverbVariants[2], &roomVariant, &makeRoom},
                           {kReverbVariants[3], &plateVariant, &makePlate},
                           {kReverbVariants[4], &springVariant, &makeSpring},
                           {kReverbVariants[5], &gatedVariant, &makeGated},
                           {kReverbVariants[6], &reverseReverbVariant, &makeReverseReverb}};

// Convolver: its id reused, the convolver as it was variant 0 (an entry without `variant` plays it, no migration),
// Cab variant 1.
constexpr std::string_view kConvolverId = "org.caw.convolver";
constexpr std::string_view kConvolverName = "Convolver";
constexpr std::string_view kConvolverVariants[] = {"Convolver", "Cab"};
const ModuleDescriptor& convolverVariant() {
    static const ModuleDescriptor& d =
        legacyVariantDescriptor(convolverDescriptor(), kConvolverId, kConvolverName, kConvolverVariants, 0);
    return d;
}
const ModuleDescriptor& cabVariant() { return cabDescriptor(kConvolverVariants, 1); }
ModuleProcessor* makeConvolver() noexcept { return makeConvolverAs(convolverVariant()); }
ModuleProcessor* makeCab() noexcept { return makeCabAs(cabVariant()); }

const Variant kConvolver[] = {{kConvolverVariants[0], &convolverVariant, &makeConvolver}, {kConvolverVariants[1], &cabVariant, &makeCab}};

const MergedDevice kDevices[] = {{kDelayId, kDelayName, kDelay},
                                 {kReverbId, kReverbName, kReverb},
                                 {kShiftId, kShiftName, kShift},
                                 {kConvolverId, kConvolverName, kConvolver}};

}  // namespace

std::span<const MergedDevice> mergedSpaceDevices() { return kDevices; }

}  // namespace caw::fx
