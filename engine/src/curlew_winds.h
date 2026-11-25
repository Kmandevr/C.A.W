// Curlew's winds (1.1.3): Timber's Simulated reeds, jets and lips without the click into the bore on every note, dry, each with a body estimated from recordings.
#pragma once

#include <cstdint>

#include "body_bands.h"
#include "timber_mallet_wind.h"

namespace caw::curlew {

using timber::Shared;

// Each instrument: the wind model's kind (0 clarinet, 1 flute, 2 sax, 3 brass) and its body (curlew_bodies.cpp).
inline constexpr int kKind[6] = {1, 0, 2, 3, 3, 3};  // Flute, Clarinet, Saxophone, Trumpet, Trombone, French horn
BodyResponse bodyResponse(int instrument) noexcept;  // curlew_bodies.cpp
// Each instrument's range for the pull table: its first key and 40 keys a semitone apart.
inline constexpr int kPullFirst[6] = {58, 50, 46, 52, 38, 40};
inline constexpr int kPullKeys = 40;
#include "curlew_tuning.inc"

// The winds of Timber's Simulated mode (timber_mallet_wind.h: the jet, the reeds, the cone, the lips, the tongue and
// the breath's turbulence), with what the realism research (2026-11-24) found wrong taken out or added:
// - no pad, key or valve click into the bore: it rang at the note's pitch on every note and slur, a pitched thump
//   (the "piano on the flute"). The breath's own turbulence stays (Breath noise).
// - the body: the instrument's recorded spectrum over the model's at the same notes (VSCO 2 Community Edition, CC0),
//   as peaking bands after the voices' sum, Body scaling them; the saxophone has none yet (no free recording).
// - its own pull (the reed's, jet's or lips' flattening, aimed off) measured over each instrument's whole range
//   (curlew_tuning.inc), where Timber measured five keys of one range;
// - dry by default (Space 0).
struct Winds : timber::Wind {
    using Base = timber::Wind;
    enum P : uint32_t { kCBreath, kCNoise, kCReed, kCVibrato, kCVibRate, kCGrowl, kCAttack };
    static constexpr uint32_t kModelParams = 7;
    int which = 0;  // the instrument (Flute .. French horn)
    BodyFilter body;
    float bodyAmount = 1;
    bool testBypassBody = false;

    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        pullTable = kPull[which], pullFirst = kPullFirst[which], pullCount = kPullKeys;
        // Brass: the lips' resonance a little above the note (outward-striking lips, as Fletcher and Rossing describe
        // them); at Timber's 0.9 below it, a trombone or horn held only half its notes (measured 2026-11-24: 1.15
        // held 10 of 11 trombone and 9 of 10 trumpet notes; the pull table aims off the sharpening that comes with it).
        if (kKind[which] == 3) lipRatio = 1.15f;
        if (!Base::prepare(rate, v, n)) return false;
        body.load(bodyResponse(which), bodyAmount, sr);
        return true;
    }
    void control(const double* p, const Shared& s) noexcept {
        double q[Base::kModelParams] = {};
        q[Base::kInstrument] = kKind[which];
        q[Base::kBreath] = p[kCBreath], q[Base::kNoise] = p[kCNoise], q[Base::kReed] = p[kCReed];
        q[Base::kVibrato] = p[kCVibrato], q[Base::kVibRate] = p[kCVibRate], q[Base::kGrowl] = p[kCGrowl];
        q[Base::kAttack] = p[kCAttack];
        Base::control(q, s);
        bodyAmount = static_cast<float>(timber::clampd(s.body, 0, 1));
        body.load(bodyResponse(which), bodyAmount, sr);
    }
    void post(float* l, float* r, uint32_t n, const Shared& s) noexcept {
        Base::post(l, r, n, s);
        if (!testBypassBody) body.process(l, r, n);
    }
    void clearPost() noexcept {
        Base::clearPost();
        body.clear();
    }
};

}  // namespace caw::curlew
