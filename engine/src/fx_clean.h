// 1.1.0's clean-up devices: Preen (org.caw.clean: Denoise, De-hum, De-reverb) and Hush (org.caw.vocalclean: De-click, De-plosive, Breath), and Denoise's offline clip pass.
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>

#include "fx_merged.h"

namespace caw {
struct BuiltinPreset;  // presets.h
namespace fx {

// Both are merged devices (fx_merged.h): one variant per mode, so only the chosen one runs.
std::span<const MergedDevice> mergedPreenDevices();  // builtin_fx_preen.cpp
std::span<const MergedDevice> mergedHushDevices();   // builtin_fx_hush.cpp
// Their presets (each names its `variant`); empty for another id. fx::newVariantPresets returns them.
std::span<const BuiltinPreset> cleanPresets(std::string_view id);

// Bytes an instance allocates at `sampleRate` (caw_bench's RAM column): Preen's variants 0-2, Hush's 0-2.
size_t preenBytes(uint32_t variant, double sampleRate) noexcept;
size_t hushBytes(uint32_t variant, double sampleRate) noexcept;

// Denoise's offline clip pass (the sound plan's "clip pass"): the High tier's window (4,096 at 48 kHz), non-causal:
// each frame's gains are smoothed over the frames before and after it, and the output is aligned with the input (no
// latency). Plain arguments, so a C API function can wrap it one to one later (the app's clip menu is not built).
struct DenoiseClipSettings {
    double reduction = 12.0;    // dB, 0..40 (0: the input back, to rounding)
    double sensitivity = 0.0;   // dB, -12..12 (the noise estimate's offset)
    double smoothing = 0.5;     // 0..1 (time and frequency)
    double low = 20.0;          // Hz: below it untouched
    double high = 20000.0;      // Hz: above it untouched
    double transient = 0.3;     // 0..1: how much of an onset is kept
    // A learned noise profile (Denoise's saved state, its `saveState` bytes), or null: then the noise is estimated
    // from the clip itself (minimum statistics over the whole clip, averaged).
    const uint8_t* profile = nullptr;
    uint32_t profileBytes = 0;
};
// Control or worker thread (it allocates): `frames` frames of a stereo clip (right may equal left: mono) at
// `sampleRate` into out (as long; may not alias in). False, with `error` set, for bad arguments (null buffers, a
// rate outside 8 kHz..384 kHz, more than 2^31 frames, a profile that doesn't parse) or no memory.
bool denoiseClip(const float* inL, const float* inR, float* outL, float* outR, size_t frames, double sampleRate,
                 const DenoiseClipSettings& settings, std::string* error = nullptr);

}  // namespace fx
}  // namespace caw
