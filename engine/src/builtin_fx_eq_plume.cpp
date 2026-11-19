// The EQ's 1.1.0 variants: Linear (the bands as a linear-phase FIR) and Match (a learned curve as a minimum-phase FIR).
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>
#include <span>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/convolver.hpp"
#include "caw/library/eq.hpp"
#include "caw/library/spectrum.hpp"
#include "component_chain.h"
#include "eq_bands.h"
#include "eq_design.h"
#include "fx_merged.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0).
//
// Linear: the bands' summed magnitude (each band's EqFilter::magnitude2 on the design grid, the bands of each lane
// multiplied; Match's curve multiplied in when on) becomes a zero-phase FIR by frequency sampling (one inverse
// FFT for both lanes), centred, Kaiser-windowed (beta 6) and played by a uniformly partitioned convolver of 256-frame
// partitions. The lanes are mid and side (a Stereo band is on both, Mid or Side on one; Left and Right bands act
// as Stereo here: a linear-phase pair of lanes cannot cross the sides). Taps by `lin_quality`: Eco 2,048, Normal
// 4,096, High 8,192; latency taps / 2 + 256 frames (1,280, 2,304, 4,352), reported per instance (VariableLatency).
// A moved knob designs the new FIR a slice per control step (about 60-150 steps) and the convolver crossfades to
// it over one partition; the first design runs at once, so a render starts with the right sound. No dynamics
// (a FIR can't follow a gain that moves every period).
//
// Match: learns the long-term spectra of a reference (the key) and of the input (eq_design.h's Welch learner),
// and plays their difference (smoothed, clamped to +-12 dB, times Amount, within Low and High) as a minimum-phase
// FIR (the cepstral method: the log magnitude's real cepstrum folded onto positive times, then exponentiated) of
// 2,048 taps in 128-frame partitions: 128 frames of latency. The learned spectra are its saved state. Its display
// carries a fit of up to 8 bells to the curve for the app's "Fit bands" (written into the Bands variant).
// [Assumption] Not patent-checked (the design notes say: check before it ships).

namespace caw::fx {

namespace {

using eqd::SpectrumLearner;

constexpr uint32_t kLinBlock = 256;
constexpr uint32_t kMatchBlock = 128, kMatchTaps = 2048, kMatchFft = 4096;
constexpr uint32_t kShowPoints = eqd::kGrid / 2;  // the display's grid: every other point (1/12 octave)
constexpr std::string_view kQualities[] = {"Eco", "Normal", "High"};
constexpr std::string_view kLearn[] = {"Off", "Reference", "Input", "Both"};

uint32_t linTaps(int tier) noexcept { return 2048u << std::clamp(tier, 0, 2); }
uint32_t linLatency(int tier) noexcept { return linTaps(tier) / 2 + kLinBlock; }

// Match's knobs (shared ids, so a value moves between Linear and Match with the variant).
void addMatchParams(ParamTable& p, bool on) {
    p.pick("match", "Match", on ? 1.0 : 0.0, kOffOn);
    p.num("match_amount", "Match amount", 1.0, 0.0, 1.0);
    p.num("match_smooth", "Match smoothing", 0.3, 0.0, 1.0);
    p.expo("match_low", "Match low", 20.0, 20.0, 20000.0, "Hz");
    p.expo("match_high", "Match high", 20000.0, 20.0, 20000.0, "Hz");
    // Learning is an action (the app's Learn button), not a sound: no lanes, modulation or MIDI.
    ParameterDescriptor& l = p.pick("match_learn", "Learn", 0.0, kLearn);
    l.automatable = l.modulatable = l.midiMappable = false;
}

// Linear's parameters: the bands and output (0..48), then these.
enum LinParam : uint32_t { kLinQuality = kEqOutput + 1, kLinSolo, kLinMatch, kLinAmount, kLinSmooth, kLinLow, kLinHigh, kLinLearn, kLinCount };
const ParamTable& linParams() {
    static const ParamTable t = [] {
        ParamTable p;
        addEqBandParams(p);
        // Sets the latency (latencyFor): no lane, modulation or MIDI may move it.
        ParameterDescriptor& q = p.pick("lin_quality", "Linear-phase quality", 1.0, kQualities);
        q.automatable = q.modulatable = q.midiMappable = false;
        addEqSolo(p);
        addMatchParams(p, false);
        return p;
    }();
    return t;
}
enum MatchParam : uint32_t { kMOn, kMAmount, kMSmooth, kMLow, kMHigh, kMLearn, kMOutput, kMCount };
const ParamTable& matchParams() {
    static const ParamTable t = [] {
        ParamTable p;
        addMatchParams(p, true);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}

const ModuleDescriptor& linBaseDescriptor() {
    static const ModuleDescriptor d = [] {
        (void)eqd::tables();  // the shared tables, built at registration
        return withCpu(keyedEffectDescriptor("org.caw.eq", "EQ", linParams(), linLatency(1), linTaps(2), false), CpuClass::Heavy);
    }();
    return d;
}
const ModuleDescriptor& matchBaseDescriptor() {
    static const ModuleDescriptor d = [] {
        (void)eqd::tables();
        return keyedEffectDescriptor("org.caw.eq", "EQ", matchParams(), kMatchBlock, kMatchTaps, false);
    }();
    return d;
}

// What both variants share: learning, the curve, and its part of the display.
struct MatchPart {
    SpectrumLearner learner;
    int learn = 0;  // kLearn
    bool on = false;
    double amount = 1, smooth = 0.3, low = 20, high = 20000;
    double curve[eqd::kGrid] = {};
    uint32_t shownGen = ~0u, fitGen = ~0u;
    float ref[kShowPoints] = {}, in[kShowPoints] = {};
    eqd::FitBand fit[kEqBands];

    bool prepare() { return learner.prepare(); }
    // The knobs; a take that starts forgets what its side learned before.
    void read(int newLearn, bool o, double a, double s, double lo, double hi) noexcept {
        if (newLearn != learn) {
            const bool refNow = newLearn == 1 || newLearn == 3, inNow = newLearn == 2 || newLearn == 3;
            const bool refWas = learn == 1 || learn == 3, inWas = learn == 2 || learn == 3;
            if (refNow && !refWas) learner.forget(SpectrumLearner::kReference);
            if (inNow && !inWas) learner.forget(SpectrumLearner::kInput);
            learner.clear();
            learn = newLearn;
        }
        on = o, amount = a, smooth = s, low = lo, high = hi;
    }
    bool learning() const noexcept { return learn != 0; }
    void push(const float* kL, const float* kR, const float* inL, const float* inR, uint32_t n) noexcept {
        if (learn) learner.push(kL, kR, inL, inR, n, learn == 1 || learn == 3, learn == 2 || learn == 3);
    }
    bool flat() const noexcept {
        for (double v : curve)
            if (v != 0.0) return false;
        return true;
    }
    void makeCurve(double sr) noexcept {
        if (on) eqd::matchCurve(learner, sr, amount, smooth, low, high, curve);
        else std::fill(std::begin(curve), std::end(curve), 0.0);
    }
    // Its display block at out (6 + 3 x kShowPoints + 3 x 8 floats); returns the count.
    uint32_t display(float* out, bool watched, double sr) noexcept {
        out[0] = static_cast<float>(learn);
        out[1] = static_cast<float>(learner.seconds(SpectrumLearner::kReference, sr));
        out[2] = static_cast<float>(learner.seconds(SpectrumLearner::kInput, sr));
        out[3] = static_cast<float>(kShowPoints);
        out[4] = static_cast<float>(eqd::gridHz(0));
        out[5] = static_cast<float>(eqd::gridHz(2 * (kShowPoints - 1)));
        float* o = out + 6;
        if (watched && shownGen != learner.generation()) {  // the spectra again only when they changed
            double g[eqd::kGrid];
            eqd::spectrumOnGrid(learner, SpectrumLearner::kReference, sr, g);
            for (uint32_t j = 0; j < kShowPoints; ++j) ref[j] = static_cast<float>(g[2 * j]);
            eqd::spectrumOnGrid(learner, SpectrumLearner::kInput, sr, g);
            for (uint32_t j = 0; j < kShowPoints; ++j) in[j] = static_cast<float>(g[2 * j]);
            shownGen = learner.generation();
        }
        for (uint32_t j = 0; j < kShowPoints; ++j) o[j] = ref[j], o[kShowPoints + j] = in[j];
        for (uint32_t j = 0; j < kShowPoints; ++j) o[2 * kShowPoints + j] = static_cast<float>(curve[2 * j]);
        o += 3 * kShowPoints;
        // The fit of the full curve (as if Amount were 1 and limits open, so Fit bands gives the whole match).
        if (watched && fitGen != learner.generation()) {
            double residual[eqd::kGrid];
            eqd::matchCurve(learner, sr, 1.0, smooth, low, high, residual);
            for (eqd::FitBand& b : fit) b = eqd::fitOneBand(residual, sr);
            fitGen = learner.generation();
        }
        for (uint32_t b = 0; b < kEqBands; ++b) {
            o[3 * b] = static_cast<float>(fit[b].freq);
            o[3 * b + 1] = static_cast<float>(fit[b].gain);
            o[3 * b + 2] = static_cast<float>(fit[b].q);
        }
        return 6 + 3 * kShowPoints + 3 * kEqBands;
    }
};
constexpr uint32_t kMatchDisplay = 6 + 3 * kShowPoints + 3 * kEqBands;

// ---------- Linear ----------

constexpr uint32_t kSpectrumBins = 128;
// Bands' layout (builtin_effects_eq.cpp: 456 floats, dynamics shown as off), then the linear part and Match's.
constexpr uint32_t kLHeader = 4, kLPre = 4, kLPost = kLPre + kSpectrumBins, kLCurve = kLPost + kSpectrumBins,
                   kLBands = kLCurve + kSpectrumBins, kLOutput = kLBands + kEqBands * kEqBandParams, kLDyn = kLOutput + 3,
                   kLLevel = kLDyn + kEqBands, kLSolo = kLLevel + kEqBands, kLLatency = kLSolo + 1, kLMatch = kLLatency + 3,
                   kLSize = kLMatch + kMatchDisplay;
static_assert(kLHeader == kLPre && kLSize <= kMaxDisplayFloats);

struct LinKey {
    int tier = -1;
    bool use[kEqBands] = {};
    int type[kEqBands] = {}, channel[kEqBands] = {};
    double freq[kEqBands] = {}, gain[kEqBands] = {}, q[kEqBands] = {};
    bool match = false;
    uint32_t matchGen = 0;
    double amount = 0, smooth = 0, low = 0, high = 0;
    bool operator==(const LinKey& o) const noexcept {
        if (tier != o.tier || match != o.match) return false;
        if (match && (matchGen != o.matchGen || amount != o.amount || smooth != o.smooth || low != o.low || high != o.high)) return false;
        for (uint32_t b = 0; b < kEqBands; ++b) {
            if (use[b] != o.use[b]) return false;
            if (use[b] && (type[b] != o.type[b] || channel[b] != o.channel[b] || freq[b] != o.freq[b] || gain[b] != o.gain[b] || q[b] != o.q[b]))
                return false;
        }
        return true;
    }
};

class LinearEq final : public EffectBase, public VariableLatency {
public:
    explicit LinearEq(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    uint32_t latencyFor(const double* values, uint32_t count) const noexcept override {
        return linLatency(count > kLinQuality ? static_cast<int>(values[kLinQuality] + 0.5) : 1);
    }
    uint32_t stateVersion() const noexcept override { return 1; }
    bool saveState(uint8_t* dst, uint32_t capacity, uint32_t& written) const noexcept override {
        return match_.learner.save(dst, capacity, written);
    }
    bool loadState(const uint8_t* src, uint32_t size, uint32_t version) noexcept override {
        return version == 1 && match_.learner.load(src, size);
    }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        try {
            conv_.prepare(kLinBlock, eqd::kMaxFft);
            re_.assign(eqd::kMaxFft, 0.0);
            im_.assign(eqd::kMaxFft, 0.0);
            stageM_.assign(kLinBlock, 0.0f);
            stageS_.assign(kLinBlock, 0.0f);
            analyzer_.prepare(sr, kSpectrumBins, 20.0, 20000.0);
            if (!match_.prepare()) return false;
        } catch (...) {
            return false;
        }
        for (uint32_t j = 0; j < kSpectrumBins; ++j) tan_[j] = detTan(kPi * std::min(analyzer_.binHz(j), 0.49 * sr) / sr);
        outCoef_ = 1.0 - detExp(-1.0 / (0.005 * sr));
        conv_.silence();
        built_ = LinKey{};
        haveBuilt_ = false;
        phase_ = kIdle;
        first_ = true;
        return true;
    }
    void clearState() noexcept override {
        conv_.clear();
        match_.learner.clear();
        analyzer_.clear();
        for (auto& s : soloL_) s.clear();
        for (auto& s : soloR_) s.clear();
        first_ = true;
    }
    uint64_t idleFrames() const noexcept override { return linTaps(2) + kLinBlock + static_cast<uint64_t>(0.05 * rate()); }

    void control(uint32_t at) noexcept override {
        const bool same = knobsUnchanged(knobs_, kLinCount, at);
        if (!same || first_) readKnobs(at);
        if (match_.learning()) match_.learner.step();
        if (phase_ == kIdle && !(want_ == built_)) startJob();
        if (phase_ != kIdle) {
            if (!haveBuilt_) {
                while (phase_ != kIdle) stepJob(true);  // the first design at once (bounded: a few hundred steps)
            } else {
                stepJob(false);
            }
        }
        first_ = false;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        float m[kControlFrames], s[kControlFrames], ym[kControlFrames], ys[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) m[i] = 0.5f * (inL[i] + inR[i]), s[i] = 0.5f * (inL[i] - inR[i]);
        conv_.process(m, s, ym, ys, n);
        double L[kControlFrames], R[kControlFrames];
        if (out_ == outTarget_) {
            for (uint32_t i = 0; i < n; ++i) L[i] = (static_cast<double>(ym[i]) + ys[i]) * out_, R[i] = (static_cast<double>(ym[i]) - ys[i]) * out_;
        } else {
            for (uint32_t i = 0; i < n; ++i) {
                out_ += (outTarget_ - out_) * outCoef_;
                if (std::fabs(out_ - outTarget_) < 1e-12) out_ = outTarget_;
                L[i] = (static_cast<double>(ym[i]) + ys[i]) * out_, R[i] = (static_cast<double>(ym[i]) - ys[i]) * out_;
            }
        }
        if (solo_ > 0)
            for (uint32_t i = 0; i < n; ++i) L[i] = soloFilter_.process(soloL_, L[i]), R[i] = soloFilter_.process(soloR_, R[i]);
        for (uint32_t i = 0; i < n; ++i) outL[i] = static_cast<float>(L[i]), outR[i] = static_cast<float>(R[i]);
        match_.push(keyLeft(), keyRight(), inL, inR, n);
        if (watching_)
            for (uint32_t i = 0; i < n; ++i) analyzer_.push(0.5f * (inL[i] + inR[i]), 0.5f * (outL[i] + outR[i]));
    }

    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        out[0] = static_cast<float>(kSpectrumBins);
        out[1] = static_cast<float>(analyzer_.lowHz());
        out[2] = static_cast<float>(analyzer_.highHz());
        out[3] = watched ? 1.0f : 0.0f;
        watching_ = watched;
        if (watched) {
            analyzer_.analyze(out + kLPre, out + kLPost);
            for (uint32_t j = 0; j < kSpectrumBins; ++j) {
                double mm = outTarget_ * outTarget_;
                for (uint32_t b = 0; b < kEqBands; ++b)
                    if (built_.use[b]) mm *= filter_[b].magnitude2(tan_[j]);
                double db = mm > 1e-24 ? 10.0 * std::log10(mm) : -240.0;
                if (built_.match) db += eqd::curveAt(match_.curve, analyzer_.binHz(j));
                out[kLCurve + j] = static_cast<float>(db);
            }
        } else {
            for (uint32_t j = 0; j < 3 * kSpectrumBins; ++j) out[kLPre + j] = -120.0f;
        }
        for (uint32_t b = 0; b < kEqBands; ++b) {
            float* o = out + kLBands + b * kEqBandParams;
            o[kEqOn] = want_.use[b] ? 1.0f : 0.0f;
            o[kEqType] = static_cast<float>(bandType_[b]);
            o[kEqFreq] = static_cast<float>(want_.freq[b]);
            o[kEqGain] = static_cast<float>(want_.gain[b]);
            o[kEqQ] = static_cast<float>(want_.q[b]);
            o[kEqChannel] = static_cast<float>(bandChannel_[b]);
            out[kLDyn + b] = 0.0f;
            out[kLLevel + b] = -120.0f;
        }
        out[kLOutput] = static_cast<float>(lib::gainToDb(outTarget_));
        out[kLOutput + 1] = inPeakDb();
        out[kLOutput + 2] = outPeakDb();
        out[kLSolo] = static_cast<float>(solo_);
        const int tier = std::max(0, built_.tier);
        out[kLLatency] = static_cast<float>(linLatency(tier) * 1000.0 / rate());
        out[kLLatency + 1] = static_cast<float>(linTaps(tier));
        out[kLLatency + 2] = phase_ != kIdle ? 1.0f : 0.0f;
        match_.display(out + kLMatch, watched, rate());
        return kLSize;
    }

private:
    enum Phase { kIdle, kMag, kFft, kStage };

    void readKnobs(uint32_t at) noexcept {
        const double sr = rate();
        LinKey k;
        k.tier = std::clamp(choice(kLinQuality, at), 0, 2);
        for (uint32_t b = 0; b < kEqBands; ++b) {
            const int type = std::clamp(choice(eqBandParam(b, kEqType), at), 0, static_cast<int>(lib::EqType::Count) - 1);
            const int channel = std::clamp(choice(eqBandParam(b, kEqChannel), at), 0, 4);
            bandType_[b] = type, bandChannel_[b] = channel;
            k.use[b] = on(eqBandParam(b, kEqOn), at);
            if (!k.use[b]) continue;
            k.type[b] = type;
            k.channel[b] = channel;
            k.freq[b] = param(eqBandParam(b, kEqFreq), at);
            k.gain[b] = param(eqBandParam(b, kEqGain), at);
            k.q[b] = param(eqBandParam(b, kEqQ), at);
        }
        for (uint32_t b = 0; b < kEqBands; ++b) {  // keep the display's values for bands that are off
            k.freq[b] = param(eqBandParam(b, kEqFreq), at);
            k.gain[b] = param(eqBandParam(b, kEqGain), at);
            k.q[b] = param(eqBandParam(b, kEqQ), at);
        }
        match_.read(std::clamp(choice(kLinLearn, at), 0, 3), on(kLinMatch, at), param(kLinAmount, at), param(kLinSmooth, at),
                    param(kLinLow, at), param(kLinHigh, at));
        k.match = match_.on;
        // While a take is learning, the curve waits for its end (no redesign every hop).
        k.matchGen = match_.learning() ? built_.matchGen : match_.learner.generation();
        k.amount = match_.amount, k.smooth = match_.smooth, k.low = match_.low, k.high = match_.high;
        want_ = k;
        outTarget_ = lib::dbToGain(param(kEqOutput, at));
        if (first_) out_ = outTarget_;
        const int solo = offlineRender() ? 0 : std::clamp(choice(kLinSolo, at), 0, static_cast<int>(kEqBands));
        if (solo != solo_) {
            for (auto& s : soloL_) s.clear();
            for (auto& s : soloR_) s.clear();
            solo_ = solo;
        }
        if (solo_ > 0)
            eqListenFilter(soloFilter_, bandType_[solo_ - 1], param(eqBandParam(solo_ - 1, kEqFreq), at),
                           param(eqBandParam(solo_ - 1, kEqQ), at), sr);
    }

    void startJob() noexcept {
        if (haveBuilt_ && !conv_.canStage()) return;  // the last response still fading in
        job_ = want_;
        n_ = linTaps(job_.tier);
        const double sr = rate();
        for (uint32_t b = 0; b < kEqBands; ++b)
            if (job_.use[b]) jobFilter_[b].set(static_cast<lib::EqType>(job_.type[b]), job_.freq[b], job_.gain[b], job_.q[b], sr);
        if (job_.match) match_.makeCurve(sr);
        idx_ = 0;
        phase_ = kMag;
    }

    // One slice of the design (at most about 40 k operations).
    void stepJob(bool all) noexcept {
        const eqd::Tables& t = eqd::tables();
        const double sr = rate();
        switch (phase_) {
            case kMag: {
                const uint32_t half = n_ / 2, stride = eqd::kMaxFft / n_;
                const uint32_t end = std::min(half + 1, idx_ + 64);
                for (; idx_ < end; ++idx_) {
                    const double tn = t.tan[idx_ * stride];
                    double mm = 1.0, ms = 1.0;
                    for (uint32_t b = 0; b < kEqBands; ++b) {
                        if (!job_.use[b]) continue;
                        const double m2 = jobFilter_[b].magnitude2(tn);
                        if (job_.channel[b] != kEqSide) mm *= m2;
                        if (job_.channel[b] != kEqMid) ms *= m2;
                    }
                    double g = 1.0;
                    if (job_.match) g = lib::dbToGain(eqd::curveAt(match_.curve, idx_ * sr / n_));
                    re_[idx_] = std::sqrt(mm) * g;
                    im_[idx_] = std::sqrt(ms) * g;
                    if (idx_ > 0 && idx_ < half) re_[n_ - idx_] = re_[idx_], im_[n_ - idx_] = im_[idx_];
                }
                if (idx_ > half) {
                    fft_.start(re_.data(), im_.data(), n_, true);
                    phase_ = kFft;
                }
                return;
            }
            case kFft:
                if (fft_.step(all ? (1u << 30) : 4096)) phase_ = kStage, idx_ = 0;
                return;
            case kStage: {
                if (!conv_.canStage()) return;
                const uint32_t parts = n_ / kLinBlock, half = n_ / 2;
                const float* w = t.kaiser[job_.tier];
                const double scale = 1.0 / n_;
                // Tap i of the FIR is the zero-phase response at i - n/2 (tap 0 left out, so the taps are symmetric
                // about n/2), windowed.
                for (uint32_t i = 0; i < kLinBlock; ++i) {
                    const uint32_t tap = idx_ * kLinBlock + i, m = (tap + half) & (n_ - 1);
                    const double win = tap == 0 ? 0.0 : w[tap] * scale;
                    stageM_[i] = static_cast<float>(re_[m] * win);
                    stageS_[i] = static_cast<float>(im_[m] * win);
                }
                conv_.stage(idx_, stageM_.data(), stageS_.data(), kLinBlock);
                if (++idx_ < parts) return;
                conv_.commit(parts);
                if (!haveBuilt_) conv_.clear();  // nothing played yet: the response plays at once, no fade in
                built_ = job_;
                for (uint32_t b = 0; b < kEqBands; ++b) filter_[b] = jobFilter_[b];
                haveBuilt_ = true;
                phase_ = kIdle;
                return;
            }
            default:
                return;
        }
    }

    const ModuleDescriptor& d_;
    lib::PartitionedConvolver conv_;
    std::vector<double> re_, im_;
    std::vector<float> stageM_, stageS_;
    eqd::StagedFft fft_;
    LinKey want_, built_, job_;
    lib::EqFilter jobFilter_[kEqBands], filter_[kEqBands];
    int bandType_[kEqBands] = {}, bandChannel_[kEqBands] = {};
    Phase phase_ = kIdle;
    uint32_t idx_ = 0, n_ = 4096;
    bool haveBuilt_ = false, first_ = true, watching_ = false;
    double knobs_[kLinCount] = {};
    double out_ = 1.0, outTarget_ = 1.0, outCoef_ = 0.0;
    int solo_ = 0;
    lib::EqFilter soloFilter_;
    lib::SvfState soloL_[lib::EqFilter::kMaxStages], soloR_[lib::EqFilter::kMaxStages];
    MatchPart match_;
    lib::SpectrumAnalyzer analyzer_;
    double tan_[kSpectrumBins] = {};
};

// ---------- Match ----------

constexpr uint32_t kMDisplay = kMatchDisplay + 4;

class MatchEq final : public EffectBase {
public:
    explicit MatchEq(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    uint32_t stateVersion() const noexcept override { return 1; }
    bool saveState(uint8_t* dst, uint32_t capacity, uint32_t& written) const noexcept override {
        return match_.learner.save(dst, capacity, written);
    }
    bool loadState(const uint8_t* src, uint32_t size, uint32_t version) noexcept override {
        return version == 1 && match_.learner.load(src, size);
    }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        try {
            conv_.prepare(kMatchBlock, kMatchTaps);
            re_.assign(kMatchFft, 0.0);
            im_.assign(kMatchFft, 0.0);
            stage_.assign(kMatchBlock, 0.0f);
            if (!match_.prepare()) return false;
        } catch (...) {
            return false;
        }
        outCoef_ = 1.0 - detExp(-1.0 / (0.005 * sr));
        conv_.silence();
        haveBuilt_ = false;
        builtGen_ = ~0u;
        phase_ = kIdle;
        first_ = true;
        return true;
    }
    void clearState() noexcept override {
        conv_.clear();
        match_.learner.clear();
        first_ = true;
    }
    uint64_t idleFrames() const noexcept override { return kMatchTaps + kMatchBlock + static_cast<uint64_t>(0.05 * rate()); }

    void control(uint32_t at) noexcept override {
        const bool same = knobsUnchanged(knobs_, kMCount, at);
        if (!same || first_) {
            match_.read(std::clamp(choice(kMLearn, at), 0, 3), on(kMOn, at), param(kMAmount, at), param(kMSmooth, at),
                        param(kMLow, at), param(kMHigh, at));
            outTarget_ = lib::dbToGain(param(kMOutput, at));
            if (first_) out_ = outTarget_;
            if (!same) ++wantGen_;  // a knob moved: design again (once the learning, if any, is done)
        }
        if (match_.learning()) match_.learner.step();
        const uint32_t want = wantGen_ * 7919u + (match_.learning() ? builtLearn_ : match_.learner.generation());
        if (phase_ == kIdle && want != builtGen_ && (!haveBuilt_ || conv_.canStage())) startJob(want);
        if (phase_ != kIdle) {
            if (!haveBuilt_) {
                while (phase_ != kIdle) stepJob(true);
            } else {
                stepJob(false);
            }
        }
        first_ = false;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        float yl[kControlFrames], yr[kControlFrames];
        conv_.process(inL, inR, yl, yr, n);
        for (uint32_t i = 0; i < n; ++i) {
            if (out_ != outTarget_) {
                out_ += (outTarget_ - out_) * outCoef_;
                if (std::fabs(out_ - outTarget_) < 1e-12) out_ = outTarget_;
            }
            outL[i] = static_cast<float>(yl[i] * out_);
            outR[i] = static_cast<float>(yr[i] * out_);
        }
        match_.push(keyLeft(), keyRight(), inL, inR, n);
    }

    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        const uint32_t k = match_.display(out, watched, rate());
        out[k] = static_cast<float>(lib::gainToDb(outTarget_));
        out[k + 1] = inPeakDb();
        out[k + 2] = outPeakDb();
        out[k + 3] = static_cast<float>(kMatchBlock * 1000.0 / rate());
        return k + 4;
    }

private:
    enum Phase { kIdle, kLog, kCepstrum, kFold, kSpectrum, kExp, kImpulse, kStage };

    void startJob(uint32_t want) noexcept {
        jobGen_ = want;
        builtLearn_ = match_.learner.generation();
        match_.makeCurve(rate());
        idx_ = 0;
        if (match_.flat()) {  // nothing to match: the response is one tap (the input, 128 frames late)
            std::fill(re_.begin(), re_.end(), 0.0);
            re_[0] = kMatchFft;
            phase_ = kStage;
            return;
        }
        phase_ = kLog;
    }

    void stepJob(bool all) noexcept {
        const uint32_t n = kMatchFft, half = n / 2;
        const uint32_t budget = all ? (1u << 30) : 4096;
        switch (phase_) {
            case kLog: {  // the log magnitude (natural log) on the whole circle
                const double sr = rate();
                const uint32_t end = std::min(half + 1, idx_ + 512);
                for (; idx_ < end; ++idx_) {
                    re_[idx_] = eqd::curveAt(match_.curve, idx_ * sr / n) * 0.11512925464970229;  // ln 10 / 20
                    im_[idx_] = 0.0;
                    if (idx_ > 0 && idx_ < half) re_[n - idx_] = re_[idx_], im_[n - idx_] = 0.0;
                }
                if (idx_ > half) fft_.start(re_.data(), im_.data(), n, true), phase_ = kCepstrum;
                return;
            }
            case kCepstrum:
                if (fft_.step(budget)) phase_ = kFold;
                return;
            case kFold: {  // the real cepstrum onto positive times: c0, 2c(1..n/2-1), c(n/2), zeros
                const double s = 1.0 / n;
                for (uint32_t i = 0; i < n; ++i) {
                    const double w = i == 0 || i == half ? 1.0 : (i < half ? 2.0 : 0.0);
                    re_[i] *= s * w;
                    im_[i] = 0.0;
                }
                fft_.start(re_.data(), im_.data(), n, false);
                phase_ = kSpectrum;
                return;
            }
            case kSpectrum:
                if (fft_.step(budget)) phase_ = kExp, idx_ = 0;
                return;
            case kExp: {  // exp of the analytic log spectrum: the minimum-phase spectrum
                const uint32_t end = std::min(n, idx_ + 256);
                for (; idx_ < end; ++idx_) {
                    const double e = detExp(std::clamp(re_[idx_], -30.0, 30.0)), ph = im_[idx_];
                    re_[idx_] = e * detCos(ph);
                    im_[idx_] = e * detSin(ph);
                }
                if (idx_ >= n) fft_.start(re_.data(), im_.data(), n, true), phase_ = kImpulse;
                return;
            }
            case kImpulse:
                if (fft_.step(budget)) phase_ = kStage, idx_ = 0;
                return;
            case kStage: {
                if (!conv_.canStage()) return;
                const double s = 1.0 / n;
                const uint32_t fadeFrom = kMatchTaps - 256;
                for (uint32_t i = 0; i < kMatchBlock; ++i) {
                    const uint32_t tap = idx_ * kMatchBlock + i;
                    const double fade = tap < fadeFrom ? 1.0 : 0.5 + 0.5 * detCos(kPi * (tap - fadeFrom) / 256.0);
                    stage_[i] = static_cast<float>(re_[tap] * s * fade);
                }
                conv_.stage(idx_, stage_.data(), stage_.data(), kMatchBlock);
                if (++idx_ < kMatchTaps / kMatchBlock) return;
                conv_.commit(kMatchTaps / kMatchBlock);
                if (!haveBuilt_) conv_.clear();
                haveBuilt_ = true;
                builtGen_ = jobGen_;
                phase_ = kIdle;
                return;
            }
            default:
                return;
        }
    }

    const ModuleDescriptor& d_;
    lib::PartitionedConvolver conv_;
    std::vector<double> re_, im_;
    std::vector<float> stage_;
    eqd::StagedFft fft_;
    Phase phase_ = kIdle;
    uint32_t idx_ = 0, wantGen_ = 0, jobGen_ = 0, builtGen_ = ~0u, builtLearn_ = 0;
    bool haveBuilt_ = false, first_ = true;
    double knobs_[kMCount] = {};
    double out_ = 1.0, outTarget_ = 1.0, outCoef_ = 0.0;
    MatchPart match_;
};

// ---------- Presets ----------

using V = std::vector<std::pair<std::string_view, double>>;

// The Bands variant's dynamic presets (variant 0) and the new variants' (4 Linear, 5 Match).
const std::vector<BuiltinPreset>& eqPresets() {
    static const std::vector<BuiltinPreset> p = {
        // Bands, dynamic (Mixing, Vocals, Guitar, Bass, Drums, Mastering)
        {"Dynamic de-harsh vocal", "Vocals: a 3.5 kHz bell dips only when the voice gets edgy",
         V{{"b5_freq", 3500}, {"b5_q", 2.5}, {"b5_dyn", 1}, {"b5_thresh", -30}, {"b5_range", -6}, {"b5_ratio", 4}, {"b5_attack", 2}, {"b5_release", 80}, {"variant", 0}}},
        {"Dynamic de-ess", "Vocals: a 7 kHz bell ducks the esses and leaves the rest bright",
         V{{"b6_freq", 7000}, {"b6_q", 2}, {"b6_dyn", 1}, {"b6_thresh", -32}, {"b6_range", -9}, {"b6_ratio", 6}, {"b6_attack", 0.5}, {"b6_release", 50}, {"variant", 0}}},
        {"Boom control", "Mixing: the low-mids come down only on boomy notes",
         V{{"b3_freq", 220}, {"b3_q", 1.4}, {"b3_dyn", 1}, {"b3_thresh", -24}, {"b3_range", -5}, {"b3_ratio", 3}, {"b3_attack", 10}, {"b3_release", 150}, {"variant", 0}}},
        {"Guitar mud tamer", "Guitar: 300 Hz clears when the chords pile up",
         V{{"b3_freq", 320}, {"b3_q", 1.2}, {"b3_dyn", 1}, {"b3_thresh", -26}, {"b3_range", -6}, {"b3_ratio", 3}, {"b3_attack", 8}, {"b3_release", 120}, {"variant", 0}}},
        {"Bass under the kick", "Bass: route the kick to Key; 80 Hz dips under each hit",
         V{{"b2_type", 0}, {"b2_freq", 80}, {"b2_q", 1}, {"b2_dyn", 1}, {"b2_key", 1}, {"b2_thresh", -30}, {"b2_range", -8}, {"b2_ratio", 8}, {"b2_attack", 1}, {"b2_release", 90}, {"variant", 0}}},
        {"Snare ring control", "Drums: a narrow bell holds the ring down after each hit",
         V{{"b4_freq", 900}, {"b4_q", 6}, {"b4_dyn", 1}, {"b4_thresh", -30}, {"b4_range", -8}, {"b4_ratio", 5}, {"b4_attack", 3}, {"b4_release", 200}, {"variant", 0}}},
        {"Air when quiet", "Mixing: the high shelf lifts the quiet passages, never the loud",
         V{{"b7_gain", 3}, {"b7_dyn", 1}, {"b7_thresh", -30}, {"b7_range", -3}, {"b7_ratio", 2}, {"b7_attack", 20}, {"b7_release", 300}, {"variant", 0}}},
        {"Master low end hold", "Mastering: the low shelf steadies a bass that jumps",
         V{{"b2_dyn", 1}, {"b2_thresh", -18}, {"b2_range", -3}, {"b2_ratio", 2}, {"b2_attack", 30}, {"b2_release", 250}, {"variant", 0}}},
        // Linear (Mastering, Mixing)
        {"Linear master polish", "Mastering: a gentle smile in linear phase, no phase shift",
         V{{"b2_gain", 1.5}, {"b7_gain", 1.5}, {"b4_gain", -1}, {"variant", 4}}},
        {"Linear low cut", "Mastering: a 30 Hz low cut with no phase shift in the bass",
         V{{"b1_on", 1}, {"b1_freq", 30}, {"b1_type", 5}, {"variant", 4}}},
        {"Linear mid/side widen", "Mastering: the side's highs up, the mid untouched",
         V{{"b7_gain", 2.5}, {"b7_channel", 2}, {"b1_on", 1}, {"b1_type", 4}, {"b1_freq", 120}, {"b1_channel", 2}, {"variant", 4}}},
        {"Linear vocal presence", "Vocals: 3 kHz up and 300 Hz down, transparent",
         V{{"b3_freq", 300}, {"b3_gain", -2}, {"b5_freq", 3000}, {"b5_gain", 2.5}, {"variant", 4}}},
        {"Linear bass tighten", "Bass: low-mids out, the fundamental kept in phase",
         V{{"b3_freq", 250}, {"b3_gain", -3}, {"b3_q", 1.5}, {"b1_on", 1}, {"b1_freq", 35}, {"variant", 4}}},
        {"Linear drum bus", "Drums: a lift at 60 Hz and 8 kHz with no smear of the transients' phase",
         V{{"b2_freq", 60}, {"b2_gain", 2}, {"b6_freq", 8000}, {"b6_gain", 2}, {"variant", 4}}},
        {"Linear high quality master", "Mastering: High quality (8,192 taps) for the finest bass",
         V{{"b2_gain", 1}, {"b7_gain", 1}, {"lin_quality", 2}, {"variant", 4}}},
        {"Linear match", "Mastering: learn a reference, then match it in linear phase",
         V{{"match", 1}, {"match_amount", 0.7}, {"match_smooth", 0.4}, {"variant", 4}}},
        // Match (Mastering, Mixing, Vocals)
        {"Match a reference", "Mastering: learn the reference (key) and your mix, then play the difference",
         V{{"match_amount", 1}, {"match_smooth", 0.3}, {"variant", 5}}},
        {"Match half way", "Mastering: half of the difference, a nudge toward the reference",
         V{{"match_amount", 0.5}, {"match_smooth", 0.3}, {"variant", 5}}},
        {"Match tone only", "Mixing: heavy smoothing, the broad tilt and no detail",
         V{{"match_amount", 0.8}, {"match_smooth", 0.9}, {"variant", 5}}},
        {"Match in detail", "Mixing: little smoothing for a close copy of the reference's curve",
         V{{"match_amount", 0.7}, {"match_smooth", 0.05}, {"variant", 5}}},
        {"Match the lows", "Mastering: only below 250 Hz",
         V{{"match_amount", 0.8}, {"match_high", 250}, {"variant", 5}}},
        {"Match the highs", "Mastering: only above 2 kHz",
         V{{"match_amount", 0.8}, {"match_low", 2000}, {"variant", 5}}},
        {"Match the mids", "Mixing: 300 Hz to 4 kHz, the body and presence",
         V{{"match_amount", 0.8}, {"match_low", 300}, {"match_high", 4000}, {"variant", 5}}},
        {"Vocal tone match", "Vocals: another take's or singer's tone, 100 Hz to 12 kHz",
         V{{"match_amount", 0.6}, {"match_smooth", 0.5}, {"match_low", 100}, {"match_high", 12000}, {"variant", 5}}},
    };
    return p;
}

}  // namespace

const ModuleDescriptor& linearEqVariantDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(linBaseDescriptor(), "org.caw.eq", "EQ", labels, index);
    return d;
}
const ModuleDescriptor& matchEqVariantDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(matchBaseDescriptor(), "org.caw.eq", "EQ", labels, index);
    return d;
}
ModuleProcessor* makeLinearEqAs(const ModuleDescriptor& variant) noexcept { return new (std::nothrow) LinearEq(variant); }
ModuleProcessor* makeMatchEqAs(const ModuleDescriptor& variant) noexcept { return new (std::nothrow) MatchEq(variant); }

std::span<const BuiltinPreset> wahPresets();  // builtin_fx_filters_wah.cpp

std::span<const BuiltinPreset> newEqFilterVariantPresets(std::string_view id) {
    if (id == "org.caw.eq") return eqPresets();
    if (id == "org.caw.filter") return wahPresets();
    return {};
}

}  // namespace caw::fx
