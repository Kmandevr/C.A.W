// org.caw.drums' parameter layout (shared by its descriptor, DSP, sound library and migration): globals, then 64 pads.
#pragma once

#include <array>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "caw/module.hpp"

namespace caw::drums {

// 4 banks (A..D) of 16 pads, as a pad controller's banks. Pad index 0..63: A1 = 0, A16 = 15, B1 = 16, ..., D16 = 63.
inline constexpr uint32_t kBanks = 4, kPadsPerBank = 16, kPads = kBanks * kPadsPerBank;
inline constexpr uint32_t kOutputs = 9;  // Main and Out 2..9

// The parameters of the whole instrument, first in the descriptor (ids without a prefix).
enum GlobalParam : uint32_t {
    kMode, kChannel, kBaseNote, kVolume, kSeed, kViewPad,
    kGlue, kGlueThreshold, kGlueRatio, kGlueAttack, kGlueRelease, kGlueMakeup,
    kKitDriveType, kKitDrive, kKitDriveMix,
    kRoom, kRoomSize, kRoomDecay, kRoomDamping, kRoomPredelay,
    kKitLow, kKitHigh, kKitClip, kKitClipGain,
    kGlobalCount
};

// One pad's parameters, in this order after the globals; id "<pad>_<name>" (e.g. "a1_body_freq").
enum PadParam : uint32_t {
    // pad: triggering, pitch, routing
    kNote, kChan, kType, kLevel, kPan, kTune, kTrack, kRoot, kMono, kGlide, kTrig, kRelease, kPoly, kChoke, kOut,
    // press: polyphonic aftertouch (a hardware pad's pressure) as a modulation source, one amount per destination
    kPressDamp, kPressChoke, kPressTone, kPressPitch, kPressLevel, kPressDrive,
    // body: a tuned oscillator with a pitch envelope
    kBodyOn, kBodyWave, kBodyShape, kBodyFold, kBodyFreq, kBodyPitch, kBodyPTime, kBodyPCurve, kBodyAttack, kBodyHold,
    kBodyDecay, kBodyDCurve, kBodyP2Ratio, kBodyP2Level, kBodyPhase, kBodyLevel,
    // penv: the body's pitch envelope drawn as four breakpoints (time, pitch, curve per segment)
    kPenvMode, kPenvT1, kPenvP1, kPenvC1, kPenvT2, kPenvP2, kPenvC2, kPenvT3, kPenvP3, kPenvC3, kPenvT4, kPenvP4, kPenvC4,
    // sub: a mono sine-family layer under the body, with its own envelope
    kSubOn, kSubWave, kSubOct, kSubFine, kSubFollow, kSubAttack, kSubHold, kSubDecay, kSubDCurve, kSubDrive, kSubLp,
    kSubRoute, kSubLevel,
    // click: the transient
    kClickOn, kClickType, kClickLevel, kClickTone, kClickLength,
    // noise
    kNoiseOn, kNoiseMode, kNoiseColor, kNoiseFilter, kNoiseFreq, kNoiseRes, kNoiseSweep, kNoiseAttack, kNoiseDecay,
    kNoiseDCurve, kNoiseBursts, kNoiseSpacing, kNoiseLevel,
    // metal: square banks or FM/ring pairs
    kMetalOn, kMetalMode, kMetalSet, kMetalFreq, kMetalSpread, kMetalFm, kMetalTone, kMetalColor, kMetalBand, kMetalRes,
    kMetalAttack, kMetalDecay, kMetalDCurve, kMetalOpen, kMetalNoise, kMetalLevel,
    // resonator: modal
    kResOn, kResModel, kResFreq, kResDecay, kResDamp, kResBright, kResInharm, kResPos, kResExciter, kResInput, kResLevel,
    // sample
    kSmpOn, kSmpStart, kSmpEnd, kSmpTune, kSmpReverse, kSmpAttack, kSmpDecay, kSmpLevel,
    // drive: multi-type distortion with a high-pass before it, a low-pass after it, and a dry/wet mix
    kDriveType, kDrive, kDrivePos, kDriveLo, kDriveHi, kDriveMix,
    // filter
    kFlt, kCutoff, kFltRes, kFltEnv, kFltDecay,
    // eq: low shelf, a bell, high shelf
    kEqLow, kEqLowFreq, kEqMid, kEqFreq, kEqQ, kEqHigh, kEqHighFreq,
    // dyn: transient shaper, compressor, clipper
    kTrAttack, kTrSustain, kComp, kCompAttack, kCompRelease, kClip, kClipGain,
    // space: stereo width (the low end stays mono) and the send to the kit's room
    kWidth, kWidthHz, kRoomSend,
    // character macros
    kPunch, kTone, kSnap, kLength, kDirt, kPitch,
    // variation
    kVelLevel, kVelPitch, kVelDecay, kVelTone, kVelClick, kVelPunch, kRndPitch, kRndDecay, kRndTone, kRndPan, kRndLevel,
    kRndPos,
    kPadParams
};
static_assert(kPadParams == 162, "the pad layout is documented in docs/engine.md");
inline constexpr uint32_t kParamCount = kGlobalCount + kPads * kPadParams;

constexpr uint32_t padParam(uint32_t pad, uint32_t p) noexcept { return kGlobalCount + pad * kPadParams + p; }

// Choice values the DSP and the sound library share.
enum Mode : int { kModeKit, kModeSingle };
enum NoteChoice : int { kNoteAuto, kNoteOff, kNoteAny, kNoteFirst };  // kNoteFirst + n: MIDI note n
enum DrumType : int {
    kTypeKick, kTypeSnare, kTypeClap, kTypeClosedHat, kTypeOpenHat, kTypePedalHat, kTypeTom, kTypeCrash, kTypeRide,
    kTypeCymbal, kTypeRim, kTypeCowbell, kTypeShaker, kTypePerc, kTypeBass, kTypeFx, kTypeCount
};
enum Wave : int { kWaveSine, kWaveTriangle, kWaveSaw, kWaveSquare };
enum ClickType : int { kClickNoise, kClickImpulse, kClickBlip, kClickTick, kClickChirp, kClickPop };
enum NoiseMode : int { kNoiseNormal, kNoiseSnappy, kNoiseClap };
enum NoiseColor : int { kWhite, kPink, kBrown, kCrushed };
enum FilterKind : int { kFilterOff, kFilterLp, kFilterBp, kFilterHp };
enum MetalMode : int { kMetalSquare, kMetalFmPairs, kMetalRing };
enum MetalSet : int { kSet808, kSetBright, kSetCymbal, kSetCowbell, kSetGong, kSetBell, kSetHarmonic, kSetCount };
enum Exciter : int { kExciteLayers, kExciteMallet, kExciteNoise };
enum DriveType : int { kDriveOff, kDriveSoft, kDriveHard, kDriveFold, kDriveCrush, kDriveTube, kDriveRectify, kDriveDecimate,
                       kDriveAsym };
enum VoiceFilter : int { kVfOff, kVfLp6, kVfLp12, kVfHp, kVfBp };
enum PenvMode : int { kPenvCurve, kPenvPoints };
enum SubWave : int { kSubSine, kSubTriangle, kSubWarm };
enum SubRoute : int { kSubClean, kSubThroughFx };
enum ClipType : int { kClipOff, kClipSoft, kClipHard };
enum TrigMode : int { kOneShot, kGate };

// "a1" .. "d16" and "A1" .. "D16".
std::string padId(uint32_t pad);
std::string padName(uint32_t pad);
// The pad's note when its note is Auto: base + index (A1 plays the base note).
constexpr int autoNote(uint32_t pad, int base) noexcept { return base + static_cast<int>(pad); }

// One pad's values, indexed by PadParam.
using Voice = std::array<double, kPadParams>;
// The neutral pad: every layer off, the knobs at their middle (what a pad's descriptor default is in banks B..D).
const Voice& neutralVoice();
// The pad parameter's suffix ("body_freq") and its descriptor (range, default of a neutral pad).
std::string_view padParamSuffix(uint32_t p);
const ParameterDescriptor& padParamDescriptor(uint32_t pad, uint32_t p);
// The descriptor's parameter table (globals then pads; built once).
const ParameterDescriptor* parameterTable();
// A pad parameter's index from its suffix, or -1.
int padParamIndex(std::string_view suffix);
// The descriptor index of `id` (a global or "<pad>_<suffix>"), or -1.
int parameterIndex(std::string_view id);
double constrainPad(uint32_t p, double v);

// The sound library: a named voice and its drum type.
struct Sound {
    std::string_view name;
    std::string_view description;
    DrumType type;
    Voice voice;
};
const std::vector<Sound>& sounds();
const Sound* findSound(std::string_view name);
// A kit: up to 64 pads (index: the sound, empty for an unused pad), plus kit-wide values.
struct Kit {
    std::string_view name;
    std::string_view description;
    std::vector<std::pair<uint32_t, std::string_view>> pads;  // pad index, sound name
    std::vector<std::pair<uint32_t, double>> globals;
};
const std::vector<Kit>& kits();
// The default kit (bank A's descriptor defaults): "808".
const Kit& defaultKit();
// The value each pad parameter defaults to in the descriptor (bank A: the default kit's sounds; B..D neutral).
const Voice& defaultVoice(uint32_t pad);
// Renders `voice` as pad A1 in Single mode: one hit at full velocity, mono, until silent or `seconds` (sample layer
// off). Control thread (allocates).
bool renderVoice(const Voice& voice, double sampleRate, double seconds, std::vector<float>& out);
// The names of the drum types (choices of the `type` parameter).
std::string_view typeName(int type);

}  // namespace caw::drums
