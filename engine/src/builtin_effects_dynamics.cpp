// The built-in dynamics (#173): compressor, look-ahead limiter, gate/expander and transient shaper.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <vector>

#include "caw/library/dynamics.hpp"
#include "caw/library/filter.hpp"

// Original code (C.A.W. is Apache-2.0). The compressor's soft knee is the textbook curve (Giannoulis, Massberg and
// Reiss, JAES 2012); the limiter is the classic look-ahead design (a sliding minimum of the gain each sample needs,
// an instant-attack release, then a moving average as long as the look-ahead, so the gain is down by the time
// the peak leaves the delay line).

namespace caw::fx {

namespace {

// The compressor's and limiter's fixed delay, in frames (5 ms at 48 kHz). A track's latency is declared once in
// its descriptor, so the look-ahead knob moves where the detector reads within it, never the delay itself.
constexpr uint32_t kLookaheadFrames = 240;
constexpr uint32_t kRing = 512;  // power of two above kLookaheadFrames + 1

float positive(double db) { return static_cast<float>(db < 0.0 ? -db : 0.0); }

// ---------- Compressor ----------

enum CompParam : uint32_t {
    kThreshold, kRatio, kKnee, kAttack, kRelease, kAutoRelease, kMakeup, kAutoMakeup, kMix, kLookahead, kDetect, kLink,
    kScHpf, kScListen, kSidechain, kCompCount
};
constexpr std::string_view kDetectModes[] = {"Peak", "RMS"};
// What the detector hears: the effect's own input, or the key another track sends it (its sidechain input).
constexpr std::string_view kSidechainSources[] = {"Internal", "External"};

const ParamTable& compParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("threshold", "Threshold", -18.0, -60.0, 0.0, "dB");
        p.expo("ratio", "Ratio", 4.0, 1.0, 20.0, ":1");
        p.num("knee", "Knee", 6.0, 0.0, 24.0, "dB");
        p.expo("attack", "Attack", 10.0, 0.05, 200.0, "ms");
        p.expo("release", "Release", 150.0, 5.0, 2000.0, "ms");
        p.pick("auto_release", "Auto release", 0.0, kOffOn);
        p.num("makeup", "Makeup", 0.0, -12.0, 24.0, "dB");
        p.pick("auto_makeup", "Auto makeup", 1.0, kOffOn);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("lookahead", "Look-ahead", 0.0, 0.0, 5.0, "ms").smoothingFrames = 0;
        p.pick("detect", "Detection", 0.0, kDetectModes);
        p.num("link", "Stereo link", 1.0, 0.0, 1.0);
        p.expo("sc_hpf", "Sidechain high-pass", 20.0, 20.0, 1000.0, "Hz");
        p.pick("sc_listen", "Sidechain listen", 0.0, kOffOn);
        p.pick("sidechain", "Sidechain", 0.0, kSidechainSources);
        return p;
    }();
    return t;
}
const ModuleDescriptor& compDescriptor() {
    static const ModuleDescriptor d =
        keyedEffectDescriptor("org.caw.compressor", "Compressor", compParams(), kLookaheadFrames, 0, false);
    return d;
}

class Compressor final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return compDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        rmsCoef_ = lib::timeCoefficient(0.01, sampleRate);
        sustainCoef_ = lib::timeCoefficient(0.4, sampleRate);
        return true;
    }
    void clearState() noexcept override {
        for (auto& c : ring_) for (float& v : c) v = 0.0f;
        for (auto& c : keyRing_) for (float& v : c) v = 0.0f;
        pos_ = 0;
        for (int c = 0; c < 2; ++c) {
            hpf_[c].clear();
            ms_[c] = 0.0;
            env_[c] = 0.0;
        }
        sustained_ = 0.0;
        grMax_ = grNow_ = 0.0;
        levelMax_ = 0.0;
    }
    uint64_t idleFrames() const noexcept override { return kLookaheadFrames + static_cast<uint64_t>(0.05 * rate()); }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        threshold_ = param(kThreshold, at);
        ratio_ = std::max(1.0, param(kRatio, at));
        knee_ = param(kKnee, at);
        attack_ = lib::timeCoefficient(param(kAttack, at) * 0.001, sr);
        double release = param(kRelease, at) * 0.001;
        if (on(kAutoRelease, at)) release *= 0.3 + 1.7 * sustained_;  // fast after a transient, slow when held down
        release_ = lib::timeCoefficient(release, sr);
        makeupDb_ = param(kMakeup, at);
        if (on(kAutoMakeup, at)) makeupDb_ -= 0.5 * lib::compressorGainDb(0.0, threshold_, ratio_, knee_);
                mix_ = std::clamp(param(kMix, at), 0.0, 1.0);
        lookahead_ = std::min<uint32_t>(kLookaheadFrames, static_cast<uint32_t>(param(kLookahead, at) * 0.001 * sr + 0.5));
        rms_ = choice(kDetect, at) == 1;
        link_ = std::clamp(param(kLink, at), 0.0, 1.0);
        const double hpf = param(kScHpf, at);
        useHpf_ = hpf > 20.5;
        for (auto& f : hpf_) f.set(hpf, 0.70710678118654752, sr);
        listen_ = on(kScListen, at);
        external_ = choice(kSidechain, at) == 1;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const uint32_t mask = kRing - 1;
        const uint32_t detectBack = kLookaheadFrames - lookahead_;
        const float* keyL = keyLeft();
        const float* keyR = keyRight();
        for (uint32_t i = 0; i < n; ++i) {
            ring_[0][pos_] = inL[i];
            ring_[1][pos_] = inR[i];
            keyRing_[0][pos_] = keyL ? keyL[i] : 0.0f;  // the key runs through the same look-ahead
            keyRing_[1][pos_] = keyR ? keyR[i] : 0.0f;
            const uint32_t d = (pos_ - detectBack) & mask, a = (pos_ - kLookaheadFrames) & mask;
            const float (*src)[kRing] = external_ ? keyRing_ : ring_;
            double sc[2] = {src[0][d], src[1][d]};
            double level[2];
            for (int c = 0; c < 2; ++c) {
                if (useHpf_) sc[c] = hpf_[c].highpass(sc[c]);
                if (rms_) {
                    ms_[c] = sc[c] * sc[c] + (ms_[c] - sc[c] * sc[c]) * rmsCoef_;
                    if (ms_[c] < 1e-30) ms_[c] = 0.0;
                    level[c] = std::sqrt(ms_[c] < 0.0 ? 0.0 : ms_[c]);
                } else {
                    level[c] = sc[c] < 0.0 ? -sc[c] : sc[c];
                }
            }
            const double most = std::max(level[0], level[1]);
            levelMax_ = std::max(levelMax_, most);
            double gain[2];
            const int channels = link_ >= 1.0 ? 1 : 2;
            for (int c = 0; c < channels; ++c) {
                const double lv = channels == 1 ? most : level[c] + (most - level[c]) * link_;
                const double target = lib::compressorGainDb(lib::gainToDb(lv, -200.0), threshold_, ratio_, knee_);
                const double coef = target < env_[c] ? attack_ : release_;
                env_[c] = target + (env_[c] - target) * coef;
                if (env_[c] - target < 1e-9 && target - env_[c] < 1e-9) env_[c] = target;  // settled: no subnormal creep
                if (env_[c] > -1e-9) env_[c] = 0.0;  // back to no reduction: no subnormal creep
                gain[c] = lib::dbToGain(env_[c] + makeupDb_);
            }
            if (channels == 1) env_[1] = env_[0], gain[1] = gain[0];
            const double gr = std::min(env_[0], env_[1]);
            grMax_ = std::min(grMax_, gr);
            grNow_ = gr;
            const double held = gr < -1.0 ? 1.0 : 0.0;
            sustained_ = held + (sustained_ - held) * sustainCoef_;
            if (sustained_ - held < 1e-12 && held - sustained_ < 1e-12) sustained_ = held;
            if (listen_) {
                outL[i] = static_cast<float>(sc[0]);
                outR[i] = static_cast<float>(sc[1]);
            } else {
                const double xl = ring_[0][a], xr = ring_[1][a];
                outL[i] = static_cast<float>(xl * (1.0 + (gain[0] - 1.0) * mix_));
                outR[i] = static_cast<float>(xr * (1.0 + (gain[1] - 1.0) * mix_));
            }
            pos_ = (pos_ + 1) & mask;
        }
    }

    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = positive(grMax_);
        out[3] = positive(grNow_);
        out[4] = static_cast<float>(lib::gainToDb(levelMax_));
        out[5] = static_cast<float>(threshold_);
        out[6] = static_cast<float>(ratio_);
        out[7] = static_cast<float>(knee_);
        out[8] = static_cast<float>(makeupDb_);
        out[9] = static_cast<float>(lookahead_ * 1000.0 / rate());
        out[10] = external_ ? 1.0f : 0.0f;  // the sidechain: 0 internal, 1 external (the key)
        grMax_ = 0.0;
        levelMax_ = 0.0;
        return 11;
    }

private:
    float ring_[2][kRing] = {};
    float keyRing_[2][kRing] = {};
    uint32_t pos_ = 0, lookahead_ = 0;
    lib::Svf hpf_[2];
    double ms_[2] = {}, env_[2] = {};
    bool external_ = false;
    double threshold_ = -18, ratio_ = 4, knee_ = 6, attack_ = 0, release_ = 0, makeupDb_ = 0;
    double mix_ = 1, link_ = 1, rmsCoef_ = 0, sustainCoef_ = 0, sustained_ = 0;
    double grMax_ = 0, grNow_ = 0, levelMax_ = 0;
    bool rms_ = false, useHpf_ = false, listen_ = false;
};

// ---------- Limiter ----------

enum LimParam : uint32_t { kLimGain, kCeiling, kLimRelease, kLimLookahead, kTruePeak, kLimCount };

const ParamTable& limParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("gain", "Gain", 0.0, 0.0, 24.0, "dB");
        p.num("ceiling", "Ceiling", -1.0, -24.0, 0.0, "dB");
        p.expo("release", "Release", 60.0, 1.0, 1000.0, "ms");
        p.expo("lookahead", "Look-ahead", 1.5, 0.1, 4.9, "ms").smoothingFrames = 0;
        p.pick("true_peak", "True peak", 1.0, kOffOn);
        return p;
    }();
    return t;
}
const ModuleDescriptor& limDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.limiter", "Limiter", limParams(), kLookaheadFrames, 0);
    return d;
}

class Limiter final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return limDescriptor(); }

protected:
    bool prepare(double, uint32_t) noexcept override {
        try {
            min_.prepare(kLookaheadFrames + 8);
        } catch (...) {
            return false;
        }
        return true;
    }
    void clearState() noexcept override {
        for (auto& c : ring_) for (float& v : c) v = 0.0f;
        for (double& v : box_) v = 1.0;
        pos_ = 0;
        boxPos_ = 0;
        sum_ = static_cast<double>(window_);
        held_ = 1.0;
        min_.clear();
        for (auto& t : tp_) t.clear();
        grMax_ = 0.0, grNow_ = 0.0;
        sinceExact_ = 0;
        gainNow_ = -1.0;
    }
    uint64_t idleFrames() const noexcept override { return kLookaheadFrames + static_cast<uint64_t>(0.01 * rate()); }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        gainTarget_ = lib::dbToGain(param(kLimGain, at));
        if (gainNow_ < 0.0) gainNow_ = gainTarget_;
        ceilingDb_ = param(kCeiling, at);
        ceiling_ = lib::dbToGain(ceilingDb_);
        release_ = lib::timeCoefficient(param(kLimRelease, at) * 0.001, sr);
        truePeak_ = on(kTruePeak, at);
        const uint32_t most = truePeak_ ? kLookaheadFrames - 4 : kLookaheadFrames;
        const uint32_t window = std::clamp<uint32_t>(static_cast<uint32_t>(param(kLimLookahead, at) * 0.001 * sr + 0.5), 1u, most);
        if (window != window_) {  // a new look-ahead: the moving average's sum over its new length
            window_ = window;
            resum();
        }
        // The detector reads the input this far back, so the averaged gain is fully down when a peak leaves the
        // delay: d = 241 - window for sample peaks, 237 - window with the true-peak estimate's 4-frame lag.
        detectBack_ = (truePeak_ ? kLookaheadFrames - 3 : kLookaheadFrames + 1) - window_;
        gainStep_ = (gainTarget_ - gainNow_) / kControlFrames;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const uint32_t mask = kRing - 1, boxMask = kBox - 1;
        for (uint32_t i = 0; i < n; ++i) {
            gainNow_ += gainStep_;
            ring_[0][pos_] = static_cast<float>(inL[i] * gainNow_);
            ring_[1][pos_] = static_cast<float>(inR[i] * gainNow_);
            const uint32_t d = (pos_ - detectBack_) & mask;
            double peak;
            if (truePeak_) {
                peak = std::max(tp_[0].process(ring_[0][d]), tp_[1].process(ring_[1][d]));
            } else {
                const double l = ring_[0][d], r = ring_[1][d];
                peak = std::max(l < 0 ? -l : l, r < 0 ? -r : r);
            }
            const double need = peak > ceiling_ ? ceiling_ / peak : 1.0;
            const double m = min_.push(need, window_);
            held_ = m < held_ ? m : m + (held_ - m) * release_;
            if (held_ - m < 1e-12) held_ = m;  // recovered: no subnormal creep
            // The moving average over `window_` frames.
            sum_ += held_ - box_[(boxPos_ - window_) & boxMask];
            box_[boxPos_] = held_;
            boxPos_ = (boxPos_ + 1) & boxMask;
            if (++sinceExact_ >= 4096) resum();  // keep the running sum from drifting
            double g = sum_ / window_;
            g = g > 1.0 ? 1.0 : g;
            const uint32_t a = (pos_ - kLookaheadFrames) & mask;
            const double gr = lib::gainToDb(g, -120.0);
            grMax_ = std::min(grMax_, gr);
            grNow_ = gr;
            // The sample-peak ceiling holds exactly, whatever the estimate missed.
            const double l = std::clamp(ring_[0][a] * g, -ceiling_, ceiling_), r = std::clamp(ring_[1][a] * g, -ceiling_, ceiling_);
            outL[i] = static_cast<float>(l);
            outR[i] = static_cast<float>(r);
            pos_ = (pos_ + 1) & mask;
        }
    }

    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = positive(grMax_);
        out[3] = positive(grNow_);
        out[4] = static_cast<float>(ceilingDb_);
        out[5] = static_cast<float>(lib::gainToDb(gainTarget_));
        out[6] = truePeak_ ? 1.0f : 0.0f;
        grMax_ = 0.0;
        return 7;
    }

private:
    static constexpr uint32_t kBox = 256;  // power of two above the longest window
    void resum() noexcept {
        sum_ = 0.0;
        for (uint32_t k = 1; k <= window_; ++k) sum_ += box_[(boxPos_ - k) & (kBox - 1)];
        sinceExact_ = 0;
    }
    float ring_[2][kRing] = {};
    double box_[kBox] = {};
    uint32_t pos_ = 0, boxPos_ = 0, window_ = 72, detectBack_ = 0, sinceExact_ = 0;
    double sum_ = 72.0, held_ = 1.0;
    lib::SlidingMinimum min_;
    lib::TruePeak tp_[2];
    double gainTarget_ = 1, gainNow_ = -1, gainStep_ = 0, ceiling_ = 0.89, ceilingDb_ = -1, release_ = 0;
    double grMax_ = 0, grNow_ = 0;
    bool truePeak_ = true;
};

// ---------- Gate / expander ----------

enum GateParam : uint32_t { kGThreshold, kGRange, kGRatio, kGAttack, kGHold, kGRelease, kGKnee, kGScHpf, kGSidechain, kGateCount };

const ParamTable& gateParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("threshold", "Threshold", -40.0, -80.0, 0.0, "dB");
        p.num("range", "Range", -80.0, -80.0, 0.0, "dB");
        p.expo("ratio", "Ratio", 10.0, 1.0, 50.0, ":1");
        p.expo("attack", "Attack", 0.5, 0.01, 50.0, "ms");
        p.num("hold", "Hold", 30.0, 0.0, 500.0, "ms");
        p.expo("release", "Release", 120.0, 5.0, 2000.0, "ms");
        p.num("knee", "Knee", 3.0, 0.0, 12.0, "dB");
        p.expo("sc_hpf", "Sidechain high-pass", 20.0, 20.0, 2000.0, "Hz");
        p.pick("sidechain", "Sidechain", 0.0, kSidechainSources);
        return p;
    }();
    return t;
}
const ModuleDescriptor& gateDescriptor() {
    static const ModuleDescriptor d = keyedEffectDescriptor("org.caw.gate", "Gate", gateParams(), 0, 0, false);
    return d;
}

class Gate final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return gateDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        detector_.setCoefficients(lib::timeCoefficient(0.0001, sampleRate), lib::timeCoefficient(0.02, sampleRate));
        return true;
    }
    void clearState() noexcept override {
        detector_.clear();
        for (auto& f : hpf_) f.clear();
        env_ = range_;
        holdLeft_ = 0;
        grMax_ = 0, levelMax_ = 0;
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        threshold_ = param(kGThreshold, at);
        range_ = param(kGRange, at);
        ratio_ = param(kGRatio, at);
        knee_ = param(kGKnee, at);
        attack_ = lib::timeCoefficient(param(kGAttack, at) * 0.001, sr);
        release_ = lib::timeCoefficient(param(kGRelease, at) * 0.001, sr);
        hold_ = static_cast<uint32_t>(param(kGHold, at) * 0.001 * sr);
        const double hpf = param(kGScHpf, at);
        useHpf_ = hpf > 20.5;
        for (auto& f : hpf_) f.set(hpf, 0.70710678118654752, sr);
        external_ = choice(kGSidechain, at) == 1;
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        // External: the key opens and closes the gate (a hi-hat gated by the kick); with no key it stays shut.
        const float* keyL = external_ ? keyLeft() : nullptr;
        const float* keyR = external_ ? keyRight() : nullptr;
        for (uint32_t i = 0; i < n; ++i) {
            double l = external_ ? (keyL ? keyL[i] : 0.0) : inL[i], r = external_ ? (keyR ? keyR[i] : 0.0) : inR[i];
            if (useHpf_) l = hpf_[0].highpass(l), r = hpf_[1].highpass(r);
            const double level = detector_.process(std::max(l < 0 ? -l : l, r < 0 ? -r : r));
            levelMax_ = std::max(levelMax_, level);
            const double levelDb = lib::gainToDb(level, -200.0);
            const double target = lib::expanderGainDb(levelDb, threshold_, ratio_, knee_, range_);
            if (levelDb > threshold_) holdLeft_ = hold_;
            if (target > env_) env_ = target + (env_ - target) * attack_;  // opening
            else if (holdLeft_ > 0) --holdLeft_;                          // held open a while
            else env_ = target + (env_ - target) * release_;              // closing
            if (env_ - target < 1e-9 && target - env_ < 1e-9) env_ = target;  // settled: no subnormal creep
            const double g = lib::dbToGain(env_);
            grMax_ = std::min(grMax_, env_);
            outL[i] = static_cast<float>(inL[i] * g);
            outR[i] = static_cast<float>(inR[i] * g);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = positive(env_);
        out[3] = positive(grMax_);
        out[4] = static_cast<float>(lib::gainToDb(levelMax_));
        out[5] = static_cast<float>(threshold_);
        out[6] = env_ > -1.0 ? 1.0f : 0.0f;
        out[7] = external_ ? 1.0f : 0.0f;  // the sidechain: 0 internal, 1 external (the key)
        grMax_ = 0.0;
        levelMax_ = 0.0;
        return 8;
    }

private:
    lib::EnvelopeFollower detector_;
    lib::Svf hpf_[2];
    double threshold_ = -40, range_ = -80, ratio_ = 10, knee_ = 3, attack_ = 0, release_ = 0, env_ = -80;
    double grMax_ = 0, levelMax_ = 0;
    uint32_t hold_ = 0, holdLeft_ = 0;
    bool useHpf_ = false, external_ = false;
};

// ---------- Transient shaper ----------

enum TransientParam : uint32_t { kTAttack, kTSustain, kTOutput, kTMix, kTransientCount };

const ParamTable& transientParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("attack", "Attack", 0.0, -1.0, 1.0);
        p.num("sustain", "Sustain", 0.0, -1.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& transientDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.transient", "Transient shaper", transientParams(), 0, 0);
    return d;
}

// Two pairs of level followers on the louder side: a fast against a slow attack finds the onsets (the fast one
// is ahead), a fast against a slow release finds the tails (the slow one stays up). Their ratios in dB, up to
// 24 dB, scaled by `attack` and `sustain` (+-1), are the gain change.
class TransientShaper final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return transientDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        fastA_.setCoefficients(lib::timeCoefficient(0.0005, sr), lib::timeCoefficient(0.1, sr));
        slowA_.setCoefficients(lib::timeCoefficient(0.02, sr), lib::timeCoefficient(0.1, sr));
        fastS_.setCoefficients(lib::timeCoefficient(0.001, sr), lib::timeCoefficient(0.02, sr));
        slowS_.setCoefficients(lib::timeCoefficient(0.001, sr), lib::timeCoefficient(0.3, sr));
        return true;
    }
    void clearState() noexcept override {
        fastA_.clear(), slowA_.clear(), fastS_.clear(), slowS_.clear();
        now_ = boost_ = cut_ = 0.0;
        first_ = true;
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>(0.05 * rate()); }
    void control(uint32_t at) noexcept override {
        attack_ = std::clamp(param(kTAttack, at), -1.0, 1.0);
        sustain_ = std::clamp(param(kTSustain, at), -1.0, 1.0);
        const double out = lib::dbToGain(param(kTOutput, at)), mix = std::clamp(param(kTMix, at), 0.0, 1.0);
        if (first_) out0_ = out, mix0_ = mix;
        outStep_ = (out - out0_) / kControlFrames;
        mixStep_ = (mix - mix0_) / kControlFrames;
        first_ = false;
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double l = inL[i], r = inR[i];
            const double x = std::max(l < 0 ? -l : l, r < 0 ? -r : r);
            const double fa = fastA_.process(x), sa = slowA_.process(x), fs = fastS_.process(x), ss = slowS_.process(x);
            double db = 0.0;
            if (attack_ != 0.0 && fa > 1e-9) db += attack_ * std::min(24.0, lib::gainToDb(fa / std::max(sa, 1e-12), 0.0));
            if (sustain_ != 0.0 && ss > 1e-9) db += sustain_ * std::min(24.0, lib::gainToDb(ss / std::max(fs, 1e-12), 0.0));
            db = std::clamp(db, -24.0, 24.0);
            now_ = db;
            boost_ = std::max(boost_, db);
            cut_ = std::min(cut_, db);
            out0_ += outStep_;
            mix0_ += mixStep_;
            const double g = (1.0 + (lib::dbToGain(db) - 1.0) * mix0_) * out0_;
            outL[i] = static_cast<float>(l * g);
            outR[i] = static_cast<float>(r * g);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(now_);
        out[3] = static_cast<float>(boost_);
        out[4] = static_cast<float>(-cut_);
        boost_ = cut_ = 0.0;
        return 5;
    }

private:
    lib::EnvelopeFollower fastA_, slowA_, fastS_, slowS_;
    double attack_ = 0, sustain_ = 0, out0_ = 1, mix0_ = 1, outStep_ = 0, mixStep_ = 0, now_ = 0, boost_ = 0, cut_ = 0;
    bool first_ = true;
};

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

}  // namespace

void registerDynamics(ModuleRegistry& registry) {
    registry.add(compDescriptor(), &make<Compressor>);
    registry.add(limDescriptor(), &make<Limiter>);
    registry.add(gateDescriptor(), &make<Gate>);
    registry.add(transientDescriptor(), &make<TransientShaper>);
}

}  // namespace caw::fx
