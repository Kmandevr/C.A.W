// Timber's electric piano (tine and reed: a few modes into a pickup curve) and tonewheel organ (drawbars, percussion, scanner vibrato and the rotary speaker) models.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <new>

#include "builtin_fx_merged_stereomod.h"
#include "caw/library/fastmath.hpp"
#include "timber_core.h"

namespace caw::timber {

// ---------- Electric piano ----------

// Tine (a struck tine beside a tonebar, a magnetic pickup) or Reed (a struck steel reed, an electrostatic pickup).
// Per key four modes (complex one-poles): the tine's or reed's fundamental, its tonebar partner just off pitch (the
// slow beating), and the cantilever's 2nd and 3rd modes at 6.27 and 17.55 times (the bell, short and louder the
// harder the strike); then the pickup: Tine reads the displacement x through a magnet's flux curve,
// h^2 (x + s) / (h^2 + (x + s)^2) (h the pickup's distance, s its offset from the tine's axis: `symmetry`), so a
// close pickup and a hard strike bark with odd and even harmonics; Reed through a soft cubic with an even term.
// `bark` drives a tanh after it. [Assumption] the curves and decays are fitted by ear, not measured. Tremolo: an
// auto-pan for Tine (the suitcase's), an amplitude tremolo for Reed. Dampers: a released key fades in `release`.
struct EPiano {
    static constexpr uint32_t kEcoCap = 16, kNormalCap = 32, kHighCap = 32, kPool = kHighCap + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = true;
    static constexpr double kMinLife = 0.02, kSpread = 0.4;
    enum P : uint32_t { kKind, kPickup, kSymmetry, kBell, kBark, kTremolo, kRate, kDecay, kModelParams };

    struct Voice : VoiceBase {
        Mode mode[4];  // set() works out each; render() runs the four as one SIMD complex one-pole
        float amp = 1;
        double hz = 0, t60 = 1;
        bool damped = false;
    };

    int kind = 0;
    double pickup = 0.5, symmetry = 0.2, bell = 0.5, bark = 0.2, tremolo = 0, rate = 4, decay = 1;
    float h2 = 1, sym = 0, drive = 1, offset = 0, norm = 1;
    double sr = 48000, phase = 0;

    size_t allocBytes() const noexcept { return 0; }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 0.45, r.decay = 1.3, r.damping = 0.5, r.mix = 1.0, r.width = 1.0;
        return r;
    }
    bool prepare(double rate, Voice*, uint32_t) noexcept {
        sr = rate;
        return true;
    }
    void reset() noexcept { clearPost(); }
    void control(const double* p, const Shared&) noexcept {
        kind = static_cast<int>(clampd(p[kKind], 0, 1) + 0.5);
        pickup = clampd(p[kPickup], 0, 1);
        symmetry = clampd(p[kSymmetry], -1, 1);
        bell = clampd(p[kBell], 0, 1);
        bark = clampd(p[kBark], 0, 1);
        tremolo = clampd(p[kTremolo], 0, 1);
        rate = clampd(p[kRate], 0.5, 12);
        decay = clampd(p[kDecay], 0.25, 4);
        // The pickup: a far pickup (h large) is nearly linear; a close one bends hard.
        const double h = 0.35 + 1.6 * (1.0 - pickup);
        h2 = static_cast<float>(h * h);
        sym = static_cast<float>(0.6 * symmetry);
        offset = h2 * sym / (h2 + sym * sym);
        drive = static_cast<float>(1.0 + 6.0 * bark);
        norm = static_cast<float>(1.0 / std::sqrt(drive));
    }
    double keyT60(double pitch) const noexcept {
        const double t = (kind == 0 ? 7.0 : 4.0) * detPow(2.0, -(pitch - 40.0) / 18.0);
        return clampd(t, 0.4, 12.0) * decay;
    }
    void setModes(Voice& v, double t60) const noexcept {
        static constexpr double kRatio[2][4] = {{1.0, 1.0007, 6.267, 17.55}, {1.0, 0.9993, 6.27, 17.6}};
        const double life[4] = {t60, t60 * 1.4, 0.25 + 0.05 * t60, 0.06 + 0.01 * t60};
        for (int k = 0; k < 4; ++k) {
            const double hz = v.hz * kRatio[kind][k];
            if (hz > 0.45 * sr) v.mode[k].set(0.0, 0.0, sr), v.mode[k].clear();
            else v.mode[k].set(hz, std::min(life[k], v.damped ? t60 : 1e9), sr);
        }
    }
    void start(Voice& v, const Shared&) noexcept {
        v.hz = noteHz(clampd(v.pitch, 0, 127));
        v.damped = false;
        v.t60 = keyT60(v.pitch);
        for (Mode& m : v.mode) m.clear();
        setModes(v, v.t60);
        const double vel = v.velocity;
        // The strike: the displacement grows with velocity (harder strikes reach the pickup's bend); the bell more so.
        v.amp = static_cast<float>(0.25 + 1.1 * detPow(vel, 1.3));
        const float hit = v.amp;
        const float bellHit = static_cast<float>(bell * (0.3 + 0.9 * vel) * (kind == 0 ? 0.5 : 0.3));
        // A unit impulse rings a mode at about its own loudness (Mode: z <- p z + x).
        v.mode[0].zr = hit;
        v.mode[1].zr = hit * (kind == 0 ? 0.35f : 0.2f);
        v.mode[2].zr = hit * bellHit;
        v.mode[3].zr = hit * bellHit * static_cast<float>(0.6 * vel);
    }
    void release(Voice& v, const Shared& s) noexcept {
        v.damped = true;
        setModes(v, std::min(v.t60, s.release));
    }
    void voiceControl(Voice& v, const Shared& s) noexcept {
        const double hz = noteHz(clampd(v.pitch, 0, 127));
        if (std::fabs(hz - v.hz) > 1e-6 * hz) v.hz = hz, setModes(v, v.damped ? std::min(v.t60, s.release) : v.t60);
        for (Mode& m : v.mode) m.flush();
    }
    void render(Voice& v, float* out, uint32_t n) noexcept {
        F4 c, sn, zr, zi;
        for (int k = 0; k < 4; ++k) c[k] = v.mode[k].c, sn[k] = v.mode[k].s, zr[k] = v.mode[k].zr, zi[k] = v.mode[k].zi;
        for (uint32_t i = 0; i < n; ++i) {
            const F4 r = c * zr - sn * zi, im = sn * zr + c * zi;
            zr = r, zi = im;
            const float x = im[0] + im[1] + im[2] + im[3];
            float y;
            if (kind == 0) {
                const float u = x + sym;
                y = h2 * u / (h2 + u * u) - offset;
            } else {
                const float u = std::clamp(x, -1.5f, 1.5f);
                y = u - 0.15f * u * u * u + 0.25f * sym * u * u;
            }
            out[i] = softClip(y * drive) * norm * 0.45f;
        }
        for (int k = 0; k < 4; ++k) v.mode[k].zr = zr[k], v.mode[k].zi = zi[k];
    }
    void post(float* l, float* r, uint32_t n, const Shared&) noexcept {
        if (tremolo <= 0.0) return;
        const double inc = rate / sr;
        for (uint32_t i = 0; i < n; ++i) {
            const float lfo = static_cast<float>(lib::fastSinCycles(phase));
            phase += inc;
            if (phase >= 1.0) phase -= 1.0;
            if (kind == 0) {  // auto-pan
                const float d = static_cast<float>(tremolo) * lfo;
                l[i] *= 1.0f - std::max(0.0f, d), r[i] *= 1.0f + std::min(0.0f, d);
            } else {
                const float g = 1.0f - static_cast<float>(tremolo) * 0.5f * (1.0f + lfo);
                l[i] *= g, r[i] *= g;
            }
        }
    }
    bool postQuiet() const noexcept { return true; }
    void clearPost() noexcept { phase = 0; }
    void display(float* out) const noexcept {
        out[0] = static_cast<float>(kind);
        out[1] = static_cast<float>(phase);
        out[2] = static_cast<float>(tremolo);
    }
};

// ---------- Organ ----------

// A tonewheel organ. Each key sums nine drawbars at the footages 16', 5 1/3', 8', 4', 2 2/3', 2', 1 3/5', 1 1/3' and
// 1' (0.5, 1.5, 1, 2, 3, 4, 5, 6 and 8 times the key's pitch) read from one shared sine table; each wheel's phase is
// set from the instrument's clock when a key goes down, so two keys sharing a wheel are in phase, as one wheel
// feeding two contacts is. A wheel below 32.7 Hz folds up an octave, one above 5.9 kHz down (the wheel set's
// ends). Each drawbar step is 3 dB. A key click (a 3 ms filtered noise burst at contact and release, `click`).
// Percussion (single-triggered: only when no other key is held): the 2nd or 3rd harmonic, decaying fast (0.25 s)
// or slow (1 s), and while it is on the 1' drawbar is cut, as on the instrument. After the keys' sum: the scanner
// vibrato or chorus (a delay swept at 6.9 Hz, V1-V3 deeper each, C1-C3 mixed with the dry), a drive (a tanh) and
// the rotary speaker: org.caw.rotary's own class run inside (Slow, Fast, Brake; the mod wheel past half switches
// Slow to Fast), its horn/drum balance from `body`. Velocity does not change the level (an organ has none).
struct Organ {
    static constexpr uint32_t kEcoCap = 61, kNormalCap = 61, kHighCap = 61, kPool = kHighCap + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = false;
    static constexpr double kMinLife = 0.01, kSpread = 0.0;
    enum P : uint32_t { kDb16, kDb513, kDb8, kDb4, kDb223, kDb2, kDb135, kDb113, kDb1, kPerc, kPercFast, kVibrato,
                        kClick, kDrive, kRotary, kModelParams };

    struct Voice : VoiceBase {
        uint32_t phase[9] = {}, inc[9] = {};
        uint32_t percPhase = 0, percInc = 0;
        float gain = 0, step = 0;  // the key's contact: 1 ms in, 5 ms (or `release`) out
        float perc = 0, percFall = 1;
        uint32_t clickLeft = 0;
        Noise noise;
        Lp1 clickLp;
    };

    float bar[9] = {};
    int barIndex[9] = {}, bars = 0;
    int perc = 0, percFast = 1, vibrato = 0, rotary = 0;
    double click = 0.3, drive = 0.1, body = 0.5;
    double sr = 48000;
    int held = 0;
    Shared last;
    // The scanner's delay and the rotary.
    std::unique_ptr<float[]> vibMem;
    Line vib;
    double vibPhase = 0;
    std::unique_ptr<ModuleProcessor> rot;
    ParameterValue rotParams[7];
    bool rotOn = false;
    float monoBuf[kControlFrames] = {};

    size_t allocBytes() const noexcept {
        return (vib.mask + 1) * sizeof(float) + (rot ? 2 * 0.01 * sr * sizeof(double) + 4096 : 0);  // [Assumption] the rotary's two 10 ms lines
    }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 0.55, r.decay = 1.6, r.damping = 0.5, r.mix = 1.0, r.width = 1.0;
        return r;
    }
    bool prepare(double rate, Voice*, uint32_t) noexcept {
        sr = rate;
        const uint32_t size = pow2At(static_cast<uint32_t>(0.004 * sr) + 8);
        vibMem.reset(new (std::nothrow) float[size]());
        if (!vibMem) return false;
        vib.bind(vibMem.get(), size);
        rot.reset(fx::makeRotaryAs(fx::legacyRotaryDescriptor()));
        if (!rot || !rot->activate(sr, kControlFrames)) return false;
        for (int k = 0; k < 7; ++k) rotParams[k].value = fx::legacyRotaryDescriptor().parameters[k].defaultValue;
        (void)tables();
        return true;
    }
    void reset() noexcept {
        held = 0;
        clearPost();
    }
    void control(const double* p, const Shared& s) noexcept {
        bars = 0;
        perc = static_cast<int>(clampd(p[kPerc], 0, 2) + 0.5);
        for (int k = 0; k < 9; ++k) {
            const double db = clampd(p[kDb16 + k], 0, 8);
            float g = db < 0.5 ? 0.0f : static_cast<float>(detPow(10.0, -3.0 * (8.0 - db) / 20.0));
            if (k == 8 && perc != 0) g = 0;  // percussion takes the 1' bus
            bar[k] = g;
            if (g > 0) barIndex[bars++] = k;
        }
        percFast = static_cast<int>(clampd(p[kPercFast], 0, 1) + 0.5);
        vibrato = static_cast<int>(clampd(p[kVibrato], 0, 6) + 0.5);
        click = clampd(p[kClick], 0, 1);
        drive = clampd(p[kDrive], 0, 1);
        rotary = static_cast<int>(clampd(p[kRotary], 0, 3) + 0.5);
        body = s.body;
        last = s;
        int speed = rotary - 1;  // Slow 0, Fast 1, Brake 2
        if (speed == 0 && s.modWheel >= 0.5) speed = 1;
        rotParams[0].value = speed < 0 ? 0 : speed;
        rotParams[2].value = (s.body - 0.5) * 2.0;  // horn (-1) .. drum (+1)
        rotOn = rotary != 0;  // by hand only: Off bypasses it at once
    }
    static double wheelHz(double hz) noexcept {
        while (hz < 32.7) hz *= 2.0;
        while (hz > 5920.0) hz *= 0.5;
        return hz;
    }
    void start(Voice& v, const Shared& s) noexcept {
        static constexpr double kRatio[9] = {0.5, 1.5, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0};
        const double f = noteHz(clampd(v.pitch, 0, 127));
        for (int k = 0; k < 9; ++k) {
            const double hz = wheelHz(f * kRatio[k]);
            v.inc[k] = static_cast<uint32_t>(hz / sr * 4294967296.0);
            v.phase[k] = static_cast<uint32_t>(static_cast<uint64_t>(v.inc[k]) * s.clock);  // the wheel's own phase now
        }
        v.gain = 0;
        v.step = static_cast<float>(1.0 / std::max(1.0, 0.001 * sr));
        v.perc = 0;
        if (perc != 0 && held == 0) {  // single-triggered
            const double hz = wheelHz(f * (perc == 1 ? 2.0 : 3.0));
            v.percInc = static_cast<uint32_t>(hz / sr * 4294967296.0);
            v.percPhase = static_cast<uint32_t>(static_cast<uint64_t>(v.percInc) * s.clock);
            v.perc = 0.9f;
            v.percFall = static_cast<float>(detExp(-6.907755 / ((percFast ? 0.25 : 1.0) * sr)));
        }
        ++held;
        v.clickLeft = static_cast<uint32_t>(0.003 * sr);
        v.noise.s = 0x1234u + 77u * v.key;
        v.clickLp.set(3000.0 + 4000.0 * click, sr);
        v.clickLp.clear();
    }
    void release(Voice& v, const Shared& s) noexcept {
        held = std::max(0, held - 1);
        v.step = -static_cast<float>(1.0 / std::max(1.0, std::max(0.005, std::min(s.release, 2.0)) * sr));
        v.clickLeft = static_cast<uint32_t>(0.002 * sr);
    }
    void voiceControl(Voice& v, const Shared&) noexcept { v.clickLp.flush(); }
    void render(Voice& v, float* out, uint32_t n) noexcept {
        const float* sine = tables().sine;
        constexpr int kShift = 32 - 13;  // 8192 points
        const float clickAmp = static_cast<float>(0.08 * click);
        for (uint32_t i = 0; i < n; ++i) {
            float x = 0;
            for (int b = 0; b < bars; ++b) {
                const int k = barIndex[b];
                x += bar[k] * sine[v.phase[k] >> kShift];
            }
            for (int k = 0; k < 9; ++k) v.phase[k] += v.inc[k];  // every wheel turns, sounding or not
            if (v.perc > 1e-4f) {
                const uint32_t idx = v.percPhase >> kShift;
                x += v.perc * sine[idx];
                v.perc *= v.percFall;
            }
            v.percPhase += v.percInc;
            v.gain = std::clamp(v.gain + v.step, 0.0f, 1.0f);
            float y = x * v.gain * 0.16f;
            if (v.clickLeft) {
                --v.clickLeft;
                y += clickAmp * v.clickLp.run(v.noise.next());
            }
            out[i] = y;
        }
    }
    void post(float* l, float* r, uint32_t n, const Shared&) noexcept {
        // The keys' sum is mono (the spread is 0): the scanner, the drive, then the rotary.
        static constexpr double kDepth[7] = {0, 0.00015, 0.0003, 0.00055, 0.00015, 0.0003, 0.00055};
        const double depth = kDepth[vibrato] * sr;
        const bool chorus = vibrato >= 4;
        const float pre = static_cast<float>(1.0 + 8.0 * drive), post = 1.0f / std::sqrt(pre);
        for (uint32_t i = 0; i < n; ++i) {
            float x = l[i] * 1.41421356f;
            if (vibrato) {
                vib.push(x);
                const double d = 1.0 + depth * (1.0 + lib::fastSinCycles(vibPhase));
                vibPhase += 6.9 / sr;
                if (vibPhase >= 1.0) vibPhase -= 1.0;
                const float w = vib.frac(static_cast<float>(d));
                x = chorus ? 0.5f * (x + w) : w;
            }
            if (drive > 0) x = softClip(x * pre) * post;
            monoBuf[i] = x;
        }
        if (rotOn) {
            const float* in[2] = {monoBuf, monoBuf};
            float* out[2] = {l, r};
            AudioProcessBlock b;
            b.input = {in, 2, n};
            b.output = {out, 2, n};
            b.frames = n;
            b.sampleRate = sr;
            b.parameters = rotParams;
            b.parameterCount = 7;
            if (!rot->process(b)) std::copy(monoBuf, monoBuf + n, l), std::copy(monoBuf, monoBuf + n, r);
        } else {
            for (uint32_t i = 0; i < n; ++i) l[i] = r[i] = monoBuf[i] * 0.70710678f;
        }
    }
    bool postQuiet() const noexcept { return !rotOn || rot->quiet(); }
    void clearPost() noexcept {
        vib.clear();
        vibPhase = 0;
        if (rot) rot->reset();
        rotOn = rotary != 0;
    }
    void display(float* out) const noexcept {
        out[0] = static_cast<float>(rotParams[0].value);
        out[1] = static_cast<float>(held);
        out[2] = static_cast<float>(vibrato);
        out[3] = static_cast<float>(perc);
        float d[8] = {};
        if (rot && rot->readDisplay(d, 8) >= 6) {  // the rotary's horn and drum angles and speeds
            out[4] = d[2], out[5] = d[3], out[6] = d[4];
        }
    }
};

}  // namespace caw::timber
