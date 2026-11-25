// Curlew's winds (1.1.3): Timber's Simulated reeds, jets and lips without the click into the bore on every note, dry, each with a body estimated from recordings.
#pragma once

#include <cmath>
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
// - Growl (2026-11-25, the owner: Timber's 35 Hz sine on the gain "doesn't do what it's supposed to do"): a growl or
//   flutter-tongue is the player humming or rolling an R into the instrument. Here: the rolled tongue, a train of
//   short closures at about 26 Hz that wanders (a rough buzz, not a tremolo), with a little pitch flutter; and the
//   hummed pitch, about an octave under the note and 2 Hz off it, modulating the air (the sub-octave sidebands and
//   the slow beating against the note that make a growl sound sung). Per sample on each voice's output.
struct Winds : timber::Wind {
    using Base = timber::Wind;
    enum P : uint32_t { kCBreath, kCNoise, kCReed, kCVibrato, kCVibRate, kCGrowl, kCAttack };
    static constexpr uint32_t kModelParams = 7;
    int which = 0;  // the instrument (Flute .. French horn)
    BodyFilter body;
    float bodyAmount = 1;
    bool testBypassBody = false;
    // The growl (its own, in place of Timber's): the amount, and each voice's tongue and hum phases (by its index).
    double growlAmount = 0;
    struct Growl {
        double tongue = 0, hum = 0, rate = 26;
        timber::Noise wander;
    };
    Growl growls[Base::kPool];

    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        padClicks = false;
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
        q[Base::kVibrato] = p[kCVibrato], q[Base::kVibRate] = p[kCVibRate], q[Base::kGrowl] = 0.0;
        growlAmount = timber::clampd(p[kCGrowl], 0, 1);
        q[Base::kAttack] = p[kCAttack], q[Base::kSim] = 1.0, q[Base::kNoises] = 0.0;
        Base::control(q, s);
        bodyAmount = static_cast<float>(timber::clampd(s.body, 0, 1));
        body.load(bodyResponse(which), bodyAmount, sr);
    }
    void start(Voice& v, const Shared& s) noexcept {
        Base::start(v, s);
        Growl& g = growls[&v - voices];
        g.tongue = 0, g.hum = 0, g.rate = 26;
        g.wander.s = 0x6A09u + 131u * v.key;
    }
    void voiceControl(Voice& v, const Shared& s) noexcept {
        Base::voiceControl(v, s);
        if (growlAmount <= 0) return;
        // The tongue's roll wanders (24..30 Hz), and the pitch flutters with it (up to 20 cents at Growl 1).
        Growl& g = growls[&v - voices];
        g.rate = timber::clampd(g.rate + 0.6 * g.wander.next(), 22.0, 31.0);
        const double flutter = 20.0 * growlAmount * lib::fastSinCycles(g.tongue);
        tune(v, 8.0 * vibrato * lib::fastSinCycles(v.vib) + flutter);
    }
    // Each voice's output through the growl's gain: the tongue's closures (a raised cosine cubed, narrow dips) times
    // the hum (a sine at half the note, 2 Hz up), its mean brought back to 1 so Growl leaves the level where it was.
    void growl(Voice& v, float* out, uint32_t n) noexcept {
        if (growlAmount <= 0) return;
        Growl& g = growls[&v - voices];
        const double a = growlAmount, dt = 1.0 / sr;
        const double humHz = 0.5 * v.baseHz + 2.0;
        const float dT = static_cast<float>(0.8 * a), dH = static_cast<float>(0.7 * a);
        const float norm = 1.0f / (1.0f - dT * 0.3125f);
        for (uint32_t i = 0; i < n; ++i) {
            const float c = 0.5f + 0.5f * static_cast<float>(lib::fastSinCycles(g.tongue + 0.25));
            const float h = static_cast<float>(lib::fastSinCycles(g.hum));
            out[i] *= (1.0f - dT * c * c * c) * norm * (1.0f + dH * h);
            g.tongue += g.rate * dt, g.hum += humHz * dt;
            g.tongue -= std::floor(g.tongue), g.hum -= std::floor(g.hum);
        }
    }
    void render(Voice& v, float* out, uint32_t n) noexcept {
        Base::render(v, out, n);
        growl(v, out, n);
    }
    void renderGroup(Voice* const* vs, uint32_t count, float (*out)[timber::kControlFrames], uint32_t n) noexcept {
        Base::renderGroup(vs, count, out, n);
        for (uint32_t l = 0; l < count; ++l) growl(*vs[l], out[l], n);
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
