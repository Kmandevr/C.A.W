// The Delay's 1.1.0 variants: Tape (wow, flutter, saturation and loss per repeat, wear), Reverse and Multi-tap (4 taps on a pattern, pitch and pan each).
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <span>
#include <vector>

#include "caw/library/dynamics.hpp"
#include "caw/library/filter.hpp"
#include "fx_merged.h"
#include "fx_modes_kit.h"
#include "presets.h"
#include "stereo_pair.h"

// Original code (C.A.W. is Apache-2.0), C.A.W's own designs (sound plan 2026-11-19, "New modes in existing
// effects"). Each is a new class appended to org.caw.delay (variants 2, 3 and 4), its own table plus `variant`.
// - Tape: one head per side on a stereo line. The head's time glides (a moved time pitches, as tape does) and is
//   moved by wow (a slow sine and a seeded drift, up to 6 ms) and flutter (two fast sines, up to 0.4 ms), worked out
//   at each 16-frame control point and followed in a straight line between. What the head reads goes through the
//   tape's loss (a low-pass falling from 16 kHz to 1.2 kHz and a high-pass rising to 200 Hz with `loss`) and its
//   saturation (tanh, up to 6x into it, unity gain for a quiet signal so the loop never grows), then wear (a seeded hiss up to -54 dBFS riding on the signal and slow seeded
//   dropouts up to -12 dB), so each repeat is darker, softer and more worn than the last. That is the wet sound and
//   what goes back to the line.
// - Reverse: each side has two read heads half a window apart. A head plays the last window's frames backwards
//   (frame k of its segment is the one written 2k + 1 frames ago), under a Hann window, so the two always sum to
//   one: no clicks at the turn. A new window length is taken by each head when its segment starts. Feedback goes
//   through a low-pass (tone) back into the line, so reversed echoes reverse again.
// - Multi-tap: a mono line read by 4 taps at a pattern's steps of the step time, each with its own level, pan
//   (equal power) and pitch (a two-head delay-line shifter, 60 ms grains, Hann-windowed; an unpitched tap reads
//   once). The taps' sum, normalised by their levels, goes through the tone low-pass back into the line.

namespace caw::fx {

const ModuleDescriptor& delayProDescriptor();  // builtin_effects_space.cpp: the stereo descriptor's ports

namespace {

using modes::Line;

constexpr std::string_view kDelayId = "org.caw.delay";
constexpr std::string_view kDelayName = "Delay";

double clamp01(double x) noexcept { return std::clamp(x, 0.0, 1.0); }

// ---------- Tape ----------

enum TapeParam : uint32_t { kTSync, kTTime, kTFeedback, kTWow, kTFlutter, kTSaturation, kTLoss, kTWear, kTSpread, kTMix, kTCount };
constexpr double kTapeMax = 2.0;          // seconds
constexpr double kWowDepth = 0.006;       // seconds
constexpr double kFlutterDepth = 0.0004;  // seconds
constexpr double kTapeMinBack = 2.0 + EffectBase::kControlFrames;  // frames (the shortest time is far longer)

const ParamTable& tapeParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("sync", "Sync", 7.0, kSyncDivisions);  // 1/8 dotted
        p.expo("time", "Time (free)", 375.0, 20.0, 2000.0, "ms");
        p.num("feedback", "Feedback", 0.45, 0.0, 1.0);
        p.num("wow", "Wow", 0.25, 0.0, 1.0);
        p.num("flutter", "Flutter", 0.15, 0.0, 1.0);
        p.num("saturation", "Saturation", 0.3, 0.0, 1.0);
        p.num("loss", "Loss", 0.35, 0.0, 1.0);
        p.num("wear", "Wear", 0.15, 0.0, 1.0);
        p.num("spread", "Spread", 0.3, 0.0, 1.0);
        p.num("mix", "Mix", 0.3, 0.0, 1.0);
        return p;
    }();
    return t;
}

class TapeDelay : public EffectBase {
public:
    explicit TapeDelay(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        const size_t need = static_cast<size_t>((kTapeMax * 1.08 + kWowDepth + 0.01) * sr);
        if (!line_[0].prepare(need) || !line_[1].prepare(need)) return false;
        glide_ = 1.0 - detExp(-1.0 / (0.08 * sr));
        driftK_ = lib::timeCoefficient(0.15, sr / kControlFrames);
        dropK_ = lib::timeCoefficient(0.04, sr);
        envK_ = lib::timeCoefficient(0.2, sr);
        return true;
    }
    void clearState() noexcept override {
        for (auto& l : line_) l.clear();
        for (int c = 0; c < 2; ++c) low_[c].clear(), high_[c].clear(), mod_[c].reset(), drop_[c].y = 1.0;
        seconds_[0] = seconds_[1] = -1.0;
        wowPhase_ = flutterPhase_ = 0.0;
        drift_.y = 0.0;
        driftTarget_ = 0.0;
        driftLeft_ = 0;
        noise_.seed = 0x7a9e;
        dropNoise_.seed = 0x51d3;
        hiss_[0].seed = 0x1234, hiss_[1].seed = 0x9876;
        env_[0] = env_[1] = 0.0;
        dropTarget_[0] = dropTarget_[1] = 1.0;
        mix_.reset();
        feedback_.reset();
        wetPeak_ = 0.0;
    }
    uint64_t idleFrames() const noexcept override {
        return static_cast<uint64_t>((std::max(target_[0], target_[1]) + kWowDepth + 0.05) * rate());
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const int sync = choice(kTSync, at);
        const double base = std::clamp(sync > 0 ? syncSeconds(sync) : param(kTTime, at) * 0.001, 0.005, kTapeMax);
        spread_ = clamp01(param(kTSpread, at));
        target_[0] = base;
        target_[1] = base * (1.0 + 0.08 * spread_);
        feedback_.set(clamp01(param(kTFeedback, at)), kControlFrames);
        wow_ = clamp01(param(kTWow, at));
        flutter_ = clamp01(param(kTFlutter, at));
        const double sat = clamp01(param(kTSaturation, at));
        satK_ = 1.0 + 5.0 * sat;
        satInv_ = 1.0 / satK_;  // unity for quiet signals: the loop's gain never rises above the feedback
        satMix_ = std::min(1.0, 4.0 * sat);
        loss_ = clamp01(param(kTLoss, at));
        const double lowpass = 16000.0 * detPow(2.0, -loss_ * 3.74);  // 16 kHz .. 1.2 kHz
        const double highpass = 30.0 + 170.0 * loss_;
        for (int c = 0; c < 2; ++c) low_[c].set(lowpass, 0.6, sr), high_[c].set(highpass, 0.6, sr);
        wear_ = clamp01(param(kTWear, at));
        hissLevel_ = wear_ * 0.002;
        mix_.set(clamp01(param(kTMix, at)), kControlFrames);
        // Wow and flutter: phases advanced by the grid step, a drift toward a new seeded target every 250 ms.
        wowPhase_ += kControlFrames * 0.55 / sr;
        wowPhase_ -= std::floor(wowPhase_);
        flutterPhase_ += kControlFrames * 7.3 / sr;
        flutterPhase_ -= std::floor(flutterPhase_);
        if (driftLeft_ == 0) {
            driftTarget_ = noise_.next();
            driftLeft_ = static_cast<uint32_t>(0.25 * sr / kControlFrames) + 1;
        }
        --driftLeft_;
        const double drift = drift_.next(driftTarget_, driftK_);
        for (int c = 0; c < 2; ++c) {
            const double off = c == 1 ? 0.25 * spread_ : 0.0;  // the right side's own phase
            const double w = kWowDepth * wow_ * (0.5 + 0.5 * (0.7 * lib::fastSinCycles(wowPhase_ + off) + 0.3 * drift));
            const double f = kFlutterDepth * flutter_ *
                             (0.5 + 0.35 * lib::fastSinCycles(flutterPhase_ + off) + 0.15 * lib::fastSinCycles(1.63 * flutterPhase_));
            mod_[c].set((w + f) * sr, kControlFrames);
            // Dropouts: now and then (more often with wear) the level dips for a moment.
            const double r = dropNoise_.next();
            if (r > 1.0 - 0.02 * wear_) dropTarget_[c] = 1.0 - 0.75 * wear_ * (0.5 + 0.5 * dropNoise_.next());
            else if (r < -0.9) dropTarget_[c] = 1.0;
        }
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        // The heads' reads first (the shortest time is 5 ms, so nothing read is written in this run), then both
        // sides as one two-wide vector (stereo_pair.h): the loss filters and the saturation; then the writes.
        const double sr = rate();
        double rd[2][kControlFrames];
        for (int c = 0; c < 2; ++c) {
            if (seconds_[c] < 0.0) seconds_[c] = target_[c];
            double sec = seconds_[c];
            const double target = target_[c];
            for (uint32_t i = 0; i < n; ++i) {
                sec += (target - sec) * glide_;
                rd[c][i] = line_[c].hermite(std::max(kTapeMinBack, sec * sr + mod_[c].next()) - i);
            }
            seconds_[c] = std::fabs(sec - target) < 1e-12 ? target : sec;
        }
        const Pair two = splat(2.0), satK = splat(satK_), satInv = splat(satInv_), satMix = splat(satMix_);
        const Pair la1 = splat(low_[0].a1()), la2 = splat(low_[0].a2()), la3 = splat(low_[0].a3());
        const Pair ha1 = splat(high_[0].a1()), ha2 = splat(high_[0].a2()), ha3 = splat(high_[0].a3()), hk = splat(high_[0].k());
        Pair l1 = pairOf(low_[0].ic1(), low_[1].ic1()), l2 = pairOf(low_[0].ic2(), low_[1].ic2());
        Pair h1 = pairOf(high_[0].ic1(), high_[1].ic1()), h2 = pairOf(high_[0].ic2(), high_[1].ic2());
        double feed[2][kControlFrames];
        for (uint32_t i = 0; i < n; ++i) {
            Pair y = pairOf(rd[0][i], rd[1][i]), v1, v2;
            lib::Svf::step(y, l1, l2, la1, la2, la3, two, v1, v2);
            y = v2;  // the loss low-pass
            lib::Svf::step(y, h1, h2, ha1, ha2, ha3, two, v1, v2);
            y = y - hk * v1 - v2;  // and high-pass
            y = y + (tanhApproxPair(y * satK) * satInv - y) * satMix;
            const double fb = feedback_.next(), m = mix_.next();
            const double x[2] = {inL[i], inR[i]};
            double o[2];
            for (int c = 0; c < 2; ++c) {
                // The hiss rides on the tape's signal (a follower of it), so a silent tape is silent and sleeps;
                // each side has its own noise.
                double v = lane(y, c);
                const double a = v < 0 ? -v : v;
                env_[c] = modes::flush(a > env_[c] ? a : env_[c] * envK_);
                v = v * drop_[c].next(dropTarget_[c], dropK_) + hissLevel_ * std::min(1.0, 8.0 * env_[c]) * hiss_[c].next();
                const double av = v < 0 ? -v : v;
                wetPeak_ = av > wetPeak_ ? av : wetPeak_;
                feed[c][i] = x[c] + v * fb;
                o[c] = x[c] + (v - x[c]) * m;
            }
            outL[i] = static_cast<float>(o[0]);
            outR[i] = static_cast<float>(o[1]);
        }
        for (int c = 0; c < 2; ++c)
            for (uint32_t i = 0; i < n; ++i) line_[c].write(feed[c][i]);
        l1 = flushPair(l1), l2 = flushPair(l2), h1 = flushPair(h1), h2 = flushPair(h2);
        low_[0].setState(lane(l1, 0), lane(l2, 0)), low_[1].setState(lane(l1, 1), lane(l2, 1));
        high_[0].setState(lane(h1, 0), lane(h2, 0)), high_[1].setState(lane(h1, 1), lane(h2, 1));
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = static_cast<float>(lib::gainToDb(wetPeak_));
        out[2] = outPeakDb();
        out[3] = static_cast<float>(seconds_[0] < 0 ? target_[0] : seconds_[0]);
        out[4] = static_cast<float>(seconds_[1] < 0 ? target_[1] : seconds_[1]);
        out[5] = static_cast<float>(feedback_.value);
        out[6] = static_cast<float>(mod_[0].value / rate() * 1000.0);  // the left head's wow and flutter now, ms
        out[7] = static_cast<float>(wow_);
        out[8] = static_cast<float>(flutter_);
        out[9] = static_cast<float>(satMix_);
        out[10] = static_cast<float>(loss_);
        out[11] = static_cast<float>(wear_);
        out[12] = static_cast<float>(drop_[0].y);  // the left side's dropout gain now (1: none)
        wetPeak_ = 0.0;
        return 13;
    }

private:
    const ModuleDescriptor& d_;
    Line line_[2];
    lib::Svf low_[2], high_[2];
    Ramp mod_[2], mix_, feedback_;
    modes::Smooth drift_, drop_[2];
    modes::Noise noise_, dropNoise_, hiss_[2];
    double seconds_[2] = {-1, -1}, target_[2] = {0.375, 0.375};
    double glide_ = 0, driftK_ = 0, dropK_ = 0, driftTarget_ = 0, dropTarget_[2] = {1, 1};
    uint32_t driftLeft_ = 0;
    double wowPhase_ = 0, flutterPhase_ = 0, wow_ = 0, flutter_ = 0, spread_ = 0;
    double satK_ = 1, satInv_ = 1, satMix_ = 0, loss_ = 0, wear_ = 0, hissLevel_ = 0, env_[2] = {0, 0}, envK_ = 0;
    double wetPeak_ = 0;
};

// ---------- Reverse ----------

enum ReverseParam : uint32_t { kRSync, kRTime, kRFeedback, kRTone, kRSpread, kRMix, kRCount };
constexpr double kReverseMax = 2.0;  // seconds of window

const ParamTable& reverseParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("sync", "Sync", 9.0, kSyncDivisions);  // 1/4
        p.expo("time", "Time (free)", 500.0, 30.0, 2000.0, "ms");
        p.num("feedback", "Feedback", 0.3, 0.0, 0.95);
        p.expo("tone", "Tone", 12000.0, 500.0, 20000.0, "Hz");
        p.num("spread", "Spread", 0.0, 0.0, 0.5);
        p.num("mix", "Mix", 0.5, 0.0, 1.0);
        return p;
    }();
    return t;
}

class ReverseDelay : public EffectBase {
public:
    explicit ReverseDelay(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        const size_t need = static_cast<size_t>(2.0 * kReverseMax * sr) + 16;
        return line_[0].prepare(need) && line_[1].prepare(need);
    }
    void clearState() noexcept override {
        for (auto& l : line_) l.clear();
        for (auto& t : tone_) t.clear();
        started_ = false;
        mix_.reset();
        wetPeak_ = 0.0;
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>(2.0 * len_ + 0.05 * rate()); }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const int sync = choice(kRSync, at);
        const double s = std::clamp(sync > 0 ? syncSeconds(sync) : param(kRTime, at) * 0.001, 0.03, kReverseMax);
        len_ = std::max<uint32_t>(64, static_cast<uint32_t>(s * sr + 0.5));
        feedback_ = std::clamp(param(kRFeedback, at), 0.0, 0.95);
        spread_ = std::clamp(param(kRSpread, at), 0.0, 0.5);
        for (auto& t : tone_) t.set(param(kRTone, at), 0.70710678118654752, sr);  // at its top it is all but open
        mix_.set(clamp01(param(kRMix, at)), kControlFrames);
        if (!started_) {  // each side's two heads, half a window apart (the right side `spread` later)
            for (int c = 0; c < 2; ++c) {
                const uint32_t off = static_cast<uint32_t>((c == 1 ? spread_ : 0.0) * len_);
                for (int h = 0; h < 2; ++h) {
                    Head& head = heads_[c][h];
                    head.len = len_;
                    head.k = (off + (h == 1 ? len_ / 2 : 0)) % len_;
                }
            }
            started_ = true;
        }
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const float* in[2] = {inL, inR};
        float* out[2] = {outL, outR};
        double mix[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) mix[i] = mix_.next();
        for (int c = 0; c < 2; ++c) {
            Line& line = line_[c];
            for (uint32_t i = 0; i < n; ++i) {
                const double x = in[c][i];
                double y = 0.0;
                for (Head& h : heads_[c]) {
                    const double w = modes::hann(static_cast<double>(h.k) / static_cast<double>(h.len));
                    y += w * line.at(2 * static_cast<size_t>(h.k) + 1);
                    if (++h.k >= h.len) h.k = 0, h.len = len_;  // a new segment takes the window length now
                }
                const double fed = tone_[c].lowpass(y);
                line.write(x + fed * feedback_);
                const double a = y < 0 ? -y : y;
                wetPeak_ = a > wetPeak_ ? a : wetPeak_;
                out[c][i] = static_cast<float>(x + (y - x) * mix[i]);
            }
            tone_[c].flushDenormals();
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = static_cast<float>(lib::gainToDb(wetPeak_));
        out[2] = outPeakDb();
        out[3] = static_cast<float>(len_ / rate());                                           // window s
        out[4] = static_cast<float>(static_cast<double>(heads_[0][0].k) / heads_[0][0].len);  // head A's place 0..1
        out[5] = static_cast<float>(static_cast<double>(heads_[0][1].k) / heads_[0][1].len);  // head B's
        out[6] = static_cast<float>(feedback_);
        out[7] = static_cast<float>(spread_);
        wetPeak_ = 0.0;
        return 8;
    }

private:
    struct Head {
        uint32_t k = 0, len = 1;
    };
    const ModuleDescriptor& d_;
    Line line_[2];
    Head heads_[2][2];
    lib::Svf tone_[2];
    Ramp mix_;
    uint32_t len_ = 24000;
    double feedback_ = 0, spread_ = 0, wetPeak_ = 0;
    bool started_ = false;
};

// ---------- Multi-tap ----------

constexpr int kTaps = 4;
constexpr std::string_view kPatterns[] = {"Straight", "Dotted", "Triplet", "Swing", "Gallop", "Cascade"};
constexpr double kPatternSteps[][kTaps] = {
    {1, 2, 3, 4}, {1.5, 3, 4.5, 6}, {2.0 / 3, 4.0 / 3, 2, 8.0 / 3}, {1, 5.0 / 3, 3, 11.0 / 3}, {1, 1.5, 2, 3}, {0.25, 0.5, 1, 2}};
constexpr double kMultiMax = 5.0;  // seconds: the longest tap (a 1 s step's 5th; 1 MB at 48 kHz)
constexpr double kGrain = 0.06;    // seconds: a pitched tap's grain
constexpr double kMinBack = EffectBase::kControlFrames + 2.0;  // frames: a tap never reads what this run writes
enum MultiParam : uint32_t { kMSync, kMTime, kMPattern, kMFeedback, kMTone, kMTap0, kMMix = kMTap0 + 3 * kTaps, kMCount };

const ParamTable& multiParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("sync", "Sync", 6.0, kSyncDivisions);  // 1/8
        p.expo("time", "Step (free)", 250.0, 10.0, 1000.0, "ms");
        p.pick("pattern", "Pattern", 0.0, kPatterns);
        p.num("feedback", "Feedback", 0.25, 0.0, 0.95);
        p.expo("tone", "Tone", 9000.0, 500.0, 20000.0, "Hz");
        constexpr double levels[kTaps] = {0.8, 0.6, 0.45, 0.3}, pans[kTaps] = {-0.6, 0.6, -0.3, 0.3};
        for (int k = 0; k < kTaps; ++k) {
            const std::string id = "t" + std::to_string(k + 1) + "_", name = "Tap " + std::to_string(k + 1) + " ";
            p.num(id + "level", name + "level", levels[k], 0.0, 1.0);
            p.num(id + "pan", name + "pan", pans[k], -1.0, 1.0);
            p.num(id + "pitch", name + "pitch", 0.0, -12.0, 12.0, "st");
        }
        p.num("mix", "Mix", 0.35, 0.0, 1.0);
        return p;
    }();
    return t;
}

class MultiTapDelay : public EffectBase {
public:
    explicit MultiTapDelay(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        return line_.prepare(static_cast<size_t>((kMultiMax + kGrain) * sr) + 16);
    }
    void clearState() noexcept override {
        line_.clear();
        tone_.clear();
        for (Tap& t : taps_) t.phase = 0.0, t.level.reset(), t.peak = 0.0, t.back = -1.0;
        mix_.reset();
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>((longest_ + kGrain + 0.05) * rate()); }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const int sync = choice(kMSync, at);
        step_ = std::max(0.001, sync > 0 ? syncSeconds(sync) : param(kMTime, at) * 0.001);
        pattern_ = std::clamp(choice(kMPattern, at), 0, static_cast<int>(std::size(kPatterns)) - 1);
        feedback_ = std::clamp(param(kMFeedback, at), 0.0, 0.95);
        tone_.set(param(kMTone, at), 0.70710678118654752, sr);  // at its top it is all but open
        double sum = 0.0;
        longest_ = 0.0;
        for (int k = 0; k < kTaps; ++k) {
            Tap& t = taps_[k];
            const uint32_t base = kMTap0 + 3 * k;
            const double level = clamp01(param(base, at));
            sum += level;
            t.level.set(level, kControlFrames);
            modes::panGains(param(base + 1, at), t.gl, t.gr);
            t.pitch = std::clamp(param(base + 2, at), -12.0, 12.0);
            t.shifted = std::fabs(t.pitch) > 1e-3;
            // The phase step of a two-head shifter: the read moves at 2^(pitch / 12) of the write's speed.
            t.dphase = (1.0 - detPow(2.0, t.pitch / 12.0)) / (kGrain * sr);
            t.seconds = std::min(kMultiMax, step_ * kPatternSteps[pattern_][k]);
            longest_ = std::max(longest_, t.seconds);
        }
        fbNorm_ = feedback_ / std::max(1.0, sum);
        mix_.set(clamp01(param(kMMix, at)), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        // Tap by tap over the run (each tap's path chosen once, a silent tap skipped), then the line is written:
        // every tap reads at least kMinBack frames back, so nothing it reads is written in this run.
        const double sr = rate(), grain = kGrain * sr;
        double wl[kControlFrames] = {}, wr[kControlFrames] = {}, sum[kControlFrames] = {};
        for (Tap& t : taps_) {
            if (t.back < 0.0) t.back = t.seconds * sr;
            if (t.level.value == 0.0 && t.level.step == 0.0) continue;  // off: costs nothing
            const double target = t.seconds * sr;
            for (uint32_t i = 0; i < n; ++i) {
                t.back += (target - t.back) * 0.0005;  // a moved time glides (about 40 ms)
                double y;
                if (!t.shifted) {
                    y = line_.hermite(std::max(kMinBack, t.back) - i);
                } else {
                    const double d = std::max(kMinBack, t.back - 0.5 * grain) - i;
                    double p2 = t.phase + 0.5;
                    p2 -= p2 >= 1.0 ? 1.0 : 0.0;
                    y = modes::hann(t.phase) * line_.linear(d + grain * t.phase) + modes::hann(p2) * line_.linear(d + grain * p2);
                    t.phase += t.dphase;
                    t.phase -= std::floor(t.phase);
                }
                y *= t.level.next();
                const double a = y < 0 ? -y : y;
                t.peak = a > t.peak ? a : t.peak;
                sum[i] += y;
                wl[i] += y * t.gl;
                wr[i] += y * t.gr;
            }
        }
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = inL[i], xr = inR[i];
            line_.write(0.5 * (xl + xr) + tone_.lowpass(sum[i]) * fbNorm_);
            const double m = mix_.next();
            outL[i] = static_cast<float>(xl + (wl[i] - xl) * m);
            outR[i] = static_cast<float>(xr + (wr[i] - xr) * m);
        }
        tone_.flushDenormals();
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(step_);
        out[3] = static_cast<float>(pattern_);
        out[4] = static_cast<float>(feedback_);
        for (int k = 0; k < kTaps; ++k) {  // per tap from 5: time s, level, pan (-1..1), pitch st, peak dB
            Tap& t = taps_[k];
            float* o = out + 5 + 5 * k;
            o[0] = static_cast<float>(t.seconds);
            o[1] = static_cast<float>(t.level.value);
            o[2] = static_cast<float>(t.gr * t.gr - t.gl * t.gl);  // equal-power gains back to -1..1-ish
            o[3] = static_cast<float>(t.pitch);
            o[4] = static_cast<float>(lib::gainToDb(t.peak));
            t.peak = 0.0;
        }
        return 5 + 5 * kTaps;
    }

private:
    struct Tap {
        double seconds = 0.25, back = -1, phase = 0, dphase = 0, pitch = 0, gl = 0.7, gr = 0.7, peak = 0;
        bool shifted = false;
        Ramp level;
    };
    const ModuleDescriptor& d_;
    Line line_;
    lib::Svf tone_;
    Tap taps_[kTaps];
    Ramp mix_;
    double step_ = 0.25, feedback_ = 0, fbNorm_ = 0, longest_ = 1.0;
    int pattern_ = 0;
};

// ---------- Descriptors, factories and presets ----------

const ModuleDescriptor& base(const ParamTable& t) {
    // The stereo effect's ports, latency 0 and an infinite tail, as the Digital delay's.
    static std::deque<ModuleDescriptor> made;
    ModuleDescriptor& d = made.emplace_back(effectDescriptor(kDelayId, kDelayName, t, 0, kInfiniteTail));
    return d;
}

using V = std::vector<std::pair<std::string_view, double>>;
BuiltinPreset preset(const char* name, const char* description, V values, double variant) {
    values.emplace_back("variant", variant);
    return {name, description, std::move(values)};
}

const std::vector<BuiltinPreset>& presets() {
    static const std::vector<BuiltinPreset> p = {
        // Tape (variant 2)
        preset("Tape slapback", "Vocals: one short, warm repeat under the voice",
               {{"sync", 0}, {"time", 110}, {"feedback", 0.1}, {"wow", 0.15}, {"flutter", 0.2}, {"saturation", 0.35}, {"loss", 0.3}, {"wear", 0.1}, {"mix", 0.3}}, 2),
        preset("Space echo", "Guitar: long, dark repeats that wander and smear",
               {{"sync", 7}, {"feedback", 0.62}, {"wow", 0.45}, {"flutter", 0.3}, {"saturation", 0.5}, {"loss", 0.55}, {"wear", 0.3}, {"spread", 0.5}, {"mix", 0.35}}, 2),
        preset("Worn cassette", "Lo-fi: a wobbly, hissy echo with dropouts",
               {{"sync", 6}, {"feedback", 0.4}, {"wow", 0.8}, {"flutter", 0.6}, {"saturation", 0.4}, {"loss", 0.75}, {"wear", 0.85}, {"mix", 0.4}}, 2),
        preset("Dub siren feedback", "Sound design: repeats that build and break up",
               {{"sync", 9}, {"feedback", 0.92}, {"wow", 0.3}, {"flutter", 0.2}, {"saturation", 0.8}, {"loss", 0.5}, {"wear", 0.2}, {"spread", 0.7}, {"mix", 0.45}}, 2),
        preset("Vintage vocal echo", "Vocals: a quarter-note echo, softened each time round",
               {{"sync", 9}, {"feedback", 0.3}, {"wow", 0.2}, {"flutter", 0.15}, {"saturation", 0.25}, {"loss", 0.45}, {"wear", 0.1}, {"mix", 0.22}}, 2),
        preset("Drum tape room", "Drums: a short, saturated doubling that thickens hits",
               {{"sync", 0}, {"time", 45}, {"feedback", 0.25}, {"wow", 0.05}, {"flutter", 0.1}, {"saturation", 0.7}, {"loss", 0.25}, {"wear", 0.05}, {"mix", 0.25}}, 2),
        preset("Bass tape thump", "Bass: a dark eighth repeat that stays under the part",
               {{"sync", 6}, {"feedback", 0.2}, {"wow", 0.1}, {"flutter", 0.05}, {"saturation", 0.45}, {"loss", 0.8}, {"wear", 0.05}, {"spread", 0}, {"mix", 0.2}}, 2),
        preset("Warped mix bus", "Mixing: a faint, wide tape wash behind the whole mix",
               {{"sync", 12}, {"feedback", 0.35}, {"wow", 0.35}, {"flutter", 0.2}, {"saturation", 0.2}, {"loss", 0.6}, {"wear", 0.25}, {"spread", 1}, {"mix", 0.12}}, 2),
        // Reverse (variant 3)
        preset("Reverse swell", "Guitar: each phrase comes back backwards, rising into the next",
               {{"sync", 9}, {"feedback", 0.25}, {"tone", 9000}, {"mix", 0.45}}, 3),
        preset("Backwards vocal", "Vocals: a half-bar reversed echo behind the voice",
               {{"sync", 12}, {"feedback", 0.15}, {"tone", 7000}, {"spread", 0.25}, {"mix", 0.35}}, 3),
        preset("Reverse drums", "Drums: hits played backwards into the beat, an eighth at a time",
               {{"sync", 6}, {"feedback", 0}, {"tone", 14000}, {"mix", 0.4}}, 3),
        preset("Bar-long reverse", "Sound design: a whole bar flipped, rising into the downbeat",
               {{"sync", 14}, {"feedback", 0.2}, {"tone", 8000}, {"mix", 0.5}}, 3),
        preset("Reverse wash", "Sound design: reversed echoes of reversed echoes, a dark swirl",
               {{"sync", 9}, {"feedback", 0.7}, {"tone", 4000}, {"spread", 0.5}, {"mix", 0.5}}, 3),
        preset("Wide reverse", "Mixing: each side reversed half a window apart, very wide",
               {{"sync", 9}, {"feedback", 0.2}, {"tone", 10000}, {"spread", 0.5}, {"mix", 0.3}}, 3),
        preset("Lo-fi reverse", "Lo-fi: a muffled backwards echo",
               {{"sync", 9}, {"feedback", 0.35}, {"tone", 1800}, {"mix", 0.45}}, 3),
        preset("Bass reverse sixteenths", "Bass: short reversed snippets, felt more than heard",
               {{"sync", 3}, {"feedback", 0}, {"tone", 3000}, {"mix", 0.25}}, 3),
        // Multi-tap (variant 4)
        preset("Rhythm taps", "Drums: four straight eighths, spread across the stereo field",
               {{"sync", 6}, {"pattern", 0}, {"feedback", 0.2}, {"mix", 0.3}}, 4),
        preset("Dotted gallop", "Guitar: the dotted-eighth figure that fills a riff",
               {{"sync", 6}, {"pattern", 1}, {"feedback", 0.35}, {"t1_pan", -0.8}, {"t2_pan", 0.8}, {"mix", 0.35}}, 4),
        preset("Shimmer taps", "Sound design: taps climbing an octave and a fifth",
               {{"sync", 6}, {"pattern", 4}, {"feedback", 0.45}, {"t2_pitch", 7}, {"t3_pitch", 12}, {"t4_pitch", 12}, {"tone", 12000}, {"mix", 0.4}}, 4),
        preset("Swing echoes", "Mixing: swung taps that sit a groove behind the part",
               {{"sync", 9}, {"pattern", 3}, {"feedback", 0.2}, {"t1_level", 0.6}, {"t2_level", 0.4}, {"mix", 0.25}}, 4),
        preset("Octave down cascade", "Bass: accelerating taps, the last ones an octave under",
               {{"sync", 9}, {"pattern", 5}, {"feedback", 0.1}, {"t3_pitch", -12}, {"t4_pitch", -12}, {"tone", 5000}, {"mix", 0.3}}, 4),
        preset("Vocal throw taps", "Vocals: triplet taps that fade away across the sides",
               {{"sync", 9}, {"pattern", 2}, {"feedback", 0.15}, {"t1_level", 0.6}, {"t2_level", 0.45}, {"t3_level", 0.3}, {"t4_level", 0.2}, {"mix", 0.3}}, 4),
        preset("Lo-fi detune taps", "Lo-fi: slightly sharp and flat taps, a wobbly smear",
               {{"sync", 6}, {"pattern", 0}, {"feedback", 0.3}, {"t1_pitch", 0.3}, {"t2_pitch", -0.3}, {"t3_pitch", 0.5}, {"t4_pitch", -0.5}, {"tone", 4000}, {"mix", 0.35}}, 4),
        preset("Wide mix taps", "Mixing: two quiet taps hard left and right for width",
               {{"sync", 3}, {"pattern", 0}, {"feedback", 0}, {"t1_level", 0.35}, {"t1_pan", -1}, {"t2_level", 0.35}, {"t2_pan", 1}, {"t3_level", 0}, {"t4_level", 0}, {"mix", 0.3}}, 4),
    };
    return p;
}

const ModuleDescriptor& tapeBase() {
    static const ModuleDescriptor& d = base(tapeParams());
    return d;
}
const ModuleDescriptor& reverseBase() {
    static const ModuleDescriptor& d = base(reverseParams());
    return d;
}
const ModuleDescriptor& multiBase() {
    static const ModuleDescriptor& d = base(multiParams());
    return d;
}

}  // namespace

// Each mode's descriptor: its table and `variant` (labels the device's whole list, `index` its place).
const ModuleDescriptor& tapeDelayDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(tapeBase(), kDelayId, kDelayName, labels, index);
    return d;
}
const ModuleDescriptor& reverseDelayDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(reverseBase(), kDelayId, kDelayName, labels, index);
    return d;
}
const ModuleDescriptor& multiTapDelayDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(multiBase(), kDelayId, kDelayName, labels, index);
    return d;
}
ModuleProcessor* makeTapeDelayAs(const ModuleDescriptor& v) noexcept { return new (std::nothrow) TapeDelay(v); }
ModuleProcessor* makeReverseDelayAs(const ModuleDescriptor& v) noexcept { return new (std::nothrow) ReverseDelay(v); }
ModuleProcessor* makeMultiTapDelayAs(const ModuleDescriptor& v) noexcept { return new (std::nothrow) MultiTapDelay(v); }
std::span<const BuiltinPreset> delayModePresets() { return presets(); }

}  // namespace caw::fx
