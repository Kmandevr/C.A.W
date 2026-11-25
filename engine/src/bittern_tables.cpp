// Bittern's rank tables (each pipe family's measured or modelled spectrum per zone, steady and speaking, band-limited and summed with seeded phases, built once per process and read-only after) and its measured speech data.
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

#include "bittern_organ.h"
#include "caw/detmath.hpp"
#include "caw/library/convolver.hpp"  // lib::Fft

namespace caw::bittern {
namespace {

#include "bittern_bank.inc"

constexpr double kTwoPiD = 6.283185307179586;
constexpr int kKinds = 2;  // steady, speaking
std::unique_ptr<float[]> gTables;
float gRms[kFamilies][kZones][kKinds] = {};
std::once_flag gOnce;

double hzOf(double key) { return 440.0 * std::pow(2.0, (key - 69.0) / 12.0); }

// Harmonic h's amplitude (of the pipe's own fundamental f0) for the families nothing measured. [Assumption] shapes
// from organ-building acoustics (Fletcher and Rossing ch. 17): a string (Gamba, Céleste) rich high up with a weaker
// fundamental, a reed (Trumpet) every harmonic with a formant near 1.5 kHz.
double modelled(int family, int h, double f0) {
    const double n = h, f = f0 * h;
    if (family == kString) return (h == 1 ? 0.55 : 1.0) * std::pow(n, -0.6) * (n > 24 ? std::pow(24.0 / n, 2.0) : 1.0);
    const double formant = 1.0 + 2.0 * std::exp(-std::pow((f - 1500.0) / 900.0, 2.0));
    return std::pow(n, -0.35) * formant * (f > 6000 ? std::pow(6000.0 / f, 1.5) : 1.0);
}

// A measured family's harmonic h in zone z (bittern_bank.inc's 32; past them, the slope of harmonics 16..32 in
// log-log carried on, at least 6 dB an octave down).
double measured(int family, int z, int h) {
    const float* a = kMeasured[family][z];
    if (h <= kMeasuredHarmonics) return a[h - 1];
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    int n = 0;
    for (int k = 16; k <= kMeasuredHarmonics; ++k) {
        const double x = std::log(static_cast<double>(k)), y = std::log(std::max(1e-6, static_cast<double>(a[k - 1])));
        sx += x, sy += y, sxx += x * x, sxy += x * y, ++n;
    }
    const double slope = std::min(-1.0, (n * sxy - sx * sy) / (n * sxx - sx * sx));
    return a[kMeasuredHarmonics - 1] * std::pow(static_cast<double>(h) / kMeasuredHarmonics, slope);
}

double amplitude(int family, int z, int h, double f0) {
    return family <= kPrincipal ? measured(family, z, h) : modelled(family, h, f0);
}

// The speaking spectrum against the steady one: [Measured] each family's tilt over the partial's frequency (dB per
// octave over 1 kHz: the principals' and open flutes' upper partials speak first; the stopped flute's barely
// differ), held within 18 dB. The strings take the principal's; the reed's tongue blares as it starts, 4 dB an
// octave brighter ([Assumption] both: neither was recorded).
double speakingGain(int family, double hz) {
    const int m = family == kStopped ? 0 : family == kOpen ? 1 : family == kReed ? -1 : 2;
    const double tilt = m < 0 ? 4.0 : kTilt[m][0];
    const double db = std::clamp(tilt * std::log2(hz / 1000.0), -18.0, 18.0);
    return std::pow(10.0, db / 20.0);
}

// The mixture's ranks as multiples of the 8' pitch in zone z: 2', 1 1/3', 1', 2/3' (4, 6, 8, 12), breaking back an
// octave each time the top rank would pass about 8 kHz at the zone's lowest key (a real mixture's repeats).
int mixtureRanks(int z, int* out) {
    double mult[4] = {4, 6, 8, 12};
    const double low = hzOf(12.0 + 6.0 * z);
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
    gTables.reset(new (std::nothrow) float[static_cast<size_t>(kFamilies) * kZones * kKinds * per]());
    if (!gTables) return;
    const double nyq = 0.45 * 44100.0;  // band-limited for 44.1 kHz and up (a little duller at higher rates)
    lib::Fft fft;
    fft.prepare(kTableSize);
    std::vector<double> re(kTableSize), im(kTableSize);
    for (int fam = 0; fam < kFamilies; ++fam)
        for (int z = 0; z < kZones; ++z)
            for (int kind = 0; kind < kKinds; ++kind) {
                float* t = gTables.get() + ((static_cast<size_t>(fam) * kZones + z) * kKinds + kind) * per;
                const double top = hzOf(12.0 + 6.0 * (z + 1));  // the zone's highest pitch sets the band limit
                const double mid = hzOf(12.0 + 6.0 * z + 3.0);
                // The spectrum, then one inverse FFT: x[i] = Im(sum X[m] e^(j 2 pi m i / N)). The phases are seeded
                // per family and zone (the same for both kinds, so the speaking table fades into the steady one).
                std::fill(re.begin(), re.end(), 0.0);
                std::fill(im.begin(), im.end(), 0.0);
                uint32_t seed = 0x51EDu + 131u * fam + 17u * z;
                auto rnd = [&seed] {
                    seed = seed * 1664525u + 1013904223u;
                    return (seed >> 8) * (1.0 / 16777216.0);
                };
                auto addRank = [&](int family, int zone, double mult, double gain) {
                    for (int h = 1; h < static_cast<int>(kTableSize / 2); ++h) {
                        const double harm = mult * h;
                        const double ph = kTwoPiD * rnd();
                        if (top * harm > nyq || harm >= kTableSize / 2) break;
                        double a = gain * amplitude(family, zone, h, mid * mult);
                        if (kind == 1) a *= speakingGain(family, mid * harm);
                        if (a < 1e-5) continue;
                        const uint32_t m = static_cast<uint32_t>(harm);
                        re[m] += a * std::cos(ph), im[m] += a * std::sin(ph);
                    }
                };
                if (fam == kMixtureFamily) {
                    int ranks[4];
                    const int n = mixtureRanks(z, ranks);
                    for (int k = 0; k < n; ++k) {
                        const int zr = std::clamp(z + static_cast<int>(std::lround(2.0 * std::log2(ranks[k]))), 0, kZones - 1);
                        addRank(kPrincipal, zr, ranks[k], 0.6);
                    }
                } else {
                    addRank(fam, z, 1.0, 1.0);
                }
                fft.inverse(re.data(), im.data());
                double peak = 1e-9;
                for (uint32_t i = 0; i < kTableSize; ++i) peak = std::max(peak, std::fabs(im[i]));
                double ss = 0;
                for (uint32_t i = 0; i < kTableSize; ++i) {
                    t[i] = static_cast<float>(im[i] / peak);
                    ss += static_cast<double>(t[i]) * t[i];
                }
                t[kTableSize] = t[0];
                gRms[fam][z][kind] = static_cast<float>(std::sqrt(ss / kTableSize));
            }
}

const float* table(int family, int zone, int kind) noexcept {
    static const float silent[kTableSize + 1] = {};
    if (!gTables || family < 0 || family >= kFamilies) return silent;
    zone = std::clamp(zone, 0, kZones - 1);
    return gTables.get() + ((static_cast<size_t>(family) * kZones + zone) * kKinds + kind) * (kTableSize + 1);
}

}  // namespace

void buildTables() noexcept {
    try {
        std::call_once(gOnce, build);
    } catch (...) {
    }
}
const float* steadyTable(int family, int zone) noexcept { return table(family, zone, 0); }
const float* speakingTable(int family, int zone) noexcept { return table(family, zone, 1); }
float tableRms(int family, int zone) noexcept {
    if (!gTables || family < 0 || family >= kFamilies) return 0.0f;
    return gRms[family][std::clamp(zone, 0, kZones - 1)][0];
}
size_t tableBytes() noexcept {
    return gTables ? static_cast<size_t>(kFamilies) * kZones * kKinds * (kTableSize + 1) * sizeof(float) : 0;
}

double riseSeconds(double hz) noexcept { return std::clamp(kRise0 * detPow(hz / 440.0, kRiseExp), 0.015, 0.35); }
int nearestClip(int group, double key, double maxSemitones) noexcept {
    int best = -1;
    double d = maxSemitones + 1e-9;
    for (int i = 0; i < static_cast<int>(sizeof(kClips) / sizeof(kClips[0])); ++i) {
        if (kClips[i].group != group) continue;
        const double e = std::fabs(key - kClips[i].key);
        if (e <= d) d = e, best = i;
    }
    return best;
}
ClipInfo clipInfo(int clip) noexcept {
    const SpeechClip& c = kClips[clip];
    return {c.key, c.first, c.frames, c.scale};
}
double noiseDb() noexcept { return kNoiseDb; }
double wanderCents() noexcept { return kWanderCents; }
double wanderDb() noexcept { return kWanderDb; }

}  // namespace caw::bittern
