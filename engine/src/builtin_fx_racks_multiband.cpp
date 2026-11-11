// The multiband rack (fx-racks, "org.caw.rack.multiband"): up to 5 Linkwitz-Riley bands, each a chain of up to 4 built-in effects.
#include <algorithm>
#include <cmath>

#include "builtin_fx_racks_internal.h"
#include "caw/library/filter.hpp"
#include "caw/library/spectrum.hpp"

namespace caw {
namespace fx {

namespace {

constexpr uint32_t kBands = 5, kSlotsPerBand = 4, kCrossovers = kBands - 1, kBins = 64;
constexpr double kButterworthQ = 0.70710678118654752;
constexpr double kK = 1.41421356237309505;  // the SVF's damping at that Q (1 / Q)

struct MbIndices {
    uint32_t bands, xover[kCrossovers];
    struct Band { uint32_t bypass, mute, solo, gain, pan; } band[kBands];
    uint32_t mix, output;
};

struct MbLayout {
    RackLayout layout;
    MbIndices k{};
    MbLayout() {
        ParamTable& p = layout.own;
        for (uint32_t b = 0; b < kBands; ++b)
            for (uint32_t s = 0; s < kSlotsPerBand; ++s)
                layout.addSlot("b" + std::to_string(b + 1) + "s" + std::to_string(s + 1),
                               "B" + std::to_string(b + 1) + "." + std::to_string(s + 1), static_cast<int>(b));
        ParameterDescriptor& bands = p.num("bands", "Bands", 3.0, 1.0, static_cast<double>(kBands));
        bands.step = 1.0;
        bands.smoothingFrames = 0;
        const double defaults[kCrossovers] = {200.0, 2500.0, 6000.0, 12000.0};
        for (uint32_t c = 0; c < kCrossovers; ++c)
            p.expo("xover" + std::to_string(c + 1), "Crossover " + std::to_string(c + 1), defaults[c], 20.0, 20000.0, "Hz");
        for (uint32_t b = 0; b < kBands; ++b) {
            const std::string i = "band" + std::to_string(b + 1) + "_", n = "Band " + std::to_string(b + 1) + " ";
            p.pick(i + "bypass", n + "bypass", 0.0, kOffOn);
            p.pick(i + "mute", n + "mute", 0.0, kOffOn);
            p.pick(i + "solo", n + "solo", 0.0, kOffOn);
            p.num(i + "gain", n + "gain", 0.0, -24.0, 24.0, "dB");
            p.num(i + "pan", n + "pan", 0.0, -1.0, 1.0);
        }
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        auto at = [&](const std::string& id) { return static_cast<uint32_t>(p.index(id)); };
        k.bands = at("bands");
        for (uint32_t c = 0; c < kCrossovers; ++c) k.xover[c] = at("xover" + std::to_string(c + 1));
        for (uint32_t b = 0; b < kBands; ++b) {
            const std::string i = "band" + std::to_string(b + 1) + "_";
            k.band[b] = {at(i + "bypass"), at(i + "mute"), at(i + "solo"), at(i + "gain"), at(i + "pan")};
        }
        k.mix = at("mix"), k.output = at("output");
        layout.finish(kMultibandRackId, "Multiband rack", false, false);
    }
};

const MbLayout& mbLayout() {
    static const MbLayout l;
    return l;
}

// One Linkwitz-Riley 24 dB/octave crossover for one channel: a Butterworth SVF gives both halves' first section at
// once, a second SVF on each finishes them. Low plus high is a second-order all-pass at the same frequency.
struct Crossover {
    lib::Svf first, low, high;
    void set(double hz, double sr) noexcept {
        first.set(hz, kButterworthQ, sr);
        low.setLike(first);
        high.setLike(first);
    }
    void split(double x, double& lo, double& hi) noexcept {
        const lib::SvfOutput o = first.process(x);
        lo = low.lowpass(o.low);
        hi = high.highpass(o.high);
    }
    void clear() noexcept { first.clear(), low.clear(), high.clear(); }
    void flush() noexcept { first.flushDenormals(), low.flushDenormals(), high.flushDenormals(); }
};

class MultibandRack final : public RackBase {
public:
    const RackLayout& layout() const noexcept override { return mbLayout().layout; }

protected:
    bool prepare(double sampleRate) override {
        uint32_t cap = 0;
        for (uint32_t b = 0; b < kBands; ++b) {
            uint32_t band = 0;
            for (uint32_t s = 0; s < kSlotsPerBand; ++s) band += slots_[b * kSlotsPerBand + s].latencyCap;
            cap = std::max(cap, band);
        }
        latencyCap_ = cap;
        for (RackDelay& d : comp_) d.prepare(cap);
        dry_.prepare(cap);
        raw_.prepare(cap);
        analyzer_.prepare(sampleRate, kBins, 20.0, 20000.0);
        return true;
    }

    void clearState() noexcept override {
        for (auto& ch : xo_)
            for (Crossover& c : ch) c.clear();
        for (auto& band : ap_)
            for (auto& ch : band)
                for (lib::Svf& f : ch) f.clear();
        for (RackDelay& d : comp_) d.clear();
        dry_.clear();
        raw_.clear();
        for (Ramp& r : gl_) r.reset();
        for (Ramp& r : gr_) r.reset();
        mix_.reset();
        gain_.reset();
        for (double& m : bandMix_) m = -1.0;
        bands_ = 0;  // the first control takes the knob as it stands
        fade_ = 1.0;
        fadeTarget_ = 1.0;
        for (float& p : bandPeak_) p = 0.0f;
        analyzer_.clear();
    }

    void control(uint32_t at) noexcept override {
        const MbIndices& k = mbLayout().k;
        const double sr = rate();
        const uint32_t want = static_cast<uint32_t>(std::clamp(choiceAt(k.bands, at), 1, static_cast<int>(kBands)));
        if (bands_ == 0) bands_ = want;
        if (want != bands_) pending_ = want, fadeTarget_ = 0.0;  // fade to the dry input, switch, fade back
        double prev = 0.0;
        for (uint32_t c = 0; c < kCrossovers; ++c) {  // ascending: each at least a twentieth of an octave over the last
            const double top = 0.45 * sr;
            double hz = std::clamp(paramAt(k.xover[c], at), 20.0, top);
            if (c > 0) hz = std::min(top, std::max(hz, prev * 1.035));
            xHz_[c] = hz;
            prev = hz;
            if (c + 1 < bands_) {
                for (auto& ch : xo_) ch[c].set(hz, sr);
                for (uint32_t b = 0; b < c; ++b)
                    for (auto& ch : ap_[b]) ch[c].set(hz, kButterworthQ, sr);
            }
        }
        bool solo = false;
        for (uint32_t b = 0; b < bands_; ++b) solo = solo || on(k.band[b].solo, at);
        uint32_t latency = 0;
        for (uint32_t b = 0; b < kBands; ++b) {
            bandOn_[b] = !on(k.band[b].bypass, at);
            uint32_t l = 0;
            if (bandOn_[b] && b < bands_) {
                for (uint32_t s = 0; s < kSlotsPerBand; ++s) {
                    const uint32_t slot = b * kSlotsPerBand + s;
                    const Slot& sl = slots_[slot];
                    if (!sl.processor || !on(static_cast<uint32_t>(layout().slots[slot].on), at)) continue;
                    if (sl.variable) {
                        for (uint32_t q = 0; q < sl.count; ++q) latencyValues_[sl.first + q] = paramAt(sl.first + q, at);
                        l += childLatency(sl, latencyValues_.data(), static_cast<uint32_t>(latencyValues_.size()));
                    } else {
                        l += childLatency(sl, nullptr, 0);
                    }
                }
            }
            bandLatency_[b] = l;
            latency = std::max(latency, l);
            const bool heard = !on(k.band[b].mute, at) && (!solo || on(k.band[b].solo, at));
            const double g = heard ? lib::dbToGain(paramAt(k.band[b].gain, at)) : 0.0;
            const double pan = std::clamp(paramAt(k.band[b].pan, at), -1.0, 1.0);
            gl_[b].set(g * (pan > 0.0 ? 1.0 - pan : 1.0), kRackControlFrames);
            gr_[b].set(g * (pan < 0.0 ? 1.0 + pan : 1.0), kRackControlFrames);
        }
        latency_ = std::min(latency, latencyCap_);
        mix_.set(std::clamp(paramAt(k.mix, at), 0.0, 1.0), kRackControlFrames);
        gain_.set(lib::dbToGain(paramAt(k.output, at)), kRackControlFrames);
        for (auto& ch : xo_)
            for (Crossover& c : ch) c.flush();
        for (auto& band : ap_)
            for (auto& ch : band)
                for (lib::Svf& f : ch) f.flushDenormals();
    }

    void chunk(const float* inL, const float* inR, float* outL, float* outR, uint32_t n, uint32_t at) noexcept override {
        const uint32_t B = bands_;
        const float* in[2] = {inL, inR};
        float x[2][kRackControlFrames];
        // The split: band 0 takes the lowest crossover's low half, then all-passes at every crossover above it, so each
        // band has the same phase and the bands sum to the input through those all-passes (flat).
        for (uint32_t ch = 0; ch < 2; ++ch) {
            for (uint32_t i = 0; i < n; ++i) {
                x[ch][i] = in[ch][i];
                double rest = static_cast<double>(in[ch][i]);
                for (uint32_t c = 0; c + 1 < B; ++c) {
                    double lo, hi;
                    xo_[ch][c].split(rest, lo, hi);
                    for (uint32_t j = c + 1; j + 1 < B; ++j) {
                        const lib::SvfOutput o = ap_[c][ch][j].process(lo);
                        lo = o.notch - kK * o.band;  // x - 2k band: the all-pass
                    }
                    band_[c][ch][i] = static_cast<float>(lo);
                    rest = hi;
                }
                band_[B - 1][ch][i] = static_cast<float>(rest);
            }
        }
        float dry[2][kRackControlFrames] = {};
        for (uint32_t b = 0; b < B; ++b)
            for (uint32_t ch = 0; ch < 2; ++ch)
                for (uint32_t i = 0; i < n; ++i) dry[ch][i] += band_[b][ch][i];
        // Each band's chain, crossfaded in and out by its bypass.
        sliceChildValues(at);
        float wet[2][kRackControlFrames] = {};
        const double bandStep = 1.0 / (0.005 * rate());
        for (uint32_t b = 0; b < B; ++b) {
            const double target = bandOn_[b] ? 1.0 : 0.0;
            if (bandMix_[b] < 0.0) bandMix_[b] = target;
            float* cur[2] = {band_[b][0], band_[b][1]};
            if (bandMix_[b] > 0.0 || target > 0.0) {
                if (bandMix_[b] == 0.0)
                    for (uint32_t s = 0; s < kSlotsPerBand; ++s)
                        if (slots_[b * kSlotsPerBand + s].processor) slots_[b * kSlotsPerBand + s].processor->reset();
                float* other[2] = {scratchA_[0], scratchA_[1]};
                float* spare[2] = {scratchB_[0], scratchB_[1]};
                // The first child reads the band and writes scratch A; after that A and B take turns.
                for (uint32_t s = 0; s < kSlotsPerBand; ++s) {
                    Slot& slot = slots_[b * kSlotsPerBand + s];
                    if (!slot.processor) continue;
                    runChild(slot, cur[0], cur[1], other[0], other[1], n, at);
                    cur[0] = other[0], cur[1] = other[1];
                    std::swap(other[0], spare[0]);
                    std::swap(other[1], spare[1]);
                }
                if (bandMix_[b] != 1.0 || target != 1.0) {
                    for (uint32_t i = 0; i < n; ++i) {
                        bandMix_[b] = target > bandMix_[b] ? std::min(target, bandMix_[b] + bandStep)
                                                           : std::max(target, bandMix_[b] - bandStep);
                        const float w = static_cast<float>(bandMix_[b]);
                        processed_[0][i] = band_[b][0][i] + (cur[0][i] - band_[b][0][i]) * w;
                        processed_[1][i] = band_[b][1][i] + (cur[1][i] - band_[b][1][i]) * w;
                    }
                    cur[0] = processed_[0], cur[1] = processed_[1];
                }
            }
            const uint32_t delay = latency_ - std::min(latency_, bandLatency_[b]);
            float peak = bandPeak_[b];
            for (uint32_t i = 0; i < n; ++i) {
                float l = cur[0][i], r = cur[1][i];
                comp_[b].tick(l, r, delay);
                l = static_cast<float>(l * gl_[b].next());
                r = static_cast<float>(r * gr_[b].next());
                peak = std::max(peak, std::max(std::fabs(l), std::fabs(r)));
                wet[0][i] += l;
                wet[1][i] += r;
            }
            bandPeak_[b] = peak;
        }
        for (uint32_t b = B; b < kBands; ++b)
            for (uint32_t i = 0; i < n; ++i) gl_[b].next(), gr_[b].next();
        const double fadeStep = 1.0 / (0.005 * rate());
        for (uint32_t i = 0; i < n; ++i) {
            float dl = dry[0][i], dr = dry[1][i];
            dry_.tick(dl, dr, latency_);
            float rl = x[0][i], rr = x[1][i];
            raw_.tick(rl, rr, latency_);
            const double m = mix_.next(), g = gain_.next();
            const double ol = (dl + (wet[0][i] - dl) * m) * g, orr = (dr + (wet[1][i] - dr) * m) * g;
            fade_ = fadeTarget_ > fade_ ? std::min(fadeTarget_, fade_ + fadeStep) : std::max(fadeTarget_, fade_ - fadeStep);
            outL[i] = static_cast<float>(rl * g + (ol - rl * g) * fade_);
            outR[i] = static_cast<float>(rr * g + (orr - rr * g) * fade_);
            if (watched_) analyzer_.push(0.5f * (x[0][i] + x[1][i]), 0.5f * (outL[i] + outR[i]));
        }
        if (fade_ == 0.0 && fadeTarget_ == 0.0) {  // faded out: the new band count starts from clean filters
            bands_ = pending_;
            for (auto& ch : xo_)
                for (Crossover& c : ch) c.clear();
            for (auto& band : ap_)
                for (auto& ch : band)
                    for (lib::Svf& f : ch) f.clear();
            fadeTarget_ = 1.0;
        }
    }

    // 0 input peak, 1 output peak, 2 bands, 3..6 crossovers Hz (as heard: held ascending), 7..11 each band's peak dB
    // after its gain, 12 bins (64), 13 analyzed (1: the spectra are fresh), 14..77 input spectrum dB, 78..141 output
    // spectrum dB (20 Hz..20 kHz, log-spaced bins, as the EQ's).
    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        watched_ = watched;
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(bands_ == 0 ? 3 : bands_);
        for (uint32_t c = 0; c < kCrossovers; ++c) out[3 + c] = static_cast<float>(xHz_[c]);
        for (uint32_t b = 0; b < kBands; ++b) {
            out[7 + b] = static_cast<float>(lib::gainToDb(bandPeak_[b]));
            bandPeak_[b] = 0.0f;
        }
        out[12] = static_cast<float>(kBins);
        out[13] = watched ? 1.0f : 0.0f;
        if (watched) {
            analyzer_.analyze(out + 14, out + 14 + kBins);
        } else {
            for (uint32_t j = 0; j < 2 * kBins; ++j) out[14 + j] = -120.0f;
        }
        return 14 + 2 * kBins;
    }

    uint32_t latencyOf(const double* values, uint32_t count) const noexcept override {
        const MbIndices& k = mbLayout().k;
        if (k.bands >= count) return 0;
        const uint32_t B = static_cast<uint32_t>(std::clamp(static_cast<int>(values[k.bands] + 0.5), 1, static_cast<int>(kBands)));
        uint32_t latency = 0;
        for (uint32_t b = 0; b < B; ++b) {
            if (values[k.band[b].bypass] >= 0.5) continue;
            uint32_t l = 0;
            for (uint32_t s = 0; s < kSlotsPerBand; ++s) {
                const uint32_t slot = b * kSlotsPerBand + s;
                const int onIndex = layout().slots[slot].on;
                if (!slots_[slot].processor || values[onIndex] < 0.5) continue;
                l += childLatency(slots_[slot], values, count);
            }
            latency = std::max(latency, l);
        }
        return std::min(latency, latencyCap_);
    }

private:
    Crossover xo_[2][kCrossovers];
    lib::Svf ap_[kCrossovers][2][kCrossovers];  // [band][channel][crossover]: the all-passes a low band takes
    float band_[kBands][2][kRackControlFrames] = {};
    float scratchA_[2][kRackControlFrames] = {}, scratchB_[2][kRackControlFrames] = {};
    float processed_[2][kRackControlFrames] = {};
    double xHz_[kCrossovers] = {};
    bool bandOn_[kBands] = {};
    double bandMix_[kBands] = {-1.0, -1.0, -1.0, -1.0, -1.0};
    uint32_t bandLatency_[kBands] = {};
    float bandPeak_[kBands] = {};
    Ramp gl_[kBands], gr_[kBands], mix_, gain_;
    RackDelay comp_[kBands], dry_, raw_;
    uint32_t latency_ = 0, latencyCap_ = 0, bands_ = 0, pending_ = 0;
    double fade_ = 1.0, fadeTarget_ = 1.0;
    bool watched_ = false;
    lib::SpectrumAnalyzer analyzer_;
};

ModuleProcessor* makeMultibandRack() noexcept { return new (std::nothrow) MultibandRack(); }

}  // namespace

void registerMultibandRack(ModuleRegistry& registry) {
    registry.add(mbLayout().layout.staticBuild.desc, &makeMultibandRack);
}

}  // namespace fx
}  // namespace caw
