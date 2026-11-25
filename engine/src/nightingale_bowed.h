// Nightingale's bowed string (1.1.3): Timber's elasto-plastic bow with the force kept inside Schelleng's window, a Guettler-shaped attack and release, bow noise at the output, allpass delays and a body estimated from recordings.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <new>

#include "body_bands.h"
#include "instrument_core.h"
#include "instrument_noinline.h"  // CAW_TIMBER_NOINLINE

namespace caw::nightingale {

using timber::clampd;
using timber::kControlFrames;
using timber::Shared;
using timber::VoiceBase;

// The body of each instrument (body_bands.h): the recordings' spectrum over the model's at the same notes, from VSCO 2
// Community Edition (CC0), as peaking bands (generated: tools/instrument_bodies.py nightingale).
BodyResponse bodyResponse(int instrument) noexcept;  // nightingale_bodies.cpp

#include "nightingale_window.inc"
inline constexpr int kLowestKey[4] = {55, 48, 36, 28};  // the window's first key per instrument

// The force factor (fn = factor x the bow's speed) at bow position `position` (0..1), `key` and place `pp` in the
// window (0 its lowest, 1 its highest; a little past at the extremes), from the measured window (log-linear).
inline double windowFactor(int instrument, double position, double key, double pp) noexcept {
    const double kz = std::clamp((key - kLowestKey[instrument]) / 3.0, 0.0, 15.0);
    const int z = std::min(static_cast<int>(kz), 14);
    const double fz = kz - z;
    const double pz = std::clamp(position, 0.0, 1.0) * 2.0;
    const int q = std::min(static_cast<int>(pz), 1);
    const double fq = pz - q;
    double lo = 0, hi = 0;
    for (int a = 0; a < 2; ++a)
        for (int b = 0; b < 2; ++b) {
            const double w = (a ? fq : 1.0 - fq) * (b ? fz : 1.0 - fz);
            lo += w * kWindow[instrument][q + a][z + b][0];
            hi += w * kWindow[instrument][q + a][z + b][1];
        }
    return detPow(10.0, lo + (hi - lo) * pp);
}

#include "nightingale_tuning.inc"

// The pull's offset (cents) at bow position, pressure and key: the measured table, linear in each (pressure
// extrapolated past 0.2 and 0.8).
inline double tuningOffset(int instrument, double position, double pressure, double key) noexcept {
    const double kz = std::clamp((key - kLowestKey[instrument]) / 3.0, 0.0, 15.0);
    const int z = std::min(static_cast<int>(kz), 14);
    const double fz = kz - z;
    const double pz = std::clamp(position, 0.0, 1.0) * 2.0;
    const int q = std::min(static_cast<int>(pz), 1);
    const double fq = pz - q;
    const double rz = (std::clamp(pressure, 0.0, 1.0) - 0.2) / 0.3;
    const int r = std::clamp(static_cast<int>(std::floor(rz)), 0, 1);
    const double fr = rz - r;
    double out = 0;
    for (int a = 0; a < 2; ++a)
        for (int b = 0; b < 2; ++b) {
            const double w = (a ? fq : 1.0 - fq) * (b ? fz : 1.0 - fz);
            const float* t0 = kTuning[instrument][q + a][r];
            const float* t1 = kTuning[instrument][q + a][r + 1];
            out += w * (t0[z + b] + (t1[z + b] - t0[z + b]) * fr);
        }
    return out;
}

// A delay line read through a first-order allpass (Thiran; J. O. Smith, PASP "Delay-line interpolation"): flat gain
// at every fraction (a linear read is a low-pass that changes with the fraction, so the brightness fluttered with
// vibrato) for two reads and one multiply-add a sample. The integer part leaves a fraction in [0.5, 1.5), where the
// allpass is well behaved; its one sample of state goes with the tap. Coefficients per control block.
struct Tap {
    uint32_t i = 2;
    float eta = 0, y1 = 0;
    void set(float d) noexcept {
        d = std::max(d, 2.5f);
        i = static_cast<uint32_t>(d - 0.5f);
        const float frac = d - static_cast<float>(i);
        eta = (1.0f - frac) / (1.0f + frac);
    }
    float read(const timber::Line& l) noexcept {
        const uint32_t w = l.w, m = l.mask;
        const float x0 = l.buf[(w - i) & m], x1 = l.buf[(w - i - 1) & m];
        y1 = eta * (x0 - y1) + x1;
        return y1;
    }
    void flush() noexcept { y1 = timber::flushf(y1); }
};

// A bowed string after McIntyre, Schumacher and Woodhouse (JASA 74(5), 1983) in Smith's waveguide form, with the
// elasto-plastic bow of Timber's Simulated mode (Dupont et al., IEEE TAC 47(5), 2002; Serafin, Avanzini and
// Rocchesso, SMAC 2003; timber_strings.h). What changes against it, from the realism research (2026-11-24):
// - The bow's normal force follows the bow's speed: fn = vb kmin^(1 - p) kmax^p, so every note, soft or loud, stays
//   inside Schelleng's window (JASA 53(1), 1973: the force range for Helmholtz motion grows with the bow speed and
//   narrows near the bridge), and Pressure is a place in that window (0 near the least: flautando; 1 near the most:
//   a dig), a little past each end at the extremes. The window's ends are measured on this model per instrument,
//   bow position and key (nightingale_window.inc). Timber's force ignored the speed, so loud high notes locked onto
//   the octave and soft ones scraped.
// - Attack and release: the bow's speed follows a smoothstep over Attack (and Release), and since the force follows
//   the speed, the bow enters and leaves the string inside Guettler's region (a clean start) instead of starting
//   at full force on a still bow (a scrape at every onset and release). Released, the bow lifts at speed 0.
// - Bow noise at the output, never in the string: band-limited noise whose level follows the sliding speed,
//   smoothed over a millisecond (Chafe's pulsed noise, ICMC 1990, made gentle), scaled by Noise.
// - The delays read by allpass interpolation; vibrato and pitch bends move the nut side only (the finger), the
//   bridge side (the bow's place) is set when the note starts; Newton's method takes one step (two at High: the
//   second cost 30 % and changed nothing the tests measure).
// - The body: the instrument's estimated response (BodyResponse, eight peaking bands) after the voices' sum, Body
//   scaling its bands' gains (1 the recorded instrument, 0 the bare string), in place of five resonances.
struct Bowed {
    static constexpr uint32_t kEcoCap = 8, kNormalCap = 8, kHighCap = 8, kPool = 16 + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = false;
    static constexpr double kMinLife = 0.05, kSpread = 0.3;
    enum P : uint32_t { kPressure, kSpeed, kPosition, kVibrato, kVibRate, kAttack, kNoise, kTier, kModelParams };

    struct Voice : VoiceBase {
        timber::Line neck, bridge;
        Tap tn, tb;
        float db = 2;  // the bridge side's delay, set at the note's start
        float lp = 0, dc = 0;
        float u = 0, uStep = 0;  // the bow's envelope 0..1 (its speed is target x smoothstep(u))
        float target = 0;        // the bow's full speed for this note
        float kF = 10;           // the force factor: fn = kF x the bow's speed (its window, at this note)
        double pull = 0;         // the tuning's offset for the bow's pull (cents)
        double forPitch = -1, forPp = -1, forPos = -1;  // what kF and pull were worked out for (kept until one moves)
        double vib = 0, baseHz = 440;
        float vibAmount = 0;
        uint32_t age = 0;
        float z = 0, zd = 0, zt = 0, invZss = 1e9f;
        bool lifted = false;
        float liftG = 1;  // the bow leaving the string: its force and the bridge's loss eased over 5 ms (1 on it, 0 off)
        float nEnv = 0, nHp = 0, nLp = 0;  // the bow noise's envelope and its band filter
        timber::Noise noise;
        uint32_t counted = 0;  // samples played (the tests read it)
    };

    int instrument = 0;  // 0 violin, 1 viola, 2 cello, 3 bass (the variant)
    double pressure = 0.5, speed = 0.5, position = 0.5, vibrato = 0.3, vibRate = 5.5, attack = 0.12, noiseLevel = 0.35;
    int tier = kQualityNormal, iterations = 2;
    float lpk = 0;
    double sr = 48000, modWheel = 0, beta = 0.1, releaseS = 0.25;
    double pp = 0.5;  // Pressure's place in the window (per control block)
    // The elasto-plastic bow (Timber's): stiffness, the bristles' damping, the friction coefficients, the Stribeck
    // speed and the breakaway share.
    float sigma0 = 4800.0f, sigma1 = 0.3f, muS = 0.45f, muD = 0.2f, vStribeck = 0.1f, breakaway = 0.7f;
    static constexpr float kNoiseGain = 0.036f;  // the bow noise at Noise 0.35: about 35 dB under the tone (nightingale_test)
    float bodyAmount = 1;
    std::unique_ptr<float[]> memory;
    uint32_t lineLen = 0, count = 0;
    Voice* voices = nullptr;
    BodyFilter body;
    bool testBypassBody = false;
    float testForceK = 0;  // the tests' sweep of the force (0: from Pressure)

    size_t allocBytes() const noexcept { return static_cast<size_t>(count) * 2 * lineLen * sizeof(float); }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 0.5, r.decay = 0.8, r.damping = 0.5, r.mix = 1.0, r.width = 1.0, r.preDelay = 0.008;
        return r;
    }
    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        sr = rate;
        voices = v, count = n;
        lineLen = timber::pow2At(static_cast<uint32_t>(sr / 30.0) + 16);
        memory.reset(new (std::nothrow) float[static_cast<size_t>(n) * 2 * lineLen]());
        if (!memory) return false;
        bindAll();
        loadBody();
        return true;
    }
    // The instrument's bands at the rate, their gains scaled by Body (at prepare and when Body or the rate moves).
    void loadBody() noexcept { body.load(bodyResponse(instrument), bodyAmount, sr); }
    void bindAll() noexcept {
        for (uint32_t k = 0; k < count; ++k) {
            voices[k].neck.bind(memory.get() + static_cast<size_t>(2 * k) * lineLen, lineLen);
            voices[k].bridge.bind(memory.get() + static_cast<size_t>(2 * k + 1) * lineLen, lineLen);
        }
    }
    void reset() noexcept {
        bindAll();
        clearPost();
    }
    void control(const double* p, const Shared& s) noexcept {
        pressure = clampd(p[kPressure], 0, 1);
        speed = clampd(p[kSpeed], 0, 1);
        position = clampd(p[kPosition], 0, 1);
        vibrato = clampd(p[kVibrato], 0, 1);
        vibRate = clampd(p[kVibRate], 2, 9);
        attack = clampd(p[kAttack], 0.005, 2);
        noiseLevel = clampd(p[kNoise], 0, 1);
        const int t = static_cast<int>(clampd(p[kTier], 0, 3) + 0.5);
        tier = t == 0 ? s.quality : t - 1;
        iterations = tier == kQualityHigh ? 2 : 1;  // Newton's steps: one holds the window (the tests), High adds one
        modWheel = s.modWheel;
        releaseS = std::max(0.01, s.release);
        bodyAmount = static_cast<float>(clampd(s.body, 0, 1));
        loadBody();
        // Bow position: 0 sul ponticello (beta 0.04) .. 1 sul tasto (0.2), 0.5 the usual place (about 0.09).
        beta = 0.04 * detPow(5.0, position);
        pp = -0.1 + 1.2 * pressure;  // a little past each end of the window at the extremes
        constants();
        // Noise: 0.35 (the default) about 35 dB under the tone, as recorded; above it the rosin's scratch comes forward
        // faster (a square law: 1 is about 17 dB under the tone, a close-miked, rough bow), below it fades out.
        nGain_ = static_cast<float>(kNoiseGain * (noiseLevel / 0.35) * (noiseLevel / 0.35));
        // The bridge's loss in the loop: Timber's 4 kHz (2.5 kHz for cello and bass) made every note dull; against
        // the VSCO recordings the model was 10-20 dB short at 2-6 kHz, so the corner moved up (the body corrects the rest).
        lpk = static_cast<float>(1.0 - detExp(-timber::kTwoPi * (instrument >= 2 ? 6000.0 : 9000.0) / sr));
    }
    void start(Voice& v, const Shared&) noexcept {
        v.neck.clear();
        v.bridge.clear();
        v.tn.y1 = v.tb.y1 = 0;
        v.lp = v.dc = 0;
        v.u = 0;
        v.uStep = static_cast<float>(1.0 / std::max(1.0, attack * sr));
        v.vib = 0, v.vibAmount = 0, v.age = 0;
        v.z = v.zd = v.zt = 0, v.invZss = 1e9f;
        v.lifted = false;
        v.liftG = 1;
        v.nEnv = v.nHp = v.nLp = 0;
        v.counted = 0;
        v.noise.s = 0xB0A1u + 17u * v.key;
        v.baseHz = timber::noteHz(clampd(v.pitch, 24.0, 108.0));
        const double period = sr / v.baseHz - 1.2;  // less the bridge filter's own delay
        // At least 4 samples to the bridge: on the shortest strings (a violin's top, 18 samples a period) the bow sits
        // a little further out, where its window is wide; at 2 the bow's place was lost to the sample grid.
        v.db = static_cast<float>(std::clamp(period * beta, 4.0, static_cast<double>(v.bridge.mask - 4)));
        v.tb.set(v.db);
        v.forPitch = -1;
        refresh(v);
        tune(v, 0.0);
    }
    // The nut side follows the pitch (vibrato, bends); the bridge side stays where the bow is.
    // The elastic bow's flattening, aimed off: it grows with the force and on shorter strings, so it is measured
    // per instrument, bow position, pressure and key (nightingale_tuning.inc), interpolated.
    double tuneOffset(double key) const noexcept { return tuningOffset(instrument, position, pressure, key); }
    void tune(Voice& v, double cents) noexcept {
        const double hz = timber::noteHz(clampd(v.pitch, 24.0, 108.0)) * lib::fastExp((cents + v.pull) * 5.776226504666211e-4);
        const double period = sr / hz - 1.2;
        const float dn = static_cast<float>(std::clamp(period - v.db, 2.0, static_cast<double>(v.neck.mask - 4)));
        v.tn.set(dn);
    }
    // The note's force factor and tuning offset, worked out again only when its pitch, Pressure or the bow's place moved.
    void refresh(Voice& v) noexcept {
        if (v.pitch == v.forPitch && pp == v.forPp && position == v.forPos) return;
        v.forPitch = v.pitch, v.forPp = pp, v.forPos = position;
        v.kF = testForceK > 0 ? testForceK : static_cast<float>(windowFactor(instrument, position, v.pitch, pp));
        v.pull = tuneOffset(v.pitch);
    }
    void release_(Voice& v) noexcept { v.uStep = -static_cast<float>(1.0 / std::max(1.0, releaseS * sr)); }
    void release(Voice& v, const Shared&) noexcept { release_(v); }
    void voiceControl(Voice& v, const Shared&) noexcept {
        const double dt = kControlFrames / sr;
        v.age += kControlFrames;
        // The vibrato comes in after the bow has caught the string: from 0.12 s, over 0.25 s (it waited 0.25 s and
        // took 0.4, so a short note never had any).
        if (v.age > 0.12 * sr) v.vibAmount = std::min(1.0f, v.vibAmount + static_cast<float>(dt / 0.25));
        v.vib += vibRate * dt;
        v.vib -= std::floor(v.vib);
        const float expr = static_cast<float>(std::max(v.pressure, modWheel));
        v.target = static_cast<float>((0.05 + 0.25 * speed) * (0.45 + 0.55 * v.velocity)) * (1.0f + 0.8f * expr);
        refresh(v);
        // Wider on the low strings, where the same cents move fewer Hz: a cello's x 1.4, a bass's x 1.8.
        static constexpr double kWidth[4] = {1.0, 1.15, 1.4, 1.8};
        tune(v, 25.0 * kWidth[instrument] * vibrato * v.vibAmount * lib::fastSinCycles(v.vib));
        v.lp = timber::flushf(v.lp), v.dc = timber::flushf(v.dc), v.z = timber::flushf(v.z);
        v.zd = timber::flushf(v.zd), v.zt = timber::flushf(v.zt), v.nEnv = timber::flushf(v.nEnv);
        v.nHp = timber::flushf(v.nHp), v.nLp = timber::flushf(v.nLp);
        v.tn.flush(), v.tb.flush();
        // The bow stopped: it leaves the string over 5 ms (lifted at once, its last force vanished in one sample, a
        // click at every release: 25-58 dB over the running step, instrument_glitch_scan).
        // Released, the bow also leaves gradually over the last 40 % of its slowing: at a force that low the stick-slip
        // fell into a sample-rate buzz (cello and bass, 24-27 dB over the running step) before the bow had stopped.
        if (v.uStep < 0.0f) {
            const float q = std::clamp(v.u / 0.7f, 0.0f, 1.0f);
            v.liftG = std::min(v.liftG, q * q * (3.0f - 2.0f * q));
        }
        if (v.uStep < 0.0f && v.u <= 0.0f) v.liftG = std::max(0.0f, v.liftG - static_cast<float>(kControlFrames / (0.005 * sr)));
        v.lifted = v.liftG <= 0.0f;
    }
    // Per-sample constants, worked out at prepare and when the rate or a knob that sets them changes (control()).
    float dck_ = 0, k2_ = 0, invOneB_ = 0, cz_ = 0, cg_ = 0, c1_ = 0, c2_ = 0, B_ = 0, invSpan_ = 0, invVs2_ = 0;
    float envK_ = 0, hpK_ = 0, lpK2_ = 0, nGain_ = 0;
    double constsFor_ = -1;
    void constants() noexcept {
        if (constsFor_ == sr) return;
        constsFor_ = sr;
        dck_ = static_cast<float>(timber::kTwoPi * 20.0 / sr);
        k2_ = static_cast<float>(0.5 / sr);
        B_ = sigma0 * k2_ + sigma1, invOneB_ = 1.0f / (1.0f + B_);
        cz_ = 1.0f - k2_ * sigma0 * invOneB_, cg_ = k2_ * invOneB_;
        c1_ = 1.0f - 2.0f * k2_ * sigma0 * invOneB_, c2_ = 2.0f * k2_ * invOneB_;
        invSpan_ = 1.0f / (1.0f - breakaway), invVs2_ = 1.0f / (vStribeck * vStribeck);
        envK_ = static_cast<float>(1.0 - detExp(-1.0 / (0.001 * sr)));  // 1 ms
        hpK_ = static_cast<float>(1.0 - detExp(-timber::kTwoPi * 1500.0 / sr));
        lpK2_ = static_cast<float>(1.0 - detExp(-timber::kTwoPi * 7000.0 / sr));
    }
    void prime(Voice& v) noexcept {
        if (v.target != 0.0f) return;  // the first block, before voiceControl ran
        const float expr = static_cast<float>(std::max(v.pressure, modWheel));
        v.target = static_cast<float>((0.05 + 0.25 * speed) * (0.45 + 0.55 * v.velocity)) * (1.0f + 0.8f * expr);
        refresh(v);
    }
    void render(Voice& v, float* out, uint32_t n) noexcept {
        Voice* one[1] = {&v};
        float buf[1][kControlFrames];
        renderGroup(one, 1, buf, n);
        std::copy(buf[0], buf[0] + n, out);
    }
    // Voices run four at a time (instrument_core.h's GroupedModel), one a lane, so four voices' friction chains overlap
    // instead of waiting on each other; lanes past `count` repeat the first voice and are thrown away. Each lane's
    // state is in locals (the delay lines' stores could otherwise alias it, and the compiler would reload all of it
    // every sample).
    bool grouped() const noexcept { return true; }
    CAW_TIMBER_NOINLINE void renderGroup(Voice* const* vs, uint32_t count, float (*out)[kControlFrames], uint32_t n) noexcept {
        Voice* lane[4];
        for (uint32_t l = 0; l < 4; ++l) lane[l] = vs[l < count ? l : 0];
        for (uint32_t l = 0; l < count; ++l) prime(*lane[l]);
        using timber::F4;
        using timber::I4;
        const F4 zero = timber::f4(0.0f), one = timber::f4(1.0f);
        const F4 dck = timber::f4(dck_), k2 = timber::f4(k2_), s0 = timber::f4(sigma0), s1 = timber::f4(sigma1);
        const F4 brk = timber::f4(breakaway), invSpan = timber::f4(invSpan_), invVs2 = timber::f4(invVs2_), B = timber::f4(B_);
        const F4 invOneB = timber::f4(invOneB_), cz = timber::f4(cz_), cg = timber::f4(cg_), c1 = timber::f4(c1_), c2 = timber::f4(c2_);
        const F4 envK = timber::f4(envK_), hpK = timber::f4(hpK_), lpK2 = timber::f4(lpK2_), nGain = timber::f4(nGain_);
        const F4 lpk4 = timber::f4(lpk), muS4 = timber::f4(muS), muD4 = timber::f4(muD), tiny = timber::f4(1e-9f), big = timber::f4(1e9f);
        F4 u, uStep, target, kF, reflect, z, zdL, zt, invZss, lp, dc, nEnv, nHp, nLp, liftG;
        I4 lifted;
        Tap tn[4], tb[4];
        timber::Line neck[4], bridge[4];
        timber::Noise noise[4];
        for (uint32_t l = 0; l < 4; ++l) {
            const Voice& v = *lane[l];
            u[l] = v.u, uStep[l] = v.uStep, target[l] = v.target, kF[l] = v.kF;
            lifted[l] = v.lifted ? -1 : 0;
            reflect[l] = v.lifted ? 0.8f : (v.liftG >= 1.0f ? 0.97f : 0.8f + 0.17f * v.liftG);
            liftG[l] = v.liftG;
            z[l] = v.z, zdL[l] = v.zd, zt[l] = v.zt, invZss[l] = v.invZss, lp[l] = v.lp, dc[l] = v.dc;
            nEnv[l] = v.nEnv, nHp[l] = v.nHp, nLp[l] = v.nLp;
            tn[l] = v.tn, tb[l] = v.tb, neck[l] = v.neck, bridge[l] = v.bridge, noise[l] = v.noise;
        }
        const int iters = iterations;
        for (uint32_t i = 0; i < n; ++i) {
            u = timber::clamp4(u + uStep, zero, one);
            const F4 sh = u * u * (timber::f4(3.0f) - timber::f4(2.0f) * u);
            const F4 vb = target * sh;
            // The force rises behind the bow's speed (as the square of its shape): a force leading the speed started C#4
            // on its octave (double slipping) for 140 ms; this way every key settles into one slip a period within 110 ms
            // (nightingale_onsets). Never under 2 % of the note's full-speed force (a bow resting lightly): at zero force
            // the bristles' limit zss goes to 0 and Newton's step diverged as a released bow stopped.
            const F4 fn = kF * target * timber::max4(sh * sh, timber::f4(0.02f));
            const F4 fs = muS4 * fn, fc = muD4 * fn;
            F4 nb, bb, w;
            for (uint32_t l = 0; l < 4; ++l) nb[l] = tn[l].read(neck[l]), bb[l] = tb[l].read(bridge[l]), w[l] = noise[l].next();
            const F4 g1 = vb - (nb + bb);
            const F4 A = g1 - s0 * zt;
            F4 zd = A * invOneB;
            const F4 z0 = zt * cz + g1 * cg, vr0 = A - B * zd;
            F4 zNew = z0, ztNext = zt * c1 + g1 * c2;
            const I4 slips = timber::and4(timber::and4(timber::gt4(vr0, zero), timber::gt4(z0, zero)), timber::gt4(timber::abs4(z0) * invZss, brk));
            if (timber::any4(slips)) {
                F4 zn = zdL;
                for (int it = 0; it < iters; ++it) {
                    const F4 vr = A - B * zn;
                    const F4 zz = zt + k2 * zn, ratio = timber::abs4(zz) * invZss;
                    const F4 t = timber::min4(one, (ratio - brk) * invSpan);
                    const I4 on = timber::and4(timber::and4(timber::gt4(vr, zero), timber::gt4(zz, zero)), timber::gt4(ratio, brk));
                    const F4 a = timber::sel4(on, t * t * (timber::f4(3.0f) - timber::f4(2.0f) * t), zero);
                    // At most -1: as the bow's force falls (a release, a lighter pressure) the bristles' steady
                    // deflection zss shrinks under the one they hold (z / zss up to 4) and they relax back; unbounded,
                    // the step's 1 + B g crossed zero and one sample spiked 25-60 dB over the note (instrument_glitch_scan).
                    const F4 g = timber::max4(one - a * ratio, zero - one);
                    // 1 / (1 + x) by its series, which holds only for small x: x kept within [0, 1].
                    const F4 x = timber::clamp4(B * g + timber::abs4(vr) * a * k2 * invZss, zero, one);
                    zn = zn + (vr * g - zn) * (one - x + x * x);
                }
                zd = timber::sel4(slips, zn, zd);
                const F4 zs = zt + k2 * zn;
                zNew = timber::sel4(slips, zs, zNew);
                ztNext = timber::sel4(slips, zs + k2 * zn, ztNext);
            }
            const F4 ff = s0 * zNew + s1 * zd;
            const F4 vr = g1 - ff;
            zdL = timber::sel4(lifted, zero, zd);
            z = timber::sel4(lifted, zero, zNew);
            zt = timber::sel4(lifted, zero, ztNext);
            const F4 f = timber::sel4(lifted, zero, ff * liftG);
            const F4 slide = timber::sel4(lifted, zero, timber::abs4(vr) * liftG);
            const F4 e1 = one + vr * vr * invVs2;
            invZss = timber::sel4(timber::gt4(fn, tiny), timber::div4(s0 * e1, fc * e1 + fs - fc), big);
            const F4 toBridge = nb + f;
            lp = lp + lpk4 * (toBridge - lp);
            dc = dc + dck * (toBridge - dc);
            const F4 back = zero - (bb + f), fromBridge = zero - reflect * lp;
            // Bow noise: band-limited (1.5..7 kHz), its level the sliding speed while the bow moves, at the output.
            nEnv = nEnv + envK * (slide * sh - nEnv);
            nHp = nHp + hpK * (w - nHp);
            nLp = nLp + lpK2 * ((w - nHp) - nLp);
            const F4 o = (toBridge - dc) * timber::f4(0.3f) + nLp * nEnv * nGain;
            for (uint32_t l = 0; l < count; ++l) {
                neck[l].push(back[l]);
                bridge[l].push(fromBridge[l]);
                out[l][i] = o[l];
            }
        }
        for (uint32_t l = 0; l < count; ++l) {
            Voice& v = *lane[l];
            v.u = u[l], v.z = z[l], v.zd = zdL[l], v.zt = zt[l], v.invZss = invZss[l], v.lp = lp[l], v.dc = dc[l];
            v.nEnv = nEnv[l], v.nHp = nHp[l], v.nLp = nLp[l];
            v.neck.w = neck[l].w, v.bridge.w = bridge[l].w, v.noise = noise[l];
            v.tn.y1 = tn[l].y1, v.tb.y1 = tb[l].y1;
            v.counted += n;
        }
    }
    void post(float* l, float* r, uint32_t n, const Shared&) noexcept {
        if (!testBypassBody) body.process(l, r, n);
    }
    bool postQuiet() const noexcept { return true; }
    void clearPost() noexcept { body.clear(); }
    void display(float* out) const noexcept {
        out[0] = static_cast<float>(instrument);
        out[1] = static_cast<float>(pressure);
        out[2] = static_cast<float>(speed);
    }
};

}  // namespace caw::nightingale
