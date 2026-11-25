// Chirp's clip editor engine: the offline analysis (YIN candidates, an HMM, note segmentation, drift and vibrato) and the non-destructive per-note TD-PSOLA render.
#include "lark_editor.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "caw/detmath.hpp"
#include "lark_dsp.h"

// Original code (C.A.W. is Apache-2.0); the methods are in lark_dsp.h. Monophonic and time-domain throughout.
// Analysis:
// - The mid, low-passed and decimated to about 12 kHz as the live detector does; per hop (64 decimated samples)
//   d' over a window centred on the hop (21 ms); its dips are candidates, each weighted by the share of a prior
//   over thresholds (a beta(2, 18) on 0.01..1, pYIN's idea) that would pick it first; the four likeliest and an
//   unvoiced state go to a Viterbi pass (staying voiced 0.99, a pitch move costing in a straight line to nothing at
//   3 semitones a hop, plus a small floor so a leap is possible). The chosen lag is refined at full rate.
// - Notes: a voiced run, cut where the pitch leaves the note's running mean by more than 70 cents for 40 ms, or
//   at an onset (6 dB up within 3 hops) once the note is 40 ms long; notes under 30 ms join their neighbour. Each
//   note's centre is the energy-weighted median; the residual's part below about 2 Hz is its drift (two zero-phase
//   one-poles at 2.5 Hz, each forward and back) and the rest its vibrato (and jitter), stored per hop.
// Render: per hop of the source, each note's edits (ramped over its transition at changes) give the shift
// offset + (drift - 1) * low + (vibrato - 1) * vib; a time map moves and stretches notes with their onsets and
// releases (up to 20 ms; the gaps between give way); TD-PSOLA runs from the original over the edited regions only (grains at analysis marks one period apart,
// laid one target period apart; repeated or skipped where time stretches), and the rest is the input, bit for bit,
// crossfaded over 10 ms.

namespace caw::lark {

namespace {

constexpr int kCandidates = 8, kKeep = 4;

float clean(float x) noexcept { return x == x && x - x == 0.0f ? x : 0.0f; }

std::vector<float> midOf(const float* l, const float* r, int64_t frames) {
    std::vector<float> m(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; ++i) m[i] = r ? 0.5f * (clean(l[i]) + clean(r[i])) : clean(l[i]);
    return m;
}

// The beta(2, 18) prior over thresholds 0.01..1 (a grid of 100), normalised.
const double* thresholdPrior() {
    static const auto t = [] {
        struct P {
            double w[100];
        } p{};
        double sum = 0;
        for (int i = 0; i < 100; ++i) {
            const double s = 0.01 * (i + 1);
            p.w[i] = s * detPow(1.0 - s, 17.0);
            sum += p.w[i];
        }
        for (double& w : p.w) w /= sum;
        return p;
    }();
    return t.w;
}

struct Cand {
    double tau = 0, dn = 1, prob = 0, midi = 0;
};

// A zero-phase one-pole low-pass of x[0..n) at `hz` (hop rate `rate`), forward then back.
void zeroPhase(const double* x, double* y, size_t n, double hz, double rate) {
    if (!n) return;
    const double a = 1.0 - detExp(-2.0 * kPi * hz / rate);
    double s = x[0];
    for (size_t i = 0; i < n; ++i) y[i] = s += a * (x[i] - s);
    s = y[n - 1];
    for (size_t i = n; i-- > 0;) y[i] = s += a * (y[i] - s);
}

}  // namespace

uint64_t audioChecksum(const float* left, const float* right, int64_t frames) noexcept {
    uint64_t h = 1469598103934665603ull;  // FNV-1a over the samples' bits
    auto mix = [&](const float* p) {
        for (int64_t i = 0; i < frames; ++i) {
            uint32_t b;
            std::memcpy(&b, p + i, 4);
            h = (h ^ b) * 1099511628211ull;
        }
    };
    if (left) mix(left);
    if (right) mix(right);
    return h ^ static_cast<uint64_t>(frames);
}

bool analyse(const float* left, const float* right, int64_t frames, double sr, const AnalyseOptions& o, Analysis& out,
             std::string& error) {
    if (!left || frames < 1) return error = "no audio", false;
    if (!(sr >= kMinRate && sr <= kMaxRate)) return error = "sample_rate must be 8000..192000", false;
    if (static_cast<double>(frames) > kMaxSeconds * sr) return error = "the clip is longer than 1800 seconds", false;
    if (!(o.lowHz >= 50.0 && o.lowHz <= 400.0)) return error = "low_hz must be 50..400", false;
    if (!(o.highHz >= 200.0 && o.highHz <= 2000.0 && o.highHz > o.lowHz * 1.5))
        return error = "high_hz must be 200..2000 and above 1.5 x low_hz", false;
    Analysis a;
    a.sampleRate = sr;
    a.frames = frames;
    a.checksum = audioChecksum(left, right, frames);
    const std::vector<float> x = midOf(left, right, frames);
    const uint32_t d = decimationFor(sr);
    const double fsd = sr / d;
    a.hopFrames = kHop * d;
    const double hopSec = a.hopFrames / sr;
    // The decimated copy.
    std::vector<float> xd(static_cast<size_t>(frames / d) + 1, 0.0f);
    {
        Biquad b1, b2;
        b1.lowpass(3000.0, sr, 0.5411961), b2.lowpass(3000.0, sr, 1.3065630);
        size_t k = 0;
        for (int64_t i = 0; i < frames; ++i) {
            const double y = b2.run(b1.run(x[i]));
            if (i % d == 0) xd[k++] = static_cast<float>(y);
        }
        xd.resize(k);
    }
    const uint32_t window = std::min<uint32_t>(kMaxWindow, static_cast<uint32_t>(0.0213 * fsd)) & ~3u;
    const uint32_t maxLag = std::min<uint32_t>(kMaxLag, static_cast<uint32_t>(std::ceil(fsd / o.lowHz)));
    const uint32_t minLag = std::max<uint32_t>(2, static_cast<uint32_t>(std::floor(fsd / o.highHz)));
    const size_t hops = static_cast<size_t>((frames + a.hopFrames - 1) / a.hopFrames);
    a.midi.assign(hops, 0.0f), a.voicing.assign(hops, 0.0f), a.rmsDb.assign(hops, -120.0f);
    a.low.assign(hops, 0.0f), a.vib.assign(hops, 0.0f), a.noteOf.assign(hops, -1);
    std::vector<Cand> cands(hops * kKeep);
    std::vector<uint8_t> count(hops, 0);
    std::vector<float> seg(window + maxLag + 4), dn(maxLag + 4);
    const double* prior = thresholdPrior();
    for (size_t h = 0; h < hops; ++h) {
        const int64_t centre = static_cast<int64_t>(h) * kHop;
        const int64_t start = centre - static_cast<int64_t>(window + maxLag) / 2;
        double energy = 0;
        for (uint32_t i = 0; i < window + maxLag + 2; ++i) {
            const int64_t j = start + i;
            seg[i] = j >= 0 && j < static_cast<int64_t>(xd.size()) ? xd[j] : 0.0f;
        }
        for (uint32_t i = maxLag / 2; i < maxLag / 2 + window; ++i) energy += static_cast<double>(seg[i]) * seg[i];
        a.rmsDb[h] = static_cast<float>(10.0 * detLog(std::max(energy / window, 1e-12)) / 2.302585092994046);
        if (!(energy / window > 1e-7)) continue;
        cmnd(seg.data(), window, minLag, maxLag + 1, dn.data(), 0.0);
        Cand all[kCandidates];
        int n = 0;
        for (uint32_t t = std::max<uint32_t>(minLag, 2); t <= maxLag && n < kCandidates; ++t)
            if (dn[t] < dn[t - 1] && dn[t] <= dn[t + 1] && dn[t] < 1.0f) all[n].tau = parabolic(dn.data(), t, maxLag + 1), all[n++].dn = dn[t];
        if (!n) continue;
        // Each threshold picks the first candidate under it; none under it: the deepest, at a hundredth.
        int deepest = 0;
        for (int c = 1; c < n; ++c)
            if (all[c].dn < all[deepest].dn) deepest = c;
        for (int i = 0; i < 100; ++i) {
            const double s = 0.01 * (i + 1);
            int pick = -1;
            for (int c = 0; c < n && pick < 0; ++c)
                if (all[c].dn < s) pick = c;
            if (pick >= 0) all[pick].prob += prior[i];
            else all[deepest].prob += 0.01 * prior[i];
        }
        std::stable_sort(all, all + n, [](const Cand& p, const Cand& q) { return p.prob > q.prob; });
        int kept = 0;
        double sum = 0;
        for (int c = 0; c < n && kept < kKeep; ++c) {
            if (all[c].prob <= 0) break;
            const double hz = fsd / all[c].tau;
            if (!(hz >= o.lowHz * 0.97 && hz <= o.highHz * 1.03)) continue;
            all[c].midi = hzToMidi(hz);
            cands[h * kKeep + kept++] = all[c];
            sum += all[c].prob;
        }
        count[h] = static_cast<uint8_t>(kept);
        a.voicing[h] = static_cast<float>(std::min(1.0, sum));
    }
    // Viterbi over the candidates and an unvoiced state (index kKeep).
    std::vector<uint8_t> back(hops * (kKeep + 1), 0);
    double prev[kKeep + 1], cur[kKeep + 1];
    const double stay = detLog(0.99), change = detLog(0.01);
    auto emit = [&](size_t h, int s) {
        if (s == kKeep) return detLog(std::max(1.0 - a.voicing[h], 1e-9));
        return detLog(cands[h * kKeep + s].prob + 1e-9);
    };
    for (int s = 0; s <= kKeep; ++s) prev[s] = (s == kKeep || s < count[0]) ? emit(0, s) : -1e300;
    for (size_t h = 1; h < hops; ++h) {
        for (int s = 0; s <= kKeep; ++s) {
            cur[s] = -1e300;
            if (s != kKeep && s >= count[h]) continue;
            double best = -1e300;
            uint8_t arg = kKeep;
            for (int p = 0; p <= kKeep; ++p) {
                if (prev[p] <= -1e299) continue;
                double t;
                if (s == kKeep) t = p == kKeep ? stay : change;
                else if (p == kKeep) t = change;
                else {
                    const double jump = std::fabs(cands[h * kKeep + s].midi - cands[(h - 1) * kKeep + p].midi);
                    t = stay + detLog(std::max(0.0, 1.0 - jump / 3.0) + 1e-3);
                }
                if (prev[p] + t > best) best = prev[p] + t, arg = static_cast<uint8_t>(p);
            }
            cur[s] = best + emit(h, s);
            back[h * (kKeep + 1) + s] = arg;
        }
        std::copy(cur, cur + kKeep + 1, prev);
    }
    {
        int s = kKeep;
        for (int k = 0; k <= kKeep; ++k)
            if (prev[k] > prev[s]) s = k;
        std::vector<float> scratch(1536 + static_cast<size_t>(sr / 50.0) + 16);
        for (size_t h = hops; h-- > 0;) {
            if (s != kKeep) {
                // The lag refined at full rate on a span centred on the hop.
                const double lag0 = cands[h * kKeep + s].tau * d;
                const uint32_t span = refineWindow(lag0) + static_cast<uint32_t>(lag0) + 8;
                const int64_t from = static_cast<int64_t>(h) * a.hopFrames - span / 2;
                const double lag = refineLag(
                    [&](uint32_t j) {
                        const int64_t i = from + j;
                        return i >= 0 && i < frames ? x[i] : 0.0f;
                    },
                    span, lag0, scratch.data());
                a.midi[h] = static_cast<float>(hzToMidi(sr / lag));
            }
            if (h) s = back[h * (kKeep + 1) + s];
        }
    }
    // Notes.
    const uint32_t cutHops = std::max<uint32_t>(2, static_cast<uint32_t>(0.040 / hopSec + 0.5));
    const uint32_t minHops = std::max<uint32_t>(2, static_cast<uint32_t>(0.030 / hopSec + 0.5));
    std::vector<std::pair<uint32_t, uint32_t>> spans;  // [first, end) hops
    for (size_t h = 0; h < hops;) {
        if (a.midi[h] <= 0) {
            ++h;
            continue;
        }
        size_t end = h;
        while (end < hops && a.midi[end] > 0) ++end;
        std::vector<std::pair<uint32_t, uint32_t>> run;
        size_t ns = h;
        double sum = 0;
        uint32_t off = 0;
        for (size_t k = h; k < end; ++k) {
            const double m = a.midi[k];
            const size_t len = k - ns;
            bool cut = false;
            size_t at = k;
            if (len > 0 && std::fabs(m - sum / len) > 0.7) {
                if (++off >= cutHops) cut = true, at = k + 1 - off;
            } else {
                off = 0;
            }
            if (!cut && len >= cutHops && k >= 3) {
                const float lo = std::min({a.rmsDb[k - 1], a.rmsDb[k - 2], a.rmsDb[k - 3]});
                if (a.rmsDb[k] - lo > 6.0f) cut = true, at = k;
            }
            if (cut && at > ns) {
                run.emplace_back(static_cast<uint32_t>(ns), static_cast<uint32_t>(at));
                ns = at;
                sum = 0;
                for (size_t j = ns; j <= k; ++j) sum += a.midi[j];
                off = 0;
                continue;
            }
            sum += m;
        }
        run.emplace_back(static_cast<uint32_t>(ns), static_cast<uint32_t>(end));
        // Short notes join a neighbour in the run; a run shorter than that is no note.
        std::vector<std::pair<uint32_t, uint32_t>> merged;
        for (auto r : run) {
            if (r.second - r.first < minHops && !merged.empty()) merged.back().second = r.second;
            else merged.push_back(r);
        }
        if (merged.size() > 1 && merged[0].second - merged[0].first < minHops) {
            merged[1].first = merged[0].first;
            merged.erase(merged.begin());
        }
        for (auto r : merged)
            if (r.second - r.first >= minHops) spans.push_back(r);
        h = end;
    }
    if (spans.size() > kMaxNotes) return error = "more than 100000 notes", false;
    std::vector<double> res, lo, lp9;
    std::vector<std::pair<double, double>> sorted;
    for (const auto& [h0, h1] : spans) {
        Note n;
        n.firstHop = h0, n.endHop = h1;
        n.start = std::max<int64_t>(0, static_cast<int64_t>(h0) * a.hopFrames - a.hopFrames / 2);
        n.end = std::min<int64_t>(frames, static_cast<int64_t>(h1) * a.hopFrames - a.hopFrames / 2);
        if (n.end <= n.start) n.end = std::min<int64_t>(frames, n.start + 1);
        const size_t len = h1 - h0;
        sorted.clear();
        double total = 0, energy = 0;
        for (uint32_t k = h0; k < h1; ++k) {
            const double w = detPow(10.0, a.rmsDb[k] / 10.0);
            sorted.emplace_back(a.midi[k], w);
            total += w;
        }
        energy = total / len;
        std::stable_sort(sorted.begin(), sorted.end());
        double acc = 0;
        n.pitch = sorted.back().first;
        for (const auto& [m, w] : sorted)
            if ((acc += w) >= 0.5 * total) {
                n.pitch = m;
                break;
            }
        res.assign(len, 0.0), lo.assign(len, 0.0), lp9.assign(len, 0.0);
        for (size_t k = 0; k < len; ++k) res[k] = a.midi[h0 + k] - n.pitch;
        zeroPhase(res.data(), lp9.data(), len, 2.5, 1.0 / hopSec);  // twice forward and back: the drift
        zeroPhase(lp9.data(), lo.data(), len, 2.5, 1.0 / hopSec);
        double l2 = 0, v2 = 0;
        int crossings = 0;
        double last = 0;
        for (size_t k = 0; k < len; ++k) {
            const double v = res[k] - lo[k];
            a.low[h0 + k] = static_cast<float>(lo[k]);
            a.vib[h0 + k] = static_cast<float>(v);
            a.noteOf[h0 + k] = static_cast<int32_t>(a.notes.size());
            l2 += lo[k] * lo[k], v2 += v * v;
            if (std::fabs(v) > 0.03) {  // a sign change past 3 cents counts
                if (last != 0 && (v > 0) != (last > 0)) ++crossings;
                last = v;
            }
        }
        n.driftCents = 100.0 * std::sqrt(l2 / len);
        n.vibratoCents = 100.0 * std::sqrt(2.0 * v2 / len);
        const double seconds = len * hopSec;
        const double rate = crossings / (2.0 * seconds);
        n.vibratoRate = n.vibratoCents >= 8.0 && rate >= 2.5 && rate <= 10.0 ? rate : 0.0;
        if (n.vibratoRate == 0.0) n.vibratoCents = n.vibratoCents >= 8.0 ? n.vibratoCents : 0.0;
        size_t in = 0, outHops = 0;
        while (in < len / 2 && std::fabs(res[in]) > 0.5) ++in;
        while (outHops < len / 2 && std::fabs(res[len - 1 - outHops]) > 0.5) ++outHops;
        n.transitionInMs = 1000.0 * in * hopSec;
        n.transitionOutMs = 1000.0 * outHops * hopSec;
        n.gainDb = 10.0 * detLog(std::max(energy, 1e-12)) / 2.302585092994046;
        a.notes.push_back(n);
    }
    out = std::move(a);
    return true;
}

// --- Render ----------------------------------------------------------------------------------------------------------

namespace {

struct Controls {  // per source hop, after the ramps
    std::vector<float> off, drift, vib, formant, keep, gain;
};

// A piecewise-linear time map from output frames to source frames (anchors strictly rising in output).
class TimeMap {
public:
    std::vector<double> src, dst;
    double source(double t, size_t& seg) const noexcept {
        while (seg + 2 < dst.size() && t >= dst[seg + 1]) ++seg;
        const double span = dst[seg + 1] - dst[seg];
        return src[seg] + (t - dst[seg]) * (src[seg + 1] - src[seg]) / span;
    }
};

}  // namespace

bool render(const Analysis& a, const float* left, const float* right, int64_t frames, const std::vector<NoteEdit>& edits,
            float* outL, float* outR, std::string& error) {
    if (!left || !outL || (right && !outR)) return error = "no audio", false;
    if (frames != a.frames) return error = "the audio's length is not the analysed clip's", false;
    if (audioChecksum(left, right, frames) != a.checksum) return error = "the audio is not the analysed clip", false;
    if (edits.size() != a.notes.size()) return error = "one edit per note", false;
    const double sr = a.sampleRate;
    const size_t hops = a.midi.size();
    const double hop = a.hopFrames;
    for (int64_t i = 0; i < frames; ++i) outL[i] = clean(left[i]);
    if (right)
        for (int64_t i = 0; i < frames; ++i) outR[i] = clean(right[i]);
    bool any = false;
    for (const NoteEdit& e : edits) any = any || !e.identity();
    if (!any) return true;
    warmTables();  // the grains' window (built once; registration builds it too)

    // The controls per source hop: each note's values over its hops, ramped at changes.
    Controls c;
    c.off.assign(hops, 0), c.drift.assign(hops, 0), c.vib.assign(hops, 0), c.formant.assign(hops, 0);
    c.keep.assign(hops, 1), c.gain.assign(hops, 0);
    std::vector<float> trans(hops, 0.0f);
    for (size_t k = 0; k < a.notes.size(); ++k) {
        const Note& n = a.notes[k];
        const NoteEdit& e = edits[k];
        for (uint32_t h = n.firstHop; h < n.endHop && h < hops; ++h) {
            c.off[h] = static_cast<float>(e.pitch);
            c.drift[h] = static_cast<float>(e.drift - 1.0);
            c.vib[h] = static_cast<float>(e.vibrato - 1.0);
            c.formant[h] = static_cast<float>(e.formant);
            c.keep[h] = e.formantKeep ? 1.0f : 0.0f;
            c.gain[h] = static_cast<float>(e.gainDb);
            trans[h] = static_cast<float>(e.transitionMs);
        }
    }
    {
        std::vector<float>* arrays[] = {&c.off, &c.drift, &c.vib, &c.formant, &c.keep, &c.gain};
        std::vector<size_t> changes;
        for (size_t h = 1; h < hops; ++h)
            for (auto* v : arrays)
                if ((*v)[h] != (*v)[h - 1]) {
                    changes.push_back(h);
                    break;
                }
        Controls raw = c;
        std::vector<float>* rawArrays[] = {&raw.off, &raw.drift, &raw.vib, &raw.formant, &raw.keep, &raw.gain};
        for (size_t i = 0; i < changes.size(); ++i) {
            const size_t b = changes[i];
            const double ms = std::max(trans[b - 1], trans[b]);
            size_t half = static_cast<size_t>(0.5 * ms * 0.001 * sr / hop + 0.5);
            const size_t before = i ? b - changes[i - 1] : b, after = (i + 1 < changes.size() ? changes[i + 1] : hops) - b;
            half = std::min({half, before / 2, after / 2});
            if (!half) continue;
            for (size_t j = b - half; j < b + half; ++j) {
                const double t = (static_cast<double>(j - (b - half)) + 0.5) / (2.0 * half);
                for (size_t q = 0; q < 6; ++q) {
                    const float x0 = (*rawArrays[q])[b - 1], x1 = (*rawArrays[q])[b];
                    (*arrays[q])[j] = static_cast<float>(x0 + (x1 - x0) * t);
                }
            }
        }
    }
    // The time map: each note moved and stretched; the gaps give way.
    TimeMap map;
    map.src.push_back(0), map.dst.push_back(0);
    // Each note with up to 20 ms either side (its onset and release, which the detector calls unvoiced), at most
    // half the gap to its neighbour, moves as one piece.
    const double pad = 0.020 * sr;
    for (size_t k = 0; k < a.notes.size(); ++k) {
        const Note& n = a.notes[k];
        const NoteEdit& e = edits[k];
        const double prevEnd = k ? static_cast<double>(a.notes[k - 1].end) : 0.0;
        const double nextStart = k + 1 < a.notes.size() ? static_cast<double>(a.notes[k + 1].start) : static_cast<double>(frames);
        const double from = std::max(n.start - pad, 0.5 * (prevEnd + n.start));
        const double to = std::min(n.end + pad, 0.5 * (n.end + nextStart));
        const double s = from + e.timeFrames;
        map.src.push_back(from), map.dst.push_back(s);
        map.src.push_back(to), map.dst.push_back(s + (to - from) * e.stretch);
    }
    map.src.push_back(static_cast<double>(frames)), map.dst.push_back(static_cast<double>(frames));
    const size_t anchors = map.dst.size();
    for (size_t i = 1; i + 1 < anchors; ++i) map.dst[i] = std::max(map.dst[i], map.dst[i - 1] + 1.0);
    for (size_t i = anchors - 1; i-- > 1;) map.dst[i] = std::min(map.dst[i], map.dst[i + 1] - 1.0);
    for (size_t i = 1; i < anchors; ++i)
        if (!(map.dst[i] > map.dst[i - 1])) return error = "the notes' moves do not fit in the clip", false;

    // Which output hops change: a moved time or a control off its identity; ramps of two hops either side.
    const size_t outHops = static_cast<size_t>((frames + a.hopFrames - 1) / a.hopFrames) + 1;
    std::vector<uint8_t> active(outHops, 0);
    {
        size_t seg = 0;
        for (size_t h = 0; h < outHops; ++h) {
            const double t = std::min(static_cast<double>(h) * hop, static_cast<double>(frames - 1));
            const double s = map.source(t, seg);
            const size_t sh = std::min(hops - 1, static_cast<size_t>(std::max(0.0, s / hop + 0.5)));
            active[h] = std::fabs(s - t) > 0.25 || c.off[sh] != 0 || c.drift[sh] != 0 || c.vib[sh] != 0 ||
                        c.formant[sh] != 0 || c.keep[sh] != 1 || c.gain[sh] != 0;
        }
    }
    std::vector<uint8_t> wide(active);
    for (size_t h = 0; h < outHops; ++h)
        if (active[h])
            for (size_t j = h >= 2 ? h - 2 : 0; j <= std::min(outHops - 1, h + 2); ++j) wide[j] = 1;
    const double fade = std::max(1.0, std::floor(0.010 * sr));
    // Each active region's first and last hop, for the ramps at its ends.
    std::vector<int64_t> regionLo(outHops, 0), regionHi(outHops, 0);
    for (size_t h = 0; h < outHops;) {
        if (!wide[h]) {
            ++h;
            continue;
        }
        size_t e = h;
        while (e + 1 < outHops && wide[e + 1]) ++e;
        for (size_t j = h; j <= e; ++j) regionLo[j] = static_cast<int64_t>(h), regionHi[j] = static_cast<int64_t>(e);
        h = e + 1;
    }
    const int64_t hopI = a.hopFrames;
    auto weight = [&](int64_t i) -> double {  // 0 where the input stays, 1 where the render plays
        const size_t h = static_cast<size_t>(i / hopI);
        if (h >= outHops || !wide[h]) return 0.0;
        const int64_t lo = regionLo[h], hi = regionHi[h];
        const double fromStart = lo == 0 ? 1e30 : static_cast<double>(i - lo * hopI);
        const double toEnd = hi + 1 >= static_cast<int64_t>(outHops) ? 1e30 : static_cast<double>((hi + 1) * hopI - i);
        return std::clamp(std::min(fromStart, toEnd) / fade, 0.0, 1.0);
    };

    // Source helpers.
    auto hopOf = [&](double s) { return std::min(hops - 1, static_cast<size_t>(std::max(0.0, s / hop + 0.5))); };
    auto voicedAt = [&](double s) { return s >= 0 && s < frames && a.noteOf[hopOf(s)] >= 0; };
    auto periodAt = [&](double s) {
        const double p = std::clamp(s / hop, 0.0, static_cast<double>(hops - 1));
        const size_t i = static_cast<size_t>(p);
        const size_t j = std::min(hops - 1, i + 1);
        double m0 = a.midi[i], m1 = a.midi[j];
        if (m0 <= 0) m0 = m1;
        if (m1 <= 0) m1 = m0;
        if (m0 <= 0) return 0.0;
        return sr / midiToHz(m0 + (m1 - m0) * (p - i));
    };
    auto lerp = [&](const std::vector<float>& v, double s) {
        const double p = std::clamp(s / hop, 0.0, static_cast<double>(hops - 1));
        const size_t i = static_cast<size_t>(p);
        const size_t j = std::min(hops - 1, i + 1);
        return v[i] + (v[j] - v[i]) * (p - i);
    };
    // The next analysis mark after m: one period on while voiced, else the next voiced hop's start.
    // A voiced run's first mark sits on the waveform's peak (the mid's largest sample) in its first half period,
    // so the grains are centred on the pulses and add in phase; the next ones follow one period apart.
    const std::vector<float> mid = midOf(left, right, frames);
    auto epoch = [&](double from, double to) {
        int64_t i0 = std::max<int64_t>(0, static_cast<int64_t>(std::ceil(from)));
        const int64_t i1 = std::min<int64_t>(frames - 1, static_cast<int64_t>(std::floor(to)));
        int64_t best = i0;
        for (int64_t i = i0; i <= i1; ++i)
            if (mid[i] > mid[best]) best = i;
        return static_cast<double>(best);
    };
    auto nextMark = [&](double m) {
        const double p = periodAt(m);
        if (p > 0 && voicedAt(m + p)) return m + p;
        size_t h = m < 0 ? 0 : hopOf(m) + 1;
        while (h < hops && a.noteOf[h] < 0) ++h;
        if (h >= hops) return 1e300;
        const double start = std::max(m + 1.0, static_cast<double>(h) * hop - hop / 2);
        const double q = periodAt(start);
        return q > 0 ? epoch(start, start + 0.5 * q) : start;
    };

    // The render: grains into scratch buffers, then crossfaded with the input.
    std::vector<float> wetL(static_cast<size_t>(frames), 0.0f), wetR, wsum(static_cast<size_t>(frames), 0.0f);
    if (right) wetR.assign(static_cast<size_t>(frames), 0.0f);
    const double unvoicedHop = sr > 70000.0 ? 512.0 : 256.0;
    double cur = nextMark(-1.0), nxt = cur < 1e299 ? nextMark(cur) : 1e300;
    size_t seg = 0;
    bool wasVoiced = false;
    double s = 0.0;
    auto read = [&](const float* x, double pos) -> double {
        const double fl = std::floor(pos);
        const int64_t i = static_cast<int64_t>(fl);
        if (i < 0 || i + 1 >= frames) return i == frames - 1 && i >= 0 ? clean(x[i]) : 0.0;
        const double f = pos - fl;
        const double x0 = clean(x[i]), x1 = clean(x[i + 1]);
        return x0 + f * (x1 - x0);
    };
    const uint64_t guard = static_cast<uint64_t>(frames) * 4 + 1024;  // spacing is at least a quarter frame... bounded
    uint64_t steps = 0;
    while (s < static_cast<double>(frames) && ++steps < guard) {
        double sigma = map.source(std::min(s, static_cast<double>(frames)), seg);
        const bool voiced = voicedAt(sigma);
        double ac, h, fs, g, next;
        if (voiced) {
            while (nxt <= sigma) cur = nxt, nxt = nextMark(cur);
            ac = (cur > sigma || nxt >= 1e299 || sigma - cur <= nxt - sigma) ? cur : nxt;
            if (!wasVoiced) {  // a voiced run starts: the synthesis lands on its mark, so in place it is the input
                s += ac - sigma;
                sigma = ac;
            }
            const double pa = std::max(2.0, periodAt(ac));
            const double shift = std::clamp(lerp(c.off, ac) + lerp(c.drift, ac) * lerp(a.low, ac) + lerp(c.vib, ac) * lerp(a.vib, ac), -24.0, 24.0);
            const double r = detPow(2.0, shift / 12.0);
            const double keep = lerp(c.keep, ac);
            fs = std::clamp(detPow(2.0, ((1.0 - keep) * shift + lerp(c.formant, ac)) / 12.0), 0.5, 2.0);
            const double ps = pa / r;
            h = pa / fs;
            g = ps / h;
            next = s + ps;
            wasVoiced = true;
        } else {
            if (wasVoiced) s = std::ceil(s), sigma = map.source(s, seg);
            wasVoiced = false;
            ac = sigma;
            h = unvoicedHop;
            fs = 1.0;
            g = 1.0;
            next = s + unvoicedHop;
        }
        const double gain = detPow(10.0, lerp(c.gain, ac) / 20.0);
        const int64_t n0 = std::max<int64_t>(0, static_cast<int64_t>(std::ceil(s - h)));
        const int64_t n1 = std::min<int64_t>(frames - 1, static_cast<int64_t>(std::floor(s + h)));
        const size_t h0 = static_cast<size_t>(std::max<int64_t>(0, n0) / a.hopFrames), h1 = static_cast<size_t>(std::max<int64_t>(0, n1) / a.hopFrames);
        bool touches = false;
        for (size_t q = h0; q <= h1 && q < outHops && !touches; ++q) touches = wide[q] != 0;
        if (touches) {
            const double inv = 1.0 / h;
            for (int64_t n = n0; n <= n1; ++n) {
                const double off = static_cast<double>(n) - s;
                const double w = hann(off * inv) * g;
                if (w == 0.0) continue;
                const double pos = ac + off * fs;
                wsum[n] += static_cast<float>(w);
                wetL[n] += static_cast<float>(w * gain * read(left, pos));
                if (right) wetR[n] += static_cast<float>(w * gain * read(right, pos));
            }
        }
        s = next;
    }
    for (int64_t i = 0; i < frames; ++i) {
        const double w = weight(i);
        if (w <= 0.0) continue;
        // The grains' windows summed to 1 (they do in a steady run; this evens the joins where runs start and end).
        const double norm = 1.0 / std::max(0.25, static_cast<double>(wsum[i]));
        outL[i] = static_cast<float>((1.0 - w) * outL[i] + w * norm * wetL[i]);
        if (right) outR[i] = static_cast<float>((1.0 - w) * outR[i] + w * norm * wetR[i]);
    }
    return true;
}

}  // namespace caw::lark
