// Parameter resolution (F6): one rule for manual values, automation, modulation and MIDI-mapped values.
#pragma once

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

// A resolved parameter for one block: per-frame values, or one value for the whole block.
struct ParameterValue {
    const double* samples = nullptr;  // null: `value` holds for every frame
    double value = 0.0;               // the block's first frame (what one-value-per-block readers see)
};

// One parameter's resolution, in this order for every frame:
//   1. Base: the automation value when a lane is active and the parameter is not touched,
//      otherwise the manual value (setBase: a knob, a typed value or a mapped MIDI CC), smoothed
//      linearly over smoothingFrames. A manual change made while automation exists is a touch:
//      it wins until clearTouch(), which the host calls when playback (re)starts.
//   2. With no links the base is only constrained, so plain values pass bit for bit.
//   3. Otherwise: normalize, apply each link in id order, clamp to 0..1, denormalize, constrain.
// configure() and setLinks() run on a control thread. setBase(), clearTouch() and resolve() are
// real-time safe (no allocation, bounded by frames x links) but single-threaded with each other.
class ParameterResolver {
public:
    // Resets to the default, untouched, no links. False for an invalid descriptor.
    bool configure(const ParameterDescriptor& parameter) noexcept;
    // Sorts by id. False (links unchanged) for more than kMaxParameterLinks, a duplicate id, an
    // unknown op or a depth outside -1..1.
    bool setLinks(const ModulationLink* links, uint32_t count) noexcept;
    void setBase(double plain) noexcept;
    void clearTouch() noexcept { touched_ = false; }
    bool touched() const noexcept { return touched_; }
    // automation: `frames` plain values, or null for no active lane. modulation: one signal per
    // link in id order (setLinks order), each null (reads 0) or `frames` floats. out: room for
    // `frames` values, used only when the block varies.
    ParameterValue resolve(uint32_t frames, const double* automation, const float* const* modulation,
                           double* out) noexcept;
    const ParameterDescriptor& descriptor() const noexcept { return parameter_; }
    uint32_t linkCount() const noexcept { return linkCount_; }
    double target() const noexcept { return target_; }  // the manual value, after smoothing ends

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
