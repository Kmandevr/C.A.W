// The built-in dynamics (#173): compressor, look-ahead limiter, gate/expander and transient shaper.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <new>
#include <vector>

#include "caw/library/dynamics.hpp"
#include "caw/library/filter.hpp"
#include "fx_merged.h"
#include "fx_sidechain.h"
#include "meters.h"
#include "sample_time.h"
#include "simd_fx.h"
#include "stereo_pair.h"

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
constexpr std::string_view kDetectModes[] = {"Peak", "RMS", "ISP"};  // ISP: 1.1.0 (Talon's Down)
// Talon's Down (1.1.0) appends these after `variant` (index kCompCount), before talon_layout: the key's low-pass,
// the character and the output. At their defaults (20 kHz, Clean, 0 dB) the old path runs unchanged, bit for bit.
enum CompExtra : uint32_t { kScLpf = kCompCount + 1, kCharacter, kOutput, kCompExtraEnd };
constexpr std::string_view kCharacterModes[] = {"Clean", "Warm"};
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
const ParamTable& compExtraParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.expo("sc_lpf", "Sidechain low-pass", 20000.0, 500.0, 20000.0, "Hz");
        p.pick("character", "Character", 0.0, kCharacterModes);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        return p;
    }();
    return t;
}
const ModuleDescriptor& compDescriptor() {
    static const ModuleDescriptor d =
        keyedEffectDescriptor("org.caw.compressor", "Compressor", compParams(), kLookaheadFrames, 0, false);
    return d;
}

class Compressor : public EffectBase {
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
        for (auto& f : lpf_) f.clear();
        for (auto& t : tp_) t.clear();
        outRamp_.reset();
    }
    uint64_t idleFrames() const noexcept override { return kLookaheadFrames + static_cast<uint64_t>(0.05 * rate()); }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        threshold_ = param(kThreshold, at);
        ratio_ = std::max(1.0, param(kRatio, at));
        knee_ = param(kKnee, at);
        // Each coefficient (an exp) worked out again only when its time or the rate moved.
        const double attack = param(kAttack, at) * 0.001;
        if (attack != attackFor_ || sr != rateFor_) attackFor_ = attack, attack_ = lib::timeCoefficient(attack, sr);
        double release = param(kRelease, at) * 0.001;
        if (on(kAutoRelease, at)) release *= 0.3 + 1.7 * sustained_;  // fast after a transient, slow when held down
        if (release != releaseFor_ || sr != rateFor_) releaseFor_ = release, release_ = lib::timeCoefficient(release, sr);
        rateFor_ = sr;
        makeupDb_ = param(kMakeup, at);
        if (on(kAutoMakeup, at)) makeupDb_ -= 0.5 * lib::compressorGainDb(0.0, threshold_, ratio_, knee_);
        // A level under this is below the knee by more than 0.01 dB, where the curve is exactly 0 dB: no log needed.
        const double kneeStart = threshold_ - 0.5 * (knee_ < 0.0 ? 0.0 : knee_) - 0.01;
        if (kneeStart != kneeStartDb_) kneeStartDb_ = kneeStart, quietBelow_ = lib::dbToGain(kneeStart);
                mix_ = std::clamp(param(kMix, at), 0.0, 1.0);
        lookahead_ = std::min<uint32_t>(kLookaheadFrames, static_cast<uint32_t>(sampletime::roundFrames(param(kLookahead, at) * 0.001, sr)));
        rms_ = choice(kDetect, at) == 1;
        link_ = std::clamp(param(kLink, at), 0.0, 1.0);
        const double hpf = param(kScHpf, at);
        useHpf_ = hpf > 20.5;
        for (auto& f : hpf_) f.set(hpf, 0.70710678118654752, sr);
        listen_ = on(kScListen, at);
        external_ = choice(kSidechain, at) == 1;
        isp_ = choice(kDetect, at) == 2;
        // The extras exist only under Talon's Down descriptor (an instance under the old one reads its defaults).
        const bool extras = descriptor().parameterCount >= kCompExtraEnd;
        const double lpf = extras ? param(kScLpf, at) : 20000.0;
        useLpf_ = lpf < 19500.0 && lpf < 0.49 * sr;
        if (useLpf_) for (auto& f : lpf_) f.set(lpf, 0.70710678118654752, sr);
        warm_ = extras && choice(kCharacter, at) == 1;
        const double out = extras ? param(kOutput, at) : 0.0;
        if (out != outDb_) outDb_ = out, outGain_ = lib::dbToGain(out);
        outRamp_.set(outGain_, kControlFrames);
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        // In passes over the run (each sample's arithmetic as frame by frame, in its order; speed phase 6): the
        // rings and the detector's reads; each side's level; the static curve, which has no state, two samples at
        // a time (its log as two-wide vectors, stereo_pair.h); the envelope and the gains, sample by sample; the
        // output. A ring entry written in this run is read in it only from 240 or more frames on, so writing all of
        // them first reads what frame by frame did.
        const uint32_t mask = kRing - 1;
        const uint32_t detectBack = kLookaheadFrames - lookahead_;
        const float* keyL = keyLeft();
        const float* keyR = keyRight();
        for (uint32_t i = 0; i < n; ++i) {
            const uint32_t at = (pos_ + i) & mask;
            ring_[0][at] = inL[i];
            ring_[1][at] = inR[i];
            keyRing_[0][at] = keyL ? keyL[i] : 0.0f;  // the key runs through the same look-ahead
            keyRing_[1][at] = keyR ? keyR[i] : 0.0f;
        }
        const float (*src)[kRing] = external_ ? keyRing_ : ring_;
        double sc[2][kControlFrames], level[2][kControlFrames], most[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) {
            const uint32_t d = (pos_ + i - detectBack) & mask;
            sc[0][i] = src[0][d];
            sc[1][i] = src[1][d];
        }
        for (int c = 0; c < 2; ++c) {
            if (useHpf_)
                for (uint32_t i = 0; i < n; ++i) sc[c][i] = hpf_[c].highpass(sc[c][i]);
            if (useLpf_)
                for (uint32_t i = 0; i < n; ++i) sc[c][i] = lpf_[c].lowpass(sc[c][i]);
            if (isp_) {
                for (uint32_t i = 0; i < n; ++i) level[c][i] = tp_[c].process(sc[c][i]);
            } else if (rms_) {
                for (uint32_t i = 0; i < n; ++i) {
                    const double x = sc[c][i];
                    ms_[c] = x * x + (ms_[c] - x * x) * rmsCoef_;
                    if (ms_[c] < 1e-30) ms_[c] = 0.0;
                    level[c][i] = std::sqrt(ms_[c] < 0.0 ? 0.0 : ms_[c]);
                }
            } else {
                for (uint32_t i = 0; i < n; ++i) level[c][i] = sc[c][i] < 0.0 ? -sc[c][i] : sc[c][i];
            }
        }
        for (uint32_t i = 0; i < n; ++i) {
            most[i] = std::max(level[0][i], level[1][i]);
            levelMax_ = std::max(levelMax_, most[i]);
        }
        const int channels = link_ >= 1.0 ? 1 : 2;
        double target[2][kControlFrames];
        for (int c = 0; c < channels; ++c) {
            double* lv = target[c];  // the level, then (in place) the curve's gain change
            if (channels == 1) std::copy(most, most + n, lv);
            else
                for (uint32_t i = 0; i < n; ++i) lv[i] = level[c][i] + (most[i] - level[c][i]) * link_;
            curve(lv, n);
        }
        double gain[2][kControlFrames];
        for (uint32_t i = 0; i < n; ++i) {
            for (int c = 0; c < channels; ++c) {
                const double t = target[c][i];
                const double coef = t < env_[c] ? attack_ : release_;
                env_[c] = t + (env_[c] - t) * coef;
                if (env_[c] - t < 1e-9 && t - env_[c] < 1e-9) env_[c] = t;  // settled: no subnormal creep
                if (env_[c] > -1e-9) env_[c] = 0.0;  // back to no reduction: no subnormal creep
                const double db = env_[c] + makeupDb_;  // the same dB as last sample (no reduction, say): the same gain
                if (db != gainDb_[c]) gainDb_[c] = db, gainOf_[c] = lib::dbToGain(db);
                gain[c][i] = gainOf_[c];
            }
            if (channels == 1) env_[1] = env_[0], gain[1][i] = gain[0][i];
            const double gr = std::min(env_[0], env_[1]);
            grMax_ = std::min(grMax_, gr);
            grNow_ = gr;
            const double held = gr < -1.0 ? 1.0 : 0.0;
            sustained_ = held + (sustained_ - held) * sustainCoef_;
            if (sustained_ - held < 1e-12 && held - sustained_ < 1e-12) sustained_ = held;
        }
        if (listen_) {
            for (uint32_t i = 0; i < n; ++i) {
                outL[i] = static_cast<float>(sc[0][i]);
                outR[i] = static_cast<float>(sc[1][i]);
            }
        } else if (!warm_ && outRamp_.value == 1.0 && outRamp_.step == 0.0) {  // the old path
            for (uint32_t i = 0; i < n; ++i) {
                const uint32_t a = (pos_ + i - kLookaheadFrames) & mask;
                const double xl = ring_[0][a], xr = ring_[1][a];
                outL[i] = static_cast<float>(xl * (1.0 + (gain[0][i] - 1.0) * mix_));
                outR[i] = static_cast<float>(xr * (1.0 + (gain[1][i] - 1.0) * mix_));
            }
        } else {  // Down's character and output (1.1.0)
            for (uint32_t i = 0; i < n; ++i) {
                const uint32_t a = (pos_ + i - kLookaheadFrames) & mask;
                const double xl = ring_[0][a], xr = ring_[1][a];
                double wl = xl * gain[0][i], wr = xr * gain[1][i];
                if (warm_) wl = lib::tanhApprox(wl), wr = lib::tanhApprox(wr);
                const double o = outRamp_.next();
                outL[i] = static_cast<float>(o * (xl + (wl - xl) * mix_));
                outR[i] = static_cast<float>(o * (xr + (wr - xr) * mix_));
            }
        }
        pos_ = (pos_ + n) & mask;
    }

    // The static curve's gain change in dB for each level of x[0..n), in place: 0 below quietBelow_ (no log), else
    // compressorGainDb(gainToDb(level, -200)). Two at a time: gainToDb's log as fastLogNormalPair and the curve's
    // selects lane by lane, for levels in the log's normal range; a pair with any other level (0 under a quietBelow_
    // of 0, a NaN, an infinity) is worked out one sample at a time.
    void curve(double* x, uint32_t n) const noexcept {
        const auto one = [&](double lv) noexcept {
            return lv < quietBelow_ ? 0.0 : lib::compressorGainDb(lib::gainToDb(lv, -200.0), threshold_, ratio_, knee_);
        };
        bool loud = false;  // any level at or above quietBelow_ (or a NaN)
        for (uint32_t i = 0; i < n; ++i) loud |= !(x[i] < quietBelow_);
        if (!loud) {  // the usual run below the knee: no log at all
            for (uint32_t i = 0; i < n; ++i) x[i] = 0.0;
            return;
        }
        uint32_t i = 0;
#if defined(__GNUC__)
        const double r = ratio_ < 1.0 ? 1.0 : ratio_, w = knee_ < 0.0 ? 0.0 : knee_;
        const double slope = 1.0 / r - 1.0;  // compressorGainDb's, from the same operands
        const Pair quiet = splat(quietBelow_), floor = splat(-200.0), thr = splat(threshold_), wv = splat(w),
                   halfW = splat(0.5 * w), twoW = splat(2.0 * w), sl = splat(slope), zero = splat(0.0);
        for (; i + 2 <= n; i += 2) {
            const Pair lv = pairOf(x[i], x[i + 1]);
            const auto normal = (lv >= splat(2.2250738585072014e-308)) & (lv <= splat(1.7976931348623157e308));
            const auto quietLane = lv < quiet;
            if ((quietLane[0] & quietLane[1]) != 0) {  // both below the knee
                x[i] = x[i + 1] = 0.0;
                continue;
            }
            const auto other = ~quietLane & ~normal;  // a level the pair form does not cover (a NaN among them)
            if ((other[0] | other[1]) != 0) {
                x[i] = one(x[i]), x[i + 1] = one(x[i + 1]);
                continue;
            }
            Pair db = fastLogNormalPair(lv) * 8.6858896380650366;  // gainToDb: 20 / ln(10)
            db = db < floor ? floor : db;
            const Pair over = db - thr;
            const Pair t = over + halfW;
            const Pair knee = sl * t * t / twoW;
            Pair g = splat(2.0) * over < wv ? knee : sl * over;
            g = splat(2.0) * over <= -wv ? zero : g;
            g = quietLane ? zero : g;
            x[i] = lane(g, 0), x[i + 1] = lane(g, 1);
        }
#endif
        for (; i < n; ++i) x[i] = one(x[i]);
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
    double attackFor_ = -1.0, releaseFor_ = -1.0, rateFor_ = -1.0;  // control: the times attack_, release_ are for
    double kneeStartDb_ = 1e300, quietBelow_ = 0.0;     // control: below quietBelow_ (linear) the curve gives 0 dB
    double gainDb_[2] = {1e300, 1e300}, gainOf_[2] = {1.0, 1.0};  // run: dbToGain(gainDb_) last worked out
    double mix_ = 1, link_ = 1, rmsCoef_ = 0, sustainCoef_ = 0, sustained_ = 0;
    double grMax_ = 0, grNow_ = 0, levelMax_ = 0;
    bool rms_ = false, useHpf_ = false, listen_ = false;
    // Talon's Down (1.1.0): the key's low-pass, ISP detection, the character and the output.
    lib::Svf lpf_[2];
    lib::TruePeak tp_[2];
    Ramp outRamp_;
    double outDb_ = 0.0, outGain_ = 1.0;
    bool useLpf_ = false, isp_ = false, warm_ = false;
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
// The loudness target (1.1.0), appended after the merged Limiter's `variant`: off by default, and only a readout (a
// ceiling, not auto gain): the display shows the output's short-term and integrated loudness and how far each is
// from the target. Not automatable (nothing heard depends on them).
const ParamTable& limTargetParams() {
    static const ParamTable t = [] {
        ParamTable p;
        ParameterDescriptor& on = p.pick("target_on", "Loudness target", 0.0, kOffOn);
        on.automatable = on.modulatable = on.midiMappable = false;
        ParameterDescriptor& lufs = p.num("target", "Target", -14.0, -30.0, -5.0, "LUFS");
        lufs.automatable = lufs.modulatable = lufs.midiMappable = false;
        return p;
    }();
    return t;
}

const ModuleDescriptor& limDescriptor() {
    static const ModuleDescriptor d = withDomains(effectDescriptor("org.caw.limiter", "Limiter", limParams(), kLookaheadFrames, 0),
                                              kDomainWhole);  // the ceiling is the whole signal's
    return d;
}

class Limiter : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return limDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        try {
            min_.prepare(kLookaheadFrames + 8);
            // The loudness target's meter (about 100 KB: its gating histogram): only where the descriptor has the
            // target and something can read it (an export shows nothing).
            targetOnK_ = targetK_ = kNoParam;
            const ModuleDescriptor& d = descriptor();
            for (uint32_t k = 0; k < d.parameterCount; ++k) {
                if (d.parameters[k].id == "target_on") targetOnK_ = k;
                else if (d.parameters[k].id == "target") targetK_ = k;
            }
            if (targetOnK_ != kNoParam && targetK_ != kNoParam && !offlineRender()) {
                if (!meter_) meter_ = std::make_unique<LoudnessMeter>();
                meter_->measureTruePeak(false);  // the limiter's own detector has the peaks
                meter_->prepare(sr);
            }
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
        tp_.clear();
        grMax_ = 0.0, grNow_ = 0.0;
        gMin_ = gLast_ = 1.0;
        sinceExact_ = 0;
        gainNow_ = -1.0;
        if (meter_) meter_->requestReset();
    }
    uint64_t idleFrames() const noexcept override { return kLookaheadFrames + static_cast<uint64_t>(0.01 * rate()); }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        // Each gain and coefficient (an exp) worked out again only when its knob or the rate moved (2026-11-27: the
        // same values; a wake costs a compare).
        const double gainDb = param(kLimGain, at), releaseS = param(kLimRelease, at) * 0.001;
        if (gainDb != gainDbFor_) gainDbFor_ = gainDb, gainTarget_ = lib::dbToGain(gainDb);
        if (gainNow_ < 0.0) gainNow_ = gainTarget_;
        const double ceilingDb = param(kCeiling, at);
        ceilingDb_ = ceilingDb;
        if (ceilingDb != ceilingFor_) ceilingFor_ = ceilingDb, ceiling_ = lib::dbToGain(ceilingDb);
        if (releaseS != releaseFor_ || sr != rateFor_) releaseFor_ = releaseS, rateFor_ = sr, release_ = lib::timeCoefficient(releaseS, sr);
        truePeak_ = on(kTruePeak, at);
        const uint32_t most = truePeak_ ? kLookaheadFrames - 4 : kLookaheadFrames;
        const uint32_t window = std::clamp<uint32_t>(static_cast<uint32_t>(sampletime::roundFrames(param(kLimLookahead, at) * 0.001, sr)), 1u, most);
        if (window != window_) {  // a new look-ahead: the moving average's sum over its new length
            window_ = window;
            resum();
        }
        // The detector reads the input this far back, so the averaged gain is fully down when a peak leaves the
        // delay: d = 241 - window for sample peaks, 237 - window with the true-peak estimate's 4-frame lag.
        detectBack_ = (truePeak_ ? kLookaheadFrames - 3 : kLookaheadFrames + 1) - window_;
        gainStep_ = (gainTarget_ - gainNow_) / kControlFrames;
        if (meter_) {  // the loudness target: integrated from when it turns on, and again at each Play
            const bool on = this->on(targetOnK_, at);
            double beat;
            const bool playing = beatAt(at, beat);
            if ((on && !targetOn_) || (playing && !playing_)) meter_->requestReset();
            targetOn_.store(on, std::memory_order_relaxed);
            playing_ = playing;
            targetLufs_.store(static_cast<float>(param(targetK_, at)), std::memory_order_relaxed);
        }
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
                peak = tp_.process(ring_[0][d], ring_[1][d]);  // both sides' estimates in one Pair, the larger
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
            gMin_ = g < gMin_ ? g : gMin_;  // the display's dB is worked out once a run, below
            gLast_ = g;
            // The sample-peak ceiling holds exactly, whatever the estimate missed.
            const double l = std::clamp(ring_[0][a] * g, -ceiling_, ceiling_), r = std::clamp(ring_[1][a] * g, -ceiling_, ceiling_);
            outL[i] = static_cast<float>(l);
            outR[i] = static_cast<float>(r);
            pos_ = (pos_ + 1) & mask;
        }
        // The gain reduction shown (display only): its dB from the run's last and smallest gain, not per sample
        // (gainToDb rises with its gain, so the smallest gain is the most reduction).
        if (n) {
            grNow_ = lib::gainToDb(gLast_, -120.0);
            grMax_ = std::min(grMax_, lib::gainToDb(gMin_, -120.0));
            gMin_ = 1.0;
        }
        if (meter_ && targetOn_.load(std::memory_order_relaxed)) meter_->process(outL, outR, static_cast<int>(n));
    }

    // [7..12] (1.1.0, the loudness target): on (1/0), the target (LUFS), the output's short-term and integrated
    // loudness (LUFS; -200 while unmeasured or off) and each one's distance from the target (LU, + louder; -200 likewise).
    // The loudness is read here, off the audio thread (LoudnessMeter::read: its integrated value is worked out now).
    uint32_t readDisplay(float* out, uint32_t max) const noexcept override {
        const uint32_t n = EffectBase::readDisplay(out, max);
        if (n < 13 || !meter_ || !targetOn_.load(std::memory_order_relaxed)) return n;
        const LoudnessMeter::Reading r = meter_->read();
        const float target = targetLufs_.load(std::memory_order_relaxed);
        out[9] = r.shortTerm;
        out[10] = r.integrated;
        out[11] = r.shortTerm > kMeterNone ? r.shortTerm - target : kMeterNone;
        out[12] = r.integrated > kMeterNone ? r.integrated - target : kMeterNone;
        return n;
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
        if (!meter_) return 7;  // no target (the old id, or an export)
        out[7] = targetOn_.load(std::memory_order_relaxed) ? 1.0f : 0.0f;
        out[8] = targetLufs_.load(std::memory_order_relaxed);
        for (int k = 9; k < 13; ++k) out[k] = kMeterNone;  // readDisplay fills them
        return 13;
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
    fxsimd::TruePeakPair tp_;
    double gMin_ = 1.0, gLast_ = 1.0;  // this run's smallest and last gain (the display's reduction)
    double gainDbFor_ = std::numeric_limits<double>::quiet_NaN(), ceilingFor_ = std::numeric_limits<double>::quiet_NaN(), releaseFor_ = -1.0, rateFor_ = -1.0;  // what the cached values are for
    double gainTarget_ = 1, gainNow_ = -1, gainStep_ = 0, ceiling_ = 0.89, ceilingDb_ = -1, release_ = 0;
    double grMax_ = 0, grNow_ = 0;
    bool truePeak_ = true;
    static constexpr uint32_t kNoParam = ~0u;
    uint32_t targetOnK_ = kNoParam, targetK_ = kNoParam;
    mutable std::unique_ptr<LoudnessMeter> meter_;  // read() from the display's reader (one at a time)
    std::atomic<bool> targetOn_{false};
    std::atomic<float> targetLufs_{-14.0f};
    bool playing_ = false;
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

class Gate : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return gateDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        detector_.setCoefficients(lib::timeCoefficient(0.0001, sampleRate), lib::timeCoefficient(0.02, sampleRate));
        sc_.bind(descriptor(), true);  // its own sc_hpf stays as it was; the shared filter adds sc_lpf and Listen
        return true;
    }
    void clearState() noexcept override {
        detector_.clear();
        for (auto& f : hpf_) f.clear();
        sc_.clear();
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
        if (sc_.bound()) sc_.set(20.0, param(sc_.lp, at), on(sc_.li, at), sr);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        // External: the key opens and closes the gate (a hi-hat gated by the kick); with no key it stays shut.
        const float* keyL = external_ ? keyLeft() : nullptr;
        const float* keyR = external_ ? keyRight() : nullptr;
        const float* srcL = external_ ? keyL : inL;  // the detector's source (null: no key, silence)
        const float* srcR = external_ ? keyR : inR;
        sc_.apply(srcL, srcR, n);  // the shared low-pass (nothing while off)
        const bool listen = sc_.listen;
        for (uint32_t i = 0; i < n; ++i) {
            double l = srcL ? srcL[i] : 0.0, r = srcR ? srcR[i] : 0.0;
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
            outL[i] = static_cast<float>(listen ? l : inL[i] * g);  // Listen: what the detector hears
            outR[i] = static_cast<float>(listen ? r : inR[i] * g);
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
    SidechainFilter sc_;  // sc_lpf and sc_listen (1.1.0)
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
class TransientShaper : public EffectBase {
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
        // The optional transient and sustain outputs (the merged Transient's; null while unconnected): the output
        // split by how far the fast onset follower is over the slow one, the two parts summing to the output.
        float* tl = optionalOutLeft(0);
        float* tr = optionalOutRight(0);
        float* sl = optionalOutLeft(1);
        float* sr = optionalOutRight(1);
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
            if (tl || sl) {
                const double w = fa > 1e-9 ? std::clamp(1.0 - sa / fa, 0.0, 1.0) : 0.0;
                const float wl = static_cast<float>(l * g * w), wr = static_cast<float>(r * g * w);
                if (tl) tl[i] = wl, tr[i] = wr;
                if (sl) sl[i] = outL[i] - wl, sr[i] = outR[i] - wr;
            }
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

// The transient shaper as the merged Transient's variant: its own descriptor, and the optional outputs.
class TransientWithPorts final : public TransientShaper {
public:
    explicit TransientWithPorts(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    std::span<const OptionalPort> optionalPorts() const noexcept override {
        static const OptionalPort ports[] = {{"transient", "Transient", false}, {"sustain", "Sustain", false}};
        return ports;
    }

private:
    const ModuleDescriptor& d_;
};

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

template <class T>
ModuleProcessor* makeAs(const ModuleDescriptor& variant) noexcept {
    return new (std::nothrow) T(variant);
}

}  // namespace

// The classes as merged variants (builtin_fx_merged_dynamics.cpp): the old descriptors, and an instance under a
// variant's descriptor.
const ModuleDescriptor& legacyCompressorDescriptor() { return compDescriptor(); }
const ParamTable& talonDownExtraParams() { return compExtraParams(); }
const ModuleDescriptor& legacyLimiterDescriptor() { return limDescriptor(); }
std::span<const ParameterDescriptor> limiterTargetParams() {
    const ParamTable& t = limTargetParams();
    return {t.data(), t.size()};
}
const ModuleDescriptor& legacyGateDescriptor() { return gateDescriptor(); }
const ModuleDescriptor& legacyTransientDescriptor() { return transientDescriptor(); }
ModuleProcessor* makeCompressorAs(const ModuleDescriptor& v) noexcept { return makeAs<AsVariant<Compressor>>(v); }
ModuleProcessor* makeLimiterAs(const ModuleDescriptor& v) noexcept { return makeAs<AsVariant<Limiter>>(v); }
ModuleProcessor* makeGateAs(const ModuleDescriptor& v) noexcept { return makeAs<AsVariant<Gate>>(v); }
ModuleProcessor* makeTransientAs(const ModuleDescriptor& v) noexcept { return makeAs<TransientWithPorts>(v); }

void registerDynamics(ModuleRegistry& registry) {
    registry.add(compDescriptor(), &make<Compressor>);
    registry.add(limDescriptor(), &make<Limiter>);
    registry.add(gateDescriptor(), &make<Gate>);
    registry.add(transientDescriptor(), &make<TransientShaper>);
}

}  // namespace caw::fx
