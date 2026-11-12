// Tolerance tests against reference renders: the comparators, the reference codec and the .cawref files (tolerance.h).
#include "tolerance.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>

#include "analysis.h"
#include "test.h"

namespace cawtest {

namespace {

constexpr double kStep = 2097152.0;  // 2^21 steps per unit (the stored resolution, tolerance.h)
constexpr int64_t kClamp = int64_t{1} << 30;
constexpr int kBlock = 4096;
constexpr int kPartition = 256;
constexpr int kBandsLowest = -16;  // 1/3-octave band centres 1000 * 2^(k/3): 25 Hz ...
constexpr int kBandsHighest = 13;  // ... 20 kHz
constexpr size_t kFftSize = 8192;

double db10(double power) { return 10.0 * std::log10(power + 1e-30); }

int32_t toStep(float v) {
    if (!std::isfinite(v)) return 0;
    const double s = std::nearbyint(static_cast<double>(v) * kStep);
    return static_cast<int32_t>(std::clamp<double>(s, -static_cast<double>(kClamp), static_cast<double>(kClamp)));
}

// ---------------------------------------------------------------- bits

struct BitWriter {
    std::vector<uint8_t> out;
    uint64_t acc = 0;
    int bits = 0;
    void put(uint64_t v, int n) {  // n <= 64
        for (int i = n - 1; i >= 0; --i) {
            acc = (acc << 1) | ((v >> i) & 1u);
            if (++bits == 8) out.push_back(static_cast<uint8_t>(acc)), acc = 0, bits = 0;
        }
    }
    void flush() {
        if (bits) out.push_back(static_cast<uint8_t>(acc << (8 - bits))), acc = 0, bits = 0;
    }
};

struct BitReader {
    const std::vector<uint8_t>& in;
    size_t at = 0;  // in bits
    bool bad = false;
    uint64_t get(int n) {
        uint64_t v = 0;
        for (int i = 0; i < n; ++i) {
            if (at >= in.size() * 8) {
                bad = true;
                return 0;
            }
            v = (v << 1) | ((in[at / 8] >> (7 - at % 8)) & 1u);
            ++at;
        }
        return v;
    }
};

uint64_t zigzag(int64_t v) { return v < 0 ? (static_cast<uint64_t>(-(v + 1)) << 1) | 1u : static_cast<uint64_t>(v) << 1; }
int64_t unzigzag(uint64_t u) { return (u & 1u) ? -static_cast<int64_t>(u >> 1) - 1 : static_cast<int64_t>(u >> 1); }

constexpr uint64_t kEscape = 31;  // a Rice quotient this big is written as 64 raw bits instead

// A block's samples as coded, after kHistory earlier ones (zero before the first frame).
constexpr size_t kHistory = 32;
using Buf = std::vector<int64_t>;

// Fixed polynomial predictors (kinds 0 to 3), or linear prediction (kind 4) with integer coefficients over 2^shift,
// so decoding is exact integer arithmetic on every platform.
struct Predictor {
    int kind = 0;
    int shift = 0;
    std::vector<int32_t> c;
};
constexpr int kLpcOrders[] = {8, 16, 32};
int64_t predict(const Buf& x, size_t n, const Predictor& p) {  // n >= kHistory
    switch (p.kind) {
        case 0: return 0;
        case 1: return x[n - 1];
        case 2: return 2 * x[n - 1] - x[n - 2];
        case 3: return 3 * x[n - 1] - 3 * x[n - 2] + x[n - 3];
        default: {
            int64_t sum = 0;
            for (size_t j = 0; j < p.c.size(); ++j) sum += static_cast<int64_t>(p.c[j]) * x[n - 1 - j];
            return sum >> p.shift;  // an arithmetic shift (C++20)
        }
    }
}
// Linear prediction coefficients of x[kHistory, kHistory + len) by Levinson-Durbin on its autocorrelation.
Predictor lpc(const Buf& x, size_t len, int order) {
    Predictor p;
    p.kind = 4;
    std::vector<double> r(static_cast<size_t>(order) + 1, 0.0);
    for (int lag = 0; lag <= order; ++lag)
        for (size_t i = kHistory; i < kHistory + len; ++i) r[static_cast<size_t>(lag)] += static_cast<double>(x[i]) * static_cast<double>(x[i - static_cast<size_t>(lag)]);
    if (!(r[0] > 0)) return p;
    r[0] *= 1.0 + 1e-9;
    std::vector<double> a(static_cast<size_t>(order) + 1, 0.0), prev;
    double err = r[0];
    for (int m = 1; m <= order; ++m) {
        double k = r[static_cast<size_t>(m)];
        for (int j = 1; j < m; ++j) k -= a[static_cast<size_t>(j)] * r[static_cast<size_t>(m - j)];
        k /= err;
        prev = a;
        a[static_cast<size_t>(m)] = k;
        for (int j = 1; j < m; ++j) a[static_cast<size_t>(j)] = prev[static_cast<size_t>(j)] - k * prev[static_cast<size_t>(m - j)];
        err *= 1.0 - k * k;
        if (!(err > 0)) break;
    }
    for (double& v : a)
        if (!std::isfinite(v)) v = 0.0;
    double biggest = 0;
    for (int j = 1; j <= order; ++j) biggest = std::max(biggest, std::fabs(a[static_cast<size_t>(j)]));
    int shift = 14;
    while (shift > 0 && biggest * std::ldexp(1.0, shift) > 32767.0) --shift;
    p.shift = shift;
    for (int j = 1; j <= order; ++j)
        p.c.push_back(static_cast<int32_t>(std::clamp(std::nearbyint(a[static_cast<size_t>(j)] * std::ldexp(1.0, shift)), -32768.0, 32767.0)));
    return p;
}

uint64_t riceBits(uint64_t u, int k) {
    const uint64_t q = u >> k;
    return q >= kEscape ? kEscape + 64 : q + 1 + static_cast<uint64_t>(k);
}
void putRice(BitWriter& w, uint64_t u, int k) {
    const uint64_t q = u >> k;
    if (q >= kEscape) {
        w.put((uint64_t{1} << kEscape) - 1, static_cast<int>(kEscape));
        w.put(u, 64);
        return;
    }
    for (uint64_t i = 0; i < q; ++i) w.put(1, 1);
    w.put(0, 1);
    w.put(u & ((uint64_t{1} << k) - 1), k);
}
bool getRice(BitReader& r, int k, uint64_t& u) {
    uint64_t q = 0;
    while (q < kEscape && r.get(1) == 1 && !r.bad) ++q;
    if (r.bad) return false;
    if (q == kEscape) {
        u = r.get(64);
        return !r.bad;
    }
    u = (q << k) | r.get(k);
    return !r.bad;
}
constexpr int kZeroPartition = 31;  // a Rice parameter that means: every residual of the partition is 0

// The best predictor and Rice parameters for x[kHistory, kHistory + len), with the bits it takes.
struct Plan {
    Predictor predictor;
    std::vector<int> ks;
    uint64_t bits = 0;
};
Plan plan(const Buf& x, size_t len) {
    const size_t start = kHistory;
    Plan best;
    best.bits = std::numeric_limits<uint64_t>::max();
    std::vector<uint64_t> u(len);
    std::vector<Predictor> candidates(4);
    for (int k = 0; k < 4; ++k) candidates[static_cast<size_t>(k)].kind = k;
    for (int order : kLpcOrders) candidates.push_back(lpc(x, len, order));
    for (const Predictor& pred : candidates) {
        for (size_t i = 0; i < len; ++i) u[i] = zigzag(x[start + i] - predict(x, start + i, pred));
        Plan p;
        p.predictor = pred;
        p.bits = 3 + (pred.kind == 4 ? 6 + 4 + 16 * pred.c.size() : 0);
        for (size_t part = 0; part < len; part += kPartition) {
            const size_t end = std::min(len, part + kPartition);
            uint64_t sum = 0;
            for (size_t i = part; i < end; ++i) sum += u[i];
            if (sum == 0) {
                p.ks.push_back(kZeroPartition);
                p.bits += 5;
                continue;
            }
            const uint64_t mean = sum / (end - part);
            int guess = 0;
            while (guess < 30 && (uint64_t{1} << (guess + 1)) <= mean) ++guess;
            int bestK = 0;
            uint64_t bestBits = std::numeric_limits<uint64_t>::max();
            for (int k = 0; k <= 30; ++k) {
                uint64_t b = 0;
                for (size_t i = part; i < end; ++i) b += riceBits(u[i], k);
                if (b < bestBits) bestBits = b, bestK = k;
            }
            p.ks.push_back(bestK);
            p.bits += 5 + bestBits;
        }
        if (p.bits < best.bits) best = p;
    }
    return best;
}
void write(BitWriter& w, const Buf& x, size_t len, const Plan& p) {
    const size_t start = kHistory;
    w.put(static_cast<uint64_t>(p.predictor.kind), 3);
    if (p.predictor.kind == 4) {
        w.put(p.predictor.c.size(), 6);
        w.put(static_cast<uint64_t>(p.predictor.shift), 4);
        for (int32_t c : p.predictor.c) w.put(static_cast<uint16_t>(static_cast<int16_t>(c)), 16);
    }
    for (size_t part = 0, j = 0; part < len; part += kPartition, ++j) {
        const int k = p.ks[j];
        w.put(static_cast<uint64_t>(k), 5);
        if (k == kZeroPartition) continue;
        for (size_t i = part; i < std::min(len, part + kPartition); ++i)
            putRice(w, zigzag(x[start + i] - predict(x, start + i, p.predictor)), k);
    }
}
bool read(BitReader& r, Buf& x, size_t len) {
    const size_t start = kHistory;
    Predictor pred;
    pred.kind = static_cast<int>(r.get(3));
    if (pred.kind > 4) return false;
    if (pred.kind == 4) {
        const size_t order = static_cast<size_t>(r.get(6));
        if (order == 0 || order > kHistory) return false;
        pred.shift = static_cast<int>(r.get(4));
        for (size_t j = 0; j < order; ++j) pred.c.push_back(static_cast<int16_t>(static_cast<uint16_t>(r.get(16))));
    }
    for (size_t part = 0; part < len && !r.bad; part += kPartition) {
        const int k = static_cast<int>(r.get(5));
        for (size_t i = part; i < std::min(len, part + kPartition); ++i) {
            uint64_t u = 0;
            if (k != kZeroPartition && !getRice(r, k, u)) return false;
            const int64_t residual = unzigzag(u);  // |residual| < 2^63; a prediction stays below 2^52
            if (residual > 8 * kClamp || residual < -8 * kClamp) return false;
            x[start + i] = residual + predict(x, start + i, pred);
            if (x[start + i] > 4 * kClamp || x[start + i] < -4 * kClamp) return false;
        }
    }
    return !r.bad;
}

// ---------------------------------------------------------------- features

std::vector<float> windowDb(const std::vector<float>& x, bool difference) {
    std::vector<float> out;
    for (size_t at = 0; at < x.size(); at += tol::kWindowFrames) {
        const size_t end = std::min(x.size(), at + tol::kWindowFrames);
        double s = 0;
        for (size_t i = at; i < end; ++i) {
            const double v = difference ? (i ? static_cast<double>(x[i]) - x[i - 1] : 0.0) : x[i];
            s += v * v;
        }
        out.push_back(static_cast<float>(db10(s / static_cast<double>(end - at))));
    }
    return out;
}

std::vector<float> bandsDb(const std::vector<float>& x) {
    std::vector<double> power(kFftSize / 2, 0.0);
    std::vector<std::complex<double>> d(kFftSize);
    int windows = 0;
    for (size_t at = 0; windows == 0 || at + kFftSize <= x.size(); at += kFftSize / 2, ++windows) {
        for (size_t i = 0; i < kFftSize; ++i) {
            const double w = 0.5 - 0.5 * std::cos(2.0 * 3.14159265358979323846 * static_cast<double>(i) / kFftSize);
            d[i] = (at + i < x.size() ? static_cast<double>(x[at + i]) : 0.0) * w;
        }
        caw::analysis::fft(d, false);
        for (size_t k = 0; k < kFftSize / 2; ++k) power[k] += std::norm(d[k]);
    }
    const double scale = static_cast<double>(windows) * (kFftSize * kFftSize / 4.0);
    // Below 20 Hz, DC included (bins 0 to 3; the 25 Hz band starts at 22.3 Hz): an offset or a lost DC blocker.
    double sub = 0;
    for (size_t k = 0; k * 48000.0 / kFftSize < 20.0; ++k) sub += power[k];
    std::vector<float> out{static_cast<float>(db10(sub / scale))};
    for (int b = kBandsLowest; b <= kBandsHighest; ++b) {
        const double centre = 1000.0 * std::pow(2.0, b / 3.0);
        const double lo = centre * std::pow(2.0, -1.0 / 6.0), hi = centre * std::pow(2.0, 1.0 / 6.0);
        double sum = 0;
        for (size_t k = 1; k < kFftSize / 2; ++k) {
            const double hz = static_cast<double>(k) * 48000.0 / kFftSize;
            if (hz >= lo && hz < hi) sum += power[k];
        }
        out.push_back(static_cast<float>(db10(sum / scale)));
    }
    return out;
}

// The largest difference between two level curves, each held at the reference's floor; "" if within `limit`.
std::string compareCurve(const char* what, int channel, const std::vector<float>& ref, const std::vector<float>& now,
                         double limit, double unit) {
    if (ref.size() != now.size()) return std::string(what) + ": " + std::to_string(now.size()) + " values, not " + std::to_string(ref.size());
    double loudest = -1e30;
    for (float v : ref) loudest = std::max(loudest, static_cast<double>(v));
    const double floor = std::max(loudest - tol::kFloorBelowLoudestDb, tol::kAbsoluteFloorDbfs);
    for (size_t i = 0; i < ref.size(); ++i) {
        const double a = std::max(static_cast<double>(ref[i]), floor), b = std::max(static_cast<double>(now[i]), floor);
        if (!(std::fabs(a - b) <= limit)) {
            char buf[200];
            std::snprintf(buf, sizeof buf, "%s %s at %.0f: %.3f dB, reference %.3f dB (limit %.2f dB)", channel ? "right" : "left",
                          what, static_cast<double>(i) * unit, b, a, limit);
            return buf;
        }
    }
    return {};
}

double maxCurveDelta(const std::vector<float>& ref, const std::vector<float>& now) {
    if (ref.size() != now.size()) return 1e9;
    double loudest = -1e30, d = 0;
    for (float v : ref) loudest = std::max(loudest, static_cast<double>(v));
    const double floor = std::max(loudest - tol::kFloorBelowLoudestDb, tol::kAbsoluteFloorDbfs);
    for (size_t i = 0; i < ref.size(); ++i)
        d = std::max(d, std::fabs(std::max(static_cast<double>(ref[i]), floor) - std::max(static_cast<double>(now[i]), floor)));
    return d;
}

// ---------------------------------------------------------------- file bytes (little-endian on every platform)

void putU(std::vector<uint8_t>& b, uint64_t v, int bytes) {
    for (int i = 0; i < bytes; ++i) b.push_back(static_cast<uint8_t>(v >> (8 * i)));
}
void putF(std::vector<uint8_t>& b, float f) {
    uint32_t u;
    std::memcpy(&u, &f, 4);
    putU(b, u, 4);
}
void putS(std::vector<uint8_t>& b, const std::string& s) {
    putU(b, s.size(), 2);
    b.insert(b.end(), s.begin(), s.end());
}
void putFloats(std::vector<uint8_t>& b, const std::vector<float>& v) {
    putU(b, v.size(), 4);
    for (float f : v) putF(b, f);
}
void putFrames(std::vector<uint8_t>& b, const std::vector<uint32_t>& v) {
    putU(b, v.size(), 4);
    for (uint32_t f : v) putU(b, f, 4);
}

struct Bytes {
    const std::vector<uint8_t>& b;
    size_t at = 0;
    bool bad = false;
    uint64_t u(int bytes) {
        if (at + static_cast<size_t>(bytes) > b.size()) {
            bad = true;
            return 0;
        }
        uint64_t v = 0;
        for (int i = 0; i < bytes; ++i) v |= static_cast<uint64_t>(b[at + static_cast<size_t>(i)]) << (8 * i);
        at += static_cast<size_t>(bytes);
        return v;
    }
    float f() {
        const uint32_t v = static_cast<uint32_t>(u(4));
        float x;
        std::memcpy(&x, &v, 4);
        return x;
    }
    std::string s() {
        const size_t n = static_cast<size_t>(u(2));
        if (bad || at + n > b.size()) {
            bad = true;
            return {};
        }
        std::string out(b.begin() + static_cast<std::ptrdiff_t>(at), b.begin() + static_cast<std::ptrdiff_t>(at + n));
        at += n;
        return out;
    }
    bool floats(std::vector<float>& v, size_t limit) {
        const size_t n = static_cast<size_t>(u(4));
        if (bad || n > limit) {
            bad = true;
            return false;
        }
        v.resize(n);
        for (float& x : v) x = f();
        return !bad;
    }
    bool frames(std::vector<uint32_t>& v, size_t limit) {
        const size_t n = static_cast<size_t>(u(4));
        if (bad || n > limit) {
            bad = true;
            return false;
        }
        v.resize(n);
        for (uint32_t& x : v) x = static_cast<uint32_t>(u(4));
        return !bad;
    }
};

constexpr char kMagic[8] = {'C', 'A', 'W', 'R', 'E', 'F', '1', '\n'};
constexpr uint32_t kMaxFrames = 48000u * 60u;

}  // namespace

// ---------------------------------------------------------------- comparators

Audio fromInterleaved(const std::vector<float>& lr) {
    Audio a;
    a.l.reserve(lr.size() / 2);
    a.r.reserve(lr.size() / 2);
    for (size_t i = 0; i + 1 < lr.size(); i += 2) a.l.push_back(lr[i]), a.r.push_back(lr[i + 1]);
    return a;
}

std::vector<uint32_t> onsets(const std::vector<float>& x) {
    std::vector<uint32_t> out;
    bool armed = true;  // after enough silence (and at the start)
    int quiet = 0;
    for (size_t i = 0; i < x.size(); ++i) {
        const float v = std::fabs(x[i]);
        if (armed && v > tol::kOnsetLevel) {
            out.push_back(static_cast<uint32_t>(i));
            armed = false;
        }
        if (!(v <= tol::kSilenceLevel)) {
            quiet = 0;
        } else if (++quiet >= tol::kSilenceFrames) {
            armed = true;
            quiet = tol::kSilenceFrames;
        }
    }
    return out;
}

Features measureFeatures(const Audio& a) {
    Features f;
    f.frames = static_cast<uint32_t>(a.frames());
    const std::vector<float>* ch[2] = {&a.l, &a.r};
    for (int c = 0; c < 2; ++c) {
        f.loud[c] = windowDb(*ch[c], false);
        f.bright[c] = windowDb(*ch[c], true);
        f.bands[c] = bandsDb(*ch[c]);
        f.onsets[c] = onsets(*ch[c]);
    }
    return f;
}

double nullResidualDbfs(const Audio& reference, const Audio& render) {
    if (reference.l.size() != render.l.size() || reference.r.size() != render.r.size())
        return std::numeric_limits<double>::infinity();
    double peak = 0;
    const std::vector<float>* a[2] = {&reference.l, &reference.r};
    const std::vector<float>* b[2] = {&render.l, &render.r};
    for (int c = 0; c < 2; ++c)
        for (size_t i = 0; i < a[c]->size(); ++i) {
            const double d = std::fabs(static_cast<double>((*a[c])[i]) - (*b[c])[i]);
            if (!(d < 1e30)) return std::numeric_limits<double>::infinity();
            peak = std::max(peak, d);
        }
    return 20.0 * std::log10(peak);
}

std::string compareStable(const Audio& reference, const Audio& render) {
    if (reference.l.size() != render.l.size() || reference.r.size() != render.r.size())
        return "length " + std::to_string(render.frames()) + " frames, reference " + std::to_string(reference.frames());
    double peak = 0;
    size_t where = 0;
    int side = 0;
    const std::vector<float>* a[2] = {&reference.l, &reference.r};
    const std::vector<float>* b[2] = {&render.l, &render.r};
    for (int c = 0; c < 2; ++c)
        for (size_t i = 0; i < a[c]->size(); ++i) {
            const double d = std::fabs(static_cast<double>((*a[c])[i]) - (*b[c])[i]);
            if (!(d <= peak)) {
                if (!(d < 1e30)) return "not finite at frame " + std::to_string(i);
                peak = d, where = i, side = c;
            }
        }
    const double dbfs = 20.0 * std::log10(std::max(peak, 1e-300));
    if (dbfs < tol::kNullPeakDbfs) return {};
    char buf[200];
    std::snprintf(buf, sizeof buf, "null residual %.1f dBFS at %s frame %zu (limit %.0f dBFS)", dbfs, side ? "right" : "left",
                  where, tol::kNullPeakDbfs);
    return buf;
}

std::string compareChaotic(const Features& reference, const Features& render) {
    if (reference.frames != render.frames)
        return "length " + std::to_string(render.frames) + " frames, reference " + std::to_string(reference.frames);
    const double window = static_cast<double>(tol::kWindowFrames);
    for (int c = 0; c < 2; ++c) {
        std::string why = compareCurve("loudness, frame", c, reference.loud[c], render.loud[c], tol::kLoudnessDb, window);
        if (why.empty()) why = compareCurve("difference loudness, frame", c, reference.bright[c], render.bright[c], tol::kLoudnessDb, window);
        if (why.empty()) why = compareCurve("1/3-octave band", c, reference.bands[c], render.bands[c], tol::kBandDb, 1);
        bool onsetsMatch = reference.onsets[c].size() == render.onsets[c].size();
        for (size_t i = 0; onsetsMatch && i < reference.onsets[c].size(); ++i) {
            const uint32_t x = reference.onsets[c][i], y = render.onsets[c][i];
            onsetsMatch = (x > y ? x - y : y - x) <= tol::kOnsetSlackFrames;
        }
        if (why.empty() && !onsetsMatch) {
            why = std::string(c ? "right" : "left") + " onsets differ:";
            for (size_t i = 0; i < std::max(reference.onsets[c].size(), render.onsets[c].size()) && i < 8; ++i)
                why += " " + (i < render.onsets[c].size() ? std::to_string(render.onsets[c][i]) : std::string("-")) + "/" +
                       (i < reference.onsets[c].size() ? std::to_string(reference.onsets[c][i]) : std::string("-"));
        }
        if (!why.empty()) return why;
    }
    return {};
}

// ---------------------------------------------------------------- codec

Audio quantize(const Audio& a) {
    Audio q;
    for (const float v : a.l) q.l.push_back(static_cast<float>(toStep(v) / kStep));
    for (const float v : a.r) q.r.push_back(static_cast<float>(toStep(v) / kStep));
    return q;
}

namespace {

// The steps of a stereo signal; a block codes the right as itself or as right minus left (`side`).
struct Steps {
    std::vector<int64_t> l, r;
};
// Channel 0 or 1 of frames [start - kHistory, start + len) as a block in that mode codes them.
Buf coded(const Steps& x, size_t start, size_t len, bool side, int channel) {
    Buf v(kHistory + len, 0);
    for (size_t k = 0; k < v.size(); ++k) {
        if (start + k < kHistory) continue;
        const size_t i = start + k - kHistory;
        v[k] = channel == 0 ? x.l[i] : side ? x.r[i] - x.l[i] : x.r[i];
    }
    return v;
}

}  // namespace

std::vector<uint8_t> encodeAudio(const Audio& a) {
    const size_t n = a.frames();
    Steps x;
    for (const float v : a.l) x.l.push_back(toStep(v));
    for (const float v : a.r) x.r.push_back(toStep(v));
    BitWriter w;
    for (size_t start = 0; start < n; start += kBlock) {
        const size_t len = std::min<size_t>(kBlock, n - start);
        const Buf l = coded(x, start, len, false, 0), r = coded(x, start, len, false, 1), s = coded(x, start, len, true, 1);
        const Plan pl = plan(l, len), pr = plan(r, len), ps = plan(s, len);
        const bool side = ps.bits < pr.bits;
        w.put(side ? 1 : 0, 1);
        write(w, l, len, pl);
        if (side) write(w, s, len, ps);
        else write(w, r, len, pr);
    }
    w.flush();
    return w.out;
}

bool decodeAudio(const std::vector<uint8_t>& bytes, uint32_t frames, Audio& out) {
    const size_t n = frames;
    Steps x;
    x.l.assign(n, 0);
    x.r.assign(n, 0);
    BitReader rd{bytes};
    for (size_t start = 0; start < n; start += kBlock) {
        const size_t len = std::min<size_t>(kBlock, n - start);
        const bool side = rd.get(1) == 1;
        if (rd.bad) return false;
        Buf v0 = coded(x, start, 0, side, 0), v1 = coded(x, start, 0, side, 1);
        v0.resize(kHistory + len), v1.resize(kHistory + len);
        if (!read(rd, v0, len) || !read(rd, v1, len)) return false;
        for (size_t k = 0; k < len; ++k) {
            x.l[start + k] = v0[kHistory + k];
            x.r[start + k] = side ? v1[kHistory + k] + v0[kHistory + k] : v1[kHistory + k];
        }
    }
    out.l.resize(n);
    out.r.resize(n);
    for (size_t i = 0; i < n; ++i) out.l[i] = static_cast<float>(x.l[i] / kStep), out.r[i] = static_cast<float>(x.r[i] / kStep);
    return true;
}

// ---------------------------------------------------------------- the reference sets

namespace {

// The largest loudness and band differences, for CAW_REFERENCE_REPORT.
std::string featureDeltas(const Features& a, const Features& b) {
    double loud = 0, bands = 0;
    for (int ch = 0; ch < 2; ++ch) {
        loud = std::max({loud, maxCurveDelta(a.loud[ch], b.loud[ch]), maxCurveDelta(a.bright[ch], b.bright[ch])});
        bands = std::max(bands, maxCurveDelta(a.bands[ch], b.bands[ch]));
    }
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.4f|%.4f", loud, bands);
    return buf;
}

}  // namespace

References::References(std::string suite) : References(std::move(suite), std::string(), updateGolden) {}

References::References(std::string suite, std::string dir, bool updating)
    : suite_(std::move(suite)), dir_(std::move(dir)), updating_(updating), failuresAtStart_(failureCount()) {
    if (!updating_) loaded_ = load();
}

References::~References() {
    if (updating_) {
        if (failureCount() > failuresAtStart_)
            std::printf("     %s not written: its test failed while recording\n", path().c_str());
        else if (!save())
            fail(__FILE__, __LINE__, "could not write " + path());
        return;
    }
    for (const Entry& e : entries_)
        if (!e.compared) fail(__FILE__, __LINE__, suite_ + "/" + e.name + ": stored but never compared (a case went missing?)");
}

std::string References::path() const {
    if (!dir_.empty()) return dir_ + "/" + suite_ + ".cawref";
#ifdef CAW_ROOT
    return std::string(CAW_ROOT) + "/engine/tests/references/" + suite_ + ".cawref";
#else
    return "engine/tests/references/" + suite_ + ".cawref";
#endif
}

References::Entry* References::find(const std::string& name) {
    for (Entry& e : entries_)
        if (e.name == name) return &e;
    return nullptr;
}

void References::check(const std::string& name, const Audio& render, Class c, const char* file, int line) {
    const std::string why = compare(name, render, c);
    if (!why.empty()) fail(file, line, suite_ + "/" + name + ": " + why);
}

std::string References::compare(const std::string& name, const Audio& render, Class c) {
    const std::string label = suite_ + "/" + name;
    if (render.l.size() != render.r.size() || render.frames() == 0 || render.frames() > kMaxFrames) return "no render to compare";
    const uint32_t frames = static_cast<uint32_t>(render.frames());
    if (updating_) {
        if (find(name)) return "recorded twice";
        Entry e;
        e.name = name;
        e.cls = c;
        e.frames = frames;
        if (c == Class::Chaotic) {
            e.features = measureFeatures(render);
        } else {
            e.wave = encodeAudio(render);
            for (const Entry& x : entries_)
                if (x.cls == Class::Stable && x.alias.empty() && x.frames == e.frames && x.wave == e.wave) {
                    e.alias = x.name;  // the same whole waveform, bit for bit
                    e.wave.clear();
                    break;
                }
        }
        entries_.push_back(std::move(e));
        return {};
    }
    if (!loaded_) return "cannot read " + path() + " (record it with caw_tests --update-references)";
    Entry* e = find(name);
    if (!e) return "no reference (record it with caw_tests --update-references)";
    e->compared = true;
    if (e->cls != c) return "recorded as another class; re-record the references";
    if (e->frames != frames) return std::to_string(frames) + " frames, reference " + std::to_string(e->frames);
    const bool report = std::getenv("CAW_REFERENCE_REPORT") != nullptr;
    if (c == Class::Chaotic) {
        const Features now = measureFeatures(render);
        const std::string why = compareChaotic(e->features, now);
        if (report)
            std::printf("REF %s|chaotic|-|%s|%s\n", label.c_str(), featureDeltas(e->features, now).c_str(), why.empty() ? "ok" : why.c_str());
        return why.empty() ? std::string() : "(chaotic) " + why;
    }
    const Entry* w = e->alias.empty() ? e : find(e->alias);
    Audio ref;
    if (!w || !decodeAudio(w->wave, w->frames, ref)) return "its stored reference does not decode";
    const std::string why = compareStable(ref, render);
    if (report) {
        const Features a = measureFeatures(ref), b = measureFeatures(render);
        const std::string heard = compareChaotic(a, b);
        std::printf("REF %s|stable|%.1f|%s|%s|%s\n", label.c_str(), nullResidualDbfs(ref, render), featureDeltas(a, b).c_str(),
                    heard.empty() ? "features-ok" : heard.c_str(), why.empty() ? "ok" : why.c_str());
    }
    return why;
}

bool References::load() {
    std::FILE* f = std::fopen(path().c_str(), "rb");
    if (!f) return false;
    std::vector<uint8_t> b;
    uint8_t buf[65536];
    for (size_t n; (n = std::fread(buf, 1, sizeof buf, f)) > 0;) b.insert(b.end(), buf, buf + n);
    std::fclose(f);
    if (b.size() < 12 || std::memcmp(b.data(), kMagic, 8) != 0) return false;
    Bytes in{b, 8};
    const size_t count = static_cast<size_t>(in.u(4));
    if (count > 10000) return false;
    for (size_t k = 0; k < count && !in.bad; ++k) {
        Entry e;
        e.name = in.s();
        const uint64_t kind = in.u(1);
        e.frames = static_cast<uint32_t>(in.u(4));
        if (in.bad || e.frames == 0 || e.frames > kMaxFrames || find(e.name)) return false;
        if (kind == 0) {
            const size_t n = static_cast<size_t>(in.u(4));
            if (in.bad || in.at + n > b.size()) return false;
            e.wave.assign(b.begin() + static_cast<std::ptrdiff_t>(in.at), b.begin() + static_cast<std::ptrdiff_t>(in.at + n));
            in.at += n;
        } else if (kind == 2) {
            e.alias = in.s();
            const Entry* target = find(e.alias);
            if (!target || !target->alias.empty() || target->cls != Class::Stable || target->frames != e.frames) return false;
        } else if (kind == 1) {
            e.cls = Class::Chaotic;
            e.features.frames = e.frames;
            for (int c = 0; c < 2; ++c)
                in.floats(e.features.loud[c], kMaxFrames), in.floats(e.features.bright[c], kMaxFrames),
                    in.floats(e.features.bands[c], 64), in.frames(e.features.onsets[c], kMaxFrames);
        } else {
            return false;
        }
        entries_.push_back(std::move(e));
    }
    if (in.bad || in.at != b.size()) {
        entries_.clear();
        return false;
    }
    return true;
}

bool References::save() const {
    std::vector<uint8_t> b(kMagic, kMagic + 8);
    putU(b, entries_.size(), 4);
    for (const Entry& e : entries_) {
        putS(b, e.name);
        const int kind = e.cls == Class::Chaotic ? 1 : e.alias.empty() ? 0 : 2;
        putU(b, static_cast<uint64_t>(kind), 1);
        putU(b, e.frames, 4);
        if (kind == 0) {
            putU(b, e.wave.size(), 4);
            b.insert(b.end(), e.wave.begin(), e.wave.end());
        } else if (kind == 2) {
            putS(b, e.alias);
        } else {
            for (int c = 0; c < 2; ++c)
                putFloats(b, e.features.loud[c]), putFloats(b, e.features.bright[c]), putFloats(b, e.features.bands[c]),
                    putFrames(b, e.features.onsets[c]);
        }
    }
    std::FILE* f = std::fopen(path().c_str(), "wb");
    if (!f) return false;
    const bool ok = std::fwrite(b.data(), 1, b.size(), f) == b.size();
    return std::fclose(f) == 0 && ok;
}

}  // namespace cawtest
