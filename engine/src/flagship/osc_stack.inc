// Flagship's oscillator: warps, decimators, per-voice state and the unison stack's copy loops (hand-written; included by builtin_flagship.cpp, not compiled alone).
// ---------- One oscillator's unison stack, per voice ----------

inline float whole(float t) noexcept { return static_cast<float>(static_cast<int32_t>(t)); }  // floor, for t >= 0

// sin(2 pi u) for u >= 0 (cycles), within about 0.001 of the true sine: a parabola refined once (no trig, no
// branch). The FM warp's modulator; at this error it is a slightly different timbre, not noise.
inline float sineCycles(float u) noexcept {
    const float x = 2.0f * (u - whole(u)) - 1.0f;  // -1..1: sin(2 pi u) = -sin(pi x)
    const float y = 4.0f * x * (1.0f - std::fabs(x));
    return -(y + 0.225f * (y * std::fabs(y) - y));
}

// The phase t (0..1) after the warp. w1, w2 are worked out at the control rate.
template <int W>
inline float warp(float t, float w1, float w2, float w3) noexcept {
    if constexpr (W == kWarpFm) {
        // Phase modulation by a sine w2 (a whole number) times per cycle, depth w1 cycles (below 1): the cycle
        // stays periodic, so FM at a harmonic ratio costs one table read like the other warps.
        float y = t + w1 * sineCycles(w2 * t) + 1.0f;
        y -= whole(y);
        return y < 0.99999994f ? y : 0.99999994f;
    } else if constexpr (W == kWarpBend) {
        const float y = t * (1.0f + w1 * (1.0f - t));  // pulls the cycle's start forward: 0 and 1 stay put
        return y < 0.99999994f ? y : 0.99999994f;
    } else if constexpr (W == kWarpSync) {
        const float s = t * w1;  // hard sync: the table runs w1 times per cycle, restarting with it
        return s - whole(s);
    } else if constexpr (W == kWarpMirror) {
        const float y = t < w1 ? t * w2 : (1.0f - t) * w3;  // forward to the turn w1, then back
        return y < 0.99999994f ? y : 0.99999994f;
    } else if constexpr (W == kWarpQuantize) {
        return whole(t * w1) * w2;  // w1 steps per cycle
    } else {
        return t;
    }
}

// What an oscillator's copies are worked out from: when none of it moves, a control skips them.
struct OscKey {
    int table = -1;
    double position = 0, level = 0, pan = 0, pitch = 0, amount = 0;
    int warp = 0;
    int fmRatio = 1;
    double modRatio = 1.0;  // Osc FM: the modulating oscillator's pitch over this one's (its octave, semitones, fine)
    bool once = false;      // the FM warp at the sample rate (Eco quality), not at twice it
    bool foldWhole = false;  // the fold warp on the stack's sum (Whole stack), not on each copy (Per copy)
    bool foldTwice = false;  // the fold warp at twice the rate (a high note: Voice::foldTwice), not with ADAA
    lib::UnisonSettings unison{-1};
    const void* bank = nullptr;  // a spectral warp's bank (null: none, or not built yet)
    bool operator==(const OscKey&) const = default;
};

// The FM and the high fold's 2x decimator for one side (the half-band all-pass pair of lib::Oversampler2x's down()): per
// stage, lane 0 the even branch's all-pass and lane 1 the odd one's, each lane lib::AllpassChain's arithmetic.
// A block at a time with the state in registers, and a stereo pair's two sides in one loop (four independent
// all-pass chains): each lane's arithmetic is one chain's, per branch and side, sample by sample (speed A2,
// 2026-11-12), so the same within the tolerance tests and bit-identical on the builds checked.
struct Decimator2x {
    static constexpr int kStages = 4;  // per branch: lib::HalfBandDesign(2 * kStages)
    alignas(16) double a[kStages][2] = {};
    alignas(16) double x1[kStages][2] = {}, y1[kStages][2] = {};
    double held = 0.0;
    void set(const lib::HalfBandDesign& d) noexcept {
        for (int i = 0; i < kStages; ++i)
            for (int lane = 0; lane < 2; ++lane) a[i][lane] = d.coefficient(2 * i + lane);
        clear();
    }
    void clear() noexcept {
        for (int i = 0; i < kStages; ++i) x1[i][0] = x1[i][1] = y1[i][0] = y1[i][1] = 0.0;
        held = 0.0;
    }
    // out[f] += the low-rate sample of in[2f], in[2f + 1], for f < n; with `r`, rOut[f] += r's of rIn likewise.
    static void down(Decimator2x& l, const float* in, float* out, Decimator2x* r, const float* rIn, float* rOut,
                     uint32_t n) noexcept {
#if defined(__GNUC__)
        if (r) return downBlock<true>(l, in, out, *r, rIn, rOut, n);
        downBlock<false>(l, in, out, l, nullptr, nullptr, n);
#else
        l.downScalar(in, out, n);
        if (r) r->downScalar(rIn, rOut, n);
#endif
    }

private:
#if defined(__GNUC__)
    // Both sides use the left's coefficients: every decimator is set from the one design (set()), so the right's are
    // the same numbers, and x86-64's 16 vector registers hold one set without spilling (2026-11-27). The flush
    // below 1e-25 tests |o| < 1e-25, which is (o < 1e-25) & (o > -1e-25) for every o, NaN included (both false).
    template <bool Two>
    static void downBlock(Decimator2x& l, const float* in, float* out, Decimator2x& r, const float* rIn, float* rOut,
                          uint32_t n) noexcept {
        typedef long long Bits __attribute__((vector_size(16)));
        const Pair tiny = splat(1e-25), zero = splat(0.0);
        const Bits magnitude = {0x7FFFFFFFFFFFFFFFLL, 0x7FFFFFFFFFFFFFFFLL};
        Pair a[kStages], x[kStages], y[kStages], rx[kStages], ry[kStages];
        for (int i = 0; i < kStages; ++i) {
            a[i] = pairOf(l.a[i][0], l.a[i][1]), x[i] = pairOf(l.x1[i][0], l.x1[i][1]), y[i] = pairOf(l.y1[i][0], l.y1[i][1]);
            if constexpr (Two) rx[i] = pairOf(r.x1[i][0], r.x1[i][1]), ry[i] = pairOf(r.y1[i][0], r.y1[i][1]);
        }
        double held = l.held, rHeld = r.held;
        // y = a (x - y1) + x1 per stage, flushed below 1e-25, into the next stage (AllpassChain::process).
        const auto stage = [&](Pair v, Pair& s, Pair& t, Pair c) noexcept {
            Pair o = c * (v - t) + s;
            s = v;
            o = reinterpret_cast<Pair>(reinterpret_cast<Bits>(o) & magnitude) < tiny ? zero : o;
            t = o;
            return o;
        };
        for (uint32_t f = 0; f < n; ++f) {
            Pair v = pairOf(static_cast<double>(in[2 * f]), held);
            held = in[2 * f + 1];
            Pair w = zero;
            if constexpr (Two) {
                w = pairOf(static_cast<double>(rIn[2 * f]), rHeld);
                rHeld = rIn[2 * f + 1];
            }
            for (int i = 0; i < kStages; ++i) {
                v = stage(v, x[i], y[i], a[i]);
                if constexpr (Two) w = stage(w, rx[i], ry[i], a[i]);
            }
            out[f] += static_cast<float>(0.5 * (lane(v, 0) + lane(v, 1)));
            if constexpr (Two) rOut[f] += static_cast<float>(0.5 * (lane(w, 0) + lane(w, 1)));
        }
        for (int i = 0; i < kStages; ++i) {
            l.x1[i][0] = lane(x[i], 0), l.x1[i][1] = lane(x[i], 1), l.y1[i][0] = lane(y[i], 0), l.y1[i][1] = lane(y[i], 1);
            if constexpr (Two)
                r.x1[i][0] = lane(rx[i], 0), r.x1[i][1] = lane(rx[i], 1), r.y1[i][0] = lane(ry[i], 0), r.y1[i][1] = lane(ry[i], 1);
        }
        l.held = held;
        if constexpr (Two) r.held = rHeld;
    }
#else
    void downScalar(const float* in, float* out, uint32_t n) noexcept {
        for (uint32_t f = 0; f < n; ++f) {
            double v[2] = {static_cast<double>(in[2 * f]), held};
            held = in[2 * f + 1];
            for (int lane = 0; lane < 2; ++lane)
                for (int i = 0; i < kStages; ++i) {
                    const double o = a[i][lane] * (v[lane] - y1[i][lane]) + x1[i][lane];
                    x1[i][lane] = v[lane];
                    y1[i][lane] = o < 1e-25 && o > -1e-25 ? 0.0 : o;
                    v[lane] = y1[i][lane];
                }
            out[f] += static_cast<float>(0.5 * (v[0] + v[1]));
        }
    }
#endif
};

struct OscVoice {
    bool on = false;
    int dest = kToFilter1;
    int count = 0;  // copies in the stack
    int warpMode = kWarpNone;
    int modSrc = 0;     // the row of Voice::fmBuf (or the oscillator, for sync) its source warps hear
    bool blep = true;   // Osc sync's jumps band-limited (not at Eco)
    float w1 = 0.0f, w2 = 0.0f, w3 = 0.0f, mix = 0.0f;  // the warp's constants; the morph between frames a and b
    int f0 = -1, f1 = -1;                              // the frames a and b read
    // The table read: the oscillator's own, or a spectral warp's bank (frames base0 + f at the amount below, base1 + f
    // at the one above, amix between them). Without a bank: the table, both bases 0 and amix 0.
    const lib::Wavetable* reading = nullptr;
    const flagship::Bank* bank = nullptr;
    int base0 = 0, base1 = 0, frames = 1;
    float amix = 0.0f;
    bool bankPending = false;  // a spectral warp whose bank is not built yet: it plays unwarped and asks each control
    const float* ca[kMaxCopies] = {};  // with a bank: frames base1 + f0 and base1 + f1 (as a and b at base0)
    const float* cb[kMaxCopies] = {};
    // Copy c's frames at mip level k.
    void point(int c, int k) noexcept {
        a[c] = reading->levelData(base0 + f0, k);
        b[c] = reading->levelData(base0 + f1, k);
        if (bank) ca[c] = reading->levelData(base1 + f0, k), cb[c] = reading->levelData(base1 + f1, k);
    }
    double faster = 1.0;                               // how much faster than the note the warp reads the table
    double pitchOffset[3] = {};                        // octave, semitones and fine, in semitones
    uint32_t phase[kMaxCopies] = {};  // in 32-bit fixed point (2^32 a cycle): it wraps by itself, and steps exactly
    double dt[kMaxCopies] = {};  // cycles per sample; 0 for a copy above Nyquist (silent)
    const float* a[kMaxCopies] = {};
    const float* b[kMaxCopies] = {};
    float size[kMaxCopies] = {};
    uint32_t step[kMaxCopies] = {};  // dt in 32-bit fixed point (2^32 a cycle), for the unwarped read
    int shift[kMaxCopies] = {};      // 32 - log2(the mip level's size): a fixed-point phase's index bits
    int level[kMaxCopies] = {};      // the mip level each copy reads
    bool centred = false;            // every copy plays the same on both sides (no pan, no spread)
    float gainL[kMaxCopies] = {}, gainR[kMaxCopies] = {};
    float monoGain[kMaxCopies] = {};  // a quarter of the copy's pan gains' sum (added twice: the mid), before the level
    // The FM warp's and the 2x fold's decimators (left, right, and the copy Osc FM hears), state the render moves on.
    Decimator2x foldL, foldR, foldM;
    // The ADAA fold's anti-aliasing state (addFold), [0] for the render and [1] for the copy Osc FM hears: per copy, each
    // copy's last read value; whole stack, each side's last sum.
    float foldLast[2][kMaxCopies] = {};
    float foldSide[2][2] = {};
    float stackL[kMaxCopies] = {}, stackR[kMaxCopies] = {};  // the copies' pan gains before the level (Whole stack)
    float levelGain = 0.0f;                                   // the oscillator's level, after a whole stack's fold
    bool stackCentred = true;                                 // every copy's pan gains alike (one fold per sample)
    void clearFold() noexcept {
        std::memset(foldLast, 0, sizeof foldLast);
        std::memset(foldSide, 0, sizeof foldSide);
    }
    // The layout and pan gains, worked out again only when their settings change.
    lib::UnisonSettings layoutKey{-1};
    double panKey = 2.0;
    lib::UnisonVoice layout[kMaxCopies];
    double ratio[kMaxCopies] = {};
    double panL[kMaxCopies] = {}, panR[kMaxCopies] = {};
    double hz = 0.0;
    OscKey key;
};

// Four samples' reads of a copy: the interpolated values at the table indices k[0..3] (each read is the pair
// A[k], A[k + 1] in one 8-byte load, split apart in registers: simd4::pairs) with the fractions fr, morphed toward
// B's by mix. Each lane's arithmetic is the scalar read's, a + (b - a) fr then v + (u - v) mix, so the same bits.
template <bool Morph>
CAW_FORCE_INLINE simd4::F4 read4(const float* A, const float* B, const uint32_t* k, simd4::F4 fr, simd4::F4 mix) noexcept {
    using namespace simd4;
    F4 a0, a1;
    pairs(A, k, a0, a1);
    F4 v = a0 + (a1 - a0) * fr;
    if constexpr (Morph) {
        F4 b0, b1;
        pairs(B, k, b0, b1);
        const F4 u = b0 + (b1 - b0) * fr;
        v = v + (u - v) * mix;
    }
    return v;
}
// One sample's read, read4's arithmetic: the tails of a piece whose length is not a multiple of four.
template <bool Morph>
CAW_FORCE_INLINE float read1(const float* A, const float* B, uint32_t k, float fr, float mix) noexcept {
    float v = A[k] + (A[k + 1] - A[k]) * fr;
    if constexpr (Morph) {
        const float u = B[k] + (B[k + 1] - B[k]) * fr;
        v += (u - v) * mix;
    }
    return v;
}

// One unwarped copy's reads over N (or n) frames from the fixed-point phase p, each handed to out(i, v) four at a
// time (a simd4::F4 for frames i..i + 3) and then one at a time (a float) for a tail. The phase is 32-bit fixed point
// (2^32 a cycle), so it wraps by itself and its top bits are the table index: no floor, no float-to-int per sample.
// Four frames at a time in vectors (SSE2 on x86-64, NEON on Arm64): the indices and fractions, the table pairs
// (simd4::pairs: no store and reload of the pairs, the old three passes' cost), the interpolation and the morph.
// Each sample's arithmetic is the one-pass loop's, in its order, so the bits are the same (2026-11-27).
template <bool Morph, uint32_t N, class Out4, class Out1>
CAW_FORCE_INLINE void readFixed(const float* A, const float* B, uint32_t p, uint32_t step, int sh, float mix, uint32_t n,
                                const Out4& out4, const Out1& out1) noexcept {
    using namespace simd4;
    const uint32_t count = N ? N : n;
    const uint32_t mask = (1u << sh) - 1u;  // sh <= 31, so p & mask fits an int32 (a signed conversion)
    const float scale = 1.0f / static_cast<float>(1u << sh);
    const I4 m4 = splatU(mask), step4 = splatU(4u * step);
    const F4 sc = splat(scale), mx = splat(mix);
    I4 P = lanesU(p, p + step, p + 2u * step, p + 3u * step);
    uint32_t i = 0;
    for (; i + 4 <= count; i += 4) {
        alignas(16) uint32_t k[4];
        storeU(k, shiftRight(P, sh));
        const F4 fr = toFloat(P & m4) * sc;
        out4(i, read4<Morph>(A, B, k, fr, mx));
        P = P + step4;
    }
    p += i * step;
    for (; i < count; ++i, p += step)
        out1(i, read1<Morph>(A, B, p >> sh, static_cast<float>(static_cast<int32_t>(p & mask)) * scale, mix));
}

// One unwarped copy over N (or n) frames, added to L and R with its gains (L and R may be one buffer: R's sum is
// then taken after L's, as the scalar loop did).
template <bool Morph, uint32_t N>
CAW_FORCE_INLINE void addCopy(const float* A, const float* B, uint32_t p, uint32_t step, int sh, float gl, float gr,
                              float mix, float* L, float* R, uint32_t n) noexcept {
    using namespace simd4;
    const F4 l4 = splat(gl), r4 = splat(gr);
    readFixed<Morph, N>(
        A, B, p, step, sh, mix, n,
        [&](uint32_t i, F4 v) noexcept {
            store(L + i, load(L + i) + v * l4);
            store(R + i, load(R + i) + v * r4);
        },
        [&](uint32_t i, float v) noexcept {
            L[i] += v * gl;
            R[i] += v * gr;
        });
}

// Table reads at the precomputed indices k and fractions fr (a warped phase's), count of them, each handed to out
// as readFixed hands them.
template <bool Morph, class Out4, class Out1>
CAW_FORCE_INLINE void readAt(const float* A, const float* B, const uint32_t* k, const float* fr, float mix, uint32_t count,
                             const Out4& out4, const Out1& out1) noexcept {
    using namespace simd4;
    const F4 mx = splat(mix);
    uint32_t i = 0;
    for (; i + 4 <= count; i += 4) out4(i, read4<Morph>(A, B, k + i, load(fr + i), mx));
    for (; i < count; ++i) out1(i, read1<Morph>(A, B, k[i], fr[i], mix));
}

// Osc FM's phase: t moved by w1 cycles per unit of the modulating oscillator's sample m (held to +-2, so a loud
// unison stack cannot run the index away).
inline float fmOscPhase(float t, float w1, float m) noexcept {
    m = m < -2.0f ? -2.0f : (m > 2.0f ? 2.0f : m);
    float y = t + w1 * m + 4.0f;  // w1 <= 1: y stays above 0
    y -= whole(y);
    return y < 0.99999994f ? y : 0.99999994f;
}

// Adds `n` frames of the stack, `first` frames into the control period, to L and R with the copies' gains gL, gR
// (L and R may be the same buffer: a mono sum). `fm` is Osc FM's modulator for the whole period (null otherwise).
// N = 16 (a whole period, the usual case: fixed-length loops) or 0 (n frames): the same arithmetic.
template <int W, bool Morph, uint32_t N>
void addStack(const OscVoice& o, const float* gL, const float* gR, float* L, float* R, uint32_t n, uint32_t first,
              const float* fm) noexcept {
    if constexpr (W == kWarpNone) {
        for (int c = 0; c < o.count; ++c) {
            if (!o.a[c]) continue;
            const uint32_t step = o.step[c];
            const uint32_t p0 = o.phase[c] + first * step;
            addCopy<Morph, N>(o.a[c], o.b[c], p0, step, o.shift[c], gL[c], gR[c], o.mix, L, R, n);
        }
        return;
    }
    // Each copy in two passes (2026-11-27): the warped phases' indices and fractions (a loop the compiler
    // vectorizes), then the reads and sums four at a time (readAt). Each sample's arithmetic is the one-pass loop's,
    // in its order, so the bits are the same.
    using namespace simd4;
    const uint32_t count = N ? N : n;
    for (int c = 0; c < o.count; ++c) {
        if (!o.a[c]) continue;
        const float m = o.size[c], t0 = static_cast<float>(o.phase[c] * (1.0 / 4294967296.0)), dt = static_cast<float>(o.dt[c]);
        const float gl = gL[c], gr = gR[c], w1 = o.w1, w2 = o.w2, w3 = o.w3;
        alignas(16) uint32_t index[kControlFrames];
        alignas(16) float fr[kControlFrames];
        for (uint32_t i = 0; i < count; ++i) {
            float t = t0 + static_cast<float>(static_cast<int32_t>(first + i)) * dt;
            t -= whole(t);
            float x;
            if constexpr (W == kWarpFm) t = t < 0.99999994f ? t : 0.99999994f;  // as addTwice
            if constexpr (W == kWarpFmOsc) x = fmOscPhase(t, w1, fm[first + i]) * m;
            else x = warp<W>(t, w1, w2, w3) * m;
            const int32_t k = static_cast<int32_t>(x);
            index[i] = static_cast<uint32_t>(k);
            fr[i] = x - static_cast<float>(k);
        }
        const F4 l4 = splat(gl), r4 = splat(gr);
        readAt<Morph>(
            o.a[c], o.b[c], index, fr, o.mix, count,
            [&](uint32_t i, F4 v) noexcept {
                store(L + i, load(L + i) + v * l4);
                store(R + i, load(R + i) + v * r4);
            },
            [&](uint32_t i, float v) noexcept {
                L[i] += v * gl;
                R[i] += v * gr;
            });
    }
}

// The FM warp at twice the rate: each copy is read (exactly: the table and the warped phase are smooth, so
// reading between samples needs no interpolation filter), warped at t and t + dt / 2, summed with its gains, and
// the sum comes down through a half-band decimator. What FM's far sidebands make above the high rate's Nyquist
// (up to 1.5 times the sample rate) lands in the decimator's stop band instead of on the audible spectrum. R null:
// mono into L (gL).
// Each copy in two passes (speed phase 1, 2026-11-12; 2026-11-27): the warped phases' indices and fractions (a
// loop the compiler vectorizes), then the table reads, the interpolation, the morph and the sums four at a time
// (readAt). Each sample's arithmetic is the one-pass loop's, in its order, so the bits are the same. Mono (R null)
// sums into the left only.
template <int W, bool Morph, uint32_t N>
void addTwice(OscVoice& o, const float* gL, const float* gR, float* L, float* R, uint32_t n, uint32_t first,
             Decimator2x& dl, Decimator2x* dr) noexcept {
    if constexpr (N != 0) n = N;
    float hl[2 * kControlFrames] = {}, hr[2 * kControlFrames] = {};
    const uint32_t count = 2 * n;
    for (int c = 0; c < o.count; ++c) {
        if (!o.a[c]) continue;
        const float* A = o.a[c];
        const float* B = o.b[c];
        const float m = o.size[c], t0 = static_cast<float>(o.phase[c] * (1.0 / 4294967296.0)), dt = static_cast<float>(o.dt[c]);
        const float half = 0.5f * dt, gl = gL[c], gr = gR ? gR[c] : 0.0f, mix = o.mix, w1 = o.w1, w2 = o.w2, w3 = o.w3;
        alignas(16) uint32_t index[2 * kControlFrames];
        alignas(16) float fr[2 * kControlFrames];
        for (uint32_t i = 0; i < count; ++i) {
            float t = t0 + static_cast<float>(static_cast<int32_t>(first + (i >> 1))) * dt + ((i & 1u) ? half : 0.0f);
            t -= whole(t);
            t = t < 0.99999994f ? t : 0.99999994f;
            const float x = warp<W>(t, w1, w2, w3) * m;
            const int32_t k = static_cast<int32_t>(x);
            index[i] = static_cast<uint32_t>(k);
            fr[i] = x - static_cast<float>(k);
        }
        using namespace simd4;
        const F4 l4 = splat(gl), r4 = splat(gr);
        if (dr) {
            readAt<Morph>(
                A, B, index, fr, mix, count,
                [&](uint32_t i, F4 v) noexcept {
                    store(hl + i, load(hl + i) + v * l4);
                    store(hr + i, load(hr + i) + v * r4);
                },
                [&](uint32_t i, float v) noexcept {
                    hl[i] += v * gl;
                    hr[i] += v * gr;
                });
        } else {
            readAt<Morph>(
                A, B, index, fr, mix, count, [&](uint32_t i, F4 v) noexcept { store(hl + i, load(hl + i) + v * l4); },
                [&](uint32_t i, float v) noexcept { hl[i] += v * gl; });
        }
    }
    Decimator2x::down(dl, hl, L, dr, hr, R, n);
}

template <int W>
void addStackWarp(const OscVoice& o, const float* gL, const float* gR, float* L, float* R, uint32_t n, uint32_t first,
                  const float* fm) noexcept {
    if (n == kControlFrames) {
        if (o.mix != 0.0f) addStack<W, true, kControlFrames>(o, gL, gR, L, R, n, first, fm);
        else addStack<W, false, kControlFrames>(o, gL, gR, L, R, n, first, fm);
    } else if (o.mix != 0.0f) {
        addStack<W, true, 0>(o, gL, gR, L, R, n, first, fm);
    } else {
        addStack<W, false, 0>(o, gL, gR, L, R, n, first, fm);
    }
}

// addTwice for warp W: stereo through the left and right decimators, or mono (the halves summed once, as one
// gain) through its own. N = 16 and N = 0 are the same arithmetic, but under -ffp-contract=fast the compiler may
// fuse them differently (about 1 ulp where a block splits a period): the same within the tolerance tests,
// bit-identical on the builds checked.
template <int W>
void addTwiceWarp(OscVoice& o, const float* gL, const float* gR, float* L, float* R, uint32_t n, uint32_t first,
                  bool mono) noexcept {
    if (mono) {
        float g[kMaxCopies];
        for (int c = 0; c < o.count; ++c) g[c] = 2.0f * o.monoGain[c];
        if (o.mix != 0.0f) addTwice<W, true, 0>(o, g, nullptr, L, nullptr, n, first, o.foldM, nullptr);
        else addTwice<W, false, 0>(o, g, nullptr, L, nullptr, n, first, o.foldM, nullptr);
    } else if (n == kControlFrames) {  // a whole period (the usual case): fixed-length loops, as addStackWarp
        if (o.mix != 0.0f) addTwice<W, true, kControlFrames>(o, gL, gR, L, R, n, first, o.foldL, &o.foldR);
        else addTwice<W, false, kControlFrames>(o, gL, gR, L, R, n, first, o.foldL, &o.foldR);
    } else if (o.mix != 0.0f) {
        addTwice<W, true, 0>(o, gL, gR, L, R, n, first, o.foldL, &o.foldR);
    } else {
        addTwice<W, false, 0>(o, gL, gR, L, R, n, first, o.foldL, &o.foldR);
    }
}

// One unwarped copy's read values over N (or n) frames into v: addCopy's reads, the values kept instead of mixed
// into L and R (the fold warp shapes them first).
template <bool Morph, uint32_t N>
CAW_FORCE_INLINE void readCopy(const float* A, const float* B, uint32_t p, uint32_t step, int sh, float mix, float* v,
                               uint32_t n) noexcept {
    readFixed<Morph, N>(
        A, B, p, step, sh, mix, n, [&](uint32_t i, simd4::F4 x) noexcept { simd4::store(v + i, x); },
        [&](uint32_t i, float x) noexcept { v[i] = x; });
}
