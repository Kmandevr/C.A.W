// Parameter resolution (F6): one rule for manual values, automation, modulation and MIDI-mapped values.
#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>

#include "module.h"

namespace caw {

// Normalized scale: 0 at minimum, 1 at maximum, through the descriptor's curve. Exponential uses
// detLog/detExp, so every platform gives the same bits. A zero-width range normalizes to 0.
double normalizeParameter(const ParameterDescriptor& parameter, double plain) noexcept;
double denormalizeParameter(const ParameterDescriptor& parameter, double normalized) noexcept;
// Clamp to the range, then (step > 0) snap to minimum + k * step and clamp again. NaN reads as
// the minimum.
double constrainParameter(const ParameterDescriptor& parameter, double plain) noexcept;
// out[i] = constrainParameter(p, denormalizeParameter(p, clamp(n0 + offset[i], 0, 1))) for i < count, with the
// curve's log worked out once for the block (the same bits, which a block split must not change): a held base
// under audio-rate modulation.
void denormalizeOffsets(const ParameterDescriptor& parameter, double n0, const float* offset, uint32_t count,
                        double* out) noexcept;

// A segment's curve, from a point to the next (owner, 2026-11-17, #230). Stored on the earlier point, with a
// tension of -1..1 that bends Slow, Fast and S-curve (0 is the default bend; Linear and Step ignore it).
enum class AutomationCurve : uint8_t { Linear = 0, Slow = 1, Fast = 2, SCurve = 3, Step = 4 };
inline constexpr uint8_t kAutomationCurveCount = 5;

// The curve's shape at t (0..1 through the segment), 0 at its start and 1 at its end. A closed form of +, -, *
// and / only (no pow or exp), so with the engine's strict floating point every platform gives the same bits:
//   b = 0.4375 * (1 + tension)              (0 .. 0.875, dyadic: tension -1 is a straight line, 0 and 1 are exact)
//   Slow(t)   = t(1-b) / (t(1-b) + (1-t)(1+b))   (eases in: at t = 1/2 it is (1-b)/2)
//   Fast(t)   = t(1+b) / (t(1+b) + (1-t)(1-b))   (eases out: at t = 1/2 it is (1+b)/2)
//   SCurve(t) = Slow(2t)/2 below t = 1/2, 1/2 + Fast(2t-1)/2 from it
//   Step(t)   = 0 (the start's value holds until the next point)
// Linear never comes here: automationLaneValue keeps its original expression so linear lanes stay bit-identical.
inline double automationCurveShape(uint8_t curve, double tension, double t) noexcept {
    if (!(tension >= -1.0)) tension = -1.0;  // below the range, or NaN (never from a parsed project): the gentlest
    if (tension > 1.0) tension = 1.0;
    const double b = 0.4375 * (1.0 + tension);
    const auto slow = [b](double x) noexcept {
        const double a = x * (1.0 - b);
        return a / (a + (1.0 - x) * (1.0 + b));
    };
    const auto fast = [b](double x) noexcept {
        const double a = x * (1.0 + b);
        return a / (a + (1.0 - x) * (1.0 - b));
    };
    switch (static_cast<AutomationCurve>(curve)) {
        case AutomationCurve::Slow: return slow(t);
        case AutomationCurve::Fast: return fast(t);
        case AutomationCurve::SCurve: return t < 0.5 ? 0.5 * slow(2.0 * t) : 0.5 + 0.5 * fast(2.0 * t - 1.0);
        case AutomationCurve::Step: return 0.0;
        default: return t;
    }
}

// An automation lane's value at `at` (in steps): the first point's value before it, the last
// point's after it, along each segment's curve between neighbours (linear unless the earlier point says
// otherwise), and the later point's value at a jump (two points at one step). `fallback` for an empty lane.
// Points need `step`, `value`, `curve` and `tension` and must be sorted by step. The Engine's automation and
// the graph's lanes share this, so they match bit for bit.
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
    if (points[lo].curve == 0) return points[lo].value + (points[hi].value - points[lo].value) * t;
    return points[lo].value + (points[hi].value - points[lo].value) *
                                  automationCurveShape(points[lo].curve, points[lo].tension, t);
}
struct AutomationPoint {
    double step = 0.0;   // song position in steps
    double value = 0.0;  // plain parameter value (constrained like any base)
    uint8_t curve = 0;   // AutomationCurve of the segment to the next point
    double tension = 0.0;  // -1..1, bends Slow, Fast and S-curve
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
    bool ramping() const noexcept { return rampLeft_ != 0; }
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
    // The steady value's constrained form, kept for the value it was worked out from (resolve's fast path).
    double steadyFor_ = std::numeric_limits<double>::quiet_NaN(), steady_ = 0.0;
    uint32_t rampLeft_ = 0;
    bool touched_ = false;
};

}  // namespace caw
