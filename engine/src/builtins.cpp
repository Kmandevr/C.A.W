// Built-in function implementations; each runs over a whole block so the VM's per-call cost stays low.
#include "builtins.h"

#include <bit>
#include <cmath>
#include <cstring>

#include "detmath.h"

namespace caw {

namespace {

template <double (*F)(double)>
void unary(const CallArgs& c) {
    for (int i = 0; i < c.n; ++i) c.out[i] = F(c.a[0][i]);
}

template <double (*F)(double, double)>
void binary(const CallArgs& c) {
    for (int i = 0; i < c.n; ++i) c.out[i] = F(c.a[0][i], c.a[1][i]);
}

template <double (*F)(double, double, double)>
void ternary(const CallArgs& c) {
    for (int i = 0; i < c.n; ++i) c.out[i] = F(c.a[0][i], c.a[1][i], c.a[2][i]);
}

double fSin(double x) { return detSin(x); }
double fCos(double x) { return detCos(x); }
double fTan(double x) { return detTan(x); }
double fAbs(double x) { return std::fabs(x); }
double fFloor(double x) { return std::floor(x); }
double fCeil(double x) { return std::ceil(x); }
double fRound(double x) { return std::floor(x + 0.5); }
double fTrunc(double x) { return std::trunc(x); }
double fSqrt(double x) { return x > 0.0 ? std::sqrt(x) : 0.0; }
double fExp(double x) { return detExp(x); }
double fLog(double x) { return detLog(x); }
double fTanh(double x) { return detTanh(x); }
double fSign(double x) { return x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0); }
double fFract(double x) { return std::isfinite(x) ? x - std::floor(x) : 0.0; }
double fMtof(double n) { return 440.0 * detExp((n - 69.0) * (0.69314718055994530942 / 12.0)); }
double fPopcount(double x) { return std::popcount(toUint32(x)); }
double fClz(double x) { return std::countl_zero(toUint32(x)); }
double fCtz(double x) { return std::countr_zero(toUint32(x)); }
double fBitrev(double x) { return static_cast<int32_t>(bitReverse(toUint32(x))); }
double fBswap(double x) { return static_cast<int32_t>(byteSwap(toUint32(x))); }
double fBits(double x) { return std::bit_cast<int32_t>(static_cast<float>(finiteOr0(x))); }
double fFloat(double x) { return finiteOr0(std::bit_cast<float>(toUint32(x))); }

double fMin(double a, double b) { return a < b ? a : b; }
double fMax(double a, double b) { return a > b ? a : b; }
double fPow(double a, double b) { return detPow(a, b); }
double fRotl(double x, double n) { return static_cast<int32_t>(std::rotl(toUint32(x), static_cast<int>(toUint32(n) & 31))); }
double fRotr(double x, double n) { return static_cast<int32_t>(std::rotr(toUint32(x), static_cast<int>(toUint32(n) & 31))); }

double fClamp(double x, double lo, double hi) { return x < lo ? lo : (x > hi ? hi : x); }
double fMix(double a, double b, double x) { return a + (b - a) * x; }

void noInit(double*, uint32_t) {}

// hash(x): a repeatable 32-bit scramble of x, changed by the project seed.
void runHash(const CallArgs& c) {
    const uint32_t s = hash32(c.ctx->seed);
    for (int i = 0; i < c.n; ++i) c.out[i] = static_cast<double>(hash32(toUint32(c.a[0][i]) ^ s));
}

// noise(): white noise in [-1, 1) from t, the seed and the call site; noise(x) hashes x instead of t.
void noiseInit(double* s, uint32_t site) { s[0] = static_cast<double>(site); }
void runNoise(const CallArgs& c) {
    const uint32_t key = hash32(c.ctx->seed ^ (static_cast<uint32_t>(c.state[0]) * 0x9E3779B9U));
    const double* src = c.a[0] ? c.a[0] : c.ctx->vars[static_cast<int>(Var::T)];
    for (int i = 0; i < c.n; ++i) {
        const uint32_t h = hash32(toUint32(src[i]) ^ key);
        c.out[i] = static_cast<double>(h) * (1.0 / 2147483648.0) - 1.0;
    }
}

// Oscillators keep a phase in [0, 1); band-limited saw and square use PolyBLEP.
double polyBlep(double p, double dt) {
    if (dt <= 0.0) return 0.0;
    if (p < dt) {
        const double x = p / dt;
        return x + x - x * x - 1.0;
    }
    if (p > 1.0 - dt) {
        const double x = (p - 1.0) / dt;
        return x * x + x + x + 1.0;
    }
    return 0.0;
}

template <int Shape>
void runOsc(const CallArgs& c) {
    double p = c.state[0];
    const double inv = 1.0 / c.ctx->sr;
    for (int i = 0; i < c.n; ++i) {
        double dt = std::fabs(finiteOr0(c.a[0][i])) * inv;
        if (dt > 0.5) dt = 0.5;
        double v;
        if constexpr (Shape == 0) {
            v = detSin(kTwoPi * p);
        } else if constexpr (Shape == 1) {
            v = 2.0 * p - 1.0 - polyBlep(p, dt);
        } else if constexpr (Shape == 2) {
            double w = c.a[1][i];
            w = w < 0.01 ? 0.01 : (w > 0.99 ? 0.99 : w);
            v = (p < w ? 1.0 : -1.0) + polyBlep(p, dt);
            double q = p + 1.0 - w;
            q -= std::floor(q);
            v -= polyBlep(q, dt);
        } else {
            v = 4.0 * std::fabs(p - 0.5) - 1.0;
        }
        c.out[i] = v;
        p += dt;
        p -= std::floor(p);
    }
    c.state[0] = p;
}

// ad(trig, attack, decay): starts on each rise of trig above 0, linear attack, decay to -60 dB in `decay` seconds.
enum { AdPrev, AdLevel, AdStage, AdA, AdD, AdInc, AdCoef, AdSize };
void adInit(double* s, uint32_t) {
    s[AdA] = -1.0;
    s[AdD] = -1.0;
}
void runAd(const CallArgs& c) {
    double* s = c.state;
    const double sr = c.ctx->sr;
    for (int i = 0; i < c.n; ++i) {
        const double trig = c.a[0][i], a = c.a[1][i], d = c.a[2][i];
        if (a != s[AdA]) {
            s[AdA] = a;
            s[AdInc] = (a > 0.0 && std::isfinite(a)) ? 1.0 / (a * sr) : 2.0;
        }
        if (d != s[AdD]) {
            s[AdD] = d;
            s[AdCoef] = (d > 0.0 && std::isfinite(d)) ? detExp(-6.907755278982137 / (d * sr)) : 0.0;
        }
        if (!truthy(s[AdPrev]) && truthy(trig)) s[AdStage] = 1.0;
        s[AdPrev] = trig;
        if (s[AdStage] == 1.0) {
            s[AdLevel] += s[AdInc];
            if (s[AdLevel] >= 1.0) {
                s[AdLevel] = 1.0;
                s[AdStage] = 2.0;
            }
        } else if (s[AdStage] == 2.0) {
            s[AdLevel] *= s[AdCoef];
            if (s[AdLevel] < 1e-6) {
                s[AdLevel] = 0.0;
                s[AdStage] = 0.0;
            }
        }
        c.out[i] = s[AdLevel];
    }
}

// lpf/hpf/bpf(x, cutoff, q): one state-variable filter (Simper's trapezoidal SVF) with three outputs.
enum { SvIc1, SvIc2, SvF, SvQ, SvA1, SvA2, SvA3, SvK, SvSize };
void svfInit(double* s, uint32_t) {
    s[SvF] = -1.0;
    s[SvQ] = -1.0;
}
template <int Mode>
void runSvf(const CallArgs& c) {
    double* s = c.state;
    const double sr = c.ctx->sr;
    for (int i = 0; i < c.n; ++i) {
        const double x = finiteOr0(c.a[0][i]);
        double f = c.a[1][i], q = c.a[2][i];
        if (f != s[SvF] || q != s[SvQ]) {
            s[SvF] = f;
            s[SvQ] = q;
            double fc = finiteOr0(f);
            fc = fc < 10.0 ? 10.0 : (fc > 0.49 * sr ? 0.49 * sr : fc);
            double qq = finiteOr0(q);
            qq = qq < 0.1 ? 0.1 : (qq > 40.0 ? 40.0 : qq);
            const double g = detTan(kPi * fc / sr);
            s[SvK] = 1.0 / qq;
            s[SvA1] = 1.0 / (1.0 + g * (g + s[SvK]));
            s[SvA2] = g * s[SvA1];
            s[SvA3] = g * s[SvA2];
        }
        const double v3 = x - s[SvIc2];
        const double v1 = s[SvA1] * s[SvIc1] + s[SvA2] * v3;
        const double v2 = s[SvIc2] + s[SvA2] * s[SvIc1] + s[SvA3] * v3;
        s[SvIc1] = 2.0 * v1 - s[SvIc1];
        s[SvIc2] = 2.0 * v2 - s[SvIc2];
        if constexpr (Mode == 0) c.out[i] = v2;
        else if constexpr (Mode == 1) c.out[i] = x - s[SvK] * v1 - v2;
        else c.out[i] = v1;
    }
}

constexpr Var kNone = Var::Count;

const Builtin kBuiltins[] = {
    {"sin", 1, 1, {}, 0, kNone, noInit, unary<fSin>},
    {"cos", 1, 1, {}, 0, kNone, noInit, unary<fCos>},
    {"tan", 1, 1, {}, 0, kNone, noInit, unary<fTan>},
    {"abs", 1, 1, {}, 0, kNone, noInit, unary<fAbs>},
    {"floor", 1, 1, {}, 0, kNone, noInit, unary<fFloor>},
    {"ceil", 1, 1, {}, 0, kNone, noInit, unary<fCeil>},
    {"round", 1, 1, {}, 0, kNone, noInit, unary<fRound>},
    {"trunc", 1, 1, {}, 0, kNone, noInit, unary<fTrunc>},
    {"sqrt", 1, 1, {}, 0, kNone, noInit, unary<fSqrt>},
    {"exp", 1, 1, {}, 0, kNone, noInit, unary<fExp>},
    {"log", 1, 1, {}, 0, kNone, noInit, unary<fLog>},
    {"tanh", 1, 1, {}, 0, kNone, noInit, unary<fTanh>},
    {"sign", 1, 1, {}, 0, kNone, noInit, unary<fSign>},
    {"fract", 1, 1, {}, 0, kNone, noInit, unary<fFract>},
    {"mtof", 1, 1, {}, 0, kNone, noInit, unary<fMtof>},
    {"popcount", 1, 1, {}, 0, kNone, noInit, unary<fPopcount>},
    {"clz", 1, 1, {}, 0, kNone, noInit, unary<fClz>},
    {"ctz", 1, 1, {}, 0, kNone, noInit, unary<fCtz>},
    {"bitrev", 1, 1, {}, 0, kNone, noInit, unary<fBitrev>},
    {"bswap", 1, 1, {}, 0, kNone, noInit, unary<fBswap>},
    {"bits", 1, 1, {}, 0, kNone, noInit, unary<fBits>},
    {"float", 1, 1, {}, 0, kNone, noInit, unary<fFloat>},
    {"min", 2, 2, {}, 0, kNone, noInit, binary<fMin>},
    {"max", 2, 2, {}, 0, kNone, noInit, binary<fMax>},
    {"pow", 2, 2, {}, 0, kNone, noInit, binary<fPow>},
    {"rotl", 2, 2, {}, 0, kNone, noInit, binary<fRotl>},
    {"rotr", 2, 2, {}, 0, kNone, noInit, binary<fRotr>},
    {"clamp", 3, 3, {}, 0, kNone, noInit, ternary<fClamp>},
    {"mix", 3, 3, {}, 0, kNone, noInit, ternary<fMix>},
    {"hash", 1, 1, {}, 0, kNone, noInit, runHash},
    {"noise", 0, 1, {}, 1, Var::T, noiseInit, runNoise},
    {"sine", 1, 1, {}, 1, kNone, noInit, runOsc<0>},
    {"saw", 1, 1, {}, 1, kNone, noInit, runOsc<1>},
    {"square", 1, 2, {0, 0.5, 0}, 1, kNone, noInit, runOsc<2>},
    {"tri", 1, 1, {}, 1, kNone, noInit, runOsc<3>},
    {"ad", 1, 3, {0, 0.005, 0.3}, AdSize, kNone, adInit, runAd},
    {"lpf", 2, 3, {0, 0, 0.707}, SvSize, kNone, svfInit, runSvf<0>},
    {"hpf", 2, 3, {0, 0, 0.707}, SvSize, kNone, svfInit, runSvf<1>},
    {"bpf", 2, 3, {0, 0, 0.707}, SvSize, kNone, svfInit, runSvf<2>},
};

}  // namespace

int findBuiltin(const char* name) {
    for (int i = 0; i < static_cast<int>(sizeof(kBuiltins) / sizeof(kBuiltins[0])); ++i)
        if (std::strcmp(kBuiltins[i].name, name) == 0) return i;
    return -1;
}

const Builtin& builtin(int id) { return kBuiltins[id]; }

}  // namespace caw
