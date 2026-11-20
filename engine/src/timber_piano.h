// Timber's piano model: a commuted digital-waveguide piano (hammer-filtered soundboard excitation, coupled detuned strings, dampers, pedal and a shared sympathetic bank).
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <new>

#include "timber_core.h"
#include "timber_piano_sim.h"

namespace caw::timber {

// The piano (Timber's model 0). The method is Smith and Van Duyne's commuted piano synthesis (ICMC 1995; its
// patent US5777255 lapsed in 2010): the string is a filtered delay loop, and everything linear around it (the
// soundboard, the case, the room) is folded into the excitation that strikes it, a table read through a
// velocity-dependent hammer filter. Original code. What it deliberately is not (the design's reading of Modartt's
// US7915515B2, owner-settled 2026-11-19): there are no per-partial damping or frequency coefficients, no
// sum-of-partials renderer and no soundboard physical parameter anywhere. The loop's loss and dispersion filters
// are designed from target curves across the keyboard (decay times at the fundamental and at a high frequency,
// and an allpass coefficient per key), never partial by partial.
//
// Per voice: 1 string (the bass, below A#1), 2 (to A2) or 3, each a delay line with an exact first-order tuning
// allpass, M first-order dispersion allpasses (the stiff string's stretched partials) and a one-pole loss. The
// strings meet at a bridge that takes c x their sum from each (Weinreich's coupled strings): the in-phase motion
// drains fast (the prompt sound), the slight detuning moves energy into the out-of-phase motion, which drains
// slowly (the aftersound): the two-stage decay and the beating come from that, not from an envelope.
// The excitation: one of 24 soundboard tables (Grand, Upright, Felt x 8 zones; timber_tables.cpp), read again
// 0.6 and 1.5 ms later on hard strikes (the hammer's staggered contacts, the commuted paper's approach), minus a
// copy a strike position later (the notch at about the 8th partial), blended with a bare hammer pulse by `body`,
// through two one-poles whose cutoff rises with velocity and `hammer` (a louder strike is brighter).
// Dampers: a released key (below F#6, whose strings have none) is damped to `release` seconds unless the sustain
// pedal (the `sustain` knob or CC 64, half-pedal in between) holds it. Sympathetic resonance: one bank of 12
// undamped strings (C2..B2, so their harmonics cover every pitch class) fed by the piano's sum while the pedal is
// down, the cheapest form that still rings in tune.
//
// 1.1.2 adds a second mode, Simulated (`sim`; Classic stays the default and its bits are unchanged, its knobs all
// appended after the old ones). What Simulated does differently is in timber_piano_sim.h and at each `sim` branch
// below: the strike is a hammer force pulse from a build-time finite-difference simulation (timber_piano_tables.inc),
// injected at two taps (the strike point's comb comes from the physics); the dispersion is fitted to an
// inharmonicity curve; the soundboard is one shared parallel-section filter after the voice sum; loud bass notes
// glide down in pitch as their energy falls (the energy-based tension modulation); the dampers land over about
// 18 ms with a contact buzz from the string's own amplitude; the attack thump, the key bottoming on the keybed, the
// finger on the key and the pedal's trapwork and dampers are simulated contacts; held keys' strings take the bridge
// sum (sympathetic resonance) and, with the pedal down, a 32-mode register bank rings. The patent reading behind
// the damper and pedal noises is in docs/decisions.md (2026-11-20): nothing depends on how a key is released (a
// note-off's velocity is ignored), and no noise ever reaches the resonance.
struct Piano {
    static constexpr uint32_t kEcoCap = 16, kNormalCap = 32, kHighCap = 48, kPool = kHighCap + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = true;
    static constexpr double kMinLife = 0.15, kSpread = 0.6;
    enum P : uint32_t {
        kHammer, kCharacter, kUnison, kStretch, kDecay, kSustain, kSoft, kResonance,
        // 1.1.2, appended: Simulated's choice and knobs (Classic ignores every one).
        kSim, kTier, kNoise, kTouch, kAction, kGlide, kSympathy, kPhantom, kModelParams
    };
    static constexpr int kMaxDisp = 12, kSymp = 12;
    static constexpr int kRes = 24;  // Simulated's register bank (pedal down)

    struct Voice : VoiceBase {
        int strings = 0, disp = 0;
        Line line[3];
        uint32_t D[3] = {};
        // Four lanes (strings; the unused ones run on zeros), so the per-sample work is 4-wide SIMD.
        alignas(16) float eta[4] = {}, apx[4] = {}, apy[4] = {}, z[4] = {}, strike[4] = {};
        alignas(16) float dx[kMaxDisp][4] = {}, dy[kMaxDisp][4] = {};
        float a = 0, b = 0, p = 0, bUndamped = 0, pUndamped = 0, bDamped = 0, pDamped = 0;
        float c = 0;
        int i1 = 0, i2 = 0, is = 0;  // the excitation's offsets in whole table frames (48 kHz: no interpolation)
        float damp = 0;  // 0 free .. 1 fully damped (eased)
        // Excitation
        const int16_t* table = nullptr;
        double pos = 0, step = 1;
        float w1 = 0, w2 = 0, cs = 0, d1 = 0, d2 = 0, ds = 0, body = 1, pulseLen = 48, hk = 1, h1 = 0, h2 = 0, gain = 0;
        bool exciting = false;
        float out = 1;  // the output gain
        double tunedPitch = -1;
        bool hasDamper = true;
        double dampedFor = -1;  // the release the damped loss was worked out for
        // ---- Simulated (1.1.2) ----
        bool sim = false;
        const int16_t* pulse[4] = {};  // the hammer's force pulses: zones z0, z1 x layers l0, l1
        float pw[4] = {};              // their bilinear weights
        float tap = 0;                 // the strike point's reflection, in table frames
        float pgain = 0, thump = 0;    // the string's input gain; the force's share straight to the board
        double ppos = 0, pstep = 1;
        uint32_t wait = 0;             // frames until the hammer arrives (the action delay)
        float felt = 1, feltY = 0;     // the Felt board's felt rail (a one-pole on the force)
        double rest[3] = {};           // each string's loop delay past its integer part at the glide's zero
        double wrad[3] = {};
        float energy = 0, gE = 0, glideCents = 0, glideScale = 0;
        uint32_t glideTick = 0;
        float landGap = 0, landGap0 = 0;  // the damper felt's distance from the string while it lands
        bool landing = false;
        float sympC = 0;                // a silently held key's share of the bridge sum (0: the voice was struck)
        psim::Contact keybed, finger;
        uint32_t keybedAt = 0, fingerAt = 0;  // frames from note-on
        bool keybedPending = false, fingerPending = false;
        float keybedGain = 0, fingerGain = 0;
        Mode phantom[2];
        float phantomGain = 0;
        uint64_t simFrames = 0;
        double strikeFrame = -1, keybedFrame = -1;  // when each began (frames from note-on; the tests read them)
    };

    // Shared by every voice of the instance (read at control points).
    double hammer = 0.5, unison = 1.0, stretch = 1.0, decay = 1.0, sustain = 0, soft = 0, resonance = 0.3;
    int character = 0;
    double pedal = 0;  // the knob or CC 64, whichever is down further
    double sr = 48000;
    int quality = 1;
    float lastCutoff = 0, lastT60 = 0, lastStrings = 0;

    std::unique_ptr<float[]> memory;  // every voice's lines, and the sympathetic bank's
    Line symp[kSymp];
    float sympDelay[kSymp] = {}, sympB = 0, sympP = 0, sympZ[kSymp] = {};
    float sympPeak = 0;
    bool sympOn = false;
    Voice* voices = nullptr;
    uint32_t voiceCount = 0;

    // ---- Simulated (1.1.2) ----
    bool simMode = false, simActive = false;
    int tier = kQualityNormal;  // the tier Simulated runs at: the device's own choice, else the Settings one
    double noise = 0.35, touch = 0, glide = 0.5, sympathy = 0.5, phantomLevel = 0.5;
    bool action = false;
    float dispA[3][89] = {};  // the fitted dispersion coefficient per tier and key (A0..C8), at this rate
    psim::Board board;
    psim::ModeBank<kRes, false> res;
    psim::Resonator keyFrame, trapwork, damperRail;
    psim::Contact trap;
    float busBoard[kControlFrames] = {}, busFrame[kControlFrames] = {}, busBridge[kControlFrames] = {};
    float bridge[32] = {};  // the bridge sum's last 32 frames, by absolute frame (the held keys' input)
    uint64_t simPos = 0;
    bool pedalDown = false;
    uint32_t pedalEvents = 0;
    struct Lift {
        uint32_t at;
        float amp;
    };
    static constexpr int kLifts = 72;  // the dampers lifting or landing with the pedal, seeded
    Lift lifts[kLifts] = {};
    int liftCount = 0;
    uint32_t liftClock = 0;
    float simPeak = 0;
    bool simQuiet = true;
    // What the tests read (kept, never used for sound): the resonance bank's input energy, the damper buzz's energy
    // into the board, and strings switched off (to hear the noises alone).
    double resInputEnergy = 0, buzzEnergy = 0, lastStrikeAt = -1, lastKeybedAt = -1;
    bool testMuteStrings = false, testMuteKeys = false;

    static uint32_t lineSize(double sr, double lowestHz) noexcept { return pow2At(static_cast<uint32_t>(sr / lowestHz) + 64); }
    // Floats per voice and for the bank at `sr` (the lowest string of each slot: A0, A#0..A2, A#2 up; C2 for the bank).
    static size_t voiceFloats(double sr) noexcept { return lineSize(sr, 27.0) + lineSize(sr, 45.0) + lineSize(sr, 114.0); }
    size_t allocBytes() const noexcept {
        return (voiceCount * voiceFloats(sr) + kSymp * static_cast<size_t>(lineSize(sr, 64.0))) * sizeof(float);
    }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 0.7, r.decay = 2.2, r.damping = 0.45, r.mix = 1.0, r.width = 1.0, r.preDelay = 0.012;
        return r;
    }

    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        sr = rate;
        voices = v, voiceCount = n;
        const uint32_t s0 = lineSize(sr, 27.0), s1 = lineSize(sr, 45.0), s2 = lineSize(sr, 114.0), sb = lineSize(sr, 64.0);
        const size_t total = n * (static_cast<size_t>(s0) + s1 + s2) + kSymp * static_cast<size_t>(sb);
        memory.reset(new (std::nothrow) float[total]());
        if (!memory) return false;
        float* at = memory.get();
        for (uint32_t k = 0; k < n; ++k) {
            v[k].line[0].bind(at, s0), at += s0;
            v[k].line[1].bind(at, s1), at += s1;
            v[k].line[2].bind(at, s2), at += s2;
        }
        for (Line& l : symp) l.bind(at, sb), at += sb;
        (void)tables();
        prepareSim();
        return true;
    }
    void reset() noexcept {
        // VoicePool::clear() rewrote the voices as new: bind their lines again (the memory itself is kept).
        if (voices && memory) {
            const uint32_t s0 = lineSize(sr, 27.0), s1 = lineSize(sr, 45.0), s2 = lineSize(sr, 114.0);
            float* at = memory.get();
            for (uint32_t k = 0; k < voiceCount; ++k) {
                voices[k].line[0].bind(at, s0), at += s0;
                voices[k].line[1].bind(at, s1), at += s1;
                voices[k].line[2].bind(at, s2), at += s2;
            }
        }
        clearPost();
        pedalDown = false;
        pedalEvents = 0;
        simPos = 0;
    }

    void control(const double* p, const Shared& s) noexcept {
        hammer = clampd(p[kHammer], 0, 1);
        character = static_cast<int>(clampd(p[kCharacter], 0, 2) + 0.5);
        unison = clampd(p[kUnison], 0, 6);
        stretch = clampd(p[kStretch], 0, 2);
        decay = clampd(p[kDecay], 0.25, 4);
        sustain = clampd(p[kSustain], 0, 1);
        soft = clampd(p[kSoft], 0, 1);
        resonance = clampd(p[kResonance], 0, 1);
        pedal = std::max(sustain, clampd(s.pedal, 0, 1));
        quality = s.quality;
        controlSim(p, s);
        const bool want = !simMode && pedal > 0.02 && resonance > 0.0;  // Simulated has its own bank
        if (want && !sympOn) tuneBank();
        sympOn = want || sympPeak > 1e-6f;
        sympPeak = 0;  // the next control block's
        for (int k = 0; k < kSymp; ++k) sympZ[k] = flushf(sympZ[k]);
    }

    // Stretch tuning, in cents: a Railsback-like curve (flat in the middle, the bass down, the treble up).
    double stretchCents(double pitch) const noexcept {
        const double x = pitch - 69.0;
        const double c = x > 0 ? 30.0 * detPow(std::min(x, 48.0) / 39.0, 3.0) : -25.0 * detPow(std::min(-x, 60.0) / 48.0, 3.0);
        return stretch * c;
    }
    // [Assumption] Target decay (T60 at the fundamental, s) across the keyboard: typical of published grand-piano
    // measurements, not fitted to a recording in this build.
    static double t60At(double key) noexcept {
        static constexpr double kKey[] = {21, 36, 48, 60, 72, 84, 96, 108};
        static constexpr double kT[] = {28, 22, 16, 12, 7.5, 4.0, 1.8, 0.7};
        if (key <= kKey[0]) return kT[0];
        for (int i = 1; i < 8; ++i)
            if (key <= kKey[i]) {
                const double f = (key - kKey[i - 1]) / (kKey[i] - kKey[i - 1]);
                return kT[i - 1] * detPow(kT[i] / kT[i - 1], f);
            }
        return kT[7];
    }
    // The dispersion design per key: stages and coefficient (a curve over the keyboard, tuned by measuring the
    // stretched partials it gives; piano_test checks them).
    void dispersion(double key, int& stages, float& a) const noexcept {
        static constexpr double kKey[] = {21, 33, 45, 60, 72, 84, 96, 108};
        static constexpr double kA[] = {-0.80, -0.75, -0.71, -0.64, -0.54, -0.36, -0.30, -0.25};
        int m = key < 40 ? 8 : (key < 60 ? 6 : (key < 80 ? 4 : (key < 96 ? 3 : 2)));
        if (quality == kQualityEco) m = std::max(1, m / 2);
        else if (quality == kQualityHigh) m = std::min(kMaxDisp, m + 2);
        stages = m;
        double c = kA[7];
        if (key <= kKey[0]) c = kA[0];
        else
            for (int i = 1; i < 8; ++i)
                if (key <= kKey[i]) {
                    c = kA[i - 1] + (kA[i] - kA[i - 1]) * (key - kKey[i - 1]) / (kKey[i] - kKey[i - 1]);
                    break;
                }
        // Eco's fewer stages each carry more, so the stretch stays about the same.
        if (quality == kQualityEco) c = -1.0 + (1.0 + c) * 0.7;
        a = static_cast<float>(c);
    }

    void tuneString(Voice& v, int s, double hz, int stages, float a, float b, float p) const noexcept {
        const double w = kTwoPi * hz / sr;
        const double period = sr / hz;
        const double fixed = stages * allpassDelay(a, w) + onePoleDelay(p, w);
        double rest = period - fixed;
        const uint32_t cap = v.line[s].mask - 4;
        if (rest < 2.5) rest = 2.5;
        uint32_t D = static_cast<uint32_t>(std::floor(rest - 0.5));
        if (D > cap) D = cap;
        if (D < 2) D = 2;
        const double frac = rest - D;
        v.D[s] = D;
        v.eta[s] = static_cast<float>(allpassFor(clampd(frac, 0.3, 1.7), w));
        (void)b;
    }

    void tune(Voice& v) noexcept {
        const double pitch = clampd(v.pitch, 21.0, 120.0);
        const double key = pitch;
        const double cents = stretchCents(pitch);
        const double f0 = noteHz(pitch + cents / 100.0);
        // Loss: the T60 at the fundamental and, faster, at a high frequency, met by a one-pole (g, p).
        const double T = t60At(key) * decay;
        const double Th = T * (0.12 + 0.25 * clampd((key - 21) / 87.0, 0, 1));
        const double fh = std::max(2.0 * f0, std::min(3500.0, 0.4 * sr));
        const double g0 = detPow(10.0, -3.0 / (T * f0)), gh = detPow(10.0, -3.0 / (Th * f0));
        const double w0 = kTwoPi * f0 / sr, wh = kTwoPi * fh / sr;
        double p = onePoleForRatio(gh / g0, wh);
        if (p > 0.95) p = 0.95;
        const double g = g0 / ((1.0 - p) * onePoleMag(p, w0));
        v.pUndamped = static_cast<float>(p);
        v.bUndamped = static_cast<float>(std::min(0.99999 * (1.0 - p), g * (1.0 - p)));  // DC gain under 1
        int stages = 0;
        float a = 0;
        dispersion(key, stages, a);
        v.disp = stages;
        v.a = a;
        // Strings: 1 below A#1, 2 to A2, 3 above (Eco: 1 from C5 up, else at most 2).
        int n = key < 34 ? 1 : (key < 46 ? 2 : 3);
        if (quality == kQualityEco) n = key >= 72 ? 1 : std::min(n, 2);
        v.strings = n;
        static constexpr double kSpreadCents[3][3] = {{0, 0, 0}, {-0.5, 0.5, 0}, {-0.6, 0.15, 0.55}};
        for (int s = 0; s < n; ++s) {
            const double hz = noteHz(pitch + (cents + unison * kSpreadCents[n - 1][s]) / 100.0);
            tuneString(v, s, hz, stages, a, v.bUndamped, static_cast<float>(p));
        }
        // The bridge coupling: the in-phase motion decays about 5x faster (the prompt sound).
        if (n > 1) {
            const double Tp = T / 4.0;
            v.c = static_cast<float>((1.0 - detPow(10.0, -3.0 / f0 * (1.0 / Tp - 1.0 / T))) / n);
        } else {
            v.c = 0;
        }
        v.tunedPitch = v.pitch;
        lastT60 = static_cast<float>(T);
        lastStrings = static_cast<float>(n);
    }

    void dampedLoss(Voice& v, double release) const noexcept {
        const double pitch = clampd(v.pitch, 21.0, 120.0);
        const double f0 = noteHz(pitch);
        const double g = detPow(10.0, -3.0 / (clampd(release, 0.02, 10.0) * f0));
        const double p = std::max<double>(v.pUndamped, 0.5);
        v.pDamped = static_cast<float>(p);
        v.bDamped = static_cast<float>(std::min(0.999 * (1.0 - p), g / onePoleMag(p, kTwoPi * f0 / sr)));
    }

    void start(Voice& v, const Shared& s) noexcept {
        if (simMode) {
            startSim(v, s);
            return;
        }
        v.sim = false;
        for (int k = 0; k < 4; ++k) {
            v.apx[k] = v.apy[k] = v.z[k] = v.strike[k] = v.eta[k] = 0;
            for (int m = 0; m < kMaxDisp; ++m) v.dx[m][k] = v.dy[m][k] = 0;
        }
        tune(v);
        // Only what the first reads will see is cleared (the rest is written before it is read).
        for (int k = 0; k < v.strings; ++k) {
            Line& l = v.line[k];
            for (uint32_t d = 1; d <= v.D[k] + 1 && d <= l.mask; ++d) l.buf[(l.w - d) & l.mask] = 0.0f;
        }
        dampedLoss(v, s.release);
        v.dampedFor = s.release;
        v.b = v.bUndamped, v.p = v.pUndamped, v.damp = 0;
        v.hasDamper = v.pitch < 90.0;
        const double vel = v.velocity, key = clampd(v.pitch, 21, 108);
        const int zone = static_cast<int>(clampd((key - 21.0) / 11.0, 0, 7));
        v.table = tables().excitation[character][zone];
        v.pos = 0;
        v.step = Tables::kExcRate / sr;
        const double ms = Tables::kExcRate / 1000.0;  // table frames per ms
        const double hard = clampd((vel - 0.45) / 0.55, 0, 1);
        v.w1 = static_cast<float>(0.55 * hard), v.w2 = static_cast<float>(0.3 * hard * hard);
        v.d1 = static_cast<float>(0.6 * ms), v.d2 = static_cast<float>(1.5 * ms);
        const double f0 = noteHz(key);
        v.ds = static_cast<float>(0.12 * Tables::kExcRate / f0);
        v.cs = 0.7f;
        v.i1 = static_cast<int>(v.d1 + 0.5f), v.i2 = static_cast<int>(v.d2 + 0.5f), v.is = static_cast<int>(v.ds + 0.5f);
        v.body = static_cast<float>(clampd(s.body, 0, 1));
        v.pulseLen = static_cast<float>((2.6 - 1.8 * vel) * ms);
        const double cutoff = clampd((500.0 + 9000.0 * detPow(vel, 1.6) * (0.35 + 1.3 * hammer)) * (0.6 + 0.8 * (key - 21) / 87.0) *
                                         (1.0 - 0.35 * soft),
                                     150.0, 0.45 * sr);
        lastCutoff = static_cast<float>(cutoff);
        v.hk = static_cast<float>(1.0 - detExp(-kTwoPi * cutoff / sr));
        v.h1 = v.h2 = 0;
        // Loudness: about 26 dB from the softest to the hardest strike (the brightness says the rest).
        v.gain = static_cast<float>(0.05 + 0.95 * detPow(vel, 1.7));
        static constexpr float kStrike[3] = {1.0f, 0.72f, 0.5f};  // unequal: some of the strike goes out of phase
        for (int k = 0; k < 3; ++k) v.strike[k] = k < v.strings ? kStrike[k] : 0.0f;
        if (v.strings == 3) v.strike[2] *= static_cast<float>(1.0 - soft);  // una corda: the third string is missed
        v.exciting = true;
        v.out = static_cast<float>(0.5 / std::sqrt(static_cast<double>(v.strings)));
    }
    void release(Voice&, const Shared&) noexcept {}

    void voiceControl(Voice& v, const Shared& s) noexcept {
        if (v.sim) {
            voiceControlSim(v, s);
            return;
        }
        if (std::fabs(v.pitch - v.tunedPitch) > 1e-4) tune(v), v.dampedFor = -1;  // a bend or a glide
        if (s.release != v.dampedFor) dampedLoss(v, s.release), v.dampedFor = s.release;
        const float target = (!v.held && v.hasDamper) ? static_cast<float>(1.0 - pedal) : 0.0f;
        v.damp += (target - v.damp) * 0.25f;  // about 1.3 ms at 48 kHz: a felt lands quickly
        if (std::fabs(target - v.damp) < 1e-4f) v.damp = target;
        v.b = v.bUndamped + (v.bDamped - v.bUndamped) * v.damp;
        v.p = v.pUndamped + (v.pDamped - v.pUndamped) * v.damp;
        for (int k = 0; k < 4; ++k) {
            v.apx[k] = flushf(v.apx[k]), v.apy[k] = flushf(v.apy[k]), v.z[k] = flushf(v.z[k]);
            for (int m = 0; m < v.disp; ++m) v.dx[m][k] = flushf(v.dx[m][k]), v.dy[m][k] = flushf(v.dy[m][k]);
        }
        v.h1 = flushf(v.h1), v.h2 = flushf(v.h2);
    }

    float excite(Voice& v) noexcept {
        const int len = Tables::kExcLength;
        float raw;
        const double x = v.pos;
        if (v.step == 1.0) {  // 48 kHz: whole frames
            const int i = static_cast<int>(x);
            const int16_t* t = v.table;
            float r = t[i];
            if (i >= v.i1) r += v.w1 * t[i - v.i1];
            if (i >= v.i2) r += v.w2 * t[i - v.i2];
            if (i >= v.is) r -= v.cs * t[i - v.is];
            raw = r * (1.0f / 32767.0f);
            if (i + 1 >= len) v.exciting = false;
        } else {
            auto at = [&](double y) -> float {
                if (y < 0.0) return 0.0f;
                const int i = static_cast<int>(y);
                if (i + 1 >= len) return 0.0f;
                const float f = static_cast<float>(y - i);
                return (v.table[i] + (v.table[i + 1] - v.table[i]) * f) * (1.0f / 32767.0f);
            };
            raw = at(x) + v.w1 * at(x - v.d1) + v.w2 * at(x - v.d2) - v.cs * at(x - v.ds);
            if (x + v.step + 1 >= len) v.exciting = false;
        }
        if (x < v.pulseLen) {  // the bare hammer pulse (raised cosine), the part `body` keeps without the board
            const float pulse = 2.5f * (0.5f - 0.5f * static_cast<float>(detCos(kTwoPi * x / v.pulseLen)));
            raw = v.body * raw + (1.0f - v.body) * pulse;
        } else {
            raw *= v.body;
        }
        v.h1 += v.hk * (raw - v.h1);
        v.h2 += v.hk * (v.h1 - v.h2);
        v.pos += v.step;
        return v.h2 * v.gain;
    }

    // One voice's n (<= 16) frames. Every string's delay is at least n frames (all but the top keys at 44.1 kHz), so
    // the block's reads come before any of its writes: each filter stage then runs over the whole block in turn, and
    // the stages' recursions overlap instead of waiting on each other sample by sample.
    void render(Voice& v, float* out, uint32_t n) noexcept {
        if (v.sim) {
            renderSim(v, out, n);
            return;
        }
        const int ns = v.strings;
        uint32_t shortest = v.D[0];
        for (int s = 1; s < ns; ++s) shortest = std::min(shortest, v.D[s]);
        if (shortest < n) {
            for (uint32_t i = 0; i < n; ++i) renderFrames(v, out + i, 1);
            return;
        }
        renderFrames(v, out, n);
    }
    void renderFrames(Voice& v, float* out, uint32_t n) noexcept {
        const int ns = v.strings, M = v.disp;
        const F4 a = f4(v.a), b = f4(v.b), p = f4(v.p);
        const float c = v.c, gain = v.out;
        float e[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) e[i] = v.exciting ? excite(v) : 0.0f;
        F4 Y[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) Y[i] = f4(0.0f);
        for (int s = 0; s < ns; ++s) {
            const Line& l = v.line[s];
            const uint32_t at = l.w - v.D[s];
            for (uint32_t i = 0; i < n; ++i) Y[i][s] = l.buf[(at + i) & l.mask];
        }
        F4 x1, y1;
        for (int k = 0; k < 4; ++k) x1[k] = v.apx[k], y1[k] = v.apy[k];
        F4 eta;
        for (int k = 0; k < 4; ++k) eta[k] = v.eta[k];
        for (uint32_t i = 0; i < n; ++i) {  // the tuning allpass: y = eta (x - y1) + x1
            const F4 t = eta * (Y[i] - y1) + x1;
            x1 = Y[i], y1 = t, Y[i] = t;
        }
        for (int k = 0; k < 4; ++k) v.apx[k] = x1[k], v.apy[k] = y1[k];
        for (int m = 0; m < M; ++m) {  // the dispersion stages, each over the block
            for (int k = 0; k < 4; ++k) x1[k] = v.dx[m][k], y1[k] = v.dy[m][k];
            for (uint32_t i = 0; i < n; ++i) {
                const F4 t = a * (Y[i] - y1) + x1;
                x1 = Y[i], y1 = t, Y[i] = t;
            }
            for (int k = 0; k < 4; ++k) v.dx[m][k] = x1[k], v.dy[m][k] = y1[k];
        }
        F4 z;
        for (int k = 0; k < 4; ++k) z[k] = v.z[k];
        for (uint32_t i = 0; i < n; ++i) {  // the loss
            z = b * Y[i] + p * z;
            Y[i] = z;
        }
        for (int k = 0; k < 4; ++k) v.z[k] = z[k];
        for (uint32_t i = 0; i < n; ++i) {  // the bridge: each string gives back c x their sum, the strike goes in
            const float S = Y[i][0] + Y[i][1] + Y[i][2] + Y[i][3];
            float o = 0;
            for (int s = 0; s < ns; ++s) {
                const float w = Y[i][s] - c * S + v.strike[s] * e[i];
                v.line[s].push(w);
                o += w;
            }
            out[i] = o * gain;
        }
    }

    // ======================= Simulated (1.1.2) =======================
    // [Assumption] The levels and contact constants below are set by ear-free calibration in the tests (loudness
    // against Classic, the noises against the tone) and from typical published magnitudes; none is a measurement.
    static constexpr float kStringGain = 0.011f;   // the string's input per newton of hammer force
    // The noises at `noise` 1 sit about 20 dB under an mf C4 (close-miked), at the default 0.35 about 30 dB under (a
    // listener's distance): timber_piano_sim_test prints them.
    static constexpr float kThumpGain = 0.008f;    // the force's share straight to the board (the attack thump)
    static constexpr float kKeybedGain = 1.5e-3f, kFingerGain = 1.0e-3f, kBuzzGain = 2.5f, kPedalGain = 5.0e-4f, kLiftGain = 0.02f;
    static constexpr float kBuzzAbsorb = 0.08f;    // the felt's grip on the buzzing string
    static constexpr float kHeldGain = 0.001f;     // a silently held key's share of the bridge sum at `sympathy` 1
    static constexpr float kGlideRef = 0.02f;      // the mean square of a loud bass string at its strike
    static constexpr float kResDrive = 0.004f, kBoardGain = 1.0f;

    // Fewer stages than Classic: each one's coefficient is fitted to the curve, not set by hand.
    static int simStages(double key, int t) noexcept {
        int m = key < 40 ? 6 : (key < 60 ? 5 : (key < 80 ? 4 : (key < 96 ? 3 : 2)));
        if (t == kQualityEco) m = std::max(1, m / 2);
        else if (t == kQualityHigh) m = std::min(kMaxDisp, m + 2);
        return m;
    }
    // The strike point along the keyboard, as a fraction of the speaking length (the generator's anchors).
    static double strikePoint(double key) noexcept {
        if (key <= 60) return 0.122 - 0.002 * (key - 21) / 39.0;
        if (key <= 96) return 0.12 - (0.12 - 0.0625) * (key - 60) / 36.0;
        return 0.0625 - 0.0125 * std::min(1.0, (key - 96) / 12.0);
    }
    // [Assumption] A smooth level correction along the keyboard so an mf strike is about as loud everywhere (set by
    // timber_piano_sim_test's keyboard check).
    // The treble needs the most: its strike point is near the agraffe, so the force and its reflection nearly cancel
    // at the low partials, and the board's response falls above 1 kHz. Matched to Classic's level per key.
    static double keyLevel(double key) noexcept {
        static constexpr double kDb[13] = {5.2, 9.7, 13.6, 12.4, 11.9, 10.7, 11.0, 16.7, 24.7, 28.5, 29.0, 35.1, 39.2};  // A0, E1, .. A7
        const double x = clampd((key - 21.0) / 7.0, 0, 12);
        const int i = std::min(static_cast<int>(x), 11);
        return detPow(10.0, (kDb[i] + (kDb[i + 1] - kDb[i]) * (x - i)) / 20.0);
    }

    void prepareSim() noexcept {
        for (int t = 0; t < 3; ++t)
            for (int k = 0; k <= 88; ++k) {
                const double key = 21.0 + k, B = piano_curves::inharmonicity(key);
                dispA[t][k] = psim::fitDispersion(noteHz(key) * std::sqrt(1.0 + B), B, simStages(key, t), sr);
            }
        static constexpr double kFrameHz[8] = {180, 310, 470, 690, 980, 1450, 2100, 3200};
        static constexpr double kFrameT[8] = {0.09, 0.07, 0.06, 0.05, 0.04, 0.035, 0.03, 0.025};
        static constexpr double kFrameG[8] = {1.0, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.25};
        keyFrame.design(kFrameHz, kFrameT, kFrameG, 8, sr);
        static constexpr double kTrapHz[6] = {85, 140, 230, 360, 520, 800};
        static constexpr double kTrapT[6] = {0.14, 0.11, 0.09, 0.07, 0.05, 0.04};
        static constexpr double kTrapG[6] = {1.0, 0.8, 0.6, 0.5, 0.35, 0.25};
        trapwork.design(kTrapHz, kTrapT, kTrapG, 6, sr);
        static constexpr double kRailHz[6] = {900, 1500, 2300, 3400, 5200, 7600};
        static constexpr double kRailT[6] = {0.03, 0.025, 0.02, 0.018, 0.015, 0.012};
        static constexpr double kRailG[6] = {1.0, 0.8, 0.7, 0.5, 0.4, 0.3};
        damperRail.design(kRailHz, kRailT, kRailG, 6, sr);
        board.size = -1;
        board.design(sr, 1, 0);
        tuneRes();
    }
    // The register bank: 24 modes on the stretched, inharmonic fundamentals of C2..B3 (every pitch class twice),
    // each ringing for half its key's aftersound: what the undamped strings answer with the pedal down.
    double resStretch = -1;
    void tuneRes() noexcept {
        resStretch = stretch;
        for (int k = 0; k < kRes; ++k) {
            const double key = 36.0 + k, B = piano_curves::inharmonicity(key);
            const double hz = noteHz(key + stretchCents(key) / 100.0) * std::sqrt(1.0 + B);
            const double t60 = 0.5 * psim::simT60(key);
            // A decaying sine per mode (c = -j g w): the same weight on each, the lower keys a little louder.
            const double g = 1.0 - 0.4 * k / kRes;
            res.set(k, hz, 6.907755278982137 / t60, 0.0, -g * kTwoPi * hz, 0, 0, sr);
        }
    }

    void controlSim(const double* p, const Shared& s) noexcept {
        simMode = p[kSim] >= 0.5;
        const int t = static_cast<int>(clampd(p[kTier], 0, 3) + 0.5);
        tier = t == 0 ? s.quality : t - 1;
        noise = clampd(p[kNoise], 0, 1);
        touch = clampd(p[kTouch], 0, 1);
        action = p[kAction] >= 0.5;
        glide = clampd(p[kGlide], 0, 1);
        sympathy = clampd(p[kSympathy], 0, 1);
        phantomLevel = clampd(p[kPhantom], 0, 1);
        if (!simMode && !simActive) return;  // Classic: nothing of Simulated runs
        gridFill = 0;
        // The bridge sum is kept only while a silently held key listens; otherwise it is all zeros (a key pressed
        // silently hears it from the next control block on, 0.3-0.7 ms later).
        bool listening = false;
        for (uint32_t k = 0; k < voiceCount; ++k) listening = listening || (voices[k].active && voices[k].sim && voices[k].sympC > 0);
        if (!listening && bridgeNeeded)
            for (float& b : bridge) b = 0;
        bridgeNeeded = listening;
        board.design(sr, tier == kQualityEco ? 0 : (tier == kQualityHigh ? 2 : 1), character);
        if (stretch != resStretch) tuneRes();
        res.groups = tier == kQualityEco ? kRes / 8 : kRes / 4;  // Eco: the lower 12
        // On the control grid only (so any block size gives the same bits): the bank runs while the pedal feeds it
        // or it still rings.
        resRun = (pedal > 0 && resonance > 0) || resEnergy > 1e-14f;
        // The pedal's own noise (output only: it never reaches the resonance or the strings).
        const bool down = pedalDown ? pedal > 0.25 : pedal > 0.35;
        if (down != pedalDown) {
            pedalDown = down;
            if (simMode && noise > 0) pedalNoise(down);
        }
        board.flush(), res.flush(), keyFrame.flush(), trapwork.flush(), damperRail.flush();
        // A bank that has rung out is cleared to exact zeros and skipped until it is struck again.
        if (!keyFrameIdle && keyFrameEnergy < 1e-14f) keyFrame.clear(), keyFrameIdle = true;
        if (!pedalIdle && pedalEnergy < 1e-14f && !trap.on && liftNext >= liftCount) trapwork.clear(), damperRail.clear(), pedalIdle = true;
        simActive = simMode || !simQuiet;
    }
    // The trapwork's wooden thump, and the dampers leaving (or meeting) the strings: a seeded spread of small
    // felt contacts into the damper rail.
    void pedalNoise(bool down) noexcept {
        trap.start(down ? 0.45 : 0.3, 3.0e6, 0.3, 0.25);
        Noise r;
        r.s = 0x9E3779B9u + 7919u * ++pedalEvents;
        const double first = down ? 0.004 : 0.002, spread = down ? 0.035 : 0.05;
        liftCount = kLifts;
        for (int k = 0; k < kLifts; ++k) {
            const double u = 0.5 + 0.5 * r.next(), a = 0.5 + 0.5 * r.next();
            lifts[k] = {static_cast<uint32_t>((first + u * u * spread) * sr), static_cast<float>((0.3 + 0.7 * a) * (down ? 1.0 : 0.6))};
        }
        for (int k = 1; k < kLifts; ++k)  // by time (insertion: 72 entries, once per pedal move)
            for (int j = k; j > 0 && lifts[j].at < lifts[j - 1].at; --j) std::swap(lifts[j], lifts[j - 1]);
        liftClock = 0;
        liftNext = 0;
    }
    int liftNext = 0;
    bool resRun = false;

    void tuneSim(Voice& v) noexcept {
        const double pitch = clampd(v.pitch, 21.0, 120.0), key = std::min(pitch, 108.0);
        const double cents = stretchCents(pitch);
        const double B = piano_curves::inharmonicity(key);
        const double f0 = noteHz(pitch + cents / 100.0) * std::sqrt(1.0 + B);
        const double T = psim::simT60(key) * decay;
        const double Th = T * (0.12 + 0.25 * clampd((key - 21) / 87.0, 0, 1));
        const double fh = std::max(2.0 * f0, std::min(3500.0, 0.4 * sr));
        const double g0 = detPow(10.0, -3.0 / (T * f0)), gh = detPow(10.0, -3.0 / (Th * f0));
        const double w0 = kTwoPi * f0 / sr, wh = kTwoPi * fh / sr;
        double p = onePoleForRatio(gh / g0, wh);
        if (p > 0.95) p = 0.95;
        const double g = g0 / ((1.0 - p) * onePoleMag(p, w0));
        v.pUndamped = static_cast<float>(p);
        v.bUndamped = static_cast<float>(std::min(0.99999 * (1.0 - p), g * (1.0 - p)));
        const int t = tier;
        v.disp = simStages(key, t);
        const double kf = clampd(key - 21.0, 0, 88);
        const int k0 = static_cast<int>(kf);
        const int k1 = std::min(k0 + 1, 88);
        v.a = dispA[t][k0] + (dispA[t][k1] - dispA[t][k0]) * static_cast<float>(kf - k0);
        // At least two lanes (the SIMD lanes run either way): a single bass string's two polarisations, slightly
        // apart, give its two-stage decay as a unison pair does.
        int n = key < 46 ? 2 : 3;
        if (t == kQualityEco) n = 2;
        v.strings = n;
        static constexpr double kSpreadCents[3][3] = {{0, 0, 0}, {-0.5, 0.5, 0}, {-0.6, 0.15, 0.55}};
        const double spread = key < 34 ? 1.0 : unison;  // a single string's polarisations: a fixed split
        for (int s = 0; s < n; ++s) {
            const double hz = noteHz(pitch + (cents + spread * kSpreadCents[n - 1][s]) / 100.0) * std::sqrt(1.0 + B);
            const double w = kTwoPi * hz / sr;
            const double fixed = v.disp * allpassDelay(v.a, w) + onePoleDelay(p, w);
            v.rest[s] = std::max(2.5, sr / hz - fixed);
            v.wrad[s] = w;
        }
        applyGlide(v);
        if (n > 1) {
            const double Tp = T * psim::simPrompt(key);
            v.c = static_cast<float>((1.0 - detPow(10.0, -3.0 / f0 * (1.0 / Tp - 1.0 / T))) / n);
        } else {
            v.c = 0;
        }
        v.tunedPitch = v.pitch;
        lastT60 = static_cast<float>(T);
        lastStrings = static_cast<float>(n);
    }
    // Sets each string's integer delay and tuning allpass for the glide's present offset (cents sharp).
    void applyGlide(Voice& v) const noexcept {
        const double up = 1.0 - detPow(2.0, -v.glideCents / 1200.0);
        for (int s = 0; s < v.strings; ++s) {
            const double rest = std::max(2.5, v.rest[s] - (kTwoPi / v.wrad[s]) * up);
            const uint32_t cap = v.line[s].mask - 4;
            uint32_t D = static_cast<uint32_t>(std::floor(rest - 0.5));
            if (D > cap) D = cap;
            if (D < 2) D = 2;
            v.D[s] = D;
            v.eta[s] = static_cast<float>(allpassFor(clampd(rest - D, 0.3, 1.7), v.wrad[s]));
        }
    }

    void startSim(Voice& v, const Shared& s) noexcept {
        v.sim = true;
        for (int k = 0; k < 4; ++k) {
            v.apx[k] = v.apy[k] = v.z[k] = v.strike[k] = v.eta[k] = 0;
            for (int m = 0; m < kMaxDisp; ++m) v.dx[m][k] = v.dy[m][k] = 0;
        }
        v.glideCents = 0;
        tuneSim(v);
        for (int k = 0; k < v.strings; ++k) {
            Line& l = v.line[k];
            for (uint32_t d = 1; d <= v.D[k] + 2 && d <= l.mask; ++d) l.buf[(l.w - d) & l.mask] = 0.0f;
        }
        dampedLoss(v, s.release);
        v.dampedFor = s.release;
        v.b = v.bUndamped, v.p = v.pUndamped, v.damp = 0;
        v.hasDamper = v.pitch < 90.0;
        const double vel = v.velocity, key = clampd(v.pitch, 21, 108);
        // The hammer: its speed from the velocity (0.5..6 m/s), the force pulses of the two nearest zones and
        // speeds; `hammer` (voicing) and the soft pedal move the pulse's shape along the speeds, not its force.
        const bool silent = vel < 0.03;  // a key pressed too slowly to throw the hammer: its strings only listen
        const double speed = 0.5 * detPow(12.0, vel);
        double lp = 0;
        for (int i = 0; i + 1 < piano_curves::kLayers; ++i)
            if (speed > piano_curves::kLayerSpeed[i])
                lp = i + std::min(1.0, detLog(speed / piano_curves::kLayerSpeed[i]) /
                                           detLog(piano_curves::kLayerSpeed[i + 1] / piano_curves::kLayerSpeed[i]));
        const double shape = clampd(lp + (hammer - 0.5) * 1.5 - 0.8 * soft - (character == 2 ? 0.6 : 0.0), 0, piano_curves::kLayers - 1.0);
        const double zp = (key - 21.0) / 87.0 * (piano_curves::kZones - 1);
        const int z0 = std::min(static_cast<int>(zp), piano_curves::kZones - 2), l0 = std::min(static_cast<int>(shape), piano_curves::kLayers - 2);
        const int f0l = std::min(static_cast<int>(lp), piano_curves::kLayers - 2);
        const float fz = static_cast<float>(zp - z0), fl = static_cast<float>(shape - l0), ff = static_cast<float>(lp - f0l);
        const psim::HammerData h00 = psim::hammer(z0, l0), h01 = psim::hammer(z0, l0 + 1), h10 = psim::hammer(z0 + 1, l0),
                               h11 = psim::hammer(z0 + 1, l0 + 1);
        v.pulse[0] = h00.pulse, v.pulse[1] = h01.pulse, v.pulse[2] = h10.pulse, v.pulse[3] = h11.pulse;
        v.pw[0] = (1 - fz) * (1 - fl), v.pw[1] = (1 - fz) * fl, v.pw[2] = fz * (1 - fl), v.pw[3] = fz * fl;
        auto bil = [&](float (*get)(const psim::HammerData&)) {
            const float a = get(psim::hammer(z0, f0l)), b = get(psim::hammer(z0, f0l + 1));
            const float c = get(psim::hammer(z0 + 1, f0l)), d = get(psim::hammer(z0 + 1, f0l + 1));
            return (1 - fz) * ((1 - ff) * a + ff * b) + fz * ((1 - ff) * c + ff * d);
        };
        const float peak = bil([](const psim::HammerData& x) { return x.peak; });
        const float contact = bil([](const psim::HammerData& x) { return x.contactMs; });
        lastCutoff = 1000.0f / std::max(0.1f, contact);  // the pulse's brightness, as 1 / its contact time
        const double f1 = noteHz(key);
        // The string's input: the force compressed a little (the board's and the ear's loudness grow slower than
        // the force; set against the Salamander Grand's pp-to-ff level, timber_piano_sim_test).
        v.pgain = silent ? 0.0f : static_cast<float>(detPow(peak / 10.0, 0.75) * 10.0 * kStringGain * keyLevel(key));
        v.thump = silent ? 0.0f : peak * kThumpGain;
        v.ppos = 0;
        v.pstep = piano_curves::kPulseRate / sr;
        v.tap = static_cast<float>(strikePoint(key) / f1 * piano_curves::kPulseRate);
        v.felt = character == 2 ? static_cast<float>(1.0 - detExp(-kTwoPi * 1500.0 / sr)) : 1.0f;
        v.feltY = 0;
        // The action: off, the hammer meets the strings at note-on; on, 2-30 ms later by velocity, as a real one.
        v.wait = action ? static_cast<uint32_t>((0.002 + 0.028 * (1.0 - vel) * (1.0 - vel)) * sr) : 0u;
        v.strikeFrame = silent ? -1.0 : static_cast<double>(v.wait);
        // The key meets the keybed a few ms before the string at pp and after it at ff, crossing near mf.
        v.keybedPending = !silent;
        const double kb = static_cast<double>(v.wait) + (vel - 0.5) * 0.008 * sr;
        v.keybedAt = static_cast<uint32_t>(std::max(0.0, kb));
        v.keybedFrame = silent ? -1.0 : static_cast<double>(v.keybedAt);
        lastStrikeAt = v.strikeFrame, lastKeybedAt = v.keybedFrame;
        v.keybedGain = static_cast<float>(kKeybedGain * (0.4 + 0.6 * vel));
        v.keybed.on = false;
        v.keybed.start(speed / 5.0, 2.0e6, 0.4, 0.03);  // the key's front, a fifth of the hammer's speed
        v.keybed.on = false;
        // The finger on the key (a struck touch): at note-on, before the action throws the hammer.
        v.fingerPending = touch > 0 && !silent;
        v.fingerAt = 0;
        v.fingerGain = static_cast<float>(kFingerGain * touch);
        v.finger.start(0.3 + 1.5 * vel, 1.0e7, 0.2, 0.008);
        v.finger.on = false;
        v.energy = v.gE = 0;
        v.glideTick = 0;
        v.glideScale = (tier == kQualityEco || key >= 72) ? 0.0f : static_cast<float>(glide * 10.0 * detPow((72.0 - key) / 51.0, 1.5));
        v.landing = false, v.landGap = v.landGap0 = 0;
        // Struck strings drive the bridge; strings held down without a strike listen to it. So no string both drives
        // and listens across voices, and the coupling cannot feed back on itself (a delayed loop between voices
        // would not be passive).
        v.sympC = silent ? static_cast<float>(sympathy * kHeldGain) : 0.0f;
        v.phantomGain = 0;
        if (tier == kQualityHigh && phantomLevel > 0) {
            const double fl2 = psim::longitudinalHz(key);
            v.phantom[0].set(fl2, 0.6, sr), v.phantom[0].clear();
            v.phantom[1].set(std::min(2.0 * fl2, 0.45 * sr), 0.4, sr), v.phantom[1].clear();
            v.phantomGain = static_cast<float>(phantomLevel * 0.04);
        }
        static constexpr float kStrike[3] = {1.0f, 0.72f, 0.5f};
        for (int k = 0; k < 3; ++k) v.strike[k] = k < v.strings ? kStrike[k] : 0.0f;
        if (key < 34) v.strike[1] = 0.3f;  // the hammer drives the vertical polarisation; the other mostly by coupling
        if (v.strings == 3) v.strike[2] *= static_cast<float>(1.0 - soft);
        v.exciting = !silent;
        v.out = static_cast<float>(0.5 / std::sqrt(static_cast<double>(v.strings)));
        v.simFrames = 0;
    }

    void voiceControlSim(Voice& v, const Shared& s) noexcept {
        if (std::fabs(v.pitch - v.tunedPitch) > 1e-4) tuneSim(v), v.dampedFor = -1;
        if (s.release != v.dampedFor) dampedLoss(v, s.release), v.dampedFor = s.release;
        // The glide: the pitch offset follows the string's energy (a running mean square), at control rate.
        // Every fourth control block (1.3 ms at 48 kHz), in steps of at least 0.1 cent: a glide lasts seconds.
        if (v.glideScale > 0 && (++v.glideTick & 3u) == 0) {
            const float E = v.energy * (1.0f / (4 * kControlFrames));
            v.gE += 0.6f * (E - v.gE);
            const float cents = v.glideScale * std::min(3.0f, v.gE / kGlideRef);
            if (std::fabs(cents - v.glideCents) > 0.1f) v.glideCents = cents, applyGlide(v);
            v.energy = 0;
        } else if (v.glideScale <= 0) {
            v.energy = 0;
        }
        // The dampers: a felt lands over about 18 ms (the loss rises along it; the buzz is the contact with the
        // string's own motion), and lifts in about 4 ms.
        const float target = (!v.held && v.hasDamper) ? static_cast<float>(1.0 - pedal) : 0.0f;
        if (target > v.damp) {
            if (!v.landing && v.damp < 0.05f && target > 0.2f) {
                v.landing = true;
                v.landGap = v.landGap0 = v.level / std::max(1e-6f, v.out);
            }
            v.damp = std::min(target, v.damp + static_cast<float>(kControlFrames / (0.018 * sr)));
        } else {
            v.damp = std::max(target, v.damp - static_cast<float>(kControlFrames / (0.004 * sr)));
        }
        if (v.landing) {
            const float prog = target > 0 ? v.damp / target : 1.0f;
            v.landGap = v.landGap0 * (1.0f - prog);
            if (prog >= 0.999f || target <= 0) v.landing = false;
        }
        v.b = v.bUndamped + (v.bDamped - v.bUndamped) * v.damp;
        v.p = v.pUndamped + (v.pDamped - v.pUndamped) * v.damp;
        for (int k = 0; k < 4; ++k) {
            v.apx[k] = flushf(v.apx[k]), v.apy[k] = flushf(v.apy[k]), v.z[k] = flushf(v.z[k]);
            for (int m = 0; m < v.disp; ++m) v.dx[m][k] = flushf(v.dx[m][k]), v.dy[m][k] = flushf(v.dy[m][k]);
        }
        v.feltY = flushf(v.feltY);
        v.phantom[0].flush(), v.phantom[1].flush();
    }

    void renderSim(Voice& v, float* out, uint32_t n) noexcept {
        uint32_t shortest = v.D[0];
        for (int s = 1; s < v.strings; ++s) shortest = std::min(shortest, v.D[s]);
        if (shortest < n) {
            for (uint32_t i = 0; i < n; ++i) renderSimFrames(v, out + i, 1, i);
            return;
        }
        renderSimFrames(v, out, n, 0);
    }
    // Per sample, in timber_piano_sim.cpp: compiled with strict floating point (no reassociation), so the
    // Simulated piano gives the same bits at any block size (the engine's fast flags may regroup a sum differently
    // in a loop's main and remainder bodies).
    void renderSimFrames(Voice& v, float* out, uint32_t n, uint32_t at) noexcept;
    void postSim(float* l, float* r, uint32_t n, const Shared& s) noexcept;
    float resEnergy = 0, keyFrameEnergy = 0, pedalEnergy = 0;  // the banks' energy at the end of the last block (postSim)
    bool keyFrameIdle = true, pedalIdle = true;
    uint32_t gridFill = 0;  // frames postSim has seen since the last control point
    bool bridgeNeeded = false;  // a silently held key is listening (else the bridge sum is not kept)
    float gridPeak = 0;

    void clearSim() noexcept {
        board.clear(), res.clear(), keyFrame.clear(), trapwork.clear(), damperRail.clear();
        trap.on = false;
        liftCount = liftNext = 0;
        for (uint32_t i = 0; i < kControlFrames; ++i) busBoard[i] = busFrame[i] = busBridge[i] = 0;
        for (float& b : bridge) b = 0;
        simPeak = gridPeak = 0, resEnergy = keyFrameEnergy = pedalEnergy = 0;
        gridFill = 0;
        keyFrameIdle = pedalIdle = true;
        simQuiet = true;
        simActive = false;
    }
    // ======================= end of Simulated =======================

    void tuneBank() noexcept {
        const double p = 0.25;
        for (int k = 0; k < kSymp; ++k) {
            const double pitch = 36.0 + k;
            const double hz = noteHz(pitch + stretchCents(pitch) / 100.0);
            const double w = kTwoPi * hz / sr;
            // A linear read's own delay is its fraction; the one-pole's is subtracted.
            sympDelay[k] = static_cast<float>(clampd(sr / hz - onePoleDelay(p, w), 2.0, symp[k].mask - 4.0));
        }
        sympP = static_cast<float>(p);
        sympB = static_cast<float>(detPow(10.0, -3.0 / (5.0 * 98.0)) * (1.0 - p));  // about 5 s
    }

    void post(float* l, float* r, uint32_t n, const Shared& s) noexcept {
        if (simActive) postSim(l, r, n, s);
        if (!sympOn) return;
        const float drive = static_cast<float>(0.00015 * resonance * pedal);
        float peak = 0;
        for (uint32_t i = 0; i < n; ++i) {
            const float x = (l[i] + r[i]) * drive;
            float sl = 0, sr2 = 0;
            for (int k = 0; k < kSymp; ++k) {
                const float y = symp[k].frac(sympDelay[k]);
                sympZ[k] = sympB * y + sympP * sympZ[k];
                symp[k].push(sympZ[k] + x);
                (k & 1 ? sr2 : sl) += sympZ[k];
            }
            const float gl = static_cast<float>(resonance) * 0.6f;
            l[i] += sl * gl;
            r[i] += sr2 * gl;
            peak = std::max(peak, std::fabs(sl) + std::fabs(sr2));
        }
        sympPeak = std::max(sympPeak, peak);
    }
    bool postQuiet() const noexcept { return !sympOn && (!simActive || simQuiet); }
    void clearPost() noexcept {
        for (Line& s : symp) s.clear();
        for (float& z : sympZ) z = 0;
        sympPeak = 0;
        sympOn = false;
        clearSim();
    }
    void display(float* out) const noexcept {
        out[0] = static_cast<float>(pedal);
        out[1] = lastCutoff;
        out[2] = lastT60;
        out[3] = lastStrings;
        out[4] = sympOn ? 1.0f : 0.0f;
        out[5] = static_cast<float>(character);
        out[6] = static_cast<float>(soft);
    }
};

}  // namespace caw::timber
