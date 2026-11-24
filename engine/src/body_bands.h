// An instrument's estimated body as a cascade of peaking filters (the recordings' spectrum over the model's: tools/instrument_bodies.py), stereo in SIMD lanes, its gains scaled by Body.
#pragma once

#include <cstdint>

#include "timber_core.h"  // kControlFrames
#include "timber_dsp.h"

namespace caw {

// One band of a body: an RBJ peaking filter.
struct BodyBand {
    float hz, q, db;
};
struct BodyResponse {
    const BodyBand* bands;
    uint32_t count;
};

// Up to kBands bands designed at the rate, left and right as two SIMD lanes (one pass a band), the gains scaled by
// `amount` (1 the recorded instrument, 0 flat: no comb from a dry/wet mix). load() at prepare or at a control point;
// process() never allocates.
struct BodyFilter {
    static constexpr int kBands = 8;
    struct Stage {
        timber::F4 b0, b1, b2, a1, a2, z1, z2;
    };
    Stage stage[kBands] = {};
    const BodyBand* bandsFor = nullptr;
    float amountFor = -1;
    double srFor = 0;
    uint32_t fill = 0;  // frames since the last control point

    void load(BodyResponse r, float amount, double sr) noexcept {
        if (r.bands == bandsFor && amount == amountFor && sr == srFor) return;
        bandsFor = r.bands, amountFor = amount, srFor = sr;
        for (int k = 0; k < kBands; ++k) {
            timber::Biquad q;
            if (static_cast<uint32_t>(k) < r.count) q.peak(r.bands[k].hz, r.bands[k].q, r.bands[k].db * amount, sr);
            Stage& st = stage[k];
            st.b0 = timber::f4(q.b0), st.b1 = timber::f4(q.b1), st.b2 = timber::f4(q.b2);
            st.a1 = timber::f4(q.a1), st.a2 = timber::f4(q.a2);
        }
    }
    void process(float* l, float* r, uint32_t n) noexcept {
        using timber::F4;
        F4 z1[kBands], z2[kBands];
        for (int k = 0; k < kBands; ++k) z1[k] = stage[k].z1, z2[k] = stage[k].z2;
        for (uint32_t i = 0; i < n; ++i) {
            F4 x = {};
            x[0] = l[i], x[1] = r[i];
            for (int k = 0; k < kBands; ++k) {  // transposed direct form II, as timber::Biquad
                const Stage& st = stage[k];
                const F4 y = st.b0 * x + z1[k];
                z1[k] = st.b1 * x - st.a1 * y + z2[k];
                z2[k] = st.b2 * x - st.a2 * y;
                x = y;
            }
            l[i] = x[0], r[i] = x[1];
        }
        for (int k = 0; k < kBands; ++k) stage[k].z1 = z1[k], stage[k].z2 = z2[k];
        // Tiny values flushed on the control grid only (the instrument's chunks never straddle a control point), so
        // any block size flushes at the same frames and gives the same bits.
        fill += n;
        if (fill >= timber::kControlFrames) {
            fill = 0;
            for (int k = 0; k < kBands; ++k)
                for (int c = 0; c < 4; ++c) stage[k].z1[c] = timber::flushf(stage[k].z1[c]), stage[k].z2[c] = timber::flushf(stage[k].z2[c]);
        }
    }
    void clear() noexcept {
        for (Stage& st : stage) st.z1 = timber::f4(0.0f), st.z2 = timber::f4(0.0f);
        fill = 0;
    }
};

}  // namespace caw
