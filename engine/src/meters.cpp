// Live loudness, true peak and correlation meters (meters.h): BS.1770-5 K-weighting, gating and Annex 2 true peak.
#include "meters.h"

#include <algorithm>
#include <cmath>

namespace caw {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kCorrelationSeconds = 0.3;  // [Assumption] a usual correlation meter's integration, not a standard
constexpr double kSilentEnergy = 1e-12;      // below about -120 dBFS on both sides: no correlation to show

// BS.1770-5 Annex 2, the example 48-tap, 4-phase interpolating FIR (12 taps a phase), as printed.
constexpr double kTruePeakTaps[4][12] = {
    {0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
     0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500},
    {-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
     0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375},
    {-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
     0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875},
    {-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
     0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750},
};

double finite(double x) noexcept { return std::isfinite(x) ? x : 0.0; }

float lufs(double meanSquare) noexcept {
    if (!(meanSquare > 0.0)) return kMeterNone;
    return static_cast<float>(std::max(-0.691 + 10.0 * std::log10(meanSquare), static_cast<double>(kMeterNone)));
}

float dbtp(double peak) noexcept {
    if (!(peak > 0.0)) return kMeterNone;
    return static_cast<float>(std::max(20.0 * std::log10(peak), static_cast<double>(kMeterNone)));
}

void storeMax(std::atomic<float>& a, float v) noexcept {
    float old = a.load(std::memory_order_relaxed);
    while (v > old && !a.compare_exchange_weak(old, v, std::memory_order_relaxed)) {
    }
}

}  // namespace

// ---------------------------------------------------------------- correlation

void CorrelationMeter::prepare(double sampleRate) noexcept {
    perFrame_ = -1.0 / (kCorrelationSeconds * (sampleRate > 0 ? sampleRate : 48000.0));
    clear();
}

void CorrelationMeter::clear() noexcept {
    ll_ = rr_ = lr_ = 0.0;
    value_.store(0.0f, std::memory_order_relaxed);
}

void CorrelationMeter::process(const float* left, const float* right, int frames) noexcept {
    if (frames <= 0) return;
    double ll = 0, rr = 0, lr = 0;
    for (int i = 0; i < frames; ++i) {
        const double l = left[i], r = right[i];
        ll += l * l;
        rr += r * r;
        lr += l * r;
    }
    // One decay a block (block-sized steps of the window: a meter's reading, not audio).
    const double keep = std::exp(perFrame_ * frames);
    ll_ = finite(ll_ * keep + ll);
    rr_ = finite(rr_ * keep + rr);
    lr_ = finite(lr_ * keep + lr);
    const double norm = ll_ * rr_;
    const double c = ll_ < kSilentEnergy || rr_ < kSilentEnergy ? 0.0 : lr_ / std::sqrt(norm);
    value_.store(static_cast<float>(std::clamp(finite(c), -1.0, 1.0)), std::memory_order_relaxed);
}

// ---------------------------------------------------------------- loudness

LoudnessMeter::LoudnessMeter() {
    for (auto& b : bins_) b.store(0, std::memory_order_relaxed);
    for (int k = 0; k < kBins; ++k) {
        const double centre = kLowestLufs + (k + 0.5) * kBinLu;
        binEnergy_[static_cast<std::size_t>(k)] = std::pow(10.0, (centre + 0.691) / 10.0);
    }
    prepare(48000.0);
}

void LoudnessMeter::kWeighting(double sampleRate, Biquad& shelf, Biquad& highpass) noexcept {
    // The pre-filter's analogue parameters (as fitted in libebur128, MIT; the test checks they give BS.1770-5's
    // 48 kHz table), designed with the bilinear transform: stage 1 a high shelf of about +4 dB above 1.68 kHz,
    // stage 2 the RLB high-pass at about 38 Hz.
    const double fs = sampleRate > 0 ? sampleRate : 48000.0;
    {
        const double f0 = 1681.974450955533, gainDb = 3.999843853973347, q = 0.7071752369554196;
        const double k = std::tan(kPi * f0 / fs);
        const double vh = std::pow(10.0, gainDb / 20.0);
        const double vb = std::pow(vh, 0.4996667741545416);
        const double a0 = 1.0 + k / q + k * k;
        shelf.b0 = (vh + vb * k / q + k * k) / a0;
        shelf.b1 = 2.0 * (k * k - vh) / a0;
        shelf.b2 = (vh - vb * k / q + k * k) / a0;
        shelf.a1 = 2.0 * (k * k - 1.0) / a0;
        shelf.a2 = (1.0 - k / q + k * k) / a0;
    }
    {
        const double f0 = 38.13547087602444, q = 0.5003270373238773;
        const double k = std::tan(kPi * f0 / fs);
        const double a0 = 1.0 + k / q + k * k;
        highpass.b0 = 1.0;
        highpass.b1 = -2.0;
        highpass.b2 = 1.0;
        highpass.a1 = 2.0 * (k * k - 1.0) / a0;
        highpass.a2 = (1.0 - k / q + k * k) / a0;
    }
}

void LoudnessMeter::prepare(double sampleRate) noexcept {
    sampleRate_ = sampleRate > 0 ? sampleRate : 48000.0;
    subFrames_ = std::max(1, static_cast<int>(std::lround(0.1 * sampleRate_)));
    oversample_ = sampleRate_ < 96000.0 * 0.95 ? 4 : sampleRate_ < 192000.0 * 0.95 ? 2 : 1;
    Biquad s, h;
    kWeighting(sampleRate_, s, h);
    for (int c = 0; c < 2; ++c) {
        shelf_[c].c = s;
        high_[c].c = h;
    }
    resetSeen_ = resetAsked_.load(std::memory_order_relaxed);
    clearAudioState();
    for (auto& b : bins_) b.store(0, std::memory_order_relaxed);
    blocks_.store(0, std::memory_order_relaxed);
}

void LoudnessMeter::clearAudioState() noexcept {
    for (int c = 0; c < 2; ++c) {
        shelf_[c].z1 = shelf_[c].z2 = high_[c].z1 = high_[c].z2 = 0.0;
        for (double& v : tpHistory_[c]) v = 0.0;
    }
    subSum_ = 0.0;
    subLeft_ = subFrames_;
    subs_.fill(0.0);
    subPos_ = subCount_ = 0;
    tpPos_ = 0;
    tpMax_ = mMax_ = sMax_ = 0.0;
    momentary_.store(kMeterNone, std::memory_order_relaxed);
    shortTerm_.store(kMeterNone, std::memory_order_relaxed);
    momentaryMax_.store(kMeterNone, std::memory_order_relaxed);
    shortTermMax_.store(kMeterNone, std::memory_order_relaxed);
    truePeakMax_.store(0.0f, std::memory_order_relaxed);
}

double LoudnessMeter::truePeak(int side, double x) noexcept {
    double* h = tpHistory_[side];
    h[tpPos_] = x;
    h[tpPos_ + 12] = x;
    if (oversample_ == 1) return x < 0 ? -x : x;
    const double* w = h + tpPos_ + 12;  // w[-k]: the sample k back
    if (oversample_ == 4) {
        // The four phases side by side (each phase's sum in its own order, k = 0..11, as below), so they vectorize.
        double y[4] = {0.0, 0.0, 0.0, 0.0};
        for (int k = 0; k < 12; ++k) {
            const double v = w[-k];
            for (int p = 0; p < 4; ++p) y[p] += kTruePeakTaps[p][k] * v;
        }
        double peak = 0.0;
        for (int p = 0; p < 4; ++p) {
            const double a = y[p] < 0 ? -y[p] : y[p];
            peak = a > peak ? a : peak;
        }
        return peak;
    }
    double peak = 0.0;
    const int step = 4 / oversample_;  // 2x: phases 0 and 2
    for (int p = 0; p < 4; p += step) {
        double y = 0.0;
        for (int k = 0; k < 12; ++k) y += kTruePeakTaps[p][k] * w[-k];
        y = y < 0 ? -y : y;
        peak = y > peak ? y : peak;
    }
    return peak;
}

void LoudnessMeter::endSubBlock() noexcept {
    subs_[static_cast<std::size_t>(subPos_)] = subSum_ / subFrames_;
    subPos_ = (subPos_ + 1) % 30;
    subCount_ = std::min(subCount_ + 1, 1 << 30);
    subSum_ = 0.0;
    subLeft_ = subFrames_;
    auto last = [&](int n) {
        double e = 0.0;
        for (int k = 1; k <= n; ++k) e += subs_[static_cast<std::size_t>((subPos_ - k + 30) % 30)];
        return e / n;
    };
    if (subCount_ >= 4) {
        const double m = last(4);  // a 400 ms block, stepped every 100 ms: 75 % overlap
        momentary_.store(lufs(m), std::memory_order_relaxed);
        if (m > mMax_) {
            mMax_ = m;
            momentaryMax_.store(lufs(m), std::memory_order_relaxed);
        }
        blocks_.fetch_add(1, std::memory_order_relaxed);
        if (m > 0.0) {
            const double l = -0.691 + 10.0 * std::log10(m);
            if (l > kLowestLufs) {  // the absolute gate
                const int bin = std::min(kBins - 1, static_cast<int>((l - kLowestLufs) / kBinLu));
                bins_[static_cast<std::size_t>(bin)].fetch_add(1, std::memory_order_relaxed);
            }
        }
    }
    if (subCount_ >= 30) {
        const double s = last(30);
        shortTerm_.store(lufs(s), std::memory_order_relaxed);
        if (s > sMax_) {
            sMax_ = s;
            shortTermMax_.store(lufs(s), std::memory_order_relaxed);
        }
    }
}

void LoudnessMeter::process(const float* left, const float* right, int frames) noexcept {
    if (sleepWhenUnread_) {
        const uint32_t reads = reads_.load(std::memory_order_relaxed);
        if (reads != readsSeen_) {
            readsSeen_ = reads;
            unreadFrames_ = 0;
            if (asleep_) {  // read again after a pause: measure from here, as after a reset
                asleep_ = false;
                requestReset();
            }
        } else if (!asleep_ && (unreadFrames_ += frames) > kUnreadSeconds * sampleRate_) {
            asleep_ = true;
        }
        if (asleep_) return;
    }
    const uint32_t asked = resetAsked_.load(std::memory_order_relaxed);
    if (asked != resetSeen_) {  // a reset: once per request, 8,000 stores
        resetSeen_ = asked;
        clearAudioState();
        for (auto& b : bins_) b.store(0, std::memory_order_relaxed);
        blocks_.store(0, std::memory_order_relaxed);
    }
    double tp[2] = {0.0, 0.0};  // this block's true peak per side
    for (int i = 0; i < frames;) {
        const int n = std::min(frames - i, subLeft_);
        double sum = 0.0;
        for (int j = i; j < i + n; ++j) {
            const double l = finite(left[j]), r = finite(right[j]);
            const double kl = high_[0].run(shelf_[0].run(l)), kr = high_[1].run(shelf_[1].run(r));
            sum += kl * kl + kr * kr;  // channel weights 1 for left and right
            tpPos_ = (tpPos_ + 1) % 12;
            tp[0] = std::max(tp[0], truePeak(0, l));
            tp[1] = std::max(tp[1], truePeak(1, r));
        }
        for (int c = 0; c < 2; ++c) {  // settle at 0 instead of decaying through denormals on silence
            for (Filter* f : {&shelf_[c], &high_[c]}) {
                if (std::fabs(f->z1) < 1e-30) f->z1 = 0.0;
                if (std::fabs(f->z2) < 1e-30) f->z2 = 0.0;
            }
        }
        subSum_ = finite(subSum_ + sum);
        subLeft_ -= n;
        i += n;
        if (subLeft_ == 0) endSubBlock();
    }
    storeMax(truePeakL_, static_cast<float>(tp[0]));
    storeMax(truePeakR_, static_cast<float>(tp[1]));
    const double most = std::max(tp[0], tp[1]);
    if (most > tpMax_) {
        tpMax_ = most;
        storeMax(truePeakMax_, static_cast<float>(most));
    }
}

LoudnessMeter::Reading LoudnessMeter::read() noexcept {
    reads_.fetch_add(1, std::memory_order_relaxed);
    Reading r;
    r.momentary = momentary_.load(std::memory_order_relaxed);
    r.shortTerm = shortTerm_.load(std::memory_order_relaxed);
    r.momentaryMax = momentaryMax_.load(std::memory_order_relaxed);
    r.shortTermMax = shortTermMax_.load(std::memory_order_relaxed);
    r.truePeakL = dbtp(truePeakL_.exchange(0.0f, std::memory_order_relaxed));
    r.truePeakR = dbtp(truePeakR_.exchange(0.0f, std::memory_order_relaxed));
    r.truePeakMax = dbtp(truePeakMax_.load(std::memory_order_relaxed));
    const uint64_t blocks = blocks_.load(std::memory_order_relaxed);
    r.integratedSeconds = blocks ? 0.4 + 0.1 * static_cast<double>(blocks - 1) : 0.0;
    // BS.1770-5 eqs. 4-7: the blocks over the absolute gate set the relative gate 10 LU below their loudness; the
    // blocks over both gates give the integrated loudness.
    double count = 0, energy = 0;
    uint32_t counts[kBins];
    for (int k = 0; k < kBins; ++k) {
        counts[k] = bins_[static_cast<std::size_t>(k)].load(std::memory_order_relaxed);
        count += counts[k];
        energy += counts[k] * binEnergy_[static_cast<std::size_t>(k)];
    }
    if (count == 0) return r;
    const double relative = -0.691 + 10.0 * std::log10(energy / count) - 10.0;
    double gatedCount = 0, gatedEnergy = 0;
    for (int k = 0; k < kBins; ++k) {
        const double centre = kLowestLufs + (k + 0.5) * kBinLu;
        if (counts[k] == 0 || !(centre > relative)) continue;
        gatedCount += counts[k];
        gatedEnergy += counts[k] * binEnergy_[static_cast<std::size_t>(k)];
    }
    if (gatedCount > 0) r.integrated = lufs(gatedEnergy / gatedCount);
    return r;
}

}  // namespace caw
