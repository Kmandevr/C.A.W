// Onsets, tempo detection and transients of an audio asset, for the app's tempo field and Slice to MIDI (API 32).
#include "audio_analysis.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstring>
#include <numeric>

#include "analysis.h"
#include "asset_store.h"
#include "json.h"

namespace caw {

namespace {

constexpr size_t kMaxOptionsBytes = 4096;

bool readOptions(const char* json, Json& out, std::string& error) {
    if (!json || !*json) return true;
    const size_t n = std::strlen(json);
    if (n > kMaxOptionsBytes) {
        error = "options are longer than " + std::to_string(kMaxOptionsBytes) + " bytes";
        return false;
    }
    if (!parseJson(std::string_view(json, n), out, error)) {
        error = "options: " + error;
        return false;
    }
    if (out.type != Json::Type::Object && out.type != Json::Type::Null) {
        error = "options must be an object";
        return false;
    }
    return true;
}

bool numberIn(const Json& j, const char* key, double lo, double hi, double& out, std::string& error) {
    const Json* v = j.type == Json::Type::Object ? j.get(key) : nullptr;
    if (!v || v->type == Json::Type::Null) return true;
    if (v->type != Json::Type::Number || !std::isfinite(v->num) || v->num < lo || v->num > hi) {
        char b[160];
        std::snprintf(b, sizeof b, "%s must be a number %g..%g", key, lo, hi);
        error = b;
        return false;
    }
    out = v->num;
    return true;
}

// The analysed range of an asset, in its frames (engine rate), and its mono sum.
bool rangeOf(const AudioAsset& a, double startSeconds, double endSeconds, int64_t& s0, int64_t& s1) {
    const double rate = a.rate;
    s0 = static_cast<int64_t>(std::floor(std::clamp(startSeconds * rate, 0.0, static_cast<double>(a.frames))));
    s1 = endSeconds > 0 ? static_cast<int64_t>(std::floor(std::clamp(endSeconds * rate, 0.0, static_cast<double>(a.frames))))
                        : a.frames;
    s1 = std::min<int64_t>(s1, s0 + static_cast<int64_t>(kMaxAnalysisSeconds * rate));
    return s1 > s0;
}

// The mono sum of an asset's frames [s0, s1), read in place (no copy of the range): index i is frame s0 + i.
struct Mono {
    const float* l;
    const float* r;
    int64_t s0, len;
    float operator[](int64_t i) const noexcept {
        const size_t f = static_cast<size_t>(s0 + i);
        return 0.5f * (l[f] + r[f]);
    }
    int64_t size() const noexcept { return len; }
};
Mono monoOf(const AudioAsset& a, int64_t s0, int64_t s1) {
    return Mono{a.channel(0), a.channel(a.channels > 1 ? 1 : 0), s0, s1 - s0};
}

// Spectral flux of log-compressed magnitudes (N-point Hann frames every `hop`), frame k centred on sample k * hop,
// in one streaming pass over the signal: its only memory is a frame, the last magnitudes and the curve itself.
std::vector<double> novelty(const Mono& x, size_t n, size_t hop) {
    const size_t frames = static_cast<size_t>(x.size()) / hop + 1;
    std::vector<double> out(frames, 0.0), prev(n / 2 + 1, 0.0), window(n);
    for (size_t i = 0; i < n; ++i) window[i] = 0.5 - 0.5 * std::cos(2.0 * 3.14159265358979323846 * static_cast<double>(i) / static_cast<double>(n));
    std::vector<std::complex<double>> buf(n);
    for (size_t k = 0; k < frames; ++k) {
        const int64_t c = static_cast<int64_t>(k * hop) - static_cast<int64_t>(n / 2);
        for (size_t i = 0; i < n; ++i) {
            const int64_t at = c + static_cast<int64_t>(i);
            const double v = at >= 0 && at < x.size() ? x[at] : 0.0;
            buf[i] = {v * window[i], 0.0};
        }
        analysis::fft(buf, false);
        double flux = 0;
        for (size_t b = 1; b <= n / 2; ++b) {
            const double m = std::log1p(100.0 * std::abs(buf[b]));
            flux += std::max(0.0, m - prev[b]);  // before the first frame: silence (an onset at the start counts)
            prev[b] = m;
        }
        out[k] = flux;
    }
    return out;
}

size_t pow2Near(double v) {
    size_t n = 64;
    while (static_cast<double>(n) * 1.5 < v && n < 16384) n *= 2;
    return n;
}

}  // namespace

bool parseTempoOptions(const char* json, TempoOptions& o, std::string& error) {
    Json j;
    if (!readOptions(json, j, error)) return false;
    if (!numberIn(j, "min_bpm", 30, 300, o.minBpm, error) || !numberIn(j, "max_bpm", 31, 600, o.maxBpm, error) ||
        !numberIn(j, "start_seconds", 0, 1e7, o.startSeconds, error) ||
        !numberIn(j, "end_seconds", 0, 1e7, o.endSeconds, error))
        return false;
    if (o.maxBpm < o.minBpm + 1 || o.maxBpm > 4 * o.minBpm) {
        error = "max_bpm must be above min_bpm (by 1 or more) and at most 4 times it";
        return false;
    }
    if (o.endSeconds > 0 && o.endSeconds <= o.startSeconds) {
        error = "end_seconds must be after start_seconds (or 0: the file's end)";
        return false;
    }
    return true;
}

bool parseSliceOptions(const char* json, SliceOptions& o, std::string& error) {
    Json j;
    if (!readOptions(json, j, error)) return false;
    double maxSlices = o.maxSlices;
    if (!numberIn(j, "sensitivity", 0, 1, o.sensitivity, error) ||
        !numberIn(j, "start_seconds", 0, 1e7, o.startSeconds, error) ||
        !numberIn(j, "end_seconds", 0, 1e7, o.endSeconds, error) ||
        !numberIn(j, "min_gap_seconds", 0.005, 2, o.minGapSeconds, error) ||
        !numberIn(j, "max_slices", 1, kMaxSlices, maxSlices, error))
        return false;
    if (maxSlices != std::floor(maxSlices)) {
        error = "max_slices must be a whole number";
        return false;
    }
    o.maxSlices = static_cast<int>(maxSlices);
    if (o.endSeconds > 0 && o.endSeconds <= o.startSeconds) {
        error = "end_seconds must be after start_seconds (or 0: the file's end)";
        return false;
    }
    if (o.endSeconds > 0 && o.endSeconds - o.startSeconds > kMaxAnalysisSeconds) {
        error = "the range is longer than " + std::to_string(static_cast<int>(kMaxAnalysisSeconds)) + " seconds";
        return false;
    }
    return true;
}

TempoResult detectTempo(const AudioAsset& a, const TempoOptions& o) {
    TempoResult res;
    int64_t s0, s1;
    if (a.rate <= 0 || !rangeOf(a, o.startSeconds, o.endSeconds, s0, s1)) return res;
    const Mono x = monoOf(a, s0, s1);
    const size_t n = pow2Near(a.rate * 0.0213), hop = n / 4;  // 1024 and 256 at 48 kHz
    const double hopSec = static_cast<double>(hop) / a.rate;
    std::vector<double> nov = novelty(x, n, hop);
    // Remove the slow trend (a moving mean over ~0.5 s), half-wave rectify.
    const size_t frames = nov.size();
    if (frames < 8) return res;
    {
        const size_t w = std::max<size_t>(1, static_cast<size_t>(0.25 / hopSec));
        std::vector<double> pre(frames + 1, 0.0);
        for (size_t i = 0; i < frames; ++i) pre[i + 1] = pre[i] + nov[i];
        std::vector<double> d(frames);
        for (size_t i = 0; i < frames; ++i) {
            const size_t lo = i > w ? i - w : 0, hi = std::min(frames, i + w + 1);
            d[i] = std::max(0.0, nov[i] - (pre[hi] - pre[lo]) / static_cast<double>(hi - lo));
        }
        nov.swap(d);
    }
    const double peak = *std::max_element(nov.begin(), nov.end());
    if (!(peak > 1e-9)) return res;
    // Onsets: local maxima above a third of the 95th percentile of the non-zero values, 50 ms apart.
    {
        std::vector<double> nz;
        for (double v : nov)
            if (v > 0) nz.push_back(v);
        std::sort(nz.begin(), nz.end());
        const double ref = nz.empty() ? peak : nz[static_cast<size_t>(0.95 * static_cast<double>(nz.size() - 1))];
        const size_t gap = std::max<size_t>(1, static_cast<size_t>(0.05 / hopSec));
        size_t last = 0;
        bool any = false;
        for (size_t i = 0; i + 1 < frames; ++i)
            if (nov[i] > ref / 3 && (i == 0 || nov[i] >= nov[i - 1]) && nov[i] > nov[i + 1] && (!any || i - last >= gap)) {
                ++res.onsets;
                last = i;
                any = true;
            }
    }
    // Autocorrelation of the novelty curve (its mean removed, so steady noise scores near 0) up to 8 periods of the
    // slowest tempo.
    {
        const double mean = std::accumulate(nov.begin(), nov.end(), 0.0) / static_cast<double>(frames);
        for (double& v : nov) v -= mean;
    }
    const size_t maxLag = std::min(frames - 1, static_cast<size_t>(std::ceil(8 * 60.0 / (o.minBpm * hopSec))) + 2);
    std::vector<double> acf(maxLag + 1, 0.0);
    for (size_t lag = 0; lag <= maxLag; ++lag) {
        double s = 0;
        for (size_t i = lag; i < frames; ++i) s += nov[i] * nov[i - lag];
        acf[lag] = s / static_cast<double>(frames - lag);
    }
    if (!(acf[0] > 0)) return res;
    auto at = [&](double lag) {
        if (lag < 0 || lag >= static_cast<double>(maxLag)) return 0.0;
        const size_t i = static_cast<size_t>(lag);
        const double f = lag - static_cast<double>(i);
        return (acf[i] * (1 - f) + acf[i + 1] * f) / acf[0];
    };
    auto score = [&](double bpm) {
        const double lag = 60.0 / (bpm * hopSec);
        double s = 0, w = 0;
        for (int k = 1; k <= 8; ++k) {
            if (k * lag >= static_cast<double>(maxLag)) break;
            s += at(k * lag);
            w += 1;
        }
        if (w <= 0) return 0.0;
        // Beats at twice this tempo (a strong half period) mean this is the half-time reading: less likely.
        const double half = 2 * bpm <= o.maxBpm ? std::max(0.0, at(0.5 * lag)) : 0.0;
        const double oct = std::log2(bpm / 120.0);
        return (s / w - 0.5 * half) * std::exp(-0.5 * oct * oct * 0.25);
    };
    std::vector<TempoCandidate> grid;
    for (double bpm = o.minBpm; bpm <= o.maxBpm + 1e-9; bpm += 0.1) grid.push_back({bpm, score(bpm)});
    // Local maxima, best first.
    std::vector<TempoCandidate> peaks;
    for (size_t i = 0; i < grid.size(); ++i) {
        const bool left = i == 0 || grid[i].score >= grid[i - 1].score;
        const bool right = i + 1 == grid.size() || grid[i].score > grid[i + 1].score;
        if (left && right) peaks.push_back(grid[i]);
    }
    std::sort(peaks.begin(), peaks.end(), [](const TempoCandidate& p, const TempoCandidate& q) { return p.score > q.score; });
    if (peaks.empty()) return res;
    // Refine the best few on a 0.01 BPM grid.
    for (size_t p = 0; p < peaks.size() && p < 3; ++p) {
        TempoCandidate best = peaks[p];
        for (double bpm = peaks[p].bpm - 0.15; bpm <= peaks[p].bpm + 0.15; bpm += 0.01) {
            if (bpm < o.minBpm || bpm > o.maxBpm) continue;
            const double s = score(bpm);
            if (s > best.score) best = {bpm, s};
        }
        double r = std::round(best.bpm * 100.0) / 100.0;
        if (std::fabs(r - std::round(r)) < 0.1) r = std::round(r);
        best.bpm = r;
        res.candidates.push_back(best);
    }
    res.bpm = res.candidates[0].bpm;
    res.confidence = std::clamp(res.candidates[0].score / std::exp(-0.5 * std::pow(std::log2(res.bpm / 120.0), 2) * 0.25), 0.0, 1.0);
    res.sure = res.onsets >= 4 && res.confidence >= 0.2;
    return res;
}

std::vector<Slice> detectSlices(const AudioAsset& a, const SliceOptions& o) {
    std::vector<Slice> out;
    int64_t s0, s1;
    if (a.rate <= 0 || !rangeOf(a, o.startSeconds, o.endSeconds, s0, s1)) return out;
    const size_t n = pow2Near(a.rate * 0.0107), hop = n / 4;  // 512 and 128 at 48 kHz
    const double hopSec = static_cast<double>(hop) / a.rate;
    // The novelty starts a whole number of hops before the range where the file has audio there, so a sound
    // already playing at the range's start is no onset; at the file's start, the silence before it is the reference.
    const int64_t lead = std::min<int64_t>(s0 / static_cast<int64_t>(hop), static_cast<int64_t>(n / hop) + 1) *
                         static_cast<int64_t>(hop);
    std::vector<double> nov = novelty(monoOf(a, s0 - lead, s1), n, hop);
    nov.erase(nov.begin(), nov.begin() + static_cast<std::ptrdiff_t>(std::min<size_t>(nov.size(), static_cast<size_t>(lead) / hop)));
    const Mono x = monoOf(a, s0, s1);
    const size_t frames = nov.size();
    if (frames < 3) return out;
    const double peak = *std::max_element(nov.begin(), nov.end());
    if (!(peak > 1e-9)) return out;
    // Threshold: a moving median over ~0.2 s plus delta, both relative to the curve's peak.
    const double s = std::clamp(o.sensitivity, 0.0, 1.0);
    const double delta = 0.02 + 0.98 * (1.0 - s) * (1.0 - s);
    const size_t w = std::max<size_t>(1, static_cast<size_t>(0.1 / hopSec));
    const size_t gap = std::max<size_t>(1, static_cast<size_t>(o.minGapSeconds / hopSec));
    std::vector<double> win;
    struct Cand {
        size_t k;
        double v;
    };
    std::vector<Cand> cands;
    for (size_t k = 0; k + 1 < frames; ++k) {
        const double v = nov[k] / peak;
        if (v < delta || (k > 0 && nov[k] < nov[k - 1]) || nov[k] <= nov[k + 1]) continue;
        const size_t lo = k > w ? k - w : 0, hi = std::min(frames, k + w + 1);
        win.assign(nov.begin() + static_cast<std::ptrdiff_t>(lo), nov.begin() + static_cast<std::ptrdiff_t>(hi));
        std::nth_element(win.begin(), win.begin() + static_cast<std::ptrdiff_t>(win.size() / 2), win.end());
        if (v < win[win.size() / 2] / peak + delta) continue;
        cands.push_back({k, v});
    }
    // At least `gap` apart: the stronger of two close peaks wins.
    std::vector<Cand> kept;
    for (const Cand& c : cands) {
        if (!kept.empty() && c.k - kept.back().k < gap) {
            if (c.v > kept.back().v) kept.back() = c;
            continue;
        }
        kept.push_back(c);
    }
    if (static_cast<int>(kept.size()) > o.maxSlices) {
        std::stable_sort(kept.begin(), kept.end(), [](const Cand& p, const Cand& q) { return p.v > q.v; });
        kept.resize(static_cast<size_t>(o.maxSlices));
        std::sort(kept.begin(), kept.end(), [](const Cand& p, const Cand& q) { return p.k < q.k; });
    }
    // Each onset to the start of its attack: the loudest sample near the frame, then back while the signal stays
    // above a tenth of it.
    const int64_t len = x.size();
    constexpr int64_t kEnv = 16;
    auto env = [&](int64_t i) {
        float m = 0;
        for (int64_t j = std::max<int64_t>(0, i); j < std::min(len, i + kEnv); ++j) m = std::max(m, std::fabs(x[j]));
        return m;
    };
    int64_t prevAt = -1;
    for (const Cand& c : kept) {
        const int64_t centre = static_cast<int64_t>(c.k * hop);
        const int64_t lo = std::max<int64_t>({0, centre - static_cast<int64_t>(n), prevAt + 1}),
                      hi = std::min<int64_t>(len, centre + static_cast<int64_t>(n / 2));
        if (hi <= lo) continue;
        int64_t ip = lo;
        float pk = 0;
        for (int64_t i = lo; i < hi; ++i)
            if (std::fabs(x[i]) > pk) {
                pk = std::fabs(x[i]);
                ip = i;
            }
        int64_t j = ip;
        while (j - kEnv >= lo && env(j - kEnv) >= 0.1f * pk) j -= kEnv;
        while (j - 1 >= lo && std::fabs(x[j - 1]) >= 0.1f * pk) --j;
        prevAt = j;
        if (static_cast<double>(j) < 0.005 * a.rate) continue;  // at the range's start: that is the first cut already
        Slice sl;
        sl.seconds = static_cast<double>(s0 + j) / a.rate;
        sl.frame = static_cast<int64_t>(std::llround(sl.seconds * (a.sourceRate > 0 ? a.sourceRate : a.rate)));
        sl.strength = std::clamp(c.v, 0.0, 1.0);
        out.push_back(sl);
    }
    return out;
}

}  // namespace caw
