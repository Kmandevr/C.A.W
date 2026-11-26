// Starling's piano model (Timber's Simulated piano, 1.1.2): the shared soundboard and resonance banks, Hunt-Crossley contacts for the mechanical noises, the fitted dispersion design and the decay curve.
#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "instrument_dsp.h"
#include "starling_piano_curves.h"

namespace caw::timber::psim {

// ---------- The generated tables (starling_piano_tables.cpp) ----------
struct HammerData {
    const int16_t* pulse;  // piano_curves::kPulseFrames frames at kPulseRate, peak 32767
    float peak;            // the pulse's peak force, N
    float contactMs;       // its first contact's length
};
HammerData hammer(int zone, int layer) noexcept;
struct BoardData {
    int K;
    const float* hz;
    const float* sigma;
    const float* c;  // [3 boards][left re, left im, right re, right im][K]
};
BoardData boardData(int size) noexcept;  // 0: 24 sections (Eco), 1: 48 (Normal), 2: 96 (High)
size_t tableBytes() noexcept;

inline F4 load4(const float* p) noexcept {
    F4 v;
    std::memcpy(&v, p, sizeof v);
    return v;
}
inline void store4(float* p, F4 v) noexcept { std::memcpy(p, &v, sizeof v); }
inline float sum4(F4 v) noexcept { return (v[0] + v[1]) + (v[2] + v[3]); }

// A bank of up to N decaying complex exponentials sharing one input, each read out as Re(c z) on one or two sides:
// z <- p z + x, p = e^{(-sigma + j w) / sr} (impulse invariance of h(t) = Re(c e^{s t}), so the same bank at any
// sample rate). Four sections at a time (SIMD); a block's sections run over the block in turn.
template <int N, bool Stereo, bool Weighted = false>
struct ModeBank {
    static_assert(N % 4 == 0);
    alignas(16) float pr[N] = {}, pi[N] = {}, lr[N] = {}, li[N] = {}, rr[N] = {}, ri[N] = {}, zr[N] = {}, zi[N] = {};
    // Weighted: each section's share of the input (1 every one by default: x times 1 is x, the same bits).
    alignas(16) float in[N];
    int groups = 0;
    ModeBank() noexcept {
        for (float& w : in) w = 1.0f;
    }

    // Section k: frequency hz, decay rate sigma (1/s), weights (left and right complex c; the right ignored if mono).
    void set(int k, double hz, double sigma, double cl_r, double cl_i, double cr_r, double cr_i, double sr) noexcept {
        if (hz >= 0.45 * sr) cl_r = cl_i = cr_r = cr_i = 0;  // above the band: silent (the state still decays)
        const double r = detExp(-sigma / sr), w = kTwoPi * hz / sr;
        pr[k] = static_cast<float>(r * detCos(w)), pi[k] = static_cast<float>(r * detSin(w));
        // Re(c z) = c_r z_r - c_i z_i; the 1/sr is the impulse invariance's time step.
        lr[k] = static_cast<float>(cl_r / sr), li[k] = static_cast<float>(-cl_i / sr);
        rr[k] = static_cast<float>(cr_r / sr), ri[k] = static_cast<float>(-cr_i / sr);
        if (k / 4 + 1 > groups) groups = k / 4 + 1;
    }
    void clear() noexcept {
        std::memset(zr, 0, sizeof zr);
        std::memset(zi, 0, sizeof zi);
    }
    void flush() noexcept {
        for (int k = 0; k < groups * 4; ++k) zr[k] = flushf(zr[k]), zi[k] = flushf(zi[k]);
    }
    float energy() const noexcept {
        float e = 0;
        for (int k = 0; k < groups * 4; ++k) e += zr[k] * zr[k] + zi[k] * zi[k];
        return e;
    }
    // Adds the bank's response to x[0, n) (n <= 16) into l (and r).
    void process(const float* x, float* l, float* r, uint32_t n) noexcept {
        F4 accL[16], accR[16];
        for (uint32_t i = 0; i < n; ++i) accL[i] = f4(0.0f), accR[i] = f4(0.0f);
        for (int g = 0; g < groups; ++g) {
            const int o = 4 * g;
            const F4 Pr = load4(pr + o), Pi = load4(pi + o), Lr = load4(lr + o), Li = load4(li + o);
            const F4 Rr = load4(rr + o), Ri = load4(ri + o);
            F4 Zr = load4(zr + o), Zi = load4(zi + o);
            const F4 In = load4(in + o);
            for (uint32_t i = 0; i < n; ++i) {
                F4 X = f4(x[i]);
                if constexpr (Weighted) X = X * In;
                const F4 nr = Pr * Zr - Pi * Zi + X;
                const F4 ni = Pi * Zr + Pr * Zi;
                Zr = nr, Zi = ni;
                accL[i] = accL[i] + (Lr * nr + Li * ni);
                if constexpr (Stereo) accR[i] = accR[i] + (Rr * nr + Ri * ni);
            }
            store4(zr + o, Zr), store4(zi + o, Zi);
        }
        for (uint32_t i = 0; i < n; ++i) {
            l[i] += sum4(accL[i]);
            if constexpr (Stereo) r[i] += sum4(accR[i]);
        }
    }
};

// The soundboard: Bank's parallel sections fitted (at build time) to a modal board; one instance after the voice sum.
struct Board : ModeBank<96, true> {
    int size = -1, board = -1;
    double rate = 0;
    void design(double sr, int sizeIndex, int which) noexcept {
        if (sizeIndex == size && which == board && sr == rate) return;
        size = sizeIndex, board = which, rate = sr;
        const BoardData d = boardData(sizeIndex);
        groups = 0;
        for (int k = 0; k < 96; ++k) pr[k] = pi[k] = lr[k] = li[k] = rr[k] = ri[k] = 0;
        const float* c = d.c + static_cast<size_t>(which) * 4 * d.K;
        for (int k = 0; k < d.K; ++k) set(k, d.hz[k], d.sigma[k], c[k], c[d.K + k], c[2 * d.K + k], c[3 * d.K + k], sr);
        // The sections a smaller size leaves keep decaying from their old state: none remain past `groups` (cleared).
        for (int k = groups * 4; k < 96; ++k) zr[k] = zi[k] = 0;
    }
};

// A mono resonator of up to 8 modes (a key frame, the trapwork, the damper rail), excited by contact forces.
struct Resonator : ModeBank<8, false> {
    // `hz`, `t60` (s) and `gain` per mode (n <= 8).
    void design(const double* hz, const double* t60, const double* gain, int n, double sr) noexcept {
        groups = 0;
        for (int k = 0; k < 8; ++k) pr[k] = pi[k] = lr[k] = li[k] = 0;
        for (int k = 0; k < n; ++k) {
            // Re(c z) with c = -j g: a decaying sine (it starts at zero, as a struck beam's velocity does not).
            set(k, hz[k], 6.907755278982137 / t60[k], 0.0, -gain[k] * kTwoPi * hz[k], 0, 0, sr);
        }
    }
};

// A Hunt and Crossley contact (J. Appl. Mech. 42(2), 1975; for sound, Avanzini and Rocchesso, DAFx-01): a mass m
// meets a felt at speed v0; while it is compressed by x, F = k x^1.5 (1 + mu v) (never pulling), m v' = -F. Stepped
// per sample (semi-implicit Euler) only while it touches: about 1-3 ms.
struct Contact {
    float x = 0, v = 0, k = 0, mu = 0, invM = 0;
    bool on = false;
    void start(double speed, double stiffness, double damping, double mass) noexcept {
        x = 0, v = static_cast<float>(speed), k = static_cast<float>(stiffness), mu = static_cast<float>(damping);
        invM = static_cast<float>(1.0 / mass);
        on = speed > 0;
    }
    float step(float dt) noexcept {
        if (!on) return 0.0f;
        float F = 0.0f;
        if (x > 0.0f) {
            F = k * x * std::sqrt(x) * (1.0f + mu * v);
            if (F < 0.0f) F = 0.0f;
        }
        v -= F * invM * dt;
        x += v * dt;
        if (x <= 0.0f && v <= 0.0f) on = false;  // it left the felt
        return F;
    }
};

// The aftersound's T60 (s, at the fundamental) along the keyboard for Simulated, and the prompt sound's share of it
// (the coupled strings' in-phase decay). [Fact, measured 2026-11-20] The targets are the Salamander Grand's
// broadband decay, per octave (C..A at velocity 8, the median of four notes): 0.1-1 s after the peak (the prompt
// sound) and 2-6 s (the aftersound, octaves 1-4; higher up the recordings end in their noise floor first).
// [Fact, measured 2026-11-26] the top octave and a half (no dampers there) from Salamander's full samples (C7, F#7, A7,
// C8 at velocities 8 and 12, CC-BY 3.0): the fundamental's T60 over 0.3-1.95 s, band-passed at it, 2.7-2.9 s at C7,
// 3.0-3.1 at F#7, 2.1-2.3 at A7, 2.3-2.7 at C8; the model read 3.5, 2.0, 1.6 and 1.3 s there on the old 1.4 s at C8 (an
// A7 note was 64 dB down by 1 s, the recording 39): the points at 96-108 now set so the model reads them
// (`starling_treble_rings_as_recorded`: 2.7, 3.1, 2.2 and 2.5 s).
inline double simT60(double key) noexcept {
    static constexpr double kKey[] = {21, 30, 42, 54, 66, 78, 90, 96, 102, 105, 108};
    static constexpr double kT[] = {34, 31, 26, 17, 26, 14, 6.0, 3.0, 3.0, 2.4, 2.6};
    constexpr int kN = static_cast<int>(sizeof(kKey) / sizeof(kKey[0]));
    if (key <= kKey[0]) return kT[0];
    for (int i = 1; i < kN; ++i)
        if (key <= kKey[i]) {
            const double f = (key - kKey[i - 1]) / (kKey[i] - kKey[i - 1]);
            return kT[i - 1] * detPow(kT[i] / kT[i - 1], f);
        }
    return kT[kN - 1];
}
inline double simPrompt(double key) noexcept {  // the prompt T60 over the aftersound's
    static constexpr double kKey[] = {21, 30, 42, 54, 66, 78, 90, 108};
    static constexpr double kR[] = {0.5, 0.5, 0.30, 0.30, 0.11, 0.15, 0.45, 0.9};
    if (key <= kKey[0]) return kR[0];
    for (int i = 1; i < 8; ++i)
        if (key <= kKey[i]) return kR[i - 1] + (kR[i] - kR[i - 1]) * (key - kKey[i - 1]) / (kKey[i] - kKey[i - 1]);
    return kR[7];
}

// The dispersion allpasses' coefficient for `stages` first-order sections, fitted so the loop's partials 2..20
// (under 0.4 sr) follow f_n = n f1 sqrt((1 + B n^2) / (1 + B)): the loop's phase delay at each partial against
// the delay that partial needs, the error in cents, by golden-section search. One coefficient per key and tier
// from the B curve (never per partial). At prepare time only.
inline float fitDispersion(double f1, double B, int stages, double sr) noexcept {
    const double P = sr / f1, w1 = kTwoPi * f1 / sr;
    int top = static_cast<int>(0.4 * sr / f1);
    if (top > 20) top = 20;
    if (top < 2) return -0.05f;
    auto err = [&](double a) {
        const double d1 = allpassDelay(a, w1);
        double e = 0;
        for (int n = 2; n <= top; ++n) {
            const double want = P * (std::sqrt((1.0 + B) / (1.0 + B * n * n)) - 1.0);
            const double got = stages * (allpassDelay(a, n * w1 * std::sqrt((1.0 + B * n * n) / (1.0 + B))) - d1);
            const double c = (got - want) / (n * P);
            e += c * c;
        }
        return e;
    };
    double lo = -0.97, hi = -0.0001;
    for (int it = 0; it < 36; ++it) {
        const double a = hi - (hi - lo) * 0.6180339887, b = lo + (hi - lo) * 0.6180339887;
        if (err(a) < err(b)) hi = b;
        else lo = a;
    }
    return static_cast<float>(0.5 * (lo + hi));
}

// The longitudinal modes' frequency along the keyboard (Hz), for the High tier's phantom partials: steel's
// longitudinal wave (about 5,100 m/s) over a typical speaking length, lowered on the wound bass strings.
// [Assumption] a curve over the keys from typical string lengths, not a measurement (Conklin, JASA 105(1), 1999 and
// Bank and Sujbert, JASA 117(4), 2005 report such modes; neither was re-read).
inline double longitudinalHz(double key) noexcept {
    static constexpr double kKey[] = {21, 36, 48, 60, 72, 84, 96, 108};
    static constexpr double kHz[] = {700, 1150, 2100, 4100, 7700, 14000, 27000, 47000};
    if (key <= kKey[0]) return kHz[0];
    for (int i = 1; i < 8; ++i)
        if (key <= kKey[i]) return kHz[i - 1] * detPow(kHz[i] / kHz[i - 1], (key - kKey[i - 1]) / (kKey[i] - kKey[i - 1]));
    return kHz[7];
}

}  // namespace caw::timber::psim
