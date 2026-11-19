// Peck (org.caw.pack.glitch, the AutoStacc beta pack): a tempo-grid glitch: each slice plays through or, by a seeded chaos roll, repeats, stutters, reverses, gates or re-pitches.
#include "builtin_effects.h"
#include "builtin_fx_creative.h"
#include "builtin_pack.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/grain.hpp"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0). The song's grid is cut into slices of `grid` (locked to the song while it
// plays, free at its tempo when stopped; at most 2 s). At each slice a roll of (seed, slice) decides, with the
// `chaos` chance, that the slice is glitched, and a second roll picks the action in proportion to the weights:
// - Repeat: the previous slice again;
// - Stutter: the slice's first 1/N (N 2, 3, 4, 6 or 8, at most `stutters`) repeated N times;
// - Reverse: the previous slice backwards;
// - Gate: the slice open for its first quarter, half or three quarters;
// - Pitch: the previous slice resampled up or down by a whole number of semitones (up to `range`), looped.
// The rolls are pure functions of (seed, slice), so a song glitches the same way wherever playback starts, and the
// display shows the bar's slices before they play. `hold` repeats the slice before it for as long as it is held
// (nothing is recorded meanwhile). Every action fades over `smooth` at the slice's edges (to and from the dry sound),
// so slices join without clicks. No latency: the actions read the slice playing or the one before it.

namespace caw::fx {

namespace {

using creative::chanceOf;
using creative::clampTo;

constexpr double kMaxSlice = 2.0;  // seconds
constexpr uint32_t kLane = 16;     // display: one bar of slices
constexpr std::string_view kGrids[] = {"1/32", "1/16 T", "1/16", "1/8 T", "1/8", "1/4", "1/2"};
constexpr double kGridBeats[] = {0.125, 0.25 * 2 / 3, 0.25, 0.5 * 2 / 3, 0.5, 1.0, 2.0};
constexpr std::string_view kStutters[] = {"2", "3", "4", "6", "8"};
constexpr int kStutterCounts[] = {2, 3, 4, 6, 8};
constexpr double kGateShares[] = {0.25, 0.5, 0.75};

enum Action : int { kThrough, kRepeat, kStutter, kReverse, kGate, kPitch };

enum PeParam : uint32_t {
    peGrid, peChaos, peRepeat, peStutter, peStutters, peReverse, peGate, pePitch, peRange, peSeed, peHold, peSmooth,
    peMix, peOutput, peCount
};

const ParamTable& peckParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("grid", "Grid", 2.0, kGrids);
        p.num("chaos", "Chaos", 0.35, 0.0, 1.0);
        p.num("repeat", "Repeat", 1.0, 0.0, 1.0);
        p.num("stutter", "Stutter", 0.7, 0.0, 1.0);
        p.pick("stutters", "Stutter most", 2.0, kStutters);
        p.num("reverse", "Reverse", 0.5, 0.0, 1.0);
        p.num("gate", "Gate", 0.4, 0.0, 1.0);
        p.num("pitch", "Pitch", 0.3, 0.0, 1.0);
        p.num("range", "Pitch range", 12.0, 1.0, 24.0, "st").step = 1.0;
        ParameterDescriptor& seed = p.num("seed", "Seed", 1.0, 0.0, 9999.0);
        seed.step = 1.0;
        seed.smoothingFrames = 0;
        p.pick("hold", "Hold", 0.0, kOffOn);
        p.num("smooth", "Smooth", 1.5, 0.5, 10.0, "ms");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}

const ModuleDescriptor& peckDescriptor() {
    static const ModuleDescriptor d = withCpu(
        effectDescriptor("org.caw.pack.glitch", "Peck", peckParams(), 0, static_cast<uint32_t>(kMaxSlice * 48000)),
        CpuClass::Light);
    return d;
}

inline float finite0(float x) noexcept { return x == x && x - x == 0.0f ? x : 0.0f; }

// What slice k does: the action and its amount (Stutter: N; Gate: the open share; Pitch: semitones).
struct Plan {
    int action = kThrough;
    double amount = 0.0;
};

class Peck final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return peckDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        return ring_.prepare(static_cast<uint32_t>(std::ceil(kMaxSlice * sr)) + 256);
    }
    void clearState() noexcept override {
        ring_.clear();
        clock_.reset();
        written_ = 0;
        slice_ = INT64_MIN;
        plan_ = {};
        t_ = 0.0;
        held_ = false;
        first_ = true;
        mix_.reset(), out_.reset();
    }
    uint64_t idleFrames() const noexcept override {
        if (hold_) return ~0ull >> 2;
        return static_cast<uint64_t>(sliceWant_ + edge_ + 0.05 * rate());
    }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        if (first_ || !knobsUnchanged(knobs_, peCount, at)) {
            beats_ = kGridBeats[std::clamp(choice(peGrid, at), 0, 6)];
            chaos_ = clampTo(param(peChaos, at), 0.0, 1.0);
            w_[0] = clampTo(param(peRepeat, at), 0.0, 1.0);
            w_[1] = clampTo(param(peStutter, at), 0.0, 1.0);
            w_[2] = clampTo(param(peReverse, at), 0.0, 1.0);
            w_[3] = clampTo(param(peGate, at), 0.0, 1.0);
            w_[4] = clampTo(param(pePitch, at), 0.0, 1.0);
            stutters_ = std::clamp(choice(peStutters, at), 0, 4) + 1;
            range_ = clampTo(std::floor(param(peRange, at) + 0.5), 1.0, 24.0);
            seed_ = static_cast<uint32_t>(clampTo(std::floor(param(peSeed, at) + 0.5), 0.0, 9999.0));
            hold_ = on(peHold, at);
            edge_ = std::max(1.0, std::floor(clampTo(param(peSmooth, at), 0.5, 10.0) * 0.001 * sr));
            mixTarget_ = clampTo(param(peMix, at), 0.0, 1.0);
            outTarget_ = lib::dbToGain(param(peOutput, at));
        }
        sliceWant_ = std::floor(clampTo(beats_ * 60.0 / tempo() * sr, 64.0, kMaxSlice * sr));
        double beat = 0.0;
        const bool playing = beatAt(at, beat);
        clock_.control(playing, beat, beats_, tempo(), sr);
        mix_.set(mixTarget_, kControlFrames), out_.set(outTarget_, kControlFrames);
        first_ = false;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const lib::grain::Source src = ring_.source(true);
        const int64_t len = ring_.length();
        auto at = [&](int64_t abs, int c) noexcept {
            int64_t k = abs % len;
            if (k < 0) k += len;
            return (c ? src.r : src.l)[k];
        };
        for (uint32_t i = 0; i < n; ++i) {
            const float dl = finite0(inL[i]), dr = finite0(inR[i]);
            const auto k = static_cast<int64_t>(std::floor(clock_.pos + 1e-9));
            clock_.advance();
            if (k != slice_) startSlice(k);
            if (!held_) ring_.write(dl, dr), ++written_;
            const double t = t_;
            t_ += 1.0;
            double wl = dl, wr = dr, e = 1.0;
            switch (plan_.action) {
                case kRepeat: {
                    const int64_t abs = base_ + static_cast<int64_t>(t) % len_;
                    wl = at(abs, 0), wr = at(abs, 1);
                    break;
                }
                case kReverse: {
                    const int64_t abs = base_ + len_ - 1 - static_cast<int64_t>(t) % len_;
                    wl = at(abs, 0), wr = at(abs, 1);
                    break;
                }
                case kStutter: {
                    const int64_t sub = std::max<int64_t>(1, len_ / static_cast<int64_t>(plan_.amount));
                    const int64_t s = static_cast<int64_t>(t);
                    if (s >= sub) {
                        const int64_t abs = start_ + s % sub;
                        wl = at(abs, 0), wr = at(abs, 1);
                        // Each repeat fades in and out at its own edges too.
                        const double u = static_cast<double>(s % sub);
                        e = std::min({1.0, (u + 1.0) / edge_, (static_cast<double>(sub) - u) / edge_});
                    } else {
                        e = std::min(1.0, (static_cast<double>(sub) - t) / edge_);
                    }
                    break;
                }
                case kPitch: {
                    double p = t * ratio_;
                    p -= static_cast<double>(len_) * std::floor(p / static_cast<double>(len_));
                    const double abs = static_cast<double>(base_) + p;
                    const double fl = std::floor(abs);
                    const auto j = static_cast<int64_t>(fl);
                    const float f = static_cast<float>(abs - fl);
                    wl = at(j, 0) + f * (at(j + 1, 0) - at(j, 0));
                    wr = at(j, 1) + f * (at(j + 1, 1) - at(j, 1));
                    break;
                }
                case kGate: {
                    const double open = plan_.amount * static_cast<double>(len_);
                    const double g = std::max(clampTo((open - t) / edge_, 0.0, 1.0),
                                              clampTo((t - (static_cast<double>(len_) - edge_)) / edge_, 0.0, 1.0));
                    wl = dl * g, wr = dr * g;
                    break;
                }
                default:
                    break;
            }
            if (plan_.action != kThrough && plan_.action != kGate) {
                // Into and out of the slice from and back to the dry sound.
                e = std::min({e, (t + 1.0) / edge_, (static_cast<double>(len_) - t) / edge_});
                e = clampTo(e, 0.0, 1.0);
                wl = dl + (wl - dl) * e, wr = dr + (wr - dr) * e;
            }
            const double m = mix_.next(), g = out_.next();
            outL[i] = static_cast<float>(g * (dl + (wl - dl) * m));
            outR[i] = static_cast<float>(g * (dr + (wr - dr) * m));
        }
    }

    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        const int64_t k = slice_ == INT64_MIN ? 0 : slice_;
        const int64_t bar = k - ((k % kLane) + kLane) % kLane;
        out[2] = static_cast<float>(k - bar);
        out[3] = static_cast<float>(plan_.action);
        out[4] = static_cast<float>(clampTo(t_ / std::max<double>(1, len_), 0.0, 1.0));
        out[5] = static_cast<float>(1000.0 * sliceWant_ / rate());
        out[6] = held_ ? 1.0f : 0.0f;
        out[7] = static_cast<float>(plan_.amount);
        // The bar's slices, played and to come: each one's action and amount.
        for (uint32_t s = 0; s < kLane; ++s) {
            const Plan p = held_ ? Plan{kRepeat, 0.0} : planOf(bar + s);
            out[8 + s] = static_cast<float>(p.action);
            out[8 + kLane + s] = static_cast<float>(p.amount);
        }
        return 8 + 2 * kLane;
    }

private:
    Plan planOf(int64_t k) const noexcept {
        const uint64_t at = static_cast<uint64_t>(k) * 8u;
        if (chanceOf(seed_, at) >= chaos_) return {};
        const double sum = w_[0] + w_[1] + w_[2] + w_[3] + w_[4];
        if (sum <= 0.0) return {};
        double r = chanceOf(seed_, at + 1) * sum;
        int pick = 0;
        while (pick < 4 && r >= w_[pick]) r -= w_[pick], ++pick;
        const double u = chanceOf(seed_, at + 2);
        switch (pick) {
            case 0: return {kRepeat, 0.0};
            case 1: return {kStutter, static_cast<double>(kStutterCounts[std::min(stutters_ - 1, static_cast<int>(u * stutters_))])};
            case 2: return {kReverse, 0.0};
            case 3: return {kGate, kGateShares[std::min(2, static_cast<int>(u * 3))]};
            default: {
                double st = std::floor((2.0 * u - 1.0) * range_ + 0.5);
                if (st == 0.0) st = u < 0.5 ? -range_ : range_;
                return {kPitch, st};
            }
        }
    }
    void startSlice(int64_t k) noexcept {
        const bool wasHeld = held_;
        slice_ = k;
        t_ = 0.0;
        start_ = written_;  // where this slice's own audio is recorded
        if (hold_) {
            if (!wasHeld) base_ = written_ - static_cast<int64_t>(len_), held_ = true;  // keep the slice before
            plan_ = {kRepeat, 0.0};
            return;
        }
        held_ = false;
        len_ = static_cast<int64_t>(sliceWant_);
        base_ = written_ - len_;  // the previous slice
        plan_ = planOf(k);
        ratio_ = plan_.action == kPitch ? detPow(2.0, plan_.amount / 12.0) : 1.0;
    }

    lib::grain::Ring ring_;
    creative::StepClock clock_;
    Ramp mix_, out_;
    double knobs_[peCount] = {};
    double w_[5] = {1, 0.7, 0.5, 0.4, 0.3};
    double beats_ = 0.25, chaos_ = 0.35, range_ = 12, edge_ = 72, sliceWant_ = 6000, ratio_ = 1.0, t_ = 0.0;
    double mixTarget_ = 1.0, outTarget_ = 1.0;
    int64_t written_ = 0, slice_ = INT64_MIN, start_ = 0, base_ = 0, len_ = 6000;
    int stutters_ = 3;
    uint32_t seed_ = 1;
    Plan plan_;
    bool hold_ = false, held_ = false, first_ = true;
};

ModuleProcessor* makePeck() noexcept { return new (std::nothrow) Peck(); }

using V = std::vector<std::pair<std::string_view, double>>;

}  // namespace

void registerPeck(ModuleRegistry& registry) { registry.add(peckDescriptor(), &makePeck); }
size_t peckBytes(double sr) noexcept {
    return sizeof(Peck) + 2 * sizeof(float) * (static_cast<size_t>(std::ceil(kMaxSlice * sr)) + 259);
}

const std::vector<BuiltinPreset>& peckPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Light pecks", "Drums: a few sixteenth glitches a bar", V{{"chaos", 0.2}}},
        {"Beat repeat", "Drums: eighth-note repeats only", V{{"grid", 4}, {"chaos", 0.4}, {"stutter", 0}, {"reverse", 0}, {"gate", 0}, {"pitch", 0}}},
        {"Stutter roll", "Drums: rolls of 4, 6 and 8 on the sixteenths", V{{"chaos", 0.5}, {"repeat", 0}, {"stutter", 1}, {"stutters", 4}, {"reverse", 0}, {"gate", 0}, {"pitch", 0}}},
        {"Reverse flips", "Sound design: slices flipped backwards", V{{"grid", 4}, {"chaos", 0.5}, {"repeat", 0}, {"stutter", 0}, {"reverse", 1}, {"gate", 0}, {"pitch", 0}}},
        {"Chopped gate", "Mixing: a choppy gate on the sixteenths", V{{"chaos", 0.7}, {"repeat", 0}, {"stutter", 0}, {"reverse", 0}, {"gate", 1}, {"pitch", 0}}},
        {"Pitch jumps", "Sound design: slices jumping by up to an octave", V{{"grid", 4}, {"chaos", 0.5}, {"repeat", 0}, {"stutter", 0}, {"reverse", 0}, {"gate", 0}, {"pitch", 1}}},
        {"Vocal chops", "Vocals: stutters and flips on the eighth triplets", V{{"grid", 3}, {"chaos", 0.45}, {"pitch", 0.5}, {"range", 7}, {"smooth", 3}}},
        {"Total chaos", "Sound design: every slice glitched, everything on", V{{"chaos", 1}, {"grid", 0}, {"stutters", 4}, {"range", 24}}},
        {"Half-bar breaks", "Drums: big half-note repeats and reverses", V{{"grid", 6}, {"chaos", 0.5}, {"gate", 0}, {"pitch", 0}, {"stutter", 0.3}}},
        {"Lo-fi skips", "Lo-fi: a skipping record: quarter-note repeats", V{{"grid", 5}, {"chaos", 0.3}, {"stutter", 0}, {"reverse", 0.2}, {"gate", 0}, {"pitch", 0}, {"smooth", 6}}},
        {"Bass wobble chops", "Bass: gates and octave jumps on the eighths", V{{"grid", 4}, {"chaos", 0.6}, {"repeat", 0.2}, {"stutter", 0}, {"reverse", 0}, {"gate", 1}, {"pitch", 0.6}, {"range", 12}}},
    };
    return p;
}

}  // namespace caw::fx
