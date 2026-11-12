// The EQ & Filter group of the effects suite (fx-filters): registration and the small helpers its effects share.
#pragma once

#include <cstdint>
#include <string_view>
#include <vector>

#include "builtin_effects.h"
#include "stereo_pair.h"
#include "presets.h"

namespace caw::fx {

// Registers org.caw.ladder, .nlfilter (builtin_fx_filters.cpp), .comb, .resonator (builtin_fx_filters_comb.cpp),
// .formant, .disperser (builtin_fx_filters_formant.cpp), .eq.dj, .tilt and .geq (builtin_fx_filters_eq.cpp).
void registerFilters(ModuleRegistry& registry);

void registerLadderAndNonlinear(ModuleRegistry& registry);  // builtin_fx_filters.cpp
void registerCombAndResonator(ModuleRegistry& registry);    // builtin_fx_filters_comb.cpp
void registerFormantAndDisperser(ModuleRegistry& registry); // builtin_fx_filters_formant.cpp
void registerFilterEqs(ModuleRegistry& registry);           // builtin_fx_filters_eq.cpp

// The factory presets of the group's effects (builtin_fx_filters_presets.cpp); null for any other id.
const std::vector<BuiltinPreset>* filtersPresets(std::string_view componentId);

namespace filters {

// A MIDI note (69 = A4 = 440 Hz) and cents to Hz.
inline double noteHz(double note, double cents = 0.0) noexcept {
    return 440.0 * detPow(2.0, (note - 69.0 + cents / 100.0) / 12.0);
}

// A crossfade between two settings of a path that cannot change smoothly (a filter's output tap, a mode): `from`
// and `to` are the old and new setting, `w` runs 0 to 1 over `step`s; a change during a fade restarts it from where
// the path is heard most.
struct Switch {
    int from = 0, to = 0;
    double w = 1.0, step = 1.0 / 240.0;
    void prepare(double sampleRate, double seconds = 0.005) noexcept { step = 1.0 / (seconds * sampleRate); }
    void snap(int v) noexcept { from = to = v, w = 1.0; }
    void set(int v) noexcept {
        if (v == to) return;
        from = w < 0.5 ? from : to;
        to = v;
        w = 0.0;
    }
    bool fading() const noexcept { return w < 1.0; }
    double next() noexcept { return w = w + step >= 1.0 ? 1.0 : w + step; }
};

// A stereo pair's two channels as one two-wide vector (stereo_pair.h).
using caw::Pair;
using caw::pairOf;
using caw::lane;
using caw::flushPair;

// A bounded, NaN-free value for a feedback state: a filter pushed past reason recovers instead of latching inf.
inline double guard(double v, double limit = 1e3) noexcept {
    if (!(v > -limit)) return v != v ? 0.0 : -limit;
    return v > limit ? limit : v;
}

}  // namespace filters
}  // namespace caw::fx
