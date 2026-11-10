// C.A.W. Library: a low-frequency oscillator (seven shapes, Hz or tempo-synced, per-sample and per-block); header-only.
#pragma once

#include <cmath>
#include <cstdint>

#include "../detmath.hpp"

namespace caw::lib {

enum class LfoShape {
    Sine,          // starts at 0 and rises
    Triangle,      // starts at 0 and rises, peaks a quarter cycle in
    SawUp,         // -1 rising to +1
    SawDown,       // +1 falling to -1
    Square,        // +1 for the first `pulseWidth` of the cycle, -1 for the rest
    SampleHold,    // a new random value at the start of each cycle, held flat
    SmoothRandom,  // glides from one random value to the next over each cycle (no corners)
};

// An LFO for modulation: vibrato, tremolo, filter sweeps, auto-pan. Output is -1..1 (bipolar) or 0..1
// (unipolar). It allocates nothing and has no prepare() beyond the sample rate, so it is safe to create
// per voice.
//
// The shapes are not band-limited: at modulation rates (below ~50 Hz) the corners of a saw or square are
// what you want. For an audible-rate oscillator use oscillator.hpp or wavetable.hpp instead.
//
// The two random shapes are a pure function of (seed, cycle number): the value in cycle k is
// hash32(seed, k). So the same seed gives the same "random" movement on every device and every render, and
// after syncToBeat() it follows the song position, not how long the plug-in has been running.
//
// Cost: next() is a phase add plus the shape (one detSin for Sine, a few flops for the rest). If what you
// modulate only needs a new value every block (a filter cutoff you set every 16-64 frames), call
// block(frames) once per block instead: the shape is evaluated once and the phase jumps the whole block.
class Lfo {
public:
    void prepare(double sampleRate) noexcept {
        sampleRate_ = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
        updateStep();
    }

    void setShape(LfoShape shape) noexcept { shape_ = shape; }
    // Free-running rate in Hz (held to 0 .. a quarter of the sample rate).
    void setRateHz(double hz) noexcept {
        hz_ = finiteOr0(hz);
        updateStep();
    }
    // Tempo-synced rate: one cycle every `beats` beats at `tempoBpm` (1 = a quarter note at 4/4, 4 = a bar,
    // 0.5 = an eighth, 1.5 = a dotted quarter). Call it again when the tempo changes.
    void setRateBeats(double beats, double tempoBpm) noexcept {
        const double b = finiteOr0(beats), t = finiteOr0(tempoBpm);
        setRateHz(b > 0.0 && t > 0.0 ? t / (60.0 * b) : 0.0);
    }
    // Where in the cycle the LFO starts (0..1 cycles; 0.25 starts a sine at its peak). Changing it shifts
    // the running phase by the difference, so two LFOs one quarter apart stay one quarter apart.
    void setPhaseOffset(double cycles) noexcept {
        const double o = wrap(finiteOr0(cycles));
        phase_ = wrap(phase_ + o - offset_);
        offset_ = o;
    }
    // The Square's duty cycle, 0.01..0.99 (0.5: a square wave).
    void setPulseWidth(double width) noexcept {
        const double w = finiteOr0(width);
        pulseWidth_ = w < 0.01 ? 0.01 : (w > 0.99 ? 0.99 : w);
    }
    void setUnipolar(bool unipolar) noexcept { unipolar_ = unipolar; }
    void setSeed(uint32_t seed) noexcept { key_ = hash32(seed ^ 0x9e3779b9U); }

    // Restart the cycle at the phase offset (a key-synced LFO calls this on every note on).
    void retrigger() noexcept {
        phase_ = offset_;
        cycle_ = 0;
    }
    // Lock to the transport: the phase becomes (beatPosition / beats) + offset, and the random shapes use
    // the cycle number counted from beat 0. Call it at Play and whenever the position jumps; between calls
    // the LFO runs freely at its rate, which matches the transport as long as the tempo does.
    void syncToBeat(double beatPosition, double beats) noexcept {
        const double b = finiteOr0(beats);
        if (!(b > 0.0)) return;
        const double cycles = finiteOr0(beatPosition) / b + offset_;
        const double whole = std::floor(cycles);
        phase_ = cycles - whole;
        cycle_ = static_cast<uint32_t>(static_cast<int64_t>(whole));
    }

    // The value at the current phase, then one sample forward.
    double next() noexcept {
        const double v = value();
        advance(1);
        return v;
    }
    // Per-block: the value at the start of the block, then `frames` samples forward.
    double block(int frames) noexcept {
        const double v = value();
        advance(frames);
        return v;
    }
    // Fill out[0..frames) with per-sample values.
    void process(float* out, int frames) noexcept {
        for (int i = 0; i < frames; ++i) out[i] = static_cast<float>(next());
    }

    // The value at the current phase, without moving.
    double value() const noexcept {
        const double v = bipolar();
        return unipolar_ ? 0.5 * (v + 1.0) : v;
    }
    // Move the phase on by `frames` samples (cheap for any count: one multiply, no loop).
    void advance(int frames) noexcept {
        if (frames <= 0) return;
        const double p = phase_ + step_ * frames;
        const double whole = std::floor(p);
        phase_ = p - whole;
        cycle_ += static_cast<uint32_t>(whole);
    }

    double phase() const noexcept { return phase_; }
    uint32_t cycle() const noexcept { return cycle_; }
    double rateHz() const noexcept { return step_ * sampleRate_; }

private:
    static double wrap(double x) noexcept { return x - std::floor(x); }

    void updateStep() noexcept {
        double s = hz_ / sampleRate_;
        step_ = s < 0.0 ? 0.0 : (s > 0.25 ? 0.25 : s);
    }
    // The random value of cycle k, -1..1.
    double randomAt(uint32_t k) const noexcept {
        return static_cast<double>(hash32(k ^ key_)) * (1.0 / 2147483648.0) - 1.0;
    }

    double bipolar() const noexcept {
        const double t = phase_;
        switch (shape_) {
            case LfoShape::Sine: return detSin(kTwoPi * t);
            case LfoShape::Triangle: return t < 0.25 ? 4.0 * t : (t < 0.75 ? 2.0 - 4.0 * t : 4.0 * t - 4.0);
            case LfoShape::SawUp: return 2.0 * t - 1.0;
            case LfoShape::SawDown: return 1.0 - 2.0 * t;
            case LfoShape::Square: return t < pulseWidth_ ? 1.0 : -1.0;
            case LfoShape::SampleHold: return randomAt(cycle_);
            case LfoShape::SmoothRandom: {
                // Smoothstep (3t^2 - 2t^3) between this cycle's value and the next: the slope is 0 at both
                // ends, so the curve has no corners, and it costs no trig.
                const double a = randomAt(cycle_), b = randomAt(cycle_ + 1);
                const double s = t * t * (3.0 - 2.0 * t);
                return a + (b - a) * s;
            }
        }
        return 0.0;
    }

    double sampleRate_ = 48000.0, hz_ = 1.0, step_ = 1.0 / 48000.0;
    double phase_ = 0.0, offset_ = 0.0, pulseWidth_ = 0.5;
    uint32_t cycle_ = 0, key_ = hash32(1U ^ 0x9e3779b9U);
    LfoShape shape_ = LfoShape::Sine;
    bool unipolar_ = false;
};

}  // namespace caw::lib
