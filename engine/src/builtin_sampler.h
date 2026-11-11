// The sampler instrument (org.caw.sampler): zones over the asset store, round robins, ADSR, a filter; SFZ import and export.
#pragma once

#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "module_registry.h"

namespace caw {

struct ComponentSpec;
struct AudioAsset;

inline constexpr const char* kSamplerId = "org.caw.sampler";
inline constexpr size_t kMaxSamplerZones = 4096;
inline constexpr uint32_t kSamplerVoices = 64;
inline constexpr uint32_t kMaxSamplerStateBytes = 4u << 20;

enum class LoopMode : uint8_t { NoLoop, OneShot, Continuous, Sustain };

// One zone (an SFZ region): the keys and velocities it answers and how it plays its sample. Frame positions are in
// the sample file's own frames, as in SFZ.
struct SamplerZone {
    std::string path;
    int lokey = 0, hikey = 127, root = 60;
    int lovel = 1, hivel = 127;
    double tune = 0;        // cents
    int transpose = 0;      // semitones
    double volume = 0;      // dB
    double pan = 0;         // -100..100
    double keytrack = 100;  // cents per key
    double veltrack = 100;  // percent
    int64_t offset = 0, end = 0;  // end: the last frame played (0: the file's end)
    LoopMode loopMode = LoopMode::NoLoop;
    bool loopModeSet = false;     // loop_mode was given (else: loop when loop points are given)
    int64_t loopStart = 0, loopEnd = 0;  // loopEnd: the last frame of the loop (0 with loopStart 0: none)
    double loopCrossfade = 0;     // seconds
    int seqLength = 1, seqPosition = 1;
    double lorand = 0, hirand = 1;
    int group = 0, offBy = 0;     // a zone with off_by = g is cut when a zone of group g starts (0: none)
    // Envelope overrides (negative: the instrument's parameter).
    double ampAttack = -1, ampDecay = -1, ampSustain = -1, ampRelease = -1;
};

struct SamplerProgram {
    std::vector<SamplerZone> zones;
};

// The sampler's state: {"zones": [zone, ...]} with the keys of docs/engine.md ("Sampler"). False with `error`.
bool parseSamplerState(std::string_view json, SamplerProgram& out, std::string& error);
std::string samplerStateJson(const SamplerProgram& program);

// SFZ (docs/engine.md, "SFZ support"). Import resolves sample paths against the file's folder (and
// default_path); warnings name every opcode left out.
bool importSfzText(std::string_view text, const std::string& baseDir, SamplerProgram& out,
                   std::vector<std::string>& warnings, std::string& error);
// The SFZ text for a program, its sample paths written relative to `sfzDir` where they are inside it.
std::string exportSfzText(const SamplerProgram& program, const std::string& sfzDir, const std::string& title);
// JSON results for the C API: {"ok","error","warnings","state"} and {"ok","error","files"}.
std::string sfzImportJson(const std::string& path);
std::string sfzExportJson(std::string_view stateJson, const std::string& sfzPath, bool copySamples);

void registerSampler(ModuleRegistry& registry);
// A kept sampler whose project state changed loads it (component_chain's project update).
void applySamplerProjectState(ModuleProcessor& processor, const ComponentSpec& spec);

}  // namespace caw
