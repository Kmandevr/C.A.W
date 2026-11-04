// Parameter resolution (F6): one rule for manual values, automation, modulation and MIDI-mapped values.
#pragma once

#include <cstddef>
#include <cstdint>

#include "module.h"

namespace caw {

// Normalized scale: 0 at minimum, 1 at maximum, through the descriptor's curve. Exponential uses
// detLog/detExp, so every platform gives the same bits. A zero-width range normalizes to 0.
double normalizeParameter(const ParameterDescriptor& parameter, double plain) noexcept;
double denormalizeParameter(const ParameterDescriptor& parameter, double normalized) noexcept;
// Clamp to the range, then (step > 0) snap to minimum + k * step and clamp again. NaN reads as
// the minimum.
double constrainParameter(const ParameterDescriptor& parameter, double plain) noexcept;

// An automation lane's value at `at` (in steps): the first point's value before it, the last
// point's after it, linear between neighbours, and the later point's value at a jump (two points
// at one step). `fallback` for an empty lane. Points need `step` and `value` and must be sorted by
// step. The Engine's automation and the graph's lanes share this, so they match bit for bit.
template <class Point>
double automationLaneValue(const Point* points, std::size_t count, double at, double fallback) noexcept {
    if (count == 0) return fallback;
    if (at <= points[0].step) return points[0].value;
    std::size_t lo = 0, hi = count - 1;
    while (lo + 1 < hi) {
        const std::size_t mid = (lo + hi) / 2;
        if (points[mid].step <= at) lo = mid; else hi = mid;
    }
    if (at >= points[count - 1].step) return points[count - 1].value;
    const double span = points[hi].step - points[lo].step;
    if (span <= 0.0) return points[hi].value;
    const double t = (at - points[lo].step) / span;
    return points[lo].value + (points[hi].value - points[lo].value) * t;
}
struct AutomationPoint {
    double step = 0.0;   // song position in steps
    double value = 0.0;  // plain parameter value (constrained like any base)
};

// How a modulation link changes the normalized value n, given its source value m (one float per
// frame from a modulation output; NaN and inf read 0) and depth d (a fraction of the range,
// -1..1; owner decision 2026-11-04). Each op blends from n toward its target by d:
//   Add      n + d * m
//   Multiply n + d * (n * m - n)      (d = 1: n * m)
//   Min      n + d * (min(n, m) - n)
//   Max      n + d * (max(n, m) - n)
//   Replace  n + d * (m - n)
enum class ModulationOp : uint8_t { Add, Multiply, Min, Max, Replace };
struct ModulationLink {
    uint32_t id = 0;  // stable identity: links apply in ascending id order, never graph order
    ModulationOp op = ModulationOp::Add;
    double depth = 0.0;
};
inline constexpr uint32_t kMaxParameterLinks = 8;
double applyModulation(ModulationOp op, double depth, double normalized, double modulation) noexcept;


// One parameter's resolution, in this order for every frame:
//   1. Base: the automation value when a lane is active and the parameter is not touched,
//      otherwise the manual value (setBase: a knob, a typed value or a mapped MIDI CC), smoothed
//      linearly over smoothingFrames from the value last resolved. A manual change made while
//      automation exists is a touch: it wins until clearTouch(), which the host calls when
//      playback (re)starts.
//   2. Links without a signal are skipped. With none carrying one the base is only constrained,
//      so plain values pass bit for bit. NaN reads as the minimum (the Engine's automation path
//      never produces NaN).
//   3. Otherwise: normalize, apply each link in id order, clamp to 0..1, denormalize, constrain.
// Threading: nothing here is synchronized. configure() and setLinks() must reach the audio thread
// through a program swap or a queue, and setBase()/clearTouch() must run on the thread that calls
// resolve(); setBase(), clearTouch() and resolve() are real-time safe (no allocation, bounded by
// frames x links). The descriptor's string views (id, unit) must outlive the resolver.
class ParameterResolver {
public:
    // Resets to the default, untouched, no links. False for an invalid descriptor.
    bool configure(const ParameterDescriptor& parameter) noexcept;
    // Sorts by id. False (links unchanged) for more than kMaxParameterLinks, a duplicate id, an
    // unknown op or a depth outside -1..1.
    bool setLinks(const ModulationLink* links, uint32_t count) noexcept;
    void setBase(double plain) noexcept;
    // A restored value (a rebuilt graph, a loaded project): jumps there, no ramp, not a touch.
    void setInitial(double plain) noexcept;
    void clearTouch() noexcept { touched_ = false; }
    bool touched() const noexcept { return touched_; }
    // automation: `frames` plain values, or null for no active lane. modulation: null, or one
    // signal per link in id order (linkCount() entries), each null (the link is skipped) or
    // `frames` floats. out: room for `frames` values, and required (non-null, frames > 0) whenever
    // a lane, a signal or a ramp is present; without it the block resolves as constant. The result
    // points into `out`, so each parameter needs its own buffer for as long as its values are read.
    ParameterValue resolve(uint32_t frames, const double* automation, const float* const* modulation,
                           double* out) noexcept;
    const ParameterDescriptor& descriptor() const noexcept { return parameter_; }
    uint32_t linkCount() const noexcept { return linkCount_; }
    // The value held once smoothing ends: the manual value, or the last automated one.
    double target() const noexcept { return target_; }

private:
    double frameValue(double base, const float* const* modulation, uint32_t frame) const noexcept;

    ParameterDescriptor parameter_{};
    ModulationLink links_[kMaxParameterLinks]{};
    uint32_t linkCount_ = 0;
    double current_ = 0.0, target_ = 0.0, increment_ = 0.0;
    uint32_t rampLeft_ = 0;
    bool touched_ = false;
};

}  // namespace caw
