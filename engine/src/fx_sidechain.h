// The sidechain filter every keyed effect shares (1.1.0): the key's high-pass, low-pass and Listen, appended off.
#pragma once

#include <cstdint>
#include <span>
#include <string_view>

#include "builtin_effects.h"
#include "fx_dyn_common.h"

namespace caw::fx {

// The three parameters, appended to a keyed effect's table (or after a variant's `variant`), each off by default so
// older projects, presets and references play exactly as before: sc_hpf (20 Hz: off), sc_lpf (20 kHz: off) and
// sc_listen (Off). The same ids, ranges and filters as Talon's and Hatch Expand's.
inline void addSidechainParams(ParamTable& p, bool withHighPass = true) {
    if (withHighPass) p.expo("sc_hpf", "Sidechain high-pass", 20.0, 20.0, 2000.0, "Hz");
    p.expo("sc_lpf", "Sidechain low-pass", 20000.0, 500.0, 20000.0, "Hz");
    p.pick("sc_listen", "Sidechain listen", 0.0, kOffOn);
}
// The same as a list, for a merged device's variant (extendedVariantDescriptor's `after`); without sc_hpf for a
// variant whose own table has it (Gate, Pedal).
inline std::span<const ParameterDescriptor> sidechainParamList(bool withHighPass = true) {
    static const ParamTable all = [] {
        ParamTable p;
        addSidechainParams(p, true);
        return p;
    }();
    static const ParamTable rest = [] {
        ParamTable p;
        addSidechainParams(p, false);
        return p;
    }();
    const ParamTable& t = withHighPass ? all : rest;
    return {t.data(), t.size()};
}

// The filter itself: 12 dB/octave TPT SVFs per side (dyn::KeyFilter), each skipped at its end stop, so an effect
// with both off runs exactly as before (one compare a run). Bound to the descriptor's parameters by id (bind, at
// prepare); an effect whose descriptor lacks them (an older id's) leaves it unbound and off.
struct SidechainFilter {
    static constexpr uint32_t kNone = ~0u;
    uint32_t hp = kNone, lp = kNone, li = kNone;
    dyn::KeyFilter f;
    bool listen = false;
    float buf[2][EffectBase::kControlFrames] = {};
    double hpFor_ = -1.0, lpFor_ = -1.0, rateFor_ = -1.0;

    // `ownHighPass`: the effect runs sc_hpf itself (Gate, Pedal: their bits stay), so this filter skips it.
    void bind(const ModuleDescriptor& d, bool ownHighPass = false) noexcept {
        hp = lp = li = kNone;
        for (uint32_t k = 0; k < d.parameterCount; ++k) {
            const std::string_view id = d.parameters[k].id;
            if (id == "sc_hpf" && !ownHighPass) hp = k;
            else if (id == "sc_lpf") lp = k;
            else if (id == "sc_listen") li = k;
        }
    }
    bool bound() const noexcept { return li != kNone; }
    // Control rate: the knobs (an unbound one is off). The coefficients are worked out only when a value moves.
    void set(double hpHz, double lpHz, bool listenOn, double sr) noexcept {
        listen = listenOn;
        if (hp == kNone) hpHz = 20.0;
        if (lp == kNone) lpHz = 20000.0;
        if (hpHz == hpFor_ && lpHz == lpFor_ && sr == rateFor_) return;
        hpFor_ = hpHz, lpFor_ = lpHz, rateFor_ = sr;
        f.set(hpHz, lpHz, sr);
    }
    bool active() const noexcept { return f.useHp || f.useLp; }
    void clear() noexcept { f.clear(); }
    // n frames (at most kControlFrames) of the detector's source, in place.
    void filter(double* l, double* r, uint32_t n) noexcept {
        if (!active()) return;
        f.run(0, l, n);
        f.run(1, r, n);
    }
    // The same for a float source: l and r then point at the filtered copy (null stays null: no key, silence).
    void apply(const float*& l, const float*& r, uint32_t n) noexcept {
        if (!active() || !l || !r) return;
        double x[2][EffectBase::kControlFrames];
        for (uint32_t i = 0; i < n; ++i) x[0][i] = caw::finiteOr0(l[i]), x[1][i] = caw::finiteOr0(r[i]);
        filter(x[0], x[1], n);
        for (uint32_t i = 0; i < n; ++i) buf[0][i] = static_cast<float>(x[0][i]), buf[1][i] = static_cast<float>(x[1][i]);
        l = buf[0];
        r = buf[1];
    }
    // Listen: what the detector hears replaces the output (silence with no key).
    template <class T>
    void listenTo(const T* l, const T* r, float* outL, float* outR, uint32_t n) const noexcept {
        for (uint32_t i = 0; i < n; ++i) {
            outL[i] = l ? static_cast<float>(l[i]) : 0.0f;
            outR[i] = r ? static_cast<float>(r[i]) : 0.0f;
        }
    }
};

}  // namespace caw::fx
