// The song's tempo map and time signatures: exact beat <-> time maths, stepped and ramped (built strict: tempo_map.cpp).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "sample_time.h"  // CAW_STRICT_FN: kept out of line, so link-time optimisation keeps them strict

namespace caw {

// One tempo point (contract 1.0.3, docs/engine.md "Tempo map"): at `beat` (quarter notes from the song start) the tempo
// is `bpm` (quarter notes per minute). `ramp`: the tempo goes linearly in BPM over beats from the previous point to
// this one; otherwise it steps here. The first point's ramp means nothing.
struct TempoPointSpec {
    double beat = 0, bpm = 120;
    bool ramp = false;
    bool operator==(const TempoPointSpec& o) const noexcept { return beat == o.beat && bpm == o.bpm && ramp == o.ramp; }
    bool operator!=(const TempoPointSpec& o) const noexcept { return !(*this == o); }
};
// One time signature: from bar `bar` (0-based, whole bars of the signatures before it) at quarter-note `beat`, `num`
// beats of 1/`den` notes per bar.
struct TimeSigSpec {
    int64_t bar = 0;
    double beat = 0;
    int num = 4, den = 4;
};

constexpr int kMaxTempoPoints = 4096;
constexpr int kMaxTimeSigs = 1024;
constexpr double kMinTempoBpm = 1.0, kMaxTempoBpm = 999.0;

// ln(1 + x) and e^x - 1 for the ramps, the same bits on every platform: the C libraries' log1p and expm1 are not
// correctly rounded and differ between glibc, bionic and MSVC. Only +, -, *, / (correctly rounded under the strict
// flags tempo_map.cpp is built with) and the exact frexp / ldexp; within a few ulp of the true value. log1p takes
// x > -1; expm1 any x below 700.
namespace tempomath {
CAW_STRICT_FN double log1p(double x) noexcept;
CAW_STRICT_FN double expm1(double x) noexcept;
}  // namespace tempomath

// Checks a tempo map from untrusted input and puts it in order: 1..kMaxTempoPoints points, finite, BPM 1..999, beats
// >= 0 and distinct, the first at beat 0. Sorts by beat. False with an error that names the problem.
bool checkTempoPoints(std::vector<TempoPointSpec>& points, std::string& error);
// Checks time signatures: 1..kMaxTimeSigs, num 1..32, den 1/2/4/8/16/32, bars distinct and >= 0, the first at bar 0.
// Sorts by bar and works out each one's beat from the bars before it; a given beat (not NaN) must agree with that
// within 1e-6 (the stored beat is redundant). False with an error.
bool checkTimeSigs(std::vector<TimeSigSpec>& sigs, std::string& error, bool checkBeats = true);

// Signatures given by beat (the C API's CawTimeSig, MIDI files): sorts them by beat, the first must be at beat 0, and
// works out each one's bar. A change off a bar line of the signature before it is an error, or, with `dropOffBar`,
// is left out (a MIDI file's stray meter). Then checkTimeSigs.
bool timeSigsFromBeats(std::vector<TimeSigSpec>& sigs, std::string& error, bool dropOffBar = false);

// The tempo map, in the engine's units: sixteenth steps (4 per beat) and frames at one sample rate, plus beats and
// seconds for the C API and the app's shared vectors (engine/tests/references/tempo_vectors.json).
//
// Each segment runs from one point to the next (the last on forever) at a constant tempo, or ramped linearly in BPM
// over beats when the next point says so. Exact closed forms: a constant segment takes 60 / bpm seconds a beat; a
// ramp from bpm0 to bpm1 over D beats (slope k = (bpm1 - bpm0) / D BPM a beat) reaches beat b0 + d at
// t = 60 / k * ln(1 + k * d / bpm0) (log1p), and the inverse is d = bpm0 / k * expm1(k * t / 60).
//
// Single tempo: neighbouring points with the same tempo (and no ramp between different ones) merge, so a map that
// never changes tempo is one segment, constant() is true, and frameAt(step) is exactly step * stepFrames() and
// stepAt(frame) exactly frame / stepFrames(): what the engine computed before the map, to the bit.
class TempoMap {
public:
    TempoMap() { build({}, 48000.0); }
    // Points as checkTempoPoints leaves them (an empty list: 120 BPM). sampleRate > 0. Allocates: control thread.
    void build(const std::vector<TempoPointSpec>& points, double sampleRate);
    static TempoMap single(double bpm, double sampleRate) {
        TempoMap m;
        m.build({{0.0, bpm, false}}, sampleRate);
        return m;
    }

    bool constant() const noexcept { return segs_.size() == 1; }
    double sampleRate() const noexcept { return sr_; }
    // Samples per step of the first segment (all of the song when constant()): sampletime::stepFrames.
    double stepFrames() const noexcept { return segs_[0].stepFrames; }
    // The map as built (merged), for writers (MIDI export) and the control side.
    const std::vector<TempoPointSpec>& points() const noexcept { return points_; }

    // Song steps <-> frames (not rounded). Monotonic; negative inputs extend the first segment.
    CAW_STRICT_FN double frameAt(double step) const noexcept;
    CAW_STRICT_FN double stepAt(double frame) const noexcept;
    // stepAt for the n frames from `frame` into out (one segment lookup, then the segments in order): the same bits
    // as n calls, for the audio thread's per-sample automation.
    CAW_STRICT_FN void stepsAt(int64_t frame, int n, double* out) const noexcept;
    // floor(frameAt(step) + 0.5): the sample a step lands on (sampletime::roundFrames when constant()).
    CAW_STRICT_FN double roundFrame(double step) const noexcept;
    // The tempo at a step or a frame, and samples per step there (60 * rate / (bpm * 4)).
    CAW_STRICT_FN double bpmAtStep(double step) const noexcept;
    CAW_STRICT_FN double bpmAtFrame(double frame) const noexcept;
    CAW_STRICT_FN double stepFramesAt(double step) const noexcept;

    // Beats (quarter notes) <-> seconds, the same maths in seconds (the C API, the vector file).
    CAW_STRICT_FN double secondsAt(double beat) const noexcept;
    CAW_STRICT_FN double beatAt(double seconds) const noexcept;

private:
    struct Seg {
        double step0 = 0, frame0 = 0, sec0 = 0;  // where it starts
        double bpm0 = 120, slope = 0;            // tempo at its start; BPM per beat (0: constant)
        double stepFrames = 0;                   // constant segments: samples per step
    };
    size_t segAtStep(double step) const noexcept;
    size_t segAtFrame(double frame) const noexcept;
    size_t segAtSecond(double sec) const noexcept;
    std::vector<Seg> segs_;
    std::vector<TempoPointSpec> points_;
    double sr_ = 48000.0;
};

// Time signatures as bars and metronome ticks (quarter-note beats; a tick is one 1/den note).
class TimeSigMap {
public:
    TimeSigMap() { build({{0, 0.0, 4, 4}}); }
    void build(const std::vector<TimeSigSpec>& sigs);  // as checkTimeSigs leaves them (empty: 4/4)
    static TimeSigMap single(int num) {
        TimeSigMap m;
        m.build({{0, 0.0, num, 4}});
        return m;
    }
    const std::vector<TimeSigSpec>& sigs() const noexcept { return sigs_; }
    // One signature of `num`/4: the metronome then ticks as it did before signatures (every beat, accent each bar).
    bool simple(int num) const noexcept { return sigs_.size() == 1 && sigs_[0].den == 4 && sigs_[0].num == num; }
    size_t indexAt(double beat) const noexcept;
    int numAt(double beat) const noexcept { return sigs_[indexAt(beat)].num; }
    // The first tick at or after `beat`, and whether it starts a bar.
    CAW_STRICT_FN double nextTick(double beat, bool& accent) const noexcept;
    // The tick after `tick` (a tick nextTick or tickAfter returned), and whether it starts a bar.
    CAW_STRICT_FN double tickAfter(double tick, bool& accent) const noexcept;
    // The 0-based bar and the beat within it (in quarter notes) at `beat`.
    CAW_STRICT_FN void barAt(double beat, int64_t& bar, double& inBar) const noexcept;

private:
    std::vector<TimeSigSpec> sigs_;
};

// What the audio thread plays by: the tempo map and the signatures, built together on the control thread and swapped
// in through the command queue (retired off the audio thread). `serial` tells one map from the next.
struct SongTime {
    TempoMap tempo;
    TimeSigMap sigs;
    uint64_t serial = 0;
};

}  // namespace caw
