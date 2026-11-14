// Clip voice reading: direct copies, cubic Hermite varispeed, and WSOLA time-stretching with a pitch stage.
#include "time_stretch.h"

#include <algorithm>
#include "caw/detmath.hpp"
#include <cmath>
#include <cstdint>

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
    ringL_.reset(new (std::nothrow) float[kHqRing]());
    ringR_.reset(new (std::nothrow) float[kHqRing]());
    if (!window_ || !accL_ || !accR_ || !scratch_ || !natural_ || !yl_ || !yr_ || !ringL_ || !ringR_) return false;
    for (int i = 0; i < n_; ++i)  // periodic Hann: shifted by a hop, two sum to 1
        window_[static_cast<size_t>(i)] =
            static_cast<float>(0.5 - 0.5 * detCos(2.0 * 3.14159265358979323846 * i / n_));
    return true;
}

void ClipReader::start(const ClipSource& src, ReadMode mode, double pitch, int64_t t, double anchorSource,
                       double slope, HqStretcher* hq, int64_t floor, int64_t heardFrom) noexcept {
    src_ = src;
    mode_ = mode;
    pitch_ = pitch > 0 && std::isfinite(pitch) ? pitch : 1.0;
    setMapping(t, anchorSource, slope);
    hq_ = nullptr;
    if (mode_ == ReadMode::Hq) {
        if (!hq || !window_ || !ringL_) {
            mode_ = ReadMode::Stretch;
        } else {
            hq_ = hq;
            floor_ = floor;
            hqBegin(t);
            if (bridgeEnd_ - kHqAlign <= heardFrom) {  // pre-rolled: good before it is heard, no bridge
                bridgeEnd_ = INT64_MIN / 2;
                aligned_ = true;
            } else {
                startWsola(t);
            }
            return;
        }
    }
    if (mode_ == ReadMode::Stretch) startWsola(t);
}

void ClipReader::upgrade(HqStretcher* hq, int64_t t, int64_t floor) noexcept {
    if (mode_ != ReadMode::Stretch || !hq || !ringL_) return;
    hq_ = hq;
    floor_ = floor;
    mode_ = ReadMode::Hq;
    hqBegin(t);  // WSOLA plays on, as the bridge
}

void ClipReader::hqBegin(int64_t t) noexcept {
    hq_->reset(pitch_);
    const int lat = hq_->outputLatency(), sl = hq_->seekLength();
    const int64_t p = static_cast<int64_t>(
        std::floor(sourceAt(static_cast<double>(t + lat)) + static_cast<double>(hq_->inputLatency())));
    float* l = hq_->inputL();
    float* r = hq_->inputR();
    for (int i = 0; i < sl; ++i) {
        const int64_t at = p - sl + i;
        if (at < floor_) l[i] = r[i] = 0.0f;
        else src_.frame(at, l[i], r[i]);
    }
    hq_->seek(sl, slope_ > 0 && std::isfinite(slope_) ? slope_ : 1.0);
    fed_ = p;
    produced_ = t;
    hqShift_ = 0;
    hqRho_ = 0;
    unshift_ = 0;
    unshiftFrom_ = 0;
    aligned_ = false;
    // Good from t + lat; the lag may read up to kHqAlign earlier, so the crossfade starts that much later.
    bridgeEnd_ = t + lat + kHqAlign;
}

void ClipReader::startWsola(int64_t t) noexcept {
    if (!window_) return;
    t0_ = t;
    frameIndex_ = 0;
    yWritten_ = 0;
    u_ = 0;
    std::fill_n(accL_.get(), n_, 0.0f);
    std::fill_n(accR_.get(), n_, 0.0f);
    hop();  // frame 0 (y-time -hs.. hs): its first half is never heard
}

void ClipReader::hqChunk() noexcept {
    const int64_t from = produced_, to = from + HqStretcher::kChunk;
    // The source this chunk's end is fed up to: the mapping at that frame, less the lag being taken out.
    const double at = static_cast<double>(to + hq_->outputLatency());
    double back = 0;
    if (unshift_ != 0) {
        const double k = (at - static_cast<double>(unshiftFrom_)) / kHqUnshift;
        back = unshift_ * (k <= 0 ? 0.0 : (k >= 1 ? 1.0 : k));
    }
    const int64_t target =
        static_cast<int64_t>(std::floor(sourceAt(at) - back + static_cast<double>(hq_->inputLatency())));
    int64_t n = target - fed_;
    if (n < 0) n = 0;  // the source can't run backwards: hold
    if (n > HqStretcher::kMaxFeed) {  // faster than kMaxFeed / kChunk times real time: the rest is skipped
        fed_ = target - HqStretcher::kMaxFeed;
        n = HqStretcher::kMaxFeed;
    }
    float* l = hq_->inputL();
    float* r = hq_->inputR();
    for (int64_t i = 0; i < n; ++i) {
        const int64_t f = fed_ + i;
        if (f < floor_) l[i] = r[i] = 0.0f;
        else src_.frame(f, l[i], r[i]);
    }
    fed_ += n;
    float ol[HqStretcher::kChunk], orr[HqStretcher::kChunk];
    hq_->process(static_cast<int>(n), ol, orr);
    for (int i = 0; i < HqStretcher::kChunk; ++i) {
        ringL_[static_cast<size_t>((from + i) & (kHqRing - 1))] = ol[i];
        ringR_[static_cast<size_t>((from + i) & (kHqRing - 1))] = orr[i];
    }
    produced_ = to;
}

void ClipReader::hqAlign(int64_t t) noexcept {
    aligned_ = true;
    // Signalsmith's output far enough ahead, and WSOLA's next frames (read without moving it).
    int guard = 0;
    while (produced_ < t + kHqAlignWindow + kHqAlign && guard++ < 64) hqChunk();
    const int window = std::max(16, std::min(kHqAlignWindow, static_cast<int>(2048.0 / pitch_)));
    guard = 0;
    while (yWritten_ <= static_cast<int64_t>(std::floor(u_ + window * pitch_)) + 3 && guard++ < 64) hop();
    float w[kHqAlignWindow];
    for (int i = 0; i < window; ++i) {
        const double pos = u_ + i * pitch_;
        const double f = std::floor(pos);
        const int64_t k = static_cast<int64_t>(f);
        auto at = [&](const std::unique_ptr<float[]>& y, int64_t j) {
            return y[static_cast<size_t>((j < 0 ? 0 : j) & yMask_)];
        };
        const float fr = static_cast<float>(pos - f);
        w[i] = cubic(at(yl_, k - 1), at(yl_, k), at(yl_, k + 1), at(yl_, k + 2), fr) +
               cubic(at(yr_, k - 1), at(yr_, k), at(yr_, k + 1), at(yr_, k + 2), fr);
    }
    double best = -1e300, energyH = 0, energyW = 0;
    int lag = 0;
    for (int i = 0; i < window; ++i) energyW += static_cast<double>(w[i]) * w[i];
    for (int d = -kHqAlign; d <= kHqAlign; ++d) {
        double c = 0;
        for (int i = 0; i < window; ++i) {
            const size_t j = static_cast<size_t>((t + i + d) & (kHqRing - 1));
            c += static_cast<double>(w[i]) * (ringL_[j] + ringR_[j]);
        }
        if (c > best || (c == best && std::abs(d) < std::abs(lag))) {
            best = c;
            lag = d;
        }
    }
    for (int i = 0; i < window; ++i) {
        const size_t j = static_cast<size_t>((t + i + lag) & (kHqRing - 1));
        const double h = static_cast<double>(ringL_[j]) + ringR_[j];
        energyH += h * h;
    }
    hqRho_ = energyW > 0 && energyH > 0 ? std::clamp(best / std::sqrt(energyW * energyH), -1.0, 1.0) : 0.0;
    hqShift_ = lag;
    // Take the lag back out of the feed from the next chunk fed on, over kHqUnshift frames.
    unshift_ = sourceAt(static_cast<double>(t + lag)) - sourceAt(static_cast<double>(t));
    unshiftFrom_ = produced_ + hq_->outputLatency();
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

void ClipReader::renderWsola(int n, const float* gain, float* l, float* r) noexcept {
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
            renderWsola(n, gain, l, r);
            return;
        case ReadMode::Hq: {
            constexpr int kSub = HqStretcher::kChunk;
            for (int done = 0; done < n;) {  // in pieces of at most 64 (the local arrays), split at the bridge's end
                int m = std::min(kSub, n - done);
                const int64_t t1 = t + done;
                if (!aligned_ && t1 < bridgeEnd_) m = static_cast<int>(std::min<int64_t>(m, bridgeEnd_ - t1));
                if (!aligned_ && t1 >= bridgeEnd_) hqAlign(t1);
                float wh[kSub], ww[kSub];
                bool bridging = false;
                for (int i = 0; i < m; ++i) {
                    const int64_t d = t1 + i - bridgeEnd_;
                    if (d < 0) {
                        wh[i] = 0.0f;
                        ww[i] = 1.0f;
                    } else if (d >= kHqCrossfade) {
                        wh[i] = 1.0f;
                        ww[i] = 0.0f;
                    } else {  // the sum's power kept for the two signals' correlation (linear when equal)
                        const double b = (static_cast<double>(d) + 0.5) / kHqCrossfade, a = 1.0 - b;
                        const double k = 1.0 / std::sqrt(std::max(1e-6, a * a + b * b + 2.0 * hqRho_ * a * b));
                        wh[i] = static_cast<float>(b * k);
                        ww[i] = static_cast<float>(a * k);
                    }
                    bridging |= ww[i] > 0.0f;
                }
                if (bridging) {
                    float g[kSub];
                    for (int i = 0; i < m; ++i) g[i] = gain[done + i] * ww[i];
                    renderWsola(m, g, l + done, r + done);
                }
                for (int i = 0; i < m; ++i) {
                    const int64_t ft = t1 + i + hqShift_;  // Signalsmith's own frame
                    if (ft - produced_ >= 8 * kSub)  // far behind (frames not rendered): skip ahead, aligned
                        produced_ += ((ft - produced_) / kSub - 1) * kSub;
                    int guard = 0;
                    while (ft >= produced_ && guard++ < 8) hqChunk();
                    if (wh[i] == 0.0f || ft < produced_ - kHqRing || ft >= produced_) continue;
                    const float g = gain[done + i] * wh[i];
                    const size_t j = static_cast<size_t>(ft & (kHqRing - 1));
                    l[done + i] += ringL_[j] * g;
                    r[done + i] += ringR_[j] * g;
                }
                done += m;
            }
            return;
        }
    }
}

}  // namespace caw
