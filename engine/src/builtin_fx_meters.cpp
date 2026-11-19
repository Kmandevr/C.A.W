// Meters (org.caw.meters, 1.1.0): Analyzer (spectrum), Tuner (YIN pitch and cents) and Loudness (BS.1770 LUFS and true peak); audio passes unchanged.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <new>

#include "builtin_effects.h"
#include "builtin_fx_tools.h"
#include "caw/library/spectrum.hpp"
#include "meters.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0). Each mode is its own variant (fx_merged.h), so only the chosen one runs, and
// each passes its input to its output bit for bit: a meter never changes the sound.
// - Analyzer: the Library's display analyzer (caw/library/spectrum.hpp: a 2048-point FFT, 128 log bins), fed and
//   run only while a page reads it (DisplayBuffer::watched), 30 times a second.
// - Tuner: YIN (A. de Cheveigne and H. Kawahara, "YIN, a fundamental frequency estimator for speech and music",
//   J. Acoust. Soc. Am. 111(4), 1917-1930, 2002), written here from the paper's steps (difference function,
//   cumulative mean normalised difference, absolute threshold, parabolic interpolation); aubio's GPL code is not
//   used. The input is summed to mono, low-passed and decimated to about 12 kHz (a boxcar of 4 at 48 kHz), and a
//   window of 384 decimated samples is analysed 15 times a second while a page reads it.
// - Loudness: the Engine's LoudnessMeter (meters.h: ITU-R BS.1770-5 K-weighting, gating and true peak, with
//   momentary 400 ms and short-term 3 s windows per EBU Tech 3341 V4, the meter EBU R 128 specifies), always
//   measuring (the integrated value needs every block), its integrated value worked out 10 times a second.

namespace caw::fx {

namespace {

constexpr std::string_view kMetersId = "org.caw.meters";
constexpr std::string_view kMetersName = "Meters";
constexpr std::string_view kMeterVariants[] = {"Analyzer", "Tuner", "Loudness"};

ModuleDescriptor meterBase(const ParamTable& t) {
    ModuleDescriptor d = effectDescriptor(kMetersId, kMetersName, t, 0, 0);
    d.domains = kDomainWhole;  // a meter reads the whole signal
    d.cpuClass = CpuClass::Light;
    d.role = ModuleRole::Analyzer;
    return d;
}

// Every mode: the input to the output, unchanged.
inline void passThrough(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept {
    std::memcpy(outL, inL, n * sizeof(float));
    std::memcpy(outR, inR, n * sizeof(float));
}

// ---- Analyzer --------------------------------------------------------------------------------------------------
enum AnalyzerParam : uint32_t { anSource, anTilt, anCount };
constexpr std::string_view kSources[] = {"Left/right", "Mid/side", "Mono"};
constexpr uint32_t kBins = 128;

const ParamTable& analyzerParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("source", "Source", 0, kSources);
        p.num("tilt", "Tilt", 4.5, 0.0, 6.0, "dB/oct").smoothingFrames = 0;
        return p;
    }();
    return t;
}
const ModuleDescriptor& analyzerVariant() {
    static const ModuleDescriptor base = meterBase(analyzerParams());
    static const ModuleDescriptor& d = legacyVariantDescriptor(base, kMetersId, kMetersName, kMeterVariants, 0);
    return d;
}

class Analyzer final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return analyzerVariant(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        try {
            spec_.prepare(sampleRate, kBins);
        } catch (...) {
            return false;
        }
        for (uint32_t j = 0; j < kBins; ++j) octaves_[j] = static_cast<float>(std::log2(spec_.binHz(j) / 1000.0));
        return true;
    }
    void control(uint32_t at) noexcept override { source_ = choice(anSource, at); }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        passThrough(inL, inR, outL, outR, n);
        if (!feed_) return;
        if (source_ == 1)
            for (uint32_t i = 0; i < n; ++i) spec_.push(0.5f * (inL[i] + inR[i]), 0.5f * (inL[i] - inR[i]));
        else if (source_ == 2)
            for (uint32_t i = 0; i < n; ++i) spec_.push(0.5f * (inL[i] + inR[i]), 0.0f);
        else
            for (uint32_t i = 0; i < n; ++i) spec_.push(inL[i], inR[i]);
    }
    void clearState() noexcept override {
        spec_.clear();
        std::fill(std::begin(a_), std::end(a_), -120.0f);
        std::fill(std::begin(b_), std::end(b_), -120.0f);
    }
    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        if (watched && !feed_) spec_.clear();  // back on screen: start from fresh audio
        feed_ = watched;
        const float tilt = static_cast<float>(param(anTilt, 0));
        if (watched && (half_ = !half_)) {  // 30 analyses a second
            spec_.analyze(a_, b_);
            if (source_ == 2) std::fill(std::begin(b_), std::end(b_), -120.0f);
        }
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(kBins);
        out[3] = watched ? 1.0f : 0.0f;
        out[4] = static_cast<float>(source_);
        out[5] = tilt;
        float best = -1e9f;
        uint32_t at = 0;
        for (uint32_t j = 0; j < kBins; ++j) {
            const float t = tilt * octaves_[j];
            out[8 + j] = watched ? std::max(-120.0f, a_[j] + t) : -120.0f;
            out[8 + kBins + j] = watched ? std::max(-120.0f, b_[j] + t) : -120.0f;
            if (a_[j] > best) best = a_[j], at = j;
        }
        out[6] = watched ? static_cast<float>(spec_.binHz(at)) : 0.0f;
        out[7] = watched ? best : -120.0f;
        return 8 + 2 * kBins;
    }

private:
    lib::SpectrumAnalyzer spec_;
    float a_[kBins] = {}, b_[kBins] = {}, octaves_[kBins] = {};
    int source_ = 0;
    bool feed_ = false, half_ = false;
};

// ---- Tuner -----------------------------------------------------------------------------------------------------
enum TunerParam : uint32_t { tuReference, tuRange, tuThreshold, tuCount };
constexpr std::string_view kRanges[] = {"Wide", "Bass", "Guitar", "Voice"};
constexpr double kRangeLo[] = {30.0, 28.0, 70.0, 70.0}, kRangeHi[] = {1500.0, 450.0, 1300.0, 1500.0};
constexpr uint32_t kWindow = 384;   // decimated samples summed by the difference function (32 ms at 12 kHz)
constexpr uint32_t kRing = 1024;    // decimated history: the window and the longest lag (30 Hz: 400)

const ParamTable& tunerParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("reference", "A4", 440.0, 415.0, 466.0, "Hz").smoothingFrames = 0;
        p.pick("range", "Range", 0, kRanges);
        p.num("threshold", "Threshold", 0.15, 0.05, 0.5).smoothingFrames = 0;
        return p;
    }();
    return t;
}
const ModuleDescriptor& tunerVariant() {
    static const ModuleDescriptor base = meterBase(tunerParams());
    static const ModuleDescriptor& d = legacyVariantDescriptor(base, kMetersId, kMetersName, kMeterVariants, 1);
    return d;
}

class Tuner final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return tunerVariant(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        decim_ = std::max(1, static_cast<int>(sampleRate / 11000.0));
        fs_ = sampleRate / decim_;
        lpCoef_ = static_cast<float>(1.0 - std::exp(-2.0 * 3.14159265358979323846 * 2500.0 / sampleRate));
        return true;
    }
    void control(uint32_t) noexcept override {}
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        passThrough(inL, inR, outL, outR, n);
        if (!feed_) return;
        for (uint32_t i = 0; i < n; ++i) {
            lp_ += lpCoef_ * (0.5f * (inL[i] + inR[i]) - lp_);
            acc_ += lp_;
            if (++count_ == decim_) {
                ring_[pos_] = acc_ / static_cast<float>(decim_);
                pos_ = (pos_ + 1) & (kRing - 1);
                acc_ = 0.0f;
                count_ = 0;
            }
        }
    }
    void clearState() noexcept override {
        std::fill(std::begin(ring_), std::end(ring_), 0.0f);
        lp_ = acc_ = 0.0f;
        count_ = 0;
        pos_ = 0;
        detected_ = false;
    }
    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        if (watched && !feed_) clearState();
        feed_ = watched;
        const double ref = param(tuReference, 0);
        if (watched && ++tick_ >= 4) {  // 15 analyses a second
            tick_ = 0;
            analyse(ref);
        }
        const double midi = detected_ ? 69.0 + 12.0 * std::log2(hz_ / ref) : 0.0;
        const double note = std::floor(midi + 0.5);
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = detected_ ? 1.0f : 0.0f;
        out[3] = static_cast<float>(detected_ ? hz_ : 0.0);
        out[4] = static_cast<float>(detected_ ? note : 0.0);
        out[5] = static_cast<float>(detected_ ? 100.0 * (midi - note) : 0.0);
        out[6] = static_cast<float>(confidence_);
        out[7] = static_cast<float>(ref);
        out[8] = static_cast<float>(midi);
        return 9;
    }

private:
    void analyse(double) noexcept {
        const int range = std::clamp(choice(tuRange, 0), 0, 3);
        const uint32_t maxLag = std::min<uint32_t>(kRing - kWindow - 2, static_cast<uint32_t>(fs_ / kRangeLo[range]));
        const uint32_t minLag = std::max<uint32_t>(2, static_cast<uint32_t>(fs_ / kRangeHi[range]));
        const uint32_t need = kWindow + maxLag + 1;
        float x[kRing];
        for (uint32_t i = 0; i < need; ++i) x[i] = ring_[(pos_ + kRing - need + i) & (kRing - 1)];
        double energy = 0.0;
        for (uint32_t i = 0; i < kWindow; ++i) energy += static_cast<double>(x[i]) * x[i];
        detected_ = false;
        confidence_ = 0.0;
        if (energy / kWindow < 1e-7) return;  // below about -70 dBFS: nothing to tune
        // YIN steps 2-3: the difference function and its cumulative mean normalised form, d'(0) = 1.
        float dn[kRing];
        dn[0] = 1.0f;
        double running = 0.0;
        for (uint32_t tau = 1; tau <= maxLag + 1; ++tau) {
            float d = 0.0f;
            for (uint32_t j = 0; j < kWindow; ++j) {
                const float e = x[j] - x[j + tau];
                d += e * e;
            }
            running += d;
            dn[tau] = running > 0.0 ? static_cast<float>(d * tau / running) : 1.0f;
        }
        // Step 4: the first dip under the threshold (then down to its bottom); none: no pitch.
        const float threshold = static_cast<float>(param(tuThreshold, 0));
        uint32_t tau = 0;
        for (uint32_t t = minLag; t <= maxLag; ++t)
            if (dn[t] < threshold) {
                while (t + 1 <= maxLag && dn[t + 1] < dn[t]) ++t;
                tau = t;
                break;
            }
        if (tau == 0) return;
        // Step 5: parabolic interpolation around the dip.
        const double a = dn[tau - 1], b = dn[tau], c = dn[tau + 1];
        const double den = a - 2.0 * b + c;
        const double shift = den > 0.0 ? std::clamp(0.5 * (a - c) / den, -0.5, 0.5) : 0.0;
        hz_ = fs_ / (tau + shift);
        confidence_ = std::clamp(1.0 - b, 0.0, 1.0);
        detected_ = true;
    }

    float ring_[kRing] = {};
    float lp_ = 0, acc_ = 0, lpCoef_ = 0.3f;
    int decim_ = 4, count_ = 0;
    uint32_t pos_ = 0, tick_ = 0;
    double fs_ = 12000.0, hz_ = 0.0, confidence_ = 0.0;
    bool detected_ = false, feed_ = false;
};

// ---- Loudness --------------------------------------------------------------------------------------------------
enum LoudParam : uint32_t { loTarget, loResetOnPlay, loReset, loCount };
constexpr std::string_view kOffOnL[] = {"Off", "On"};

const ParamTable& loudParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("target", "Target", -14.0, -36.0, -5.0, "LUFS").smoothingFrames = 0;
        p.pick("reset_on_play", "Reset on Play", 1, kOffOnL);
        ParameterDescriptor& r = p.pick("reset", "Reset", 0, kOffOnL);  // Off to On: the integrated value starts over
        r.automatable = false;
        r.modulatable = false;
        return p;
    }();
    return t;
}
const ModuleDescriptor& loudVariant() {
    static const ModuleDescriptor base = withCpu(meterBase(loudParams()), CpuClass::Medium);  // BS.1770's 4x true peak
    static const ModuleDescriptor& d = legacyVariantDescriptor(base, kMetersId, kMetersName, kMeterVariants, 2);
    return d;
}

class Loudness final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return loudVariant(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        meter_ = std::unique_ptr<LoudnessMeter>(new (std::nothrow) LoudnessMeter());
        if (!meter_) return false;
        meter_->prepare(sampleRate);
        return true;
    }
    // Never asleep once woken: the windows must see the silence after the music (the integrated value gates it out).
    uint64_t idleFrames() const noexcept override { return ~0ull >> 1; }
    void control(uint32_t at) noexcept override {
        double beat;
        const bool playing = beatAt(at, beat);
        const bool reset = on(loReset, at);
        if ((reset && !resetWas_) || (playing && !playingWas_ && on(loResetOnPlay, at))) meter_->requestReset();
        resetWas_ = reset;
        playingWas_ = playing;
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        passThrough(inL, inR, outL, outR, n);
        meter_->process(inL, inR, static_cast<int>(n));
    }
    void clearState() noexcept override {
        if (meter_) meter_->requestReset();
        shown_ = LoudnessMeter::Reading{};
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        if (++tick_ >= 6) {  // 10 readings a second (the integrated value walks the histogram)
            tick_ = 0;
            const LoudnessMeter::Reading r = meter_->read();
            shown_ = r;
            tpL_ = std::max(tpL_, r.truePeakL);
            tpR_ = std::max(tpR_, r.truePeakR);
        }
        const double target = param(loTarget, 0);
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = shown_.momentary;
        out[3] = shown_.shortTerm;
        out[4] = shown_.integrated;
        out[5] = shown_.momentaryMax;
        out[6] = shown_.shortTermMax;
        out[7] = tick_ == 0 ? tpL_ : shown_.truePeakL;
        out[8] = tick_ == 0 ? tpR_ : shown_.truePeakR;
        out[9] = shown_.truePeakMax;
        out[10] = static_cast<float>(shown_.integratedSeconds);
        out[11] = static_cast<float>(target);
        out[12] = shown_.integrated > kMeterNone ? static_cast<float>(shown_.integrated - target) : 0.0f;
        if (tick_ == 0) tpL_ = tpR_ = kMeterNone;
        return 13;
    }

private:
    std::unique_ptr<LoudnessMeter> meter_;
    LoudnessMeter::Reading shown_;
    float tpL_ = kMeterNone, tpR_ = kMeterNone;
    uint32_t tick_ = 0;
    bool resetWas_ = false, playingWas_ = false;
};

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

const Variant kMeters[] = {{kMeterVariants[0], &analyzerVariant, &make<Analyzer>},
                           {kMeterVariants[1], &tunerVariant, &make<Tuner>},
                           {kMeterVariants[2], &loudVariant, &make<Loudness>}};
const MergedDevice kMeterDevices[] = {{kMetersId, kMetersName, kMeters}};

}  // namespace

std::span<const MergedDevice> mergedMeterDevices() { return kMeterDevices; }

const std::vector<BuiltinPreset>& meterPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Mix spectrum", "Mixing: left and right, tilted 4.5 dB an octave so a balanced mix reads flat", {{"variant", 0}}},
        {"Flat spectrum", "Sound design: no tilt, the plain FFT", {{"variant", 0}, {"tilt", 0}}},
        {"Master tilt 3 dB", "Mastering: a gentler 3 dB an octave slope", {{"variant", 0}, {"tilt", 3}}},
        {"Mid and side", "Mastering: what is centred against what is wide", {{"variant", 0}, {"source", 1}}},
        {"Mono sum", "Mixing: one spectrum of the summed sides", {{"variant", 0}, {"source", 2}}},
        {"Bass check", "Bass: mono sum, flat, to see the low end", {{"variant", 0}, {"source", 2}, {"tilt", 0}}},
        {"Vocal spectrum", "Vocals: mid and side, 4.5 dB tilt", {{"variant", 0}, {"source", 1}, {"tilt", 4.5}}},
        {"Drum bus spectrum", "Drums: left and right, 3 dB tilt", {{"variant", 0}, {"tilt", 3}}},
        {"Guitar tuner", "Guitar: 70 Hz to 1.3 kHz, A = 440 Hz", {{"variant", 1}, {"range", 2}}},
        {"Bass tuner", "Bass: down to a low B (31 Hz)", {{"variant", 1}, {"range", 1}}},
        {"Vocal pitch", "Vocals: a singer's range, a stricter threshold", {{"variant", 1}, {"range", 3}, {"threshold", 0.1}}},
        {"Wide tuner", "Sound design: 30 Hz to 1.5 kHz", {{"variant", 1}}},
        {"Baroque A415", "Guitar: period tuning, A = 415 Hz", {{"variant", 1}, {"reference", 415}}},
        {"Orchestra A442", "Mixing: A = 442 Hz, as many orchestras tune", {{"variant", 1}, {"reference", 442}}},
        {"Noisy room tuner", "Guitar: a looser threshold for a noisy signal", {{"variant", 1}, {"range", 2}, {"threshold", 0.3}}},
        {"Synth tuner", "Sound design: wide range, strict threshold", {{"variant", 1}, {"threshold", 0.08}}},
        {"Streaming -14 LUFS", "Mastering: Spotify's and YouTube's normalisation level", {{"variant", 2}, {"target", -14}}},
        {"Apple Music -16 LUFS", "Mastering: Apple's Sound Check level", {{"variant", 2}, {"target", -16}}},
        {"Podcast -16 LUFS", "Vocals: a common spoken-word target", {{"variant", 2}, {"target", -16}}},
        {"Broadcast R128 -23 LUFS", "Mastering: EBU R 128's programme level", {{"variant", 2}, {"target", -23}}},
        {"US broadcast -24 LUFS", "Mastering: ATSC A/85's level", {{"variant", 2}, {"target", -24}}},
        {"Loud master -9 LUFS", "Mastering: a loud club master's reading", {{"variant", 2}, {"target", -9}}},
        {"Film dialogue -27 LUFS", "Mixing: a quiet dialogue reference", {{"variant", 2}, {"target", -27}}},
        {"Whole session", "Mixing: keeps measuring across Plays", {{"variant", 2}, {"reset_on_play", 0}}},
    };
    return p;
}

}  // namespace caw::fx
