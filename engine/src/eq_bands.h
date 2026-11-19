// The EQ's band layout, shared by its Bands, Linear and Match variants (builtin_effects_eq.cpp, builtin_fx_eq_plume.cpp).
#pragma once

#include <cstdint>
#include <string_view>

#include "builtin_effects.h"
#include "caw/library/eq.hpp"

namespace caw::fx {

constexpr uint32_t kEqBands = 8;
// Each band's knobs, in order (b1_on, b1_type, ...): parameter b * kEqBandParams + p.
enum EqBandParam : uint32_t { kEqOn, kEqType, kEqFreq, kEqGain, kEqQ, kEqChannel, kEqBandParams };
constexpr uint32_t eqBandParam(uint32_t b, uint32_t p) { return b * kEqBandParams + p; }
constexpr uint32_t kEqOutput = kEqBands * kEqBandParams;  // "output", right after the bands

inline constexpr std::string_view kEqTypes[] = {"Bell", "Low shelf", "High shelf", "Low cut 12", "Low cut 24", "Low cut 48",
                                                "High cut 12", "High cut 24", "High cut 48", "Notch", "Band-pass", "Tilt",
                                                "Low cut 96", "High cut 96"};  // the 96s appended (fx-filters): old numbers kept
static_assert(sizeof(kEqTypes) / sizeof(kEqTypes[0]) == static_cast<size_t>(lib::EqType::Count));
inline constexpr std::string_view kEqChannels[] = {"Stereo", "Mid", "Side", "Left", "Right"};
enum EqChannel : int { kEqStereo, kEqMid, kEqSide, kEqLeft, kEqRight };
// band solo: Off, then Band 1..8.
inline constexpr std::string_view kEqSolo[] = {"Off", "Band 1", "Band 2", "Band 3", "Band 4", "Band 5", "Band 6", "Band 7", "Band 8"};

// The 8 bands' knobs and `output`, as the EQ has had them since #173 (ids, defaults and ranges): parameters 0..48.
void addEqBandParams(ParamTable& p);
// `solo_band` (Off, Band 1..8): listening only, never automated, modulated or MIDI-mapped.
ParameterDescriptor& addEqSolo(ParamTable& p);

// Whether a type has a gain (a bell, shelf or tilt: the ones a band's dynamics can move).
inline bool eqTypeHasGain(int type) noexcept {
    const auto t = static_cast<lib::EqType>(type);
    return t == lib::EqType::Bell || t == lib::EqType::LowShelf || t == lib::EqType::HighShelf || t == lib::EqType::Tilt;
}

// What band solo (and a dynamic band's detector) listens through for a band of `type` at hz and q: a band-pass at
// its frequency and Q, or for a shelf or a cut a 12 dB low-pass or high-pass on the side it works on (a low shelf
// or low cut: the lows, below hz; a high one: the highs).
inline void eqListenFilter(lib::EqFilter& f, int type, double hz, double q, double sampleRate) noexcept {
    using T = lib::EqType;
    const auto t = static_cast<T>(type);
    if (t == T::LowShelf || t == T::LowCut12 || t == T::LowCut24 || t == T::LowCut48 || t == T::LowCut96)
        f.set(T::HighCut12, hz, 0.0, 0.70710678118654752, sampleRate);
    else if (t == T::HighShelf || t == T::HighCut12 || t == T::HighCut24 || t == T::HighCut48 || t == T::HighCut96)
        f.set(T::LowCut12, hz, 0.0, 0.70710678118654752, sampleRate);
    else
        f.set(T::BandPass, hz, 0.0, q, sampleRate);
}

}  // namespace caw::fx
