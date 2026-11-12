// Filters side by side against one at a time (speed A2): MultiLadder::processPairs and Svf::lowpassPairs runs, for exact and tolerance checks.
#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

#include "caw/library/filter.hpp"

namespace cawtest {

// One run's outputs: every channel's samples, side by side and through each filter alone.
struct PairRun {
    std::vector<float> together, alone;
    double peak = 0;  // the largest |sample| in or out
};

// 2K channels (K pairs), each with its own cutoff and resonance and a loud, uneven signal (a saw, noise, a jump,
// an infinity and a NaN), run in uneven blocks, so the state carries across calls.
inline std::vector<std::vector<float>> pairInputs(int channels, uint32_t frames) {
    std::vector<std::vector<float>> in(static_cast<size_t>(channels), std::vector<float>(frames));
    uint32_t seed = 12345;
    for (int c = 0; c < channels; ++c)
        for (uint32_t i = 0; i < frames; ++i) {
            seed = seed * 1664525u + 1013904223u;
            const double noise = static_cast<double>(seed >> 8) / 8388608.0 - 1.0;
            const double saw = std::fmod(i * (0.004 + 0.003 * c), 1.0) * 2.0 - 1.0;
            in[static_cast<size_t>(c)][i] = static_cast<float>((1.5 + c) * saw + 0.4 * noise + (i > frames / 2 ? 2.0 : 0.0));
        }
    in[0][37] = std::numeric_limits<float>::infinity();
    in[static_cast<size_t>(channels - 1)][101] = std::numeric_limits<float>::quiet_NaN();
    return in;
}
constexpr uint32_t kPairBlocks[] = {1, 7, 16, 33, 64, 5, 128, 2};

template <caw::lib::LadderMode Mode, int K>
PairRun ladderPairs(bool approx) {
    constexpr int C = 2 * K;
    uint32_t frames = 0;
    for (uint32_t b : kPairBlocks) frames += b;
    const std::vector<std::vector<float>> in = pairInputs(C, frames);
    caw::lib::MultiLadder a[C], b[C];
    for (int c = 0; c < C; ++c) {
        const double cutoff = 300.0 * (c + 1), resonance = 0.15 * c;
        if (approx) a[c].setApprox(cutoff, resonance, 48000.0), b[c].setApprox(cutoff, resonance, 48000.0);
        else a[c].set(cutoff, resonance, 48000.0), b[c].set(cutoff, resonance, 48000.0);
    }
    std::vector<std::vector<float>> x = in, y = in;
    uint32_t at = 0;
    for (uint32_t n : kPairBlocks) {
        caw::lib::MultiLadder* f[C];
        float* left[K];
        float* right[K];
        for (int c = 0; c < C; ++c) f[c] = &a[c];
        for (int k = 0; k < K; ++k) left[k] = x[static_cast<size_t>(2 * k)].data() + at, right[k] = x[static_cast<size_t>(2 * k + 1)].data() + at;
        caw::lib::MultiLadder::processPairs<Mode, K>(f, left, right, n);
        for (int c = 0; c < C; ++c) b[c].template process<Mode>(y[static_cast<size_t>(c)].data() + at, n);
        at += n;
    }
    PairRun r;
    for (int c = 0; c < C; ++c)
        for (uint32_t i = 0; i < frames; ++i) {
            const float t = x[static_cast<size_t>(c)][i], s = y[static_cast<size_t>(c)][i], v = in[static_cast<size_t>(c)][i];
            r.together.push_back(t), r.alone.push_back(s);
            if (std::isfinite(v)) r.peak = std::fmax(r.peak, std::fabs(v));
            r.peak = std::fmax(r.peak, std::fmax(std::fabs(t), std::fabs(s)));
        }
    return r;
}

template <int K>
PairRun svfPairs() {
    constexpr int C = 2 * K;
    uint32_t frames = 0;
    for (uint32_t b : kPairBlocks) frames += b;
    const std::vector<std::vector<float>> in = pairInputs(C, frames);
    caw::lib::Svf a[C], b[C];
    for (int c = 0; c < C; ++c) {
        const double cutoff = 250.0 * (c + 1) * (c + 1), q = 0.5 + 1.5 * c;
        a[c].set(cutoff, q, 48000.0), b[c].set(cutoff, q, 48000.0);
    }
    std::vector<std::vector<float>> x = in, y = in;
    uint32_t at = 0;
    for (uint32_t n : kPairBlocks) {
        caw::lib::Svf* f[C];
        float* left[K];
        float* right[K];
        for (int c = 0; c < C; ++c) f[c] = &a[c];
        for (int k = 0; k < K; ++k) left[k] = x[static_cast<size_t>(2 * k)].data() + at, right[k] = x[static_cast<size_t>(2 * k + 1)].data() + at;
        caw::lib::Svf::lowpassPairs<K>(f, left, right, n);
        for (int c = 0; c < C; ++c) {
            float* s = y[static_cast<size_t>(c)].data() + at;
            for (uint32_t i = 0; i < n; ++i) s[i] = static_cast<float>(b[c].lowpass(static_cast<double>(s[i])));
        }
        at += n;
    }
    PairRun r;
    for (int c = 0; c < C; ++c)
        for (uint32_t i = 0; i < frames; ++i) {
            const float t = x[static_cast<size_t>(c)][i], s = y[static_cast<size_t>(c)][i], v = in[static_cast<size_t>(c)][i];
            r.together.push_back(t), r.alone.push_back(s);
            if (std::isfinite(v)) r.peak = std::fmax(r.peak, std::fabs(v));
            r.peak = std::fmax(r.peak, std::fmax(std::fabs(t), std::fabs(s)));
        }
    return r;
}

// How many samples differ in their bits (strict builds: none).
inline size_t pairBitsDiffer(const PairRun& r) {
    size_t n = 0;
    for (size_t i = 0; i < r.together.size(); ++i) n += std::memcmp(&r.together[i], &r.alone[i], sizeof(float)) != 0;
    return n;
}
// The engine's flags (-ffp-contract=fast -fassociative-math) may fuse or reorder either path differently: the
// filters' double arithmetic then agrees within about 1e-12 of the signal's peak, and each float sample within one
// float step of that. The worst sample's error over that allowance (at most 1 passes).
inline double pairWorst(const PairRun& r) {
    double worst = 0;
    for (size_t i = 0; i < r.together.size(); ++i) {
        const double t = r.together[i], s = r.alone[i];
        if (!std::isfinite(t) || !std::isfinite(s)) return std::numeric_limits<double>::infinity();
        const double allow = std::numeric_limits<float>::epsilon() * std::fabs(s) + 1e-12 * r.peak;
        worst = std::fmax(worst, std::fabs(t - s) / allow);
    }
    return worst;
}

}  // namespace cawtest
