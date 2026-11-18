// Merged devices, part A (Compressor, Limiter, Transient): their variants, each an old dynamics class unchanged (FX consolidation, 1.0.8).
#include "fx_merged.h"

// The ids this part replaces (the old ones stay registered until part F retires them):
// Compressor (variants: the old compressor; dynamics; gate; the ducker as "Shape", today's drawn-shape ducker,
//   where old projects open unchanged; later, new DSP: "Duck" (Compactor-style, following a sidechain level), the
//   expander and upward compression) replaces:
//   org.caw.compressor (builtin_effects_dynamics.cpp), org.caw.dynamics (builtin_fx_dynamics.cpp),
//   org.caw.ducker (builtin_ducker.cpp), org.caw.gate (builtin_effects_dynamics.cpp).
//   Keyed: keep the descriptor's real "sidechain" input on the variants that have one today.
// Limiter replaces org.caw.limiter (builtin_effects_dynamics.cpp).
// Transient replaces org.caw.transient (builtin_effects_dynamics.cpp); optional ports transient/sustain.
// Not merged: org.caw.multiband, org.caw.deesser (builtin_fx_dynamics.cpp).

namespace caw::fx {

// The old classes under a variant's descriptor (their own source files).
const ModuleDescriptor& legacyCompressorDescriptor();  // builtin_effects_dynamics.cpp
const ModuleDescriptor& legacyLimiterDescriptor();
const ModuleDescriptor& legacyGateDescriptor();
const ModuleDescriptor& legacyTransientDescriptor();
ModuleProcessor* makeCompressorAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeLimiterAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeGateAs(const ModuleDescriptor& variant) noexcept;
ModuleProcessor* makeTransientAs(const ModuleDescriptor& variant) noexcept;  // with the transient/sustain outputs
const ModuleDescriptor& legacyDynamicsDescriptor();  // builtin_fx_dynamics.cpp
ModuleProcessor* makeDynamicsAs(const ModuleDescriptor& variant) noexcept;
const ModuleDescriptor& legacyDuckerDescriptor();  // builtin_ducker.cpp
ModuleProcessor* makeDuckerAs(const ModuleDescriptor& variant) noexcept;

namespace {

// Built (2026-11-18): each variant is its old class unchanged under its own descriptor (the old parameters in their
// order, its own ports, latency, tail and cost, `variant` last). The ids whose name is the device's are reused:
// org.caw.compressor, org.caw.limiter and org.caw.transient, each with its old effect as variant 0.
// Compressor's variants keep their own ports: Compressor and Gate a "sidechain" input, Shape (the drawn-shape
// ducker) a "sidechain" and "key_notes", Dynamics none (and it may still run per note); the chain wires each by
// the chosen variant's descriptor. Left for later (new DSP): the Compactor-style "Duck", the expander and upward
// compression.
constexpr std::string_view kCompressorId = "org.caw.compressor";
constexpr std::string_view kCompressorName = "Compressor";
constexpr std::string_view kCompressorVariants[] = {"Compressor", "Dynamics", "Gate", "Shape"};
constexpr std::string_view kLimiterId = "org.caw.limiter";
constexpr std::string_view kLimiterName = "Limiter";
constexpr std::string_view kLimiterVariants[] = {"Limiter"};
constexpr std::string_view kTransientId = "org.caw.transient";
constexpr std::string_view kTransientName = "Transient";
constexpr std::string_view kTransientVariants[] = {"Transient"};

const ModuleDescriptor& compressorVariant() {
    static const ModuleDescriptor& d =
        legacyVariantDescriptor(legacyCompressorDescriptor(), kCompressorId, kCompressorName, kCompressorVariants, 0);
    return d;
}
const ModuleDescriptor& dynamicsVariant() {
    static const ModuleDescriptor& d =
        legacyVariantDescriptor(legacyDynamicsDescriptor(), kCompressorId, kCompressorName, kCompressorVariants, 1);
    return d;
}
const ModuleDescriptor& gateVariant() {
    static const ModuleDescriptor& d =
        legacyVariantDescriptor(legacyGateDescriptor(), kCompressorId, kCompressorName, kCompressorVariants, 2);
    return d;
}
const ModuleDescriptor& shapeVariant() {
    static const ModuleDescriptor& d =
        legacyVariantDescriptor(legacyDuckerDescriptor(), kCompressorId, kCompressorName, kCompressorVariants, 3);
    return d;
}
const ModuleDescriptor& limiterVariant() {
    static const ModuleDescriptor& d =
        legacyVariantDescriptor(legacyLimiterDescriptor(), kLimiterId, kLimiterName, kLimiterVariants, 0);
    return d;
}
const ModuleDescriptor& transientVariant() {
    static const ModuleDescriptor& d =
        legacyVariantDescriptor(legacyTransientDescriptor(), kTransientId, kTransientName, kTransientVariants, 0);
    return d;
}
ModuleProcessor* makeCompressor() noexcept { return makeCompressorAs(compressorVariant()); }
ModuleProcessor* makeDynamics() noexcept { return makeDynamicsAs(dynamicsVariant()); }
ModuleProcessor* makeGate() noexcept { return makeGateAs(gateVariant()); }
ModuleProcessor* makeShape() noexcept { return makeDuckerAs(shapeVariant()); }
ModuleProcessor* makeLimiter() noexcept { return makeLimiterAs(limiterVariant()); }
ModuleProcessor* makeTransient() noexcept { return makeTransientAs(transientVariant()); }

const Variant kCompressor[] = {{kCompressorVariants[0], &compressorVariant, &makeCompressor},
                               {kCompressorVariants[1], &dynamicsVariant, &makeDynamics},
                               {kCompressorVariants[2], &gateVariant, &makeGate},
                               {kCompressorVariants[3], &shapeVariant, &makeShape}};
const Variant kLimiter[] = {{kLimiterVariants[0], &limiterVariant, &makeLimiter}};
const Variant kTransient[] = {{kTransientVariants[0], &transientVariant, &makeTransient}};

const MergedDevice kDevices[] = {{kCompressorId, kCompressorName, kCompressor},
                                 {kLimiterId, kLimiterName, kLimiter},
                                 {kTransientId, kTransientName, kTransient}};

}  // namespace

std::span<const MergedDevice> mergedDynamicsDevices() { return kDevices; }

}  // namespace caw::fx
