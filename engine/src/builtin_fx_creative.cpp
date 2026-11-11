// The Creative and Pitch & Time effects (fx-creative): registers the eight, in the browser's order.
#include "builtin_fx_creative.h"

namespace caw::fx {

void registerCreative(ModuleRegistry& registry) {
    registerTapeStop(registry);
    registerReverser(registry);
    registerStutter(registry);
    registerPitchShift(registry);
    registerFreqShift(registry);
    registerTranceGate(registry);
    registerBitcrush(registry);
    registerRingMod(registry);
}

}  // namespace caw::fx
