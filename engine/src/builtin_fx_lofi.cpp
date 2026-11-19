// Lo-fi (org.caw.lofi, 1.1.0): vinyl crackle and wear, tape hiss and wobble, radio/phone/cassette bands, sample-rate grit, and one Age macro.
#include <algorithm>
#include <cmath>
#include <memory>
#include <new>

#include "builtin_effects.h"
#include "builtin_fx_tools.h"
#include "caw/detmath.hpp"
#include "caw/library/fastmath.hpp"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0), in this order per sample: wobble (a short delay line read at a slowly moving
// time: wow at 0.55 Hz, flutter at 6.3 Hz and a seeded drift), the band (a 12 or 24 dB/octave high- and low-pass
// pair), wear (a low-pass falling from 20 kHz to 2.5 kHz, a low cut rising to 90 Hz and a soft saturation), grit
// (sample-and-hold to a lower rate and fewer bits), then crackle (seeded clicks of random size and sign, each a
// short decaying pulse) and hiss (high-passed white noise), whose level follows the input's envelope (a 0.25 s
// release, off below -80 dBFS) so the effect still falls silent, and sleeps, after its input does. Age moves every section at once
// (crackle 0.6, wear 1, hiss 0.5, wobble 0.5, grit from 0.6 on) on top of each section's own amount.
// Each section runs only when its amount is above 0; coefficients are worked out on the 16-frame control grid and
// only when a value moved. The delay line is sized to the rate (4 ms plus room), the rest is a few filter states.

namespace caw::fx {

namespace {

enum LofiParam : uint32_t { kAge, kCrackle, kWear, kHiss, kWobble, kBand, kGrit, kSeed, kMix, kOutput, kCount };
constexpr std::string_view kBands[] = {"Off", "Radio", "Phone", "Cassette"};
constexpr double kBandLo[] = {0, 200, 300, 40}, kBandHi[] = {0, 4500, 3400, 12000};
constexpr double kMaxWobbleMs = 3.0;

const ParamTable& lofiParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("age", "Age", 0.0, 0.0, 1.0);
        p.num("crackle", "Crackle", 0.0, 0.0, 1.0);
        p.num("wear", "Wear", 0.0, 0.0, 1.0);
        p.num("hiss", "Hiss", 0.0, 0.0, 1.0);
        p.num("wobble", "Wobble", 0.0, 0.0, 1.0);
        p.pick("band", "Band", 0, kBands);
        p.num("grit", "Grit", 0.0, 0.0, 1.0);
        ParameterDescriptor& s = p.num("seed", "Seed", 1, 0, 9999);
        s.step = 1;
        s.smoothingFrames = 0;
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}
const ModuleDescriptor& lofiDescriptor() {
    static const ModuleDescriptor d = withCpu(effectDescriptor("org.caw.lofi", "Lo-fi", lofiParams(), 0, 0), CpuClass::Medium);
    return d;
}

// A biquad (RBJ cookbook Butterworth, Q 0.7071), transposed direct form II, per side.
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1[2] = {}, z2[2] = {};
    void set(double hz, double rate, bool high) noexcept {
        const double w = kTwoPi * std::clamp(hz, 10.0, 0.45 * rate) / rate;
        const double c = detCos(w), alpha = detSin(w) * 0.70710678118654752;
        const double a0 = 1.0 + alpha;
        b1 = (high ? -(1.0 + c) : (1.0 - c)) / a0;
        b0 = b2 = (high ? (1.0 + c) : (1.0 - c)) * 0.5 / a0;
        a1 = -2.0 * c / a0;
        a2 = (1.0 - alpha) / a0;
    }
    double run(int s, double x) noexcept {
        const double y = b0 * x + z1[s];
        z1[s] = b1 * x - a1 * y + z2[s];
        z2[s] = b2 * x - a2 * y;
        return y;
    }
    void clear() noexcept { z1[0] = z1[1] = z2[0] = z2[1] = 0; }
};

class Lofi final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return lofiDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        uint32_t n = 4;
        while (n < static_cast<uint32_t>(std::ceil(kMaxWobbleMs * 1e-3 * sampleRate)) + 4) n <<= 1;
        lineL_.reset(new (std::nothrow) float[n]);
        lineR_.reset(new (std::nothrow) float[n]);
        if (!lineL_ || !lineR_) return false;
        mask_ = n - 1;
        envRelease_ = std::exp(-1.0 / (0.25 * sampleRate));
        clickDecay_ = std::exp(-1.0 / (0.0004 * sampleRate));
        hissCoef_ = 1.0 - std::exp(-kTwoPi * 2000.0 / sampleRate);
        return true;
    }

    void control(uint32_t at) noexcept override {
        const double age = param(kAge, at);
        auto amount = [&](uint32_t k, double recipe) { return std::clamp(param(k, at) + age * recipe, 0.0, 1.0); };
        crackle_ = amount(kCrackle, 0.6);
        wear_ = amount(kWear, 1.0);
        hiss_ = amount(kHiss, 0.5);
        wobble_ = amount(kWobble, 0.5);
        grit_ = std::clamp(param(kGrit, at) + std::max(0.0, age - 0.6) * 1.5, 0.0, 1.0);
        ageNow_ = age;
        const uint32_t seed = static_cast<uint32_t>(param(kSeed, at));
        if (seed != seed_) seed_ = seed, rng_ = hash32(seed * 2654435761u + 1u) | 1u;
        const double r = rate();
        // The band and wear filters: worked out again only when their values move.
        const int band = std::clamp(choice(kBand, at), 0, 3);
        if (band != band_) {
            band_ = band;
            if (band) bandHp_.set(kBandLo[band], r, true), bandLp_.set(kBandHi[band], r, false);
            bandHp2_ = bandHp_, bandLp2_ = bandLp_;  // the phone's second pair (24 dB/octave)
            bandHp_.clear(), bandLp_.clear(), bandHp2_.clear(), bandLp2_.clear();
        }
        if (wear_ != wearFor_) {
            wearFor_ = wear_;
            wearLp_.set(20000.0 * std::pow(2.5 / 20.0, wear_), r, false);
            wearHp_.set(20.0 + 70.0 * wear_, r, true);
            wearDrive_ = 1.0 + 2.0 * wear_;
            wearNorm_ = 1.0 / lib::tanhApprox(wearDrive_ * 0.5) * 0.5;
        }
        // Crackle: clicks a second from a few to about 60, sized by the amount.
        clickChance_ = crackle_ > 0.0 ? (2.0 + 58.0 * crackle_ * crackle_) / r : 0.0;
        clickSize_ = 0.02 + 0.25 * crackle_;
        hissLevel_ = hiss_ > 0.0 ? 0.0316 * hiss_ * hiss_ : 0.0;  // up to -30 dBFS of noise at full input
        // Grit: hold each sample for rate/target frames (target 16 kHz down to 2 kHz) at 16 down to 6 bits.
        holdFrames_ = grit_ > 0.0 ? r / (16000.0 * std::pow(2000.0 / 16000.0, grit_)) : 1.0;
        const double bits = 16.0 - 10.0 * grit_;
        quantStep_ = grit_ > 0.0 ? std::pow(2.0, 1.0 - bits) : 0.0;
        const double outGain = lib::dbToGain(param(kOutput, at));
        outRamp_.set(outGain, kControlFrames);
        mixRamp_.set(param(kMix, at), kControlFrames);
        if (wobble_ > 0.0 && !wobbleOn_) {  // the line starts empty when the wobble starts
            std::fill_n(lineL_.get(), mask_ + 1, 0.0f);
            std::fill_n(lineR_.get(), mask_ + 1, 0.0f);
        }
        wobbleOn_ = wobble_ > 0.0;
        const double wowStep = kTwoPi * 0.55 / r, flutterStep = kTwoPi * 6.3 / r;
        wowPhase_ = std::fmod(wowPhase_ + wowStep * kControlFrames, kTwoPi);
        flutterPhase_ = std::fmod(flutterPhase_ + flutterStep * kControlFrames, kTwoPi);
        drift_ += 0.02 * (nextNoise() - drift_);  // a slow random walk
        const double depth = wobble_ * kMaxWobbleMs * 1e-3 * r;
        const double lfo = 0.6 * detSin(wowPhase_) + 0.25 * detSin(flutterPhase_) + 0.15 * drift_;
        delayRamp_.set(0.5 * depth * (1.0 + std::clamp(lfo, -1.0, 1.0)), kControlFrames);
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            double l = inL[i], r = inR[i];
            const double dryL = l, dryR = r;
            const double level = std::max(std::fabs(l), std::fabs(r));
            env_ = level > env_ ? level : env_ * envRelease_;
            const double noiseEnv = env_ > 1e-4 ? env_ : 0.0;  // below -80 dBFS the noise stops
            if (wobbleOn_) {
                lineL_[write_] = static_cast<float>(l);
                lineR_[write_] = static_cast<float>(r);
                const double d = delayRamp_.next();
                const double pos = static_cast<double>(write_) - d;
                const double fl = std::floor(pos);
                const double frac = pos - fl;
                const uint32_t a = static_cast<uint32_t>(static_cast<int64_t>(fl)) & mask_;
                l = lineL_[a] + (lineL_[(a + 1) & mask_] - lineL_[a]) * frac;
                r = lineR_[a] + (lineR_[(a + 1) & mask_] - lineR_[a]) * frac;
                write_ = (write_ + 1) & mask_;
            }
            if (band_) {
                l = bandLp_.run(0, bandHp_.run(0, l));
                r = bandLp_.run(1, bandHp_.run(1, r));
                if (band_ == 2) {
                    l = bandLp2_.run(0, bandHp2_.run(0, l));
                    r = bandLp2_.run(1, bandHp2_.run(1, r));
                }
            }
            if (wear_ > 0.0) {
                l = lib::tanhApprox(wearHp_.run(0, wearLp_.run(0, l)) * wearDrive_ * 0.5) * wearNorm_ * 2.0;
                r = lib::tanhApprox(wearHp_.run(1, wearLp_.run(1, r)) * wearDrive_ * 0.5) * wearNorm_ * 2.0;
            }
            if (grit_ > 0.0) {
                holdLeft_ -= 1.0;
                if (holdLeft_ <= 0.0) {
                    holdLeft_ += holdFrames_;
                    heldL_ = std::floor(l / quantStep_ + 0.5) * quantStep_;
                    heldR_ = std::floor(r / quantStep_ + 0.5) * quantStep_;
                }
                l = heldL_, r = heldR_;
            }
            if (clickChance_ > 0.0) {
                if (unitNoise() < clickChance_) click_ += clickSize_ * nextNoise(), clickSide_ = unitNoise();
                const double c = click_ * noiseEnv;
                l += c * (0.5 + clickSide_), r += c * (1.5 - clickSide_);
                click_ *= clickDecay_;
            }
            if (hissLevel_ > 0.0) {
                const double wl = nextNoise(), wr = nextNoise();
                hissLpL_ += hissCoef_ * (wl - hissLpL_);
                hissLpR_ += hissCoef_ * (wr - hissLpR_);
                l += (wl - hissLpL_) * hissLevel_ * noiseEnv;
                r += (wr - hissLpR_) * hissLevel_ * noiseEnv;
            }
            const double mix = mixRamp_.next(), g = outRamp_.next();
            outL[i] = static_cast<float>((dryL + (l - dryL) * mix) * g);
            outR[i] = static_cast<float>((dryR + (r - dryR) * mix) * g);
        }
        if (env_ < 1e-9) env_ = 0.0;
        if (std::fabs(click_) < 1e-12) click_ = 0.0;
        // A non-finite input must not stay in the filters: they start again from silence.
        const double states = bandHp_.z1[0] + bandHp_.z1[1] + bandLp_.z1[0] + bandLp_.z1[1] + bandHp2_.z1[0] + bandLp2_.z1[1] +
                              wearLp_.z1[0] + wearLp_.z1[1] + wearHp_.z1[0] + wearHp_.z1[1] + heldL_ + heldR_ + env_;
        if (!std::isfinite(states)) {
            bandHp_.clear(), bandLp_.clear(), bandHp2_.clear(), bandLp2_.clear(), wearLp_.clear(), wearHp_.clear();
            heldL_ = heldR_ = env_ = 0.0;
        }
    }

    void clearState() noexcept override {
        bandHp_.clear(), bandLp_.clear(), bandHp2_.clear(), bandLp2_.clear(), wearLp_.clear(), wearHp_.clear();
        if (lineL_) std::fill_n(lineL_.get(), mask_ + 1, 0.0f), std::fill_n(lineR_.get(), mask_ + 1, 0.0f);
        write_ = 0;
        env_ = click_ = clickSide_ = 0.0;
        hissLpL_ = hissLpR_ = 0.0;
        holdLeft_ = 0.0;
        heldL_ = heldR_ = 0.0;
        wowPhase_ = flutterPhase_ = drift_ = 0.0;
        rng_ = hash32(seed_ * 2654435761u + 1u) | 1u;
        outRamp_.reset(), mixRamp_.reset(), delayRamp_.reset();
        band_ = -1;
        wearFor_ = -1.0;
        wobbleOn_ = false;
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(ageNow_);
        out[3] = static_cast<float>(crackle_);
        out[4] = static_cast<float>(wear_);
        out[5] = static_cast<float>(hiss_);
        out[6] = static_cast<float>(wobble_);
        out[7] = static_cast<float>(std::max(band_, 0));
        out[8] = static_cast<float>(grit_);
        out[9] = static_cast<float>(delayRamp_.value * 1000.0 / rate());
        out[10] = static_cast<float>(grit_ > 0.0 ? rate() / holdFrames_ : rate());
        out[11] = static_cast<float>(16.0 - 10.0 * grit_);
        return 12;
    }

private:
    // xorshift32: seeded, the same bits everywhere.
    uint32_t nextBits() noexcept {
        rng_ ^= rng_ << 13;
        rng_ ^= rng_ >> 17;
        rng_ ^= rng_ << 5;
        return rng_;
    }
    double unitNoise() noexcept { return static_cast<double>(nextBits()) * (1.0 / 4294967296.0); }
    double nextNoise() noexcept { return 2.0 * unitNoise() - 1.0; }

    std::unique_ptr<float[]> lineL_, lineR_;
    uint32_t mask_ = 0, write_ = 0;
    Biquad bandHp_, bandLp_, bandHp2_, bandLp2_, wearLp_, wearHp_;
    int band_ = -1;
    double crackle_ = 0, wear_ = 0, hiss_ = 0, wobble_ = 0, grit_ = 0, ageNow_ = 0, wearFor_ = -1;
    double wearDrive_ = 1, wearNorm_ = 1;
    double env_ = 0, envRelease_ = 0.9999, clickDecay_ = 0.9, click_ = 0, clickSide_ = 0, clickChance_ = 0, clickSize_ = 0;
    double hissLevel_ = 0, hissCoef_ = 0.2, hissLpL_ = 0, hissLpR_ = 0;
    double holdFrames_ = 1, holdLeft_ = 0, quantStep_ = 0, heldL_ = 0, heldR_ = 0;
    double wowPhase_ = 0, flutterPhase_ = 0, drift_ = 0;
    bool wobbleOn_ = false;
    uint32_t seed_ = 1, rng_ = 1;
    Ramp outRamp_, mixRamp_, delayRamp_;
};

ModuleProcessor* makeLofi() noexcept { return new (std::nothrow) Lofi(); }

}  // namespace

void registerLofi(ModuleRegistry& registry) { registry.add(lofiDescriptor(), &makeLofi); }

const std::vector<BuiltinPreset>& lofiPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Old record", "Lo-fi: crackle and a worn top on a vinyl record", {{"crackle", 0.5}, {"wear", 0.5}}},
        {"Dusty sample", "Lo-fi: a hip-hop sample's crackle, wear and a little grit", {{"crackle", 0.4}, {"wear", 0.6}, {"grit", 0.3}}},
        {"Worn cassette", "Lo-fi: tape band, hiss and wobble", {{"band", 3}, {"hiss", 0.5}, {"wobble", 0.4}, {"wear", 0.3}}},
        {"AM radio", "Vocals: a narrow radio band with a touch of hiss", {{"band", 1}, {"hiss", 0.2}, {"wear", 0.2}}},
        {"Telephone", "Vocals: a phone line, steep and narrow", {{"band", 2}, {"wear", 0.3}}},
        {"Seasick tape", "Sound design: deep, slow wobble", {{"wobble", 1.0}, {"hiss", 0.2}}},
        {"8-bit grit", "Sound design: low rate and few bits", {{"grit", 0.85}}},
        {"Age it all", "Lo-fi: the Age macro at three quarters", {{"age", 0.75}}},
        {"Gentle warmth", "Mixing: a little wear and wobble, half mixed in", {{"wear", 0.3}, {"wobble", 0.15}, {"mix", 0.5}}},
        {"Lo-fi drums", "Drums: band-limited, gritty, a little crackle", {{"band", 3}, {"grit", 0.4}, {"crackle", 0.2}}},
    };
    return p;
}

}  // namespace caw::fx
