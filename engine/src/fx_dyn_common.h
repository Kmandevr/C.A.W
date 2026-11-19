// What 1.1.0's dynamics variants share (Talon's Up and Bus, Hatch's Expand and Pedal gate, Duck's Level): the key filter, the detectors and the warm character.
#pragma once

#include <cmath>
#include <cstdint>
#include <string_view>

#include "builtin_effects.h"
#include "caw/library/dynamics.hpp"
#include "caw/library/filter.hpp"
#include "stereo_pair.h"

// Original code (C.A.W. is Apache-2.0). Each variant templates its run loop on the detection mode, so no sample
// branches on a parameter; the key filter's two flags are read once per run.

namespace caw::fx::dyn {

constexpr std::string_view kDetections[] = {"Peak", "RMS", "ISP"};
constexpr std::string_view kSources[] = {"Internal", "External"};
constexpr std::string_view kCharacters[] = {"Clean", "Warm"};
enum Detection : int { kPeak = 0, kRms = 1, kIsp = 2 };

// The talon_layout marker (fx_migrate.h): a hidden structural parameter every 1.1.0 Talon entry carries, so an
// org.caw.compressor entry without it is from 1.0.8 or 1.0.9 and its variant is moved (Gate, Shape, Duck left it).
inline constexpr std::string_view kTalonLayoutParam = "talon_layout";
inline constexpr double kTalonLayoutCurrent = 1.0;

// The marker as a parameter: default 1, not automatable, modulatable or MIDI-mappable, never smoothed.
inline ParameterDescriptor talonLayoutParameter() noexcept {
    ParameterDescriptor p;
    p.id = kTalonLayoutParam;
    p.name = "Talon layout";
    p.defaultValue = kTalonLayoutCurrent;
    p.minimum = 0.0;
    p.maximum = kTalonLayoutCurrent;
    p.step = 1.0;
    p.smoothingFrames = 0;
    p.automatable = false;
    p.modulatable = false;
    p.midiMappable = false;
    return p;
}

// The key filter: a high-pass and a low-pass (12 dB/octave TPT SVFs) per side, each skipped at its end stop.
struct KeyFilter {
    lib::Svf hp[2], lp[2];
    bool useHp = false, useLp = false;
    void set(double hpHz, double lpHz, double sr) noexcept {
        useHp = hpHz > 20.5;
        useLp = lpHz < 19500.0 && lpHz < 0.49 * sr;
        if (useHp) for (auto& f : hp) f.set(hpHz, 0.70710678118654752, sr);
        if (useLp) for (auto& f : lp) f.set(lpHz, 0.70710678118654752, sr);
    }
    void clear() noexcept {
        for (auto& f : hp) f.clear();
        for (auto& f : lp) f.clear();
    }
    // n frames of side c in place.
    void run(int c, double* x, uint32_t n) noexcept {
        if (useHp) for (uint32_t i = 0; i < n; ++i) x[i] = hp[c].highpass(x[i]);
        if (useLp) for (uint32_t i = 0; i < n; ++i) x[i] = lp[c].lowpass(x[i]);
    }
};

// A side's detector: |x| (Peak), a 10 ms mean square's root (RMS) or the 4x inter-sample peak (ISP, lib::TruePeak:
// four frames late, which the look-ahead covers where there is one). Levels are linear.
struct Detector {
    double ms[2] = {}, rmsCoef = 0.0;
    lib::TruePeak tp[2];
    void prepare(double sr) noexcept { rmsCoef = lib::timeCoefficient(0.01, sr); }
    void clear() noexcept {
        ms[0] = ms[1] = 0.0;
        tp[0].clear();
        tp[1].clear();
    }
    template <int Det>
    void run(int c, const double* x, double* level, uint32_t n) noexcept {
        if constexpr (Det == kRms) {
            double m = ms[c];
            for (uint32_t i = 0; i < n; ++i) {
                const double sq = x[i] * x[i];
                m = sq + (m - sq) * rmsCoef;
                if (m < 1e-30) m = 0.0;
                level[i] = std::sqrt(m);
            }
            ms[c] = m;
        } else if constexpr (Det == kIsp) {
            for (uint32_t i = 0; i < n; ++i) level[i] = tp[c].process(x[i]);
        } else {
            for (uint32_t i = 0; i < n; ++i) level[i] = x[i] < 0.0 ? -x[i] : x[i];
        }
    }
};

// Levels to dB (lib::gainToDb with a -200 floor), two at a time where both are normal and at least `quiet`
// (fastLogNormalPair: the same bits); a level under `quiet` gives -200 with no log.
inline void toDb(const double* lv, double* db, uint32_t n, double quiet) noexcept {
    const auto one = [quiet](double x) noexcept { return x < quiet ? -200.0 : lib::gainToDb(x, -200.0); };
    uint32_t i = 0;
#if defined(__GNUC__)
    for (; i + 2 <= n; i += 2) {
        const Pair x = pairOf(lv[i], lv[i + 1]);
        const auto ok = (x >= splat(quiet)) & (x >= splat(2.2250738585072014e-308)) & (x <= splat(1.7976931348623157e308));
        if ((ok[0] & ok[1]) == 0) {
            db[i] = one(lv[i]), db[i + 1] = one(lv[i + 1]);
            continue;
        }
        Pair d = fastLogNormalPair(x) * 8.6858896380650366;
        d = d < splat(-200.0) ? splat(-200.0) : d;
        db[i] = lane(d, 0), db[i + 1] = lane(d, 1);
    }
#endif
    for (; i < n; ++i) db[i] = one(lv[i]);
}

// A gain that follows a dB value sample by sample without an exp each time: step() multiplies by e^d (d the dB
// change in nepers) as its cubic series when |d| is small (a follower moves a fraction of a dB a sample; the
// series' error is under 1e-9 there), else works it out exactly; resync() (each run) starts again from the exact
// value, so no error builds up.
struct GainTracker {
    double db = 0.0, gain = 1.0;
    void resync() noexcept { gain = lib::dbToGain(db); }
    double step(double to) noexcept {
        const double d = (to - db) * 0.11512925464970229;  // ln(10) / 20
        db = to;
        if (d < 0.02 && d > -0.02) gain *= 1.0 + d * (1.0 + d * (0.5 + d * (1.0 / 6.0)));
        else gain = lib::dbToGain(to);
        return gain;
    }
};

// Warm character: a gentle odd-order saturation (tanh, unity slope at 0), about -0.7 dB at half scale.
inline double warm(double x) noexcept { return lib::tanhApprox(x); }

// The stereo link of two sides' levels: 1 both follow the louder, 0 each its own.
inline void link(double* l, double* r, double amount, uint32_t n) noexcept {
    for (uint32_t i = 0; i < n; ++i) {
        const double most = l[i] > r[i] ? l[i] : r[i];
        l[i] += (most - l[i]) * amount;
        r[i] += (most - r[i]) * amount;
    }
}

}  // namespace caw::fx::dyn
