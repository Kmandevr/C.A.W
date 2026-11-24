// Timber's Simulated piano: the generated hammer and soundboard tables (timber_piano_tables.inc) behind small accessors, compiled once.
#include <cstdint>

#include "timber_piano_sim.h"

namespace caw::timber::psim {
namespace {
#include "timber_piano_tables.inc"
}  // namespace

static_assert(sizeof(kHammerPulse) / sizeof(kHammerPulse[0]) == piano_curves::kZones * piano_curves::kLayers);
static_assert(sizeof(kHammerPulse[0]) / sizeof(int16_t) == piano_curves::kPulseFrames);

HammerData hammer(int zone, int layer) noexcept {
    zone = zone < 0 ? 0 : (zone >= piano_curves::kZones ? piano_curves::kZones - 1 : zone);
    layer = layer < 0 ? 0 : (layer >= piano_curves::kLayers ? piano_curves::kLayers - 1 : layer);
    const int k = zone * piano_curves::kLayers + layer;
    return {kHammerPulse[k], kHammerPeak[k], kHammerContactMs[k]};
}

BoardData boardData(int size) noexcept {
    switch (size) {
        case 0: return {24, kBoardHz24, kBoardSigma24, &kBoardC24[0][0][0]};
        case 2: return {96, kBoardHz96, kBoardSigma96, &kBoardC96[0][0][0]};
        default: return {48, kBoardHz48, kBoardSigma48, &kBoardC48[0][0][0]};
    }
}

size_t tableBytes() noexcept {
    return sizeof(kHammerPulse) + sizeof(kHammerPeak) + sizeof(kHammerContactMs) + sizeof(kBoardHz24) + sizeof(kBoardSigma24) +
           sizeof(kBoardC24) + sizeof(kBoardHz48) + sizeof(kBoardSigma48) + sizeof(kBoardC48) + sizeof(kBoardHz96) +
           sizeof(kBoardSigma96) + sizeof(kBoardC96);
}

}  // namespace caw::timber::psim
