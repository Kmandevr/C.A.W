// Two doubles as one vector (SSE2 or NEON): a stereo pair's channels through one stream of the same arithmetic.
#pragma once

#include "caw/library/fastmath.hpp"

namespace caw {

// A stereo pair's two channels run through the same arithmetic in one vector on GCC and Clang (the plain struct
// elsewhere: MSVC and clang-cl). Each lane's arithmetic is the scalar one in the scalar order, but the engine's
// flags let the compiler fuse multiply-adds (Arm64) and reassociate sums, so the vector and the scalar code may
// differ in the last bits: the same arithmetic up to fusing or reassociation (speed phase 4, engine-performance.md).
#if defined(__GNUC__)
typedef double Pair __attribute__((vector_size(16)));
inline Pair pairOf(double a, double b) noexcept { return Pair{a, b}; }
inline Pair splat(double a) noexcept { return Pair{a, a}; }
inline double lane(const Pair& p, int i) noexcept { return p[i]; }
// std::max and std::min per lane ((a < b) ? b : a and (b < a) ? b : a), a select, no branch.
inline Pair pairMax(Pair a, Pair b) noexcept { return a < b ? b : a; }
inline Pair pairMin(Pair a, Pair b) noexcept { return b < a ? b : a; }
// x < 0 ? -x : x per lane.
inline Pair pairAbs(Pair x) noexcept { return x < splat(0.0) ? -x : x; }
// a - b < eps && b - a < eps ? b : a per lane: a value that has reached its target within eps snaps to it.
inline Pair pairSnap(Pair a, Pair b, double eps) noexcept {
    const Pair e = splat(eps);
    return (a - b < e) & (b - a < e) ? b : a;
}
// Each lane below 1e-20 in magnitude is 0 (a feedback state's subnormal tail, cut).
inline Pair flushPair(Pair p) noexcept { return (p < splat(1e-20)) & (p > splat(-1e-20)) ? splat(0.0) : p; }
#else
struct Pair {
    double v[2];
    friend Pair operator+(Pair a, Pair b) noexcept { return {{a.v[0] + b.v[0], a.v[1] + b.v[1]}}; }
    friend Pair operator-(Pair a, Pair b) noexcept { return {{a.v[0] - b.v[0], a.v[1] - b.v[1]}}; }
    friend Pair operator*(Pair a, Pair b) noexcept { return {{a.v[0] * b.v[0], a.v[1] * b.v[1]}}; }
    friend Pair operator/(Pair a, Pair b) noexcept { return {{a.v[0] / b.v[0], a.v[1] / b.v[1]}}; }
    Pair& operator+=(Pair b) noexcept { return *this = *this + b; }
    Pair& operator-=(Pair b) noexcept { return *this = *this - b; }
    Pair& operator*=(Pair b) noexcept { return *this = *this * b; }
};
inline Pair pairOf(double a, double b) noexcept { return {{a, b}}; }
inline Pair splat(double a) noexcept { return {{a, a}}; }
inline double lane(const Pair& p, int i) noexcept { return p.v[i]; }
inline Pair pairMax(Pair a, Pair b) noexcept {
    return {{a.v[0] < b.v[0] ? b.v[0] : a.v[0], a.v[1] < b.v[1] ? b.v[1] : a.v[1]}};
}
inline Pair pairMin(Pair a, Pair b) noexcept {
    return {{b.v[0] < a.v[0] ? b.v[0] : a.v[0], b.v[1] < a.v[1] ? b.v[1] : a.v[1]}};
}
inline Pair pairAbs(Pair x) noexcept { return {{x.v[0] < 0.0 ? -x.v[0] : x.v[0], x.v[1] < 0.0 ? -x.v[1] : x.v[1]}}; }
inline Pair pairSnap(Pair a, Pair b, double eps) noexcept {
    Pair r = a;
    for (int i = 0; i < 2; ++i)
        if (a.v[i] - b.v[i] < eps && b.v[i] - a.v[i] < eps) r.v[i] = b.v[i];
    return r;
}
inline Pair flushPair(Pair p) noexcept {
    for (double& x : p.v)
        if (x < 1e-20 && x > -1e-20) x = 0.0;
    return p;
}
#endif

// lib::tanhApprox per lane (its operations in its order; elsewhere two calls).
inline Pair tanhApproxPair(Pair x) noexcept {
#if defined(__GNUC__)
    x = x == x ? x : splat(0.0);
    x = x > splat(10.0) ? splat(10.0) : (x < splat(-10.0) ? splat(-10.0) : x);
    const Pair s = x * x;
    Pair p = splat(3.217632110003212e-11);
    p = p * s + 1.0357852250132971e-07;
    p = p * s + 4.092017186705684e-05;
    p = p * s + 0.0043728758223902315;
    p = p * s + 0.14059264090233234;
    p = p * s + 0.9999999993415611;
    Pair q = splat(2.6742358055163463e-09);
    q = q * s + 2.4792909092118756e-06;
    q = q * s + 0.0004906653531677001;
    q = q * s + 0.02901487015638532;
    q = q * s + 0.4739259712575389;
    q = q * s + 1.0;
    return x * p / q;
#else
    return pairOf(lib::tanhApprox(lane(x, 0)), lib::tanhApprox(lane(x, 1)));
#endif
}

}  // namespace caw
