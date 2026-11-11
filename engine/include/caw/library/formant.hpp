// C.A.W. Library: a vowel formant filter (three band-passes morphing A, E, I, O, U); header-only, allocation-free.
#pragma once

#include "filter.hpp"

namespace caw::lib {

// A voice's vowels are mostly its first three formants: resonances of the vocal tract that stay put while
// the pitch moves. This filter runs three state-variable band-passes in parallel at a vowel's formants and
// sums them, weighted. `vowel` 0..1 morphs A (0), E (0.25), I (0.5), O (0.75) and U (1), moving each formant
// in a straight line between two neighbours; `shift` scales every formant (1: as listed, 2: an octave up, a
// smaller "throat"); `q` sets how sharp they are (about 4 soft .. 20 whistling).
//
// [Assumption] The formant frequencies are rounded textbook values for an adult voice (in the region of the
// classic Peterson and Barney 1952 averages, not re-checked against the paper): they only need to sound like
// the vowels, not match a measurement.
//
// The first three formants (Hz) of A, E, I, O and U, in that order.
inline constexpr double kVowelFormantsHz[5][3] = {
    {730.0, 1090.0, 2440.0},  // A as in "father"
    {530.0, 1840.0, 2480.0},  // E as in "bed"
    {270.0, 2290.0, 3010.0},  // I as in "beet"
    {570.0, 840.0, 2410.0},   // O as in "bought"
    {300.0, 870.0, 2240.0},   // U as in "boot"
};

// Cost: set() up to three tans (only for formants that moved); process() three SVF steps.
class FormantFilter {
public:
    void set(double vowel, double shift, double q, double sampleRate) noexcept {
        const auto& kHz = kVowelFormantsHz;
        double v = finiteOr0(vowel);
        v = (v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v)) * 4.0;
        const int k = v >= 4.0 ? 3 : static_cast<int>(v);
        const double mix = v - k;
        double s = finiteOr0(shift);
        s = s < 0.25 ? 0.25 : (s > 4.0 ? 4.0 : s);
        for (int f = 0; f < 3; ++f) {
            const double hz = (kHz[k][f] + (kHz[k + 1][f] - kHz[k][f]) * mix) * s;
            band_[f].set(hz, q, sampleRate);
        }
        k_ = 1.0 / (q < 0.1 ? 0.1 : (q > 40.0 ? 40.0 : q));
    }
    double process(double x) noexcept {
        // Each band-pass output times k peaks at unity at its formant; F2 and F3 are quieter, as in speech.
        return k_ * (band_[0].process(x).band + 0.7 * band_[1].process(x).band + 0.45 * band_[2].process(x).band);
    }
    void clear() noexcept {
        for (Svf& b : band_) b.clear();
    }

private:
    Svf band_[3];
    double k_ = 0.1;
};

}  // namespace caw::lib
