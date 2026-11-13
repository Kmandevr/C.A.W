// The benchmark's projects, shared by caw_bench and the app's Benchmark (stress test): builders, the suite, ramps.
#pragma once

#include <cstddef>
#include <functional>
#include <string>
#include <utility>
#include <vector>

#include "project.h"

namespace caw::stress {

using Values = std::vector<std::pair<std::string, double>>;

// ---------- Builders (moved from engine/bench/caw_bench.cpp; caw_bench's output is unchanged by the move) ----------

std::string patternSource(const std::string& name, const std::string& length, const std::string& notes);
// One track: a native instrument (with its values) playing a pattern, then native effects.
void addInstrumentLayer(ProjectSpec& p, const std::string& id, const std::string& instrument, Values params,
                        const std::string& pattern, double volume, std::vector<ComponentSpec> effects = {});
ComponentSpec component(const std::string& id, Values params = {});
ComponentSpec keyed(const std::string& id, Values params, const std::string& from);
void addSends(LayerSpec& l, double reverb, double delay);
// A MIDI note's name in the pattern language (36: C2).
std::string noteName(int midi);

// The app's starter project ("First loop") with every track playing; `only` keeps one track (by id).
ProjectSpec firstLoop(const std::string& only = "");
// First loop's tracks repeated until there are n (ids made unique), all into the master.
ProjectSpec manyTracks(int n);
// First loop with a delay and a reverb after each track's own effects.
ProjectSpec withSpace();
// One native instrument (and effects) under a busy pattern.
ProjectSpec busy(const std::string& instrument, Values params, std::vector<ComponentSpec> effects = {}, bool notes_ = true);
// The typical song: eight tracks, buses, master chain, two LFOs. `extras` adds per-note FX, an audio-clip track and
// a sampler track, whose WAVs are written into `dir` (an existing folder the caller gives: Android has no usable
// temporary folder). A WAV that cannot be written sets *error (when given) and the project lacks nothing else.
ProjectSpec typicalSong(bool extras, const std::string& dir = "", std::string* error = nullptr);
// The owner's 3-track project (2026-11-11 screenshot).
ProjectSpec threeTracks();
// One Flagship patch at its heaviest, `voices` notes held for the whole run.
ProjectSpec flagshipHeavy(int voices);
// org.caw.drums' default kit with its kit-wide effects, all 16 pads of bank A busy.
ProjectSpec drumsBusy();
// The typical song's eight instrument tracks repeated to `n`; `heavy` adds effects, group buses and a plate bus.
ProjectSpec bigSong(int n, bool heavy);
// A reverb and delay tail fading to silence (`notes` false: the same project playing nothing).
ProjectSpec tailSong(bool notes);

// ---------- Ramp builders (the Benchmark's limits) ----------

// Flagship's default patch (unison 7, ladder, reverb) holding `voices` notes (1..64, its polyphony) for the run.
ProjectSpec flagshipVoices(int voices);
// One Flagship track (default patch, a chord every beat) through `effects` common effects in turn (EQ, compressor,
// saturator, chorus, delay, filter, phaser, reverb, ...), so the count is what one track's chain holds.
ProjectSpec effectsChain(int effects);

// ---------- The suite: fixed scenarios at a stated callback, as caw_bench SECONDS 500 runs them for CI ----------

enum class Tier { Normal = 0, Heavy = 1, Extreme = 2, Idle = 3 };
const char* tierName(Tier t);  // "normal", "heavy", "extreme", "idle"

struct SuiteScenario {
    const char* id;
    const char* name;
    std::function<ProjectSpec(const std::string&)> make;  // the argument: typicalSong's work folder
    bool tail = false;  // played for kTailSeconds and reported as three phases (notes, ringing, silence)
    Tier tier = Tier::Normal;
    bool benchOnly = false;  // caw_bench's only (the tail phases): not one of the Benchmark's ten
    int memoryMiB = 64;      // about what setting it up and playing it takes (measured; stress_scenarios.cpp), for the app's budget check
};

constexpr double kTailSeconds = 30.0;
constexpr double kTailNotesSeconds = 2.0;   // the bar the notes play in (at 120 BPM)
constexpr float kSilence = 1e-5f;           // -100 dBFS: below this the output counts as silent

// Every scenario in caw_bench's order (the CI suite's tables keep it).
std::vector<SuiteScenario> suiteScenarios();
// The Benchmark's ten (the ids section H2 and the relay know), in the same order.
std::vector<SuiteScenario> benchmarkScenarios();
// One of suiteScenarios() by id; null if there is none.
const SuiteScenario* findScenario(const std::vector<SuiteScenario>& all, const std::string& id);

struct SuiteStats {
    double meanUs = 0, p99Us = 0, maxUs = 0;
    size_t callbacks = 0;
    size_t maxAt = 0;  // the callback the worst case was, counted from Play
};
// Mean, 99th percentile and worst of us[from, to).
SuiteStats stats(const std::vector<double>& us, size_t from, size_t to);
double median(std::vector<double> v);

}  // namespace caw::stress
