// Tests for parameter resolution (F6.1): curves, constraints, modulation ops, smoothing, touch and link order.
#include "test.h"

#include "params.h"

#include <algorithm>
#include <cmath>
#include <limits>

using namespace caw;

namespace {
ParameterDescriptor linear(double def = 0.5, double lo = 0.0, double hi = 1.0) {
    ParameterDescriptor p;
    p.id = "p";
    p.defaultValue = def;
    p.minimum = lo;
    p.maximum = hi;
    return p;
}
ParameterDescriptor cutoff() {
    ParameterDescriptor p = linear(1000.0, 20.0, 20000.0);
    p.curve = ParameterCurve::Exponential;
    p.unit = "Hz";
    return p;
}
constexpr double kNaN = std::numeric_limits<double>::quiet_NaN();
}  // namespace

TEST(parameter_curves_map_the_range_to_zero_one_and_back) {
    const ParameterDescriptor lin = linear(0.0, -12.0, 12.0);
    CHECK_EQ(normalizeParameter(lin, -12.0), 0.0);
    CHECK_EQ(normalizeParameter(lin, 12.0), 1.0);
    CHECK_EQ(normalizeParameter(lin, 0.0), 0.5);
    CHECK_EQ(denormalizeParameter(lin, 0.25), -6.0);
    CHECK_EQ(normalizeParameter(lin, 99.0), 1.0);  // clamped first
    const ParameterDescriptor exp = cutoff();
    CHECK_EQ(normalizeParameter(exp, 20.0), 0.0);
    CHECK(std::fabs(normalizeParameter(exp, 20000.0) - 1.0) < 1e-12);
    CHECK_EQ(denormalizeParameter(exp, 1.0), 20000.0);  // endpoints exact, not one ulp short
    CHECK_EQ(denormalizeParameter(exp, 0.0), 20.0);
    CHECK(std::fabs(denormalizeParameter(exp, 0.5) - std::sqrt(20.0 * 20000.0)) < 1e-6);  // the geometric middle
    for (double v : {20.0, 55.0, 440.0, 1000.0, 19999.0})
        CHECK(std::fabs(denormalizeParameter(exp, normalizeParameter(exp, v)) - v) < v * 1e-12);
    const ParameterDescriptor flat = linear(3.0, 3.0, 3.0);
    CHECK_EQ(normalizeParameter(flat, 3.0), 0.0);
    CHECK_EQ(denormalizeParameter(flat, 0.7), 3.0);
}

TEST(parameter_constrain_clamps_then_snaps_to_step_like_the_engine) {
    ParameterDescriptor p = linear(0.0, -1.0, 1.0);
    CHECK_EQ(constrainParameter(p, 2.0), 1.0);
    CHECK_EQ(constrainParameter(p, kNaN), -1.0);
    CHECK_EQ(constrainParameter(p, 0.1), 0.1);  // continuous: bits unchanged
    p.step = 0.25;
    for (double v : {-0.9, -0.13, 0.12, 0.13, 0.62, 0.99}) {
        const double engine = std::clamp(p.minimum + std::round((std::clamp(v, -1.0, 1.0) - p.minimum) / p.step) * p.step,
                                         p.minimum, p.maximum);
        CHECK_EQ(constrainParameter(p, v), engine);
    }
    CHECK_EQ(constrainParameter(p, 0.13), 0.25);
}

TEST(parameter_modulation_ops_blend_by_depth) {
    CHECK_EQ(applyModulation(ModulationOp::Add, 0.5, 0.25, 0.5), 0.5);
    CHECK_EQ(applyModulation(ModulationOp::Add, -0.5, 0.25, 0.5), 0.0);
    CHECK_EQ(applyModulation(ModulationOp::Multiply, 1.0, 0.8, 0.5), 0.4);
    CHECK_EQ(applyModulation(ModulationOp::Multiply, 0.0, 0.8, 0.5), 0.8);
    CHECK_EQ(applyModulation(ModulationOp::Min, 1.0, 0.8, 0.5), 0.5);
    CHECK_EQ(applyModulation(ModulationOp::Min, 1.0, 0.25, 0.5), 0.25);
    CHECK_EQ(applyModulation(ModulationOp::Max, 0.5, 0.25, 0.75), 0.5);
    CHECK_EQ(applyModulation(ModulationOp::Replace, 1.0, 0.25, 0.75), 0.75);
    CHECK_EQ(applyModulation(ModulationOp::Replace, 0.5, 0.25, 0.75), 0.5);
}

TEST(parameter_resolver_is_constant_and_exact_without_sources) {
    ParameterResolver r;
    CHECK(r.configure(linear(0.1)));
    double out[8];
    ParameterValue v = r.resolve(8, nullptr, nullptr, out);
    CHECK(v.samples == nullptr);
    CHECK_EQ(v.value, 0.1);
    r.setBase(0.3);  // no smoothing: the next block reads it, still constant
    v = r.resolve(8, nullptr, nullptr, out);
    CHECK(v.samples == nullptr);
    CHECK_EQ(v.value, 0.3);
    r.setBase(5.0);
    CHECK_EQ(r.resolve(8, nullptr, nullptr, out).value, 1.0);  // clamped
}

TEST(parameter_resolver_smooths_manual_changes_and_lands_on_the_target) {
    ParameterDescriptor p = linear(0.0);
    p.smoothingFrames = 4;
    ParameterResolver r;
    CHECK(r.configure(p));
    r.setBase(1.0);
    double out[6];
    ParameterValue v = r.resolve(6, nullptr, nullptr, out);
    CHECK(v.samples == out);
    const double expected[] = {0.25, 0.5, 0.75, 1.0, 1.0, 1.0};
    for (int i = 0; i < 6; ++i) CHECK_EQ(out[i], expected[i]);
    CHECK_EQ(v.value, 0.25);
    v = r.resolve(6, nullptr, nullptr, out);
    CHECK(v.samples == nullptr);
    CHECK_EQ(v.value, 1.0);
    // A ramp spanning two blocks continues where it left off.
    r.setBase(0.0);
    r.resolve(2, nullptr, nullptr, out);
    CHECK_EQ(out[1], 0.5);
    r.resolve(2, nullptr, nullptr, out);
    CHECK_EQ(out[1], 0.0);
}

TEST(parameter_resolver_follows_automation_until_touched) {
    ParameterResolver r;
    CHECK(r.configure(linear(0.5)));
    const double lane[] = {0.1, 0.2, 0.3, 2.0};
    double out[4];
    ParameterValue v = r.resolve(4, lane, nullptr, out);
    CHECK(v.samples == out);
    CHECK_EQ(out[0], 0.1);
    CHECK_EQ(out[2], 0.3);
    CHECK_EQ(out[3], 1.0);  // automation is constrained like any base
    r.setBase(0.7);  // a touch: the manual value wins while the lane plays on
    CHECK(r.touched());
    v = r.resolve(4, lane, nullptr, out);
    CHECK(v.samples == nullptr);
    CHECK_EQ(v.value, 0.7);
    r.clearTouch();  // playback restart: automation again
    r.resolve(4, lane, nullptr, out);
    CHECK_EQ(out[1], 0.2);
}

TEST(parameter_resolver_applies_links_in_id_order_whatever_order_they_were_given) {
    // Add 0.5 (id 1) then Replace with depth 0.5 (id 2) differs from the other order, so the order shows.
    const ModulationLink given[] = {{2, ModulationOp::Replace, 0.5}, {1, ModulationOp::Add, 0.5}};
    const ModulationLink reversed[] = {{1, ModulationOp::Add, 0.5}, {2, ModulationOp::Replace, 0.5}};
    ParameterResolver a, b;
    CHECK(a.configure(linear(0.0)) && b.configure(linear(0.0)));
    CHECK(a.setLinks(given, 2));
    CHECK(b.setLinks(reversed, 2));
    const float add[] = {0.5f, 0.5f}, replace[] = {0.0f, 1.0f};
    const float* signals[] = {add, replace};  // in id order
    double outA[2], outB[2];
    a.resolve(2, nullptr, signals, outA);
    b.resolve(2, nullptr, signals, outB);
    // n = 0 + 0.5*0.5 = 0.25, then Replace by 0.5 toward m: frame 0 -> 0.125, frame 1 -> 0.625.
    CHECK_EQ(outA[0], 0.125);
    CHECK_EQ(outA[1], 0.625);
    CHECK_EQ(outB[0], outA[0]);
    CHECK_EQ(outB[1], outA[1]);
}

TEST(parameter_resolver_modulates_on_the_normalized_curve_and_clamps) {
    ParameterResolver r;
    CHECK(r.configure(cutoff()));
    r.setBase(20.0);
    const ModulationLink half{1, ModulationOp::Add, 0.5};
    CHECK(r.setLinks(&half, 1));
    const float m[] = {1.0f, 4.0f, std::numeric_limits<float>::quiet_NaN(), -std::numeric_limits<float>::infinity()};
    const float* signals[] = {m};
    double out[4];
    r.resolve(4, nullptr, signals, out);
    CHECK(std::fabs(out[0] - std::sqrt(20.0 * 20000.0)) < 1e-6);  // half the normalized range
    CHECK_EQ(out[1], 20000.0);  // 0 + 0.5 * 4 clamps to 1
    CHECK_EQ(out[2], 20.0);     // NaN and inf read 0
    CHECK_EQ(out[3], 20.0);
    // A link with no signal reads 0 and the block stays constant.
    ParameterValue v = r.resolve(4, nullptr, nullptr, out);
    CHECK(v.samples == nullptr);
    CHECK(std::fabs(v.value - 20.0) < 1e-9);
}

TEST(parameter_resolver_rejects_bad_links_and_keeps_the_old_ones) {
    ParameterResolver r;
    CHECK(r.configure(linear()));
    const ModulationLink one{1, ModulationOp::Add, 0.5};
    CHECK(r.setLinks(&one, 1));
    ModulationLink many[kMaxParameterLinks + 1];
    for (uint32_t k = 0; k <= kMaxParameterLinks; ++k) many[k] = {k, ModulationOp::Add, 0.1};
    CHECK(!r.setLinks(many, kMaxParameterLinks + 1));
    const ModulationLink duplicate[] = {{3, ModulationOp::Add, 0.1}, {3, ModulationOp::Max, 0.2}};
    CHECK(!r.setLinks(duplicate, 2));
    const ModulationLink deep{2, ModulationOp::Add, 1.5};
    CHECK(!r.setLinks(&deep, 1));
    const ModulationLink nanDepth{2, ModulationOp::Add, kNaN};
    CHECK(!r.setLinks(&nanDepth, 1));
    const ModulationLink badOp{2, static_cast<ModulationOp>(9), 0.1};
    CHECK(!r.setLinks(&badOp, 1));
    CHECK_EQ(r.linkCount(), 1u);
    CHECK(r.setLinks(many, kMaxParameterLinks));
}

TEST(parameter_descriptor_validates_step_and_curve) {
    ParameterDescriptor p = linear();
    p.step = -0.1;
    CHECK(validateModuleDescriptor({"x", 1, nullptr, 0, &p, 1}) == ModuleValidation::InvalidParameterStep);
    p.step = std::numeric_limits<double>::infinity();
    CHECK(validateModuleDescriptor({"x", 1, nullptr, 0, &p, 1}) == ModuleValidation::InvalidParameterStep);
    p = linear(0.5, 0.0, 1.0);
    p.curve = ParameterCurve::Exponential;  // needs minimum > 0
    CHECK(validateModuleDescriptor({"x", 1, nullptr, 0, &p, 1}) == ModuleValidation::InvalidParameterCurve);
    ParameterResolver r;
    CHECK(!r.configure(p));
    const ParameterDescriptor a = cutoff();
    ParameterDescriptor b = cutoff();
    b.smoothingFrames = 64;
    CHECK(!moduleDescriptorsMatch({"x", 1, nullptr, 0, &a, 1}, {"x", 1, nullptr, 0, &b, 1}));
    b = cutoff();
    b.unit = "kHz";  // display text only: not part of the match
    CHECK(moduleDescriptorsMatch({"x", 1, nullptr, 0, &a, 1}, {"x", 1, nullptr, 0, &b, 1}));
    b = cutoff();
    b.smoothingFrames = kMaxParameterSmoothingFrames + 1;
    CHECK(validateModuleDescriptor({"x", 1, nullptr, 0, &b, 1}) == ModuleValidation::InvalidParameterSmoothing);
    CHECK(moduleDescriptorsMatch({"x", 1, nullptr, 0, &a, 1}, {"x", 1, nullptr, 0, &a, 1}));
}

TEST(parameter_resolver_touch_during_automation_ramps_from_the_value_that_was_playing) {
    ParameterDescriptor p = linear(0.0);
    p.smoothingFrames = 2;
    ParameterResolver r;
    CHECK(r.configure(p));
    const double lane[] = {0.6, 0.8};
    double out[2];
    r.resolve(2, lane, nullptr, out);
    CHECK_EQ(out[1], 0.8);
    r.setBase(1.0);  // a touch: ramp from 0.8 (what was sounding), not from the old manual 0.0
    r.resolve(2, lane, nullptr, out);
    CHECK_EQ(out[0], 0.8 + (1.0 - 0.8) / 2.0);
    CHECK_EQ(out[1], 1.0);
}

TEST(parameter_resolver_skips_links_without_a_signal) {
    // A disconnected or bypassed source leaves the value alone, whatever the op, and without any
    // links carrying a signal the value passes bit for bit (no curve round trip).
    ParameterResolver r;
    CHECK(r.configure(cutoff()));
    r.setBase(1234.5678);
    const ModulationLink links[] = {{1, ModulationOp::Multiply, 1.0}, {2, ModulationOp::Replace, 1.0}};
    CHECK(r.setLinks(links, 2));
    double out[2];
    ParameterValue v = r.resolve(2, nullptr, nullptr, out);
    CHECK(v.samples == nullptr);
    CHECK_EQ(v.value, 1234.5678);
    const float* none[] = {nullptr, nullptr};
    CHECK_EQ(r.resolve(2, nullptr, none, out).value, 1234.5678);
    // Only the connected link (Replace toward 0 = the minimum) acts.
    const float zero[] = {0.0f, 0.0f};
    const float* one[] = {nullptr, zero};
    r.resolve(2, nullptr, one, out);
    CHECK_EQ(out[0], 20.0);
}

TEST(parameter_resolver_holds_the_last_automated_value_when_the_lane_stops) {
    ParameterResolver r;
    ParameterDescriptor p = linear();
    p.smoothingFrames = 4;
    CHECK(r.configure(p));
    double out[4];
    const double lane[4] = {0.1, 0.2, 0.3, 0.4};
    r.resolve(4, lane, nullptr, out);
    CHECK_EQ(r.target(), 0.4);
    const ParameterValue v = r.resolve(4, nullptr, nullptr, out);  // stopped: no jump, no ramp
    CHECK(v.samples == nullptr);
    CHECK_EQ(v.value, 0.4);
}

TEST(automation_lane_value_interpolates_holds_and_jumps) {
    const AutomationPoint points[] = {{1.0, 0.0}, {3.0, 1.0}, {3.0, 5.0}, {4.0, 6.0}};
    CHECK_EQ(automationLaneValue(points, 0, 2.0, 9.0), 9.0);  // empty: the fallback
    CHECK_EQ(automationLaneValue(points, 4, 0.0, 9.0), 0.0);  // before the first point
    CHECK_EQ(automationLaneValue(points, 4, 2.0, 9.0), 0.5);
    CHECK_EQ(automationLaneValue(points, 4, 3.0, 9.0), 5.0);  // a jump takes the later value
    CHECK_EQ(automationLaneValue(points, 4, 3.5, 9.0), 5.5);
    CHECK_EQ(automationLaneValue(points, 4, 10.0, 9.0), 6.0);  // after the last
}
