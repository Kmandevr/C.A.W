// The built-in kit effects (#173): a multimode filter with LFO and envelope, phaser, flanger and a utility.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <new>
#include <vector>

#include "caw/library/dynamics.hpp"
#include "caw/library/eq.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/lfo.hpp"
#include "caw/library/stereo.hpp"

// Original code (C.A.W. is Apache-2.0), on the Library's filters and LFO.

namespace caw::fx {

namespace {

constexpr std::string_view kLfoSyncs[] = {"Off", "1/16", "1/8", "1/4", "1/2", "1 bar", "2 bars", "4 bars"};
constexpr double kLfoSyncBeats[] = {0.0, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0};
constexpr std::string_view kLfoShapes[] = {"Sine", "Triangle", "Saw up", "Saw down", "Square", "Sample & hold", "Smooth random"};
constexpr uint32_t kResponsePoints = 64;

// An LFO pair read at the control rate: the right one `stereo` x half a cycle on. Free at `hz`, or (sync > 0 and
// the song playing) locked to the song's position.
struct StereoLfo {
    lib::Lfo left, right;
    double l = 0.0, r = 0.0;
    void prepare(double sr) noexcept {
        left.prepare(sr);
        right.prepare(sr);
    }
    void clear() noexcept {
        left.retrigger();
        right.retrigger();
        l = r = 0.0;
    }
    void step(int shape, double hz, int sync, double stereo, bool playing, double beat, double tempo, uint32_t frames) noexcept {
        const auto s = static_cast<lib::LfoShape>(std::clamp(shape, 0, 6));
        left.setShape(s);
        right.setShape(s);
        right.setPhaseOffset(0.5 * std::clamp(stereo, 0.0, 1.0));
        const int k = std::clamp(sync, 0, 7);
        if (k > 0) {
            left.setRateBeats(kLfoSyncBeats[k], tempo);
            right.setRateBeats(kLfoSyncBeats[k], tempo);
            if (playing) {
                left.syncToBeat(beat, kLfoSyncBeats[k]);
                right.syncToBeat(beat, kLfoSyncBeats[k]);
            }
        } else {
            left.setRateHz(hz);
            right.setRateHz(hz);
        }
        l = left.block(static_cast<int>(frames));
        r = right.block(static_cast<int>(frames));
    }
};

// ---------- Filter ----------

enum FilterParam : uint32_t {
    kType, kCutoff, kResonance, kDrive, kLfoAmount, kLfoRate, kLfoSync, kLfoShape, kLfoStereo, kEnvAmount, kEnvAttack,
    kEnvRelease, kFMix, kFilterCount
};
constexpr std::string_view kFilterTypes[] = {"Low-pass 12", "Low-pass 24", "High-pass 12", "High-pass 24", "Band-pass",
                                             "Notch", "Ladder low-pass", "Ladder high-pass", "Ladder band-pass"};
enum FilterType : int { kLp12, kLp24, kHp12, kHp24, kBp, kNotch, kLadLp, kLadHp, kLadBp };

const ParamTable& filterParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("type", "Type", kLp24, kFilterTypes);
        p.expo("cutoff", "Cutoff", 1200.0, 20.0, 20000.0, "Hz");
        p.num("resonance", "Resonance", 0.2, 0.0, 1.0);
        p.num("drive", "Drive", 0.0, 0.0, 24.0, "dB");
        p.num("lfo_amount", "LFO amount", 0.0, -1.0, 1.0);
        p.expo("lfo_rate", "LFO rate", 1.0, 0.02, 20.0, "Hz");
        p.pick("lfo_sync", "LFO sync", 0.0, kLfoSyncs);
        p.pick("lfo_shape", "LFO shape", 0.0, kLfoShapes);
        p.num("lfo_stereo", "LFO stereo", 0.0, 0.0, 1.0);
        p.num("env_amount", "Envelope amount", 0.0, -1.0, 1.0);
        p.expo("env_attack", "Envelope attack", 5.0, 0.1, 100.0, "ms");
        p.expo("env_release", "Envelope release", 150.0, 5.0, 2000.0, "ms");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& filterDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.filter", "Filter", filterParams(), 0, 0);
    return d;
}

class FilterEffect final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return filterDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        lfo_.prepare(sr);
        return true;
    }
    void clearState() noexcept override {
        for (int c = 0; c < 2; ++c) a_[c].clear(), b_[c].clear(), ladder_[c].clear();
        env_.clear();
        lfo_.clear();
        mix_.reset(), drive_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        type_ = std::clamp(choice(kType, at), 0, 8);
        resonance_ = std::clamp(param(kResonance, at), 0.0, 1.0);
        env_.setCoefficients(lib::timeCoefficient(param(kEnvAttack, at) * 0.001, sr), lib::timeCoefficient(param(kEnvRelease, at) * 0.001, sr));
        double beat = 0.0;
        const bool playing = beatAt(at, beat);
        lfo_.step(choice(kLfoShape, at), param(kLfoRate, at), choice(kLfoSync, at), param(kLfoStereo, at), playing, beat,
                  tempo(), kControlFrames);
        const double lfoAmt = std::clamp(param(kLfoAmount, at), -1.0, 1.0), envAmt = std::clamp(param(kEnvAmount, at), -1.0, 1.0);
        const double e = std::min(1.0, env_.value());
        const double cutoff = param(kCutoff, at);
        cutoff_[0] = lib::shiftCutoff(cutoff, 4.0 * (lfoAmt * lfo_.l + envAmt * e), sr);
        cutoff_[1] = lib::shiftCutoff(cutoff, 4.0 * (lfoAmt * lfo_.r + envAmt * e), sr);
        const double q = lib::resonanceQ(resonance_);
        for (int c = 0; c < 2; ++c) {
            if (type_ == kLp24 || type_ == kHp24) {
                a_[c].set(cutoff_[c], 0.54119610014619698, sr);
                b_[c].set(cutoff_[c], 1.30656296487637652 * q / 0.70710678118654752, sr);
            } else {
                a_[c].set(cutoff_[c], q, sr);
            }
            if (type_ >= kLadLp) ladder_[c].set(cutoff_[c], resonance_, sr);
        }
        const double g = lib::dbToGain(std::clamp(param(kDrive, at), 0.0, 24.0));
        drive_.set(g, kControlFrames);
        mix_.set(std::clamp(param(kFMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double x[2] = {inL[i], inR[i]};
            env_.process(std::max(x[0] < 0 ? -x[0] : x[0], x[1] < 0 ? -x[1] : x[1]));
            const double g = drive_.next(), m = mix_.next();
            const bool driven = g > 1.0001;
            double y[2];
            for (int c = 0; c < 2; ++c) {
                const double v = driven ? lib::fastTanh(x[c] * g) : x[c];
                double o;
                switch (type_) {
                    case kLp12: o = a_[c].lowpass(v); break;
                    case kLp24: o = b_[c].lowpass(a_[c].lowpass(v)); break;
                    case kHp12: o = a_[c].highpass(v); break;
                    case kHp24: o = b_[c].highpass(a_[c].highpass(v)); break;
                    case kBp: {
                        const lib::SvfOutput s = a_[c].process(v);
                        o = s.band / lib::resonanceQ(resonance_);  // unity at the centre
                        break;
                    }
                    case kNotch: o = a_[c].process(v).notch; break;
                    case kLadHp: o = ladder_[c].process<lib::LadderMode::HighPass>(v); break;
                    case kLadBp: o = ladder_[c].process<lib::LadderMode::BandPass>(v); break;
                    default: o = ladder_[c].process<lib::LadderMode::LowPass>(v); break;
                }
                if (driven) o *= 1.0 / std::sqrt(g);  // the drive's level, made up halfway
                y[c] = x[c] + (o - x[c]) * m;
            }
            outL[i] = static_cast<float>(y[0]);
            outR[i] = static_cast<float>(y[1]);
        }
    }
    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(type_);
        out[3] = static_cast<float>(cutoff_[0]);
        out[4] = static_cast<float>(cutoff_[1]);
        out[5] = static_cast<float>(resonance_);
        out[6] = static_cast<float>(lfo_.l);
        out[7] = static_cast<float>(std::min(1.0, env_.value()));
        out[8] = static_cast<float>(kResponsePoints);
        // The response at the left cutoff, 20 Hz .. 20 kHz on a log grid (the analog prototypes).
        const double sr = rate(), pi = 3.14159265358979323846;
        const double gc = std::tan(pi * std::min(cutoff_[0], 0.49 * sr) / sr), k = 1.0 / lib::resonanceQ(resonance_);
        const double lk = 3.95 * resonance_;
        const double k1 = 1.0 / 0.54119610014619698, k2 = 0.70710678118654752 * k / 1.30656296487637652;  // the 24 dB stages
        for (uint32_t j = 0; j < kResponsePoints; ++j) {
            if (!watched) {
                out[9 + j] = 0.0f;
                continue;
            }
            const double f = std::min(20.0 * std::pow(1000.0, j / (kResponsePoints - 1.0)), 0.49 * sr);
            const std::complex<double> s(0.0, std::tan(pi * f / sr) / gc);
            std::complex<double> h;
            auto svf = [&](double kk) { return s * s + kk * s + 1.0; };
            switch (type_) {
                case kLp12: h = 1.0 / svf(k); break;
                case kLp24: h = 1.0 / (svf(k1) * svf(k2)); break;
                case kHp12: h = s * s / svf(k); break;
                case kHp24: h = s * s * s * s / (svf(k1) * svf(k2)); break;
                case kBp: h = k * s / svf(k); break;
                case kNotch: h = (s * s + 1.0) / svf(k); break;
                default: {
                    const std::complex<double> p = (1.0 + s) * (1.0 + s) * (1.0 + s) * (1.0 + s) + lk;
                    const double in = 1.0 + 0.5 * lk;
                    h = type_ == kLadHp ? in * s * s * s * s / p : type_ == kLadBp ? 4.0 * in * s * s / p : in / p;
                }
            }
            const double m = std::abs(h);
            out[9 + j] = static_cast<float>(m > 1e-12 ? 20.0 * std::log10(m) : -240.0);
        }
        return 9 + kResponsePoints;
    }

private:
    lib::Svf a_[2], b_[2];
    lib::MultiLadder ladder_[2];
    lib::EnvelopeFollower env_;
    StereoLfo lfo_;
    Ramp mix_, drive_;
    int type_ = kLp24;
    double resonance_ = 0.2, cutoff_[2] = {1200, 1200};
};

// ---------- Phaser ----------

enum PhaserParam : uint32_t { kStages, kPRate, kPSync, kPDepth, kCenter, kPFeedback, kPStereo, kPMix, kPhaserCount };
constexpr std::string_view kStageChoices[] = {"2", "4", "6", "8", "10", "12"};
constexpr uint32_t kMaxStages = 12;

const ParamTable& phaserParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("stages", "Stages", 2.0, kStageChoices);
        p.expo("rate", "Rate", 0.4, 0.02, 10.0, "Hz");
        p.pick("sync", "Sync", 0.0, kLfoSyncs);
        p.num("depth", "Depth", 0.7, 0.0, 1.0);
        p.expo("center", "Centre", 700.0, 100.0, 8000.0, "Hz");
        p.num("feedback", "Feedback", 0.4, -0.95, 0.95);
        p.num("stereo", "Stereo", 0.5, 0.0, 1.0);
        p.num("mix", "Mix", 0.5, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& phaserDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.phaser", "Phaser", phaserParams(), 0, 0);
    return d;
}

// A chain of first-order all-passes per side, their corner swept by an LFO over +-3 octaves x depth around the
// centre; the chain's output fed back to its input; half mixed with the dry it notches. The all-pass coefficient
// is worked out at control points (a tan) and glides in a straight line between them.
class Phaser final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return phaserDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        lfo_.prepare(sr);
        return true;
    }
    void clearState() noexcept override {
        for (auto& c : z_) for (double& v : c) v = 0.0;
        last_[0] = last_[1] = 0.0;
        lfo_.clear();
        coef_[0].reset(), coef_[1].reset(), mix_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        stages_ = 2 * static_cast<uint32_t>(std::clamp(choice(kStages, at), 0, 5) + 1);
        double beat = 0.0;
        const bool playing = beatAt(at, beat);
        lfo_.step(0, param(kPRate, at), choice(kPSync, at), param(kPStereo, at), playing, beat, tempo(), kControlFrames);
        const double depth = std::clamp(param(kPDepth, at), 0.0, 1.0), centre = param(kCenter, at);
        const double v[2] = {lfo_.l, lfo_.r};
        for (int c = 0; c < 2; ++c) {
            freq_[c] = lib::shiftCutoff(centre, 3.0 * depth * v[c], sr);
            const double t = detTan(kPi * freq_[c] / sr);
            coef_[c].set((t - 1.0) / (t + 1.0), kControlFrames);
        }
        feedback_ = std::clamp(param(kPFeedback, at), -0.95, 0.95);
        mix_.set(std::clamp(param(kPMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double x[2] = {inL[i], inR[i]};
            const double m = mix_.next();
            double y[2];
            for (int c = 0; c < 2; ++c) {
                const double a = coef_[c].next();
                double s = x[c] + feedback_ * last_[c];
                for (uint32_t k = 0; k < stages_; ++k) {
                    const double o = a * s + z_[c][k];
                    z_[c][k] = s - a * o;
                    if (z_[c][k] < 1e-20 && z_[c][k] > -1e-20) z_[c][k] = 0.0;
                    s = o;
                }
                last_[c] = s;
                y[c] = x[c] + (s - x[c]) * m;
            }
            outL[i] = static_cast<float>(y[0]);
            outR[i] = static_cast<float>(y[1]);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(lfo_.l);
        out[3] = static_cast<float>(lfo_.r);
        out[4] = static_cast<float>(freq_[0]);
        out[5] = static_cast<float>(freq_[1]);
        out[6] = static_cast<float>(stages_);
        return 7;
    }

private:
    double z_[2][kMaxStages] = {}, last_[2] = {}, feedback_ = 0.4, freq_[2] = {700, 700};
    uint32_t stages_ = 6;
    StereoLfo lfo_;
    Ramp coef_[2], mix_;
};

// ---------- Flanger ----------

enum FlangerParam : uint32_t { kFDelay, kFDepth, kFRate, kFSync, kFFeedback, kFStereo, kFlMix, kFlangerCount };

const ParamTable& flangerParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.expo("delay", "Delay", 2.0, 0.2, 10.0, "ms");
        p.num("depth", "Depth", 0.7, 0.0, 1.0);
        p.expo("rate", "Rate", 0.25, 0.02, 10.0, "Hz");
        p.pick("sync", "Sync", 0.0, kLfoSyncs);
        p.num("feedback", "Feedback", 0.6, -0.95, 0.95);
        p.num("stereo", "Stereo", 0.5, 0.0, 1.0);
        p.num("mix", "Mix", 0.5, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& flangerDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.flanger", "Flanger", flangerParams(), 0, 4800);
    return d;
}

// A short delay per side swept by an LFO (from 5 % to 195 % of `delay` at full depth), read between samples
// (4-point Hermite), fed back; mixed with the dry it combs, and the comb sweeps.
class Flanger final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return flangerDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        try {
            size_ = 1;
            while (size_ < static_cast<size_t>(0.025 * sr) + 8) size_ <<= 1;
            line_[0].assign(size_, 0.0f);
            line_[1].assign(size_, 0.0f);
        } catch (...) {
            return false;
        }
        lfo_.prepare(sr);
        return true;
    }
    void clearState() noexcept override {
        for (auto& l : line_) std::fill(l.begin(), l.end(), 0.0f);
        pos_ = 0;
        lfo_.clear();
        delay_[0].reset(), delay_[1].reset(), mix_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        double beat = 0.0;
        const bool playing = beatAt(at, beat);
        lfo_.step(1, param(kFRate, at), choice(kFSync, at), param(kFStereo, at), playing, beat, tempo(), kControlFrames);
        const double base = param(kFDelay, at) * 0.001 * sr, depth = 0.95 * std::clamp(param(kFDepth, at), 0.0, 1.0);
        delay_[0].set(std::max(2.0, base * (1.0 + depth * lfo_.l)), kControlFrames);
        delay_[1].set(std::max(2.0, base * (1.0 + depth * lfo_.r)), kControlFrames);
        feedback_ = std::clamp(param(kFFeedback, at), -0.95, 0.95);
        mix_.set(std::clamp(param(kFlMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const size_t mask = size_ - 1;
        for (uint32_t i = 0; i < n; ++i) {
            const double x[2] = {inL[i], inR[i]};
            const double m = mix_.next();
            double y[2];
            for (int c = 0; c < 2; ++c) {
                const double back = delay_[c].next();
                const size_t whole = static_cast<size_t>(back);
                const double t = back - static_cast<double>(whole);
                const float* line = line_[c].data();
                const double ym1 = line[(pos_ - whole + 1) & mask], y0 = line[(pos_ - whole) & mask];
                const double y1 = line[(pos_ - whole - 1) & mask], y2 = line[(pos_ - whole - 2) & mask];
                const double c1 = 0.5 * (y1 - ym1), c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2;
                const double c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1);
                const double d = ((c3 * t + c2) * t + c1) * t + y0;
                double w = x[c] + feedback_ * d;
                w = w > 1e4 ? 1e4 : (w < -1e4 ? -1e4 : w);
                line_[c][pos_] = (w < 1e-20 && w > -1e-20) ? 0.0f : static_cast<float>(w);
                y[c] = x[c] + (d - x[c]) * m;
            }
            pos_ = (pos_ + 1) & mask;
            outL[i] = static_cast<float>(y[0]);
            outR[i] = static_cast<float>(y[1]);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(lfo_.l);
        out[3] = static_cast<float>(lfo_.r);
        out[4] = static_cast<float>(delay_[0].value * 1000.0 / rate());
        out[5] = static_cast<float>(delay_[1].value * 1000.0 / rate());
        return 6;
    }

private:
    std::vector<float> line_[2];
    size_t size_ = 0, pos_ = 0;
    double feedback_ = 0.6;
    StereoLfo lfo_;
    Ramp delay_[2], mix_;
};

// ---------- Utility ----------

enum UtilityParam : uint32_t { kGain, kInvertL, kInvertR, kChannels, kUWidth, kPan, kBassMono, kBassFreq, kDcBlock, kUtilityCount };
constexpr std::string_view kChannelModes[] = {"Stereo", "Mono", "Left", "Right", "Swap"};
enum ChannelMode : int { kAsIs, kMono, kLeftOnly, kRightOnly, kSwap };

const ParamTable& utilityParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("gain", "Gain", 0.0, -60.0, 24.0, "dB");
        p.pick("invert_l", "Invert left", 0.0, kOffOn);
        p.pick("invert_r", "Invert right", 0.0, kOffOn);
        p.pick("channels", "Channels", 0.0, kChannelModes);
        p.num("width", "Width", 1.0, 0.0, 2.0);
        p.num("pan", "Pan", 0.0, -1.0, 1.0);
        p.pick("bass_mono", "Bass mono", 0.0, kOffOn);
        p.expo("bass_freq", "Bass mono below", 120.0, 40.0, 500.0, "Hz");
        p.pick("dc_block", "DC block", 0.0, kOffOn);
        return p;
    }();
    return t;
}
const ModuleDescriptor& utilityDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.utility", "Utility", utilityParams(), 0, 0);
    return d;
}

class Utility final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return utilityDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        for (auto& d : dc_) d.set(8.0, sr);
        return true;
    }
    void clearState() noexcept override {
        for (auto& d : dc_) d.clear();
        side_.clear();
        gain_.reset(), width_.reset(), pan_.reset();
        lr_ = ll_ = rr_ = 0.0;
    }
    void control(uint32_t at) noexcept override {
        gain_.set(lib::dbToGain(param(kGain, at)), kControlFrames);
        invL_ = on(kInvertL, at) ? -1.0 : 1.0;
        invR_ = on(kInvertR, at) ? -1.0 : 1.0;
        mode_ = std::clamp(choice(kChannels, at), 0, 4);
        width_.set(std::clamp(param(kUWidth, at), 0.0, 2.0), kControlFrames);
        pan_.set(std::clamp(param(kPan, at), -1.0, 1.0), kControlFrames);
        bassMono_ = on(kBassMono, at);
        side_.set(param(kBassFreq, at), 0.70710678118654752, rate());
        if (!bassMono_) side_.clear();
        dcBlock_ = on(kDcBlock, at);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            double l = inL[i], r = inR[i];
            if (dcBlock_) l = dc_[0].high(l), r = dc_[1].high(r);
            switch (mode_) {
                case kMono: l = r = 0.5 * (l + r); break;
                case kLeftOnly: r = l; break;
                case kRightOnly: l = r; break;
                case kSwap: std::swap(l, r); break;
                default: break;
            }
            l *= invL_;
            r *= invR_;
            const double w = width_.next(), p = pan_.next(), g = gain_.next();
            if (bassMono_) {  // the side below the corner removed: the bass sits in the middle
                const double mid = 0.5 * (l + r), side = side_.highpass(0.5 * (l - r));
                l = mid + side, r = mid - side;
            }
            lib::applyWidth(w, l, r);
            const lib::PanGains pg = lib::balanceGains(p);
            l *= pg.left * g;
            r *= pg.right * g;
            lr_ += l * r, ll_ += l * l, rr_ += r * r;
            outL[i] = static_cast<float>(l);
            outR[i] = static_cast<float>(r);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        const double den = std::sqrt(ll_ * rr_);
        out[2] = static_cast<float>(den > 1e-20 ? lr_ / den : 0.0);  // -1 (out of phase) .. 1 (mono)
        out[3] = static_cast<float>(lib::gainToDb(gain_.value));
        out[4] = static_cast<float>(width_.value);
        out[5] = static_cast<float>(pan_.value);
        lr_ = ll_ = rr_ = 0.0;
        return 6;
    }

private:
    lib::OnePole dc_[2];
    lib::Svf side_;
    Ramp gain_, width_, pan_;
    double invL_ = 1, invR_ = 1, lr_ = 0, ll_ = 0, rr_ = 0;
    int mode_ = 0;
    bool bassMono_ = false, dcBlock_ = false;
};

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

}  // namespace

void registerKit(ModuleRegistry& registry) {
    registry.add(filterDescriptor(), &make<FilterEffect>);
    registry.add(phaserDescriptor(), &make<Phaser>);
    registry.add(flangerDescriptor(), &make<Flanger>);
    registry.add(utilityDescriptor(), &make<Utility>);
}

}  // namespace caw::fx
