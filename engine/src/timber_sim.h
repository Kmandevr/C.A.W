// Timber's 1.1.2 simulation parts shared by the non-piano models: a Hunt-Crossley contact, a pad or key click pulse, and the elasto-plastic friction's helpers.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "timber_dsp.h"

// The Simulated paths are kept out of line where they sit beside a 1.1.0 loop, so the compiler's choices for that
// loop (the engine builds with -fassociative-math) stay as they were and 1.1.0 presets render bit for bit.
#if defined(_MSC_VER)
#define CAW_TIMBER_NOINLINE __declspec(noinline)
#define CAW_TIMBER_INLINE __forceinline
#else
#define CAW_TIMBER_NOINLINE __attribute__((noinline))
#define CAW_TIMBER_INLINE inline __attribute__((always_inline))
#endif

namespace caw::timber {

// A fixed delay's read, worked out once (a block's delays move only at control points): the same arithmetic as
// Line::frac(d), so the same bits, without its float-to-integer step each sample.
struct Tap {
    uint32_t i = 2;
    float f = 0;
    void set(float d) noexcept {
        i = static_cast<uint32_t>(d);
        f = d - static_cast<float>(i);
    }
    float read(const Line& l) const noexcept {
        const float a = l.buf[(l.w - i) & l.mask], b = l.buf[(l.w - i - 1) & l.mask];
        return a + (b - a) * f;
    }
};

// The appended `sim` choice of every model but the piano (0 Classic: 1.1.0 bit for bit; 1 Simulated).
inline constexpr double kSimDefault = 0.0;
// The appended `noises` knob: the mechanical noises' level, 0 none, about 0.3 a natural listening position (the
// default: subtle), 1 close-miked (owner, 2026-11-20).
inline constexpr double kNoisesDefault = 0.3;

// A Hunt-Crossley contact (Hunt and Crossley, J. Appl. Mech. 42(2), 1975: F = k x^a + lambda x^a x', the damping
// proportional to the compression's power, so the force is continuous at touch and release): a mass `m` (the
// mallet head, hammer or tongue) moving at `vel` toward a surface whose displacement the caller gives each sample.
// Units are normalised: the caller scales k from the contact time it wants. Stepped only while it touches.
struct Contact {
    float y = 0, vel = 0;    // the head's position and velocity (toward +)
    float k = 1, lambda = 0, invMass = 1, dt = 1;
    float x = 0;             // the last compression (0: apart)
    bool touching = false, done = true;
    uint32_t left = 0;       // samples it may still take (a soft head can bounce back once; then it is caught)
    // Starts a strike: the head at the surface, moving at `v0`, with a contact time near `tc` seconds at v0 = 1
    // (Hertz's law for a = 1.5: tc = 3.21 (m / k)^0.4 v0^-0.2, so k = m (3.21 / tc)^2.5 for m = 1).
    void strike(float v0, double tc, double damping, double sr) noexcept {
        y = 0, vel = v0, x = 0;
        dt = static_cast<float>(1.0 / sr);
        const double t = clampd(tc, 2e-5, 0.05);
        k = static_cast<float>(detPow(3.21 / t, 2.5));
        lambda = static_cast<float>(damping);
        invMass = 1.0f;
        touching = true, done = false;
        left = static_cast<uint32_t>(std::min(0.04 * sr, 12.0 * t * sr + 32.0));
    }
    // One sample against a surface at `surface` (its displacement, + away from the head): the force on the surface.
    float step(float surface) noexcept {
        if (done) return 0.0f;
        const float comp = y - surface;
        float f = 0;
        if (comp > 0) {
            const float xa = comp * std::sqrt(comp);  // x^1.5
            const float rate = (comp - x) / dt;
            f = std::max(0.0f, k * xa * (1.0f + lambda * rate));
            x = comp;
        } else {
            x = 0;
        }
        vel -= f * invMass * dt;
        y += vel * dt;
        if (left) --left;
        if (left == 0 || (vel < 0 && comp <= 0 && y < surface - 1e-4f)) done = true, touching = false;
        return f;
    }
};

// A pad, key or valve click: a half-sine force pulse of `len` samples (a pad closing on a tone hole, a key
// bottoming), added where its model injects it (into a bore, at the output).
struct Click {
    uint32_t left = 0, len = 1;
    float amp = 0;
    void start(float a, double seconds, double sr) noexcept {
        len = std::max<uint32_t>(2, static_cast<uint32_t>(seconds * sr));
        left = len, amp = a;
    }
    float next() noexcept {
        if (!left) return 0.0f;
        --left;
        const float ph = static_cast<float>(len - left) / static_cast<float>(len);
        // sin(pi ph) by the [3/2] Pade of tanh's shape is not a sine; a cheap parabola 4 ph (1 - ph) is (within 6 %).
        return amp * 4.0f * ph * (1.0f - ph);
    }
};

// The elasto-plastic friction's adhesion map alpha(v, z) (Dupont, Hayward, Armstrong and Altpeter, IEEE TAC 47(5),
// 2002; for bowing Serafin, Avanzini and Rocchesso, SMAC 2003, eq. (4)-(5)), with the paper's half-sine transition
// replaced by a smoothstep (the paper: "significant deviations from these curves can be tolerated"): 0 below the
// breakaway zba, 1 at the steady state zss, 0 when v and z disagree in sign.
inline float adhesion(float v, float z, float zba, float zss) noexcept {
    if ((v > 0) != (z > 0)) return 0.0f;
    const float az = std::fabs(z), as = std::fabs(zss);
    if (az <= zba) return 0.0f;
    if (az >= as) return 1.0f;
    const float t = (az - zba) / std::max(1e-12f, as - zba);
    return t * t * (3.0f - 2.0f * t);
}

}  // namespace caw::timber
