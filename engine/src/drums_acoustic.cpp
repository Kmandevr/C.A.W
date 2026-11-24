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

// The free-ringing kernels are kept out of line and unspecialised (no inlining, no clones for a constant frame
// count), so a span stepped at once and a frame stepped alone run the same machine code: the same bits.
#if defined(__clang__)
#define CAW_ACOU_KERNEL __attribute__((noinline))
#elif defined(__GNUC__)
#define CAW_ACOU_KERNEL __attribute__((noinline, noipa))
#elif defined(_MSC_VER)
#define CAW_ACOU_KERNEL __declspec(noinline)
#else
#define CAW_ACOU_KERNEL
#endif

// A loop whose one body serves every trip count (no unrolled or vectorized copies that a compiler free to reassociate
// could round differently): the kernels' frame loops, so one frame and a span give the same bits.
#if defined(__clang__)
#define CAW_ONE_BODY _Pragma("clang loop unroll(disable) vectorize(disable) interleave(disable)")
#elif defined(__GNUC__)
#define CAW_ONE_BODY _Pragma("GCC unroll 1")
#else
#define CAW_ONE_BODY
#endif

// Four modes as one SIMD value (GCC and Clang vector extensions: SSE on x86-64, NEON on Arm64; else a plain struct).
#if defined(__GNUC__) || defined(__clang__)
typedef float V4 __attribute__((vector_size(16)));
#else
struct V4 {
    float v[4];
    float& operator[](int i) noexcept { return v[i]; }
    float operator[](int i) const noexcept { return v[i]; }
};
inline V4 operator+(V4 a, V4 b) noexcept { return {{a.v[0] + b.v[0], a.v[1] + b.v[1], a.v[2] + b.v[2], a.v[3] + b.v[3]}}; }
inline V4 operator-(V4 a, V4 b) noexcept { return {{a.v[0] - b.v[0], a.v[1] - b.v[1], a.v[2] - b.v[2], a.v[3] - b.v[3]}}; }
inline V4 operator*(V4 a, V4 b) noexcept { return {{a.v[0] * b.v[0], a.v[1] * b.v[1], a.v[2] * b.v[2], a.v[3] * b.v[3]}}; }
#endif
inline V4 load4(const float* p) noexcept {
    V4 v;
    std::memcpy(&v, p, sizeof v);
    return v;
}
inline void store4(float* p, V4 v) noexcept { std::memcpy(p, &v, sizeof v); }
inline float sum4(V4 v) noexcept { return (v[0] + v[1]) + (v[2] + v[3]); }

// The modal kernels (structure of arrays, every count a multiple of 4), four modes at a time. y = a1 y1 - a2 y2 is a
// mode's next displacement before new forces (the damping is in a1, a2); the radiated sum is the weighted velocity
// sum w (y - y1). The sums run in two interleaved accumulators: two chains of adds, not one, per frame.
template <class F>
inline float sumGroups(uint32_t n, F&& f) noexcept {
    n &= ~3u;
    V4 s0 = {0.0f, 0.0f, 0.0f, 0.0f}, s1 = s0;
    uint32_t k = 0;
    for (; k + 8 <= n; k += 8) {
        s0 = s0 + f(k);
        s1 = s1 + f(k + 4);
    }
    if (k < n) s0 = s0 + f(k);
    return sum4(s0 + s1);
}
inline void predictModes(uint32_t n, const float* __restrict a1, const float* __restrict a2, const float* __restrict y1,
                         const float* __restrict y2, float* __restrict yp) noexcept {
    n &= ~3u;
    for (uint32_t k = 0; k < n; k += 4) store4(yp + k, load4(a1 + k) * load4(y1 + k) - load4(a2 + k) * load4(y2 + k));
}
inline float dotModes(uint32_t n, const float* __restrict a, const float* __restrict b) noexcept {
    return sumGroups(n, [&](uint32_t k) { return load4(a + k) * load4(b + k); });
}
inline void addModes(uint32_t n, float* __restrict y, const float* __restrict phi, float c) noexcept {
    n &= ~3u;
    const V4 C = {c, c, c, c};
    for (uint32_t k = 0; k < n; k += 4) store4(y + k, load4(y + k) + C * load4(phi + k));
}
inline float commitModes(uint32_t n, const float* __restrict yp, float* __restrict y1, float* __restrict y2,
                         const float* __restrict w) noexcept {
    return sumGroups(n, [&](uint32_t k) {
        const V4 Y = load4(yp + k), Y1 = load4(y1 + k);
        store4(y2 + k, Y1), store4(y1 + k, Y);
        return load4(w + k) * (Y - Y1);
    });
}
// predictModes and the predicted displacement's dot product with phi, in one pass.
inline float predictDot(uint32_t n, const float* __restrict a1, const float* __restrict a2, const float* __restrict y1,
                        const float* __restrict y2, float* __restrict yp, const float* __restrict phi) noexcept {
    return sumGroups(n, [&](uint32_t k) {
        const V4 Y = load4(a1 + k) * load4(y1 + k) - load4(a2 + k) * load4(y2 + k);
        store4(yp + k, Y);
        return load4(phi + k) * Y;
    });
}
// addModes(c, phi) then commitModes, in one pass.
inline float commitAdd(uint32_t n, const float* __restrict yp, const float* __restrict phi, float c, float* __restrict y1,
                       float* __restrict y2, const float* __restrict w) noexcept {
    const V4 C = {c, c, c, c};
    return sumGroups(n, [&](uint32_t k) {
        const V4 Y = load4(yp + k) + C * load4(phi + k), Y1 = load4(y1 + k);
        store4(y2 + k, Y1), store4(y1 + k, Y);
        return load4(w + k) * (Y - Y1);
    });
}
// stepModes with a force f[k] added to each mode's displacement (predicted, forced and committed in one pass).
inline float stepForced(uint32_t n, const float* __restrict a1, const float* __restrict a2, float* __restrict y1,
                        float* __restrict y2, const float* __restrict w, const float* __restrict f) noexcept {
    return sumGroups(n, [&](uint32_t k) {
        const V4 Y1 = load4(y1 + k), Y = load4(a1 + k) * Y1 - load4(a2 + k) * load4(y2 + k) + load4(f + k);
        store4(y2 + k, Y1), store4(y1 + k, Y);
        return load4(w + k) * (Y - Y1);
    });
}
inline float stepModes(uint32_t n, const float* __restrict a1, const float* __restrict a2, float* __restrict y1,
                       float* __restrict y2, const float* __restrict w) noexcept {
    return sumGroups(n, [&](uint32_t k) {
        const V4 Y1 = load4(y1 + k), Y = load4(a1 + k) * Y1 - load4(a2 + k) * load4(y2 + k);
        store4(y2 + k, Y1), store4(y1 + k, Y);
        return load4(w + k) * (Y - Y1);
    });
}

// Free ringing, n frames (n <= kCell): modes [from, to) (multiples of 4) four at a time, each group kept in registers
// over the frames, each frame's weighted velocity sum w (y - y1) added into acc[t] group by group in order. The
// same function steps one frame (n = 1) or a whole span, so the two give the same bits: a piece may ring a span at
// a time while nothing touches it and frame by frame otherwise, at any block size.
CAW_ACOU_KERNEL void ringGroups(const float* __restrict a1, const float* __restrict a2, float* __restrict y1, float* __restrict y2,
                                  const float* __restrict w, uint32_t from, uint32_t to, V4* __restrict acc, uint32_t n) noexcept {
    for (uint32_t k = from; k < to; k += 4) {
        const V4 A1 = load4(a1 + k), A2 = load4(a2 + k), W = load4(w + k);
        V4 Y1 = load4(y1 + k), Y2 = load4(y2 + k);
        CAW_ONE_BODY
        for (uint32_t t = 0; t < n; ++t) {
            const V4 Y = A1 * Y1 - A2 * Y2;
            acc[t] = acc[t] + W * (Y - Y1);
            Y2 = Y1, Y1 = Y;
        }
        store4(y1 + k, Y1), store4(y2 + k, Y2);
    }
}

// Each frame's sum of its four lanes (the same kernel for one frame and a span).
CAW_ACOU_KERNEL void sumAcc(const V4* __restrict acc, float* __restrict out, uint32_t n) noexcept {
    CAW_ONE_BODY
    for (uint32_t t = 0; t < n; ++t) out[t] = sum4(acc[t]);
}

// Whether a stick stays still for the next n frames: idle, or a delayed one whose wait outlasts them.
inline bool stillFor(const Striker& s, uint32_t n) noexcept { return !s.active || s.delay >= n; }
// Its wait, n frames on (as n calls of due() leave it).
inline void waitOut(Striker& s, uint32_t n) noexcept {
    if (s.active) s.delay -= n;
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
    // (each a multiple of 4: the kernels run in fours)
    static constexpr Counts kKick[3] = {{12, 4, 4}, {24, 8, 4}, {48, 16, 8}};
    static constexpr Counts kSnare[3] = {{16, 8, 4}, {32, 12, 8}, {48, 16, 8}};
    static constexpr Counts kTom[3] = {{12, 4, 4}, {24, 8, 4}, {48, 16, 8}};
    const Counts* c = kind == kPieceKick ? kKick : (kind == kPieceSnare ? kSnare : kTom);
    return c[q < 0 ? 0 : (q > 2 ? 2 : q)];
}

}  // namespace

// ---------- Setup ----------

bool AcousticKit::prepare(double sampleRate) {
    sr_ = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
    dt_ = 1.0 / sr_;
    (void)membrane();  // built here, not on the audio thread
    uint32_t size = 64;
    while (size < static_cast<uint32_t>(sr_ * 0.008) + kCell + 4) size *= 2;  // the longest delay (2 m: 5.8 ms) and a span
    ohL_.assign(size, 0.0f);
    ohR_.assign(size, 0.0f);
    ohMask_ = size - 1;
    bleedDelay_ = static_cast<uint32_t>(sr_ * 0.0015) + 1;
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
    std::fill(ohL_.begin(), ohL_.end(), 0.0f);
    std::fill(ohR_.begin(), ohR_.end(), 0.0f);
    std::fill(ring_, ring_ + kRing, 0.0f);
    awake_ = 0;
    clock_ = 0;
    cellFrames_ = 0;
    ohAt_ = 0;
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
    p.cs[i] = static_cast<float>(cosr(om));
    p.sn[i] = static_cast<float>(lib::fastSinCycles(om * (1.0 / kTwoPi)));
    p.a1[i] = p.a1b[i] = p.a1n[i] = static_cast<float>(2.0 * r * cosr(om));
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
                p.psiT[k][wi] = p.psiW[wi][k] = static_cast<float>(v);
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
        // both plates in one pass: the gap reads +top -bottom at the edge, the force pushes them apart
        for (uint32_t k = 0; k < top; ++k) p.hatEta[k] = p.phiEdge[k], p.hatPush[k] = -p.seg[0].g * p.phiEdge[k];
        for (uint32_t k = top; k < top + bottom; ++k) p.hatEta[k] = -p.phiEdge[k], p.hatPush[k] = p.seg[1].g * p.phiEdge[k];
        for (uint32_t k = top; k < top + bottom; ++k) p.w[k] *= 0.7f;  // the bottom plate radiates less (under the top)
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
        // The low modes the products read (sat is worked out up to the highest, in fours).
        uint32_t top = 0;
        for (uint32_t t = 0; t < p.triplets; ++t) top = std::max<uint32_t>(top, std::max(p.ti[t], p.tj[t]) + 1u);
        p.satTop = std::min<uint32_t>(p.seg[0].count, (top + 3u) & ~3u);
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
    const uint32_t most = ohMask_ > kCell ? ohMask_ - kCell : 0;
    p.ohDelayL = std::min<uint32_t>(most, static_cast<uint32_t>(dl / 343.0 * sr_));
    p.ohDelayR = std::min<uint32_t>(most, static_cast<uint32_t>(dr / 343.0 * sr_));
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

// A drum ringing on its own for n frames from frame t0 of the span: every mode, then the few point forces (the heads'
// air, the sympathetic drive) on the batter's and the resonant head's lowest group, stepped frame by frame with them.
// out[t]: the radiated sum; vel[t] (when not null): the snare-side head's two lowest modes' speed (Eco's wire gate).
CAW_ACOU_KERNEL void AcousticKit::ringDrum(Piece& p, uint32_t t0, uint32_t n, uint64_t clock, float* out, float* vel) noexcept {
    const Segment b = p.seg[0], r = p.seg[1], sh = p.seg[2];
    const uint32_t all = b.count + r.count + sh.count;
    const float gb = b.g, gr = r.g;
    const bool snare = p.set.kind == kPieceSnare;
    float* const y1 = p.y1;
    float* const y2 = p.y2;
    V4 acc[kCell];
    // The rest of the kit, kLag frames back (all before this span): it drives the snare-side head (the wires buzz
    // with the kick) and a tom's lowest modes (sympathetic ring).
    float drive[kCell];
    for (uint32_t t = 0; t < n; ++t) {
        acc[t] = V4{0.0f, 0.0f, 0.0f, 0.0f};
        const uint32_t back = static_cast<uint32_t>(clock + t0 + t - kLag) & (kRing - 1);
        drive[t] = p.symp > 0.0f ? ring_[back] - p.own[back] : 0.0f;
    }
    const float kB = snare ? 0.0f : gb * p.symp * 0.3f, kR = snare ? gr * p.symp * 8.0f : 0.0f;
    {
        // The two coupled groups (batter b.at.., resonant head r.at..), frame by frame: the heads' air between their
        // lowest modes, the drive on the batter's two lowest or the snare-side head's first and third. Each force
        // is radiated with the motion it causes (w (y + F - y1)).
        const uint32_t kb = b.at, kr = r.at;
        const V4 A1b = load4(p.a1 + kb), A2b = load4(p.a2 + kb), Wb = load4(p.w + kb);
        const V4 A1r = load4(p.a1 + kr), A2r = load4(p.a2 + kr), Wr = load4(p.w + kr);
        V4 Y1b = load4(y1 + kb), Y2b = load4(y2 + kb), Y1r = load4(y1 + kr), Y2r = load4(y2 + kr);
        const float airK = p.airK;
        CAW_ONE_BODY
        for (uint32_t t = 0; t < n; ++t) {
            const float fAir = airK * (Y1b[0] - Y1r[0]);
            const float symB = kB * drive[t], symR = kR * drive[t];
            const float db0 = symB - gb * fAir, dr0 = gr * fAir + symR;
            const V4 Fb = {db0, symB, 0.0f, 0.0f}, Fr = {dr0, 0.0f, 0.6f * symR, 0.0f};
            const V4 Yb = A1b * Y1b - A2b * Y2b + Fb;
            const V4 Yr = A1r * Y1r - A2r * Y2r + Fr;
            acc[t] = acc[t] + Wb * (Yb - Y1b) + Wr * (Yr - Y1r);
            Y2b = Y1b, Y1b = Yb;
            Y2r = Y1r, Y1r = Yr;
            if (vel) vel[t] = std::fabs(Y1r[0] - Y2r[0]) + std::fabs(Y1r[1] - Y2r[1]);
        }
        store4(y1 + kb, Y1b), store4(y2 + kb, Y2b), store4(y1 + kr, Y1r), store4(y2 + kr, Y2r);
    }
    ringGroups(p.a1, p.a2, y1, y2, p.w, b.at + 4, r.at, acc, n);
    ringGroups(p.a1, p.a2, y1, y2, p.w, r.at + 4, all, acc, n);
    sumAcc(acc, out, n);
}

// The snare wires against the resonant head: mass-spring each, pressed into the head, a one-sided power-law contact
// solved per wire with the head's response (all wires at once: they vectorize). ypR: the head's lowest kResoWireModes
// modes as predicted; back: what their forces take from each of those modes (gr times it is subtracted), set when the
// return (their total force) is above 0. Steps the wires.
float AcousticKit::wireForces(Piece& p, const float* __restrict ypR, float* __restrict back) noexcept {
    // The tiers' wire counts (Normal 8, High 16) as constants: the loops run whole in fours.
    return p.wires == 16 ? wiresOf<16>(p, ypR, back, static_cast<float>(dt_)) : wiresOf<8>(p, ypR, back, static_cast<float>(dt_));
}
template <uint32_t NW>
float AcousticKit::wiresOf(Piece& p, const float* __restrict ypR, float* __restrict back, float dt) noexcept {
    static_assert(NW % 4 == 0 && NW <= kMaxWires && kResoWireModes % 4 == 0);
    // Each wire's head displacement under it, u = sum_k psi[k][w] y_k, four wires at a time.
    V4 U[NW / 4];
    for (uint32_t j = 0; j < NW / 4; ++j) U[j] = V4{0.0f, 0.0f, 0.0f, 0.0f};
    for (uint32_t k = 0; k < kResoWireModes; ++k) {
        const V4 y = V4{ypR[k], ypR[k], ypR[k], ypR[k]};
        for (uint32_t j = 0; j < NW / 4; ++j) U[j] = U[j] + load4(p.psiT[k] + 4 * j) * y;
    }
    alignas(16) float u[NW], F[NW];
    for (uint32_t j = 0; j < NW / 4; ++j) store4(u + 4 * j, U[j]);
    // The wires' state through unaliased pointers (so the loop vectorizes).
    float* __restrict wx = p.wx;
    float* __restrict wv = p.wv;
    float* __restrict wDPrev = p.wDPrev;
    const float* __restrict wC = p.wC;
    const float wOm2 = p.wOm2, wRest = p.wRest, wDampK = p.wDampK, wK = p.wK, wMass = p.wMass;
    float fWires = 0.0f;
    for (uint32_t w = 0; w < NW; ++w) {
        const float acc = -wOm2 * (wx[w] - wRest) - wDampK * wv[w];
        const float vP = wv[w] + acc * dt;
        const float xP = wx[w] + vP * dt;
        const float eta = u[w] - xP;  // > 0: the head is past the wire (they touch)
        const float e = eta > 0.0f ? eta : 0.0f;
        const float sq = std::sqrt(e);
        float f = wK * e * sq / (1.0f + 1.5f * wK * sq * wC[w]);
        f *= 1.0f + 0.2f * (e - wDPrev[w]) / dt;
        f = f > 0.0f ? f : 0.0f;
        wDPrev[w] = e - f * wC[w];
        wv[w] = vP + f * dt / wMass;
        wx[w] += wv[w] * dt;
        F[w] = f;
        fWires += f;
    }
    if (fWires > 0.0f) {  // the forces back into the head's modes, a wire at a time (no per-mode sums)
        V4 B[kResoWireModes / 4];
        for (uint32_t j = 0; j < kResoWireModes / 4; ++j) B[j] = V4{0.0f, 0.0f, 0.0f, 0.0f};
        for (uint32_t w = 0; w < NW; ++w) {
            const V4 f = V4{F[w], F[w], F[w], F[w]};
            for (uint32_t j = 0; j < kResoWireModes / 4; ++j) B[j] = B[j] + load4(p.psiW[w] + 4 * j) * f;
        }
        for (uint32_t j = 0; j < kResoWireModes / 4; ++j) store4(back + 4 * j, B[j]);
    }
    p.rattleEnergy += static_cast<double>(fWires) * fWires;
    return fWires;
}

void AcousticKit::runDrum(Piece& p, uint32_t n, uint64_t clock) noexcept {
    const float scale = static_cast<float>(sr_) * p.gain;
    const bool snare = p.set.kind == kPieceSnare, eco = p.quality == 0;
    // The rattle (the collisions' force changing: radiated sound goes with its rate), high-passed (two poles at 3 kHz):
    // the wires' clicks against the head; Eco: noise gated by the snare-side head's motion (`vel`).
    auto rattleOf = [&](float fWires, float vel) {
        float rattle = 0.0f;
        if (snare && p.rattleGain > 0.0f) {
            float x = (fWires - p.lastF) * 0.02f;
            p.lastF = fWires;
            if (eco) {
                p.wireGate += 0.01f * (vel * scale - p.wireGate);
                x = unit(p.rng) * std::max(0.0f, p.wireGate - 0.0005f) * 0.05f;
            }
            p.rattleHp[0] = p.rattleK * p.rattleHp[0] + (1.0f - p.rattleK) * x;
            const float h = x - p.rattleHp[0];
            p.rattleHp[1] = p.rattleK * p.rattleHp[1] + (1.0f - p.rattleK) * h;
            rattle = (h - p.rattleHp[1]) * p.rattleGain;
        }
        return rattle;
    };
    // The modes first (each frame's radiated sum, the wires' force and the snare-side head's speed), then the rattle
    // and the noises over the span, one loop whichever way the modes ran.
    float mo[kCell], fw[kCell], vs[kCell];
    for (uint32_t t = 0; t < n; ++t) fw[t] = vs[t] = 0.0f;
    if (!p.wires && !p.rim.active && stillFor(p.stick[0], n) && stillFor(p.stick[1], n)) {
        // Nothing can touch it this span (no stick due, no rim, no wires): it rings a span at a time.
        waitOut(p.stick[0], n), waitOut(p.stick[1], n);
        ringDrum(p, 0, n, clock, mo, snare && eco ? vs : nullptr);
    } else {
        modesDrum(p, n, clock, mo, fw, vs);
    }
    for (uint32_t t = 0; t < n; ++t) {
        const float rattle = rattleOf(fw[t], vs[t]);
        p.out[t] = mo[t] * scale + rattle + noiseSample(p);
    }
}

// A drum frame by frame (a stick, the rim or the wires may touch): mo, fw and vs as runDrum keeps them.
void AcousticKit::modesDrum(Piece& p, uint32_t n, uint64_t clock, float* mo, float* fw, float* vs) noexcept {
    const Segment b = p.seg[0], r = p.seg[1], sh = p.seg[2];
    const uint32_t all = b.count + r.count + sh.count;
    const float gb = b.g, gr = r.g, gs = sh.g;
    const bool snare = p.set.kind == kPieceSnare, eco = p.quality == 0;
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
        float out = 0.0f, fWires = 0.0f, vel = 0.0f;
        if (!ca && !cb && !rim && !p.wires) {
            // Ringing on its own this frame: the span kernel for one frame (the same bits as a span at a time).
            ringDrum(p, t, 1, clock, &out, snare && eco ? &vel : nullptr);
        } else if (!ca && !cb && !rim) {
            // Only the wires touch (most of a snare's frames): the snare-side head's lowest modes are predicted
            // first, with their point forces, for the wires to press against; then every force goes in as the modes
            // step, in one pass.
            // (The forces sit on the batter's first group and the head's first kResoWireModes modes: r.count >= 12
            // wherever there are wires.)
            alignas(16) float fb[4] = {symB - gb * fAir, symB, 0.0f, 0.0f}, fr[kResoWireModes], ypR[kResoWireModes], back[kResoWireModes];
            for (uint32_t j = 0; j < kResoWireModes; j += 4) {
                const uint32_t i = r.at + j;
                const V4 F = j == 0 ? V4{gr * fAir + symR, 0.0f, 0.6f * symR, 0.0f} : V4{0.0f, 0.0f, 0.0f, 0.0f};
                store4(fr + j, F);
                store4(ypR + j, load4(p.a1 + i) * load4(y1 + i) - load4(p.a2 + i) * load4(y2 + i) + F);
            }
            fWires = wireForces(p, ypR, back);
            if (fWires > 0.0f)
                for (uint32_t j = 0; j < kResoWireModes; j += 4) store4(fr + j, load4(fr + j) - V4{gr, gr, gr, gr} * load4(back + j));
            out = stepForced(4, p.a1, p.a2, y1, y2, p.w, fb);
            out += stepModes(r.at - 4, p.a1 + 4, p.a2 + 4, y1 + 4, y2 + 4, p.w + 4);
            out += stepForced(kResoWireModes, p.a1 + r.at, p.a2 + r.at, y1 + r.at, y2 + r.at, p.w + r.at, fr);
            const uint32_t past = r.at + kResoWireModes;
            out += stepModes(all - past, p.a1 + past, p.a2 + past, y1 + past, y2 + past, p.w + past);
            vel = std::fabs(y1[r.at] - y2[r.at]) + std::fabs(y1[r.at + 1] - y2[r.at + 1]);
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
                alignas(16) float back[kResoWireModes];
                fWires = wireForces(p, yp + r.at, back);
                if (fWires > 0.0f)
                    for (uint32_t k = 0; k < kResoWireModes; ++k) yp[r.at + k] -= gr * back[k];
            }
            out = commitModes(all, yp, y1, y2, p.w);
            vel = std::fabs(y1[r.at] - y2[r.at]) + std::fabs(y1[r.at + 1] - y2[r.at + 1]);
        }
        mo[t] = out, fw[t] = fWires, vs[t] = vel;
    }
}

void AcousticKit::runCymbal(Piece& p, uint32_t n, uint64_t clock) noexcept {
    (void)clock;
    const Segment s = p.seg[0];
    const float scale = static_cast<float>(sr_) * p.gain;
    // Eco's substitute for the cascade: band-limited noise growing with the low modes' energy.
    auto swellOf = [&]() {
        float x = unit(p.rng) * std::sqrt(std::max(0.0f, p.swellEnv)) * p.swellGain;
        const float h = x - p.swellHp[0];
        p.swellHp[0] += 0.35f * h;
        x = h;
        p.swellLp += 0.6f * (x - p.swellLp);
        return p.swellLp;
    };
    // The modes first (each frame's radiated sum), then the swell and the noises over the span, one loop whichever
    // way the modes ran.
    float mo[kCell];
    if (!p.triplets && stillFor(p.stick[0], n) && stillFor(p.stick[1], n)) {
        // No cascade and nothing touching it this span: it rings a span at a time (the same kernel as one frame).
        waitOut(p.stick[0], n), waitOut(p.stick[1], n);
        V4 acc[kCell];
        for (uint32_t t = 0; t < n; ++t) acc[t] = V4{0.0f, 0.0f, 0.0f, 0.0f};
        ringGroups(p.a1, p.a2, p.y1, p.y2, p.w, 0, s.count, acc, n);
        sumAcc(acc, mo, n);
    } else {
        modesCymbal(p, n, mo);
    }
    for (uint32_t t = 0; t < n; ++t) {
        float out = mo[t] * scale;
        if (p.swellGain > 0.0f) out += swellOf();  // Eco's substitute for the cascade
        p.out[t] = out + noiseSample(p);
    }
}

// A cymbal frame by frame (a stick may touch, or the cascade drives it): mo as runCymbal keeps it.
void AcousticKit::modesCymbal(Piece& p, uint32_t n, float* mo) noexcept {
    const Segment s = p.seg[0];
    const float g = s.g;
    alignas(32) float yp[kMaxModes], sat[kMaxModes];
    for (uint32_t t = 0; t < n; ++t) {
        Striker& sa = p.stick[0];
        Striker& sb = p.stick[1];
        const bool ca = due(sa);
        const bool cb = due(sb);
        float out;
        if (!ca && !cb && !p.triplets) {
            V4 acc[1] = {V4{0.0f, 0.0f, 0.0f, 0.0f}};
            ringGroups(p.a1, p.a2, p.y1, p.y2, p.w, 0, s.count, acc, 1);
            sumAcc(acc, &out, 1);
        } else if (!ca && !cb) {
            // Only the cascade (most of a ringing cymbal's frames): its forces come from the last frame's motion,
            // so they are worked out first and go in as the modes step, in one pass.
            alignas(32) float fz[kMaxModes];
            const uint32_t lo = p.tk[0], hi = lo + p.triplets;  // the driven modes (multiples of 4)
            const float inv = 1.0f / p.satY;
            for (uint32_t k = 0; k < p.satTop; ++k) sat[k] = p.y1[k] / (1.0f + std::fabs(p.y1[k]) * inv);
            for (uint32_t q = 0; q < p.triplets; ++q) fz[q] = p.tc[q] * sat[p.ti[q]] * sat[p.tj[q]];
            out = stepModes(lo, p.a1, p.a2, p.y1, p.y2, p.w);
            out += stepForced(hi - lo, p.a1 + lo, p.a2 + lo, p.y1 + lo, p.y2 + lo, p.w + lo, fz);
            out += stepModes(s.count - hi, p.a1 + hi, p.a2 + hi, p.y1 + hi, p.y2 + hi, p.w + hi);
        } else {
            predictModes(s.count, p.a1, p.a2, p.y1, p.y2, yp);
            if (p.triplets) {
                // the cascade: F_k = c s_i s_j (s: the low modes, softly limited), already scaled by g
                const float inv = 1.0f / p.satY;
                for (uint32_t k = 0; k < p.satTop; ++k) sat[k] = p.y1[k] / (1.0f + std::fabs(p.y1[k]) * inv);
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
        mo[t] = out;
    }
}

void AcousticKit::runHat(Piece& p, uint32_t n, uint64_t clock) noexcept {
    (void)clock;
    const Segment top = p.seg[0], bot = p.seg[1];
    const float gt = top.g;
    const float dt = static_cast<float>(dt_);
    const float scale = static_cast<float>(sr_) * p.gain;
    const uint32_t all = top.count + bot.count;
    alignas(32) float yp[kMaxModes];
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
            out = stepModes(all, p.a1, p.a2, p.y1, p.y2, p.w);
            p.hatDPrev = -zP;
        } else {
            // The plates' contact near the edge (down positive: the top plate sits zP above the bottom one).
            const float eta = predictDot(all, p.a1, p.a2, p.y1, p.y2, yp, p.hatEta) - zP;
            float Fc = 0.0f;
            if (eta > 0.0f) {
                const float sq = std::sqrt(eta);
                Fc = p.hatK * eta * sq / (1.0f + 1.5f * p.hatK * sq * p.hatC);
                Fc *= 1.0f + 0.3f * (eta - p.hatDPrev) / dt;
                if (Fc < 0.0f) Fc = 0.0f;
            }
            p.hatDPrev = eta - Fc * p.hatC;
            vz += Fc * dt / 0.4f;
            p.hatPressureSum += Fc;  // frame by frame into the cell's sum: the same at any block size
            if (!ca && !cb) {  // only the plates' force: added as the modes commit (one pass)
                out = commitAdd(all, yp, p.hatPush, Fc, p.y1, p.y2, p.w);
            } else {
                if (Fc > 0.0f) addModes(all, yp, p.hatPush, Fc);
                // the stick pushes the top plate on its felt clutch down toward the bottom one, as well as bending it
                if (ca) {
                    const float F = stickForce(sa, dotModes(top.count, p.phiA, yp) + sa.ref - zP);
                    if (F > 0.0f) addModes(top.count, yp, p.phiA, gt * F), vz -= F * dt / 0.4f;
                }
                if (cb) {
                    const float F = stickForce(sb, dotModes(top.count, p.phiB, yp) + sb.ref - zP);
                    if (F > 0.0f) addModes(top.count, yp, p.phiB, gt * F), vz -= F * dt / 0.4f;
                }
                out = commitModes(all, yp, p.y1, p.y2, p.w);
            }
        }
        p.hatV = vz;
        p.hatZ += vz * dt;
        p.out[t] = out * scale + noiseSample(p);
    }
    // (the cell's end turns hatPressureSum into the plates' damping: endCell)
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
    // cos(w (1 + g)) = cos w cos(wg) - sin w sin(wg), the small angle wg by its series (wg < 0.25 rad here)
    const float db = p.seg[0].damp, drr = p.seg[1].damp;
    for (uint32_t k = 0; k < b.count + r.count; ++k) {
        const float x = p.om[k] * g, x2 = x * x;
        const float c = 1.0f - x2 * (0.5f - x2 * (1.0f / 24.0f)), s = x * (1.0f - x2 * (1.0f / 6.0f));
        p.a1b[k] = 2.0f * p.rr[k] * (p.cs[k] * c - p.sn[k] * s);
        p.a1[k] = p.a1b[k] * (k < b.count ? db : drr);
    }
}

void AcousticKit::process(double* left, double* right, double* room, uint32_t n) noexcept {
    if (awake_) span(left, right, room, n);
}

void AcousticKit::span(double* left, double* right, double* room, uint32_t n) noexcept {
    // The pieces' sums for this span: raw (the sympathetic drive), the close mics and the bleed bus (one delay for
    // every piece, so it is summed here and added to the overhead rings once).
    float sum[kCell], closeL[kCell], closeR[kCell], bleed[kCell];
    for (uint32_t t = 0; t < n; ++t) sum[t] = closeL[t] = closeR[t] = bleed[t] = 0.0f;
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
        // Mics: close (panned), the overhead pair (delayed by distance: added where it will be heard), the room send
        // and the bleed bus (every close mic hearing the others 1.5 ms late, centred).
        float* const ohl = ohL_.data();
        float* const ohr = ohR_.data();
        const uint32_t mask = ohMask_, dl = ohAt_ + p.ohDelayL, dr = ohAt_ + p.ohDelayR;
        const float level = level_, cl = p.closeL * level, cr = p.closeR * level, gl = p.ohL * level, gr = p.ohR * level,
                    bl = p.bleedSend * level * bleedGain_ * 0.7f, rs = p.roomSend * level;
        for (uint32_t t = 0; t < n; ++t) {
            const float y = p.out[t];
            sum[t] += y;
            p.own[(clock_ + t) & (kRing - 1)] = y;
            closeL[t] += y * cl;
            closeR[t] += y * cr;
            bleed[t] += y * bl;
        }
        for (uint32_t t = 0; t < n; ++t) ohl[(dl + t) & mask] += p.out[t] * gl;
        for (uint32_t t = 0; t < n; ++t) ohr[(dr + t) & mask] += p.out[t] * gr;
        if (room)
            for (uint32_t t = 0; t < n; ++t) room[t] += p.out[t] * rs;
    }
    for (uint32_t t = 0; t < n; ++t) {
        const uint32_t at = (ohAt_ + bleedDelay_ + t) & ohMask_;
        ohL_[at] += bleed[t];
        ohR_[at] += bleed[t];
    }
    // The rings' slots for these frames: heard now, then cleared for their next turn.
    for (uint32_t t = 0; t < n; ++t) {
        const uint32_t at = (ohAt_ + t) & ohMask_;
        left[t] += closeL[t];
        right[t] += closeR[t];
        left[t] += ohL_[at];
        right[t] += ohR_[at];
        ohL_[at] = ohR_[at] = 0.0f;
        ring_[(clock_ + t) & (kRing - 1)] = sum[t];
    }
    ohAt_ = (ohAt_ + n) & ohMask_;
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
        // Denormal guard (for the targets without flush-to-zero, fp_mode.h): a mode, wire or filter far below
        // hearing is set to exact zero, so it never computes as a subnormal.
        const uint32_t all = p.seg[0].count + p.seg[1].count + p.seg[2].count;
        for (uint32_t k = 0; k < all; ++k) {
            const bool tiny = std::fabs(p.y1[k]) < 1e-20f && std::fabs(p.y2[k]) < 1e-20f;
            p.y1[k] = tiny ? 0.0f : p.y1[k];
            p.y2[k] = tiny ? 0.0f : p.y2[k];
        }
        for (float* f : {&p.rattleHp[0], &p.rattleHp[1], &p.wireGate, &p.swellHp[0], &p.swellLp, &p.noiseLp, &p.swellEnv})
            if (std::fabs(*f) < 1e-20f) *f = 0.0f;
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
        std::fill(ohL_.begin(), ohL_.end(), 0.0f);
        std::fill(ohR_.begin(), ohR_.end(), 0.0f);
    }
}

void AcousticKit::silence(uint32_t i) noexcept {
    quietState(pieces_[i]);
    awake_ &= ~(1u << i);
}

// A piece at rest: every state to exact zero, its tuning and damping as configured (no re-tuning: cheap to sleep).
void AcousticKit::quietState(Piece& p) noexcept {
    const uint32_t all = p.seg[0].count + p.seg[1].count + p.seg[2].count;
    for (uint32_t k = 0; k < all; ++k) {
        p.y1[k] = p.y2[k] = 0.0f;
        p.a1[k] = p.a1b[k] = p.a1n[k];
        p.a2[k] = p.a2b[k];
    }
    for (Segment& sg : p.seg) sg.damp = 1.0f;
    for (uint32_t w = 0; w < kMaxWires; ++w) p.wx[w] = p.wv[w] = p.wDPrev[w] = 0.0f;
    p.stick[0] = p.stick[1] = p.rim = Striker{};
    p.rattleHp[0] = p.rattleHp[1] = p.lastF = p.wireGate = 0.0f;
    p.rattleEnergy = 0.0;
    p.glideNow = 0.0f;
    p.swellEnv = p.swellHp[0] = p.swellHp[1] = p.swellLp = 0.0f;
    p.hatV = p.hatDPrev = p.hatPressure = p.hatPressureSum = p.hatFootBoost = 0.0f;
    p.hatZ = p.hatTarget;
    p.noiseLeft = 0;
    p.noiseLp = 0.0f;
    p.rolling = false;
    p.quietFrames = 0;
    p.peak = 0.0f;
    p.awake = false;
    std::fill(p.own, p.own + kRing, 0.0f);
}

uint32_t AcousticKit::awakeCount() const noexcept {
    uint32_t c = 0;
    for (uint32_t i = 0; i < kPieces; ++i) c += (awake_ >> i) & 1u;
    return c;
}

}  // namespace caw::drums::acoustic
