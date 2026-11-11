// The Space, Modulation and Utility effects of the Kilohearts-style suite (fx-space): registration, presets and the shared helpers.
#pragma once

#include <cstdint>
#include <string_view>
#include <vector>

#include "builtin_effects.h"
#include "presets.h"
#include "caw/library/lfo.hpp"

namespace caw {
namespace fx {

// Registers org.caw.ensemble, .doubler, .vibrato, .tremolo, .autopan, .rotary (builtin_fx_space_mod.cpp), .haas,
// .imager, .channelmixer (builtin_fx_space_stereo.cpp), .convolver and .shimmer (builtin_fx_space_reverb.cpp).
void registerFxSpace(ModuleRegistry& registry);
void registerFxSpaceMod(ModuleRegistry& registry);
void registerFxSpaceStereo(ModuleRegistry& registry);
void registerFxSpaceReverb(ModuleRegistry& registry);

// The factory presets of one of those effects (builtin_fx_space_presets.cpp), or null for any other id.
const std::vector<BuiltinPreset>* fxSpacePresets(std::string_view componentId);

// The convolver's own IR state (builtin_fx_space_reverb.cpp), for tests and the app: decode an impulse response
// from a WAV file's bytes (untrusted: every size checked; PCM 16/24/32-bit or float 32/64, 1 or more channels, the
// first two kept, at most kMaxIrFileSeconds at its rate). False, with `error` set, for anything else.
constexpr double kMaxIrFileSeconds = 10.0;
constexpr uint32_t kMaxIrFileBytes = 16u * 1024u * 1024u;
struct DecodedIr {
    uint32_t sampleRate = 0, channels = 0;
    std::vector<float> left, right;  // right == left for a mono file
};
bool decodeIrWav(const uint8_t* bytes, size_t size, DecodedIr& out, const char*& error);

// LFO shapes and sync shared by the modulation effects: the Library's LfoShape order.
constexpr std::string_view kSpaceLfoShapes[] = {"Sine", "Triangle", "Saw up", "Saw down", "Square", "Sample & hold",
                                                "Smooth random"};

// A delay line read between samples (4-point Hermite), its length a power of two set at prepare (allocates).
class ModLine {
public:
    bool prepare(double seconds, double sampleRate) noexcept;
    void clear() noexcept;
    void write(double x) noexcept;  // then read() counts back from this sample
    // `back` frames before the last write (at least 1, at most the length - 3).
    double read(double back) const noexcept;
    size_t length() const noexcept { return mask_ + 1; }

private:
    std::vector<float> line_;
    size_t mask_ = 0, pos_ = 0;
};

}  // namespace fx
}  // namespace caw

namespace caw::fx {

// A delay-line pitch shifter: two taps sweeping through a `window` (seconds) at the speed that shifts the pitch by
// `ratio`, each faded by sin^2 of its place in the sweep, so their gains always sum to 1 (DAFX ch. 6, "delay-line
// modulation" pitch shifting). Adds about window / 2 of delay.
class GrainShifter {
public:
    bool prepare(double window, double sampleRate) noexcept;
    void clear() noexcept;
    void setRatio(double ratio) noexcept;
    double process(double x) noexcept;

private:
    ModLine line_;
    double window_ = 2400.0, phase_ = 0.0, step_ = 0.0;
};

// Rate in Hz of a sync choice (kSyncDivisions; 0 = Free: `hz`) at `tempo`, and the LFO stepped one control block:
// locked to the song's beat while it plays and the choice is synced. Returns the value at the block's start.
double stepSyncedLfo(lib::Lfo& lfo, int division, double hz, bool playing, double beat, double tempo, uint32_t frames) noexcept;

}  // namespace caw::fx
