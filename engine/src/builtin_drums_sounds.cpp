// org.caw.drums' sound library, kits, presets, randomize/mutate, explode-to-tracks and the old drums' migration.
#include "builtin_drums.h"
#include "builtin_drums_layout.h"
#include "presets.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <deque>
#include <initializer_list>

#include "caw/detmath.hpp"
#include "json.h"

namespace caw {

namespace drums {

namespace {

using P = std::pair<uint32_t, double>;

double db(double gain) { return gain > 1e-3 ? 20.0 * std::log10(gain) : -60.0; }

Voice voice(DrumType type, std::initializer_list<P> values) {
    Voice v = neutralVoice();
    v[kType] = type;
    for (const P& p : values) v[p.first] = p.second;
    return v;
}

// Each sound is a starting point: its layers, then the effects. Reference values (pitch, decay, brightness) and
// where they come from are in docs/engine.md ("Drums", Sound library); the presets test checks them.
std::vector<Sound> makeSounds() {
    std::vector<Sound> s;
    auto add = [&](std::string_view name, std::string_view description, DrumType type, std::initializer_list<P> values) {
        s.push_back({name, description, type, voice(type, values)});
    };
    // ---- Kicks ----
    add("808 Kick", "A long, round 808 boom: a sine with a small pitch drop and a soft click", kTypeKick,
        {{kPoly, 1}, {kChoke, 0}, {kBodyOn, 1}, {kBodyFreq, 47}, {kBodyPitch, 12}, {kBodyPTime, 0.05}, {kBodyDecay, 1.4},
         {kBodyDCurve, -0.1}, {kClickOn, 1}, {kClickType, kClickImpulse}, {kClickLevel, 0.25}, {kClickTone, 1500},
         {kClickLength, 0.004}, {kDriveType, kDriveSoft}, {kDrive, 1.4}, {kFlt, kVfLp6}, {kCutoff, 5000}});
    add("909 Kick", "The 909's punch: a shaped triangle swept fast from high, with a noise click", kTypeKick,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyWave, kWaveTriangle}, {kBodyShape, 0.35}, {kBodyFreq, 54}, {kBodyPitch, 30},
         {kBodyPTime, 0.035}, {kBodyPCurve, 0.3}, {kBodyDecay, 0.45}, {kClickOn, 1}, {kClickType, kClickNoise},
         {kClickLevel, 0.55}, {kClickTone, 3000}, {kClickLength, 0.006}, {kDriveType, kDriveSoft}, {kDrive, 1.8}});
    add("Punchy Kick", "An acoustic kick: a short head with a beater pop and the shell's thud", kTypeKick,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyFreq, 60}, {kBodyPitch, 14}, {kBodyPTime, 0.02}, {kBodyDecay, 0.3},
         {kBodyDCurve, 0.4}, {kClickOn, 1}, {kClickType, kClickPop}, {kClickLevel, 0.6}, {kClickTone, 3500},
         {kClickLength, 0.01}, {kResOn, 1}, {kResModel, 0}, {kResFreq, 68}, {kResDecay, 0.25}, {kResDamp, 0.7},
         {kResBright, 0.3}, {kResExciter, kExciteLayers}, {kResInput, 0.3}, {kResLevel, -10}, {kEqMid, -4}, {kEqFreq, 400},
         {kTrAttack, 0.4}, {kComp, 0.3}});
    add("Techno Kick", "A driven kick with a long rumble-ready body", kTypeKick,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyFreq, 48}, {kBodyPitch, 30}, {kBodyPTime, 0.04}, {kBodyDecay, 0.7},
         {kBodyDCurve, -0.2}, {kClickOn, 1}, {kClickLevel, 0.4}, {kClickTone, 4000}, {kDriveType, kDriveSoft},
         {kDrive, 4}, {kFlt, kVfLp12}, {kCutoff, 3000}});
    add("Hardstyle Kick", "Clipped and folded, with a long tonal tail", kTypeKick,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyFreq, 55}, {kBodyPitch, 40}, {kBodyPTime, 0.06}, {kBodyPCurve, 0.5},
         {kBodyDecay, 0.6}, {kBodyShape, 0.8}, {kBodyFold, 0.2}, {kClickOn, 1}, {kClickType, kClickChirp},
         {kClickTone, 800}, {kClickLevel, 0.8}, {kClickLength, 0.02}, {kDriveType, kDriveHard}, {kDrive, 6},
         {kDrivePos, 1}, {kFlt, kVfLp12}, {kCutoff, 7000}, {kFltRes, 0.2}, {kEqMid, 6}, {kEqFreq, 1200}, {kComp, 0.4}});
    add("Distorted Kick", "A tube-driven kick, dark and thick", kTypeKick,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyFreq, 52}, {kBodyPitch, 28}, {kBodyPTime, 0.035}, {kBodyDecay, 0.5},
         {kClickOn, 1}, {kClickLevel, 0.5}, {kDriveType, kDriveTube}, {kDrive, 8}, {kFlt, kVfLp12}, {kCutoff, 5000}});
    add("Sub Kick", "Almost all sub: a sine with a tiny drop, no click", kTypeKick,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyFreq, 42}, {kBodyPitch, 5}, {kBodyPTime, 0.02}, {kBodyDecay, 1.2},
         {kFlt, kVfLp6}, {kCutoff, 1200}});
    add("Trap Kick", "A long, saturated 808-style kick", kTypeKick,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyFreq, 45}, {kBodyPitch, 18}, {kBodyPTime, 0.04}, {kBodyDecay, 1.8},
         {kBodyDCurve, -0.3}, {kClickOn, 1}, {kClickType, kClickImpulse}, {kClickLevel, 0.4}, {kClickTone, 2500},
         {kDriveType, kDriveSoft}, {kDrive, 2.5}});
    add("808 Bass", "A tuned 808 for basslines: pitch tracking, mono, slides between overlapping notes", kTypeBass,
        {{kPoly, 1}, {kTrack, 1}, {kRoot, 36}, {kMono, 1}, {kGlide, 0.06}, {kBodyOn, 1}, {kBodyFreq, 65.41},
         {kBodyPitch, 5}, {kBodyPTime, 0.03}, {kBodyDecay, 2.5}, {kBodyDCurve, -0.3}, {kDriveType, kDriveSoft},
         {kDrive, 2.5}, {kFlt, kVfLp6}, {kCutoff, 6000}});
    add("808 Kick Long", "The 808 boom with its decay up: a held sine that rings for seconds (trap, drill)", kTypeKick,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyFreq, 48}, {kBodyPitch, 12}, {kBodyPTime, 0.06}, {kBodyHold, 0.05},
         {kBodyDecay, 3.0}, {kBodyDCurve, -0.25}, {kClickOn, 1}, {kClickType, kClickImpulse}, {kClickLevel, 0.25},
         {kClickTone, 1500}, {kClickLength, 0.004}, {kDriveType, kDriveSoft}, {kDrive, 1.6}, {kFlt, kVfLp6},
         {kCutoff, 4000}, {kVelPunch, 0.3}});
    add("808 Kick Short", "The 808 kick with its decay down: a tight thump (electro, house)", kTypeKick,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyFreq, 52}, {kBodyPitch, 14}, {kBodyPTime, 0.045}, {kBodyDecay, 0.32},
         {kBodyDCurve, 0.2}, {kClickOn, 1}, {kClickType, kClickImpulse}, {kClickLevel, 0.3}, {kClickTone, 1800},
         {kClickLength, 0.004}, {kDriveType, kDriveSoft}, {kDrive, 1.4}, {kFlt, kVfLp6}, {kCutoff, 5000},
         {kVelPunch, 0.3}});
    add("Dubstep Kick", "Punch over a clean sub: a drawn pitch drop, a driven and clipped mid, a short click", kTypeKick,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyFreq, 55}, {kBodyDecay, 0.26}, {kBodyDCurve, 0.35}, {kPenvMode, kPenvPoints},
         {kBodyPitch, 38}, {kPenvT1, 0.006}, {kPenvP1, 14}, {kPenvC1, 0.6}, {kPenvT2, 0.025}, {kPenvP2, 3},
         {kPenvC2, 0.5}, {kPenvT3, 0.06}, {kPenvP3, 0}, {kPenvC3, 0.4}, {kPenvT4, 0.1}, {kPenvP4, 0}, {kPenvC4, 0},
         {kSubOn, 1}, {kSubOct, 0}, {kSubAttack, 0.004}, {kSubDecay, 0.42}, {kSubDCurve, -0.2}, {kSubLevel, -3},
         {kSubRoute, kSubClean}, {kClickOn, 1}, {kClickType, kClickNoise}, {kClickTone, 5000}, {kClickLevel, 0.45},
         {kClickLength, 0.003}, {kDriveType, kDriveAsym}, {kDrive, 7}, {kDriveLo, 90}, {kDriveHi, 9000},
         {kDriveMix, 0.75}, {kEqMid, 4}, {kEqFreq, 2500}, {kEqQ, 0.8}, {kTrAttack, 0.3}, {kComp, 0.35},
         {kClip, kClipHard}, {kClipGain, 9}, {kVelPunch, 0.2}});
    add("House Kick", "A round four-on-the-floor kick: a 909-style body, a soft click, a little glue", kTypeKick,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyWave, kWaveTriangle}, {kBodyShape, 0.25}, {kBodyFreq, 52}, {kBodyPitch, 24},
         {kBodyPTime, 0.04}, {kBodyPCurve, 0.25}, {kBodyDecay, 0.4}, {kClickOn, 1}, {kClickType, kClickNoise},
         {kClickLevel, 0.35}, {kClickTone, 2500}, {kClickLength, 0.005}, {kDriveType, kDriveSoft}, {kDrive, 1.6},
         {kComp, 0.25}, {kEqLow, 2}, {kEqLowFreq, 70}});
    add("Acoustic Kick", "A miked bass drum: a felt beater's pop, the batter head's short drop, the shell's membrane "
        "modes, the boxiness cut, and a little room", kTypeKick,
        {{kPoly, 2}, {kBodyOn, 1}, {kBodyFreq, 60}, {kBodyPitch, 6}, {kBodyPTime, 0.015}, {kBodyDecay, 0.22},
         {kBodyDCurve, 0.3}, {kBodyLevel, -3}, {kResOn, 1}, {kResModel, 0}, {kResFreq, 62}, {kResDecay, 0.32},
         {kResDamp, 0.65}, {kResBright, 0.35}, {kResPos, 0.15}, {kResExciter, kExciteMallet}, {kResInput, 0.15},
         {kResLevel, 2}, {kClickOn, 1}, {kClickType, kClickPop}, {kClickTone, 3500}, {kClickLevel, 0.5},
         {kClickLength, 0.003}, {kEqMid, -5}, {kEqFreq, 400}, {kEqQ, 1.2}, {kEqHigh, 3}, {kEqHighFreq, 4000},
         {kTrAttack, 0.2}, {kComp, 0.2}, {kRoomSend, 0.5}, {kVelTone, 0.6}, {kVelPunch, 0.5}, {kVelDecay, 0.2},
         {kRndPitch, 8}, {kRndTone, 0.1}, {kRndDecay, 0.1}, {kRndPos, 0.3}});
    // ---- Snares ----
    add("808 Snare", "Two tuned partials and bright noise", kTypeSnare,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyWave, kWaveTriangle}, {kBodyFreq, 180}, {kBodyPitch, 3}, {kBodyPTime, 0.02},
         {kBodyDecay, 0.12}, {kBodyP2Ratio, 1.48}, {kBodyP2Level, 0.67}, {kBodyLevel, -4}, {kNoiseOn, 1},
         {kNoiseFreq, 1800}, {kNoiseDecay, 0.18}, {kNoiseLevel, -2}, {kFlt, kVfLp12}, {kCutoff, 7000}});
    add("909 Snare", "A tighter body and snappy, buzzing noise", kTypeSnare,
        {{kPoly, 1}, {kBodyOn, 1}, {kBodyFreq, 200}, {kBodyPitch, 7}, {kBodyPTime, 0.015}, {kBodyDecay, 0.1},
         {kBodyP2Ratio, 1.6}, {kBodyP2Level, 0.5}, {kBodyLevel, -3}, {kNoiseOn, 1}, {kNoiseMode, kNoiseSnappy},
         {kNoiseFreq, 2500}, {kNoiseDecay, 0.25}, {kNoiseLevel, 1}, {kClickOn, 1}, {kClickLevel, 0.4},
         {kClickTone, 5000}, {kClickLength, 0.004}, {kDriveType, kDriveSoft}, {kDrive, 1.5}, {kFlt, kVfLp12},
         {kCutoff, 9000}});
    add("Tight Snare", "An acoustic snare, tuned up: a ringing head and crisp wires", kTypeSnare,
        {{kPoly, 2}, {kBodyOn, 1}, {kBodyFreq, 220}, {kBodyPitch, 4}, {kBodyPTime, 0.01}, {kBodyDecay, 0.09},
         {kBodyLevel, -4}, {kResOn, 1}, {kResFreq, 230}, {kResDecay, 0.18}, {kResDamp, 0.6}, {kResBright, 0.6},
         {kResExciter, kExciteLayers}, {kResInput, 0.3}, {kResLevel, -6}, {kNoiseOn, 1}, {kNoiseMode, kNoiseSnappy},
         {kNoiseFreq, 1500}, {kNoiseRes, 0.1}, {kNoiseDecay, 0.16}, {kClickOn, 1}, {kClickType, kClickPop},
         {kClickTone, 3000}, {kClickLevel, 0.5}, {kTrAttack, 0.3}, {kEqHigh, 3}, {kFlt, kVfLp12}, {kCutoff, 8000}});
    add("Fat Snare", "A deep acoustic snare with a long, dark wire tail", kTypeSnare,
        {{kPoly, 2}, {kBodyOn, 1}, {kBodyFreq, 170}, {kBodyPitch, 5}, {kBodyDecay, 0.16}, {kBodyLevel, -3},
         {kResOn, 1}, {kResFreq, 175}, {kResDecay, 0.35}, {kResDamp, 0.5}, {kResExciter, kExciteLayers},
         {kResInput, 0.3}, {kResLevel, -4}, {kNoiseOn, 1}, {kNoiseMode, kNoiseSnappy}, {kNoiseColor, kPink},
         {kNoiseFreq, 900}, {kNoiseDecay, 0.32}, {kComp, 0.4}, {kEqLow, 3}});
    add("Rim Snare", "A snare hit on the rim: a hard crack over a short body", kTypeSnare,
        {{kPoly, 2}, {kBodyOn, 1}, {kBodyFreq, 260}, {kBodyDecay, 0.06}, {kBodyLevel, -4}, {kClickOn, 1},
         {kClickType, kClickTick}, {kClickTone, 1800}, {kClickLevel, 0.7}, {kClickLength, 0.003}, {kResOn, 1},
         {kResModel, 2}, {kResFreq, 900}, {kResDecay, 0.07}, {kResLevel, -6}, {kNoiseOn, 1}, {kNoiseFreq, 3000},
         {kNoiseDecay, 0.12}, {kNoiseLevel, -6}});
    add("Clap Snare", "A clap's bursts over a snare body", kTypeSnare,
        {{kPoly, 2}, {kBodyOn, 1}, {kBodyWave, kWaveTriangle}, {kBodyFreq, 200}, {kBodyDecay, 0.1},
         {kBodyP2Ratio, 1.48}, {kBodyP2Level, 0.6}, {kBodyLevel, -5}, {kNoiseOn, 1}, {kNoiseMode, kNoiseClap},
         {kNoiseFilter, kFilterBp}, {kNoiseFreq, 1500}, {kNoiseRes, 0.23}, {kNoiseAttack, 0.004}, {kNoiseDecay, 0.22}});
    add("Acoustic Snare", "A played snare: the batter head's membrane modes struck off centre, the wires buzzing with "
        "the head, a stick's tick; harder hits are brighter and ring longer", kTypeSnare,
        {{kPoly, 3}, {kResOn, 1}, {kResModel, 0}, {kResFreq, 190}, {kResDecay, 0.25}, {kResDamp, 0.55},
         {kResBright, 0.6}, {kResPos, 0.35}, {kResExciter, kExciteMallet}, {kResInput, 0.1}, {kResLevel, -4},
         {kBodyOn, 1}, {kBodyFreq, 190}, {kBodyPitch, 3}, {kBodyPTime, 0.008}, {kBodyDecay, 0.08}, {kBodyLevel, -6},
         {kNoiseOn, 1}, {kNoiseMode, kNoiseSnappy}, {kNoiseColor, kPink}, {kNoiseFilter, kFilterHp},
         {kNoiseFreq, 1800}, {kNoiseDecay, 0.24}, {kNoiseDCurve, 0.2}, {kNoiseLevel, 2}, {kClickOn, 1},
         {kClickType, kClickPop}, {kClickTone, 4000}, {kClickLevel, 0.35}, {kClickLength, 0.002}, {kEqMid, 2},
         {kEqFreq, 200}, {kTrAttack, 0.2}, {kRoomSend, 0.6}, {kVelTone, 0.7}, {kVelDecay, 0.3}, {kRndPitch, 6},
         {kRndTone, 0.1}, {kRndDecay, 0.1}, {kRndPos, 0.3}});
    add("Trap Snare", "A tight, bright snare-clap: a short tuned body and a clap's bursts, high-passed", kTypeSnare,
        {{kPoly, 2}, {kBodyOn, 1}, {kBodyFreq, 230}, {kBodyPitch, 5}, {kBodyPTime, 0.01}, {kBodyDecay, 0.07},
         {kBodyLevel, -6}, {kNoiseOn, 1}, {kNoiseMode, kNoiseClap}, {kNoiseFilter, kFilterBp}, {kNoiseFreq, 2200},
         {kNoiseRes, 0.2}, {kNoiseBursts, 3}, {kNoiseSpacing, 0.007}, {kNoiseDecay, 0.16}, {kNoiseLevel, 2},
         {kFlt, kVfHp}, {kCutoff, 180}, {kEqHigh, 4}, {kClip, kClipSoft}, {kClipGain, 3}});
    add("Dubstep Snare", "A huge layered snare: a fat body, snappy wires, a clap on top, clipped, in the room",
        kTypeSnare,
        {{kPoly, 2}, {kBodyOn, 1}, {kBodyWave, kWaveTriangle}, {kBodyFreq, 185}, {kBodyPitch, 9}, {kBodyPTime, 0.015},
         {kBodyDecay, 0.16}, {kBodyP2Ratio, 1.5}, {kBodyP2Level, 0.5}, {kBodyLevel, -2}, {kNoiseOn, 1},
         {kNoiseMode, kNoiseSnappy}, {kNoiseColor, kPink}, {kNoiseFreq, 1200}, {kNoiseDecay, 0.3}, {kNoiseLevel, 0},
         {kClickOn, 1}, {kClickType, kClickNoise}, {kClickTone, 3500}, {kClickLevel, 0.4}, {kClickLength, 0.006},
         {kFlt, kVfLp12}, {kCutoff, 8000},
         {kDriveType, kDriveSoft}, {kDrive, 3}, {kEqLow, 3}, {kEqLowFreq, 200}, {kTrAttack, 0.4}, {kComp, 0.4},
         {kClip, kClipHard}, {kClipGain, 5}, {kWidth, 0.4}, {kRoomSend, 0.8}});
    // ---- Hats ----
    add("808 Closed Hat", "Six detuned squares through a band and a high-pass, short", kTypeClosedHat,
        {{kPoly, 1}, {kChoke, 1}, {kMetalOn, 1}, {kMetalNoise, 0.25}, {kMetalTone, 7000}, {kMetalColor, 10000},
         {kMetalBand, 0.6}, {kMetalAttack, 0.0003}, {kMetalDecay, 0.045}});
    add("808 Open Hat", "The 808 bank left ringing", kTypeOpenHat,
        {{kPoly, 1}, {kChoke, 1}, {kMetalOn, 1}, {kMetalNoise, 0.25}, {kMetalTone, 7000}, {kMetalColor, 10000},
         {kMetalBand, 0.6}, {kMetalAttack, 0.0003}, {kMetalDecay, 0.045}, {kMetalOpen, 0.6}});
    add("909 Closed Hat", "A brighter metal bank, crushed toward the 909's 6-bit samples", kTypeClosedHat,
        {{kPoly, 1}, {kChoke, 1}, {kMetalOn, 1}, {kMetalSet, kSetBright}, {kMetalFreq, 470}, {kMetalNoise, 0.55},
         {kMetalTone, 8500}, {kMetalColor, 11000}, {kMetalBand, 0.3}, {kMetalDecay, 0.04}, {kDriveType, kDriveCrush},
         {kDrive, 6}});
    add("909 Open Hat", "The 909 hat, open", kTypeOpenHat,
        {{kPoly, 1}, {kChoke, 1}, {kMetalOn, 1}, {kMetalSet, kSetBright}, {kMetalFreq, 470}, {kMetalNoise, 0.55},
         {kMetalTone, 8500}, {kMetalColor, 11000}, {kMetalBand, 0.3}, {kMetalDecay, 0.04}, {kMetalOpen, 0.65},
         {kDriveType, kDriveCrush}, {kDrive, 6}});
    add("Acoustic Hat", "FM-paired metal and air, with a stick tick", kTypeClosedHat,
        {{kPoly, 1}, {kChoke, 1}, {kMetalOn, 1}, {kMetalMode, kMetalFmPairs}, {kMetalSet, kSetCymbal}, {kMetalFreq, 520},
         {kMetalFm, 3}, {kMetalNoise, 0.6}, {kMetalTone, 6000}, {kMetalColor, 9000}, {kMetalBand, 0.4},
         {kMetalDecay, 0.06}, {kMetalDCurve, 0.3}, {kClickOn, 1}, {kClickTone, 8000}, {kClickLevel, 0.3},
         {kClickLength, 0.002}, {kRndTone, 0.15}, {kRndDecay, 0.15}});
    add("Trashy Hat", "Ring-modulated and clipped", kTypeClosedHat,
        {{kPoly, 1}, {kChoke, 1}, {kMetalOn, 1}, {kMetalMode, kMetalRing}, {kMetalSet, kSetBright}, {kMetalFreq, 600},
         {kMetalNoise, 0.4}, {kMetalTone, 4000}, {kMetalDecay, 0.09}, {kDriveType, kDriveHard}, {kDrive, 5},
         {kEqMid, 6}, {kEqFreq, 3000}});
    add("Pedal Hat", "The hats closing under the foot: a soft chick", kTypePedalHat,
        {{kPoly, 1}, {kChoke, 1}, {kMetalOn, 1}, {kMetalFreq, 410}, {kMetalNoise, 0.3}, {kMetalTone, 6000},
         {kMetalAttack, 0.002}, {kMetalDecay, 0.03}, {kMetalDCurve, -0.4}, {kClickOn, 1}, {kClickTone, 3000},
         {kClickLevel, 0.5}, {kClickLength, 0.01}});
    // ---- Toms ----
    add("Low Tom", "A floor tom: a swept sine and a ringing membrane", kTypeTom,
        {{kBodyOn, 1}, {kBodyFreq, 85}, {kBodyPitch, 7}, {kBodyPTime, 0.06}, {kBodyDecay, 0.5}, {kResOn, 1},
         {kResFreq, 85}, {kResDecay, 0.4}, {kResDamp, 0.5}, {kResExciter, kExciteLayers}, {kResLevel, -8},
         {kClickOn, 1}, {kClickType, kClickPop}, {kClickTone, 2500}, {kClickLevel, 0.3}});
    add("Mid Tom", "A rack tom", kTypeTom,
        {{kBodyOn, 1}, {kBodyFreq, 120}, {kBodyPitch, 7}, {kBodyPTime, 0.05}, {kBodyDecay, 0.4}, {kResOn, 1},
         {kResFreq, 120}, {kResDecay, 0.35}, {kResDamp, 0.5}, {kResExciter, kExciteLayers}, {kResLevel, -8},
         {kClickOn, 1}, {kClickType, kClickPop}, {kClickTone, 2800}, {kClickLevel, 0.3}});
    add("High Tom", "A small rack tom", kTypeTom,
        {{kBodyOn, 1}, {kBodyFreq, 165}, {kBodyPitch, 7}, {kBodyPTime, 0.04}, {kBodyDecay, 0.32}, {kResOn, 1},
         {kResFreq, 165}, {kResDecay, 0.3}, {kResDamp, 0.5}, {kResExciter, kExciteLayers}, {kResLevel, -8},
         {kClickOn, 1}, {kClickType, kClickPop}, {kClickTone, 3200}, {kClickLevel, 0.3}});
    add("808 Tom", "The 808's slow-falling sine tom with a touch of noise", kTypeTom,
        {{kBodyOn, 1}, {kBodyFreq, 110}, {kBodyPitch, 5}, {kBodyPTime, 0.1}, {kBodyPCurve, -0.3}, {kBodyDecay, 0.45},
         {kNoiseOn, 1}, {kNoiseFilter, kFilterLp}, {kNoiseFreq, 2000}, {kNoiseDecay, 0.02}, {kNoiseLevel, -14}});
    add("Acoustic Tom", "A struck membrane, mallet-excited", kTypeTom,
        {{kResOn, 1}, {kResFreq, 105}, {kResDecay, 0.55}, {kResDamp, 0.45}, {kResBright, 0.45}, {kResPos, 0.25},
         {kResExciter, kExciteMallet}, {kResLevel, 6}, {kBodyOn, 1}, {kBodyFreq, 105}, {kBodyPitch, 3},
         {kBodyDecay, 0.3}, {kBodyLevel, -6}});
    // ---- Cymbals ----
    add("Crash", "A wash of FM metal and noise over a ringing cymbal", kTypeCrash,
        {{kPoly, 3}, {kMetalOn, 1}, {kMetalMode, kMetalFmPairs}, {kMetalSet, kSetCymbal}, {kMetalFreq, 380},
         {kMetalFm, 4.5}, {kMetalNoise, 0.55}, {kMetalTone, 3500}, {kMetalColor, 7000}, {kMetalBand, 0.3},
         {kMetalAttack, 0.001}, {kMetalDecay, 1.6}, {kResOn, 1}, {kResModel, 5}, {kResFreq, 420}, {kResDecay, 1.8},
         {kResExciter, kExciteNoise}, {kResLevel, -10}, {kNoiseOn, 1}, {kNoiseFreq, 5000}, {kNoiseDecay, 1.4},
         {kNoiseLevel, -10}, {kPressDamp, 1}});
    add("Ride", "A ride's ping and its long shimmer", kTypeRide,
        {{kPoly, 3}, {kMetalOn, 1}, {kMetalSet, kSetCymbal}, {kMetalFreq, 470}, {kMetalNoise, 0.3}, {kMetalTone, 4000},
         {kMetalDecay, 2.2}, {kMetalDCurve, 0.3}, {kResOn, 1}, {kResModel, 5}, {kResFreq, 520}, {kResDecay, 2.5},
         {kResDamp, 0.2}, {kResLevel, -8}, {kClickOn, 1}, {kClickType, kClickTick}, {kClickTone, 4000},
         {kClickLevel, 0.3}, {kPressDamp, 1}});
    add("Ride Bell", "The bell of the ride", kTypeRide,
        {{kPoly, 3}, {kMetalOn, 1}, {kMetalMode, kMetalFmPairs}, {kMetalSet, kSetBell}, {kMetalFm, 1.5},
         {kMetalFreq, 650}, {kMetalNoise, 0.05}, {kMetalTone, 1500}, {kMetalDecay, 1.6}, {kResOn, 1}, {kResModel, 4},
         {kResFreq, 700}, {kResDecay, 1.4}, {kResLevel, -6}});
    add("China", "A trashy china: ring-modulated gong metal, clipped", kTypeCymbal,
        {{kPoly, 3}, {kMetalOn, 1}, {kMetalMode, kMetalRing}, {kMetalSet, kSetGong}, {kMetalFreq, 330},
         {kMetalNoise, 0.5}, {kMetalTone, 2500}, {kMetalColor, 4500}, {kMetalBand, 0.5}, {kMetalRes, 0.3},
         {kMetalDecay, 1.3}, {kDriveType, kDriveHard}, {kDrive, 3}, {kPressDamp, 1}});
    add("Splash", "A small, quick cymbal", kTypeCymbal,
        {{kPoly, 3}, {kMetalOn, 1}, {kMetalMode, kMetalFmPairs}, {kMetalSet, kSetCymbal}, {kMetalFreq, 520},
         {kMetalFm, 3.5}, {kMetalNoise, 0.6}, {kMetalTone, 5000}, {kMetalDecay, 0.6}, {kNoiseOn, 1}, {kNoiseFreq, 6000},
         {kNoiseDecay, 0.5}, {kNoiseLevel, -8}, {kPressDamp, 1}});
    // ---- Percussion ----
    add("Rim", "A rimshot: a tick and a short, hard bar", kTypeRim,
        {{kPoly, 2}, {kClickOn, 1}, {kClickType, kClickTick}, {kClickTone, 1700}, {kClickLevel, 0.8},
         {kClickLength, 0.002}, {kBodyOn, 1}, {kBodyFreq, 455}, {kBodyPitch, 0}, {kBodyDecay, 0.02}, {kBodyLevel, -6},
         {kResOn, 1}, {kResModel, 2}, {kResFreq, 1700}, {kResDecay, 0.03}, {kFlt, kVfHp}, {kCutoff, 300}});
    add("Clap", "Four quick bursts of band-passed noise and a tail", kTypeClap,
        {{kPoly, 2}, {kNoiseOn, 1}, {kNoiseMode, kNoiseClap}, {kNoiseFilter, kFilterBp}, {kNoiseFreq, 1200},
         {kNoiseRes, 0.23}, {kNoiseBursts, 4}, {kNoiseSpacing, 0.009}, {kNoiseAttack, 0.004}, {kNoiseDecay, 0.18},
         {kNoiseLevel, 3}, {kRndTone, 0.1}, {kRndDecay, 0.1}});
    add("Snap", "A finger snap", kTypeClap,
        {{kPoly, 2}, {kNoiseOn, 1}, {kNoiseFilter, kFilterBp}, {kNoiseFreq, 2200}, {kNoiseRes, 0.3},
         {kNoiseDecay, 0.06}, {kNoiseLevel, 3}, {kClickOn, 1}, {kClickTone, 4000}, {kClickLevel, 0.6}});
    add("Cowbell", "Two squares a fifth-and-a-bit apart (540 and 800 Hz) through a band", kTypeCowbell,
        {{kPoly, 2}, {kMetalOn, 1}, {kMetalSet, kSetCowbell}, {kMetalFreq, 540}, {kMetalNoise, 0}, {kMetalTone, 400},
         {kMetalColor, 2600}, {kMetalBand, 0.7}, {kMetalRes, 0.3}, {kMetalDecay, 0.3}, {kMetalDCurve, 0.4}});
    add("Shaker", "A swish of high, band-passed noise", kTypeShaker,
        {{kPoly, 2}, {kNoiseOn, 1}, {kNoiseFilter, kFilterBp}, {kNoiseFreq, 6000}, {kNoiseRes, 0.2},
         {kNoiseAttack, 0.02}, {kNoiseDecay, 0.08}, {kNoiseDCurve, -0.3}, {kNoiseLevel, 2}, {kRndTone, 0.2},
         {kRndDecay, 0.2}, {kRndLevel, 0.2}});
    add("Tambourine", "Jingles: bright FM metal and noise", kTypeShaker,
        {{kPoly, 2}, {kMetalOn, 1}, {kMetalMode, kMetalFmPairs}, {kMetalSet, kSetBright}, {kMetalFreq, 1100},
         {kMetalFm, 6}, {kMetalNoise, 0.5}, {kMetalTone, 6000}, {kMetalAttack, 0.002}, {kMetalDecay, 0.2},
         {kNoiseOn, 1}, {kNoiseFreq, 7000}, {kNoiseDecay, 0.15}, {kNoiseLevel, -6}});
    add("Conga", "A hand drum: a bright membrane struck near the edge", kTypePerc,
        {{kPoly, 2}, {kResOn, 1}, {kResFreq, 210}, {kResDecay, 0.35}, {kResDamp, 0.55}, {kResBright, 0.55},
         {kResPos, 0.2}, {kResLevel, 6}, {kBodyOn, 1}, {kBodyFreq, 210}, {kBodyPitch, 4}, {kBodyPTime, 0.02},
         {kBodyDecay, 0.18}, {kBodyLevel, -6}});
    add("Bongo", "A small, high hand drum", kTypePerc,
        {{kPoly, 2}, {kResOn, 1}, {kResFreq, 400}, {kResDecay, 0.2}, {kResDamp, 0.6}, {kResBright, 0.6},
         {kResLevel, 6}, {kBodyOn, 1}, {kBodyFreq, 400}, {kBodyPitch, 5}, {kBodyDecay, 0.1}, {kBodyLevel, -8}});
    add("Woodblock", "A hollow block: a short bar", kTypePerc,
        {{kPoly, 2}, {kResOn, 1}, {kResModel, 2}, {kResFreq, 1100}, {kResDecay, 0.08}, {kResDamp, 0.5},
         {kResBright, 0.7}, {kResLevel, 6}, {kClickOn, 1}, {kClickType, kClickPop}, {kClickTone, 2500},
         {kClickLevel, 0.4}});
    add("Clave", "Two hardwood sticks: a high, pure bar", kTypePerc,
        {{kPoly, 2}, {kResOn, 1}, {kResModel, 2}, {kResFreq, 2500}, {kResDecay, 0.06}, {kResDamp, 0.3},
         {kResLevel, 6}});
    add("Triangle", "A struck steel bar, ringing long", kTypePerc,
        {{kPoly, 2}, {kResOn, 1}, {kResModel, 2}, {kResFreq, 1600}, {kResDecay, 2.0}, {kResDamp, 0.1},
         {kResBright, 0.8}, {kResPos, 0.9}, {kResLevel, 3}, {kClickOn, 1}, {kClickType, kClickTick},
         {kClickTone, 6000}, {kClickLevel, 0.15}, {kPressDamp, 1}});
    add("Zap", "A fast, wide pitch dive", kTypeFx,
        {{kBodyOn, 1}, {kBodyFreq, 100}, {kBodyPitch, 60}, {kBodyPTime, 0.12}, {kBodyPCurve, 0.6}, {kBodyDecay, 0.25}});
    add("Laser", "A resonant saw dive", kTypeFx,
        {{kBodyOn, 1}, {kBodyWave, kWaveSaw}, {kBodyFreq, 200}, {kBodyPitch, 48}, {kBodyPTime, 0.3}, {kBodyDecay, 0.4},
         {kFlt, kVfLp12}, {kCutoff, 3000}, {kFltRes, 0.6}, {kFltEnv, 2}});
    add("Noise Riser", "Noise swept up through a resonant band", kTypeFx,
        {{kNoiseOn, 1}, {kNoiseFilter, kFilterBp}, {kNoiseFreq, 300}, {kNoiseRes, 0.6}, {kNoiseSweep, 5},
         {kNoiseAttack, 0.4}, {kNoiseDecay, 1.0}, {kNoiseLevel, 4}});
    // Level trims (dB on the pad's level), measured on these renders so a full-velocity hit peaks near -1 dBFS (hats,
    // shakers and cymbals lower, as they sit in a mix): the presets test checks the result.
    const std::pair<std::string_view, double> trims[] = {
        {"808 Kick", -1.0},
        {"808 Kick Long", -1.0},
        {"808 Kick Short", -0.8},
        {"Dubstep Kick", -1.4},
        {"House Kick", -4.6},
        {"Acoustic Kick", -7.0},
        {"Acoustic Snare", -9.4},
        {"Trap Snare", 0.0},
        {"Dubstep Snare", -4.6},
        {"909 Kick", -1.7},
        {"Punchy Kick", -10.0},
        {"Techno Kick", -1.0},
        {"Hardstyle Kick", -8.7},
        {"Distorted Kick", -1.0},
        {"Sub Kick", -0.8},
        {"Trap Kick", -1.0},
        {"808 Bass", -1.0},
        {"808 Snare", -2.2},
        {"909 Snare", -1.7},
        {"Tight Snare", -7.9},
        {"Fat Snare", -4.3},
        {"Rim Snare", -0.9},
        {"Clap Snare", 1.8},
        {"808 Closed Hat", 6.0},
        {"808 Open Hat", 5.0},
        {"909 Closed Hat", 2.0},
        {"909 Open Hat", -0.5},
        {"Acoustic Hat", -0.6},
        {"Trashy Hat", -11.1},
        {"Pedal Hat", 1.7},
        {"Low Tom", -1.5},
        {"Mid Tom", -2.0},
        {"High Tom", -2.0},
        {"808 Tom", -1.1},
        {"Acoustic Tom", -13.5},
        {"Crash", -2.4},
        {"Ride", 0.6},
        {"Ride Bell", -5.4},
        {"China", -6.6},
        {"Splash", -3.6},
        {"Rim", 1.8},
        {"Clap", 2.6},
        {"Snap", 2.2},
        {"Cowbell", -0.4},
        {"Shaker", -5.5},
        {"Tambourine", -5.6},
        {"Conga", -11.3},
        {"Bongo", -7.2},
        {"Woodblock", 4.0},
        {"Clave", 14.4},
        {"Triangle", 6.9},
        {"Zap", -1.0},
        {"Laser", -6.1},
        {"Noise Riser", -14.6}};
    for (Sound& x : s)
        for (const auto& [name, db] : trims)
            if (x.name == name) x.voice[kLevel] = x.voice[kLevel] + db;
    return s;
}

// A kit pad: which sound, tuned and levelled.
struct KitPad {
    uint32_t pad;
    std::string_view sound;
    double tune = 0, level = 0;
};
struct KitDef {
    std::string_view name, description;
    std::vector<KitPad> pads;
    std::vector<P> globals;
};

// Bank A follows the General MIDI percussion keys 36..51 (A1 = 36 kick, A3 = 38 snare, A7 = 42 closed hat...).
std::vector<KitDef> makeKits() {
    auto row = [](std::string_view kick, std::string_view rim, std::string_view snare, std::string_view clap,
                  std::string_view snare2, std::string_view tom, std::string_view closed, std::string_view pedal,
                  std::string_view open, std::string_view crash, std::string_view ride, double t2 = 0) {
        return std::vector<KitPad>{
            {0, kick}, {1, rim}, {2, snare}, {3, clap}, {4, snare2, t2}, {5, tom, -7}, {6, closed}, {7, tom, -5},
            {8, pedal}, {9, tom, -3}, {10, open}, {11, tom, 0}, {12, tom, 2}, {13, crash}, {14, tom, 5}, {15, ride}};
    };
    std::vector<KitDef> k;
    k.push_back({"808", "The 808's kit: boom, snare, clap, metal hats, sine toms, cowbell and crash",
                 row("808 Kick", "Rim", "808 Snare", "Clap", "808 Snare", "808 Tom", "808 Closed Hat", "Pedal Hat",
                     "808 Open Hat", "Crash", "Cowbell", 3),
                 {}});
    k.push_back({"909", "The 909's kit: punchy kick, snappy snare, crushed hats",
                 row("909 Kick", "Rim", "909 Snare", "Clap", "Clap Snare", "Mid Tom", "909 Closed Hat", "Pedal Hat",
                     "909 Open Hat", "Crash", "Ride"),
                 {{kGlue, 0.3}}});
    k.push_back({"Acoustic", "A played kit: beater kick, wired snares, membrane toms, cymbals in a room",
                 row("Acoustic Kick", "Rim Snare", "Acoustic Snare", "Snap", "Tight Snare", "Acoustic Tom", "Acoustic Hat",
                     "Pedal Hat", "808 Open Hat", "Crash", "Ride"),
                 {{kRoom, 0.2}, {kRoomSize, 0.5}, {kRoomDecay, 1.0}, {kGlue, 0.3}}});
    k.push_back({"Trap", "Long 808s, crisp claps and fast hats",
                 row("Trap Kick", "Rim", "Clap Snare", "Clap", "808 Snare", "808 Tom", "808 Closed Hat", "Pedal Hat",
                     "808 Open Hat", "Crash", "Ride Bell", 2),
                 {{kGlue, 0.4}}});
    k.push_back({"Techno", "Driven kick, trashy hats and a glued, taped bus",
                 row("Techno Kick", "Rim", "909 Snare", "Clap", "Clap Snare", "808 Tom", "Trashy Hat", "Pedal Hat",
                     "909 Open Hat", "China", "Ride"),
                 {{kGlue, 0.6}, {kGlueThreshold, -18}, {kGlueMakeup, 6}, {kKitDriveType, 2}, {kKitDrive, 2.5}, {kRoom, 0.1}}});
    k.push_back({"Lo-fi", "Dusty and crushed: soft kick, fat snare, a small room",
                 row("Sub Kick", "Rim", "Fat Snare", "Snap", "Clap Snare", "Acoustic Tom", "Acoustic Hat", "Pedal Hat",
                     "808 Open Hat", "Splash", "Ride"),
                 {{kKitDriveType, 4}, {kKitDrive, 5}, {kKitDriveMix, 0.6}, {kGlue, 0.5}, {kRoom, 0.15}}});
    return k;
}

const std::vector<KitDef>& kitDefs() {
    static const std::vector<KitDef> k = makeKits();
    return k;
}

Voice kitVoice(const KitPad& p) {
    const Sound* s = findSound(p.sound);
    Voice v = s ? s->voice : neutralVoice();
    v[kTune] = constrainPad(kTune, v[kTune] + p.tune);
    v[kLevel] = constrainPad(kLevel, v[kLevel] + p.level);
    return v;
}

std::string number(double v) {
    char buf[40];
    std::snprintf(buf, sizeof buf, "%.17g", v);
    return buf;
}

}  // namespace

const std::vector<Sound>& sounds() {
    static const std::vector<Sound> s = makeSounds();
    return s;
}

const Sound* findSound(std::string_view name) {
    for (const Sound& s : sounds())
        if (s.name == name) return &s;
    return nullptr;
}

const Voice& defaultVoice(uint32_t pad) {
    static const std::vector<Voice> v = [] {
        std::vector<Voice> x(kPads, neutralVoice());
        for (const KitPad& p : kitDefs().front().pads) x[p.pad] = kitVoice(p);
        return x;
    }();
    return pad < kPads ? v[pad] : neutralVoice();
}

}  // namespace drums

using namespace drums;

namespace {

// ---------- Presets ----------

// The values that turn the descriptor's defaults into `pads` (index: a voice or null) and `globals`.
std::vector<std::pair<std::string_view, double>> presetValues(const std::vector<const Voice*>& pads,
                                                               const std::vector<P>& globals) {
    const ParameterDescriptor* t = parameterTable();
    std::vector<std::pair<std::string_view, double>> out;
    for (const P& g : globals)
        if (t[g.first].defaultValue != g.second) out.emplace_back(t[g.first].id, g.second);
    for (uint32_t pad = 0; pad < kPads; ++pad) {
        const Voice& def = defaultVoice(pad);
        const Voice* want = pads[pad];
        if (!want) {  // unused: a default sound there stops answering its note
            if (def[kBodyOn] + def[kSubOn] + def[kClickOn] + def[kNoiseOn] + def[kMetalOn] + def[kResOn] + def[kSmpOn] > 0.0)
                out.emplace_back(t[padParam(pad, kNote)].id, kNoteOff);
            continue;
        }
        for (uint32_t k = 0; k < kPadParams; ++k)
            if ((*want)[k] != def[k]) out.emplace_back(t[padParam(pad, k)].id, (*want)[k]);
    }
    return out;
}

std::vector<BuiltinPreset> makePresets() {
    std::vector<BuiltinPreset> out;
    static std::deque<std::string> text;
    static std::deque<Voice> voices;
    for (const KitDef& k : kitDefs()) {
        std::vector<const Voice*> pads(kPads, nullptr);
        for (const KitPad& p : k.pads) {
            voices.push_back(kitVoice(p));
            pads[p.pad] = &voices.back();
        }
        std::vector<P> globals = k.globals;
        globals.push_back({kMode, kModeKit});
        text.push_back("Kit: " + std::string(k.name));
        out.push_back({text.back(), k.description, presetValues(pads, globals)});
    }
    for (const Sound& s : sounds()) {
        std::vector<const Voice*> pads(kPads, nullptr);
        for (uint32_t p = 0; p < kPads; ++p) pads[p] = &defaultVoice(p);  // the kit stays as it is
        pads[0] = &s.voice;
        out.push_back({s.name, s.description, presetValues(pads, {{kMode, kModeSingle}})});
    }
    return out;
}

// ---------- Randomize ----------

struct Range {
    uint32_t p;
    double lo, hi;
};
// Per drum type: the knobs a random sound draws, within the ranges that keep it that drum (and the layers that
// must be on). Anything not listed stays as the starting sound has it.
struct TypeRule {
    std::vector<uint32_t> on;
    std::vector<Range> ranges;
    std::vector<std::pair<uint32_t, std::vector<int>>> choices;
};

const TypeRule& rule(int type) {
    static const std::vector<TypeRule> rules = [] {
        std::vector<TypeRule> r(kTypeCount);
        const std::vector<Range> common = {{kDrive, 1, 6},     {kEqLow, -6, 6},     {kEqMid, -6, 6},   {kEqHigh, -6, 6},
                                           {kTrAttack, -0.3, 0.6}, {kComp, 0, 0.5}, {kRndPitch, 0, 12}, {kRndDecay, 0, 0.25},
                                           {kRndTone, 0, 0.25}, {kVelTone, 0, 0.6}, {kClipGain, 0, 6}};
        const std::vector<std::pair<uint32_t, std::vector<int>>> commonChoices = {
            {kDriveType, {kDriveOff, kDriveOff, kDriveSoft, kDriveTube, kDriveAsym}}, {kClip, {kClipOff, kClipOff, kClipOff, kClipSoft}}};
        auto set = [&](int t, std::vector<uint32_t> on, std::vector<Range> ranges,
                       std::vector<std::pair<uint32_t, std::vector<int>>> choices = {}) {
            r[t].on = std::move(on);
            r[t].ranges = common;
            r[t].ranges.insert(r[t].ranges.end(), ranges.begin(), ranges.end());
            r[t].choices = commonChoices;
            r[t].choices.insert(r[t].choices.end(), choices.begin(), choices.end());
        };
        const std::vector<Range> metalHat = {{kMetalFreq, 300, 700}, {kMetalTone, 5000, 11000}, {kMetalColor, 6000, 14000},
                                             {kMetalBand, 0, 0.8}, {kMetalNoise, 0.1, 0.7}, {kMetalFm, 0, 6},
                                             {kMetalSpread, -0.4, 0.4}};
        const std::vector<std::pair<uint32_t, std::vector<int>>> hatChoices = {
            {kMetalSet, {kSet808, kSetBright, kSetCymbal}}, {kMetalMode, {kMetalSquare, kMetalFmPairs, kMetalRing}}};
        set(kTypeKick, {kBodyOn},
            {{kBodyFreq, 38, 80}, {kBodyPitch, 4, 40}, {kBodyPTime, 0.01, 0.12}, {kBodyPCurve, -0.3, 0.7},
             {kBodyDecay, 0.15, 1.8}, {kBodyDCurve, -0.5, 0.5}, {kBodyShape, 0, 0.6}, {kClickLevel, 0.1, 0.9},
             {kClickTone, 800, 6000}, {kClickLength, 0.002, 0.02}, {kSubDecay, 0.2, 1.5}, {kSubLevel, -18, -3},
             {kVelPunch, 0, 0.5}},
            {{kBodyWave, {kWaveSine, kWaveSine, kWaveTriangle}}, {kClickType, {0, 1, 2, 3, 4, 5}}, {kSubOn, {0, 0, 1}},
             {kSubOct, {0, 1}}});
        set(kTypeBass, {kBodyOn},
            {{kBodyPitch, 0, 12}, {kBodyPTime, 0.01, 0.08}, {kBodyDecay, 0.6, 3}, {kBodyShape, 0, 0.5}});
        set(kTypeSnare, {kBodyOn, kNoiseOn},
            {{kBodyFreq, 150, 280}, {kBodyDecay, 0.05, 0.25}, {kBodyPitch, 0, 10}, {kBodyP2Ratio, 1.3, 1.8},
             {kBodyP2Level, 0.2, 0.8}, {kNoiseFreq, 800, 5000}, {kNoiseDecay, 0.08, 0.4}, {kNoiseRes, 0, 0.3}},
            {{kNoiseMode, {kNoiseNormal, kNoiseSnappy}}, {kNoiseColor, {kWhite, kPink}}});
        set(kTypeClap, {kNoiseOn},
            {{kNoiseFreq, 700, 2500}, {kNoiseRes, 0.1, 0.4}, {kNoiseBursts, 2, 6}, {kNoiseSpacing, 0.006, 0.015},
             {kNoiseDecay, 0.08, 0.4}});
        set(kTypeClosedHat, {kMetalOn}, metalHat, hatChoices);
        r[kTypeClosedHat].ranges.push_back({kMetalDecay, 0.02, 0.08});
        r[kTypeClosedHat].ranges.push_back({kMetalOpen, 0, 0});
        r[kTypePedalHat] = r[kTypeClosedHat];
        set(kTypeOpenHat, {kMetalOn}, metalHat, hatChoices);
        r[kTypeOpenHat].ranges.push_back({kMetalDecay, 0.035, 0.08});
        r[kTypeOpenHat].ranges.push_back({kMetalOpen, 0.4, 0.8});
        set(kTypeTom, {kBodyOn},
            {{kBodyFreq, 60, 300}, {kBodyPitch, 2, 12}, {kBodyPTime, 0.02, 0.12}, {kBodyDecay, 0.2, 0.8},
             {kResDecay, 0.2, 0.6}, {kResDamp, 0.3, 0.7}, {kRndPos, 0, 0.3}});
        const std::vector<Range> cymbal = {{kMetalFreq, 250, 700}, {kMetalTone, 2500, 7000}, {kMetalFm, 1, 7},
                                           {kMetalNoise, 0.2, 0.7}, {kMetalSpread, -0.3, 0.3}};
        const std::vector<std::pair<uint32_t, std::vector<int>>> cymbalChoices = {
            {kMetalSet, {kSetCymbal, kSetGong, kSetBright}}, {kMetalMode, {kMetalSquare, kMetalFmPairs, kMetalRing}}};
        set(kTypeCrash, {kMetalOn}, cymbal, cymbalChoices);
        r[kTypeCrash].ranges.push_back({kMetalDecay, 0.8, 3});
        set(kTypeRide, {kMetalOn}, cymbal, cymbalChoices);
        r[kTypeRide].ranges.push_back({kMetalDecay, 1.5, 3.5});
        set(kTypeCymbal, {kMetalOn}, cymbal, cymbalChoices);
        r[kTypeCymbal].ranges.push_back({kMetalDecay, 0.4, 2.5});
        set(kTypeRim, {kClickOn, kResOn}, {{kResFreq, 800, 2500}, {kResDecay, 0.02, 0.08}, {kClickTone, 1000, 3000}});
        set(kTypeCowbell, {kMetalOn},
            {{kMetalFreq, 450, 700}, {kMetalDecay, 0.1, 0.5}, {kMetalColor, 1500, 3500}, {kMetalBand, 0.4, 0.9}});
        set(kTypeShaker, {kNoiseOn}, {{kNoiseFreq, 4000, 10000}, {kNoiseAttack, 0.005, 0.05}, {kNoiseDecay, 0.04, 0.2}});
        set(kTypePerc, {kResOn},
            {{kResFreq, 150, 2500}, {kResDecay, 0.05, 0.6}, {kResDamp, 0.2, 0.7}, {kResBright, 0.3, 0.8},
             {kResPos, 0.05, 0.6}, {kResInharm, -0.3, 0.3}},
            {{kResModel, {0, 1, 2, 3}}});
        set(kTypeFx, {kBodyOn},
            {{kBodyFreq, 50, 600}, {kBodyPitch, 12, 96}, {kBodyPTime, 0.05, 1}, {kBodyPCurve, -1, 1}, {kBodyDecay, 0.1, 1.5},
             {kBodyFold, 0, 0.8}},
            {{kBodyWave, {0, 1, 2, 3}}});
        return r;
    }();
    return rules[type >= 0 && type < kTypeCount ? type : kTypePerc];
}

// A deterministic stream of numbers in 0..1 from a seed.
struct Stream {
    uint32_t seed, n = 0;
    double next() { return hash32(seed * 0x9E3779B1u ^ hash32(++n * 0x85EBCA77u)) / 4294967296.0; }
};

double normalized(uint32_t p, double v) {
    const ParameterDescriptor& d = padParamDescriptor(0, p);
    if (d.curve == ParameterCurve::Exponential) return std::log(v / d.minimum) / std::log(d.maximum / d.minimum);
    return d.maximum > d.minimum ? (v - d.minimum) / (d.maximum - d.minimum) : 0.0;
}
double denormalized(uint32_t p, double t) {
    const ParameterDescriptor& d = padParamDescriptor(0, p);
    if (d.curve == ParameterCurve::Exponential) return d.minimum * std::pow(d.maximum / d.minimum, t);
    return d.minimum + t * (d.maximum - d.minimum);
}

}  // namespace

namespace drums {
const std::vector<Kit>& kits() {
    static const std::vector<Kit> k = [] {
        std::vector<Kit> x;
        for (const KitDef& d : kitDefs()) {
            Kit kit{d.name, d.description, {}, d.globals};
            for (const KitPad& p : d.pads) kit.pads.emplace_back(p.pad, p.sound);
            x.push_back(std::move(kit));
        }
        return x;
    }();
    return k;
}
const Kit& defaultKit() { return kits().front(); }

// The randomizer (pure: the same type, seed, amount and start give the same sound). It starts from `start`, draws
// each knob of the type's rule within its range and moves it `amount` of the way there (in the knob's own taper),
// switches each listed choice with probability amount / 3, turns the type's layers on, and clamps every drawn
// knob into its range again: a random kick is still a kick.
Voice randomizeVoice(int type, uint32_t seed, double amount, const Voice& start) {
    const TypeRule& r = rule(type);
    Stream rng{seed};
    Voice v = start;
    const double a = amount < 0.0 ? 0.0 : (amount > 1.0 ? 1.0 : amount);
    for (const Range& range : r.ranges) {
        const double target = range.lo + (range.hi - range.lo) * rng.next();
        const double t0 = normalized(range.p, constrainPad(range.p, v[range.p]));
        const double t1 = normalized(range.p, constrainPad(range.p, target));
        double x = denormalized(range.p, t0 + (t1 - t0) * a);
        x = x < range.lo ? range.lo : (x > range.hi ? range.hi : x);
        v[range.p] = constrainPad(range.p, x);
    }
    for (const auto& [p, values] : r.choices) {
        const double roll = rng.next(), pick = rng.next();
        if (roll < a / 3.0) v[p] = values[static_cast<size_t>(pick * values.size()) % values.size()];
    }
    for (uint32_t p : r.on) v[p] = 1.0;
    v[kType] = type;
    // Level-matched: a hit (its first 0.4 s, rendered here) peaks near -1 dBFS whatever the draw did to its gain.
    std::vector<float> hit;
    if (renderVoice(v, 48000.0, 0.4, hit)) {
        float peak = 0.0f;
        for (float x : hit) peak = std::max(peak, std::fabs(x));
        if (peak > 1e-4f) v[kLevel] = constrainPad(kLevel, v[kLevel] + std::clamp(db(0.89 / peak), -24.0, 24.0));
    }
    return v;
}
}  // namespace drums

const std::vector<BuiltinPreset>& drumsPresets() {
    static const std::vector<BuiltinPreset> p = makePresets();
    return p;
}

// ---------- The C API's JSON ----------

namespace {

std::string voiceJson(const Voice& v, const std::string& prefix, bool onlyChanged) {
    std::string j = "{";
    bool first = true;
    const Voice& n = neutralVoice();
    for (uint32_t k = 0; k < kPadParams; ++k) {
        if (onlyChanged && v[k] == n[k]) continue;
        j += (first ? "\"" : ",\"") + prefix + std::string(padParamSuffix(k)) + "\":" + number(v[k]);
        first = false;
    }
    return j + "}";
}

// The pad's values from a {"params": {...}} object: prefixed ids ("a1_body_freq") for `pad`, or bare suffixes.
Voice voiceFrom(const Json* params, uint32_t pad, const Voice& base) {
    Voice v = base;
    if (!params || params->type != Json::Type::Object) return v;
    const std::string prefix = padId(pad) + "_";
    for (const auto& [k, value] : params->obj) {
        if (value.type != Json::Type::Number) continue;
        std::string_view id = k;
        if (id.substr(0, prefix.size()) == prefix) id.remove_prefix(prefix.size());
        const int p = padParamIndex(id);
        if (p >= 0) v[static_cast<uint32_t>(p)] = constrainPad(static_cast<uint32_t>(p), value.num);
    }
    return v;
}

std::string error(const std::string& message) { return "{\"ok\":false,\"error\":\"" + jsonEscape(message) + "\"}"; }

constexpr const char* kLayerNames[][2] = {
    {"pad", "Pad"},       {"press", "Pressure"}, {"body", "Body"},     {"penv", "Pitch shape"}, {"sub", "Sub"},
    {"click", "Click"},   {"noise", "Noise"},    {"metal", "Metal"},   {"res", "Resonator"},    {"smp", "Sample"},
    {"drive", "Drive"},   {"filter", "Filter"},  {"eq", "EQ"},         {"dyn", "Dynamics"},     {"space", "Space"},
    {"macro", "Character"}, {"var", "Variation"}};
// The General MIDI percussion names of keys 35..81 (GM 1 Sound Set; docs/engine.md "Drums", MIDI map).
constexpr const char* kGmNames[] = {
    "Acoustic Bass Drum", "Bass Drum 1", "Side Stick", "Acoustic Snare", "Hand Clap", "Electric Snare", "Low Floor Tom",
    "Closed Hi-Hat", "High Floor Tom", "Pedal Hi-Hat", "Low Tom", "Open Hi-Hat", "Low-Mid Tom", "Hi-Mid Tom",
    "Crash Cymbal 1", "High Tom", "Ride Cymbal 1", "Chinese Cymbal", "Ride Bell", "Tambourine", "Splash Cymbal",
    "Cowbell", "Crash Cymbal 2", "Vibraslap", "Ride Cymbal 2", "Hi Bongo", "Low Bongo", "Mute Hi Conga",
    "Open Hi Conga", "Low Conga", "High Timbale", "Low Timbale", "High Agogo", "Low Agogo", "Cabasa", "Maracas",
    "Short Whistle", "Long Whistle", "Short Guiro", "Long Guiro", "Claves", "Hi Wood Block", "Low Wood Block",
    "Mute Cuica", "Open Cuica", "Mute Triangle", "Open Triangle"};

}  // namespace

std::string drumsInfoJson() {
    std::string j = "{\"ok\":true,\"id\":\"" + std::string(kDrumsId) + "\",\"banks\":" + std::to_string(kBanks) +
                    ",\"pads_per_bank\":" + std::to_string(kPadsPerBank) + ",\"pads\":" + std::to_string(kPads) +
                    ",\"parameters\":" + std::to_string(kParamCount) + ",\"pad_parameters\":" + std::to_string(kPadParams) +
                    ",\"outputs\":" + std::to_string(kOutputs) + ",\"globals\":[";
    const ParameterDescriptor* t = parameterTable();
    for (uint32_t k = 0; k < kGlobalCount; ++k) j += (k ? ",\"" : "\"") + std::string(t[k].id) + "\"";
    j += "],\"layers\":[";
    bool firstLayer = true;
    for (const auto& layer : kLayerNames) {
        j += std::string(firstLayer ? "" : ",") + "{\"id\":\"" + layer[0] + "\",\"name\":\"" + layer[1] + "\",\"params\":[";
        bool first = true;
        for (uint32_t k = 0; k < kPadParams; ++k) {
            const std::string_view g = padParamDescriptor(0, k).group;
            if (g.substr(g.find('/') + 1) != layer[0]) continue;
            j += (first ? "\"" : ",\"") + std::string(padParamSuffix(k)) + "\"";
            first = false;
        }
        j += "]}";
        firstLayer = false;
    }
    j += "],\"types\":[";
    for (int k = 0; k < kTypeCount; ++k) j += (k ? ",\"" : "\"") + std::string(typeName(k)) + "\"";
    j += "],\"sounds\":[";
    for (size_t i = 0; i < sounds().size(); ++i) {
        const Sound& s = sounds()[i];
        j += std::string(i ? "," : "") + "{\"name\":\"" + jsonEscape(s.name) + "\",\"type\":" + std::to_string(s.type) +
             ",\"description\":\"" + jsonEscape(s.description) + "\",\"params\":" + voiceJson(s.voice, "", true) + "}";
    }
    j += "],\"kits\":[";
    for (size_t i = 0; i < kits().size(); ++i) {
        const Kit& k = kits()[i];
        j += std::string(i ? "," : "") + "{\"name\":\"" + jsonEscape(k.name) + "\",\"preset\":\"Kit: " + jsonEscape(k.name) +
             "\",\"description\":\"" + jsonEscape(k.description) + "\",\"pads\":{";
        for (size_t p = 0; p < k.pads.size(); ++p)
            j += (p ? ",\"" : "\"") + padId(k.pads[p].first) + "\":\"" + jsonEscape(k.pads[p].second) + "\"";
        j += "}}";
    }
    j += "],\"samples\":[";
    const std::vector<std::string> names = builtinDrumSampleNames();
    for (size_t i = 0; i < names.size(); ++i) j += (i ? ",\"" : "\"") + jsonEscape(names[i]) + "\"";
    j += "],\"gm\":[";
    for (int n = 35; n <= 81; ++n) {
        j += std::string(n > 35 ? "," : "") + "{\"note\":" + std::to_string(n) + ",\"name\":\"" + kGmNames[n - 35] + "\"";
        if (n >= 36 && n < 36 + static_cast<int>(kPads)) j += ",\"pad\":\"" + padId(static_cast<uint32_t>(n - 36)) + "\"";
        j += "}";
    }
    j += "],\"display\":{\"version\":2,\"floats\":656,\"header\":16,\"pad_levels\":16,\"wave_max\":80,\"wave_min\":336,\"wave_bins\":256,"
         "\"pitch\":592,\"pitch_points\":64}}";
    return j;
}

std::string drumsRandomizeJson(int type, uint32_t seed, double amount, int pad, std::string_view currentJson) {
    const uint32_t p = pad >= 0 && pad < static_cast<int>(kPads) ? static_cast<uint32_t>(pad) : 0;
    Voice start;
    bool haveCurrent = false;
    if (!currentJson.empty()) {
        Json j;
        std::string why;
        if (!parseJson(currentJson, j, why) || j.type != Json::Type::Object) return error(why.empty() ? "current must be an object" : why);
        const Json* params = j.get("params");
        if (params && params->type == Json::Type::Object && !params->obj.empty()) {
            start = voiceFrom(params, p, defaultVoice(p));
            haveCurrent = true;
        }
    }
    if (type < 0 || type >= kTypeCount) type = haveCurrent ? static_cast<int>(start[kType]) : kTypeKick;
    if (!haveCurrent || (haveCurrent && static_cast<int>(start[kType]) != type)) {
        // A fresh sound: a seeded pick among the library's sounds of this type (the nearest kind when it has none).
        std::vector<const Sound*> pool;
        for (const Sound& s : sounds())
            if (s.type == type) pool.push_back(&s);
        if (pool.empty())
            for (const Sound& s : sounds())
                if (s.type == kTypePerc) pool.push_back(&s);
        const Voice keep = haveCurrent ? start : defaultVoice(p);
        start = pool[hash32(seed ^ 0xA511E9B3u) % pool.size()]->voice;
        for (uint32_t k : {kNote, kChan, kLevel, kPan, kChoke, kOut}) start[k] = keep[k];  // where it sits stays
        if (amount <= 0.0) amount = 1.0;
    }
    const Voice v = randomizeVoice(type, seed, amount, start);
    return "{\"ok\":true,\"type\":\"" + std::string(typeName(type)) + "\",\"pad\":\"" + padId(p) +
           "\",\"params\":" + voiceJson(v, padId(p) + "_", false) + "}";
}

std::string drumsExplodeJson(std::string_view entryJson) {
    Json j;
    std::string why;
    if (!parseJson(entryJson, j, why) || j.type != Json::Type::Object) return error(why.empty() ? "an entry must be an object" : why);
    if (j.string("id") != kDrumsId) return error("only org.caw.drums can be exploded");
    const Json* params = j.get("params");
    auto global = [&](uint32_t k) {
        const ParameterDescriptor& d = parameterTable()[k];
        if (params && params->type == Json::Type::Object)
            if (const Json* v = params->get(std::string(d.id)); v && v->type == Json::Type::Number) return v->num;
        return d.defaultValue;
    };
    const int base = static_cast<int>(global(kBaseNote));
    const int mode = static_cast<int>(global(kMode));
    const Json* samples = j.get("samples");
    std::string out = "{\"ok\":true,\"tracks\":[";
    bool first = true;
    for (uint32_t pad = 0; pad < (mode == kModeSingle ? 1u : kPads); ++pad) {
        const Voice v = voiceFrom(params, pad, defaultVoice(pad));
        const int note = static_cast<int>(v[kNote]);
        const bool used = v[kBodyOn] + v[kSubOn] + v[kClickOn] + v[kNoiseOn] + v[kMetalOn] + v[kResOn] + v[kSmpOn] > 0.0 &&
                          v[kLevel] > -60.0 && (mode == kModeSingle || note != kNoteOff);
        if (!used) continue;
        Voice single = v;
        single[kNote] = kNoteAuto;
        single[kChan] = 1;  // Any: the track's own notes
        single[kChoke] = 0;
        single[kOut] = 0;
        std::string notes;
        if (mode == kModeSingle) notes = "\"all\"";
        else if (v[kTrack] >= 0.5 && v[kChan] >= 2) notes = "{\"channel\":" + std::to_string(static_cast<int>(v[kChan]) - 1) + "}";
        else if (note == kNoteAny) notes = "\"other\"";
        else notes = "[" + std::to_string(note == kNoteAuto ? autoNote(pad, base) : note - kNoteFirst) + "]";
        out += std::string(first ? "" : ",") + "{\"pad\":\"" + padId(pad) + "\",\"name\":\"" + padName(pad) + " " +
               std::string(typeName(static_cast<int>(v[kType]))) + "\",\"notes\":" + notes +
               ",\"choke\":" + std::to_string(static_cast<int>(v[kChoke])) +
               ",\"instrument\":{\"id\":\"org.caw.drums\",\"params\":";
        // Pad A1 of a Single-mode Drums carries the sound (the kit effects stay on the original; see "kit").
        std::string ps = voiceJson(single, "a1_", false);
        ps.insert(1, "\"mode\":1,");
        out += ps;
        if (samples && samples->type == Json::Type::Array)
            for (const Json& s : samples->arr)
                if (s.type == Json::Type::Object && static_cast<uint32_t>(s.number("slot", -1)) == pad) {
                    out += ",\"samples\":[{\"slot\":0";
                    if (!s.string("path").empty()) out += ",\"path\":\"" + jsonEscape(s.string("path")) + "\"";
                    if (!s.string("builtin").empty()) out += ",\"builtin\":\"" + jsonEscape(s.string("builtin")) + "\"";
                    out += "}]";
                }
        out += "}}";
        first = false;
    }
    out += "],\"kit\":{";
    for (uint32_t k = kGlue; k < kGlobalCount; ++k)
        out += (k > kGlue ? ",\"" : "\"") + std::string(parameterTable()[k].id) + "\":" + number(global(k));
    return out + "}}";
}

std::vector<std::string> builtinDrumSampleNames() {
    std::vector<std::string> names;
    for (const Sound& s : sounds()) names.emplace_back(s.name);
    return names;
}

// ---------- The old drums ----------

namespace {

constexpr std::string_view kOldKick = "org.caw.drum.kick", kOldSnare = "org.caw.drum.snare",
                           kOldHats = "org.caw.drum.hats", kOldKit = "org.caw.drum.kit";

double read(const std::vector<std::pair<std::string, double>>& params, std::string_view id, double def) {
    for (const auto& [k, v] : params)
        if (k == id && std::isfinite(v)) return v;
    return def;
}
double clampTo(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }

// lib::KickVoice as a pad: a sine falling from tune (1 + 10 punch) Hz along the square of an envelope (an
// exponential twice as fast), a high-passed noise click, the Library's tanh drive, then a one-pole tone filter.
Voice oldKick(double tune, double punch, double decay, double click, double tone, double drive) {
    punch = clampTo(punch, 0, 1);
    return voice(kTypeKick, {{kPoly, 1}, {kVelTone, 0}, {kVelClick, 0}, {kBodyOn, 1}, {kBodyFreq, clampTo(tune, 20, 200)},
                             {kBodyPitch, 12.0 * std::log2(1.0 + 10.0 * punch)}, {kBodyPTime, (0.04 + 0.08 * punch) / 2.0},
                             {kBodyAttack, 0.001}, {kBodyDecay, clampTo(decay, 0.01, 4)}, {kClickOn, 1},
                             {kClickType, kClickNoise}, {kClickLevel, clampTo(click, 0, 1)}, {kClickTone, 1500},
                             {kClickLength, 0.008}, {kDriveType, kDriveSoft}, {kDrive, clampTo(drive, 1, 10)},
                             {kFlt, kVfLp6}, {kCutoff, 150.0 * std::pow(60.0, clampTo(tone, 0, 1))}});
}
// lib::SnareVoice: a triangle and a sine 1.48 times higher (0.6 : 0.4) with a small drop, plus high-passed noise.
Voice oldSnare(double tune, double body, double snappy, double tone, double mix) {
    mix = clampTo(mix, 0, 1);
    return voice(kTypeSnare, {{kPoly, 1}, {kVelTone, 0}, {kVelClick, 0}, {kBodyOn, mix < 0.999 ? 1.0 : 0.0},
                              {kBodyWave, kWaveTriangle}, {kBodyFreq, clampTo(tune, 80, 400)},
                              {kBodyPitch, 12.0 * std::log2(1.6)}, {kBodyPTime, 0.015}, {kBodyAttack, 0.001},
                              {kBodyDecay, clampTo(body, 0.01, 1)}, {kBodyP2Ratio, 1.48}, {kBodyP2Level, 0.4 / 0.6},
                              {kBodyLevel, db(0.6 * 1.2 * 0.8 * (1.0 - mix))}, {kNoiseOn, mix > 0.001 ? 1.0 : 0.0},
                              {kNoiseFilter, kFilterHp}, {kNoiseFreq, clampTo(tone, 200, 12000)}, {kNoiseRes, 0},
                              {kNoiseAttack, 0.001}, {kNoiseDecay, clampTo(snappy, 0.01, 2)},
                              {kNoiseLevel, db(2.0 * 0.8 * mix)}});
}
// lib::HatVoice: the six 808 squares (at twice the oscillators' pitch) mixed with noise, high-passed at q 1.2.
Voice oldHat(double tone, double metal, double decay, DrumType type) {
    return voice(type, {{kPoly, 1}, {kChoke, 1}, {kVelTone, 0}, {kVelClick, 0}, {kMetalOn, 1}, {kMetalSet, kSet808},
                        {kMetalFreq, 410.6}, {kMetalNoise, 1.0 - clampTo(metal, 0, 1)},
                        {kMetalTone, clampTo(tone, 1000, 16000)}, {kMetalBand, 0},
                        {kMetalRes, std::log(1.2 / 0.70710678118654752) / std::log(28.0)}, {kMetalAttack, 0.0005},
                        {kMetalDecay, clampTo(decay, 0.005, 4)}});
}
// lib::ClapVoice: band-passed noise (q 1.5) in three bursts 10 ms apart, each falling 60 dB in 30 ms, then a tail.
Voice oldClap(double decay) {
    return voice(kTypeClap, {{kPoly, 1}, {kVelTone, 0}, {kVelClick, 0}, {kNoiseOn, 1}, {kNoiseMode, kNoiseClap},
                             {kNoiseFilter, kFilterBp}, {kNoiseFreq, 1200},
                             {kNoiseRes, std::log(1.5 / 0.70710678118654752) / std::log(28.0)}, {kNoiseBursts, 3},
                             {kNoiseSpacing, 0.01}, {kNoiseAttack, 0.004}, {kNoiseDecay, clampTo(decay, 0.02, 2)},
                             {kNoiseLevel, db(1.6)}});
}

void put(std::vector<std::pair<std::string, double>>& out, uint32_t pad, const Voice& v, double levelDb) {
    Voice x = v;
    x[kLevel] = clampTo(levelDb, -60, 12);
    for (uint32_t k = 0; k < kPadParams; ++k) out.emplace_back(padId(pad) + "_" + std::string(padParamSuffix(k)), x[k]);
}
void noteOf(std::vector<std::pair<std::string, double>>& out, uint32_t pad, int note) {
    for (auto& [k, v] : out)
        if (k == padId(pad) + "_note") {
            v = note;
            return;
        }
    out.emplace_back(padId(pad) + "_note", note);
}
// Bank A pads the migration doesn't use stop answering their notes.
void silenceOthers(std::vector<std::pair<std::string, double>>& out, std::initializer_list<uint32_t> used) {
    for (uint32_t pad = 0; pad < kPadsPerBank; ++pad) {
        bool in = false;
        for (uint32_t u : used) in = in || u == pad;
        if (!in) noteOf(out, pad, kNoteOff);
    }
}

}  // namespace

bool isLegacyDrum(std::string_view id) { return id == kOldKick || id == kOldSnare || id == kOldHats || id == kOldKit; }

bool migrateLegacyDrum(std::string& id, std::vector<std::pair<std::string, double>>& params, std::string* preset) {
    if (!isLegacyDrum(id)) return false;
    const auto& in = params;
    std::vector<std::pair<std::string, double>> out;
    const double volume = clampTo(read(in, "volume", 0.8), 0, 1);
    if (id == kOldKick || id == kOldSnare) {
        out.emplace_back("mode", kModeSingle);
        if (id == kOldKick)
            put(out, 0, oldKick(read(in, "tune", 48), read(in, "punch", 0.6), read(in, "decay", 0.35), read(in, "click", 0.3),
                                read(in, "tone", 0.6), read(in, "drive", 1.5)), db(volume));
        else
            put(out, 0, oldSnare(read(in, "tune", 185), read(in, "body", 0.07), read(in, "snappy", 0.18),
                                 read(in, "tone", 2500), read(in, "mix", 0.5)), db(volume));
    } else if (id == kOldHats) {
        const int mode = static_cast<int>(clampTo(std::floor(read(in, "mode", 0) + 0.5), 0, 2));
        const double tone = read(in, "tone", 7000), metal = read(in, "metal", 0.5);
        const double closed = read(in, "closed", 0.045), open = read(in, "open", 0.3);
        if (mode == 0) {  // by note: open on A#2 (46), closed on every other key
            out.emplace_back("mode", kModeKit);
            put(out, 0, oldHat(tone, metal, closed, kTypeClosedHat), db(volume));
            put(out, 1, oldHat(tone, metal, open, kTypeOpenHat), db(volume));
            noteOf(out, 0, kNoteAny);
            noteOf(out, 1, kNoteFirst + 46);
            silenceOthers(out, {0, 1});
        } else {
            out.emplace_back("mode", kModeSingle);
            put(out, 0, oldHat(tone, metal, mode == 1 ? closed : open, mode == 1 ? kTypeClosedHat : kTypeOpenHat), db(volume));
        }
    } else {  // the kit: B1/C2 kick, D2/E2 snare, D#2 clap, F#2/G#2 closed hat, A#2 open hat
        out.emplace_back("mode", kModeKit);
        out.emplace_back("volume", db(volume));
        const Voice kick = oldKick(read(in, "kick_tune", 48), read(in, "kick_punch", 0.6), read(in, "kick_decay", 0.35), 0.3, 0.6, 1.5);
        const Voice snare = oldSnare(read(in, "snare_tune", 185), 0.07, read(in, "snare_snappy", 0.18), 2500, 0.5);
        const double tone = read(in, "hat_tone", 7000);
        Voice kickVoice = kick, snareVoice = snare;
        kickVoice[kChoke] = 2;  // the two keys of one drum cut each other, as one voice did
        snareVoice[kChoke] = 3;
        const double kl = db(clampTo(read(in, "kick", 1.0), 0, 1)), sl = db(clampTo(read(in, "snare", 0.8), 0, 1)),
                     cl = db(clampTo(read(in, "clap", 0.7), 0, 1)), hl = db(clampTo(read(in, "hats", 0.6), 0, 1));
        put(out, 0, kickVoice, kl);   // A1 = 36
        put(out, 1, kickVoice, kl);   // A2, on 35
        noteOf(out, 1, kNoteFirst + 35);
        put(out, 2, snareVoice, sl);  // A3 = 38
        put(out, 4, snareVoice, sl);  // A5 = 40
        put(out, 3, oldClap(read(in, "clap_decay", 0.15)), cl);  // A4 = 39
        put(out, 6, oldHat(tone, 0.5, read(in, "hat_closed", 0.045), kTypeClosedHat), hl);  // A7 = 42
        put(out, 8, oldHat(tone, 0.5, read(in, "hat_closed", 0.045), kTypePedalHat), hl);   // A9 = 44
        put(out, 10, oldHat(tone, 0.5, read(in, "hat_open", 0.3), kTypeOpenHat), hl);       // A11 = 46
        silenceOthers(out, {0, 1, 2, 3, 4, 6, 8, 10});
    }
    id = std::string(kDrumsId);
    params = std::move(out);
    if (preset) preset->clear();  // no preset: the values are the old drum's own
    return true;
}

std::string migratedLegacyDrumParameter(std::string_view legacyId, std::string_view param) {
    if (legacyId == kOldKick) {
        if (param == "tune") return "a1_body_freq";
        if (param == "decay") return "a1_body_decay";
        if (param == "click") return "a1_click_level";
        if (param == "drive") return "a1_drive";
    } else if (legacyId == kOldSnare) {
        if (param == "tune") return "a1_body_freq";
        if (param == "body") return "a1_body_decay";
        if (param == "snappy") return "a1_noise_decay";
        if (param == "tone") return "a1_noise_freq";
    } else if (legacyId == kOldHats) {
        if (param == "closed") return "a1_metal_decay";
        if (param == "open") return "a2_metal_decay";  // by note (the default); Open mode plays pad A1
        if (param == "tone") return "a1_metal_tone";
    } else if (legacyId == kOldKit) {
        if (param == "kick_tune") return "a1_body_freq";
        if (param == "kick_decay") return "a1_body_decay";
        if (param == "snare_tune") return "a3_body_freq";
        if (param == "snare_snappy") return "a3_noise_decay";
        if (param == "clap_decay") return "a4_noise_decay";
        if (param == "hat_closed") return "a7_metal_decay";
        if (param == "hat_open") return "a11_metal_decay";
        if (param == "hat_tone") return "a7_metal_tone";
    }
    return {};
}

const std::vector<std::string_view>& legacyDrumKnobs(std::string_view legacyId) {
    static const std::vector<std::string_view> kick = {"tune", "punch", "decay", "click", "tone", "drive", "volume"},
                                               snare = {"tune", "body", "snappy", "tone", "mix", "volume"},
                                               hats = {"mode", "closed", "open", "tone", "metal", "volume"},
                                               kit = {"kick_tune", "kick_decay", "kick_punch", "snare_tune", "snare_snappy",
                                                      "clap_decay", "hat_closed", "hat_open", "hat_tone", "kick", "snare",
                                                      "clap", "hats", "volume"},
                                               none;
    if (legacyId == kOldKick) return kick;
    if (legacyId == kOldSnare) return snare;
    if (legacyId == kOldHats) return hats;
    if (legacyId == kOldKit) return kit;
    return none;
}

}  // namespace caw
