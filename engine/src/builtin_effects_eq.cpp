// The built-in parametric EQ (#173, "org.caw.eq"): 8 bands of 14 types, stereo/mid/side per band, a live spectrum.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>

#include "caw/library/eq.hpp"
#include "caw/library/spectrum.hpp"
#include "stereo_pair.h"

// Original code (C.A.W. is Apache-2.0). Every band is one to eight trapezoidal state-variable filter stages
// (caw/library/eq.hpp, EqFilter): minimum phase, no latency, and stable however fast a knob moves.

namespace caw::fx {

namespace {

constexpr uint32_t kBands = 8;
enum BandParam : uint32_t { kOn, kType, kFreq, kGain, kQ, kChannel, kBandParams };
constexpr uint32_t bandParam(uint32_t b, uint32_t p) { return b * kBandParams + p; }
constexpr uint32_t kOutput = kBands * kBandParams;

constexpr std::string_view kTypes[] = {"Bell", "Low shelf", "High shelf", "Low cut 12", "Low cut 24", "Low cut 48",
                                       "High cut 12", "High cut 24", "High cut 48", "Notch", "Band-pass", "Tilt",
                                       "Low cut 96", "High cut 96"};  // the 96s appended (fx-filters): old numbers kept
static_assert(sizeof(kTypes) / sizeof(kTypes[0]) == static_cast<size_t>(lib::EqType::Count));
constexpr std::string_view kChannels[] = {"Stereo", "Mid", "Side", "Left", "Right"};
enum Channel : int { kStereo, kMid, kSide, kLeft, kRight };

constexpr uint32_t kSpectrumBins = 128;
// The display layout (docs/engine.md, "Display data"): a header, the spectra, the curve, the bands, levels.
constexpr uint32_t kDisplayHeader = 4, kDisplayPre = kDisplayHeader, kDisplayPost = kDisplayPre + kSpectrumBins,
                   kDisplayCurve = kDisplayPost + kSpectrumBins, kDisplayBands = kDisplayCurve + kSpectrumBins,
                   kDisplayOutput = kDisplayBands + kBands * kBandParams, kDisplaySize = kDisplayOutput + 3;

const ParamTable& params() {
    static const ParamTable t = [] {
        ParamTable p;
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
            p.pick(id + "type", name + "type", static_cast<double>(d[b].type), kTypes);
            p.expo(id + "freq", name + "frequency", d[b].hz, 20.0, 20000.0, "Hz");
            p.num(id + "gain", name + "gain", 0.0, -24.0, 24.0, "dB");
            p.expo(id + "q", name + "Q", d[b].q, 0.1, 18.0);
            p.pick(id + "channel", name + "channel", 0.0, kChannels);
        }
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}

const ModuleDescriptor& eqDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.eq", "EQ", params(), 0, 0);
    return d;
}

class Eq final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return eqDescriptor(); }

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
        for (Band& band : bands_) band.clear();
        analyzer_.clear();
        first_ = true;
    }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        active_ = 0;
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
            band.filter.set(static_cast<lib::EqType>(band.type), band.freq, band.gain, band.q, sr);
            if (band.filter.identity() && band.w == 0.0 && band.target == 0.0) band.clear();
            if (band.w == 0.0 && band.target == 0.0) continue;  // off: not run
            if (band.filter.identity()) {  // no gain: the band passes its input; keep it clean for later
                band.clear();
                continue;
            }
            order_[active_++] = static_cast<uint8_t>(b);
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
        for (uint32_t i = 0; i < n; ++i) {
            out_ += (outTarget_ - out_) * outCoef_;
            if (out_ - outTarget_ < 1e-12 && outTarget_ - out_ < 1e-12) out_ = outTarget_;
            const double l = L[i] * out_, r = R[i] * out_;
            outL[i] = static_cast<float>(l);
            outR[i] = static_cast<float>(r);
            // The display's spectrum: only while a UI reads it (the audio doesn't depend on it).
            if (watching_) analyzer_.push(static_cast<float>(0.5 * (static_cast<double>(inL[i]) + inR[i])), static_cast<float>(0.5 * (l + r)));
        }
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
                ic1 = flushPair(two * v1 - ic1);
                ic2 = flushPair(two * v2 - ic2);
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
        return kDisplaySize;
    }

private:
    struct Band {
        lib::EqFilter filter;
        lib::SvfState left[lib::EqFilter::kMaxStages], right[lib::EqFilter::kMaxStages];  // left also serves mid/side
        int type = 0, channel = 0;
        double freq = 1000, gain = 0, q = 1;
        double w = 0, target = 0;  // the band's share in its output (fades on a switch)
        bool wantOn = false;
        void clear() noexcept {
            for (auto& s : left) s.clear();
            for (auto& s : right) s.clear();
        }
    };
    Band bands_[kBands];
    uint8_t order_[kBands] = {};
    uint32_t active_ = 0;
    double out_ = 1.0, outTarget_ = 1.0, outCoef_ = 0.0, fadeStep_ = 0.0;
    bool first_ = true;
    bool watching_ = false;  // a UI read the display lately: the analyzer hears the audio
    lib::SpectrumAnalyzer analyzer_;
    double tan_[kSpectrumBins] = {};
};

ModuleProcessor* makeEq() noexcept { return new (std::nothrow) Eq(); }

}  // namespace

void registerEq(ModuleRegistry& registry) { registry.add(eqDescriptor(), &makeEq); }

}  // namespace caw::fx
