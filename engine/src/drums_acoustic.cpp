// Rook's Acoustic engine (1.1.2): modal drum heads and cymbal plates struck by simulated sticks, lumped snare wires, a colliding hi-hat, mics and bleed.
#include "drums_acoustic.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>

#include "caw/detmath.hpp"
#include "caw/library/fastmath.hpp"

// Original code (C.A.W. is Apache-2.0), after published models, in our own words in docs/engine.md ("Drums",
// Acoustic): modal membranes (Rossing 1992), two heads coupled through the enclosed air and energy-based tension
// modulation (Avanzini and Marogna 2010; Avanzini, Marogna and Bank 2012), Hunt-Crossley stick contact, lumped
// snare wires colliding one-sidedly with the snare-side head (after Ducceschi, Hamilton and Russo 2023; Torin,
// Hamilton and Bilbao 2014), cymbals as modal plates with a sparse quadratic coupling (after the modal von Karman
// reduction of Ducceschi and Touze 2015). No other instrument's code was used.
//
// How it runs:
// - A piece is one physical object: striking it again adds to its motion (a real drum keeps ringing when re-hit).
// - Every mode is a two-pole resonator in float, structure of arrays; contacts (sticks, rim, wires, the hat's
//   plates) are stepped every sample only while they can touch, each with a linearly implicit force (the force
//   solved together with the response it causes), so stiff contacts stay stable.
// - A piece sleeps after its output stays below -100 dBFS for a quarter second: silent pieces cost nothing.
// - The sympathetic drive (kick and toms buzzing the snare) reads the kit's sum kRing / 2 frames back, so the
//   result does not depend on the block size.

namespace caw::drums::acoustic {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr double kTwoPi = 2.0 * kPi;
constexpr uint32_t kLag = kRing / 2;
// Tuned against the realism tests (drums_acoustic_test.cpp): the wires' rattle (Normal and Eco), the cascade's
// strength and the hat plates' clamping loss (per newton of contact).
constexpr float kRattle = 150.0f, kRattleEco = 150.0f, kSwellScale = 4.0f, kHatDamp = 6.0f;
// the sympathetic drive's delay (frames): 16, the longest chunk

double clampd(double v, double lo, double hi) noexcept {
    if (!(v == v)) return lo;
    return v < lo ? lo : (v > hi ? hi : v);
}
double dbGain(double db) noexcept { return db <= -59.999 ? 0.0 : lib::dbToGain(db); }
double cosr(double r) noexcept { return lib::fastSinCycles(r * (1.0 / kTwoPi) + 0.25); }

// J_m(x) by its power series (x <= 24 here; double keeps 1e-8 of it).
double besselJ(int m, double x) noexcept {
    double t = 1.0;
    for (int k = 1; k <= m; ++k) t *= x * 0.5 / k;
    double sum = 0.0;
    const double q = x * x * 0.25;
    for (int k = 0; k < 100; ++k) {
        sum += t;
        t *= -q / ((k + 1.0) * (k + 1.0 + m));
        if (std::fabs(t) < 1e-18 && k > 2 * x) break;
    }
    return sum;
}

// The ideal membrane's modes: the zeros j(m, n) of J_m in ascending order, with m and n (computed once, by
// bisection; AcousticKit::prepare builds it, off the audio thread).
struct MembraneTable {
    static constexpr uint32_t kCount = 64;
    double zero[kCount];
    int m[kCount], n[kCount];
    MembraneTable() {
        struct Z {
            double z;
            int m, n;
        };
        Z all[18 * 8];
        uint32_t count = 0;
        for (int mm = 0; mm < 18; ++mm) {
            int found = 0;
            double a = mm + 0.5, fa = besselJ(mm, a);
            for (double b = a + 0.05; b < 24.5 && found < 8; b += 0.05) {
                const double fb = besselJ(mm, b);
                if ((fa < 0.0) != (fb < 0.0)) {
                    double lo = b - 0.05, hi = b, flo = fa;
                    for (int it = 0; it < 60; ++it) {
                        const double mid = 0.5 * (lo + hi), fm = besselJ(mm, mid);
                        if ((fm < 0.0) == (flo < 0.0)) lo = mid, flo = fm;
                        else hi = mid;
                    }
                    all[count++] = {0.5 * (lo + hi), mm, ++found};
                }
                a = b;
                fa = fb;
            }
        }
        std::sort(all, all + count, [](const Z& x, const Z& y) { return x.z < y.z; });
        for (uint32_t k = 0; k < kCount; ++k) zero[k] = all[k].z, m[k] = all[k].m, n[k] = all[k].n;
    }
};
const MembraneTable& membrane() {
    static const MembraneTable t;
    return t;
}

// The modal kernels (structure of arrays, no aliasing: they vectorize). y = (a1 y1 - a2 y2) d is a mode's next
// displacement before new forces; the radiated sum is the weighted velocity sum w (y - y1).
inline void predictModes(uint32_t n, const float* __restrict a1, const float* __restrict a2, const float* __restrict y1,
                         const float* __restrict y2, float* __restrict yp) noexcept {
    for (uint32_t k = 0; k < n; ++k) yp[k] = a1[k] * y1[k] - a2[k] * y2[k];
}
inline float dotModes(uint32_t n, const float* __restrict a, const float* __restrict b) noexcept {
    float s = 0.0f;
    for (uint32_t k = 0; k < n; ++k) s += a[k] * b[k];
    return s;
}
inline void addModes(uint32_t n, float* __restrict y, const float* __restrict phi, float c) noexcept {
    for (uint32_t k = 0; k < n; ++k) y[k] += c * phi[k];
}
inline float commitModes(uint32_t n, const float* __restrict yp, float* __restrict y1, float* __restrict y2,
                         const float* __restrict w) noexcept {
    float out = 0.0f;
    for (uint32_t k = 0; k < n; ++k) {
        out += w[k] * (yp[k] - y1[k]);
        y2[k] = y1[k];
        y1[k] = yp[k];
    }
    return out;
}
inline float stepModes(uint32_t n, const float* __restrict a1, const float* __restrict a2, float* __restrict y1,
                       float* __restrict y2, const float* __restrict w) noexcept {
    float out = 0.0f;
    for (uint32_t k = 0; k < n; ++k) {
        const float y = a1[k] * y1[k] - a2[k] * y2[k];
        out += w[k] * (y - y1[k]);
        y2[k] = y1[k];
        y1[k] = y;
    }
    return out;
}

// Whether a stick moves this frame: a delayed one (a flam's main stroke, a roll's next) waits its frames out first.
inline bool due(Striker& s) noexcept {
    if (!s.active) return false;
    if (s.delay == 0) return true;
    --s.delay;
    return false;
}

uint32_t hash(uint32_t x) noexcept {
    x ^= x >> 16;
    x *= 0x7feb352du;
    x ^= x >> 15;
    x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}
float unit(uint32_t& s) noexcept {  // -1..1
    s = hash(s + 0x9e3779b9u);
    return static_cast<float>(s) * (2.0f / 4294967295.0f) - 1.0f;
}

// The top hat plate's height above the bottom one (m) for a pedal 0 (open) .. 1 (closed, pressed): the MIDI
// foot controller's direction (CC 4: open to closed, Roland's V-Drums MIDI implementation).
float pedalHeight(double pedal) noexcept {
    const double q = pedal < 0.0 ? 0.0 : (pedal > 1.0 ? 1.0 : pedal);
    return static_cast<float>(0.010 * (1.0 - q) * (1.0 - q) - 0.0015 * q * q * q * q);
}

// Modes per tier (Eco, Normal, High).
struct Counts {
    uint32_t batter, reso, shell;
};
Counts drumCounts(int kind, int q) noexcept {
    static constexpr Counts kKick[3] = {{12, 4, 2}, {24, 8, 4}, {48, 16, 8}};
    static constexpr Counts kSnare[3] = {{16, 8, 4}, {32, 12, 6}, {48, 16, 8}};
    static constexpr Counts kTom[3] = {{12, 4, 2}, {24, 8, 4}, {48, 16, 8}};
    const Counts* c = kind == kPieceKick ? kKick : (kind == kPieceSnare ? kSnare : kTom);
    return c[q < 0 ? 0 : (q > 2 ? 2 : q)];
}

}  // namespace

// ---------- Setup ----------

bool AcousticKit::prepare(double sampleRate) {
    sr_ = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
    dt_ = 1.0 / sr_;
    (void)membrane();  // built here, not on the audio thread
    ohLength_ = static_cast<uint32_t>(sr_ * 0.008) + 4;
    oh_.assign(static_cast<size_t>(ohLength_) * kPieces, 0.0f);
    bleedDelay_ = static_cast<uint32_t>(sr_ * 0.0015) + 1;
    bleed_.assign(bleedDelay_ + kCell + 1, 0.0f);
    for (Piece& p : pieces_) p = Piece{};
    level_ = static_cast<float>(dbGain(kit_.level));
    bleedGain_ = static_cast<float>(kit_.bleed);
    reset();
    return true;
}

void AcousticKit::reset() noexcept {
    for (uint32_t i = 0; i < kPieces; ++i) {
        Piece& p = pieces_[i];
        const PieceSettings s = p.set;
        const int q = p.quality;
        const bool was = p.configured;
        p = Piece{};
        p.set = s;
        p.quality = q;
        p.rng = 0x51ed0000u + i * 7919u;
        p.symp = static_cast<float>(kit_.sympathy);
        if (was) configure(p);
    }
    std::fill(oh_.begin(), oh_.end(), 0.0f);
    std::fill(bleed_.begin(), bleed_.end(), 0.0f);
    std::fill(ring_, ring_ + kRing, 0.0f);
    awake_ = 0;
    clock_ = 0;
    cellFrames_ = 0;
    ohAt_ = bleedAt_ = 0;
}

void AcousticKit::setKit(const KitSettings& k) noexcept {
    if (k == kit_) return;
    if (std::fabs(k.hatPedal - kit_.hatPedal) > 0.005)  // the pedal (CC 4) moved: it decides the hat again
        for (Piece& p : pieces_) p.hatOverride = -1;
    const bool micsMoved = k.mics != kit_.mics || k.bleed != kit_.bleed || k.room != kit_.room || k.level != kit_.level;
    kit_ = k;
    level_ = static_cast<float>(dbGain(k.level));
    bleedGain_ = static_cast<float>(k.bleed);
    if (micsMoved)
        for (Piece& p : pieces_)
            if (p.configured) mics(p);
    for (Piece& p : pieces_) p.symp = static_cast<float>(k.sympathy);
}

void AcousticKit::setPiece(uint32_t piece, const PieceSettings& s, int quality) noexcept {
    if (piece >= kPieces) return;
    Piece& p = pieces_[piece];
    if (p.configured && s == p.set && quality == p.quality) return;
    const bool structural = !p.configured || s.kind != p.set.kind || quality != p.quality;
    p.set = s;
    p.quality = quality;
    if (structural) {  // the kind or the tier: the piece starts over, silent
        const uint32_t bit = 1u << piece;
        const PieceSettings keep = s;
        const uint32_t seed = p.rng;
        p = Piece{};
        p.set = keep;
        p.quality = quality;
        p.rng = seed;
        awake_ &= ~bit;
    }
    configure(p);
    p.symp = static_cast<float>(kit_.sympathy);
}

void AcousticKit::configure(Piece& p) noexcept {
    p.configured = true;
    p.seg[0] = p.seg[1] = p.seg[2] = Segment{};
    p.wires = 0;
    p.rattleGain = 0.0f;  // the wires (or Eco's stand-in) only while a snare has them on
    p.glideK = 0.0f;
    p.airK = 0.0f;
    p.swellGain = 0.0f;
    if (!isCymbalPiece(p.set.kind)) p.triplets = 0;
    if (isDrumPiece(p.set.kind)) configureDrum(p);
    else if (p.set.kind != kPieceOff) configureCymbal(p);
    mics(p);
}

double AcousticKit::modeHz(uint32_t piece, uint32_t s, uint32_t k) const noexcept {
    const Piece& p = pieces_[piece < kPieces ? piece : 0];
    if (s > 2 || k >= p.seg[s].count) return 0.0;
    return p.om[p.seg[s].at + k] * sr_ / kTwoPi;
}

// One run of modes: frequency, T60 and radiation per mode -> the resonator's coefficients.
static void setMode(Piece& p, uint32_t i, double hz, double t60, double weight, double sr) noexcept {
    const double nyq = 0.45 * sr;
    if (hz > nyq) weight = 0.0, hz = nyq;  // above the band: kept silent (its weight 0) so counts stay fixed
    const double om = kTwoPi * hz / sr;
    const double r = std::exp(-6.907755278982137 / (std::max(t60, 0.005) * sr));
    p.om[i] = static_cast<float>(om);
    p.rr[i] = static_cast<float>(r);
    p.a1[i] = p.a1b[i] = static_cast<float>(2.0 * r * cosr(om));
    p.a2[i] = p.a2b[i] = static_cast<float>(r * r);
    p.w[i] = static_cast<float>(weight);
}

void AcousticKit::configureDrum(Piece& p) noexcept {
    const PieceSettings& s = p.set;
    const MembraneTable& mt = membrane();
    const Counts c = drumCounts(s.kind, p.quality);
    p.seg[0] = {0, c.batter, 0, 1};
    p.seg[1] = {c.batter, c.reso, 0, 1};
    p.seg[2] = {c.batter + c.reso, c.shell, 0, 1};
    const double size = clampd(s.size, 6, 26), depth = clampd(s.depth, 3, 22), a = size * 0.0254 * 0.5;
    // The batter's (0,1) mode: from the size and the tuning (Hz).
    double f01 = naturalHz(s.kind, size);
    f01 *= std::exp2(clampd(s.tune, -24, 24) / 12.0);
    const double fReso = f01 * std::exp2(clampd(s.reso, -12, 12) / 12.0) * (s.kind == kPieceSnare ? 1.45 : 1.0);
    // Heads: areal density (kg/m^2), decay and brightness.
    static constexpr double kDensity[] = {0.27, 0.25, 0.5, 0.48, 0.45};
    static constexpr double kT60[] = {0.85, 1.1, 0.6, 0.75, 0.5};
    static constexpr double kBright[] = {0.8, 1.25, 0.6, 0.8, 0.45};
    const int head = static_cast<int>(clampd(s.head, 0, 4));
    const double damp = clampd(s.damp, 0, 1), decay = clampd(s.decay, 0.25, 4);
    double t0 = (s.kind == kPieceKick ? 0.5 : (s.kind == kPieceSnare ? 0.6 : 0.9 * size / 12.0)) * kT60[head] * decay *
                (1.0 - 0.8 * damp);
    const double fd = 700.0 * kBright[head] * (1.0 - 0.5 * damp);
    const double mass = kDensity[head] * kPi * a * a * 0.27;  // per mode
    const double air = clampd(s.air, 0, 1);
    auto membraneRun = [&](const Segment& sg, double f, double t60, double massScale) {
        for (uint32_t k = 0; k < sg.count; ++k) {
            const uint32_t i = sg.at + k;
            const double ratio = mt.zero[k] / mt.zero[0];
            // Air loading (Christian et al. 1984): the low modes carry more of the air's mass, so the (m,1) family
            // moves toward harmonic. [Assumption] its size: mu = 1.0 * air / ratio^2, the (0,1) mode kept on pitch.
            const double mu = air / (ratio * ratio), mu0 = air;
            const double hz = f * ratio * std::sqrt((1.0 + mu0) / (1.0 + mu));
            const int m = mt.m[k];
            const double weight = m == 0 ? 1.0 / mt.n[k] : 0.3 / m;
            setMode(p, i, hz, t60 / (1.0 + hz / fd), weight, sr_);
            p.ratio[i] = static_cast<float>(hz / f);
            p.order[i] = m;
            p.strain[i] = static_cast<float>(mt.zero[k] * mt.zero[k] / (a * a));
        }
        (void)massScale;
    };
    // Eco has no wires to take energy out of the heads: their damping stands in for it.
    const bool ecoWires = s.kind == kPieceSnare && p.quality == 0 && s.wires > 0.0;
    membraneRun(p.seg[0], f01, ecoWires ? t0 * 0.45 : t0, 1.0);
    const bool port = s.kind == kPieceKick && s.port;  // a kick's resonant head can have a port
    double resoT = t0 * (port ? 0.4 : 1.3);
    if (ecoWires) resoT *= 0.25;
    membraneRun(p.seg[1], fReso, resoT, 1.0);
    for (uint32_t k = 0; k < p.seg[1].count; ++k) p.w[p.seg[1].at + k] *= 0.6f;  // the resonant head radiates less
    p.seg[0].g = static_cast<float>(dt_ * dt_ / mass);
    p.seg[1].g = static_cast<float>(dt_ * dt_ / (mass * (s.kind == kPieceSnare ? 0.35 : 0.9)));  // a snare-side head is thin
    // The shell: a few modes from the material, driven by the rim and the bearing edge.
    static constexpr double kShellHz[] = {520, 600, 430, 560, 900, 820, 480};
    static constexpr double kShellT60[] = {0.12, 0.1, 0.14, 0.11, 0.45, 0.4, 0.15};
    static constexpr double kShellRatio[] = {1.0, 1.62, 2.31, 3.08, 3.95, 4.9, 5.9, 7.0};
    const int shell = static_cast<int>(clampd(s.shell, 0, 6));
    const double fs = kShellHz[shell] * 14.0 / size * std::pow(6.5 / depth, 0.25);
    for (uint32_t k = 0; k < p.seg[2].count; ++k) {
        const uint32_t i = p.seg[2].at + k;
        setMode(p, i, fs * kShellRatio[k], kShellT60[shell] / (1.0 + 0.2 * k), clampd(s.shellLevel, 0, 1) * 6.0 / (1.0 + k), sr_);
        p.ratio[i] = static_cast<float>(kShellRatio[k]);
    }
    p.seg[2].g = static_cast<float>(dt_ * dt_ / 0.15);
    // The bearing edge's weights (r = 0.97): where the rim and the shell meet the head.
    for (uint32_t k = 0; k < p.seg[0].count; ++k) p.phiEdge[k] = static_cast<float>(besselJ(mt.m[k], mt.zero[k] * 0.97));
    // The heads' (0,1) modes coupled through the enclosed air: a spring k = c M w01^2, stiffer when shallow.
    const double w01 = kTwoPi * f01;
    p.airK = static_cast<float>(0.6 * mass * w01 * w01 * (6.5 / depth) * (port ? 0.3 : 1.0) * (s.kind == kPieceKick ? 0.7 : 1.0));
    // Glide: frequencies x (1 + glideK E), E the strain energy of the low modes (sum of (j/a)^2 A^2).
    p.glideK = static_cast<float>(clampd(s.glide, 0, 1) * 60.0);
    // Snare wires.
    if (s.kind == kPieceSnare && s.wires > 0.0) {
        const uint32_t count = p.quality == 0 ? 0 : (p.quality == 2 ? 16 : 8);
        p.wires = count;
        const double tension = clampd(s.wires, 0, 1);
        p.wMass = static_cast<float>(0.02 / (count ? count : 8));
        const double wom = kTwoPi * (40.0 + 140.0 * tension);
        p.wOm2 = static_cast<float>(wom * wom);
        p.wDampK = static_cast<float>(2.0 * 0.08 * wom);
        p.wRest = static_cast<float>(-(0.00001 + 0.00006 * tension));  // pressed into the head (inside: negative)
        p.wK = 5.0e7f;  // thin steel: stiff collisions, broadband clicks
        const uint32_t modes = std::min<uint32_t>(kResoWireModes, p.seg[1].count);
        for (uint32_t wi = 0; wi < count; ++wi) {
            const double x = -0.6 + 1.2 * (wi + 0.5) / count;
            const double r = std::fabs(x) + 0.04;
            double sum = 0.0;
            for (uint32_t k = 0; k < kResoWireModes; ++k) {
                double v = 0.0;
                if (k < modes) {
                    v = besselJ(mt.m[k], mt.zero[k] * r);
                    if (x < 0.0 && (mt.m[k] & 1)) v = -v;
                }
                p.psiT[k][wi] = static_cast<float>(v);
                sum += v * v;
            }
            p.wC[wi] = static_cast<float>(dt_ * dt_ / p.wMass + p.seg[1].g * sum);
        }
        p.rattleK = static_cast<float>(std::exp(-kTwoPi * 3000.0 / sr_));
        p.rattleGain = static_cast<float>(dbGain(clampd(s.wireLevel, -24, 12)) * 0.05 * (0.4 + tension) * kRattle);
    }
    if (s.kind == kPieceSnare && p.quality == 0 && s.wires > 0.0)  // Eco: a gated noise for the wires
        p.rattleGain = static_cast<float>(dbGain(clampd(s.wireLevel, -24, 12)) * 0.6 * (0.4 + clampd(s.wires, 0, 1)) * kRattleEco);
    p.rattleK = static_cast<float>(std::exp(-kTwoPi * 3000.0 / sr_));
    p.gain = static_cast<float>(s.kind == kPieceKick ? 0.14 : (s.kind == kPieceSnare ? 0.12 : 0.12));
}

void AcousticKit::configureCymbal(Piece& p) noexcept {
    const PieceSettings& s = p.set;
    const int q = p.quality < 0 ? 0 : (p.quality > 2 ? 2 : p.quality);
    const double size = clampd(s.size, 6, 26);
    const bool hat = s.kind == kPieceHiHat;
    // Plate modes: f_k = f0 (1 + b k)^g up to the top of the kind's band (Rossing's cymbal modes are dense and
    // grow a little faster than linearly); a fixed per-mode jitter keeps them inharmonic.
    static constexpr uint32_t kCount[3] = {32, 64, 128};
    const uint32_t total = kCount[q];
    const uint32_t top = hat ? total / 2 : total, bottom = hat ? total / 2 : 0;
    double f0 = 3300.0 / size * std::exp2(clampd(s.tune, -24, 24) / 12.0);
    double fTop = 14000.0, gamma = 1.2, tLow = 6.0 * size / 18.0, fDec = 2200.0, ref = 18.0;
    switch (s.kind) {
        case kPieceRide: fTop = 12000.0, tLow = 11.0 * size / 21.0, fDec = 3000.0, f0 *= 0.95, ref = 21.0; break;
        case kPieceSplash: fTop = 16000.0, tLow = 2.6 * size / 10.0, fDec = 2600.0, ref = 10.0; break;
        case kPieceChina: fTop = 13000.0, gamma = 1.05, tLow = 4.0, fDec = 1500.0; break;
        case kPieceHiHat: fTop = 15000.0, tLow = 3.5, fDec = 2500.0, f0 *= 1.1, ref = 14.0; break;
        default: break;
    }
    static constexpr double kAlloyT[] = {1.0, 0.7, 0.5, 0.85}, kAlloyF[] = {1.0, 1.3, 0.7, 0.6}, kAlloyTop[] = {1.0, 1.1, 0.75, 0.85};
    const int alloy = static_cast<int>(clampd(s.alloy, 0, 3));
    tLow *= kAlloyT[alloy] * clampd(s.decay, 0.25, 4) * (1.0 - 0.8 * clampd(s.damp, 0, 1));
    fDec *= kAlloyF[alloy];
    fTop *= kAlloyTop[alloy];
    // The mode ratios depend on the kind, alloy and tier only (a bigger or retuned cymbal moves every mode alike).
    const double fRef = 3300.0 / ref * (s.kind == kPieceRide ? 0.95 : (hat ? 1.1 : 1.0));
    auto plate = [&](uint32_t at, uint32_t count, double base, uint32_t salt) {
        const uint32_t span = q == 0 && !hat ? count * 2 : count;  // Eco: the low half of Normal's modes
        const double b = (std::pow(fTop / fRef, 1.0 / gamma) - 1.0) / (span - 1);
        uint32_t r = 0xc0ffee00u + salt * 131u + static_cast<uint32_t>(s.kind) * 17u;
        for (uint32_t k = 0; k < count; ++k) {
            const double jitter = 1.0 + 0.03 * unit(r);
            const double ratio = std::pow(1.0 + b * k, gamma) * (k ? jitter : 1.0), hz = base * ratio;
            setMode(p, at + k, hz, tLow / (1.0 + hz / fDec), 1.0 / (1.0 + k / 40.0), sr_);
            p.ratio[at + k] = static_cast<float>(ratio);
            p.strain[at + k] = static_cast<float>(std::min(3.0, 3.0 / std::sqrt(ratio)));  // a hat's clamping loss weight
            // the contact ring near the edge (a hat's plates meet there)
            p.phiEdge[at + k] = static_cast<float>(lib::fastSinCycles(0.5 * (0.5 + 0.7 * std::sqrt(k + 1.0)) * 0.95 + 0.37 * k / kTwoPi));
        }
    };
    p.seg[0] = {0, top, static_cast<float>(dt_ * dt_ / (0.25 * size / 16.0)), 1};
    plate(0, top, f0, 1);
    if (hat) {
        p.seg[1] = {top, bottom, static_cast<float>(dt_ * dt_ / (0.3 * size / 14.0)), 1};
        plate(top, bottom, f0 * 0.92, 2);
        p.hatOm = static_cast<float>(kTwoPi * 12.0);
        p.hatZ = p.hatTarget = pedalHeight(p.hatOverride >= 0 ? p.hatOverride / 1000.0 : kit_.hatPedal);
        p.hatK = 3.0e6f;
        double sum = 0.0;
        for (uint32_t k = 0; k < top; ++k) sum += p.seg[0].g * p.phiEdge[k] * p.phiEdge[k];
        for (uint32_t k = 0; k < bottom; ++k) sum += p.seg[1].g * p.phiEdge[top + k] * p.phiEdge[top + k];
        p.hatC = static_cast<float>(dt_ * dt_ / 0.4 + sum);
    }
    // The cascade (the design's reduced coupling): each mode above the lowest quarter driven by the product of the
    // two lower modes whose frequencies add up nearest to its own. Energy climbs a step at a time, so a hard hit's
    // high band builds up over the first few hundred milliseconds (the plate's swell); a soft hit's products are
    // negligible (it stays linear). The pairs depend on the ratios only: found once per kind, alloy and tier.
    const double swell = clampd(s.swell, 0, 1);
    if (hat || q == 0 || swell <= 0.0) {
        p.triplets = 0;
    } else {
        const uint32_t low = top / 4;
        if (p.pairKind != s.kind || p.pairAlloy != alloy || p.pairQuality != q) {
            p.triplets = 0;
            for (uint32_t k = low; k < top && p.triplets < 96; ++k) {
                uint32_t bi = 0, bj = 0;
                double err = 1e30;
                for (uint32_t i = 0; i < k; ++i)
                    for (uint32_t j = i; j < k; ++j) {
                        const double e = std::fabs(p.ratio[i] + p.ratio[j] - p.ratio[k]);
                        if (e < err) err = e, bi = i, bj = j;
                    }
                p.ti[p.triplets] = static_cast<uint16_t>(bi);
                p.tj[p.triplets] = static_cast<uint16_t>(bj);
                p.tk[p.triplets] = static_cast<uint16_t>(k);
                ++p.triplets;
            }
            p.pairKind = static_cast<uint8_t>(s.kind), p.pairAlloy = static_cast<uint8_t>(alloy), p.pairQuality = static_cast<uint8_t>(q);
        }
        // F_k = c s_i s_j with c s <= kSwell sqrt(K_i K_j) at the limit Y (K = w^2 M): it never out-stiffens the pair.
        const double gk = p.seg[0].g;
        for (uint32_t t = 0; t < p.triplets; ++t) {
            const double ki = p.om[p.ti[t]] * p.om[p.ti[t]] / gk, kj = p.om[p.tj[t]] * p.om[p.tj[t]] / gk;
            p.tc[t] = static_cast<float>(swell * 0.25 * kSwellScale * std::sqrt(ki * kj) / 0.004 * gk);
        }
        p.satY = 0.004f;
    }
    // Eco: the cascade's substitute, band-limited noise in the high band growing as E_low^2 (100-300 ms).
    p.swellK = static_cast<float>(1.0 - std::exp(-1.0 / (0.2 * sr_ / 16.0)));
    p.swellGain = static_cast<float>(q == 0 && !hat ? swell * 2.0e9 : 0.0);
    p.gain = static_cast<float>(hat ? 0.6 : 0.5);
}

void AcousticKit::mics(Piece& p) noexcept {
    static constexpr float kClose[] = {1.0f, 0.8f, 0.4f, 0.15f}, kOh[] = {0.12f, 0.45f, 0.45f, 1.0f},
                           kRoomAmt[] = {0.0f, 0.25f, 0.8f, 0.3f};
    const int m = kit_.mics < 0 ? 0 : (kit_.mics > 3 ? 3 : kit_.mics);
    const PieceSettings& s = p.set;
    const float level = static_cast<float>(dbGain(s.level));
    float close = kClose[m];
    if (isCymbalPiece(s.kind)) close *= 0.3f;  // cymbals have no close mic of their own: the hat's and the toms' hear them
    if (s.kind == kPieceHiHat) close = kClose[m] * 0.7f;
    const double pan = clampd(s.pan, -1, 1);
    const double th = (pan + 1.0) * kPi * 0.25;
    p.closeL = static_cast<float>(close * level * cosr(th));
    p.closeR = static_cast<float>(close * level * cosr(kPi * 0.5 - th));
    // The overhead pair 1.2 m apart above the kit; a piece at x = 0.8 pan, `dist` below them.
    const double x = 0.8 * pan, d = clampd(s.dist, 0.3, 2);
    const double dl = std::sqrt((x + 0.6) * (x + 0.6) + d * d), dr = std::sqrt((x - 0.6) * (x - 0.6) + d * d);
    p.ohL = static_cast<float>(kOh[m] * level * 0.6 / dl);
    p.ohR = static_cast<float>(kOh[m] * level * 0.6 / dr);
    p.ohDelayL = std::min<uint32_t>(ohLength_ - 1, static_cast<uint32_t>(dl / 343.0 * sr_));
    p.ohDelayR = std::min<uint32_t>(ohLength_ - 1, static_cast<uint32_t>(dr / 343.0 * sr_));
    p.roomSend = static_cast<float>(kRoomAmt[m] * clampd(kit_.room, 0, 1) * level * 2.0);
    p.bleedSend = static_cast<float>(0.25 * clampd(kit_.bleed, 0, 1) * level * (isCymbalPiece(s.kind) ? 1.5 : 1.0));
}

// The segment's poles scaled by d (a hand on the head, a choke, the hat's pressure): a1 = d a1b, a2 = d^2 a2b.
void AcousticKit::applyDamp(Piece& p, uint32_t segment, float d) noexcept {
    Segment& sg = p.seg[segment];
    if (d == sg.damp) return;
    sg.damp = d;
    const float d2 = d * d;
    for (uint32_t k = sg.at; k < sg.at + sg.count; ++k) p.a1[k] = p.a1b[k] * d, p.a2[k] = p.a2b[k] * d2;
}

// ---------- Strokes ----------

void AcousticKit::weights(Piece& p, float* phi, float pos, bool bell) noexcept {
    const Segment& sg = p.seg[0];
    if (isDrumPiece(p.set.kind)) {
        const MembraneTable& mt = membrane();
        for (uint32_t k = 0; k < sg.count; ++k) phi[k] = static_cast<float>(besselJ(mt.m[k], mt.zero[k] * pos));
    } else {
        // A plate's pseudo mode shapes along a radius; the bell (pos ~ 0) is stiff and rings its own few modes.
        for (uint32_t k = 0; k < sg.count; ++k) {
            const double shape = lib::fastSinCycles(0.5 * (0.5 + 0.7 * std::sqrt(k + 1.0)) * pos + 0.37 * k / kTwoPi);
            phi[k] = static_cast<float>(bell ? (k < 6 ? 0.3 : 0.6 + 0.4 * shape) : 0.25 + 0.75 * shape);
        }
    }
    for (uint32_t k = sg.count; k < kMaxModes; ++k) phi[k] = 0.0f;
}

void AcousticKit::wake(Piece& p) noexcept {
    const uint32_t i = static_cast<uint32_t>(&p - pieces_);
    awake_ |= 1u << i;
    p.awake = true;
    p.quietFrames = 0;
}

void AcousticKit::startStroke(Piece& p, Striker& s, double velocity, float pos, int artic, bool press, bool dead, uint32_t delay) noexcept {
    // The striker: the kit's sticks, or a kick's beater.
    // [Assumption] a stick pivots in the hand: its tip strikes with about a quarter of its 45-60 g.
    float m = 0.013f, k = 3.0e7f, lambda = 0.15f;
    bool soft = false;
    if (p.set.kind == kPieceKick) {
        static constexpr float kM[] = {0.12f, 0.1f, 0.1f, 0.12f}, kK[] = {4.0e6f, 3.0e7f, 8.0e7f, 6.0e5f}, kL[] = {0.5f, 0.2f, 0.1f, 0.8f};
        static constexpr bool kSoft[] = {true, false, false, true};
        const int b = p.set.beater < 0 ? 0 : (p.set.beater > 3 ? 3 : p.set.beater);
        m = kM[b], k = kK[b], lambda = kL[b], soft = kSoft[b];
    } else {
        switch (kit_.stick) {
            case kStickRods: m = 0.012f, k = 1.0e7f, lambda = 0.3f; break;
            case kStickBrushes: m = 0.008f, k = 2.0e5f, lambda = 1.0f, soft = true; break;
            case kStickMallets: m = 0.03f, k = 1.5e6f, lambda = 0.6f, soft = true; break;
            default: break;
        }
        if (isCymbalPiece(p.set.kind) && !soft) k *= 3.0f;  // bronze is harder than a head
        if (artic == kArtEdge || artic == kArtBell) m *= 1.4f, k *= 0.6f;  // the shoulder
    }
    const float v = static_cast<float>(clampd(0.3 + 6.0 * velocity, 0.05, 10.0));
    s = Striker{};
    s.active = true;
    s.m = m, s.k = k, s.lambda = lambda, s.soft = soft;
    s.startV = v;
    s.delay = delay;
    s.x = -v * static_cast<float>(dt_) * 1.5f;
    s.v = v;
    s.pos = pos;
    s.ref = p.hatZ;
    if (press || dead) {  // the hand presses through the surface: the stick bounces (buzz) or stays (dead stroke)
        s.handTarget = dead ? 0.002f : 0.004f;
        s.handK = (dead ? 3000.0f : 2000.0f) * m / 0.045f;  // the fingers' stiffness, scaled with the tip's mass
        s.handC = (dead ? 2.0f : 0.16f) * std::sqrt(s.handK * m);
        s.pressFor = static_cast<uint32_t>((dead ? 0.5 : (p.rolling ? 1.0 / std::max<double>(1.0, sr_ / std::max<uint32_t>(1u, p.rollEvery)) + 0.03 : 0.18)) * sr_);
    } else {
        s.handTarget = -0.03f;
        s.handK = 60.0f;
        s.handC = 2.0f * std::sqrt(s.handK * m);
    }
    float* phi = &s == &p.stick[0] ? p.phiA : p.phiB;
    if (&s != &p.rim) {
        weights(p, phi, pos, artic == kArtBell);
        double sum = 0.0;
        for (uint32_t i = 0; i < p.seg[0].count; ++i) sum += static_cast<double>(phi[i]) * phi[i];
        s.C = static_cast<float>(dt_ * dt_ / m + p.seg[0].g * sum);
    } else {
        s.C = static_cast<float>(dt_ * dt_ / m);
    }
}

void AcousticKit::strike(uint32_t piece, int artic, double velocity, double jitter, uint32_t noteId) noexcept {
    if (piece >= kPieces) return;
    Piece& p = pieces_[piece];
    if (!p.configured || p.set.kind == kPieceOff) return;
    const int a = articulationFor(p.set.kind, artic);
    const double vel = clampd(velocity, 0, 2);
    if (!(vel > 0.0)) return;
    wake(p);
    p.lastNote = noteId;
    const float j = static_cast<float>(clampd(jitter, -1, 1) * 0.08);
    float pos = 0.25f;
    switch (a) {
        case kArtOffCenter: pos = 0.55f; break;
        case kArtEdge: pos = 0.86f; break;
        case kArtBell: pos = 0.05f; break;
        default: break;
    }
    if (isCymbalPiece(p.set.kind) && a == kArtHit) pos = 0.5f;  // the bow
    pos = std::clamp(pos + j, 0.02f, 0.95f);
    // A new stroke lifts any hand left on the head (cross-stick, a choke, a dead stroke) unless it is one.
    for (uint32_t sg = 0; sg < 3; ++sg) applyDamp(p, sg, 1.0f);
    if (a != kArtRoll) p.rolling = false;
    const uint32_t which = p.nextStick;
    p.nextStick ^= 1u;
    Striker& s = p.stick[which];
    const float noise = static_cast<float>(clampd(kit_.noise, 0, 1));
    auto noiseBurst = [&](double seconds, double level, double lp) {
        p.noiseLength = p.noiseLeft = std::max<uint32_t>(1u, static_cast<uint32_t>(seconds * sr_));
        p.noiseLevel = static_cast<float>(level * noise * std::sqrt(vel));
        p.noiseK = static_cast<float>(lp);
    };
    switch (a) {
        case kArtRimshot:
            startStroke(p, s, vel, pos, a, false, false, 0);
            s.m *= 0.5f;
            s.C = static_cast<float>(dt_ * dt_ / s.m + (s.C - dt_ * dt_ / (2.0 * s.m)));
            startStroke(p, p.rim, vel, 1.0f, a, false, false, 0);
            p.rim.m *= 0.5f;
            break;
        case kArtCrossStick:
            startStroke(p, p.rim, vel * 0.6, 1.0f, a, false, false, 0);
            p.rim.m = 0.08f;
            applyDamp(p, 0, static_cast<float>(std::exp(-1.0 / (0.08 * sr_))));  // the hand on the head
            break;
        case kArtRimClick: startStroke(p, p.rim, vel * 0.8, 1.0f, a, false, false, 0); p.rim.m = 0.025f; break;
        case kArtFlam:
            startStroke(p, s, vel * 0.35, std::clamp(pos + 0.07f, 0.02f, 0.95f), a, false, false, 0);
            startStroke(p, p.stick[which ^ 1u], vel, pos, a, false, false, static_cast<uint32_t>(0.022 * sr_));
            break;
        case kArtRoll:
            p.rolling = true;
            p.rollNote = noteId;
            p.rollVel = static_cast<float>(vel);
            p.rollPos = pos;
            p.rollEvery = static_cast<uint32_t>(sr_ / (9.0 + 7.0 * std::min(vel, 1.0)));  // strokes per second
            p.rollIn = p.rollEvery;
            p.rollLeft = static_cast<uint32_t>(8.0 * sr_);
            startStroke(p, s, vel, pos, a, true, false, 0);
            break;
        case kArtBuzz: startStroke(p, s, vel, pos, a, true, false, 0); break;
        case kArtChoke: {  // the hand grabs or mutes it: fast damping, and the hand's own noise
            const double tau = isCymbalPiece(p.set.kind) ? 0.03 : 0.05;
            for (uint32_t sg = 0; sg < 3; ++sg) applyDamp(p, sg, static_cast<float>(std::exp(-1.0 / (tau * sr_))));
            noiseBurst(0.04, 0.15, 0.2);
            break;
        }
        case kArtClosed:
            if (p.set.kind == kPieceHiHat) {
                p.hatOverride = 1000;
                p.hatTarget = pedalHeight(1.0);
                p.hatZ = p.hatTarget, p.hatV = 0;
                startStroke(p, s, vel, pos, a, false, false, 0);
            } else {
                startStroke(p, s, vel, pos, a, false, true, 0);  // a dead stroke (a buried beater)
            }
            break;
        case kArtOpen:
            p.hatOverride = 0;
            p.hatTarget = pedalHeight(0.0);
            p.hatZ = p.hatTarget, p.hatV = 0;
            startStroke(p, s, vel, pos, a, false, false, 0);
            break;
        case kArtFoot:  // the pedal closes fast: the plates meet (the chick)
            p.hatOverride = 1000;
            p.hatTarget = pedalHeight(1.0);
            p.hatFootBoost = static_cast<float>(0.05 * sr_);
            p.hatV = -static_cast<float>(0.6 + 1.6 * vel);
            noiseBurst(0.025, 0.1, 0.4);
            break;
        default:
            if (p.set.kind == kPieceHiHat) p.hatOverride = -1;  // a plain stroke: the hat is where the pedal holds it
            startStroke(p, s, vel, pos, a, false, false, 0);
            break;
    }
    if (p.set.kind == kPieceKick) noiseBurst(0.025, 0.6, 0.25);  // the pedal's mechanism (its spring and cam)
    if (kit_.stick == kStickBrushes && p.set.kind != kPieceKick && a != kArtChoke) noiseBurst(0.08, 0.5, 0.9);  // the swish
}

bool AcousticKit::wakeHat(uint32_t piece) noexcept {
    if (piece >= kPieces) return false;
    Piece& p = pieces_[piece];
    if (!p.configured || p.set.kind != kPieceHiHat) return false;
    if (!p.awake) wake(p);
    return true;
}

void AcousticKit::release(uint32_t noteId) noexcept {
    for (Piece& p : pieces_)
        if (p.rolling && p.rollNote == noteId) p.rolling = false;
}

void AcousticKit::pressure(uint32_t noteId, double value) noexcept {
    // A pad's pressure on a cymbal chokes it (an e-drum's cymbal grab sends poly pressure: Roland's TD-50 MIDI
    // implementation, 7FH while the edge is held).
    if (!(value >= 0.5)) return;
    for (Piece& p : pieces_)
        if (p.awake && p.lastNote == noteId && isCymbalPiece(p.set.kind) && p.set.kind != kPieceHiHat)
            for (uint32_t sg = 0; sg < 3; ++sg) applyDamp(p, sg, static_cast<float>(std::exp(-1.0 / (0.03 * sr_))));
}

// ---------- Running ----------

float AcousticKit::noiseSample(Piece& p) noexcept {
    if (!p.noiseLeft) return 0.0f;
    const float env = static_cast<float>(p.noiseLeft) / static_cast<float>(p.noiseLength);
    --p.noiseLeft;
    p.noiseLp += p.noiseK * (unit(p.rng) - p.noiseLp);
    return p.noiseLp * env * env * p.noiseLevel;
}

// The contact force (N, pushing the surface down) for a stick whose surface point would be at uPred (m) without it;
// moves the stick a step.
float AcousticKit::stickForce(Striker& s, float uPred) noexcept {
    const float dt = static_cast<float>(dt_);
    if (s.pressFor) {
        if (--s.pressFor == 0) {  // the hand lifts
            s.handTarget = -0.03f;
            s.handK = 60.0f;
            s.handC = 2.0f * std::sqrt(s.handK * s.m);
        }
    }
    const float acc = (s.handK * (s.handTarget - s.x) - s.handC * s.v) / s.m;
    const float vP = s.v + acc * dt;
    const float xP = s.x + vP * dt;
    const float d = xP - uPred;
    float F = 0.0f;
    if (d > 0.0f) {
        const float sq = std::sqrt(d);
        const float f = s.soft ? s.k * d * d * sq : s.k * d * sq;
        const float fp = s.soft ? 2.5f * s.k * d * sq : 1.5f * s.k * sq;
        F = f / (1.0f + fp * s.C);
        const float rate = (d - s.dPrev) / dt;
        F *= 1.0f + s.lambda * rate;
        if (F < 0.0f) F = 0.0f;
        if (!s.contact) {
            ++s.bounces;
            if (!s.touched) s.firstContact = s.contactFrames;
        }
        if (!s.firstDone) s.firstLength += s.gap + 1;
        s.gap = 0;
        s.contact = s.touched = true;
        ++s.contactFrames;
        s.lastContact = s.contactFrames;
        if (F > s.peakForce) s.peakForce = F;
    } else {
        s.contact = false;
        if (s.touched || s.pressFor) ++s.contactFrames;  // a clock since the first touch (contact times, bounces)
        if (s.touched && !s.firstDone && ++s.gap > static_cast<uint32_t>(0.0005 * sr_)) s.firstDone = true;
    }
    s.dPrev = d - F * s.C;
    s.v = vP - F * dt / s.m;
    s.x += s.v * dt;
    // Done: lifted clear and settling, nothing pressing.
    if (s.touched && !s.contact && !s.pressFor && s.x < -0.002f && s.v < 0.0f) s.active = false;
    if (!s.touched && s.contactFrames == 0 && s.x < -0.05f) s.active = false;
    return F;
}

void AcousticKit::runDrum(Piece& p, uint32_t n, uint64_t clock) noexcept {
    const Segment b = p.seg[0], r = p.seg[1], sh = p.seg[2];
    const uint32_t all = b.count + r.count + sh.count;
    const float gb = b.g, gr = r.g, gs = sh.g;
    const float scale = static_cast<float>(sr_) * p.gain;
    const bool snare = p.set.kind == kPieceSnare, eco = p.quality == 0;
    const float dt = static_cast<float>(dt_);
    float* const y1 = p.y1;
    float* const y2 = p.y2;
    alignas(32) float yp[kMaxModes];
    for (uint32_t t = 0; t < n; ++t) {
        // The rest of the kit, kLag frames back: it drives the snare-side head (the wires buzz with the kick) and a
        // tom's lowest modes (sympathetic ring).
        const uint32_t back = static_cast<uint32_t>(clock + t - kLag) & (kRing - 1);
        const float drive = p.symp > 0.0f ? ring_[back] - p.own[back] : 0.0f;
        const float fAir = p.airK * (y1[b.at] - y1[r.at]);
        const float symB = snare ? 0.0f : gb * p.symp * 0.3f * drive;
        const float symR = snare ? gr * p.symp * 8.0f * drive : 0.0f;
        Striker& sa = p.stick[0];
        Striker& sb = p.stick[1];
        const bool ca = due(sa);
        const bool cb = due(sb);
        const bool rim = p.rim.active;
        float out = 0.0f, fWires = 0.0f;
        if (!ca && !cb && !rim && !p.wires) {
            // Ringing on its own: one pass over every mode, the few point forces (air, sympathy) added after.
            out = stepModes(all, p.a1, p.a2, y1, y2, p.w);
            const float db0 = symB - gb * fAir, dr0 = gr * fAir + symR;
            y1[b.at] += db0;
            y1[r.at] += dr0;
            out += p.w[b.at] * db0 + p.w[r.at] * dr0;
            if (symB != 0.0f && b.count > 1) y1[b.at + 1] += symB, out += p.w[b.at + 1] * symB;
            if (symR != 0.0f && r.count > 2) y1[r.at + 2] += 0.6f * symR, out += p.w[r.at + 2] * 0.6f * symR;
        } else {
            // A stick, the rim or the wires may touch: every force is solved with the response it causes.
            predictModes(all, p.a1, p.a2, y1, y2, yp);
            yp[b.at] += symB - gb * fAir;
            if (b.count > 1) yp[b.at + 1] += symB;
            yp[r.at] += gr * fAir + symR;
            if (r.count > 2) yp[r.at + 2] += 0.6f * symR;
            const float FA = ca ? stickForce(sa, dotModes(b.count, p.phiA, yp)) : 0.0f;
            const float FB = cb ? stickForce(sb, dotModes(b.count, p.phiB, yp)) : 0.0f;
            // The rim: a steel or cast hoop, far stiffer than the stick's tip (a fixed surface for the contact); its
            // force rings the shell and pulls the head at its edge.
            const float FR = rim ? stickForce(p.rim, 0.0f) : 0.0f;
            if (FA > 0.0f) addModes(b.count, yp, p.phiA, gb * FA);
            if (FB > 0.0f) addModes(b.count, yp, p.phiB, gb * FB);
            if (FR > 0.0f) addModes(b.count, yp, p.phiEdge, gb * 0.3f * FR);  // the rim pulls the head at its edge
            const float fShell = gs * (FR + 0.3f * (FA + FB));                 // and the head the shell, through the edge
            if (fShell != 0.0f)
                for (uint32_t k = 0; k < sh.count; ++k) yp[sh.at + k] += fShell;
            if (p.wires) {
                // The snare wires against the resonant head: mass-spring each, pressed into the head, a one-sided
                // power-law contact solved per wire with the head's response (all wires at once: they vectorize).
                float* const ypR = yp + r.at;
                alignas(32) float u[kMaxWires] = {}, F[kMaxWires];
                const uint32_t nw = p.wires;
                for (uint32_t k = 0; k < kResoWireModes; ++k) {
                    const float y = ypR[k];
                    const float* __restrict row = p.psiT[k];
                    for (uint32_t w = 0; w < nw; ++w) u[w] += row[w] * y;
                }
                for (uint32_t w = 0; w < nw; ++w) {
                    const float acc = -p.wOm2 * (p.wx[w] - p.wRest) - p.wDampK * p.wv[w];
                    const float vP = p.wv[w] + acc * dt;
                    const float xP = p.wx[w] + vP * dt;
                    const float eta = u[w] - xP;  // > 0: the head is past the wire (they touch)
                    const float e = eta > 0.0f ? eta : 0.0f;
                    const float sq = std::sqrt(e);
                    float f = p.wK * e * sq / (1.0f + 1.5f * p.wK * sq * p.wC[w]);
                    f *= 1.0f + 0.2f * (e - p.wDPrev[w]) / dt;
                    f = f > 0.0f ? f : 0.0f;
                    p.wDPrev[w] = e - f * p.wC[w];
                    p.wv[w] = vP + f * dt / p.wMass;
                    p.wx[w] += p.wv[w] * dt;
                    F[w] = f;
                    fWires += f;
                }
                for (uint32_t k = 0; k < kResoWireModes; ++k) ypR[k] -= gr * dotModes(nw, p.psiT[k], F);
                p.rattleEnergy += static_cast<double>(fWires) * fWires;
            }
            out = commitModes(all, yp, y1, y2, p.w);
        }
        // The rattle: the collisions' force changing (radiated sound goes with its rate), high-passed (two poles at
        // 3 kHz): the wires' clicks against the head.
        float rattle = 0.0f;
        if (snare && p.rattleGain > 0.0f) {
            float x = (fWires - p.lastF) * 0.02f;
            p.lastF = fWires;
            if (eco) {  // Eco: noise gated by the snare-side head's motion
                const float vel = (std::fabs(y1[r.at] - y2[r.at]) + std::fabs(y1[r.at + 1] - y2[r.at + 1])) * scale;
                p.wireGate += 0.01f * (vel - p.wireGate);
                x = unit(p.rng) * std::max(0.0f, p.wireGate - 0.0005f) * 0.05f;
            }
            p.rattleHp[0] = p.rattleK * p.rattleHp[0] + (1.0f - p.rattleK) * x;
            const float h = x - p.rattleHp[0];
            p.rattleHp[1] = p.rattleK * p.rattleHp[1] + (1.0f - p.rattleK) * h;
            rattle = (h - p.rattleHp[1]) * p.rattleGain;
        }
        p.out[t] = out * scale + rattle + noiseSample(p);
    }
}

void AcousticKit::runCymbal(Piece& p, uint32_t n, uint64_t clock) noexcept {
    (void)clock;
    const Segment s = p.seg[0];
    const float g = s.g;
    const float scale = static_cast<float>(sr_) * p.gain;
    alignas(32) float yp[kMaxModes], sat[kMaxModes];
    for (uint32_t t = 0; t < n; ++t) {
        Striker& sa = p.stick[0];
        Striker& sb = p.stick[1];
        const bool ca = due(sa);
        const bool cb = due(sb);
        float out;
        if (!ca && !cb && !p.triplets) {
            out = stepModes(s.count, p.a1, p.a2, p.y1, p.y2, p.w);
        } else {
            predictModes(s.count, p.a1, p.a2, p.y1, p.y2, yp);
            if (p.triplets) {
                // the cascade: F_k = c s_i s_j (s: the low modes, softly limited), already scaled by g
                const float inv = 1.0f / p.satY;
                for (uint32_t k = 0; k < s.count; ++k) sat[k] = p.y1[k] / (1.0f + std::fabs(p.y1[k]) * inv);
                float* const high = yp + p.tk[0];
                for (uint32_t q = 0; q < p.triplets; ++q) high[q] += p.tc[q] * sat[p.ti[q]] * sat[p.tj[q]];
            }
            if (ca) {
                const float F = stickForce(sa, dotModes(s.count, p.phiA, yp));
                if (F > 0.0f) addModes(s.count, yp, p.phiA, g * F);
            }
            if (cb) {
                const float F = stickForce(sb, dotModes(s.count, p.phiB, yp));
                if (F > 0.0f) addModes(s.count, yp, p.phiB, g * F);
            }
            out = commitModes(s.count, yp, p.y1, p.y2, p.w);
        }
        out *= scale;
        if (p.swellGain > 0.0f) {  // Eco's substitute for the cascade
            float x = unit(p.rng) * std::sqrt(std::max(0.0f, p.swellEnv)) * p.swellGain;
            const float h = x - p.swellHp[0];
            p.swellHp[0] += 0.35f * h;
            x = h;
            p.swellLp += 0.6f * (x - p.swellLp);
            out += p.swellLp;
        }
        p.out[t] = out + noiseSample(p);
    }
}

void AcousticKit::runHat(Piece& p, uint32_t n, uint64_t clock) noexcept {
    (void)clock;
    const Segment top = p.seg[0], bot = p.seg[1];
    const float gt = top.g, gb = bot.g;
    const float dt = static_cast<float>(dt_);
    const float scale = static_cast<float>(sr_) * p.gain;
    const uint32_t all = top.count + bot.count;
    float* const phiB = p.phiEdge + top.count;
    alignas(32) float yp[kMaxModes];
    float pressure = 0.0f;
    for (uint32_t t = 0; t < n; ++t) {
        Striker& sa = p.stick[0];
        Striker& sb = p.stick[1];
        const bool ca = due(sa);
        const bool cb = due(sb);
        // The clutch: the top plate's height follows the pedal through the rod (a damped spring; a stamp is faster).
        const float om = p.hatOm * (p.hatFootBoost > 0.0f ? 3.0f : 1.0f);
        if (p.hatFootBoost > 0.0f) p.hatFootBoost -= 1.0f;
        const float acc = om * om * (p.hatTarget - p.hatZ) - 1.4f * om * p.hatV;
        float vz = p.hatV + acc * dt;
        const float zP = p.hatZ + vz * dt;
        float out;
        if (zP > 0.006f && !ca && !cb) {  // wide open and untouched: the plates ring on their own
            out = stepModes(top.count, p.a1, p.a2, p.y1, p.y2, p.w) +
                  0.7f * stepModes(bot.count, p.a1 + top.count, p.a2 + top.count, p.y1 + top.count, p.y2 + top.count,
                                   p.w + top.count);
            p.hatDPrev = -zP;
        } else {
            predictModes(all, p.a1, p.a2, p.y1, p.y2, yp);
            // The plates' contact near the edge (down positive: the top plate sits zP above the bottom one).
            const float eta = (dotModes(top.count, p.phiEdge, yp) - zP) - dotModes(bot.count, phiB, yp + top.count);
            float Fc = 0.0f;
            if (eta > 0.0f) {
                const float sq = std::sqrt(eta);
                Fc = p.hatK * eta * sq / (1.0f + 1.5f * p.hatK * sq * p.hatC);
                Fc *= 1.0f + 0.3f * (eta - p.hatDPrev) / dt;
                if (Fc < 0.0f) Fc = 0.0f;
            }
            p.hatDPrev = eta - Fc * p.hatC;
            vz += Fc * dt / 0.4f;
            pressure += Fc;
            if (Fc > 0.0f) {
                addModes(top.count, yp, p.phiEdge, -gt * Fc);
                addModes(bot.count, yp + top.count, phiB, gb * Fc);
            }
            // the stick pushes the top plate on its felt clutch down toward the bottom one, as well as bending it
            if (ca) {
                const float F = stickForce(sa, dotModes(top.count, p.phiA, yp) + sa.ref - zP);
                if (F > 0.0f) addModes(top.count, yp, p.phiA, gt * F), vz -= F * dt / 0.4f;
            }
            if (cb) {
                const float F = stickForce(sb, dotModes(top.count, p.phiB, yp) + sb.ref - zP);
                if (F > 0.0f) addModes(top.count, yp, p.phiB, gt * F), vz -= F * dt / 0.4f;
            }
            out = commitModes(top.count, yp, p.y1, p.y2, p.w) +
                  0.7f * commitModes(bot.count, yp + top.count, p.y1 + top.count, p.y2 + top.count, p.w + top.count);
        }
        p.hatV = vz;
        p.hatZ += vz * dt;
        p.out[t] = out * scale + noiseSample(p);
    }
    p.hatPressureSum += pressure;  // the cell's end turns it into the plates' damping (endCell)
}

void AcousticKit::control(Piece& p) noexcept {
    // Glide: the low modes' strain energy now sets every head mode's frequency (tension modulation).
    if (!isDrumPiece(p.set.kind) || p.glideK <= 0.0f) return;
    const Segment& b = p.seg[0];
    float e = 0.0f;
    for (uint32_t k = 0; k < 8 && k < b.count; ++k) {
        const float c = 0.5f * p.a1b[k] / p.rr[k], s2 = std::max(1e-6f, 1.0f - c * c);
        const float a2 = (p.y1[k] * p.y1[k] + p.y2[k] * p.y2[k] - 2.0f * c * p.y1[k] * p.y2[k]) / s2;
        e += p.strain[k] * a2;
    }
    float g = std::min(0.25f, p.glideK * e);
    if (g < 2e-4f) g = 0.0f;  // under a third of a cent: the head is at rest pitch
    // Re-tuned when the glide moved by a sixth of a cent or more (it falls fast, then stays put).
    if (std::fabs(g - p.glideNow) < 1e-4f && !(g == 0.0f && p.glideNow != 0.0f)) return;
    p.glideNow = g;
    const Segment& r = p.seg[1];
    for (uint32_t k = 0; k < b.count + r.count; ++k) {
        p.a1b[k] = static_cast<float>(2.0 * p.rr[k] * cosr(p.om[k] * (1.0 + g)));
        p.a1[k] = p.a1b[k] * p.seg[k < b.count ? 0 : 1].damp;
    }
}

void AcousticKit::process(double* left, double* right, double* room, uint32_t n) noexcept {
    if (awake_) span(left, right, room, n);
}

void AcousticKit::span(double* left, double* right, double* room, uint32_t n) noexcept {
    float sum[kCell] = {}, bleedIn[kCell] = {};
    for (uint32_t i = 0; i < kPieces; ++i) {
        Piece& p = pieces_[i];
        if (!p.awake) continue;
        // A roll: the next press strokes due in this span, each at its own frame.
        if (p.rolling) {
            while (p.rollIn < n) {
                const float jitter = unit(p.rollRng) * 0.04f;
                Striker& s = p.stick[p.nextStick];
                p.nextStick ^= 1u;
                startStroke(p, s, p.rollVel * (0.85f + 0.1f * unit(p.rollRng)), std::clamp(p.rollPos + jitter, 0.02f, 0.95f), kArtRoll,
                            true, false, p.rollIn);
                p.rollIn += p.rollEvery;
            }
            p.rollIn -= n;
            if (p.rollLeft <= n) p.rolling = false;
            else p.rollLeft -= n;
        }
        if (isDrumPiece(p.set.kind)) {
            runDrum(p, n, clock_);
        } else if (p.set.kind == kPieceHiHat) {
            p.hatTarget = pedalHeight(p.hatOverride >= 0 ? p.hatOverride / 1000.0 : kit_.hatPedal);
            runHat(p, n, clock_);
        } else {
            runCymbal(p, n, clock_);
        }
        // The guard: a non-finite or runaway output silences the piece (it starts over at its next stroke).
        bool bad = false;
        for (uint32_t t = 0; t < n; ++t) {
            const float a = std::fabs(p.out[t]);
            bad = bad || !(a < 16.0f);
            p.peak = std::max(p.peak, a);
        }
        if (bad) {
            silence(i);
            continue;
        }
        // Mics: close (panned), the overhead pair (delayed by distance), the room send and the bleed bus.
        float* line = oh_.data() + static_cast<size_t>(i) * ohLength_;
        const uint32_t len = ohLength_;
        uint32_t at = ohAt_, rl = (ohAt_ + len - p.ohDelayL) % len, rr = (ohAt_ + len - p.ohDelayR) % len;
        for (uint32_t t = 0; t < n; ++t) {
            const float y = p.out[t] * level_;
            sum[t] += p.out[t];
            p.own[(clock_ + t) & (kRing - 1)] = p.out[t];
            line[at] = y;
            left[t] += y * p.closeL + line[rl] * p.ohL;
            right[t] += y * p.closeR + line[rr] * p.ohR;
            if (room) room[t] += y * p.roomSend;
            bleedIn[t] += y * p.bleedSend;
            if (++at == len) at = 0;
            if (++rl == len) rl = 0;
            if (++rr == len) rr = 0;
        }
    }
    // The bleed bus: every close mic hearing the others 1.5 ms late, centred.
    const uint32_t size = static_cast<uint32_t>(bleed_.size());
    for (uint32_t t = 0; t < n; ++t) {
        bleed_[bleedAt_] = bleedIn[t];
        const float b = bleed_[(bleedAt_ + size - bleedDelay_) % size] * bleedGain_;
        if (++bleedAt_ == size) bleedAt_ = 0;
        left[t] += b * 0.7f;
        right[t] += b * 0.7f;
        ring_[(clock_ + t) & (kRing - 1)] = sum[t];
    }
    ohAt_ = (ohAt_ + n) % ohLength_;
    clock_ += n;
    cellFrames_ += n;
}

void AcousticKit::endCell() noexcept {
    if (!awake_) return;
    const float frames = static_cast<float>(cellFrames_ ? cellFrames_ : 1);
    for (uint32_t i = 0; i < kPieces; ++i) {
        Piece& p = pieces_[i];
        if (!p.awake) continue;
        control(p);
        if (p.set.kind == kPieceHiHat) {  // the plates' pressure over the cell damps both (friction), low modes most
            const Segment top = p.seg[0], bot = p.seg[1];
            p.hatPressure = p.hatPressureSum / frames;
            p.hatPressureSum = 0.0f;
            const float d = static_cast<float>(std::exp(-kHatDamp * p.hatPressure * dt_));
            if (std::fabs(d - p.seg[0].damp) > 1e-7f) {
                p.seg[0].damp = p.seg[1].damp = d;
                const float loss = 1.0f - d;
                for (uint32_t k = 0; k < top.count + bot.count; ++k) {
                    const float dk = 1.0f - loss * p.strain[k];
                    p.a1[k] = p.a1b[k] * dk;
                    p.a2[k] = p.a2b[k] * dk * dk;
                }
            }
        }
        const bool busy = p.stick[0].active || p.stick[1].active || p.rim.active || p.rolling || p.noiseLeft ||
                          (p.set.kind == kPieceHiHat && std::fabs(p.hatV) > 1e-4f);
        p.quietFrames = p.peak < 1e-5f && !busy ? p.quietFrames + cellFrames_ : 0;
        p.peak = 0.0f;
        if (p.quietFrames > static_cast<uint32_t>(0.25 * sr_)) silence(i);  // asleep: its state to exact zero
    }
    // A sleeping snare wakes when the rest of the kit drove it in the last cell (its buzz from the kick).
    float drive = 0.0f;
    for (uint32_t t = 0; t < kLag; ++t) drive = std::max(drive, std::fabs(ring_[(clock_ + t - kLag) & (kRing - 1)]));
    if (drive > 0.01f)
        for (Piece& p : pieces_)
            if (!p.awake && p.configured && p.set.kind == kPieceSnare && p.symp > 0.0f) wake(p);
    cellFrames_ = 0;
    if (!awake_) {  // the whole kit asleep: its history starts over at the next stroke
        std::fill(ring_, ring_ + kRing, 0.0f);
        std::fill(bleed_.begin(), bleed_.end(), 0.0f);
    }
}

void AcousticKit::silence(uint32_t i) noexcept {
    Piece& p = pieces_[i];
    const PieceSettings s = p.set;
    const int q = p.quality;
    const uint32_t seed = p.rng;
    const uint8_t pk = p.pairKind, pa = p.pairAlloy, pq = p.pairQuality;
    const uint32_t triplets = p.triplets;
    uint16_t ti[96], tj[96], tk[96];
    std::copy(p.ti, p.ti + 96, ti), std::copy(p.tj, p.tj + 96, tj), std::copy(p.tk, p.tk + 96, tk);
    p = Piece{};
    p.set = s, p.quality = q, p.rng = seed;
    p.pairKind = pk, p.pairAlloy = pa, p.pairQuality = pq, p.triplets = triplets;  // the cascade's pairs stay found
    std::copy(ti, ti + 96, p.ti), std::copy(tj, tj + 96, p.tj), std::copy(tk, tk + 96, p.tk);
    configure(p);
    p.symp = static_cast<float>(kit_.sympathy);
    awake_ &= ~(1u << i);
    std::fill(oh_.begin() + static_cast<size_t>(i) * ohLength_, oh_.begin() + static_cast<size_t>(i + 1) * ohLength_, 0.0f);
}

uint32_t AcousticKit::awakeCount() const noexcept {
    uint32_t c = 0;
    for (uint32_t i = 0; i < kPieces; ++i) c += (awake_ >> i) & 1u;
    return c;
}

}  // namespace caw::drums::acoustic
