// Bittern's rank tables: each stop's family spectrum per zone, band-limited and summed with seeded phases, built once per process (read-only after).
#include <cmath>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

#include "bittern_organ.h"
#include "caw/detmath.hpp"
#include "caw/library/convolver.hpp"  // lib::Fft

namespace caw::bittern {
namespace {

constexpr double kTwoPiD = 6.283185307179586;
std::unique_ptr<float[]> gTables;
std::once_flag gOnce;

// Harmonic h's amplitude (of the rank's own fundamental at `f0` Hz) for each stop's family. [Assumption] shapes from
// organ-building acoustics (Fletcher and Rossing ch. 17), not measurements: a principal is full and bright, an open
// flute mostly its fundamental, a stopped flute (Bourdon, Rohrflöte, Subbass) its odd harmonics, a string (Gamba,
// Céleste) rich high up with a weaker fundamental, a reed (Trumpet) every harmonic with a formant near 1.5 kHz.
double amplitude(int stop, int h, double f0) {
    const double n = h, f = f0 * h;
    switch (stop) {
        case kPrincipal8: case kOctave4: case kFifteenth2:
            return std::pow(n, -1.1) * (n > 8 ? std::pow(8.0 / n, 0.8) : 1.0);
        case kFlute4: case kNazard: case kTierce:  // open flutes and the flute mutations
            return h == 1 ? 1.0 : (h == 2 ? 0.3 : 0.1 * std::pow(n, -2.0));
        case kBourdon16: case kRohrflute8: case kSubbass32:  // stopped: the odd harmonics
            return h % 2 ? std::pow(n, -1.4) : 0.03 * std::pow(n, -1.4);
        case kGamba8: case kCeleste8:
            return (h == 1 ? 0.55 : 1.0) * std::pow(n, -0.6) * (n > 24 ? std::pow(24.0 / n, 2.0) : 1.0);
        case kTrumpet8: {
            const double formant = 1.0 + 2.0 * std::exp(-std::pow((f - 1500.0) / 900.0, 2.0));
            return std::pow(n, -0.35) * formant * (f > 6000 ? std::pow(6000.0 / f, 1.5) : 1.0);
        }
        default: return 0.0;
    }
}

// The mixture's ranks as multiples of the 8' pitch in zone z: 2', 1 1/3', 1', 2/3' (4, 6, 8, 12), breaking back an
// octave each time the top rank would pass about 8 kHz at the zone's lowest key (a real mixture's repeats).
int mixtureRanks(int z, int* out) {
    double mult[4] = {4, 6, 8, 12};
    const double low = 440.0 * std::pow(2.0, (21.0 + 8.0 * z - 69.0) / 12.0);
    while (low * mult[3] > 8000.0 && mult[0] > 1) {
        for (double& m : mult) m *= 0.5;
    }
    int k = 0;
    for (double m : mult)
        if (m >= 1 && m == std::floor(m)) out[k++] = static_cast<int>(m);
    return k;
}

void build() {
    const size_t per = kTableSize + 1;
    gTables.reset(new (std::nothrow) float[static_cast<size_t>(kStops) * kZones * per]());
    if (!gTables) return;
    const double nyq = 0.45 * 44100.0;  // band-limited for 44.1 kHz and up (a little duller at higher rates)
    lib::Fft fft;
    fft.prepare(kTableSize);
    std::vector<double> re(kTableSize), im(kTableSize);
    for (int s = 0; s < kStops; ++s)
        for (int z = 0; z < kZones; ++z) {
            float* t = gTables.get() + (static_cast<size_t>(s) * kZones + z) * per;
            const double topKey = 21.0 + 8.0 * z + 8.0;  // the zone's highest pitch sets the band limit
            const double f8 = 440.0 * std::pow(2.0, (topKey - 69.0) / 12.0);
            const double fMid = 440.0 * std::pow(2.0, (21.0 + 8.0 * z + 4.0 - 69.0) / 12.0);
            // The spectrum, then one inverse FFT: x[i] = Im(sum X[m] e^(j 2 pi m i / N)) = sum a sin(2 pi m i / N + ph).
            std::fill(re.begin(), re.end(), 0.0);
            std::fill(im.begin(), im.end(), 0.0);
            uint32_t seed = 0x51EDu + 131u * s + 17u * z;
            auto rnd = [&seed] {
                seed = seed * 1664525u + 1013904223u;
                return (seed >> 8) * (1.0 / 16777216.0);
            };
            auto addRank = [&](int family, double mult, double gain) {
                for (int h = 1; h < static_cast<int>(kTableSize / 2); ++h) {
                    const double harm = mult * h;  // the table's own harmonic (its base is the stop's foot pitch)
                    if (f8 * kFoot[s] * harm > nyq || harm >= kTableSize / 2) break;
                    const double a = gain * amplitude(family, h, fMid * kFoot[s] * mult);
                    const double ph = kTwoPiD * rnd();
                    if (a < 1e-5) continue;
                    const uint32_t m = static_cast<uint32_t>(harm);
                    re[m] += a * std::cos(ph), im[m] += a * std::sin(ph);
                }
            };
            if (s == kMixture) {
                int ranks[4];
                const int n = mixtureRanks(z, ranks);
                for (int k = 0; k < n; ++k) addRank(kPrincipal8, ranks[k], 0.6);
            } else {
                addRank(s, 1.0, 1.0);
            }
            fft.inverse(re.data(), im.data());
            const std::vector<double>& acc = im;
            double peak = 1e-9;
            for (uint32_t i = 0; i < kTableSize; ++i) peak = std::max(peak, std::fabs(acc[i]));
            for (uint32_t i = 0; i < kTableSize; ++i) t[i] = static_cast<float>(acc[i] / peak);
            t[kTableSize] = t[0];
        }
}

}  // namespace

void buildTables() noexcept {
    try {
        std::call_once(gOnce, build);
    } catch (...) {
    }
}
const float* rankTable(int stop, int zone) noexcept {
    static const float silent[kTableSize + 1] = {};
    if (!gTables) return silent;
    return gTables.get() + (static_cast<size_t>(stop) * kZones + zone) * (kTableSize + 1);
}
size_t tableBytes() noexcept { return gTables ? static_cast<size_t>(kStops) * kZones * (kTableSize + 1) * sizeof(float) : 0; }

}  // namespace caw::bittern
