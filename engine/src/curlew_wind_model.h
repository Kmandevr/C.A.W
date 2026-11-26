// Curlew's winds model (Timber's Simulated winds, 1.1.2: blown-pipe waveguides for clarinet, flute, sax and brass).
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <new>

#include "caw/library/fastmath.hpp"
#include "instrument_core.h"
#include "instrument_noinline.h"  // CAW_TIMBER_NOINLINE

namespace caw::timber {

// ---------- Winds ----------

// Blown pipes: Timber's Simulated winds (1.1.2; the Classic ones they were beside left with Timber in 1.1.3), the
// model Curlew (curlew_winds.h) plays. Each kind is a bore delay line with the published excitation for it (the
// physics is described at renderSim below): the clarinet's reed on a cylinder, the flute's jet, the sax's reed on a
// cone and the brass's lips. Breath is an envelope (`attack`, the shared `release`) times `breath`, the velocity,
// poly pressure and the mod wheel; `noise` adds breath turbulence; `vibrato` moves the breath and a little the
// pitch; `growl` modulates it at about 35 Hz (a growled sax). Each kind's pitch pull is aimed off by a measured
// table (Curlew's own, curlew_tuning.inc).
struct Wind {
    static constexpr uint32_t kEcoCap = 8, kNormalCap = 8, kHighCap = 8, kPool = 16 + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = false;
    static constexpr double kMinLife = 0.05, kSpread = 0.25;
    enum P : uint32_t { kInstrument, kBreath, kNoise, kReed, kVibrato, kVibRate, kGrowl, kAttack, kModelParams };

    struct Voice : VoiceBase {
        Line bore, jet;
        float d = 2, dj = 2, lp = 0, dcx = 0, dcy = 0, ox = 0, oy = 0;
        float env = 0, envStep = 0;
        double vib = 0, growl = 0;
        float g = 1, gStep = 0;  // the growl's gain, in a straight line over each control block
        float lipA1 = 0, lipA2 = 0, lipG = 0, lip1 = 0, lip2 = 0;
        Noise noise;
        double tunedPitch = -1, baseHz = 440;
        // The tongue on the reed (1 closed), the jet's last flow and travel ramp, the sax's apex line length (the
        // jet line serves it), the High reed's mass-spring, the last turbulence.
        float jetU = 0, jetUStep = 0, coneA = 0, apX = 0, apY = 0, tongue = 0, tongueStep = 0, q1 = 0, djStep = 0, djCur = 2, da = 2, reed1 = 0, reed2 = 0, turb = 0;
    };

    int instrument = 0;
    double breath = 0.6, noise = 0.15, reed = 0.5, vibrato = 0.2, vibRate = 5, growl = 0, attack = 0.04;
    bool steep = true, dynamicReed = false;
    float reedA1 = 0, reedA2 = 0, reedG = 0;
    float jetGain = 1.2f, jetDiff = 0.0f, jetOffset = 0.2f, jetRatio = 0.5f, boreLp = 0.3f, coneK = 3.0f, saxLp = 0.5f, lipOpen = 4.0f, lipFlow = 0.18f, lipRatio = 0.9f, lipMax = 6.0f, steepK = 15.0f, turbFloor = 0.01f, jetSharp = -3.0f;
    double sr = 48000, modWheel = 0;
    std::unique_ptr<float[]> memory;
    uint32_t lineLen = 0, count = 0;
    Voice* voices = nullptr;

    size_t allocBytes() const noexcept { return static_cast<size_t>(count) * 2 * lineLen * sizeof(float); }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 0.6, r.decay = 1.7, r.damping = 0.5, r.mix = 1.0, r.width = 1.0, r.preDelay = 0.01;
        return r;
    }
    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        sr = rate;
        voices = v, count = n;
        lineLen = pow2At(static_cast<uint32_t>(sr / 30.0) + 16);
        memory.reset(new (std::nothrow) float[static_cast<size_t>(n) * 2 * lineLen]());
        if (!memory) return false;
        bindAll();
        return true;
    }
    void bindAll() noexcept {
        for (uint32_t k = 0; k < count; ++k) {
            voices[k].bore.bind(memory.get() + static_cast<size_t>(2 * k) * lineLen, lineLen);
            voices[k].jet.bind(memory.get() + static_cast<size_t>(2 * k + 1) * lineLen, lineLen);
        }
    }
    void reset() noexcept { bindAll(); }
    void control(const double* p, const Shared& s) noexcept {
        instrument = static_cast<int>(clampd(p[kInstrument], 0, 3) + 0.5);
        breath = clampd(p[kBreath], 0, 1);
        noise = clampd(p[kNoise], 0, 1);
        reed = clampd(p[kReed], 0, 1);
        vibrato = clampd(p[kVibrato], 0, 1);
        vibRate = clampd(p[kVibRate], 2, 9);
        growl = clampd(p[kGrowl], 0, 1);
        attack = clampd(p[kAttack], 0.005, 2);
        modWheel = s.modWheel;
        steep = s.quality != kQualityEco;          // Eco: no brassy steepening
        dynamicReed = s.quality == kQualityHigh;  // High: the reed as a mass-spring
        if (dynamicReed) {  // the reed's own resonance (about 2.3 kHz, damped), unit gain at DC
            const double w = kTwoPi * std::min(2300.0, 0.4 * sr) / sr, r = 0.86;
            reedA1 = static_cast<float>(2.0 * r * std::cos(w)), reedA2 = static_cast<float>(-r * r);
            reedG = 1.0f - reedA1 - reedA2;
        }
    }
    // Each kind's remaining pull at five keys (cents), measured in 1.1.2's tests (Curlew sets its own table).
    static double simPull(int instrument, double pitch) noexcept {
        static constexpr double kKey[5] = {45, 50, 62, 74, 81};
        static constexpr double kPull[4][5] = {{0, 0, 0, 1, 2}, {84, 63, 26, 12, 3}, {104, 65, 32, 19, 14}, {140, 106, 57, 35, 34}};
        const double* p = kPull[instrument];
        if (pitch <= kKey[0]) return p[0];
        for (int i = 1; i < 5; ++i)
            if (pitch <= kKey[i]) return p[i - 1] + (p[i] - p[i - 1]) * (pitch - kKey[i - 1]) / (kKey[i] - kKey[i - 1]);
        return p[4];
    }
    void tune(Voice& v, double cents) noexcept {
        // Brass: the lips pull the pitch by a measured amount that grows down the range; it is aimed off by that.
        if (v.pitch != v.tunedPitch) {  // the note's own pitch, aimed off by its kind's pull (worked out once)
            double aim = -simPull(instrument, v.pitch);
            if (pullTable) aim = -pullAt(v.pitch);  // Curlew: its own pull, measured over each instrument's range
            v.baseHz = noteHz(clampd(v.pitch, 28.0, 108.0) + aim / 100.0);  // (Curlew 2026-11-26: the tuba, the piccolo)
        }
        const double f0 = v.baseHz * lib::fastExp(cents * 5.776226504666211e-4);  // ln 2 / 1200
        const double period = sr / f0;
        // Clarinet and sax: half a period (closed at the reed, inverted at the bell). Flute: the model speaks at 1.5x
        // its bore's lowest mode, so the bore is 1.5 periods. Brass: the lips pick the bore's 2nd mode (2 periods).
        static constexpr double kBore[4] = {0.5, 1.5, 0.5, 2.0};
        const float cap = static_cast<float>(v.bore.mask - 4);
        const double bore = instrument == 3 && brassBore > 0 ? brassBore : kBore[instrument];
        v.d = std::min(cap, static_cast<float>(std::max(2.0, bore * period - 1.0)));
        v.dj = std::min(cap, static_cast<float>(std::max(2.0, v.d * (0.28 + 0.1 * reed))));
        if (instrument == 1) {  // an open-open pipe: a period round trip, both ends inverting (+1 in all)
            v.d = std::min(cap, static_cast<float>(std::max(2.0, period - 1.0)));
            v.dj = std::min(cap, static_cast<float>(std::max(2.0, v.d * (jetRatio + 0.1 * (reed - 0.5)))));
        }
        if (instrument == 2) {  // the cone: a period round trip less the closed end's and the bell's delays
            const double w0 = kTwoPi * f0 / sr, K = 2.0, wc = coneK * w0;
            const double a = (K - wc) / (K + wc);
            v.coneA = static_cast<float>(a);
            const double rest = period - onePoleDelay(1.0 - saxLp, w0) - allpassDelay(-a, w0);
            v.d = std::min(cap, static_cast<float>(std::max(2.0, rest)));
        }
        if (instrument == 3) {  // the lips: a two-pole resonance at the note
            // Curlew widens the lips' tension (lipSpan) around the same middle, so Lips is heard on every brass.
            const double lr = lipSpan > 0 ? lipRatio + 0.01 + lipSpan * (reed - 0.5) : lipRatio + 0.02 * reed;
            const double w = kTwoPi * f0 * lr / sr;
            // Curlew: the lips' Q fixed (lipQ), not their bandwidth (Timber's r 0.997: Q 6 at C4, under 2 in the
            // bass, where the notes fell into other regimes), at Timber's peak gain.
            const double r = lipQ > 0 ? std::exp(-kPi * f0 * lr / (lipQ * sr)) : 0.997;
            v.lipA1 = static_cast<float>(2.0 * r * std::cos(w)), v.lipA2 = static_cast<float>(-r * r);
            v.lipG = static_cast<float>(0.002 * std::sin(w) / 0.043 * (lipQ > 0 ? (1.0 - r) / 0.003 : 1.0));  // the same peak gain at every pitch
        }
        v.tunedPitch = v.pitch;
    }
    void start(Voice& v, const Shared&) noexcept {
        v.bore.clear();
        v.jet.clear();
        v.lp = v.dcx = v.dcy = v.ox = v.oy = 0;
        v.env = 0;
        v.envStep = static_cast<float>(1.0 / std::max(1.0, attack * sr));
        v.vib = v.growl = 0;
        v.g = 1, v.gStep = 0;
        v.lip1 = v.lip2 = 0;
        v.noise.s = 0xB1ABu + 31u * v.key;
        v.tunedPitch = -1;
        tune(v, 0);
        // The tongue holds the reed (the lips, the flute's air) until the note's start, then leaves it in 4-12 ms.
        v.tongue = 1, v.tongueStep = -static_cast<float>(1.0 / (tongueScale * (0.012 - 0.008 * v.velocity) * sr));
        v.q1 = v.djStep = v.reed1 = v.reed2 = v.turb = v.apX = v.apY = v.jetU = v.jetUStep = 0;
        v.djCur = std::min(static_cast<float>(v.jet.mask - 4), v.dj * 2.5f);
    }
    // Curlew (1.1.3): a pull table of its own, `pullCount` keys a semitone apart from `pullFirst` (cents; linear between,
    // held outside), measured over each instrument's whole range (Timber's five keys held outside 45..81).
    const float* pullTable = nullptr;
    int pullFirst = 0, pullCount = 0;
    double pullAt(double pitch) const noexcept {
        const double k = clampd(pitch - pullFirst, 0.0, pullCount - 1.0);
        const int i = std::min(static_cast<int>(k), pullCount - 2);
        return pullTable[i] + (pullTable[i + 1] - pullTable[i]) * (k - i);
    }
    const float (*breathMod)[kControlFrames] = nullptr;  // Curlew (1.1.3): its growl, per lane and frame, times the breath
    // The vibrato's depth at Vibrato 1: the breath's share (Simulated) and the pitch (cents). Timber 0.05 and 8.
    double vibBreath = 0.05, vibCents = 8.0;
    float lipTurb = 0.5f;  // the breath's turbulence through the lips (Curlew sets its own)
    double lipQ = 0;       // Curlew (1.1.3): the lips' resonance Q at every pitch (0: Timber's fixed bandwidth)
    double tongueScale = 1;  // Curlew (1.1.3): the tongue's leave time over Timber's 4-12 ms
    double brassBore = 0;  // Curlew (1.1.3): the brass bore's round trip in periods (0: Timber's 2)
    double brassPush = 0.75, brassPushSpan = 0.5;  // the brass's mouth pressure over the velocity (Timber's)
    float lipCloseK = 20.0f;  // Curlew (1.1.3): with lipsCloseWithBreath, the lips close below 1 / lipCloseK of the breath
    float brassLp = 0;        // Curlew (1.1.3): the brass bore's wall loss, a one-pole on its reflection (0: none, Timber's)
    bool lipsCloseWithBreath = false;  // Curlew (1.1.3): the lips' rest gap closes as the breath ends
    double lipSpan = 0;  // Curlew (1.1.3): the lips' tension range over Lips 0..1 (Timber: 0.02 from 0)
    void release(Voice& v, const Shared& s) noexcept {
        v.envStep = -static_cast<float>(1.0 / std::max(1.0, std::max(0.01, s.release) * sr));
        if (s.release < 0.06)  // a short release is a tongued stop: the tongue back on the reed
            v.tongueStep = static_cast<float>(1.0 / (std::max(0.004, s.release) * sr));
    }
    void voiceControl(Voice& v, const Shared&) noexcept {
        const double dt = kControlFrames / sr;
        v.vib += vibRate * dt;
        v.vib -= std::floor(v.vib);
        tune(v, vibCents * vibrato * lib::fastSinCycles(v.vib));
        // The growl (about 35 Hz): its gain now and at the next control point, in a line between.
        // No growl: exactly 1 and no step, without the two sines.
        const double amt = 0.4 * growl;
        v.g = amt > 0.0 ? static_cast<float>(1.0 + amt * lib::fastSinCycles(v.growl)) : 1.0f;
        v.growl += 35.0 * dt;
        v.growl -= std::floor(v.growl);
        v.gStep = amt > 0.0 ? static_cast<float>((1.0 + amt * lib::fastSinCycles(v.growl) - v.g) / kControlFrames) : 0.0f;
        v.lp = flushf(v.lp), v.dcx = flushf(v.dcx), v.dcy = flushf(v.dcy), v.ox = flushf(v.ox), v.oy = flushf(v.oy);
        v.lip1 = flushf(v.lip1), v.lip2 = flushf(v.lip2);
        {
            v.apX = flushf(v.apX), v.apY = flushf(v.apY), v.q1 = flushf(v.q1), v.reed1 = flushf(v.reed1), v.reed2 = flushf(v.reed2);
            if (instrument == 1) {  // the jet's travel time from its speed, U = sqrt(2 p / rho): toward its value at the next point
                const float p = std::max(0.16f, std::min(1.0f, v.env + v.envStep * kControlFrames) * pressureScale());
                const float target = std::min(static_cast<float>(v.jet.mask - 4), v.dj / std::sqrt(p));
                v.djStep = (std::max(2.0f, target) - v.djCur) / kControlFrames;
                // The jet's speed sqrt(p) now and at the next point, in a line between (the breath moves slowly).
                static constexpr float kLow = 0.9f, kSpan = 0.4f;
                const float push = static_cast<float>(0.9 + 0.2 * v.velocity) * (1.0f + 0.15f * static_cast<float>(std::max(v.pressure, modWheel)));
                const float base = (kLow + kSpan * static_cast<float>(breath)) * push;
                const float e1 = std::clamp(v.env + v.envStep * kControlFrames, 0.0f, 1.0f);
                const float u0 = std::sqrt(std::max(0.0f, v.env * base)), u1 = std::sqrt(std::max(0.0f, e1 * base));
                v.jetU = u0, v.jetUStep = (u1 - u0) / kControlFrames;
            }
        }
    }
    // Each kind speaks only in a window of mouth pressure (its excitation's own regime), so `breath` moves the
    // pressure within that window, and the velocity, poly pressure and mod wheel set the loudness.
    void render(Voice& v, float* out, uint32_t n) noexcept {
        Voice* one[1] = {&v};
        float buf[1][kControlFrames];
        renderSim(one, 1, buf, n);
        std::copy(buf[0], buf[0] + n, out);
    }
    static constexpr float kRadiate = 24.0f;  // the brass's radiation line's middle, in samples
    // The mouth pressure against the window's middle (breath 0.5): 1 there.
    float pressureScale() const noexcept { return static_cast<float>(0.5 + breath) / 1.0f; }

    // ---------- the simulation (1.1.2) ----------
    // Flute: the jet drive (Fletcher, JASA 60(2), 1976; Verge, Hirschberg and Causse, JASA 101(5), 1997): the jet
    // leaves the flue at U = sqrt(2 p / rho) and travels to the labium at about U / 2, so its delay is the nominal
    // one over sqrt(p) (a weak breath is slow: the attack's search; a strong one overblows); there the acoustic
    // flow has deflected it, and the share of it entering the pipe is 1/2 (1 + tanh((eta - y0) / b)) (the jet
    // offset y0 from `reed`); the pipe is driven by that flux's change. Breath turbulence (Verge et al.: amplitude
    // as U^2) enters with the flux, so it pulses with the period (Chafe, ICMC 1995). The tongue starts each note.
    // Clarinet and sax: the reed table (McIntyre, Schumacher and Woodhouse, JASA 74(5), 1983; Smith, ICMC 1986)
    // with the tongue as a contact on the reed (a closed reed reflects all and passes no flow), turbulence as the
    // flow through the reed, and at High the reed's own mass-spring resonance before the table. The sax's bore is
    // a cone: the reed sits between a short apex line and the bell line (both inverting, as r p in a cone), so it
    // sounds every harmonic (after Scavone's 1997 thesis, two waveguides of a truncated cone).
    // Brass: the lips as a mass-spring valve (after Adachi and Sato, JASA 99(2), 1996, one outward-striking mass):
    // its opening h = max(0, h0 + y), the flow h sqrt(|dp|) into the bore; brassiness (Hirschberg, Gilbert, Msallam
    // and Wijnands, JASA 99(3), 1996): the wave toward the bell travels faster where its pressure is high, so its
    // crests arrive early and it steepens with level (a read of the bore at a delay shortened by its own value).
    // Voices run four at a time (GroupedModel, instrument_core.h): each lane is one voice, so four voices' bore and lip
    // chains overlap instead of waiting on each other. Lanes past `count` repeat the first voice and are thrown away
    // (they never write its lines or its state).
    bool grouped() const noexcept { return true; }
    void renderGroup(Voice* const* vs, uint32_t count, float (*out)[kControlFrames], uint32_t n) noexcept { renderSim(vs, count, out, n); }
    CAW_TIMBER_NOINLINE void renderSim(Voice* const* vs, uint32_t count, float (*out)[kControlFrames], uint32_t n) noexcept {
        switch (instrument) {
            case 0: simKind<0>(vs, count, out, n); break;
            case 1: simKind<1>(vs, count, out, n); break;
            case 2: simKind<2>(vs, count, out, n); break;
            default: simKind<3>(vs, count, out, n); break;
        }
    }
    // One kind's loop (K: 0 clarinet, 1 flute, 2 sax, 3 brass), four voices a lane each.
    template <int K>
    void simKind(Voice* const* vs, uint32_t count, float (*out)[kControlFrames], uint32_t n) noexcept {
        Voice* lane[4];
        for (uint32_t l = 0; l < 4; ++l) lane[l] = vs[l < count ? l : 0];
        static constexpr float kOut[4] = {0.5f, 0.25f, 0.45f, 0.45f};
        static constexpr float kLow[4] = {0.5f, 0.9f, 0.55f, 0.3f}, kSpan[4] = {0.5f, 0.4f, 0.45f, 0.15f};
        const float turbAmt = static_cast<float>(0.5 * noise + turbFloor);
        const float y0 = static_cast<float>(jetOffset + 0.15 * (reed - 0.5));
        const float ks = steep ? static_cast<float>(steepK * sr / 48000.0) : 0.0f;
        // Each lane's constants and state, in locals (the bore's stores cannot then make the compiler reload the
        // state every sample). The ramps' running sums are four-lane values: no closed form can stand in for them.
        F4 base, loud, vibAm, slope, env, envStep, tongue, tongueStep, g, gStep, lp, dcx, dcy, lip1, lip2, reed1, reed2, apX, apY,
            turb, q1, ox, oy, coneA, lipG, lipA1, lipA2, djCur, djStep, jetU, jetUStep;
        float d[4];
        Line bore[4], jet[4];
        Noise nzs[4];
        for (uint32_t l = 0; l < 4; ++l) {
            const Voice& v = *lane[l];
            const float expr = static_cast<float>(std::max(v.pressure, modWheel));
            // The player blows harder for a louder note: the velocity and expression move the mouth pressure (so a
            // brass note brightens with level), the rest of the loudness is the gain.
            const float push = static_cast<float>(K == 3 ? brassPush + brassPushSpan * v.velocity : 0.9 + 0.2 * v.velocity) * (1.0f + 0.15f * expr);
            base[l] = (kLow[K] + kSpan[K] * static_cast<float>(breath)) * push;
            loud[l] = static_cast<float>(0.45 + 0.55 * v.velocity) * (1.0f + 0.4f * expr);
            vibAm[l] = static_cast<float>(vibBreath * vibrato * lib::fastSinCycles(v.vib));
            slope[l] = -static_cast<float>(0.19 + 0.06 * reed) / base[l];
            env[l] = v.env, envStep[l] = v.envStep, tongue[l] = v.tongue, tongueStep[l] = v.tongueStep, g[l] = v.g, gStep[l] = v.gStep;
            lp[l] = v.lp, dcx[l] = v.dcx, dcy[l] = v.dcy, lip1[l] = v.lip1, lip2[l] = v.lip2, reed1[l] = v.reed1, reed2[l] = v.reed2;
            apX[l] = v.apX, apY[l] = v.apY, turb[l] = v.turb, q1[l] = v.q1, ox[l] = v.ox, oy[l] = v.oy;
            coneA[l] = v.coneA, lipG[l] = v.lipG, lipA1[l] = v.lipA1, lipA2[l] = v.lipA2;
            djCur[l] = v.djCur, djStep[l] = v.djStep, jetU[l] = v.jetU, jetUStep[l] = v.jetUStep;
            d[l] = v.d;
            bore[l] = v.bore, jet[l] = v.jet;
            nzs[l] = v.noise;
        }
        const F4 zero = f4(0.0f), one = f4(1.0f);
        F4 bms[kControlFrames];  // the growl's breath, gathered once a block (no branch in the loop)
        for (uint32_t i = 0; i < n; ++i) {
            bms[i] = one;
            if (breathMod)
                for (uint32_t l = 0; l < 4; ++l) bms[i][l] = breathMod[l < count ? l : 0][i];
        }
        F4 nz = zero, b = zero, eta = zero;  // per-lane reads (the unused lanes read none: they stay 0)
        for (uint32_t i = 0; i < n; ++i) {
            env = clamp4(env + envStep, zero, one);
            tongue = clamp4(tongue + tongueStep, zero, one);
            const F4 open = one - tongue;
            // Curlew's growl, into the breath (the flute's: its jet; 1 when none: Timber never sets it).
            const F4 bm = bms[i];
            const F4 pm = env * base * (one + vibAm) * bm;
            g = g + gStep;
            for (uint32_t l = 0; l < count; ++l) nz[l] = nzs[l].next(), b[l] = bore[l].frac(d[l]);
            F4 w, y;
            if constexpr (K == 0) {  // clarinet
                lp = lp + f4(0.5f) * (b - lp);
                F4 dp = f4(-0.95f) * lp - pm;
                if (dynamicReed) {
                    const F4 r2 = f4(reedG) * dp + f4(reedA1) * reed1 + f4(reedA2) * reed2;
                    reed2 = reed1, reed1 = r2, dp = r2;
                }
                const F4 r = clamp4(f4(0.7f) + slope * dp, f4(-1.0f), one);
                const F4 re = r + (one - r) * tongue;
                const F4 flow = (one - re) * (pm + dp);
                turb = f4(turbAmt) * flow * nz;
                w = re * (f4(-0.95f) * lp) + (one - re) * pm + turb;
                y = w;
            } else if constexpr (K == 2) {  // sax: the cone
                lp = lp + f4(saxLp) * (b - lp);
                const F4 h = f4(-0.95f) * lp;
                // The truncated cone's closed end: (a - z^-1) / (1 - a z^-1), -1 at low frequencies (as an apex)
                // and +1 at high ones (as a closed cylinder).
                const F4 ap0 = coneA * h - apX + coneA * apY;
                apX = h, apY = ap0;
                const F4 ap = ap0 - dcx + f4(0.995f) * dcy;  // the bore passes no DC back (the mean flow leaves)
                dcx = ap0, dcy = ap;
                F4 dp = ap - pm;
                if (dynamicReed) {
                    const F4 r2 = f4(reedG) * dp + f4(reedA1) * reed1 + f4(reedA2) * reed2;
                    reed2 = reed1, reed1 = r2, dp = r2;
                }
                const F4 r = clamp4(f4(0.7f) + slope * dp, f4(-1.0f), one);
                const F4 re = r + (one - r) * tongue;
                const F4 flow = (one - re) * (pm - ap);
                turb = f4(turbAmt) * flow * nz;
                w = re * ap + (one - re) * pm + turb;
                y = w;
            } else if constexpr (K == 1) {  // flute
                lp = lp + f4(boreLp) * (b - lp);
                const F4 dd = lp - dcx + f4(0.995f) * dcy;
                dcx = lp, dcy = dd;
                const F4 t = dd;
                djCur = djCur + djStep;
                for (uint32_t l = 0; l < count; ++l) eta[l] = jet[l].frac(djCur[l]);
                const F4 U = jetU * open * bm;
                jetU = jetU + jetUStep;
                const F4 half = f4(0.5f) * t;
                for (uint32_t l = 0; l < count; ++l) jet[l].push(half[l]);
                // The flux into the pipe: softClip, lane by lane.
                const F4 sx = clamp4(f4(jetSharp) * (eta - f4(y0)), f4(-3.0f), f4(3.0f)), s2 = sx * sx;
                const F4 sc = div4(sx * (f4(27.0f) + s2), f4(27.0f) + f4(9.0f) * s2);
                const F4 q = f4(0.5f) * U * (one + sc);
                const F4 drive = f4(jetGain) * (q - f4(0.5f) * U) - f4(jetDiff) * (q - q1);
                q1 = q;
                turb = f4(turbAmt) * f4(0.6f) * U * q * nz;  // turbulence ~ U^2, entering with the flux
                w = drive + f4(0.5f) * t + turb;
                y = b;
            } else {  // brass
                if (brassLp > 0.0f) lp = lp + f4(brassLp) * (b - lp), b = lp;  // Curlew: the bore's wall loss
                const F4 dp = pm - f4(0.85f) * b;
                const F4 lip = lipG * dp + lipA1 * lip1 + lipA2 * lip2;
                lip2 = lip1, lip1 = lip;
                F4 hgt = clamp4(f4(0.02f) + f4(lipOpen) * lip, zero, f4(lipMax)) * open;  // the lips part only so far
                // Curlew: with no breath the lips close (their rest gap let the bore's own wave through the valve,
                // and a released low note kept sounding, -33 dB, 0.3 s after its release had ended).
                if (lipsCloseWithBreath) hgt = hgt * min4(one, env * f4(lipCloseK));
                const F4 root = sqrt4(abs4(dp));
                const F4 flow = hgt * sel4(gt4(dp, zero), root, zero - root);
                turb = f4(turbAmt) * f4(lipTurb) * abs4(flow) * nz;
                const F4 x = f4(0.85f) * b + f4(lipFlow) * flow + turb;
                const F4 dd = x - dcx + f4(0.995f) * dcy;
                dcx = x, dcy = dd;
                w = y = clamp4(dd, f4(-4.0f), f4(4.0f));
                if (ks > 0.0f) {
                    // Brassiness: on the way out to the bell (not in the loop: Hirschberg et al. find it matters
                    // for the radiated sound, not for the oscillation) a crest travels faster than a trough, so
                    // the wave steepens as it gets louder: a short line read earlier by the wave's own pressure.
                    const F4 at = clamp4(f4(kRadiate) - f4(ks) * y, one, f4(2.0f * kRadiate - 1.0f));
                    for (uint32_t l = 0; l < count; ++l) jet[l].push(y[l]);
                    for (uint32_t l = 0; l < count; ++l) y[l] = jet[l].frac(at[l]);
                }
            }
            for (uint32_t l = 0; l < count; ++l) bore[l].push(w[l]);
            const F4 o = y - ox + f4(0.995f) * oy;
            ox = y, oy = o;
            const F4 s = o * loud * g * f4(kOut[K]);
            for (uint32_t l = 0; l < count; ++l) out[l][i] = s[l];
        }
        for (uint32_t l = 0; l < count; ++l) {
            Voice& v = *lane[l];
            v.env = env[l], v.tongue = tongue[l], v.g = g[l];
            v.lp = lp[l], v.dcx = dcx[l], v.dcy = dcy[l], v.lip1 = lip1[l], v.lip2 = lip2[l], v.reed1 = reed1[l], v.reed2 = reed2[l];
            v.apX = apX[l], v.apY = apY[l], v.turb = turb[l], v.q1 = q1[l], v.ox = ox[l], v.oy = oy[l];
            v.djCur = djCur[l], v.jetU = jetU[l];
            v.bore.w = bore[l].w, v.jet.w = jet[l].w;
            v.noise = nzs[l];
        }
    }

    void post(float*, float*, uint32_t, const Shared&) noexcept {}
    bool postQuiet() const noexcept { return true; }
    void clearPost() noexcept {}
    void display(float* out) const noexcept {
        out[0] = static_cast<float>(instrument);
        out[1] = static_cast<float>(breath);
        out[2] = static_cast<float>(reed);
    }
};

}  // namespace caw::timber
