// Starling's piano model (Timber's Simulated piano, 1.1.2): coupled stiff strings with fitted dispersion struck by a simulated hammer, the dampers, the pedal, the board and the contacts' noises.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <new>

#include "instrument_core.h"
#include "starling_piano_sim.h"

namespace caw::timber {

// Three peaking filters in series on `out` (transposed direct form II, coefficients and states per filter), the
// piano's crossfade tone EQ (starling_piano.h). Defined in the strict starling_piano_sim.cpp, so any block size gives
// the same bits on every build. No flush here: render's chunks follow the blocks.
void toneEqRun(float* out, uint32_t n, const float* b0, const float* b1, const float* b2, const float* a1,
               const float* a2, float* z1, float* z2) noexcept;


// The piano: Timber's Simulated piano (1.1.2; Classic, the commuted piano it was beside, left with Timber in 1.1.3),
// the model Starling (starling_piano.h) plays under its recordings. Per voice two or three coupled strings, each a
// delay line with an exact first-order tuning allpass, M dispersion allpasses fitted to an inharmonicity curve and a
// one-pole loss, meeting at a bridge that takes c x their sum from each (Weinreich's coupled strings: the two-stage
// decay and the beating). The strike is a hammer force pulse from a build-time finite-difference simulation
// (starling_piano_tables.inc), injected at two taps (the strike point's comb comes from the physics); the soundboard
// is one shared parallel-section filter after the voice sum; loud bass notes glide down in pitch as their energy
// falls; the dampers land over about 18 ms with a contact buzz from the string's own amplitude; the attack thump,
// the key bottoming on the keybed, the finger on the key and the pedal's trapwork and dampers are simulated
// contacts; held keys' strings take the bridge sum (sympathetic resonance) and, with the pedal down, a 24-mode
// register bank rings (starling_piano_sim.h). What it deliberately is not (the design's reading of Modartt's
// US7915515B2, owner-settled 2026-11-19): no per-partial damping or frequency coefficients, no sum-of-partials
// renderer and no soundboard physical parameter. The patent reading behind the damper and pedal noises is in
// docs/decisions.md (2026-11-20): nothing depends on how a key is released, and no noise ever reaches the resonance.
struct Piano {
    static constexpr uint32_t kEcoCap = 16, kNormalCap = 32, kHighCap = 48, kPool = kHighCap + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = true;
    static constexpr double kMinLife = 0.15, kSpread = 0.6;
    enum P : uint32_t {
        kHammer, kCharacter, kUnison, kStretch, kDecay, kSustain, kSoft, kResonance,
        kTier, kNoise, kTouch, kAction, kGlide, kSympathy, kPhantom, kModelParams
    };
    static constexpr int kMaxDisp = 12;
    static constexpr int kRes = 24;  // the register bank (pedal down)

    struct Voice : VoiceBase {
        int strings = 0, disp = 0;
        Line line[3];
        uint32_t D[3] = {};
        // Four lanes (strings; the unused ones run on zeros), so the per-sample work is 4-wide SIMD.
        alignas(16) float eta[4] = {}, apx[4] = {}, apy[4] = {}, z[4] = {}, strike[4] = {};
        alignas(16) float dx[kMaxDisp][4] = {}, dy[kMaxDisp][4] = {};
        float a = 0, b = 0, p = 0, bUndamped = 0, pUndamped = 0, bDamped = 0, pDamped = 0;
        float c = 0;
        float damp = 0;  // 0 free .. 1 fully damped (eased)
        bool exciting = false;
        float out = 1;  // the output gain
        double tunedPitch = -1;
        bool hasDamper = true;
        double dampedFor = -1;  // the release the damped loss was worked out for
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
        // ---- Starling's hybrid (1.1.3, starling_piano.h): the model fades in under a recorded attack ----
        bool gated = false;         // this voice's output is still crossing from the recording into the model
        uint32_t gateHold = 0;      // frames of the model held silent (the recording alone)
        float gateT = 0, gateStep = 0;  // the crossfade's progress 0..1 and its step per frame
        float hardK = 0, hardLpK = 0, hardY = 0;  // a hard hammer's shelf on the force (Starling's voicing; 0: none)
        bool damperNoiseDue = false;  // Starling: released under the pedal, its damper lands (and sounds) when the pedal lifts
    };

    // Shared by every voice of the instance (read at control points).
    double hammer = 0.5, unison = 1.0, stretch = 1.0, decay = 1.0, sustain = 0, soft = 0, resonance = 0.3;
    int character = 0;
    double pedal = 0;  // the knob or CC 64, whichever is down further
    double sr = 48000;
    int quality = 1;
    float lastCutoff = 0, lastT60 = 0, lastStrings = 0;

    std::unique_ptr<float[]> memory;  // every voice's lines
    Voice* voices = nullptr;
    uint32_t voiceCount = 0;

    int tier = kQualityNormal;  // the tier Simulated runs at: the device's own choice, else the Settings one
    double noise = 0.35, touch = 0, glide = 0.5, sympathy = 0.5, phantomLevel = 0.5;
    bool action = false;
    float dispA[3][89] = {};  // the fitted dispersion coefficient per tier and key (A0..C8), at this rate
    float dispU[3][89] = {};  // Starling: the same for the upright's strings (uprightStrings)
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
    // ---- Starling's hybrid (1.1.3, starling_piano.h); Timber never sets these, so its sound is unchanged ----
    const float* f1Cents = nullptr;  // the measured tuning: the fundamental's cents against equal temperament, 89 keys
    bool recordedPedal = false;      // the pedal's noise is recorded: report pedal moves instead of simulating them
    float buzzSound = 1.0f;          // the dampers' buzz into the board (0: its sound is recorded; it still damps the string)
    int pedalEvent = 0;              // 1 down, 2 up: the last pedal move, for the recorded noise (read and cleared)
    // Starling's voicing (1.1.3, 2026-11-25: its hammer, soft pedal, resonance and sympathy were too small to hear).
    bool voicing = false;    // hammer and the soft pedal filter the strike's force; a key pressed silently is a played velocity of 0..3
    double resGain = 1.0;    // the register bank's drive (pedal down) and its sympathetic share without the pedal
    double resHeld = 0.0;    // the bank's drive with the pedal up, from the undamped strings of the held keys
    double heldGain = 1.0;   // a silently held key's share of the bridge sum
    bool phantomNormal = false;  // phantom partials at Normal too (Timber: High only)
    int heldKeys = 0;        // keys held (struck) at the last control point
    // Starling's Upright and Felt (an upright with a felt rail): their own strings and dampers. [Assumption] typical
    // magnitudes, not measured: an upright's bass strings are shorter, so stiffer for their pitch (B up to 2.2 x the
    // grand's at A0, the same from C5 up; Conklin, JASA 100(2), 1996 describes the trend, not these numbers), and
    // its dampers, pressing from the front of the strings, take longer to stop them (1.6 x the release).
    bool uprightStrings = false;
    double uprightDamper = 1.0;
    static double uprightB(double key) noexcept { return 1.0 + 1.2 * clampd((72.0 - key) / 51.0, 0.0, 1.0); }
    bool strungUpright() const noexcept { return uprightStrings && character != 0; }

    static uint32_t lineSize(double sr, double lowestHz) noexcept { return pow2At(static_cast<uint32_t>(sr / lowestHz) + 64); }
    // Floats per voice at `sr` (the lowest string of each slot: A0, A#0..A2, A#2 up).
    static size_t voiceFloats(double sr) noexcept { return lineSize(sr, 27.0) + lineSize(sr, 45.0) + lineSize(sr, 114.0); }
    size_t allocBytes() const noexcept {
        return voiceCount * voiceFloats(sr) * sizeof(float);
    }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 0.7, r.decay = 2.2, r.damping = 0.45, r.mix = 1.0, r.width = 1.0, r.preDelay = 0.012;
        return r;
    }

    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        sr = rate;
        voices = v, voiceCount = n;
        const uint32_t s0 = lineSize(sr, 27.0), s1 = lineSize(sr, 45.0), s2 = lineSize(sr, 114.0);
        const size_t total = n * (static_cast<size_t>(s0) + s1 + s2);
        memory.reset(new (std::nothrow) float[total]());
        if (!memory) return false;
        float* at = memory.get();
        for (uint32_t k = 0; k < n; ++k) {
            v[k].line[0].bind(at, s0), at += s0;
            v[k].line[1].bind(at, s1), at += s1;
            v[k].line[2].bind(at, s2), at += s2;
        }
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
    }

    // Stretch tuning, in cents: a Railsback-like curve (flat in the middle, the bass down, the treble up).
    double stretchCents(double pitch) const noexcept {
        if (f1Cents) {  // Starling: `stretch` scales the measured tuning; the string's own inharmonicity is taken off
            const double k = clampd(pitch, 21.0, 108.0) - 21.0;
            const int i = std::min(static_cast<int>(k), 87);
            const double c = f1Cents[i] + (f1Cents[i + 1] - f1Cents[i]) * (k - i);
            return stretch * c - 600.0 * detLog(1.0 + piano_curves::inharmonicity(std::min(pitch, 108.0))) / detLog(2.0);
        }
        const double x = pitch - 69.0;
        const double c = x > 0 ? 30.0 * detPow(std::min(x, 48.0) / 39.0, 3.0) : -25.0 * detPow(std::min(-x, 60.0) / 48.0, 3.0);
        return stretch * c;
    }
    void dampedLoss(Voice& v, double release) const noexcept {
        const double pitch = clampd(v.pitch, 21.0, 120.0);
        const double f0 = noteHz(pitch);
        const double slow = strungUpright() ? uprightDamper : 1.0;
        const double g = detPow(10.0, -3.0 / (clampd(release * slow, 0.02, 10.0) * f0));
        const double p = std::max<double>(v.pUndamped, 0.5);
        v.pDamped = static_cast<float>(p);
        v.bDamped = static_cast<float>(std::min(0.999 * (1.0 - p), g / onePoleMag(p, kTwoPi * f0 / sr)));
    }

    void start(Voice& v, const Shared& s) noexcept { startSim(v, s); }
    void release(Voice&, const Shared&) noexcept {}
    void voiceControl(Voice& v, const Shared& s) noexcept { voiceControlSim(v, s); }
    void render(Voice& v, float* out, uint32_t n) noexcept { renderSim(v, out, n); }

    // ======================= the simulation (1.1.2) =======================
    // [Assumption] The levels and contact constants below were set by ear-free calibration in 1.1.2's tests (loudness
    // against Timber's Classic piano, the noises against the tone) and from typical published magnitudes; none is a
    // measurement.
    static constexpr float kStringGain = 0.011f;   // the string's input per newton of hammer force
    // The noises at `noise` 1 sit about 20 dB under an mf C4 (close-miked), at the default 0.35 about 30 dB under (a
    // listener's distance): timber_piano_sim_test prints them.
    static constexpr float kThumpGain = 0.008f;    // the force's share straight to the board (the attack thump)
    static constexpr float kKeybedGain = 1.5e-3f, kFingerGain = 1.0e-3f, kBuzzGain = 2.5f, kPedalGain = 5.0e-4f, kLiftGain = 0.02f;
    static constexpr float kBuzzAbsorb = 0.08f;    // the felt's grip on the buzzing string
    static constexpr float kHeldGain = 0.001f;     // a silently held key's share of the bridge sum at `sympathy` 1
    static constexpr float kGlideRef = 0.02f;      // the mean square of a loud bass string at its strike
    static constexpr float kResDrive = 0.004f, kBoardGain = 1.0f;

    // The dispersion stages per key: each one's coefficient is fitted to the curve, not set by hand.
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
    // at the low partials, and the board's response falls above 1 kHz. Matched in 1.1.2 to Classic's level per key.
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
                if (uprightStrings) {
                    const double Bu = B * uprightB(key);
                    dispU[t][k] = psim::fitDispersion(noteHz(key) * std::sqrt(1.0 + Bu), Bu, simStages(key, t), sr);
                }
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
        const int t = static_cast<int>(clampd(p[kTier], 0, 3) + 0.5);
        tier = t == 0 ? s.quality : t - 1;
        noise = clampd(p[kNoise], 0, 1);
        touch = clampd(p[kTouch], 0, 1);
        action = p[kAction] >= 0.5;
        glide = clampd(p[kGlide], 0, 1);
        sympathy = clampd(p[kSympathy], 0, 1);
        phantomLevel = clampd(p[kPhantom], 0, 1);
        gridFill = 0;
        // The bridge sum is kept only while a silently held key listens; otherwise it is all zeros (a key pressed
        // silently hears it from the next control block on, 0.3-0.7 ms later).
        bool listening = false;
        for (uint32_t k = 0; k < voiceCount; ++k) listening = listening || (voices[k].active && voices[k].sympC > 0);
        if (!listening && bridgeNeeded)
            for (float& b : bridge) b = 0;
        bridgeNeeded = listening;
        board.design(sr, tier == kQualityEco ? 0 : (tier == kQualityHigh ? 2 : 1), character);
        if (stretch != resStretch) tuneRes();
        res.groups = tier == kQualityEco ? kRes / 8 : kRes / 4;  // Eco: the lower 12
        // Starling: the pedal up and no key held, the dampers are on every string the bank stands for: it stops in
        // about 0.2 s (as the strings' own dampers do) instead of ringing its seconds out.
        if (voicing && pedal < 0.1 && heldKeys == 0 && resEnergy > 0) {
            const float d = static_cast<float>(detExp(-6.907755278982137 * kControlFrames / (0.2 * sr)));
            for (int k = 0; k < kRes; ++k) res.zr[k] *= d, res.zi[k] *= d;
        }
        // On the control grid only (so any block size gives the same bits): the bank runs while the pedal feeds it
        // or it still rings.
        heldKeys = 0;
        for (uint32_t k = 0; k < voiceCount; ++k) heldKeys += voices[k].active && voices[k].held ? 1 : 0;
        resRun = ((pedal > 0 || (resHeld > 0 && heldKeys > 0)) && resonance > 0) || resEnergy > 1e-14f;
        // The pedal's own noise (output only: it never reaches the resonance or the strings).
        const bool down = pedalDown ? pedal > 0.25 : pedal > 0.35;
        if (down != pedalDown) {
            pedalDown = down;
            if (noise > 0) {
                if (recordedPedal) pedalEvent = down ? 1 : 2;
                else pedalNoise(down);
            }
        }
        board.flush(), res.flush(), keyFrame.flush(), trapwork.flush(), damperRail.flush();
        // A bank that has rung out is cleared to exact zeros and skipped until it is struck again.
        if (!keyFrameIdle && keyFrameEnergy < 1e-14f) keyFrame.clear(), keyFrameIdle = true;
        if (!pedalIdle && pedalEnergy < 1e-14f && !trap.on && liftNext >= liftCount) trapwork.clear(), damperRail.clear(), pedalIdle = true;
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
        const bool upright = strungUpright();
        const double B = piano_curves::inharmonicity(key) * (upright ? uprightB(key) : 1.0);
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
        const float (*disp)[89] = upright ? dispU : dispA;
        v.a = disp[t][k0] + (disp[t][k1] - disp[t][k0]) * static_cast<float>(kf - k0);
        // At least two lanes (the SIMD lanes run either way): a single bass string's two polarisations, slightly
        // apart, give its two-stage decay as a unison pair does.
        int n = key < 46 ? 2 : 3;
        if (t == kQualityEco) n = 2;
        v.strings = n;
        static constexpr double kSpreadCents[3][3] = {{0, 0, 0}, {-0.5, 0.5, 0}, {-0.6, 0.15, 0.55}};
        const double spread = key < 34 ? 1.0 : unison;  // a single string's polarisations: a fixed split
        // An out-of-tune piano (owner, 2026-11-25: Unison "just makes it sound weird"): every key has drifted its own
        // way, so the detune pattern and a small whole-note offset are fixed per key (hashed, the same every strike)
        // rather than one pattern on every key, which only sounded like a chorus. At Unison 1 (a tuned grand) the
        // offsets are tiny; at 6 a key's strings sit up to about ±9 cents apart and the note up to ±4 cents off.
        uint32_t h = static_cast<uint32_t>(key) * 2654435761u;
        auto rnd = [&h]() noexcept { h ^= h << 13; h ^= h >> 17; h ^= h << 5; return static_cast<double>(h & 0xFFFF) / 65535.0; };
        const double drift = std::max(0.0, unison - 1.0) / 5.0;  // 0 at a tuned grand, 1 at the most worn
        const double noteOff = drift * 4.0 * (2.0 * rnd() - 1.0);
        for (int s = 0; s < n; ++s) {
            const double own = 1.0 + drift * 1.5 * (2.0 * rnd() - 1.0);  // this string's share of the spread, per key
            const double hz = noteHz(pitch + (cents + noteOff + spread * own * kSpreadCents[n - 1][s] * (1.0 + drift * 1.5)) / 100.0) * std::sqrt(1.0 + B);
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
        // A key pressed too slowly to throw the hammer: its strings only listen. Starling: the played velocity (before the
        // Velocity knob's scaling) under 0.03, MIDI 1..3, as a key pressed down silently on a keyboard.
        const bool silent = vel < 0.03 || (voicing && s.velocity > 0.05 && 0.75 + (vel - 0.75) / s.velocity < 0.03);
        const double speed = 0.5 * detPow(12.0, vel);
        double lp = 0;
        for (int i = 0; i + 1 < piano_curves::kLayers; ++i)
            if (speed > piano_curves::kLayerSpeed[i])
                lp = i + std::min(1.0, detLog(speed / piano_curves::kLayerSpeed[i]) /
                                           detLog(piano_curves::kLayerSpeed[i + 1] / piano_curves::kLayerSpeed[i]));
        const double shape = clampd(lp + (hammer - 0.5) * (voicing ? 2.5 : 1.5) - (voicing ? 1.4 : 0.8) * soft - (character == 2 ? 0.6 : 0.0) + (voicing && character == 1 ? 0.4 : 0.0), 0,
                                    piano_curves::kLayers - 1.0);
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
        v.hardK = 0, v.hardLpK = 0, v.hardY = 0;
        if (voicing) {
            // The hammer's felt: softer than the middle, a low-pass on the force from 21 kHz (0.5) down to 600 Hz (0);
            // harder, a shelf over 1 kHz up to +10 dB (1). The soft pedal moves the strike toward the softer felt.
            const double h = clampd(hammer - 0.4 * soft, 0, 1);
            // The Felt's rail: its felt between hammer and string, 700 Hz (in series with the hammer's own).
            double fc = h < 0.5 ? 600.0 * detPow(35.0, 2.0 * h) : 0.0;
            if (character == 2) fc = fc > 0 ? 1.0 / (1.0 / fc + 1.0 / 700.0) : 700.0;
            if (fc > 0) v.felt = static_cast<float>(1.0 - detExp(-kTwoPi * std::min(fc, 0.45 * sr) / sr));
            if (h > 0.5) {
                v.hardK = static_cast<float>(4.4 * (h - 0.5));
                v.hardLpK = static_cast<float>(1.0 - detExp(-kTwoPi * 1000.0 / sr));
            }
            v.pgain *= static_cast<float>(1.0 - 0.3 * soft);  // una corda: two strings struck of three, about 3 dB down
        }
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
        v.sympC = silent ? static_cast<float>(sympathy * kHeldGain * heldGain) : 0.0f;
        v.phantomGain = 0;
        if ((tier == kQualityHigh || (phantomNormal && tier == kQualityNormal)) && phantomLevel > 0) {
            const double fl2 = psim::longitudinalHz(key);
            v.phantom[0].set(fl2, 0.6, sr), v.phantom[0].clear();
            v.phantom[1].set(std::min(2.0 * fl2, 0.45 * sr), 0.4, sr), v.phantom[1].clear();
            v.phantomGain = static_cast<float>(phantomLevel * 0.04);
            // Starling: a mode over 0.45 x the rate is left out (it aliased: the treble's 40-47 kHz modes folded down to
            // near DC, where the string's squared motion drove them, 20-26 dB over the note).
            if (voicing) {
                if (fl2 >= 0.45 * sr) v.phantomGain = 0;
                else if (2.0 * fl2 >= 0.45 * sr) v.phantom[1].set(0.45 * sr, 0.0, sr);
            }
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
    // Per sample, in starling_piano_sim.cpp: compiled with strict floating point (no reassociation), so the
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
    }
    // ======================= end of the simulation =======================

    void post(float* l, float* r, uint32_t n, const Shared& s) noexcept { postSim(l, r, n, s); }
    bool postQuiet() const noexcept { return simQuiet; }
    void clearPost() noexcept { clearSim(); }
    void display(float* out) const noexcept {
        out[0] = static_cast<float>(pedal);
        out[1] = lastCutoff;
        out[2] = lastT60;
        out[3] = lastStrings;
        out[4] = resRun ? 1.0f : 0.0f;  // the pedal's register bank rings
        out[5] = static_cast<float>(character);
        out[6] = static_cast<float>(soft);
    }
};

}  // namespace caw::timber
