// Bittern's per-sample voice (its ranks' tables, speech, chiff and release), compiled with strict floating point so any block size gives the same bits.
#include "bittern_organ.h"

namespace caw::bittern {

void Organ::render(Voice& v, float* out, uint32_t n) noexcept {
    float acc[kControlFrames] = {}, flue[kControlFrames], reed[kControlFrames];
    // The speech, per sample (so any block size steps it the same way): flue and reed pipes, squared.
    for (uint32_t i = 0; i < n; ++i) {
        v.speak = std::min(1.0f, v.speak + v.speakStep);
        v.reedSpeak = std::min(1.0f, v.reedSpeak + v.reedStep);
        flue[i] = v.speak * v.speak, reed[i] = v.reedSpeak * v.reedSpeak;
    }
    constexpr int kShift = 32 - 11;  // kTableSize = 2^11
    constexpr float kFrac = 1.0f / static_cast<float>(1u << kShift);
    for (int k = 0; k < kStops; ++k) {
        const float g = level[k];
        if (g <= 0.0f) continue;
        const float* t = v.table[k];
        const uint32_t inc = static_cast<uint32_t>(v.inc[k] * pitchMod);
        uint32_t ph = v.phase[k];
        const float* sp = k == kTrumpet8 ? reed : flue;
        for (uint32_t i = 0; i < n; ++i) {
            const uint32_t at = ph >> kShift;
            const float f = static_cast<float>(ph & ((1u << kShift) - 1u)) * kFrac;
            acc[i] += (t[at] + (t[at + 1] - t[at]) * f) * g * sp[i];
            ph += inc;  // wraps at 2^32: a whole cycle
        }
        v.phase[k] = ph;
    }
    const float lm = levelMod * 0.12f;
    for (uint32_t i = 0; i < n; ++i) {
        // The chiff: a decaying noise through a state-variable band-pass near the 3rd harmonic.
        float c = 0;
        if (v.chiff > 1e-6f) {
            const float w = v.rng.next() * v.chiff;
            v.chiff *= v.chiffDecay;
            v.cLp += v.cF * v.cBp;
            const float hp = w - v.cLp - 0.7f * v.cBp;
            v.cBp += v.cF * hp;
            c = v.cBp;
        }
        if (v.relStep > 0) v.rel = std::max(0.0f, v.rel - v.relStep);
        out[i] = (acc[i] * lm + c) * v.rel;
    }
}

}  // namespace caw::bittern
