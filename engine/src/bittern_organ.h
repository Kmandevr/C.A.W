// Bittern's pipe organ (1.1.3): ranks from measured pipe spectra, each pipe speaking on its own with recorded speech noise, one shared and sagging wind, a tremulant, a swell box and a cathedral room on by default.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>

#include "recorded_bank.h"
#include "timber_core.h"

namespace caw::bittern {

using timber::clampd;
using timber::kControlFrames;
using timber::Shared;
using timber::VoiceBase;

// The stops (ranks), in the descriptor's order: by division, the Great, then the Swell, then the Pedal.
enum Stop : int {
    kBourdon16, kPrincipal8, kOctave4, kFifteenth2, kMixture, kTrumpet8,  // Great
    kRohrflute8, kGamba8, kCeleste8, kFlute4, kNazard, kTierce,         // Swell
    kSubbass32,                                                         // Pedal
    kStops
};
enum Division : int { kGreat, kSwell, kPedal, kDivisions };
inline constexpr int kDivisionOf[kStops] = {kGreat, kGreat, kGreat, kGreat, kGreat, kGreat, kSwell, kSwell, kSwell, kSwell, kSwell, kSwell, kPedal};
// Each stop's pipe family: its tables (bittern_tables.cpp). The first three are measured (tools/bittern_assets.py).
enum Family : int { kStopped, kOpen, kPrincipal, kString, kReed, kMixtureFamily, kFamilies };
inline constexpr int kFamilyOf[kStops] = {kStopped, kPrincipal, kPrincipal, kPrincipal, kMixtureFamily, kReed,
                                          kStopped, kString,    kString,    kOpen,      kOpen,          kOpen, kStopped};
// The rank's pitch as a multiple of the 8' note (16' = 0.5; the mixture's tables are built at the 8' pitch).
inline constexpr double kFoot[kStops] = {0.5, 1, 2, 4, 1, 1, 1, 1, 1, 2, 3, 5, 0.25};

// The tables' zones: 6 semitones of the pipe's sounding pitch each, from MIDI 12 (the mixture's by its key's 8'
// pitch), every table kTableSize + 1 floats (the last repeats the first, for the interpolation), peak 1.
inline constexpr int kZones = 18;
inline constexpr uint32_t kTableSize = 2048;
inline int zoneOf(double sounding) noexcept { return std::clamp(static_cast<int>((sounding - 12.0) / 6.0), 0, kZones - 1); }

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
int nearestClip(int group, double key, double maxSemitones) noexcept;
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

// The registrations (combinations: the organ's usual ones, one tap): each stop's level, 0 the knobs themselves.
inline constexpr int kRegistrations = 6;
inline constexpr float kRegistration[kRegistrations][kStops] = {
    // Bourdon16 Principal8 Octave4 Fifteenth2 Mixture Trumpet8 | Rohrflute8 Gamba8 Celeste8 Flute4 Nazard Tierce | Subbass32
    {},                                                          // the stops as drawn
    {0, 0, 0, 0, 0, 0, 0.9f, 0, 0, 0.7f, 0, 0, 0},                // Flutes 8' 4'
    {0.6f, 1, 0.8f, 0.6f, 0, 0, 0, 0, 0, 0, 0, 0, 0.5f},          // Principal chorus (8' 4' 2' on the 16')
    {0.8f, 1, 0.9f, 0.8f, 0.7f, 0.7f, 0.5f, 0, 0, 0.5f, 0, 0, 0.8f},  // Full organ (plenum, with the reed)
    {0, 0.3f, 0, 0, 0, 1, 0.5f, 0, 0, 0, 0, 0, 0.4f},             // Reeds (the trumpet on a soft 8')
    {0, 0, 0, 0, 0, 0, 0.3f, 0.8f, 0.8f, 0, 0, 0, 0},             // Strings (Gamba with its céleste)
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
    // Stop levels (kStops), then Tremulant, Wind, Chiff, Tremulant rate, Registration.
    static constexpr uint32_t kTrem = kStops, kWind = kStops + 1, kChiff = kStops + 2, kTremRate = kStops + 3,
                              kReg = kStops + 4;
    static constexpr uint32_t kModelParams = kStops + 5;
    static constexpr int kPlayers = 4;  // recorded speech clips per note: one per recorded registration
    static constexpr int kBreathBands = 4;
    static constexpr float kBreathDamp = 0.25f;  // the breath's band-passes: Q 4
    static constexpr float kOut = 0.12f;  // a rank at level 1 (its table's peak 1)

    // A recorded speech clip playing.
    struct Player {
        const float* data = nullptr;
        uint32_t frames = 0;
        double pos = 0, step = 1;
        float gain = 0;
    };

    struct Voice : VoiceBase {
        uint32_t phase[kStops] = {};  // each pipe's phase, a full cycle 2^32 (exact at any block size, and cheap)
        uint32_t step[kStops] = {};   // its step a sample this control block (pitch, tuning, wander, the wind)
        double inc[kStops] = {};      // its step at its tuned pitch
        const float* steady[kStops] = {};
        const float* speaking[kStops] = {};
        float rms[kStops] = {};
        // Its speech and release (0..1; the pipe sounds env^2): a one-pole worked out per control block, env at
        // the block's start and envTo at its end, a line across it (envStep a sample).
        float env[kStops] = {}, envTo[kStops] = {}, envStep[kStops] = {};
        float spoke[kStops] = {};    // how far it has spoken (the spectrum, speaking to steady)
        float rise[kStops] = {};     // its one-pole's decay over a control block while it speaks
        // Its level (the stop, its wander, the wind): eased toward the knob per control block (about 5 ms), and a
        // line from the block's start (gain) to its end (gainTo) across it, sample by sample (gStep a sample; pos the
        // voice's place in the block), so no sample's level depends on the last one's and any block size gives the
        // same bits.
        float gain[kStops] = {}, gainTo[kStops] = {}, gStep[kStops] = {};
        uint32_t pos = 0;
        float tuning[kStops] = {};   // its fixed tuning error (cents)
        float strikeRise[kStops] = {};  // this strike's own speed of speech (a factor near 1)
        float settle[kStops] = {}, settleK[kStops] = {};  // its speech's pitch error (cents) and its decay a block
        float wPitch[kStops] = {}, wPitchTo[kStops] = {}, wLevel[kStops] = {}, wLevelTo[kStops] = {};
        float relK = 0;              // the release's one-pole coefficient a sample (the recorded speech's)
        float relD = 0;              // and over a control block (the pipes')
        double relFor = -1;          // the Release it was worked out for
        bool on[kStops] = {};        // the pipe's valve open (key held and stop drawn)
        Player players[kPlayers];
        int playersOn = 0;
        float speech = 1;  // the recorded speech's level: it stops with the pipes when the key is let go
        float inFade = 1, inStep = 0;  // a key struck again: this voice fades in as the frame fades the old one out
        // The breath: a noise through band-passes at the key's 2nd, 3rd, 4th and 6th harmonics (state-variable, Q 4),
        // its level the sounding pipes' (smoothed), plus the puffs of the valve opening a reed and of it closing.
        float nLp[kBreathBands] = {}, nBp[kBreathBands] = {}, nF[kBreathBands] = {}, nW[kBreathBands] = {};
        float nGain = 0, nGainTo = 0, puff = 0, puffK = 0;
        float strikeLevel[kStops] = {};  // this strike's own level error (a fraction)
        Rng rng, noise;
        double tunedPitch = -1;
    };

    double sr = 48000;
    float level[kStops] = {};
    float knob[kStops] = {};
    int registration = 0;
    double trem = 0, wind = 0.3, chiffAmt = 0.5, tremRate = 5.5, modWheel = 0;
    // The wind (shared by every pipe): its sway (a smoothed random walk), the tremulant's phase and the reservoir's
    // sag under the pipes' draw (a damped spring), per control block.
    double sway = 0, swayTarget = 0, tremPhase = 0, sag = 0, sagVel = 0, draw = 0;
    float pitchMod = 1, levelMod = 1;
    Rng windRng;
    uint32_t notes = 0;  // notes started since the last reset (each note's phases)
    // The swell box: a one-pole low-pass and a gain, each smoothed per sample toward the mod wheel's.
    float swellLp[2] = {}, swellK = 1, swellG = 1, swellKTo = 1, swellGTo = 1;
    uint32_t swellFill = 0;
    float gainK = 0.004f;   // the breath's level eased over about 5 ms a sample (prepare())
    float blockK = 0.064f;  // a pipe's level eased over about 5 ms a control block (prepare())
    std::shared_ptr<const recorded::Bank> bank;
    Voice* voices = nullptr;
    uint32_t count = 0;
    bool testMuteSpeech = false;  // the tests' A/B (never used for sound)

    size_t allocBytes() const noexcept { return 0; }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 1.0, r.decay = 6.5, r.damping = 0.4, r.mix = 1.0, r.width = 1.3, r.preDelay = 0.04, r.modulation = 0.3;
        return r;
    }
    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        sr = rate;
        voices = v, count = n;
        gainK = static_cast<float>(1.0 - detExp(-1.0 / (0.005 * sr)));
        blockK = static_cast<float>(1.0 - detExp(-static_cast<double>(kControlFrames) / (0.005 * sr)));
        buildTables();
        if (!bank) bank = recorded::acquire(recorded::BankId::Bittern);
        reset();
        return true;
    }
    void reset() noexcept {
        sway = swayTarget = tremPhase = sag = sagVel = draw = 0;
        pitchMod = levelMod = 1;
        swellLp[0] = swellLp[1] = 0;
        swellK = swellKTo, swellG = swellGTo;
        swellFill = 0;
        windRng.s = 0x0B177E2Du;
        notes = 0;
    }
    static double cents(double c) noexcept { return lib::fastExp(c * 5.776226504666211e-4); }

    void control(const double* p, const Shared& s) noexcept {
        registration = static_cast<int>(clampd(p[kReg], 0, kRegistrations - 1) + 0.5);
        for (int k = 0; k < kStops; ++k) {
            knob[k] = static_cast<float>(clampd(p[k], 0, 1));
            level[k] = registration == 0 ? knob[k] : kRegistration[registration][k];
        }
        trem = clampd(p[kTrem], 0, 1);
        wind = clampd(p[kWind], 0, 1);
        chiffAmt = clampd(p[kChiff], 0, 1);
        tremRate = clampd(p[kTremRate], 2, 9);
        modWheel = s.modWheel;
        const double dt = kControlFrames / sr;
        // The living wind: a new sway target now and then (about 0.4 Hz), approached smoothly; the tremulant a sine.
        if (windRng.next() > 1.0f - static_cast<float>(2.0 * 0.4 * dt)) swayTarget = windRng.next();
        sway += (swayTarget - sway) * std::min(1.0, dt * 2.0);
        tremPhase += tremRate * dt;
        tremPhase -= std::floor(tremPhase);
        const double t = lib::fastSinCycles(tremPhase);
        // The reservoir: what the sounding pipes draw (each pipe's level, a big pipe more: the square root of its
        // length), the sag toward draw / (draw + 24) through a spring of 3 Hz damped at 0.35 (a big chord sags and
        // bounces a little). [Assumption] chosen, not measured (the recordings hold single notes): full sag is 5
        // cents flat and 0.9 dB softer; ten keys of the full organ sag about two thirds of that.
        double d = 0;
        for (uint32_t i = 0; i < count; ++i) {
            const Voice& v = voices[i];
            if (!v.active) continue;
            for (int k = 0; k < kStops; ++k) d += static_cast<double>(v.env[k]) * v.env[k] * v.gainTo[k] * kDraw[k];
        }
        draw = d;
        const double target = d / (d + 24.0), w = timber::kTwoPi * 3.0;
        sagVel += ((target - sag) * w * w - 2.0 * 0.35 * w * sagVel) * dt;
        sag += sagVel * dt;
        pitchMod = static_cast<float>(cents(sway * 3.0 * wind + t * 9.0 * trem - 5.0 * sag));
        levelMod = static_cast<float>((1.0 + sway * 0.04 * wind + t * 0.22 * trem) * (1.0 - 0.1 * sag));
        // The swell box: the mod wheel closes it (darker, quieter), open at 0.
        const double box = clampd(modWheel, 0, 1);
        swellKTo = box < 1e-3 ? 1.0f : static_cast<float>(1.0 - detExp(-timber::kTwoPi * (12000.0 * detPow(0.08, box)) / sr));
        swellGTo = static_cast<float>(1.0 - 0.6 * box);
    }
    // A big pipe draws more wind: the square root of its length against the 8'.
    static constexpr float kDraw[kStops] = {1.41f, 1, 0.71f, 0.5f, 1.2f, 1, 1, 1, 1, 0.71f, 0.58f, 0.45f, 2};

    void tune(Voice& v) noexcept {
        const double pitch = clampd(v.pitch, 12.0, 120.0), hz = timber::noteHz(pitch);
        const int zMix = zoneOf(pitch);
        for (int k = 0; k < kStops; ++k) {
            const int fam = kFamilyOf[k];
            const int z = fam == kMixtureFamily ? zMix : zoneOf(pitch + 12.0 * std::log2(kFoot[k]));
            v.inc[k] = hz * kFoot[k] / sr * 4294967296.0;
            v.steady[k] = steadyTable(fam, z), v.speaking[k] = speakingTable(fam, z);
            v.rms[k] = tableRms(fam, z);
        }
        v.tunedPitch = v.pitch;
    }
    // Each pipe's rise: the measured time to half level for its pitch (bittern_bank.inc), the reed's 12 ms and the
    // strings' 1.5 times a principal's ([Assumption]: neither was recorded). The pipe sounds env^2, a one-pole's
    // square, at half level when env is 0.707, 1.23 time constants in.
    void setRise(Voice& v, int k) const noexcept {
        const double hz = timber::noteHz(clampd(v.pitch, 12.0, 120.0)) * kFoot[k];
        double t50 = kFamilyOf[k] == kReed ? 0.012 : riseSeconds(std::max(hz, 20.0));
        if (kFamilyOf[k] == kString) t50 *= 1.5;
        const double tau = std::max(0.004, t50 * v.strikeRise[k] / 1.23);
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
        if (v.env[k] < 0.05f) v.spoke[k] = 0;
        v.strikeRise[k] = 1.0f + 0.2f * v.rng.next();
        v.strikeLevel[k] = 0.035f * v.rng.next();
        setRise(v, k);
        v.settle[k] = 6.0f * v.rng.next() * (1.0f - v.env[k]);
        if (kFamilyOf[k] == kReed) {
            v.settle[k] = -(12.5f + 2.5f * v.rng.next()) * (1.0f - v.env[k]);
            v.puff += static_cast<float>(level[k] * v.rms[k] * kOut * 0.06 * chiffAmt / 0.5) * (1.0f - v.env[k]);
        }
        v.gain[k] = v.gainTo[k] = level[k], v.gStep[k] = 0;
    }
    void start(Voice& v, const Shared& s) noexcept {
        v.rng.s = 0xB177E2Du + 977u * v.key + 7919u * notes;
        ++notes;
        // A key struck again while its pipes still sound (the frame fades that voice over 5 ms): carry its pipes on in
        // the same phase and level, so the two are one sound and the valve's reopening is all that is heard.
        const Voice* was = nullptr;
        for (uint32_t i = 0; i < count; ++i) {
            const Voice& o = voices[i];
            if (&o != &v && o.active && o.fading && o.key == v.key && (!was || o.fade > was->fade)) was = &o;
        }
        Rng pipe;  // each pipe's own fixed tuning (the same pipe plays every time its key is struck)
        pipe.s = 0x9E3779B9u + 131u * v.key;
        for (int k = 0; k < kStops; ++k) {
            // [Measured] the chorus' ranks beat at a median 4.4 cents (VCSL's Loud: 0.4-4 Hz on partials of 0.2-2 kHz):
            // each pipe's tuning a triangular error of +-11 cents (standard deviation 4.6), so two pipes of a key
            // differ by a median of 4.4 cents, narrowing as the square root of the pipe's pitch over 500 Hz (the
            // recording's small pipes sit within its harmonics' 20 Hz: its residual stays 33-40 dB under the tone up
            // to C7, where 4.6 cents would put the 2' at -18 dB); the céleste 6 cents sharp on top.
            const double pipeHz = timber::noteHz(clampd(v.pitch, 12.0, 120.0)) * kFoot[k] * (kFamilyOf[k] == kMixtureFamily ? 4.0 : 1.0);
            const float narrow = static_cast<float>(std::min(1.0, std::sqrt(500.0 / pipeHz)));
            v.tuning[k] = (k == kCeleste8 ? 6.0f : 0.0f) + 5.6f * narrow * (pipe.next() + pipe.next());
            v.strikeRise[k] = 1.0f, v.strikeLevel[k] = 0;
            if (was) {
                v.phase[k] = was->phase[k], v.env[k] = v.envTo[k] = was->envTo[k], v.spoke[k] = was->spoke[k];
                v.gain[k] = v.gainTo[k] = was->gainTo[k], v.wPitch[k] = was->wPitch[k], v.wLevel[k] = was->wLevel[k];
            } else {
                v.phase[k] = static_cast<uint32_t>((0.5 + 0.5 * v.rng.next()) * 4294967295.0);
                v.env[k] = v.envTo[k] = v.spoke[k] = 0;
                v.gain[k] = v.gainTo[k] = level[k];
                v.wPitch[k] = v.rng.next(), v.wLevel[k] = v.rng.next();
            }
            v.wPitchTo[k] = v.wPitch[k], v.wLevelTo[k] = v.wLevel[k];
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
        for (int k = 0; k < kStops; ++k)
            if (level[k] > 0.0f) open(v, k);
        v.relFor = -1;
        // The breath's bands: the key's 2nd, 3rd, 4th and 6th harmonics ([Measured] the residual's centroid sits about
        // 4 times the 8' pitch: 3.5-6x, 400 Hz in the bass to 7.4 kHz at C7), each scaled to unit RMS for a uniform
        // noise (a band-pass of Q 1/d passes pi fc / (3 sr d) of its power), the four summed in power to one; a band
        // past 0.15 of the rate is left out.
        static constexpr double kBand[kBreathBands] = {2, 3, 4, 6};
        const double f8 = timber::noteHz(clampd(v.pitch, 12.0, 120.0));
        for (int b = 0; b < kBreathBands; ++b) {
            const double fc = std::max(120.0, f8 * kBand[b]);
            const bool ok = fc < 0.15 * sr;
            v.nF[b] = ok ? static_cast<float>(2.0 * std::sin(timber::kPi * fc / sr)) : 0.0f;
            v.nW[b] = ok ? static_cast<float>(0.5 / std::sqrt(timber::kPi * fc / (3.0 * sr * kBreathDamp))) : 0.0f;
        }
        v.speech = 1;
        // The frame fades the old voice out over 5 ms (a step of 1 / max(1, 0.005 sr) a sample); this one comes in by
        // the same steps, so the two (the same pipes in the same phase) always sum to one.
        v.inFade = was ? 0.0f : 1.0f;
        v.inStep = static_cast<float>(1.0 / std::max(1.0, 0.005 * sr));
        startSpeech(v, was ? was->env : nullptr);
        voiceControl(v, s);
        // Started between two control points: the levels hold until the next one, from this sample of the block.
        v.pos = static_cast<uint32_t>(s.clock % kControlFrames);
        for (int k = 0; k < kStops; ++k) v.gain[k] = v.gainTo[k], v.gStep[k] = 0, v.envTo[k] = v.env[k], v.envStep[k] = 0;
    }
    // The recorded speech: for each flue stop drawn, its family's recording nearest the key (within 2 semitones; the
    // clip is played at the ratio to the key), at the stop's level, summed where stops share a clip (so a note plays
    // at most one clip per family: the chorus' recording holds its octaves and mixture already).
    void startSpeech(Voice& v, const float* still) noexcept {
        v.playersOn = 0;
        if (!bank || testMuteSpeech || chiffAmt <= 0) return;
        const float amount = static_cast<float>(chiffAmt / 0.5);  // Chiff 0.5: as recorded
        for (int k = 0; k < kStops; ++k) {
            if (level[k] <= 0.0f) continue;
            const int fam = kFamilyOf[k];
            if (fam == kReed) continue;
            // Each family's recording: the stopped flutes the quiet manual, the open flutes the quiet pedal (the quiet
            // manual past its range), the principals, mixture and strings the chorus, the 32' the loud pedal.
            const double at = clampd(v.pitch, 12.0, 120.0);
            int group = fam == kStopped ? 0 : fam == kOpen ? 2 : 1;
            if (k == kSubbass32) group = 3;
            int c = nearestClip(group, at, 2.0);
            if (c < 0 && group == 2) c = nearestClip(0, at, 2.0);
            if (c < 0) continue;
            const ClipInfo ci = clipInfo(c);
            if (static_cast<uint64_t>(ci.first) + ci.frames > bank->frames) continue;
            // The clip in the rank's own units: its peak over its tone's RMS, times this rank's RMS at its level. The
            // chorus' recording sounds three ranks (and the mixture's), so each principal takes a third of it in
            // power; the strings a quarter of it ([Assumption]: a string's speech is like a principal's).
            const double share = fam == kPrincipal || fam == kMixtureFamily ? 0.577 : fam == kString ? 0.5 : 1.0;
            const float since = still ? 1.0f - still[k] : 1.0f;  // a pipe still sounding speaks less again
            const float g = static_cast<float>(level[k] * v.rms[k] * kOut * ci.scale * share) * amount * since;
            if (g <= 1e-7f) continue;
            const double ratio = detPow(2.0, (at - ci.key) / 12.0);
            Player* p = nullptr;
            for (int i = 0; i < v.playersOn; ++i)
                if (v.players[i].data == bank->pcm.get() + ci.first) p = &v.players[i];
            if (!p) {
                if (v.playersOn == kPlayers) {  // full: replace the quietest if this one is louder
                    Player* q = &v.players[0];
                    for (int i = 1; i < kPlayers; ++i)
                        if (v.players[i].gain < q->gain) q = &v.players[i];
                    if (q->gain >= g) continue;
                    p = q;
                } else {
                    p = &v.players[v.playersOn++];
                }
                *p = Player{};
                p->data = bank->pcm.get() + ci.first;
                p->frames = ci.frames;
                p->step = ratio * bank->rate / sr;
            }
            p->gain += g;
        }
    }
    // [Measured] a pipe's own release: -20 dB in 35-45 ms where the room is weakest (VCSL's single notes), so the
    // default Release (0.12 s) is its T60. The pipe sounds env^2: env's time constant is T60 / 3.45 (voiceControl).
    // The valve closing puffs: [Assumption] a breath burst at the speech's measured level (28 dB under the tone, at
    // Chiff 0.5), 25 ms long.
    void release(Voice& v, const Shared&) noexcept {
        float tone = 0;
        for (int k = 0; k < kStops; ++k) {
            v.on[k] = false;
            if (kFamilyOf[k] == kReed) continue;
            const float a = v.env[k] * v.env[k] * v.gainTo[k] * v.rms[k];
            tone += a * a;
        }
        v.puff += static_cast<float>(std::sqrt(tone) * kOut * 0.04 * chiffAmt / 0.5);
    }
    // Each sounding voice, each control block: stops drawn or retired, each pipe's pitch, wander and level.
    void voiceControl(Voice& v, const Shared& s) noexcept {
        if (v.pitch != v.tunedPitch) {
            tune(v);
            for (int k = 0; k < kStops; ++k) setRise(v, k);
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
        const float follow = static_cast<float>(std::min(1.0, 2.0 * kControlFrames / sr));
        const float jump = static_cast<float>(1.0 - 2.0 * kControlFrames / sr);
        float tone = 0;
        v.pos = 0;
        const float bk = blockK;
        for (int k = 0; k < kStops; ++k) {
            v.gain[k] = v.gainTo[k], v.gStep[k] = 0;
            v.env[k] = v.envTo[k], v.envStep[k] = 0;
            const bool want = v.held && level[k] > 0.0f;
            if (want && !v.on[k]) open(v, k);
            if (!want) v.on[k] = false;
            if (!v.on[k] && v.env[k] < 1e-5f) {
                v.env[k] = v.envTo[k] = 0;
                continue;
            }
            // Spoken, the steady table alone (the last 3 % of the speaking spectrum's difference is inaudible); up,
            // the pipe at its full level (0.05 % from it).
            v.spoke[k] = std::max(v.spoke[k], v.env[k]);
            if (v.spoke[k] > 0.97f) v.spoke[k] = 1.0f;
            if (v.on[k] && v.env[k] > 0.9995f) v.env[k] = 1.0f;
            const float target = v.on[k] ? 1.0f : 0.0f;
            v.envTo[k] = target + (v.env[k] - target) * (v.on[k] ? v.rise[k] : v.relD);
            v.envStep[k] = (v.envTo[k] - v.env[k]) * (1.0f / kControlFrames);
            if (v.rng.next() > jump) v.wPitchTo[k] = v.rng.next();
            if (v.rng.next() > jump) v.wLevelTo[k] = v.rng.next();
            v.wPitch[k] += (v.wPitchTo[k] - v.wPitch[k]) * follow;
            v.wLevel[k] += (v.wLevelTo[k] - v.wLevel[k]) * follow;
            v.settle[k] *= v.settleK[k];
            const double c = v.tuning[k] + v.settle[k] + 2.6 * wc * v.wPitch[k];
            v.step[k] = static_cast<uint32_t>(v.inc[k] * cents(c) * pitchMod);
            // A stop retired holds its gain (its pipe releases); a stop drawn or moving takes its new level.
            if (level[k] > 0.0f) {
                const float to = static_cast<float>(level[k] * levelMod * (1.0 + 0.115 * 3.0 * wd * v.wLevel[k]) * (1.0 + v.strikeLevel[k]));
                v.gainTo[k] += (to - v.gainTo[k]) * bk;
                v.gStep[k] = (v.gainTo[k] - v.gain[k]) * (1.0f / kControlFrames);
            }
            const float a = v.env[k] * v.env[k] * v.gainTo[k] * v.rms[k];
            tone += a * a;
        }
        // The steady wind noise: [Measured] the flue registrations' residual, kNoiseDb under their tone, at Living
        // wind 0.3 (it grows as the square root of the knob: +5 dB at 1, none at 0).
        v.nGainTo = static_cast<float>(std::sqrt(tone * scale) * kOut * detPow(10.0, noiseDb() / 20.0));
        for (int b = 0; b < kBreathBands; ++b) v.nLp[b] = timber::flushf(v.nLp[b]), v.nBp[b] = timber::flushf(v.nBp[b]);
        v.puff = timber::flushf(v.puff);
    }
    // Per sample, in bittern_render.cpp: compiled with strict floating point, so any block size gives the same bits
    // (the fast flags vectorise a loop's main body and its remainder with different groupings).
    void render(Voice& v, float* out, uint32_t n) noexcept;
    // The swell box after the voices' sum: a one-pole low-pass and a gain from the mod wheel, each eased per sample.
    void post(float* l, float* r, uint32_t n, const Shared&) noexcept;
    bool postQuiet() const noexcept { return true; }
    // Asleep (nothing sounding for 0.5 s): the box's and the reservoir's state to rest, so the next note does not
    // start on a sagging wind.
    void clearPost() noexcept {
        swellLp[0] = swellLp[1] = 0;
        sag = sagVel = draw = 0;
    }
    void display(float* out) const noexcept {
        for (int k = 0; k < 7; ++k) out[k] = level[k];
    }
};

}  // namespace caw::bittern
