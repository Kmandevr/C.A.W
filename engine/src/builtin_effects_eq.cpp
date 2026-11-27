// The built-in parametric EQ (#173, "org.caw.eq"): 8 bands of 14 types, stereo/mid/side per band, a live spectrum.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <span>

#include "caw/library/eq.hpp"
#include "eq_bands.h"
#include "caw/library/spectrum.hpp"
#include "fx_merged.h"
#include "stereo_pair.h"

// Original code (C.A.W. is Apache-2.0). Every band is one to eight trapezoidal state-variable filter stages
// (caw/library/eq.hpp, EqFilter): minimum phase, no latency, and stable however fast a knob moves.

namespace caw::fx {

namespace {

constexpr uint32_t kBands = kEqBands;
enum BandParam : uint32_t { kOn = kEqOn, kType = kEqType, kFreq = kEqFreq, kGain = kEqGain, kQ = kEqQ, kChannel = kEqChannel,
                            kBandParams = kEqBandParams };
constexpr uint32_t bandParam(uint32_t b, uint32_t p) { return b * kBandParams + p; }
constexpr uint32_t kOutput = kEqOutput;
enum Channel : int { kStereo = kEqStereo, kMid = kEqMid, kSide = kEqSide, kLeft = kEqLeft, kRight = kEqRight };

// Per-band dynamics (1.1.0), appended after `output` so every older parameter keeps its index: each band's
// b<n>_dyn, _thresh, _range, _ratio, _attack, _release and _key; then `solo_band`.
enum DynParam : uint32_t { kDynOn, kDynThresh, kDynRange, kDynRatio, kDynAttack, kDynRelease, kDynKey, kDynParams };
constexpr uint32_t kDynBase = kOutput + 1;
constexpr uint32_t dynParam(uint32_t b, uint32_t p) { return kDynBase + b * kDynParams + p; }
constexpr uint32_t kSolo = kDynBase + kBands * kDynParams;
// The detector's key: the band's own region of the EQ's input, the same region of the key (the optional "key"
// input), or another band's region (its type, frequency and Q) of the input.
constexpr std::string_view kDynKeys[] = {"Self", "Key", "Band 1", "Band 2", "Band 3", "Band 4", "Band 5", "Band 6", "Band 7", "Band 8"};
enum DynKey : int { kKeySelf, kKeyInput, kKeyBand1 };

constexpr uint32_t kSpectrumBins = 128;
// The display layout (docs/engine.md, "Display data"): a header, the spectra, the curve, the bands, levels.
constexpr uint32_t kDisplayHeader = 4, kDisplayPre = kDisplayHeader, kDisplayPost = kDisplayPre + kSpectrumBins,
                   kDisplayCurve = kDisplayPost + kSpectrumBins, kDisplayBands = kDisplayCurve + kSpectrumBins,
                   kDisplayOutput = kDisplayBands + kBands * kBandParams, kDisplayDyn = kDisplayOutput + 3,
                   kDisplayLevel = kDisplayDyn + kBands, kDisplaySolo = kDisplayLevel + kBands, kDisplaySize = kDisplaySolo + 1;

}  // namespace

void addEqBandParams(ParamTable& p) {
    struct Default {
        bool on;
        lib::EqType type;
        double hz, q;
    };
    const Default d[kBands] = {{false, lib::EqType::LowCut24, 30.0, 0.71},  {true, lib::EqType::LowShelf, 100.0, 0.71},
                               {true, lib::EqType::Bell, 250.0, 1.0},       {true, lib::EqType::Bell, 800.0, 1.0},
                               {true, lib::EqType::Bell, 2500.0, 1.0},      {true, lib::EqType::Bell, 6000.0, 1.0},
                               {true, lib::EqType::HighShelf, 10000.0, 0.71}, {false, lib::EqType::HighCut24, 18000.0, 0.71}};
    for (uint32_t b = 0; b < kBands; ++b) {
        const std::string id = "b" + std::to_string(b + 1) + "_", name = "Band " + std::to_string(b + 1) + " ";
        p.pick(id + "on", name + "on", d[b].on ? 1.0 : 0.0, kOffOn);
        p.pick(id + "type", name + "type", static_cast<double>(d[b].type), kEqTypes);
        p.expo(id + "freq", name + "frequency", d[b].hz, 20.0, 20000.0, "Hz");
        p.num(id + "gain", name + "gain", 0.0, -24.0, 24.0, "dB");
        p.expo(id + "q", name + "Q", d[b].q, 0.1, 18.0);
        p.pick(id + "channel", name + "channel", 0.0, kEqChannels);
    }
    p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
}

ParameterDescriptor& addEqSolo(ParamTable& p) {
    // Listening only: never automated, modulated or MIDI-mapped, and an export ignores it (offlineRender()).
    ParameterDescriptor& s = p.pick("solo_band", "Band solo", 0.0, kEqSolo);
    s.automatable = s.modulatable = s.midiMappable = false;
    return s;
}

namespace {

const ParamTable& params() {
    static const ParamTable t = [] {
        ParamTable p;
        addEqBandParams(p);
        for (uint32_t b = 0; b < kBands; ++b) {
            const std::string id = "b" + std::to_string(b + 1) + "_", name = "Band " + std::to_string(b + 1) + " ";
            p.pick(id + "dyn", name + "dynamic", 0.0, kOffOn);
            p.num(id + "thresh", name + "threshold", -24.0, -60.0, 0.0, "dB");
            p.num(id + "range", name + "range", -6.0, -24.0, 24.0, "dB");
            p.expo(id + "ratio", name + "ratio", 3.0, 1.0, 20.0);
            p.expo(id + "attack", name + "attack", 5.0, 0.1, 200.0, "ms");
            p.expo(id + "release", name + "release", 120.0, 5.0, 2000.0, "ms");
            p.pick(id + "key", name + "key", 0.0, kDynKeys);
        }
        addEqSolo(p);
        return p;
    }();
    return t;
}

const ModuleDescriptor& eqDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.eq", "EQ", params(), 0, 0);
    return d;
}

class Eq : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return eqDescriptor(); }
    // The dynamic bands' key ("Key"): an optional input, so the EQ stays a plain stereo effect (and may run per
    // note); unconnected it is silence and costs one compare a run.
    std::span<const OptionalPort> optionalPorts() const noexcept override {
        static const OptionalPort ports[] = {{"key", "Key", true}};
        return ports;
    }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        try {
            analyzer_.prepare(sampleRate, kSpectrumBins, 20.0, 20000.0);
        } catch (...) {
            return false;
        }
        for (uint32_t j = 0; j < kSpectrumBins; ++j) {
            double f = analyzer_.binHz(j);
            if (f > 0.49 * sampleRate) f = 0.49 * sampleRate;
            tan_[j] = std::tan(3.14159265358979323846 * f / sampleRate);
        }
        fadeStep_ = 1.0 / (0.005 * sampleRate);  // a band switching on, off or to another type fades over 5 ms
        outCoef_ = 1.0 - detExp(-1.0 / (0.005 * sampleRate));
        first_ = true;
        return true;
    }

    void clearState() noexcept override {
        for (Band& band : bands_) {
            band.clear();
            for (auto& st : band.detector) st.clear();
            band.env = 0.0, band.dynDb = band.appliedDb = 0.0;
        }
        for (auto& st : soloL_) st.clear();
        for (auto& st : soloR_) st.clear();
        analyzer_.clear();
        first_ = true;
    }

    void control(uint32_t at) noexcept override {
        // Every knob as at the last control and no band fading: the bands, their coefficients and the output gain
        // would all be worked out as they are (each band's state is where the last control left it), so nothing
        // to do. Most controls are these: a steady EQ compares its knobs once a block, not eight bands each control.
        // A band waiting to switch type or channel is not steady: its switch happens in a later control.
        // Dynamic bands are work at every control (their gains follow their detectors), but only their own: the
        // knobs are read again only when one moved.
        // The stereo bands' states settle to 0 when tiny here, on the control grid (the same at any block size),
        // instead of at every sample in runStereo (2026-11-27: a third fewer operations per stage; class B, the
        // difference stays below -400 dBFS).
        for (uint32_t a = 0; a < active_; ++a) {
            Band& band = bands_[order_[a]];
            if (band.channel != kStereo) continue;
            for (int k = 0; k < band.filter.stages(); ++k)
                for (lib::SvfState* st : {&band.left[k], &band.right[k]}) {
                    if (st->ic1 < 1e-20 && st->ic1 > -1e-20) st->ic1 = 0.0;
                    if (st->ic2 < 1e-20 && st->ic2 > -1e-20) st->ic2 = 0.0;
                }
        }
        if (solo_ > 0)  // the solo's listening filter runs runStereo too (its states are cleared when it changes)
            for (auto* side : {soloL_, soloR_})
                for (int k = 0; k < soloFilter_.stages(); ++k) {
                    if (side[k].ic1 < 1e-20 && side[k].ic1 > -1e-20) side[k].ic1 = 0.0;
                    if (side[k].ic2 < 1e-20 && side[k].ic2 > -1e-20) side[k].ic2 = 0.0;
                }
        const bool same = knobsUnchanged(knobs_, kParamCount, at);
        if (same && !first_ && !pending_) {
            bool fading = false;
            for (uint32_t a = 0; a < active_; ++a) fading |= bands_[order_[a]].w != bands_[order_[a]].target;
            if (!fading) {
                if (dynCount_) followDynamics();
                return;
            }
        }
        readKnobs(at);
        if (dynCount_) followDynamics();
    }

    void readKnobs(uint32_t at) noexcept {
        const double sr = rate();
        active_ = 0;
        dynCount_ = 0;
        pending_ = false;
        for (uint32_t b = 0; b < kBands; ++b) {
            Band& band = bands_[b];
            const bool wantOn = on(bandParam(b, kOn), at);
            const int type = std::clamp(choice(bandParam(b, kType), at), 0, static_cast<int>(lib::EqType::Count) - 1);
            const int channel = std::clamp(choice(bandParam(b, kChannel), at), 0, 4);
            band.freq = param(bandParam(b, kFreq), at);
            band.gain = param(bandParam(b, kGain), at);
            band.q = param(bandParam(b, kQ), at);
            band.wantOn = wantOn;
            if (first_) {  // the first control after a reset: no fades, start where the knobs are
                band.type = type;
                band.channel = channel;
                band.w = band.target = wantOn ? 1.0 : 0.0;
            }
            // A new type or channel: fade the band out, then switch with a clean state and fade it back in.
            const bool change = type != band.type || channel != band.channel;
            if (change && band.w == 0.0) {
                band.type = type;
                band.channel = channel;
                band.clear();
            }
            band.target = wantOn && !(type != band.type || channel != band.channel) ? 1.0 : 0.0;
            // A dynamic band: a band with a gain whose dynamics are on; its gain is the knob's plus what its
            // detector asks for now (followDynamics). It runs even at 0 dB (its gain may move any moment).
            const bool dyn = on(dynParam(b, kDynOn), at) && eqTypeHasGain(band.type);
            if (dyn != band.dyn) {
                band.dyn = dyn;
                for (auto& st : band.detector) st.clear();
                band.env = 0.0, band.dynDb = band.appliedDb = 0.0;
            }
            if (dyn) readDynamics(b, at, sr);
            band.filter.set(static_cast<lib::EqType>(band.type), band.freq, dyn ? band.gain + band.appliedDb : band.gain, band.q, sr);
            if (type != band.type || channel != band.channel) {
                pending_ = true;
                // An identity band is not run, so it never fades: it passes its input either way, so it is out now.
                if (band.filter.identity() && !dyn) band.w = 0.0;
            }
            if (band.filter.identity() && !dyn && band.w == 0.0 && band.target == 0.0) band.clear();
            if (band.w == 0.0 && band.target == 0.0) continue;  // off: not run
            if (band.filter.identity() && !dyn) {  // no gain: the band passes its input; keep it clean for later
                band.clear();
                continue;
            }
            order_[active_++] = static_cast<uint8_t>(b);
            if (dyn) dynOrder_[dynCount_++] = static_cast<uint8_t>(b);
        }
        // Band solo (listening only; an export never plays it): the output through the band's listening filter.
        const int solo = offlineRender() ? 0 : std::clamp(choice(kSolo, at), 0, static_cast<int>(kBands));
        if (solo != solo_) {
            for (auto& st : soloL_) st.clear();
            for (auto& st : soloR_) st.clear();
            solo_ = solo;
        }
        if (solo_ > 0) {
            const Band& sb = bands_[solo_ - 1];
            eqListenFilter(soloFilter_, std::clamp(choice(bandParam(solo_ - 1, kType), at), 0, static_cast<int>(lib::EqType::Count) - 1),
                           sb.freq, sb.q, sr);
        }
        outTarget_ = lib::dbToGain(param(kOutput, at));
        if (first_) out_ = outTarget_;
        first_ = false;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        // Band by band over the run, each band's channel and fade worked out once per run and each stage run over
        // the whole run (its state stays in registers; no switch or branch per sample). A stereo band runs both
        // sides as one two-wide vector (stereo_pair.h). Every sample goes through each side's scalar operations
        // in the same order as frame by frame (speed phase 4).
        double L[kControlFrames], R[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) L[i] = inL[i], R[i] = inR[i];
        if (dynCount_) detect(inL, inR, n);
        for (uint32_t a = 0; a < active_; ++a) {
            Band& band = bands_[order_[a]];
            const lib::EqFilter& f = band.filter;
            double w[kControlFrames];
            if (band.w != band.target) {
                for (uint32_t i = 0; i < n; ++i) {
                    if (band.w != band.target)
                        band.w = band.target > band.w ? std::min(band.target, band.w + fadeStep_) : std::max(band.target, band.w - fadeStep_);
                    w[i] = band.w;
                }
            } else {
                for (uint32_t i = 0; i < n; ++i) w[i] = band.w;
            }
            double x[kControlFrames], y[kControlFrames];
            switch (band.channel) {
                case kMid:
                case kSide: {
                    const bool mid = band.channel == kMid;
                    for (uint32_t i = 0; i < n; ++i) x[i] = mid ? 0.5 * (L[i] + R[i]) : 0.5 * (L[i] - R[i]);
                    runMono(f, band.left, x, y, n);
                    for (uint32_t i = 0; i < n; ++i) {
                        const double m = 0.5 * (L[i] + R[i]), s = 0.5 * (L[i] - R[i]);
                        const double v = mid ? m : s;
                        const double out = v + (y[i] - v) * w[i];
                        if (mid) L[i] = out + s, R[i] = out - s;
                        else L[i] = m + out, R[i] = m - out;
                    }
                    break;
                }
                case kLeft:
                case kRight: {
                    double* c = band.channel == kLeft ? L : R;
                    runMono(f, band.channel == kLeft ? band.left : band.right, c, y, n);
                    for (uint32_t i = 0; i < n; ++i) c[i] += (y[i] - c[i]) * w[i];
                    break;
                }
                default:
                    runStereo(f, band.left, band.right, L, R, w, n);
                    break;
            }
        }
        if (out_ == outTarget_) {  // the output gain at rest (the glide below would leave it as it is): vectorized
            const double g = out_;
            for (uint32_t i = 0; i < n; ++i) L[i] *= g, R[i] *= g;
        } else {
            for (uint32_t i = 0; i < n; ++i) {
                out_ += (outTarget_ - out_) * outCoef_;
                if (out_ - outTarget_ < 1e-12 && outTarget_ - out_ < 1e-12) out_ = outTarget_;
                L[i] *= out_, R[i] *= out_;
            }
        }
        if (solo_ > 0) {
            double one[kControlFrames];
            for (uint32_t i = 0; i < n; ++i) one[i] = 1.0;
            runStereo(soloFilter_, soloL_, soloR_, L, R, one, n);
        }
        for (uint32_t i = 0; i < n; ++i) {
            outL[i] = static_cast<float>(L[i]);
            outR[i] = static_cast<float>(R[i]);
        }
        // The display's spectrum: only while a UI reads it (the audio doesn't depend on it).
        if (watching_)
            for (uint32_t i = 0; i < n; ++i)
                analyzer_.push(static_cast<float>(0.5 * (static_cast<double>(inL[i]) + inR[i])), static_cast<float>(0.5 * (L[i] + R[i])));
    }

    // y = f.process(state, x) for each sample of the run, stage by stage (each sample through the stages in order).
    static void runMono(const lib::EqFilter& f, lib::SvfState* state, const double* x, double* y, uint32_t n) noexcept {
        for (uint32_t i = 0; i < n; ++i) y[i] = x[i];
        for (int k = 0; k < f.stages(); ++k) {
            const lib::SvfMix& c = f.stage(k);
            lib::SvfState st = state[k];
            for (uint32_t i = 0; i < n; ++i) y[i] = st.process(c, y[i]);
            state[k] = st;
        }
        const double scale = f.scale();
        for (uint32_t i = 0; i < n; ++i) y[i] *= scale;
    }
    // Both sides of a stereo band, l += (f.process(left, l) - l) w and the same on the right, as two-wide vectors:
    // SvfState::process()'s operations lane by lane.
    static void runStereo(const lib::EqFilter& f, lib::SvfState* left, lib::SvfState* right, double* L, double* R,
                          const double* w, uint32_t n) noexcept {
        Pair y[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) y[i] = pairOf(L[i], R[i]);
        const Pair two = splat(2.0);
        for (int k = 0; k < f.stages(); ++k) {
            const lib::SvfMix& c = f.stage(k);
            const Pair a1 = splat(c.a1), a2 = splat(c.a2), a3 = splat(c.a3);
            const Pair m0 = splat(c.m0), m1 = splat(c.m1), m2 = splat(c.m2);
            Pair ic1 = pairOf(left[k].ic1, right[k].ic1), ic2 = pairOf(left[k].ic2, right[k].ic2);
            for (uint32_t i = 0; i < n; ++i) {
                const Pair x = y[i];
                const Pair v3 = x - ic2;
                const Pair v1 = a1 * ic1 + a2 * v3;
                const Pair v2 = ic2 + a2 * ic1 + a3 * v3;
                ic1 = two * v1 - ic1;  // settled at the control points (control())
                ic2 = two * v2 - ic2;
                y[i] = m0 * x + m1 * v1 + m2 * v2;
            }
            left[k].ic1 = lane(ic1, 0), right[k].ic1 = lane(ic1, 1);
            left[k].ic2 = lane(ic2, 0), right[k].ic2 = lane(ic2, 1);
        }
        const Pair scale = splat(f.scale());
        for (uint32_t i = 0; i < n; ++i) {
            const Pair v = y[i] * scale, x = pairOf(L[i], R[i]), g = splat(w[i]);
            const Pair out = x + (v - x) * g;
            L[i] = lane(out, 0), R[i] = lane(out, 1);
        }
    }

    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        out[0] = static_cast<float>(kSpectrumBins);
        out[1] = static_cast<float>(analyzer_.lowHz());
        out[2] = static_cast<float>(analyzer_.highHz());
        out[3] = watched ? 1.0f : 0.0f;
        watching_ = watched;
        if (watched) {
            analyzer_.analyze(out + kDisplayPre, out + kDisplayPost);
            for (uint32_t j = 0; j < kSpectrumBins; ++j) {
                double m = out_ * out_;
                for (const Band& band : bands_)
                    if (band.wantOn && band.target > 0.0) m *= band.filter.magnitude2(tan_[j]);
                out[kDisplayCurve + j] = static_cast<float>(m > 1e-24 ? 10.0 * std::log10(m) : -240.0);
            }
        } else {
            for (uint32_t j = 0; j < 3 * kSpectrumBins; ++j) out[kDisplayPre + j] = -120.0f;
        }
        for (uint32_t b = 0; b < kBands; ++b) {
            const Band& band = bands_[b];
            float* o = out + kDisplayBands + b * kBandParams;
            o[kOn] = band.wantOn ? 1.0f : 0.0f;
            o[kType] = static_cast<float>(band.type);
            o[kFreq] = static_cast<float>(band.freq);
            o[kGain] = static_cast<float>(band.gain);
            o[kQ] = static_cast<float>(band.q);
            o[kChannel] = static_cast<float>(band.channel);
        }
        out[kDisplayOutput] = static_cast<float>(lib::gainToDb(outTarget_));
        out[kDisplayOutput + 1] = inPeakDb();
        out[kDisplayOutput + 2] = outPeakDb();
        for (uint32_t b = 0; b < kBands; ++b) {
            const Band& band = bands_[b];
            out[kDisplayDyn + b] = band.dyn ? static_cast<float>(band.appliedDb) : 0.0f;
            out[kDisplayLevel + b] = band.dyn ? static_cast<float>(band.levelDb) : -120.0f;
        }
        out[kDisplaySolo] = static_cast<float>(solo_);
        return kDisplaySize;
    }

    // A dynamic band's knobs: its threshold, range and ratio, its attack and release as control-step
    // coefficients, and its detector (the listening filter of its own region, or another band's).
    void readDynamics(uint32_t b, uint32_t at, double sr) noexcept {
        Band& band = bands_[b];
        band.thresh = param(dynParam(b, kDynThresh), at);
        band.range = std::clamp(param(dynParam(b, kDynRange), at), -24.0, 24.0);
        band.slope = 1.0 - 1.0 / std::max(1.0, param(dynParam(b, kDynRatio), at));
        const double step = static_cast<double>(kControlFrames) / sr;
        band.attack = 1.0 - detExp(-step / (std::max(0.1, param(dynParam(b, kDynAttack), at)) * 0.001));
        band.release = 1.0 - detExp(-step / (std::max(1.0, param(dynParam(b, kDynRelease), at)) * 0.001));
        const int key = std::clamp(choice(dynParam(b, kDynKey), at), 0, static_cast<int>(kKeyBand1 + kBands) - 1);
        band.keyed = key == kKeyInput;
        uint32_t src = b;
        if (key >= kKeyBand1) src = static_cast<uint32_t>(key - kKeyBand1);
        const int type = std::clamp(choice(bandParam(src, kType), at), 0, static_cast<int>(lib::EqType::Count) - 1);
        const double hz = param(bandParam(src, kFreq), at), q = param(bandParam(src, kQ), at);
        eqListenFilter(band.detectFilter, type, hz, q, sr);
        // The level falls over about six periods of the region's frequency (1..100 ms) between peaks: within
        // 0.4 dB of a steady tone's peak on average.
        const double hold = std::clamp(6.0 / std::max(hz, 10.0), 0.001, 0.1);
        band.decay = detExp(-1.0 / (hold * sr));
    }

    // Each dynamic band's detector over the run: its listening filter on its channel of the input (or the key),
    // then a peak that falls between peaks. About 15 operations a frame.
    void detect(const float* inL, const float* inR, uint32_t n) noexcept {
        const float* kL = optionalInLeft(0);
        const float* kR = optionalInRight(0);
        // Each source (the input or the key) on each channel once a run, whatever number of bands hears it.
        double src[2][4][kControlFrames];
        bool made[2][4] = {};
        for (uint32_t d = 0; d < dynCount_; ++d) {
            Band& band = bands_[dynOrder_[d]];
            const int which = band.keyed ? 1 : 0;
            const int ch = band.channel == kSide ? 1 : band.channel == kLeft ? 2 : band.channel == kRight ? 3 : 0;
            double* x = src[which][ch];
            if (!made[which][ch]) {
                made[which][ch] = true;
                const float* sl = which ? kL : inL;
                const float* sr = which ? kR : inR;
                if (!sl) {
                    for (uint32_t i = 0; i < n; ++i) x[i] = 0.0;
                } else if (ch == 0) {
                    for (uint32_t i = 0; i < n; ++i) x[i] = 0.5 * (static_cast<double>(sl[i]) + sr[i]);
                } else if (ch == 1) {
                    for (uint32_t i = 0; i < n; ++i) x[i] = 0.5 * (static_cast<double>(sl[i]) - sr[i]);
                } else {
                    const float* c = ch == 2 ? sl : sr;
                    for (uint32_t i = 0; i < n; ++i) x[i] = c[i];
                }
            }
            // The listening filter is one stage (a band-pass, or a 12 dB low- or high-pass), unscaled: the SVF and
            // the falling peak in one pass.
            const lib::SvfMix& c = band.detectFilter.stage(0);
            lib::SvfState st = band.detector[0];
            double env = band.env;
            const double decay = band.decay;
            for (uint32_t i = 0; i < n; ++i) {
                const double a = std::fabs(st.process(c, x[i]));
                env *= decay;
                env = a > env ? a : env;
            }
            band.detector[0] = st;
            if (!(env == env)) {  // a NaN reached the detector: start it again clean
                env = 0.0;
                band.detector[0].clear();
            }
            band.env = env < 1e-12 ? 0.0 : env;
        }
    }

    // At each control: every dynamic band's gain moves toward what its level asks (by the attack while it
    // deepens, the release while it recovers), and its coefficients follow when it moved by 0.005 dB or more.
    void followDynamics() noexcept {
        const double sr = rate();
        for (uint32_t d = 0; d < dynCount_; ++d) {
            Band& band = bands_[dynOrder_[d]];
            band.levelDb = lib::gainToDb(band.env);
            const double over = band.levelDb - band.thresh;
            double target = 0.0;
            if (over > 0.0) {
                const double amount = over * band.slope;
                target = band.range < 0.0 ? -std::min(amount, -band.range) : std::min(amount, band.range);
            }
            const double coef = std::fabs(target) > std::fabs(band.dynDb) ? band.attack : band.release;
            band.dynDb += (target - band.dynDb) * coef;
            if (target == 0.0 && std::fabs(band.dynDb) < 1e-3) band.dynDb = 0.0;
            if (std::fabs(band.dynDb - band.appliedDb) >= 0.005 || (band.dynDb == 0.0 && band.appliedDb != 0.0)) {
                band.appliedDb = band.dynDb;
                // Back at rest: the band exactly as set() makes it; moving: only the gain's coefficients.
                if (band.appliedDb == 0.0) band.filter.set(static_cast<lib::EqType>(band.type), band.freq, band.gain, band.q, sr);
                else band.filter.setGainFast(band.gain + band.appliedDb);
            }
        }
    }

private:
    struct Band {
        lib::EqFilter filter;
        lib::SvfState left[lib::EqFilter::kMaxStages], right[lib::EqFilter::kMaxStages];  // left also serves mid/side
        int type = 0, channel = 0;
        double freq = 1000, gain = 0, q = 1;
        double w = 0, target = 0;  // the band's share in its output (fades on a switch)
        bool wantOn = false;
        // Dynamics (when dyn): the detector's filter and state, its level, and the gain it moves.
        bool dyn = false, keyed = false;
        lib::EqFilter detectFilter;
        lib::SvfState detector[lib::EqFilter::kMaxStages];
        double env = 0, decay = 0, levelDb = -120, dynDb = 0, appliedDb = 0;
        double thresh = -24, range = -6, slope = 0.5, attack = 1, release = 1;
        void clear() noexcept {
            for (auto& s : left) s.clear();
            for (auto& s : right) s.clear();
        }
    };
    static constexpr uint32_t kParamCount = kSolo + 1;
    Band bands_[kBands];
    double knobs_[kParamCount] = {};  // control: every knob as it last read them (first_ ignores them)
    uint8_t order_[kBands] = {};
    uint32_t active_ = 0;
    uint8_t dynOrder_[kBands] = {};  // the running bands that are dynamic
    uint32_t dynCount_ = 0;
    int solo_ = 0;                    // band solo: 0 off, else the band (1..8)
    lib::EqFilter soloFilter_;
    lib::SvfState soloL_[lib::EqFilter::kMaxStages], soloR_[lib::EqFilter::kMaxStages];
    double out_ = 1.0, outTarget_ = 1.0, outCoef_ = 0.0, fadeStep_ = 0.0;
    bool first_ = true;
    bool pending_ = false;  // a band waits to switch type or channel (control: not a steady state)
    bool watching_ = false;  // a UI read the display lately: the analyzer hears the audio
    lib::SpectrumAnalyzer analyzer_;
    double tan_[kSpectrumBins] = {};
};

ModuleProcessor* makeEq() noexcept { return new (std::nothrow) Eq(); }

}  // namespace

// The old effect as a variant of a merged device (builtin_fx_merged_eqfilter.cpp, fx_merged.h AsVariant): its own
// (legacy) descriptor, and an instance of the same class under a variant's descriptor.
const ModuleDescriptor& legacyEqDescriptor() { return eqDescriptor(); }
ModuleProcessor* makeEqAs(const ModuleDescriptor& variant) noexcept { return new (std::nothrow) AsVariant<Eq>(variant); }

void registerEq(ModuleRegistry& registry) { registry.add(eqDescriptor(), &makeEq); }

}  // namespace caw::fx
