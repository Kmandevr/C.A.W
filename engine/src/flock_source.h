// Flock's sources (org.caw.flock): a sample from the asset store read in place with its half-band mip copies, or a built-in synthesised tone, built off the audio thread and shared.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "caw/library/grain.hpp"

namespace caw {
struct AudioAsset;
namespace flock {

// Mip copies above the source's own frames: a grain up to 48 semitones up (a rate of 16) reads level 4 at a rate
// of at most 1 (together about 94 % more RAM than the sample).
inline constexpr uint32_t kMipLevels = 4;
inline constexpr double kMaxMipSeconds = 120.0;  // a longer sample gets no mip copies (their RAM)
inline constexpr uint32_t kOverview = 32;  // the display's peaks of the source
inline constexpr uint32_t kBuiltinCount = 4;
inline constexpr double kBuiltinSeconds = 2.0;
inline constexpr double kBuiltinRootHz = 261.6255653005986;  // the built-in tones sound middle C (key 60)

// What Flock's grains read. Immutable once built (on a control thread); the audio thread only reads it through a
// pointer the instrument holds. levels[0] is the source at the engine's rate (a sample read in place from the asset
// store: no copy), levels[1..kMipLevels] its half-band copies, each half the frames of the one before.
struct Source {
    std::shared_ptr<const AudioAsset> asset;  // a sample (null: a built-in tone)
    std::vector<float> own[kMipLevels + 1][2];  // the padded frames this source owns (a built-in's level 0, the mips)
    lib::grain::Source levels[kMipLevels + 1];
    uint32_t mips = 0;  // the mip copies built (0 for a sample over kMaxMipSeconds: it reads level 0 at any rate)
    float overview[kOverview] = {};  // the peak of each 32nd of the source
    double seconds = 0;
    int builtin = -1;  // the built-in tone, or -1 for a sample
    size_t bytes() const noexcept;  // what it owns (the asset not counted)
};

// The source for an asset (its mip copies built once and shared by every Flock playing that asset at its rate while
// one holds it); null when the asset is too short (under 16 frames) or out of memory. Control thread.
std::shared_ptr<const Source> sampleSource(const std::shared_ptr<const AudioAsset>& asset);
// Built-in tone `kind` (0 Strings, 1 Glass, 2 Breath, 3 Choir) at `rate`, synthesised once per process and rate.
// Control thread.
std::shared_ptr<const Source> builtinSource(int kind, double rate);

}  // namespace flock
}  // namespace caw
