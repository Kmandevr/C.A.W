// Strict IEEE reference for sample timing (CMakeLists builds this file with the strict floating-point flags).
#include "timing_oracle.h"

#include <cmath>

namespace cawtest {

double strictStepFrames(double sampleRate, double bpm) { return 60.0 * sampleRate / (bpm * 4.0); }

double strictRatchetStep(double at, double len, int ratchet, int sub) {
    const double part = len / ratchet;
    return at + part * sub;
}

double strictBeatFrame(double beat, double rate, double tempo) {
    return std::floor(beat * 60.0 * rate / tempo + 0.5);
}

int64_t strictRatchetStart(double sampleRate, double bpm, double at, double len, int ratchet, int sub) {
    const double part = len / ratchet;
    const double step = at + part * sub;
    return static_cast<int64_t>(std::floor(step * strictStepFrames(sampleRate, bpm) + 0.5));
}

double strictTempoFrame(const std::vector<OraclePoint>& in, double rate, double step) {
    std::vector<OraclePoint> pts;
    for (size_t i = 0; i < in.size(); ++i) {
        const bool rampFromHere = i + 1 < in.size() && in[i + 1].ramp && in[i + 1].bpm != in[i].bpm;
        if (!pts.empty() && pts.back().bpm == in[i].bpm && !rampFromHere) continue;
        pts.push_back(in[i]);
        if (i == 0) pts.back().ramp = false;
    }
    double frame = 0;
    for (size_t i = 0; i < pts.size(); ++i) {
        const double s0 = pts[i].beat * 4.0;
        const bool last = i + 1 == pts.size();
        const double s1 = last ? step : pts[i + 1].beat * 4.0;
        const bool ramp = !last && pts[i + 1].ramp && pts[i + 1].bpm != pts[i].bpm;
        const double upto = last || step < s1 ? step : s1;
        const double d = upto - s0;
        if (!ramp) {
            frame = frame + d * strictStepFrames(rate, pts[i].bpm);
        } else {
            const double k = (pts[i + 1].bpm - pts[i].bpm) / (pts[i + 1].beat - pts[i].beat);
            frame = frame + 60.0 / k * std::log1p(k * (d / 4.0) / pts[i].bpm) * rate;
        }
        if (last || step < s1) break;
    }
    return frame;
}

}  // namespace cawtest
