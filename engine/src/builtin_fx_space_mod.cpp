// The fx-space modulation effects: ensemble, doubler, vibrato, tremolo, auto-pan and rotary speaker, plus the group's shared helpers.
#include "builtin_fx_space.h"

#include <algorithm>
#include <cmath>
#include <new>

#include "caw/library/filter.hpp"
#include "caw/library/oversample.hpp"
#include "caw/library/stereo.hpp"

// Original code (C.A.W. is Apache-2.0): modulated delay lines, LFOs and gains on the Library's kernels.

namespace caw::fx {

// ---------- Shared helpers ----------

bool ModLine::prepare(double seconds, double sampleRate) noexcept {
    try {
        size_t n = 8;
        while (n < static_cast<size_t>(seconds * sampleRate) + 8) n <<= 1;
        line_.assign(n, 0.0f);
        mask_ = n - 1;
        pos_ = 0;
    } catch (...) {
        return false;
    }
    return true;
}
void ModLine::clear() noexcept {
    std::fill(line_.begin(), line_.end(), 0.0f);
    pos_ = 0;
}
void ModLine::write(double x) noexcept {
    pos_ = (pos_ + 1) & mask_;
    double v = x > 1e4 ? 1e4 : (x < -1e4 ? -1e4 : (x == x ? x : 0.0));
    line_[pos_] = (v < 1e-20 && v > -1e-20) ? 0.0f : static_cast<float>(v);
}
double ModLine::read(double back) const noexcept {
    const double top = static_cast<double>(mask_) - 3.0;
    back = back < 1.0 ? 1.0 : (back > top ? top : back);
    const size_t whole = static_cast<size_t>(back);
    const double t = back - static_cast<double>(whole);
    const float* l = line_.data();
    const double ym1 = l[(pos_ - whole + 1) & mask_], y0 = l[(pos_ - whole) & mask_];
    const double y1 = l[(pos_ - whole - 1) & mask_], y2 = l[(pos_ - whole - 2) & mask_];
    const double c1 = 0.5 * (y1 - ym1), c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2;
    const double c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1);
    return ((c3 * t + c2) * t + c1) * t + y0;
}

bool GrainShifter::prepare(double window, double sampleRate) noexcept {
    window_ = std::max(64.0, window * sampleRate);
    return line_.prepare(window + 0.01, sampleRate);
}
void GrainShifter::clear() noexcept {
    line_.clear();
    phase_ = 0.0;
}
void GrainShifter::setRatio(double ratio) noexcept {
    const double r = std::clamp(ratio == ratio ? ratio : 1.0, 0.25, 4.0);
    step_ = (r - 1.0) / window_;
}
double GrainShifter::process(double x) noexcept {
    line_.write(x);
    phase_ -= std::floor(phase_ += step_);
    double b = phase_ + 0.5;
    b -= std::floor(b);
    // The delay falls through the window as the phase rises (a rising pitch), or rises as it falls.
    const double da = 2.0 + window_ * (1.0 - phase_), db = 2.0 + window_ * (1.0 - b);
    const double ga = detSin(kPi * phase_), gb = detSin(kPi * b);
    return line_.read(da) * ga * ga + line_.read(db) * gb * gb;
}

double stepSyncedLfo(lib::Lfo& lfo, int division, double hz, bool playing, double beat, double tempo, uint32_t frames) noexcept {
    const int d = std::clamp(division, 0, kSyncCount - 1);
    if (d > 0) {
        const double beats = kSyncWholeNotes[d] * 4.0;
        lfo.setRateBeats(beats, tempo);
        if (playing) lfo.syncToBeat(beat, beats);
    } else {
        lfo.setRateHz(hz);
    }
    return lfo.block(static_cast<int>(frames));
}

namespace {

double centsToRatio(double cents) noexcept { return detPow(2.0, cents / 1200.0); }

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

// ---------- Ensemble ----------

enum EnsembleParam : uint32_t { kEVoices, kEDelay, kEDetune, kERate, kESpread, kEMotion, kETone, kEMix, kEnsembleCount };
constexpr std::string_view kVoiceCounts[] = {"2", "3", "4", "5", "6", "7", "8"};
constexpr std::string_view kMotions[] = {"Sine", "Triangle", "Random", "Vintage"};
enum Motion : int { kMSine, kMTriangle, kMRandom, kMVintage };
constexpr int kMaxVoices = 8;

const ParamTable& ensembleParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("voices", "Voices", 2.0, kVoiceCounts);
        p.expo("delay", "Delay", 12.0, 3.0, 40.0, "ms");
        p.num("detune", "Detune", 12.0, 0.0, 50.0, "ct");
        p.expo("rate", "Rate", 0.6, 0.05, 8.0, "Hz");
        p.num("spread", "Spread", 0.8, 0.0, 1.0);
        p.pick("motion", "Motion", 3.0, kMotions);
        p.expo("tone", "Tone", 12000.0, 1000.0, 20000.0, "Hz");
        p.num("mix", "Mix", 0.5, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& ensembleDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.ensemble", "Ensemble", ensembleParams(), 0, 9600);
    return d;
}

// 2 to 8 voices, each a delay swept by its own LFO (phases spread evenly around the cycle), read between samples
// and panned across the field (alternately left and right, `spread` wide). The sweep's depth is worked out from the
// detune in cents and the rate (a sine of depth D samples at f Hz bends the pitch by at most 2 pi f D / rate), so
// the pitch wobble stays as set whatever the rate. Vintage adds a fast, shallow second sine to the slow one, as the
// bucket-brigade string ensembles did; Random glides between seeded random values.
class Ensemble final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return ensembleDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        if (!line_[0].prepare(0.1, sr) || !line_[1].prepare(0.1, sr)) return false;
        for (int v = 0; v < kMaxVoices; ++v) {
            slow_[v].prepare(sr);
            fast_[v].prepare(sr);
            slow_[v].setSeed(101 + v);
        }
        return true;
    }
    void clearState() noexcept override {
        line_[0].clear(), line_[1].clear();
        for (int v = 0; v < kMaxVoices; ++v) {
            slow_[v].retrigger(), fast_[v].retrigger();
            delay_[v].reset();
        }
        for (auto& f : tone_) f.clear();
        mix_.reset();
        shown_ = 0;
    }
    void control(uint32_t at) noexcept override {
        // Recursive states flushed once per control block (on the grid: the same at any block size).
        for (int c = 0; c < 2; ++c) tone_[c].flushDenormals();
        const double sr = rate();
        voices_ = std::clamp(choice(kEVoices, at), 0, 6) + 2;
        const int motion = std::clamp(choice(kEMotion, at), 0, 3);
        const double hz = std::clamp(param(kERate, at), 0.05, 8.0);
        const double base = std::clamp(param(kEDelay, at), 3.0, 40.0) * 0.001 * sr;
        const double dev = centsToRatio(std::clamp(param(kEDetune, at), 0.0, 50.0)) - 1.0;
        // The most the delay's slope may reach for that detune, per LFO shape.
        const double slopePerDepth = motion == kMTriangle ? 4.0 * hz / sr : motion == kMVintage ? kTwoPi * hz * 2.5 / sr
                                                                                                 : kTwoPi * hz / sr;
        const double depth = std::min(0.9 * base, dev / slopePerDepth);
        const double spread = std::clamp(param(kESpread, at), 0.0, 1.0);
        for (int v = 0; v < voices_; ++v) {
            const double phase = static_cast<double>(v) / voices_;
            lib::Lfo& s = slow_[v];
            s.setShape(motion == kMTriangle ? lib::LfoShape::Triangle : motion == kMRandom ? lib::LfoShape::SmoothRandom
                                                                                            : lib::LfoShape::Sine);
            s.setPhaseOffset(phase);
            s.setRateHz(motion == kMRandom ? hz * (1.0 + 0.13 * v) : hz);
            double m = s.block(static_cast<int>(kControlFrames));
            if (motion == kMVintage) {
                fast_[v].setShape(lib::LfoShape::Sine);
                fast_[v].setPhaseOffset(1.0 - phase);
                fast_[v].setRateHz(hz * 6.0);
                m = 0.7 * m + 0.3 * fast_[v].block(static_cast<int>(kControlFrames));
            }
            if (v == 0) shown_ = m;
            delay_[v].set(base + depth * m, kControlFrames);
            // Pan: voices alternate sides, the outer ones furthest out.
            const double place = voices_ == 1 ? 0.0 : (2.0 * v / (voices_ - 1) - 1.0);
            const double pan = spread * ((v & 1) ? -place : place);
            pan_[v] = lib::constantPowerPan(pan);
        }
        for (int v = voices_; v < kMaxVoices; ++v) delay_[v].set(base, kControlFrames);
        depthMs_ = depth * 1000.0 / sr;
        const double tone = param(kETone, at);
        useTone_ = tone < 19999.0;
        for (auto& f : tone_) f.set(tone, 0.70710678118654752, sr);
        norm_ = 1.4142135623730951 / std::sqrt(static_cast<double>(voices_));
        mix_.set(std::clamp(param(kEMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = inL[i], xr = inR[i];
            line_[0].write(xl);
            line_[1].write(xr);
            double wl = 0.0, wr = 0.0;
            for (int v = 0; v < kMaxVoices; ++v) {
                const double d = delay_[v].next();
                if (v >= voices_) continue;
                const double y = line_[v & 1].read(d);
                wl += y * pan_[v].left;
                wr += y * pan_[v].right;
            }
            wl *= norm_, wr *= norm_;
            if (useTone_) wl = tone_[0].lowpass(wl), wr = tone_[1].lowpass(wr);
            const double m = mix_.next();
            outL[i] = static_cast<float>(xl + (wl - xl) * m);
            outR[i] = static_cast<float>(xr + (wr - xr) * m);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(voices_);
        out[3] = static_cast<float>(depthMs_);
        out[4] = static_cast<float>(shown_);
        for (int v = 0; v < kMaxVoices; ++v) out[5 + v] = static_cast<float>(delay_[v].value * 1000.0 / rate());
        return 5 + kMaxVoices;
    }

private:
    ModLine line_[2];
    lib::Lfo slow_[kMaxVoices], fast_[kMaxVoices];
    Ramp delay_[kMaxVoices], mix_;
    lib::PanGains pan_[kMaxVoices];
    lib::Svf tone_[2];
    int voices_ = 4;
    bool useTone_ = true;
    double norm_ = 1.0, depthMs_ = 0.0, shown_ = 0.0;
};

// ---------- Doubler ----------

enum DoublerParam : uint32_t { kDVoices, kDDelay, kDDetune, kDDrift, kDWidth, kDLowCut, kDHighCut, kDMix, kDoublerCount };
constexpr std::string_view kDoubles[] = {"2", "4"};

const ParamTable& doublerParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("voices", "Doubles", 0.0, kDoubles);
        p.expo("delay", "Delay", 18.0, 5.0, 60.0, "ms");
        p.num("detune", "Detune", 8.0, 0.0, 30.0, "ct");
        p.num("drift", "Drift", 0.4, 0.0, 1.0);
        p.num("width", "Width", 0.9, 0.0, 1.0);
        p.expo("low_cut", "Low cut", 120.0, 20.0, 1000.0, "Hz");
        p.expo("high_cut", "High cut", 9000.0, 1000.0, 20000.0, "Hz");
        p.num("mix", "Mix", 0.5, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& doublerDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.doubler", "Doubler", doublerParams(), 0, 9600);
    return d;
}

// Double-tracking: copies of the mono sum, each delayed (its own time, wandering by up to 3 ms x drift on a seeded
// smooth-random LFO, as a second take's timing does), pitched a few cents off (a two-tap shifter: a steady detune
// with none of a chorus's wobble) and panned out by `width`, the low end cut so the doubles don't muddy the centre
// or fight it in mono. The dry stays in the middle; `mix` blends to the doubles alone.
class Doubler final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return doublerDescriptor(); }

protected:
    static constexpr int kMax = 4;
    bool prepare(double sr, uint32_t) noexcept override {
        if (!line_.prepare(0.15, sr)) return false;
        for (int v = 0; v < kMax; ++v) {
            if (!shift_[v].prepare(0.03, sr)) return false;
            drift_[v].prepare(sr);
            drift_[v].setShape(lib::LfoShape::SmoothRandom);
            drift_[v].setSeed(7 + 31 * v);
        }
        return true;
    }
    void clearState() noexcept override {
        line_.clear();
        for (int v = 0; v < kMax; ++v) shift_[v].clear(), drift_[v].retrigger(), delay_[v].reset();
        for (auto& f : low_) f.clear();
        for (auto& f : high_) f.clear();
        mix_.reset();
    }
    void control(uint32_t at) noexcept override {
        // Recursive states flushed once per control block (on the grid: the same at any block size).
        for (int c = 0; c < 2; ++c) low_[c].flushDenormals(), high_[c].flushDenormals();
        const double sr = rate();
        count_ = choice(kDVoices, at) >= 1 ? 4 : 2;
        const double base = param(kDDelay, at) * 0.001 * sr, drift = std::clamp(param(kDDrift, at), 0.0, 1.0) * 0.003 * sr;
        const double cents = std::clamp(param(kDDetune, at), 0.0, 30.0), width = std::clamp(param(kDWidth, at), 0.0, 1.0);
        static constexpr double kTime[kMax] = {1.0, 1.37, 0.62, 1.81};
        static constexpr double kCents[kMax] = {1.0, -1.0, -0.6, 0.6};
        static constexpr double kPan[kMax] = {-1.0, 1.0, -0.5, 0.5};
        for (int v = 0; v < kMax; ++v) {
            drift_[v].setRateHz(0.35 + 0.17 * v);
            const double wander = drift_[v].block(static_cast<int>(kControlFrames));
            delay_[v].set(std::max(2.0, base * kTime[v] + drift * wander), kControlFrames);
            shift_[v].setRatio(centsToRatio(cents * kCents[v]));
            pan_[v] = lib::constantPowerPan(kPan[v] * width);
            shownMs_[v] = delay_[v].value * 1000.0 / sr;
        }
        const double lo = param(kDLowCut, at), hi = param(kDHighCut, at);
        useLow_ = lo > 20.5;
        useHigh_ = hi < 19999.0;
        for (auto& f : low_) f.set(lo, 0.70710678118654752, sr);
        for (auto& f : high_) f.set(hi, 0.70710678118654752, sr);
        norm_ = count_ == 4 ? 0.75 : 1.0;
        mix_.set(std::clamp(param(kDMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = inL[i], xr = inR[i];
            line_.write(0.5 * (xl + xr));
            double wl = 0.0, wr = 0.0;
            for (int v = 0; v < kMax; ++v) {
                const double d = delay_[v].next();
                if (v >= count_) continue;
                const double y = shift_[v].process(line_.read(d)) * norm_;
                wl += y * pan_[v].left;
                wr += y * pan_[v].right;
            }
            if (useLow_) wl = low_[0].highpass(wl), wr = low_[1].highpass(wr);
            if (useHigh_) wl = high_[0].lowpass(wl), wr = high_[1].lowpass(wr);
            // The doubles sit beside the dry: at mix 0.5 both at full level, at 1 the doubles alone.
            const double m = mix_.next();
            const double dry = m <= 0.5 ? 1.0 : 2.0 * (1.0 - m), wet = m >= 0.5 ? 1.0 : 2.0 * m;
            outL[i] = static_cast<float>(xl * dry + wl * wet);
            outR[i] = static_cast<float>(xr * dry + wr * wet);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(count_);
        for (int v = 0; v < kMax; ++v) out[3 + v] = static_cast<float>(shownMs_[v]);
        return 3 + kMax;
    }

private:
    ModLine line_;
    GrainShifter shift_[kMax];
    lib::Lfo drift_[kMax];
    Ramp delay_[kMax], mix_;
    lib::PanGains pan_[kMax];
    lib::Svf low_[2], high_[2];
    int count_ = 2;
    bool useLow_ = true, useHigh_ = true;
    double norm_ = 1.0, shownMs_[kMax] = {};
};

// ---------- Vibrato ----------

enum VibratoParam : uint32_t { kVRate, kVSync, kVDepth, kVShape, kVStereo, kVMix, kVibratoCount };
constexpr std::string_view kVibratoShapes[] = {"Sine", "Triangle", "Smooth random"};

const ParamTable& vibratoParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.expo("rate", "Rate", 5.0, 0.1, 14.0, "Hz");
        p.pick("sync", "Sync", 0.0, kSyncDivisions);
        p.num("depth", "Depth", 25.0, 0.0, 100.0, "ct");
        p.pick("shape", "Shape", 0.0, kVibratoShapes);
        p.num("stereo", "Stereo", 0.0, 0.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& vibratoDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.vibrato", "Vibrato", vibratoParams(), 0, 4800);
    return d;
}

// Pitch vibrato: the whole signal through a delay swept by an LFO (no dry, by default), the sweep's depth worked
// out from cents and rate so the pitch swings by exactly the depth at any rate (held to 12 ms). The right side's
// LFO runs `stereo` x half a cycle behind.
class Vibrato final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return vibratoDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        if (!line_[0].prepare(0.04, sr) || !line_[1].prepare(0.04, sr)) return false;
        for (auto& l : lfo_) l.prepare(sr);
        lfo_[1].setSeed(2);
        return true;
    }
    void clearState() noexcept override {
        for (int c = 0; c < 2; ++c) line_[c].clear(), lfo_[c].retrigger(), delay_[c].reset();
        mix_.reset();
        base_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const int shape = std::clamp(choice(kVShape, at), 0, 2);
        const lib::LfoShape s = shape == 1 ? lib::LfoShape::Triangle : shape == 2 ? lib::LfoShape::SmoothRandom : lib::LfoShape::Sine;
        double beat = 0.0;
        const bool playing = beatAt(at, beat);
        const int sync = choice(kVSync, at);
        lfo_[1].setPhaseOffset(0.5 * std::clamp(param(kVStereo, at), 0.0, 1.0));
        double v[2];
        for (int c = 0; c < 2; ++c) {
            lfo_[c].setShape(s);
            v[c] = stepSyncedLfo(lfo_[c], sync, param(kVRate, at), playing, beat, tempo(), kControlFrames);
        }
        hz_ = lfo_[0].rateHz();
        const double dev = centsToRatio(std::clamp(param(kVDepth, at), 0.0, 100.0)) - 1.0;
        const double slope = (shape == 1 ? 4.0 : kTwoPi) * std::max(0.05, hz_) / sr;
        depth_ = std::min(0.012 * sr, dev / slope);
        base_.set(depth_ + 2.0, kControlFrames);
        lfoL_ = v[0], lfoR_ = v[1];
        delay_[0].set(depth_ * v[0], kControlFrames);
        delay_[1].set(depth_ * v[1], kControlFrames);
        mix_.set(std::clamp(param(kVMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double x[2] = {inL[i], inR[i]};
            const double b = base_.next(), m = mix_.next();
            double y[2];
            for (int c = 0; c < 2; ++c) {
                line_[c].write(x[c]);
                const double w = line_[c].read(b + delay_[c].next());
                y[c] = x[c] + (w - x[c]) * m;
            }
            outL[i] = static_cast<float>(y[0]);
            outR[i] = static_cast<float>(y[1]);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(lfoL_);
        out[3] = static_cast<float>(lfoR_);
        out[4] = static_cast<float>(hz_);
        out[5] = static_cast<float>(depth_ * 1000.0 / rate());
        return 6;
    }

private:
    ModLine line_[2];
    lib::Lfo lfo_[2];
    Ramp delay_[2], base_, mix_;
    double depth_ = 0.0, hz_ = 5.0, lfoL_ = 0.0, lfoR_ = 0.0;
};

// ---------- Tremolo and auto-pan ----------

enum TremoloParam : uint32_t { kTRate, kTSync, kTDepth, kTShape, kTSmooth, kTStereo, kTMode, kTremoloCount };
constexpr std::string_view kTremoloModes[] = {"Classic", "Harmonic"};

const ParamTable& tremoloParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.expo("rate", "Rate", 4.0, 0.1, 20.0, "Hz");
        p.pick("sync", "Sync", 0.0, kSyncDivisions);
        p.num("depth", "Depth", 0.6, 0.0, 1.0);
        p.pick("shape", "Shape", 0.0, kSpaceLfoShapes);
        p.num("smooth", "Smooth", 0.2, 0.0, 1.0);
        p.num("stereo", "Stereo", 0.0, 0.0, 1.0);
        p.pick("mode", "Mode", 0.0, kTremoloModes);
        return p;
    }();
    return t;
}
const ModuleDescriptor& tremoloDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.tremolo", "Tremolo", tremoloParams(), 0, 0);
    return d;
}

enum AutopanParam : uint32_t { kARate, kASync, kADepth, kAShape, kASmooth, kAOffset, kAWidth, kAutopanCount };

const ParamTable& autopanParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.expo("rate", "Rate", 1.0, 0.05, 20.0, "Hz");
        p.pick("sync", "Sync", 12.0, kSyncDivisions);  // a half note
        p.num("depth", "Depth", 0.8, 0.0, 1.0);
        p.pick("shape", "Shape", 0.0, kSpaceLfoShapes);
        p.num("smooth", "Smooth", 0.1, 0.0, 1.0);
        p.num("offset", "Phase", 0.0, 0.0, 1.0);
        p.num("width", "Width", 0.5, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& autopanDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.autopan", "Auto-pan", autopanParams(), 0, 0);
    return d;
}

// Tremolo turns the level down and up by `depth` with the LFO (the right side `stereo` x half a cycle behind);
// Harmonic splits at 800 Hz and moves the lows and highs in opposite directions, as the 1960s amplifiers did.
// Auto-pan moves the sound between the sides (the source's own width folded to `width` first). Both smooth the
// gain with a one-pole of up to 15 ms x `smooth`, which rounds a square's corners into clickless steps.
class TremoloBase : public EffectBase {
protected:
    bool prepare(double sr, uint32_t) noexcept override {
        for (auto& l : lfo_) l.prepare(sr);
        lfo_[1].setSeed(3);
        split_[0].set(800.0, sr), split_[1].set(800.0, sr);
        return true;
    }
    void clearState() noexcept override {
        for (auto& l : lfo_) l.retrigger();
        for (auto& g : gain_) g.reset();
        for (auto& s : split_) s.clear();
        for (auto& s : smoothed_) s = 1.0;
        primed_ = false;
    }
    // Both LFOs one control block on; their values at its start.
    void stepLfos(uint32_t at, int shape, double hz, int sync, double rightOffset, double startOffset) noexcept {
        double beat = 0.0;
        const bool playing = beatAt(at, beat);
        lfo_[0].setPhaseOffset(startOffset);
        lfo_[1].setPhaseOffset(startOffset + rightOffset);
        for (int c = 0; c < 2; ++c) {
            lfo_[c].setShape(static_cast<lib::LfoShape>(std::clamp(shape, 0, 6)));
            v_[c] = stepSyncedLfo(lfo_[c], sync, hz, playing, beat, tempo(), kControlFrames);
        }
        hz_ = lfo_[0].rateHz();
    }
    void setSmooth(double smooth) noexcept {
        const double s = std::clamp(smooth, 0.0, 1.0) * 0.015;
        k_ = s <= 0.0 ? 1.0 : 1.0 - detExp(-1.0 / (s * rate()));
    }
    double smooth(int c, double g) noexcept {
        if (!primed_) smoothed_[0] = smoothed_[1] = g;
        return smoothed_[c] += (g - smoothed_[c]) * k_;
    }
    uint32_t fillLfo(float* out) noexcept {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(v_[0]);
        out[3] = static_cast<float>(v_[1]);
        out[4] = static_cast<float>(smoothed_[0]);
        out[5] = static_cast<float>(smoothed_[1]);
        out[6] = static_cast<float>(hz_);
        return 7;
    }

    lib::Lfo lfo_[2];
    lib::OnePole split_[2];
    Ramp gain_[2];
    double v_[2] = {}, smoothed_[2] = {1.0, 1.0}, k_ = 1.0, hz_ = 1.0;
    bool primed_ = false;
};

class Tremolo final : public TremoloBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return tremoloDescriptor(); }

protected:
    void control(uint32_t at) noexcept override {
        stepLfos(at, choice(kTShape, at), param(kTRate, at), choice(kTSync, at), 0.5 * std::clamp(param(kTStereo, at), 0.0, 1.0), 0.0);
        const double depth = std::clamp(param(kTDepth, at), 0.0, 1.0);
        harmonic_ = choice(kTMode, at) == 1;
        // Gain from 1 (the LFO at its top) down to 1 - depth (at its bottom).
        for (int c = 0; c < 2; ++c) gain_[c].set(1.0 - depth * 0.5 * (1.0 - v_[c]), kControlFrames);
        depth_ = depth;
        setSmooth(param(kTSmooth, at));
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double x[2] = {inL[i], inR[i]};
            double y[2];
            for (int c = 0; c < 2; ++c) {
                const double g = smooth(c, gain_[c].next());
                if (harmonic_) {  // the lows follow the gain, the highs its mirror
                    const double lo = split_[c].low(x[c]), hi = x[c] - lo;
                    y[c] = lo * g + hi * (2.0 - depth_ - g);
                } else {
                    y[c] = x[c] * g;
                }
            }
            primed_ = true;
            outL[i] = static_cast<float>(y[0]);
            outR[i] = static_cast<float>(y[1]);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override { return fillLfo(out); }

private:
    bool harmonic_ = false;
    double depth_ = 0.6;
};

class Autopan final : public TremoloBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return autopanDescriptor(); }

protected:
    void control(uint32_t at) noexcept override {
        stepLfos(at, choice(kAShape, at), param(kARate, at), choice(kASync, at), 0.0, std::clamp(param(kAOffset, at), 0.0, 1.0));
        const double pan = std::clamp(param(kADepth, at), 0.0, 1.0) * v_[0];
        // The side moving away falls along a constant-power curve; the side moving closer stays at unity.
        const lib::PanGains g = lib::constantPowerPan(pan);
        gain_[0].set(std::min(1.0, 1.4142135623730951 * g.left), kControlFrames);
        gain_[1].set(std::min(1.0, 1.4142135623730951 * g.right), kControlFrames);
        width_ = std::clamp(param(kAWidth, at), 0.0, 1.0);
        setSmooth(param(kASmooth, at));
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            double l = inL[i], r = inR[i];
            lib::applyWidth(width_, l, r);
            const double gl = smooth(0, gain_[0].next()), gr = smooth(1, gain_[1].next());
            primed_ = true;
            outL[i] = static_cast<float>(l * gl);
            outR[i] = static_cast<float>(r * gr);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override { return fillLfo(out); }

private:
    double width_ = 0.5;
};

// ---------- Rotary speaker ----------

enum RotaryParam : uint32_t { kRSpeed, kRAccel, kRBalance, kRDrive, kRWidth, kRDoppler, kRMix, kRotaryCount };
constexpr std::string_view kRotarySpeeds[] = {"Slow", "Fast", "Brake"};

const ParamTable& rotaryParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("speed", "Speed", 0.0, kRotarySpeeds);
        p.expo("accel", "Inertia", 1.0, 0.25, 4.0, "x");
        p.num("balance", "Horn / drum", 0.0, -1.0, 1.0);
        p.num("drive", "Drive", 0.0, 0.0, 24.0, "dB");
        p.num("width", "Mic width", 0.7, 0.0, 1.0);
        p.num("doppler", "Doppler", 0.6, 0.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& rotaryDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.rotary", "Rotary", rotaryParams(), 0, 4800);
    return d;
}

// A Leslie-style rotary speaker (after Smith, Serafin, Abel and Berners, "Doppler simulation and the Leslie",
// DAFx-02): the mono sum (optionally driven through a tanh, 2x oversampled at High quality) split at 800 Hz
// by a 4th-order Linkwitz-Riley crossover; the horn (highs) and the drum (lows) each spin at their own speed
// (chorale 0.83 / 0.67 Hz, tremolo 6.75 / 5.8 Hz), easing between speeds with the horn's light inertia (about
// 0.7 s) and the drum's heavy one (about 4 s), x `accel`. Two virtual mics `width` x 90 degrees either side each
// hear each rotor through a delay that is shortest when the rotor faces the mic (the Doppler shift, up to 0.5 ms
// for the horn and 0.2 ms for the drum, x `doppler`) and loudest then (the horn's beam swings the level far more
// than the drum's).
class Rotary final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return rotaryDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        for (auto& l : line_) if (!l.prepare(0.01, sr)) return false;
        for (int k = 0; k < 2; ++k) lp_[k].set(800.0, 0.70710678118654752, sr), hp_[k].set(800.0, 0.70710678118654752, sr);
        return true;
    }
    void clearState() noexcept override {
        for (auto& l : line_) l.clear();
        for (auto& f : lp_) f.clear();
        for (auto& f : hp_) f.clear();
        os_.clear();
        for (auto& r : delay_) r.reset();
        for (auto& r : amp_) r.reset();
        mix_.reset();
        angle_[0] = 0.0, angle_[1] = 0.25;  // the rotors start a quarter turn apart
        primed_ = false;
    }
    void control(uint32_t at) noexcept override {
        // Recursive states flushed once per control block (on the grid: the same at any block size).
        for (int k = 0; k < 2; ++k) lp_[k].flushDenormals(), hp_[k].flushDenormals();
        const double sr = rate();
        const int speed = std::clamp(choice(kRSpeed, at), 0, 2);
        static constexpr double kSlow[2] = {0.83, 0.67}, kFast[2] = {6.75, 5.8};
        static constexpr double kUp[2] = {0.6, 3.5}, kDown[2] = {0.7, 4.5};  // seconds (time constants)
        const double accel = std::clamp(param(kRAccel, at), 0.25, 4.0);
        const double dt = kControlFrames / sr;
        for (int k = 0; k < 2; ++k) {
            const double target = speed == 2 ? 0.0 : speed == 1 ? kFast[k] : kSlow[k];
            if (!primed_) hz_[k] = target;
            const double tau = (target > hz_[k] ? kUp[k] : kDown[k]) * accel;
            hz_[k] += (target - hz_[k]) * (1.0 - detExp(-dt / tau));
            angle_[k] += hz_[k] * dt;
            angle_[k] -= std::floor(angle_[k]);
        }
        primed_ = true;
        const double width = std::clamp(param(kRWidth, at), 0.0, 1.0) * 0.25;  // a quarter turn = 90 degrees
        const double doppler = std::clamp(param(kRDoppler, at), 0.0, 1.0);
        static constexpr double kDepthS[2] = {0.0005, 0.0002}, kAm[2] = {0.6, 0.2};
        for (int k = 0; k < 2; ++k)
            for (int mic = 0; mic < 2; ++mic) {
                const double rel = angle_[k] - (mic == 0 ? -width : width);
                const double facing = 0.5 * (1.0 + detCos(kTwoPi * rel));  // 1: facing the mic
                delay_[2 * k + mic].set(2.0 + doppler * kDepthS[k] * sr * (1.0 - facing), kControlFrames);
                amp_[2 * k + mic].set(1.0 - kAm[k] * (1.0 - facing), kControlFrames);
            }
        const double bal = std::clamp(param(kRBalance, at), -1.0, 1.0);
        hornGain_ = bal < 0.0 ? 1.0 + bal : 1.0;
        drumGain_ = bal > 0.0 ? 1.0 - bal : 1.0;
        drive_ = lib::dbToGain(std::clamp(param(kRDrive, at), 0.0, 24.0));
        driven_ = drive_ > 1.0001;
        oversample_ = driven_ && quality() == kQualityHigh;
        mix_.set(std::clamp(param(kRMix, at), 0.0, 1.0), kControlFrames);
    }
    double shape(double x) const noexcept { return lib::fastTanh(x * drive_) / std::sqrt(drive_); }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = inL[i], xr = inR[i];
            double x = 0.5 * (xl + xr);
            if (oversample_) {
                double up[2];
                os_.up(x, up);
                up[0] = shape(up[0]), up[1] = shape(up[1]);
                x = os_.down(up);
            } else if (driven_) {
                x = shape(x);
            }
            const double low = lp_[1].lowpass(lp_[0].lowpass(x)), high = hp_[1].highpass(hp_[0].highpass(x));
            line_[0].write(high);
            line_[1].write(low);
            double y[2];
            for (int mic = 0; mic < 2; ++mic) {
                const double horn = line_[0].read(delay_[mic].next()) * amp_[mic].next();
                const double drum = line_[1].read(delay_[2 + mic].next()) * amp_[2 + mic].next();
                y[mic] = horn * hornGain_ + drum * drumGain_;
            }
            const double m = mix_.next();
            outL[i] = static_cast<float>(xl + (y[0] - xl) * m);
            outR[i] = static_cast<float>(xr + (y[1] - xr) * m);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(angle_[0]);
        out[3] = static_cast<float>(angle_[1]);
        out[4] = static_cast<float>(hz_[0]);
        out[5] = static_cast<float>(hz_[1]);
        return 6;
    }

private:
    ModLine line_[2];
    lib::Svf lp_[2], hp_[2];
    lib::Oversampler2x os_;
    Ramp delay_[4], amp_[4], mix_;  // horn left, horn right, drum left, drum right
    double angle_[2] = {0.0, 0.25}, hz_[2] = {0.83, 0.67};
    double hornGain_ = 1.0, drumGain_ = 1.0, drive_ = 1.0;
    bool primed_ = false, driven_ = false, oversample_ = false;
};

}  // namespace

void registerFxSpaceMod(ModuleRegistry& registry) {
    registry.add(ensembleDescriptor(), &make<Ensemble>);
    registry.add(doublerDescriptor(), &make<Doubler>);
    registry.add(vibratoDescriptor(), &make<Vibrato>);
    registry.add(tremoloDescriptor(), &make<Tremolo>);
    registry.add(autopanDescriptor(), &make<Autopan>);
    registry.add(rotaryDescriptor(), &make<Rotary>);
}

void registerFxSpace(ModuleRegistry& registry) {
    registerFxSpaceMod(registry);
    registerFxSpaceStereo(registry);
    registerFxSpaceReverb(registry);
}

}  // namespace caw::fx
