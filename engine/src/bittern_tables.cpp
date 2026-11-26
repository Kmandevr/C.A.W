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
// from organ-building acoustics (Fletcher and Rossing ch. 17, Audsley), not measurements:
// - a string (Viole, Céleste) rich high up with a weaker fundamental;
// - the Great's Trumpet and the Pedal's reeds every harmonic with a formant near 1.5 kHz;
// - the French Trompette brighter and more brassy, its formant near 2.2 kHz and less taken off up high;
// - the Hautbois (a narrow, capped reed): a thin fundamental and a nasal formant near 1.2 kHz with another near 3 kHz;
// - the Krummhorn (a reed in a narrow cylinder, as a clarinet): the odd harmonics up to about 1.5 kHz, the even ones
//   weak below it;
// - the Tuba Mirabilis (a big reed on high pressure): a strong, round fundamental and harmonics falling steadily,
//   smooth up high;
// - the Kleine Erzähler (soft, tapered flue pipes): the fundamental with a clear octave and little above.
double modelled(int family, int h, double f0) {
    const double n = h, f = f0 * h;
    auto bump = [f](double at, double width) { return std::exp(-std::pow((f - at) / width, 2.0)); };
    switch (family) {
        case kString: return (h == 1 ? 0.55 : 1.0) * std::pow(n, -0.6) * (n > 24 ? std::pow(24.0 / n, 2.0) : 1.0);
        case kTrompette:
            return std::pow(n, -0.25) * (1.0 + 2.0 * bump(2200.0, 1200.0)) * (f > 5000 ? std::pow(5000.0 / f, 2.0) : 1.0);
        case kOboe:
            return (h == 1 ? 0.35 : 1.0) * std::pow(n, -0.5) * (1.0 + 3.0 * bump(1200.0, 450.0) + 1.2 * bump(3000.0, 700.0)) *
                   (f > 5000 ? std::pow(5000.0 / f, 2.0) : 1.0);
        case kKrummhorn:
            return std::pow(n, -0.7) * (h % 2 ? 1.0 : (f < 1500.0 ? 0.12 : 0.6)) * (f > 6000 ? std::pow(6000.0 / f, 1.5) : 1.0);
        case kTuba:
            return std::pow(n, -1.0) * (1.0 + 0.8 * bump(800.0, 600.0)) * (f > 4000 ? std::pow(4000.0 / f, 2.0) : 1.0);
        case kErzahler: return h == 1 ? 1.0 : h == 2 ? 0.45 : h == 3 ? 0.12 : 0.05 * std::pow(n, -2.0);
        // The orchestral strings: a bowed string's sawtooth (1/n, Helmholtz motion) through a body: the violin's air
        // and wood modes near 280 and 500 Hz and its bridge hill near 2.8 kHz, weak below its air mode; the cello's an
        // octave and more lower (air near 110 Hz, wood near 220, the bridge hill near 1.5 kHz).
        case kViolin:
            return (f < 250 ? 0.4 : 1.0) / n * (1.0 + 1.5 * bump(280.0, 80.0) + 1.2 * bump(500.0, 150.0) + 2.0 * bump(2800.0, 1000.0)) *
                   (f > 6000 ? std::pow(6000.0 / f, 2.0) : 1.0);
        case kCello:
            return 1.0 / n * (1.0 + 1.5 * bump(110.0, 40.0) + 1.5 * bump(220.0, 80.0) + 1.5 * bump(1500.0, 700.0)) *
                   (f > 4000 ? std::pow(4000.0 / f, 2.0) : 1.0);
        // The Voix Humaine: a short-resonator reed, its odd harmonics the stronger and two vowel formants (an "ah", near
        // 550 Hz and 1.5 kHz).
        case kVoixHumaine:
            return std::pow(n, -0.6) * (h % 2 ? 1.0 : 0.4) * (1.0 + 2.5 * bump(550.0, 200.0) + 1.5 * bump(1500.0, 400.0)) *
                   (f > 4000 ? std::pow(4000.0 / f, 2.0) : 1.0);
        default: {  // kReed: a trumpet's reed pipe, its harmonics steady up to the formant near 1.5 kHz and falling
                    // steeply above 3 kHz (2026-11-25, the owner: the reeds too noisy and not like real brass: they had
                    // kept a buzz up to 6 kHz)
            const double formant = 1.0 + 1.5 * bump(1500.0, 900.0);
            return std::pow(n, -0.35) * formant * (f > 3000 ? std::pow(3000.0 / f, 2.5) : 1.0);
        }
    }
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

// Two stops built on the measured families ([Assumption] by organ-building description, Audsley and Skinner's own):
// the Geigen Principal a narrow-scaled principal, its fundamental 3 dB down and its upper harmonics brighter (+2 dB an
// octave from the 2nd: "a principal with a touch of string"); the Flûte Harmonique a harmonic (double-length,
// overblown) open flute, fuller and brighter than a plain one ("almost reedy" in the treble): its 2nd to 6th
// harmonics 8 dB up.
double amplitude(int family, int z, int h, double f0) {
    if (family == kGeigen) return measured(kPrincipal, z, h) * (h == 1 ? 0.71 : std::pow(static_cast<double>(h), 0.33));
    if (family == kHarmonicFlute) return measured(kOpen, z, h) * (h >= 2 && h <= 6 ? 2.5 : 1.0);
    return family <= kPrincipal ? measured(family, z, h) : modelled(family, h, f0);
}

// The speaking spectrum against the steady one: [Measured] each family's tilt over the partial's frequency (dB per
// octave over 1 kHz: the principals' and open flutes' upper partials speak first; the stopped flute's barely
// differ), held within 18 dB. The strings take the principal's and the Erzähler the open flute's; a reed's tongue
// blares as it starts, 4 dB an octave brighter ([Assumption] all three: none was recorded).
double speakingGain(int family, double hz) {
    const int m = family == kStopped ? 0 : family == kOpen || family == kErzahler || family == kHarmonicFlute ? 1 : isReed(family) ? -1 : 2;
    const double tilt = m < 0 ? 2.0 : kTilt[m][0];  // a reed's onset 2 dB an octave brighter (it was 4: a blare)
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
    const size_t per = 2 * kTableSize;
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
                    t[2 * i] = static_cast<float>(im[i] / peak);
                    ss += static_cast<double>(t[2 * i]) * t[2 * i];
                }
                // Each value with the step to the next beside it (the interpolation's two reads at one place).
                for (uint32_t i = 0; i < kTableSize; ++i) t[2 * i + 1] = t[2 * ((i + 1) % kTableSize)] - t[2 * i];
                gRms[fam][z][kind] = static_cast<float>(std::sqrt(ss / kTableSize));
            }
}

const float* table(int family, int zone, int kind) noexcept {
    static const float silent[2 * kTableSize] = {};
    if (!gTables || family < 0 || family >= kFamilies) return silent;
    zone = std::clamp(zone, 0, kZones - 1);
    return gTables.get() + ((static_cast<size_t>(family) * kZones + zone) * kKinds + kind) * (2 * kTableSize);
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
    return gTables ? static_cast<size_t>(kFamilies) * kZones * kKinds * (2 * kTableSize) * sizeof(float) : 0;
}

double riseSeconds(double hz) noexcept { return std::clamp(kRise0 * detPow(hz / 440.0, kRiseExp), 0.015, 0.35); }
int clipCount() noexcept { return static_cast<int>(sizeof(kClips) / sizeof(kClips[0])); }
int nearestClip(int group, double key, double maxSemitones, uint64_t live) noexcept {
    int best = -1;
    double d = maxSemitones + 1e-9;
    for (int i = 0; i < static_cast<int>(sizeof(kClips) / sizeof(kClips[0])); ++i) {
        if (kClips[i].group != group || i >= 64 || !(live >> i & 1u)) continue;
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
