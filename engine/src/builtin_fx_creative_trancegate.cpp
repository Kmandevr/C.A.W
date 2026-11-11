// The trance gate (fx-creative): "org.caw.trancegate", a drawn pattern of 8, 16 or 32 steps opening the sound with an envelope on each step, with swing.
#include <cmath>
#include <string>

#include "builtin_fx_creative.h"
#include "caw/library/dynamics.hpp"

// Original code (C.A.W. is Apache-2.0). A step sequencer drives an ADSR amplitude envelope (attack, decay to a
// sustain, release when the step's gate ends), retriggered on each step that is on, its peak the step's level;
// swing delays every second step (the off-beat) by part of a step.

namespace caw::fx {

namespace {

using creative::clampTo;

constexpr uint32_t kMaxSteps = 32;
enum GateParam : uint32_t {
    kSteps, kRate, kAttack, kDecay, kSustain, kRelease, kLength, kSwing, kLegato, kMixG, kFirstStep,
    kGateCount = kFirstStep + kMaxSteps
};
constexpr std::string_view kStepCounts[] = {"8", "16", "32"};
constexpr double kStepCountValues[] = {8, 16, 32};
constexpr std::string_view kStepRates[] = {"1/32", "1/16 T", "1/16", "1/8 T", "1/8", "1/4"};
constexpr double kStepRateWholes[] = {0.03125, 0.0625 * 2 / 3, 0.0625, 0.125 * 2 / 3, 0.125, 0.25};
// The default pattern (16 steps, repeated to 32): a classic off-beat gate.
constexpr double kDefaultPattern[16] = {1, 0, 1, 1, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1, 0.6, 1};

const ParamTable& gateParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("steps", "Steps", 1.0, kStepCounts);
        p.pick("rate", "Rate", 2.0, kStepRates);
        p.expo("attack", "Attack", 1.0, 0.1, 200.0, "ms");
        p.expo("decay", "Decay", 200.0, 1.0, 2000.0, "ms");
        p.num("sustain", "Sustain", 1.0, 0.0, 1.0);
        p.expo("release", "Release", 30.0, 1.0, 1000.0, "ms");
        p.num("length", "Gate length", 0.5, 0.05, 1.0);
        p.num("swing", "Swing", 0.0, 0.0, 1.0);
        p.pick("legato", "Tie steps", 0.0, kOffOn);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        for (uint32_t k = 0; k < kMaxSteps; ++k)
            p.num("s" + std::to_string(k + 1), "Step " + std::to_string(k + 1), kDefaultPattern[k % 16], 0.0, 1.0)
                .smoothingFrames = 0;
        return p;
    }();
    return t;
}

const ModuleDescriptor& gateDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.trancegate", "Trance gate", gateParams(), 0, 0);
    return d;
}

class TranceGate final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return gateDescriptor(); }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void clearState() noexcept override {
        clock_.reset();
        env_ = 0.0, peak_ = 0.0;
        stage_ = sIdle;
        step_ = -1;
        mix_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        count_ = static_cast<int>(kStepCountValues[std::clamp(choice(kSteps, at), 0, 2)]);
        const double stepBeats = kStepRateWholes[std::clamp(choice(kRate, at), 0, 5)] * 4.0;
        double beat = 0.0;
        const bool playing = beatAt(at, beat);
        clock_.control(playing, beat, stepBeats, tempo(), sr);
        attackStep_ = 1.0 / std::max(1.0, param(kAttack, at) * 0.001 * sr);
        decayCoef_ = lib::timeCoefficient(param(kDecay, at) * 0.001 / 3.0, sr);  // the decay time to about -26 dB
        releaseCoef_ = lib::timeCoefficient(param(kRelease, at) * 0.001 / 3.0, sr);
        sustain_ = clampTo(param(kSustain, at), 0.0, 1.0);
        length_ = clampTo(param(kLength, at), 0.05, 1.0);
        swing_ = clampTo(param(kSwing, at), 0.0, 1.0) * 0.5;  // at most half a step late
        legato_ = on(kLegato, at);
        for (int k = 0; k < count_; ++k) level_[k] = clampTo(param(kFirstStep + k, at), 0.0, 1.0);
        mix_.set(clampTo(param(kMixG, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            // Where we are: pairs of steps, the second of each pair starting `swing_` of a step late.
            const double pos = clock_.pos < 0.0 ? 0.0 : clock_.pos;
            clock_.advance();
            const double pair = std::floor(pos * 0.5);
            const double inPair = pos - 2.0 * pair;  // 0 .. 2
            const double split = 1.0 + swing_;
            const bool second = inPair >= split;
            const double into = second ? inPair - split : inPair;               // steps into this step
            const double span = second ? 2.0 - split : split;                   // this step's length in steps
            const auto index = static_cast<int64_t>(2.0 * pair) + (second ? 1 : 0);
            const int k = static_cast<int>(((index % count_) + count_) % count_);
            const double level = level_[k];
            if (index != step_) {
                step_ = index;
                const int before = (k + count_ - 1) % count_;
                const bool tie = legato_ && level_[before] > 0.0 && stage_ != sIdle && stage_ != sRelease;
                if (level > 0.0 && !tie) stage_ = sAttack, peak_ = level;
                else if (level > 0.0) peak_ = level;  // tied on: no new attack, the level follows
                else if (stage_ != sIdle) stage_ = sRelease;
            }
            // The gate ends `length_` of the way through the step, unless the next step ties on.
            if (stage_ != sIdle && stage_ != sRelease && into >= length_ * span) {
                const int next = (k + 1) % count_;
                if (!(legato_ && level_[next] > 0.0)) stage_ = sRelease;
            }
            switch (stage_) {
                case sAttack:
                    // A straight ramp to the step's level (down to it, at the same speed, from above).
                    if (env_ < peak_) env_ = std::min(peak_, env_ + attackStep_);
                    else env_ = std::max(peak_, env_ - attackStep_);
                    if (env_ == peak_) stage_ = sDecay;
                    break;
                case sDecay: env_ = peak_ * sustain_ + (env_ - peak_ * sustain_) * decayCoef_; break;
                case sRelease:
                    env_ *= releaseCoef_;
                    if (env_ < 1e-6) env_ = 0.0, stage_ = sIdle;
                    break;
                default: env_ = 0.0; break;
            }
            const double m = mix_.next();
            const double g = 1.0 - m + m * env_;
            outL[i] = static_cast<float>(inL[i] * g);
            outR[i] = static_cast<float>(inR[i] * g);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(step_ < 0 ? 0 : step_ % count_);
        out[3] = static_cast<float>(env_);
        out[4] = static_cast<float>(count_);
        return 5;
    }

private:
    enum Stage : int { sIdle, sAttack, sDecay, sRelease };
    creative::StepClock clock_;
    Ramp mix_;
    double level_[kMaxSteps] = {};
    double env_ = 0.0, peak_ = 0.0, attackStep_ = 0.02, decayCoef_ = 0.999, releaseCoef_ = 0.99, sustain_ = 1.0;
    double length_ = 0.5, swing_ = 0.0;
    int count_ = 16, stage_ = sIdle;
    int64_t step_ = -1;
    bool legato_ = false;
};

}  // namespace

void registerTranceGate(ModuleRegistry& registry) { registry.add(gateDescriptor(), &creative::make<TranceGate>); }

}  // namespace caw::fx
