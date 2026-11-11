// C.A.W. Library: a radix-2 FFT and a uniformly partitioned stereo convolver whose work is spread over each block; header-only.
#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "../detmath.hpp"

namespace caw::lib {

// An in-place complex radix-2 FFT (decimation in time, a bit-reversed load, twiddles from detSin/detCos, so the
// same bits on every platform built without fused multiply-add). prepare() allocates; forward() and inverse()
// never do. inverse() is unscaled (divide by size() yourself).
class Fft {
public:
    void prepare(uint32_t size) {
        n_ = 1;
        while (n_ < size) n_ <<= 1;
        uint32_t bits = 0;
        while ((1u << bits) < n_) ++bits;
        rev_.resize(n_);
        for (uint32_t i = 0; i < n_; ++i) {
            uint32_t r = 0;
            for (uint32_t k = 0; k < bits; ++k) r |= ((i >> k) & 1u) << (bits - 1 - k);
            rev_[i] = r;
        }
        cos_.resize(n_ / 2);
        sin_.resize(n_ / 2);
        for (uint32_t i = 0; i < n_ / 2; ++i) {
            cos_[i] = detCos(kTwoPi * i / n_);
            sin_[i] = -detSin(kTwoPi * i / n_);
        }
    }
    uint32_t size() const noexcept { return n_; }
    void forward(double* re, double* im) noexcept { run(re, im, 1.0); }
    void inverse(double* re, double* im) noexcept { run(re, im, -1.0); }

private:
    void run(double* re, double* im, double sign) noexcept {
        for (uint32_t i = 0; i < n_; ++i) {
            const uint32_t r = rev_[i];
            if (r > i) {
                double t = re[i];
                re[i] = re[r], re[r] = t;
                t = im[i];
                im[i] = im[r], im[r] = t;
            }
        }
        for (uint32_t half = 1; half < n_; half <<= 1) {
            const uint32_t step = n_ / (half * 2);
            for (uint32_t start = 0; start < n_; start += half * 2)
                for (uint32_t k = 0; k < half; ++k) {
                    const double wr = cos_[k * step], wi = sign * sin_[k * step];
                    const uint32_t p = start + k, q = p + half;
                    const double tr = re[q] * wr - im[q] * wi, ti = re[q] * wi + im[q] * wr;
                    re[q] = re[p] - tr;
                    im[q] = im[p] - ti;
                    re[p] += tr;
                    im[p] += ti;
                }
        }
    }

    uint32_t n_ = 0;
    std::vector<uint32_t> rev_;
    std::vector<double> cos_, sin_;
};

// Stereo convolution (left input with the left response, right with the right) by uniformly partitioned
// overlap-save (UPOLS): the response is cut into P partitions of B frames, each held as the spectrum of 2B
// points; each block of B input frames is transformed once (both sides in one complex FFT: left in the real part,
// right in the imaginary part, split afterwards by the FFT's symmetry) into a frequency-domain delay line, and
// the output block is the inverse FFT of sum_k X[n-k] H[k], of which the last B points are kept. The latency is B
// frames.
//
// The multiply-adds for partitions 1..P-1 only need input blocks already seen, so they are done ahead, in 16
// equal shares spread over the block (every B/16 frames), and a block boundary does only partition 0 and the two
// FFTs: the cost per frame stays even, and because the shares are counted in frames, any host block size gives
// the same bits.
//
// The response is held in two banks: stage() fills the bank not playing, one partition per call (a caller spreads
// the calls over time), and commit() makes it play from the next block on, its first block crossfaded from the
// old response over B frames (both run for that one block), so a new response never clicks.
//
// Real-time rules: prepare() allocates everything; process(), stage() and commit() never allocate or lock.
class PartitionedConvolver {
public:
    static constexpr uint32_t kShares = 16;

    // Partitions of `block` frames (a power of two, at least 2 * kShares) and responses up to `maxFrames` long.
    void prepare(uint32_t block, uint32_t maxFrames) {
        b_ = 2 * kShares;
        while (b_ < block) b_ <<= 1;
        bins_ = b_ + 1;
        maxParts_ = (maxFrames + b_ - 1) / b_;
        if (maxParts_ < 1) maxParts_ = 1;
        fft_.prepare(2 * b_);
        re_.assign(2 * b_, 0.0);
        im_.assign(2 * b_, 0.0);
        const size_t bank = static_cast<size_t>(maxParts_) * 2 * bins_;
        for (int k = 0; k < 2; ++k) {
            hRe_[k].assign(bank, 0.0f);
            hIm_[k].assign(bank, 0.0f);
            parts_[k] = 0;
            accRe_[k].assign(2 * bins_, 0.0f);
            accIm_[k].assign(2 * bins_, 0.0f);
        }
        xRe_.assign(bank, 0.0f);
        xIm_.assign(bank, 0.0f);
        inL_.assign(2 * b_, 0.0f);
        inR_.assign(2 * b_, 0.0f);
        outL_.assign(b_, 0.0f);
        outR_.assign(b_, 0.0f);
        fadeL_.assign(b_, 0.0f);
        fadeR_.assign(b_, 0.0f);
        active_ = 0;
        clear();
    }
    uint32_t block() const noexcept { return b_; }
    uint32_t latency() const noexcept { return b_; }
    uint32_t maxPartitions() const noexcept { return maxParts_; }
    uint32_t partitions() const noexcept { return parts_[active_]; }
    // A new response may be staged now (none is waiting to play or fading in).
    bool canStage() const noexcept { return !pending_ && !fading_; }

    // The input history and output to silence (the response stays).
    void clear() noexcept {
        for (float& v : xRe_) v = 0.0f;
        for (float& v : xIm_) v = 0.0f;
        for (float& v : inL_) v = 0.0f;
        for (float& v : inR_) v = 0.0f;
        for (float& v : outL_) v = 0.0f;
        for (float& v : outR_) v = 0.0f;
        for (int k = 0; k < 2; ++k) {
            for (float& v : accRe_[k]) v = 0.0f;
            for (float& v : accIm_[k]) v = 0.0f;
        }
        pos_ = 0;
        head_ = 0;
        share_ = 0;
        if (fading_) {  // a fade cut short: the new response plays from here
            active_ ^= 1;
            fading_ = false;
        }
        if (pending_) {
            active_ ^= 1;
            pending_ = false;
        }
    }

    // Partition `index` of the staged response from `frames` (at most block()) frames of each side (null: silence).
    void stage(uint32_t index, const float* left, const float* right, uint32_t frames) noexcept {
        if (index >= maxParts_ || !canStage()) return;
        const int bank = active_ ^ 1;
        for (uint32_t i = 0; i < 2 * b_; ++i) {
            re_[i] = left && i < frames && i < b_ ? left[i] : 0.0;
            im_[i] = right && i < frames && i < b_ ? right[i] : 0.0;
        }
        fft_.forward(re_.data(), im_.data());
        split(hRe_[bank].data() + offset(index), hIm_[bank].data() + offset(index));
    }
    // The staged response, `partitions` long, plays from the next block on.
    void commit(uint32_t partitions) noexcept {
        if (!canStage()) return;
        parts_[active_ ^ 1] = partitions > maxParts_ ? maxParts_ : partitions;
        pending_ = true;
    }
    // Silence as the response, at once (no fade): for a start with nothing loaded.
    void silence() noexcept {
        parts_[0] = parts_[1] = 0;
        pending_ = fading_ = false;
    }

    // n frames through the convolution (any n: blocks are counted inside). The output is the input convolved with
    // the response, latency() frames later.
    void process(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept {
        const uint32_t shareFrames = b_ / kShares;
        for (uint32_t i = 0; i < n; ++i) {
            const float l = inL[i], r = inR[i];
            inL_[b_ + pos_] = l == l ? l : 0.0f;
            inR_[b_ + pos_] = r == r ? r : 0.0f;
            outL[i] = outL_[pos_];
            outR[i] = outR_[pos_];
            ++pos_;
            if (pos_ % shareFrames == 0 && share_ < kShares) {
                doShare(share_);
                ++share_;
            }
            if (pos_ == b_) boundary();
        }
    }

private:
    size_t offset(uint32_t part) const noexcept { return static_cast<size_t>(part) * 2 * bins_; }

    // re_/im_ (the FFT of l + j r) into the two half spectra (left at dst, right at dst + bins_).
    void split(float* dstRe, float* dstIm) noexcept {
        const uint32_t n = 2 * b_;
        for (uint32_t k = 0; k < bins_; ++k) {
            const uint32_t m = (n - k) & (n - 1);
            dstRe[k] = static_cast<float>(0.5 * (re_[k] + re_[m]));
            dstIm[k] = static_cast<float>(0.5 * (im_[k] - im_[m]));
            dstRe[bins_ + k] = static_cast<float>(0.5 * (im_[k] + im_[m]));
            dstIm[bins_ + k] = static_cast<float>(-0.5 * (re_[k] - re_[m]));
        }
    }

    // acc[bank] += X(slot) H(bank, part), both sides.
    void mac(int bank, uint32_t slot, uint32_t part) noexcept {
        const float* __restrict xr = xRe_.data() + offset(slot);
        const float* __restrict xi = xIm_.data() + offset(slot);
        const float* __restrict hr = hRe_[bank].data() + offset(part);
        const float* __restrict hi = hIm_[bank].data() + offset(part);
        float* __restrict ar = accRe_[bank].data();
        float* __restrict ai = accIm_[bank].data();
        const uint32_t m = 2 * bins_;
        // Single precision, split real and imaginary arrays: the loop the compiler turns into SIMD (SSE, NEON).
        for (uint32_t k = 0; k < m; ++k) {
            ar[k] += xr[k] * hr[k] - xi[k] * hi[k];
            ai[k] += xr[k] * hi[k] + xi[k] * hr[k];
        }
    }

    // One sixteenth of partitions 1..P-1 for the block now filling (X[n+1-k] = slot head_ - k + 1).
    void doShare(uint32_t s) noexcept {
        for (int bank = 0; bank < 2; ++bank) {
            if (bank != active_ && !fading_) continue;
            const uint32_t p = parts_[bank];
            if (p < 2) continue;
            const uint32_t from = 1 + (p - 1) * s / kShares, to = 1 + (p - 1) * (s + 1) / kShares;
            for (uint32_t k = from; k < to; ++k) mac(bank, (head_ + maxParts_ + 1 - k) % maxParts_, k);
        }
    }

    // The inverse of acc[bank] (both sides) into dstL/dstR (the last B points), then acc cleared.
    void inverseTo(int bank, float* dstL, float* dstR) noexcept {
        const uint32_t n = 2 * b_;
        const float* ar = accRe_[bank].data();
        const float* ai = accIm_[bank].data();
        // Z = YL + j YR over the whole circle: YL, YR are spectra of real signals (Y[N-k] = conj Y[k]).
        for (uint32_t k = 0; k < bins_; ++k) {
            const double lr = ar[k], li = ai[k], rr = ar[bins_ + k], ri = ai[bins_ + k];
            re_[k] = lr - ri;
            im_[k] = li + rr;
            if (k > 0 && k < b_) {
                re_[n - k] = lr + ri;
                im_[n - k] = -li + rr;
            }
        }
        fft_.inverse(re_.data(), im_.data());
        const double scale = 1.0 / n;
        for (uint32_t i = 0; i < b_; ++i) {
            dstL[i] = flush(re_[b_ + i] * scale);
            dstR[i] = flush(im_[b_ + i] * scale);
        }
        for (float& v : accRe_[bank]) v = 0.0f;
        for (float& v : accIm_[bank]) v = 0.0f;
    }
    static float flush(double v) noexcept {
        if (!(v > -1e4)) return v != v ? 0.0f : -1e4f;
        if (v > 1e4) return 1e4f;
        return (v < 1e-20 && v > -1e-20) ? 0.0f : static_cast<float>(v);
    }

    void boundary() noexcept {
        // The last 2B input frames (the previous block, then this one), transformed into the delay line's next slot.
        head_ = (head_ + 1) % maxParts_;
        for (uint32_t i = 0; i < 2 * b_; ++i) {
            re_[i] = inL_[i];
            im_[i] = inR_[i];
        }
        fft_.forward(re_.data(), im_.data());
        split(xRe_.data() + offset(head_), xIm_.data() + offset(head_));
        for (uint32_t i = 0; i < b_; ++i) inL_[i] = inL_[b_ + i], inR_[i] = inR_[b_ + i];
        const int other = active_ ^ 1;
        if (parts_[active_] > 0) mac(active_, head_, 0);
        if (fading_) {
            if (parts_[other] > 0) mac(other, head_, 0);
            inverseTo(active_, outL_.data(), outR_.data());
            inverseTo(other, fadeL_.data(), fadeR_.data());
            // Old to new over the block, a straight line.
            const float* nl = fadeL_.data();
            const float* nr = fadeR_.data();
            for (uint32_t i = 0; i < b_; ++i) {
                const float t = static_cast<float>(i + 1) / static_cast<float>(b_);
                outL_[i] += (nl[i] - outL_[i]) * t;
                outR_[i] += (nr[i] - outR_[i]) * t;
            }
            active_ = other;
            fading_ = false;
        } else {
            inverseTo(active_, outL_.data(), outR_.data());
        }
        if (pending_) {  // the staged response runs alongside from this block on, and takes over at the next boundary
            pending_ = false;
            fading_ = true;
        }
        pos_ = 0;
        share_ = 0;
    }
private:
    uint32_t b_ = 0, bins_ = 0, maxParts_ = 0, parts_[2] = {0, 0};
    uint32_t pos_ = 0, head_ = 0, share_ = 0;
    int active_ = 0;
    bool pending_ = false, fading_ = false;
    Fft fft_;
    std::vector<double> re_, im_;
    std::vector<float> accRe_[2], accIm_[2];
    std::vector<float> hRe_[2], hIm_[2], xRe_, xIm_, inL_, inR_, outL_, outR_, fadeL_, fadeR_;  // fade*: the new response's first block
};

}  // namespace caw::lib
