// C.A.W. Library: a stereo algorithmic reverb (8-line feedback delay network, Hadamard mixing); header-only, original code.
#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "../detmath.hpp"

namespace caw::lib {

// The reverb's knobs. set() clamps every value to the range given here.
struct ReverbSettings {
    double size = 0.5;      // 0..1: room size (scales the delay lengths, about 15 ms .. 150 ms per line)
    double decay = 2.0;     // seconds for the tail to fall 60 dB (RT60), 0.05 .. 60
    double damping = 0.3;   // 0..1: high frequencies die faster (0: none, 1: a dark room, ~1 kHz)
    double preDelay = 0.0;  // seconds before the reverb starts, 0 .. the prepare() maximum
    double width = 1.0;     // 0 (mono tail) .. 1 (natural) .. 2 (extra wide)
    double mix = 0.3;       // 0 (dry only) .. 1 (wet only)
    // Line modulation, 0 (none: every read a whole sample, the original sound) .. 1 (each line's length swept by up
    // to 0.8 ms at its own rate near `modRate` Hz): blurs the tail's resonances, as a large hall's air does.
    double modulation = 0.0;
    double modRate = 0.7;   // Hz, 0.05 .. 5
    // Freeze: the loop keeps what it holds forever (gain 1, no damping) and takes no new input.
    bool freeze = false;
};

// How it works (an 8x8 feedback delay network, FDN):
//
//   in -> pre-delay -> 4 diffusing all-passes per side -> + -> 8 delay lines -> damping -> decay gain -+
//                                                         ^                                         |
//                                                         +------ 8x8 Hadamard mixing matrix <------+
//
// Each loop round, the 8 line outputs are mixed by a scaled Hadamard matrix: every output is +/- every
// input over sqrt(8). That matrix is orthogonal (it keeps energy exactly), so the network on its own
// neither grows nor fades, and the decay is set only by each line's gain g = 10^(-3 * length / (RT60 *
// rate)): a line of any length loses exactly 60 dB per RT60 seconds, so all lines fade together. The
// mixing is done as a fast Walsh-Hadamard transform: 24 additions instead of 64 multiplies.
// The line lengths are spread so their echoes rarely coincide (no single pitch rings), and a one-pole
// low-pass in each loop makes the highs decay faster, as air and soft walls do.
//
// Real-time rules: prepare() allocates every buffer (call it off the audio thread); process() and set()
// never allocate, lock or branch on data-dependent loops. NaN and Inf inputs are read as 0, and what goes
// back into a loop is bounded and flushed to exactly 0 when tiny, so a long silent tail never runs in
// slow subnormal numbers (denormal-safe without relying on the CPU's flush-to-zero mode).
//
// Changing `size` moves the read positions in whole samples, which can click on a playing tail; treat it
// as a preset choice (or ramp `mix` down around it). decay, damping, width and mix are click-free.
class Reverb {
public:
    // Allocate for `sampleRate` and pre-delays up to `maxPreDelaySeconds`. `maxBlock` is the host's
    // largest block; the reverb processes any block length, so it is accepted only for symmetry with
    // activate().
    void prepare(double sampleRate, int maxBlock, double maxPreDelaySeconds = 0.5) {
        (void)maxBlock;
        rate_ = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
        const double scale = rate_ / 1000.0;
        size_t total = 0;
        modRoom_ = static_cast<size_t>(2.0 * kMaxModSeconds * rate_) + 2;  // room for the deepest sweep (2 x depth)
        for (int i = 0; i < 8; ++i) {  // room for the longest size (scale 1.0 at size 1)
            lineMask_[i] = pow2Above(static_cast<size_t>(kLineMs[i] * kMaxScale * scale) + 2 + modRoom_) - 1;
            lineStart_[i] = total;
            total += lineMask_[i] + 1;
        }
        for (int i = 0; i < 8; ++i) {
            apLen_[i] = static_cast<size_t>(kAllpassMs[i] * scale + 0.5);
            if (apLen_[i] < 1) apLen_[i] = 1;
            apMask_[i] = pow2Above(apLen_[i] + 1) - 1;
            apStart_[i] = total;
            total += apMask_[i] + 1;
        }
        const double pd = maxPreDelaySeconds > 0.0 && std::isfinite(maxPreDelaySeconds) ? maxPreDelaySeconds : 0.0;
        preMask_ = pow2Above(static_cast<size_t>(pd * rate_) + 2) - 1;
        preStart_ = total;
        total += 2 * (preMask_ + 1);  // left then right
        maxPreFrames_ = static_cast<size_t>(pd * rate_ + 0.5);  // the line has room for at least this
        memory_.assign(total, 0.0f);
        pos_ = 0;
        set(settings_);
        clear();
    }

    // Recompute the coefficients (8 detPow and one detExp). Call it when a knob moves, not every sample.
    void set(const ReverbSettings& s) noexcept {
        settings_ = s;
        const double size = clamp(s.size, 0.0, 1.0);
        const double rt60 = clamp(s.decay, 0.05, 60.0);
        const double lineScale = kMinScale + (kMaxScale - kMinScale) * size;
        for (int i = 0; i < 8; ++i) {
            size_t len = static_cast<size_t>(kLineMs[i] * lineScale * rate_ / 1000.0 + 0.5);
            if (len < 1) len = 1;
            if (len + modRoom_ > lineMask_[i]) len = lineMask_[i] - modRoom_;
            lineLen_[i] = len;
            gain_[i] = s.freeze ? 1.0 : detPow(10.0, -3.0 * static_cast<double>(len) / (rt60 * rate_));
        }
        const double d = s.freeze ? 0.0 : clamp(s.damping, 0.0, 1.0);
        // Loop low-pass cutoff from 20 kHz (damping 0: the filter is skipped) down to 1 kHz (damping 1).
        dampK_ = d <= 0.0 ? 1.0 : 1.0 - detExp(-kTwoPi * 20000.0 * detPow(0.05, d) / rate_);
        freeze_ = s.freeze;
        modDepth_ = clamp(s.modulation, 0.0, 1.0) * kMaxModSeconds * rate_;
        const double modHz = clamp(s.modRate, 0.05, 5.0);
        if (modDepth_ > 0.0 && modHz != modHz_) {
            modHz_ = modHz;
            for (int i = 0; i < 8; ++i) {  // each line its own rate, so the sweeps never line up
                const double w = kTwoPi * modHz * (1.0 + 0.137 * i) / rate_;
                rotC_[i] = detCos(w);
                rotS_[i] = detSin(w);
            }
        }
        double pre = clamp(s.preDelay, 0.0, 1e9) * rate_;
        preFrames_ = static_cast<size_t>(pre > static_cast<double>(maxPreFrames_) ? maxPreFrames_ : pre + 0.5);
        width_ = clamp(s.width, 0.0, 2.0);
        mix_ = clamp(s.mix, 0.0, 1.0);
    }
    const ReverbSettings& settings() const noexcept { return settings_; }

    // Silence the tail (at Play, after a mute) without reallocating.
    void clear() noexcept {
        for (float& v : memory_) v = 0.0f;
        for (double& v : lp_) v = 0.0;
        for (int i = 0; i < 8; ++i) {  // the sweeps start spread around the circle
            modC_[i] = detCos(kTwoPi * i / 8.0);
            modS_[i] = detSin(kTwoPi * i / 8.0);
        }
        modCount_ = 0;
    }

    // One stereo frame, in place.
    void process(float& left, float& right) noexcept {
        if (memory_.empty()) return;
        const double inL = finiteOr0(left), inR = finiteOr0(right);

        // Pre-delay (a plain delay line per side).
        float* preL = &memory_[preStart_];
        float* preR = preL + preMask_ + 1;
        const size_t pw = pos_ & preMask_;
        preL[pw] = static_cast<float>(inL);
        preR[pw] = static_cast<float>(inR);
        const size_t pr = (pos_ - preFrames_) & preMask_;
        double xl = preL[pr], xr = preR[pr];
        if (freeze_) xl = xr = 0.0;  // frozen: the loop takes nothing new

        // Input diffusion: Schroeder all-passes smear each click into a burst, so the tail is dense from
        // the first echo. Lines 0-3 diffuse the left, 4-7 the right.
        for (int i = 0; i < 4; ++i) xl = allpass(i, xl);
        for (int i = 4; i < 8; ++i) xr = allpass(i, xr);

        // Read the 8 line outputs, damp them and apply their decay gains.
        double v[8];
        if (modDepth_ > 0.0) {
            // Each line read between samples, modDepth_ * (1 + sin) further back: a quadrature oscillator per line
            // (one rotation, four multiplies), its radius pulled back to 1 every 1024 samples.
            for (int i = 0; i < 8; ++i) {
                const double c = modC_[i] * rotC_[i] - modS_[i] * rotS_[i];
                modS_[i] = modS_[i] * rotC_[i] + modC_[i] * rotS_[i];
                modC_[i] = c;
                const float* line = &memory_[lineStart_[i]];
                const double back = static_cast<double>(lineLen_[i]) + modDepth_ * (1.0 + modS_[i]);
                const size_t whole = static_cast<size_t>(back);
                const double frac = back - static_cast<double>(whole);
                const double a = line[(pos_ - whole) & lineMask_[i]], b = line[(pos_ - whole - 1) & lineMask_[i]];
                const double y = a + (b - a) * frac;
                lp_[i] += (y - lp_[i]) * dampK_;
                v[i] = lp_[i] * gain_[i];
            }
            if (++modCount_ >= 1024) {
                modCount_ = 0;
                for (int i = 0; i < 8; ++i) {
                    const double k = 1.5 - 0.5 * (modC_[i] * modC_[i] + modS_[i] * modS_[i]);
                    modC_[i] *= k;
                    modS_[i] *= k;
                }
            }
        } else {
            for (int i = 0; i < 8; ++i) {
                const float* line = &memory_[lineStart_[i]];
                const double y = line[(pos_ - lineLen_[i]) & lineMask_[i]];
                lp_[i] += (y - lp_[i]) * dampK_;
                v[i] = lp_[i] * gain_[i];
            }
        }
        // Stereo taps before mixing: two orthogonal sign patterns give a decorrelated left and right.
        double wetL = v[0] - v[1] + v[2] - v[3] + v[4] - v[5] + v[6] - v[7];
        double wetR = v[0] + v[1] - v[2] - v[3] + v[4] + v[5] - v[6] - v[7];
        wetL *= kOutScale;
        wetR *= kOutScale;

        hadamard8(v);
        // Feed back the mixed lines plus the input (left into even lines, right into odd).
        for (int i = 0; i < 8; ++i) {
            float* line = &memory_[lineStart_[i]];
            line[pos_ & lineMask_[i]] = store(v[i] + ((i & 1) ? xr : xl));
        }
        ++pos_;

        // Width by mid/side, then dry/wet.
        const double mid = 0.5 * (wetL + wetR), side = 0.5 * (wetL - wetR) * width_;
        wetL = mid + side;
        wetR = mid - side;
        left = static_cast<float>(inL + (wetL - inL) * mix_);
        right = static_cast<float>(inR + (wetR - inR) * mix_);
    }

    // A block, in place.
    void process(float* left, float* right, int frames) noexcept {
        for (int i = 0; i < frames; ++i) process(left[i], right[i]);
    }

    // Frames until the tail falls below -90 dB after the input stops: 1.5 RT60 plus the pre-delay (for a
    // component's tailFrames).
    uint64_t tailFrames() const noexcept {
        return static_cast<uint64_t>(1.5 * clamp(settings_.decay, 0.05, 60.0) * rate_) + preFrames_ + 1;
    }

private:
    // Line lengths in ms at size 1, spread between 1 : 2.5 and not multiples of each other.
    static constexpr double kLineMs[8] = {58.6, 69.4, 77.1, 87.3, 98.9, 109.7, 121.3, 139.9};
    static constexpr double kMinScale = 0.25, kMaxScale = 1.0;
    // Input all-pass lengths (ms), gain 0.6: short and mutually prime-ish, as in classic diffusers.
    static constexpr double kAllpassMs[8] = {4.77, 3.59, 12.73, 9.31, 4.31, 3.83, 11.89, 8.71};
    static constexpr double kAllpassGain = 0.6;
    static constexpr double kOutScale = 0.35355339059327376;  // 1/sqrt(8)
    static constexpr double kMaxModSeconds = 0.0008;           // the deepest sweep at modulation 1

    static double clamp(double x, double lo, double hi) noexcept {
        if (!(x >= lo)) return lo;  // below the range, or NaN: the minimum
        return x > hi ? hi : x;
    }
    static size_t pow2Above(size_t n) noexcept {
        size_t p = 1;
        while (p < n) p <<= 1;
        return p;
    }
    // Bounded (an extreme input can't overflow to inf and latch the loop) and flushed to 0 when tiny.
    static float store(double v) noexcept {
        if (!(v > -1e4)) return v != v ? 0.0f : -1e4f;
        if (v > 1e4) return 1e4f;
        return (v < 1e-20 && v > -1e-20) ? 0.0f : static_cast<float>(v);
    }
    // In-place scaled Hadamard (orthonormal): three butterfly stages, then 1/sqrt(8).
    static void hadamard8(double* v) noexcept {
        for (int h = 1; h < 8; h <<= 1)
            for (int i = 0; i < 8; i += h << 1)
                for (int j = i; j < i + h; ++j) {
                    const double a = v[j], b = v[j + h];
                    v[j] = a + b;
                    v[j + h] = a - b;
                }
        for (int i = 0; i < 8; ++i) v[i] *= kOutScale;
    }
    // Schroeder all-pass: y = -g x + d, buffer <- x + g y, with d the value `len` samples back.
    double allpass(int i, double x) noexcept {
        float* buf = &memory_[apStart_[i]];
        const double d = buf[(pos_ - apLen_[i]) & apMask_[i]];
        const double y = d - kAllpassGain * x;
        buf[pos_ & apMask_[i]] = store(x + kAllpassGain * y);
        return y;
    }

    std::vector<float> memory_;  // every line, all-pass and the pre-delay, one allocation
    size_t lineStart_[8] = {}, lineMask_[8] = {}, lineLen_[8] = {};
    size_t apStart_[8] = {}, apMask_[8] = {}, apLen_[8] = {};
    size_t preStart_ = 0, preMask_ = 0, preFrames_ = 0, maxPreFrames_ = 0;
    size_t pos_ = 0;  // one write position for every line; each line masks it to its own length
    double gain_[8] = {}, lp_[8] = {};
    double rate_ = 48000.0, dampK_ = 1.0, width_ = 1.0, mix_ = 0.3;
    size_t modRoom_ = 0;
    double modDepth_ = 0.0, modHz_ = -1.0;  // samples of sweep; the rate the rotations were made for
    double modC_[8] = {}, modS_[8] = {}, rotC_[8] = {}, rotS_[8] = {};
    uint32_t modCount_ = 0;
    bool freeze_ = false;
    ReverbSettings settings_;
};

}  // namespace caw::lib
