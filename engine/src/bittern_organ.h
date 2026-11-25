// Bittern's pipe organ (1.1.3): ranks as shared band-limited tables, each stop its own phase and detune, flue chiff, a living wind with tremulant, a swell box, and a cathedral room on by default.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "instrument_core.h"

namespace caw::bittern {

using timber::clampd;
using timber::kControlFrames;
using timber::Shared;
using timber::VoiceBase;

// The stops (ranks), in the descriptor's order.
enum Stop : int {
    kBourdon16, kPrincipal8, kRohrflute8, kGamba8, kCeleste8, kOctave4, kFlute4, kNazard, kFifteenth2, kTierce,
    kMixture, kTrumpet8, kSubbass32, kStops
};
inline constexpr int kZones = 12;          // table zones, 8 semitones apart from key 21 (A0) to 117
inline constexpr uint32_t kTableSize = 2048;
// The rank's pitch as a multiple of the 8' note (16' = 0.5; the mixture's table is built at the 8' pitch).
inline constexpr double kFoot[kStops] = {0.5, 1, 1, 1, 1, 2, 2, 3, 4, 5, 1, 1, 0.25};

// The shared tables (built once per process, read-only; bittern_tables.cpp): stop s, zone z, kTableSize + 1 floats
// (the last repeats the first, for the interpolation), peak about 1 for a full rank.
const float* rankTable(int stop, int zone) noexcept;
void buildTables() noexcept;  // registerBittern calls it, so no voice ever builds them
size_t tableBytes() noexcept;
inline int zoneOf(double key) noexcept { return std::clamp(static_cast<int>((key - 21.0) / 8.0), 0, kZones - 1); }

// A noise from a seed (the chiff and the wind's sway): a linear-congruential generator, -1..1.
struct Rng {
    uint32_t s = 1;
    float next() noexcept {
        s = s * 1664525u + 1013904223u;
        return static_cast<float>(static_cast<int32_t>(s)) * (1.0f / 2147483648.0f);
    }
};

// The pipe organ (the owner, 2026-11-24: "a giant cathedral organ ... a bunch of flutes and mock brass instruments
// linked together in a big room"). Original code after the realism research's design ("Pipes as tables, not live
// waveguides"): a pipe's steady tone barely changes, so each rank is a table oscillator, built from its family's
// spectrum (principal, open and stopped flutes, string, reed; mutations and a breaking mixture) and band-limited
// per zone. **[Assumption]** the spectra follow organ-building acoustics (Fletcher and Rossing ch. 17; wide scales
// favour the fundamental, stopped pipes the odd partials, strings the high ones, reeds a formant), not measurements.
// Every stop of a note runs at its own phase with a seeded detune of under 1.5 cents (ranks are never exactly in
// tune), the céleste 6 cents sharp. Flue stops speak in 30-60 ms with a chiff (a short noise near their 2nd-4th
// harmonics, Castellengo ISMA 2004), reeds in 12 ms. The wind is shared: a slow random sway of pitch and level and
// the Tremulant; the mod wheel closes the swell box (darker and quieter). The room is on by default (Space 0.45): a
// cathedral of about 6.5 s, the one realistic instrument that is not dry (owner, 2026-11-24).
struct Organ {
    static constexpr uint32_t kEcoCap = 12, kNormalCap = 16, kHighCap = 24, kPool = kHighCap + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = false;
    static constexpr double kMinLife = 0.05, kSpread = 0.5;
    // Stop levels (kStops), then Tremulant, Wind, Chiff, Tremulant rate.
    static constexpr uint32_t kTrem = kStops, kWind = kStops + 1, kChiff = kStops + 2, kTremRate = kStops + 3;
    static constexpr uint32_t kModelParams = kStops + 4;

    struct Voice : VoiceBase {
        uint32_t phase[kStops] = {};  // each rank's phase, a full cycle 2^32 (exact at any block size, and cheap)
        double inc[kStops] = {};      // its step a sample in those units (the note's pitch, the stop's foot, its detune)
        const float* table[kStops] = {};
        float speak = 0, speakStep = 0, reedSpeak = 0, reedStep = 0;  // flue and reed speech (0..1)
        float rel = 1, relStep = 0;
        float chiff = 0, chiffDecay = 0, cLp = 0, cBp = 0, cF = 0.1f;
        Rng rng;
        float detune[kStops] = {};  // cents
        double tunedPitch = -1;
    };

    double sr = 48000;
    float level[kStops] = {};
    double trem = 0, wind = 0.3, chiffAmt = 0.5, tremRate = 5.5, modWheel = 0;
    // The wind (shared by every pipe): its sway (a smoothed random walk) and the tremulant's phase, per control block.
    double sway = 0, swayTarget = 0, tremPhase = 0;
    float pitchMod = 1, levelMod = 1;
    Rng windRng;
    float swellLp[2] = {}, swellK = 1, swellG = 1;
    Voice* voices = nullptr;
    uint32_t count = 0;

    size_t allocBytes() const noexcept { return 0; }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 1.0, r.decay = 6.5, r.damping = 0.4, r.mix = 1.0, r.width = 1.3, r.preDelay = 0.04, r.modulation = 0.3;
        return r;
    }
    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        sr = rate;
        voices = v, count = n;
        buildTables();
        windRng.s = 0x0B177E2Du;
        return true;
    }
    void reset() noexcept {
        sway = swayTarget = tremPhase = 0;
        swellLp[0] = swellLp[1] = 0;
        windRng.s = 0x0B177E2Du;
    }
    void control(const double* p, const Shared& s) noexcept {
        for (int k = 0; k < kStops; ++k) level[k] = static_cast<float>(clampd(p[k], 0, 1));
        trem = clampd(p[kTrem], 0, 1);
        wind = clampd(p[kWind], 0, 1);
        chiffAmt = clampd(p[kChiff], 0, 1);
        tremRate = clampd(p[kTremRate], 2, 9);
        modWheel = s.modWheel;
        // The wind: a new sway target now and then (about 0.4 Hz), approached smoothly; the tremulant a sine.
        const double dt = kControlFrames / sr;
        if (windRng.next() > 1.0f - static_cast<float>(2.0 * 0.4 * dt)) swayTarget = windRng.next();
        sway += (swayTarget - sway) * std::min(1.0, dt * 2.0);
        tremPhase += tremRate * dt;
        tremPhase -= std::floor(tremPhase);
        const double t = lib::fastSinCycles(tremPhase);
        pitchMod = static_cast<float>(lib::fastExp((sway * 3.0 * wind + t * 9.0 * trem) * 5.776226504666211e-4));
        levelMod = static_cast<float>(1.0 + sway * 0.04 * wind + t * 0.22 * trem);
        // The swell box: the mod wheel closes it (darker, quieter), open at 0.
        const double box = clampd(modWheel, 0, 1);
        swellK = box < 1e-3 ? 1.0f : static_cast<float>(1.0 - detExp(-timber::kTwoPi * (12000.0 * detPow(0.08, box)) / sr));
        swellG = static_cast<float>(1.0 - 0.6 * box);
    }
    void tune(Voice& v) noexcept {
        const double hz = timber::noteHz(clampd(v.pitch, 12.0, 120.0));
        const int z = zoneOf(v.pitch);
        for (int k = 0; k < kStops; ++k) {
            const double f = hz * kFoot[k] * lib::fastExp(v.detune[k] * 5.776226504666211e-4);
            v.inc[k] = f / sr * 4294967296.0;
            v.table[k] = rankTable(k, z);
        }
        v.tunedPitch = v.pitch;
    }
    void start(Voice& v, const Shared&) noexcept {
        v.rng.s = 0xB177E2Du + 977u * v.key;
        for (int k = 0; k < kStops; ++k) {
            v.detune[k] = (k == kCeleste8 ? 6.0f : 0.0f) + 1.4f * v.rng.next();
            v.phase[k] = static_cast<uint32_t>((0.5 + 0.5 * v.rng.next()) * 4294967295.0);  // each rank's own phase
        }
        tune(v);
        v.speak = 0, v.speakStep = static_cast<float>(1.0 / ((0.03 + 0.03 * (1.0 - v.velocity)) * sr));
        v.reedSpeak = 0, v.reedStep = static_cast<float>(1.0 / (0.012 * sr));
        v.rel = 1, v.relStep = 0;
        // The chiff: the flue stops' share, near the 3rd harmonic of the 8' pitch (a band-pass of that centre).
        float flue = 0;
        for (int k = 0; k < kStops; ++k)
            if (k != kTrumpet8) flue += level[k];
        v.chiff = static_cast<float>(chiffAmt * 0.06 * std::min(1.0f, flue));
        v.chiffDecay = static_cast<float>(detExp(-1.0 / (0.035 * sr)));
        v.cLp = v.cBp = 0;
        v.cF = static_cast<float>(2.0 * std::sin(timber::kPi * std::min(0.2, 3.0 * timber::noteHz(v.pitch) / sr)));
    }
    void release(Voice& v, const Shared& s) noexcept {
        v.relStep = static_cast<float>(1.0 / std::max(1.0, std::max(0.03, s.release) * sr));
    }
    void voiceControl(Voice& v, const Shared&) noexcept {
        if (v.pitch != v.tunedPitch) tune(v);
        v.cLp = timber::flushf(v.cLp), v.cBp = timber::flushf(v.cBp);
    }
    // Per sample, in bittern_render.cpp: compiled with strict floating point, so any block size gives the same bits
    // (the fast flags vectorise a loop's main body and its remainder with different groupings).
    void render(Voice& v, float* out, uint32_t n) noexcept;
    // The swell box after the voices' sum: a one-pole low-pass and a gain, both from the mod wheel.
    void post(float* l, float* r, uint32_t n, const Shared&) noexcept {
        if (swellK >= 0.999f && swellG >= 0.999f) return;
        for (uint32_t i = 0; i < n; ++i) {
            swellLp[0] += swellK * (l[i] - swellLp[0]);
            swellLp[1] += swellK * (r[i] - swellLp[1]);
            l[i] = swellLp[0] * swellG, r[i] = swellLp[1] * swellG;
        }
        swellFill += n;
        if (swellFill >= kControlFrames) {  // flushed on the control grid only, so any block size gives the same bits
            swellFill = 0;
            swellLp[0] = timber::flushf(swellLp[0]), swellLp[1] = timber::flushf(swellLp[1]);
        }
    }
    uint32_t swellFill = 0;
    bool postQuiet() const noexcept { return true; }
    void clearPost() noexcept { swellLp[0] = swellLp[1] = 0; }
    void display(float* out) const noexcept {
        for (int k = 0; k < 7; ++k) out[k] = level[k];
    }
};

}  // namespace caw::bittern
