// Flagship's oscillator modes: ADAA fold, spectral banks, ring/AM, hard sync and addOscillator (hand-written; included by builtin_flagship.cpp, not compiled alone).
// sin(2 pi u) for u in cycles (|u| below 2^31), within about 1e-7 (a sine to its x^11 term on a quarter cycle).
// No offset is added to u, so a small u keeps its relative accuracy. No branch, so it vectorizes. The fold's sine
// (#197): sineCycles' 0.001 error, with its kinks, put partials of its own at about -65 dB.
inline float sinCyclesFine(float u) noexcept {
    float h = u - static_cast<float>(static_cast<int32_t>(u));  // -1 .. 1
    h = h > 0.5f ? h - 1.0f : (h < -0.5f ? h + 1.0f : h);         // -0.5 .. 0.5
    const float r = h > 0.25f ? 0.5f - h : (h < -0.25f ? -0.5f - h : h);  // sin(2 pi h) = sin(2 pi r)
    const float x = 6.28318531f * r, x2 = x * x;
    float p = -2.50521084e-8f;
    p = p * x2 + 2.75573192e-6f;
    p = p * x2 - 1.98412698e-4f;
    p = p * x2 + 8.33333333e-3f;
    p = p * x2 - 0.166666667f;
    return x + x * x2 * p;
}

// sin(z) / z for z = 2 pi u, u from 0 to 0.5 (up to the first zero), as its series to z^12 (within about 7e-6;
// exact at 0, where the quotient is 0 / 0): no reduction, no division.
inline float sincNear(float u) noexcept {
    const float z = 6.28318531f * u, t = z * z;
    float p = 1.60590438e-10f;
    p = p * t - 2.50521084e-8f;
    p = p * t + 2.75573192e-6f;
    p = p * t - 1.98412698e-4f;
    p = p * t + 8.33333333e-3f;
    p = p * t - 0.166666667f;
    return 1.0f + t * p;
}

// sin(2 pi u) / (2 pi u) for u >= 0: sincNear up to u = 0.5, beyond it the sine over the angle.
inline float sincCycles(float u) noexcept {
    const float far = sinCyclesFine(u) / (6.28318531f * (u > 0.5f ? u : 0.5f));
    return u > 0.5f ? far : sincNear(u);
}

// The fold warp's shaper: lib::fold's sin(x drive pi / 2), drive w1, blended in by w2, on the value v whose
// previous value was p, with first-order antiderivative anti-aliasing (ADAA, #197, owner 2026-11-13): the mean of
// the shaper over the straight line from p to v, (G(v) - G(p)) / (v - p) for G the shaper's antiderivative. For
// the sine, with m = (v + p) / 2 and d = v - p, (cos(k p) - cos(k v)) / (k d) is exactly sin(k m) sin(k d / 2) /
// (k d / 2) (k = drive pi / 2): no difference of nearly equal numbers, so v = p (where the quotient is 0 / 0) needs
// no special case, and there it is the plain fold of v. The blend's straight part averages to m.
// Near: every step d of the run small enough that sincNear covers it (foldRun checks), so sincCycles' far branch,
// which would give the same bits, is not worked out.
template <bool Near>
CAW_FORCE_INLINE float foldAdaa(float v, float p, float w1, float w2) noexcept {
    const float m = 0.5f * (v + p), d = v - p;
    const float u = 0.125f * w1 * std::fabs(d);
    const float f = sinCyclesFine(0.25f * w1 * m) * (Near ? sincNear(u) : sincCycles(u));
    return m + w2 * (f - m);
}

// The fold over the period's values v, after `last` (the value before v[0]), into y; `last` becomes v's last.
template <uint32_t N>
CAW_FORCE_INLINE void foldRun(const float* v, float& last, float* y, uint32_t n, float w1, float w2) noexcept {
    const uint32_t count = N ? N : n;
    if (count == 0) return;
    alignas(16) float before[kControlFrames];
    before[0] = last;
    for (uint32_t i = 1; i < count; ++i) before[i] = v[i - 1];
    // The largest step, as its bits (a non-negative float's bits order as it does, and an integer maximum
    // vectorizes): 0.125 w1 |d| is at most 0.5 for every sample when it is for this one.
    int32_t most = 0;
    CAW_NO_UNROLL
    for (uint32_t i = 0; i < count; ++i) {
        const int32_t d = std::bit_cast<int32_t>(std::fabs(v[i] - before[i]));
        most = d > most ? d : most;
    }
    if (0.125f * w1 * std::bit_cast<float>(most) <= 0.5f) {
        CAW_NO_UNROLL
        for (uint32_t i = 0; i < count; ++i) y[i] = foldAdaa<true>(v[i], before[i], w1, w2);
    } else {
        CAW_NO_UNROLL
        for (uint32_t i = 0; i < count; ++i) y[i] = foldAdaa<false>(v[i], before[i], w1, w2);
    }
    last = v[count - 1];
}

// The fold warp's ADAA path (#197, 2026-11-13): at the sample rate, anti-aliased by ADAA (foldAdaa), for every
// note below the hybrid's crossover (foldTwiceFor; addFoldTwice above it) and every note at Eco. Its phase is unwarped, so each copy is read as addCopy reads one.
// Per copy (Whole false): each copy folded, then added with its gains, as before. Whole stack: the copies summed
// first at their pan gains (the level left out, so the level never changes the fold), each side's sum folded once
// (one fold a sample when every copy is centred), then the level: the fold costs two shapers a voice instead of
// one a copy, and folds the stack's beating as one waveform (a different, rougher sound). Spread copies fold side
// by side, as only a side's own copies reach it. Mono (the copy Osc FM hears, into L): per copy, each copy at
// its mono gain; whole stack, the mean of the two sides' folds, before the level. State: foldLast, foldSide.
template <bool Morph, bool Whole, bool Mono, uint32_t N>
void addFold(OscVoice& o, const float* gL, const float* gR, float* L, float* R, uint32_t n, uint32_t first) noexcept {
    if constexpr (N != 0) n = N;
    const int slot = Mono ? 1 : 0;
    const float w1 = o.w1, w2 = o.w2, mix = o.mix;
    alignas(16) float v[kControlFrames], y[kControlFrames];
    if constexpr (!Whole) {
        float* last = o.foldLast[slot];
        alignas(16) float accL[kControlFrames] = {}, accR[kControlFrames] = {};
        for (int c = 0; c < o.count; ++c) {
            if (!o.a[c]) continue;
            const uint32_t step = o.step[c];
            readCopy<Morph, N>(o.a[c], o.b[c], o.phase[c] + first * step, step, o.shift[c], mix, v, n);
            foldRun<N>(v, last[c], y, n, w1, w2);
            if constexpr (Mono) {
                const float g = 2.0f * gL[c];
                CAW_NO_UNROLL
                for (uint32_t i = 0; i < n; ++i) accL[i] += y[i] * g;
            } else {
                const float gl = gL[c], gr = gR[c];
                CAW_NO_UNROLL
                for (uint32_t i = 0; i < n; ++i) accL[i] += y[i] * gl;
                CAW_NO_UNROLL
                for (uint32_t i = 0; i < n; ++i) accR[i] += y[i] * gr;
            }
        }
        CAW_NO_UNROLL
        for (uint32_t i = 0; i < n; ++i) L[i] += accL[i];
        if constexpr (!Mono)
            CAW_NO_UNROLL
            for (uint32_t i = 0; i < n; ++i) R[i] += accR[i];
        return;
    }
    (void)gR;
    alignas(16) float sl[kControlFrames] = {}, sr[kControlFrames] = {};
    const bool centred = o.stackCentred;
    for (int c = 0; c < o.count; ++c) {
        if (!o.a[c]) continue;
        const uint32_t step = o.step[c];
        readCopy<Morph, N>(o.a[c], o.b[c], o.phase[c] + first * step, step, o.shift[c], mix, v, n);
        const float pl = o.stackL[c], pr = o.stackR[c];
        CAW_NO_UNROLL
        for (uint32_t i = 0; i < n; ++i) sl[i] += v[i] * pl;
        if (!centred)
            CAW_NO_UNROLL
            for (uint32_t i = 0; i < n; ++i) sr[i] += v[i] * pr;
    }
    float* side = o.foldSide[slot];
    foldRun<N>(sl, side[0], y, n, w1, w2);
    if (centred) {
        side[1] = side[0];  // a centred stack's right side is its left (should it spread again)
        if constexpr (Mono) {
            CAW_NO_UNROLL
            for (uint32_t i = 0; i < n; ++i) L[i] += y[i];
        } else {
            const float g = o.levelGain;
            CAW_NO_UNROLL
            for (uint32_t i = 0; i < n; ++i) {
                L[i] += y[i] * g;
                R[i] += y[i] * g;
            }
        }
        return;
    }
    alignas(16) float yr[kControlFrames];
    foldRun<N>(sr, side[1], yr, n, w1, w2);
    if constexpr (Mono) {
        CAW_NO_UNROLL
        for (uint32_t i = 0; i < n; ++i) L[i] += 0.5f * (y[i] + yr[i]);
    } else {
        const float g = o.levelGain;
        CAW_NO_UNROLL
        for (uint32_t i = 0; i < n; ++i) {
            L[i] += y[i] * g;
            R[i] += yr[i] * g;
        }
    }
}

template <bool Morph, bool Whole>
void addFoldIn(OscVoice& o, const float* gL, const float* gR, float* L, float* R, uint32_t n, uint32_t first,
               bool mono) noexcept {
    if (mono) addFold<Morph, Whole, true, 0>(o, gL, gR, L, R, n, first);
    else if (n == kControlFrames) addFold<Morph, Whole, false, kControlFrames>(o, gL, gR, L, R, n, first);
    else addFold<Morph, Whole, false, 0>(o, gL, gR, L, R, n, first);
}

// The fold warp's shaper on its own (foldAdaa where a sample's step is 0): the 2x path folds each sample.
CAW_FORCE_INLINE float foldPlain(float v, float w1, float w2) noexcept {
    return v + w2 * (sinCyclesFine(0.25f * w1 * v) - v);
}

// The two halves of a period at twice the rate, folded: ve (at the period's samples) and vo (half a sample on).
template <uint32_t N>
CAW_FORCE_INLINE void foldPlainRun(float* ve, float* vo, uint32_t n, float w1, float w2) noexcept {
    const uint32_t count = N ? N : n;
    CAW_NO_UNROLL
    for (uint32_t i = 0; i < count; ++i) ve[i] = foldPlain(ve[i], w1, w2);
    CAW_NO_UNROLL
    for (uint32_t i = 0; i < count; ++i) vo[i] = foldPlain(vo[i], w1, w2);
}

// The fold warp at twice the rate, for a note high enough that ADAA would let more alias through (the hybrid,
// #197, owner 2026-11-13: Voice::foldTwice). Each copy is read at its samples and half a sample on (exactly: the
// table is smooth and the phase unwarped, so reading between samples needs no interpolation filter), folded
// (foldPlain, the ADAA path's shaper), and the high-rate sum comes down through the half-band decimators: what
// the fold makes above the high rate's Nyquist, up to 1.5 times the sample rate, lands in their stop band. The
// path the fold had before #197 (addTwice's), with Whole stack added: there the copies are summed at their pan
// gains first, each side's sum folded once, then the level, as addFold does. A centred stack (every copy alike
// on both sides) runs one decimator and copies its state to the right one, which stays ready should the stack
// spread. Mono (the copy Osc FM hears, into L, through foldM): per copy at the copies' mono gains; whole stack,
// the mean of the two sides' folds, before the level.
template <bool Morph, bool Whole, bool Mono, uint32_t N>
void addFoldTwice(OscVoice& o, const float* gL, const float* gR, float* L, float* R, uint32_t n, uint32_t first) noexcept {
    if constexpr (N != 0) n = N;
    const float w1 = o.w1, w2 = o.w2, mix = o.mix;
    alignas(16) float hl[2 * kControlFrames] = {}, hr[2 * kControlFrames] = {};
    alignas(16) float ve[kControlFrames], vo[kControlFrames];
    const bool centred = Whole ? o.stackCentred : o.centred;
    if constexpr (!Whole) {
        for (int c = 0; c < o.count; ++c) {
            if (!o.a[c]) continue;
            const uint32_t step = o.step[c], p = o.phase[c] + first * step;
            readCopy<Morph, N>(o.a[c], o.b[c], p, step, o.shift[c], mix, ve, n);
            readCopy<Morph, N>(o.a[c], o.b[c], p + (step >> 1), step, o.shift[c], mix, vo, n);
            foldPlainRun<N>(ve, vo, n, w1, w2);
            const float gl = Mono ? 2.0f * gL[c] : gL[c];
            for (uint32_t i = 0; i < n; ++i) hl[2 * i] += ve[i] * gl, hl[2 * i + 1] += vo[i] * gl;
            if (Mono || centred) continue;
            const float gr = gR[c];
            for (uint32_t i = 0; i < n; ++i) hr[2 * i] += ve[i] * gr, hr[2 * i + 1] += vo[i] * gr;
        }
    } else {
        (void)gL, (void)gR;
        alignas(16) float sle[kControlFrames] = {}, slo[kControlFrames] = {}, sre[kControlFrames] = {}, sro[kControlFrames] = {};
        for (int c = 0; c < o.count; ++c) {
            if (!o.a[c]) continue;
            const uint32_t step = o.step[c], p = o.phase[c] + first * step;
            readCopy<Morph, N>(o.a[c], o.b[c], p, step, o.shift[c], mix, ve, n);
            readCopy<Morph, N>(o.a[c], o.b[c], p + (step >> 1), step, o.shift[c], mix, vo, n);
            const float pl = o.stackL[c], pr = o.stackR[c];
            CAW_NO_UNROLL
            for (uint32_t i = 0; i < n; ++i) sle[i] += ve[i] * pl, slo[i] += vo[i] * pl;
            if (centred) continue;
            CAW_NO_UNROLL
            for (uint32_t i = 0; i < n; ++i) sre[i] += ve[i] * pr, sro[i] += vo[i] * pr;
        }
        foldPlainRun<N>(sle, slo, n, w1, w2);
        if (!centred) foldPlainRun<N>(sre, sro, n, w1, w2);
        if constexpr (Mono) {
            if (centred) {
                for (uint32_t i = 0; i < n; ++i) hl[2 * i] = sle[i], hl[2 * i + 1] = slo[i];
            } else {
                for (uint32_t i = 0; i < n; ++i) hl[2 * i] = 0.5f * (sle[i] + sre[i]), hl[2 * i + 1] = 0.5f * (slo[i] + sro[i]);
            }
        } else {
            const float g = o.levelGain;
            for (uint32_t i = 0; i < n; ++i) hl[2 * i] = sle[i] * g, hl[2 * i + 1] = slo[i] * g;
            if (!centred)
                for (uint32_t i = 0; i < n; ++i) hr[2 * i] = sre[i] * g, hr[2 * i + 1] = sro[i] * g;
        }
    }
    if constexpr (Mono) {
        Decimator2x::down(o.foldM, hl, L, nullptr, nullptr, nullptr, n);
    } else if (centred) {  // both sides the same: one decimator, its state copied to the other
        alignas(16) float y[kControlFrames] = {};
        Decimator2x::down(o.foldL, hl, y, nullptr, nullptr, nullptr, n);
        o.foldR = o.foldL;
        for (uint32_t i = 0; i < n; ++i) L[i] += y[i], R[i] += y[i];
    } else {
        Decimator2x::down(o.foldL, hl, L, &o.foldR, hr, R, n);
    }
}

template <bool Morph, bool Whole>
void addFoldTwiceIn(OscVoice& o, const float* gL, const float* gR, float* L, float* R, uint32_t n, uint32_t first,
                    bool mono) noexcept {
    if (mono) addFoldTwice<Morph, Whole, true, 0>(o, gL, gR, L, R, n, first);
    else if (n == kControlFrames) addFoldTwice<Morph, Whole, false, kControlFrames>(o, gL, gR, L, R, n, first);
    else addFoldTwice<Morph, Whole, false, 0>(o, gL, gR, L, R, n, first);
}

void addFoldWarp(OscVoice& o, const float* gL, const float* gR, float* L, float* R, uint32_t n, uint32_t first,
                 bool mono) noexcept {
    const bool morph = o.mix != 0.0f;
    if (o.key.foldTwice) {
        if (o.key.foldWhole) {
            if (morph) addFoldTwiceIn<true, true>(o, gL, gR, L, R, n, first, mono);
            else addFoldTwiceIn<false, true>(o, gL, gR, L, R, n, first, mono);
        } else if (morph) {
            addFoldTwiceIn<true, false>(o, gL, gR, L, R, n, first, mono);
        } else {
            addFoldTwiceIn<false, false>(o, gL, gR, L, R, n, first, mono);
        }
        return;
    }
    if (o.key.foldWhole) {
        if (morph) addFoldIn<true, true>(o, gL, gR, L, R, n, first, mono);
        else addFoldIn<false, true>(o, gL, gR, L, R, n, first, mono);
    } else if (morph) {
        addFoldIn<true, false>(o, gL, gR, L, R, n, first, mono);
    } else {
        addFoldIn<false, false>(o, gL, gR, L, R, n, first, mono);
    }
}

// The hybrid fold's crossover (#197, owner 2026-11-13): whether a note folds at twice the rate rather than with
// ADAA, from the highest frequency `hz` it may play (scaled to 48 kHz: the caller multiplies by 48000 over the
// sample rate) and the fold drive (1..8). Measured on a sine, A4 to A7 a semitone apart at five drives, both
// modes (2026-11-13, docs/engine-performance.md): ADAA keeps the aliases below -60 dB (the 2x path's own worst)
// while hz (drive + 2) stays under about 14 kHz per copy and 12 kHz for a whole 7-copy stack (whose sum folds
// harder); above that it gives way fast (-38 dB at A6, full drive). 2x from 10 kHz leaves at least 3.5
// semitones of margin: at full drive from 1 kHz (about B5), at drive 3.8 (amount 0.4) from 1.7 kHz.
bool foldTwiceFor(double hz, double drive) noexcept {
#if defined(CAW_FOLD_FORCE)  // scratch measurement builds only: one path at every pitch
    (void)hz, (void)drive;
    return CAW_FOLD_FORCE != 0;
#else
    return hz * (drive + 2.0) > 10000.0;
#endif
}

// A spectral warp between two of its bank's amounts (1.1.0): each copy reads four frames (two frames at two
// amounts), the frame morph at each amount, then the morph between the amounts. At an amount on one of the bank's
// eight levels (amix 0) the oscillator reads two frames as an unwarped one does (addStackWarp<kWarpNone>).
template <bool Morph>
void addBank(const OscVoice& o, const float* gL, const float* gR, float* L, float* R, uint32_t n, uint32_t first) noexcept {
    const float mix = o.mix, amix = o.amix;
    for (int c = 0; c < o.count; ++c) {
        if (!o.a[c]) continue;
        const float* A = o.a[c];
        const float* B = o.b[c];
        const float* C = o.ca[c];
        const float* D = o.cb[c];
        const uint32_t step = o.step[c];
        uint32_t p = o.phase[c] + first * step;
        const int sh = o.shift[c];
        const uint32_t mask = (1u << sh) - 1u;
        const float scale = 1.0f / static_cast<float>(1u << sh), gl = gL[c], gr = gR[c];
        for (uint32_t i = 0; i < n; ++i, p += step) {
            const uint32_t k = p >> sh;
            const float fr = static_cast<float>(static_cast<int32_t>(p & mask)) * scale;
            float x = A[k] + (A[k + 1] - A[k]) * fr, y = C[k] + (C[k + 1] - C[k]) * fr;
            if constexpr (Morph) {
                x += (B[k] + (B[k + 1] - B[k]) * fr - x) * mix;
                y += (D[k] + (D[k + 1] - D[k]) * fr - y) * mix;
            }
            const float v = x + (y - x) * amix;
            L[i] += v * gl;
            R[i] += v * gr;
        }
    }
}

// Osc RM and Osc AM (1.1.0): the stack, unwarped, times its source's mono copy m (held to +-2, as Osc FM holds it):
// ring 1 - a + a m (at full amount the plain product, the sum and difference tones), amplitude 1 - a / 2 + a m / 2
// (the carrier kept). The product is taken once on the stack's sum, not per copy: about two operations a sample.
template <bool Am>
void addRing(const OscVoice& o, const float* gL, const float* gR, float* L, float* R, uint32_t n, uint32_t first,
             const float* fm, bool mono) noexcept {
    alignas(16) float tL[kControlFrames] = {}, tR[kControlFrames] = {};
    float* const sR = mono ? tL : tR;
    addStackWarp<kWarpNone>(o, gL, gR, tL, sR, n, first, nullptr);
    const float a = Am ? 0.5f * o.w1 : o.w1, dry = 1.0f - a;
    for (uint32_t i = 0; i < n; ++i) {
        float m = fm[first + i];
        m = m < -2.0f ? -2.0f : (m > 2.0f ? 2.0f : m);
        const float g = dry + a * m;
        L[i] += tL[i] * g;
        if (!mono) R[i] += tR[i] * g;
    }
}

// Osc sync (1.1.0): hard sync to the source oscillator. Each copy's phase is the source's matching copy's phase (the
// centre one for a copy the source lacks) times this copy's speed over the source's, times w1 (1..8, the amount: the
// classic sync sweep), so it restarts with each of the source's cycles. No state of its own: the phase comes from the
// source's, which every block size steps alike. Blep: each restart's jump h (the table at 0 less the table at the
// phase the cycle reached) band-limited by a two-sample polyBLEP, the sample before the restart and the one after.
template <bool Morph, bool Blep>
void addSync(const OscVoice& o, const OscVoice& M, const float* gL, const float* gR, float* L, float* R, uint32_t n,
             uint32_t first) noexcept {
    const float mix = o.mix;
    for (int c = 0; c < o.count; ++c) {
        if (!o.a[c]) continue;
        const int mc = c < M.count ? c : 0;
        if (mc >= M.count || !M.a[mc] || !(M.dt[mc] > 0.0)) {  // no source copy sounding: the copy plays free
            const uint32_t step = o.step[c];
            addCopy<Morph, 0>(o.a[c], o.b[c], o.phase[c] + first * step, step, o.shift[c], gL[c], gR[c], mix, L, R, n);
            continue;
        }
        const float* A = o.a[c];
        const float* B = o.b[c];
        const float m = o.size[c], gl = gL[c], gr = gR[c];
        const uint32_t ms = M.step[mc];
        uint32_t pm = M.phase[mc] + first * ms;
        const float r = static_cast<float>(o.dt[c] * o.w1 / M.dt[mc]);
        const auto read = [&](float t) noexcept {
            const float x = t * m;
            const int32_t k = static_cast<int32_t>(x);
            const float fr = x - static_cast<float>(k);
            float v = A[k] + (A[k + 1] - A[k]) * fr;
            if constexpr (Morph) {
                const float u = B[k] + (B[k + 1] - B[k]) * fr;
                v += (u - v) * mix;
            }
            return v;
        };
        float half = 0.0f, inv = 0.0f;
        if constexpr (Blep) {
            float end = r - whole(r);
            end = end < 0.99999994f ? end : 0.99999994f;
            half = 0.5f * (read(0.0f) - read(end));
            inv = 1.0f / static_cast<float>(ms);
        }
        for (uint32_t i = 0; i < n; ++i, pm += ms) {
            float t = static_cast<float>(pm) * 2.3283064365386963e-10f * r;
            t -= whole(t);
            t = t < 0.99999994f ? t : 0.99999994f;
            float v = read(t);
            if constexpr (Blep) {
                const float after = static_cast<float>(pm) * inv;              // samples since the restart
                const uint32_t left = 0u - pm;                                  // to the next restart (0: one now)
                const float before = left ? -static_cast<float>(left) * inv : -2.0f;
                const float pa = after < 1.0f ? after + after - after * after - 1.0f : 0.0f;
                const float pb = before > -1.0f ? before * before + before + before + 1.0f : 0.0f;
                v += half * (pa + pb);
            }
            L[i] += v * gl;
            R[i] += v * gr;
        }
    }
}

// The oscillator's stack into L and R (its gains, its level), or with `mono` into L alone at its pre-level mono
// gains (what Osc FM hears of it). `fm`: the source's copy a hearing warp reads, period-indexed; `master`: Osc
// sync's source oscillator.
void addOscillator(OscVoice& o, float* L, float* R, uint32_t n, uint32_t first, const float* fm,
                   bool mono = false, const OscVoice* master = nullptr) noexcept {
    const float* gL = mono ? o.monoGain : o.gainL;
    const float* gR = mono ? o.monoGain : o.gainR;
    if (mono) R = L;  // two half gains into one buffer: the mono sum
    if (spectral(o.warpMode)) {
        if (o.amix == 0.0f) addStackWarp<kWarpNone>(o, gL, gR, L, R, n, first, fm);
        else if (o.mix != 0.0f) addBank<true>(o, gL, gR, L, R, n, first);
        else addBank<false>(o, gL, gR, L, R, n, first);
        return;
    }
    switch (o.warpMode) {
        case kWarpOscRm:
        case kWarpOscAm:
            if (!fm) addStackWarp<kWarpNone>(o, gL, gR, L, R, n, first, fm);
            else if (o.warpMode == kWarpOscAm) addRing<true>(o, gL, gR, L, R, n, first, fm, mono);
            else addRing<false>(o, gL, gR, L, R, n, first, fm, mono);
            break;
        case kWarpOscSync:
            if (!master || master->count == 0) addStackWarp<kWarpNone>(o, gL, gR, L, R, n, first, fm);
            else if (o.mix != 0.0f) o.blep ? addSync<true, true>(o, *master, gL, gR, L, R, n, first)
                                           : addSync<true, false>(o, *master, gL, gR, L, R, n, first);
            else o.blep ? addSync<false, true>(o, *master, gL, gR, L, R, n, first)
                        : addSync<false, false>(o, *master, gL, gR, L, R, n, first);
            break;
        case kWarpBend: addStackWarp<kWarpBend>(o, gL, gR, L, R, n, first, fm); break;
        case kWarpSync: addStackWarp<kWarpSync>(o, gL, gR, L, R, n, first, fm); break;
        case kWarpMirror: addStackWarp<kWarpMirror>(o, gL, gR, L, R, n, first, fm); break;
        case kWarpQuantize: addStackWarp<kWarpQuantize>(o, gL, gR, L, R, n, first, fm); break;
        case kWarpFm:
            if (o.key.once) addStackWarp<kWarpFm>(o, gL, gR, L, R, n, first, fm);  // Eco
            else addTwiceWarp<kWarpFm>(o, gL, gR, L, R, n, first, mono);
            break;
        case kWarpFmOsc:
            if (fm) addStackWarp<kWarpFmOsc>(o, gL, gR, L, R, n, first, fm);
            else addStackWarp<kWarpNone>(o, gL, gR, L, R, n, first, fm);
            break;
        case kWarpFold: addFoldWarp(o, gL, gR, L, R, n, first, mono); break;
        default: addStackWarp<kWarpNone>(o, gL, gR, L, R, n, first, fm); break;
    }
}
