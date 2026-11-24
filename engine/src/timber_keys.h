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
#include "timber_sim.h"

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
    enum P : uint32_t { kKind, kPickup, kSymmetry, kBell, kBark, kTremolo, kRate, kDecay, kSim, kNoises, kModelParams };

    struct Voice : VoiceBase {
        Mode mode[4];  // set() works out each; render() runs the four as one SIMD complex one-pole
        float amp = 1;
        double hz = 0, t60 = 1, tunedPitch = -1;
        bool damped = false;
        // 1.1.2 Simulated: the hammer's contact and each mode's force input and shape at the strike point; the
        // action's thunk (a low, short body resonance) and the damper felt's touch, heard acoustically.
        Contact contact;
        F4 phi, place;
        Mode thunk;
        uint32_t feltLeft = 0, thunkLeft = 0;
        float feltAmp = 0, thunkKick = 0;
        Lp1 felt;
        Noise noise;
    };

    int kind = 0;
    double pickup = 0.5, symmetry = 0.2, bell = 0.5, bark = 0.2, tremolo = 0, rate = 4, decay = 1;
    bool sim = false, contactOn = true;
    double noises = kNoisesDefault;
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
    void control(const double* p, const Shared& s) noexcept {
        kind = static_cast<int>(clampd(p[kKind], 0, 1) + 0.5);
        pickup = clampd(p[kPickup], 0, 1);
        symmetry = clampd(p[kSymmetry], -1, 1);
        bell = clampd(p[kBell], 0, 1);
        bark = clampd(p[kBark], 0, 1);
        tremolo = clampd(p[kTremolo], 0, 1);
        rate = clampd(p[kRate], 0.5, 12);
        decay = clampd(p[kDecay], 0.25, 4);
        sim = p[kSim] >= 0.5;
        noises = clampd(p[kNoises], 0, 1);
        contactOn = s.quality != kQualityEco;  // Eco: 1.1.0's strike, with the thunk and the felt
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
        v.tunedPitch = v.pitch;
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
        v.contact.done = true;
        if (sim) startSim(v);
    }
    // 1.1.2 Simulated: the tine (or reed) is struck by its neoprene hammer tip through a Hunt-Crossley contact (as
    // the mallets: Hunt and Crossley 1975), about 1.2 ms on a tine and 0.8 ms on a steel reed at a medium blow and
    // shorter the harder; each mode feels the force through its shape at the strike point (the tonebar only
    // through its coupling; the cantilever's 2nd and 3rd modes by `bell`, how near the tip the hammer meets the
    // tine). So a hard blow excites the bell modes and drives the tine into the pickup's bend by itself. The
    // action's thunk (the key and hammer bottoming: a short body resonance near 110 Hz) and the damper felt landing
    // on a released key (as loud as the tine still is) are heard acoustically, not through the pickup (`noises`).
    // [Assumption] the contact times, the thunk's pitch and the levels are fitted by ear, not measured.
    void startSim(Voice& v) noexcept {
        static constexpr double kRatio[2][4] = {{1.0, 1.0007, 6.267, 17.55}, {1.0, 0.9993, 6.27, 17.6}};
        const double placeK[4] = {1.0, 0.3, 0.3 + 0.7 * bell, 0.2 + 0.6 * bell};
        if (contactOn) {
            for (int k = 0; k < 4; ++k) {
                v.mode[k].zr = v.mode[k].zi = 0;
                const bool on = v.hz * kRatio[kind][k] < 0.45 * sr;
                v.place[k] = static_cast<float>(on ? placeK[k] : 0.0);
                v.phi[k] = static_cast<float>(on ? kSimGain * placeK[k] / (kTwoPi * v.hz * kRatio[kind][k]) / sr : 0.0);
            }
            const double v0 = 0.2 + 1.8 * v.velocity;
            v.contact.strike(static_cast<float>(v0), kind == 0 ? 0.0016 : 0.001, 0.3 / v0, sr);
        }
        v.thunk.set(110.0, 0.03, sr);
        v.thunk.clear();
        v.thunkKick = static_cast<float>(0.05 * noises * (0.3 + 0.7 * v.velocity));
        v.thunkLeft = noises > 0.0 ? static_cast<uint32_t>(0.12 * sr) : 0;  // 4 T60s of the 30 ms thunk
        v.feltLeft = 0;
        v.felt.set(500.0, sr);
        v.felt.clear();
        v.noise.s = 0xE11Au + 7u * v.key;
    }
    void release(Voice& v, const Shared& s) noexcept {
        v.damped = true;
        setModes(v, std::min(v.t60, s.release));
        if (sim) {
            v.feltLeft = static_cast<uint32_t>(0.015 * sr);
            v.feltAmp = static_cast<float>(0.06 * noises) * std::min(1.0f, v.level);
        }
    }
    void voiceControl(Voice& v, const Shared& s) noexcept {
        if (v.pitch != v.tunedPitch) {  // a bend or a glide
            v.tunedPitch = v.pitch;
            v.hz = noteHz(clampd(v.pitch, 0, 127));
            setModes(v, v.damped ? std::min(v.t60, s.release) : v.t60);
        }
        for (Mode& m : v.mode) m.flush();
        if (sim) v.thunk.flush(), v.felt.flush();
    }
    static constexpr double kSimGain = 4000.0;  // the modes' displacement to the 1.1.0 strike's (measured)
    float pickupOf(float x) const noexcept {
        float y;
        if (kind == 0) {
            const float u = x + sym;
            y = h2 * u / (h2 + u * u) - offset;
        } else {
            const float u = std::clamp(x, -1.5f, 1.5f);
            y = u - 0.15f * u * u * u + 0.25f * sym * u * u;
        }
        return softClip(y * drive) * norm * 0.45f;
    }
    CAW_TIMBER_NOINLINE void renderSim(Voice& v, float* out, uint32_t n) noexcept {
        F4 c, sn, zr, zi;
        for (int k = 0; k < 4; ++k) c[k] = v.mode[k].c, sn[k] = v.mode[k].s, zr[k] = v.mode[k].zr, zi[k] = v.mode[k].zi;
        const float invGain = static_cast<float>(1.0 / kSimGain);
        uint32_t i = 0;
        for (; i < n && !v.contact.done; ++i) {  // the hammer touching
            const F4 d = v.place * zi;
            const float f = v.contact.step((d[0] + d[1] + d[2] + d[3]) * invGain);
            zr = zr + v.phi * f4(f);
            const F4 r = c * zr - sn * zi, im = sn * zr + c * zi;
            zr = r, zi = im;
            out[i] = pickupOf(im[0] + im[1] + im[2] + im[3]);
        }
        for (; i < n; ++i) {
            const F4 r = c * zr - sn * zi, im = sn * zr + c * zi;
            zr = r, zi = im;
            out[i] = pickupOf(im[0] + im[1] + im[2] + im[3]);
        }
        for (int k = 0; k < 4; ++k) v.mode[k].zr = zr[k], v.mode[k].zi = zi[k];
        // The acoustic noises, while they sound.
        if (v.thunkLeft) {
            const uint32_t m = std::min(n, v.thunkLeft);
            for (uint32_t j = 0; j < m; ++j) out[j] += v.thunk.run(v.thunkKick), v.thunkKick = 0;
            v.thunkLeft -= m;
        }
        if (v.feltLeft) {
            const uint32_t m = std::min(n, v.feltLeft);
            for (uint32_t j = 0; j < m; ++j) out[j] += v.feltAmp * v.felt.run(v.noise.next());
            v.feltLeft -= m;
        }
    }
    void render(Voice& v, float* out, uint32_t n) noexcept {
        if (sim) {
            renderSim(v, out, n);
            return;
        }
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
                        kClick, kDrive, kRotary, kSim, kModelParams };

    struct Voice : VoiceBase {
        uint32_t phase[9] = {}, inc[9] = {};
        uint32_t percPhase = 0, percInc = 0;
        float gain = 0, step = 0;  // the key's contact: 1 ms in, 5 ms (or `release`) out
        float perc = 0, percFall = 1;
        uint32_t clickLeft = 0;
        Noise noise;
        Lp1 clickLp;
        // 1.1.2 Simulated: the key's nine contacts against their busbars. Each closes (at key down) or opens (at key
        // up) at its own moment and bounces once; `contact` counts samples since the key moved.
        uint16_t closeAt[9] = {}, bounceAt[9] = {}, bounceLen[9] = {};
        uint32_t contact = 0;
        bool opening = false;
    };

    float bar[9] = {};
    bool sim = false;
    uint32_t window = 0;  // samples the contacts take to settle
    float ramp = 1;       // a contact's make, in samples (a worn contact is softer: `click` 0)
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
        sim = p[kSim] >= 0.5;
        ramp = static_cast<float>(1.0 + (1.0 - click) * 0.0015 * sr);
        window = static_cast<uint32_t>(0.006 * sr);
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
        if (sim) contacts(v, false);
    }
    // 1.1.2 Simulated: a key's nine contacts (one per drawbar's busbar) do not touch at once: each closes at its own
    // moment within about 3 ms (a seeded spread per key: the same key always sounds the same) and bounces once,
    // and a contact switches the wheel's signal on wherever the wheel is: the key click is that step in nine sines
    // at unrelated phases (the 1.1.0 noise burst is not used). Key up opens them the same way. `click` is the
    // contacts' hardness: 1 switches in a sample, 0 makes over 1.5 ms (a soft click). [Assumption] nine contacts,
    // as widely described for the tonewheel organ, not checked against a service manual; the spread and bounce are
    // fitted by ear.
    void contacts(Voice& v, bool opening) noexcept {
        uint32_t h = hash32(0xC0A7u + 977u * v.key + (opening ? 0x51u : 0u));
        const double spread = 0.003 * sr;
        for (int k = 0; k < 9; ++k) {
            h = hash32(h + static_cast<uint32_t>(k));
            v.closeAt[k] = static_cast<uint16_t>((h & 0xFFFF) / 65535.0 * spread);
            v.bounceAt[k] = static_cast<uint16_t>(v.closeAt[k] + 1 + ((h >> 16) & 0xFF) / 255.0 * 0.0004 * sr);
            v.bounceLen[k] = static_cast<uint16_t>(1 + ((h >> 24) & 0xFF) / 255.0 * 0.0003 * sr);
        }
        v.contact = 0;
        v.opening = opening;
        v.gain = 1, v.step = 0;  // the contacts are the attack
        v.clickLeft = 0;
    }
    void release(Voice& v, const Shared& s) noexcept {
        held = std::max(0, held - 1);
        v.step = -static_cast<float>(1.0 / std::max(1.0, std::max(0.005, std::min(s.release, 2.0)) * sr));
        v.clickLeft = static_cast<uint32_t>(0.002 * sr);
        if (sim) {
            contacts(v, true);
            v.step = s.release > 0.02 ? -static_cast<float>(1.0 / (std::min(s.release, 2.0) * sr)) : 0.0f;
            v.gain = 1;
        }
    }
    void voiceControl(Voice& v, const Shared&) noexcept { v.clickLp.flush(); }
    void render(Voice& v, float* out, uint32_t n) noexcept {
        if (sim) {
            renderSim(v, out, n);
            return;
        }
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
    // While the contacts settle each drawbar has its own gate; after, the 1.1.0 loop (no per-sample gates).
    CAW_TIMBER_NOINLINE void renderSim(Voice& v, float* out, uint32_t n) noexcept {
        const float* sine = tables().sine;
        constexpr int kShift = 32 - 13;
        const float invRamp = 1.0f / ramp;
        for (uint32_t i = 0; i < n; ++i) {
            float x = 0;
            if (v.contact < window) {
                const float t = static_cast<float>(v.contact);
                for (int b = 0; b < bars; ++b) {
                    const int k = barIndex[b];
                    float g = std::clamp((t - v.closeAt[k]) * invRamp, 0.0f, 1.0f);
                    if (v.contact >= v.bounceAt[k] && v.contact < static_cast<uint32_t>(v.bounceAt[k] + v.bounceLen[k])) g = 0;
                    x += (v.opening ? 1.0f - g : g) * bar[k] * sine[v.phase[k] >> kShift];
                }
                ++v.contact;
            } else if (!v.opening) {
                for (int b = 0; b < bars; ++b) {
                    const int k = barIndex[b];
                    x += bar[k] * sine[v.phase[k] >> kShift];
                }
            }
            for (int k = 0; k < 9; ++k) v.phase[k] += v.inc[k];
            if (v.perc > 1e-4f) {
                x += v.perc * sine[v.percPhase >> kShift];
                v.perc *= v.percFall;
            }
            v.percPhase += v.percInc;
            v.gain = std::clamp(v.gain + v.step, 0.0f, 1.0f);
            out[i] = x * v.gain * 0.16f;
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
