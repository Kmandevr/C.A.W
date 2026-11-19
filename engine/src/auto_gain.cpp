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
    fadeFrames_ = fadeFrames(sr);
    reset();
}

void AutoGainMatcher::clearAnalysis() noexcept {
    for (auto& c : st_)
        for (State& s : c) s = {};
    eIn_ = eOut_ = 0.0;
    targetDb_ = trimDb_ = 0.0;
    gain_ = 1.0;
    step_ = 0.0;
    left_ = 0;
}

void AutoGainMatcher::reset() noexcept {
    clearAnalysis();
    fadeFrom_ = applied_ = 1.0;
    fadeLeft_ = 0;
    on_ = false;
}

void AutoGainMatcher::restart() noexcept {
    clearAnalysis();
    fadeFrom_ = applied_;
    fadeLeft_ = applied_ != 1.0 ? fadeFrames_ : 0;
    on_ = true;
}

void AutoGainMatcher::release() noexcept {
    fadeFrom_ = applied_;
    fadeLeft_ = applied_ != 1.0 ? fadeFrames_ : 0;
    on_ = false;
}

double AutoGainMatcher::frame(double inL, double inR, double outL, double outR) noexcept {
    double g = 1.0;
    if (on_) {
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
        const double il = run(high_, st_[0][1], run(shelf_, st_[0][0], inL));
        const double ir = run(high_, st_[1][1], run(shelf_, st_[1][0], inR));
        const double ol = run(high_, st_[2][1], run(shelf_, st_[2][0], outL));
        const double orr = run(high_, st_[3][1], run(shelf_, st_[3][0], outR));
        const double xi = il * il + ir * ir, xo = ol * ol + orr * orr;
        eIn_ = xi + (eIn_ - xi) * keep_;
        eOut_ = xo + (eOut_ - xo) * keep_;
        if (eIn_ < 1e-30) eIn_ = 0.0;  // silence: no subnormal creep
        if (eOut_ < 1e-30) eOut_ = 0.0;
        gain_ += step_;
        if (left_ == 0) gain_ = lib::dbToGain(trimDb_);  // the ramp's end exactly (no drift from the steps)
        g = gain_;
    }
    if (fadeLeft_ > 0) {  // from the gain heard before (a restart, a release) to this one, in a straight line
        --fadeLeft_;
        g += (fadeFrom_ - g) * (static_cast<double>(fadeLeft_) / static_cast<double>(fadeFrames_));
    }
    applied_ = g;
    return g;
}

void AutoGainMatcher::process(const float* inL, const float* inR, float* outL, float* outR, uint32_t m) noexcept {
    for (uint32_t i = 0; i < m; ++i) {
        const double g = frame(inL[i], inR[i], outL[i], outR[i]);
        outL[i] = static_cast<float>(outL[i] * g);
        outR[i] = static_cast<float>(outR[i] * g);
    }
}

bool AutoGainMatcher::settled() const noexcept {
    if (fadeLeft_ > 0 || eIn_ != 0.0 || eOut_ != 0.0 || trimDb_ != targetDb_ || step_ != 0.0 || applied_ != gain_)
        return false;
    for (const auto& c : st_)
        for (const State& s : c)
            if (s.z1 != 0.0 || s.z2 != 0.0) return false;
    return true;
}

void AutoGainMatcher::advanceSilence(uint32_t m) noexcept {
    // Settled (no fade, the filters and energies at 0, the trim at its held target): a frame of silence then moves
    // only the grid; otherwise each frame is worked out as process() would.
    if (on_ && settled() && gain_ == lib::dbToGain(trimDb_)) {
        left_ = (left_ + kGrid - m % kGrid) % kGrid;
        return;
    }
    for (uint32_t i = 0; i < m; ++i) frame(0.0, 0.0, 0.0, 0.0);
}

}  // namespace caw
