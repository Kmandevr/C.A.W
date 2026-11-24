// Timber's plucked strings (guitar, nylon, harp, koto: an extended Karplus-Strong loop and body resonances) and bowed strings (a bow-friction waveguide and a shared body) models.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <new>

#include "caw/library/fastmath.hpp"
#include "timber_core.h"
#include "timber_sim.h"

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
    enum P : uint32_t { kInstrument, kPosition, kPick, kDamping, kBrightness, kDecay, kSim, kNoises, kModelParams };

    struct Voice : VoiceBase {
        Line line;
        uint32_t D = 2;
        float eta = 0, x1 = 0, y1 = 0, b = 0, p = 0, z = 0;
        float bFree = 0, pFree = 0, bDamped = 0, pDamped = 0, damp = 0;
        uint32_t excLeft = 0, excAt = 0, comb = 0;
        float excGain = 0, hk = 1, h = 0;
        double tunedPitch = -1, tunedFor = -1;
        // 1.1.2 Simulated: the pluck's shape (position along the period), the fret's gap (0: no fret buzz), the
        // finger's slide along a wound string (its windings' pulse phase and rate, level and ramp, the longitudinal
        // mode it rings), the finger's damping touch at release and the scrape noise.
        uint32_t shapeAt = 0, shapeLen = 1, touchLeft = 0;
        float gap = 0, slidePhase = 0, slideInc = 0, slideAmp = 0, slideStep = 0, touchAmp = 0, slideHz = 0;
        double slideFrom = -1;
        bool wound = false;
        Biquad longitudinal;
        Lp1 touchLp;
        Noise noise;
    };

    int instrument = 0;
    double position = 0.2, pick = 0.5, damping = 0, brightness = 0.5, decay = 1;
    double sr = 48000;
    bool sim = false, buzz = true;
    double noises = kNoisesDefault;
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
        sim = p[kSim] >= 0.5;
        noises = clampd(p[kNoises], 0, 1);
        buzz = s.quality != kQualityEco;  // Eco: no fret buzz
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
        // The excitation's span, kept inside the pluck table: at 192 kHz a low note's period is longer than a third of
        // it (equal to the period at 48 kHz, so the sound there is unchanged).
        const uint32_t period = std::min<uint32_t>(v.D + 1, (Tables::kPluck - 8) / 3);
        v.excLeft = period;
        v.comb = static_cast<uint32_t>(position * period + 0.5);
        v.excAt = (hash32(++plucks * 2654435761u + v.key) % (Tables::kPluck - 2 * period - 4)) + period;
        const double vel = v.velocity;
        const double cutoff = clampd(300.0 + 9000.0 * pick * detPow(vel, 1.3) + 1500.0 * vel, 200.0, 0.45 * sr);
        v.hk = static_cast<float>(1.0 - detExp(-kTwoPi * cutoff / sr));
        v.excGain = static_cast<float>(0.15 + 0.85 * vel);
        if (sim) startSim(v);
    }
    // 1.1.2 Simulated: the string is let go from the shape the pick or finger held it in (a triangle with its corner
    // at `position`: the loop holds the round trip, the shape and then its inverted mirror, so the position's
    // missing partials come from the shape itself), through the contact's low-pass (the pick's hardness: a finger
    // lets go over longer); a scrape noise as it leaves (`noises`). Fret buzz (guitars, Normal and High): the string
    // collides with the frets below it once its swing passes their gap (Evangelista and Eckerholm, IEEE TASLP 18(4),
    // 2010, a string-fret collision in a waveguide): inelastic, so a hard pluck buzzes until it has decayed under
    // the gap. Handling noise (Pakarinen, Penttinen and Bank, JASA 122(6), EL197, 2007): a finger sliding on a wound
    // string (a pitch bend or glide) crosses its windings, a pulse train whose rate and RMS level rise linearly
    // with the sliding speed, ringing the string's longitudinal mode. A released string is stopped by a finger:
    // its touch noise is as loud as the string still is.
    void startSim(Voice& v) noexcept {
        v.shapeAt = 0, v.shapeLen = std::max<uint32_t>(4, v.excLeft);
        const bool guitar = instrument <= 1;
        // The action's gap in loop units: a hard pluck of a low string reaches it (fitted by ear [Assumption]).
        v.gap = guitar && buzz ? static_cast<float>((instrument == 0 ? 0.26 : 0.32) * (1.0 + 0.012 * (v.pitch - 40.0))) : 0.0f;
        v.wound = guitar && v.pitch < (instrument == 0 ? 55.0 : 50.0);
        v.slideFrom = v.pitch, v.slidePhase = 0, v.slideInc = 0, v.slideAmp = 0, v.slideStep = 0;
        // The longitudinal mode of a guitar string: about 13x the transverse fundamental of the open string (Bank and
        // Sujbert's measurements put it at 1-3 kHz for wound strings) [Assumption: a fixed ratio].
        v.slideHz = static_cast<float>(clampd(13.0 * noteHz(clampd(v.pitch, 24, 115)), 600.0, 0.4 * sr));
        v.longitudinal.band(v.slideHz, 6.0, sr);
        v.longitudinal.clear();
        v.touchLeft = 0, v.touchAmp = 0;
        v.touchLp.set(900.0, sr);
        v.touchLp.clear();
        v.noise.s = 0x5EEDu + 131u * v.key + plucks;
    }
    void release(Voice& v, const Shared&) noexcept {
        if (!sim || instrument == 2) return;  // the harp rings on
        v.touchLeft = static_cast<uint32_t>(0.012 * sr);
        v.touchAmp = static_cast<float>(0.25 * noises) * std::min(1.0f, v.level);
    }
    void voiceControl(Voice& v, const Shared& s) noexcept {
        if (std::fabs(v.pitch - v.tunedPitch) > 1e-4) design(v), v.tunedFor = -1;
        if (s.release != v.tunedFor) dampedLoss(v, s.release);
        const float target = (!v.held && instrument != 2) ? 1.0f : 0.0f;  // the harp rings on
        v.damp += (target - v.damp) * 0.3f;
        if (std::fabs(target - v.damp) < 1e-4f) v.damp = target;
        v.b = v.bFree + (v.bDamped - v.bFree) * v.damp;
        v.p = v.pFree + (v.pDamped - v.pFree) * v.damp;
        v.x1 = flushf(v.x1), v.y1 = flushf(v.y1), v.z = flushf(v.z), v.h = flushf(v.h);
        if (sim) {
            // The finger's slide over this control block: its speed along a 0.65 m scale (the fret position of a
            // pitch above the open string is L (1 - 2^-st/12)), only on a wound string.
            const double dt = kControlFrames / sr;
            const double from = 0.65 * (1.0 - detPow(2.0, -(v.slideFrom - 40.0) / 12.0));
            const double to = 0.65 * (1.0 - detPow(2.0, -(v.pitch - 40.0) / 12.0));
            const double speed = v.wound ? std::fabs(to - from) / dt : 0.0;  // m/s
            v.slideFrom = v.pitch;
            // Windings about 0.8 mm apart [Assumption: a typical wound string]: the pulse rate is speed / pitch.
            v.slideInc = static_cast<float>(std::min(0.45, speed / 0.0008 / sr));
            // The pulses' size as the square root of the speed: with their rate also rising with it, the RMS
            // level then rises linearly with the speed, as measured.
            const float target = static_cast<float>(std::sqrt(std::min(1.0, speed / 0.4)) * 0.5 * noises);
            v.slideStep = (target - v.slideAmp) / kControlFrames;
            v.longitudinal.flush();
            v.touchLp.flush();
        }
    }
    void render(Voice& v, float* out, uint32_t n) noexcept {
        if (sim) {
            renderSim(v, out, n);
            return;
        }
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
    CAW_TIMBER_NOINLINE void renderSim(Voice& v, float* out, uint32_t n) noexcept {
        const float scrape = static_cast<float>(0.04 * noises);
        const float beta = static_cast<float>(clampd(position, 0.02, 0.5));
        for (uint32_t i = 0; i < n; ++i) {
            float e = 0;
            if (v.excLeft) {
                --v.excLeft;
                // The shape at this point of the round trip: the triangle out, then its inverted mirror back.
                const float u = 2.0f * static_cast<float>(v.shapeAt++) / static_cast<float>(v.shapeLen);
                const float x = u < 1.0f ? u : 2.0f - u;
                const float tri = x < beta ? x / beta : (1.0f - x) / (1.0f - beta);
                const float raw = (u < 1.0f ? tri : -tri) * 0.45f + scrape * v.noise.next();
                v.h += v.hk * (raw - v.h);
                e = v.h * v.excGain;
            }
            const float x = v.line.at(v.D);
            const float t = v.eta * (x - v.y1) + v.x1;
            v.x1 = x, v.y1 = t;
            v.z = v.b * t + v.p * v.z;
            float w = v.z + e;
            if (w < -v.gap && v.gap > 0.0f) w = -v.gap - 0.7f * (w + v.gap);  // the fret: the string bounces off it, losing some
            v.line.push(w);
            out[i] = w * 0.6f;
        }
        // The slide's windings and the finger's touch, only while they sound.
        if (v.slideAmp > 0.0f || v.slideStep != 0.0f) {
            for (uint32_t i = 0; i < n; ++i) {
                v.slideAmp = std::max(0.0f, v.slideAmp + v.slideStep);
                v.slidePhase += v.slideInc;
                float pulse = 0;
                if (v.slidePhase >= 1.0f) v.slidePhase -= 1.0f, pulse = 1.0f;
                out[i] += v.longitudinal.run(v.slideAmp * (pulse + 0.15f * v.noise.next()));
            }
            if (v.slideAmp < 1e-6f && v.slideStep <= 0.0f) v.slideAmp = 0, v.slideStep = 0;
        }
        if (v.touchLeft) {
            const uint32_t m = std::min(n, v.touchLeft);
            for (uint32_t i = 0; i < m; ++i) out[i] += v.touchAmp * v.touchLp.run(v.noise.next());
            v.touchLeft -= m;
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
    enum P : uint32_t { kSection, kPressure, kSpeed, kPosition, kVibrato, kVibRate, kAttack, kSim, kNoises, kModelParams };

    struct Voice : VoiceBase {
        Line neck, bridge;
        float dn = 2, db = 2;
        float lp = 0, dc = 0;
        float bow = 0, bowStep = 0, vibAmount = 0;
        double vib = 0, tunedPitch = -1, baseHz = 440;
        uint32_t age = 0;
        // 1.1.2 Simulated: the bristles' mean deflection z and its rate, and (for tests) the samples sliding / all.
        float z = 0, zd = 0, zt = 0, invZss = 1e9f;  // zt: z advanced by half the last rate; 1 / zss at the last sliding speed
        bool lifted = false;
        uint32_t sliding = 0, counted = 0;
        Noise noise;
    };

    int section = 0;
    double pressure = 0.5, speed = 0.5, position = 0.12, vibrato = 0.3, vibRate = 5.5, attack = 0.12;
    bool sim = false, simEco = false;
    int iterations = 2;
    double noises = kNoisesDefault;
    // The elasto-plastic bow (normalised to the waves' units): stiffness per second, the bristles' damping,
    // the static and dynamic friction coefficients, the Stribeck velocity and the breakaway share of zss.
    float sigma0 = 4800.0f, sigma1 = 0.3f, muS = 0.45f, muD = 0.2f, vStribeck = 0.1f, breakaway = 0.7f, forceScale = 12.0f;
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
        sim = p[kSim] >= 0.5;
        noises = clampd(p[kNoises], 0, 1);
        iterations = s.quality == kQualityHigh ? 2 : 1;
        simEco = s.quality == kQualityEco;
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
        v.tunedPitch = -1;
        v.z = v.zd = v.zt = 0;
        v.invZss = 1e9f;
        v.lifted = false;
        v.sliding = v.counted = 0;
        v.noise.s = 0xB0A1u + 17u * v.key;
        tune(v, 0.0);
    }
    void tune(Voice& v, double cents) noexcept {
        if (v.pitch != v.tunedPitch) v.tunedPitch = v.pitch, v.baseHz = noteHz(clampd(v.pitch, 24.0, 108.0));
        // Simulated: the elasto-plastic bow flattens the note a little (more the harder it presses, as a real bow);
        // aimed off by its measured pull at the default force.
        static constexpr double kSimPull[4] = {14, 9, 10, 8};
        if (sim) cents += kSimPull[section];
        const double f0 = v.baseHz * lib::fastExp(cents * 5.776226504666211e-4);  // ln 2 / 1200
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
        v.lp = flushf(v.lp), v.dc = flushf(v.dc), v.z = flushf(v.z), v.zd = flushf(v.zd), v.zt = flushf(v.zt);
        v.lifted = sim && v.bowStep < 0.0f && v.bow <= 0.0f;
    }
    void render(Voice& v, float* out, uint32_t n) noexcept {
        if (sim) {
            renderSim(v, out, n);
            return;
        }
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
    // 1.1.2 Simulated: the bow's friction as elasto-plastic (Dupont, Hayward, Armstrong and Altpeter, IEEE TAC 47(5),
    // 2002; for bowing Serafin, Avanzini and Rocchesso, SMAC 2003): the rosin's bristles deflect by z, z' = v (1 -
    // alpha(v, z) z / zss(v)), the force sigma0 z + sigma1 z', zss from the Stribeck curve (fc + (fs - fc)
    // e^-(v/vs)^2) / sigma0 with fs = muS Fn and fc = muD Fn (muS about 0.45, muD 0.2: the paper's rosin values),
    // Fn from `pressure`. The bristles' rate at each sample solves the delay-free loop by Newton's method (the
    // paper's 7 iterations converge in 2 here from the last sample's: Normal 2, High 3), with z by the trapezoid
    // rule. So the stick phase is elastic (the paper's micro-oscillations), the release a breakaway, and Schelleng's
    // window (JASA 53(1), 1973) emerges: too little force for the bow speed and position and the string slips more
    // than once a period (surface sound), too much and it is raucous. Bow noise (Chafe's pulsed noise, ICMC 1990):
    // a noise in the force while it slides, as the sliding speed (`noises`). Eco: 1.1.0's friction table and the
    // bow noise.
    CAW_TIMBER_NOINLINE void renderSim(Voice& v, float* out, uint32_t n) noexcept {
        const float expr = static_cast<float>(std::max(v.pressure, modWheel));
        const float target = static_cast<float>((0.05 + 0.25 * speed) * (0.45 + 0.55 * v.velocity)) * (1.0f + 0.8f * expr);
        const float kk = static_cast<float>(1.5 + 6.0 * (1.0 - pressure));
        const float lpk = static_cast<float>(1.0 - detExp(-kTwoPi * (section >= 2 ? 2500.0 : 4000.0) / sr));
        const float dck = static_cast<float>(kTwoPi * 20.0 / sr);
        const float dt = static_cast<float>(1.0 / sr), k2 = 0.5f * dt;
        const float s0 = sigma0, s1 = sigma1, brk = breakaway;
        const int iters = iterations;
        const float fn = forceScale * static_cast<float>(0.04 + 0.96 * pressure * pressure) * (1.0f + 0.5f * expr);
        const float fs = muS * fn, fc = muD * fn;
        const float invSpan = 1.0f / (1.0f - brk);
        const float invVs2 = 1.0f / (vStribeck * vStribeck);
        const float B = s0 * k2 + s1, invOneB = 1.0f / (1.0f + B);
        const float cz = 1.0f - k2 * s0 * invOneB, cg = k2 * invOneB;  // z = zt + k2 zd with zd = (g1 - s0 zt) / (1 + B)
        const float c1 = 1.0f - 2.0f * k2 * s0 * invOneB, c2 = 2.0f * k2 * invOneB;  // the next zt = z + k2 zd
        const float nAmt = static_cast<float>(0.6 * noises), slideAt = 0.2f * target;
        // The state in locals: the delay lines' stores cannot then make the compiler reload it every sample.
        float z = v.z, zdLast = v.zd, zt = v.zt, invZss = v.invZss, lp = v.lp, dc = v.dc;
        const float bowStep = v.bowStep, dn = v.dn, db = v.db;
        uint32_t sliding = 0;
        Noise noise = v.noise;
        // Released and the bow's speed down to 0: the bow leaves the string and the player's fingers damp it (the
        // elastic bristles alone, against a resting bow, would hand the string back its energy).
        const bool lifted = v.lifted;  // decided on the control grid (voiceControl), so any block size gives the same bits
        const float reflect = lifted ? 0.8f : 0.97f;
        Line neck = v.neck, bridge = v.bridge;
        for (uint32_t i = 0; i < n; ++i) {
            v.bow = std::clamp(v.bow + bowStep, 0.0f, 1.0f);  // in the voice: a running sum (see the winds)
            const float bow = v.bow, vb = bow * target;
            const float nb = neck.frac(dn), bb = bridge.frac(db);
            const float vh = nb + bb;
            float f, slide;
            if (lifted) {
                f = 0, slide = 0, z = zdLast = zt = 0;
            } else if (simEco) {
                const float dv = vb - vh;
                const float q = 1.0f + kk * kk * dv * dv;
                f = dv / (q * q);
                slide = std::fabs(dv - f);
            } else {
                // zt (z advanced half a step by the last rate) is the state carried from sample to sample: in the
                // elastic case the next one is one multiply-add of this one, so the chain stays short.
                const float g1 = vb - vh;
                const float A = g1 - s0 * zt;
                // The elastic (sticking) solution is exact while alpha is 0: most of each period.
                float zd = A * invOneB;
                const float z0 = zt * cz + g1 * cg, vr0 = A - B * zd;
                float zNew = z0, ztNext = zt * c1 + g1 * c2;
                if ((vr0 > 0) == (z0 > 0) && std::fabs(z0) * invZss > brk) {
                    // Past the breakaway (a share of zss, from the Stribeck curve at the last sample's sliding speed,
                    // below): Newton's method from the last sample's rate.
                    zd = zdLast;
                    for (int it = 0; it < iters; ++it) {
                        const float vr = A - B * zd;
                        const float zz = zt + k2 * zd, ratio = std::fabs(zz) * invZss;
                        float a = 0;
                        if ((vr > 0) == (zz > 0) && ratio > brk) {
                            const float t = std::min(1.0f, (ratio - brk) * invSpan);
                            a = t * t * (3.0f - 2.0f * t);
                        }
                        const float g = 1.0f - a * ratio;
                        // dG/dzd = -(1 + B g) - |vr| a k2 / zss, the last term under 1 %: 1 / (1 + x) by its series.
                        const float x = B * g + std::fabs(vr) * a * k2 * invZss;
                        zd += (vr * g - zd) * (1.0f - x + x * x);
                    }
                    zNew = zt + k2 * zd;
                    ztNext = zNew + k2 * zd;
                }
                zdLast = zd;
                z = zNew;
                zt = ztNext;
                f = s0 * z + s1 * zd;
                const float vr = g1 - f;
                slide = std::fabs(vr);
                // The Stribeck curve for the next sample (off this sample's chain): zss = (fc + (fs - fc) S) / sigma0
                // with S = 1 / (1 + (v/vs)^2), a Lorentzian in place of the paper's e^-(v/vs)^2 (the same shape near 0).
                const float e1 = 1.0f + vr * vr * invVs2;
                invZss = s0 * e1 / (fc * e1 + fs - fc);
            }
            // Bow noise, only while it slides and the bow moves (a resting bow adds none: no energy without motion).
            if (slide > slideAt) f += nAmt * bow * slide * noise.next(), ++sliding;
            neck.push(-(bb + f));
            const float toBridge = nb + f;
            lp += lpk * (toBridge - lp);
            bridge.push(-reflect * lp);
            dc += dck * (toBridge - dc);
            out[i] = (toBridge - dc) * 0.3f;
        }
        v.neck.w = neck.w, v.bridge.w = bridge.w;
        v.z = z, v.zd = zdLast, v.zt = zt, v.invZss = invZss, v.lp = lp, v.dc = dc;
        v.noise = noise;
        v.sliding += sliding, v.counted += n;
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
