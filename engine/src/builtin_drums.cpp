// org.caw.drums (Drums): 64 pads (4 banks of 16) of layered drum synthesis (body, click, noise, metal, modal resonator, sample) with pad and kit effects.
#include "builtin_drums.h"
#include "builtin_drums_layout.h"
#include "component_samples.h"
#include "quality.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>

#include "caw/detmath.hpp"
#include "caw/display.hpp"
#include "caw/instrument.hpp"
#include "caw/library/distortion.hpp"
#include "caw/library/dynamics.hpp"
#include "caw/library/envelope.hpp"
#include "caw/library/eq.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/modal.hpp"
#include "caw/library/oscillator.hpp"
#include "caw/library/oversample.hpp"
#include "caw/library/reverb.hpp"

// Original code (C.A.W. is Apache-2.0). The techniques (an 808-style swept sine body, six-square metal banks,
// band-passed noise bursts for claps, modal membranes and bars) are described in docs/engine.md ("Drums") in our
// own words, with sources; no other instrument's code was used.
//
// How it runs:
// - A voice belongs to a pad; a pool of 64 voices serves all 64 pads (each pad up to its own polyphony, 1..4).
//   Only sounding voices are visited, and in a voice only the layers that are on.
// - Once per control period (16 frames) each pad with a sounding voice reads its 119 knobs and works out its
//   settings (macros included); each of its voices then works out its coefficients (with its own velocity,
//   variation, glide and pressure). A pad that isn't sounding reads nothing: unused pads cost nothing.
// - The grid runs on from block to block (it never restarts), and a hit reads its pad's knobs at its own frame,
//   so a render is the same at any block size.

namespace caw {

namespace {

using namespace drums;

constexpr uint32_t kControlFrames = 16;
constexpr uint32_t kVoices = 64;
constexpr double kLn2 = 0.69314718055994530942;
constexpr double kSixtyDb = 6.907755278982137;

double clampd(double v, double lo, double hi) noexcept {
    v = finiteOr0(v);
    return v < lo ? lo : (v > hi ? hi : v);
}
int clampi(double v, int lo, int hi) noexcept { return static_cast<int>(clampd(v + 0.5, lo, hi + 0.49)); }
double exp2d(double x) noexcept { return lib::fastExp(x * kLn2); }
double dbGain(double db) noexcept { return db <= -59.999 ? 0.0 : lib::dbToGain(db); }
// The per-sample factor that falls 60 dB in `seconds`.
double fall(double seconds, double sr) noexcept { return seconds > 0.0 ? lib::fastExp(-kSixtyDb / (seconds * sr)) : 0.0; }

// ---------- Kernels ----------

// Attack (linear), hold, then a decay of 60 dB in `decay` seconds whose curve blends the analog exponential (0)
// toward a quick drop with a long tail (+1: a second exponential 6 times as fast) or a straight line (-1: a
// gated, held sound). Ends below about -94 dB.
struct DrumEnv {
    int stage = 0;  // 0 off, 1 attack, 2 hold, 3 decay
    double level = 0, inc = 1, e = 1, ef = 1, lin = 1, coef = 0, coefFast = 0, linStep = 0, curve = 0;
    double was[4] = {-1, -1, -1, -1};  // what set() last worked out from
    uint32_t holdLeft = 0, holdFrames = 0;
    void set(double attack, double hold, double decay, double c, double sr) noexcept {
        if (attack == was[0] && hold == was[1] && decay == was[2] && c == was[3]) return;  // unchanged: no exps
        was[0] = attack, was[1] = hold, was[2] = decay, was[3] = c;
        inc = attack > 0.0 ? 1.0 / (attack * sr) : 2.0;
        holdFrames = static_cast<uint32_t>(clampd(hold, 0.0, 10.0) * sr);
        coef = fall(decay, sr);
        coefFast = fall(decay / 6.0, sr);
        linStep = decay > 0.0 ? 1.0 / (decay * sr) : 1.0;
        curve = clampd(c, -1.0, 1.0);
    }
    void trigger() noexcept {
        stage = 1;
        level = 0.0;
        e = ef = lin = 1.0;
        holdLeft = holdFrames;
    }
    // Straight into the decay at full level (a pitch envelope).
    void start() noexcept {
        stage = 3;
        level = 1.0;
        e = ef = lin = 1.0;
    }
    double next() noexcept {
        switch (stage) {
            case 1:
                level += inc;
                if (level >= 1.0) {
                    level = 1.0;
                    stage = holdLeft ? 2 : 3;
                }
                return level;
            case 2:
                if (--holdLeft == 0) stage = 3;
                return 1.0;
            case 3: {
                e *= coef;
                double out;
                if (curve >= 0.0) {
                    ef *= coefFast;
                    out = e + curve * (ef - e);
                } else {
                    lin = lin > linStep ? lin - linStep : 0.0;
                    out = e - curve * (lin - e);
                }
                if (out < 2e-5) {
                    stage = 0;
                    out = 0.0;
                }
                return level = out;
            }
            default: return 0.0;
        }
    }
    bool active() const noexcept { return stage != 0; }
};

// The six oscillator ratios and loudnesses of each metal set. 808: the TR-808 cymbal and hi-hat bank's six square
// oscillators (205.3, 304.4, 369.6, 522.7, 540 and 800 Hz, divided by the lowest; docs/engine.md); Cowbell: two
// of them (540 and 800 Hz). The rest are made up here, for their character.
struct MetalSet {
    double ratio[6];
    double amp[6];
};
constexpr MetalSet kMetalSets[kSetCount] = {
    {{1.0, 1.48271, 1.80029, 2.54603, 2.63030, 3.89674}, {1, 1, 1, 1, 1, 1}},           // 808
    {{1.0, 1.342, 1.759, 2.107, 2.533, 3.191}, {1, 0.9, 1, 0.8, 0.9, 0.7}},             // Bright
    {{1.0, 1.215, 1.797, 2.341, 3.106, 4.207}, {1, 0.9, 0.85, 0.8, 0.7, 0.6}},          // Cymbal
    {{1.0, 1.48148, 1.0, 1.0, 1.0, 1.0}, {1, 0.85, 0, 0, 0, 0}},                       // Cowbell (540 : 800)
    {{1.0, 1.5, 2.08, 2.84, 3.6, 4.42}, {1, 0.8, 0.6, 0.5, 0.35, 0.25}},                // Gong
    {{1.0, 2.0, 2.76, 3.0, 5.4, 6.0}, {1, 0.6, 0.8, 0.4, 0.5, 0.3}},                    // Bell
    {{1.0, 2.0, 3.0, 4.0, 5.0, 6.0}, {1, 0.5, 0.33, 0.25, 0.2, 0.17}},                  // Harmonic
};

// The half-band filters' design, worked out once (a voice is reset on every hit).
const lib::HalfBandDesign& halfBand() {
    static const lib::HalfBandDesign d;
    return d;
}

// A drive stage, with its 2x oversampling (Normal and High quality) around the curve.
struct Drive {
    int type = kDriveOff;
    double amount = 1, norm = 1, q = 1, tubeBias = 0, tubeNorm = 1;
    lib::Saturator sat;
    lib::Oversampler2x os{halfBand()}, os2a{halfBand()}, os2b{halfBand()};
    void set(int t, double a) noexcept {
        type = t;
        amount = clampd(a, 1.0, 20.0);
        if (type == kDriveSoft) sat.set(amount);
        if (type == kDriveCrush) {
            const double bits = 16.0 - 13.0 * (lib::fastLog(amount) / lib::fastLog(20.0));
            q = exp2d(std::floor(bits) - 1.0);
        }
        if (type == kDriveTube) {  // a biased tanh: even harmonics; the bias's offset taken out, held within +-1
            tubeBias = lib::fastTanh(0.3);
            tubeNorm = 1.0 / (1.0 + tubeBias);
        }
    }
    double curveAt(double x) const noexcept {
        switch (type) {
            case kDriveSoft: return sat.process(x);
            case kDriveHard: return lib::hardClip(x, amount);
            case kDriveFold: return lib::fastSinCycles(x * amount * 0.25);
            case kDriveTube: return (lib::fastTanh(amount * x + 0.3) - tubeBias) * tubeNorm;
            default: return x;
        }
    }
    // factor 1 (Eco), 2 (Normal) or 4 (High: two 2x stages).
    double process(double x, int factor) noexcept {
        if (type == kDriveOff) return x;
        if (type == kDriveCrush) return std::floor(x * q + 0.5) / q;
        if (factor <= 1) return curveAt(x);
        double up[2];
        os.up(x, up);
        if (factor == 2) {
            up[0] = curveAt(up[0]);
            up[1] = curveAt(up[1]);
        } else {
            double a[2], b[2];
            os2a.up(up[0], a);
            os2b.up(up[1], b);
            a[0] = curveAt(a[0]), a[1] = curveAt(a[1]), b[0] = curveAt(b[0]), b[1] = curveAt(b[1]);
            up[0] = os2a.down(a);
            up[1] = os2b.down(b);
        }
        return os.down(up);
    }
    void clear() noexcept {
        os.clear();
        os2a.clear();
        os2b.clear();
    }
};

// ---------- A pad's settings, worked out from its knobs and macros ----------

struct PadSettings {
    double gain = 1, pan = 0, tune = 0, root = 60, glide = 0.08, release = 0.1, pressAmt = 0;
    int type = kTypePerc, poly = 2, choke = 0, out = 0, pressDest = 0;
    bool track = false, mono = false, gate = false;
    // body
    bool bodyOn = false;
    int wave = 0, subDiv = 2;
    double shape = 0, shapeNorm = 1, fold = 0, freq = 55, pitchSt = 24, ptime = 0.05, pcurve = 0, attack = 0.0005,
           hold = 0, decay = 0.4, dcurve = 0, p2ratio = 1.5, p2level = 0, sub = 0, phase = 0, bodyLevel = 1;
    // click
    bool clickOn = false;
    int clickType = 0;
    double clickLevel = 0.5, clickTone = 2000, clickLength = 0.008;
    // noise
    bool noiseOn = false;
    int noiseMode = 0, color = 0, noiseFilter = kFilterHp, bursts = 3;
    double noiseFreq = 2000, noiseQ = 0.707, sweep = 0, noiseAttack = 0.001, noiseDecay = 0.2, noiseCurve = 0,
           spacing = 0.01, noiseLevel = 1;
    // metal
    bool metalOn = false;
    int metalMode = 0, metalSet = 0;
    double metalFreq = 410.6, ratio[6] = {}, amp[6] = {}, fm = 2, metalTone = 7000, metalColor = 8000, band = 0,
           metalQ = 1.2, metalAttack = 0.0005, metalDecay = 0.05, metalCurve = 0, metalNoise = 0.5, metalLevel = 1;
    // resonator
    bool resOn = false;
    int model = 0, exciter = kExciteMallet;
    double resFreq = 150, resDecay = 0.6, damp = 0.4, bright = 0.5, inharm = 0, pos = 0.3, input = 0.2, resLevel = 1;
    // sample
    bool smpOn = false, reverse = false;
    double start = 0, end = 1, smpTune = 0, smpAttack = 0.0001, smpDecay = 30, smpLevel = 1;
    // effects
    int driveType = 0, flt = 0;
    bool drivePost = false;
    double drive = 2, cutoff = 12000, fltQ = 0.707, fltEnv = 0, fltDecay = 0.2, eqLow = 0, eqMid = 0, eqFreq = 1000,
           eqHigh = 0, trA = 0, trS = 0, comp = 0;
    // variation
    double velLevel = 1, velPitch = 0, velDecay = 0, velTone = 0.3, velClick = 0.5, rndPitch = 0, rndDecay = 0,
           rndTone = 0, rndPan = 0, rndLevel = 0;
    bool used = false;  // any layer on and the pad not silent
    double raw[kPadParams] = {};  // the knobs these were worked out from
    bool valid = false;
    bool perFrame = false;          // some knob moved within the block it was read in (a ramp, a lane)
    uint64_t block = ~0ull;         // the block it was read in
};

// Reads pad `pad`'s knobs at frame `at` and applies its macros (docs/engine.md, "Drums", Character macros).
// `block` counts the instrument's blocks: knobs that hold one value for the block are read once in it.
void readPad(const ProcessBlock& b, uint32_t pad, uint32_t at, PadSettings& s, uint64_t block = ~0ull) noexcept {
    // The knobs first; when none moved since the last read, the settings stand (most controls of a hit).
    if (block != ~0ull && s.block == block && !s.perFrame && s.valid) return;
    s.block = block;
    const Voice& def = defaultVoice(pad);
    double raw[kPadParams];
    const uint32_t first = padParam(pad, 0);
    if (b.parameters && first + kPadParams <= b.parameterCount) {
        bool perFrame = false;
        for (uint32_t p = 0; p < kPadParams; ++p) {
            const ParameterValue& pv = b.parameters[first + p];
            raw[p] = pv.samples ? pv.samples[at] : pv.value;
            perFrame = perFrame || pv.samples;
        }
        s.perFrame = perFrame;
    } else {
        for (uint32_t p = 0; p < kPadParams; ++p) raw[p] = def[p];
    }
    if (s.valid && std::memcmp(raw, s.raw, sizeof raw) == 0) return;
    std::memcpy(s.raw, raw, sizeof raw);
    s.valid = true;
    auto v = [&](uint32_t p) noexcept { return raw[p]; };
    auto on = [&](uint32_t p) noexcept { return v(p) >= 0.5; };
    const double punch = clampd(v(kPunch), -1, 1), tone = clampd(v(kTone), -1, 1), snap = clampd(v(kSnap), -1, 1),
                 length = clampd(v(kLength), -1, 1), dirt = clampd(v(kDirt), -1, 1), pitch = clampd(v(kPitch), -1, 1);
    const double lengthMul = exp2d(2.0 * length);
    s.gain = dbGain(v(kLevel));
    s.pan = clampd(v(kPan), -1, 1);
    s.tune = clampd(v(kTune), -48, 48) + 12.0 * pitch;
    s.track = on(kTrack);
    s.root = clampd(v(kRoot), 0, 127);
    s.mono = on(kMono);
    s.glide = clampd(v(kGlide), 0.001, 2);
    s.gate = clampi(v(kTrig), 0, 1) == kGate;
    s.release = clampd(v(kRelease), 0.001, 5);
    s.poly = clampi(v(kPoly), 1, 4);
    s.choke = clampi(v(kChoke), 0, 8);
    s.out = clampi(v(kOut), 0, static_cast<int>(kOutputs) - 1);
    s.pressDest = clampi(v(kPressDest), 0, kPressPitch);
    s.pressAmt = clampd(v(kPressAmt), -1, 1);
    s.type = clampi(v(kType), 0, kTypeCount - 1);

    s.bodyOn = on(kBodyOn);
    if (s.bodyOn) {
        s.wave = clampi(v(kBodyWave), 0, kWaveSquare);
        s.shape = clampd(v(kBodyShape), 0, 1);
        s.shapeNorm = s.shape > 0 ? 1.0 / lib::fastTanh(1.0 + 9.0 * s.shape) : 1.0;
        s.fold = clampd(v(kBodyFold), 0, 1);
        s.freq = clampd(v(kBodyFreq), 20, 2000);
        s.pitchSt = clampd(v(kBodyPitch) + 12.0 * punch, 0, 96);
        s.ptime = clampd(v(kBodyPTime) * exp2d(-0.7 * punch), 0.001, 2);
        s.pcurve = clampd(v(kBodyPCurve), -1, 1);
        s.attack = clampd(v(kBodyAttack), 0.0001, 0.5);
        s.hold = clampd(v(kBodyHold) * exp2d(length), 0, 2);
        s.decay = clampd(v(kBodyDecay) * lengthMul, 0.005, 40);
        s.dcurve = clampd(v(kBodyDCurve), -1, 1);
        s.p2ratio = clampd(v(kBodyP2Ratio), 0.5, 8);
        s.p2level = clampd(v(kBodyP2Level), 0, 1);
        s.sub = clampd(v(kBodySub), 0, 1);
        s.subDiv = clampi(v(kBodySubOct), 0, 1) ? 4 : 2;
        s.phase = clampd(v(kBodyPhase), 0, 1);
        s.bodyLevel = dbGain(v(kBodyLevel));
    }
    s.clickOn = on(kClickOn);
    if (s.clickOn) {
        s.clickType = clampi(v(kClickType), 0, kClickPop);
        s.clickLevel = clampd(v(kClickLevel) * exp2d(1.5 * punch + snap), 0, 4);
        s.clickTone = clampd(v(kClickTone) * exp2d(1.5 * tone), 50, 20000);
        s.clickLength = clampd(v(kClickLength), 0.0005, 0.1);
    }
    s.noiseOn = on(kNoiseOn);
    if (s.noiseOn) {
        s.noiseMode = clampi(v(kNoiseMode), 0, kNoiseClap);
        s.color = clampi(v(kNoiseColor), 0, kCrushed);
        s.noiseFilter = clampi(v(kNoiseFilter), 0, kFilterHp);
        s.noiseFreq = clampd(v(kNoiseFreq) * exp2d(1.5 * tone), 20, 20000);
        s.noiseQ = lib::resonanceQ(clampd(v(kNoiseRes), 0, 1));
        s.sweep = clampd(v(kNoiseSweep), -6, 6);
        s.noiseAttack = clampd(v(kNoiseAttack), 0.0001, 1);
        s.noiseDecay = clampd(v(kNoiseDecay) * lengthMul, 0.003, 40);
        s.noiseCurve = clampd(v(kNoiseDCurve), -1, 1);
        s.bursts = clampi(v(kNoiseBursts), 1, 8);
        s.spacing = clampd(v(kNoiseSpacing), 0.002, 0.05);
        s.noiseLevel = dbGain(v(kNoiseLevel)) * exp2d(0.8 * snap);
    }
    s.metalOn = on(kMetalOn);
    if (s.metalOn) {
        s.metalMode = clampi(v(kMetalMode), 0, kMetalRing);
        s.metalSet = clampi(v(kMetalSet), 0, kSetCount - 1);
        s.metalFreq = clampd(v(kMetalFreq), 50, 2000);
        const double stretch = 1.0 + 0.5 * clampd(v(kMetalSpread), -1, 1);
        const MetalSet& set = kMetalSets[s.metalSet];
        double sum = 0.0;
        for (int i = 0; i < 6; ++i) {
            s.ratio[i] = detPow(set.ratio[i], stretch);
            s.amp[i] = set.amp[i];
            sum += set.amp[i];
        }
        for (double& a : s.amp) a /= sum;
        s.fm = clampd(v(kMetalFm), 0, 10);
        s.metalTone = clampd(v(kMetalTone) * exp2d(tone), 100, 20000);
        s.metalColor = clampd(v(kMetalColor) * exp2d(tone), 100, 20000);
        s.band = clampd(v(kMetalBand), 0, 1);
        s.metalQ = lib::resonanceQ(clampd(v(kMetalRes), 0, 1));
        s.metalAttack = clampd(v(kMetalAttack), 0.0001, 0.5);
        const double open = clampd(v(kMetalOpen), 0, 1);
        s.metalDecay = clampd(v(kMetalDecay) * (1.0 + 15.0 * open * open) * lengthMul, 0.003, 60);
        s.metalCurve = clampd(v(kMetalDCurve), -1, 1);
        s.metalNoise = clampd(v(kMetalNoise), 0, 1);
        s.metalLevel = dbGain(v(kMetalLevel));
    }
    s.resOn = on(kResOn);
    if (s.resOn) {
        s.model = clampi(v(kResModel), 0, lib::kModalModelCount - 1);
        s.resFreq = clampd(v(kResFreq), 20, 8000);
        s.resDecay = clampd(v(kResDecay) * lengthMul, 0.01, 60);
        s.damp = clampd(v(kResDamp), 0, 1);
        s.bright = clampd(v(kResBright) + 0.35 * tone, 0, 1);
        s.inharm = clampd(v(kResInharm), -1, 1);
        s.pos = clampd(v(kResPos), 0, 1);
        s.exciter = clampi(v(kResExciter), 0, kExciteNoise);
        s.input = clampd(v(kResInput), 0, 1);
        s.resLevel = dbGain(v(kResLevel));
    }
    s.smpOn = on(kSmpOn);
    if (s.smpOn) {
        s.start = clampd(v(kSmpStart), 0, 1);
        s.end = clampd(v(kSmpEnd), 0, 1);
        s.smpTune = clampd(v(kSmpTune), -48, 48);
        s.reverse = on(kSmpReverse);
        s.smpAttack = clampd(v(kSmpAttack), 0.0001, 1);
        s.smpDecay = clampd(v(kSmpDecay) * lengthMul, 0.01, 60);
        s.smpLevel = dbGain(v(kSmpLevel));
    }
    s.driveType = clampi(v(kDriveType), 0, kDriveTube);
    s.drive = clampd(v(kDrive), 1, 20);
    if (dirt > 0.0) {
        if (s.driveType == kDriveOff) {
            s.driveType = kDriveSoft;
            s.drive = 1.0 + 6.0 * dirt;
        } else {
            s.drive = clampd(s.drive * exp2d(2.0 * dirt), 1, 20);
        }
    } else if (dirt < 0.0) {
        s.drive = clampd(1.0 + (s.drive - 1.0) * (1.0 + dirt), 1, 20);
    }
    s.drivePost = on(kDrivePos);
    s.flt = clampi(v(kFlt), 0, kVfBp);
    s.cutoff = clampd(v(kCutoff) * exp2d(2.0 * tone), 20, 20000);
    s.fltQ = lib::resonanceQ(clampd(v(kFltRes), 0, 1));
    s.fltEnv = clampd(v(kFltEnv), -6, 6);
    s.fltDecay = clampd(v(kFltDecay) * exp2d(length), 0.005, 10);
    s.eqLow = clampd(v(kEqLow), -18, 18);
    s.eqMid = clampd(v(kEqMid), -18, 18);
    s.eqFreq = clampd(v(kEqFreq), 80, 12000);
    s.eqHigh = clampd(v(kEqHigh) + 6.0 * tone, -24, 24);
    s.trA = clampd(v(kTrAttack) + 0.5 * punch + 0.4 * snap, -1, 1);
    s.trS = clampd(v(kTrSustain), -1, 1);
    s.comp = clampd(v(kComp) + (dirt > 0.0 ? 0.3 * dirt : 0.0), 0, 1);
    s.velLevel = clampd(v(kVelLevel), 0, 1);
    s.velPitch = clampd(v(kVelPitch), 0, 24);
    s.velDecay = clampd(v(kVelDecay), -1, 1);
    s.velTone = clampd(v(kVelTone), -1, 1);
    s.velClick = clampd(v(kVelClick), 0, 1);
    s.rndPitch = clampd(v(kRndPitch), 0, 100);
    s.rndDecay = clampd(v(kRndDecay), 0, 1);
    s.rndTone = clampd(v(kRndTone), 0, 1);
    s.rndPan = clampd(v(kRndPan), 0, 1);
    s.rndLevel = clampd(v(kRndLevel), 0, 1);
    s.used = (s.bodyOn || s.clickOn || s.noiseOn || s.metalOn || s.resOn || s.smpOn) && s.gain > 0.0;
}

// ---------- A voice ----------

struct Variation {
    double gain = 1, pitch = 0, decayMul = 1, toneOct = 0, click = 1, pan = 0;
};

struct DrumVoice {
    // bookkeeping
    bool active = false, held = false;
    int pad = -1;
    uint32_t noteId = 0;
    uint64_t age = 0;
    double note = 60, velocity = 1, pressure = 0;
    Variation var;
    double glideSt = 0, glideTarget = 0;
    // fades: a choke or steal (5 ms), a gate's release, a pressure damp
    bool fading = false, releasing = false;
    double fadeGain = 1, fadeCoef = 1, relGain = 1, relCoef = 1, dampGain = 1, dampCoef = 1;
    // what this voice runs (copied from its pad's settings at each control)
    bool body = false, click = false, noise = false, metal = false, res = false, smp = false;
    int quality = kQualityNormal;
    // body
    DrumEnv bodyEnv, pitchEnv;
    double phase = 0, phase2 = 0, phaseSub = 0, fEnd = 55, fStart = 220, invSr = 1.0 / 48000, p2ratio = 1.5, p2level = 0,
           sub = 0, subDt = 0, shapeAmt = 0, shapeNorm = 1, fold = 0, bodyLevel = 1;
    int wave = 0;
    // click
    DrumEnv clickEnv;
    lib::OnePole clickHp;
    lib::Svf clickBp;
    double clickPhase = 0, clickTone = 2000, clickLevel = 0.5;
    int clickType = 0;
    // noise
    DrumEnv noiseEnv, tailEnv;
    lib::Noise rng{1};
    lib::Svf noiseSvf;
    double pink[3] = {0, 0, 0}, pinkK[3] = {0, 0, 0}, brown = 0, brownK = 0, crushHeld = 0, wire = 0, wireK = 0;
    uint32_t crushEvery = 1, crushLeft = 0, clapCount = 0, clapPeriod = 480, clapBursts = 3;
    double burst = 0, burstCoef = 0, noiseLevel = 1, sweep = 0, noiseFreq = 2000, noiseQ = 0.707;
    int noiseMode = 0, color = 0, noiseFilter = kFilterHp;
    // metal
    DrumEnv metalEnv;
    lib::Svf metalBp, metalHp;
    lib::Oversampler2x metalOs{halfBand()};
    double mPhase[6] = {}, mDt[6] = {}, mAmp[6] = {}, fmIndex = 0, metalNoise = 0.5, band = 0, bandGain = 1, metalLevel = 1;
    int metalMode = 0;
    // resonator
    lib::ModalBank modal;
    lib::ModalSettings modalSet;
    uint32_t exciteLeft = 0, exciteLength = 1, exciteAt = 0;
    double resInput = 0.2, resLevel = 1;
    int exciter = kExciteMallet;
    bool ringing = false;
    // sample
    const SampleBuffer* sample = nullptr;
    double smpPos = 0, smpStep = 1, smpFirst = 0, smpLast = 0, smpLevel = 1;
    bool reverse = false, smpPlaying = false;
    DrumEnv smpEnv;
    // effects
    Drive drive;
    bool drivePost = false;
    int flt = 0;
    lib::OnePole lp6;
    lib::Svf svf;
    double fltEnvLevel = 1, fltEnvCoef = 0;
    bool eq = false;
    lib::EqBand eqLow, eqMid, eqHigh;
    bool shaper = false, comp = false;
    lib::EnvelopeFollower fast, slow, compEnv;
    double trA = 0, trS = 0, compThr = 0, compRatio = 1, compMakeup = 1, gr = 0;
    double gainL = 1, gainR = 1;
    // display
    bool capture = false;

    bool sounding() const noexcept {
        return bodyEnv.active() || clickEnv.active() || noiseEnv.active() || tailEnv.active() || clapCount < clapEnd() ||
               metalEnv.active() || ringing || smpPlaying;
    }
    uint32_t clapEnd() const noexcept { return noiseMode == kNoiseClap && noise ? clapBursts * clapPeriod : 0; }
};

// ---------- The instrument ----------

const ModuleDescriptor& drumsDescriptor();

class DrumsProcessor final : public InstrumentProcessor, public SampleSlots {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return drumsDescriptor(); }

    bool activate(double sampleRate, uint32_t maxFrames) noexcept override {
        (void)maxFrames;
        sr_ = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
        quality_ = buildingQuality();
        try {
            room_.prepare(sr_, 64, 0.1);
        } catch (...) {
            return false;
        }
        displayClock_.prepare(sr_);
        display_.clear();
        reset();
        return true;
    }

    void reset() noexcept override {
        for (DrumVoice& v : voices_) v = DrumVoice{};
        live_ = 0;
        for (uint32_t p = 0; p < kPads; ++p) {
            hits_[p] = 0;
            heldCount_[p] = 0;
            padLevel_[p] = 0.0f;
        }
        for (auto& c : captureMax_) c.fill(0.0f);
        for (auto& c : captureMin_) c.fill(0.0f);
        captureAt_.fill(0);
        captureBin_.fill(1);
        glue_.clear();
        glueGain_ = 1.0;
        kitDriveL_.clear();
        kitDriveR_.clear();
        room_.clear();
        roomQuiet_ = 0;
        roomOn_ = false;
        settled_ = true;
        left_ = 0;
        clock_ = 0;
        lastPad_ = -1;
    }

    bool quiet() const noexcept override { return settled_; }

    uint32_t readDisplay(float* out, uint32_t max) const noexcept override { return display_.read(out, max); }

    // SampleSlots: one slot per pad (A1 = 0).
    uint32_t sampleSlotCount() const noexcept override { return kPads; }
    const std::string& sampleSource(uint32_t slot) const noexcept override {
        static const std::string none;
        return slot < kPads ? sources_[slot] : none;
    }
    bool setSample(uint32_t slot, std::unique_ptr<SampleBuffer> buffer) noexcept override {
        if (slot >= kPads) return false;
        if (!buffer) buffer.reset(new (std::nothrow) SampleBuffer());
        if (!buffer) return false;
        sources_[slot] = buffer->source;
        slots_[slot].offer(buffer.release());
        return true;
    }

protected:
    void beginBlock(const ProcessBlock& b) noexcept override {
        block_ = &b;
        ++blockCount_;
        // A new sample: voices still playing the one it replaces stop their sample layer (it is freed later).
        for (uint32_t s = 0; s < kPads; ++s) {
            const SampleBuffer* before = playing_[s];
            const SampleBuffer* now = slots_[s].poll();
            if (now != before) {
                for (DrumVoice& v : voices_)
                    if (v.sample == before && before) v.sample = nullptr, v.smpPlaying = false;
                playing_[s] = now;
            }
        }
        const bool playing = b.transport && b.transport->playing;
        if (playing && !wasPlaying_)  // Play: the variation starts over, so a render repeats
            for (uint32_t p = 0; p < kPads; ++p) hits_[p] = 0;
        wasPlaying_ = playing;
        mode_ = clampi(parameterAt(b, kMode, 0, kModeKit), 0, 1);
        channel_ = clampi(parameterAt(b, kChannel, 0, 0), 0, 16);
        base_ = clampi(parameterAt(b, kBaseNote, 0, 36), 0, 64);
        seed_ = static_cast<uint32_t>(clampi(parameterAt(b, kSeed, 0, 1), 0, 65535));
    }

    void onNote(const NoteMessage& m) noexcept override {
        if (!block_) return;
        const uint32_t at = m.frame;
        switch (m.type) {
            case NoteMessageType::On: noteOn(m, at); break;
            case NoteMessageType::Off: noteOff(m, at); break;
            case NoteMessageType::Pressure:
                for (DrumVoice& v : voices_)
                    if (v.active && v.noteId == m.noteId) v.pressure = clampd(m.value, 0, 1);
                break;
            default: break;
        }
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        for (uint32_t i = 0; i < frames;) {
            if (left_ == 0) {
                control(b, offset + i);
                left_ = kControlFrames;
            }
            const uint32_t n = std::min(left_, frames - i);
            renderChunk(left + i, right + i, n);
            i += n;
            left_ -= n;
            clock_ += n;
        }
        if (displayClock_.tick(frames)) publish(b, offset);
    }

private:
    // ---------- Notes ----------

    // Whether a note on MIDI channel `ch` (0..15) reaches pad settings with channel choice `chan`.
    bool channelMatches(int chan, int ch) const noexcept {
        if (chan == 0) return channel_ == 0 || channel_ == ch + 1;  // Kit: the instrument's channel
        if (chan == 1) return true;                                // Any
        return chan - 2 == ch;
    }

    void noteOn(const NoteMessage& m, uint32_t at) noexcept {
        const ProcessBlock& b = *block_;
        if (mode_ == kModeSingle) {
            if (channel_ == 0 || channel_ == m.channel + 1) hit(0, m, at);
            return;
        }
        bool any = false;
        // Pads playing chromatically on their own channel take every note there; the others their note.
        for (uint32_t p = 0; p < kPads; ++p) {
            const Voice& def = defaultVoice(p);
            const int note = clampi(parameterAt(b, padParam(p, kNote), at, def[kNote]), 0, kNoteFirst + 127);
            if (note == kNoteOff) continue;
            const int chan = clampi(parameterAt(b, padParam(p, kChan), at, def[kChan]), 0, 17);
            if (!channelMatches(chan, m.channel)) continue;
            const bool track = parameterAt(b, padParam(p, kTrack), at, def[kTrack]) >= 0.5;
            const bool chromatic = track && chan >= 2;
            const int key = note == kNoteAuto ? autoNote(p, base_) : note - kNoteFirst;
            if (chromatic || (note != kNoteAny && key == m.key)) any = hit(p, m, at) || any;
        }
        if (any) return;
        for (uint32_t p = 0; p < kPads; ++p) {
            const Voice& def = defaultVoice(p);
            if (clampi(parameterAt(b, padParam(p, kNote), at, def[kNote]), 0, kNoteFirst + 127) != kNoteAny) continue;
            if (!channelMatches(clampi(parameterAt(b, padParam(p, kChan), at, def[kChan]), 0, 17), m.channel)) continue;
            hit(p, m, at);
        }
    }

    void noteOff(const NoteMessage& m, uint32_t at) noexcept {
        for (uint32_t i = 0; i < live_; ++i) {
            DrumVoice& v = voices_[list_[i]];
            if (!v.active || v.noteId != m.noteId) continue;
            const PadSettings& s = settings_[v.pad];
            removeHeld(static_cast<uint32_t>(v.pad), m.noteId);
            if (s.mono && s.track && heldCount_[v.pad] > 0) {  // back to the newest note still held, gliding
                const auto& top = held_[v.pad][heldCount_[v.pad] - 1];
                v.noteId = top.first;
                v.note = top.second;
                v.glideTarget = v.note - s.root;
                continue;
            }
            v.held = false;
            if (s.gate && !v.releasing) {
                v.releasing = true;
                v.relCoef = fall(s.release, sr_);
            }
        }
        (void)at;
    }

    void addHeld(uint32_t pad, uint32_t id, double note) noexcept {
        auto& h = held_[pad];
        uint32_t& n = heldCount_[pad];
        if (n == kHeldMax) {  // full: the oldest goes
            for (uint32_t i = 1; i < n; ++i) h[i - 1] = h[i];
            --n;
        }
        h[n++] = {id, note};
    }
    void removeHeld(uint32_t pad, uint32_t id) noexcept {
        auto& h = held_[pad];
        uint32_t& n = heldCount_[pad];
        uint32_t keep = 0;
        for (uint32_t i = 0; i < n; ++i)
            if (h[i].first != id) h[keep++] = h[i];
        n = keep;
    }

    // A deterministic number in -1..1: the variation seed, the pad, its hit count and which value.
    double random(uint32_t pad, uint32_t which) const noexcept {
        const uint32_t x = hash32(seed_ * 0x9E3779B1u ^ hash32(pad * 0x85EBCA77u ^ hash32(hits_[pad] * 0xC2B2AE3Du ^ which)));
        return static_cast<double>(x) * (2.0 / 4294967295.0) - 1.0;
    }

    // A hit on `pad`; false (nothing happens) when the pad is unused.
    bool hit(uint32_t pad, const NoteMessage& m, uint32_t at) noexcept {
        PadSettings& s = settings_[pad];
        readPad(*block_, pad, at, s, blockCount_);
        if (!s.used) return false;
        const double note = m.pitch;
        if (s.track) addHeld(pad, m.noteId, note);
        // Mono with pitch tracking: an overlapping note glides the sounding voice there (an 808 slide).
        if (s.mono && s.track && heldCount_[pad] > 1) {
            for (uint32_t i = 0; i < live_; ++i) {
                DrumVoice& v = voices_[list_[i]];
                if (v.active && v.pad == static_cast<int>(pad) && v.held && !v.fading) {
                    v.noteId = m.noteId;
                    v.note = note;
                    v.glideTarget = note - s.root;
                    return true;
                }
            }
        }
        // Choke group: every other pad in it fades out.
        if (s.choke > 0)
            for (uint32_t i = 0; i < live_; ++i) {
                DrumVoice& v = voices_[list_[i]];
                if (v.active && v.pad != static_cast<int>(pad) && settings_[v.pad].choke == s.choke) fade(v);
            }
        // The pad's own polyphony: the oldest past it fades (mono: every one).
        const int poly = s.mono ? 1 : s.poly;
        for (;;) {
            int count = 0;
            DrumVoice* oldest = nullptr;
            for (uint32_t i = 0; i < live_; ++i) {
                DrumVoice& v = voices_[list_[i]];
                if (!v.active || v.fading || v.pad != static_cast<int>(pad)) continue;
                ++count;
                if (!oldest || v.age < oldest->age) oldest = &v;
            }
            if (count < poly || !oldest) break;
            fade(*oldest);
        }
        if (settled_) {
            left_ = 0;  // from silence the grid starts at this hit, so a skipped (quiet) stretch changes nothing
            settled_ = false;
        }
        roomQuiet_ = 0;
        DrumVoice& v = allocate();
        const uint32_t index = static_cast<uint32_t>(&v - voices_);
        const SampleBuffer* sample = playing_[pad];
        const int quality = qualityNow(quality_);
        v = DrumVoice{};
        v.active = true;
        v.held = true;
        v.pad = static_cast<int>(pad);
        v.noteId = m.noteId;
        v.note = note;
        v.age = ++age_;
        v.velocity = clampd(m.velocity, 0, 1);
        v.quality = quality;
        v.sample = sample;
        v.rng = lib::Noise(0x5eed0000u + pad * 977u + hits_[pad] * 31u);
        // Velocity and the per-hit variation (docs/engine.md, "Drums", Variation).
        const double x = v.velocity - 1.0;
        v.var.gain = (1.0 + s.velLevel * x) * dbGain(s.rndLevel * 6.0 * random(pad, 5));
        v.var.pitch = s.velPitch * x + s.rndPitch * 0.01 * random(pad, 1);
        v.var.decayMul = exp2d(s.velDecay * x + 0.5 * s.rndDecay * random(pad, 2));
        v.var.toneOct = 2.0 * s.velTone * x + s.rndTone * random(pad, 3);
        v.var.click = 1.0 + s.velClick * x;
        v.var.pan = clampd(s.pan + s.rndPan * random(pad, 4), -1, 1);
        ++hits_[pad];
        v.glideSt = v.glideTarget = s.track ? note - s.root : 0.0;
        start(v, s);
        list_[live_++] = static_cast<uint16_t>(index);
        // Display: this pad's picture starts over with this hit.
        v.capture = true;
        for (uint32_t i = 0; i + 1 < live_; ++i)
            if (voices_[list_[i]].pad == static_cast<int>(pad)) voices_[list_[i]].capture = false;
        startCapture(pad, s, v);
        lastPad_ = static_cast<int>(pad);
        return true;
    }

    void fade(DrumVoice& v) noexcept {
        if (v.fading) return;
        v.fading = true;
        v.fadeCoef = fall(0.00375, sr_);  // -80 dB in 5 ms
    }

    DrumVoice& allocate() noexcept {
        prune();
        if (live_ < kVoices)
            for (DrumVoice& v : voices_)
                if (!v.active) return v;
        // Full: the oldest fading voice, else the oldest; it leaves the list (and is restarted by the caller).
        DrumVoice* pick = nullptr;
        for (int pass = 0; pass < 2 && !pick; ++pass)
            for (DrumVoice& v : voices_)
                if ((pass == 1 || v.fading) && (!pick || v.age < pick->age)) pick = &v;
        pick->active = false;
        prune();
        return *pick;
    }

    void prune() noexcept {
        uint32_t keep = 0;
        for (uint32_t i = 0; i < live_; ++i)
            if (voices_[list_[i]].active) list_[keep++] = list_[i];
        live_ = keep;
    }

    // ---------- Starting and updating a voice ----------

    void start(DrumVoice& v, const PadSettings& s) noexcept {
        v.invSr = 1.0 / sr_;
        coefficients(v, s, true);
        if (v.body) {
            v.bodyEnv.trigger();
            v.pitchEnv.start();
            v.phase = s.phase;
            v.phase2 = s.phase;
            v.phaseSub = 0.0;
        }
        if (v.click) {
            v.clickEnv.set(0.0001, 0.0, s.clickLength, 0.0, sr_);
            v.clickEnv.trigger();
        }
        if (v.noise) {
            v.clapCount = 0;
            v.clapPeriod = std::max<uint32_t>(1, static_cast<uint32_t>(s.spacing * sr_));
            v.clapBursts = s.noiseMode == kNoiseClap ? static_cast<uint32_t>(s.bursts) : 0;
            v.burstCoef = fall(3.0 * s.spacing, sr_);
            if (s.noiseMode == kNoiseClap) v.burst = 0.0;
            else v.noiseEnv.trigger();
        }
        if (v.metal) {
            for (double& p : v.mPhase) p = 0.0;
            v.metalEnv.trigger();
        }
        if (v.res) {
            v.modal.clear();
            v.exciteAt = 0;
            const double width = 0.0005 + (1.0 - s.bright) * 0.002;  // a softer mallet strikes longer
            v.exciteLength = s.exciter == kExciteNoise ? static_cast<uint32_t>(0.008 * sr_)
                                                       : std::max<uint32_t>(2, static_cast<uint32_t>(width * sr_));
            v.exciteLeft = s.exciter == kExciteLayers ? 0 : v.exciteLength;
            v.ringing = true;
        }
        if (v.smp && v.sample) {
            const double len = static_cast<double>(v.sample->data.size());
            double a = s.start * (len - 1.0), z = s.end * (len - 1.0);
            if (z < a) std::swap(a, z);
            v.smpFirst = a;
            v.smpLast = z;
            v.reverse = s.reverse;
            v.smpPos = s.reverse ? z : a;
            v.smpPlaying = z > a;
            v.smpEnv.set(s.smpAttack, 0.0, s.smpDecay, 0.0, sr_);
            v.smpEnv.trigger();
        }
        v.fltEnvLevel = 1.0;
    }

    // The voice's coefficients from its pad's settings, its variation, glide and pressure (each control).
    void coefficients(DrumVoice& v, const PadSettings& s, bool first) noexcept {
        const double sr = sr_;
        const bool eco = v.quality == kQualityEco;
        if (!first) v.glideSt += (v.glideTarget - v.glideSt) * (1.0 - lib::fastExp(-3.0 * kControlFrames / (s.glide * sr)));
        double st = s.tune + v.var.pitch + v.glideSt;
        double toneOct = v.var.toneOct;
        const double p = v.pressure * s.pressAmt;
        if (s.pressDest == kPressPitch) st += 12.0 * p;
        if (s.pressDest == kPressTone) toneOct -= 4.0 * p;
        if (s.pressDest == kPressChoke && v.pressure * std::fabs(s.pressAmt) > 0.5) fade(v);
        v.dampCoef = s.pressDest == kPressDamp && p > 0.0 ? fall(0.03 / p, sr) : 1.0;
        const double mul = exp2d(st / 12.0);
        const double decayMul = v.var.decayMul;
        if (first) {
            v.body = s.bodyOn;
            v.click = s.clickOn;
            v.noise = s.noiseOn;
            v.metal = s.metalOn;
            v.res = s.resOn;
            v.smp = s.smpOn;
        }
        if (v.body) {
            v.wave = s.wave;
            v.fEnd = s.freq * mul;
            v.fStart = v.fEnd * exp2d(s.pitchSt / 12.0);
            v.pitchEnv.set(0.0, 0.0, s.ptime, s.pcurve, sr);
            v.bodyEnv.set(s.attack, s.hold, s.decay * decayMul, s.dcurve, sr);
            v.p2ratio = s.p2ratio;
            v.p2level = s.p2level;
            v.sub = s.sub;
            v.subDt = v.fEnd / s.subDiv * v.invSr;
            v.shapeAmt = s.shape > 0.0 ? 1.0 + 9.0 * s.shape : 0.0;
            v.shapeNorm = s.shapeNorm;
            v.fold = s.fold > 0.0 ? 1.0 + 5.0 * s.fold : 0.0;
            v.bodyLevel = s.bodyLevel;
        }
        if (v.click) {
            v.clickType = s.clickType;
            v.clickTone = s.clickTone * mul;
            v.clickLevel = s.clickLevel * v.var.click;
            if (s.clickType == kClickNoise) v.clickHp.set(s.clickTone, sr);
            else if (s.clickType == kClickImpulse) v.clickHp.set(s.clickTone, sr);
            else if (s.clickType == kClickPop) v.clickBp.set(s.clickTone, 3.0, sr);
        }
        if (v.noise) {
            v.noiseMode = s.noiseMode;
            v.color = s.color;
            v.noiseFilter = s.noiseFilter;
            v.noiseLevel = s.noiseLevel;
            if (s.noiseMode == kNoiseClap) v.tailEnv.set(s.noiseAttack, 0.0, s.noiseDecay * decayMul, s.noiseCurve, sr);
            else v.noiseEnv.set(s.noiseAttack, 0.0, s.noiseDecay * decayMul, s.noiseCurve, sr);
            const double env = s.noiseMode == kNoiseClap ? std::max(v.burst, v.tailEnv.level) : v.noiseEnv.level;
            const double f = clampd(s.noiseFreq * exp2d(s.sweep * env + toneOct), 20, 0.45 * sr);
            if (s.noiseFilter != kFilterOff) v.noiseSvf.set(f, s.noiseQ, sr);
            if (first) {
                const double corners[3] = {80.0, 800.0, 6000.0};
                for (int k = 0; k < 3; ++k) v.pinkK[k] = 1.0 - lib::fastExp(-kTwoPi * corners[k] / sr);
                v.brownK = 1.0 - lib::fastExp(-kTwoPi * 40.0 / sr);
                v.wireK = 1.0 - lib::fastExp(-1.0 / (0.004 * sr));
            }
            v.crushEvery = std::max<uint32_t>(1, static_cast<uint32_t>(sr / f));
        }
        if (v.metal) {
            v.metalMode = s.metalMode;
            const double base = s.metalFreq * mul;
            const double rate = v.quality == kQualityHigh ? 0.5 : 1.0;  // High runs it at twice the rate
            for (int i = 0; i < 6; ++i) {
                double f = base * s.ratio[i];
                v.mAmp[i] = f < 0.45 * sr ? s.amp[i] : 0.0;
                v.mDt[i] = f * v.invSr * rate;
            }
            v.fmIndex = s.fm / kTwoPi;
            v.metalNoise = s.metalNoise;
            v.band = s.band;
            v.bandGain = 1.0 / s.metalQ;
            v.metalLevel = s.metalLevel;
            v.metalBp.set(clampd(s.metalColor * exp2d(toneOct), 100, 0.45 * sr), s.metalQ, sr);
            v.metalHp.set(clampd(s.metalTone * exp2d(toneOct), 100, 0.45 * sr), s.metalQ, sr);
            v.metalEnv.set(s.metalAttack, 0.0, s.metalDecay * decayMul, s.metalCurve, sr);
        }
        if (v.res) {
            lib::ModalSettings m;
            m.model = static_cast<lib::ModalModel>(s.model);
            m.frequency = s.resFreq * mul;
            m.decay = s.resDecay * decayMul;
            m.damping = s.damp;
            m.brightness = clampd(s.bright + 0.15 * toneOct, 0, 1);
            m.inharmonicity = s.inharm;
            m.position = s.pos;
            m.modes = v.quality == kQualityEco ? 8 : (v.quality == kQualityHigh ? 32 : 16);
            if (first || m.model != v.modalSet.model || m.frequency != v.modalSet.frequency || m.decay != v.modalSet.decay ||
                m.damping != v.modalSet.damping || m.brightness != v.modalSet.brightness ||
                m.inharmonicity != v.modalSet.inharmonicity || m.position != v.modalSet.position || m.modes != v.modalSet.modes) {
                v.modal.set(m, sr);
                v.modalSet = m;
            }
            v.exciter = s.exciter;
            v.resInput = s.input;
            v.resLevel = s.resLevel;
        }
        if (v.smp) {
            v.smpStep = exp2d((s.smpTune + st) / 12.0);
            v.smpLevel = s.smpLevel;
            v.smpEnv.coef = fall(s.smpDecay * decayMul, sr);
            v.smpEnv.coefFast = v.smpEnv.coef;
        }
        // Effects.
        v.drive.set(s.driveType, s.drive);
        v.drivePost = s.drivePost;
        v.flt = s.flt;
        if (first) v.fltEnvCoef = lib::fastExp(-kSixtyDb * kControlFrames / (s.fltDecay * sr));
        const double fc = clampd(s.cutoff * exp2d(s.fltEnv * v.fltEnvLevel + toneOct), 20, 0.45 * sr);
        if (!first) {
            v.fltEnvLevel *= v.fltEnvCoef;
            v.fltEnvCoef = lib::fastExp(-kSixtyDb * kControlFrames / (s.fltDecay * sr));
        }
        if (s.flt == kVfLp6) v.lp6.set(fc, sr);
        else if (s.flt != kVfOff) v.svf.set(fc, s.fltQ, sr);
        v.eq = s.eqLow != 0.0 || s.eqMid != 0.0 || s.eqHigh != 0.0;
        if (v.eq) {
            v.eqLow.set(lib::EqBand::Kind::LowShelf, 120.0, s.eqLow, 0.70710678118654752, sr);
            v.eqMid.set(lib::EqBand::Kind::Bell, s.eqFreq, s.eqMid, 1.0, sr);
            v.eqHigh.set(lib::EqBand::Kind::HighShelf, 6000.0, s.eqHigh, 0.70710678118654752, sr);
        }
        v.shaper = s.trA != 0.0 || s.trS != 0.0;
        v.trA = s.trA;
        v.trS = s.trS;
        if (first) {
            v.fast.setCoefficients(lib::timeCoefficient(0.0005, sr), lib::timeCoefficient(0.015, sr));
            v.slow.setCoefficients(lib::timeCoefficient(0.015, sr), lib::timeCoefficient(0.15, sr));
            v.compEnv.setCoefficients(lib::timeCoefficient(0.002, sr), lib::timeCoefficient(0.06, sr));
        }
        v.comp = s.comp > 0.0;
        v.compThr = -6.0 - 24.0 * s.comp;
        v.compRatio = 1.0 + 9.0 * s.comp;
        v.compMakeup = lib::dbToGain(-0.35 * v.compThr * (1.0 - 1.0 / v.compRatio));
        // Level and pan: a balance with the centre at full level on both sides (a mono drum stays as loud as it was);
        // toward a side, the other falls along a quarter cosine.
        const double g = s.gain * v.var.gain, pan = v.var.pan;
        v.gainL = g * (pan <= 0.0 ? 1.0 : lib::fastSinCycles(0.25 + 0.25 * pan));
        v.gainR = g * (pan >= 0.0 ? 1.0 : lib::fastSinCycles(0.25 - 0.25 * pan));
        (void)eco;
    }

    // ---------- Per sample ----------

    static double bodySample(DrumVoice& v) noexcept {
        const double pe = v.pitchEnv.next();
        const double f = v.fEnd + (v.fStart - v.fEnd) * pe;
        const double dt = f * v.invSr;
        double y;
        switch (v.wave) {
            case kWaveTriangle: y = lib::triangleWave(v.phase); break;
            case kWaveSaw: y = lib::sawWave(v.phase, dt); break;
            case kWaveSquare: y = lib::squareWave(v.phase, dt); break;
            default: y = lib::fastSinCycles(v.phase); break;
        }
        v.phase += dt;
        v.phase -= std::floor(v.phase);
        if (v.p2level > 0.0) {
            y += v.p2level * lib::fastSinCycles(v.phase2);
            v.phase2 += dt * v.p2ratio;
            v.phase2 -= std::floor(v.phase2);
        }
        if (v.shapeAmt > 0.0) y = lib::fastTanh(y * v.shapeAmt) * v.shapeNorm;
        if (v.fold > 0.0) y = lib::fastSinCycles(y * v.fold * 0.25);
        if (v.sub > 0.0) {
            y += v.sub * lib::fastSinCycles(v.phaseSub);
            v.phaseSub += v.subDt;
            v.phaseSub -= std::floor(v.phaseSub);
        }
        return y * v.bodyEnv.next();
    }

    static double clickSample(DrumVoice& v) noexcept {
        const double env = v.clickEnv.next();
        if (env == 0.0) return 0.0;
        double y;
        switch (v.clickType) {
            case kClickImpulse: y = v.clickHp.low(env); break;
            case kClickBlip:
                y = lib::fastSinCycles(v.clickPhase);
                v.clickPhase += v.clickTone * v.invSr;
                break;
            case kClickTick:
                y = v.clickPhase - std::floor(v.clickPhase) < 0.5 ? 1.0 : -1.0;
                v.clickPhase += v.clickTone * v.invSr;
                break;
            case kClickChirp:
                y = lib::fastSinCycles(v.clickPhase);
                v.clickPhase += v.clickTone * (1.0 + 3.0 * env) * v.invSr;
                break;
            case kClickPop: y = v.clickBp.bandpass(v.rng.next()) * 2.0; break;
            default: y = v.clickHp.high(v.rng.next()); break;
        }
        v.clickPhase -= std::floor(v.clickPhase);
        return y * env * v.clickLevel;
    }

    static double noiseSource(DrumVoice& v) noexcept {
        const double w = v.rng.next();
        switch (v.color) {
            case kPink: {
                // Approximately -3 dB an octave: white plus three one-poles a decade apart, each louder as it is lower.
                v.pink[0] += (w - v.pink[0]) * v.pinkK[0];
                v.pink[1] += (w - v.pink[1]) * v.pinkK[1];
                v.pink[2] += (w - v.pink[2]) * v.pinkK[2];
                return (0.25 * w + 2.2 * v.pink[0] + 1.0 * v.pink[1] + 0.55 * v.pink[2]) * 0.9;
            }
            case kBrown:
                v.brown += (w - v.brown) * v.brownK;
                return v.brown * 6.0;
            case kCrushed:
                if (v.crushLeft == 0) {
                    v.crushHeld = w;
                    v.crushLeft = v.crushEvery;
                }
                --v.crushLeft;
                return v.crushHeld;
            default: return w;
        }
    }

    static double noiseSample(DrumVoice& v, double bodyRaw) noexcept {
        double env;
        if (v.noiseMode == kNoiseClap) {
            if (v.clapCount < v.clapBursts * v.clapPeriod) {
                if (v.clapCount % v.clapPeriod == 0) v.burst = 1.0;
                env = v.burst;
                v.burst *= v.burstCoef;
                if (++v.clapCount == v.clapBursts * v.clapPeriod) v.tailEnv.trigger();
            } else {
                env = v.tailEnv.next();
            }
        } else {
            env = v.noiseEnv.next();
            if (v.noiseMode == kNoiseSnappy && v.body) {
                // The snares: the wires buzz while the shell moves them.
                const double a = bodyRaw < 0.0 ? -bodyRaw : bodyRaw;
                v.wire += (a - v.wire) * v.wireK;
                const double w = v.wire * 3.0;
                env *= 0.35 + 0.65 * (w > 1.0 ? 1.0 : w);
            }
        }
        if (env == 0.0) return 0.0;
        const double x = noiseSource(v);
        double y;
        switch (v.noiseFilter) {
            case kFilterLp: y = v.noiseSvf.lowpass(x); break;
            case kFilterBp: y = v.noiseSvf.bandpass(x); break;
            case kFilterHp: y = v.noiseSvf.highpass(x); break;
            default: y = x; break;
        }
        return y * env * v.noiseLevel;
    }

    static double metalOsc(DrumVoice& v) noexcept {
        double y = 0.0;
        switch (v.metalMode) {
            case kMetalFmPairs:
                for (int i = 0; i < 6; i += 2) {
                    y += v.mAmp[i] * 2.0 * lib::fastSinCycles(v.mPhase[i] + v.fmIndex * lib::fastSinCycles(v.mPhase[i + 1]));
                }
                break;
            case kMetalRing:
                for (int i = 0; i < 6; i += 2) {
                    const double a = v.mPhase[i] < 0.5 ? 1.0 : -1.0, b = v.mPhase[i + 1] < 0.5 ? 1.0 : -1.0;
                    y += (v.mAmp[i] + v.mAmp[i + 1]) * a * b;
                }
                break;
            default:
                if (v.quality == kQualityEco) {
                    for (int i = 0; i < 6; ++i) y += v.mAmp[i] * (v.mPhase[i] < 0.5 ? 1.0 : -1.0);
                } else {
                    for (int i = 0; i < 6; ++i) y += v.mAmp[i] * lib::squareWave(v.mPhase[i], v.mDt[i]);
                }
                break;
        }
        for (int i = 0; i < 6; ++i) {
            v.mPhase[i] += v.mDt[i];
            if (v.mPhase[i] >= 1.0) v.mPhase[i] -= 1.0;
        }
        return y;
    }

    static double metalSample(DrumVoice& v) noexcept {
        const double env = v.metalEnv.next();
        if (env == 0.0) return 0.0;
        double m;
        if (v.quality == kQualityHigh) {
            double two[2] = {metalOsc(v), metalOsc(v)};
            m = v.metalOs.down(two);
        } else {
            m = metalOsc(v);
        }
        double x = m * (1.0 - v.metalNoise) + v.rng.next() * v.metalNoise;
        if (v.band > 0.0) x += (v.metalBp.bandpass(x) * v.bandGain - x) * v.band;  // unity at the band's centre
        return v.metalHp.highpass(x) * env * v.metalLevel;
    }

    static double sampleSample(DrumVoice& v) noexcept {
        if (!v.smpPlaying || !v.sample) return 0.0;
        const float* d = v.sample->data.data();
        const double pos = v.smpPos;
        const size_t i = static_cast<size_t>(pos);
        const double f = pos - static_cast<double>(i);
        const size_t last = v.sample->data.size() - 1;
        const double a = d[i], b = d[i < last ? i + 1 : last];
        const double y = (a + (b - a) * f) * v.smpEnv.next();
        if (v.reverse) {
            v.smpPos -= v.smpStep;
            if (v.smpPos <= v.smpFirst) v.smpPlaying = false;
        } else {
            v.smpPos += v.smpStep;
            if (v.smpPos >= v.smpLast) v.smpPlaying = false;
        }
        if (!v.smpEnv.active()) v.smpPlaying = false;
        return y * v.smpLevel;
    }

    double voiceSample(DrumVoice& v) noexcept {
        double bodyRaw = 0.0, layers = 0.0;
        if (v.body) {
            bodyRaw = bodySample(v);
            layers += bodyRaw * v.bodyLevel;
        }
        if (v.click) layers += clickSample(v);
        if (v.noise) layers += noiseSample(v, bodyRaw);
        if (v.metal) layers += metalSample(v);
        if (v.smp) layers += sampleSample(v);
        double y = layers;
        if (v.res) {
            double excite = 0.0;
            if (v.exciteLeft) {
                const uint32_t k = v.exciteLength - v.exciteLeft--;
                if (v.exciter == kExciteMallet) {
                    const double n = static_cast<double>(v.exciteLength);
                    excite += (1.0 - lib::fastSinCycles(static_cast<double>(k) / n + 0.25)) / n;  // unit area
                } else {
                    excite += v.rng.next() * 0.02 * (1.0 - static_cast<double>(k) / v.exciteLength);
                }
            }
            y += v.modal.process(excite, v.resInput * layers) * v.resLevel;
        }
        // Effects.
        const int os = v.quality == kQualityEco ? 1 : (v.quality == kQualityHigh ? 4 : 2);
        if (!v.drivePost) y = v.drive.process(y, os);
        switch (v.flt) {
            case kVfLp6: y = v.lp6.low(y); break;
            case kVfLp12: y = v.svf.lowpass(y); break;
            case kVfHp: y = v.svf.highpass(y); break;
            case kVfBp: y = v.svf.bandpass(y); break;
            default: break;
        }
        if (v.drivePost) y = v.drive.process(y, os);
        if (v.eq) y = v.eqHigh.process(v.eqMid.process(v.eqLow.process(y)));
        if (v.shaper) {
            const double a = y < 0.0 ? -y : y;
            const double f = v.fast.process(a), s = v.slow.process(a);
            double d = (f - s) / (s + 1e-6);
            d = d > 1.0 ? 1.0 : (d < -1.0 ? -1.0 : d);
            y *= lib::dbToGain(d > 0.0 ? 9.0 * v.trA * d : -9.0 * v.trS * d);  // up to 9 dB either way
        }
        if (v.comp) {
            const double a = y < 0.0 ? -y : y;
            const double level = lib::gainToDb(v.compEnv.process(a));
            v.gr = lib::compressorGainDb(level, v.compThr, v.compRatio, 6.0);
            y *= lib::dbToGain(v.gr) * v.compMakeup;
        }
        if (v.fading) {
            v.fadeGain *= v.fadeCoef;
            y *= v.fadeGain;
        }
        if (v.releasing) {
            v.relGain *= v.relCoef;
            y *= v.relGain;
        }
        if (v.dampCoef < 1.0) v.dampGain *= v.dampCoef;
        return y * v.dampGain;
    }

    // ---------- The control grid and the block ----------

    void control(const ProcessBlock& b, uint32_t at) noexcept {
        prune();
        uint64_t updated = 0;  // pads whose settings were read this control
        for (uint32_t i = 0; i < live_; ++i) {
            DrumVoice& v = voices_[list_[i]];
            const uint32_t pad = static_cast<uint32_t>(v.pad);
            const uint64_t bit = 1ull << pad;
            if (!(updated & bit)) {
                readPad(b, pad, at, settings_[pad], blockCount_);
                updated |= bit;
            }
            if (v.res) v.ringing = v.exciteLeft > 0 || v.modal.ringing();
            const bool done = !v.sounding() || (v.fading && v.fadeGain < 1e-4) || (v.releasing && v.relGain < 1e-4) ||
                              v.dampGain < 1e-4;
            if (done) {
                v.active = false;
                continue;
            }
            coefficients(v, settings_[pad], false);
        }
        prune();
        // Kit effects' knobs.
        glueAmount_ = clampd(parameterAt(b, kGlue, at, 0), 0, 1);
        if (glueAmount_ > 0.0) {
            glueThr_ = clampd(parameterAt(b, kGlueThreshold, at, -12), -40, 0);
            glueRatio_ = clampd(parameterAt(b, kGlueRatio, at, 4), 1, 20);
            glueMakeup_ = lib::dbToGain(clampd(parameterAt(b, kGlueMakeup, at, 0), 0, 24));
            glue_.setCoefficients(lib::timeCoefficient(clampd(parameterAt(b, kGlueAttack, at, 10), 0.1, 100) * 0.001, sr_),
                                  lib::timeCoefficient(clampd(parameterAt(b, kGlueRelease, at, 120), 10, 1000) * 0.001, sr_));
        }
        kitDriveType_ = clampi(parameterAt(b, kKitDriveType, at, 0), 0, 4);
        if (kitDriveType_ != 0) {
            static constexpr int kMap[] = {kDriveOff, kDriveSoft, kDriveTube, kDriveHard, kDriveCrush};
            const double amount = parameterAt(b, kKitDrive, at, 2);
            kitDriveL_.set(kMap[kitDriveType_], amount);
            kitDriveR_.set(kMap[kitDriveType_], amount);
            kitDriveMix_ = clampd(parameterAt(b, kKitDriveMix, at, 1), 0, 1);
        }
        const double room = clampd(parameterAt(b, kRoom, at, 0), 0, 1);
        if (room > 0.0) {
            lib::ReverbSettings r;
            r.size = clampd(parameterAt(b, kRoomSize, at, 0.35), 0, 1);
            r.decay = clampd(parameterAt(b, kRoomDecay, at, 0.8), 0.1, 10);
            r.damping = clampd(parameterAt(b, kRoomDamping, at, 0.5), 0, 1);
            r.mix = room;
            r.width = 1.0;
            const lib::ReverbSettings& was = room_.settings();
            if (!roomOn_ || r.size != was.size || r.decay != was.decay || r.damping != was.damping || r.mix != was.mix)
                room_.set(r);
            room_.setLight(qualityNow(quality_) == kQualityEco);
            roomOn_ = true;
        } else if (roomOn_) {
            room_.clear();  // turned off: its tail stops
            roomOn_ = false;
        }
        roomMix_ = room;
        // Nothing sounding and the room's tail below -100 dB for half a second: every state goes to exact zero and
        // the instrument says it is quiet (the host may skip it until the next note).
        if (live_ == 0 && !settled_ && (!roomOn_ || roomQuiet_ >= static_cast<uint32_t>(sr_ * 0.5))) {
            glue_.clear();
            kitDriveL_.clear();
            kitDriveR_.clear();
            if (roomOn_) room_.clear();
            settled_ = true;
        }
        volume_ = dbGain(parameterAt(b, kVolume, at, 0));
    }

    void renderChunk(float* left, float* right, uint32_t n) noexcept {
        double busL[kOutputs][kControlFrames], busR[kOutputs][kControlFrames];
        uint32_t used = 1;  // buses 0..used-1 written
        for (uint32_t i = 0; i < n; ++i) busL[0][i] = busR[0][i] = 0.0;
        for (uint32_t i = 0; i < live_; ++i) {
            DrumVoice& v = voices_[list_[i]];
            if (!v.active) continue;
            const uint32_t pad = static_cast<uint32_t>(v.pad);
            const uint32_t out = static_cast<uint32_t>(settings_[pad].out);
            while (used <= out) {
                for (uint32_t k = 0; k < n; ++k) busL[used][k] = busR[used][k] = 0.0;
                ++used;
            }
            float peak = padLevel_[pad];
            for (uint32_t k = 0; k < n; ++k) {
                const double y = voiceSample(v);
                busL[out][k] += y * v.gainL;
                busR[out][k] += y * v.gainR;
                const float a = static_cast<float>(y < 0.0 ? -y : y);
                if (a > peak) peak = a;
                if (v.capture) captureSample(pad, static_cast<float>(y));
            }
            padLevel_[pad] = peak;
        }
        // Kit effects on the main bus.
        for (uint32_t k = 0; k < n; ++k) {
            double l = busL[0][k], r = busR[0][k];
            if (glueAmount_ > 0.0) {
                const double a = std::max(l < 0.0 ? -l : l, r < 0.0 ? -r : r);
                const double gr = lib::compressorGainDb(lib::gainToDb(glue_.process(a)), glueThr_, glueRatio_, 6.0);
                glueGr_ = gr;
                const double g = lib::dbToGain(gr) * glueMakeup_;
                const double w = (g - 1.0) * glueAmount_ + 1.0;
                l *= w;
                r *= w;
            }
            if (kitDriveType_ != 0) {
                const int q = qualityNow(quality_);
                const int os = q == kQualityEco ? 1 : (q == kQualityHigh ? 4 : 2);
                l += (kitDriveL_.process(l, os) - l) * kitDriveMix_;
                r += (kitDriveR_.process(r, os) - r) * kitDriveMix_;
            }
            float fl = static_cast<float>(l), fr = static_cast<float>(r);
            if (roomOn_) {
                room_.process(fl, fr);
                if (live_ == 0) roomQuiet_ = std::fabs(fl) + std::fabs(fr) < 1e-5f ? roomQuiet_ + 1 : 0;
            }
            double outL = fl, outR = fr;
            for (uint32_t o = 1; o < used; ++o) {  // the other outputs: past the kit effects, into the one output
                outL += busL[o][k];
                outR += busR[o][k];
            }
            left[k] = static_cast<float>(outL * volume_);
            right[k] = static_cast<float>(outR * volume_);
        }
    }

    // ---------- Display ----------

    static constexpr uint32_t kBins = 256, kPitchPoints = 64;

    void startCapture(uint32_t pad, const PadSettings& s, const DrumVoice& v) noexcept {
        double length = 0.05;
        if (s.bodyOn) length = std::max(length, s.attack + s.hold + s.decay);
        if (s.clickOn) length = std::max(length, s.clickLength);
        if (s.noiseOn) length = std::max(length, s.noiseAttack + s.noiseDecay + (s.noiseMode == kNoiseClap ? s.bursts * s.spacing : 0.0));
        if (s.metalOn) length = std::max(length, s.metalAttack + s.metalDecay);
        if (s.resOn) length = std::max(length, s.resDecay);
        if (s.smpOn && v.sample)
            length = std::max(length, std::min(s.smpDecay, std::fabs(s.end - s.start) * v.sample->data.size() / sr_));
        length = clampd(length * v.var.decayMul * 1.1, 0.05, 4.0);
        captureMax_[pad].fill(0.0f);
        captureMin_[pad].fill(0.0f);
        captureAt_[pad] = 0;
        captureBin_[pad] = std::max<uint32_t>(1, static_cast<uint32_t>(length * sr_ / kBins));
        captureLength_[pad] = static_cast<float>(captureBin_[pad] * kBins / sr_);
    }
    void captureSample(uint32_t pad, float y) noexcept {
        const uint32_t bin = captureAt_[pad] / captureBin_[pad];
        if (bin >= kBins) return;
        ++captureAt_[pad];
        if (y > captureMax_[pad][bin]) captureMax_[pad][bin] = y;
        if (y < captureMin_[pad][bin]) captureMin_[pad][bin] = y;
    }

    // Layout (docs/engine.md, "Drums", Display data): 16 header floats, 64 pad levels, the shown pad's waveform
    // (256 maxima, 256 minima) and its body pitch curve (64 points, Hz).
    void publish(const ProcessBlock& b, uint32_t at) noexcept {
        if (qualityNow(quality_) == kQualityEco && (++publishCount_ & 1)) return;  // Eco: half as often
        const int view = clampi(parameterAt(b, kViewPad, at, 0), 0, static_cast<int>(kPads));
        const int pad = view > 0 ? view - 1 : (lastPad_ >= 0 ? lastPad_ : 0);
        float* d = frame_;
        for (uint32_t i = 0; i < 16; ++i) d[i] = 0.0f;
        d[0] = 1.0f;  // layout version
        d[1] = static_cast<float>(mode_);
        d[2] = static_cast<float>(pad);
        d[3] = static_cast<float>(-glueGr_);
        float gr = 0.0f;
        uint32_t sounding = 0;
        for (uint32_t i = 0; i < live_; ++i) {
            const DrumVoice& v = voices_[list_[i]];
            if (!v.active) continue;
            ++sounding;
            if (v.pad == pad && v.comp) gr = std::max(gr, static_cast<float>(-v.gr));
        }
        d[4] = gr;
        d[5] = captureLength_[pad];
        d[6] = kBins;
        d[7] = kPitchPoints;
        d[9] = static_cast<float>(sounding);
        d[10] = static_cast<float>(lastPad_);
        uint64_t mask = 0;
        for (uint32_t i = 0; i < live_; ++i)
            if (voices_[list_[i]].active) mask |= 1ull << voices_[list_[i]].pad;
        for (uint32_t p = 0; p < kPads; ++p) {
            d[16 + p] = (mask >> p & 1) ? std::max(padLevel_[p], 1e-6f) : 0.0f;
            padLevel_[p] = 0.0f;
        }
        for (uint32_t i = 0; i < kBins; ++i) {
            d[80 + i] = captureMax_[pad][i];
            d[80 + kBins + i] = captureMin_[pad][i];
        }
        // The body's pitch over the pitch envelope's first three time spans, as a hit at full velocity plays it.
        PadSettings s;
        readPad(b, static_cast<uint32_t>(pad), at, s);
        const double span = s.bodyOn ? clampd(s.ptime * 3.0, 0.01, 2.0) : 0.0;
        d[8] = static_cast<float>(span);
        if (s.bodyOn) {
            const double mul = exp2d(s.tune / 12.0), fEnd = s.freq * mul, fStart = fEnd * exp2d(s.pitchSt / 12.0);
            const double c = s.pcurve;
            for (uint32_t i = 0; i < kPitchPoints; ++i) {
                const double t = span * i / (kPitchPoints - 1);
                const double e = lib::fastExp(-kSixtyDb * t / s.ptime);
                const double shaped = c >= 0.0 ? e + c * (lib::fastExp(-kSixtyDb * 6.0 * t / s.ptime) - e)
                                               : e - c * (std::max(0.0, 1.0 - t / s.ptime) - e);
                d[80 + 2 * kBins + i] = static_cast<float>(fEnd + (fStart - fEnd) * shaped);
            }
        } else {
            for (uint32_t i = 0; i < kPitchPoints; ++i) d[80 + 2 * kBins + i] = 0.0f;
        }
        display_.publish(d, kDisplayFloats);
    }

public:
    static constexpr uint32_t kDisplayFloats = 80 + 2 * kBins + kPitchPoints;  // 656

private:
    static constexpr uint32_t kHeldMax = 8;

    double sr_ = 48000.0;
    const std::atomic<int>* quality_ = nullptr;
    const ProcessBlock* block_ = nullptr;
    DrumVoice voices_[kVoices];
    uint16_t list_[kVoices] = {};
    uint32_t live_ = 0;
    uint64_t age_ = 0;
    PadSettings settings_[kPads];
    uint32_t hits_[kPads] = {};
    std::pair<uint32_t, double> held_[kPads][kHeldMax] = {};
    uint32_t heldCount_[kPads] = {};
    int mode_ = kModeKit, channel_ = 0, base_ = 36;
    uint32_t seed_ = 1;
    bool wasPlaying_ = false;
    uint32_t left_ = 0;
    uint64_t clock_ = 0, blockCount_ = 0;
    // samples
    SampleHandover slots_[kPads];
    const SampleBuffer* playing_[kPads] = {};
    std::string sources_[kPads];  // control thread
    // kit effects
    lib::EnvelopeFollower glue_;
    double glueAmount_ = 0, glueThr_ = -12, glueRatio_ = 4, glueMakeup_ = 1, glueGr_ = 0, glueGain_ = 1;
    int kitDriveType_ = 0;
    double kitDriveMix_ = 1;
    Drive kitDriveL_, kitDriveR_;
    lib::Reverb room_;
    bool roomOn_ = false, settled_ = true;
    double roomMix_ = 0;
    uint32_t roomQuiet_ = 0;
    double volume_ = 1;
    // display
    DisplayBuffer<kDisplayFloats> display_;
    DisplayClock displayClock_;
    float frame_[kDisplayFloats] = {};
    float padLevel_[kPads] = {};
    std::array<std::array<float, kBins>, kPads> captureMax_{}, captureMin_{};
    std::array<uint32_t, kPads> captureAt_{}, captureBin_{};
    float captureLength_[kPads] = {};
    int lastPad_ = -1;
    uint32_t publishCount_ = 0;
};

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

const ModuleDescriptor& drumsDescriptor() {
    static const ModuleDescriptor d = [] {
        ModuleDescriptor m;
        m.id = kDrumsId;
        m.name = "Drums";
        m.role = ModuleRole::Instrument;
        m.ports = kPorts;
        m.portCount = 2;
        m.parameters = parameterTable();
        m.parameterCount = kParamCount;
        m.tailFrames = 192000 * 70;  // a 60 s ring at 192 kHz and the room; it says quiet() sooner
        return m;
    }();
    return d;
}

ModuleProcessor* makeDrums() noexcept { return new (std::nothrow) DrumsProcessor(); }

}  // namespace

void registerDrums(ModuleRegistry& registry) { registry.add(drumsDescriptor(), &makeDrums); }

// Renders one sound of the library as a built-in one-shot: a hit at full velocity on pad A1 in Single mode, until
// it falls silent (at most 6 s), the sample layer off.
bool renderBuiltinDrumSample(std::string_view name, double sampleRate, std::vector<float>& out) {
    const Sound* sound = findSound(name);
    return sound && drums::renderVoice(sound->voice, sampleRate, 6.0, out);
}

bool drums::renderVoice(const Voice& voice, double sampleRate, double seconds, std::vector<float>& out) {
    const Voice* sound = &voice;
    std::unique_ptr<DrumsProcessor> p(new (std::nothrow) DrumsProcessor());
    if (!p || !p->activate(sampleRate, 64)) return false;
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> values(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) values[k].value = d.parameters[k].defaultValue;
    values[kMode].value = kModeSingle;
    for (uint32_t k = 0; k < kPadParams; ++k) values[padParam(0, k)].value = (*sound)[k];
    values[padParam(0, kSmpOn)].value = 0.0;
    values[padParam(0, kPan)].value = 0.0;
    values[padParam(0, kRndPan)].value = 0.0;
    const uint32_t most = static_cast<uint32_t>(seconds * sampleRate);
    out.clear();
    out.reserve(most);
    float l[64], r[64];
    float* ch[2] = {l, r};
    const ChannelBufferView audio{ch, 2, 64};
    const Event on = notes::noteOn(0, 1, 60, 1.0);
    uint32_t silent = 0;
    for (uint32_t done = 0; done < most; done += 64) {
        const EventInput in{&on, done == 0 ? 1u : 0u};
        ProcessBlock b;
        b.frames = 64;
        b.sampleRate = sampleRate;
        b.audioOut = &audio;
        b.audioOutCount = 1;
        b.eventIn = &in;
        b.eventInCount = 1;
        b.parameters = values.data();
        b.parameterCount = d.parameterCount;
        if (!p->processPorts(b)) return false;
        for (int i = 0; i < 64; ++i) out.push_back(0.5f * (l[i] + r[i]));  // centred: both sides carry it whole
        if (p->quiet()) {
            if (++silent > 2) break;
        }
    }
    while (!out.empty() && std::fabs(out.back()) < 1e-6f) out.pop_back();
    return !out.empty();
}

}  // namespace caw
