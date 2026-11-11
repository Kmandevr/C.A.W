// fx-dynamics (Dynamics category): Dynamics (upward/downward compression and expansion), Multiband dynamics (OTT mode) and De-esser.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>

#include "caw/library/dynamics.hpp"
#include "caw/library/filter.hpp"

// Original code (C.A.W. is Apache-2.0). Techniques, in our own words (docs/engine.md, "Dynamics and drive"):
// - a level detector in dB (peak or RMS) smoothed with separate attack and release, then a static curve in dB,
//   as in Giannoulis, Massberg and Reiss, "Digital Dynamic Range Compressor Design" (JAES 2012), and Zölzer (ed.),
//   DAFX (2nd ed., Wiley 2011), ch. 4 "Nonlinear processing";
// - each threshold's soft knee is that paper's quadratic, here with any slope, so the same piece gives downward
//   compression, upward compression and both kinds of expansion;
// - the multiband split is Linkwitz-Riley 4th order (two 2nd-order Butterworth sections in cascade; Linkwitz,
//   "Active crossover networks for noncoincident drivers", JAES 1976): its low and high outputs sum to a 2nd-order
//   all-pass, so the low band (and the dry path) go through that all-pass to stay in phase with the others.

namespace caw::fx {

namespace {

constexpr double kButterworthQ = 0.70710678118654752;
constexpr double kSqrt2 = 1.41421356237309505;

float positive(double db) { return static_cast<float>(db < 0.0 ? -db : 0.0); }

// The gain in dB of a soft-knee segment `over` dB past its threshold, changing `slope` dB per dB past it, with a
// quadratic across a knee `w` dB wide centred on the threshold (0 before it).
inline double kneeGain(double over, double slope, double w) noexcept {
    if (2.0 * over <= -w) return 0.0;
    if (2.0 * over < w) {
        const double t = over + 0.5 * w;
        return slope * t * t / (2.0 * w);
    }
    return slope * over;
}

// A level detector in dB: the linked peak (or a 10 ms RMS) of what it is given, in dB (floored at -120), then
// rising at the attack and falling at the release (one-pole each, in dB: the textbook log-domain detector).
class DbDetector {
public:
    void set(double attackCoef, double releaseCoef) noexcept { att_ = attackCoef, rel_ = releaseCoef; }
    void setRms(bool rms, double rmsCoef) noexcept { rms_ = rms, rmsCoef_ = rmsCoef; }
    double process(double level) noexcept {
        double x = level;
        if (rms_) {
            ms_ = x * x + (ms_ - x * x) * rmsCoef_;
            if (ms_ < 1e-30) ms_ = 0.0;
            x = std::sqrt(ms_);
        }
        const double target = lib::gainToDb(x, -120.0);
        const double c = target > db_ ? att_ : rel_;
        db_ = target + (db_ - target) * c;
        if (db_ - target < 1e-9 && target - db_ < 1e-9) db_ = target;  // settled
        return db_;
    }
    double value() const noexcept { return db_; }
    void clear() noexcept { db_ = -120.0, ms_ = 0.0; }

private:
    double db_ = -120.0, ms_ = 0.0, att_ = 0.0, rel_ = 0.0, rmsCoef_ = 0.0;
    bool rms_ = false;
};

constexpr std::string_view kDetectModes[] = {"Peak", "RMS"};

// ---------- Dynamics ----------

enum DynParam : uint32_t {
    kLowThr, kLowRatio, kHighThr, kHighRatio, kKnee, kAttack, kRelease, kRange, kDetect, kInGain, kOutGain, kMix, kDynCount
};

const ParamTable& dynParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("low_threshold", "Low threshold", -40.0, -80.0, 0.0, "dB");
        // Below the low threshold: above 1 lifts quiet sound toward it (upward compression), below 1 pushes it
        // down (expansion; 0.1 is all but a gate).
        p.expo("low_ratio", "Low ratio", 1.0, 0.1, 10.0, ":1");
        p.num("high_threshold", "High threshold", -12.0, -80.0, 0.0, "dB");
        // Above the high threshold: above 1 holds loud sound down (compression), below 1 pushes it up (upward
        // expansion).
        p.expo("high_ratio", "High ratio", 2.0, 0.1, 10.0, ":1");
        p.num("knee", "Knee", 6.0, 0.0, 24.0, "dB");
        p.expo("attack", "Attack", 5.0, 0.05, 200.0, "ms");
        p.expo("release", "Release", 100.0, 5.0, 2000.0, "ms");
        p.num("range", "Range", 24.0, 0.0, 48.0, "dB");
        p.pick("detect", "Detection", 0.0, kDetectModes);
        p.num("in_gain", "In gain", 0.0, -24.0, 24.0, "dB");
        p.num("out_gain", "Out gain", 0.0, -24.0, 24.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& dynDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.dynamics", "Dynamics", dynParams(), 0, 0);
    return d;
}

// The two-threshold curve: the gain change in dB at a level (both thresholds' segments, held within +-range).
// `fast` is the level from an instant-attack detector: an upward lift is never more than it allows, so a hit
// after a quiet passage isn't lifted by the whole boost before the detector catches up (no spike), while the
// attack still shapes the downward side and expansion.
struct TwoThresholds {
    double lowThr = -40, lowRatio = 1, highThr = -12, highRatio = 2, knee = 6, range = 24;
    double gainDb(double level, double fast) const noexcept {
        const double slope = 1.0 - 1.0 / lowRatio;
        double low = kneeGain(lowThr - level, slope, knee);
        if (slope > 0.0) low = std::min(low, kneeGain(lowThr - fast, slope, knee));
        const double g = low + kneeGain(level - highThr, 1.0 / highRatio - 1.0, knee);
        return std::clamp(g, -range, range);
    }
};

class Dynamics final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return dynDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        rmsCoef_ = lib::timeCoefficient(0.01, sampleRate);
        return true;
    }
    void clearState() noexcept override {
        det_.clear(), fast_.clear();
        in_.reset(), out_.reset(), mix_.reset();
        gainNow_ = boost_ = cut_ = 0.0;
        levelMax_ = -120.0;
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        curve_.highThr = param(kHighThr, at);
        curve_.lowThr = std::min(param(kLowThr, at), curve_.highThr);
        curve_.lowRatio = std::clamp(param(kLowRatio, at), 0.1, 10.0);
        curve_.highRatio = std::clamp(param(kHighRatio, at), 0.1, 10.0);
        curve_.knee = std::clamp(param(kKnee, at), 0.0, 24.0);
        curve_.range = std::clamp(param(kRange, at), 0.0, 48.0);
        det_.set(lib::timeCoefficient(param(kAttack, at) * 0.001, sr), lib::timeCoefficient(param(kRelease, at) * 0.001, sr));
        det_.setRms(choice(kDetect, at) == 1, rmsCoef_);
        fast_.set(0.0, lib::timeCoefficient(param(kRelease, at) * 0.001, sr));
        inDb_ = param(kInGain, at);
        outDb_ = param(kOutGain, at);
        in_.set(lib::dbToGain(inDb_), kControlFrames);
        out_.set(lib::dbToGain(outDb_), kControlFrames);
        mix_.set(std::clamp(param(kMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double ig = in_.next(), og = out_.next(), mix = mix_.next();
            const double xl = inL[i], xr = inR[i];
            const double l = xl * ig, r = xr * ig;
            const double most = std::max(l < 0 ? -l : l, r < 0 ? -r : r);
            const double level = det_.process(most), fast = fast_.process(most);
            levelMax_ = std::max(levelMax_, level);
            const double g = curve_.gainDb(level, fast);
            gainNow_ = g;
            boost_ = std::max(boost_, g);
            cut_ = std::min(cut_, g);
            const double k = lib::dbToGain(g) * og;
            outL[i] = static_cast<float>(xl + (l * k - xl) * mix);
            outR[i] = static_cast<float>(xr + (r * k - xr) * mix);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(gainNow_);
        out[3] = static_cast<float>(boost_);
        out[4] = positive(cut_);
        out[5] = static_cast<float>(levelMax_);
        out[6] = static_cast<float>(curve_.lowThr);
        out[7] = static_cast<float>(curve_.lowRatio);
        out[8] = static_cast<float>(curve_.highThr);
        out[9] = static_cast<float>(curve_.highRatio);
        out[10] = static_cast<float>(curve_.knee);
        out[11] = static_cast<float>(curve_.range);
        out[12] = static_cast<float>(inDb_);
        out[13] = static_cast<float>(outDb_);
        boost_ = cut_ = 0.0;
        levelMax_ = -120.0;
        return 14;
    }

private:
    DbDetector det_, fast_;
    TwoThresholds curve_;
    Ramp in_, out_, mix_;
    double rmsCoef_ = 0, inDb_ = 0, outDb_ = 0, gainNow_ = 0, boost_ = 0, cut_ = 0, levelMax_ = -120;
};

// ---------- Multiband dynamics (OTT mode) ----------

constexpr std::string_view kMbModes[] = {"Multiband", "OTT"};
constexpr int kBands = 3;
constexpr const char* kBandNames[kBands] = {"Low", "Mid", "High"};
// A ratio at the top of its knob is infinite (a brick wall at the threshold).
constexpr double kMaxRatio = 50.0;
// The most an upward compressor lifts (the quietest sound would otherwise be lifted without end).
constexpr double kMaxBoostDb = 36.0;

// The OTT mode's per-band settings, low to high [Assumption: the values usually given for the "OTT" preset of
// Ableton's Multiband Dynamics, not confirmed from a primary source (2026-11-11)]: downward threshold dB, upward
// threshold dB, upward ratio, attack ms, release ms, band gain dB. Downward ratios are infinite.
struct OttBand {
    double downThr, upThr, upRatio, attackMs, releaseMs, gainDb;
};
constexpr OttBand kOtt[kBands] = {
    {-33.8, -40.8, 4.17, 47.8, 282.0, 10.3},
    {-30.2, -41.8, 4.17, 22.4, 282.0, 5.7},
    {-35.5, -40.8, 4.17, 13.5, 132.0, 10.3},
};

enum MbParam : uint32_t {
    kMbMode, kMbDepth, kMbTime, kMbUp, kMbDown, kMbXLow, kMbXHigh, kMbIn, kMbOut, kMbBand0
};
enum BandParam : uint32_t { kBDownThr, kBDownRatio, kBUpThr, kBUpRatio, kBGain, kBAttack, kBRelease, kBandParams };

const ParamTable& mbParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("mode", "Mode", 1.0, kMbModes);
        p.num("depth", "Depth", 0.5, 0.0, 1.0);
        p.expo("time", "Time", 1.0, 0.1, 10.0, "x");
        p.num("upward", "Upward", 1.0, 0.0, 1.0);
        p.num("downward", "Downward", 1.0, 0.0, 1.0);
        p.expo("xover_low", "Low crossover", 88.3, 40.0, 1000.0, "Hz");
        p.expo("xover_high", "High crossover", 2500.0, 1000.0, 12000.0, "Hz");
        p.num("in_gain", "In gain", 0.0, -24.0, 24.0, "dB");
        p.num("out_gain", "Out gain", 0.0, -24.0, 24.0, "dB");
        // Each band's own (Multiband mode; OTT mode uses its table and adds only the band's gain).
        const double attack[kBands] = {30.0, 15.0, 8.0}, release[kBands] = {250.0, 180.0, 120.0};
        for (int b = 0; b < kBands; ++b) {
            const std::string id = "b" + std::to_string(b + 1) + "_", name = std::string(kBandNames[b]) + " ";
            p.num(id + "down_thr", name + "down threshold", -24.0, -60.0, 0.0, "dB");
            p.expo(id + "down_ratio", name + "down ratio", 4.0, 1.0, kMaxRatio, ":1");
            p.num(id + "up_thr", name + "up threshold", -48.0, -80.0, 0.0, "dB");
            p.expo(id + "up_ratio", name + "up ratio", 2.0, 1.0, kMaxRatio, ":1");
            p.num(id + "gain", name + "gain", 0.0, -24.0, 24.0, "dB");
            p.expo(id + "attack", name + "attack", attack[b], 0.1, 200.0, "ms");
            p.expo(id + "release", name + "release", release[b], 5.0, 2000.0, "ms");
        }
        return p;
    }();
    return t;
}
const ModuleDescriptor& mbDescriptor() {
    static const ModuleDescriptor d = withCpu(effectDescriptor("org.caw.multiband", "Multiband dynamics", mbParams(), 0, 0), CpuClass::Heavy);
    return d;
}

// One channel's three-band Linkwitz-Riley split and its matching all-pass for the dry path.
struct ThreeWay {
    lib::Svf s1, lp1, hp1, s2, lp2, hp2, ap2, dry1, dry2;
    void set(double f1, double f2, double sr) noexcept {
        s1.set(f1, kButterworthQ, sr);
        lp1.setLike(s1), hp1.setLike(s1), dry1.setLike(s1);
        s2.set(f2, kButterworthQ, sr);
        lp2.setLike(s2), hp2.setLike(s2), ap2.setLike(s2), dry2.setLike(s2);
    }
    // x into low, mid and high (they sum to the dry() all-pass of x).
    void split(double x, double band[kBands]) noexcept {
        const lib::SvfOutput a = s1.process(x);
        const double low = lp1.process(a.low).low, rest = hp1.process(a.high).high;
        const lib::SvfOutput b = s2.process(rest);
        band[1] = lp2.process(b.low).low;
        band[2] = hp2.process(b.high).high;
        const lib::SvfOutput c = ap2.process(low);
        band[0] = c.notch - kSqrt2 * c.band;  // the all-pass at the high crossover: x - 2k band
    }
    double dry(double x) noexcept {
        const lib::SvfOutput a = dry1.process(x);
        const lib::SvfOutput b = dry2.process(a.notch - kSqrt2 * a.band);
        return b.notch - kSqrt2 * b.band;
    }
    void clear() noexcept {
        for (lib::Svf* f : {&s1, &lp1, &hp1, &s2, &lp2, &hp2, &ap2, &dry1, &dry2}) f->clear();
    }
    void flush() noexcept {
        for (lib::Svf* f : {&s1, &lp1, &hp1, &s2, &lp2, &hp2, &ap2, &dry1, &dry2}) f->flushDenormals();
    }
};

class Multiband final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return mbDescriptor(); }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void clearState() noexcept override {
        for (auto& s : split_) s.clear();
        for (auto& d : det_) d.clear();
        for (auto& d : fast_) d.clear();
        in_.reset(), out_.reset(), depth_.reset();
        for (int b = 0; b < kBands; ++b) {
            gain_[b].reset();
            grNow_[b] = boost_[b] = cut_[b] = 0.0;
            levelMax_[b] = -120.0;
        }
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        ott_ = choice(kMbMode, at) == 1;
        const double time = std::clamp(param(kMbTime, at), 0.1, 10.0);
        up_ = std::clamp(param(kMbUp, at), 0.0, 1.0);
        down_ = std::clamp(param(kMbDown, at), 0.0, 1.0);
        f1_ = std::clamp(param(kMbXLow, at), 40.0, 1000.0);
        f2_ = std::clamp(param(kMbXHigh, at), 1000.0, 12000.0);
        f2_ = std::max(f2_, f1_ * 2.0);
        for (auto& s : split_) s.set(f1_, f2_, sr), s.flush();  // on the control grid: the same bits at any block size
        in_.set(lib::dbToGain(param(kMbIn, at)), kControlFrames);
        out_.set(lib::dbToGain(param(kMbOut, at)), kControlFrames);
        depth_.set(std::clamp(param(kMbDepth, at), 0.0, 1.0), kControlFrames);
        for (int b = 0; b < kBands; ++b) {
            const uint32_t k = kMbBand0 + b * kBandParams;
            const double bandGain = param(k + kBGain, at);
            double attackMs, releaseMs, makeup;
            if (ott_) {
                const OttBand& o = kOtt[b];
                downThr_[b] = o.downThr, downSlope_[b] = -1.0;
                upThr_[b] = o.upThr, upSlope_[b] = 1.0 - 1.0 / o.upRatio;
                attackMs = o.attackMs, releaseMs = o.releaseMs, makeup = o.gainDb;
            } else {
                downThr_[b] = param(k + kBDownThr, at);
                const double dr = std::clamp(param(k + kBDownRatio, at), 1.0, kMaxRatio);
                downSlope_[b] = dr >= kMaxRatio - 1e-6 ? -1.0 : 1.0 / dr - 1.0;
                upThr_[b] = param(k + kBUpThr, at);
                const double ur = std::clamp(param(k + kBUpRatio, at), 1.0, kMaxRatio);
                upSlope_[b] = ur >= kMaxRatio - 1e-6 ? 1.0 : 1.0 - 1.0 / ur;
                attackMs = param(k + kBAttack, at), releaseMs = param(k + kBRelease, at), makeup = 0.0;
            }
            const double release = lib::timeCoefficient(releaseMs * time * 0.001, sr);
            det_[b].set(lib::timeCoefficient(attackMs * time * 0.001, sr), release);
            fast_[b].set(0.0, release);  // the upward lift's limit (TwoThresholds' note)
            // OTT's makeup follows how much of the compression is used (upward or downward, whichever is more).
            const double scale = std::max(up_, down_);
            gainDb_[b] = makeup * scale + bandGain;
            gain_[b].set(gainDb_[b], kControlFrames);
        }
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double ig = in_.next(), og = out_.next(), depth = depth_.next();
            const double x[2] = {inL[i] * ig, inR[i] * ig};
            double band[2][kBands];
            split_[0].split(x[0], band[0]);
            split_[1].split(x[1], band[1]);
            double y[2] = {0.0, 0.0};
            for (int b = 0; b < kBands; ++b) {
                const double l = band[0][b], r = band[1][b];
                const double most = std::max(l < 0 ? -l : l, r < 0 ? -r : r);
                const double level = det_[b].process(most), fast = fast_[b].process(most);
                levelMax_[b] = std::max(levelMax_[b], level);
                const double upG = std::min({kMaxBoostDb, kneeGain(upThr_[b] - level, upSlope_[b], 6.0),
                                             kneeGain(upThr_[b] - fast, upSlope_[b], 6.0)});
                const double downG = kneeGain(level - downThr_[b], downSlope_[b], 6.0);
                const double g = up_ * upG + down_ * downG;
                grNow_[b] = g;
                boost_[b] = std::max(boost_[b], g);
                cut_[b] = std::min(cut_[b], g);
                const double k = lib::dbToGain(g + gain_[b].next());
                y[0] += l * k;
                y[1] += r * k;
            }
            const double dl = split_[0].dry(x[0]), dr = split_[1].dry(x[1]);
            outL[i] = static_cast<float>((dl + (y[0] - dl) * depth) * og);
            outR[i] = static_cast<float>((dr + (y[1] - dr) * depth) * og);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = ott_ ? 1.0f : 0.0f;
        out[3] = static_cast<float>(f1_);
        out[4] = static_cast<float>(f2_);
        // Per band (low, mid, high), 7 floats each from 5: level peak dB, gain change now dB, most boost, most
        // cut, down threshold, up threshold, band gain dB (with OTT's makeup).
        for (int b = 0; b < kBands; ++b) {
            float* o = out + 5 + 7 * b;
            o[0] = static_cast<float>(levelMax_[b]);
            o[1] = static_cast<float>(grNow_[b]);
            o[2] = static_cast<float>(boost_[b]);
            o[3] = positive(cut_[b]);
            o[4] = static_cast<float>(downThr_[b]);
            o[5] = static_cast<float>(upThr_[b]);
            o[6] = static_cast<float>(gainDb_[b]);
            boost_[b] = cut_[b] = 0.0;
            levelMax_[b] = -120.0;
        }
        return 5 + 7 * kBands;
    }

private:
    ThreeWay split_[2];
    DbDetector det_[kBands], fast_[kBands];
    Ramp in_, out_, depth_, gain_[kBands];
    bool ott_ = true;
    double up_ = 1, down_ = 1, f1_ = 88.3, f2_ = 2500;
    double downThr_[kBands] = {}, downSlope_[kBands] = {}, upThr_[kBands] = {}, upSlope_[kBands] = {}, gainDb_[kBands] = {};
    double grNow_[kBands] = {}, boost_[kBands] = {}, cut_[kBands] = {}, levelMax_[kBands] = {-120, -120, -120};
};

// ---------- De-esser ----------

constexpr std::string_view kDeessModes[] = {"Split", "Wideband"};
enum DeessParam : uint32_t { kDFreq, kDThreshold, kDRange, kDRelease, kDMode, kDListen, kDeessCount };

const ParamTable& deessParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.expo("freq", "Frequency", 6000.0, 2000.0, 16000.0, "Hz");
        p.num("threshold", "Threshold", -30.0, -60.0, 0.0, "dB");
        p.num("range", "Range", 12.0, 0.0, 24.0, "dB");
        p.expo("release", "Release", 60.0, 10.0, 500.0, "ms");
        p.pick("mode", "Mode", 0.0, kDeessModes);
        p.pick("listen", "Listen", 0.0, kOffOn);
        return p;
    }();
    return t;
}
const ModuleDescriptor& deessDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.deesser", "De-esser", deessParams(), 0, 0);
    return d;
}

// The sibilance is the input above `freq` (a Linkwitz-Riley 4th-order split: the low and high parts sum to an
// all-pass, as in the multiband). Its level over the threshold is held down at 6:1 (no more than the range);
// Split turns down only the high part (lp + g hp), Wideband both (g (lp + hp)). Mode and listen changes
// cross-fade over 5 ms.
class Deesser final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return deessDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        attack_ = lib::timeCoefficient(0.0005, sampleRate);
        fadeStep_ = 1.0 / (0.005 * sampleRate);
        return true;
    }
    void clearState() noexcept override {
        for (auto& c : split_)
            for (auto& f : c) f.clear();
        env_ = 0.0;
        grNow_ = grMax_ = 0.0;
        levelMax_ = -120.0;
        fresh_ = true;
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        freq_ = std::clamp(param(kDFreq, at), 2000.0, 16000.0);
        split_[0][0].set(freq_, kButterworthQ, sr);
        for (auto& c : split_)
            for (auto& f : c) f.setLike(split_[0][0]), f.flushDenormals();  // on the control grid: any block size
        threshold_ = param(kDThreshold, at);
        range_ = std::clamp(param(kDRange, at), 0.0, 24.0);
        release_ = lib::timeCoefficient(param(kDRelease, at) * 0.001, sr);
        wideTarget_ = choice(kDMode, at) == 1 ? 1.0 : 0.0;
        listenTarget_ = on(kDListen, at) ? 1.0 : 0.0;
        if (fresh_) wide_ = wideTarget_, listen_ = listenTarget_, fresh_ = false;
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double x[2] = {inL[i], inR[i]};
            double lo[2], hi[2];
            for (int c = 0; c < 2; ++c) {
                const lib::SvfOutput a = split_[c][0].process(x[c]);
                lo[c] = split_[c][1].process(a.low).low;
                hi[c] = split_[c][2].process(a.high).high;
            }
            const double levelDb = lib::gainToDb(std::max(std::fabs(hi[0]), std::fabs(hi[1])), -120.0);
            levelMax_ = std::max(levelMax_, levelDb);
            const double target = std::max(-range_, lib::compressorGainDb(levelDb, threshold_, 6.0, 6.0));
            env_ = target + (env_ - target) * (target < env_ ? attack_ : release_);
            if (env_ - target < 1e-9 && target - env_ < 1e-9) env_ = target;
            grNow_ = env_;
            grMax_ = std::min(grMax_, env_);
            const double g = lib::dbToGain(env_);
            wide_ += std::clamp(wideTarget_ - wide_, -fadeStep_, fadeStep_);
            listen_ += std::clamp(listenTarget_ - listen_, -fadeStep_, fadeStep_);
            float* o[2] = {outL + i, outR + i};
            for (int c = 0; c < 2; ++c) {
                // Split and wideband, cross-faded by `wide_`; then the sidechain itself while listening.
                const double split = lo[c] + g * hi[c], wide = g * (lo[c] + hi[c]);
                const double y = split + (wide - split) * wide_;
                *o[c] = static_cast<float>(y + (hi[c] - y) * listen_);
            }
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = positive(grNow_);
        out[3] = positive(grMax_);
        out[4] = static_cast<float>(levelMax_);
        out[5] = static_cast<float>(threshold_);
        out[6] = static_cast<float>(freq_);
        out[7] = static_cast<float>(range_);
        out[8] = static_cast<float>(wideTarget_);
        grMax_ = 0.0;
        levelMax_ = -120.0;
        return 9;
    }

private:
    lib::Svf split_[2][3];  // per side: the shared first section, the low's second, the high's second
    double freq_ = 6000, threshold_ = -30, range_ = 12, attack_ = 0, release_ = 0, env_ = 0;
    double wide_ = 0, wideTarget_ = 0, listen_ = 0, listenTarget_ = 0, fadeStep_ = 0.004;
    double grNow_ = 0, grMax_ = 0, levelMax_ = -120;
    bool fresh_ = true;
};

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

}  // namespace

void registerFxDynamics(ModuleRegistry& registry) {
    registry.add(dynDescriptor(), &make<Dynamics>);
    registry.add(mbDescriptor(), &make<Multiband>);
    registry.add(deessDescriptor(), &make<Deesser>);
    registerFxDrive(registry);
}

}  // namespace caw::fx
