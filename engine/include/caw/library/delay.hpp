// C.A.W. Library: delay lines (the ping-pong delay), header-only; memory is set aside before processing.
#pragma once

#include <cmath>
#include <cstddef>
#include <vector>

#include "../detmath.hpp"

namespace caw::lib {

// A stereo ping-pong delay: each channel's echo can feed the other (cross 0: two plain echoes, 1: full
// ping-pong). prepare() allocates (call it off the audio thread); process() never does.
class PingPongDelay {
public:
    // Room for delays up to maxSeconds at sampleRate.
    void prepare(double sampleRate, double maxSeconds) {
        sampleRate_ = sampleRate;
        const size_t n = static_cast<size_t>(std::ceil(sampleRate * maxSeconds)) + 2;
        left_.assign(n, 0.0f);
        right_.assign(n, 0.0f);
        pos_ = 0;
    }
    void clear() noexcept {
        for (float& v : left_) v = 0.0f;
        for (float& v : right_) v = 0.0f;
    }
    // One frame: delaySeconds (clamped to the room), feedback 0..0.98, cross 0..1, mix 0..1 (dry/wet).
    void process(double delaySeconds, double feedback, double cross, double mix, float& l, float& r) noexcept {
        const size_t n = left_.size();
        if (n < 3) return;
        double d = finiteOr0(delaySeconds) * sampleRate_;
        d = d < 1.0 ? 1.0 : (d > static_cast<double>(n - 2) ? static_cast<double>(n - 2) : d);
        const double fb = feedback < 0.0 ? 0.0 : (feedback > 0.98 ? 0.98 : feedback);
        const double x = cross < 0.0 ? 0.0 : (cross > 1.0 ? 1.0 : cross);
        // Read d samples back, linearly between the two nearest.
        // back is pos + 2 .. pos + n - 1 (under 2n): one subtraction wraps it, and truncation is its floor.
        const double back = static_cast<double>(pos_) + static_cast<double>(n) - d;
        const size_t whole = static_cast<size_t>(back);
        const size_t i0 = whole >= n ? whole - n : whole;
        const size_t i1 = i0 + 1 == n ? 0 : i0 + 1;
        const double frac = back - static_cast<double>(whole);
        const double dl = left_[i0] + (left_[i1] - left_[i0]) * frac;
        const double dr = right_[i0] + (right_[i1] - right_[i0]) * frac;
        const double inL = finiteOr0(l), inR = finiteOr0(r);
        left_[pos_] = store(inL + fb * ((1.0 - x) * dl + x * dr));
        right_[pos_] = store(inR + fb * ((1.0 - x) * dr + x * dl));
        pos_ = pos_ + 1 == n ? 0 : pos_ + 1;
        l = static_cast<float>(inL + (dl - inL) * mix);
        r = static_cast<float>(inR + (dr - inR) * mix);
    }

private:
    // What goes back into the loop: bounded (an extreme input can't overflow to inf and latch the line
    // silent) and flushed to 0 when tiny (a decaying loop never sticks in slow subnormal numbers).
    static float store(double v) noexcept {
        if (!(v > -1e4)) return v != v ? 0.0f : -1e4f;  // NaN reads 0
        if (v > 1e4) return 1e4f;
        return (v < 1e-20 && v > -1e-20) ? 0.0f : static_cast<float>(v);
    }

    std::vector<float> left_, right_;
    size_t pos_ = 0;
    double sampleRate_ = 48000.0;
};

// A stereo chorus: each side reads a short delay swept by its own sine LFO, the right a quarter cycle
// after the left, so the two sides move apart. prepare() allocates; process() never does.
class Chorus {
public:
    void prepare(double sampleRate) {
        sampleRate_ = sampleRate;
        const size_t n = static_cast<size_t>(std::ceil(sampleRate * 0.05)) + 2;  // up to 50 ms
        left_.assign(n, 0.0f);
        right_.assign(n, 0.0f);
        pos_ = 0;
        phase_ = 0.0;
        ramp_ = false;
    }
    void clear() noexcept {
        for (float& v : left_) v = 0.0f;
        for (float& v : right_) v = 0.0f;
        phase_ = 0.0;
        ramp_ = false;
    }
    // One frame: rate in Hz, depth 0..1 (0 to 8 ms of sweep around 12 ms), mix 0..1.
    void process(double rate, double depth, double mix, float& l, float& r) noexcept {
        const size_t n = left_.size();
        if (n < 3) return;
        const double inL = finiteOr0(l), inR = finiteOr0(r);
        left_[pos_] = static_cast<float>(inL);
        right_[pos_] = static_cast<float>(inR);
        const double sweep = 0.008 * (depth < 0.0 ? 0.0 : (depth > 1.0 ? 1.0 : depth));
        const double dl = read(left_, (0.012 + sweep * 0.5 * (1.0 + detSin(phase_))) * sampleRate_);
        const double dr = read(right_, (0.012 + sweep * 0.5 * (1.0 + detCos(phase_))) * sampleRate_);
        phase_ += 2.0 * kPi * (rate < 0.0 ? 0.0 : rate) / sampleRate_;
        if (phase_ >= 2.0 * kPi) phase_ -= 2.0 * kPi;
        pos_ = pos_ + 1 == n ? 0 : pos_ + 1;
        l = static_cast<float>(inL + (dl - inL) * mix);
        r = static_cast<float>(inR + (dr - inR) * mix);
    }


    // The same chorus with its LFO at a control rate (several times cheaper): control() works out where the
    // sweep will be `frames` frames on (rate and depth as for process()), and the frames that follow glide
    // there in a straight line, one step() each; call control() again after that many steps. The sweep's
    // curve differs from process()'s by well under a thousandth of a sample at 16 frames.
    void control(double rate, double depth, uint32_t frames) noexcept {
        if (left_.size() < 3 || frames == 0) return;
        const double sweep = 0.008 * (depth < 0.0 ? 0.0 : (depth > 1.0 ? 1.0 : depth));
        if (!ramp_) {  // the first control after clear(): start where the sweep is now
            delayL_ = (0.012 + sweep * 0.5 * (1.0 + detSin(phase_))) * sampleRate_;
            delayR_ = (0.012 + sweep * 0.5 * (1.0 + detCos(phase_))) * sampleRate_;
            ramp_ = true;
        }
        phase_ += static_cast<double>(frames) * 2.0 * kPi * (rate < 0.0 ? 0.0 : rate) / sampleRate_;
        while (phase_ >= 2.0 * kPi) phase_ -= 2.0 * kPi;
        const double toL = (0.012 + sweep * 0.5 * (1.0 + detSin(phase_))) * sampleRate_;
        const double toR = (0.012 + sweep * 0.5 * (1.0 + detCos(phase_))) * sampleRate_;
        stepL_ = (toL - delayL_) / static_cast<double>(frames);
        stepR_ = (toR - delayR_) / static_cast<double>(frames);
    }
    // One frame along the sweep control() set: mix 0..1.
    void step(double mix, float& l, float& r) noexcept {
        const size_t n = left_.size();
        if (n < 3) return;
        const double inL = finiteOr0(l), inR = finiteOr0(r);
        left_[pos_] = static_cast<float>(inL);
        right_[pos_] = static_cast<float>(inR);
        const double dl = read(left_, delayL_);
        const double dr = read(right_, delayR_);
        delayL_ += stepL_;
        delayR_ += stepR_;
        pos_ = pos_ + 1 == n ? 0 : pos_ + 1;
        l = static_cast<float>(inL + (dl - inL) * mix);
        r = static_cast<float>(inR + (dr - inR) * mix);
    }

private:
    double read(const std::vector<float>& line, double samplesBack) const noexcept {
        const size_t n = line.size();
        const double d = samplesBack < 1.0 ? 1.0 : (samplesBack > static_cast<double>(n - 2) ? static_cast<double>(n - 2) : samplesBack);
        // back is pos + 2 .. pos + n - 1 (under 2n): one subtraction wraps it, and truncation is its floor.
        const double back = static_cast<double>(pos_) + static_cast<double>(n) - d;
        const size_t whole = static_cast<size_t>(back);
        const size_t i0 = whole >= n ? whole - n : whole;
        const double frac = back - static_cast<double>(whole);
        return line[i0] + (line[i0 + 1 == n ? 0 : i0 + 1] - line[i0]) * frac;
    }

    std::vector<float> left_, right_;
    size_t pos_ = 0;
    double sampleRate_ = 48000.0, phase_ = 0.0;
    bool ramp_ = false;  // control() has set a sweep
    double delayL_ = 0.0, delayR_ = 0.0, stepL_ = 0.0, stepR_ = 0.0;  // samples back now, and per step()
};

// A note division in seconds at a tempo: 1 = a whole note, 0.25 = a quarter, 0.375 = a dotted eighth.
inline double noteSeconds(double tempo, double wholeNotes) noexcept {
    const double t = tempo > 1.0 ? tempo : 1.0;
    return wholeNotes * 4.0 * 60.0 / t;
}

}  // namespace caw::lib
