// Per-slot auto gain (auto_gain.h): K-weighted energies of a slot's input and output, and the trim that matches them.
#include "auto_gain.h"

#include <cmath>

#include "caw/library/fastmath.hpp"
#include "meters.h"

namespace caw {

void AutoGainMatcher::prepare(double sampleRate) noexcept {
    const double sr = sampleRate > 0 ? sampleRate : 48000.0;
    LoudnessMeter::Biquad s, h;
    LoudnessMeter::kWeighting(sr, s, h);
    shelf_ = {s.b0, s.b1, s.b2, s.a1, s.a2};
    high_ = {h.b0, h.b1, h.b2, h.a1, h.a2};
    keep_ = std::exp(-1.0 / (kWindowSeconds * sr));
    trimKeep_ = std::exp(-static_cast<double>(kGrid) / (kTrimSeconds * sr));
    floor_ = std::pow(10.0, (kFloorLufs + 0.691) / 10.0);
    reset();
}

void AutoGainMatcher::reset() noexcept {
    for (auto& c : st_)
        for (State& s : c) s = {};
    eIn_ = eOut_ = 0.0;
    targetDb_ = trimDb_ = 0.0;
    gain_ = 1.0;
    step_ = 0.0;
    left_ = 0;
}

void AutoGainMatcher::process(const float* inL, const float* inR, float* outL, float* outR, uint32_t m) noexcept {
    for (uint32_t i = 0; i < m; ++i) {
        if (left_ == 0) {  // a grid point: a new target from the energies so far, and the ramp to its gain
            if (eIn_ > floor_ && eOut_ > floor_) {
                const double db = 0.5 * lib::gainToDb(eIn_ / eOut_, -400.0);  // 10 log10 of the energy ratio
                targetDb_ = db > kMaxTrimDb ? kMaxTrimDb : (db < -kMaxTrimDb ? -kMaxTrimDb : db);
            }
            trimDb_ = targetDb_ + (trimDb_ - targetDb_) * trimKeep_;
            if (trimDb_ - targetDb_ < 1e-9 && targetDb_ - trimDb_ < 1e-9) trimDb_ = targetDb_;
            step_ = (lib::dbToGain(trimDb_) - gain_) / static_cast<double>(kGrid);
            left_ = kGrid;
        }
        --left_;
        const double il = run(high_, st_[0][1], run(shelf_, st_[0][0], inL[i]));
        const double ir = run(high_, st_[1][1], run(shelf_, st_[1][0], inR[i]));
        const double ol = run(high_, st_[2][1], run(shelf_, st_[2][0], outL[i]));
        const double orr = run(high_, st_[3][1], run(shelf_, st_[3][0], outR[i]));
        const double xi = il * il + ir * ir, xo = ol * ol + orr * orr;
        eIn_ = xi + (eIn_ - xi) * keep_;
        eOut_ = xo + (eOut_ - xo) * keep_;
        if (eIn_ < 1e-30) eIn_ = 0.0;  // silence: no subnormal creep
        if (eOut_ < 1e-30) eOut_ = 0.0;
        gain_ += step_;
        if (left_ == 0) gain_ = lib::dbToGain(trimDb_);  // the ramp's end exactly (no drift from the steps)
        outL[i] = static_cast<float>(outL[i] * gain_);
        outR[i] = static_cast<float>(outR[i] * gain_);
    }
}

}  // namespace caw
