// Timber's plucked strings (guitar, nylon, harp, koto: an extended Karplus-Strong loop and body resonances) and bowed strings (a bow-friction waveguide and a shared body) models.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <new>

#include "timber_core.h"

namespace caw::timber {

// A body: a few resonances added to the dry sound (`body` the amount), run once after the voices' sum, per side.
struct Body {
    static constexpr int kModes = 5;
    Biquad bp[2][kModes];
    float gain[kModes] = {};
    Biquad dc[2];
    int modes = 0;
    void set(const double* hz, const double* q, const double* db, int n, double scale, double sr) noexcept {
        modes = n;
        for (int k = 0; k < n; ++k) {
            for (int c = 0; c < 2; ++c) bp[c][k].band(hz[k] * scale, q[k], sr);
            gain[k] = static_cast<float>(detPow(10.0, db[k] / 20.0));
        }
        for (int c = 0; c < 2; ++c) dc[c].highpass(30.0, 0.7, sr);
    }
    void run(float* l, float* r, uint32_t n, float amount) noexcept {
        float* ch[2] = {l, r};
        for (int c = 0; c < 2; ++c)
            for (uint32_t i = 0; i < n; ++i) {
                const float x = dc[c].run(ch[c][i]);
                float y = 0;
                for (int k = 0; k < modes; ++k) y += gain[k] * bp[c][k].run(x);
                ch[c][i] = x + amount * y;
            }
    }
    void flush() noexcept {
        for (auto& side : bp)
            for (Biquad& b : side) b.flush();
        for (Biquad& b : dc) b.flush();
    }
    void clear() noexcept {
        for (auto& side : bp)
            for (Biquad& b : side) b.clear();
        for (Biquad& b : dc) b.clear();
    }
};

// ---------- Plucked strings ----------

// The extended Karplus-Strong string (Jaffe and Smith, CMJ 7(2), 1983): a delay loop with an exact first-order tuning
// allpass and a one-pole loss designed from two decay times (at the fundamental and, faster, at 4 kHz: `brightness`
// moves the second), plucked by one period of a shared noise burst minus itself a pluck position later (the comb
// that leaves out the partials with a node there), through a low-pass set by the pick's hardness and the velocity
// (a harder pluck is brighter: the dynamics filter). `damping` mutes the string (palm mute: shorter and darker).
// A released key damps it in `release`, except on the harp, whose strings ring on. The body (after the sum):
// the instrument's few low resonances (Helmholtz and top plate; the harp's soundbox, the koto's long body).
// [Assumption] the decay and body values are typical, chosen by ear, not measured.
struct Pluck {
    static constexpr uint32_t kEcoCap = 16, kNormalCap = 32, kHighCap = 32, kPool = kHighCap + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = true;
    static constexpr double kMinLife = 0.05, kSpread = 0.35;
    enum P : uint32_t { kInstrument, kPosition, kPick, kDamping, kBrightness, kDecay, kModelParams };

    struct Voice : VoiceBase {
        Line line;
        uint32_t D = 2;
        float eta = 0, x1 = 0, y1 = 0, b = 0, p = 0, z = 0;
        float bFree = 0, pFree = 0, bDamped = 0, pDamped = 0, damp = 0;
        uint32_t excLeft = 0, excAt = 0, comb = 0;
        float excGain = 0, hk = 1, h = 0;
        double tunedPitch = -1, tunedFor = -1;
    };

    int instrument = 0;
    double position = 0.2, pick = 0.5, damping = 0, brightness = 0.5, decay = 1;
    double sr = 48000;
    float bodyAmount = 0.5;
    int bodyFor = -1;
    uint32_t plucks = 0;
    std::unique_ptr<float[]> memory;
    uint32_t lineLen = 0;
    Voice* voices = nullptr;
    uint32_t count = 0;
    Body body;

    size_t allocBytes() const noexcept { return static_cast<size_t>(count) * lineLen * sizeof(float); }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 0.5, r.decay = 1.5, r.damping = 0.4, r.mix = 1.0, r.width = 1.0;
        return r;
    }
    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        sr = rate;
        voices = v, count = n;
        lineLen = pow2At(static_cast<uint32_t>(sr / 30.0) + 16);
        memory.reset(new (std::nothrow) float[static_cast<size_t>(n) * lineLen]());
        if (!memory) return false;
        bindAll();
        (void)tables();
        return true;
    }
    void bindAll() noexcept {
        for (uint32_t k = 0; k < count; ++k) voices[k].line.bind(memory.get() + static_cast<size_t>(k) * lineLen, lineLen);
    }
    void reset() noexcept {
        bindAll();
        plucks = 0;
        clearPost();
    }
    void control(const double* p, const Shared& s) noexcept {
        instrument = static_cast<int>(clampd(p[kInstrument], 0, 3) + 0.5);
        position = clampd(p[kPosition], 0.02, 0.5);
        pick = clampd(p[kPick], 0, 1);
        damping = clampd(p[kDamping], 0, 1);
        brightness = clampd(p[kBrightness], 0, 1);
        decay = clampd(p[kDecay], 0.25, 4);
        bodyAmount = static_cast<float>(s.body * 1.5);
        if (instrument != bodyFor) {
            static constexpr double kHz[4][4] = {{100, 205, 410, 2400}, {95, 190, 380, 1300}, {150, 300, 620, 1500}, {180, 450, 900, 3000}};
            static constexpr double kQ[4][4] = {{6, 8, 5, 1.5}, {6, 8, 5, 2}, {4, 6, 5, 2}, {5, 6, 4, 2}};
            static constexpr double kDb[4][4] = {{0, -3, -4, -9}, {0, -3, -5, -10}, {-2, -1, -5, -10}, {-3, -2, -3, -6}};
            body.set(kHz[instrument], kQ[instrument], kDb[instrument], 4, 1.0, sr);
            bodyFor = instrument;
        }
        body.flush();
    }
    double t60(double pitch) const noexcept {
        static constexpr double kT[4] = {6.0, 4.5, 8.0, 5.0};
        return clampd(kT[instrument] * detPow(2.0, -(pitch - 40.0) / 24.0), 0.3, 20.0) * decay;
    }
    void design(Voice& v) noexcept {
        const double pitch = clampd(v.pitch, 24.0, 115.0);
        const double f0 = noteHz(pitch);
        const double T = t60(pitch) * (1.0 - 0.85 * damping);
        const double ratio = (0.04 + 0.5 * brightness) * (1.0 - 0.8 * damping);
        const double fh = std::min(4000.0, 0.4 * sr);
        const double g0 = detPow(10.0, -3.0 / (T * f0)), gh = detPow(10.0, -3.0 / (T * ratio * f0));
        const double w0 = kTwoPi * f0 / sr;
        const double fhh = std::max(fh, 2.0 * f0);
        double p = onePoleForRatio(gh / g0, kTwoPi * std::min(fhh, 0.45 * sr) / sr);
        p = std::min(p, 0.95);
        v.pFree = static_cast<float>(p);
        v.bFree = static_cast<float>(std::min(0.99999 * (1.0 - p), g0 / onePoleMag(p, w0)));
        const double rest = std::max(2.5, sr / f0 - onePoleDelay(p, w0));
        uint32_t D = static_cast<uint32_t>(std::floor(rest - 0.5));
        D = std::min<uint32_t>(std::max<uint32_t>(D, 2), v.line.mask - 4);
        v.D = D;
        v.eta = static_cast<float>(allpassFor(clampd(rest - D, 0.3, 1.7), w0));
        v.tunedPitch = v.pitch;
    }
    void dampedLoss(Voice& v, double release) noexcept {
        const double f0 = noteHz(clampd(v.pitch, 24.0, 115.0));
        const double p = std::max<double>(v.pFree, 0.4);
        v.pDamped = static_cast<float>(p);
        v.bDamped = static_cast<float>(std::min(0.999 * (1.0 - p), detPow(10.0, -3.0 / (release * f0)) / onePoleMag(p, kTwoPi * f0 / sr)));
        v.tunedFor = release;
    }
    void start(Voice& v, const Shared& s) noexcept {
        design(v);
        dampedLoss(v, s.release);
        for (uint32_t d = 1; d <= v.D + 1; ++d) v.line.buf[(v.line.w - d) & v.line.mask] = 0.0f;
        v.x1 = v.y1 = v.z = v.h = 0;
        v.b = v.bFree, v.p = v.pFree, v.damp = 0;
        const uint32_t period = v.D + 1;
        v.excLeft = period;
        v.comb = static_cast<uint32_t>(position * period + 0.5);
        v.excAt = (hash32(++plucks * 2654435761u + v.key) % (Tables::kPluck - 2 * period - 4)) + period;
        const double vel = v.velocity;
        const double cutoff = clampd(300.0 + 9000.0 * pick * detPow(vel, 1.3) + 1500.0 * vel, 200.0, 0.45 * sr);
        v.hk = static_cast<float>(1.0 - detExp(-kTwoPi * cutoff / sr));
        v.excGain = static_cast<float>(0.15 + 0.85 * vel);
    }
    void release(Voice&, const Shared&) noexcept {}
    void voiceControl(Voice& v, const Shared& s) noexcept {
        if (std::fabs(v.pitch - v.tunedPitch) > 1e-4) design(v), v.tunedFor = -1;
        if (s.release != v.tunedFor) dampedLoss(v, s.release);
        const float target = (!v.held && instrument != 2) ? 1.0f : 0.0f;  // the harp rings on
        v.damp += (target - v.damp) * 0.3f;
        if (std::fabs(target - v.damp) < 1e-4f) v.damp = target;
        v.b = v.bFree + (v.bDamped - v.bFree) * v.damp;
        v.p = v.pFree + (v.pDamped - v.pFree) * v.damp;
        v.x1 = flushf(v.x1), v.y1 = flushf(v.y1), v.z = flushf(v.z), v.h = flushf(v.h);
    }
    void render(Voice& v, float* out, uint32_t n) noexcept {
        const float* noise = tables().pluck;
        for (uint32_t i = 0; i < n; ++i) {
            float e = 0;
            if (v.excLeft) {
                --v.excLeft;
                const float raw = noise[v.excAt] - noise[v.excAt - v.comb];
                ++v.excAt;
                v.h += v.hk * (raw - v.h);
                e = v.h * v.excGain;
            }
            const float x = v.line.at(v.D);
            const float t = v.eta * (x - v.y1) + v.x1;
            v.x1 = x, v.y1 = t;
            v.z = v.b * t + v.p * v.z;
            const float w = v.z + e;
            v.line.push(w);
            out[i] = w * 0.6f;
        }
    }
    void post(float* l, float* r, uint32_t n, const Shared&) noexcept { body.run(l, r, n, bodyAmount); }
    bool postQuiet() const noexcept { return true; }
    void clearPost() noexcept { body.clear(); }
    void display(float* out) const noexcept {
        out[0] = static_cast<float>(instrument);
        out[1] = static_cast<float>(position);
        out[2] = static_cast<float>(damping);
    }
};

// ---------- Bowed strings ----------

// A bowed string (after McIntyre, Schumacher and Woodhouse, JASA 74(5), 1983, in Smith's waveguide form): two delay
// lines meet at the bow, one to the nut and back (inverted there), one to the bridge and back (inverted through a
// one-pole loss there). At the bow the string's velocity (the two arriving waves) is compared with the bow's: the
// friction passes back (dv) r(dv), r = 1 / (1 + (k dv)^2)^2, near 1 while the string sticks and falling as it slips,
// k narrower the harder the bow presses. Original code; STK's Bowed model (MIT-like licence) was read for ideas only.
// The bow speed follows an envelope (`attack`, the shared `release`), the velocity, poly pressure and the mod
// wheel; vibrato (on the string's length) fades in after 0.25 s. The bridge's outgoing wave is the output, and the
// body (the section's few resonances and the bridge hill, after the voices' sum) is the same for every voice, so
// it runs once, not per voice. [Assumption] body frequencies are typical values for each instrument, not measured.
struct Bowed {
    static constexpr uint32_t kEcoCap = 8, kNormalCap = 8, kHighCap = 8, kPool = 16 + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = false;
    static constexpr double kMinLife = 0.05, kSpread = 0.3;
    enum P : uint32_t { kSection, kPressure, kSpeed, kPosition, kVibrato, kVibRate, kAttack, kModelParams };

    struct Voice : VoiceBase {
        Line neck, bridge;
        float dn = 2, db = 2;
        float lp = 0, dc = 0;
        float bow = 0, bowStep = 0, vibAmount = 0;
        double vib = 0;
        uint32_t age = 0;
    };

    int section = 0;
    double pressure = 0.5, speed = 0.5, position = 0.12, vibrato = 0.3, vibRate = 5.5, attack = 0.12;
    double sr = 48000, modWheel = 0;
    float bodyAmount = 0.5;
    int bodyFor = -1;
    std::unique_ptr<float[]> memory;
    uint32_t lineLen = 0, count = 0;
    Voice* voices = nullptr;
    Body body;

    size_t allocBytes() const noexcept { return static_cast<size_t>(count) * 2 * lineLen * sizeof(float); }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 0.7, r.decay = 2.0, r.damping = 0.5, r.mix = 1.0, r.width = 1.0, r.preDelay = 0.015;
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
            voices[k].neck.bind(memory.get() + static_cast<size_t>(2 * k) * lineLen, lineLen);
            voices[k].bridge.bind(memory.get() + static_cast<size_t>(2 * k + 1) * lineLen, lineLen);
        }
    }
    void reset() noexcept {
        bindAll();
        clearPost();
    }
    void control(const double* p, const Shared& s) noexcept {
        section = static_cast<int>(clampd(p[kSection], 0, 3) + 0.5);
        pressure = clampd(p[kPressure], 0, 1);
        speed = clampd(p[kSpeed], 0, 1);
        position = clampd(p[kPosition], 0.03, 0.3);
        vibrato = clampd(p[kVibrato], 0, 1);
        vibRate = clampd(p[kVibRate], 2, 9);
        attack = clampd(p[kAttack], 0.005, 2);
        modWheel = s.modWheel;
        bodyAmount = static_cast<float>(s.body * 1.6);
        if (section != bodyFor) {
            static constexpr double kHz[5] = {275, 460, 550, 1100, 2600};
            static constexpr double kQ[5] = {10, 12, 12, 6, 1.4};
            static constexpr double kDb[5] = {0, -2, -1, -6, -3};
            static constexpr double kScale[4] = {1.0, 0.78, 0.42, 0.26};
            body.set(kHz, kQ, kDb, 5, kScale[section], sr);
            bodyFor = section;
        }
        body.flush();
    }
    void start(Voice& v, const Shared&) noexcept {
        v.neck.clear();
        v.bridge.clear();
        v.lp = v.dc = 0;
        v.bow = 0;
        v.bowStep = static_cast<float>(1.0 / std::max(1.0, attack * sr));
        v.vib = 0;
        v.vibAmount = 0;
        v.age = 0;
        tune(v, 0.0);
    }
    void tune(Voice& v, double cents) noexcept {
        const double f0 = noteHz(clampd(v.pitch, 24.0, 108.0) + cents / 100.0);
        const double period = sr / f0 - 1.2;  // less the bridge filter's and the reads' own delay
        v.db = static_cast<float>(std::max(2.0, period * position));
        v.dn = static_cast<float>(std::max(2.0, period - v.db));
        const float cap = static_cast<float>(v.neck.mask - 4);
        v.dn = std::min(v.dn, cap), v.db = std::min(v.db, cap);
    }
    void release(Voice& v, const Shared& s) noexcept {
        v.bowStep = -static_cast<float>(1.0 / std::max(1.0, std::max(0.01, s.release) * sr));
    }
    void voiceControl(Voice& v, const Shared&) noexcept {
        // Vibrato on the length, fading in after a quarter second; recomputed per control block (cheap).
        const double dt = kControlFrames / sr;
        v.age += kControlFrames;
        if (v.age > 0.25 * sr) v.vibAmount = std::min(1.0f, v.vibAmount + static_cast<float>(dt / 0.4));
        v.vib += vibRate * dt;
        v.vib -= std::floor(v.vib);
        tune(v, 25.0 * vibrato * v.vibAmount * lib::fastSinCycles(v.vib));
        v.lp = flushf(v.lp), v.dc = flushf(v.dc);
    }
    void render(Voice& v, float* out, uint32_t n) noexcept {
        const float expr = static_cast<float>(std::max(v.pressure, modWheel));
        const float target = static_cast<float>((0.05 + 0.25 * speed) * (0.45 + 0.55 * v.velocity)) * (1.0f + 0.8f * expr);
        const float kk = static_cast<float>(1.5 + 6.0 * (1.0 - pressure));
        const float lpk = static_cast<float>(1.0 - detExp(-kTwoPi * (section >= 2 ? 2500.0 : 4000.0) / sr));  // the bridge's loss
        const float dck = static_cast<float>(kTwoPi * 20.0 / sr);
        for (uint32_t i = 0; i < n; ++i) {
            v.bow = std::clamp(v.bow + v.bowStep, 0.0f, 1.0f);
            const float vb = v.bow * target;
            const float nb = v.neck.frac(v.dn), bb = v.bridge.frac(v.db);
            const float dv = vb - (nb + bb);
            const float q = 1.0f + kk * kk * dv * dv;
            const float f = dv / (q * q);
            v.neck.push(-(bb + f));
            const float toBridge = nb + f;
            v.lp += lpk * (toBridge - v.lp);
            v.bridge.push(-0.97f * v.lp);
            v.dc += dck * (toBridge - v.dc);  // the bow's DC is no sound: it would keep a silent voice alive
            out[i] = (toBridge - v.dc) * 0.45f;
        }
    }
    void post(float* l, float* r, uint32_t n, const Shared&) noexcept { body.run(l, r, n, bodyAmount); }
    bool postQuiet() const noexcept { return true; }
    void clearPost() noexcept { body.clear(); }
    void display(float* out) const noexcept {
        out[0] = static_cast<float>(section);
        out[1] = static_cast<float>(pressure);
        out[2] = static_cast<float>(speed);
    }
};

}  // namespace caw::timber
