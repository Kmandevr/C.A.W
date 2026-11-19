// The Drive's 1.1.0 variants: Amp (Clean, Crunch, Lead, High gain with a tone stack), Pedal (Overdrive, Distortion, Fuzz) and Bands (1-4 Linkwitz-Riley bands, each its own drive).
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <deque>
#include <new>
#include <span>
#include <vector>

#include "caw/library/eq.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/oversample.hpp"
#include "fx_merged.h"
#include "fx_modes_kit.h"
#include "presets.h"
#include "stereo_pair.h"

// Original code (C.A.W. is Apache-2.0), C.A.W's own designs (sound plan 2026-11-19); nothing from Fire (AGPL) or any
// other drive's code. Appended to org.caw.drive as variants 4 (Amp), 5 (Pedal) and 6 (Bands).
// - Amp: a tightening high-pass, one gain stage (Clean, Crunch) or two with a low-pass between (Lead, High gain),
//   each an asymmetric soft clip (the positive side harder than the negative: even harmonics, as a triode stage),
//   then the tone stack: bass (a low shelf at 120 Hz), mid (a bell at the voicing's own centre), treble (a high
//   shelf at 2.8 kHz), each +-12 dB, and presence (a high shelf at 5 kHz, 0..+9 dB), then a gentle power-stage clip
//   and the voicing's top roll-off. No cabinet: the Convolver's Cab mode is that.
// - Pedal: Overdrive (a mid-hump drive blended onto the clean signal, soft-clipped), Distortion (high gain into a
//   hard-knee clip) and Fuzz (a biased, asymmetric clip, gated by its own bias at low levels), then a tone low-pass.
// - Bands: 1..4 bands split by Linkwitz-Riley (24 dB/octave) crossovers: each split one state-variable stage giving
//   its low and high, each followed by a second; the lower bands are passed through the later crossovers' all-pass
//   (a 4th-order Linkwitz-Riley pair sums to a 2nd-order Butterworth all-pass), so the bands sum flat. Each band has
//   its own type (Clean, Soft, Hard, Tube, Fuzz, Fold), drive (0..36 dB, level-matched), tone (a tilt about the
//   band) and mix, solo and mute. Only the bands in use are split; a muted band's shaper is skipped.
// Oversampling: 2x (the Library's half-band all-pass pair, no latency) only where it is measured to matter
// (fx_drive_modes_test.cpp measures the aliasing): Amp's Lead and High gain, Pedal's Distortion and Fuzz, by
// `oversample` Auto; Off and 2x force it. The Eco quality tier turns Auto off.

namespace caw::fx {

namespace {

constexpr std::string_view kDriveId = "org.caw.drive";
constexpr std::string_view kDriveName = "Drive";
constexpr std::string_view kOversample[] = {"Auto", "Off", "2x"};
constexpr double kSqrtHalf = 0.70710678118654752;

double clamp01(double x) noexcept { return std::clamp(x, 0.0, 1.0); }

// The half-band design every 2x oversampler shares: built once at start-up (registration), read only.
const lib::HalfBandDesign& halfBand() {
    static const lib::HalfBandDesign d(6, 0.06);
    return d;
}

// A soft clip, harder on the positive side (`asym` 0..1 softens the negative): even harmonics, one tanh, no
// branch (the side picks a factor) and no division.
struct Tube {
    double k = 1, inv = 1;
    explicit Tube(double asym) noexcept : k(1.0 - 0.4 * asym), inv(1.0 / (1.0 - 0.4 * asym)) {}
    double operator()(double x) const noexcept {
        const bool neg = x < 0.0;
        return lib::tanhApprox(x * (neg ? k : 1.0)) * (neg ? inv : 1.0);
    }
    Pair operator()(Pair x) const noexcept {
        const Pair ks = pairOf(lane(x, 0) < 0.0 ? k : 1.0, lane(x, 1) < 0.0 ? k : 1.0);
        const Pair is = pairOf(lane(x, 0) < 0.0 ? inv : 1.0, lane(x, 1) < 0.0 ? inv : 1.0);
        return tanhApproxPair(x * ks) * is;
    }
};
inline double tube(double x, double asym) noexcept { return Tube(asym)(x); }

// Runs `shape` on n frames of one side, at 1x or 2x (`os` its oversampler, null for 1x).
template <class F>
void shapeRun(double* x, uint32_t n, lib::Oversampler2x* os, F&& shape) noexcept {
    if (!os) {
        for (uint32_t i = 0; i < n; ++i) x[i] = shape(x[i]);
        return;
    }
    double up[2 * EffectBase::kControlFrames];
    os->upBlock(x, up, static_cast<int>(n));
    for (uint32_t i = 0; i < 2 * n; ++i) up[i] = shape(up[i]);
    os->downBlock(up, x, static_cast<int>(n));
}

// ---------- Amp ----------

constexpr std::string_view kVoicings[] = {"Clean", "Crunch", "Lead", "High gain"};
struct Voicing {
    double tightHz, gainDb, gainRange, asym, midHz, topHz, trim;
    bool twoStages, oversample;
};
constexpr Voicing kVoice[] = {
    {60, 0, 18, 0.2, 800, 9000, 0, false, false},     // Clean: headroom, a little warmth when pushed
    {90, 8, 26, 0.5, 650, 7500, -4, false, false},    // Crunch: one stage driven
    {120, 14, 30, 0.6, 700, 7000, -9, true, true},    // Lead: two stages, a mid push
    {150, 18, 34, 0.7, 500, 6500, -12, true, true},   // High gain: two stages, tight lows
};
enum AmpParam : uint32_t { kAVoicing, kAGain, kABass, kAMid, kATreble, kAPresence, kAOutput, kAMix, kAOversample, kACount };

const ParamTable& ampParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("voicing", "Voicing", 1.0, kVoicings);
        p.num("gain", "Gain", 0.5, 0.0, 1.0);
        p.num("bass", "Bass", 0.5, 0.0, 1.0);
        p.num("mid", "Mid", 0.5, 0.0, 1.0);
        p.num("treble", "Treble", 0.5, 0.0, 1.0);
        p.num("presence", "Presence", 0.3, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.pick("oversample", "Oversampling", 0.0, kOversample);
        return p;
    }();
    return t;
}

class Amp : public EffectBase {
public:
    explicit Amp(const ModuleDescriptor& d) noexcept : d_(d) {
        for (auto& o : os1_) o.set(halfBand());
    }
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void clearState() noexcept override {
        tight_.clear(), between_.clear(), top_.clear(), dc_ = splat(0.0);
        for (int c = 0; c < 2; ++c) os1_[c].clear(), betweenUp_[c].clear();
        for (auto& b : stack_) b.clear();
        outRamp_.reset();
        mixRamp_.reset();
        drivenPeak_ = 0.0;
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        voicing_ = std::clamp(choice(kAVoicing, at), 0, 3);
        const Voicing& v = kVoice[voicing_];
        gain_ = clamp01(param(kAGain, at));
        gainLin_ = lib::dbToGain(v.gainDb + v.gainRange * gain_);
        const int os = std::clamp(choice(kAOversample, at), 0, 2);
        oversampled_ = os == 2 || (os == 0 && v.oversample && quality() != kQualityEco);
        const double bass = (clamp01(param(kABass, at)) - 0.5) * 24.0, mid = (clamp01(param(kAMid, at)) - 0.5) * 24.0;
        const double treble = (clamp01(param(kATreble, at)) - 0.5) * 24.0, presence = clamp01(param(kAPresence, at)) * 9.0;
        tone_[0] = bass, tone_[1] = mid, tone_[2] = treble, tone_[3] = presence;
        using K = modes::PairEq;
        tight_.set(v.tightHz, kSqrtHalf, sr);
        between_.set(5500.0, kSqrtHalf, sr);
        for (auto& b : betweenUp_) b.set(5500.0, kSqrtHalf, 2.0 * sr);  // the same low-pass inside the 2x region
        top_.set(v.topHz, kSqrtHalf, sr);
        stack_[0].set(K::LowShelf, 120.0, bass, kSqrtHalf, sr);
        stack_[1].set(K::Bell, v.midHz, mid, 0.8, sr);
        stack_[2].set(K::HighShelf, 2800.0, treble, kSqrtHalf, sr);
        stack_[3].set(K::HighShelf, 5000.0, presence, kSqrtHalf, sr);
        dcK_ = 1.0 - detExp(-kTwoPi * 8.0 / sr);
        outRamp_.set(lib::dbToGain(param(kAOutput, at) + v.trim), kControlFrames);
        mixRamp_.set(clamp01(param(kAMix, at)), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        // The filters on both sides as one two-wide vector (stereo_pair.h); the clipping stages per side, at 1x or
        // through each side's 2x oversampler.
        const Voicing& v = kVoice[voicing_];
        const double asym = v.asym;
        const Pair g = splat(gainLin_);
        double y[2][kControlFrames];
        for (uint32_t i = 0; i < n; ++i) {
            const Pair x = tight_.high(modes::finitePair(pairOf(inL[i], inR[i]))) * g;
            y[0][i] = lane(x, 0), y[1][i] = lane(x, 1);
        }
        const Tube stage(asym);
        const double lift = 0.1 * asym, bias = stage(lift);
        if (v.twoStages && oversampled_) {
            // Both stages and the low-pass between them inside one 2x region: one up and one down per side.
            for (int c = 0; c < 2; ++c) {
                double up[2 * kControlFrames];
                os1_[c].upBlock(y[c], up, static_cast<int>(n));
                for (uint32_t i = 0; i < 2 * n; ++i) up[i] = stage(betweenUp_[c].lowpass(stage(up[i])) * 6.0 + lift) - bias;
                os1_[c].downBlock(up, y[c], static_cast<int>(n));
                betweenUp_[c].flushDenormals();
            }
        } else {
            for (int c = 0; c < 2; ++c) shapeRun(y[c], n, oversampled_ ? &os1_[c] : nullptr, stage);
            if (v.twoStages) {
                const Pair six = splat(6.0);
                for (uint32_t i = 0; i < n; ++i) {
                    const Pair x = between_.low(pairOf(y[0][i], y[1][i])) * six;
                    y[0][i] = lane(x, 0), y[1][i] = lane(x, 1);
                }
                for (int c = 0; c < 2; ++c)
                    for (uint32_t i = 0; i < n; ++i) y[c][i] = stage(y[c][i] + lift) - bias;
            }
        }
        Pair most = splat(drivenPeak_);
        const Pair power = splat(0.8), back = splat(1.25), dcK = splat(dcK_);
        for (uint32_t i = 0; i < n; ++i) {
            Pair s = pairOf(y[0][i], y[1][i]);
            most = pairMax(most, pairAbs(s));
            for (auto& b : stack_) s = b.process(s);
            s = top_.low(tanhApproxPair(s * power) * back);  // the power stage, then the top roll-off
            dc_ = dc_ + (s - dc_) * dcK;                       // and no DC (a one-pole at 8 Hz taken off)
            s = s - dc_;
            const double o = outRamp_.next(), m = mixRamp_.next();
            outL[i] = static_cast<float>(inL[i] + (lane(s, 0) * o - inL[i]) * m);
            outR[i] = static_cast<float>(inR[i] + (lane(s, 1) * o - inR[i]) * m);
        }
        drivenPeak_ = std::max(lane(most, 0), lane(most, 1));
        tight_.flush(), between_.flush(), top_.flush(), dc_ = flushPair(dc_);
        for (auto& b : stack_) b.flush();
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(voicing_);
        out[3] = static_cast<float>(lib::gainToDb(gainLin_));         // the input gain dB
        out[4] = static_cast<float>(lib::gainToDb(drivenPeak_));      // the gain stages' peak dB (0: clipping hard)
        for (int k = 0; k < 4; ++k) out[5 + k] = static_cast<float>(tone_[k]);  // bass, mid, treble, presence dB
        out[9] = static_cast<float>(kVoice[voicing_].midHz);
        out[10] = oversampled_ ? 2.0f : 1.0f;
        drivenPeak_ = 0.0;
        return 11;
    }

private:
    const ModuleDescriptor& d_;
    modes::PairSvf tight_, between_, top_;
    modes::PairEq stack_[4];
    Pair dc_{};
    lib::Oversampler2x os1_[2];
    lib::Svf betweenUp_[2];
    Ramp outRamp_, mixRamp_;
    int voicing_ = 1;
    double gain_ = 0.5, gainLin_ = 1, tone_[4] = {}, drivenPeak_ = 0, dcK_ = 0;
    bool oversampled_ = false;
};

// ---------- Pedal ----------

constexpr std::string_view kPedals[] = {"Overdrive", "Distortion", "Fuzz"};
enum PedalParam : uint32_t { kPType, kPDrive, kPTone, kPLevel, kPMix, kPOversample, kPCount };

const ParamTable& pedalParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("type", "Type", 0.0, kPedals);
        p.num("drive", "Drive", 0.5, 0.0, 1.0);
        p.num("tone", "Tone", 0.5, 0.0, 1.0);
        p.num("level", "Level", 0.0, -24.0, 12.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.pick("oversample", "Oversampling", 0.0, kOversample);
        return p;
    }();
    return t;
}

class Pedal : public EffectBase {
public:
    explicit Pedal(const ModuleDescriptor& d) noexcept : d_(d) {
        for (auto& o : os_) o.set(halfBand());
    }
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void clearState() noexcept override {
        for (int c = 0; c < 2; ++c) hump_[c].clear(), tone_[c].clear(), os_[c].clear(), dc_[c].clear();
        levelRamp_.reset();
        mixRamp_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        type_ = std::clamp(choice(kPType, at), 0, 2);
        drive_ = clamp01(param(kPDrive, at));
        // Overdrive 0..+40 dB, Distortion +10..+56 dB, Fuzz +12..+48 dB into the clip.
        constexpr double lo[] = {0, 10, 12}, range[] = {40, 46, 36}, trims[] = {-2, -8, -9};
        gain_ = lib::dbToGain(lo[type_] + range[type_] * drive_);
        const int os = std::clamp(choice(kPOversample, at), 0, 2);
        oversampled_ = os == 2 || (os == 0 && type_ != 0 && quality() != kQualityEco);
        toneHz_ = 600.0 * detPow(2.0, clamp01(param(kPTone, at)) * 4.2);  // 600 Hz .. 11 kHz
        for (int c = 0; c < 2; ++c) {
            hump_[c].set(type_ == 0 ? 720.0 : 90.0, kSqrtHalf, sr);
            tone_[c].set(toneHz_, kSqrtHalf, sr);
            dc_[c].set(8.0, sr);
        }
        levelRamp_.set(lib::dbToGain(param(kPLevel, at) + trims[type_]), kControlFrames);
        mixRamp_.set(clamp01(param(kPMix, at)), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const float* in[2] = {inL, inR};
        double y[2][kControlFrames];
        const double g = gain_;
        for (int c = 0; c < 2; ++c) {
            double* x = y[c];
            for (uint32_t i = 0; i < n; ++i) x[i] = hump_[c].highpass(in[c][i]) * g;
            lib::Oversampler2x* os = oversampled_ ? &os_[c] : nullptr;
            switch (type_) {  // once per run, not per sample
                case 0:  // Overdrive: the driven mids soft-clipped (x / (1 + |x|)), the clean signal under them
                    shapeRun(x, n, os, [](double s) { return s / (1.0 + (s < 0 ? -s : s)); });
                    for (uint32_t i = 0; i < n; ++i) x[i] += 0.5 * in[c][i];
                    break;
                case 1:  // Distortion: a hard knee, held at +-1
                    shapeRun(x, n, os, [](double s) { return std::clamp(lib::tanhApprox(1.5 * s) * 1.1, -1.0, 1.0); });
                    break;
                default:  // Fuzz: biased and asymmetric; the bias closes it at low levels (a fuzz's gating)
                    shapeRun(x, n, os, [](double s) {
                        const double b = 0.35;
                        return lib::tanhApprox(s + b) - lib::tanhApprox(b) + 0.15 * lib::tanhApprox(3.0 * s * s * (s > 0 ? 1.0 : -1.0));
                    });
                    break;
            }
            for (uint32_t i = 0; i < n; ++i) x[i] = dc_[c].high(tone_[c].lowpass(x[i]));
            hump_[c].flushDenormals(), tone_[c].flushDenormals();
        }
        for (uint32_t i = 0; i < n; ++i) {
            const double o = levelRamp_.next(), m = mixRamp_.next();
            outL[i] = static_cast<float>(inL[i] + (y[0][i] * o - inL[i]) * m);
            outR[i] = static_cast<float>(inR[i] + (y[1][i] * o - inR[i]) * m);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(type_);
        out[3] = static_cast<float>(drive_);
        out[4] = static_cast<float>(lib::gainToDb(gain_));
        out[5] = static_cast<float>(toneHz_);
        out[6] = oversampled_ ? 2.0f : 1.0f;
        return 7;
    }

private:
    const ModuleDescriptor& d_;
    lib::Svf hump_[2], tone_[2];
    lib::OnePole dc_[2];  // the fuzz's offset, blocked at 8 Hz
    lib::Oversampler2x os_[2];
    Ramp levelRamp_, mixRamp_;
    int type_ = 0;
    double drive_ = 0.5, gain_ = 1, toneHz_ = 2000;
    bool oversampled_ = false;
};

// ---------- Bands ----------

constexpr int kBands = 4;
constexpr std::string_view kBandCounts[] = {"1", "2", "3", "4"};
constexpr std::string_view kShapes[] = {"Clean", "Soft", "Hard", "Tube", "Fuzz", "Fold"};
constexpr double kBandsDefault[kBands - 1] = {120.0, 1000.0, 5000.0};
// Per band: type, drive, tone, mix, solo, mute (6), from kBand0.
enum BandsParam : uint32_t { kBCount, kBX1, kBX2, kBX3, kBand0, kBOutput = kBand0 + 6 * kBands, kBMix, kBTotal };

const ParamTable& bandsParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("bands", "Bands", 2.0, kBandCounts);
        p.expo("x1", "Crossover 1", kBandsDefault[0], 30.0, 16000.0, "Hz");
        p.expo("x2", "Crossover 2", kBandsDefault[1], 30.0, 16000.0, "Hz");
        p.expo("x3", "Crossover 3", kBandsDefault[2], 30.0, 16000.0, "Hz");
        constexpr double types[kBands] = {3, 1, 2, 1};
        for (int b = 0; b < kBands; ++b) {
            const std::string id = "b" + std::to_string(b + 1) + "_", name = "Band " + std::to_string(b + 1) + " ";
            p.pick(id + "type", name + "type", types[b], kShapes);
            p.num(id + "drive", name + "drive", 0.3, 0.0, 1.0);
            p.num(id + "tone", name + "tone", 0.0, -1.0, 1.0);
            p.num(id + "mix", name + "mix", 1.0, 0.0, 1.0);
            p.pick(id + "solo", name + "solo", 0.0, kOffOn);
            p.pick(id + "mute", name + "mute", 0.0, kOffOn);
        }
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}

// One band's shaper of a type on both sides, over n frames (the type chosen once per run, not per sample).
inline void shapeBand(int type, Pair* x, uint32_t n, double g, double makeup) noexcept {
    const Pair gain = splat(g), mk = splat(makeup);
    switch (type) {
        case 1:
            for (uint32_t i = 0; i < n; ++i) x[i] = tanhApproxPair(x[i] * gain) * mk;
            break;
        case 2:
            for (uint32_t i = 0; i < n; ++i) x[i] = pairMin(splat(1.0), pairMax(splat(-1.0), x[i] * gain)) * mk;
            break;
        case 3: {
            const Tube t(0.6);
            for (uint32_t i = 0; i < n; ++i) x[i] = t(x[i] * gain) * mk;
            break;
        }
        case 4: {
            const Pair b = splat(0.3), off = splat(lib::tanhApprox(0.3));
            for (uint32_t i = 0; i < n; ++i) x[i] = (tanhApproxPair(x[i] * gain + b) - off) * mk;
            break;
        }
        case 5:  // folds past full scale
            for (uint32_t i = 0; i < n; ++i) {
                const Pair s = x[i] * gain;
                x[i] = pairOf(lib::fastSinCycles(0.25 * lane(s, 0)), lib::fastSinCycles(0.25 * lane(s, 1))) * mk;
            }
            break;
        default:
            break;
    }
}

class Bands : public EffectBase {
public:
    explicit Bands(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void clearState() noexcept override {
        for (auto& x : split_) x.clear();
        for (auto& row : comp_)
            for (auto& x : row) x.clear();
        for (auto& b : info_) b.mix.reset(), b.peakIn = b.peakOut = 0.0, b.tone = splat(0.0);
        dc_ = splat(0.0);
        outRamp_.reset();
        mixRamp_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        count_ = std::clamp(choice(kBCount, at), 0, kBands - 1) + 1;
        // The crossovers in order (each held at least a third of an octave above the last).
        double last = 20.0;
        for (int k = 0; k < kBands - 1; ++k) {
            const double hz = std::max(param(kBX1 + k, at), last * 1.26);
            freq_[k] = hz;
            last = hz;
            split_[k].set(hz, sr);
            for (int lower = 0; lower < k; ++lower) comp_[lower][k].set(hz, kSqrtHalf, sr);
        }
        bool anySolo = false;
        for (int b = 0; b < count_; ++b) anySolo = anySolo || on(kBand0 + 6 * b + 4, at);
        for (int b = 0; b < kBands; ++b) {
            const uint32_t p = kBand0 + 6 * b;
            BandInfo& info = info_[b];
            info.type = std::clamp(choice(p, at), 0, 5);
            info.drive = clamp01(param(p + 1, at));
            const double db = 36.0 * info.drive;
            info.gain = lib::dbToGain(db);
            info.makeup = info.type == 0 ? 1.0 : lib::dbToGain(-0.5 * db);  // half the drive back off: louder, not blasting
            info.tilt = std::clamp(param(p + 2, at), -1.0, 1.0);
            info.mix.set(clamp01(param(p + 3, at)), kControlFrames);
            info.solo = on(p + 4, at);
            info.muted = on(p + 5, at) || (anySolo && !info.solo) || b >= count_;
            // The tilt's pivot: the band's centre (geometric, between its crossovers), a one-pole.
            const double lo = b == 0 ? 40.0 : freq_[b - 1], hi = b >= count_ - 1 ? 12000.0 : freq_[b];
            info.toneK = 1.0 - detExp(-kTwoPi * std::sqrt(lo * hi) / sr);
        }
        dcK_ = 1.0 - detExp(-kTwoPi * 8.0 / sr);
        outRamp_.set(lib::dbToGain(param(kBOutput, at)), kControlFrames);
        mixRamp_.set(clamp01(param(kBMix, at)), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        // Both sides as one two-wide vector (stereo_pair.h). Split: bands[b] holds band b's frames; only the
        // crossovers in use run, and each band below a crossover takes that crossover's all-pass (its own).
        Pair bands[kBands][kControlFrames], sum[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) bands[0][i] = modes::finitePair(pairOf(inL[i], inR[i])), sum[i] = splat(0.0);
        for (int k = 0; k < count_ - 1; ++k) {
            for (uint32_t i = 0; i < n; ++i) split_[k].process(bands[k][i], bands[k][i], bands[k + 1][i]);
            for (int lower = 0; lower < k; ++lower)
                for (uint32_t i = 0; i < n; ++i) bands[lower][i] = comp_[lower][k].allpass(bands[lower][i]);
        }
        for (int b = 0; b < count_; ++b) {
            BandInfo& info = info_[b];
            if (info.muted) {  // nothing to hear: no shaper (its mix still moves with its knob)
                for (uint32_t i = 0; i < n; ++i) info.mix.next();
                continue;
            }
            Pair* x = bands[b];
            Pair dry[kControlFrames], most = splat(info.peakIn);
            const Pair up = splat(1.0 + info.tilt), down = splat(1.0 - info.tilt), k = splat(info.toneK);
            for (uint32_t i = 0; i < n; ++i) {  // the tilt: the band's low under a one-pole, the rest above it
                dry[i] = x[i];
                most = pairMax(most, pairAbs(x[i]));
                info.tone = info.tone + (x[i] - info.tone) * k;
                x[i] = info.tone * down + (x[i] - info.tone) * up;
            }
            info.tone = flushPair(info.tone);
            info.peakIn = std::max(lane(most, 0), lane(most, 1));
            shapeBand(info.type, x, n, info.gain, info.makeup);
            Pair out = splat(info.peakOut);
            for (uint32_t i = 0; i < n; ++i) {
                const Pair y = dry[i] + (x[i] - dry[i]) * splat(info.mix.next());
                out = pairMax(out, pairAbs(y));
                sum[i] = sum[i] + y;
            }
            info.peakOut = std::max(lane(out, 0), lane(out, 1));
        }
        for (int k = 0; k < kBands; ++k)
            if (k >= count_) info_[k].mixSkip(n);
        const Pair dcK = splat(dcK_);
        for (uint32_t i = 0; i < n; ++i) {
            dc_ = dc_ + (sum[i] - dc_) * dcK;  // the asymmetric shapes' offset, blocked at 8 Hz
            const Pair s = sum[i] - dc_;
            const double o = outRamp_.next(), m = mixRamp_.next();
            outL[i] = static_cast<float>(inL[i] + (lane(s, 0) * o - inL[i]) * m);
            outR[i] = static_cast<float>(inR[i] + (lane(s, 1) * o - inR[i]) * m);
        }
        dc_ = flushPair(dc_);
        for (int k = 0; k < count_ - 1; ++k) {
            split_[k].flush();
            for (int lower = 0; lower < k; ++lower) comp_[lower][k].flush();
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(count_);
        for (int k = 0; k < kBands - 1; ++k) out[3 + k] = static_cast<float>(freq_[k]);
        for (int b = 0; b < kBands; ++b) {  // per band from 6: in peak dB, out peak dB, type, drive, active
            BandInfo& info = info_[b];
            float* o = out + 6 + 5 * b;
            o[0] = static_cast<float>(lib::gainToDb(info.peakIn));
            o[1] = static_cast<float>(lib::gainToDb(info.peakOut));
            o[2] = static_cast<float>(info.type);
            o[3] = static_cast<float>(info.drive);
            o[4] = info.muted ? 0.0f : 1.0f;
            info.peakIn = info.peakOut = 0.0;
        }
        return 6 + 5 * kBands;
    }

private:
    // A Linkwitz-Riley split: one state-variable stage gives the low and the high of x, each then through a second
    // stage of its own (low of low, high of high): two Butterworth 2nd-order stages each, 24 dB/octave, in phase.
    struct Split {
        modes::PairSvf first, low, high;
        void set(double hz, double sr) noexcept {
            first.set(hz, kSqrtHalf, sr);
            low.set(hz, kSqrtHalf, sr);
            high.set(hz, kSqrtHalf, sr);
        }
        void process(Pair x, Pair& lo, Pair& hi) noexcept {
            Pair v1, v2;
            first.step(x, v1, v2);
            const Pair h = x - splat(first.coef.k()) * v1 - v2;
            lo = low.low(v2);
            hi = high.high(h);
        }
        void clear() noexcept { first.clear(), low.clear(), high.clear(); }
        void flush() noexcept { first.flush(), low.flush(), high.flush(); }
    };
    struct BandInfo {
        int type = 1;
        double drive = 0.3, gain = 1, makeup = 1, tilt = 0, toneK = 0.1, peakIn = 0, peakOut = 0;
        Pair tone{};
        bool solo = false, muted = false;
        Ramp mix;
        void mixSkip(uint32_t n) noexcept {
            for (uint32_t i = 0; i < n; ++i) mix.next();
        }
    };
    const ModuleDescriptor& d_;
    Split split_[kBands - 1];
    modes::PairSvf comp_[kBands - 1][kBands - 1];  // [band][crossover above it]
    BandInfo info_[kBands];
    Pair dc_{};
    double freq_[kBands - 1] = {120, 1000, 5000}, dcK_ = 0;
    int count_ = 3;
    Ramp outRamp_, mixRamp_;
};

// ---------- Descriptors, factories and presets ----------

const ModuleDescriptor& base(const ParamTable& t, CpuClass cpu) {
    static std::deque<ModuleDescriptor> made;  // start-up only
    return made.emplace_back(withCpu(effectDescriptor(kDriveId, kDriveName, t, 0, 0), cpu));
}

using V = std::vector<std::pair<std::string_view, double>>;
BuiltinPreset preset(const char* name, const char* description, V values, double variant) {
    values.emplace_back("variant", variant);
    return {name, description, std::move(values)};
}

const std::vector<BuiltinPreset>& presets() {
    static const std::vector<BuiltinPreset> p = {
        // Amp (4)
        preset("Clean jazz amp", "Guitar: round, clean, a touch of warmth", {{"voicing", 0}, {"gain", 0.3}, {"bass", 0.55}, {"treble", 0.4}, {"presence", 0.2}}, 4),
        preset("Edge of breakup", "Guitar: clean until you dig in", {{"voicing", 0}, {"gain", 0.8}, {"mid", 0.6}, {"presence", 0.4}}, 4),
        preset("Classic crunch", "Guitar: chords that bite, a British-style crunch", {{"voicing", 1}, {"gain", 0.55}, {"mid", 0.65}, {"treble", 0.6}}, 4),
        preset("Blues lead", "Guitar: a singing lead with a mid push", {{"voicing", 2}, {"gain", 0.45}, {"mid", 0.7}, {"presence", 0.5}}, 4),
        preset("Modern high gain", "Guitar: tight, scooped rhythm for heavy riffs", {{"voicing", 3}, {"gain", 0.7}, {"bass", 0.6}, {"mid", 0.3}, {"treble", 0.6}, {"presence", 0.6}}, 4),
        preset("Bass amp grit", "Bass: a driven bass amp, lows kept", {{"voicing", 1}, {"gain", 0.35}, {"bass", 0.65}, {"mid", 0.55}, {"treble", 0.35}}, 4),
        preset("Drum smash amp", "Drums: a room mic through a cranked amp, blended", {{"voicing", 2}, {"gain", 0.8}, {"mix", 0.3}}, 4),
        preset("Vocal amp", "Vocals: a megaphone-like, mid-forward amp", {{"voicing", 1}, {"gain", 0.4}, {"bass", 0.2}, {"mid", 0.85}, {"treble", 0.4}}, 4),
        // Pedal (5)
        preset("Green overdrive", "Guitar: a mid-hump overdrive in front of an amp", {{"type", 0}, {"drive", 0.4}, {"tone", 0.55}}, 5),
        preset("Light boost", "Guitar: a little hair on a clean tone", {{"type", 0}, {"drive", 0.15}, {"tone", 0.6}, {"level", 2}}, 5),
        preset("Rat-style distortion", "Guitar: a gritty, hard-clipped distortion", {{"type", 1}, {"drive", 0.6}, {"tone", 0.45}}, 5),
        preset("Wall of fuzz", "Guitar: thick, saturated fuzz", {{"type", 2}, {"drive", 0.8}, {"tone", 0.4}}, 5),
        preset("Bass fuzz blend", "Bass: fuzz under the clean low end", {{"type", 2}, {"drive", 0.6}, {"tone", 0.35}, {"mix", 0.4}}, 5),
        preset("Vocal distortion", "Vocals: a gritty, telephone-ish edge", {{"type", 1}, {"drive", 0.3}, {"tone", 0.6}, {"mix", 0.5}}, 5),
        preset("Drum crush pedal", "Drums: distortion pushed hard, blended under the kit", {{"type", 1}, {"drive", 0.9}, {"tone", 0.5}, {"mix", 0.25}}, 5),
        preset("Lo-fi fuzz", "Lo-fi: a gated, dark, broken fuzz", {{"type", 2}, {"drive", 1.0}, {"tone", 0.15}}, 5),
        // Bands (6)
        preset("Bass split drive", "Bass: clean lows, driven mids and highs", {{"bands", 1}, {"x1", 200}, {"b1_type", 0}, {"b2_type", 3}, {"b2_drive", 0.5}}, 6),
        preset("Drum bus grit", "Drums: soft lows, hard-clipped snare band, airy tops", {{"bands", 2}, {"b1_type", 1}, {"b1_drive", 0.2}, {"b2_type", 2}, {"b2_drive", 0.4}, {"b3_type", 1}, {"b3_drive", 0.2}}, 6),
        preset("Vocal presence drive", "Vocals: only the presence band driven", {{"bands", 2}, {"x1", 800}, {"x2", 4000}, {"b1_type", 0}, {"b2_type", 3}, {"b2_drive", 0.35}, {"b3_type", 0}}, 6),
        preset("Mix glue saturation", "Mixing: a little tube on each of four bands", {{"bands", 3}, {"b1_type", 3}, {"b2_type", 3}, {"b3_type", 3}, {"b4_type", 3}, {"b1_drive", 0.15}, {"b2_drive", 0.15}, {"b3_drive", 0.15}, {"b4_drive", 0.1}}, 6),
        preset("Master band warmth", "Mastering: gentle soft clip on the lows and mids only", {{"bands", 2}, {"x1", 150}, {"x2", 3000}, {"b1_type", 1}, {"b1_drive", 0.08}, {"b2_type", 1}, {"b2_drive", 0.06}, {"b3_type", 0}}, 6),
        preset("Guitar high fold", "Guitar: folded top end, the lows left clean", {{"bands", 1}, {"x1", 1500}, {"b1_type", 0}, {"b2_type", 5}, {"b2_drive", 0.5}, {"b2_mix", 0.6}}, 6),
        preset("Sound design shred", "Sound design: four bands, four kinds of damage", {{"bands", 3}, {"b1_type", 4}, {"b2_type", 2}, {"b3_type", 5}, {"b4_type", 3}, {"b1_drive", 0.7}, {"b2_drive", 0.7}, {"b3_drive", 0.7}, {"b4_drive", 0.7}}, 6),
        preset("Lo-fi mids", "Lo-fi: the mid band fuzzed, the rest dulled", {{"bands", 2}, {"b1_type", 0}, {"b1_tone", -0.5}, {"b2_type", 4}, {"b2_drive", 0.6}, {"b3_type", 0}, {"b3_tone", -0.8}}, 6),
    };
    return p;
}

template <class T>
ModuleProcessor* makeAs(const ModuleDescriptor& v) noexcept {
    return new (std::nothrow) T(v);
}

const ModuleDescriptor& ampBase() {
    static const ModuleDescriptor& d = base(ampParams(), CpuClass::Medium);
    return d;
}
const ModuleDescriptor& pedalBase() {
    static const ModuleDescriptor& d = base(pedalParams(), CpuClass::Medium);
    return d;
}
const ModuleDescriptor& bandsBase() {
    static const ModuleDescriptor& d = base(bandsParams(), CpuClass::Medium);
    return d;
}

}  // namespace

const ModuleDescriptor& ampDriveDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(ampBase(), kDriveId, kDriveName, labels, index);
    return d;
}
const ModuleDescriptor& pedalDriveDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(pedalBase(), kDriveId, kDriveName, labels, index);
    return d;
}
const ModuleDescriptor& bandsDriveDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(bandsBase(), kDriveId, kDriveName, labels, index);
    return d;
}
ModuleProcessor* makeAmpDriveAs(const ModuleDescriptor& v) noexcept {
    halfBand();
    return makeAs<Amp>(v);
}
ModuleProcessor* makePedalDriveAs(const ModuleDescriptor& v) noexcept {
    halfBand();
    return makeAs<Pedal>(v);
}
ModuleProcessor* makeBandsDriveAs(const ModuleDescriptor& v) noexcept { return makeAs<Bands>(v); }
std::span<const BuiltinPreset> driveModePresets() { return presets(); }

}  // namespace caw::fx
