// Curlew's estimated bodies (flute, clarinet, trumpet, trombone, French horn; the saxophone its bell's radiation, chosen): the generated bands (tools/instrument_bodies.py curlew) behind bodyResponse().
#include "curlew_winds.h"

namespace caw::curlew {
namespace {
#include "curlew_bodies.inc"
// The saxophone has no free recording to estimate its body from yet. [Assumption] its bell's radiation instead: a
// bell reflects its low partials back into the bore and radiates its high ones (the bell's cutoff, as Benade describes
// it for brass and woodwinds; not re-read), so heard outside it, the bore's sound tilts up above about 1.5 kHz: two
// broad bands up, one down at 400 Hz to keep the level. Chosen, not fitted to a recording.
const BodyBand kSaxBell[] = {
    {400.0f, 0.7f, -3.0f},
    {2500.0f, 0.6f, 6.0f},
    {6000.0f, 0.8f, 3.0f},
};
}  // namespace

BodyResponse bodyResponse(int instrument) noexcept {
    switch (instrument) {
        case 0: return {kFlute, sizeof(kFlute) / sizeof(BodyBand)};
        case 1: return {kClarinet, sizeof(kClarinet) / sizeof(BodyBand)};
        case 3: return {kTrumpet, sizeof(kTrumpet) / sizeof(BodyBand)};
        case 4: return {kTrombone, sizeof(kTrombone) / sizeof(BodyBand)};
        case 5: return {kHorn, sizeof(kHorn) / sizeof(BodyBand)};
        default: return {kSaxBell, sizeof(kSaxBell) / sizeof(BodyBand)};  // the saxophone: its bell's radiation (below)
    }
}

}  // namespace caw::curlew
