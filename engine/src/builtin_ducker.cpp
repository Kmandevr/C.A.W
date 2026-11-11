// The ducker (org.caw.ducker, #175): a drawn duck shape triggered by a key's audio, a track's notes or the tempo.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/dynamics.hpp"
#include "caw/library/filter.hpp"
#include "component_chain.h"

// Original code (C.A.W. is Apache-2.0); the technique is in docs/engine.md ("The ducker"). The key filters are
// Simper's trapezoidal state-variable filter (caw/library/filter.hpp); the band split is a Linkwitz-Riley
// crossover (two second-order Butterworth sections per side, so the two bands sum flat: Linkwitz, "Active
// crossover networks for noncoincident drivers", JAES 24(1), 1976).

namespace caw::fx {

namespace {

enum DuckParam : uint32_t {
    kMode, kDepth, kAttack, kHold, kRelease, kTension, kMix, kRate, kOffset, kThreshold, kResponse, kKeyHpf, kKeyLpf,
    kLookahead, kBands, kCrossover, kLink, kVelocity, kListen, kDuckCount
};
constexpr std::string_view kModes[] = {"Audio", "Notes", "Tempo"};
constexpr std::string_view kResponses[] = {"Trigger", "Follow"};
constexpr std::string_view kBandModes[] = {"Full", "Lows", "Highs"};
constexpr std::string_view kLookaheads[] = {"Off", "1 ms", "3 ms", "5 ms", "10 ms"};
constexpr double kLookaheadMs[] = {0.0, 1.0, 3.0, 5.0, 10.0};
constexpr std::string_view kRates[] = {"1/16", "1/8 T", "1/8", "1/8 D", "1/4 T", "1/4", "1/4 D", "1/2", "1 bar", "2 bars"};
constexpr double kRateBeats[] = {0.25, 1.0 / 3.0, 0.5, 0.75, 2.0 / 3.0, 1.0, 1.5, 2.0, 4.0, 8.0};  // in beats (bar: 4/4)
constexpr double kFollowRangeDb = 12.0;  // Follow: the duck reaches full depth this far over the threshold
constexpr double kRearmDb = 4.0;          // Trigger: the key must fall this far under the threshold to trigger again
constexpr double kTensionSteepness = 6.0;

const ParamTable& duckParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("mode", "Trigger", 2.0, kModes);
        p.num("depth", "Depth", 0.9, 0.0, 1.0);
        p.expo("attack", "Attack", 1.0, 0.1, 500.0, "ms");
        p.num("hold", "Hold", 10.0, 0.0, 1000.0, "ms");
        p.expo("release", "Release", 220.0, 1.0, 4000.0, "ms");
        p.num("tension", "Curve", 0.35, -1.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.pick("rate", "Rate", 5.0, kRates);
        p.num("offset", "Offset", 0.0, 0.0, 1.0);
        p.num("threshold", "Threshold", -24.0, -60.0, 0.0, "dB");
        p.pick("response", "Response", 0.0, kResponses);
        p.expo("key_hpf", "Key high-pass", 20.0, 20.0, 2000.0, "Hz");
        p.expo("key_lpf", "Key low-pass", 20000.0, 200.0, 20000.0, "Hz");
        p.pick("lookahead", "Look-ahead", 0.0, kLookaheads);
        p.pick("bands", "Bands", 0.0, kBandModes);
        p.expo("crossover", "Crossover", 150.0, 40.0, 2000.0, "Hz");
        p.num("link", "Stereo link", 1.0, 0.0, 1.0);
        p.num("velocity", "Velocity", 0.0, 0.0, 1.0);
        p.pick("listen", "Key listen", 0.0, kOffOn);
        return p;
    }();
    return t;
}

const ModuleDescriptor& duckDescriptor() {
    // Latency 0 here: the look-ahead's delay is reported per instance (VariableLatency), only while it is on.
    static const ModuleDescriptor d = keyedEffectDescriptor("org.caw.ducker", "Ducker", duckParams(), 0, 0, true);
    return d;
}

uint32_t lookaheadFrames(int mode, int choice, double sampleRate) {
    if (mode != 0 || choice <= 0) return 0;
    const int c = std::min(choice, 4);
    return static_cast<uint32_t>(std::lround(kLookaheadMs[c] * 0.001 * sampleRate));
}

// 0..1 to 0..1 with a bend: 0 straight, > 0 starts slow and speeds up (convex), < 0 starts fast and settles.
double bend(double x, double tension) noexcept {
    x = std::clamp(x, 0.0, 1.0);
    if (std::fabs(tension) < 1e-3) return x;
    const double c = tension * kTensionSteepness;
    return (std::exp(c * x) - 1.0) / (std::exp(c) - 1.0);
}

class Ducker final : public EffectBase, public VariableLatency {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return duckDescriptor(); }
    uint32_t latencyFor(const double* values, uint32_t count) const noexcept override {
        if (count <= kLookahead) return 0;
        return lookaheadFrames(static_cast<int>(values[kMode] + 0.5), static_cast<int>(values[kLookahead] + 0.5), rate());
    }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        // The look-ahead line: up to 10 ms at any rate (set aside here, never on the audio thread).
        const size_t n = static_cast<size_t>(std::ceil(0.0105 * sampleRate)) + 2;
        try {
            delay_[0].assign(n, 0.0f);
            delay_[1].assign(n, 0.0f);
        } catch (const std::bad_alloc&) {
            return false;
        }
        follow_[0].setCoefficients(lib::timeCoefficient(0.00005, sampleRate), lib::timeCoefficient(0.03, sampleRate));
        follow_[1].setCoefficients(lib::timeCoefficient(0.00005, sampleRate), lib::timeCoefficient(0.03, sampleRate));
        return true;
    }
    void clearState() noexcept override {
        for (auto& line : delay_) std::fill(line.begin(), line.end(), 0.0f);
        pos_ = 0;
        for (int c = 0; c < 2; ++c) {
            hpf_[c].clear();
            lpf_[c].clear();
            follow_[c].clear();
            for (auto& f : split_[c]) f.clear();
            amount_[c] = 0.0;
            followHold_[c] = 0;
        }
        at_ = -1;
        from_ = duck_ = 0.0;
        armed_ = true;
        lastPeriod_ = INT64_MIN;
        scale_ = scaleTarget_ = 1.0;
        scaleStep_ = 0.0;
        grMax_ = keyMax_ = 0.0;
        triggers_ = 0;
    }
    uint64_t idleFrames() const noexcept override {
        // Silent in and out this long: nothing more can come out (the look-ahead line has emptied too).
        return static_cast<uint64_t>(0.0105 * rate()) + static_cast<uint64_t>(0.05 * rate());
    }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        mode_ = choice(kMode, at);
        depth_ = std::clamp(param(kDepth, at), 0.0, 1.0);
        attack_ = std::max(1.0, param(kAttack, at) * 0.001 * sr);
        hold_ = std::max(0.0, param(kHold, at) * 0.001 * sr);
        release_ = std::max(1.0, param(kRelease, at) * 0.001 * sr);
        tension_ = std::clamp(param(kTension, at), -1.0, 1.0);
        mix_ = std::clamp(param(kMix, at), 0.0, 1.0);
        const int rate = std::clamp(choice(kRate, at), 0, static_cast<int>(std::size(kRateBeats)) - 1);
        periodBeats_ = kRateBeats[rate];
        offset_ = std::clamp(param(kOffset, at), 0.0, 1.0);
        threshold_ = param(kThreshold, at);
        followMode_ = choice(kResponse, at) == 1;
        const double hpf = param(kKeyHpf, at), lpf = param(kKeyLpf, at);
        useHpf_ = hpf > 20.5;
        useLpf_ = lpf < 19999.0;
        for (int c = 0; c < 2; ++c) {
            hpf_[c].set(hpf, 0.70710678118654752, sr);
            lpf_[c].set(lpf, 0.70710678118654752, sr);
        }
        lookahead_ = lookaheadFrames(mode_, choice(kLookahead, at), sr);
        bands_ = std::clamp(choice(kBands, at), 0, 2);
        const double xo = param(kCrossover, at);
        for (int c = 0; c < 2; ++c)
            for (auto& f : split_[c]) f.set(xo, 0.70710678118654752, sr);
        link_ = std::clamp(param(kLink, at), 0.0, 1.0);
        velocity_ = std::clamp(param(kVelocity, at), 0.0, 1.0);
        listen_ = on(kListen, at);
        followAttack_ = lib::timeCoefficient(std::max(0.0001, param(kAttack, at) * 0.001), sr);
        followRelease_ = lib::timeCoefficient(std::max(0.001, param(kRelease, at) * 0.001), sr);
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const float* keyL = keyLeft();
        const float* keyR = keyRight();
        const EventInput& notes = keyNotes();
        const uint32_t first = runStart();
        const size_t size = delay_[0].size();
        // Filters fed silence decay through denormal numbers (slow on many CPUs): settle them at 0 instead.
        for (int c = 0; c < 2; ++c) {
            hpf_[c].flushDenormals();
            lpf_[c].flushDenormals();
            for (auto& f : split_[c]) f.flushDenormals();
        }
        for (uint32_t i = 0; i < n; ++i) {
            // The key, filtered (Audio mode reads it; Listen plays it). A NaN or Inf in it reads as 0, before the
            // filters (whose state it would stay in) and after them.
            double k[2] = {keyL ? finiteOr0(keyL[i]) : 0.0, keyR ? finiteOr0(keyR[i]) : 0.0};
            if (mode_ == 0 || listen_)
                for (int c = 0; c < 2; ++c) {
                    if (useHpf_) k[c] = hpf_[c].highpass(k[c]);
                    if (useLpf_) k[c] = lpf_[c].lowpass(k[c]);
                    k[c] = finiteOr0(k[c]);
                }
            double g[2] = {1.0, 1.0};
            if (mode_ == 0) {
                const double level[2] = {follow_[0].process(std::fabs(k[0])), follow_[1].process(std::fabs(k[1]))};
                const double most = std::max(level[0], level[1]);
                keyMax_ = std::max(keyMax_, most);
                const double mostDb = lib::gainToDb(most, -200.0);
                if (followMode_) {
                    // Follow: the duck follows how far the key is over the threshold (per side, linked by `link`).
                    for (int c = 0; c < 2; ++c) {
                        const double lv = level[c] + (most - level[c]) * link_;
                        const double over = (lib::gainToDb(lv, -200.0) - threshold_) / kFollowRangeDb;
                        const double target = std::clamp(over, 0.0, 1.0);
                        if (target > amount_[c]) {
                            amount_[c] = target + (amount_[c] - target) * followAttack_;
                            followHold_[c] = static_cast<int64_t>(hold_);
                        } else if (followHold_[c] > 0) {
                            --followHold_[c];
                        } else {
                            amount_[c] = target + (amount_[c] - target) * followRelease_;
                        }
                        if (!(amount_[c] >= 1e-9 && amount_[c] <= 1.0)) amount_[c] = 0.0;  // settled, or not finite
                        g[c] = 1.0 - depth_ * mix_ * bend(amount_[c], -tension_ * 0.5);
                    }
                    duck_ = std::max(amount_[0], amount_[1]);
                } else {
                    // Trigger: the key crossing the threshold plays the shape; it re-arms once the key falls well
                    // under it and the attack has played, so one kick is one duck.
                    if (armed_ && mostDb > threshold_) {
                        trigger(1.0);
                        armed_ = false;
                    } else if (!armed_ && mostDb < threshold_ - kRearmDb && (at_ < 0 || at_ >= attack_)) {
                        armed_ = true;
                    }
                }
            } else if (mode_ == 1) {
                // Notes: every note-on of the key's track plays the shape on its own frame.
                for (uint32_t e = 0; e < notes.count; ++e) {
                    const Event& ev = notes.events[e];
                    if (ev.frame != first + i || ev.kind != EventKind::Note) continue;
                    if (((ev.data[0] >> 28) & 0xFu) != 0x4u || ((ev.data[0] >> 20) & 0xFu) != 0x9u) continue;
                    const double vel = static_cast<double>(ev.data[1] >> 16) / 65535.0;
                    if (vel <= 0.0) continue;
                    trigger(vel);
                }
            } else {
                // Tempo: a duck on every division of the song's beat (no input needed), shifted by the offset.
                double beat = 0.0;
                if (beatAt(first + i, beat)) {
                    const double phase = beat / periodBeats_ - offset_;
                    const int64_t period = static_cast<int64_t>(std::floor(phase + 1e-9));
                    if (period != lastPeriod_) {
                        lastPeriod_ = period;
                        trigger(1.0);
                    }
                    phase_ = phase - std::floor(phase);
                } else {
                    lastPeriod_ = INT64_MIN;  // stopped: the next Play ducks on its first beat
                    phase_ = -1.0;
                }
            }
            if (mode_ != 0 || !followMode_) {
                if (scale_ != scaleTarget_) {  // a retrigger's new depth, gliding in over the attack
                    scale_ += scaleStep_;
                    if ((scaleStep_ > 0.0) == (scale_ >= scaleTarget_)) scale_ = scaleTarget_;
                }
                duck_ = shape();
                const double gain = 1.0 - depth_ * scale_ * mix_ * duck_;
                g[0] = g[1] = gain;
            }
            // The main signal, through the look-ahead line (Audio mode with look-ahead: the duck leads by it).
            delay_[0][pos_] = inL[i];
            delay_[1][pos_] = inR[i];
            const size_t read = (pos_ + size - lookahead_) % size;
            const double x[2] = {delay_[0][read], delay_[1][read]};
            pos_ = pos_ + 1 == size ? 0 : pos_ + 1;
            double y[2];
            for (int c = 0; c < 2; ++c) {
                if (bands_ == 0) {
                    y[c] = x[c] * g[c];
                } else {
                    const double low = split_[c][1].lowpass(split_[c][0].lowpass(x[c]));
                    const double high = split_[c][3].highpass(split_[c][2].highpass(x[c]));
                    y[c] = bands_ == 1 ? low * g[c] + high : low + high * g[c];
                }
            }
            const double gr = std::min(g[0], g[1]);
            grMax_ = std::min(grMax_, lib::gainToDb(gr, -120.0));
            grNow_ = lib::gainToDb(gr, -120.0);
            if (listen_) {
                outL[i] = static_cast<float>(k[0]);
                outR[i] = static_cast<float>(k[1]);
            } else {
                outL[i] = static_cast<float>(y[0]);
                outR[i] = static_cast<float>(y[1]);
            }
        }
    }

    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(lib::gainToDb(keyMax_));
        out[3] = static_cast<float>(duck_);
        out[4] = static_cast<float>(grNow_ < 0.0 ? -grNow_ : 0.0);
        out[5] = static_cast<float>(grMax_ < 0.0 ? -grMax_ : 0.0);
        out[6] = at_ >= 0 ? static_cast<float>(at_ * 1000.0 / rate()) : -1.0f;
        out[7] = static_cast<float>(mode_);
        out[8] = static_cast<float>(threshold_);
        out[9] = static_cast<float>(depth_);
        out[10] = static_cast<float>(lookahead_ * 1000.0 / rate());
        out[11] = static_cast<float>(triggers_);
        out[12] = mode_ == 2 ? static_cast<float>(periodBeats_ * 60000.0 / std::max(1.0, tempo())) : 0.0f;
        out[13] = mode_ == 2 ? static_cast<float>(phase_) : -1.0f;
        out[14] = static_cast<float>(attack_ * 1000.0 / rate());
        out[15] = static_cast<float>(hold_ * 1000.0 / rate());
        out[16] = static_cast<float>(release_ * 1000.0 / rate());
        out[17] = static_cast<float>(tension_);
        grMax_ = 0.0;
        keyMax_ = 0.0;
        triggers_ = 0;
        return 18;
    }

private:
    // The shape starts again (a kick, a note, a beat): the attack runs from wherever the duck is now, so a duck
    // retriggered before it has recovered doesn't jump. A new depth (Velocity: a softer or harder note) jumps only
    // while nothing is ducked; during a duck it glides in over the attack, so the gain stays continuous.
    void trigger(double velocity) noexcept {
        from_ = duck_;
        at_ = 0;
        scaleTarget_ = 1.0 - velocity_ * (1.0 - std::clamp(velocity, 0.0, 1.0));
        if (duck_ <= 0.0) {
            scale_ = scaleTarget_;
            scaleStep_ = 0.0;
        } else {
            scaleStep_ = (scaleTarget_ - scale_) / std::max(1.0, attack_);
        }
        ++triggers_;
    }
    // The duck now (0 none, 1 full) and one sample on: attack (from where it was to full), hold, release (its
    // curve bent by the tension: > 0 swells back, the classic pump; < 0 springs back and settles).
    double shape() noexcept {
        if (at_ < 0) return 0.0;
        const double t = static_cast<double>(at_);
        double d;
        if (t < attack_) {
            d = from_ + (1.0 - from_) * (1.0 - bend(1.0 - (t + 1.0) / attack_, 0.5));
        } else if (t < attack_ + hold_) {
            d = 1.0;
        } else if (t < attack_ + hold_ + release_) {
            d = 1.0 - bend((t - attack_ - hold_ + 1.0) / release_, tension_);
        } else {
            at_ = -1;
            return 0.0;
        }
        ++at_;
        return d;
    }

    std::vector<float> delay_[2];
    size_t pos_ = 0;
    lib::Svf hpf_[2], lpf_[2];
    lib::Svf split_[2][4];  // per side: two low-passes, then two high-passes (Linkwitz-Riley, 24 dB/octave)
    lib::EnvelopeFollower follow_[2];
    double amount_[2] = {}, followAttack_ = 0, followRelease_ = 0;
    int64_t followHold_[2] = {};
    int mode_ = 2, bands_ = 0;
    double depth_ = 0.9, attack_ = 48, hold_ = 480, release_ = 10560, tension_ = 0.35, mix_ = 1;
    double periodBeats_ = 1, offset_ = 0, threshold_ = -24, link_ = 1, velocity_ = 0;
    double phase_ = -1;
    uint32_t lookahead_ = 0;
    bool useHpf_ = false, useLpf_ = false, followMode_ = false, listen_ = false, armed_ = true;
    int64_t at_ = -1, lastPeriod_ = INT64_MIN;
    double from_ = 0, duck_ = 0, scale_ = 1, scaleTarget_ = 1, scaleStep_ = 0;
    double grMax_ = 0, grNow_ = 0, keyMax_ = 0;
    uint32_t triggers_ = 0;
};

}  // namespace

ModuleProcessor* makeDucker() noexcept { return new (std::nothrow) Ducker(); }

void registerDucker(ModuleRegistry& registry) { registry.add(duckDescriptor(), &makeDucker); }

}  // namespace caw::fx
