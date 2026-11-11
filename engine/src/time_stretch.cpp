// Clip voice reading: direct copies, cubic Hermite varispeed, and WSOLA time-stretching with a pitch stage.
#include "time_stretch.h"

#include <algorithm>
#include <cmath>

namespace caw {

namespace {
inline float cubic(float a, float b, float c, float d, float t) noexcept {
    // Catmull-Rom (cubic Hermite with central-difference tangents) between b and c.
    return b + 0.5f * t * (c - a + t * (2.0f * a - 5.0f * b + 4.0f * c - d + t * (3.0f * (b - c) + d - a)));
}
}  // namespace

bool ClipReader::prepare(double sampleRate) {
    hs_ = std::max(16, static_cast<int>(std::lround(0.015 * sampleRate)));
    n_ = 2 * hs_;
    delta_ = hs_ / 2;
    window_.reset(new (std::nothrow) float[static_cast<size_t>(n_)]);
    accL_.reset(new (std::nothrow) float[static_cast<size_t>(n_)]());
    accR_.reset(new (std::nothrow) float[static_cast<size_t>(n_)]());
    scratch_.reset(new (std::nothrow) float[static_cast<size_t>(2 * delta_ + n_ + 8)]());
    natural_.reset(new (std::nothrow) float[static_cast<size_t>(n_)]());
    int ring = 1;
    while (ring < 4 * n_) ring <<= 1;
    yl_.reset(new (std::nothrow) float[static_cast<size_t>(ring)]());
    yr_.reset(new (std::nothrow) float[static_cast<size_t>(ring)]());
    yMask_ = ring - 1;
    if (!window_ || !accL_ || !accR_ || !scratch_ || !natural_ || !yl_ || !yr_) return false;
    for (int i = 0; i < n_; ++i)  // periodic Hann: shifted by a hop, two sum to 1
        window_[static_cast<size_t>(i)] =
            static_cast<float>(0.5 - 0.5 * std::cos(2.0 * 3.14159265358979323846 * i / n_));
    return true;
}

void ClipReader::start(const ClipSource& src, ReadMode mode, double pitch, int64_t t, double anchorSource,
                       double slope) noexcept {
    src_ = src;
    mode_ = mode;
    pitch_ = pitch > 0 && std::isfinite(pitch) ? pitch : 1.0;
    setMapping(t, anchorSource, slope);
    if (mode_ != ReadMode::Stretch || !window_) return;
    t0_ = t;
    frameIndex_ = 0;
    yWritten_ = 0;
    u_ = 0;
    std::fill_n(accL_.get(), n_, 0.0f);
    std::fill_n(accR_.get(), n_, 0.0f);
    hop();  // frame 0 (y-time -hs.. hs): its first half is never heard
}

void ClipReader::hermite(double pos, float& l, float& r) const noexcept {
    const double f = std::floor(pos);
    const int64_t i = static_cast<int64_t>(f);
    const float t = static_cast<float>(pos - f);
    float l0, r0, l1, r1, l2, r2, l3, r3;
    src_.frame(i - 1, l0, r0);
    src_.frame(i, l1, r1);
    src_.frame(i + 1, l2, r2);
    src_.frame(i + 2, l3, r3);
    l = cubic(l0, l1, l2, l3, t);
    r = cubic(r0, r1, r2, r3, t);
}

void ClipReader::hop() noexcept {
    const int64_t m = frameIndex_++;
    const double v = static_cast<double>((m - 1) * hs_);  // the frame's window starts here in y-time
    const int64_t nominal = static_cast<int64_t>(std::floor(sourceAt(static_cast<double>(t0_) + v / pitch_) + 0.5));
    int64_t start = nominal;
    if (m > 0) {
        // The natural continuation of the last frame, and the candidates around the nominal start (mono sums).
        const int64_t natural = prevStart_ + hs_;
        float a, b;
        for (int i = 0; i < hs_; ++i) {
            src_.frame(natural + i, a, b);
            natural_[static_cast<size_t>(i)] = a + b;
        }
        const int span = 2 * delta_ + hs_;
        for (int i = 0; i < span; ++i) {
            src_.frame(nominal - delta_ + i, a, b);
            scratch_[static_cast<size_t>(i)] = a + b;
        }
        auto score = [&](int lag, int stride) {
            double acc = 0;
            const float* c = scratch_.get() + lag;
            for (int i = 0; i < hs_; i += stride) acc += static_cast<double>(c[i]) * natural_[static_cast<size_t>(i)];
            return acc;
        };
        int best = delta_;
        double bestScore = -1e300;
        for (int lag = 0; lag <= 2 * delta_; lag += 4) {
            const double s = score(lag, 4);
            if (s > bestScore) {
                bestScore = s;
                best = lag;
            }
        }
        const int coarse = best;
        bestScore = -1e300;
        for (int lag = std::max(0, coarse - 3); lag <= std::min(2 * delta_, coarse + 3); ++lag) {
            const double s = score(lag, 1);
            if (s > bestScore) {
                bestScore = s;
                best = lag;
            }
        }
        start = nominal - delta_ + best;
    }
    prevStart_ = start;
    for (int i = 0; i < n_; ++i) {
        float a, b;
        src_.frame(start + i, a, b);
        const float w = window_[static_cast<size_t>(i)];
        accL_[static_cast<size_t>(i)] += a * w;
        accR_[static_cast<size_t>(i)] += b * w;
    }
    if (m > 0) {  // the first half is complete: y-time (m-1)*hs .. m*hs
        for (int i = 0; i < hs_; ++i) {
            const int64_t at = (m - 1) * hs_ + i;
            yl_[static_cast<size_t>(at & yMask_)] = accL_[static_cast<size_t>(i)];
            yr_[static_cast<size_t>(at & yMask_)] = accR_[static_cast<size_t>(i)];
        }
        yWritten_ = m * hs_;
    }
    std::copy(accL_.get() + hs_, accL_.get() + n_, accL_.get());
    std::copy(accR_.get() + hs_, accR_.get() + n_, accR_.get());
    std::fill(accL_.get() + hs_, accL_.get() + n_, 0.0f);
    std::fill(accR_.get() + hs_, accR_.get() + n_, 0.0f);
}

void ClipReader::render(int64_t t, int n, const float* gain, float* l, float* r) noexcept {
    switch (mode_) {
        case ReadMode::Direct:
            for (int i = 0; i < n; ++i) {
                float a, b;
                src_.frame(static_cast<int64_t>(std::llround(sourceAt(static_cast<double>(t + i)))), a, b);
                l[i] += a * gain[i];
                r[i] += b * gain[i];
            }
            return;
        case ReadMode::Varispeed:
            for (int i = 0; i < n; ++i) {
                float a, b;
                hermite(sourceAt(static_cast<double>(t + i)), a, b);
                l[i] += a * gain[i];
                r[i] += b * gain[i];
            }
            return;
        case ReadMode::Stretch:
            if (!window_) return;
            for (int i = 0; i < n; ++i) {
                const double f = std::floor(u_);
                const int64_t k = static_cast<int64_t>(f);
                int guard = 0;
                while (yWritten_ <= k + 2 && guard++ < 64) hop();
                auto at = [&](const std::unique_ptr<float[]>& y, int64_t j) {
                    return y[static_cast<size_t>((j < 0 ? 0 : j) & yMask_)];
                };
                const float frac = static_cast<float>(u_ - f);
                const float a = cubic(at(yl_, k - 1), at(yl_, k), at(yl_, k + 1), at(yl_, k + 2), frac);
                const float b = cubic(at(yr_, k - 1), at(yr_, k), at(yr_, k + 1), at(yr_, k + 2), frac);
                l[i] += a * gain[i];
                r[i] += b * gain[i];
                u_ += pitch_;
            }
            return;
    }
}

}  // namespace caw
