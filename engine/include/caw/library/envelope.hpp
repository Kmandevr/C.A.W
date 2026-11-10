// C.A.W. Library: envelopes (attack-decay, ADSR) and a glide, with the .caw ad/env.adsr timing; header-only.
#pragma once

#include <cmath>

#include "../detmath.hpp"

namespace caw::lib {

// The per-sample factor that falls 60 dB in `seconds` (0 for no time: an instant drop).
inline double decayCoefficient(double seconds, double sampleRate) noexcept {
    return seconds > 0.0 && std::isfinite(seconds) ? detExp(-6.907755278982137 / (seconds * sampleRate)) : 0.0;
}
// The per-sample rise of a linear attack lasting `seconds` (2 for no time: one sample).
inline double attackStep(double seconds, double sampleRate) noexcept {
    return seconds > 0.0 && std::isfinite(seconds) ? 1.0 / (seconds * sampleRate) : 2.0;
}

// Attack-decay, as the .caw ad(): trigger() starts a linear attack from the level it is at (so a retrigger
// doesn't click), then it falls 60 dB in `decay` seconds and stops. set() costs an exp; call it when the
// times change.
class AdEnvelope {
public:
    void set(double attack, double decay, double sampleRate) noexcept {
        inc_ = attackStep(attack, sampleRate);
        coef_ = decayCoefficient(decay, sampleRate);
    }
    void trigger() noexcept { stage_ = 1; }
    double next() noexcept {
        if (stage_ == 1) {
            level_ += inc_;
            if (level_ >= 1.0) {
                level_ = 1.0;
                stage_ = 2;
            }
        } else if (stage_ == 2) {
            level_ *= coef_;
            if (level_ < 1e-6) {
                level_ = 0.0;
                stage_ = 0;
            }
        }
        return level_;
    }
    double level() const noexcept { return level_; }
    bool active() const noexcept { return stage_ != 0; }
    void clear() noexcept {
        level_ = 0.0;
        stage_ = 0;
    }

private:
    double level_ = 0, inc_ = 2, coef_ = 0;
    int stage_ = 0;  // 0 idle, 1 attack, 2 decay
};

// ADSR, as the .caw env.adsr(): gateOn() attacks (from the current level), it decays to the sustain level
// (60 dB of the way in `decay` seconds) and holds while the gate is on, and gateOff() releases (60 dB in
// `release` seconds). A moving sustain glides instead of clicking.
class Adsr {
public:
    void set(double attack, double decay, double sustain, double release, double sampleRate) noexcept {
        inc_ = attackStep(attack, sampleRate);
        decayCoef_ = decayCoefficient(decay, sampleRate);
        releaseCoef_ = decayCoefficient(release, sampleRate);
        const double s = finiteOr0(sustain);
        sustain_ = s < 0.0 ? 0.0 : (s > 1.0 ? 1.0 : s);
    }
    void gateOn() noexcept { stage_ = 1; }
    void gateOff() noexcept {
        if (stage_ != 0) stage_ = 3;
    }
    double next() noexcept {
        switch (stage_) {
            case 1:
                level_ += inc_;
                if (level_ >= 1.0) {
                    level_ = 1.0;
                    stage_ = 2;
                }
                break;
            case 2: level_ = sustain_ + (level_ - sustain_) * decayCoef_; break;
            case 3:
                level_ *= releaseCoef_;
                if (level_ < 1e-6) {
                    level_ = 0.0;
                    stage_ = 0;
                }
                break;
            default: break;
        }
        return level_;
    }
    double level() const noexcept { return level_; }
    bool active() const noexcept { return stage_ != 0; }
    bool releasing() const noexcept { return stage_ == 3; }
    void clear() noexcept {
        level_ = 0.0;
        stage_ = 0;
    }

private:
    double level_ = 0, inc_ = 2, decayCoef_ = 0, releaseCoef_ = 0, sustain_ = 1;
    int stage_ = 0;  // 0 idle, 1 attack, 2 decay and sustain, 3 release
};

// A glide (portamento): moves toward a target exponentially, about 99 % of the way in `seconds`.
// jump() sets the value at once; glideTo() costs an exp.
class Glide {
public:
    void jump(double value) noexcept {
        value_ = target_ = finiteOr0(value);
        coef_ = 0.0;
    }
    void glideTo(double target, double seconds, double sampleRate) noexcept {
        target_ = finiteOr0(target);
        coef_ = seconds > 0.0 && std::isfinite(seconds) ? detExp(-4.605170185988091 / (seconds * sampleRate)) : 0.0;
    }
    double next() noexcept { return value_ = target_ + (value_ - target_) * coef_; }
    double value() const noexcept { return value_; }
    double target() const noexcept { return target_; }

private:
    double value_ = 0, target_ = 0, coef_ = 0;
};

}  // namespace caw::lib
