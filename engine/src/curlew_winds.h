// Curlew's winds (1.1.3): Timber's Simulated reeds, jets and lips without the click into the bore on every note, dry, each with a body estimated from recordings.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "body_bands.h"
#include "curlew_wind_model.h"

namespace caw::curlew {

using timber::Shared;

// Each instrument: the wind model's kind (0 clarinet, 1 flute, 2 sax, 3 brass) and its body (curlew_bodies.cpp).
inline constexpr int kKind[6] = {1, 0, 2, 3, 3, 3};  // Flute, Clarinet, Saxophone, Trumpet, Trombone, French horn
BodyResponse bodyResponse(int instrument) noexcept;  // curlew_bodies.cpp
// Each instrument's range for the pull table: its first key and 40 keys a semitone apart.
inline constexpr int kPullFirst[6] = {58, 50, 46, 52, 38, 40};
inline constexpr int kPullKeys = 40;
#include "curlew_tuning.inc"

// The winds of Timber's Simulated mode (curlew_wind_model.h: the jet, the reeds, the cone, the lips, the tongue and
// the breath's turbulence), with what the realism research (2026-11-24) found wrong taken out or added:
// - no pad, key or valve click into the bore: it rang at the note's pitch on every note and slur, a pitched thump
//   (the "piano on the flute"). The breath's own turbulence stays (Breath noise).
// - the body: the instrument's recorded spectrum over the model's at the same notes (VSCO 2 Community Edition, CC0),
//   as peaking bands after the voices' sum, Body scaling them; the saxophone (no free recording yet) its bell's radiation, chosen (curlew_bodies.cpp).
// - its own pull (the reed's, jet's or lips' flattening, aimed off) measured over each instrument's whole range
//   (curlew_tuning.inc), where Timber measured five keys of one range;
// - dry by default (Space 0).
// - Growl (2026-11-25, the owner: Timber's 35 Hz sine on the gain "doesn't do what it's supposed to do"): a growl or
//   flutter-tongue is the player humming or rolling an R into the instrument. Here: the rolled tongue, a train of
//   short closures at about 26 Hz that wanders (a rough buzz, not a tremolo), with a little pitch flutter; and the
//   hummed pitch, about an octave under the note and 2 Hz off it, modulating the air (the sub-octave sidebands and
//   the slow beating against the note that make a growl sound sung). Per sample, into each voice's breath.
struct Winds : timber::Wind {
    using Base = timber::Wind;
    enum P : uint32_t { kCBreath, kCNoise, kCReed, kCVibrato, kCVibRate, kCGrowl, kCAttack, kCPlay };
    static constexpr uint32_t kModelParams = 8;
    // Play (1.1.3): Legato, one note at a time, a new note slurring from the held one as a player does (the frame's
    // mono legato), or Poly for chords.
    bool mono = true;
    bool legato(const Shared&) const noexcept { return mono; }
    int which = 0;  // the instrument (Flute .. French horn)
    BodyFilter body;
    float bodyAmount = 1;
    bool testBypassBody = false;
    // The growl (its own, in place of Timber's): the amount, and each voice's tongue and hum phases (by its index).
    double growlAmount = 0;
    // Two rotating phasors a voice (the tongue's roll and the hum: a complex multiply a sample, their steps set and
    // their length renormalised on the control grid, so any block size gives the same bits).
    struct Growl {
        float tr = 1, ti = 0, hr = 1, hi = 0;    // the tongue's and the hum's phasors
        float tc = 1, ts = 0, hc = 1, hs = 0;    // their steps (cos, sin)
        double rate = 26;
        timber::Noise wander;
    };
    Growl growls[Base::kPool];
    // A released note fades with its breath at the output too (the envelope's level, in a line over each block): the
    // breath alone let a low brass note's bore and lips go on sounding, -33 dB, after its release had ended, and a
    // flute's jet fall into a lower regime with a 6 dB blip as it died.
    // The step is set on the control grid (voiceControl), so any block size gives the same bits.
    float releaseGain[Base::kPool] = {}, releaseStep[Base::kPool] = {};
    void fadeReleased(Voice& v, float* out, uint32_t n) noexcept {
        if (v.envStep >= 0.0f) return;
        const auto k = &v - voices;
        float g = releaseGain[k];
        const float step = releaseStep[k];
        for (uint32_t i = 0; i < n; ++i) g = std::max(0.0f, g + step), out[i] *= g;
        releaseGain[k] = g;
    }

    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        // [Assumption] a wind player's vibrato is breath and pitch together (the flute's is usually described as
        // mostly breath; not re-read): at Vibrato 1, 20 % of the breath and 50 cents, so the default 0.2 is 10 cents
        // and 4 % (Timber's 8 cents and 5 % at 1 gave 1.6 cents at the default: Vibrato rate could not be heard).
        vibBreath = 0.2, vibCents = 50.0;
        pullTable = kPull[which], pullFirst = kPullFirst[which], pullCount = kPullKeys;
        // Brass (2026-11-26, the owner: the brass "don't really sound like genuine brass instruments"): the bore a
        // period's round trip (every one of its resonances a harmonic of the note) and the lips' resonance just under
        // the note at a fixed Q of 3, as lips are (Adachi and Sato, JASA 99(2), 1996: a Q of a few). Before, the
        // bore two periods long (resonances at the half harmonics too) and the lips at 1.15 times the note with
        // Timber's fixed bandwidth (r 0.997: a Q of 6 at C4, under 2 in the bass): the lips led, each note sounded
        // 2.2 semitones over its bore's tuning (the pull table aimed it off), the bore's resonances missed its
        // harmonics, and every brass had one clarinet-like spectrum (its 2nd harmonic 12 dB under the 1st and the
        // 3rd). [Measured] (a copy of the loop, 2026-11-26): every key E2..A#5 speaks, 1.4-2 semitones over the bore
        // (aimed off by the pull table), its harmonics falling smoothly (0, -8, -12, -14, -16 dB at velocity 0.7) and
        // 41-76 dB over what lies between them; under a mouth pressure of 1.05 the lips' oscillation turned
        // quasi-periodic (a rough tone 23-36 dB over the noise), so the velocity moves the pressure 1.05..1.2 and
        // the gain carries the rest of the loudness. Lips 0..1: 0.87..0.93 times the note.
        if (kKind[which] == 3) {
            lipRatio = 0.89f, lipSpan = 0.06, lipQ = 3.0, lipsCloseWithBreath = true;
            brassBore = 1.0, brassPush = 1.05, brassPushSpan = 0.15;
        }
        // Brass: the breath's turbulence through the lips 20 dB under Timber's (2026-11-26, the owner: "a bit too
        // noisy"). [Measured] VSCO 2 CE's sustains hold their noise between the harmonics 24-45 dB under the tone; at
        // Breath noise 0.15 the model's sat at 13-18 dB under it, at 0 at 31-38 dB: the turbulence was nearly all of it.
        if (kKind[which] == 3) lipTurb = 0.05f;
        if (!Base::prepare(rate, v, n)) return false;
        bell.design(kBellHz[which], rate);
        body.load(bodyResponse(which), bodyAmount, sr);
        return true;
    }
    void control(const double* p, const Shared& s) noexcept {
        double q[Base::kModelParams] = {};
        q[Base::kInstrument] = kKind[which];
        q[Base::kBreath] = p[kCBreath], q[Base::kNoise] = p[kCNoise], q[Base::kReed] = p[kCReed];
        q[Base::kVibrato] = p[kCVibrato], q[Base::kVibRate] = p[kCVibRate], q[Base::kGrowl] = 0.0;
        growlAmount = timber::clampd(p[kCGrowl], 0, 1);
        q[Base::kAttack] = p[kCAttack];
        mono = p[kCPlay] < 0.5;
        Base::control(q, s);
        bodyAmount = static_cast<float>(timber::clampd(s.body, 0, 1));
        body.load(bodyResponse(which), bodyAmount, sr);
    }
    void start(Voice& v, const Shared& s) noexcept {
        Base::start(v, s);
        Growl& g = growls[&v - voices];
        g = Growl{};
        g.wander.s = 0x6A09u + 131u * v.key;
        releaseGain[&v - voices] = 1.0f, releaseStep[&v - voices] = 0.0f;
    }
    void voiceControl(Voice& v, const Shared& s) noexcept {
        Base::voiceControl(v, s);
        if (v.envStep < 0.0f) {  // released: the output's gain toward the breath's level at the next control point
            const auto k = &v - voices;
            const float to = std::clamp(v.env + v.envStep * timber::kControlFrames, 0.0f, 1.0f);
            releaseStep[k] = (to - releaseGain[k]) / timber::kControlFrames;
        }
        if (growlAmount <= 0) return;
        // The tongue's roll wanders (24..30 Hz), and the pitch flutters with it (up to 20 cents at Growl 1).
        Growl& g = growls[&v - voices];
        g.rate = timber::clampd(g.rate + 0.6 * g.wander.next(), 22.0, 31.0);
        // The tongue's step by its series (w is under 0.005 rad: exact to float); the hum's is set at the note's start.
        const double wt = timber::kTwoPi * g.rate / sr, w2 = wt * wt;
        g.tc = static_cast<float>(1.0 - w2 * (0.5 - w2 / 24.0)), g.ts = static_cast<float>(wt * (1.0 - w2 / 6.0));
        if (g.hs == 0.0f) {
            const double wh = timber::kTwoPi * (0.5 * v.baseHz + 2.0) / sr;
            g.hc = static_cast<float>(std::cos(wh)), g.hs = static_cast<float>(std::sin(wh));
        }
        // Their lengths back to 1 (one Newton step of 1 / sqrt: they drift by rounding only).
        const float nt = 1.5f - 0.5f * (g.tr * g.tr + g.ti * g.ti), nh = 1.5f - 0.5f * (g.hr * g.hr + g.hi * g.hi);
        g.tr *= nt, g.ti *= nt, g.hr *= nh, g.hi *= nh;
        const double flutter = 20.0 * growlAmount * g.ti;
        tune(v, vibCents * vibrato * lib::fastSinCycles(v.vib) + flutter);
    }
    // The growl into each voice's breath (the mouth pressure, before the reed, jet or lips: the hum and the rolled
    // tongue modulate the air, and the excitation's nonlinearity mixes them with the note): the tongue's closures (a
    // raised cosine cubed, narrow dips that nearly stop the air) times the hum (a sine at half the note, 2 Hz up),
    // the mean brought back to 1 so Growl leaves the breath where it was on average.
    void growl(Voice& v, float* gm, uint32_t n) noexcept {
        Growl& g = growls[&v - voices];
        // A reed speaks only in a narrow window of pressure: less depth there (the clarinet half, the sax 0.6) keeps it
        // speaking through the growl.
        const double a = growlAmount * (kKind[which] == 0 ? 0.5 : (kKind[which] == 2 ? 0.6 : 1.0));
        const float dT = static_cast<float>(0.85 * a), dH = static_cast<float>(0.6 * a);
        const float norm = 1.0f / (1.0f - dT * 0.3125f);
        float tr = g.tr, ti = g.ti, hr = g.hr, hi = g.hi;
        const float tc = g.tc, ts = g.ts, hc = g.hc, hs = g.hs;
        for (uint32_t i = 0; i < n; ++i) {
            const float c = 0.5f + 0.5f * tr;
            gm[i] = (1.0f - dT * c * c * c) * norm * (1.0f + dH * hi);
            const float t2 = tr * tc - ti * ts, h2 = hr * hc - hi * hs;
            ti = tr * ts + ti * tc, hi = hr * hs + hi * hc;
            tr = t2, hr = h2;
        }
        g.tr = tr, g.ti = ti, g.hr = hr, g.hi = hi;
    }
    float growlBuf[4][timber::kControlFrames] = {};
    void render(Voice& v, float* out, uint32_t n) noexcept {
        if (growlAmount > 0) growl(v, growlBuf[0], n), breathMod = growlBuf;
        Base::render(v, out, n);
        fadeReleased(v, out, n);
        breathMod = nullptr;
    }
    void renderGroup(Voice* const* vs, uint32_t count, float (*out)[timber::kControlFrames], uint32_t n) noexcept {
        if (growlAmount > 0) {
            for (uint32_t l = 0; l < count; ++l) growl(*vs[l], growlBuf[l], n);
            breathMod = growlBuf;
        }
        Base::renderGroup(vs, count, out, n);
        for (uint32_t l = 0; l < count; ++l) fadeReleased(*vs[l], out[l], n);
        breathMod = nullptr;
    }
    // The bell's radiation (brass): the model's sound is the mouthpiece's pressure, whose low harmonics are strong;
    // a bell radiates its high ones far better (Benade's spectrum transformation, Fundamentals of Musical Acoustics
    // ch. 20: rising about 6 dB an octave up to the bell's cutoff, then level). A first-order shelf, 18 dB over the
    // three octaves under the cutoff, 0 dB an octave and a half under it, so the level stays near where it was.
    // [Assumption] the cutoffs (not measured: each bell's size): trumpet 1.5 kHz, trombone 0.8; the horn none (its
    // hand in the bell takes the highs back: [Measured] with a 0.6 kHz lift its centroid sat 1.1-1.6 times VSCO's). Without it the three were one dull, clarinet-like spectrum (the 2nd harmonic 12 dB
    // under the 1st; VSCO's trumpet holds its 2nd to 6th within 5 dB of the strongest).
    static constexpr double kBellHz[6] = {0, 0, 0, 1500.0, 800.0, 0};
    struct Bell {
        float b0 = 1, b1 = 0, a1 = 0, xl = 0, yl = 0, xr = 0, yr = 0;
        bool on = false;
        void design(double fc, double sr) noexcept {
            on = fc > 0;
            if (!on) return;
            // H(s) = g (s + wz) / (s + wp), wz = wp / 8 (18 dB), g so |H| = 1 at fc / 2.83; bilinear, prewarped.
            const double k = 1.0 / std::tan(timber::kPi * std::min(fc, 0.45 * sr) / sr), wp = 1.0;
            const double wz = wp / 8.0;
            const double wn = std::tan(timber::kPi * std::min(fc / 2.83, 0.45 * sr) / sr) * k;  // fc/2.83 against wp
            const double g = std::sqrt((wn * wn + wp * wp) / (wn * wn + wz * wz));
            const double a0 = k + wp;
            b0 = static_cast<float>(g * (k + wz) / a0), b1 = static_cast<float>(g * (wz - k) / a0);
            a1 = static_cast<float>((wp - k) / a0);
        }
        void process(float* l, float* r, uint32_t n) noexcept {
            if (!on) return;
            for (uint32_t i = 0; i < n; ++i) {
                const float ol = b0 * l[i] + b1 * xl - a1 * yl, orr = b0 * r[i] + b1 * xr - a1 * yr;
                xl = l[i], yl = ol, xr = r[i], yr = orr;
                l[i] = ol, r[i] = orr;
            }
            yl = timber::flushf(yl), yr = timber::flushf(yr);
        }
        void clear() noexcept { xl = yl = xr = yr = 0; }
    };
    Bell bell;
    void post(float* l, float* r, uint32_t n, const Shared& s) noexcept {
        Base::post(l, r, n, s);
        bell.process(l, r, n);
        if (!testBypassBody) body.process(l, r, n);
    }
    void clearPost() noexcept {
        Base::clearPost();
        bell.clear();
        body.clear();
    }
};

}  // namespace caw::curlew
