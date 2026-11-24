// The AutoStacc beta pack (1.1.0, built in for now; an AutoStacc download from 1.2.0): Murmur, Peck, Bend and Molt, their registration, presets and pack mark.
#pragma once

#include <cstddef>
#include <string_view>
#include <vector>

#include "module_registry.h"

namespace caw {
struct BuiltinPreset;  // presets.h
namespace fx {

// The pack every device here belongs to: caw_engine_components marks each with "pack": this.
inline constexpr std::string_view kAutoStaccBetaPack = "autostacc-beta";

// Registers the pack's devices (registerBuiltinEffects calls it) and builds the grain windows they share.
void registerPack(ModuleRegistry& registry);
// The pack a built-in belongs to ("autostacc-beta"), or empty for one that is part of C.A.W itself.
std::string_view packOf(std::string_view id) noexcept;
// The pack devices' presets; null for another id.
const std::vector<BuiltinPreset>* packPresets(std::string_view id);

void registerMurmur(ModuleRegistry& registry);  // builtin_pack_murmur.cpp: org.caw.pack.granular
void registerPeck(ModuleRegistry& registry);    // builtin_pack_peck.cpp: org.caw.pack.glitch
void registerBend(ModuleRegistry& registry);    // builtin_pack_bend.cpp: org.caw.pack.warp
void registerIris(ModuleRegistry& registry);    // builtin_pack_iris.cpp: org.caw.pack.spectral
const std::vector<BuiltinPreset>& murmurPresets();
const std::vector<BuiltinPreset>& peckPresets();
const std::vector<BuiltinPreset>& bendPresets();
const std::vector<BuiltinPreset>& irisPresets();

// Bytes per instance at `sampleRate` (the class and what it allocates), for caw_bench.
size_t murmurBytes(double sampleRate) noexcept;
size_t peckBytes(double sampleRate) noexcept;
size_t bendBytes(double sampleRate) noexcept;
size_t irisBytes(double sampleRate) noexcept;

}  // namespace fx
}  // namespace caw
