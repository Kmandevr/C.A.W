// The pitch shifter (fx-creative): "org.caw.pitchshift", semitones and cents by two crossfaded grains read from a delay line, with jitter; its latency is half a grain.
#include <cmath>

#include "builtin_fx_creative.h"
#include "component_chain.h"

// Original code (C.A.W. is Apache-2.0). The technique is the time-domain pitch shifter by delay-line modulation
// (DAFX, 2nd ed., ch. 6 and 7; Zölzer's description of the two-tap "rotating head" shifter): two read taps sweep
// through a delay of one grain at a speed 1 - ratio, half a grain apart, each faded in and out by a sin^2
// window so the two always sum to one. Formants move with the pitch (a formant-preserving shifter needs a
// spectral envelope, PSOLA or a vocoder: not built, see docs/engine.md). The delay the taps sweep averages half
// a grain, so the effect reports that as its latency and delays its dry signal by the same, so the mix doesn't comb.

namespace caw::fx {

namespace {

using creative::clampTo;

enum PitchParam : uint32_t { kSemitones, kCents, kGrain, kJitterP, kMixP, kPitchCount };
constexpr double kMaxGrainMs = 200.0;
constexpr double kRefade = 0.005;  // seconds out and in when the grain size changes

const ParamTable& pitchParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("semitones", "Semitones", 0.0, -24.0, 24.0, "st").step = 1.0;
        p.num("cents", "Cents", 0.0, -100.0, 100.0, "ct");
        // The grain sets the latency, so no lane or modulation may move it while playing (as the ducker's look-ahead).
        ParameterDescriptor& g = p.expo("grain", "Grain", 60.0, 10.0, kMaxGrainMs, "ms");
        g.automatable = false;
        g.modulatable = false;
        g.smoothingFrames = 0;
        p.num("jitter", "Jitter", 0.0, 0.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}

const ModuleDescriptor& pitchDescriptor() {
    // Latency 0 here: half the grain is reported per instance (VariableLatency).
    static const ModuleDescriptor d = withCpu(effectDescriptor("org.caw.pitchshift", "Pitch shifter", pitchParams(), 0, 0), CpuClass::Heavy);
    return d;
}

// Frames of grain for a knob value, and the latency it gives: half of it, plus the one frame the cubic read keeps.
double grainFrames(double ms, double sr) noexcept { return std::floor(clampTo(ms, 10.0, kMaxGrainMs) * 0.001 * sr); }
uint32_t latencyOf(double grain) noexcept { return static_cast<uint32_t>(std::floor(grain * 0.5)) + 1; }

class PitchShift final : public EffectBase, public VariableLatency {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return pitchDescriptor(); }
    uint32_t latencyFor(const double* values, uint32_t count) const noexcept override {
        return latencyOf(grainFrames(count > kGrain ? values[kGrain] : 60.0, rate()));
    }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        noise_.seed(0x9171);
        return ring_.allocate(static_cast<size_t>(std::ceil(kMaxGrainMs * 0.001 * sr)) + 8);
    }
    void clearState() noexcept override {
        ring_.clear();
        phase_ = 0.5;
        grain_ = 0.0;  // the next control takes the knob's at once
        fade_ = 1.0, fadeDir_ = 0.0;
        jitterNow_ = jitterTo_ = 0.0;
        half_ = false;
        noise_.seed(0x9171);
        mix_.reset();
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>(grain_ + 0.05 * rate()); }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const double want = grainFrames(param(kGrain, at), sr);
        if (grain_ <= 0.0) grain_ = want;
        else if (want != grain_ && fadeDir_ >= 0.0) fadeDir_ = -1.0;  // fade out, switch, fade in
        semis_ = clampTo(std::floor(param(kSemitones, at) + 0.5), -24.0, 24.0) + clampTo(param(kCents, at), -100.0, 100.0) * 0.01;
        jitter_ = clampTo(param(kJitterP, at), 0.0, 1.0);
        want_ = want;
        linear_ = quality() == kQualityEco;
        mix_.set(clampTo(param(kMixP, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const double fadeStep = 1.0 / (kRefade * rate());
        for (uint32_t i = 0; i < n; ++i) {
            ring_.write(inL[i], inR[i]);
            // The jitter: up to +-35 cents, a new random target at each half grain, glided to.
            jitterNow_ += (jitterTo_ - jitterNow_) * 0.001;
            const double semis = semis_ + jitterNow_;
            const double ratio = lib::fastExp(semis * 0.057762265046662105);  // 2^(semis / 12)
            const double g = grain_;
            if (semis_ == 0.0 && jitter_ == 0.0) {
                // No shift: settle on the one tap half a grain back (a fixed delay, no comb of two taps).
                phase_ += clampTo(0.5 - phase_, -0.25 / g, 0.25 / g);
            } else {
                phase_ += (1.0 - ratio) / g;
            }
            phase_ -= std::floor(phase_);
            const bool half = phase_ >= 0.5;
            if (half != half_) {
                half_ = half;
                jitterTo_ = jitter_ * 35.0 * noise_.bipolar();
            }
            const double p2 = phase_ + 0.5 >= 1.0 ? phase_ - 0.5 : phase_ + 0.5;
            const double w1 = 0.5 - 0.5 * lib::fastSinCycles(phase_ + 0.25);  // sin^2(pi phase)
            const double w2 = 1.0 - w1;
            const double d1 = 1.0 + phase_ * g, d2 = 1.0 + p2 * g;
            double wl, wr;
            if (linear_) {
                wl = w1 * ring_.readLinear(0, d1) + w2 * ring_.readLinear(0, d2);
                wr = w1 * ring_.readLinear(1, d1) + w2 * ring_.readLinear(1, d2);
            } else {
                wl = w1 * ring_.read(0, d1) + w2 * ring_.read(0, d2);
                wr = w1 * ring_.read(1, d1) + w2 * ring_.read(1, d2);
            }
            // A new grain size: out, switch, in (5 ms each way).
            if (fadeDir_ != 0.0) {
                fade_ += fadeDir_ * fadeStep;
                if (fade_ <= 0.0) fade_ = 0.0, fadeDir_ = 1.0, grain_ = want_, phase_ = 0.5;
                if (fade_ >= 1.0) fade_ = 1.0, fadeDir_ = 0.0;
            }
            const double latency = static_cast<double>(latencyOf(grain_));
            const double dl = ring_.readLinear(0, latency), dr = ring_.readLinear(1, latency);  // the dry, in time
            const double m = mix_.next();
            outL[i] = static_cast<float>(dl + (wl * fade_ - dl) * m);
            outR[i] = static_cast<float>(dr + (wr * fade_ - dr) * m);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(semis_ + jitterNow_);
        out[3] = static_cast<float>(grain_ / rate() * 1000.0);
        out[4] = static_cast<float>(latencyOf(grain_) / rate() * 1000.0);
        out[5] = static_cast<float>(phase_);
        return 6;
    }

private:
    creative::Ring ring_;
    creative::Noise noise_;
    Ramp mix_;
    double phase_ = 0.5, grain_ = 0.0, want_ = 2880.0, fade_ = 1.0, fadeDir_ = 0.0;
    double semis_ = 0.0, jitter_ = 0.0, jitterNow_ = 0.0, jitterTo_ = 0.0;
    bool half_ = false, linear_ = false;
};

}  // namespace

void registerPitchShift(ModuleRegistry& registry) { registry.add(pitchDescriptor(), &creative::make<PitchShift>); }

}  // namespace caw::fx
