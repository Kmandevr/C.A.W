// The tempo map and time signatures (tempo_map.h). Built with the strict floating-point flags, as sample_time.cpp is:
// note, clip, loop and automation timing is exact to the sample on every platform.
#include "tempo_map.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

#include "sample_time.h"

namespace caw {

namespace {

std::string num(double v) {
    char b[32];
    std::snprintf(b, sizeof b, "%.10g", v);
    return b;
}

}  // namespace

namespace tempomath {

namespace {

constexpr double kLn2Hi = 6.93147180369123816490e-01;  // ln 2 split for Cody-Waite (fdlibm's constants)
constexpr double kLn2Lo = 1.90821492927058770002e-10;
constexpr double kLn2 = 0.693147180559945309417232121458176568;
constexpr double kInvLn2 = 1.44269504088896338700e+00;

// 1 / (2k + 1) for k = 0..12 and 1 / n! for n = 0..15, as literals (no division at run time).
constexpr double kOdd[13] = {1.0, 1.0 / 3, 1.0 / 5, 1.0 / 7, 1.0 / 9, 1.0 / 11, 1.0 / 13, 1.0 / 15, 1.0 / 17, 1.0 / 19,
                             1.0 / 21, 1.0 / 23, 1.0 / 25};
constexpr double kFact[16] = {1.0, 1.0, 1.0 / 2, 1.0 / 6, 1.0 / 24, 1.0 / 120, 1.0 / 720, 1.0 / 5040, 1.0 / 40320,
                              1.0 / 362880, 1.0 / 3628800, 1.0 / 39916800, 1.0 / 479001600, 1.0 / 6227020800.0,
                              1.0 / 87178291200.0, 1.0 / 1307674368000.0};

// 2 atanh(s) = ln((1 + s) / (1 - s)), |s| <= 0.1716: the odd series to s^25.
double logSeries(double s) {
    const double s2 = s * s;
    double p = kOdd[12];
    for (int k = 11; k >= 0; --k) p = p * s2 + kOdd[k];
    return 2.0 * s * p;
}

// e^r - 1 for |r| <= 0.35: Taylor to r^15 / 15!, Horner from the top.
double expm1Series(double r) {
    double p = kFact[15];
    for (int n = 14; n >= 1; --n) p = p * r + kFact[n];
    return r * p;
}

}  // namespace

double log1p(double x) noexcept {
    if (!(x > -1.0)) return -1e300;
    if (x > -0.2928932188134524 && x < 0.41421356237309515) return logSeries(x / (2.0 + x));  // 1 + x in [1/sqrt2, sqrt2]
    int e = 0;
    double m = std::frexp(1.0 + x, &e);  // [0.5, 1)
    if (m < 0.70710678118654752440) {
        m *= 2.0;
        e -= 1;
    }
    return static_cast<double>(e) * kLn2 + logSeries((m - 1.0) / (m + 1.0));
}

double expm1(double x) noexcept {
    if (!(x < 700.0)) return 1e300;
    if (x < -40.0) return -1.0;
    if (x > -0.35 && x < 0.35) return expm1Series(x);
    const double n = std::floor(x * kInvLn2 + 0.5);
    const double r = (x - n * kLn2Hi) - n * kLn2Lo;  // |r| <= ln2 / 2 + a little
    return std::ldexp(1.0 + expm1Series(r), static_cast<int>(n)) - 1.0;
}

}  // namespace tempomath

bool checkTempoPoints(std::vector<TempoPointSpec>& points, std::string& error) {
    if (points.empty() || points.size() > static_cast<size_t>(kMaxTempoPoints)) {
        error = "tempo_map must hold 1 to " + std::to_string(kMaxTempoPoints) + " points";
        return false;
    }
    for (const TempoPointSpec& p : points) {
        if (!std::isfinite(p.beat) || p.beat < 0 || p.beat > 1e9) {
            error = "tempo_map beats must be from 0 to 1e9";
            return false;
        }
        if (!std::isfinite(p.bpm) || p.bpm < kMinTempoBpm || p.bpm > kMaxTempoBpm) {
            error = "tempo_map bpm must be from 1 to 999 (point at beat " + num(p.beat) + ")";
            return false;
        }
    }
    std::stable_sort(points.begin(), points.end(), [](const TempoPointSpec& a, const TempoPointSpec& b) {
        return a.beat < b.beat;
    });
    if (points.front().beat != 0.0) {
        error = "tempo_map must start with a point at beat 0";
        return false;
    }
    for (size_t i = 1; i < points.size(); ++i)
        if (points[i].beat == points[i - 1].beat) {
            error = "tempo_map has two points at beat " + num(points[i].beat);
            return false;
        }
    points.front().ramp = false;
    return true;
}

bool checkTimeSigs(std::vector<TimeSigSpec>& sigs, std::string& error, bool checkBeats) {
    if (sigs.empty() || sigs.size() > static_cast<size_t>(kMaxTimeSigs)) {
        error = "time_signatures must hold 1 to " + std::to_string(kMaxTimeSigs) + " entries";
        return false;
    }
    for (const TimeSigSpec& s : sigs) {
        if (s.bar < 0 || s.bar > 1000000000) {
            error = "time_signatures bars must be from 0 to 1e9";
            return false;
        }
        const bool denOk = s.den == 1 || s.den == 2 || s.den == 4 || s.den == 8 || s.den == 16 || s.den == 32;
        if (s.num < 1 || s.num > 32 || !denOk) {
            error = "time signature at bar " + std::to_string(s.bar) + " must be 1..32 over 1, 2, 4, 8, 16 or 32";
            return false;
        }
    }
    std::stable_sort(sigs.begin(), sigs.end(), [](const TimeSigSpec& a, const TimeSigSpec& b) { return a.bar < b.bar; });
    if (sigs.front().bar != 0) {
        error = "time_signatures must start at bar 0";
        return false;
    }
    double beat = 0;
    for (size_t i = 0; i < sigs.size(); ++i) {
        if (i > 0) {
            if (sigs[i].bar == sigs[i - 1].bar) {
                error = "time_signatures has two entries at bar " + std::to_string(sigs[i].bar);
                return false;
            }
            beat += static_cast<double>(sigs[i].bar - sigs[i - 1].bar) * (sigs[i - 1].num * 4.0 / sigs[i - 1].den);
        }
        if (checkBeats && !std::isnan(sigs[i].beat) && !(std::fabs(sigs[i].beat - beat) <= 1e-6)) {
            error = "time signature at bar " + std::to_string(sigs[i].bar) + " says beat " + num(sigs[i].beat) +
                    ", but its bars put it at beat " + num(beat);
            return false;
        }
        sigs[i].beat = beat;
    }
    return true;
}

bool timeSigsFromBeats(std::vector<TimeSigSpec>& sigs, std::string& error, bool dropOffBar) {
    if (sigs.empty() || sigs.size() > static_cast<size_t>(kMaxTimeSigs)) {
        error = "time signatures must hold 1 to " + std::to_string(kMaxTimeSigs) + " entries";
        return false;
    }
    for (const TimeSigSpec& s : sigs)
        if (!std::isfinite(s.beat) || s.beat < 0 || s.beat > 1e9) {
            error = "time signature beats must be from 0 to 1e9";
            return false;
        }
    std::stable_sort(sigs.begin(), sigs.end(), [](const TimeSigSpec& a, const TimeSigSpec& b) { return a.beat < b.beat; });
    if (sigs.front().beat != 0.0) {
        error = "the first time signature must be at beat 0";
        return false;
    }
    std::vector<TimeSigSpec> out;
    out.reserve(sigs.size());
    for (TimeSigSpec s : sigs) {
        if (out.empty()) {
            s.bar = 0;
            out.push_back(s);
            continue;
        }
        const TimeSigSpec& p = out.back();
        if (p.num < 1 || p.den < 1) break;  // checkTimeSigs names it
        const double bars = (s.beat - p.beat) / (p.num * 4.0 / p.den);
        const double whole = std::floor(bars + 0.5);
        if (whole < 1 || std::fabs(bars - whole) > 1e-6) {
            if (dropOffBar) continue;
            error = "the time signature at beat " + num(s.beat) + " is not on a bar line";
            return false;
        }
        s.bar = p.bar + static_cast<int64_t>(whole);
        out.push_back(s);
    }
    sigs = std::move(out);
    return checkTimeSigs(sigs, error, false);
}

// ---------------------------------------------------------------------------------------------------------------
// TempoMap

void TempoMap::build(const std::vector<TempoPointSpec>& in, double sampleRate) {
    sr_ = sampleRate;
    std::vector<TempoPointSpec> pts;
    pts.reserve(in.size() + 1);
    if (in.empty()) pts.push_back({0.0, 120.0, false});
    for (size_t i = 0; i < in.size(); ++i) {
        TempoPointSpec p = in[i];
        if (i == 0) p.ramp = false;
        // A point with the tempo before it changes nothing, unless a ramp starts from it.
        const bool rampFromHere = i + 1 < in.size() && in[i + 1].ramp && in[i + 1].bpm != p.bpm;
        if (!pts.empty() && pts.back().bpm == p.bpm && !rampFromHere) continue;
        pts.push_back(p);
    }
    points_ = pts;
    segs_.assign(pts.size(), Seg{});
    for (size_t i = 0; i < pts.size(); ++i) {
        Seg& s = segs_[i];
        s.step0 = pts[i].beat * 4.0;
        s.bpm0 = pts[i].bpm;
        const bool ramp = i + 1 < pts.size() && pts[i + 1].ramp && pts[i + 1].bpm != pts[i].bpm;
        s.slope = ramp ? (pts[i + 1].bpm - pts[i].bpm) / (pts[i + 1].beat - pts[i].beat) : 0.0;
        s.stepFrames = sampletime::stepFrames(sr_, s.bpm0);
        if (i > 0) {
            const Seg& p = segs_[i - 1];
            const double d = s.step0 - p.step0;
            if (p.slope == 0.0) {
                s.frame0 = p.frame0 + d * p.stepFrames;
                s.sec0 = p.sec0 + (d / 4.0) * 60.0 / p.bpm0;
            } else {
                const double t = 60.0 / p.slope * tempomath::log1p(p.slope * (d / 4.0) / p.bpm0);
                s.frame0 = p.frame0 + t * sr_;
                s.sec0 = p.sec0 + t;
            }
        }
    }
}

size_t TempoMap::segAtStep(double step) const noexcept {
    if (segs_.size() == 1 || step < segs_[1].step0) return 0;
    const auto it = std::upper_bound(segs_.begin(), segs_.end(), step, [](double v, const Seg& s) { return v < s.step0; });
    return static_cast<size_t>(it - segs_.begin()) - 1;
}

size_t TempoMap::segAtFrame(double frame) const noexcept {
    if (segs_.size() == 1 || frame < segs_[1].frame0) return 0;
    const auto it = std::upper_bound(segs_.begin(), segs_.end(), frame, [](double v, const Seg& s) { return v < s.frame0; });
    return static_cast<size_t>(it - segs_.begin()) - 1;
}

size_t TempoMap::segAtSecond(double sec) const noexcept {
    if (segs_.size() == 1 || sec < segs_[1].sec0) return 0;
    const auto it = std::upper_bound(segs_.begin(), segs_.end(), sec, [](double v, const Seg& s) { return v < s.sec0; });
    return static_cast<size_t>(it - segs_.begin()) - 1;
}

double TempoMap::frameAt(double step) const noexcept {
    const Seg& s = segs_[segAtStep(step)];
    const double d = step - s.step0;
    if (s.slope == 0.0 || d < 0.0) return s.frame0 + d * s.stepFrames;
    return s.frame0 + 60.0 / s.slope * tempomath::log1p(s.slope * (d / 4.0) / s.bpm0) * sr_;
}

double TempoMap::stepAt(double frame) const noexcept {
    const Seg& s = segs_[segAtFrame(frame)];
    const double d = frame - s.frame0;
    if (s.slope == 0.0 || d < 0.0) return s.step0 + d / s.stepFrames;
    return s.step0 + 4.0 * (s.bpm0 / s.slope * tempomath::expm1(s.slope * (d / sr_) / 60.0));
}

void TempoMap::stepsAt(int64_t frame, int n, double* out) const noexcept {
    if (n <= 0) return;
    size_t i = segAtFrame(static_cast<double>(frame));
    for (int k = 0; k < n; ++k) {
        const double f = static_cast<double>(frame + k);
        while (i + 1 < segs_.size() && f >= segs_[i + 1].frame0) ++i;  // the next segment from its first frame
        const Seg& s = segs_[i];
        const double d = f - s.frame0;
        out[k] = s.slope == 0.0 || d < 0.0 ? s.step0 + d / s.stepFrames
                                           : s.step0 + 4.0 * (s.bpm0 / s.slope * tempomath::expm1(s.slope * (d / sr_) / 60.0));
    }
}

double TempoMap::roundFrame(double step) const noexcept { return std::floor(frameAt(step) + 0.5); }

double TempoMap::bpmAtStep(double step) const noexcept {
    const Seg& s = segs_[segAtStep(step)];
    if (s.slope == 0.0 || step <= s.step0) return s.bpm0;
    return s.bpm0 + s.slope * ((step - s.step0) / 4.0);
}

double TempoMap::bpmAtFrame(double frame) const noexcept {
    const size_t i = segAtFrame(frame);
    if (segs_[i].slope == 0.0) return segs_[i].bpm0;
    return bpmAtStep(stepAt(frame));
}

double TempoMap::stepFramesAt(double step) const noexcept {
    const Seg& s = segs_[segAtStep(step)];
    if (s.slope == 0.0) return s.stepFrames;
    return sampletime::stepFrames(sr_, bpmAtStep(step));
}

double TempoMap::secondsAt(double beat) const noexcept {
    const Seg& s = segs_[segAtStep(beat * 4.0)];
    const double d = beat - s.step0 / 4.0;
    if (s.slope == 0.0 || d < 0.0) return s.sec0 + d * 60.0 / s.bpm0;
    return s.sec0 + 60.0 / s.slope * tempomath::log1p(s.slope * d / s.bpm0);
}

double TempoMap::beatAt(double seconds) const noexcept {
    const Seg& s = segs_[segAtSecond(seconds)];
    const double t = seconds - s.sec0;
    if (s.slope == 0.0 || t < 0.0) return s.step0 / 4.0 + t * s.bpm0 / 60.0;
    return s.step0 / 4.0 + s.bpm0 / s.slope * tempomath::expm1(s.slope * t / 60.0);
}

// ---------------------------------------------------------------------------------------------------------------
// TimeSigMap

void TimeSigMap::build(const std::vector<TimeSigSpec>& sigs) {
    sigs_ = sigs.empty() ? std::vector<TimeSigSpec>{{0, 0.0, 4, 4}} : sigs;
}

size_t TimeSigMap::indexAt(double beat) const noexcept {
    if (sigs_.size() == 1 || beat < sigs_[1].beat) return 0;
    const auto it = std::upper_bound(sigs_.begin(), sigs_.end(), beat,
                                     [](double v, const TimeSigSpec& s) { return v < s.beat; });
    return static_cast<size_t>(it - sigs_.begin()) - 1;
}

double TimeSigMap::nextTick(double beat, bool& accent) const noexcept {
    const size_t i = indexAt(beat);
    const TimeSigSpec& s = sigs_[i];
    const double unit = 4.0 / s.den;
    const double j = std::max(0.0, std::ceil((beat - s.beat) / unit));
    const double tick = s.beat + j * unit;
    if (i + 1 < sigs_.size() && tick >= sigs_[i + 1].beat) {
        accent = true;
        return sigs_[i + 1].beat;
    }
    accent = std::fmod(j, static_cast<double>(s.num)) == 0.0;
    return tick;
}

double TimeSigMap::tickAfter(double tick, bool& accent) const noexcept {
    const size_t i = indexAt(tick);
    const TimeSigSpec& s = sigs_[i];
    const double unit = 4.0 / s.den;
    const double j = std::floor((tick - s.beat) / unit + 0.5) + 1.0;
    const double next = s.beat + j * unit;
    if (i + 1 < sigs_.size() && next >= sigs_[i + 1].beat) {
        accent = true;
        return sigs_[i + 1].beat;
    }
    accent = std::fmod(j, static_cast<double>(s.num)) == 0.0;
    return next;
}

void TimeSigMap::barAt(double beat, int64_t& bar, double& inBar) const noexcept {
    const TimeSigSpec& s = sigs_[indexAt(beat)];
    const double len = s.num * 4.0 / s.den;
    const double k = std::floor((beat - s.beat) / len);
    bar = s.bar + static_cast<int64_t>(k);
    inBar = beat - s.beat - k * len;
}

}  // namespace caw
