// C.A.W. Library: delay lines (the ping-pong delay), header-only; memory is set aside before processing.
#pragma once

#include <cmath>
#include <cstddef>
#include <vector>

#include "../detmath.hpp"

namespace caw::lib {

// A stereo ping-pong delay: each channel's echo can feed the other (cross 0: two plain echoes, 1: full
// ping-pong, where the input enters on the left (summed) and the echoes alternate sides, even for a centred sound). prepare() allocates (call it off the audio thread); process() never does.
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
        const double back = static_cast<double>(pos_) + static_cast<double>(n) - d;
        const size_t i0 = static_cast<size_t>(back) % n;
        const size_t i1 = (i0 + 1) % n;
        const double frac = back - std::floor(back);
        const double dl = left_[i0] + (left_[i1] - left_[i0]) * frac;
        const double dr = right_[i0] + (right_[i1] - right_[i0]) * frac;
        const double inL = finiteOr0(l), inR = finiteOr0(r);
        // Feeding: with cross 0 each side echoes its own input. Toward full ping-pong the right input moves over to
        // the left (summed, like a ping-pong delay's mono input) and the loop carries it across, so even a centred
        // sound bounces left, right, left. Feeding each side its own input would keep a centred sound centred.
        const double feedL = inL + x * inR;
        const double feedR = (1.0 - x) * inR;
        left_[pos_] = store(feedL + fb * ((1.0 - x) * dl + x * dr));
        right_[pos_] = store(feedR + fb * ((1.0 - x) * dr + x * dl));
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
    }
    void clear() noexcept {
        for (float& v : left_) v = 0.0f;
        for (float& v : right_) v = 0.0f;
        phase_ = 0.0;
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

private:
    double read(const std::vector<float>& line, double samplesBack) const noexcept {
        const size_t n = line.size();
        const double d = samplesBack < 1.0 ? 1.0 : (samplesBack > static_cast<double>(n - 2) ? static_cast<double>(n - 2) : samplesBack);
        const double back = static_cast<double>(pos_) + static_cast<double>(n) - d;
        const size_t i0 = static_cast<size_t>(back) % n;
        const double frac = back - std::floor(back);
        return line[i0] + (line[(i0 + 1) % n] - line[i0]) * frac;
    }

    std::vector<float> left_, right_;
    size_t pos_ = 0;
    double sampleRate_ = 48000.0, phase_ = 0.0;
};

// A note division in seconds at a tempo: 1 = a whole note, 0.25 = a quarter, 0.375 = a dotted eighth.
inline double noteSeconds(double tempo, double wholeNotes) noexcept {
    const double t = tempo > 1.0 ? tempo : 1.0;
    return wholeNotes * 4.0 * 60.0 / t;
}

}  // namespace caw::lib
