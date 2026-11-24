// Timber's mallets and bells (modal: marimba, vibraphone, xylophone, glockenspiel, chimes, bell) and winds (blown-pipe waveguides: clarinet, flute, sax, brass) models.
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

// ---------- Mallets and bells ----------

// Modal synthesis: up to eight decaying sines per strike (complex one-poles, run 4-wide), at the instrument's mode
// ratios: the tuned bars of a marimba and vibraphone (1 : 4 : 10, the first two by the maker's tuning), the
// xylophone's (1 : 3 : 6), a glockenspiel's free bar (1 : 2.76 : 5.40 : 8.93, Euler-Bernoulli), tubular chimes'
// free tube ((2k + 1)^2, its strike note an octave under the 4th mode) and a church bell's partials (hum, prime,
// tierce, quint, nominal..., as caw/library/modal.hpp). The mallet's hardness and the velocity tilt the modes'
// loudness toward the high ones (a hard mallet's short contact excites more of them); `position` weights them by
// where the bar is struck; `damping` shortens the high modes against the low; `dampen` is how much a released key
// damps (a vibraphone's pedal, 0 for a marimba that rings out); `motor` is the vibraphone's tremolo (0 off).
// [Assumption] the weights and decays are typical, chosen by ear, not measured.
struct Mallet {
    static constexpr uint32_t kEcoCap = 16, kNormalCap = 32, kHighCap = 32, kPool = kHighCap + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = true;
    static constexpr double kMinLife = 0.02, kSpread = 0.5;
    enum P : uint32_t { kInstrument, kHardness, kDecay, kPosition, kDamping, kDampen, kMotor, kSim, kNoises, kModelParams };
    static constexpr int kModes = 8;

    struct Voice : VoiceBase {
        F4 c[2], s[2], zr[2], zi[2];
        double hz = 0, t60 = 1, tunedPitch = -1;
        bool damped = false;
        uint32_t clickLeft = 0;
        Noise noise;
        // 1.1.2 Simulated: the mallet's contact, each mode's force input (its shape at the strike point over its
        // modal mass and frequency) and its share of the sound (radiation), applied when the contact ends.
        Contact contact;
        F4 phi[2], place[2], radiate[2];
        float contactPeak = 0;
    };

    int instrument = 0;
    double hardness = 0.5, decay = 1, position = 0.3, damping = 0.4, dampen = 0, motor = 0;
    bool sim = false, contactOn = true;
    double noises = kNoisesDefault;
    double sr = 48000, phase = 0;

    size_t allocBytes() const noexcept { return 0; }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 0.6, r.decay = 1.8, r.damping = 0.4, r.mix = 1.0, r.width = 1.0;
        return r;
    }
    bool prepare(double rate, Voice*, uint32_t) noexcept {
        sr = rate;
        return true;
    }
    void reset() noexcept { clearPost(); }
    void control(const double* p, const Shared& s) noexcept {
        instrument = static_cast<int>(clampd(p[kInstrument], 0, 5) + 0.5);
        hardness = clampd(p[kHardness], 0, 1);
        decay = clampd(p[kDecay], 0.25, 4);
        position = clampd(p[kPosition], 0, 1);
        damping = clampd(p[kDamping], 0, 1);
        dampen = clampd(p[kDampen], 0, 1);
        motor = clampd(p[kMotor], 0, 10);
        sim = p[kSim] >= 0.5;
        noises = clampd(p[kNoises], 0, 1);
        contactOn = s.quality != kQualityEco;  // Eco: 1.1.0's strike
    }
    struct Table {
        double ratio[kModes], weight[kModes], t60;
        int modes;
    };
    static const Table& table(int instrument) noexcept {
        static const Table kTables[6] = {
            {{1, 4.0, 9.9, 17.2}, {1, 0.35, 0.15, 0.06}, 1.6, 4},                                // Marimba
            {{1, 4.0, 10.0, 16.9}, {1, 0.3, 0.12, 0.05}, 6.0, 4},                                // Vibraphone
            {{1, 3.0, 6.0, 10.2}, {1, 0.5, 0.25, 0.1}, 0.7, 4},                                  // Xylophone
            {{1, 2.756, 5.404, 8.933}, {1, 0.6, 0.35, 0.15}, 3.0, 4},                            // Glockenspiel
            {{0.617, 1.21, 2.0, 2.99, 4.17, 5.53}, {0.3, 0.7, 1.0, 0.7, 0.4, 0.2}, 5.0, 6},     // Chimes
            {{0.5, 1.0, 1.183, 1.506, 2.0, 2.514, 2.662, 3.011}, {0.6, 1.0, 0.8, 0.45, 0.9, 0.35, 0.3, 0.4}, 6.0, 8},  // Bell
        };
        return kTables[instrument];
    }
    void setModes(Voice& v, double t60) const noexcept {
        const Table& t = table(instrument);
        for (int k = 0; k < kModes; ++k) {
            const double hz = v.hz * t.ratio[k];
            double c = 0, s = 0;
            if (k < t.modes && hz < 0.45 * sr) {
                const double r = std::max(1.0, t.ratio[k] / t.ratio[0]);
                const double life = t60 * detPow(r, -1.5 * damping);
                const double rr = detExp(-6.907755278982137 / (life * sr));
                const double w = kTwoPi * hz / sr;
                c = rr * std::cos(w), s = rr * std::sin(w);
            }
            v.c[k / 4][k % 4] = static_cast<float>(c), v.s[k / 4][k % 4] = static_cast<float>(s);
        }
    }
    void start(Voice& v, const Shared&) noexcept {
        const Table& t = table(instrument);
        v.hz = noteHz(clampd(v.pitch, 0, 127));
        v.tunedPitch = v.pitch;
        v.t60 = t.t60 * decay * clampd(detPow(2.0, -(v.pitch - 60.0) / 24.0), 0.15, 4.0);
        v.damped = false;
        setModes(v, v.t60);
        const double vel = v.velocity;
        const double tilt = -1.4 + 2.2 * hardness * (0.35 + 0.65 * vel);
        double sum = 0, w[kModes] = {};
        for (int k = 0; k < t.modes; ++k) {
            const double r = t.ratio[k] / t.ratio[0];
            const double place = 0.3 + 0.7 * std::fabs(std::sin(kPi * (k + 1) * (0.1 + 0.4 * position)));
            w[k] = t.weight[k] * detPow(r, tilt) * place;
            sum += w[k] * w[k];
        }
        const double amp = (0.12 + 0.88 * detPow(vel, 1.5)) * 0.5 / std::sqrt(sum + 1e-12);
        for (int k = 0; k < kModes; ++k) {
            v.zr[k / 4][k % 4] = static_cast<float>(w[k] * amp);
            v.zi[k / 4][k % 4] = 0.0f;
        }
        v.clickLeft = static_cast<uint32_t>(0.0008 * sr * hardness);
        v.noise.s = 0x9E37u + v.key;
        v.contact.done = true;
        if (sim && contactOn) strikeSim(v);
    }
    // 1.1.2 Simulated: the bar is struck by a mallet head through a Hunt-Crossley contact (Hunt and Crossley, J.
    // Appl. Mech. 42(2), 1975): the head (its mass the unit) arrives at the velocity's speed, the felt or rubber's
    // stiffness sets the contact time (`hardness`: about 4 ms for yarn down to 0.25 ms for a hard plastic head, a
    // little shorter the harder the blow, as Hertz's law has it), and the bar's modes feel the force through their
    // shape at the strike point (`position`) over their modal mass and frequency. So a hard mallet's short contact
    // excites the high modes, a soft one's long contact only the low ones, and the strike's brightness grows with
    // velocity: no tilt is set by hand. The head's own knock (`noises`) is a small noise with the force.
    // [Assumption] the modal masses are equal (four times the head's), not measured.
    void strikeSim(Voice& v) noexcept {
        const Table& t = table(instrument);
        const double w0 = kTwoPi * v.hz;
        for (int k = 0; k < kModes; ++k) {
            const double r = t.ratio[k] / t.ratio[0];
            const bool on = k < t.modes && v.hz * t.ratio[k] < 0.45 * sr;
            const double place = on ? 0.3 + 0.7 * std::fabs(std::sin(kPi * (k + 1) * (0.1 + 0.4 * position))) : 0.0;
            v.place[k / 4][k % 4] = static_cast<float>(place);
            v.phi[k / 4][k % 4] = static_cast<float>(on ? place / (4.0 * w0 * r) / sr : 0.0);
            v.radiate[k / 4][k % 4] = static_cast<float>(on ? t.weight[k] * r : 0.0);
            v.zr[k / 4][k % 4] = 0.0f, v.zi[k / 4][k % 4] = 0.0f;
        }
        const double vel = v.velocity;
        const double tc = 0.004 * detPow(16.0, -hardness);  // 4 ms .. 0.25 ms
        const double v0 = 0.2 + 1.8 * vel;
        v.contact.strike(static_cast<float>(v0), tc, 0.3 / v0, sr);  // lambda = 3 (1 - e) / 2 v0 for a restitution e = 0.8
        v.contactPeak = 0;
        v.clickLeft = 0;
    }
    // The contact's samples: the bar's displacement under the head is the modes' sum through their shapes.
    CAW_TIMBER_NOINLINE uint32_t renderContact(Voice& v, float* out, uint32_t n) noexcept {
        const int blocks = table(instrument).modes > 4 ? 2 : 1;
        const float knock = static_cast<float>(0.002 * noises);
        // The modes' displacements are scaled for the ear once the contact ends; until then the output uses them.
        const float gain = static_cast<float>(kSimGain * (0.12 + 0.88 * v.velocity) / (0.2 + 1.8 * v.velocity));
        uint32_t i = 0;
        for (; i < n && !v.contact.done; ++i) {
            float yb = 0;
            for (int b = 0; b < blocks; ++b) {
                const F4 d = v.place[b] * v.zi[b];
                yb += d[0] + d[1] + d[2] + d[3];
            }
            const float f = v.contact.step(yb);
            v.contactPeak = std::max(v.contactPeak, f);
            float y = 0;
            for (int b = 0; b < blocks; ++b) {
                const F4 zr = v.zr[b] + v.phi[b] * f4(f);
                const F4 r = v.c[b] * zr - v.s[b] * v.zi[b], im = v.s[b] * zr + v.c[b] * v.zi[b];
                v.zr[b] = r, v.zi[b] = im;
                const F4 o = v.radiate[b] * im;
                y += o[0] + o[1] + o[2] + o[3];
            }
            out[i] = y * gain + knock * f * v.noise.next() / (1.0f + v.contactPeak);
        }
        if (v.contact.done)  // from here the modes ring as 1.1.0's, each already at its loudness
            for (int b = 0; b < 2; ++b) v.zr[b] = v.zr[b] * v.radiate[b] * f4(gain), v.zi[b] = v.zi[b] * v.radiate[b] * f4(gain);
        return i;
    }
    static constexpr double kSimGain = 3000.0;  // the modes' displacement to the 1.1.0 strike's level (measured)
    void release(Voice& v, const Shared& s) noexcept {
        if (dampen <= 0.0) return;
        v.damped = true;
        // Toward `release` seconds by `dampen` (a log blend: half-way is the geometric mean).
        setModes(v, v.t60 * detPow(std::min(1.0, s.release / v.t60), dampen));
    }
    void voiceControl(Voice& v, const Shared&) noexcept {
        if (v.pitch != v.tunedPitch) v.tunedPitch = v.pitch, v.hz = noteHz(clampd(v.pitch, 0, 127)), setModes(v, v.t60);
        for (int b = 0; b < 2; ++b)
            for (int k = 0; k < 4; ++k) v.zr[b][k] = flushf(v.zr[b][k]), v.zi[b][k] = flushf(v.zi[b][k]);
    }
    void render(Voice& v, float* out, uint32_t n) noexcept {
        if (!v.contact.done) {  // Simulated, while the head touches (then the 1.1.0 loop, below)
            const uint32_t i = renderContact(v, out, n);
            if (i < n) render(v, out + i, n - i);
            return;
        }
        const int blocks = table(instrument).modes > 4 ? 2 : 1;
        for (uint32_t i = 0; i < n; ++i) {
            float y = 0;
            for (int b = 0; b < blocks; ++b) {
                const F4 r = v.c[b] * v.zr[b] - v.s[b] * v.zi[b], im = v.s[b] * v.zr[b] + v.c[b] * v.zi[b];
                v.zr[b] = r, v.zi[b] = im;
                y += im[0] + im[1] + im[2] + im[3];
            }
            if (v.clickLeft) --v.clickLeft, y += 0.05f * static_cast<float>(hardness * v.velocity) * v.noise.next();
            out[i] = y;
        }
    }
    void post(float* l, float* r, uint32_t n, const Shared&) noexcept {
        if (motor <= 0.0) return;
        const double inc = motor / sr;
        for (uint32_t i = 0; i < n; ++i) {
            const float g = 1.0f - 0.25f * (1.0f + static_cast<float>(lib::fastSinCycles(phase)));
            phase += inc;
            if (phase >= 1.0) phase -= 1.0;
            l[i] *= g, r[i] *= g;
        }
    }
    bool postQuiet() const noexcept { return true; }
    void clearPost() noexcept { phase = 0; }
    void display(float* out) const noexcept {
        out[0] = static_cast<float>(instrument);
        out[1] = static_cast<float>(phase);
        out[2] = static_cast<float>(motor);
    }
};

// ---------- Winds ----------

// Blown pipes, each a bore delay line with the published excitation for its kind (Smith's and Cook's waveguide
// wind models; STK, MIT-like licence, read for ideas, no code taken):
// - Clarinet: a cylindrical bore closed at the reed (half a period of delay, inverted at the bell through a
//   one-pole loss); the reed is a table of the pressure difference, r = offset + slope x dp held to -1..1, stiffer
//   (a steeper slope) with `reed`.
// - Flute: an open bore (a whole period) and a jet delay (`reed` sets its length, 0.32-0.52 of the bore's): the
//   jet's sigmoid x - x^3 drives the bore.
// - Sax: the clarinet's reed on a whole-period bore without the inversion, so every harmonic sounds (a cone's
//   series). [Assumption] a simplification of a conical bore, chosen by ear.
// - Brass: a lip resonator (a resonant biquad near the note, `reed` its tension) whose squared output is the
//   valve between the mouth and the bore.
// Breath is an envelope (`attack`, the shared `release`) times `breath`, the velocity, poly pressure and the mod
// wheel; `noise` adds breath noise; `vibrato` moves the breath and a little the pitch; `growl` modulates it at
// about 35 Hz (a growled sax). Each kind's pitch pull is corrected by a factor measured in timber_test.
struct Wind {
    static constexpr uint32_t kEcoCap = 8, kNormalCap = 8, kHighCap = 8, kPool = 16 + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = false;
    static constexpr double kMinLife = 0.05, kSpread = 0.25;
    enum P : uint32_t { kInstrument, kBreath, kNoise, kReed, kVibrato, kVibRate, kGrowl, kAttack, kSim, kNoises, kModelParams };

    struct Voice : VoiceBase {
        Line bore, jet;
        float d = 2, dj = 2, lp = 0, dcx = 0, dcy = 0, ox = 0, oy = 0;
        float env = 0, envStep = 0;
        double vib = 0, growl = 0;
        float g = 1, gStep = 0;  // the growl's gain, in a straight line over each control block
        float lipA1 = 0, lipA2 = 0, lipG = 0, lip1 = 0, lip2 = 0;
        Noise noise;
        double tunedPitch = -1, baseHz = 440;
        // 1.1.2 Simulated: the tongue on the reed (1 closed), the jet's last flow and travel ramp, the sax's apex
        // line length (the jet line serves it), the High reed's mass-spring, the pad clicks, the last turbulence.
        float jetU = 0, jetUStep = 0, coneA = 0, apX = 0, apY = 0, tongue = 0, tongueStep = 0, q1 = 0, djStep = 0, djCur = 2, da = 2, reed1 = 0, reed2 = 0, turb = 0;
        double clickPitch = -1;
        Click click;
    };

    int instrument = 0;
    double breath = 0.6, noise = 0.15, reed = 0.5, vibrato = 0.2, vibRate = 5, growl = 0, attack = 0.04;
    bool sim = false, steep = true, dynamicReed = false;
    double noises = kNoisesDefault;
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
        sim = p[kSim] >= 0.5;
        noises = clampd(p[kNoises], 0, 1);
        steep = s.quality != kQualityEco;          // Eco: no brassy steepening
        dynamicReed = s.quality == kQualityHigh;  // High: the reed as a mass-spring
        if (dynamicReed) {  // the reed's own resonance (about 2.3 kHz, damped), unit gain at DC
            const double w = kTwoPi * std::min(2300.0, 0.4 * sr) / sr, r = 0.86;
            reedA1 = static_cast<float>(2.0 * r * std::cos(w)), reedA2 = static_cast<float>(-r * r);
            reedG = 1.0f - reedA1 - reedA2;
        }
    }
    // The measured pull of each kind's excitation on its pitch, as a period factor (timber_test checks the result).
    static double periodFactor(int instrument) noexcept {
        static constexpr double kF[4] = {1.0, 1.0, 1.0, 1.053};
        return kF[instrument];
    }
    // What is left of the flute's and the brass's pitch pull, measured at five keys (cents; linear between, held outside).
    static double residualPull(int instrument, double pitch) noexcept {
        static constexpr double kKey[5] = {45, 50, 62, 74, 81};
        static constexpr double kPull[4][5] = {{0, 0, 0, 0, 0}, {31, 14, 4, -1, -6}, {0, 0, 0, 0, 0}, {9, 9, 0, 7, 16}};
        const double* p = kPull[instrument];
        if (pitch <= kKey[0]) return p[0];
        for (int i = 1; i < 5; ++i)
            if (pitch <= kKey[i]) return p[i - 1] + (p[i] - p[i - 1]) * (pitch - kKey[i - 1]) / (kKey[i] - kKey[i - 1]);
        return p[4];
    }
    // Simulated: each kind's period factor and its remaining pull at the five keys (cents), measured in timber_test.
    static double simPeriod(int instrument) noexcept {
        static constexpr double kF[4] = {1.0, 1.0, 1.0, 1.0};
        return kF[instrument];
    }
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
            double aim = sim ? -simPull(instrument, v.pitch) : -residualPull(instrument, v.pitch);
            if (instrument == 3 && !sim) aim -= 6.0 - 3.4 * (clampd(v.pitch, 34.0, 100.0) - 62.0);
            v.baseHz = noteHz(clampd(v.pitch, 34.0, 100.0) + aim / 100.0);
        }
        const double f0 = v.baseHz * lib::fastExp(cents * 5.776226504666211e-4);  // ln 2 / 1200
        const double period = sr / f0 * (sim ? simPeriod(instrument) : periodFactor(instrument));
        // Clarinet and sax: half a period (closed at the reed, inverted at the bell). Flute: the model speaks at 1.5x
        // its bore's lowest mode, so the bore is 1.5 periods. Brass: the lips pick the bore's 2nd mode (2 periods).
        static constexpr double kBore[4] = {0.5, 1.5, 0.5, 2.0};
        const float cap = static_cast<float>(v.bore.mask - 4);
        v.d = std::min(cap, static_cast<float>(std::max(2.0, kBore[instrument] * period - 1.0)));
        v.dj = std::min(cap, static_cast<float>(std::max(2.0, v.d * (0.28 + 0.1 * reed))));
        if (sim && instrument == 1) {  // an open-open pipe: a period round trip, both ends inverting (+1 in all)
            v.d = std::min(cap, static_cast<float>(std::max(2.0, period * simPeriod(1) - 1.0)));
            v.dj = std::min(cap, static_cast<float>(std::max(2.0, v.d * (jetRatio + 0.1 * (reed - 0.5)))));
        }
        if (sim && instrument == 2) {  // the cone: a period round trip less the closed end's and the bell's delays
            const double w0 = kTwoPi * f0 / sr, K = 2.0, wc = coneK * w0;
            const double a = (K - wc) / (K + wc);
            v.coneA = static_cast<float>(a);
            const double rest = period * simPeriod(2) - onePoleDelay(1.0 - saxLp, w0) - allpassDelay(-a, w0);
            v.d = std::min(cap, static_cast<float>(std::max(2.0, rest)));
        }
        if (instrument == 3) {  // the lips: a two-pole resonance at the note
            const double w = kTwoPi * f0 * ((sim ? lipRatio : 0.92) + 0.02 * reed) / sr, r = 0.997;
            v.lipA1 = static_cast<float>(2.0 * r * std::cos(w)), v.lipA2 = static_cast<float>(-r * r);
            v.lipG = static_cast<float>(0.002 * std::sin(w) / 0.043);  // the same peak gain at every pitch
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
        if (sim) {
            // The tongue holds the reed (the lips, the flute's air) until the note's start, then leaves it in 4-12 ms;
            // the key's pad (the valve) closes first, its click ringing in the new bore.
            v.tongue = 1, v.tongueStep = -static_cast<float>(1.0 / ((0.012 - 0.008 * v.velocity) * sr));
            v.q1 = v.djStep = v.reed1 = v.reed2 = v.turb = v.apX = v.apY = v.jetU = v.jetUStep = 0;
            v.djCur = std::min(static_cast<float>(v.jet.mask - 4), v.dj * 2.5f);
            padClick(v);
        }
    }
    void padClick(Voice& v) noexcept {
        v.clickPitch = v.pitch;
        const double a = noises * (0.4 + 0.6 * v.velocity) * (instrument == 3 ? 0.12 : 0.3);
        v.click.start(static_cast<float>(a), instrument == 3 ? 0.002 : 0.001, sr);
    }
    void release(Voice& v, const Shared& s) noexcept {
        v.envStep = -static_cast<float>(1.0 / std::max(1.0, std::max(0.01, s.release) * sr));
        if (sim && s.release < 0.06)  // a short release is a tongued stop: the tongue back on the reed
            v.tongueStep = static_cast<float>(1.0 / (std::max(0.004, s.release) * sr));
    }
    void voiceControl(Voice& v, const Shared&) noexcept {
        const double dt = kControlFrames / sr;
        v.vib += vibRate * dt;
        v.vib -= std::floor(v.vib);
        tune(v, 8.0 * vibrato * lib::fastSinCycles(v.vib));
        // The growl (about 35 Hz): its gain now and at the next control point, in a line between.
        // No growl: exactly 1 and no step, without the two sines.
        const double amt = 0.4 * growl;
        v.g = amt > 0.0 ? static_cast<float>(1.0 + amt * lib::fastSinCycles(v.growl)) : 1.0f;
        v.growl += 35.0 * dt;
        v.growl -= std::floor(v.growl);
        v.gStep = amt > 0.0 ? static_cast<float>((1.0 + amt * lib::fastSinCycles(v.growl) - v.g) / kControlFrames) : 0.0f;
        v.lp = flushf(v.lp), v.dcx = flushf(v.dcx), v.dcy = flushf(v.dcy), v.ox = flushf(v.ox), v.oy = flushf(v.oy);
        v.lip1 = flushf(v.lip1), v.lip2 = flushf(v.lip2);
        if (sim) {
            v.apX = flushf(v.apX), v.apY = flushf(v.apY), v.q1 = flushf(v.q1), v.reed1 = flushf(v.reed1), v.reed2 = flushf(v.reed2);
            if (std::fabs(v.pitch - v.clickPitch) >= 0.5) padClick(v);  // a slur to another note: its keys move
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
        if (sim) {
            Voice* one[1] = {&v};
            float buf[1][kControlFrames];
            renderSim(one, 1, buf, n);
            std::copy(buf[0], buf[0] + n, out);
            return;
        }
        const float expr = static_cast<float>(std::max(v.pressure, modWheel));
        static constexpr float kOut[4] = {0.5f, 0.2f, 0.45f, 0.8f};  // about level with each other
        static constexpr float kLow[4] = {0.5f, 0.9f, 0.55f, 0.3f}, kSpan[4] = {0.5f, 0.4f, 0.45f, 0.15f};
        const float base = kLow[instrument] + kSpan[instrument] * static_cast<float>(breath);
        const float loud = static_cast<float>(0.35 + 0.65 * v.velocity) * (1.0f + 0.6f * expr);
        const float vibAm = static_cast<float>(0.05 * vibrato * lib::fastSinCycles(v.vib));
        const float noiseAmt = static_cast<float>(0.2 * noise + 0.004);  // a breath is never still: it also starts the tone
        // The reed: the product of pressure and slope sets whether it speaks; `reed` moves it within the window.
        const float slope = -static_cast<float>(0.19 + 0.06 * reed) / base;
        for (uint32_t i = 0; i < n; ++i) {
            v.env = std::clamp(v.env + v.envStep, 0.0f, 1.0f);
            float pm = v.env * base * (1.0f + vibAm);
            v.g += v.gStep;
            const float g = v.g;
            pm *= 1.0f + noiseAmt * v.noise.next();
            const float b = v.bore.frac(v.d);
            float w, y;
            switch (instrument) {
                case 0:    // clarinet
                case 2: {  // sax
                    v.lp += 0.5f * (b - v.lp);
                    const float dp = -0.95f * v.lp - pm;
                    const float r = std::clamp(0.7f + slope * dp, -1.0f, 1.0f);
                    w = pm + dp * r;
                    y = instrument == 0 ? w : w + 0.45f * w * w;  // [Assumption] the cone's even harmonics, folded in
                    break;
                }
                case 1: {  // flute
                    v.lp += 0.3f * (b - v.lp);
                    float t = -v.lp;
                    const float d = t - v.dcx + 0.995f * v.dcy;  // the reflection's DC blocked
                    v.dcx = t, v.dcy = d, t = d;
                    const float j = v.jet.frac(v.dj);
                    v.jet.push(pm - 0.5f * t);
                    w = std::clamp(j * (j * j - 1.0f), -1.0f, 1.0f) + 0.5f * t;
                    y = b;
                    break;
                }
                default: {  // brass
                    const float dp = pm - 0.85f * b;
                    const float lip = v.lipG * dp + v.lipA1 * v.lip1 + v.lipA2 * v.lip2;
                    v.lip2 = v.lip1, v.lip1 = lip;
                    const float m = std::min(1.0f, lip * lip);
                    const float x = pm * m + (1.0f - m) * 0.85f * b;
                    const float d = x - v.dcx + 0.995f * v.dcy;  // a DC blocker in the loop
                    v.dcx = x, v.dcy = d;
                    w = y = d;
                    break;
                }
            }
            v.bore.push(w);
            const float o = y - v.ox + 0.995f * v.oy;  // the breath's pressure is DC: only its motion sounds
            v.ox = y, v.oy = o;
            out[i] = o * loud * g * kOut[instrument];
        }
    }
    static constexpr float kRadiate = 24.0f;  // the brass's radiation line's middle, in samples
    // The mouth pressure against the window's middle (breath 0.5): 1 there.
    float pressureScale() const noexcept { return static_cast<float>(0.5 + breath) / 1.0f; }

    // ---------- 1.1.2 Simulated ----------
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
    // Pad, key and valve clicks are half-sine forces into the bore at each note and slur (`noises`).
    // Voices run four at a time (GroupedModel, timber_core.h): each lane is one voice, so four voices' bore and lip
    // chains overlap instead of waiting on each other. Lanes past `count` repeat the first voice and are thrown away
    // (they never write its lines or its state).
    bool grouped() const noexcept { return sim; }
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
        Click click[4];
        for (uint32_t l = 0; l < 4; ++l) {
            const Voice& v = *lane[l];
            const float expr = static_cast<float>(std::max(v.pressure, modWheel));
            // The player blows harder for a louder note: the velocity and expression move the mouth pressure (so a
            // brass note brightens with level), the rest of the loudness is the gain.
            const float push = static_cast<float>(K == 3 ? 0.75 + 0.5 * v.velocity : 0.9 + 0.2 * v.velocity) * (1.0f + 0.15f * expr);
            base[l] = (kLow[K] + kSpan[K] * static_cast<float>(breath)) * push;
            loud[l] = static_cast<float>(0.45 + 0.55 * v.velocity) * (1.0f + 0.4f * expr);
            vibAm[l] = static_cast<float>(0.05 * vibrato * lib::fastSinCycles(v.vib));
            slope[l] = -static_cast<float>(0.19 + 0.06 * reed) / base[l];
            env[l] = v.env, envStep[l] = v.envStep, tongue[l] = v.tongue, tongueStep[l] = v.tongueStep, g[l] = v.g, gStep[l] = v.gStep;
            lp[l] = v.lp, dcx[l] = v.dcx, dcy[l] = v.dcy, lip1[l] = v.lip1, lip2[l] = v.lip2, reed1[l] = v.reed1, reed2[l] = v.reed2;
            apX[l] = v.apX, apY[l] = v.apY, turb[l] = v.turb, q1[l] = v.q1, ox[l] = v.ox, oy[l] = v.oy;
            coneA[l] = v.coneA, lipG[l] = v.lipG, lipA1[l] = v.lipA1, lipA2[l] = v.lipA2;
            djCur[l] = v.djCur, djStep[l] = v.djStep, jetU[l] = v.jetU, jetUStep[l] = v.jetUStep;
            d[l] = v.d;
            bore[l] = v.bore, jet[l] = v.jet;
            nzs[l] = v.noise;
            click[l] = v.click;
        }
        const F4 zero = f4(0.0f), one = f4(1.0f);
        for (uint32_t i = 0; i < n; ++i) {
            env = clamp4(env + envStep, zero, one);
            tongue = clamp4(tongue + tongueStep, zero, one);
            const F4 open = one - tongue;
            const F4 pm = env * base * (one + vibAm);
            g = g + gStep;
            F4 nz, clk, b;
            for (uint32_t l = 0; l < 4; ++l) nz[l] = nzs[l].next(), clk[l] = l < count ? click[l].next() : 0.0f, b[l] = bore[l].frac(d[l]);
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
                w = re * (f4(-0.95f) * lp) + (one - re) * pm + turb + clk;
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
                w = re * ap + (one - re) * pm + turb + clk;
                y = w;
            } else if constexpr (K == 1) {  // flute
                lp = lp + f4(boreLp) * (b - lp);
                const F4 dd = lp - dcx + f4(0.995f) * dcy;
                dcx = lp, dcy = dd;
                const F4 t = dd;
                djCur = djCur + djStep;
                F4 eta;
                for (uint32_t l = 0; l < 4; ++l) eta[l] = jet[l].frac(djCur[l]);
                const F4 U = jetU * open;
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
                w = drive + f4(0.5f) * t + turb + clk;
                y = b;
            } else {  // brass
                const F4 dp = pm - f4(0.85f) * b;
                const F4 lip = lipG * dp + lipA1 * lip1 + lipA2 * lip2;
                lip2 = lip1, lip1 = lip;
                const F4 hgt = clamp4(f4(0.02f) + f4(lipOpen) * lip, zero, f4(lipMax)) * open;  // the lips part only so far
                const F4 root = sqrt4(abs4(dp));
                const F4 flow = hgt * sel4(gt4(dp, zero), root, zero - root);
                turb = f4(turbAmt) * f4(0.5f) * abs4(flow) * nz;
                const F4 x = f4(0.85f) * b + f4(lipFlow) * flow + turb + clk;
                const F4 dd = x - dcx + f4(0.995f) * dcy;
                dcx = x, dcy = dd;
                w = y = clamp4(dd, f4(-4.0f), f4(4.0f));
                if (ks > 0.0f) {
                    // Brassiness: on the way out to the bell (not in the loop: Hirschberg et al. find it matters
                    // for the radiated sound, not for the oscillation) a crest travels faster than a trough, so
                    // the wave steepens as it gets louder: a short line read earlier by the wave's own pressure.
                    const F4 at = clamp4(f4(kRadiate) - f4(ks) * y, one, f4(2.0f * kRadiate - 1.0f));
                    for (uint32_t l = 0; l < count; ++l) jet[l].push(y[l]);
                    for (uint32_t l = 0; l < 4; ++l) y[l] = jet[l].frac(at[l]);
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
            v.click = click[l];
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
