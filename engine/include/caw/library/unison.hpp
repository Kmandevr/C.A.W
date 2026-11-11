// C.A.W. Library: a unison layout (detune with a power curve, stereo spread, centre blend, stack intervals); header-only.
#pragma once

#include <cmath>
#include <cstdint>

#include "../detmath.hpp"

namespace caw::lib {

// How a unison stack is laid out (original code; the controls are the ones a modern wavetable synth offers):
//
// `voices` copies of one oscillator sit at positions x evenly from -1 (the lowest) to +1 (the highest), 0 in
// the middle for an odd count. Each copy plays `detune` semitones times curve(x) away from the note, so the
// outermost copies are at exactly +-detune. `power` bends the curve: 0 spaces the copies evenly in pitch;
// toward +1 they gather near the centre pitch (a thick centre with a few wide copies, |x|^4 at +1); toward
// -1 they crowd out toward the outer pitches (|x|^0.25 at -1).
//
// `spread` pans them: each copy's pan is spread * |x|, the two copies of each mirror pair on opposite sides,
// and the side alternates from one pair to the next, so low and high copies land on both sides (a centred
// patch stays centred: the left and right mixes are mirror images). At spread 0 every copy is centred.
//
// `blend` weighs the centre copy (the middle one, or the middle two for an even count) against the rest: 0
// plays only the centre, 0.5 all at the same level, 1 only the others. The levels are then scaled so their
// squares sum to 1: the stack's loudness hardly changes with the voice count or the blend.
//
// `stack` adds intervals, copy by copy in pitch order, so each layer spans the whole detune range: Octave
// puts every second copy an octave up, TwoOctaves cycles 0, +12, +24, Fifth every second copy up a fifth,
// Major and Minor cycle the chord's root, third and fifth, and Harmonics puts copy k (from 0) on harmonic k + 1
// of the note (k mod 16).
enum class UnisonStack : int { Off, Octave, TwoOctaves, Fifth, Major, Minor, Harmonics };
inline constexpr int kUnisonStackCount = 7;
inline constexpr int kMaxUnisonVoices = 16;

struct UnisonSettings {
    int voices = 1;           // 1..16
    double detune = 0.0;      // semitones of the outermost copies from the note (>= 0)
    double power = 0.0;       // -1..1: the detune curve (0 even)
    double spread = 0.0;      // 0..1: stereo width
    double blend = 0.5;       // 0..1: centre copy (0) .. even (0.5) .. the others (1)
    UnisonStack stack = UnisonStack::Off;
    bool operator==(const UnisonSettings&) const = default;
};

struct UnisonVoice {
    double semitones = 0.0;  // offset from the note: detune plus the stack's interval
    double pan = 0.0;        // -1 (left) .. +1 (right)
    double gain = 1.0;       // level (the squares of all copies sum to 1)
};

// The semitones above the note of harmonic h (1..16): 12 log2(h).
inline double harmonicSemitones(int h) noexcept {
    return h <= 1 ? 0.0 : 12.0 * detLog(static_cast<double>(h)) / 0.69314718055994530942;
}

// The interval stack mode `stack` gives the copy at `index` (0 = lowest).
inline double unisonStackSemitones(UnisonStack stack, int index) noexcept {
    switch (stack) {
        case UnisonStack::Octave: return index % 2 ? 12.0 : 0.0;
        case UnisonStack::TwoOctaves: return 12.0 * (index % 3);
        case UnisonStack::Fifth: return index % 2 ? 7.0 : 0.0;
        case UnisonStack::Major: return index % 3 == 0 ? 0.0 : (index % 3 == 1 ? 4.0 : 7.0);
        case UnisonStack::Minor: return index % 3 == 0 ? 0.0 : (index % 3 == 1 ? 3.0 : 7.0);
        case UnisonStack::Harmonics: return harmonicSemitones(index % 16 + 1);
        default: return 0.0;
    }
}

// Fills out[0 .. voices) (voices clamped to 1..16) and returns the count. Costs a detPow per copy: call it
// when a setting changes, not every sample.
inline int unisonLayout(const UnisonSettings& s, UnisonVoice* out) noexcept {
    const int n = s.voices < 1 ? 1 : (s.voices > kMaxUnisonVoices ? kMaxUnisonVoices : s.voices);
    const double detune = finiteOr0(s.detune) < 0.0 ? 0.0 : finiteOr0(s.detune);
    double power = finiteOr0(s.power);
    power = power < -1.0 ? -1.0 : (power > 1.0 ? 1.0 : power);
    double spread = finiteOr0(s.spread);
    spread = spread < 0.0 ? 0.0 : (spread > 1.0 ? 1.0 : spread);
    double blend = finiteOr0(s.blend);
    blend = blend < 0.0 ? 0.0 : (blend > 1.0 ? 1.0 : blend);
    const double exponent = detPow(4.0, power);  // 0.25 .. 4
    const double centreGain = blend < 0.5 ? 1.0 : 2.0 * (1.0 - blend);
    const double otherGain = blend > 0.5 ? 1.0 : 2.0 * blend;
    double sumSquares = 0.0;
    for (int i = 0; i < n; ++i) {
        const double x = n == 1 ? 0.0 : 2.0 * i / (n - 1) - 1.0;
        const double a = x < 0.0 ? -x : x;
        const double curve = a == 0.0 ? 0.0 : (a == 1.0 || power == 0.0 ? a : detPow(a, exponent));
        UnisonVoice& v = out[i];
        v.semitones = (x < 0.0 ? -curve : curve) * detune + unisonStackSemitones(s.stack, i);
        // Mirror pair k (k = 0 the outermost): the lower copy goes left for even k, right for odd k.
        const int pair = i < n - 1 - i ? i : n - 1 - i;
        const bool lower = i < n - 1 - i;
        const double side = (pair % 2 == 0) == lower ? -1.0 : 1.0;
        v.pan = i == n - 1 - i ? 0.0 : side * spread * a;
        const bool centre = n == 1 || i == (n - 1) / 2 || i == n / 2;
        v.gain = n == 1 ? 1.0 : (centre ? centreGain : otherGain);
        sumSquares += v.gain * v.gain;
    }
    const double scale = sumSquares > 0.0 ? 1.0 / std::sqrt(sumSquares) : 0.0;
    for (int i = 0; i < n; ++i) out[i].gain *= scale;
    return n;
}

}  // namespace caw::lib
