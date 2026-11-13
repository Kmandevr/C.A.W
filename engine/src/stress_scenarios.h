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

// ---------- The feature scenarios' builders (featureScenarios) ----------

// Nothing at all: no tracks, the master alone.
ProjectSpec emptyProject();
// One instrument (flagship, sampler or drums) under busy notes; the sampler's WAV goes into `dir`.
ProjectSpec singleSynth();
ProjectSpec singleSampler(const std::string& dir, std::string* error);
ProjectSpec singleDrums();
// One audio-clip track: a looped stereo clip at the file's speed.
ProjectSpec singleAudio(const std::string& dir, std::string* error);
// Folders: `levels` nested deep (each level a folder holding the next and one track), `width` such chains.
ProjectSpec folders(int levels, int width);
// Sends: `tracks` tracks each sending to every one of `buses` effect-free buses twice (pre and post fader); `chained`: one track's send goes
// through a chain of `buses` buses, each sending on to the next.
ProjectSpec sends(int tracks, int buses, bool chained);
// Automation lanes: `tracks` tracks with `lanes` lanes each (volume, pan and effect parameters), `points` a bar.
ProjectSpec automation(int tracks, int lanes, int points);
// Project modulation: `modulators` LFOs, envelopes and steps each driving every track's effect and fader.
ProjectSpec modulationDense(int tracks, int modulators);
// Chord storms on Flagship (fast chords past its polyphony, so voices are stolen every step).
ProjectSpec voiceStorm();
// `clips` long audio clips on `tracks` tracks (streamed, stretched); `mixedRates`: files at 22.05, 44.1, 88.2 and
// 96 kHz, played at the engine's rate (resampled).
ProjectSpec sampleStream(const std::string& dir, int tracks, bool mixedRates, std::string* error);
// Every built-in instrument on its own track; every built-in effect on a few tracks.
ProjectSpec everyInstrument(const std::string& dir, std::string* error);
ProjectSpec everyEffect();
// Many tracks and buses whose meters, scopes and correlation are all running (cheap instruments).
ProjectSpec meteringHeavy();
// Everything at once: the heavy song plus folders, sends, lanes, modulation, a chord storm and audio clips.
ProjectSpec worstAll(const std::string& dir, std::string* error);

// ---------- Ramp builders (the Benchmark's limits) ----------

// Flagship's default patch (unison 7, ladder, reverb) holding `voices` notes (1..64, its polyphony) for the run.
ProjectSpec flagshipVoices(int voices);
// One Flagship track (default patch, a chord every beat) through `effects` common effects in turn (EQ, compressor,
// saturator, chorus, delay, filter, phaser, reverb, ...), so the count is what one track's chain holds.
ProjectSpec effectsChain(int effects);

// ---------- The suite: fixed scenarios at a stated callback, as caw_bench SECONDS 500 runs them for CI ----------

enum class Tier { Normal = 0, Heavy = 1, Extreme = 2, Idle = 3 };
const char* tierName(Tier t);  // "normal", "heavy", "extreme", "idle"

// The feature a scenario measures (caw_stress_scenarios' "feature": the app groups scenarios by it).
// One of: baseline, instrument, effect, routing, sends, automation, modulation, voices, samples, audio, metering,
// mix_pool, all.
struct SuiteScenario {
    const char* id;
    const char* name;
    std::function<ProjectSpec(const std::string&)> make;  // the argument: typicalSong's work folder
    bool tail = false;  // played for kTailSeconds and reported as three phases (notes, ringing, silence)
    Tier tier = Tier::Normal;
    bool benchOnly = false;  // caw_bench's only (the tail phases): not one of the Benchmark's
    int memoryMiB = 64;      // about what setting it up and playing it takes (measured; stress_scenarios.cpp), for the app's budget check
    const char* feature = "all";
    // A scenario that writes WAVs into the work folder: made with this instead (it needs a folder, and a WAV that
    // can't be written is an error).
    std::function<ProjectSpec(const std::string&, std::string*)> makeChecked;
};

constexpr double kTailSeconds = 30.0;
constexpr double kTailNotesSeconds = 2.0;   // the bar the notes play in (at 120 BPM)
constexpr float kSilence = 1e-5f;           // -100 dBFS: below this the output counts as silent

// Every scenario in caw_bench's order (the CI suite's tables keep it).
std::vector<SuiteScenario> suiteScenarios();
// The Benchmark's feature scenarios (batch 1.0.2, #197): each feature from its best case to its worst. Not in
// caw_bench's suite (its CI tables stay as they are) and not in H2 (the relay knows the first ten only).
std::vector<SuiteScenario> featureScenarios();
// The Benchmark's: the ten the ids section H2 and the relay know (suiteScenarios' order), then featureScenarios().
std::vector<SuiteScenario> benchmarkScenarios();
// A Benchmark scenario's project (makeChecked where it has one); false and `error` when it can't be made.
bool makeScenario(const SuiteScenario& s, const std::string& dir, ProjectSpec& out, std::string& error);
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
