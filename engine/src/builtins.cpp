// Built-in functions and constants with their documentation; each function runs over a whole block to keep the VM's cost low.
#include "builtins.h"

#include <bit>
#include <cmath>
#include <cstring>

#include "detmath.h"

namespace caw {

namespace {

// ---------- helpers ----------

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

double clampd(double x, double lo, double hi) { return x < lo ? lo : (x > hi ? hi : x); }

// ---------- maths and bits (v1) ----------

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
void siteInit(double* s, uint32_t site) { s[0] = static_cast<double>(site); }

void runHash(const CallArgs& c) {
    const uint32_t s = hash32(c.ctx->seed);
    for (int i = 0; i < c.n; ++i) c.out[i] = static_cast<double>(hash32(toUint32(c.a[0][i]) ^ s));
}

uint32_t siteKey(const CallArgs& c) { return hash32(c.ctx->seed ^ (static_cast<uint32_t>(c.state[0]) * 0x9E3779B9U)); }

void runNoise(const CallArgs& c) {
    const uint32_t key = siteKey(c);
    const double* src = c.a[0] ? c.a[0] : c.ctx->vars[static_cast<int>(Var::T)];
    for (int i = 0; i < c.n; ++i) {
        const uint32_t h = hash32(toUint32(src[i]) ^ key);
        c.out[i] = static_cast<double>(h) * (1.0 / 2147483648.0) - 1.0;
    }
}

// rand(x): 0..1 from x and the seed (no call-site key, so the same x gives the same value anywhere).
double unit(uint32_t h) { return static_cast<double>(h) * (1.0 / 4294967296.0); }
void runRand(const CallArgs& c) {
    const uint32_t s = hash32(c.ctx->seed ^ 0x5bd1e995U);
    for (int i = 0; i < c.n; ++i) c.out[i] = unit(hash32(toUint32(c.a[0][i]) ^ s));
}
void runRandi(const CallArgs& c) {
    const uint32_t s = hash32(c.ctx->seed ^ 0x5bd1e995U);
    for (int i = 0; i < c.n; ++i) {
        const double n = std::floor(c.a[1][i]);
        c.out[i] = n >= 1 ? std::floor(unit(hash32(toUint32(c.a[0][i]) ^ s)) * n) : 0.0;
    }
}
void runChance(const CallArgs& c) {
    const uint32_t s = hash32(c.ctx->seed ^ 0x5bd1e995U);
    for (int i = 0; i < c.n; ++i) c.out[i] = unit(hash32(toUint32(c.a[0][i]) ^ s)) < c.a[1][i] ? 1.0 : 0.0;
}

// beats(n): seconds in n beats at the project tempo.
void runBeats(const CallArgs& c) {
    const double spb = 60.0 / c.ctx->bpm;
    for (int i = 0; i < c.n; ++i) c.out[i] = c.a[0][i] * spb;
}

// ---------- oscillators (v1) ----------

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

// ---------- envelopes ----------

// ad / env.ar: starts on each rise of trig above 0, linear attack, decay to -60 dB in `decay` seconds.
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

// Exponential coefficient that covers 60 dB in `seconds`, cached while the time stays the same.
double coefFor(double seconds, double sr, double& cacheIn, double& cacheOut) {
    if (seconds != cacheIn) {
        cacheIn = seconds;
        cacheOut = (seconds > 0.0 && std::isfinite(seconds)) ? detExp(-6.907755278982137 / (seconds * sr)) : 0.0;
    }
    return cacheOut;
}

// env.adsr(gate, attack, decay, sustain, release): holds at sustain while gate is above 0, releases when it falls.
enum { AsPrev, AsLevel, AsStage, AsA, AsInc, AsD, AsDCoef, AsR, AsRCoef, AsSize };
void adsrInit(double* s, uint32_t) {
    s[AsA] = -1.0;
    s[AsD] = -1.0;
    s[AsR] = -1.0;
}
void runAdsr(const CallArgs& c) {
    double* s = c.state;
    const double sr = c.ctx->sr;
    for (int i = 0; i < c.n; ++i) {
        const double gate = c.a[0][i], a = c.a[1][i];
        const double sus = clampd(finiteOr0(c.a[3][i]), 0.0, 1.0);
        if (a != s[AsA]) {
            s[AsA] = a;
            s[AsInc] = (a > 0.0 && std::isfinite(a)) ? 1.0 / (a * sr) : 2.0;
        }
        const double dc = coefFor(c.a[2][i], sr, s[AsD], s[AsDCoef]);
        const double rc = coefFor(c.a[4][i], sr, s[AsR], s[AsRCoef]);
        const bool on = truthy(gate);
        if (!truthy(s[AsPrev]) && on) s[AsStage] = 1.0;          // attack
        if (truthy(s[AsPrev]) && !on && s[AsStage] != 0.0) s[AsStage] = 4.0;  // release
        s[AsPrev] = gate;
        double& lv = s[AsLevel];
        if (s[AsStage] == 1.0) {
            lv += s[AsInc];
            if (lv >= 1.0) {
                lv = 1.0;
                s[AsStage] = 2.0;
            }
        } else if (s[AsStage] == 2.0) {
            lv = sus + (lv - sus) * dc;
            if (std::fabs(lv - sus) < 1e-6) {
                lv = sus;
                s[AsStage] = 3.0;
            }
        } else if (s[AsStage] == 3.0) {
            lv = sus + (lv - sus) * dc;  // a moving sustain glides instead of clicking
        } else if (s[AsStage] == 4.0) {
            lv *= rc;
            if (lv < 1e-6) {
                lv = 0.0;
                s[AsStage] = 0.0;
            }
        }
        c.out[i] = lv;
    }
}

// slew(x, rise, fall): moves toward x, taking `rise` seconds up and `fall` seconds down (63% of the way).
enum { SlY, SlR, SlRc, SlF, SlFc, SlInit, SlSize };
void slewInit(double* s, uint32_t) {
    s[SlR] = -1.0;
    s[SlF] = -1.0;
}
double onePoleCoef(double seconds, double sr, double& cacheIn, double& cacheOut) {
    if (seconds != cacheIn) {
        cacheIn = seconds;
        cacheOut = (seconds > 0.0 && std::isfinite(seconds)) ? 1.0 - detExp(-1.0 / (seconds * sr)) : 1.0;
    }
    return cacheOut;
}
void runSlew(const CallArgs& c) {
    double* s = c.state;
    for (int i = 0; i < c.n; ++i) {
        const double x = finiteOr0(c.a[0][i]);
        if (s[SlInit] == 0.0) {
            s[SlY] = x;
            s[SlInit] = 1.0;
        }
        const double fall = c.a[2][i] < 0.0 ? c.a[1][i] : c.a[2][i];
        const double k = x > s[SlY] ? onePoleCoef(c.a[1][i], c.ctx->sr, s[SlR], s[SlRc])
                                    : onePoleCoef(fall, c.ctx->sr, s[SlF], s[SlFc]);
        s[SlY] += (x - s[SlY]) * k;
        c.out[i] = s[SlY];
    }
}

// ---------- LFOs (tempo-synced, from the layer's time) ----------

template <int Shape>
void runLfo(const CallArgs& c) {
    const double* time = c.ctx->vars[static_cast<int>(Var::Time)];
    const double bps = c.ctx->bpm / 60.0;
    for (int i = 0; i < c.n; ++i) {
        const double beats = c.a[0][i];
        if (!(beats > 0.0) || !std::isfinite(beats) || !time) {
            c.out[i] = 0.0;
            continue;
        }
        const double cycles = time[i] * bps / beats + c.a[1][i];
        const double p = cycles - std::floor(cycles);
        double v;
        if constexpr (Shape == 0) v = detSin(kTwoPi * p);
        else if constexpr (Shape == 1) v = 1.0 - 4.0 * std::fabs(p - 0.5);
        else if constexpr (Shape == 2) v = 2.0 * p - 1.0;
        else if constexpr (Shape == 3) v = p < 0.5 ? 1.0 : -1.0;
        else v = static_cast<double>(hash32(toUint32(std::floor(cycles)) ^ siteKey(c))) * (1.0 / 2147483648.0) - 1.0;
        c.out[i] = v;
    }
}

// ---------- filters ----------

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
        else if constexpr (Mode == 2) c.out[i] = v1;
        else c.out[i] = x - s[SvK] * v1;  // notch
    }
}

// One-pole lowpass/highpass: gentle 6 dB/octave slopes.
enum { OpY, OpF, OpK, OpSize };
void opInit(double* s, uint32_t) { s[OpF] = -1.0; }
template <bool High>
void runOnePole(const CallArgs& c) {
    double* s = c.state;
    for (int i = 0; i < c.n; ++i) {
        const double x = finiteOr0(c.a[0][i]);
        if (c.a[1][i] != s[OpF]) {
            s[OpF] = c.a[1][i];
            const double fc = clampd(finiteOr0(s[OpF]), 1.0, 0.49 * c.ctx->sr);
            s[OpK] = 1.0 - detExp(-kTwoPi * fc / c.ctx->sr);
        }
        s[OpY] += (x - s[OpY]) * s[OpK];
        c.out[i] = High ? x - s[OpY] : s[OpY];
    }
}

// ---------- effects ----------

double fDrive(double x, double amount) {
    const double a = amount < 0.01 ? 0.01 : amount;
    return detTanh(finiteOr0(x) * a) / detTanh(a);
}
double fCrush(double x, double bits) {
    const double q = detPow(2.0, std::floor(clampd(bits, 1.0, 24.0)) - 1.0);
    return std::floor(finiteOr0(x) * q + 0.5) / q;
}
double fFoldFx(double x, double drive) { return detSin(finiteOr0(x) * drive * (kPi / 2.0)); }

// fx.delay(x, time, feedback, mix): up to 2 seconds at 96 kHz (1 s at 192 kHz), with linear interpolation.
// Only the header is cleared at a loop start; a slot not written since then reads as 0, as if the buffer were
// cleared, so the audio thread never has to clear 1.5 MB at once.
constexpr int kDelayMax = 192000;
enum { DlPos, DlCount, DlHeader, DlSize = DlHeader + kDelayMax };
void runDelay(const CallArgs& c) {
    double* buf = c.state + DlHeader;
    int pos = static_cast<int>(c.state[DlPos]);
    int written = static_cast<int>(c.state[DlCount]);
    for (int i = 0; i < c.n; ++i) {
        const double x = finiteOr0(c.a[0][i]);
        const double d = clampd(finiteOr0(c.a[1][i]) * c.ctx->sr, 1.0, kDelayMax - 2.0);
        const double fb = clampd(finiteOr0(c.a[2][i]), 0.0, 0.98);
        const double mix = clampd(finiteOr0(c.a[3][i]), 0.0, 1.0);
        const int di = static_cast<int>(d);
        const double frac = d - di;
        int r0 = pos - di;
        if (r0 < 0) r0 += kDelayMax;
        int r1 = r0 - 1;
        if (r1 < 0) r1 += kDelayMax;
        const double y0 = di <= written ? buf[r0] : 0.0;
        const double y1 = di + 1 <= written ? buf[r1] : 0.0;
        const double y = y0 + (y1 - y0) * frac;
        buf[pos] = x + y * fb;
        if (++pos >= kDelayMax) pos = 0;
        if (written < kDelayMax) ++written;
        c.out[i] = x * (1.0 - mix) + y * mix;
    }
    c.state[DlPos] = pos;
    c.state[DlCount] = written;
}

// fx.reverb(x, size, damp, mix): a mono Freeverb (8 combs, 4 allpasses), tunings scaled from 44.1 kHz.
constexpr int kCombLen[8] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
constexpr int kApLen[4] = {556, 441, 341, 225};
constexpr double kRvMaxScale = 192000.0 / 44100.0;
constexpr int rvCap(int len) { return static_cast<int>(len * kRvMaxScale) + 2; }
constexpr int kRvBufTotal = rvCap(1116) + rvCap(1188) + rvCap(1277) + rvCap(1356) + rvCap(1422) + rvCap(1491) +
                            rvCap(1557) + rvCap(1617) + rvCap(556) + rvCap(441) + rvCap(341) + rvCap(225);
// Like the delay, only the header is cleared at a loop start: each buffer is read only once it has wrapped.
enum { RvPos = 0, RvStore = 12, RvCount = 20, RvBuf = 21, RvSize = RvBuf + kRvBufTotal };
void runReverb(const CallArgs& c) {
    double* s = c.state;
    const double scale = clampd(c.ctx->sr, 8000.0, 192000.0) / 44100.0;
    int lens[12];
    double* bufs[12];
    double* p = s + RvBuf;
    for (int k = 0; k < 8; ++k) {
        lens[k] = static_cast<int>(kCombLen[k] * scale);
        bufs[k] = p;
        p += rvCap(kCombLen[k]);
    }
    for (int k = 0; k < 4; ++k) {
        lens[8 + k] = static_cast<int>(kApLen[k] * scale);
        bufs[8 + k] = p;
        p += rvCap(kApLen[k]);
    }
    for (int i = 0; i < c.n; ++i) {
        const double x = finiteOr0(c.a[0][i]);
        const double fb = 0.7 + 0.28 * clampd(finiteOr0(c.a[1][i]), 0.0, 1.0);
        const double damp = 0.4 * clampd(finiteOr0(c.a[2][i]), 0.0, 1.0);
        const double mix = clampd(finiteOr0(c.a[3][i]), 0.0, 1.0);
        const double in = x * 0.015;
        const double count = s[RvCount];
        double out = 0.0;
        for (int k = 0; k < 8; ++k) {
            int pos = static_cast<int>(s[RvPos + k]);
            if (pos >= lens[k]) pos = 0;
            const double y = count >= lens[k] ? bufs[k][pos] : 0.0;
            s[RvStore + k] = y * (1.0 - damp) + s[RvStore + k] * damp;
            bufs[k][pos] = in + s[RvStore + k] * fb;
            out += y;
            s[RvPos + k] = pos + 1 >= lens[k] ? 0 : pos + 1;
        }
        for (int k = 8; k < 12; ++k) {
            int pos = static_cast<int>(s[RvPos + k]);
            if (pos >= lens[k]) pos = 0;
            const double b = count >= lens[k] ? bufs[k][pos] : 0.0;
            const double y = b - out;
            bufs[k][pos] = out + b * 0.5;
            out = y;
            s[RvPos + k] = pos + 1 >= lens[k] ? 0 : pos + 1;
        }
        if (count < 1e9) s[RvCount] = count + 1;
        c.out[i] = x * (1.0 - mix) + out * mix;
    }
}

// fx.comp(x, threshold, ratio, attack, release): a feed-forward compressor; threshold in dB.
enum { CpEnv, CpA, CpAc, CpR, CpRc, CpSize };
void compInit(double* s, uint32_t) {
    s[CpA] = -1.0;
    s[CpR] = -1.0;
}
void runComp(const CallArgs& c) {
    double* s = c.state;
    for (int i = 0; i < c.n; ++i) {
        const double x = finiteOr0(c.a[0][i]);
        const double lvl = std::fabs(x);
        const double k = lvl > s[CpEnv] ? onePoleCoef(c.a[3][i], c.ctx->sr, s[CpA], s[CpAc])
                                        : onePoleCoef(c.a[4][i], c.ctx->sr, s[CpR], s[CpRc]);
        s[CpEnv] += (lvl - s[CpEnv]) * k;
        const double thr = detPow(10.0, clampd(finiteOr0(c.a[1][i]), -60.0, 0.0) / 20.0);
        const double ratio = clampd(finiteOr0(c.a[2][i]), 1.0, 40.0);
        double gain = 1.0;
        if (s[CpEnv] > thr) gain = detPow(s[CpEnv] / thr, 1.0 / ratio - 1.0);
        c.out[i] = x * gain;
    }
}

// ---------- glitch ----------

// glitch.hold(x, rate): sample and hold, picking up a new value `rate` times a second.
enum { ShPhase, ShVal, ShInit, ShSize };
void runHold(const CallArgs& c) {
    double* s = c.state;
    for (int i = 0; i < c.n; ++i) {
        if (s[ShInit] == 0.0 || s[ShPhase] >= 1.0) {
            s[ShVal] = finiteOr0(c.a[0][i]);
            s[ShInit] = 1.0;
            s[ShPhase] -= std::floor(s[ShPhase]);
        }
        s[ShPhase] += clampd(finiteOr0(c.a[1][i]), 0.0, c.ctx->sr) / c.ctx->sr;
        c.out[i] = s[ShVal];
    }
}

// glitch.stutter(x, on, length): while `on` is above 0, repeats the first `length` seconds heard after it rose.
// It only plays back what it recorded since `on` rose, so a loop start needs to clear only the header.
constexpr int kStutterMax = 96000;
enum { StPrev, StRec, StLen, StPos, StSize = 4 + kStutterMax };
void runStutter(const CallArgs& c) {
    double* s = c.state;
    double* buf = s + 4;
    for (int i = 0; i < c.n; ++i) {
        const double x = finiteOr0(c.a[0][i]);
        const bool on = truthy(c.a[1][i]);
        if (on && !truthy(s[StPrev])) {
            s[StRec] = 0;
            s[StPos] = 0;
            s[StLen] = clampd(std::floor(finiteOr0(c.a[2][i]) * c.ctx->sr), 1.0, kStutterMax);
        }
        s[StPrev] = c.a[1][i];
        if (!on) {
            c.out[i] = x;
            continue;
        }
        const int len = static_cast<int>(s[StLen]);
        int rec = static_cast<int>(s[StRec]);
        if (rec < len) {
            buf[rec] = x;
            s[StRec] = rec + 1;
            c.out[i] = x;
        } else {
            int pos = static_cast<int>(s[StPos]);
            c.out[i] = buf[pos];
            s[StPos] = pos + 1 >= len ? 0 : pos + 1;
        }
    }
}

// glitch.mask(x, mask): flips bits of the sound read as 16-bit numbers.
double fMask(double x, double mask) {
    const int32_t q = static_cast<int32_t>(std::floor(clampd(finiteOr0(x), -1.0, 1.0) * 32767.0));
    return static_cast<double>(q ^ (toInt32(mask) & 0xFFFF)) / 32767.0;
}
// glitch.wrap(x, amount): pushes the sound past full scale and wraps it around.
double fWrap(double x, double amount) {
    const double v = finiteOr0(x) * (amount < 1.0 ? 1.0 : amount) + 1.0;
    return v - 2.0 * std::floor(v / 2.0) - 1.0;
}

// ---------- music ----------

struct ScaleDef {
    const char* name;
    int n;
    int steps[12];
};
const ScaleDef kScales[] = {
    {"major", 7, {0, 2, 4, 5, 7, 9, 11}},     {"minor", 7, {0, 2, 3, 5, 7, 8, 10}},
    {"dorian", 7, {0, 2, 3, 5, 7, 9, 10}},    {"phrygian", 7, {0, 1, 3, 5, 7, 8, 10}},
    {"lydian", 7, {0, 2, 4, 6, 7, 9, 11}},    {"mixolydian", 7, {0, 2, 4, 5, 7, 9, 10}},
    {"locrian", 7, {0, 1, 3, 5, 6, 8, 10}},   {"harmonic", 7, {0, 2, 3, 5, 7, 8, 11}},
    {"melodic", 7, {0, 2, 3, 5, 7, 9, 11}},   {"pentatonic", 5, {0, 2, 4, 7, 9}},
    {"minorpenta", 5, {0, 3, 5, 7, 10}},      {"blues", 6, {0, 3, 5, 6, 7, 10}},
    {"chromatic", 12, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}}, {"whole", 6, {0, 2, 4, 6, 8, 10}},
};
constexpr int kScaleCount = sizeof(kScales) / sizeof(kScales[0]);

struct ChordDef {
    const char* name;
    int n;
    int tones[5];
};
const ChordDef kChords[] = {
    {"maj", 3, {0, 4, 7}},       {"min", 3, {0, 3, 7}},        {"dim", 3, {0, 3, 6}},      {"aug", 3, {0, 4, 8}},
    {"sus2", 3, {0, 2, 7}},      {"sus4", 3, {0, 5, 7}},       {"maj7", 4, {0, 4, 7, 11}}, {"min7", 4, {0, 3, 7, 10}},
    {"dom7", 4, {0, 4, 7, 10}},  {"maj9", 5, {0, 4, 7, 11, 14}}, {"min9", 5, {0, 3, 7, 10, 14}}, {"power", 2, {0, 7}},
};
constexpr int kChordCount = sizeof(kChords) / sizeof(kChords[0]);

const char* const kArpModes[] = {"up", "down", "updown", "random"};

int floorDiv(long a, long b) { return static_cast<int>(a >= 0 ? a / b : -((-a + b - 1) / b)); }

// NaN and huge values are cleaned before any cast to int, so every platform picks the same scale.
int scaleId(double v, const BlockCtx& ctx) {
    v = finiteOr0(v);
    if (v < 0) return ctx.keyScale;
    return v < kScaleCount ? static_cast<int>(v) : 1;
}
double rootNote(double v, const BlockCtx& ctx) {
    v = finiteOr0(v);
    return v < 0 ? 60.0 + ctx.keyRoot : std::floor(std::fmin(v, 1000.0));
}

// scale(degree, scale, root): the MIDI note of a scale degree; degrees past the end continue into the next octave.
void runScale(const CallArgs& c) {
    for (int i = 0; i < c.n; ++i) {
        const ScaleDef& sc = kScales[scaleId(c.a[1][i], *c.ctx)];
        const long d = static_cast<long>(std::floor(clampd(finiteOr0(c.a[0][i]), -1000.0, 1000.0)));
        const int oct = floorDiv(d, sc.n);
        c.out[i] = rootNote(c.a[2][i], *c.ctx) + 12.0 * oct + sc.steps[d - static_cast<long>(oct) * sc.n];
    }
}

// quantize(note, scale, root): the nearest note in the scale (ties go down).
void runQuantize(const CallArgs& c) {
    for (int i = 0; i < c.n; ++i) {
        const ScaleDef& sc = kScales[scaleId(c.a[1][i], *c.ctx)];
        const double note = clampd(finiteOr0(c.a[0][i]), -1000.0, 1000.0);
        const double root = rootNote(c.a[2][i], *c.ctx);
        double best = note, bestDist = 1e9;
        const int base = floorDiv(static_cast<long>(std::floor(note - root)), 12);
        for (int o = base - 1; o <= base + 1; ++o)
            for (int k = 0; k < sc.n; ++k) {
                const double cand = root + 12.0 * o + sc.steps[k];
                const double dist = std::fabs(cand - note);
                if (dist < bestDist || (dist == bestDist && cand < best)) {
                    best = cand;
                    bestDist = dist;
                }
            }
        c.out[i] = best;
    }
}

int chordTone(const ChordDef& ch, long index) {
    const int oct = floorDiv(index, ch.n);
    return 12 * oct + ch.tones[index - static_cast<long>(oct) * ch.n];
}

int chordId(double v) {
    v = finiteOr0(v);
    return v >= 0 && v < kChordCount ? static_cast<int>(v) : 0;
}

// chord(type, index, root): the index-th note of a chord; indexes past the end climb octaves.
void runChord(const CallArgs& c) {
    for (int i = 0; i < c.n; ++i) {
        const ChordDef& ch = kChords[chordId(c.a[0][i])];
        const long idx = static_cast<long>(std::floor(clampd(finiteOr0(c.a[1][i]), -1000.0, 1000.0)));
        c.out[i] = rootNote(c.a[2][i], *c.ctx) + chordTone(ch, idx);
    }
}

// arp(type, step, mode, root, octaves): walks through a chord one note per step.
void runArp(const CallArgs& c) {
    const uint32_t s = hash32(c.ctx->seed ^ 0x27d4eb2dU);
    for (int i = 0; i < c.n; ++i) {
        const ChordDef& ch = kChords[chordId(c.a[0][i])];
        const long step = static_cast<long>(std::floor(clampd(finiteOr0(c.a[1][i]), 0.0, 1e9)));
        const int mode = static_cast<int>(clampd(finiteOr0(c.a[2][i]), 0.0, 3.0));
        const int octaves = static_cast<int>(clampd(std::floor(finiteOr0(c.a[4][i])), 1.0, 4.0));
        const long n = static_cast<long>(ch.n) * octaves;
        long idx;
        if (mode == 0) idx = step % n;
        else if (mode == 1) idx = n - 1 - step % n;
        else if (mode == 2) {
            const long period = n > 1 ? 2 * n - 2 : 1;
            const long k = step % period;
            idx = k < n ? k : period - k;
        } else {
            idx = static_cast<long>(hash32(static_cast<uint32_t>(step) ^ s) % static_cast<uint32_t>(n));
        }
        c.out[i] = rootNote(c.a[3][i], *c.ctx) + chordTone(ch, idx);
    }
}

// euclid(hits, steps, pos, rotate): 1 where `hits` notes spread as evenly as possible over `steps` fall.
void runEuclid(const CallArgs& c) {
    for (int i = 0; i < c.n; ++i) {
        const long steps = static_cast<long>(clampd(std::floor(finiteOr0(c.a[1][i])), 1.0, 1024.0));
        const long hits = static_cast<long>(clampd(std::floor(finiteOr0(c.a[0][i])), 0.0, static_cast<double>(steps)));
        long pos = static_cast<long>(std::floor(clampd(finiteOr0(c.a[2][i]) + finiteOr0(c.a[3][i]), -1e9, 1e9))) % steps;
        if (pos < 0) pos += steps;
        c.out[i] = (pos * hits) % steps < hits ? 1.0 : 0.0;
    }
}

constexpr Var kNone = Var::Count;
// Docs strings: argument lines are "name: meaning". Examples are whole module bodies (float mode) that make sound.
const Builtin kBuiltins[] = {
    // Maths
    {"sin", 1, 1, {}, 0, kNone, noInit, unary<fSin>, "Maths", "Sine of x (radians). The same bits on every device.", {"x: angle in radians"}, "sin(time * 220 * 2 * pi) * 0.5"},
    {"cos", 1, 1, {}, 0, kNone, noInit, unary<fCos>, "Maths", "Cosine of x (radians).", {"x: angle in radians"}, "cos(time * 220 * 2 * pi) * 0.5"},
    {"tan", 1, 1, {}, 0, kNone, noInit, unary<fTan>, "Maths", "Tangent of x (radians); 0 where the cosine is exactly 0.", {"x: angle in radians"}, "clamp(tan(time * 110 * pi), -1, 1) * 0.3"},
    {"abs", 1, 1, {}, 0, kNone, noInit, unary<fAbs>, "Maths", "Absolute value.", {"x: any number"}, "abs(saw(110)) - 0.5"},
    {"floor", 1, 1, {}, 0, kNone, noInit, unary<fFloor>, "Maths", "Largest whole number not above x.", {"x: any number"}, "floor(saw(110) * 4) / 4 * 0.5"},
    {"ceil", 1, 1, {}, 0, kNone, noInit, unary<fCeil>, "Maths", "Smallest whole number not below x.", {"x: any number"}, "ceil(saw(110) * 4) / 4 * 0.5"},
    {"round", 1, 1, {}, 0, kNone, noInit, unary<fRound>, "Maths", "Nearest whole number; halves round up (like JavaScript).", {"x: any number"}, "round(sine(110) * 3) / 3 * 0.5"},
    {"trunc", 1, 1, {}, 0, kNone, noInit, unary<fTrunc>, "Maths", "Drops the fraction (towards 0).", {"x: any number"}, "trunc(sine(110) * 3) / 3 * 0.5"},
    {"sqrt", 1, 1, {}, 0, kNone, noInit, unary<fSqrt>, "Maths", "Square root; 0 for x <= 0.", {"x: any number"}, "sqrt(abs(sine(110))) * sign(sine(110)) * 0.5"},
    {"exp", 1, 1, {}, 0, kNone, noInit, unary<fExp>, "Maths", "e to the power x.", {"x: any number"}, "sine(110) * exp(-fract(time * bpm / 60) * 6) * 0.6"},
    {"log", 1, 1, {}, 0, kNone, noInit, unary<fLog>, "Maths", "Natural logarithm; 0 for x <= 0.", {"x: a positive number"}, "sine(110 + 40 * log(1 + step % 8)) * 0.5"},
    {"tanh", 1, 1, {}, 0, kNone, noInit, unary<fTanh>, "Maths", "Hyperbolic tangent: a smooth clipper.", {"x: any number"}, "tanh(saw(55) * 4) * 0.5"},
    {"sign", 1, 1, {}, 0, kNone, noInit, unary<fSign>, "Maths", "-1, 0 or 1.", {"x: any number"}, "sign(sine(110)) * 0.3"},
    {"fract", 1, 1, {}, 0, kNone, noInit, unary<fFract>, "Maths", "The part after the decimal point, 0..1 (also for negatives).", {"x: any number"}, "(fract(time * 110) * 2 - 1) * 0.5"},
    {"mtof", 1, 1, {}, 0, kNone, noInit, unary<fMtof>, "Maths", "MIDI note number to frequency in Hz (A4 = 69 = 440 Hz).", {"note: MIDI note number (C4 = 60)"}, "sine(mtof(A3)) * 0.5"},
    {"min", 2, 2, {}, 0, kNone, noInit, binary<fMin>, "Maths", "The smaller of a and b.", {"a: any number", "b: any number"}, "min(saw(110), 0.2)"},
    {"max", 2, 2, {}, 0, kNone, noInit, binary<fMax>, "Maths", "The larger of a and b.", {"a: any number", "b: any number"}, "max(saw(110), -0.2)"},
    {"pow", 2, 2, {}, 0, kNone, noInit, binary<fPow>, "Maths", "x to the power y (exact for whole y; 0 when undefined).", {"x: base", "y: exponent"}, "sine(110) * pow(0.5, step % 4)"},
    {"clamp", 3, 3, {}, 0, kNone, noInit, ternary<fClamp>, "Maths", "Keeps x between lo and hi.", {"x: any number", "lo: lowest result", "hi: highest result"}, "clamp(saw(110) * 3, -0.5, 0.5)"},
    {"mix", 3, 3, {}, 0, kNone, noInit, ternary<fMix>, "Maths", "Blends from a (amount 0) to b (amount 1).", {"a: first value", "b: second value", "amount: 0..1"}, "mix(sine(110), saw(110), pos) * 0.5"},
    {"beats", 1, 1, {}, 0, kNone, noInit, runBeats, "Maths", "Seconds in n beats at the project tempo, for delay times and envelopes.", {"n: beats (0.25 = a 16th)"}, "fx.delay(saw(220) * ad(step % 8 == 0, 0.001, 0.1), beats(0.75), 0.5, 0.5)"},
    // Bits
    {"popcount", 1, 1, {}, 0, kNone, noInit, unary<fPopcount>, "Bits", "How many bits are 1 in x (as 32 bits).", {"x: read as a 32-bit integer"}, "sine(110 * (1 + popcount(step))) * 0.4"},
    {"clz", 1, 1, {}, 0, kNone, noInit, unary<fClz>, "Bits", "Leading zero bits of x (32 for 0).", {"x: read as a 32-bit integer"}, "sine(55 * (1 + clz(step + 1) % 5)) * 0.4"},
    {"ctz", 1, 1, {}, 0, kNone, noInit, unary<fCtz>, "Bits", "Trailing zero bits of x (32 for 0).", {"x: read as a 32-bit integer"}, "sine(110 * (1 + ctz(step + 1) % 4)) * 0.4"},
    {"bitrev", 1, 1, {}, 0, kNone, noInit, unary<fBitrev>, "Bits", "Reverses the 32 bits of x.", {"x: read as a 32-bit integer"}, "((bitrev(floor(time * 8000)) >>> 24) & 255) / 128 - 1"},
    {"bswap", 1, 1, {}, 0, kNone, noInit, unary<fBswap>, "Bits", "Reverses the 4 bytes of x.", {"x: read as a 32-bit integer"}, "((bswap(floor(time * 8000)) >>> 16) & 255) / 128 - 1"},
    {"bits", 1, 1, {}, 0, kNone, noInit, unary<fBits>, "Bits", "The bits of x as a 32-bit float, read as an integer.", {"x: any number"}, "((bits(sine(110)) >> 16) & 255) / 128 - 1"},
    {"float", 1, 1, {}, 0, kNone, noInit, unary<fFloat>, "Bits", "The 32-bit float whose bits are i (the reverse of bits).", {"i: read as a 32-bit integer"}, "clamp(float(bits(sine(110)) ^ (step & 7)), -1, 1) * 0.5"},
    {"rotl", 2, 2, {}, 0, kNone, noInit, binary<fRotl>, "Bits", "Rotates the 32 bits of x left by n.", {"x: read as a 32-bit integer", "n: places, 0..31"}, "((rotl(floor(time * 8000), step % 8) >> 4) & 255) / 128 - 1"},
    {"rotr", 2, 2, {}, 0, kNone, noInit, binary<fRotr>, "Bits", "Rotates the 32 bits of x right by n.", {"x: read as a 32-bit integer", "n: places, 0..31"}, "((rotr(floor(time * 8000), 3) >> 1) & 255) / 128 - 1"},
    // Random (seeded, repeatable)
    {"hash", 1, 1, {}, 0, kNone, noInit, runHash, "Random", "A repeatable 32-bit scramble of x; changes with the project seed.", {"x: read as a 32-bit integer"}, "sine(110 * (1 + hash(step) % 4)) * 0.4"},
    {"noise", 0, 1, {}, 1, Var::T, siteInit, runNoise, "Random", "White noise in -1..1 from t (or from x), the seed and the call's place in the code.", {"x: optional; what the noise follows (default t)"}, "noise() * ad(step % 2 == 0, 0.001, 0.05) * 0.4"},
    {"rand", 1, 1, {}, 0, kNone, noInit, runRand, "Random", "A repeatable random number 0..1 for x (the same x gives the same value).", {"x: anything that picks the value, e.g. step"}, "sine(110 + 330 * rand(step)) * 0.4"},
    {"randi", 2, 2, {}, 0, kNone, noInit, runRandi, "Random", "A repeatable random whole number 0..n-1 for x.", {"x: anything that picks the value", "n: how many values"}, "sine(mtof(scale(randi(step, 8)))) * 0.4"},
    {"chance", 2, 2, {}, 0, kNone, noInit, runChance, "Random", "1 with probability p for x, otherwise 0; repeatable.", {"x: anything that picks the value, e.g. step", "p: probability 0..1"}, "noise() * ad(chance(step, 0.6), 0.001, 0.04) * 0.4"},
    // Oscillators
    {"sine", 1, 1, {}, 1, kNone, noInit, runOsc<0>, "Oscillators", "Sine wave, -1..1.", {"freq: Hz"}, "sine(220) * 0.5"},
    {"saw", 1, 1, {}, 1, kNone, noInit, runOsc<1>, "Oscillators", "Band-limited sawtooth, -1..1.", {"freq: Hz"}, "saw(110) * 0.4"},
    {"square", 1, 2, {0, 0.5}, 1, kNone, noInit, runOsc<2>, "Oscillators", "Band-limited square/pulse wave, -1..1.", {"freq: Hz", "width: pulse width 0.01..0.99 (default 0.5)"}, "square(110, 0.25) * 0.3"},
    {"tri", 1, 1, {}, 1, kNone, noInit, runOsc<3>, "Oscillators", "Triangle wave, -1..1.", {"freq: Hz"}, "tri(220) * 0.5"},
    // Envelopes and LFOs
    {"ad", 1, 3, {0, 0.005, 0.3}, AdSize, kNone, adInit, runAd, "Envelopes", "Attack-decay envelope 0..1, started each time trig rises above 0.", {"trig: starts the envelope when it goes above 0", "attack: seconds (default 0.005)", "decay: seconds to -60 dB (default 0.3)"}, "sine(110) * ad(step % 4 == 0, 0.001, 0.3)"},
    {"env.ar", 1, 3, {0, 0.005, 0.3}, AdSize, kNone, adInit, runAd, "Envelopes", "Attack-release envelope 0..1, started each time trig rises (same as ad).", {"trig: starts the envelope when it goes above 0", "attack: seconds (default 0.005)", "release: seconds to -60 dB (default 0.3)"}, "saw(110) * env.ar(step % 4 == 0, 0.01, 0.2) * 0.5"},
    {"env.adsr", 5, 5, {}, AsSize, kNone, adsrInit, runAdsr, "Envelopes", "Attack-decay-sustain-release envelope 0..1: holds at sustain while gate is above 0, releases when it falls.", {"gate: above 0 while the note is held", "attack: seconds", "decay: seconds to reach sustain", "sustain: level 0..1", "release: seconds to -60 dB after the gate falls"}, "saw(110) * env.adsr(step % 4 < 2, 0.01, 0.1, 0.6, 0.2) * 0.5"},
    {"slew", 2, 3, {0, 0.05, -1}, SlSize, kNone, slewInit, runSlew, "Envelopes", "Smooths x: moves toward it taking `rise` seconds up and `fall` seconds down. Good for glide and de-clicking.", {"x: the value to follow", "rise: seconds when going up (default 0.05)", "fall: seconds when going down (default: same as rise)"}, "sine(slew(mtof(scale(step % 5)), 0.03)) * 0.5"},
    {"lfo.sine", 1, 2, {1, 0}, 0, Var::Time, noInit, runLfo<0>, "LFOs", "Sine LFO -1..1 synced to the tempo.", {"beats: length of one cycle in beats", "phase: start point 0..1 (default 0)"}, "lpf(saw(55), 600 + 500 * lfo.sine(4), 4) * 0.5"},
    {"lfo.tri", 1, 2, {1, 0}, 0, Var::Time, noInit, runLfo<1>, "LFOs", "Triangle LFO -1..1 synced to the tempo.", {"beats: length of one cycle in beats", "phase: start point 0..1 (default 0)"}, "sine(220 + 50 * lfo.tri(1)) * 0.5"},
    {"lfo.saw", 1, 2, {1, 0}, 0, Var::Time, noInit, runLfo<2>, "LFOs", "Rising saw LFO -1..1 synced to the tempo.", {"beats: length of one cycle in beats", "phase: start point 0..1 (default 0)"}, "sine(220 + 100 * lfo.saw(2)) * 0.5"},
    {"lfo.square", 1, 2, {1, 0}, 0, Var::Time, noInit, runLfo<3>, "LFOs", "Square LFO (1 then -1) synced to the tempo.", {"beats: length of one cycle in beats", "phase: start point 0..1 (default 0)"}, "sine(220 * (1.5 + 0.5 * lfo.square(1))) * 0.5"},
    {"lfo.random", 1, 2, {1, 0}, 1, Var::Time, siteInit, runLfo<4>, "LFOs", "A new random level -1..1 every cycle (stepped), synced to the tempo and the seed.", {"beats: how long each level lasts, in beats", "phase: start point 0..1 (default 0)"}, "sine(330 + 200 * lfo.random(0.25)) * 0.5"},
    // Filters
    {"lpf", 2, 3, {0, 0, 0.707}, SvSize, kNone, svfInit, runSvf<0>, "Filters", "Low-pass state-variable filter (12 dB/octave).", {"x: input", "cutoff: Hz", "q: resonance 0.1..40 (default 0.707)"}, "lpf(saw(55), 800, 4) * 0.5"},
    {"hpf", 2, 3, {0, 0, 0.707}, SvSize, kNone, svfInit, runSvf<1>, "Filters", "High-pass state-variable filter (12 dB/octave).", {"x: input", "cutoff: Hz", "q: resonance 0.1..40 (default 0.707)"}, "hpf(noise(), 6000) * 0.3"},
    {"bpf", 2, 3, {0, 0, 0.707}, SvSize, kNone, svfInit, runSvf<2>, "Filters", "Band-pass state-variable filter.", {"x: input", "cutoff: centre Hz", "q: resonance 0.1..40 (default 0.707)"}, "bpf(noise(), 1200, 6) * 0.8"},
    {"notch", 2, 3, {0, 0, 0.707}, SvSize, kNone, svfInit, runSvf<3>, "Filters", "Notch (band-reject) state-variable filter.", {"x: input", "cutoff: centre Hz", "q: width 0.1..40 (default 0.707)"}, "notch(saw(110), 1000, 2) * 0.4"},
    {"lp1", 2, 2, {}, OpSize, kNone, opInit, runOnePole<false>, "Filters", "Gentle one-pole low-pass (6 dB/octave).", {"x: input", "cutoff: Hz"}, "lp1(noise(), 500) * 0.8"},
    {"hp1", 2, 2, {}, OpSize, kNone, opInit, runOnePole<true>, "Filters", "Gentle one-pole high-pass (6 dB/octave); removes rumble and DC.", {"x: input", "cutoff: Hz"}, "hp1(saw(55), 200) * 0.5"},
    // Effects
    {"fx.drive", 2, 2, {}, 0, kNone, noInit, binary<fDrive>, "Effects", "Warm saturation (tanh), level-matched so full scale stays full scale.", {"x: input", "amount: 1 = clean, 10 = heavy"}, "fx.drive(sine(55), 8) * 0.5"},
    {"fx.crush", 2, 2, {}, 0, kNone, noInit, binary<fCrush>, "Effects", "Bit crusher: rounds the sound to fewer bits.", {"x: input", "bits: 1..24"}, "fx.crush(sine(110), 3) * 0.5"},
    {"fx.fold", 2, 2, {}, 0, kNone, noInit, binary<fFoldFx>, "Effects", "Wavefolder: more drive folds the wave back on itself.", {"x: input", "drive: 1..12"}, "fx.fold(sine(110), 4) * 0.5"},
    {"fx.delay", 2, 4, {0, 0.25, 0.4, 0.5}, DlSize, kNone, noInit, runDelay, "Effects", "Echo with feedback, up to 2 s (at 96 kHz).", {"x: input", "time: seconds (try beats(0.75))", "feedback: 0..0.98 (default 0.4)", "mix: dry 0 .. wet 1 (default 0.5)"}, "fx.delay(saw(220) * ad(step % 8 == 0, 0.001, 0.08), beats(0.5), 0.6, 0.5)", DlHeader},
    {"fx.reverb", 1, 4, {0, 0.7, 0.3, 0.3}, RvSize, kNone, noInit, runReverb, "Effects", "Room reverb (mono Freeverb).", {"x: input", "size: 0..1 (default 0.7)", "damp: high-frequency damping 0..1 (default 0.3)", "mix: dry 0 .. wet 1 (default 0.3)"}, "fx.reverb(noise() * ad(step % 8 == 0, 0.001, 0.05), 0.8, 0.3, 0.5)", RvBuf},
    {"fx.comp", 1, 5, {0, -18, 4, 0.005, 0.1}, CpSize, kNone, compInit, runComp, "Effects", "Compressor: turns down whatever goes above the threshold.", {"x: input", "threshold: dB, -60..0 (default -18)", "ratio: 1..40 (default 4)", "attack: seconds (default 0.005)", "release: seconds (default 0.1)"}, "fx.comp(saw(55) * ad(step % 4 == 0, 0.001, 0.4), -24, 8) * 1.5"},
    // Glitch
    {"glitch.hold", 2, 2, {}, ShSize, kNone, noInit, runHold, "Glitch", "Sample and hold: grabs a new value `rate` times a second and holds it.", {"x: input", "rate: holds per second"}, "glitch.hold(sine(220), 2000) * 0.5"},
    {"glitch.stutter", 3, 3, {}, StSize, kNone, noInit, runStutter, "Glitch", "While `on` is above 0, repeats the first `length` seconds heard after it rose (up to 1 s at 96 kHz).", {"x: input", "on: above 0 while stuttering", "length: seconds to repeat"}, "glitch.stutter(saw(110 + step * 20) * 0.4, step % 16 >= 12, beats(0.125))", 4},
    {"glitch.mask", 2, 2, {}, 0, kNone, noInit, binary<fMask>, "Glitch", "Flips bits of the sound read as 16-bit numbers.", {"x: input", "mask: bits to flip, 0..65535"}, "glitch.mask(sine(110) * 0.5, 0x0F00)"},
    {"glitch.wrap", 2, 2, {}, 0, kNone, noInit, binary<fWrap>, "Glitch", "Pushes the sound past full scale and wraps it around to the other side.", {"x: input", "amount: 1 = clean, more = wilder"}, "glitch.wrap(sine(110), 3) * 0.5"},
    // Music
    {"scale", 1, 3, {0, -1, -1}, 0, kNone, noInit, runScale, "Music", "The MIDI note of a scale degree; degrees past the end continue into the next octave.", {"degree: 0 = root, 1 = second note, ... (negative goes down)", "scale: a scale.* constant (default: the project key's scale)", "root: MIDI note of degree 0 (default: the project key in octave 4)"}, "sine(mtof(scale(step % 8))) * ad(1, 0.005, 0.2) * 0.5"},
    {"quantize", 1, 3, {0, -1, -1}, 0, kNone, noInit, runQuantize, "Music", "Moves a MIDI note to the nearest note of the scale.", {"note: MIDI note number", "scale: a scale.* constant (default: the project key's scale)", "root: any note of the key (default: the project key)"}, "sine(mtof(quantize(48 + rand(step) * 24))) * 0.5"},
    {"chord", 2, 3, {0, 0, -1}, 0, kNone, noInit, runChord, "Music", "The index-th note of a chord; indexes past the end climb octaves.", {"type: a chord.* constant", "index: 0 = root, 1 = next note, ...", "root: MIDI note (default: the project key in octave 4)"}, "(sine(mtof(chord(chord.min7, 0))) + sine(mtof(chord(chord.min7, 1))) + sine(mtof(chord(chord.min7, 2)))) * 0.2"},
    {"arp", 2, 5, {0, 0, 0, -1, 1}, 0, kNone, noInit, runArp, "Music", "Walks through a chord one note per step (up, down, up-down or random).", {"type: a chord.* constant", "step: which step of the arpeggio (e.g. step)", "mode: an arp.* constant (default arp.up)", "root: MIDI note (default: the project key in octave 4)", "octaves: 1..4 (default 1)"}, "saw(mtof(arp(chord.min, step, arp.updown, 57, 2))) * ad(1, 0.002, 0.1) * 0.4"},
    {"euclid", 3, 4, {0, 16, 0, 0}, 0, kNone, noInit, runEuclid, "Music", "1 on the steps where `hits` notes spread as evenly as possible over `steps`; otherwise 0.", {"hits: how many notes", "steps: length of the pattern", "pos: which step (e.g. step)", "rotate: shifts the pattern (default 0)"}, "noise() * ad(euclid(5, 16, step), 0.001, 0.05) * 0.4"},
};

const char* const kScaleNames[] = {"major", "minor", "dorian", "phrygian", "lydian", "mixolydian", "locrian",
                                   "harmonic", "melodic", "pentatonic", "minorpenta", "blues", "chromatic", "whole"};
const char* const kChordNames[] = {"maj", "min", "dim", "aug", "sus2", "sus4", "maj7", "min7", "dom7", "maj9", "min9", "power"};

const ConstantGroup kGroups[] = {
    {"scale", "Scales for scale() and quantize(): major, natural minor, the modes, harmonic and melodic minor, major and minor pentatonic, blues, chromatic and whole-tone.", kScaleNames, kScaleCount},
    {"chord", "Chord shapes for chord() and arp().", kChordNames, kChordCount},
    {"arp", "Arpeggio directions for arp().", kArpModes, 4},
};

}  // namespace

int findBuiltin(const char* name) {
    for (int i = 0; i < builtinCount(); ++i)
        if (std::strcmp(kBuiltins[i].name, name) == 0) return i;
    return -1;
}

const Builtin& builtin(int id) { return kBuiltins[id]; }

int builtinCount() { return static_cast<int>(sizeof(kBuiltins) / sizeof(kBuiltins[0])); }

bool findConstant(const char* name, double& value) {
    for (const ConstantGroup& g : kGroups) {
        const size_t len = std::strlen(g.prefix);
        if (std::strncmp(name, g.prefix, len) != 0 || name[len] != '.') continue;
        for (int i = 0; i < g.count; ++i)
            if (std::strcmp(name + len + 1, g.names[i]) == 0) {
                value = i;
                return true;
            }
    }
    return false;
}

const ConstantGroup* constantGroups(int& count) {
    count = static_cast<int>(sizeof(kGroups) / sizeof(kGroups[0]));
    return kGroups;
}

}  // namespace caw
