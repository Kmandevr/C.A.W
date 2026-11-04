// Offline renders for export: exact loops, free-length takes, trimmed one-shots and wavetables.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "project.h"

namespace caw {

enum class ExportKind { Loop, Free, OneShot, Wavetable };

struct ExportOptions {
    ExportKind kind = ExportKind::Loop;
    int sampleRate = 48000;
    double seconds = 8.0;  // Free
    std::string target;    // OneShot: layer id. Wavetable: module id
    std::string param;     // Wavetable: the param swept across frames (empty = none)
    int frames = 64;       // Wavetable frame count
    uint64_t memoryBytes = 0;  // the most the render and its WAV copy may hold; 0 = this device's engine budget
};

// The most frames a WAV file holds at the widest format (stereo 32-bit float), whose sizes are 32-bit.
constexpr int64_t kMaxWavFrames = (0xFFFFFFFFll - 1024) / 8;

struct RenderResult {
    std::vector<float> samples;  // interleaved
    int channels = 2;
    int sampleRate = 48000;
    int64_t frames = 0;
    bool loop = false;
    std::string error;
};

constexpr int kWavetableFrame = 2048;

// progress gets 0..1000 and a non-zero cancel stops the render; both may be shared with another thread.
bool renderExport(const ProjectSpec& p, const ExportOptions& o, RenderResult& out, int32_t* progress = nullptr,
                  int32_t* cancel = nullptr);

}  // namespace caw
