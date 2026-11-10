// The built-in reverb and delay (#173): "org.caw.reverb.pro" and "org.caw.delay.pro", with sync, filters, ducking, freeze.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <vector>

#include "caw/library/dynamics.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/reverb.hpp"

// Original code (C.A.W. is Apache-2.0). The reverb is the Library's 8-line feedback delay network
// (caw/library/reverb.hpp) run wet only, with the pre-delay, filters, ducking and mix around it here.

namespace caw::fx {

namespace {

// Ducking: the input's level (5 ms up, 250 ms down) turns the wet down by up to 30 dB x `duck`, fully from 0 dBFS,
// not at all below -50 dBFS.
struct Ducker {
    lib::EnvelopeFollower follower;
    double amount = 0.0, reduction = 0.0, most = 0.0;  // reduction now and its most since the last display, in dB
    void prepare(double sr) noexcept { follower.setCoefficients(lib::timeCoefficient(0.005, sr), lib::timeCoefficient(0.25, sr)); }
    double gain(double l, double r) noexcept {
        const double level = follower.process(std::max(l < 0 ? -l : l, r < 0 ? -r : r));
        if (amount <= 0.0) return 1.0;
        const double over = std::clamp((lib::gainToDb(level, -200.0) + 50.0) / 50.0, 0.0, 1.0);
        reduction = 30.0 * amount * over;
        most = std::max(most, reduction);
        return lib::dbToGain(-reduction);
    }
    void clear() noexcept {
        follower.clear();
        reduction = most = 0.0;
    }
};

// ---------- Reverb ----------

enum ReverbParam : uint32_t {
    kSize, kDecay, kPreDelay, kPreSync, kDamping, kLowCut, kHighCut, kWidth, kMod, kModRate, kFreeze, kDuck, kMix, kReverbCount
};
constexpr std::string_view kPreSyncs[] = {"Free", "1/64", "1/32", "1/16", "1/16 D", "1/8", "1/8 D", "1/4"};
constexpr double kPreSyncWholes[] = {0.0, 0.015625, 0.03125, 0.0625, 0.09375, 0.125, 0.1875, 0.25};
constexpr double kMaxPreDelay = 1.0;  // seconds (a synced quarter note below 60 BPM is held there)

const ParamTable& reverbParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("size", "Size", 0.6, 0.0, 1.0);
        p.expo("decay", "Decay", 2.5, 0.1, 30.0, "s");
        p.num("predelay", "Pre-delay", 15.0, 0.0, 500.0, "ms");
        p.pick("predelay_sync", "Pre-delay sync", 0.0, kPreSyncs);
        p.num("damping", "Damping", 0.5, 0.0, 1.0);
        p.expo("low_cut", "Low cut", 120.0, 20.0, 2000.0, "Hz");
        p.expo("high_cut", "High cut", 9000.0, 1000.0, 20000.0, "Hz");
        p.num("width", "Width", 1.0, 0.0, 2.0);
        p.num("mod", "Modulation", 0.3, 0.0, 1.0);
        p.expo("mod_rate", "Modulation rate", 0.7, 0.05, 5.0, "Hz");
        p.pick("freeze", "Freeze", 0.0, kOffOn);
        p.num("duck", "Ducking", 0.0, 0.0, 1.0);
        p.num("mix", "Mix", 0.25, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& reverbDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.reverb.pro", "Reverb", reverbParams(), 0, kInfiniteTail);
    return d;
}

class ReverbPro final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return reverbDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t maxFrames) noexcept override {
        try {
            reverb_.prepare(sampleRate, static_cast<int>(maxFrames), kMaxPreDelay);
        } catch (...) {
            return false;
        }
        duck_.prepare(sampleRate);
        return true;
    }
    void clearState() noexcept override {
        reverb_.clear();
        for (auto& f : low_) f.clear();
        for (auto& f : high_) f.clear();
        duck_.clear();
        mix_.reset();
        wetPeak_ = 0.0;
    }
    uint64_t idleFrames() const noexcept override {
        return static_cast<uint64_t>((settings_.preDelay + 0.2) * rate());  // the pre-delay, then 0.2 s of a silent tail
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        lib::ReverbSettings s;
        s.size = param(kSize, at);
        s.decay = param(kDecay, at);
        const int sync = std::clamp(choice(kPreSync, at), 0, 7);
        s.preDelay = sync > 0 ? kPreSyncWholes[sync] * 240.0 / tempo() : param(kPreDelay, at) * 0.001;
        s.preDelay = std::min(s.preDelay, kMaxPreDelay);
        s.damping = param(kDamping, at);
        s.width = param(kWidth, at);
        s.mix = 1.0;  // wet only: the dry/wet mix is ours, after the filters and the ducking
        s.modulation = param(kMod, at);
        s.modRate = param(kModRate, at);
        s.freeze = on(kFreeze, at);
        reverb_.setLight(quality() == kQualityEco);
        if (s.size != settings_.size || s.decay != settings_.decay || s.preDelay != settings_.preDelay ||
            s.damping != settings_.damping || s.width != settings_.width || s.modulation != settings_.modulation ||
            s.modRate != settings_.modRate || s.freeze != settings_.freeze || !set_) {
            reverb_.set(s);
            settings_ = s;
            set_ = true;
        }
        const double lowCut = param(kLowCut, at), highCut = param(kHighCut, at);
        useLow_ = lowCut > 20.5;
        useHigh_ = highCut < 19999.0;
        for (auto& f : low_) f.set(lowCut, 0.70710678118654752, sr);
        for (auto& f : high_) f.set(highCut, 0.70710678118654752, sr);
        duck_.amount = std::clamp(param(kDuck, at), 0.0, 1.0);
        mix_.set(std::clamp(param(kMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = inL[i], xr = inR[i];
            float wl = inL[i], wr = inR[i];
            reverb_.process(wl, wr);
            double l = wl, r = wr;
            if (useLow_) l = low_[0].highpass(l), r = low_[1].highpass(r);
            if (useHigh_) l = high_[0].lowpass(l), r = high_[1].lowpass(r);
            const double g = duck_.gain(xl, xr);
            l *= g;
            r *= g;
            wetPeak_ = std::max(wetPeak_, std::max(l < 0 ? -l : l, r < 0 ? -r : r));
            const double m = mix_.next();
            outL[i] = static_cast<float>(xl + (l - xl) * m);
            outR[i] = static_cast<float>(xr + (r - xr) * m);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = static_cast<float>(lib::gainToDb(wetPeak_));
        out[2] = outPeakDb();
        out[3] = static_cast<float>(duck_.most);
        out[4] = static_cast<float>(settings_.decay);
        out[5] = static_cast<float>(settings_.preDelay);
        out[6] = settings_.freeze ? 1.0f : 0.0f;
        out[7] = static_cast<float>(settings_.size);
        wetPeak_ = 0.0;
        duck_.most = 0.0;
        return 8;
    }

private:
    lib::Reverb reverb_;
    lib::ReverbSettings settings_;
    bool set_ = false, useLow_ = true, useHigh_ = true;
    lib::Svf low_[2], high_[2];
    Ducker duck_;
    Ramp mix_;
    double wetPeak_ = 0.0;
};

// ---------- Delay ----------

enum DelayParam : uint32_t {
    kMode, kSync, kTime, kSyncR, kTimeR, kOffset, kFeedback, kDLowCut, kDHighCut, kDrive, kModDepth, kDModRate, kDDuck,
    kDFreeze, kDMix, kDelayCount
};
constexpr std::string_view kDelayModes[] = {"Stereo", "Ping-pong", "Dual"};
enum DelayMode : int { kStereoMode, kPingPong, kDual };
constexpr double kMaxDelay = 4.0;      // seconds (a longer synced division is held there)
constexpr double kMaxModDelay = 0.003; // the deepest sweep, seconds either way

const ParamTable& delayParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("mode", "Mode", 0.0, kDelayModes);
        p.pick("sync", "Sync", 7.0, kSyncDivisions);  // 1/8 dotted
        p.expo("time", "Time (free)", 375.0, 1.0, 4000.0, "ms");
        p.pick("sync_r", "Right sync (dual)", 9.0, kSyncDivisions);  // 1/4
        p.expo("time_r", "Right time (dual, free)", 500.0, 1.0, 4000.0, "ms");
        p.num("offset", "Right offset (stereo)", 0.0, -50.0, 50.0, "%");
        p.num("feedback", "Feedback", 0.4, 0.0, 1.0);
        p.expo("low_cut", "Low cut", 80.0, 20.0, 2000.0, "Hz");
        p.expo("high_cut", "High cut", 8000.0, 500.0, 20000.0, "Hz");
        p.num("drive", "Drive", 0.15, 0.0, 1.0);
        p.num("mod_depth", "Modulation", 0.1, 0.0, 1.0);
        p.expo("mod_rate", "Modulation rate", 0.6, 0.05, 8.0, "Hz");
        p.num("duck", "Ducking", 0.0, 0.0, 1.0);
        p.pick("freeze", "Freeze", 0.0, kOffOn);
        p.num("mix", "Mix", 0.3, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& delayDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.delay.pro", "Delay", delayParams(), 0, kInfiniteTail);
    return d;
}

// Two delay lines read between samples (4-point Hermite, so a swept time stays clean), each echo high- and
// low-passed (12 dB each) on its way out and back in, soft-saturated in the loop (unity for small signals, so the
// feedback knob means what it says up to 1, and loud loops stay bounded), modulated by a slow sine (the right a
// quarter cycle on), ducked by the input, frozen on request (the loop repeats exactly: no input, feedback 1, no
// filter or saturation). A new time glides there over ~50 ms (a tape-like bend, no click).
class DelayPro final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return delayDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        try {
            size_ = 1;
            const size_t need = static_cast<size_t>((kMaxDelay + kMaxModDelay) * sampleRate) + 8;
            while (size_ < need) size_ <<= 1;
            line_[0].assign(size_, 0.0f);
            line_[1].assign(size_, 0.0f);
        } catch (...) {
            return false;
        }
        glide_ = 1.0 - detExp(-1.0 / (0.05 * sampleRate));
        duck_.prepare(sampleRate);
        return true;
    }
    void clearState() noexcept override {
        for (auto& l : line_) std::fill(l.begin(), l.end(), 0.0f);
        pos_ = 0;
        for (int c = 0; c < 2; ++c) low_[c].clear(), high_[c].clear();
        duck_.clear();
        mix_.reset();
        feedback_.reset();
        seconds_[0] = seconds_[1] = -1.0;
        phase_ = 0.0;
        mod_[0].reset(), mod_[1].reset();
        wetPeak_ = 0.0;
    }
    uint64_t idleFrames() const noexcept override {
        const double longest = std::max(target_[0], target_[1]) + kMaxModDelay;
        return static_cast<uint64_t>((longest + 0.05) * rate());
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        mode_ = std::clamp(choice(kMode, at), 0, 2);
        const int sync = choice(kSync, at);
        target_[0] = sync > 0 ? syncSeconds(sync) : param(kTime, at) * 0.001;
        if (mode_ == kDual) {
            const int syncR = choice(kSyncR, at);
            target_[1] = syncR > 0 ? syncSeconds(syncR) : param(kTimeR, at) * 0.001;
        } else if (mode_ == kStereoMode) {
            target_[1] = target_[0] * (1.0 + std::clamp(param(kOffset, at), -50.0, 50.0) * 0.01);
        } else {
            target_[1] = target_[0];
        }
        for (double& t : target_) t = std::clamp(t, 1.0 / sr, kMaxDelay);
        freeze_ = on(kDFreeze, at);
        feedback_.set(freeze_ ? 1.0 : std::clamp(param(kFeedback, at), 0.0, 1.0), kControlFrames);
        const double lowCut = param(kDLowCut, at), highCut = param(kDHighCut, at);
        useLow_ = lowCut > 20.5;
        useHigh_ = highCut < 19999.0;
        for (int c = 0; c < 2; ++c) {
            low_[c].set(lowCut, 0.70710678118654752, sr);
            high_[c].set(highCut, 0.70710678118654752, sr);
        }
        const double drive = std::clamp(param(kDrive, at), 0.0, 1.0);
        satK_ = 1.0 + 3.0 * drive;
        satInv_ = 1.0 / satK_;
        satMix_ = std::min(1.0, 5.0 * drive);
        // The modulation, worked out at control points and followed in a straight line in between.
        const double depth = std::clamp(param(kModDepth, at), 0.0, 1.0) * kMaxModDelay * sr;
        phase_ += kControlFrames * param(kDModRate, at) / sr;
        phase_ -= std::floor(phase_);
        mod_[0].set(depth * lib::fastSinCycles(phase_), kControlFrames);
        mod_[1].set(depth * lib::fastSinCycles(phase_ + 0.25), kControlFrames);
        duck_.amount = std::clamp(param(kDDuck, at), 0.0, 1.0);
        mix_.set(std::clamp(param(kDMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const double sr = rate();
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = inL[i], xr = inR[i];
            double read[2];
            for (int c = 0; c < 2; ++c) {
                seconds_[c] = seconds_[c] < 0.0 ? target_[c] : seconds_[c] + (target_[c] - seconds_[c]) * glide_;
                if (seconds_[c] - target_[c] < 1e-12 && target_[c] - seconds_[c] < 1e-12) seconds_[c] = target_[c];
                const double back = std::max(2.0, seconds_[c] * sr + mod_[c].next());  // the newest tap stays written
                read[c] = hermite(line_[c].data(), back);
            }
            double wet[2] = {read[0], read[1]};
            if (!freeze_) {
                for (int c = 0; c < 2; ++c) {
                    if (useLow_) wet[c] = low_[c].highpass(wet[c]);
                    if (useHigh_) wet[c] = high_[c].lowpass(wet[c]);
                }
            }
            const double fb = feedback_.next();
            double back[2];
            if (freeze_) {
                back[0] = read[0], back[1] = read[1];
            } else {
                for (int c = 0; c < 2; ++c)  // drive 0 is clean; the curve fades in over the first fifth
                    back[c] = (wet[c] + (lib::fastTanh(wet[c] * satK_) * satInv_ - wet[c]) * satMix_) * fb;
            }
            double feedL, feedR;
            if (mode_ == kPingPong) {  // the input enters on the left (mono), the echoes cross over
                feedL = (freeze_ ? 0.0 : 0.5 * (xl + xr)) + back[1];
                feedR = back[0];
            } else {
                feedL = (freeze_ ? 0.0 : xl) + back[0];
                feedR = (freeze_ ? 0.0 : xr) + back[1];
            }
            line_[0][pos_] = store(feedL);
            line_[1][pos_] = store(feedR);
            pos_ = (pos_ + 1) & (size_ - 1);
            const double g = duck_.gain(xl, xr);
            const double l = wet[0] * g, r = wet[1] * g;
            wetPeak_ = std::max(wetPeak_, std::max(l < 0 ? -l : l, r < 0 ? -r : r));
            const double m = mix_.next();
            outL[i] = static_cast<float>(xl + (l - xl) * m);
            outR[i] = static_cast<float>(xr + (r - xr) * m);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = static_cast<float>(lib::gainToDb(wetPeak_));
        out[2] = outPeakDb();
        out[3] = static_cast<float>(seconds_[0] < 0 ? target_[0] : seconds_[0]);
        out[4] = static_cast<float>(seconds_[1] < 0 ? target_[1] : seconds_[1]);
        out[5] = static_cast<float>(feedback_.value);
        out[6] = static_cast<float>(duck_.most);
        out[7] = freeze_ ? 1.0f : 0.0f;
        out[8] = static_cast<float>(mode_);
        wetPeak_ = 0.0;
        duck_.most = 0.0;
        return 9;
    }

private:
    // `back` samples before the write position (at least 2), by 4-point Hermite interpolation.
    double hermite(const float* line, double back) const noexcept {
        const size_t mask = size_ - 1;
        const size_t whole = static_cast<size_t>(back);
        const double t = back - static_cast<double>(whole);
        // Samples at whole - 1, whole, whole + 1, whole + 2 frames back (newest first).
        const double ym1 = line[(pos_ - whole + 1) & mask], y0 = line[(pos_ - whole) & mask];
        const double y1 = line[(pos_ - whole - 1) & mask], y2 = line[(pos_ - whole - 2) & mask];
        const double c1 = 0.5 * (y1 - ym1), c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2;
        const double c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1);
        return ((c3 * t + c2) * t + c1) * t + y0;
    }
    // Bounded and flushed (as the Library's delay lines): an extreme input can't latch the loop.
    static float store(double v) noexcept {
        if (!(v > -1e4)) return v != v ? 0.0f : -1e4f;
        if (v > 1e4) return 1e4f;
        return (v < 1e-20 && v > -1e-20) ? 0.0f : static_cast<float>(v);
    }
    std::vector<float> line_[2];
    size_t size_ = 0, pos_ = 0;
    double seconds_[2] = {-1, -1}, target_[2] = {0.375, 0.375}, glide_ = 0.0, phase_ = 0.0, satK_ = 1, satInv_ = 1, satMix_ = 0;
    int mode_ = 0;
    bool freeze_ = false, useLow_ = true, useHigh_ = true;
    lib::Svf low_[2], high_[2];
    Ramp mix_, feedback_, mod_[2];
    Ducker duck_;
    double wetPeak_ = 0.0;
};

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

}  // namespace

void registerSpace(ModuleRegistry& registry) {
    registry.add(reverbDescriptor(), &make<ReverbPro>);
    registry.add(delayDescriptor(), &make<DelayPro>);
}

}  // namespace caw::fx
