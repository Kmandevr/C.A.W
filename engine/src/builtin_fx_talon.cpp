// Talon's new variants (1.1.0): Up (upward compression with look-ahead) and Bus (a feedback glue compressor with stepped ratios and auto release).
#include <algorithm>
#include <cmath>
#include <new>
#include <vector>

#include "builtin_effects.h"
#include "component_chain.h"
#include "fx_dyn_common.h"
#include "fx_merged.h"
#include "sample_time.h"

// Original code (C.A.W. is Apache-2.0).
// Up: below the threshold the gain rises (thr - level)(1 - 1/ratio) dB, the compressor's soft knee mirrored about
//   the threshold, capped by Range; below Floor the lift falls away 1 dB per dB, so silence and noise are not raised.
//   Loud parts pass at unity, so there is nothing to make up. Look-ahead 0-10 ms (its delay reported per instance).
// Bus: a feedback compressor (the detector hears the output, as classic bus glue does; its curve's slope is
//   1 - ratio, so the settled input-to-output ratio is the one chosen), ratios 1.5/2/4/10, attack
//   0.1-30 ms, release 0.1/0.3/0.6/1.2 s or Auto: two followers, a fast one (the attack, 100 ms back) and a slow one
//   (300 ms in, 1.2 s back), the deeper of the two applied, so a transient recovers fast and a held level slowly.
//   With an external key it is fed forward from the key (a key cannot hear this output).
// Both: knee, Peak/RMS/ISP detection, stereo link, key high- and low-pass, Listen, Clean/Warm character (tanh on the
//   processed signal), parallel mix and output, ramped every 16 frames.

namespace caw::fx {

namespace {

constexpr uint32_t kUpRing = 2048;  // above 10 ms at 192 kHz
constexpr std::string_view kBusRatios[] = {"1.5:1", "2:1", "4:1", "10:1"};
constexpr double kBusRatioValues[] = {1.5, 2.0, 4.0, 10.0};
constexpr std::string_view kBusReleases[] = {"0.1 s", "0.3 s", "0.6 s", "1.2 s", "Auto"};
constexpr double kBusReleaseValues[] = {0.1, 0.3, 0.6, 1.2, 0.0};

// ---------- Up ----------

enum UpParam : uint32_t {
    kUThreshold, kURatio, kURange, kUFloor, kUKnee, kUAttack, kURelease, kULookahead, kUDetect, kULink, kUScHpf,
    kUScLpf, kUListen, kUSidechain, kUCharacter, kUMix, kUOutput, kUCount
};

const ParamTable& upParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("threshold", "Threshold", -30.0, -80.0, 0.0, "dB");
        p.expo("ratio", "Ratio", 2.0, 1.0, 10.0, ":1");
        p.num("range", "Max lift", 12.0, 0.0, 36.0, "dB");
        p.num("floor", "Floor", -60.0, -100.0, -20.0, "dB");
        p.num("knee", "Knee", 6.0, 0.0, 24.0, "dB");
        p.expo("attack", "Attack", 5.0, 0.05, 200.0, "ms");
        p.expo("release", "Release", 150.0, 5.0, 2000.0, "ms");
        ParameterDescriptor& look = p.num("lookahead", "Look-ahead", 0.0, 0.0, 10.0, "ms");
        look.smoothingFrames = 0;
        look.automatable = look.modulatable = false;  // sets the reported latency
        p.pick("detect", "Detection", 0.0, dyn::kDetections);
        p.num("link", "Stereo link", 1.0, 0.0, 1.0);
        p.expo("sc_hpf", "Sidechain high-pass", 20.0, 20.0, 1000.0, "Hz");
        p.expo("sc_lpf", "Sidechain low-pass", 20000.0, 500.0, 20000.0, "Hz");
        p.pick("sc_listen", "Sidechain listen", 0.0, kOffOn);
        p.pick("sidechain", "Sidechain", 0.0, dyn::kSources);
        p.pick("character", "Character", 0.0, dyn::kCharacters);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        return p;
    }();
    return t;
}

uint32_t upLookahead(double ms, double sr) noexcept {
    const double f = std::isfinite(ms) && ms > 0.0 ? std::min(ms, 10.0) * 0.001 * sr + 0.5 : 0.0;
    return std::min<uint32_t>(kUpRing - 17, static_cast<uint32_t>(f));
}

class TalonUp final : public EffectBase, public VariableLatency {
public:
    explicit TalonUp(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    uint32_t latencyFor(const double* values, uint32_t count) const noexcept override {
        return count > kULookahead ? upLookahead(values[kULookahead], rate()) : 0;
    }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        det_.prepare(sampleRate);
        uint32_t size = 32;  // the look-ahead line: 10 ms at this rate, a power of two
        while (size < upLookahead(10.0, sampleRate) + kControlFrames + 1) size <<= 1;
        try {
            for (auto& c : ring_) c.assign(size, 0.0f);
        } catch (...) {
            return false;
        }
        return true;
    }
    void clearState() noexcept override {
        for (auto& c : ring_) std::fill(c.begin(), c.end(), 0.0f);
        pos_ = 0;
        key_.clear();
        det_.clear();
        env_[0] = env_[1] = 0.0;
        liftNow_ = liftMax_ = levelMax_ = 0.0;
        mix_.reset();
        out_.reset();
    }
    uint64_t idleFrames() const noexcept override { return delay_ + static_cast<uint64_t>(0.05 * rate()); }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        thr_ = param(kUThreshold, at);
        ratio_ = std::max(1.0, param(kURatio, at));
        range_ = std::max(0.0, param(kURange, at));
        floor_ = std::min(param(kUFloor, at), thr_);
        knee_ = std::max(0.0, param(kUKnee, at));
        const double a = param(kUAttack, at) * 0.001, r = param(kURelease, at) * 0.001;
        if (a != attackFor_ || sr != rateFor_) attackFor_ = a, attack_ = lib::timeCoefficient(a, sr);
        if (r != releaseFor_ || sr != rateFor_) releaseFor_ = r, release_ = lib::timeCoefficient(r, sr);
        rateFor_ = sr;
        delay_ = upLookahead(param(kULookahead, at), sr);
        detect_ = std::clamp(choice(kUDetect, at), 0, 2);
        link_ = std::clamp(param(kULink, at), 0.0, 1.0);
        key_.set(param(kUScHpf, at), param(kUScLpf, at), sr);
        listen_ = on(kUListen, at);
        external_ = choice(kUSidechain, at) == 1;
        warm_ = choice(kUCharacter, at) == 1;
        mix_.set(std::clamp(param(kUMix, at), 0.0, 1.0), kControlFrames);
        const double o = param(kUOutput, at);
        if (o != outDb_) outDb_ = o, outGain_ = lib::dbToGain(o);
        out_.set(outGain_, kControlFrames);
        thrLin_ = lib::dbToGain(thr_ - 0.5 * knee_ + 0.01);  // above this the curve is exactly 0 dB: no log
    }

    // The lift in dB (0 or more) for a level in dB.
    double lift(double db) const noexcept {
        double g = std::min(range_, -lib::compressorGainDb(2.0 * thr_ - db, thr_, ratio_, knee_));
        if (db < floor_) {
            const double atFloor = std::min(range_, -lib::compressorGainDb(2.0 * thr_ - floor_, thr_, ratio_, knee_));
            g = atFloor - (floor_ - db);
        }
        return g > 0.0 ? g : 0.0;
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
        const uint32_t mask = static_cast<uint32_t>(ring_[0].size()) - 1;
        const float* kl = external_ ? keyLeft() : nullptr;
        const float* kr = external_ ? keyRight() : nullptr;
        double sc[2][kControlFrames], lv[2][kControlFrames];
        for (uint32_t i = 0; i < n; ++i) {
            ring_[0][(pos_ + i) & mask] = inL[i];
            ring_[1][(pos_ + i) & mask] = inR[i];
            sc[0][i] = external_ ? (kl ? kl[i] : 0.0) : inL[i];  // the detector hears now; the audio is delay_ late
            sc[1][i] = external_ ? (kr ? kr[i] : 0.0) : inR[i];
        }
        for (int c = 0; c < 2; ++c) {
            key_.run(c, sc[c], n);
            det_.run<Det>(c, sc[c], lv[c], n);
        }
        dyn::link(lv[0], lv[1], link_, n);
        const int sides = link_ >= 1.0 ? 1 : 2;  // fully linked: one follower for both
        for (uint32_t i = 0; i < n; ++i) {
            double g[2];
            for (int c = 0; c < sides; ++c) {
                const double level = lv[c][i];
                levelMax_ = level > levelMax_ ? level : levelMax_;
                const double t = level >= thrLin_ ? 0.0 : lift(lib::gainToDb(level, -200.0));
                // Attack while the lift falls (the level came up), release while it rises.
                env_[c] = t + (env_[c] - t) * (t < env_[c] ? attack_ : release_);
                if (env_[c] - t < 1e-9 && t - env_[c] < 1e-9) env_[c] = t;
                if (env_[c] < 1e-9) env_[c] = 0.0;
                g[c] = env_[c] == 0.0 ? 1.0 : lib::dbToGain(env_[c]);
            }
            if (sides == 1) env_[1] = env_[0], g[1] = g[0];
            const double lift = std::max(env_[0], env_[1]);
            liftNow_ = lift;
            liftMax_ = lift > liftMax_ ? lift : liftMax_;
            const double m = mix_.next(), o = out_.next();
            if (listen_) {
                outL[i] = static_cast<float>(sc[0][i]);
                outR[i] = static_cast<float>(sc[1][i]);
                continue;
            }
            const uint32_t a = (pos_ + i - delay_) & mask;
            const double xl = ring_[0][a], xr = ring_[1][a];
            double wl = xl * g[0], wr = xr * g[1];
            if (warm_) wl = dyn::warm(wl), wr = dyn::warm(wr);
            outL[i] = static_cast<float>(o * (xl + (wl - xl) * m));
            outR[i] = static_cast<float>(o * (xr + (wr - xr) * m));
        }
        pos_ = (pos_ + n) & mask;
    }

    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(liftNow_);  // the lift now, dB (positive: raised)
        out[3] = static_cast<float>(liftMax_);
        out[4] = static_cast<float>(lib::gainToDb(levelMax_));
        out[5] = static_cast<float>(thr_);
        out[6] = static_cast<float>(ratio_);
        out[7] = static_cast<float>(knee_);
        out[8] = static_cast<float>(range_);
        out[9] = static_cast<float>(floor_);
        out[10] = static_cast<float>(delay_ * 1000.0 / rate());
        out[11] = external_ ? 1.0f : 0.0f;
        liftMax_ = levelMax_ = 0.0;
        return 12;
    }

private:
    const ModuleDescriptor& d_;
    std::vector<float> ring_[2];
    uint32_t pos_ = 0, delay_ = 0;
    dyn::KeyFilter key_;
    dyn::Detector det_;
    double env_[2] = {};
    double thr_ = -30, ratio_ = 2, range_ = 12, floor_ = -60, knee_ = 6, thrLin_ = 1;
    double attack_ = 0, release_ = 0, attackFor_ = -1, releaseFor_ = -1, rateFor_ = -1;
    double link_ = 1, outDb_ = 1e300, outGain_ = 1;
    Ramp mix_, out_;
    int detect_ = 0;
    bool listen_ = false, external_ = false, warm_ = false;
    double liftNow_ = 0, liftMax_ = 0, levelMax_ = 0;
};

// ---------- Bus ----------

enum BusParam : uint32_t {
    kBThreshold, kBRatio, kBAttack, kBRelease, kBKnee, kBMakeup, kBAutoMakeup, kBDetect, kBLink, kBScHpf, kBScLpf,
    kBListen, kBSidechain, kBCharacter, kBMix, kBOutput, kBCount
};

const ParamTable& busParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("threshold", "Threshold", -12.0, -40.0, 0.0, "dB");
        p.pick("ratio", "Ratio", 1.0, kBusRatios);
        p.expo("attack", "Attack", 10.0, 0.1, 30.0, "ms");
        p.pick("release", "Release", 4.0, kBusReleases);
        p.num("knee", "Knee", 6.0, 0.0, 12.0, "dB");
        p.num("makeup", "Makeup", 0.0, -12.0, 24.0, "dB");
        p.pick("auto_makeup", "Auto makeup", 1.0, kOffOn);
        p.pick("detect", "Detection", 0.0, dyn::kDetections);
        p.num("link", "Stereo link", 1.0, 0.0, 1.0);
        p.expo("sc_hpf", "Sidechain high-pass", 20.0, 20.0, 1000.0, "Hz");
        p.expo("sc_lpf", "Sidechain low-pass", 20000.0, 500.0, 20000.0, "Hz");
        p.pick("sc_listen", "Sidechain listen", 0.0, kOffOn);
        p.pick("sidechain", "Sidechain", 0.0, dyn::kSources);
        p.pick("character", "Character", 0.0, dyn::kCharacters);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        return p;
    }();
    return t;
}

class TalonBus final : public EffectBase {
public:
    explicit TalonBus(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        det_.prepare(sampleRate);
        read_ = true;
        relFast_ = lib::timeCoefficient(0.1, sampleRate);
        attSlow_ = lib::timeCoefficient(0.3, sampleRate);
        relSlow_ = lib::timeCoefficient(1.2, sampleRate);
        return true;
    }
    void clearState() noexcept override {
        key_.clear();
        det_.clear();
        for (int c = 0; c < 2; ++c) fast_[c] = slow_[c] = gain_[c] = 0.0, prevDb_[c] = -200.0;
        grNow_ = grMax_ = levelMax_ = 0.0;
        track_[0] = track_[1] = dyn::GainTracker{};
        mix_.reset();
        out_.reset();
        makeupRamp_.reset();
    }

    void control(uint32_t at) noexcept override {
        // The knobs are read again only when one moved (or the rate did): a held block costs a compare. The ramps
        // and the trackers' resync run at every grid point either way.
        const bool same = knobsUnchanged(knobs_, kBCount, at);
        if (!same || read_ || rate() != rateFor_) readKnobs(at);
        read_ = false;
        makeupRamp_.set(makeupGain_, kControlFrames);
        mix_.set(mixTo_, kControlFrames);
        track_[0].resync();  // at each grid point (the same frames at any block size)
        track_[1].resync();
        out_.set(outGain_, kControlFrames);
    }

    void readKnobs(uint32_t at) noexcept {
        const double sr = rate();
        thr_ = param(kBThreshold, at);
        ratio_ = kBusRatioValues[std::clamp(choice(kBRatio, at), 0, 3)];
        knee_ = std::max(0.0, param(kBKnee, at));
        const double a = param(kBAttack, at) * 0.001;
        if (a != attackFor_ || sr != rateFor_) attackFor_ = a, attack_ = lib::timeCoefficient(a, sr);
        // The feedback loop's gain per sample is (1 - attack) (ratio - 1): held at 0.9 or less, so it settles
        // without ringing (10:1 at the fastest attack: about 0.2 ms).
        loopAttack_ = ratio_ > 1.9 ? std::max(attack_, 1.0 - 0.9 / (ratio_ - 1.0)) : attack_;
        const int rel = std::clamp(choice(kBRelease, at), 0, 4);
        auto_ = rel == 4;
        if (!auto_ && (rel != releaseFor_ || sr != rateFor_)) releaseFor_ = rel, release_ = lib::timeCoefficient(kBusReleaseValues[rel], sr);
        rateFor_ = sr;
        double makeup = param(kBMakeup, at);
        if (on(kBAutoMakeup, at)) makeup -= 0.5 * lib::compressorGainDb(0.0, thr_, ratio_, knee_);
        if (makeup != makeupDb_) makeupDb_ = makeup, makeupGain_ = lib::dbToGain(makeup);
        detect_ = std::clamp(choice(kBDetect, at), 0, 2);
        link_ = std::clamp(param(kBLink, at), 0.0, 1.0);
        key_.set(param(kBScHpf, at), param(kBScLpf, at), sr);
        listen_ = on(kBListen, at);
        external_ = choice(kBSidechain, at) == 1;
        warm_ = choice(kBCharacter, at) == 1;
        mixTo_ = std::clamp(param(kBMix, at), 0.0, 1.0);
        const double o = param(kBOutput, at);
        if (o != outDb_) outDb_ = o, outGain_ = lib::dbToGain(o);
        kneeLow_ = thr_ - 0.5 * knee_ - 0.01;  // at or under this the curve is exactly 0 dB
        quietBelow_ = lib::dbToGain(kneeLow_);  // the gain change is never above 0 dB, so under it: no log
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        switch (detect_) {
            case dyn::kRms: return runAs<dyn::kRms>(inL, inR, outL, outR, n);
            case dyn::kIsp: return runAs<dyn::kIsp>(inL, inR, outL, outR, n);
            default: return runAs<dyn::kPeak>(inL, inR, outL, outR, n);
        }
    }

    // The gain change for the output's level (feedback): the slope 1 - ratio (with the same quadratic knee), which
    // holds the input-to-output ratio at `ratio` once settled (y - thr = (x - thr) / ratio), as the feed-forward
    // curve does from the input.
    double feedbackGainDb(double heard) const noexcept {
        const double over = heard - thr_, slope = 1.0 - ratio_;
        if (2.0 * over <= -knee_) return 0.0;
        if (2.0 * over < knee_) {
            const double t = over + 0.5 * knee_;
            return slope * t * t / (2.0 * knee_);
        }
        return slope * over;
    }

    // One side's reduction toward target t (dB, 0 or less).
    double follow(int c, double t) noexcept {
        double& f = fast_[c];
        f = t + (f - t) * (t < f ? (external_ ? attack_ : loopAttack_) : (auto_ ? relFast_ : release_));
        if (f - t < 1e-9 && t - f < 1e-9) f = t;
        if (f > -1e-9) f = 0.0;
        if (!auto_) return f;
        double& s = slow_[c];
        s = t + (s - t) * (t < s ? attSlow_ : relSlow_);
        if (s - t < 1e-9 && t - s < 1e-9) s = t;
        if (s > -1e-9) s = 0.0;
        return f < s ? f : s;
    }

    template <int Det>
    void runAs(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept {
        // The detector's levels in dB for the whole run: the key's (fed forward), or the input's, from which the
        // feedback level follows without a per-sample log: the output's level is the input's plus the gain change
        // in dB (exact for Peak; for RMS, ISP and the key filters, which here hear the input, as close as the gain
        // moves slowly against them). So the loop below carries only the curve and the followers.
        const float* kl = external_ ? keyLeft() : nullptr;
        const float* kr = external_ ? keyRight() : nullptr;
        double sc[2][kControlFrames], lv[2][kControlFrames];
        for (uint32_t i = 0; i < n; ++i) {
            sc[0][i] = external_ ? (kl ? kl[i] : 0.0) : inL[i];
            sc[1][i] = external_ ? (kr ? kr[i] : 0.0) : inR[i];
        }
        for (int c = 0; c < 2; ++c) key_.run(c, sc[c], n), det_.run<Det>(c, sc[c], lv[c], n);
        dyn::link(lv[0], lv[1], link_, n);
        const bool one = link_ >= 1.0;
        const int sides = one ? 1 : 2;
        double gr[2][kControlFrames];
        for (int c = 0; c < sides; ++c) {
            double db[kControlFrames];
            for (uint32_t i = 0; i < n; ++i) levelMax_ = lv[c][i] > levelMax_ ? lv[c][i] : levelMax_;
            dyn::toDb(lv[c], db, n, quietBelow_);
            double prev = prevDb_[c];
            for (uint32_t i = 0; i < n; ++i) {
                const double heard = external_ ? db[i] : prev + gain_[c];  // the key now, or the last output
                const double t = heard <= kneeLow_ ? 0.0
                                 : external_ ? lib::compressorGainDb(heard, thr_, ratio_, knee_)
                                             : feedbackGainDb(heard);
                gain_[c] = follow(c, t);
                gr[c][i] = gain_[c];
                prev = db[i];
            }
            prevDb_[c] = prev;
        }
        if (one) {
            gain_[1] = gain_[0], fast_[1] = fast_[0], slow_[1] = slow_[0], prevDb_[1] = prevDb_[0];
            for (uint32_t i = 0; i < n; ++i) gr[1][i] = gr[0][i];
        }
        // The gains first (the trackers' serial steps, and the meters), then the output in a loop with no mode tests
        // when Listen and Warm are off (the common case), so it vectorises. The same values in the same order.
        double gl[kControlFrames], gg[kControlFrames];
        double grMax = grMax_;
        dyn::GainTracker t0 = track_[0], t1 = track_[1];
        for (uint32_t i = 0; i < n; ++i) {
            const double rl = gr[0][i], rr = gr[1][i];
            const double g = rl < rr ? rl : rr;
            grMax = g < grMax ? g : grMax;
            gl[i] = t0.step(rl);
            gg[i] = one ? gl[i] : t1.step(rr);
        }
        track_[0] = t0, track_[1] = t1;
        if (n > 0) {
            grNow_ = gr[0][n - 1] < gr[1][n - 1] ? gr[0][n - 1] : gr[1][n - 1];
            gainOf_[0] = gl[n - 1], gainOf_[1] = gg[n - 1];
        }
        grMax_ = grMax;
        double mk[kControlFrames], m[kControlFrames], o[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) mk[i] = makeupRamp_.next(), m[i] = mix_.next(), o[i] = out_.next();
        if (listen_) {
            for (uint32_t i = 0; i < n; ++i) outL[i] = static_cast<float>(sc[0][i]), outR[i] = static_cast<float>(sc[1][i]);
        } else if (warm_) {
            for (uint32_t i = 0; i < n; ++i) {
                const double xl = inL[i], xr = inR[i];
                const double wl = dyn::warm(xl * gl[i] * mk[i]), wr = dyn::warm(xr * gg[i] * mk[i]);
                outL[i] = static_cast<float>(o[i] * (xl + (wl - xl) * m[i]));
                outR[i] = static_cast<float>(o[i] * (xr + (wr - xr) * m[i]));
            }
        } else {
            for (uint32_t i = 0; i < n; ++i) {
                const double xl = inL[i], xr = inR[i];
                const double wl = xl * gl[i] * mk[i], wr = xr * gg[i] * mk[i];
                outL[i] = static_cast<float>(o[i] * (xl + (wl - xl) * m[i]));
                outR[i] = static_cast<float>(o[i] * (xr + (wr - xr) * m[i]));
            }
        }
    }

    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(grMax_ < 0 ? -grMax_ : 0.0);
        out[3] = static_cast<float>(grNow_ < 0 ? -grNow_ : 0.0);
        out[4] = static_cast<float>(lib::gainToDb(levelMax_));
        out[5] = static_cast<float>(thr_);
        out[6] = static_cast<float>(ratio_);
        out[7] = static_cast<float>(knee_);
        out[8] = static_cast<float>(makeupDb_);
        out[9] = auto_ ? 1.0f : 0.0f;  // the auto release is on
        out[10] = static_cast<float>(-std::min(slow_[0], slow_[1]));  // the slow follower's share, dB
        out[11] = external_ ? 1.0f : 0.0f;
        grMax_ = levelMax_ = 0.0;
        return 12;
    }

private:
    const ModuleDescriptor& d_;
    dyn::KeyFilter key_;
    dyn::Detector det_;
    double fast_[2] = {}, slow_[2] = {}, gain_[2] = {}, prevDb_[2] = {-200.0, -200.0};
    double thr_ = -12, ratio_ = 2, knee_ = 6, quietBelow_ = 0, kneeLow_ = -15;
    double attack_ = 0, loopAttack_ = 0, release_ = 0, relFast_ = 0, attSlow_ = 0, relSlow_ = 0;
    double attackFor_ = -1, rateFor_ = -1;
    int releaseFor_ = -1;
    double makeupDb_ = 1e300, makeupGain_ = 1, outDb_ = 1e300, outGain_ = 1, link_ = 1;
    double gainOf_[2] = {1, 1};
    dyn::GainTracker track_[2];
    Ramp mix_, out_, makeupRamp_;
    int detect_ = 0;
    bool auto_ = true, listen_ = false, external_ = false, warm_ = false;
    double grNow_ = 0, grMax_ = 0, levelMax_ = 0;
    double knobs_[kBCount] = {}, mixTo_ = 1;
    bool read_ = true;  // read the knobs at the next control() whatever they are
};

const ModuleDescriptor& upBase() {
    static const ModuleDescriptor d = keyedEffectDescriptor("org.caw.compressor", "Compressor", upParams(), 0, 0, false);
    return d;
}
const ModuleDescriptor& busBase() {
    static const ModuleDescriptor d = keyedEffectDescriptor("org.caw.compressor", "Compressor", busParams(), 0, 0, false);
    return d;
}

}  // namespace

const ModuleDescriptor& talonUpBaseDescriptor() { return upBase(); }
const ModuleDescriptor& talonBusBaseDescriptor() { return busBase(); }
ModuleProcessor* makeTalonUpAs(const ModuleDescriptor& v) noexcept { return new (std::nothrow) TalonUp(v); }
ModuleProcessor* makeTalonBusAs(const ModuleDescriptor& v) noexcept { return new (std::nothrow) TalonBus(v); }
size_t talonUpBytes(double sr) noexcept {
    uint32_t size = 32;
    while (size < upLookahead(10.0, sr) + 17) size <<= 1;
    return sizeof(TalonUp) + 2 * size * sizeof(float);
}
size_t talonBusBytes() noexcept { return sizeof(TalonBus); }

}  // namespace caw::fx
