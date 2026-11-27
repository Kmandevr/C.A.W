// caw_bench's mode numbers (`caw_bench SECONDS MODE`), the one list: caw_bench dispatches by name, CMake makes the cost ctests from it, and a number used twice fails the build.
#pragma once

#include <string_view>

namespace caw::bench {

// One mode. `ctest` names the Release ctest that runs it ("" for none) as `caw_bench <first of ctestArgs> <number>
// <rest of ctestArgs>`; engine/CMakeLists.txt reads these rows (one per line, this layout), and
// scripts/number-lists.js checks every `caw_bench S N` in the docs, workflows and CMake against them.
struct Mode {
    int number;
    const char* name;
    const char* ctest;
    const char* ctestArgs;
    const char* what;
};

// A new mode takes the next free number of its series (300s: a device family's cost ceilings) here, and only here:
// two branches that pick the same number then fail to build when merged, instead of one silently shadowing the other.
inline constexpr Mode kModes[] = {
    {-1, "graph", "", "", "the graph executor scenarios only"},
    {0, "full", "", "", "every playback scenario, First loop's cases, editing, export, memory and the graph scenarios"},
    {1, "scenario1", "", "", "playback scenario 1 only: one track (bass)"},
    {2, "scenario2", "", "", "playback scenario 2 only: First loop (6 tracks)"},
    {3, "scenario3", "", "", "playback scenario 3 only: 16 tracks"},
    {4, "scenario4", "", "", "playback scenario 4 only: 64 tracks"},
    {5, "scenario5", "", "", "playback scenario 5 only: First loop with a delay and a reverb on each track"},
    {100, "first_loop", "", "", "First loop, its tracks and each built-in alone (100 K: case K only)"},
    {200, "flagship_voices", "", "", "the flagship synth's cost per voice and per unison copy"},
    {300, "effects", "", "", "each built-in effect's cost, then every device family below (exit 1 over a ceiling)"},
    {301, "tools", "caw_tools_cost", "0.5", "1.1.0's tools (MIDI effects, Meters, Lo-fi, Phase align)"},
    {302, "dynsplit", "caw_dynsplit_cost", "0.5", "1.1.0's dynamics split"},
    {303, "voice", "caw_voice_cost", "0.5", "1.1.0's voice devices (Glint, Harmonizer, Octaver, Mimic)"},
    {306, "lark", "caw_lark_cost", "0.5", "Lark (org.caw.pitchfix)"},
    {307, "pack", "caw_pack_cost", "0.5", "the AutoStacc beta pack"},
    {308, "sampler", "caw_sampler_cost", "0.5", "the sampler's plain and stretched zones"},
    {310, "clean", "caw_clean_cost", "0.5", "Preen and Hush"},
    {320, "raven", "caw_raven_cost", "0.5", "Flagship's 1.1.0 synthesis (Raven)"},
    {321, "timber", "caw_timber_cost", "0.5", "the modelled instruments (the name is Timber's, 1.1.0-1.1.2)"},
    {322, "flock", "caw_flock_cost", "0.5", "Flock (org.caw.flock)"},
    {323, "rook", "caw_rook_cost", "0.5", "the drums' 1.1.0 additions and the Acoustic kit (Rook)"},
    {400, "song", "", "", "song scenario K, timed (400 K)"},
    {401, "song_profile", "", "", "song scenario K, profiled per component (401 K)"},
    {500, "suite", "", "", "the CI suite (options: --runs, --threads, --mode, --only, --json, --md, ...)"},
    {600, "long", "", "", "a long run of one suite scenario"},
    {601, "drift", "", "", "per-track drift against 64-frame callbacks"},
    {602, "spikes", "caw_spike_check", "1 --runs 3 --check 3", "the one-off slow callbacks"},
};

consteval bool unique() {
    constexpr int n = sizeof(kModes) / sizeof(kModes[0]);
    for (int i = 0; i < n; ++i)
        for (int j = i + 1; j < n; ++j) {
            if (kModes[i].number == kModes[j].number) return false;
            if (std::string_view(kModes[i].name) == kModes[j].name) return false;
            if (*kModes[i].ctest && std::string_view(kModes[i].ctest) == kModes[j].ctest) return false;
        }
    return true;
}
static_assert(unique(), "two caw_bench modes share a number, name or ctest: give the newer one the next free number "
                        "(engine/bench/bench_modes.h)");

// A mode's number by name, at compile time: a name not in kModes does not compile.
consteval int mode(std::string_view name) {
    for (const Mode& m : kModes)
        if (name == m.name) return m.number;
    throw "no caw_bench mode of that name (engine/bench/bench_modes.h)";
}

// The listed mode with this number, or null.
inline const Mode* findMode(int number) {
    for (const Mode& m : kModes)
        if (m.number == number) return &m;
    return nullptr;
}

}  // namespace caw::bench
