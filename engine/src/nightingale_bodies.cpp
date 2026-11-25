// Nightingale's estimated bodies (violin, viola, cello, bass): the generated bands (tools/instrument_bodies.py nightingale) behind bodyResponse().
#include "nightingale_bowed.h"

namespace caw::nightingale {
namespace {
#include "nightingale_bodies.inc"
}  // namespace

BodyResponse bodyResponse(int instrument) noexcept {
    switch (instrument) {
        case 0: return {kViolin, sizeof(kViolin) / sizeof(BodyBand)};
        case 1: return {kViola, sizeof(kViola) / sizeof(BodyBand)};
        case 2: return {kCello, sizeof(kCello) / sizeof(BodyBand)};
        default: return {kBass, sizeof(kBass) / sizeof(BodyBand)};
    }
}

}  // namespace caw::nightingale
