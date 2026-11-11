// C.A.W. Library: drum voices (kick, snare, clap, hi-hat) built from the Library's oscillators, filters and envelopes.
#pragma once

#include <cstdint>

#include "../detmath.hpp"
#include "distortion.hpp"
#include "envelope.hpp"
#include "fastmath.hpp"
#include "filter.hpp"
#include "oscillator.hpp"

namespace caw::lib {

// Each voice: set() its settings (it costs a few exps and tans: call it every 16 frames or when they change),
// trigger() a hit at a velocity 0..1, next() one sample, and choke() to fade it out over 5 ms (a closed hat
// cutting an open one, or the kick before the next hit). Allocation-free and deterministic.

namespace detail {
inline double clampTo(double v, double lo, double hi) noexcept {
    v = finiteOr0(v);
    return v < lo ? lo : (v > hi ? hi : v);
}
// The 5 ms fade a choke starts.
struct Choke {
    double gain = 1.0, coef = 1.0;
    bool on = false;
    void start(double sampleRate) noexcept {
        on = true;
        coef = decayCoefficient(0.005, sampleRate);
    }
    void clear() noexcept {
        gain = 1.0;
        on = false;
    }
    double next() noexcept {
        if (on) gain *= coef;
        return gain;
    }
    bool done() const noexcept { return on && gain < 1e-4; }
};
}  // namespace detail

// Kick: a sine whose pitch drops fast from `tune * (1 + 10 * punch)` to `tune` Hz, a click of filtered noise,
// then drive and a tone filter (0 dark .. 1 bright).
struct KickSettings {
    double tune = 48.0;    // Hz the body settles at, 20..200
    double punch = 0.6;    // how far and how long the pitch drops, 0..1
    double decay = 0.35;   // seconds to -60 dB
    double click = 0.3;    // the click's level, 0..1
    double tone = 0.6;     // 0 dark .. 1 bright
    double drive = 1.5;    // 1 clean .. 10 heavy
};

// Fast: the body's sine and the drive use the Library's fast maths (fastmath.hpp), several times cheaper and
// the same sound (within 1e-9); KickVoice is the exact version, FastKickVoice the fast one.
template <bool Fast>
class BasicKickVoice {
public:
    void set(const KickSettings& s, double sampleRate) noexcept {
        sr_ = sampleRate;
        tune_ = detail::clampTo(s.tune, 20.0, 200.0);
        punch_ = detail::clampTo(s.punch, 0.0, 1.0);
        click_ = detail::clampTo(s.click, 0.0, 1.0);
        drive_ = detail::clampTo(s.drive, 1.0, 10.0);
        if constexpr (Fast) saturator_.set(drive_);
        amp_.set(0.001, detail::clampTo(s.decay, 0.01, 4.0), sampleRate);
        drop_.set(0.0005, 0.04 + punch_ * 0.08, sampleRate);
        clickEnv_.set(0.0001, 0.008, sampleRate);
        clickFilter_.set(1500.0, sampleRate);
        toneFilter_.set(150.0 * detPow(60.0, detail::clampTo(s.tone, 0.0, 1.0)), sampleRate);
    }
    void trigger(double velocity) noexcept {
        clear();
        velocity_ = detail::clampTo(velocity, 0.0, 1.0);
        amp_.trigger();
        drop_.trigger();
        clickEnv_.trigger();
    }
    void choke() noexcept { choke_.start(sr_); }
    double next() noexcept {
        if (!active()) return 0.0;
        const double d = drop_.next();
        const double f = tune_ * (1.0 + 10.0 * punch_ * d * d);
        double body = 0.0;
        if constexpr (Fast) body = fastSinCycles(phase_);
        else body = sineWave(phase_);
        phase_ = wrap01(phase_ + f / sr_);
        const double click = clickEnv_.next() * click_ * clickFilter_.high(noise_.next());
        double y = 0.0;
        if constexpr (Fast) y = saturator_.process((body + click) * amp_.next());
        else y = drive((body + click) * amp_.next(), drive_);
        y = toneFilter_.low(y) * velocity_ * choke_.next();
        if (!amp_.active() || choke_.done()) clear();
        return y;
    }
    bool active() const noexcept { return amp_.active(); }
    void clear() noexcept {
        amp_.clear();
        drop_.clear();
        clickEnv_.clear();
        clickFilter_.clear();
        toneFilter_.clear();
        choke_.clear();
        noise_.reset();
        phase_ = 0.0;
    }

private:
    AdEnvelope amp_, drop_, clickEnv_;
    OnePole clickFilter_, toneFilter_;
    Noise noise_{0x4b1c};
    detail::Choke choke_;
    Saturator saturator_;
    double sr_ = 48000.0, tune_ = 48.0, punch_ = 0.6, click_ = 0.3, drive_ = 1.5, velocity_ = 1.0, phase_ = 0.0;
};
using KickVoice = BasicKickVoice<false>;
using FastKickVoice = BasicKickVoice<true>;

// Snare: a short two-mode body (triangle and sine, with a little pitch drop) plus high-passed noise.
struct SnareSettings {
    double tune = 185.0;   // the body's pitch, Hz 80..400
    double body = 0.07;    // seconds the body rings
    double snappy = 0.18;  // seconds the noise rings
    double tone = 2500.0;  // lowest noise frequency let through, Hz (higher is thinner)
    double mix = 0.5;      // 0 body only .. 1 noise only
};

class SnareVoice {
public:
    void set(const SnareSettings& s, double sampleRate) noexcept {
        sr_ = sampleRate;
        tune_ = detail::clampTo(s.tune, 80.0, 400.0);
        mix_ = detail::clampTo(s.mix, 0.0, 1.0);
        bodyEnv_.set(0.001, detail::clampTo(s.body, 0.01, 1.0), sampleRate);
        noiseEnv_.set(0.001, detail::clampTo(s.snappy, 0.01, 2.0), sampleRate);
        drop_.set(0.0005, 0.03, sampleRate);
        filter_.set(detail::clampTo(s.tone, 200.0, 12000.0), 0.707, sampleRate);
    }
    void trigger(double velocity) noexcept {
        clear();
        velocity_ = detail::clampTo(velocity, 0.0, 1.0);
        bodyEnv_.trigger();
        noiseEnv_.trigger();
        drop_.trigger();
    }
    void choke() noexcept { choke_.start(sr_); }
    double next() noexcept {
        if (!active()) return 0.0;
        const double d = drop_.next();
        const double f = tune_ * (1.0 + 0.6 * d * d);
        const double body = triangleWave(phase1_) * 0.6 + sineWave(phase2_) * 0.4;
        phase1_ = wrap01(phase1_ + f / sr_);
        phase2_ = wrap01(phase2_ + 1.48 * f / sr_);
        const double noise = filter_.highpass(noise_.next());
        const double y = (body * bodyEnv_.next() * 1.2 * (1.0 - mix_) + noise * noiseEnv_.next() * 2.0 * mix_) * 0.8;
        const double out = y * velocity_ * choke_.next();
        if ((!bodyEnv_.active() && !noiseEnv_.active()) || choke_.done()) clear();
        return out;
    }
    bool active() const noexcept { return bodyEnv_.active() || noiseEnv_.active(); }
    void clear() noexcept {
        bodyEnv_.clear();
        noiseEnv_.clear();
        drop_.clear();
        filter_.clear();
        choke_.clear();
        noise_.reset();
        phase1_ = phase2_ = 0.0;
    }

private:
    AdEnvelope bodyEnv_, noiseEnv_, drop_;
    Svf filter_;
    Noise noise_{0x5a4e};
    detail::Choke choke_;
    double sr_ = 48000.0, tune_ = 185.0, mix_ = 0.5, velocity_ = 1.0, phase1_ = 0.0, phase2_ = 0.0;
};

// Clap: band-passed noise in three quick bursts 10 ms apart, then a tail.
struct ClapSettings {
    double tone = 1200.0;  // the band's centre, Hz 300..6000
    double decay = 0.15;   // seconds the tail rings
};

class ClapVoice {
public:
    void set(const ClapSettings& s, double sampleRate) noexcept {
        sr_ = sampleRate;
        filter_.set(detail::clampTo(s.tone, 300.0, 6000.0), 1.5, sampleRate);
        tail_.set(0.004, detail::clampTo(s.decay, 0.02, 2.0), sampleRate);
        burstCoef_ = decayCoefficient(0.03, sampleRate);
        period_ = static_cast<uint32_t>(0.01 * sampleRate);
        if (period_ == 0) period_ = 1;
    }
    void trigger(double velocity) noexcept {
        clear();
        velocity_ = detail::clampTo(velocity, 0.0, 1.0);
        running_ = true;
    }
    void choke() noexcept { choke_.start(sr_); }
    double next() noexcept {
        if (!running_) return 0.0;
        double env = 0.0;
        if (count_ < 3 * period_) {
            if (count_ % period_ == 0) burst_ = 1.0;
            env = burst_;
            burst_ *= burstCoef_;
        } else {
            if (count_ == 3 * period_) tail_.trigger();
            env = tail_.next();
        }
        ++count_;
        const double out = filter_.bandpass(noise_.next()) * env * 1.6 * velocity_ * choke_.next();
        if ((count_ > 3 * period_ && !tail_.active()) || choke_.done()) clear();
        return out;
    }
    bool active() const noexcept { return running_; }
    void clear() noexcept {
        tail_.clear();
        filter_.clear();
        choke_.clear();
        noise_.reset();
        running_ = false;
        count_ = 0;
        burst_ = 0.0;
    }

private:
    AdEnvelope tail_;
    Svf filter_;
    Noise noise_{0xc1a9};
    detail::Choke choke_;
    double sr_ = 48000.0, velocity_ = 1.0, burst_ = 0.0, burstCoef_ = 0.0;
    uint32_t period_ = 480, count_ = 0;
    bool running_ = false;
};

// Hi-hat: six square waves at inharmonic pitches (metal) mixed with noise, high-passed. Short decays sound
// closed, long ones open.
struct HatSettings {
    double tone = 7000.0;  // lowest frequency let through, Hz 2000..14000 (higher is thinner)
    double decay = 0.04;   // seconds to -60 dB
    double metal = 0.5;    // 0 noise only .. 1 metal only
};

class HatVoice {
public:
    void set(const HatSettings& s, double sampleRate) noexcept {
        sr_ = sampleRate;
        metal_ = detail::clampTo(s.metal, 0.0, 1.0);
        filter_.set(detail::clampTo(s.tone, 1000.0, 16000.0), 1.2, sampleRate);
        env_.set(0.0005, detail::clampTo(s.decay, 0.005, 4.0), sampleRate);
        constexpr double kPitches[6] = {205.3, 304.4, 369.6, 522.7, 540.0, 800.0};
        for (int i = 0; i < 6; ++i) dt_[i] = 2.0 * kPitches[i] / sampleRate;
    }
    void trigger(double velocity) noexcept {
        clear();
        velocity_ = detail::clampTo(velocity, 0.0, 1.0);
        env_.trigger();
    }
    void choke() noexcept { choke_.start(sr_); }
    double next() noexcept {
        if (!active()) return 0.0;
        double metal = 0.0;
        for (int i = 0; i < 6; ++i) {
            metal += squareWave(phase_[i], dt_[i]);
            phase_[i] = wrap01(phase_[i] + dt_[i]);
        }
        const double x = metal * (1.0 / 6.0) * metal_ + noise_.next() * (1.0 - metal_);
        const double out = filter_.highpass(x) * env_.next() * velocity_ * choke_.next();
        if (!env_.active() || choke_.done()) clear();
        return out;
    }
    bool active() const noexcept { return env_.active(); }
    void clear() noexcept {
        env_.clear();
        filter_.clear();
        choke_.clear();
        noise_.reset();
        for (double& p : phase_) p = 0.0;
    }

private:
    AdEnvelope env_;
    Svf filter_;
    Noise noise_{0x4a75};
    detail::Choke choke_;
    double phase_[6] = {0, 0, 0, 0, 0, 0}, dt_[6] = {0, 0, 0, 0, 0, 0};
    double sr_ = 48000.0, metal_ = 0.5, velocity_ = 1.0;
};

}  // namespace caw::lib
