// Curlew's estimated bodies (flute, clarinet, trumpet, trombone, French horn; the saxophone flat): the generated bands (tools/instrument_bodies.py curlew) behind bodyResponse().
#include "curlew_winds.h"

namespace caw::curlew {
namespace {
#include "curlew_bodies.inc"
}  // namespace

BodyResponse bodyResponse(int instrument) noexcept {
    switch (instrument) {
        case 0: return {kFlute, sizeof(kFlute) / sizeof(BodyBand)};
        case 1: return {kClarinet, sizeof(kClarinet) / sizeof(BodyBand)};
        case 3: return {kTrumpet, sizeof(kTrumpet) / sizeof(BodyBand)};
        case 4: return {kTrombone, sizeof(kTrombone) / sizeof(BodyBand)};
        case 5: return {kHorn, sizeof(kHorn) / sizeof(BodyBand)};
        default: return {nullptr, 0};  // the saxophone: no free recording to estimate it from yet
    }
}

}  // namespace caw::curlew
