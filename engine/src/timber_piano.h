// Timber's piano model: a commuted digital-waveguide piano (hammer-filtered soundboard excitation, coupled detuned strings, dampers, pedal and a shared sympathetic bank).
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <new>

#include "timber_core.h"

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
struct Piano {
    static constexpr uint32_t kEcoCap = 16, kNormalCap = 32, kHighCap = 48, kPool = kHighCap + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = true;
    static constexpr double kMinLife = 0.15, kSpread = 0.6;
    enum P : uint32_t { kHammer, kCharacter, kUnison, kStretch, kDecay, kSustain, kSoft, kResonance, kModelParams };
    static constexpr int kMaxDisp = 12, kSymp = 12;

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
        const bool want = pedal > 0.02 && resonance > 0.0;
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

    void post(float* l, float* r, uint32_t n, const Shared&) noexcept {
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
    bool postQuiet() const noexcept { return !sympOn; }
    void clearPost() noexcept {
        for (Line& s : symp) s.clear();
        for (float& z : sympZ) z = 0;
        sympPeak = 0;
        sympOn = false;
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
