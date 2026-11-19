// Hatch's new variants (1.1.0): Expand (a downward expander) and Pedal gate (zero latency, open/close hysteresis, release that tracks the input's decay).
#include <algorithm>
#include <cmath>
#include <new>

#include "builtin_effects.h"
#include "fx_dyn_common.h"
#include "fx_merged.h"

// Original code (C.A.W. is Apache-2.0).
// Expand: below the threshold the level falls `ratio` times as fast (1.5:1 to 4:1, lib::expanderGainDb with its
//   quadratic knee), never more than Range; attack opens, hold waits, release closes. Peak/RMS/ISP detection, key
//   high- and low-pass, an external key, Listen, output. No look-ahead, so no latency.
// Pedal gate: a guitar pedal's noise gate. A fast peak follower (0.1 ms in, 20 ms out) on the key opens the gate
//   above Threshold and closes it only below Threshold - Hysteresis, after Hold, so a decaying note doesn't chatter.
//   While open it measures how fast the input's level falls (dB per second, smoothed over about 50 ms); Tracking
//   blends the release from the Release knob toward the time that decay needs to fall 20 dB, so a long note fades
//   as it was dying and a palm-mute stops short. The release coefficient is worked out every 16 frames.
//   Keyed by its own input (the clean signal when it sits before a Drive) or an external key.

namespace caw::fx {

namespace {

// ---------- Expand ----------

enum ExpParam : uint32_t {
    kEThreshold, kERatio, kERange, kEKnee, kEAttack, kEHold, kERelease, kEDetect, kEScHpf, kEScLpf, kEListen,
    kESidechain, kEOutput, kECount
};

const ParamTable& expandParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("threshold", "Threshold", -40.0, -80.0, 0.0, "dB");
        p.expo("ratio", "Ratio", 2.0, 1.5, 4.0, ":1");
        p.num("range", "Range", -40.0, -80.0, 0.0, "dB");
        p.num("knee", "Knee", 6.0, 0.0, 24.0, "dB");
        p.expo("attack", "Attack", 1.0, 0.01, 50.0, "ms");
        p.num("hold", "Hold", 20.0, 0.0, 500.0, "ms");
        p.expo("release", "Release", 150.0, 5.0, 2000.0, "ms");
        p.pick("detect", "Detection", 0.0, dyn::kDetections);
        p.expo("sc_hpf", "Sidechain high-pass", 20.0, 20.0, 2000.0, "Hz");
        p.expo("sc_lpf", "Sidechain low-pass", 20000.0, 500.0, 20000.0, "Hz");
        p.pick("sc_listen", "Sidechain listen", 0.0, kOffOn);
        p.pick("sidechain", "Sidechain", 0.0, dyn::kSources);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        return p;
    }();
    return t;
}

class HatchExpand final : public EffectBase {
public:
    explicit HatchExpand(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        det_.prepare(sampleRate);
        return true;
    }
    void clearState() noexcept override {
        key_.clear();
        det_.clear();
        env_ = range_;
        gainDb_ = 1e300;
        holdLeft_ = 0;
        grNow_ = grMax_ = levelMax_ = 0.0;
        out_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        thr_ = param(kEThreshold, at);
        ratio_ = std::clamp(param(kERatio, at), 1.0, 4.0);
        range_ = std::min(0.0, param(kERange, at));
        knee_ = std::max(0.0, param(kEKnee, at));
        const double a = param(kEAttack, at) * 0.001, r = param(kERelease, at) * 0.001;
        if (a != attackFor_ || sr != rateFor_) attackFor_ = a, attack_ = lib::timeCoefficient(a, sr);
        if (r != releaseFor_ || sr != rateFor_) releaseFor_ = r, release_ = lib::timeCoefficient(r, sr);
        rateFor_ = sr;
        hold_ = static_cast<uint32_t>(std::max(0.0, param(kEHold, at)) * 0.001 * sr);
        detect_ = std::clamp(choice(kEDetect, at), 0, 2);
        key_.set(param(kEScHpf, at), param(kEScLpf, at), sr);
        listen_ = on(kEListen, at);
        external_ = choice(kESidechain, at) == 1;
        const double o = param(kEOutput, at);
        if (o != outDb_) outDb_ = o, outGain_ = lib::dbToGain(o);
        out_.set(outGain_, kControlFrames);
        openAbove_ = lib::dbToGain(thr_ + 0.5 * knee_ + 0.01);  // above this the curve is exactly 0 dB: no log
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        switch (detect_) {
            case dyn::kRms: return runAs<dyn::kRms>(inL, inR, outL, outR, n);
            case dyn::kIsp: return runAs<dyn::kIsp>(inL, inR, outL, outR, n);
            default: return runAs<dyn::kPeak>(inL, inR, outL, outR, n);
        }
    }
    template <int Det>
    void runAs(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept {
        const float* kl = external_ ? keyLeft() : nullptr;
        const float* kr = external_ ? keyRight() : nullptr;
        double sc[2][kControlFrames], lv[2][kControlFrames];
        for (uint32_t i = 0; i < n; ++i) {
            sc[0][i] = external_ ? (kl ? kl[i] : 0.0) : inL[i];
            sc[1][i] = external_ ? (kr ? kr[i] : 0.0) : inR[i];
        }
        for (int c = 0; c < 2; ++c) key_.run(c, sc[c], n), det_.run<Det>(c, sc[c], lv[c], n);
        for (uint32_t i = 0; i < n; ++i) {
            const double level = lv[0][i] > lv[1][i] ? lv[0][i] : lv[1][i];
            levelMax_ = level > levelMax_ ? level : levelMax_;
            const bool open = level >= openAbove_;
            const double t = open ? 0.0 : lib::expanderGainDb(lib::gainToDb(level, -200.0), thr_, ratio_, knee_, range_);
            if (open) holdLeft_ = hold_;
            if (t > env_) env_ = t + (env_ - t) * attack_;
            else if (holdLeft_ > 0) --holdLeft_;
            else env_ = t + (env_ - t) * release_;
            if (env_ - t < 1e-9 && t - env_ < 1e-9) env_ = t;
            if (env_ != gainDb_) gainDb_ = env_, gain_ = lib::dbToGain(env_);
            grNow_ = env_;
            grMax_ = env_ < grMax_ ? env_ : grMax_;
            const double o = out_.next();
            if (listen_) {
                outL[i] = static_cast<float>(sc[0][i]), outR[i] = static_cast<float>(sc[1][i]);
                continue;
            }
            outL[i] = static_cast<float>(inL[i] * gain_ * o);
            outR[i] = static_cast<float>(inR[i] * gain_ * o);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(grNow_ < 0 ? -grNow_ : 0.0);
        out[3] = static_cast<float>(grMax_ < 0 ? -grMax_ : 0.0);
        out[4] = static_cast<float>(lib::gainToDb(levelMax_));
        out[5] = static_cast<float>(thr_);
        out[6] = static_cast<float>(ratio_);
        out[7] = static_cast<float>(range_);
        out[8] = static_cast<float>(knee_);
        out[9] = external_ ? 1.0f : 0.0f;
        grMax_ = levelMax_ = 0.0;
        return 10;
    }

private:
    const ModuleDescriptor& d_;
    dyn::KeyFilter key_;
    dyn::Detector det_;
    double thr_ = -40, ratio_ = 2, range_ = -40, knee_ = 6, openAbove_ = 1, env_ = -40;
    double attack_ = 0, release_ = 0, attackFor_ = -1, releaseFor_ = -1, rateFor_ = -1;
    double gainDb_ = 1e300, gain_ = 1, outDb_ = 1e300, outGain_ = 1;
    uint32_t hold_ = 0, holdLeft_ = 0;
    Ramp out_;
    int detect_ = 0;
    bool listen_ = false, external_ = false;
    double grNow_ = 0, grMax_ = 0, levelMax_ = 0;
};

// ---------- Pedal gate ----------

enum PedalParam : uint32_t {
    kPThreshold, kPHysteresis, kPRange, kPAttack, kPHold, kPRelease, kPTracking, kPScHpf, kPSidechain, kPCount
};

const ParamTable& pedalParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("threshold", "Threshold", -50.0, -90.0, 0.0, "dB");
        p.num("hysteresis", "Hysteresis", 6.0, 0.0, 24.0, "dB");
        p.num("range", "Range", -80.0, -80.0, 0.0, "dB");
        p.expo("attack", "Attack", 0.1, 0.01, 10.0, "ms");
        p.num("hold", "Hold", 10.0, 0.0, 200.0, "ms");
        p.expo("release", "Release", 80.0, 2.0, 1000.0, "ms");
        p.num("tracking", "Release tracking", 0.7, 0.0, 1.0);
        p.expo("sc_hpf", "Sidechain high-pass", 20.0, 20.0, 2000.0, "Hz");
        p.pick("sidechain", "Sidechain", 0.0, dyn::kSources);
        return p;
    }();
    return t;
}

class HatchPedal final : public EffectBase {
public:
    explicit HatchPedal(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        follower_.setCoefficients(lib::timeCoefficient(0.0001, sampleRate), lib::timeCoefficient(0.02, sampleRate));
        slopeCoef_ = lib::timeCoefficient(0.05, sampleRate);
        return true;
    }
    void clearState() noexcept override {
        follower_.clear();
        for (auto& f : hpf_) f.clear();
        open_ = false;
        holdLeft_ = 0;
        env_ = range_;
        gainDb_ = 1e300;
        lastDb_ = -200.0;
        slope_ = 0.0;
        levelMax_ = 0.0;
        grMax_ = 0.0;
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        openDb_ = param(kPThreshold, at);
        closeDb_ = openDb_ - std::max(0.0, param(kPHysteresis, at));
        openLin_ = lib::dbToGain(openDb_);
        closeLin_ = lib::dbToGain(closeDb_);
        range_ = std::min(0.0, param(kPRange, at));
        const double a = param(kPAttack, at) * 0.001;
        if (a != attackFor_ || sr != rateFor_) attackFor_ = a, attack_ = lib::timeCoefficient(a, sr);
        rateFor_ = sr;
        hold_ = static_cast<uint32_t>(std::max(0.0, param(kPHold, at)) * 0.001 * sr);
        // The release: the knob's time, blended toward the time the measured decay takes to fall 20 dB.
        const double knob = param(kPRelease, at) * 0.001;
        const double perSecond = -slope_ * sr;  // dB per second the level is falling (0 when it isn't)
        const double tracked = perSecond > 1.0 ? std::clamp(20.0 / perSecond, 0.002, 2.0) : knob;
        const double tr = std::clamp(param(kPTracking, at), 0.0, 1.0);
        release_ = lib::timeCoefficient(knob + (tracked - knob) * tr, sr);
        releaseMs_ = (knob + (tracked - knob) * tr) * 1000.0;
        const double hpf = param(kPScHpf, at);
        useHpf_ = hpf > 20.5;
        if (useHpf_) for (auto& f : hpf_) f.set(hpf, 0.70710678118654752, sr);
        external_ = choice(kPSidechain, at) == 1;
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const float* kl = external_ ? keyLeft() : nullptr;
        const float* kr = external_ ? keyRight() : nullptr;
        double sc[2][kControlFrames];
        for (uint32_t i = 0; i < n; ++i) {
            sc[0][i] = external_ ? (kl ? kl[i] : 0.0) : inL[i];
            sc[1][i] = external_ ? (kr ? kr[i] : 0.0) : inR[i];
        }
        if (useHpf_)
            for (int c = 0; c < 2; ++c)
                for (uint32_t i = 0; i < n; ++i) sc[c][i] = hpf_[c].highpass(sc[c][i]);
        for (uint32_t i = 0; i < n; ++i) {
            const double l = sc[0][i] < 0 ? -sc[0][i] : sc[0][i], r = sc[1][i] < 0 ? -sc[1][i] : sc[1][i];
            const double level = follower_.process(l > r ? l : r);
            levelMax_ = level > levelMax_ ? level : levelMax_;
            if (!open_ && level > openLin_) open_ = true, holdLeft_ = hold_;
            else if (open_ && level >= closeLin_) holdLeft_ = hold_;
            else if (open_ && holdLeft_ > 0) --holdLeft_;
            else if (open_) open_ = false;
            // The decay slope, measured only while open and above the close threshold (where the note rings).
            if (open_ && level >= closeLin_) {
                const double db = lib::gainToDb(level, -200.0);
                const double d = db - lastDb_;
                lastDb_ = db;
                const double fall = d < 0.0 ? d : 0.0;
                slope_ = fall + (slope_ - fall) * slopeCoef_;
            } else {
                lastDb_ = closeDb_;
            }
            const double t = open_ ? 0.0 : range_;
            env_ = t + (env_ - t) * (t > env_ ? attack_ : release_);
            if (env_ - t < 1e-9 && t - env_ < 1e-9) env_ = t;
            if (env_ != gainDb_) gainDb_ = env_, gain_ = lib::dbToGain(env_);
            grMax_ = env_ < grMax_ ? env_ : grMax_;
            outL[i] = static_cast<float>(inL[i] * gain_);
            outR[i] = static_cast<float>(inR[i] * gain_);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(env_ < 0 ? -env_ : 0.0);
        out[3] = static_cast<float>(grMax_ < 0 ? -grMax_ : 0.0);
        out[4] = static_cast<float>(lib::gainToDb(levelMax_));
        out[5] = static_cast<float>(openDb_);
        out[6] = static_cast<float>(closeDb_);
        out[7] = open_ ? 1.0f : 0.0f;
        out[8] = static_cast<float>(releaseMs_);  // the release in use, ms (tracked)
        out[9] = external_ ? 1.0f : 0.0f;
        grMax_ = levelMax_ = 0.0;
        return 10;
    }

private:
    const ModuleDescriptor& d_;
    lib::EnvelopeFollower follower_;
    lib::Svf hpf_[2];
    double openDb_ = -50, closeDb_ = -56, openLin_ = 0, closeLin_ = 0, range_ = -80, env_ = -80;
    double attack_ = 0, release_ = 0, attackFor_ = -1, rateFor_ = -1, releaseMs_ = 80;
    double gainDb_ = 1e300, gain_ = 1, lastDb_ = -200, slope_ = 0, slopeCoef_ = 0;
    uint32_t hold_ = 0, holdLeft_ = 0;
    bool open_ = false, useHpf_ = false, external_ = false;
    double levelMax_ = 0, grMax_ = 0;
};

const ModuleDescriptor& expandBase() {
    static const ModuleDescriptor d = keyedEffectDescriptor("org.caw.gate", "Gate", expandParams(), 0, 0, false);
    return d;
}
const ModuleDescriptor& pedalBase() {
    static const ModuleDescriptor d = keyedEffectDescriptor("org.caw.gate", "Gate", pedalParams(), 0, 0, false);
    return d;
}

}  // namespace

const ModuleDescriptor& hatchExpandBaseDescriptor() { return expandBase(); }
const ModuleDescriptor& hatchPedalBaseDescriptor() { return pedalBase(); }
ModuleProcessor* makeHatchExpandAs(const ModuleDescriptor& v) noexcept { return new (std::nothrow) HatchExpand(v); }
ModuleProcessor* makeHatchPedalAs(const ModuleDescriptor& v) noexcept { return new (std::nothrow) HatchPedal(v); }
size_t hatchExpandBytes() noexcept { return sizeof(HatchExpand); }
size_t hatchPedalBytes() noexcept { return sizeof(HatchPedal); }

}  // namespace caw::fx
