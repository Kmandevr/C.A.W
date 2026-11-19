// Bend (org.caw.pack.warp, the AutoStacc beta pack): time and pitch warping of the input along a drawable, tempo-synced curve (a smoothed, time-varying resample of a recorded buffer).
#include "builtin_effects.h"
#include "builtin_fx_creative.h"
#include "builtin_pack.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <string>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/grain.hpp"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0); the varispeed tape-delay idea. The input is recorded into a 2 s ring and
// read back at a moving age. A curve of `points` values (p0..p15, -1..1; Linear, Smooth or Step between them, and
// round from the last back to the first) is played once per `cycle` (locked to the song while it plays, free at its
// tempo when stopped):
// - Time: the curve is the delay, from the shortest (-1) to `depth` later (+1). Where it rises the sound slows and
//   drops in pitch, where it falls it speeds up and rises (a fall faster than real time plays backwards).
// - Speed: the curve is the speed, 2^(value x `range`) octaves (-1 .. +1: `range` octaves down .. up). The read
//   drifts from the recording, held between the newest frames and 2 s back (at an end it moves at 1x); `resync`
//   brings it back to the newest frames at each cycle's start, crossfaded over 10 ms.
// The curve is read at control rate (16 frames) and its delay (or speed) smoothed by a one-pole over `smooth`, then
// ramped frame by frame, so the resample never steps. The read is cubic. Latency: 3 frames (the newest a cubic read
// may take); the dry sound is delayed to match, so the mix is aligned.

namespace caw::fx {

namespace {

using creative::clampTo;

constexpr double kMaxAge = 2.0;  // seconds
constexpr uint32_t kBase = 4;    // the newest age read (age 1 is the frame just recorded): 3 frames late, the latency
constexpr uint32_t kPoints = 16, kShape = 64;
constexpr std::string_view kModes[] = {"Time", "Speed"};
constexpr std::string_view kCycles[] = {"1/4", "1/2", "1 bar", "2 bars", "4 bars"};
constexpr double kCycleBeats[] = {1, 2, 4, 8, 16};
constexpr std::string_view kPointCounts[] = {"4", "8", "16"};
constexpr uint32_t kPointCount[] = {4, 8, 16};
constexpr std::string_view kShapes[] = {"Linear", "Smooth", "Step"};

enum BeParam : uint32_t {
    beMode, beCycle, beDepth, beRange, bePoints, beShape, beSmooth, beResync, beMix, beOutput, beP0, beCount = beP0 + kPoints
};

const ParamTable& bendParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("mode", "Mode", 0.0, kModes);
        p.pick("cycle", "Cycle", 2.0, kCycles);
        p.num("depth", "Depth", 40.0, 0.0, 1000.0, "ms");
        p.num("range", "Range", 1.0, 0.0, 2.0, "oct");
        p.pick("points", "Points", 1.0, kPointCounts);
        p.pick("shape", "Shape", 1.0, kShapes);
        p.num("smooth", "Smooth", 20.0, 0.0, 200.0, "ms");
        p.pick("resync", "Resync", 1.0, kOffOn);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        for (uint32_t k = 0; k < kPoints; ++k)  // a sine of 8 points: a gentle wow
            p.num("p" + std::to_string(k), "Point " + std::to_string(k + 1), std::round(1000.0 * detSin(kTwoPi * k / 8.0)) / 1000.0, -1.0, 1.0);
        return p;
    }();
    return t;
}

const ModuleDescriptor& bendDescriptor() {
    static const ModuleDescriptor d = withCpu(
        effectDescriptor("org.caw.pack.warp", "Bend", bendParams(), kBase - 1, static_cast<uint32_t>(kMaxAge * 48000)),
        CpuClass::Light);
    return d;
}

inline float finite0(float x) noexcept { return x == x && x - x == 0.0f ? x : 0.0f; }

class Bend final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return bendDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        maxAge_ = std::floor(kMaxAge * sr);
        return ring_.prepare(static_cast<uint32_t>(maxAge_) + 64);
    }
    void clearState() noexcept override {
        ring_.clear();
        clock_.reset();
        written_ = 0;
        age_ = step_ = smoothed_ = kBase;
        old_ = kBase;
        xf_ = 0;
        lastCycle_ = INT64_MIN;
        first_ = true;
        dry_.reset(), wet_.reset();
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>(maxAge_ + 0.05 * rate()); }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        if (first_ || !knobsUnchanged(knobs_, beCount, at)) {
            speedMode_ = choice(beMode, at) == 1;
            beats_ = kCycleBeats[std::clamp(choice(beCycle, at), 0, 4)];
            depth_ = clampTo(param(beDepth, at), 0.0, 1000.0) * 0.001 * sr;
            range_ = clampTo(param(beRange, at), 0.0, 2.0);
            n_ = kPointCount[std::clamp(choice(bePoints, at), 0, 2)];
            shape_ = std::clamp(choice(beShape, at), 0, 2);
            const double s = clampTo(param(beSmooth, at), 0.0, 200.0) * 0.001;
            pole_ = s <= 0.0 ? 1.0 : 1.0 - detExp(-static_cast<double>(kControlFrames) / (s * sr));
            resync_ = on(beResync, at);
            const double mix = clampTo(param(beMix, at), 0.0, 1.0), out = lib::dbToGain(param(beOutput, at));
            dryTarget_ = (1.0 - mix) * out, wetTarget_ = mix * out;
            for (uint32_t k = 0; k < kPoints; ++k) p_[k] = clampTo(param(beP0 + k, at), -1.0, 1.0);
        }
        double beat = 0.0;
        const bool playing = beatAt(at, beat);
        clock_.control(playing, beat, beats_, tempo(), sr);
        const double cycles = clock_.pos;
        phase_ = cycles - std::floor(cycles);
        value_ = curve(phase_);
        const auto cycle = static_cast<int64_t>(std::floor(cycles + 1e-9));
        const bool newCycle = cycle != lastCycle_ && lastCycle_ != INT64_MIN;
        lastCycle_ = cycle;
        const double target = speedMode_ ? detPow(2.0, value_ * range_) : kBase + depth_ * 0.5 * (value_ + 1.0);
        smoothed_ = first_ ? target : smoothed_ + (target - smoothed_) * pole_;
        if (speedMode_) {
            speed_ = smoothed_;
            if (newCycle && resync_ && age_ > kBase + 1.0) old_ = age_, age_ = kBase, xf_ = kXfade;
        } else {
            // The delay moves to its new value over the next 16 frames.
            if (first_) age_ = smoothed_;
            step_ = (smoothed_ - age_) / kControlFrames;
        }
        dry_.set(dryTarget_, kControlFrames), wet_.set(wetTarget_, kControlFrames);
        first_ = false;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const lib::grain::Source src = ring_.source(true);
        const double len = ring_.length();
        auto read = [&](double age, float& l, float& r) noexcept {
            double p = static_cast<double>(written_) - age;
            p -= len * std::floor(p / len);
            const auto k = static_cast<uint32_t>(p);
            const float t = static_cast<float>(p - k);
            l = cubic(src.l + k, t), r = cubic(src.r + k, t);
        };
        const double lo = kBase, hi = maxAge_ - 4.0;
        for (uint32_t i = 0; i < n; ++i) {
            const float x = finite0(inL[i]), y = finite0(inR[i]);
            ring_.write(x, y);
            ++written_;
            float wl, wr;
            if (speedMode_) {
                age_ = clampTo(age_ + 1.0 - speed_, lo, hi);
                read(age_, wl, wr);
                if (xf_ > 0) {  // the read before a resync, fading out
                    old_ = clampTo(old_ + 1.0 - speed_, lo, hi);
                    float ol, orr;
                    read(old_, ol, orr);
                    const float g = static_cast<float>(xf_) / kXfade;
                    wl = ol * g + wl * (1.0f - g), wr = orr * g + wr * (1.0f - g);
                    --xf_;
                }
            } else {
                age_ = clampTo(age_ + step_, lo, hi);
                read(age_, wl, wr);
            }
            float dl, dr;
            read(kBase, dl, dr);  // the dry sound as late as the newest read
            const double d = dry_.next(), w = wet_.next();
            outL[i] = static_cast<float>(d * dl + w * wl);
            outR[i] = static_cast<float>(d * dr + w * wr);
        }
    }

    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = speedMode_ ? 1.0f : 0.0f;
        out[3] = static_cast<float>(n_);
        out[4] = static_cast<float>(phase_);
        out[5] = static_cast<float>(1000.0 * age_ / rate());
        out[6] = static_cast<float>(speedMode_ ? speed_ : 1.0 - step_);
        out[7] = static_cast<float>(1000.0 * beats_ * 60.0 / tempo());
        for (uint32_t k = 0; k < kPoints; ++k) out[8 + k] = static_cast<float>(p_[k]);
        // The curve as played (its shape between the points), 64 steps through a cycle.
        for (uint32_t j = 0; j < kShape; ++j) out[8 + kPoints + j] = watched ? static_cast<float>(curve(j / static_cast<double>(kShape))) : 0.0f;
        return 8 + kPoints + kShape;
    }

private:
    static constexpr uint32_t kXfade = 480;
    // The curve at phase 0..1: between point i and the next (the last back to the first).
    double curve(double phase) const noexcept {
        const double x = phase * n_;
        const uint32_t i = std::min<uint32_t>(static_cast<uint32_t>(x), n_ - 1);
        const double f = x - i, a = p_[i], b = p_[(i + 1) % n_];
        if (shape_ == 2) return a;
        if (shape_ == 1) return a + (b - a) * 0.5 * (1.0 - detCos(kPi * f));
        return a + (b - a) * f;
    }
    static float cubic(const float* x, float t) noexcept {
        const float a = x[-1], b = x[0], c = x[1], d = x[2];
        const float c1 = 0.5f * (c - a);
        const float c2 = a - 2.5f * b + 2.0f * c - 0.5f * d;
        const float c3 = 0.5f * (d - a) + 1.5f * (b - c);
        return ((c3 * t + c2) * t + c1) * t + b;
    }

    lib::grain::Ring ring_;
    creative::StepClock clock_;
    Ramp dry_, wet_;
    double knobs_[beCount] = {};
    double p_[kPoints] = {};
    double maxAge_ = 96000, beats_ = 4, depth_ = 1920, range_ = 1, pole_ = 1, phase_ = 0, value_ = 0;
    double age_ = kBase, step_ = 0, smoothed_ = kBase, speed_ = 1, old_ = kBase, dryTarget_ = 0, wetTarget_ = 1;
    uint64_t written_ = 0;
    int64_t lastCycle_ = INT64_MIN;
    uint32_t n_ = 8, xf_ = 0;
    int shape_ = 1;
    bool speedMode_ = false, resync_ = true, first_ = true;
};

ModuleProcessor* makeBend() noexcept { return new (std::nothrow) Bend(); }

using V = std::vector<std::pair<std::string_view, double>>;

// Points p0.. from a list (the rest left at their defaults).
V withPoints(V v, std::initializer_list<double> points) {
    uint32_t k = 0;
    static const char* const ids[] = {"p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9", "p10", "p11", "p12", "p13", "p14", "p15"};
    for (double x : points) v.emplace_back(ids[k++], x);
    return v;
}

}  // namespace

void registerBend(ModuleRegistry& registry) { registry.add(bendDescriptor(), &makeBend); }
size_t bendBytes(double sr) noexcept {
    return sizeof(Bend) + 2 * sizeof(float) * (static_cast<size_t>(std::floor(kMaxAge * sr)) + 67);
}

const std::vector<BuiltinPreset>& bendPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Tape wow", "Lo-fi: a slow, gentle wow over a bar", V{{"depth", 25}}},
        {"Seasick", "Sound design: deep, slow pitch sway over two bars", V{{"depth", 200}, {"cycle", 3}}},
        {"Tape stop", "Sound design: slows to a quarter speed by the bar's end, then snaps back", withPoints({{"mode", 1}, {"range", 2}, {"points", 0}, {"shape", 0}}, {0, -0.3, -0.7, -1})},
        {"Half-time bar", "Drums: the second half of each bar at half speed", withPoints({{"mode", 1}, {"points", 0}, {"shape", 2}}, {0, 0, -1, -1})},
        {"Speed-up riser", "Sound design: speeds up an octave over 4 bars", withPoints({{"mode", 1}, {"cycle", 4}, {"points", 0}, {"shape", 0}, {"resync", 1}}, {0, 0.33, 0.66, 1})},
        {"Quarter wobble", "Bass: a quick wobble on each beat", {{"cycle", 0}, {"depth", 8}}},
        {"Vinyl warp", "Lo-fi: an uneven, warped record", withPoints({{"depth", 18}, {"points", 1}}, {0, 0.8, -0.2, 0.4, -0.9, 0.3, 0.6, -0.5})},
        {"Pitch steps", "Sound design: stepped delay jumps: pitch blips between steps", withPoints({{"depth", 120}, {"shape", 2}, {"smooth", 30}}, {-1, -0.5, 0, 0.5, 1, 0.5, 0, -0.5})},
        {"Chorus drift", "Mixing: a little warped copy under the dry sound", {{"depth", 12}, {"cycle", 1}, {"mix", 0.5}}},
        {"Reverse swoop", "Sound design: the delay falls faster than real time: a backwards swoop", withPoints({{"depth", 900}, {"points", 0}, {"shape", 0}, {"smooth", 5}}, {1, -1, -1, -1})},
    };
    return p;
}

}  // namespace caw::fx
