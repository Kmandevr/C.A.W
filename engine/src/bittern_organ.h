// Bittern's pipe organ (1.1.3): the Salt Lake Tabernacle organ's divisions (Great, Swell and Choir in their swell boxes, Antiphonal, Pedal) as 26 of its stops, ranks from measured and modelled pipe spectra, each pipe speaking on its own with recorded speech noise, one shared and sagging wind, the tremulant, and the hall on by default.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <initializer_list>
#include <memory>

#include "recorded_bank.h"
#include "instrument_core.h"

namespace caw::bittern {

using timber::clampd;
using timber::kControlFrames;
using timber::Shared;
using timber::VoiceBase;

// The stops, in the descriptor's order, by division as the Salt Lake Tabernacle organ has them (Aeolian-Skinner
// Opus 1075, docs/organ-research-tabernacle.md): the Great (unenclosed), the Swell and the Choir (each in its own
// swell box, with its tremulant), the Antiphonal's Tuba Mirabilis and the Pedal. Every stop is one of that organ's,
// by its name and pitch; the cut to 26 is the research's proposal (its 24, with the Swell's Nazard and Tierce kept
// for the cornet). The ids of the 1.1.3-alpha organ's stops are kept where the stop is the same kind of pipe, so a
// project from then loads.
enum Stop : int {
    kSubprincipal16, kPrincipal8, kFluteHarm8, kOctave4, kSuperOctave2, kFourniture, kTrumpet8,       // Great
    kGeigen8, kGedeckt8, kViole8, kTraverso4, kNazard, kTierce, kPleinJeu, kTrompette8, kHautbois8,  // Swell
    kConcertFlute8, kErzahler8, kKrummhorn8,                                                          // Choir
    kTuba8,                                                                                           // Antiphonal
    kContreBourdon32, kPedPrincipal16, kBourdon16, kPedOctave8, kTrombone16, kBombarde32,             // Pedal
    // 2026-11-25 (the owner: "a few more stops", strings "as additional sets of pipes", more low end): the Great's
    // Gemshorn, the Swell's Voix Humaine, the Choir's orchestral strings (Violin and Violoncello, as the Skinner
    // organs' orchestral string stops), and the Pedal's Contrabass, Quint 10 2/3' (with the 16' it sounds a 32'
    // resultant, the organ's own way to a low end smaller speakers can carry) and Choral Bass 4'.
    kGemshorn4, kVoixHumaine8, kViolin8, kCello8, kContrabass16, kQuint10, kChoralBass4,
    kStops,
    // The second ranks of the two-rank celestes (each follows its stop's knob): the Viole Céleste II's céleste and
    // the Kleine Erzähler II's.
    kVioleCeleste = kStops, kErzahlerCeleste, kRanks
};
enum Division : int { kGreat, kSwell, kChoir, kAntiphonal, kPedal, kDivisions };
inline constexpr int kDivisionOf[kRanks] = {
    kGreat, kGreat, kGreat, kGreat, kGreat, kGreat, kGreat,
    kSwell, kSwell, kSwell, kSwell, kSwell, kSwell, kSwell, kSwell, kSwell,
    kChoir, kChoir, kChoir,
    kAntiphonal,
    kPedal, kPedal, kPedal, kPedal, kPedal, kPedal,
    kGreat, kSwell, kChoir, kChoir, kPedal, kPedal, kPedal,
    kSwell, kChoir};
// The enclosed divisions: the swell box (the mod wheel) and the tremulant act on these only.
inline constexpr bool enclosed(int division) noexcept { return division == kSwell || division == kChoir; }
// Each rank's pipe family: its tables (bittern_tables.cpp). The first three are measured (tools/bittern_assets.py);
// the rest **[Assumption]** modelled spectra (nothing of theirs was recorded).
enum Family : int {
    kStopped, kOpen, kPrincipal, kString, kReed, kMixtureFamily, kOboe, kKrummhorn, kTuba, kErzahler, kTrompette,
    kGeigen, kHarmonicFlute, kViolin, kCello, kVoixHumaine, kFamilies
};
inline constexpr int kFamilyOf[kRanks] = {
    kPrincipal, kPrincipal, kHarmonicFlute, kPrincipal, kPrincipal, kMixtureFamily, kReed,
    kGeigen, kStopped, kString, kOpen, kOpen, kOpen, kMixtureFamily, kTrompette, kOboe,
    kOpen, kErzahler, kKrummhorn,
    kTuba,
    kStopped, kPrincipal, kStopped, kPrincipal, kReed, kReed,
    kErzahler, kVoixHumaine, kViolin, kCello, kCello, kStopped, kPrincipal,
    kString, kErzahler};
inline constexpr bool isReed(int family) noexcept {
    return family == kReed || family == kOboe || family == kKrummhorn || family == kTuba || family == kTrompette ||
           family == kVoixHumaine;
}
// The string families (the Viole, the orchestral Violin and Violoncello): slower to speak, and the orchestral ones
// with a player's vibrato.
inline constexpr bool isString(int family) noexcept { return family == kString || family == kViolin || family == kCello; }
// The rank's pitch as a multiple of the 8' note (16' = 0.5; the mixtures' tables are built at the 8' pitch).
inline constexpr double kFoot[kRanks] = {
    0.5, 1, 1, 2, 4, 1, 1,
    1, 1, 1, 2, 3, 5, 1, 1, 1,
    1, 1, 1,
    1,
    0.25, 0.5, 0.5, 1, 0.5, 0.25,
    2, 1, 1, 1, 0.5, 0.75, 2,
    1, 1};
// Each stop's voicing at its knob's full: its loudness against a principal 8' ([Assumption] by kind, after Harrison's
// "there are no very loud stops, the effect being obtained by the 188 ranks" and the Tuba Mirabilis on high pressure
// "to sing out above the choir or the organ"): flutes a little under the principals, strings and the Erzähler soft,
// the Swell's chorus a little under the Great's, the 32's felt more than heard.
inline constexpr float kVoicing[kRanks] = {
    0.8f, 1.0f, 0.85f, 0.85f, 0.7f, 1.0f, 0.9f,
    0.75f, 0.7f, 0.5f, 0.6f, 0.45f, 0.4f, 0.8f, 0.9f, 0.6f,
    0.65f, 0.35f, 0.55f,
    1.7f,
    0.9f, 0.9f, 0.8f, 0.7f, 0.9f, 1.0f,
    0.6f, 0.5f, 0.55f, 0.6f, 0.8f, 0.6f, 0.6f,
    0.5f, 0.35f};
// Each rank's tuning above its stop's (cents): the celestes' second ranks beat against the first ([Assumption] a
// string céleste about 6 cents sharp, a gentle one 3-4).
inline constexpr float kCelesteCents[kRanks] = {
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6.0f, 3.5f};
// The knob that sets a rank: its own, or for a céleste's second rank its stop's.
inline constexpr int stopOf(int rank) noexcept {
    return rank == kVioleCeleste ? kViole8 : rank == kErzahlerCeleste ? kErzahler8 : rank;
}
// The pedal's compass: C to g' (32 notes, MIDI 36-67 at the 8' pitch); a pedal stop sounds only within it.
inline constexpr double kPedalLow = 36, kPedalHigh = 67;

// The tables' zones: 2 semitones of the pipe's sounding pitch each, from MIDI 12 (the mixture's by its key's 8'
// pitch), every table 2^tableBits(zone) pairs of floats (each value and the step to the next; at most kTableSize),
// peak 1.
inline constexpr int kZones = 54;
inline constexpr uint32_t kTableSize = 2048;
inline int zoneOf(double sounding) noexcept { return std::clamp(static_cast<int>((sounding - 12.0) / 2.0), 0, kZones - 1); }
int tableBits(int zone) noexcept;

// The shared tables (built once per process, read-only; bittern_tables.cpp): a family's steady tone and its speaking
// tone (the spectrum while the pipe speaks) in zone z, and each table's RMS.
const float* steadyTable(int family, int zone) noexcept;
const float* speakingTable(int family, int zone) noexcept;
float tableRms(int family, int zone) noexcept;
void buildTables() noexcept;  // registerBittern calls it, so no voice ever builds them
size_t tableBytes() noexcept;

// The measured speech (bittern_tables.cpp, from bittern_bank.inc): the rise to half level of a flue pipe sounding
// at `hz`, and the recorded speech clip of group g (0 Quiet: stopped flute, 1 Loud: principal chorus, 2 Quiet Pedal:
// open flute, 3 Loud Pedal) nearest to MIDI `key` (8' pitch) within `maxSemitones`, or -1.
double riseSeconds(double hz) noexcept;
// `live` marks the clips that hold sound (bit i: clip i; Organ::prepare), the others never picked.
int nearestClip(int group, double key, double maxSemitones, uint64_t live) noexcept;
int clipCount() noexcept;
struct ClipInfo {
    float key;
    uint32_t first, frames;
    float scale;  // the clip's peak over its recording's steady tone RMS
};
ClipInfo clipInfo(int clip) noexcept;
// The measured steady wind noise against the tone (dB) and a single pipe's wander (cents, dB; standard deviations).
double noiseDb() noexcept;
double wanderCents() noexcept;
double wanderDb() noexcept;

// The registrations (combinations, one tap): each stop's level, row 0 the knobs themselves. **[Assumption]** no
// source gives the Tabernacle organists' own registrations; these follow the research's proposal (section 6): BYU
// OrganTutor's "the PRINCIPAL CHORUS should form the basis for registration in congregational singing" and
// Harrison's ensemble of many mild ranks, with the Tuba "to sing out above the choir or the organ".
inline constexpr int kRegistrations = 9;
struct Drawn {
    Stop stop;
    float level;
};
struct Registration {
    float level[kStops] = {};
    constexpr Registration() = default;
    constexpr Registration(std::initializer_list<Drawn> on) {
        for (const Drawn& d : on) level[d.stop] = d.level;
    }
};
inline constexpr Registration kRegistration[kRegistrations] = {
    {},  // the stops as drawn
    // Soft accompaniment: the Swell's Gedeckt and Viole Céleste, the Choir's Kleine Erzähler, the Pedal's Bourdon.
    {{kGedeckt8, 0.8f}, {kViole8, 0.7f}, {kErzahler8, 0.8f}, {kBourdon16, 0.7f}},
    // Hymn plenum: the Great's principal chorus with its Fourniture, the Swell's Geigen and Plein Jeu coupled, the
    // Pedal's principals and Bourdon.
    {{kPrincipal8, 1}, {kOctave4, 0.9f}, {kSuperOctave2, 0.8f}, {kFourniture, 0.7f}, {kGeigen8, 0.8f}, {kPleinJeu, 0.6f},
     {kPedPrincipal16, 0.8f}, {kPedOctave8, 0.7f}, {kBourdon16, 0.7f}},
    // Hymn with reeds: the plenum with the Swell's Trompette, the Great's Trumpet and the Pedal's Trombone.
    {{kPrincipal8, 1}, {kOctave4, 0.9f}, {kSuperOctave2, 0.8f}, {kFourniture, 0.7f}, {kGeigen8, 0.8f}, {kPleinJeu, 0.6f},
     {kTrompette8, 0.8f}, {kTrumpet8, 0.8f}, {kPedPrincipal16, 0.8f}, {kPedOctave8, 0.7f}, {kBourdon16, 0.7f},
     {kTrombone16, 0.8f}},
    // Full organ: everything but the celestes, the Erzähler, the solo reeds and the Tuba, with both 32's.
    {{kSubprincipal16, 0.8f}, {kPrincipal8, 1}, {kFluteHarm8, 0.7f}, {kOctave4, 1}, {kSuperOctave2, 0.9f},
     {kFourniture, 0.9f}, {kTrumpet8, 0.9f}, {kGeigen8, 0.9f}, {kGedeckt8, 0.6f}, {kTraverso4, 0.6f}, {kPleinJeu, 0.8f},
     {kTrompette8, 0.9f}, {kConcertFlute8, 0.6f}, {kContreBourdon32, 0.9f}, {kPedPrincipal16, 1}, {kBourdon16, 0.8f},
     {kPedOctave8, 0.8f}, {kTrombone16, 0.9f}, {kBombarde32, 0.8f}},
    // Tuba over full: the full organ with the Antiphonal's Tuba Mirabilis on top.
    {{kSubprincipal16, 0.8f}, {kPrincipal8, 1}, {kFluteHarm8, 0.7f}, {kOctave4, 1}, {kSuperOctave2, 0.9f},
     {kFourniture, 0.9f}, {kTrumpet8, 0.9f}, {kGeigen8, 0.9f}, {kGedeckt8, 0.6f}, {kTraverso4, 0.6f}, {kPleinJeu, 0.8f},
     {kTrompette8, 0.9f}, {kConcertFlute8, 0.6f}, {kTuba8, 1}, {kContreBourdon32, 0.9f}, {kPedPrincipal16, 1},
     {kBourdon16, 0.8f}, {kPedOctave8, 0.8f}, {kTrombone16, 0.9f}, {kBombarde32, 0.8f}},
    // Harmonic flute solo: the Great's Flûte Harmonique over the Swell's Viole Céleste, the Pedal's Bourdon.
    {{kFluteHarm8, 1}, {kViole8, 0.6f}, {kBourdon16, 0.6f}},
    // Reed solo: the Choir's Krummhorn over the Swell's Gedeckt and Flauto Traverso, the Pedal's Bourdon.
    {{kKrummhorn8, 1}, {kGedeckt8, 0.6f}, {kTraverso4, 0.5f}, {kBourdon16, 0.6f}},
    // Celestes: the Swell's Viole Céleste and the Choir's Kleine Erzähler, the
    // Pedal's Bourdon (with the Tremulant, the Swell's and the Choir's shimmer).
    {{kViole8, 0.9f}, {kErzahler8, 0.9f}, {kBourdon16, 0.6f}},
};

// A noise from a seed (the speech, the wind and each pipe's own tuning): a linear-congruential generator, -1..1.
struct Rng {
    uint32_t s = 1;
    float next() noexcept {
        s = s * 1664525u + 1013904223u;
        return static_cast<float>(static_cast<int32_t>(s)) * (1.0f / 2147483648.0f);
    }
};

// The pipe organ (the owner, 2026-11-24: "a giant cathedral organ ... a bunch of flutes and mock brass instruments
// linked together in a big room"; 2026-11-25: "the organ sounds like a synth and not the organ, and half of the
// things that should be together are separate"). Original code. A pipe's steady tone barely changes, so each rank is
// a table oscillator; what made 1.1.3-alpha.1 sound like a synth was everything else (docs/engine.md, "Bittern"):
// - the spectra are measured (VCSL's organ, CC0): the stopped flutes (Bourdon, Rohrflöte, Subbass) from its quiet
//   manual, the open flutes (Flute 4', Nazard, Tierce) from its quiet pedal, the principals and the mixture from its
//   chorus; the Gamba, Céleste and Trumpet keep **[Assumption]** formula spectra (nothing recorded);
// - every pipe speaks on its own: its level rises in the measured time for its pitch (small pipes first, so a chorus
//   builds from the top as the recording does) and its spectrum moves from the measured speaking one to the steady
//   one; it starts a few cents off and settles; with it plays the recording's own speech (what the recording holds
//   over its harmonics' envelopes in its first 400 ms: the chiff and the wind's rush);
// - every pipe is its own: a fixed tuning error (the chorus' measured beating), its own slow wander of pitch and
//   level (measured), and the steady wind noise (measured level) while it sounds;
// - one wind: a reservoir that sags under the pipes drawing on it (a big chord flattens and softens everything a
//   little, with a small bounce), the living wind's sway and the tremulant, shared by every pipe, so the ranks move
//   as one instrument; the swell box and the room (on by default) after them.
struct Organ {
    static constexpr uint32_t kEcoCap = 12, kNormalCap = 16, kHighCap = 24, kPool = kHighCap + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = false;
    static constexpr double kMinLife = 0.05, kSpread = 0.5;
    // Stop levels (kStops), then Tremulant, Wind, Chiff, Tremulant rate, Registration, Pedal.
    static constexpr uint32_t kTrem = kStops, kWind = kStops + 1, kChiff = kStops + 2, kTremRate = kStops + 3,
                              kReg = kStops + 4, kPedalMode = kStops + 5, kSwellKnob = kStops + 6,
                              kWeight = kStops + 7, kChimes = kStops + 8, kSpreadKnob = kStops + 9;
    static constexpr uint32_t kModelParams = kStops + 10;
    // The Chimes (tubular bells, as an organ's Chimes stop): the modes over the struck note, measured on VCSL's
    // chimes (Woodpecker's: 0.63, 1.22, 2.00, 2.92, 3.98, 5.1, 6.5), each one's level and ring ([Assumption] chosen:
    // the 2.00 the strongest, the lowest and highest softer), sounding from G3 to G5 (MIDI 55-79, a Deagan set's 25).
    static constexpr int kChimeModes = 7;
    static constexpr double kChimeLow = 55, kChimeHigh = 79;
    static constexpr int kPlayers = 4;  // recorded speech clips per note: one per recorded registration
    static constexpr int kBreathBands = 4;
    static constexpr float kBreathDamp = 0.25f;  // the breath's band-passes: Q 4
    static constexpr float kOut = 0.12f;  // a rank at level 1 (its table's peak 1)

    // A recorded speech clip playing.
    struct Player {
        const float* data = nullptr;
        uint32_t frames = 0;
        uint64_t pos = 0, step = 1ull << 32;  // frames in 32.32 fixed point (exact at any block size, and cheap)
        float gain = 0;
    };

    struct Voice : VoiceBase {
        uint32_t phase[kRanks] = {};  // each pipe's phase, a full cycle 2^32 (exact at any block size, and cheap)
        uint32_t step[kRanks] = {};   // its step a sample this control block (pitch, tuning, wander, the wind)
        double inc[kRanks] = {};      // its step at its tuned pitch
        const float* steady[kRanks] = {};
        const float* speaking[kRanks] = {};
        uint32_t shift[kRanks] = {};  // 32 less its tables' bits: the phase's top bits index them
        float rms[kRanks] = {};
        // Each pipe is worked out every other control block (half of them each block, by the parity of their
        // index) and runs on lines from then (lineAt, on the voice's clock of samples) until the next time: so no
        // sample's level depends on the last one's and any block size gives the same bits.
        // Its speech and release (0..1; the pipe sounds env^2): a one-pole, env at the line's start, envStep a sample.
        float env[kRanks] = {}, envStep[kRanks] = {};
        uint32_t lineAt[kRanks] = {};
        uint32_t clock = 0;
        float drawOf[kRanks] = {}, toneOf[kRanks] = {};  // its last share of the wind's draw and of the breath
        // How far it has spoken (the spectrum, speaking 0 to steady 1), on its line.
        float spoke[kRanks] = {}, spokeStep[kRanks] = {};
        float rise[kRanks] = {};     // its one-pole's decay over a control block while it speaks
        // Its level (the stop, its wander, the wind): eased toward the knob (about 5 ms), on its line.
        float gain[kRanks] = {}, gStep[kRanks] = {};
        float envAt(int k) const noexcept { return env[k] + envStep[k] * static_cast<float>(clock - lineAt[k]); }
        float gainAt(int k) const noexcept { return gain[k] + gStep[k] * static_cast<float>(clock - lineAt[k]); }
        float spokeAt(int k) const noexcept { return spoke[k] + spokeStep[k] * static_cast<float>(clock - lineAt[k]); }
        float tuning[kRanks] = {};   // its fixed tuning error (cents)
        float voiced[kRanks] = {};   // its fixed level as voiced (a factor near 1) and speed of speech (likewise)
        float voicedRise[kRanks] = {};
        float strikeRise[kRanks] = {};  // this strike's own speed of speech (a factor near 1)
        float settle[kRanks] = {}, settleK[kRanks] = {};  // its speech's pitch error (cents) and its decay a block
        float wPitch[kRanks] = {}, wPitchTo[kRanks] = {}, wLevel[kRanks] = {}, wLevelTo[kRanks] = {};
        float relK = 0;              // the release's one-pole coefficient a sample (the recorded speech's)
        float relD = 0;              // and over a control block (the pipes')
        double relFor = -1;          // the Release it was worked out for
        bool on[kRanks] = {};        // the pipe's valve open (key held and stop drawn)
        Player players[kPlayers];
        int playersOn = 0;
        float speech = 1;  // the recorded speech's level: it stops with the pipes when the key is let go
        float inFade = 1, inStep = 0;  // a key struck again: this voice fades in as the frame fades the old one out
        // The breath: a noise through band-passes at the key's 2nd, 3rd, 4th and 6th harmonics (state-variable, Q 4),
        // its level the sounding pipes' (smoothed), plus the puffs of the valve opening a reed and of it closing.
        float nLp[kBreathBands] = {}, nBp[kBreathBands] = {}, nF[kBreathBands] = {}, nW[kBreathBands] = {};
        float nGain = 0, nGainTo = 0, puff = 0, puffK = 0;
        int bands = 2;  // the breath's bands this note (by the quality tier)
        // Body: the pipes' scale, a one-pole low-pass at 2.5 times the key's pitch mixed in (wider, rounder) or out
        // (narrower, brighter).
        float bodyLp = 0, bodyK = 0.1f;
        float boxLp = 0;  // the enclosed divisions' swell box, a one-pole low-pass (Organ::swellK)
        float chC[kChimeModes] = {}, chS[kChimeModes] = {}, chZr[kChimeModes] = {}, chZi[kChimeModes] = {};
        bool chimeOn = false;
        float vibOffset = 0;  // the orchestral strings' vibrato: this note's own phase (cycles)
        uint32_t tick = 0;  // control blocks since the note started (each pipe's pitch is worked out every other one)
        float strikeLevel[kRanks] = {};  // this strike's own level error (a fraction)
        Rng rng, noise;
        double tunedPitch = -1;
    };

    double sr = 48000;
    float level[kRanks] = {};
    float knob[kRanks] = {};
    bool pedalEvery = false;  // the Pedal choice: Every key (else the lowest key held)
    double swellKnob = 1, weightFor = -1, vibPhase = 0;
    float chimes = 0;
    double spread = 0.6;  // Spread: how far the pipes stand apart across the case
    timber::Biquad floorL, floorR;  // Weight's low shelf
    uint32_t floorFill = 0;
    int pedalKey = -1;        // the lowest key held this block (-1 none)
    int registration = 0;
    double trem = 0, wind = 0.3, chiffAmt = 0.5, tremRate = 6.0, modWheel = 0;
    // The wind (shared by every pipe): its sway (a smoothed random walk), the tremulant's phase and the reservoir's
    // sag under the pipes' draw (a damped spring), per control block.
    double sway = 0, swayTarget = 0, tremPhase = 0, sag = 0, sagVel = 0, draw = 0, drawNext = 0;
    // The wind's pitch and level for the open divisions [0] and the enclosed ones [1] (their tremulant).
    float pitchMod[2] = {1, 1}, levelMod[2] = {1, 1};
    Rng windRng;
    uint32_t notes = 0;  // notes started since the last reset (each note's phases)
    // The swell boxes (the Swell's and the Choir's, moved together by the mod wheel): each voice's one-pole
    // low-pass coefficient and the gain, eased per control block toward the wheel's.
    float swellK = 1, swellG = 1, swellKTo = 1, swellGTo = 1;
    float gainK = 0.004f;   // the breath's level eased over about 5 ms a sample (prepare())
    // The quality tier's share of the work (control()): Normal crossfades a pipe's speaking spectrum into its steady
    // one by the time it reaches 0.75 of its level (High 0.97), plays 1 of a note's recorded speech clips (High 4,
    // Eco none) and its breath in one band (High 4).
    float speakEnd = 0.75f;
    int tierBands = 2, maxPlayers = 2;
    float body = 0;  // Body as -1 (narrow scale, brighter) .. 1 (wide, rounder), 0 at Body 0.5: as measured
    float blockK = 0.12f;   // a pipe's level eased over about 5 ms, two control blocks at a time (prepare())
    float noiseGain = 0;    // the breath against the pipes' tone (prepare(), from kNoiseDb)
    std::shared_ptr<const recorded::Bank> bank;
    uint64_t clipLive = 0;  // the speech clips that hold sound (prepare())
    Voice* voices = nullptr;
    uint32_t count = 0;
    bool testMuteSpeech = false;  // the tests' A/B (never used for sound)

    size_t allocBytes() const noexcept { return 0; }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        // The Tabernacle: [Fact] T30 3.83 s empty (Rollins 2005), about 3 s occupied, shorter up high (its ceiling
        // and the air); [Assumption] the reverb's decay and damping set to that: a long, warm, slightly dark tail.
        r.size = 1.0, r.decay = 3.8, r.damping = 0.55, r.mix = 1.0, r.width = 1.3, r.preDelay = 0.04, r.modulation = 0.3;
        return r;
    }
    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        sr = rate;
        voices = v, count = n;
        gainK = static_cast<float>(1.0 - detExp(-1.0 / (0.005 * sr)));
        noiseGain = static_cast<float>(kOut * detPow(10.0, noiseDb() / 20.0));
        blockK = static_cast<float>(1.0 - detExp(-2.0 * kControlFrames / (0.005 * sr)));  // over two blocks
        for (int k = 0; k < kRanks; ++k)
            pipeDraw[k] = kFamilyOf[k] == kMixtureFamily ? 1.2f : static_cast<float>(std::sqrt(1.0 / kFoot[k]));
        buildTables();
        if (!bank) bank = recorded::acquire(recorded::BankId::Bittern);
        // [Measured] some of the recorded speech clips are silent (bittern_assets.py found no speech over the
        // harmonics there): marked once here, off the audio thread, so a note never plays one in place of a real one.
        clipLive = 0;
        for (int c = 0; bank && c < clipCount() && c < 64; ++c) {
            const ClipInfo ci = clipInfo(c);
            if (static_cast<uint64_t>(ci.first) + ci.frames > bank->frames) continue;
            double e = 0;
            for (uint32_t i = 0; i < ci.frames; ++i) e += std::fabs(bank->pcm[ci.first + i]);
            if (e > 1e-3 * ci.frames * 1e-3) clipLive |= 1ull << c;
        }
        reset();
        return true;
    }
    void reset() noexcept {
        sway = swayTarget = tremPhase = sag = sagVel = draw = drawNext = 0;
        pitchMod[0] = pitchMod[1] = levelMod[0] = levelMod[1] = 1;
        swellK = swellKTo, swellG = swellGTo;
        windRng.s = 0x0B177E2Du;
        notes = 0;
    }
    // 2^(c / 1200) for a few tens of cents: its Taylor series to x^3 (within 1e-6 of the exponential to 50 cents),
    // so each pipe's pitch each control block costs a few multiplies.
    static double cents(double c) noexcept {
        const double x = c * 5.776226504666211e-4;
        return 1.0 + x * (1.0 + x * (0.5 + x * (1.0 / 6.0)));
    }

    void control(const double* p, const Shared& s) noexcept {
        registration = static_cast<int>(clampd(p[kReg], 0, kRegistrations - 1) + 0.5);
        for (int k = 0; k < kStops; ++k) {
            knob[k] = static_cast<float>(clampd(p[k], 0, 1));
            level[k] = registration == 0 ? knob[k] : kRegistration[registration].level[k];
        }
        for (int k = kStops; k < kRanks; ++k) knob[k] = knob[stopOf(k)], level[k] = level[stopOf(k)];
        // The pedal (one keyboard plays the manuals and the pedal): its stops sound on the lowest key held, as a
        // pedal line under the hands, or on every key; either way within the pedal's compass.
        pedalEvery = p[kPedalMode] >= 0.5;
        swellKnob = clampd(p[kSwellKnob], 0, 1);
        chimes = static_cast<float>(clampd(p[kChimes], 0, 1));
        spread = clampd(p[kSpreadKnob], 0, 1);
        const double wt = clampd(p[kWeight], 0, 1);
        if (wt != weightFor) {  // the floor: a low shelf at 110 Hz, +12 dB at 1 (only when the knob moves)
            weightFor = wt;
            floorL.lowShelf(110.0, 0.707, 12.0 * wt, sr), floorR.lowShelf(110.0, 0.707, 12.0 * wt, sr);
        }
        pedalKey = -1;
        for (uint32_t i = 0; i < count; ++i) {
            const Voice& o = voices[i];
            if (o.active && o.held && !o.fading && (pedalKey < 0 || o.key < pedalKey)) pedalKey = o.key;
        }
        trem = clampd(p[kTrem], 0, 1);
        wind = clampd(p[kWind], 0, 1);
        speakEnd = s.quality == kQualityHigh ? 0.97f : s.quality == kQualityEco ? 0.5f : 0.75f;
        tierBands = s.quality == kQualityHigh ? 4 : 1;
        maxPlayers = s.quality == kQualityHigh ? kPlayers : s.quality == kQualityEco ? 0 : 1;
        body = static_cast<float>(2.0 * clampd(s.body, 0, 1) - 1.0);
        chiffAmt = clampd(p[kChiff], 0, 1);
        tremRate = clampd(p[kTremRate], 2, 9);
        modWheel = s.modWheel;
        const double dt = kControlFrames / sr;
        // The living wind: a new sway target now and then (about 0.4 Hz), approached smoothly; the tremulant a sine.
        if (windRng.next() > 1.0f - static_cast<float>(2.0 * 0.4 * dt)) swayTarget = windRng.next();
        sway += (swayTarget - sway) * std::min(1.0, dt * 2.0);
        tremPhase += tremRate * dt;
        tremPhase -= std::floor(tremPhase);
        vibPhase += 5.5 * dt;  // the orchestral strings' vibrato, 5.5 Hz
        vibPhase -= std::floor(vibPhase);
        const double t = lib::fastSinCycles(tremPhase);
        // The reservoir: what the sounding pipes draw (each pipe's level, a big pipe more: the square root of its
        // length), the sag toward draw / (draw + 24) through a spring of 3 Hz damped at 0.35 (a big chord sags and
        // bounces a little). [Assumption] chosen, not measured (the recordings hold single notes): full sag is 5
        // cents flat and 0.9 dB softer; ten keys of the full organ sag about two thirds of that.
        // (The draw is summed by each voice's voiceControl over the last block: drawNext.)
        const double d = drawNext;
        drawNext = 0;
        draw = d;
        const double target = d / (d + 24.0), w = timber::kTwoPi * 3.0;
        sagVel += ((target - sag) * w * w - 2.0 * 0.35 * w * sagVel) * dt;
        sag += sagVel * dt;
        // The living wind: its sway up to 8 cents and 12 % at Living wind 1, and the reservoir's give (its sag's
        // depth) from 0.4 at 0 (a steady blower) through 1 at 0.3 to 2.4 at 1. The tremulant (a real one's 5-7 Hz,
        // 6 by default): up to 5 cents and 20 % (3.5 dB from trough to crest) at Tremulant 1.
        const double give = 0.4 + 2.0 * wind;
        // The tremulant shakes the enclosed divisions' wind only (the Swell's and the Choir's, as on the real organ).
        for (int e = 0; e < 2; ++e) {
            const double tr = e ? t * trem : 0.0;
            pitchMod[e] = static_cast<float>(cents(sway * 8.0 * wind + tr * 5.0 - 5.0 * give * sag));
            levelMod[e] = static_cast<float>((1.0 + sway * 0.12 * wind + tr * 0.2) * (1.0 - 0.1 * give * sag));
        }
        // The swell box: the mod wheel closes it (darker, quieter), open at 0.
        // The Swell knob (open at 1, automatable) and the mod wheel (closing from it) together.
        const double box = clampd(modWheel + (1.0 - swellKnob), 0, 1);
        swellKTo = box < 1e-3 ? 1.0f : static_cast<float>(1.0 - detExp(-timber::kTwoPi * (12000.0 * detPow(0.08, box)) / sr));
        swellGTo = static_cast<float>(1.0 - 0.6 * box);
        // The box's shutters move, they do not jump: eased over about 10 ms (each pipe's level eases on to it).
        const float ease = static_cast<float>(1.0 - detExp(-dt / 0.01));
        swellK += (swellKTo - swellK) * ease;
        swellG += (swellGTo - swellG) * ease;
    }
    // A big pipe draws more wind: the square root of its length against the 8'.
    // A big pipe draws more wind: the square root of its length against the 8' (a mixture's four small ranks 1.2).
    float pipeDraw[kRanks] = {};
    // A rank's level at its knob, voiced, and through its box (the wind's sway and the tremulant ride on it).
    float pipeLevel(int k) const noexcept { return level[k] * kVoicing[k] * (enclosed(kDivisionOf[k]) ? swellG : 1.0f); }

    // Whether rank k speaks on voice v: a pedal stop on the lowest key held (or every key) within the pedal's
    // compass; every other stop on every key.
    bool speaks(const Voice& v, int k) const noexcept {
        if (kDivisionOf[k] != kPedal) return true;
        return (pedalEvery || v.key == pedalKey) && v.pitch >= kPedalLow - 0.5 && v.pitch <= kPedalHigh + 0.5;
    }
    void tune(Voice& v) noexcept {
        const double pitch = clampd(v.pitch, 12.0, 120.0), hz = timber::noteHz(pitch);
        const int zMix = zoneOf(pitch);
        for (int k = 0; k < kRanks; ++k) {
            const int fam = kFamilyOf[k];
            const int z = fam == kMixtureFamily ? zMix : zoneOf(pitch + 12.0 * std::log2(kFoot[k]));
            v.inc[k] = hz * kFoot[k] / sr * 4294967296.0;
            v.steady[k] = steadyTable(fam, z), v.speaking[k] = speakingTable(fam, z);
            v.shift[k] = static_cast<uint32_t>(32 - tableBits(z));
            v.rms[k] = tableRms(fam, z);
        }
        v.tunedPitch = v.pitch;
    }
    // Each pipe's rise: the measured time to half level for its pitch (bittern_bank.inc), the reed's 12 ms and the
    // strings' 1.5 times a principal's ([Assumption]: neither was recorded). The pipe sounds env^2, a one-pole's
    // square, at half level when env is 0.707, 1.23 time constants in.
    void setRise(Voice& v, int k) const noexcept {
        const double hz = timber::noteHz(clampd(v.pitch, 12.0, 120.0)) * kFoot[k];
        double t50 = isReed(kFamilyOf[k]) ? 0.012 : riseSeconds(std::max(hz, 20.0));
        if (isString(kFamilyOf[k])) t50 *= 1.5;
        // [Assumption] a tracker action: a key struck faster opens its pallet faster, so the pipe speaks a little
        // sooner (and with more of its speech: startSpeech); as measured at the frame's velocity 0.75.
        const double vel = 1.6 - 0.8 * clampd(v.velocity, 0, 1);
        const double tau = std::max(0.004, t50 * vel * v.strikeRise[k] * v.voicedRise[k] / 1.23);
        v.rise[k] = static_cast<float>(detExp(-static_cast<double>(kControlFrames) / (tau * sr)));
        v.settleK[k] = static_cast<float>(detExp(-static_cast<double>(kControlFrames) / (tau * sr)));
    }
    // A pipe opening: it speaks from rest (or from what it still sounds), a few cents off, and no two strikes alike
    // (each from the voice's seeded generator: the same notes give the same sound). [Assumption] the speech's pitch
    // error is uniform within 6 cents, settling as it rises (the recordings' first 50 ms scatter by about that much,
    // too short to measure a direction); each strike's speech 20 % faster or slower and its level within 0.3 dB.
    // A reed's tongue starts flat (10-15 cents, settling in its 12 ms) and its valve's puff is heard ([Assumption]:
    // no reed was recorded).
    void open(Voice& v, int k) noexcept {
        v.on[k] = true;
        if (v.envAt(k) < 0.05f) v.spoke[k] = v.spokeStep[k] = 0;
        v.strikeRise[k] = 1.0f + 0.2f * v.rng.next();
        v.strikeLevel[k] = 0.035f * v.rng.next();
        setRise(v, k);
        v.settle[k] = 6.0f * v.rng.next() * (1.0f - v.env[k]);
        if (isReed(kFamilyOf[k])) {
            v.settle[k] = -(12.5f + 2.5f * v.rng.next()) * (1.0f - v.env[k]);
            v.puff += static_cast<float>(pipeLevel(k) * v.rms[k] * kOut * 0.02 * chiffAmt / 0.5) * (1.0f - v.env[k]);
        }
        v.gain[k] = pipeLevel(k) * v.voiced[k], v.gStep[k] = 0;
    }
    void start(Voice& v, const Shared& s) noexcept {
        v.rng.s = 0xB177E2Du + 977u * v.key + 7919u * notes;
        ++notes;
        if (pedalKey < 0 || v.key < pedalKey) pedalKey = v.key;  // a new lowest key takes the pedal this block
        // A key struck again while its pipes still sound (the frame fades that voice over 5 ms): carry its pipes on in
        // the same phase and level, so the two are one sound and the valve's reopening is all that is heard.
        const Voice* was = nullptr;
        for (uint32_t i = 0; i < count; ++i) {
            const Voice& o = voices[i];
            if (&o != &v && o.active && o.fading && o.key == v.key && (!was || o.fade > was->fade)) was = &o;
        }
        Rng pipe;  // each pipe's own fixed tuning (the same pipe plays every time its key is struck)
        pipe.s = 0x9E3779B9u + 131u * v.key;
        for (int k = 0; k < kRanks; ++k) {
            // [Measured] the chorus' ranks beat at a median 4.4 cents (VCSL's Loud: 0.4-4 Hz on partials of 0.2-2 kHz):
            // each pipe's tuning a triangular error of +-11 cents (standard deviation 4.6), so two pipes of a key
            // differ by a median of 4.4 cents, narrowing as the square root of the pipe's pitch over 500 Hz (the
            // recording's small pipes sit within its harmonics' 20 Hz: its residual stays 33-40 dB under the tone up
            // to C7, where 4.6 cents would put the 2' at -18 dB); the céleste 6 cents sharp on top.
            const double pipeHz = timber::noteHz(clampd(v.pitch, 12.0, 120.0)) * kFoot[k] * (kFamilyOf[k] == kMixtureFamily ? 4.0 : 1.0);
            const float narrow = static_cast<float>(std::min(1.0, std::sqrt(500.0 / pipeHz)));
            v.tuning[k] = kCelesteCents[k] + 5.6f * narrow * (pipe.next() + pipe.next());
            // [Assumption] no two pipes of a rank voiced alike (a voicer evens a rank by ear, pipe by pipe, to within
            // about a decibel; each mouth speaks a little sooner or later): each its own level within 1.2 dB
            // (triangular) and speed of speech within 15 %, fixed for the key, after the tuning (whose draws stay).
            v.voiced[k] = 1.0f + 0.075f * (pipe.next() + pipe.next());
            v.voicedRise[k] = 1.0f + 0.15f * pipe.next();
            v.strikeRise[k] = 1.0f, v.strikeLevel[k] = 0;
            if (was) {
                v.phase[k] = was->phase[k], v.env[k] = was->envAt(k), v.spoke[k] = was->spokeAt(k);
                v.gain[k] = was->gainAt(k), v.wPitch[k] = was->wPitch[k], v.wLevel[k] = was->wLevel[k];
            } else {
                v.phase[k] = static_cast<uint32_t>((0.5 + 0.5 * v.rng.next()) * 4294967295.0);
                v.env[k] = v.spoke[k] = 0;
                v.gain[k] = pipeLevel(k) * v.voiced[k];
                v.wPitch[k] = v.rng.next(), v.wLevel[k] = v.rng.next();
            }
            v.wPitchTo[k] = v.wPitch[k], v.wLevelTo[k] = v.wLevel[k];
            v.envStep[k] = v.spokeStep[k] = v.gStep[k] = 0, v.lineAt[k] = 0;
            v.drawOf[k] = v.toneOf[k] = 0;
            v.on[k] = false;
            v.settle[k] = 0;
        }
        for (int b = 0; b < kBreathBands; ++b) {
            v.nLp[b] = was ? was->nLp[b] : 0.0f;
            v.nBp[b] = was ? was->nBp[b] : 0.0f;
        }
        v.nGain = was ? was->nGain : 0.0f;
        v.puff = 0;
        v.puffK = static_cast<float>(detExp(-1.0 / (0.025 * sr)));
        v.noise.s = 0x5EEDu + 131u * v.key + 31u * notes;
        tune(v);
        for (int k = 0; k < kRanks; ++k)
            if (level[k] > 0.0f && speaks(v, k)) open(v, k);
        v.relFor = -1;
        // The breath's bands, at the key's harmonics ([Measured] the residual's centroid sits about 4 times the 8'
        // pitch: 3.5-6x, 400 Hz in the bass to 7.4 kHz at C7): High the 2nd, 3rd, 4th and 6th, Normal and Eco the
        // 4th; each scaled to unit RMS for a uniform noise (a band-pass of Q 1/d passes pi fc / (3 sr d) of its
        // power), summed in power to one; a band past 0.15 of the rate is left out.
        static constexpr double kBands[2][kBreathBands] = {{4, 0, 0, 0}, {2, 3, 4, 6}};
        v.bands = tierBands;
        const double* band = kBands[tierBands == 4 ? 1 : 0];
        const double f8 = timber::noteHz(clampd(v.pitch, 12.0, 120.0));
        for (int b = 0; b < kBreathBands; ++b) {
            const double fc = std::max(120.0, f8 * band[b]);
            const bool ok = b < v.bands && fc < 0.15 * sr;
            v.nF[b] = ok ? static_cast<float>(2.0 * std::sin(timber::kPi * fc / sr)) : 0.0f;
            v.nW[b] = ok ? static_cast<float>(1.0 / std::sqrt(v.bands * timber::kPi * fc / (3.0 * sr * kBreathDamp))) : 0.0f;
        }
        v.bodyK = static_cast<float>(1.0 - detExp(-timber::kTwoPi * std::min(2.5 * f8, 0.2 * sr) / sr));
        v.bodyLp = was ? was->bodyLp : 0.0f;
        v.boxLp = was ? was->boxLp : 0.0f;
        v.speech = 1;
        v.tick = 0, v.clock = 0;
        // The frame fades the old voice out over 5 ms (a step of 1 / max(1, 0.005 sr) a sample); this one comes in by
        // the same steps, so the two (the same pipes in the same phase) always sum to one.
        v.inFade = was ? 0.0f : 1.0f;
        v.inStep = static_cast<float>(1.0 / std::max(1.0, 0.005 * sr));
        startSpeech(v, was ? was->env : nullptr);
        place(v);
        v.vibOffset = 0.5f + 0.5f * v.rng.next();
        strikeChimes(v);
        voiceControl(v, s);
    }
    // The recorded speech: for each flue stop drawn, its family's recording nearest the key (within 2 semitones; the
    // clip is played at the ratio to the key), at the stop's level, summed where stops share a clip (so a note plays
    // at most one clip per family: the chorus' recording holds its octaves and mixture already).
    void startSpeech(Voice& v, const float* still) noexcept {
        v.playersOn = 0;
        if (!bank || testMuteSpeech || chiffAmt <= 0 || maxPlayers == 0) return;
        // Chiff 0.5: as recorded; 0 none, 1 four times (+12 dB); a key struck hard more, softly less.
        const float amount = static_cast<float>(chiffAmt / 0.5 * chiffAmt / 0.5 * (0.2 + 1.07 * clampd(v.velocity, 0, 1)));
        for (int k = 0; k < kRanks; ++k) {
            if (level[k] <= 0.0f || !speaks(v, k)) continue;
            const int fam = kFamilyOf[k];
            if (isReed(fam)) continue;
            // Each family's recording: the stopped flutes the quiet manual, the open flutes the quiet pedal (the quiet
            // manual past its range), the principals, mixture and strings the chorus, the 32' the loud pedal.
            const double at = clampd(v.pitch, 12.0, 120.0);
            int group = fam == kStopped ? 0 : fam == kOpen || fam == kHarmonicFlute ? 2 : 1;
            if (kDivisionOf[k] == kPedal) group = 3;
            int c = nearestClip(group, at, 2.0, clipLive);
            if (c < 0 && group == 2) c = nearestClip(0, at, 2.0, clipLive);
            if (c < 0 && group == 3) c = nearestClip(1, at, 2.0, clipLive);  // the pedal's flues: the chorus'
            if (c < 0) continue;
            const ClipInfo ci = clipInfo(c);
            if (static_cast<uint64_t>(ci.first) + ci.frames > bank->frames) continue;
            // The clip in the rank's own units: its peak over its tone's RMS, times this rank's RMS at its level. The
            // chorus' recording sounds three ranks (and the mixture's), so each principal takes a third of it in
            // power; the strings a quarter of it ([Assumption]: a string's speech is like a principal's).
            const double share = fam == kPrincipal || fam == kGeigen || fam == kMixtureFamily ? 0.577 : isString(fam) ? 0.5 : 1.0;
            const float since = still ? 1.0f - still[k] : 1.0f;  // a pipe still sounding speaks less again
            const float g = static_cast<float>(pipeLevel(k) * v.rms[k] * kOut * ci.scale * share) * amount * since;
            if (g <= 1e-7f) continue;
            const double ratio = detPow(2.0, (at - ci.key) / 12.0);
            Player* p = nullptr;
            for (int i = 0; i < v.playersOn; ++i)
                if (v.players[i].data == bank->pcm.get() + ci.first) p = &v.players[i];
            if (!p) {
                if (v.playersOn == maxPlayers) {  // full: replace the quietest if this one is louder
                    Player* q = &v.players[0];
                    for (int i = 1; i < maxPlayers; ++i)
                        if (v.players[i].gain < q->gain) q = &v.players[i];
                    if (q->gain >= g) continue;
                    p = q;
                } else {
                    p = &v.players[v.playersOn++];
                }
                *p = Player{};
                p->data = bank->pcm.get() + ci.first;
                p->frames = ci.frames;
                p->step = static_cast<uint64_t>(ratio * bank->rate / sr * 4294967296.0);
            }
            p->gain += g;
        }
    }
    // [Measured] a pipe's own release: -20 dB in 35-45 ms where the room is weakest (VCSL's single notes), so the
    // default Release (0.12 s) is its T60. The pipe sounds env^2: env's time constant is T60 / 3.45 (voiceControl).
    // The valve closing puffs: [Assumption] a breath burst at the speech's measured level (28 dB under the tone, at
    // Chiff 0.5), 25 ms long.
    // Spread (2026-11-25, the owner: "places the different pipes around the room"): a note's pipes stand where an
    // organ's case puts them, the chromatic layout: the C side (C, D, E, F#, G#, A#) to the left, the C# side to the
    // right, each side's big bass pipes in its outer tower and the treble toward the middle (a key's place: 0.3 of the
    // way out at C6 and up, all the way at C2 and down). Spread 0 all in the middle; the pan keeps its power.
    void place(Voice& v) const noexcept {
        const int pc = static_cast<int>(v.key) % 12;
        const double side = pc % 2 == 0 ? -1.0 : 1.0;
        const double out = 0.3 + 0.7 * clampd((84.0 - v.pitch) / 48.0, 0, 1);
        const double pan = clampd(spread * side * out, -1, 1);
        v.panL = static_cast<float>(std::cos((pan + 1.0) * 0.25 * timber::kPi));
        v.panR = static_cast<float>(std::sin((pan + 1.0) * 0.25 * timber::kPi));
    }
    // The Chimes' modes at their rings (seconds to -60 dB, the struck mode's `t60`, the others in proportion).
    void setChimes(Voice& v, double t60) const noexcept {
        static constexpr double kRatio[kChimeModes] = {0.63, 1.22, 2.00, 2.92, 3.98, 5.1, 6.5};
        static constexpr double kRing[kChimeModes] = {0.5, 0.7, 1.0, 0.85, 0.7, 0.55, 0.45};
        const double f = timber::noteHz(clampd(v.pitch, kChimeLow - 12, kChimeHigh + 12));
        for (int m = 0; m < kChimeModes; ++m) {
            const double hz = f * kRatio[m];
            const double r = hz < 0.45 * sr ? detExp(-6.907755278982137 / (t60 * kRing[m] * sr)) : 0.0, w = timber::kTwoPi * hz / sr;
            v.chC[m] = static_cast<float>(r * detCos(w)), v.chS[m] = static_cast<float>(r * detSin(w));
        }
    }
    // A key of the Chimes' compass struck: its modes from rest (a struck tube), louder for a harder key.
    void strikeChimes(Voice& v) noexcept {
        v.chimeOn = false;
        for (int m = 0; m < kChimeModes; ++m) v.chZr[m] = v.chZi[m] = 0;
        if (chimes <= 0.0f || v.pitch < kChimeLow - 0.5 || v.pitch > kChimeHigh + 0.5) return;
        static constexpr float kLevel[kChimeModes] = {0.15f, 0.35f, 1.0f, 0.7f, 0.5f, 0.3f, 0.18f};
        setChimes(v, 6.0);
        const float a = 0.6f * chimes * static_cast<float>(0.4 + 0.6 * clampd(v.velocity, 0, 1));
        for (int m = 0; m < kChimeModes; ++m) v.chZr[m] = a * kLevel[m];
        v.chimeOn = true;
    }
    void release(Voice& v, const Shared&) noexcept {
        if (v.chimeOn) setChimes(v, 0.8);  // the chimes' damper as the key comes up: out in about 0.8 s
        float tone = 0;
        for (int k = 0; k < kRanks; ++k) {
            v.on[k] = false;
            if (isReed(kFamilyOf[k])) continue;
            const float e = v.envAt(k), a = e * e * v.gainAt(k) * v.rms[k];
            tone += a * a;
        }
        v.puff += static_cast<float>(std::sqrt(tone) * kOut * 0.04 * chiffAmt / 0.5);
    }
    // Each sounding voice, each control block: stops drawn or retired, each pipe's pitch, wander and level.
    void voiceControl(Voice& v, const Shared& s) noexcept {
        bool all = v.tick == 0;  // the note's first block, or a new pitch: every pipe's step now
        if (v.pitch != v.tunedPitch) {
            tune(v);
            for (int k = 0; k < kRanks; ++k) setRise(v, k);
            all = true;
        }
        if (!(s.release == v.relFor)) {
            v.relFor = s.release;
            const double tau = std::max(0.004, std::max(0.03, s.release) / 3.45);
            v.relK = static_cast<float>(1.0 - detExp(-1.0 / (tau * sr)));
            v.relD = static_cast<float>(detExp(-static_cast<double>(kControlFrames) / (tau * sr)));
        }
        // [Measured] a single pipe's wander: the stopped flute's medians (about 1.2 cents and 0.85 dB, over 0.2-10
        // Hz), at Living wind 0.3: each pipe's own random walk toward a new target about once a second, scaled so a
        // dry flute reads 1.2 cents and 0.6 dB (the recording's level also swings with its room's reflections).
        const double scale = wind / 0.3;
        const float wc = static_cast<float>(wanderCents() * scale), wd = static_cast<float>(wanderDb() * scale);
        // A pipe's wander worked out every fourth block (a quarter of them each block): it is slow.
        const float follow = static_cast<float>(std::min(1.0, 8.0 * kControlFrames / sr));
        const float jump = static_cast<float>(1.0 - 8.0 * kControlFrames / sr);
        const uint32_t parity = v.tick++ & 1u;
        constexpr float kLine = 1.0f / (2 * kControlFrames);  // a line runs two blocks
        float tone = 0;
        const float bk = blockK;
        for (int k = 0; k < kRanks; ++k) {
            const bool want = v.held && level[k] > 0.0f && speaks(v, k);
            const bool due = all || ((static_cast<uint32_t>(k) & 1u) == parity) || want != v.on[k];
            if (!due) {
                drawNext += v.drawOf[k];
                tone += v.toneOf[k];
                continue;
            }
            // Where its lines are now; then new ones for the next two blocks.
            float env = v.envAt(k), gain = v.gainAt(k), spoke = v.spokeAt(k);
            v.lineAt[k] = v.clock;
            const bool fresh = want && !v.on[k];
            if (fresh) open(v, k), gain = v.gain[k], spoke = v.spoke[k];
            if (!want) v.on[k] = false;
            if (!v.on[k] && env < 1e-5f) {
                v.env[k] = v.envStep[k] = v.drawOf[k] = v.toneOf[k] = 0;
                v.gain[k] = gain, v.gStep[k] = 0, v.spoke[k] = spoke, v.spokeStep[k] = 0;
                continue;
            }
            if (v.on[k] && env > 0.9995f) env = 1.0f;  // up: the pipe at its full level (0.05 % from it)
            const float target = v.on[k] ? 1.0f : 0.0f, d = v.on[k] ? v.rise[k] : v.relD;
            const float envEnd = target + (env - target) * (d * d);
            v.env[k] = env, v.envStep[k] = (envEnd - env) * kLine;
            // Spoken (the tier's speakEnd of its level reached), the steady table alone.
            float spokeEnd = std::max(spoke, std::min(1.0f, envEnd / speakEnd));
            if (spokeEnd > 0.999f) spokeEnd = 1.0f;
            if (spoke > 0.999f) spoke = 1.0f;
            v.spoke[k] = spoke, v.spokeStep[k] = (spokeEnd - spoke) * kLine;
            // Its pitch and wander every fourth block (every other time it is worked out), or now when it opens.
            if (all || fresh || (((static_cast<uint32_t>(k) >> 1) ^ (v.tick >> 1)) & 1u) == 0) {
                const float u = v.rng.next();  // one draw: a new pitch target at one end, a new level one at the other
                if (u > jump) v.wPitchTo[k] = v.rng.next();
                else if (u < -jump) v.wLevelTo[k] = v.rng.next();
                v.wPitch[k] += (v.wPitchTo[k] - v.wPitch[k]) * follow;
                v.wLevel[k] += (v.wLevelTo[k] - v.wLevel[k]) * follow;
                v.settle[k] *= v.settleK[k] * v.settleK[k] * v.settleK[k] * v.settleK[k];
                // The orchestral strings' vibrato: a player's 10 cents at 5.5 Hz, each note from its own phase.
                const int fam = kFamilyOf[k];
                const double vib = fam == kViolin || fam == kCello ? 10.0 * lib::fastSinCycles(vibPhase + v.vibOffset) : 0.0;
                const double c = v.tuning[k] + v.settle[k] + 2.6 * wc * v.wPitch[k] + vib;
                v.step[k] = static_cast<uint32_t>(v.inc[k] * cents(c) * pitchMod[enclosed(kDivisionOf[k])]);
            }
            // A stop retired holds its gain (its pipe releases); a stop drawn or moving eases to its new level.
            v.gain[k] = gain, v.gStep[k] = 0;
            if (level[k] > 0.0f) {
                const bool box = enclosed(kDivisionOf[k]);
                const float to = level[k] * kVoicing[k] * levelMod[box] * (box ? swellG : 1.0f) *
                                 (1.0f + 0.345f * wd * v.wLevel[k]) * (1.0f + v.strikeLevel[k]) * v.voiced[k];
                v.gStep[k] = (to - gain) * bk * kLine;
            }
            const float e2 = env * env * gain;
            const float a = e2 * v.rms[k];
            // A reed's tongue makes no wind noise of its own (only the flues' mouths do): its tone stays out of the
            // breath (2026-11-25, the owner: the reeds too noisy).
            v.drawOf[k] = e2 * pipeDraw[k], v.toneOf[k] = isReed(kFamilyOf[k]) ? 0.0f : a * a;
            drawNext += v.drawOf[k];
            tone += v.toneOf[k];
        }
        // The steady wind noise: [Measured] the flue registrations' residual, kNoiseDb under their tone, at Living
        // wind 0.3 (it grows as the square root of the knob: +5 dB at 1, none at 0).
        v.nGainTo = static_cast<float>(std::sqrt(tone * scale)) * noiseGain;
        for (int b = 0; b < kBreathBands; ++b) v.nLp[b] = timber::flushf(v.nLp[b]), v.nBp[b] = timber::flushf(v.nBp[b]);
        v.bodyLp = timber::flushf(v.bodyLp);
        v.boxLp = timber::flushf(v.boxLp);
        if (v.chimeOn) {  // rung out (about -100 dB): off
            float e = 0;
            for (int m = 0; m < kChimeModes; ++m) {
                v.chZr[m] = timber::flushf(v.chZr[m]), v.chZi[m] = timber::flushf(v.chZi[m]);
                e += v.chZr[m] * v.chZr[m] + v.chZi[m] * v.chZi[m];
            }
            if (e < 1e-10f) v.chimeOn = false;
        }
        v.puff = timber::flushf(v.puff);
    }
    // Per sample, in bittern_render.cpp: compiled with strict floating point, so any block size gives the same bits
    // (the fast flags vectorise a loop's main body and its remainder with different groupings).
    void render(Voice& v, float* out, uint32_t n) noexcept;
    // The swell boxes are in each voice (render): only the Swell and the Choir are enclosed.
    // The floor (Weight): a low shelf at 110 Hz on the organ's sum, +6 dB at the default 0.5 (2026-11-25, the owner:
    // "a quite literal wall of sound ... a lot of it is normally lost in recording"; the 16's and 32's the organ is
    // felt by), flushed on the control grid so any block size gives the same bits.
    void post(float* l, float* r, uint32_t n, const Shared&) noexcept {
        if (weightFor <= 0.0) return;
        for (uint32_t i = 0; i < n; ++i) l[i] = floorL.run(l[i]), r[i] = floorR.run(r[i]);
        floorFill += n;
        if (floorFill >= kControlFrames) floorFill = 0, floorL.flush(), floorR.flush();
    }
    bool postQuiet() const noexcept { return true; }
    // Asleep (nothing sounding for 0.5 s): the box's and the reservoir's state to rest, so the next note does not
    // start on a sagging wind.
    void clearPost() noexcept {
        floorL.clear(), floorR.clear(), floorFill = 0;
        sag = sagVel = draw = drawNext = 0;
    }
    void display(float* out) const noexcept {
        for (int k = 0; k < 7; ++k) out[k] = level[k];
    }
};

}  // namespace caw::bittern
