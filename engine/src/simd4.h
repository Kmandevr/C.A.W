// Four floats a vector, portably: SSE2 on x86-64, NEON on Arm64, plain arrays elsewhere (each lane the scalar's IEEE op).
#pragma once

#include <cstdint>
#include <cstring>

#if defined(CAW_SIMD4_SCALAR)  // forced (to test the fallback): plain arrays
#elif defined(__aarch64__) || defined(_M_ARM64)
#include <arm_neon.h>
#define CAW_SIMD4_NEON 1
#elif defined(__SSE2__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#include <emmintrin.h>
#define CAW_SIMD4_SSE2 1
#endif

namespace caw::simd4 {

// Every operation is one IEEE single-precision operation per lane, rounded as the scalar one is (no fused
// multiply-add, no reciprocal estimate), so a loop written with these gives the bits of the scalar loop it
// replaces, on every build. Kept small: only what the callers use. No AVX branch: no shipped build enables AVX
// (docs/engine-performance.md, A5), and the x86-64 baseline's SSE2 already holds four floats.
#if defined(CAW_SIMD4_NEON)
struct F4 {
    float32x4_t v;
};
struct I4 {
    uint32x4_t v;
};
inline F4 load(const float* p) noexcept { return {vld1q_f32(p)}; }
inline void store(float* p, F4 a) noexcept { vst1q_f32(p, a.v); }
inline F4 splat(float x) noexcept { return {vdupq_n_f32(x)}; }
inline F4 operator+(F4 a, F4 b) noexcept { return {vaddq_f32(a.v, b.v)}; }
inline F4 operator-(F4 a, F4 b) noexcept { return {vsubq_f32(a.v, b.v)}; }
inline F4 operator*(F4 a, F4 b) noexcept { return {vmulq_f32(a.v, b.v)}; }
inline I4 splatU(uint32_t x) noexcept { return {vdupq_n_u32(x)}; }
inline I4 lanesU(uint32_t a, uint32_t b, uint32_t c, uint32_t d) noexcept {
    const uint32_t x[4] = {a, b, c, d};
    return {vld1q_u32(x)};
}
inline I4 operator+(I4 a, I4 b) noexcept { return {vaddq_u32(a.v, b.v)}; }
inline I4 operator&(I4 a, I4 b) noexcept { return {vandq_u32(a.v, b.v)}; }
inline I4 shiftRight(I4 a, int s) noexcept { return {vshlq_u32(a.v, vdupq_n_s32(-s))}; }  // s in 0..31
// The lanes as signed integers, to float (exact up to 2^24, rounded to nearest beyond, as static_cast<float>(int32_t)).
inline F4 toFloat(I4 a) noexcept { return {vcvtq_f32_s32(vreinterpretq_s32_u32(a.v))}; }
inline void storeU(uint32_t* p, I4 a) noexcept { vst1q_u32(p, a.v); }
// Lanes x[k0], x[k1], x[k2], x[k3] and x[k0 + 1] .. x[k3 + 1]: four neighbouring pairs, each one 8-byte load, split into
// the first of each pair and the second (a gather NEON has no instruction for).
inline void pairs(const float* x, const uint32_t* k, F4& first, F4& second) noexcept {
    const float32x4_t p01 = vcombine_f32(vld1_f32(x + k[0]), vld1_f32(x + k[1]));
    const float32x4_t p23 = vcombine_f32(vld1_f32(x + k[2]), vld1_f32(x + k[3]));
    first.v = vuzp1q_f32(p01, p23);
    second.v = vuzp2q_f32(p01, p23);
}
#elif defined(CAW_SIMD4_SSE2)
struct F4 {
    __m128 v;
};
struct I4 {
    __m128i v;
};
inline F4 load(const float* p) noexcept { return {_mm_loadu_ps(p)}; }
inline void store(float* p, F4 a) noexcept { _mm_storeu_ps(p, a.v); }
inline F4 splat(float x) noexcept { return {_mm_set1_ps(x)}; }
inline F4 operator+(F4 a, F4 b) noexcept { return {_mm_add_ps(a.v, b.v)}; }
inline F4 operator-(F4 a, F4 b) noexcept { return {_mm_sub_ps(a.v, b.v)}; }
inline F4 operator*(F4 a, F4 b) noexcept { return {_mm_mul_ps(a.v, b.v)}; }
inline I4 splatU(uint32_t x) noexcept { return {_mm_set1_epi32(static_cast<int>(x))}; }
inline I4 lanesU(uint32_t a, uint32_t b, uint32_t c, uint32_t d) noexcept {
    return {_mm_setr_epi32(static_cast<int>(a), static_cast<int>(b), static_cast<int>(c), static_cast<int>(d))};
}
inline I4 operator+(I4 a, I4 b) noexcept { return {_mm_add_epi32(a.v, b.v)}; }
inline I4 operator&(I4 a, I4 b) noexcept { return {_mm_and_si128(a.v, b.v)}; }
inline I4 shiftRight(I4 a, int s) noexcept { return {_mm_srl_epi32(a.v, _mm_cvtsi32_si128(s))}; }
inline F4 toFloat(I4 a) noexcept { return {_mm_cvtepi32_ps(a.v)}; }
inline void storeU(uint32_t* p, I4 a) noexcept { _mm_storeu_si128(reinterpret_cast<__m128i*>(p), a.v); }
// Each pair is copied into a double (std::memcpy: x + k is only 4-byte aligned, and a float pair read through a
// double* would be a misaligned, aliasing load, undefined behaviour the sanitizer build stops at); the compilers
// turn the copies into the same two 8-byte loads (movsd, movhpd).
inline __m128d pairLoad(const float* a, const float* b) noexcept {
    double lo, hi;
    std::memcpy(&lo, a, sizeof lo);
    std::memcpy(&hi, b, sizeof hi);
    return _mm_set_pd(hi, lo);
}
inline void pairs(const float* x, const uint32_t* k, F4& first, F4& second) noexcept {
    const __m128 p01 = _mm_castpd_ps(pairLoad(x + k[0], x + k[1]));
    const __m128 p23 = _mm_castpd_ps(pairLoad(x + k[2], x + k[3]));
    first.v = _mm_shuffle_ps(p01, p23, _MM_SHUFFLE(2, 0, 2, 0));
    second.v = _mm_shuffle_ps(p01, p23, _MM_SHUFFLE(3, 1, 3, 1));
}
#else
struct F4 {
    float v[4];
};
struct I4 {
    uint32_t v[4];
};
inline F4 load(const float* p) noexcept { F4 r; std::memcpy(r.v, p, sizeof r.v); return r; }
inline void store(float* p, F4 a) noexcept { std::memcpy(p, a.v, sizeof a.v); }
inline F4 splat(float x) noexcept { return {{x, x, x, x}}; }
inline F4 operator+(F4 a, F4 b) noexcept { for (int i = 0; i < 4; ++i) a.v[i] += b.v[i]; return a; }
inline F4 operator-(F4 a, F4 b) noexcept { for (int i = 0; i < 4; ++i) a.v[i] -= b.v[i]; return a; }
inline F4 operator*(F4 a, F4 b) noexcept { for (int i = 0; i < 4; ++i) a.v[i] *= b.v[i]; return a; }
inline I4 splatU(uint32_t x) noexcept { return {{x, x, x, x}}; }
inline I4 lanesU(uint32_t a, uint32_t b, uint32_t c, uint32_t d) noexcept { return {{a, b, c, d}}; }
inline I4 operator+(I4 a, I4 b) noexcept { for (int i = 0; i < 4; ++i) a.v[i] += b.v[i]; return a; }
inline I4 operator&(I4 a, I4 b) noexcept { for (int i = 0; i < 4; ++i) a.v[i] &= b.v[i]; return a; }
inline I4 shiftRight(I4 a, int s) noexcept { for (int i = 0; i < 4; ++i) a.v[i] >>= s; return a; }
inline F4 toFloat(I4 a) noexcept {
    F4 r;
    for (int i = 0; i < 4; ++i) r.v[i] = static_cast<float>(static_cast<int32_t>(a.v[i]));
    return r;
}
inline void storeU(uint32_t* p, I4 a) noexcept { std::memcpy(p, a.v, sizeof a.v); }
inline void pairs(const float* x, const uint32_t* k, F4& first, F4& second) noexcept {
    for (int i = 0; i < 4; ++i) first.v[i] = x[k[i]], second.v[i] = x[k[i] + 1];
}
#endif

}  // namespace caw::simd4
