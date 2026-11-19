// The Compressor's "Duck" variant (1.0.8): a ducker and leveller that follows a key's level (or its own input's) with RMS, Peak or ISP detection.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <span>
#include <vector>

#include "caw/library/dynamics.hpp"
#include "fx_merged.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0), C.A.W's own design with the controls the owner listed for Kilohearts
// Compactor (threshold, amount, attack, hold, release, a sidechain, RMS/Peak/ISP detection; 2026-11-18 brief, no
// code of it seen).
// The detector hears the key (Sidechain: External, another track's sound) or the effect's own input (Internal: a
// leveller), linked across both sides. Above the threshold the gain falls by `amount` times the level's excess in
// dB: amount 1 holds the level at the threshold (a limiter's static curve, infinite ratio), 0.5 halves the excess
// (2:1), 0 does nothing. The reduction moves toward that target with the attack while it deepens, waits `hold` once
// it stops deepening, then recovers with the release. No look-ahead, so no latency.
// Detection: RMS is a 10 ms mean square (the Compressor's), Peak the larger side's |x| each sample, ISP the
// inter-sample (true) peak: the samples and three points between each pair (4x, the samples about 4 frames late),
// interpolated by an 8-tap
// Hann-windowed sinc per point, each normalised to unity at DC (within 0.1 dB to 12 kHz and 0.55 dB at 16 kHz at
// 48 kHz). Half the work of BS.1770's 48-tap meter filter, enough
// for a detector.

namespace caw::fx {

namespace {

enum DuckParam : uint32_t { kThreshold, kAmount, kAttack, kHold, kRelease, kDetection, kOutput, kMix, kSidechain, kCount };
constexpr std::string_view kDetections[] = {"RMS", "Peak", "ISP"};
constexpr std::string_view kSources[] = {"Internal", "External"};

const ParamTable& duckParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("threshold", "Threshold", -20.0, -60.0, 0.0, "dB");
        p.num("amount", "Amount", 0.5, 0.0, 1.0);
        p.expo("attack", "Attack", 5.0, 0.05, 200.0, "ms");
        p.num("hold", "Hold", 30.0, 0.0, 500.0, "ms");
        p.expo("release", "Release", 150.0, 5.0, 2000.0, "ms");
        p.pick("detection", "Detection", 0.0, kDetections);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.pick("sidechain", "Sidechain", 0.0, kSources);
        return p;
    }();
    return t;
}

// Its own table as a "legacy" descriptor (never registered): legacyVariantDescriptor appends `variant`.
const ModuleDescriptor& duckBaseDescriptor() {
    static const ModuleDescriptor d = keyedEffectDescriptor("org.caw.compressor", "Compressor", duckParams(), 0, 0, false);
    return d;
}

class Duck : public EffectBase {
public:
    explicit Duck(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        rmsCoef_ = lib::timeCoefficient(0.01, sampleRate);
        // ISP's interpolators: window sample 3 itself (phase 0) and the points d = 1/4, 1/2, 3/4 after it, from
        // window samples 0..7 (tap_[phase][tap]).
        for (int k = 0; k < kTaps; ++k) tap_[0][k] = k == 3 ? 1.0f : 0.0f;
        for (int p = 1; p < 4; ++p) {
            const double d = 0.25 * p;
            double sum = 0.0, tap[kTaps];
            for (int k = 0; k < kTaps; ++k) {
                const double x = d - (k - 3);
                const double sinc = std::sin(kPi * x) / (kPi * x);  // x is never 0 (d is fractional)
                const double t = x / (kTaps / 2);
                tap[k] = sinc * (0.5 + 0.5 * std::cos(kPi * t));
                sum += tap[k];
            }
            for (int k = 0; k < kTaps; ++k) tap_[p][k] = static_cast<float>(tap[k] / sum);
        }
        return true;
    }
    void clearState() noexcept override {
        ms_ = 0.0;
        env_ = 0.0;
        holdLeft_ = 0;
        for (auto& h : win_)
            for (float& v : h) v = 0.0f;
        grMax_ = grNow_ = 0.0;
        levelMax_ = keyMax_ = 0.0;
        outRamp_.reset();
        mixRamp_.reset();
    }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        threshold_ = param(kThreshold, at);
        thresholdLin_ = lib::dbToGain(threshold_);
        thresholdSq_ = thresholdLin_ * thresholdLin_;
        amount_ = std::clamp(param(kAmount, at), 0.0, 1.0);
        const double attack = param(kAttack, at) * 0.001;
        if (attack != attackFor_ || sr != rateFor_) attackFor_ = attack, attack_ = lib::timeCoefficient(attack, sr);
        const double release = param(kRelease, at) * 0.001;
        if (release != releaseFor_ || sr != rateFor_) releaseFor_ = release, release_ = lib::timeCoefficient(release, sr);
        rateFor_ = sr;
        holdFrames_ = static_cast<uint32_t>(std::max(0.0, param(kHold, at)) * 0.001 * sr + 0.5);
        detection_ = std::clamp(choice(kDetection, at), 0, 2);
        // Output and Mix ramp in a straight line over the grid step to their values here (a knob's or a lane's
        // per-frame values read every 16 frames would step: zipper noise).
        const double out = param(kOutput, at);
        if (out != outDb_) outDb_ = out, outGain_ = lib::dbToGain(out);
        outRamp_.set(outGain_, kControlFrames);
        mixRamp_.set(std::clamp(param(kMix, at), 0.0, 1.0), kControlFrames);
        external_ = choice(kSidechain, at) == 1;
    }

    // The detector's level of one frame, linear (RMS: its mean square, returned squared; `squared` says so).
    double detect(double l, double r, bool& squared) noexcept {
        if (detection_ == 0) {
            const double x = 0.5 * (l * l + r * r);
            ms_ = x + (ms_ - x) * rmsCoef_;
            if (ms_ < 1e-30) ms_ = 0.0;
            squared = true;
            return ms_;
        }
        squared = false;
        const double al = l < 0 ? -l : l, ar = r < 0 ? -r : r;
        if (detection_ == 1) return al > ar ? al : ar;
        return isp_[ispAt_++];  // ISP: worked out for the whole run() by truePeaks()
    }

    // ISP for run()'s n frames (at most kControlFrames) of the detector's source: each frame's sample and the three
    // points after it, interpolated from a window of 8 (the last 7 frames kept from before), the larger side's.
    // Frame by frame independent, so it vectorizes across the frames.
    void truePeaks(const float* l, const float* r, uint32_t n) noexcept {
        // Always all kControlFrames frames (those past n read zeros and are unused): every frame then takes the same
        // code path (no remainder loop summing in another order), so the bits don't depend on how blocks split.
        for (uint32_t i = 0; i < kControlFrames; ++i) {
            win_[0][kTaps - 1 + i] = i < n ? l[i] : 0.0f;
            win_[1][kTaps - 1 + i] = i < n ? r[i] : 0.0f;
        }
        float most[kControlFrames];
        for (uint32_t i = 0; i < kControlFrames; ++i) most[i] = 0.0f;
        for (int c = 0; c < 2; ++c) {
            const float* w = win_[c];
            for (int p = 0; p < 4; ++p) {
                const float* t = tap_[p];
                for (uint32_t i = 0; i < kControlFrames; ++i) {
                    float y = 0.0f;
                    for (int k = 0; k < kTaps; ++k) y += t[k] * w[i + k];
                    y = y < 0 ? -y : y;
                    most[i] = y > most[i] ? y : most[i];
                }
            }
        }
        for (uint32_t i = 0; i < n; ++i) isp_[i] = most[i];
        for (int c = 0; c < 2; ++c)
            for (int k = 0; k < kTaps - 1; ++k) win_[c][k] = win_[c][n + k];
        ispAt_ = 0;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const float* keyL = keyLeft();
        const float* keyR = keyRight();
        // The key when one is asked for and given (the chain gives silence when no track keys it); else the input.
        const bool key = external_ && keyL && keyR;
        if (detection_ == 2) truePeaks(key ? keyL : inL, key ? keyR : inR, n);
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = inL[i], xr = inR[i];
            const double sl = key ? keyL[i] : xl, sr = key ? keyR[i] : xr;
            if (key) {
                const double k = std::max(sl < 0 ? -sl : sl, sr < 0 ? -sr : sr);
                keyMax_ = k > keyMax_ ? k : keyMax_;
            }
            bool squared = false;
            const double lv = detect(sl, sr, squared);
            double target = 0.0;
            if (squared) {
                levelMax_ = std::max(levelMax_, lv);  // squared: taken back in fillDisplay
                if (lv > thresholdSq_) target = -amount_ * (0.5 * lib::gainToDb(lv, -400.0) - threshold_);
            } else {
                levelMax_ = std::max(levelMax_, lv * lv);
                if (lv > thresholdLin_) target = -amount_ * (lib::gainToDb(lv, -200.0) - threshold_);
            }
            if (target < env_) {  // deepening: attack, and the hold starts again
                env_ = target + (env_ - target) * attack_;
                holdLeft_ = holdFrames_;
            } else if (target == env_ && target < 0.0) {  // held down at its target: the hold waits from here
                holdLeft_ = holdFrames_;
            } else if (holdLeft_ > 0) {
                --holdLeft_;
            } else {
                env_ = target + (env_ - target) * release_;
            }
            if (env_ - target < 1e-9 && target - env_ < 1e-9) env_ = target;  // settled (no subnormal creep)
            if (env_ > -1e-9) env_ = 0.0;
            if (env_ != gainDb_) gainDb_ = env_, gainOf_ = lib::dbToGain(env_);
            grNow_ = env_;
            grMax_ = std::min(grMax_, env_);
            const double g = outRamp_.next() * (1.0 + (gainOf_ - 1.0) * mixRamp_.next());
            outL[i] = static_cast<float>(xl * g);
            outR[i] = static_cast<float>(xr * g);
        }
    }

    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(0.5 * lib::gainToDb(levelMax_, -240.0));  // the detector's level, dB
        out[2] = std::max(out[2], -120.0f);
        out[3] = external_ ? static_cast<float>(lib::gainToDb(keyMax_)) : -120.0f;  // the key's own peak
        out[4] = static_cast<float>(grNow_ < 0 ? -grNow_ : 0.0);
        out[5] = static_cast<float>(grMax_ < 0 ? -grMax_ : 0.0);
        out[6] = static_cast<float>(threshold_);
        out[7] = static_cast<float>(amount_);
        out[8] = static_cast<float>(detection_);
        out[9] = external_ ? 1.0f : 0.0f;
        grMax_ = 0.0;
        levelMax_ = keyMax_ = 0.0;
        return 10;
    }

private:
    const ModuleDescriptor& d_;
    double ms_ = 0, env_ = 0;
    uint32_t holdLeft_ = 0, holdFrames_ = 0;
    static constexpr int kTaps = 8;
    static constexpr double kPi = 3.14159265358979323846;
    float tap_[4][kTaps] = {};
    float win_[2][kTaps - 1 + kControlFrames] = {};  // ISP: the last 7 frames, then run()'s
    float isp_[kControlFrames] = {};                 // ISP: run()'s levels
    uint32_t ispAt_ = 0;
    int detection_ = 0;
    bool external_ = false;
    double threshold_ = -20, thresholdLin_ = 0.1, thresholdSq_ = 0.01, amount_ = 0.5;
    double attack_ = 0, release_ = 0, attackFor_ = -1, releaseFor_ = -1, rateFor_ = -1, rmsCoef_ = 0;
    double outDb_ = 1e300, outGain_ = 1.0;
    Ramp outRamp_, mixRamp_;  // the output gain and the mix, ramped over each grid step
    double gainDb_ = 0.0, gainOf_ = 1.0;  // dbToGain(gainDb_) last worked out
    double grNow_ = 0, grMax_ = 0, levelMax_ = 0, keyMax_ = 0;
};

// Its presets (job-named; `variant` 4). A keyed one says so: the app turns Sidechain to External with a key.
const std::vector<BuiltinPreset>& duckPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Kick duck bass", "Key it from the kick: the bass dips under each hit and is back before the next",
         {{"threshold", -30}, {"amount", 0.8}, {"attack", 0.5}, {"hold", 20}, {"release", 110}, {"detection", 1}, {"sidechain", 1}, {"variant", 4}}},
        {"Voice over music", "Key it from the voice: the music steps back while someone talks",
         {{"threshold", -40}, {"amount", 0.5}, {"attack", 15}, {"hold", 250}, {"release", 600}, {"detection", 0}, {"sidechain", 1}, {"variant", 4}}},
        {"Pad pump", "Key it from the kick: a deep, slow-recovering pump on pads and chords",
         {{"threshold", -36}, {"amount", 1}, {"attack", 1}, {"hold", 0}, {"release", 220}, {"detection", 1}, {"sidechain", 1}, {"variant", 4}}},
        {"Snare makes room", "Key it from the snare: a short dip so the crack comes through",
         {{"threshold", -28}, {"amount", 0.6}, {"attack", 0.2}, {"hold", 10}, {"release", 70}, {"detection", 2}, {"sidechain", 1}, {"variant", 4}}},
        {"Gentle leveller", "Its own input: evens out a part that comes and goes, slowly",
         {{"threshold", -24}, {"amount", 0.35}, {"attack", 30}, {"hold", 100}, {"release", 800}, {"detection", 0}, {"variant", 4}}},
        {"Vocal rider", "Its own input: holds a voice's loud words near the threshold",
         {{"threshold", -20}, {"amount", 0.6}, {"attack", 10}, {"hold", 50}, {"release", 300}, {"detection", 0}, {"output", 2}, {"variant", 4}}},
        {"Peak catcher", "Its own input: true-peak detection pulls fast peaks to the threshold",
         {{"threshold", -6}, {"amount", 1}, {"attack", 0.05}, {"hold", 5}, {"release", 60}, {"detection", 2}, {"variant", 4}}},
        {"Bus glue", "Its own input: a light, even hold on a group or the mix",
         {{"threshold", -18}, {"amount", 0.25}, {"attack", 20}, {"hold", 30}, {"release", 250}, {"detection", 0}, {"variant", 4}}},
        {"Parallel duck", "Key it from the kick: half the ducked signal under the dry, a gentle groove",
         {{"threshold", -32}, {"amount", 1}, {"attack", 0.5}, {"hold", 15}, {"release", 140}, {"detection", 1}, {"mix", 0.5}, {"sidechain", 1}, {"variant", 4}}},
    };
    return p;
}

}  // namespace

const ModuleDescriptor& duckVariantDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d =
        legacyVariantDescriptor(duckBaseDescriptor(), "org.caw.compressor", "Compressor", labels, index);
    return d;
}

ModuleProcessor* makeDuckAs(const ModuleDescriptor& variant) noexcept {
    return new (std::nothrow) Duck(variant);
}

std::span<const BuiltinPreset> delayModePresets();   // builtin_fx_delay_modes.cpp
std::span<const BuiltinPreset> reverbModePresets();  // builtin_fx_reverb_modes.cpp
std::span<const BuiltinPreset> driveModePresets();   // builtin_fx_drive_modes.cpp
std::span<const BuiltinPreset> bitwisePresets();     // builtin_fx_bits_bitwise.cpp
std::span<const BuiltinPreset> cabPresets();         // builtin_fx_cab.cpp

std::span<const BuiltinPreset> newVariantPresets(std::string_view id) {
    if (id == "org.caw.compressor") return duckPresets();
    if (id == "org.caw.delay") return delayModePresets();
    if (id == "org.caw.reverb") return reverbModePresets();
    if (id == "org.caw.drive") return driveModePresets();
    if (id == "org.caw.bits") return bitwisePresets();
    if (id == "org.caw.convolver") return cabPresets();
    return {};
}

}  // namespace caw::fx
