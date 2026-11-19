// The Reverb's 1.1.0 variants: Room (early reflections and a small tail), Plate (a figure-eight tank), Spring (a dispersive loop), Gated and Reverse.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <deque>
#include <new>
#include <span>
#include <vector>

#include "caw/library/dynamics.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/reverb.hpp"
#include "fx_merged.h"
#include "fx_modes_kit.h"
#include "presets.h"
#include "stereo_pair.h"

// Original code (C.A.W. is Apache-2.0), C.A.W's own designs (sound plan 2026-11-19, "New modes in existing
// effects"), appended to org.caw.reverb as variants 2..6, each its own table plus `variant`:
// - Room: 8 early reflections per side (a tapped line, times and signs C.A.W's own, scaled by size, falling 0.8 per
//   tap) and the Library's 8-line network (caw/library/reverb.hpp) at a small size for the tail.
// - Plate: a figure-eight tank in the plate-reverb family described in the literature (Dattorro, "Effect Design
//   Part 1", JAES 1997: an input diffuser, then two halves of modulated all-pass, delay, damping, all-pass, delay,
//   each feeding the other); C.A.W's own output taps. Lengths scaled from 29761 Hz to the rate.
// - Spring: per side a loop of a delay (its length), 12 first-order all-passes (the dispersion that makes a spring's
//   chirp; `tension` sets their coefficient) and a low-pass (tone), decaying by its RT60; the sides differ in length.
// - Gated: the Library's network, dense and long, through a gate that opens when the input passes `threshold`,
//   holds `hold` after the input falls under it, then closes over `release` (the 1980s drum sound).
// - Reverse: a swell. The input is diffused (2 all-passes), then 24 taps per side spread over `length` with gains
//   rising toward the longest (`curve` from linear to steep), then diffused again, so the sound builds and stops.
// Each sums its wet with low and high cuts and a width (mid/side) and mixes with the dry.

namespace caw::fx {

namespace {

using modes::Allpass;
using modes::Line;

constexpr std::string_view kReverbId = "org.caw.reverb";
constexpr std::string_view kReverbName = "Reverb";
constexpr double kSqrtHalf = 0.70710678118654752;

double clamp01(double x) noexcept { return std::clamp(x, 0.0, 1.0); }

// What every mode does after its wet: low and high cuts, width (mid/side), the mix ramp and the peaks.
struct WetOut {
    lib::Svf low[2], high[2];
    Ramp mix;
    double width = 1.0, wetPeak = 0.0;
    void set(double lowCut, double highCut, double w, double m, double sr) noexcept {
        for (int c = 0; c < 2; ++c) low[c].set(lowCut, kSqrtHalf, sr), high[c].set(highCut, kSqrtHalf, sr);
        width = std::clamp(w, 0.0, 2.0);
        mix.set(clamp01(m), EffectBase::kControlFrames);
    }
    void clear() noexcept {
        for (int c = 0; c < 2; ++c) low[c].clear(), high[c].clear();
        mix.reset();
        wetPeak = 0.0;
    }
    // wl, wr: the wet of run()'s n frames (finite); writes the output. Both sides as one two-wide vector
    // (stereo_pair.h): the low cut's and high cut's state-variable steps, the width and the mix.
    void finish(const float* inL, const float* inR, const double* wl, const double* wr, float* outL, float* outR,
                uint32_t n) noexcept {
        const Pair two = splat(2.0), la1 = splat(low[0].a1()), la2 = splat(low[0].a2()), la3 = splat(low[0].a3());
        const Pair lk = splat(low[0].k()), ha1 = splat(high[0].a1()), ha2 = splat(high[0].a2()), ha3 = splat(high[0].a3());
        Pair l1 = pairOf(low[0].ic1(), low[1].ic1()), l2 = pairOf(low[0].ic2(), low[1].ic2());
        Pair h1 = pairOf(high[0].ic1(), high[1].ic1()), h2 = pairOf(high[0].ic2(), high[1].ic2());
        const double side = 0.5 * width;
        Pair most = splat(wetPeak);
        for (uint32_t i = 0; i < n; ++i) {
            Pair x = pairOf(wl[i], wr[i]), v1, v2;
            lib::Svf::step(x, l1, l2, la1, la2, la3, two, v1, v2);
            x = x - lk * v1 - v2;  // the high-pass
            lib::Svf::step(x, h1, h2, ha1, ha2, ha3, two, v1, v2);
            const double l = lane(v2, 0), r = lane(v2, 1);
            const double mid = 0.5 * (l + r), s = (l - r) * side;
            const Pair w = pairOf(mid + s, mid - s);
            most = pairMax(most, pairAbs(w));
            const double m = mix.next(), xl = inL[i], xr = inR[i];
            outL[i] = static_cast<float>(xl + (lane(w, 0) - xl) * m);
            outR[i] = static_cast<float>(xr + (lane(w, 1) - xr) * m);
        }
        l1 = flushPair(l1), l2 = flushPair(l2), h1 = flushPair(h1), h2 = flushPair(h2);
        low[0].setState(lane(l1, 0), lane(l2, 0)), low[1].setState(lane(l1, 1), lane(l2, 1));
        high[0].setState(lane(h1, 0), lane(h2, 0)), high[1].setState(lane(h1, 1), lane(h2, 1));
        wetPeak = std::max(lane(most, 0), lane(most, 1));
    }
};

// The shared tail parameters: added to each table in this order after the mode's own.
void addOutput(ParamTable& p, double lowCut, double highCut, double width, double mix) {
    p.expo("low_cut", "Low cut", lowCut, 20.0, 2000.0, "Hz");
    p.expo("high_cut", "High cut", highCut, 1000.0, 20000.0, "Hz");
    p.num("width", "Width", width, 0.0, 2.0);
    p.num("mix", "Mix", mix, 0.0, 1.0);
}

class ReverbMode : public EffectBase {
public:
    explicit ReverbMode(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    // The output parameters' first index (the mode's own come before).
    void controlOutput(uint32_t first, uint32_t at) noexcept {
        out_.set(param(first, at), param(first + 1, at), param(first + 2, at), param(first + 3, at), rate());
    }
    void clearOutput() noexcept { out_.clear(); }
    void outputDisplay(float* out) noexcept {
        out[0] = inPeakDb();
        out[1] = static_cast<float>(lib::gainToDb(out_.wetPeak));
        out[2] = outPeakDb();
        out_.wetPeak = 0.0;
    }
    WetOut out_;

private:
    const ModuleDescriptor& d_;
};

// ---------- Room ----------

enum RoomParam : uint32_t { kRoSize, kRoDecay, kRoEarly, kRoDamping, kRoPreDelay, kRoOut, kRoCount = kRoOut + 4 };
constexpr int kEarly = 8;
constexpr double kEarlyMs[2][kEarly] = {{4.3, 7.9, 11.2, 15.7, 19.1, 23.8, 29.3, 34.6}, {5.1, 8.6, 12.9, 16.4, 21.2, 25.5, 31.0, 36.7}};
constexpr double kEarlySign[2][kEarly] = {{1, -1, 1, 1, -1, 1, -1, 1}, {-1, 1, 1, -1, 1, -1, 1, 1}};
constexpr double kMaxEarlyScale = 2.0, kMaxRoomPre = 0.2;

const ParamTable& roomParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("size", "Size", 0.4, 0.0, 1.0);
        p.expo("decay", "Decay", 0.8, 0.1, 5.0, "s");
        p.num("early", "Early reflections", 0.6, 0.0, 1.0);
        p.num("damping", "Damping", 0.5, 0.0, 1.0);
        p.num("predelay", "Pre-delay", 5.0, 0.0, 200.0, "ms");
        addOutput(p, 100.0, 12000.0, 1.0, 0.25);
        return p;
    }();
    return t;
}

class Room : public ReverbMode {
public:
    using ReverbMode::ReverbMode;

protected:
    bool prepare(double sr, uint32_t maxFrames) noexcept override {
        const size_t need = static_cast<size_t>((kMaxRoomPre + kEarlyMs[1][kEarly - 1] * 0.001 * kMaxEarlyScale) * sr) + 4;
        if (!line_[0].prepare(need) || !line_[1].prepare(need)) return false;
        try {
            tail_.prepare(sr, static_cast<int>(maxFrames), kMaxRoomPre + 0.03);
        } catch (...) {
            return false;
        }
        return true;
    }
    void clearState() noexcept override {
        for (auto& l : line_) l.clear();
        tail_.clear();
        clearOutput();
        set_ = false;
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>((pre_ + 0.25) * rate()); }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const double size = clamp01(param(kRoSize, at));
        pre_ = std::clamp(param(kRoPreDelay, at) * 0.001, 0.0, kMaxRoomPre);
        const double scale = 0.3 + (kMaxEarlyScale - 0.3) * size;
        early_ = clamp01(param(kRoEarly, at));
        double g = 1.0;
        for (int c = 0; c < 2; ++c) {
            g = 1.0;
            for (int k = 0; k < kEarly; ++k, g *= 0.8) {
                tap_[c][k] = static_cast<size_t>((pre_ + kEarlyMs[c][k] * 0.001 * scale) * sr) + 1;
                gain_[c][k] = 0.45 * early_ * g * kEarlySign[c][k];
            }
        }
        lib::ReverbSettings s;
        s.size = 0.3 * size;
        s.decay = param(kRoDecay, at);
        s.damping = param(kRoDamping, at);
        s.preDelay = pre_ + kEarlyMs[0][3] * 0.001 * scale;  // the tail starts among the reflections
        s.width = 1.0;
        s.mix = 1.0;
        s.modulation = 0.0;
        if (!set_ || s.size != settings_.size || s.decay != settings_.decay || s.damping != settings_.damping ||
            s.preDelay != settings_.preDelay) {
            tail_.set(s);
            settings_ = s;
            set_ = true;
        }
        tail_.setLight(true);  // a small room's tail needs no more than two diffusers a side and no line sweep
        controlOutput(kRoOut, at);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        float tl[kControlFrames], tr[kControlFrames];
        std::copy_n(inL, n, tl);
        std::copy_n(inR, n, tr);
        tail_.process(tl, tr, static_cast<int>(n));
        double wl[kControlFrames], wr[kControlFrames];
        const float* in[2] = {inL, inR};
        double* w[2] = {wl, wr};
        for (int c = 0; c < 2; ++c) {
            Line& line = line_[c];
            for (uint32_t i = 0; i < n; ++i) {
                line.write(in[c][i]);
                double e = 0.0;
                for (int k = 0; k < kEarly; ++k) e += gain_[c][k] * line.at(tap_[c][k]);
                w[c][i] = e + (c == 0 ? tl[i] : tr[i]);
            }
        }
        out_.finish(inL, inR, wl, wr, outL, outR, n);
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        outputDisplay(out);
        out[3] = static_cast<float>(settings_.decay);
        out[4] = static_cast<float>(pre_);
        out[5] = static_cast<float>(settings_.size / 0.3);
        out[6] = static_cast<float>(early_);
        for (int k = 0; k < kEarly; ++k) out[7 + k] = static_cast<float>(tap_[0][k] / rate());  // the left reflections' times s
        return 7 + kEarly;
    }

private:
    Line line_[2];
    lib::Reverb tail_;
    lib::ReverbSettings settings_;
    size_t tap_[2][kEarly] = {};
    double gain_[2][kEarly] = {};
    double pre_ = 0.005, early_ = 0.6;
    bool set_ = false;
};

// ---------- Plate ----------

enum PlateParam : uint32_t { kPlPreDelay, kPlDecay, kPlDamping, kPlDiffusion, kPlMod, kPlOut, kPlCount = kPlOut + 4 };
constexpr double kPlateRate = 29761.0;  // the lengths below are frames at this rate
constexpr double kInDiff[4] = {142, 107, 379, 277};
constexpr double kTankAp1[2] = {672, 908}, kTankDelay1[2] = {4453, 4217}, kTankAp2[2] = {1800, 2656}, kTankDelay2[2] = {3720, 3163};
constexpr double kPlateExcursion = 16;  // frames at kPlateRate, the modulated all-passes' sweep at mod 1
constexpr double kMaxPlatePre = 0.2;

const ParamTable& plateParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("predelay", "Pre-delay", 10.0, 0.0, 200.0, "ms");
        p.expo("decay", "Decay", 2.0, 0.2, 10.0, "s");
        p.num("damping", "Damping", 0.4, 0.0, 1.0);
        p.num("diffusion", "Diffusion", 0.75, 0.0, 1.0);
        p.num("mod", "Modulation", 0.3, 0.0, 1.0);
        addOutput(p, 80.0, 14000.0, 1.0, 0.25);
        return p;
    }();
    return t;
}

class Plate : public ReverbMode {
public:
    using ReverbMode::ReverbMode;

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        const double r = sr / kPlateRate;
        auto frames = [&](double n) { return static_cast<size_t>(n * r) + 2; };
        bool ok = pre_.prepare(static_cast<size_t>(kMaxPlatePre * sr) + 2);
        for (int k = 0; k < 4; ++k) ok = ok && inAp_[k].prepare(frames(kInDiff[k])), inAp_[k].setLength(frames(kInDiff[k]) - 2);
        for (int h = 0; h < 2; ++h) {
            ok = ok && ap1_[h].prepare(frames(kTankAp1[h] + kPlateExcursion + 2)) && ap2_[h].prepare(frames(kTankAp2[h])) &&
                 d1_[h].prepare(frames(kTankDelay1[h])) && d2_[h].prepare(frames(kTankDelay2[h]));
            ap1_[h].setLength(frames(kTankAp1[h]) - 2);
            ap2_[h].setLength(frames(kTankAp2[h]) - 2);
            len1_[h] = frames(kTankDelay1[h]) - 2;
            len2_[h] = frames(kTankDelay2[h]) - 2;
        }
        // Output taps (C.A.W's own): fractions of the tank's lines, each side from both halves, signs alternating.
        constexpr double kTapFrac[2][6] = {{0.11, 0.63, 0.37, 0.29, 0.82, 0.52}, {0.17, 0.71, 0.44, 0.23, 0.58, 0.91}};
        for (int c = 0; c < 2; ++c) {
            const int o = 1 - c;  // the left side reads mostly the right half, as in the classic tank
            taps_[c][0] = {&d1_[o], static_cast<size_t>(kTapFrac[c][0] * len1_[o]) + 1, 0.6};
            taps_[c][1] = {&d1_[o], static_cast<size_t>(kTapFrac[c][1] * len1_[o]) + 1, 0.6};
            taps_[c][2] = {&d2_[o], static_cast<size_t>(kTapFrac[c][2] * len2_[o]) + 1, -0.6};
            taps_[c][3] = {&d1_[c], static_cast<size_t>(kTapFrac[c][3] * len1_[c]) + 1, -0.6};
            taps_[c][4] = {&d2_[c], static_cast<size_t>(kTapFrac[c][4] * len2_[c]) + 1, 0.6};
            taps_[c][5] = {&d2_[o], static_cast<size_t>(kTapFrac[c][5] * len2_[o]) + 1, -0.6};
        }
        loopFrames_ = static_cast<double>(len1_[0] + len2_[0] + len1_[1] + len2_[1]) * 0.5 +
                      (kTankAp1[0] + kTankAp2[0] + kTankAp1[1] + kTankAp2[1]) * 0.5 * r;
        excursion_ = kPlateExcursion * r;
        return ok;
    }
    void clearState() noexcept override {
        pre_.clear();
        for (auto& a : inAp_) a.clear();
        for (int h = 0; h < 2; ++h) ap1_[h].clear(), ap2_[h].clear(), d1_[h].clear(), d2_[h].clear(), damp_[h] = 0.0, back_[h] = 0.0;
        band_ = 0.0;
        phase_ = 0.0;
        clearOutput();
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>((preSec_ + 0.25) * rate()); }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        preSec_ = std::clamp(param(kPlPreDelay, at) * 0.001, 0.0, kMaxPlatePre);
        preFrames_ = static_cast<size_t>(preSec_ * sr) + 1;
        decaySec_ = std::clamp(param(kPlDecay, at), 0.2, 10.0);
        decay_ = detPow(10.0, -3.0 * (loopFrames_ * 0.5) / (decaySec_ * sr));  // per half: 60 dB per RT60
        const double damping = clamp01(param(kPlDamping, at));
        dampK_ = 1.0 - 0.95 * damping;
        diffusion_ = clamp01(param(kPlDiffusion, at));
        bandK_ = 1.0 - detExp(-kTwoPi * 12000.0 / sr);  // the input's bandwidth
        mod_ = clamp01(param(kPlMod, at));
        phase_ += kControlFrames * 0.9 / sr;
        phase_ -= std::floor(phase_);
        // The two modulated all-passes in quadrature, followed in a straight line between control points.
        for (int h = 0; h < 2; ++h)
            sweep_[h].set(excursion_ * mod_ * (0.5 + 0.5 * lib::fastSinCycles(phase_ + 0.25 * h)), kControlFrames);
        controlOutput(kPlOut, at);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        double wl[kControlFrames], wr[kControlFrames];
        const double g1 = 0.75 * diffusion_, g2 = 0.625 * diffusion_, gt1 = -0.7 * std::max(0.3, diffusion_), gt2 = 0.5 * diffusion_;
        for (uint32_t i = 0; i < n; ++i) {
            pre_.write(0.5 * (static_cast<double>(inL[i]) + inR[i]));
            double x = pre_.at(preFrames_);
            band_ = modes::flush(band_ + (x - band_) * bandK_);
            x = inAp_[0].process(band_, g1);
            x = inAp_[1].process(x, g1);
            x = inAp_[2].process(x, g2);
            x = inAp_[3].process(x, g2);
            double half[2];
            for (int h = 0; h < 2; ++h) {
                double v = ap1_[h].processMod(x + back_[1 - h], gt1, sweep_[h].next());
                d1_[h].write(v);
                v = d1_[h].at(len1_[h]);
                damp_[h] = modes::flush(damp_[h] + (v - damp_[h]) * dampK_);
                v = ap2_[h].process(damp_[h] * decay_, gt2);
                d2_[h].write(v);
                half[h] = d2_[h].at(len2_[h]) * decay_;
            }
            back_[0] = half[0], back_[1] = half[1];
            double o[2] = {0.0, 0.0};
            for (int c = 0; c < 2; ++c)
                for (const Tap& t : taps_[c]) o[c] += t.gain * t.line->at(t.back);
            wl[i] = o[0];
            wr[i] = o[1];
        }
        out_.finish(inL, inR, wl, wr, outL, outR, n);
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        outputDisplay(out);
        out[3] = static_cast<float>(decaySec_);
        out[4] = static_cast<float>(preSec_);
        out[5] = static_cast<float>(diffusion_);
        out[6] = static_cast<float>(mod_);
        out[7] = static_cast<float>(sweep_[0].value / rate() * 1000.0);  // the first all-pass's sweep now, ms
        return 8;
    }

private:
    struct Tap {
        const Line* line = nullptr;
        size_t back = 1;
        double gain = 0.0;
    };
    Line pre_, d1_[2], d2_[2];
    Allpass inAp_[4], ap1_[2], ap2_[2];
    Tap taps_[2][6];
    Ramp sweep_[2];
    size_t len1_[2] = {1, 1}, len2_[2] = {1, 1}, preFrames_ = 1;
    double loopFrames_ = 1, excursion_ = 0, preSec_ = 0.01, decaySec_ = 2, decay_ = 0.5, dampK_ = 1, diffusion_ = 0.75;
    double bandK_ = 1, mod_ = 0, phase_ = 0, band_ = 0, damp_[2] = {0, 0}, back_[2] = {0, 0};
};

// ---------- Spring ----------

enum SpringParam : uint32_t { kSpDecay, kSpTension, kSpLength, kSpTone, kSpOut, kSpCount = kSpOut + 4 };
constexpr int kDispersion = 12;
constexpr double kMaxSpringLen = 0.08;  // seconds of loop delay (the right side 13 % longer)

const ParamTable& springParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.expo("decay", "Decay", 1.8, 0.3, 6.0, "s");
        p.num("tension", "Tension", 0.5, 0.0, 1.0);
        p.num("length", "Length", 0.5, 0.0, 1.0);
        p.expo("tone", "Tone", 4500.0, 1000.0, 9000.0, "Hz");
        addOutput(p, 150.0, 9000.0, 0.7, 0.3);
        return p;
    }();
    return t;
}

class Spring : public ReverbMode {
public:
    using ReverbMode::ReverbMode;

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        const size_t need = static_cast<size_t>(kMaxSpringLen * 1.13 * sr) + 4;
        return loop_[0].prepare(need) && loop_[1].prepare(need);
    }
    void clearState() noexcept override {
        for (int c = 0; c < 2; ++c) {
            loop_[c].clear();
            tone_[c].clear();
        }
        for (int k = 0; k < kDispersion; ++k) ap0_[k] = ap1_[k] = splat(0.0);
        clearOutput();
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>(0.3 * rate()); }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        decaySec_ = std::clamp(param(kSpDecay, at), 0.3, 6.0);
        tension_ = clamp01(param(kSpTension, at));
        coef_ = -(0.45 + 0.4 * tension_);  // more tension: a longer, deeper chirp
        length_ = clamp01(param(kSpLength, at));
        const double seconds = 0.025 + (kMaxSpringLen - 0.025) * length_;
        for (int c = 0; c < 2; ++c) {
            const double s = seconds * (c == 1 ? 1.13 : 1.0);
            len_[c] = static_cast<size_t>(s * sr) + 2;
            gain_[c] = detPow(10.0, -3.0 * s / decaySec_);
            tone_[c].set(param(kSpTone, at), kSqrtHalf, sr);
        }
        controlOutput(kSpOut, at);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        // Both springs as one two-wide vector (their lengths differ, their all-passes and tone are alike).
        double wl[kControlFrames], wr[kControlFrames];
        const Pair a = splat(coef_), gain = pairOf(gain_[0], gain_[1]), half = splat(0.5), two = splat(2.0);
        const Pair ta1 = splat(tone_[0].a1()), ta2 = splat(tone_[0].a2()), ta3 = splat(tone_[0].a3());
        Pair t1 = pairOf(tone_[0].ic1(), tone_[1].ic1()), t2 = pairOf(tone_[0].ic2(), tone_[1].ic2());
        for (uint32_t i = 0; i < n; ++i) {
            Pair y = pairOf(loop_[0].at(len_[0]), loop_[1].at(len_[1]));
            for (int k = 0; k < kDispersion; ++k) {  // first-order all-passes: y = a (x - y1) + x1
                const Pair out = a * (y - ap1_[k]) + ap0_[k];
                ap0_[k] = y;
                ap1_[k] = out;
                y = out;
            }
            Pair v1, v2;
            lib::Svf::step(y, t1, t2, ta1, ta2, ta3, two, v1, v2);
            wl[i] = lane(v2, 0), wr[i] = lane(v2, 1);
            const Pair fed = half * pairOf(inL[i], inR[i]) + v2 * gain;
            loop_[0].write(lane(fed, 0));
            loop_[1].write(lane(fed, 1));
        }
        for (int k = 0; k < kDispersion; ++k) ap0_[k] = flushPair(ap0_[k]), ap1_[k] = flushPair(ap1_[k]);
        t1 = flushPair(t1), t2 = flushPair(t2);
        tone_[0].setState(lane(t1, 0), lane(t2, 0)), tone_[1].setState(lane(t1, 1), lane(t2, 1));
        out_.finish(inL, inR, wl, wr, outL, outR, n);
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        outputDisplay(out);
        out[3] = static_cast<float>(decaySec_);
        out[4] = static_cast<float>(tension_);
        out[5] = static_cast<float>(length_);
        out[6] = static_cast<float>(len_[0] / rate());  // the left spring's loop s
        return 7;
    }

private:
    Line loop_[2];
    Pair ap0_[kDispersion] = {}, ap1_[kDispersion] = {};  // each all-pass's last input and output, both sides
    lib::Svf tone_[2];
    size_t len_[2] = {2, 2};
    double gain_[2] = {0, 0}, coef_ = -0.6, decaySec_ = 1.8, tension_ = 0.5, length_ = 0.5;
};

// ---------- Gated ----------

enum GatedParam : uint32_t { kGaSize, kGaDecay, kGaThreshold, kGaHold, kGaRelease, kGaPreDelay, kGaOut, kGaCount = kGaOut + 4 };
constexpr double kMaxGatePre = 0.1;

const ParamTable& gatedParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("size", "Size", 0.6, 0.0, 1.0);
        p.expo("decay", "Decay", 2.5, 0.3, 10.0, "s");
        p.num("threshold", "Threshold", -30.0, -60.0, 0.0, "dB");
        p.expo("hold", "Hold", 250.0, 10.0, 1000.0, "ms");
        p.expo("release", "Release", 40.0, 2.0, 500.0, "ms");
        p.num("predelay", "Pre-delay", 0.0, 0.0, 100.0, "ms");
        addOutput(p, 150.0, 10000.0, 1.0, 0.35);
        return p;
    }();
    return t;
}

class Gated : public ReverbMode {
public:
    using ReverbMode::ReverbMode;

protected:
    bool prepare(double sr, uint32_t maxFrames) noexcept override {
        try {
            tail_.prepare(sr, static_cast<int>(maxFrames), kMaxGatePre);
        } catch (...) {
            return false;
        }
        attack_ = lib::timeCoefficient(0.001, sr);
        return true;
    }
    void clearState() noexcept override {
        tail_.clear();
        gate_ = 0.0;
        holdLeft_ = 0;
        set_ = false;
        clearOutput();
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>((holdSec_ + 0.3) * rate()); }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        lib::ReverbSettings s;
        s.size = clamp01(param(kGaSize, at));
        s.decay = param(kGaDecay, at);
        s.damping = 0.3;
        s.preDelay = std::clamp(param(kGaPreDelay, at) * 0.001, 0.0, kMaxGatePre);
        s.width = 1.0;
        s.mix = 1.0;
        s.modulation = 0.0;
        if (!set_ || s.size != settings_.size || s.decay != settings_.decay || s.preDelay != settings_.preDelay) {
            tail_.set(s);
            settings_ = s;
            set_ = true;
        }
        tail_.setLight(true);  // the gate cuts the tail short: two diffusers a side and no sweep are dense enough
        threshold_ = param(kGaThreshold, at);
        thresholdLin_ = lib::dbToGain(threshold_);
        holdSec_ = std::max(0.0, param(kGaHold, at) * 0.001);
        holdFrames_ = static_cast<uint32_t>(holdSec_ * sr);
        release_ = lib::timeCoefficient(std::max(0.002, param(kGaRelease, at) * 0.001), sr);
        controlOutput(kGaOut, at);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        float tl[kControlFrames], tr[kControlFrames];
        std::copy_n(inL, n, tl);
        std::copy_n(inR, n, tr);
        tail_.process(tl, tr, static_cast<int>(n));
        double wl[kControlFrames], wr[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) {
            const double al = inL[i] < 0 ? -inL[i] : inL[i], ar = inR[i] < 0 ? -inR[i] : inR[i];
            if ((al > ar ? al : ar) > thresholdLin_) holdLeft_ = holdFrames_ + 1;
            if (holdLeft_ > 0) {
                --holdLeft_;
                gate_ = 1.0 + (gate_ - 1.0) * attack_;
            } else {
                gate_ = modes::flush(gate_ * release_);
            }
            gateMax_ = std::max(gateMax_, gate_);
            wl[i] = tl[i] * gate_;
            wr[i] = tr[i] * gate_;
        }
        out_.finish(inL, inR, wl, wr, outL, outR, n);
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        outputDisplay(out);
        out[3] = static_cast<float>(gate_);     // the gate now (0 shut .. 1 open)
        out[4] = static_cast<float>(gateMax_);  // the most it opened since the last publish
        out[5] = static_cast<float>(threshold_);
        out[6] = static_cast<float>(holdSec_);
        out[7] = static_cast<float>(settings_.decay);
        gateMax_ = 0.0;
        return 8;
    }

private:
    lib::Reverb tail_;
    lib::ReverbSettings settings_;
    double gate_ = 0, gateMax_ = 0, attack_ = 0, release_ = 0, threshold_ = -30, thresholdLin_ = 0.03, holdSec_ = 0.25;
    uint32_t holdLeft_ = 0, holdFrames_ = 0;
    bool set_ = false;
};

// ---------- Reverse ----------

enum ReverseParam : uint32_t { kRvLength, kRvCurve, kRvDiffusion, kRvOut, kRvCount = kRvOut + 4 };
constexpr int kSwellTaps = 24;
constexpr double kMaxSwell = 2.0;
constexpr double kSwellAp[2][2] = {{0.0047, 0.0113}, {0.0053, 0.0127}};    // seconds: input diffusers per side
constexpr double kSwellOutAp[2][2] = {{0.0071, 0.0029}, {0.0067, 0.0031}};  // and output ones

const ParamTable& swellParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.expo("length", "Length", 600.0, 100.0, 2000.0, "ms");
        p.num("curve", "Curve", 0.5, 0.0, 1.0);
        p.num("diffusion", "Diffusion", 0.7, 0.0, 1.0);
        addOutput(p, 100.0, 9000.0, 1.0, 0.35);
        return p;
    }();
    return t;
}

class ReverseReverb : public ReverbMode {
public:
    using ReverbMode::ReverbMode;

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        bool ok = line_[0].prepare(static_cast<size_t>(kMaxSwell * sr) + 4) && line_[1].prepare(static_cast<size_t>(kMaxSwell * sr) + 4);
        for (int c = 0; c < 2; ++c)
            for (int k = 0; k < 2; ++k) {
                ok = ok && inAp_[c][k].prepare(static_cast<size_t>(kSwellAp[c][k] * sr) + 2) &&
                     outAp_[c][k].prepare(static_cast<size_t>(kSwellOutAp[c][k] * sr) + 2);
                inAp_[c][k].setLength(static_cast<size_t>(kSwellAp[c][k] * sr));
                outAp_[c][k].setLength(static_cast<size_t>(kSwellOutAp[c][k] * sr));
            }
        // Each tap's place in its slot, seeded (the same on every platform), different per side.
        modes::Noise noise;
        noise.seed = 0x5e11;
        for (int c = 0; c < 2; ++c)
            for (int k = 0; k < kSwellTaps; ++k) jitter_[c][k] = 0.5 + 0.4 * noise.next();
        return ok;
    }
    void clearState() noexcept override {
        for (int c = 0; c < 2; ++c) {
            line_[c].clear();
            for (int k = 0; k < 2; ++k) inAp_[c][k].clear(), outAp_[c][k].clear();
        }
        clearOutput();
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>((lengthSec_ + 0.1) * rate()); }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        lengthSec_ = std::clamp(param(kRvLength, at) * 0.001, 0.1, kMaxSwell);
        curve_ = clamp01(param(kRvCurve, at));
        diffusion_ = clamp01(param(kRvDiffusion, at)) * 0.7;
        const double power = 1.0 + 4.0 * curve_;
        double sum = 0.0;
        for (int k = 0; k < kSwellTaps; ++k) sum += detPow((k + 1.0) / kSwellTaps, 2.0 * power);
        const double norm = 1.0 / std::sqrt(sum);  // equal energy whatever the curve
        for (int c = 0; c < 2; ++c)
            for (int k = 0; k < kSwellTaps; ++k) {
                const double place = (k + jitter_[c][k]) / kSwellTaps;
                tap_[c][k] = std::max<size_t>(kControlFrames + 2, static_cast<size_t>(place * lengthSec_ * sr));
                gain_[c][k] = norm * detPow((k + 1.0) / kSwellTaps, power) * ((k & 1) ? -1.0 : 1.0);
            }
        controlOutput(kRvOut, at);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        double wl[kControlFrames], wr[kControlFrames];
        const float* in[2] = {inL, inR};
        double* w[2] = {wl, wr};
        // Tap by tap over the run, then the run is written: every tap is at least 20 frames back (the shortest
        // length's first slot), so none reads what this run writes.
        for (int c = 0; c < 2; ++c) {
            Line& line = line_[c];
            double x[kControlFrames], y[kControlFrames] = {};
            for (uint32_t i = 0; i < n; ++i) x[i] = inAp_[c][1].process(inAp_[c][0].process(in[c][i], diffusion_), diffusion_);
            for (int k = 0; k < kSwellTaps; ++k) {
                const double g = gain_[c][k];
                const size_t t = tap_[c][k];
                for (uint32_t i = 0; i < n; ++i) y[i] += g * line.at(t - i);
            }
            for (uint32_t i = 0; i < n; ++i) {
                line.write(x[i]);
                w[c][i] = outAp_[c][1].process(outAp_[c][0].process(y[i], diffusion_), diffusion_);
            }
        }
        out_.finish(inL, inR, wl, wr, outL, outR, n);
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        outputDisplay(out);
        out[3] = static_cast<float>(lengthSec_);
        out[4] = static_cast<float>(curve_);
        out[5] = static_cast<float>(kSwellTaps);
        for (int k = 0; k < kSwellTaps; ++k) out[6 + k] = static_cast<float>(std::fabs(gain_[0][k]));  // the left taps' gains, earliest first
        return 6 + kSwellTaps;
    }

private:
    Line line_[2];
    Allpass inAp_[2][2], outAp_[2][2];
    size_t tap_[2][kSwellTaps] = {};
    double gain_[2][kSwellTaps] = {}, jitter_[2][kSwellTaps] = {};
    double lengthSec_ = 0.6, curve_ = 0.5, diffusion_ = 0.5;
};

// ---------- Descriptors, factories and presets ----------

const ModuleDescriptor& base(const ParamTable& t, CpuClass cpu) {
    static std::deque<ModuleDescriptor> made;  // start-up only (each mode's descriptor function holds its result)
    return made.emplace_back(withCpu(effectDescriptor(kReverbId, kReverbName, t, 0, kInfiniteTail), cpu));
}

using V = std::vector<std::pair<std::string_view, double>>;
BuiltinPreset preset(const char* name, const char* description, V values, double variant) {
    values.emplace_back("variant", variant);
    return {name, description, std::move(values)};
}

const std::vector<BuiltinPreset>& presets() {
    static const std::vector<BuiltinPreset> p = {
        // Room (2)
        preset("Vocal booth", "Vocals: a small, dry room that places the voice", {{"size", 0.15}, {"decay", 0.35}, {"early", 0.7}, {"mix", 0.18}}, 2),
        preset("Drum room", "Drums: a live room with strong early reflections", {{"size", 0.55}, {"decay", 0.9}, {"early", 0.85}, {"damping", 0.4}, {"mix", 0.3}}, 2),
        preset("Studio live room", "Mixing: a natural, mid-sized room for the whole band", {{"size", 0.45}, {"decay", 0.7}, {"early", 0.6}, {"mix", 0.2}}, 2),
        preset("Guitar amp room", "Guitar: the room around a miked cabinet", {{"size", 0.3}, {"decay", 0.5}, {"early", 0.75}, {"damping", 0.6}, {"low_cut", 150}, {"mix", 0.22}}, 2),
        preset("Wooden hall", "Mixing: a larger, warm room", {{"size", 0.9}, {"decay", 1.8}, {"early", 0.5}, {"damping", 0.65}, {"mix", 0.25}}, 2),
        preset("Bathroom", "Lo-fi: a tiled, bright little room", {{"size", 0.1}, {"decay", 1.2}, {"early", 0.9}, {"damping", 0.1}, {"high_cut", 16000}, {"mix", 0.3}}, 2),
        preset("Bass ambience", "Bass: a hint of room with the lows kept clean", {{"size", 0.25}, {"decay", 0.4}, {"early", 0.5}, {"low_cut", 250}, {"mix", 0.15}}, 2),
        preset("Snare chamber", "Drums: a short chamber that lifts a snare", {{"size", 0.35}, {"decay", 1.1}, {"early", 0.65}, {"predelay", 12}, {"mix", 0.3}}, 2),
        // Plate (3)
        preset("Vocal plate", "Vocals: the classic bright plate behind a lead", {{"decay", 2.2}, {"predelay", 25}, {"damping", 0.35}, {"mix", 0.22}}, 3),
        preset("Snare plate", "Drums: a short, splashy plate on the snare", {{"decay", 1.2}, {"predelay", 5}, {"damping", 0.25}, {"diffusion", 0.85}, {"mix", 0.3}}, 3),
        preset("Dark plate", "Mixing: a long, soft plate that stays behind the mix", {{"decay", 3.5}, {"damping", 0.75}, {"high_cut", 7000}, {"mix", 0.2}}, 3),
        preset("Guitar plate", "Guitar: a medium plate with a little movement", {{"decay", 1.8}, {"predelay", 15}, {"mod", 0.5}, {"mix", 0.25}}, 3),
        preset("Huge plate", "Sound design: a ten-second wash", {{"decay", 10}, {"damping", 0.5}, {"mod", 0.6}, {"mix", 0.4}}, 3),
        preset("Mastering sheen", "Mastering: a trace of bright plate for air", {{"decay", 1.0}, {"low_cut", 600}, {"damping", 0.2}, {"mix", 0.06}}, 3),
        preset("Bass plate", "Bass: a tight plate with the lows cut", {{"decay", 0.8}, {"low_cut", 300}, {"mix", 0.12}}, 3),
        preset("Lo-fi tin plate", "Lo-fi: a narrow, filtered plate", {{"decay", 1.5}, {"diffusion", 0.4}, {"high_cut", 4000}, {"low_cut", 400}, {"width", 0.3}, {"mix", 0.3}}, 3),
        // Spring (4)
        preset("Surf spring", "Guitar: the drippy amp spring of surf rock", {{"decay", 2.5}, {"tension", 0.8}, {"length", 0.6}, {"tone", 5000}, {"mix", 0.4}}, 4),
        preset("Amp spring", "Guitar: a gentle spring as in a combo amp", {{"decay", 1.6}, {"tension", 0.5}, {"mix", 0.25}}, 4),
        preset("Dub spring", "Drums: a long, boingy spring for dub snares", {{"decay", 4.0}, {"tension", 0.9}, {"length", 0.9}, {"tone", 3500}, {"mix", 0.45}}, 4),
        preset("Vocal spring", "Vocals: a vintage spring, tucked under the voice", {{"decay", 1.4}, {"tension", 0.4}, {"low_cut", 300}, {"mix", 0.2}}, 4),
        preset("Short tank", "Mixing: a short spring for a vintage colour", {{"decay", 0.8}, {"tension", 0.3}, {"length", 0.2}, {"mix", 0.2}}, 4),
        preset("Broken spring", "Lo-fi: a dark, rattly tank", {{"decay", 2.0}, {"tension", 1.0}, {"length", 0.1}, {"tone", 2000}, {"mix", 0.35}}, 4),
        preset("Bass spring", "Bass: a spring with the lows kept dry", {{"decay", 1.0}, {"tension", 0.6}, {"low_cut", 400}, {"mix", 0.15}}, 4),
        preset("Spring wash", "Sound design: six seconds of chirping springs", {{"decay", 6.0}, {"tension", 0.7}, {"length", 1.0}, {"width", 1.2}, {"mix", 0.5}}, 4),
        // Gated (5)
        preset("80s gated snare", "Drums: the big, cut-off snare reverb", {{"size", 0.7}, {"decay", 3.0}, {"threshold", -24}, {"hold", 220}, {"release", 30}, {"mix", 0.45}}, 5),
        preset("Gated toms", "Drums: a fat burst of room on each tom", {{"size", 0.6}, {"decay", 2.0}, {"threshold", -28}, {"hold", 300}, {"release", 60}, {"mix", 0.35}}, 5),
        preset("Gated kick", "Drums: a short thump of room after the kick", {{"size", 0.4}, {"decay", 1.5}, {"threshold", -18}, {"hold", 120}, {"release", 20}, {"low_cut", 60}, {"mix", 0.3}}, 5),
        preset("Gated vocal", "Vocals: a dense room that stops with each phrase", {{"size", 0.5}, {"decay", 2.0}, {"threshold", -36}, {"hold", 150}, {"release", 80}, {"mix", 0.25}}, 5),
        preset("Gated clap", "Drums: a wide, tight burst on claps", {{"size", 0.8}, {"decay", 2.5}, {"threshold", -26}, {"hold", 180}, {"release", 25}, {"width", 1.5}, {"mix", 0.4}}, 5),
        preset("Gated guitar chops", "Guitar: reverb that opens on each chord and slams shut", {{"size", 0.6}, {"decay", 3.0}, {"threshold", -30}, {"hold", 90}, {"release", 10}, {"mix", 0.35}}, 5),
        preset("Gated mix bus", "Mixing: a little gated room for punch on a drum bus", {{"size", 0.45}, {"decay", 1.5}, {"threshold", -20}, {"hold", 100}, {"release", 40}, {"mix", 0.15}}, 5),
        preset("Gated stutter", "Sound design: a long tail chopped short by a high threshold", {{"size", 1.0}, {"decay", 8.0}, {"threshold", -12}, {"hold", 60}, {"release", 5}, {"mix", 0.5}}, 5),
        // Reverse (6)
        preset("Reverse vocal swell", "Vocals: a swell that rises into each word", {{"length", 700}, {"curve", 0.6}, {"mix", 0.3}}, 6),
        preset("Reverse snare", "Drums: the backwards-reverb snare build", {{"length", 450}, {"curve", 0.8}, {"diffusion", 0.8}, {"mix", 0.4}}, 6),
        preset("Ghost swell", "Sound design: a long, soft swell", {{"length", 1800}, {"curve", 0.4}, {"diffusion", 0.9}, {"mix", 0.45}}, 6),
        preset("Guitar bloom", "Guitar: chords bloom backwards", {{"length", 900}, {"curve", 0.5}, {"mix", 0.3}}, 6),
        preset("Short reverse", "Drums: a quick backwards smear on hats", {{"length", 180}, {"curve", 0.9}, {"mix", 0.25}}, 6),
        preset("Dark swell", "Mixing: a muffled swell behind a part", {{"length", 1000}, {"curve", 0.3}, {"high_cut", 3500}, {"mix", 0.25}}, 6),
        preset("Lo-fi reverse", "Lo-fi: a grainy, undiffused backwards echo", {{"length", 500}, {"curve", 0.7}, {"diffusion", 0.1}, {"high_cut", 5000}, {"mix", 0.35}}, 6),
        preset("Bass swell", "Bass: a gentle swell with the lows kept dry", {{"length", 600}, {"curve", 0.5}, {"low_cut", 300}, {"mix", 0.2}}, 6),
    };
    return p;
}

template <class T>
ModuleProcessor* makeAs(const ModuleDescriptor& v) noexcept {
    return new (std::nothrow) T(v);
}

const ModuleDescriptor& roomBase() {
    static const ModuleDescriptor& d = base(roomParams(), CpuClass::Medium);
    return d;
}
const ModuleDescriptor& plateBase() {
    static const ModuleDescriptor& d = base(plateParams(), CpuClass::Medium);
    return d;
}
const ModuleDescriptor& springBase() {
    static const ModuleDescriptor& d = base(springParams(), CpuClass::Medium);
    return d;
}
const ModuleDescriptor& gatedBase() {
    static const ModuleDescriptor& d = base(gatedParams(), CpuClass::Medium);
    return d;
}
const ModuleDescriptor& swellBase() {
    static const ModuleDescriptor& d = base(swellParams(), CpuClass::Medium);
    return d;
}

}  // namespace

// Each mode's descriptor (its table and `variant`, labels the device's whole list) and instance.
const ModuleDescriptor& roomReverbDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(roomBase(), kReverbId, kReverbName, labels, index);
    return d;
}
const ModuleDescriptor& plateReverbDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(plateBase(), kReverbId, kReverbName, labels, index);
    return d;
}
const ModuleDescriptor& springReverbDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(springBase(), kReverbId, kReverbName, labels, index);
    return d;
}
const ModuleDescriptor& gatedReverbDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(gatedBase(), kReverbId, kReverbName, labels, index);
    return d;
}
const ModuleDescriptor& reverseReverbDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(swellBase(), kReverbId, kReverbName, labels, index);
    return d;
}
ModuleProcessor* makeRoomReverbAs(const ModuleDescriptor& v) noexcept { return makeAs<Room>(v); }
ModuleProcessor* makePlateReverbAs(const ModuleDescriptor& v) noexcept { return makeAs<Plate>(v); }
ModuleProcessor* makeSpringReverbAs(const ModuleDescriptor& v) noexcept { return makeAs<Spring>(v); }
ModuleProcessor* makeGatedReverbAs(const ModuleDescriptor& v) noexcept { return makeAs<Gated>(v); }
ModuleProcessor* makeReverseReverbAs(const ModuleDescriptor& v) noexcept { return makeAs<ReverseReverb>(v); }
std::span<const BuiltinPreset> reverbModePresets() { return presets(); }

}  // namespace caw::fx
