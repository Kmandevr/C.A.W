// Flock's sources: the half-band mip copies of a sample, the four synthesised built-in tones, their display overview and the process-wide caches that share them.
#include "flock_source.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <mutex>

#include "asset_store.h"
#include "caw/detmath.hpp"
#include "caw/library/filter.hpp"

// Original code (C.A.W. is Apache-2.0). The mips are a 31-tap Blackman-windowed half-band low-pass, every second
// frame kept (zero phase: level k's frame j is level 0's frame j x 2^k). The built-in tones are additive (strings,
// glass, choir) or filtered noise (breath), 2 s at middle C, with their timbre moving through the 2 s so the
// position knob picks a different moment; each fades in over 5 ms and out over 40 ms, so a grain that runs off an
// end ends in silence.

namespace caw::flock {

namespace {

constexpr int kHalfTaps = 15;

const double* halfband() {
    static const auto h = [] {
        static double t[2 * kHalfTaps + 1];
        double sum = 0;
        for (int k = -kHalfTaps; k <= kHalfTaps; ++k) {
            const double n = k + kHalfTaps, N = 2 * kHalfTaps;
            const double w = 0.42 - 0.5 * detCos(kTwoPi * n / N) + 0.08 * detCos(2 * kTwoPi * n / N);
            const double s = k == 0 ? 0.5 : ((k & 1) ? detSin(kPi * k / 2.0) / (kPi * k) : 0.0);
            t[k + kHalfTaps] = s * w;
            sum += s * w;
        }
        for (double& x : t) x /= sum;
        return t;
    }();
    return h;
}

// A padded copy: one zero frame before, two after; `view` points at frame 0.
bool padded(std::vector<float>& out, size_t frames) {
    try {
        out.assign(frames + 3, 0.0f);
    } catch (...) {
        return false;
    }
    return true;
}

// The next mip of x (n frames; outside them 0) into out, (n + 1) / 2 frames.
bool halve(const float* x, uint32_t n, std::vector<float>& out, uint32_t& m) {
    m = (n + 1) / 2;
    if (!padded(out, m)) return false;
    const double* h = halfband();
    float* y = out.data() + 1;
    for (uint32_t j = 0; j < m; ++j) {
        const int64_t c = 2 * static_cast<int64_t>(j);
        double acc = 0;
        if (c - kHalfTaps >= 0 && c + kHalfTaps < n) {
            for (int k = -kHalfTaps; k <= kHalfTaps; ++k) acc += h[k + kHalfTaps] * x[c - k];
        } else {
            for (int k = -kHalfTaps; k <= kHalfTaps; ++k) {
                const int64_t i = c - k;
                if (i >= 0 && i < n) acc += h[k + kHalfTaps] * x[i];
            }
        }
        y[j] = static_cast<float>(acc);
    }
    return true;
}

// Builds levels 1..mips from levels[0] (and the overview).
bool finish(Source& s, bool mips) {
    const lib::grain::Source& base = s.levels[0];
    const bool mono = base.r == base.l;
    s.mips = 0;
    if (mips) {
        for (uint32_t k = 1; k <= kMipLevels; ++k) {
            const lib::grain::Source& prev = s.levels[k - 1];
            uint32_t m = 0;
            if (!halve(prev.l, prev.length, s.own[k][0], m)) return false;
            if (!mono && !halve(prev.r, prev.length, s.own[k][1], m)) return false;
            lib::grain::Source& lv = s.levels[k];
            lv.l = s.own[k][0].data() + 1;
            lv.r = mono ? lv.l : s.own[k][1].data() + 1;
            lv.length = m;
            if (m < 8) break;
            s.mips = k;
        }
    }
    for (uint32_t k = s.mips + 1; k <= kMipLevels; ++k) s.levels[k] = s.levels[s.mips];
    const uint32_t len = base.length, stretch = std::max<uint32_t>(1, len / kOverview);
    for (uint32_t b = 0; b < kOverview; ++b) {
        float p = 0;
        for (uint32_t j = b * stretch; j < std::min(len, (b + 1) * stretch); j += 4)
            p = std::max({p, std::fabs(base.l[j]), std::fabs(base.r[j])});
        s.overview[b] = p;
    }
    return true;
}

// ---------------------------------------------------------------- the built-in tones

// A sine by rotation (two multiplies a frame, deterministic): the phasor's real part.
struct Rotor {
    double c = 1, s = 0, re = 1, im = 0;
    void set(double hz, double rate, double phase) {
        c = detCos(kTwoPi * hz / rate), s = detSin(kTwoPi * hz / rate);
        re = detCos(phase), im = detSin(phase);
    }
    double next() {
        const double r = re * c - im * s, i = re * s + im * c;
        re = r, im = i;
        return r;
    }
};

std::vector<float> strings(double rate, size_t n) {
    // Three slightly detuned saws (an ensemble), their brightness opening through the 2 s.
    std::vector<float> x(n, 0.0f);
    const double detune[3] = {-0.07, 0.0, 0.06};  // semitones
    for (int v = 0; v < 3; ++v) {
        const double f0 = kBuiltinRootHz * detPow(2.0, detune[v] / 12.0);
        for (int k = 1; k <= 48 && k * f0 < 0.45 * rate; ++k) {
            Rotor r;
            r.set(k * f0, rate, 0.7 * k * (v + 1));
            // exp(-(0.22 - 0.17 t) k) / k: darker at the start, open at the end (a growth by one factor a frame)
            double g = detExp(-0.22 * k) / k;
            const double grow = detExp(0.17 * k / static_cast<double>(n));
            for (size_t i = 0; i < n; ++i) {
                x[i] += static_cast<float>(r.next() * g);
                g *= grow;
            }
        }
    }
    return x;
}

std::vector<float> glass(double rate, size_t n) {
    // Inharmonic partials (a struck glass's ratios), each a pair beating slowly, the upper ones fading in.
    std::vector<float> x(n, 0.0f);
    const double ratio[] = {1.0, 2.32, 4.25, 6.63, 9.38, 12.6};
    for (int k = 0; k < 6; ++k) {
        const double f = kBuiltinRootHz * ratio[k];
        if (f > 0.45 * rate) break;
        for (int pair = 0; pair < 2; ++pair) {
            Rotor r;
            r.set(f + pair * (0.4 + 0.25 * k), rate, 1.3 * k + pair);
            const double a = 0.5 / (1.0 + k);
            for (size_t i = 0; i < n; ++i) {
                const double t = static_cast<double>(i) / n;
                x[i] += static_cast<float>(a * (k < 2 ? 1.0 : t) * r.next());
            }
        }
    }
    return x;
}

std::vector<float> breath(double rate, size_t n) {
    // Noise through a band-pass sweeping 500 Hz to 3 kHz, over a soft pitched core (the first two harmonics).
    std::vector<float> x(n, 0.0f);
    lib::Svf bp;
    uint32_t seed = 0x2545F491u;
    Rotor a, b;
    a.set(kBuiltinRootHz, rate, 0), b.set(2 * kBuiltinRootHz, rate, 0.5);
    for (size_t i = 0; i < n; ++i) {
        if ((i & 63) == 0) bp.set(500.0 * detPow(6.0, static_cast<double>(i) / n), 2.5, rate);
        seed = seed * 1664525u + 1013904223u;
        const double noise = static_cast<double>(seed >> 8) / 8388608.0 - 1.0;
        x[i] = static_cast<float>(1.6 * bp.process(noise).band + 0.25 * a.next() + 0.08 * b.next());
    }
    return x;
}

std::vector<float> choir(double rate, size_t n) {
    // Harmonics weighted by three formants that move from "ah" through "oh" to "eh", in three detuned voices.
    std::vector<float> x(n, 0.0f);
    const double vowels[3][3] = {{800, 1150, 2900}, {450, 800, 2830}, {400, 1600, 2700}};
    const double detune[3] = {-0.1, 0.0, 0.09};
    for (int v = 0; v < 3; ++v) {
        const double f0 = kBuiltinRootHz * detPow(2.0, detune[v] / 12.0);
        for (int k = 1; k * f0 < std::min(5000.0, 0.45 * rate); ++k) {
            Rotor r;
            r.set(k * f0, rate, 1.1 * k + v);
            double amp = 0, step = 0;
            for (size_t i = 0; i < n; ++i) {
                if ((i & 255) == 0) {  // the formant weight of this harmonic, linear between points every 256 frames
                    auto weight = [&](size_t at) {
                        const double t = 2.0 * std::min<double>(1.0, static_cast<double>(at) / n);
                        const int a = std::min(1, static_cast<int>(t));
                        const double u = t - a;
                        double w = 0;
                        for (int f = 0; f < 3; ++f) {
                            const double F = vowels[a][f] + u * (vowels[a + 1][f] - vowels[a][f]);
                            const double d = (k * f0 - F) / (90.0 + 0.06 * F);
                            w += detExp(-d * d) / (1 + f);
                        }
                        return 0.4 * w / std::sqrt(static_cast<double>(k));
                    };
                    const double now = i == 0 ? weight(0) : amp;
                    step = (weight(i + 256) - now) / 256.0;
                    amp = now;
                }
                x[i] += static_cast<float>(amp * r.next());
                amp += step;
            }
        }
    }
    return x;
}

std::shared_ptr<const Source> makeBuiltin(int kind, double rate) {
    auto s = std::make_shared<Source>();
    const size_t n = static_cast<size_t>(kBuiltinSeconds * rate);
    std::vector<float> x = kind == 0 ? strings(rate, n) : kind == 1 ? glass(rate, n) : kind == 2 ? breath(rate, n) : choir(rate, n);
    float peak = 0;
    for (float v : x) peak = std::max(peak, std::fabs(v));
    const double in = 0.005 * rate, out = 0.04 * rate;
    if (!padded(s->own[0][0], n)) return nullptr;
    float* y = s->own[0][0].data() + 1;
    for (size_t i = 0; i < n; ++i) {
        double g = peak > 0 ? 0.5 / peak : 0;
        if (i < in) g *= i / in;
        if (n - 1 - i < out) g *= (n - 1 - i) / out;
        y[i] = static_cast<float>(x[i] * g);
    }
    s->levels[0] = {y, y, static_cast<uint32_t>(n), false, 0, false};
    s->seconds = kBuiltinSeconds;
    s->builtin = kind;
    if (!finish(*s, true)) return nullptr;
    return s;
}

}  // namespace

size_t Source::bytes() const noexcept {
    size_t b = sizeof(Source);
    for (const auto& lv : own)
        for (const auto& c : lv) b += c.capacity() * sizeof(float);
    return b;
}

std::shared_ptr<const Source> sampleSource(const std::shared_ptr<const AudioAsset>& asset) {
    if (!asset || asset->frames < 16 || asset->frames > 0xFFFFFFF0ll) return nullptr;
    static std::mutex guard;
    static std::map<const AudioAsset*, std::weak_ptr<const Source>> cache;
    const std::lock_guard<std::mutex> lock(guard);
    for (auto it = cache.begin(); it != cache.end();) it = it->second.expired() ? cache.erase(it) : std::next(it);
    if (auto it = cache.find(asset.get()); it != cache.end())
        if (auto s = it->second.lock(); s && s->asset == asset) return s;
    try {
        auto s = std::make_shared<Source>();
        s->asset = asset;
        // Read in place: frames -1 .. length + 1 of the view are the asset's 0 .. frames - 1.
        const float* l = asset->channel(0) + 1;
        const float* r = asset->channel(1) + 1;
        s->levels[0] = {l, r, static_cast<uint32_t>(asset->frames - 3), false, 0, false};
        s->seconds = asset->seconds();
        if (!finish(*s, asset->seconds() <= kMaxMipSeconds)) return nullptr;
        cache[asset.get()] = s;
        return s;
    } catch (...) {
        return nullptr;
    }
}

std::shared_ptr<const Source> builtinSource(int kind, double rate) {
    kind = std::clamp(kind, 0, static_cast<int>(kBuiltinCount) - 1);
    if (!(rate >= 8000.0 && rate <= 384000.0)) rate = 48000.0;
    static std::mutex guard;
    static std::map<std::pair<int, double>, std::shared_ptr<const Source>> cache;
    const std::lock_guard<std::mutex> lock(guard);
    auto& slot = cache[{kind, rate}];
    if (!slot) {
        try {
            slot = makeBuiltin(kind, rate);
        } catch (...) {
            slot = nullptr;
        }
    }
    return slot;
}

}  // namespace caw::flock
