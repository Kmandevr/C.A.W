// Build-time generator of Timber's Simulated piano tables (src/timber_piano_tables.inc): finite-difference hammer-string strikes (Chaigne and Askenfelt) and the soundboards' parallel second-order fits (Bank); --check regenerates and compares.
//
// Usage: timber_piano_gen --write <file>   writes the tables
//        timber_piano_gen --check <file>   regenerates them and compares with <file> (numbers within rounding): CI's check
//
// Original code, run during development; its output is committed. Nothing here runs in the app.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "caw/detmath.hpp"
#include "timber_piano_curves.h"

using namespace caw;
namespace pc = caw::timber::piano_curves;

namespace {

constexpr double kPi = 3.14159265358979323846;

double noteHz(double key) { return 440.0 * detPow(2.0, (key - 69.0) / 12.0); }

// A piecewise curve over the keyboard: linear in `key` between anchors, either in value or in log value.
double curve(const double (*a)[2], int n, double key, bool logScale) {
    if (key <= a[0][0]) return a[0][1];
    for (int i = 1; i < n; ++i)
        if (key <= a[i][0]) {
            const double f = (key - a[i - 1][0]) / (a[i][0] - a[i - 1][0]);
            return logScale ? a[i - 1][1] * detPow(a[i][1] / a[i - 1][1], f) : a[i - 1][1] + (a[i][1] - a[i - 1][1]) * f;
        }
    return a[n - 1][1];
}

// ---------- The hammer and the string (Chaigne and Askenfelt, JASA 95(2) and 95(3), 1994) ----------
//
// The string: y_tt = c^2 y_xx - k^2 y_xxxx - 2 b1 y_t + 2 b3 y_txx + f(x, t) / rho, simply supported at both ends,
// in the explicit finite-difference scheme of their part I. The hammer: a mass M on a felt of force F = K d^p while
// compressed (d its compression against the string under it), M eta_tt = -F; the force is spread over the hammer's
// width. [Assumption] The parameter anchors below: hammer masses, felt K and p, string lengths, the strike point
// and the damping are typical values interpolated through their three notes (C2, C4, C7) as commonly cited from
// part II; its table was not re-read on 2026-11-20. Tension is about 750 N (1,100 N on the lowest wound strings);
// the linear mass follows from it, the length and f0; the stiffness from the inharmonicity curve.
struct Strike {
    std::vector<double> force;  // at kPulseRate, kPulseFrames long
    double peak = 0;            // N
    double contactMs = 0;       // the first contact's length
};

Strike strike(double key, double speed) {
    static constexpr double kLength[][2] = {{21, 1.95}, {36, 1.45}, {48, 1.05}, {60, 0.62}, {72, 0.33}, {84, 0.175}, {96, 0.09}, {108, 0.052}};
    static constexpr double kTension[][2] = {{21, 1100}, {36, 750}, {60, 700}, {96, 750}, {108, 750}};
    static constexpr double kMass[][2] = {{21, 0.0110}, {36, 0.0049}, {60, 0.00297}, {96, 0.0022}, {108, 0.0020}};
    static constexpr double kP[][2] = {{21, 2.2}, {36, 2.3}, {60, 2.5}, {96, 3.0}, {108, 3.0}};
    static constexpr double kK[][2] = {{21, 1.0e8}, {36, 4.0e8}, {60, 4.5e9}, {96, 1.0e12}, {108, 2.0e12}};
    static constexpr double kBeta[][2] = {{21, 0.122}, {60, 0.12}, {96, 0.0625}, {108, 0.05}};
    const double L = curve(kLength, 8, key, true), T = curve(kTension, 5, key, false);
    const double M = curve(kMass, 5, key, true), p = curve(kP, 5, key, false), K = curve(kK, 5, key, true);
    const double beta = curve(kBeta, 4, key, false);
    const double f0 = noteHz(key);
    const double c = 2.0 * L * f0, rho = T / (c * c);
    const double kappa = std::sqrt(pc::inharmonicity(key)) * c * L / kPi;
    const double b1 = 1.0, b3 = 5.0e-9;  // s^-1 and m^2/s: over 8 ms they barely matter
    // The time step: a power-of-two fraction of the table's period, fine enough that the stable space step leaves
    // at least 40 points on the string; at most 400 points (a coarser grid is still stable).
    int over = 16;
    double dt = 0, dx = 0;
    int N = 0;
    for (;; over *= 2) {
        dt = 1.0 / (pc::kPulseRate * over);
        const double a = c * c * dt * dt, b = 4.0 * kappa * kappa * dt * dt;
        const double u = (-a + std::sqrt(a * a + 4.0 * b * 0.9)) / (2.0 * b);  // 1/dx^2 at the stability limit (0.9)
        const double dxMin = 1.0 / std::sqrt(u);
        N = static_cast<int>(L / dxMin);
        if (N >= 40 || over >= 1024) break;
    }
    if (N > 400) N = 400;
    dx = L / N;
    const double lam2 = c * c * dt * dt / (dx * dx), mu2 = kappa * kappa * dt * dt / (dx * dx * dx * dx);
    const double damp3 = 2.0 * b3 * dt / (dx * dx), d1 = b1 * dt;
    std::vector<double> y0(N + 3, 0.0), y1(N + 3, 0.0), y2(N + 3, 0.0);  // index i + 1 for point i (ghosts at 0 and N + 2)
    // The hammer's width (about 1 cm at the crown's contact) as a Hann window over the string's points.
    const int centre = static_cast<int>(std::lround(beta * N));
    const int half = std::max(1, static_cast<int>(std::lround(0.005 / dx)));
    std::vector<double> g(2 * half + 1);
    double gs = 0;
    for (int k = -half; k <= half; ++k) gs += g[k + half] = 0.5 + 0.5 * std::cos(kPi * k / (half + 1));
    for (double& w : g) w /= gs;
    double eta = 0, etaPrev = -speed * dt;  // the hammer just touching, moving up at `speed`
    const int steps = pc::kPulseFrames * over;
    Strike s;
    s.force.assign(pc::kPulseFrames, 0.0);
    bool touched = false, left = false;
    for (int n = 0; n < steps; ++n) {
        double under = 0;
        for (int k = -half; k <= half; ++k) under += g[k + half] * y1[centre + k + 1];
        const double d = eta - under;
        const double F = d > 0 ? K * detPow(d, p) : 0.0;
        if (F > 0) touched = true;
        if (touched && F == 0 && !left) left = true, s.contactMs = n * dt * 1000.0;
        // The string.
        for (int i = 1; i < N; ++i) {
            const int j = i + 1;
            const double lap1 = y1[j + 1] - 2 * y1[j] + y1[j - 1], lap0 = y0[j + 1] - 2 * y0[j] + y0[j - 1];
            const double bih = y1[j + 2] - 4 * y1[j + 1] + 6 * y1[j] - 4 * y1[j - 1] + y1[j - 2];
            double f = 0;
            const int k = i - centre;
            if (k >= -half && k <= half) f = F * g[k + half] / dx;
            y2[j] = (2 * y1[j] - (1 - d1) * y0[j] + lam2 * lap1 - mu2 * bih + damp3 * (lap1 - lap0) + dt * dt * f / rho) / (1 + d1);
        }
        y2[1] = 0, y2[N + 1] = 0, y2[0] = -y2[2], y2[N + 2] = -y2[N];  // simply supported
        std::swap(y0, y1), std::swap(y1, y2);
        // The hammer.
        const double etaNext = 2 * eta - etaPrev - dt * dt * F / M;
        etaPrev = eta, eta = etaNext;
        s.force[n / over] += F / over;  // the mean over each table frame
    }
    if (!left) s.contactMs = steps * dt * 1000.0;
    for (double f : s.force) s.peak = std::max(s.peak, f);
    return s;
}

// ---------- The soundboards (Bank, "Direct design of parallel second-order filters for instrument body modeling",
// ICMC 2007: a fixed logarithmic pole grid, the numerators by least squares) ----------
//
// The target is a modal soundboard synthesised from published statistics: [Fact, Ege, Boutillon and Rebillat, JSV
// 332(5), 2013, read 2026-11-20] a modal loss factor of about 2 % up to about 3 kHz; [Assumption] above it rising to
// 5 % at 14 kHz (the region turns noise-like), a mode every 18 Hz on average (Grand) or 25 Hz (Upright), seeded
// positions and amplitudes, and a mobility envelope per board. Each section is a decaying complex exponential
// Re(c e^{s t}), s = -sigma + j w (impulse-invariant at any sample rate): two outputs (left, right) share its pole.
// Nothing is computed per string partial (the Modartt reading, docs/decisions.md).
struct Uniform {
    uint32_t s;
    double next() {
        s = s * 1664525u + 1013904223u;
        return (s >> 8) * (1.0 / 16777216.0);
    }
};

struct Mode {
    double f, sigma, aL, aR;
};

double envelopeDb(int board, double f) {
    const double oct = detLog(f / 1000.0) / detLog(2.0);
    double db = 0;
    db -= 10.0 * detLog(1.0 + detPow(60.0 / f, 4.0)) / detLog(10.0);  // the low end
    if (f > 1000.0) db -= 3.0 * oct;
    if (f > 5000.0) db -= 6.0 * detLog(f / 5000.0) / detLog(2.0);
    if (board >= 1) {  // Upright (and Felt, an upright with its felt rail): a boxy peak, less of both ends
        const double o = detLog(f / 400.0) / detLog(2.0);
        db += 6.0 * detExp(-o * o) - (f < 100.0 ? 5.0 : 0.0) - (f > 5000.0 ? 4.0 : 0.0);
    }
    if (board == 2 && f > 1200.0) db -= 12.0 * detLog(f / 1200.0) / detLog(2.0);
    return db;
}

std::vector<Mode> boardModes(int board) {
    std::vector<Mode> m;
    Uniform u{0xB0A2Du + 7919u * static_cast<uint32_t>(board)};
    const double spacing = board == 0 ? 18.0 : 25.0;
    for (double f = 45.0; f < 14000.0; f += spacing * (0.6 + 0.8 * u.next())) {
        const double eta = f < 3000.0 ? 0.02 : 0.02 + 0.03 * (f - 3000.0) / 11000.0;
        const double a = detPow(10.0, envelopeDb(board, f) / 20.0);
        // Gaussian-ish amplitudes (the sum of three uniforms), independent per side: the two mics hear the modes
        // with their own radiation weights.
        const double gl = u.next() + u.next() + u.next() - 1.5, gr = u.next() + u.next() + u.next() - 1.5;
        m.push_back({f, kPi * eta * f, a * gl, a * gr});
    }
    return m;
}

struct Fit {
    std::vector<double> hz, sigma;
    std::vector<double> c[3][4];  // per board: left re, left im, right re, right im
};

// Solves the symmetric positive system A x = b (n x n, row-major) by Cholesky, in place.
bool cholesky(std::vector<double>& A, std::vector<double>& b, int n) {
    for (int j = 0; j < n; ++j) {
        double d = A[j * n + j];
        for (int k = 0; k < j; ++k) d -= A[j * n + k] * A[j * n + k];
        if (d <= 0) return false;
        d = std::sqrt(d);
        A[j * n + j] = d;
        for (int i = j + 1; i < n; ++i) {
            double s = A[i * n + j];
            for (int k = 0; k < j; ++k) s -= A[i * n + k] * A[j * n + k];
            A[i * n + j] = s / d;
        }
    }
    for (int i = 0; i < n; ++i) {
        double s = b[i];
        for (int k = 0; k < i; ++k) s -= A[i * n + k] * b[k];
        b[i] = s / A[i * n + i];
    }
    for (int i = n - 1; i >= 0; --i) {
        double s = b[i];
        for (int k = i + 1; k < n; ++k) s -= A[k * n + i] * b[k];
        b[i] = s / A[i * n + i];
    }
    return true;
}

Fit fitBoards(int K) {
    Fit fit;
    const double lo = 40.0, hi = 16000.0;
    for (int k = 0; k < K; ++k) fit.hz.push_back(lo * detPow(hi / lo, static_cast<double>(k) / (K - 1)));
    for (int k = 0; k < K; ++k) {  // the pole's damping from the grid's spacing (Bank's rule: half the spacing)
        const double a = k > 0 ? fit.hz[k - 1] : fit.hz[k] * fit.hz[k] / fit.hz[k + 1];
        const double b = k < K - 1 ? fit.hz[k + 1] : fit.hz[k] * fit.hz[k] / fit.hz[k - 1];
        fit.sigma.push_back(0.5 * 2.0 * kPi * (b - a) / 2.0);
    }
    // The frequencies the fit is made at: 1,600 points on a logarithmic grid.
    const int F = 1600;
    std::vector<double> w(F);
    for (int i = 0; i < F; ++i) w[i] = 2.0 * kPi * 30.0 * detPow(18000.0 / 30.0, static_cast<double>(i) / (F - 1));
    // The basis: column 2k is Re c_k's response, 2k + 1 Im c_k's (complex values at each frequency).
    const int n = 2 * K;
    std::vector<double> br(static_cast<size_t>(F) * n), bi(static_cast<size_t>(F) * n);
    for (int k = 0; k < K; ++k) {
        const double sr = -fit.sigma[k], si = 2.0 * kPi * fit.hz[k];
        for (int i = 0; i < F; ++i) {
            // 1 / (jw - s) and 1 / (jw - conj s)
            const double ar = -sr, ai = w[i] - si, cr = -sr, ci = w[i] + si;
            const double da = ar * ar + ai * ai, dc = cr * cr + ci * ci;
            const double p_r = ar / da, p_i = -ai / da, q_r = cr / dc, q_i = -ci / dc;
            // Re part: (p + q) / 2; Im part: j (p - q) / 2
            br[static_cast<size_t>(i) * n + 2 * k] = 0.5 * (p_r + q_r);
            bi[static_cast<size_t>(i) * n + 2 * k] = 0.5 * (p_i + q_i);
            br[static_cast<size_t>(i) * n + 2 * k + 1] = -0.5 * (p_i - q_i);
            bi[static_cast<size_t>(i) * n + 2 * k + 1] = 0.5 * (p_r - q_r);
        }
    }
    std::vector<double> AtA(static_cast<size_t>(n) * n, 0.0);
    for (int i = 0; i < F; ++i)
        for (int a = 0; a < n; ++a) {
            const double xr = br[static_cast<size_t>(i) * n + a], xi = bi[static_cast<size_t>(i) * n + a];
            for (int b = 0; b <= a; ++b)
                AtA[static_cast<size_t>(a) * n + b] += xr * br[static_cast<size_t>(i) * n + b] + xi * bi[static_cast<size_t>(i) * n + b];
        }
    double tr = 0;
    for (int a = 0; a < n; ++a) tr += AtA[static_cast<size_t>(a) * n + a];
    for (int a = 0; a < n; ++a) {
        AtA[static_cast<size_t>(a) * n + a] += 1e-7 * tr / n;
        for (int b = 0; b < a; ++b) AtA[static_cast<size_t>(b) * n + a] = AtA[static_cast<size_t>(a) * n + b];
    }
    for (int board = 0; board < 3; ++board) {
        const std::vector<Mode> modes = boardModes(board);
        double gain = 0;
        std::vector<double> sol[2];
        for (int side = 0; side < 2; ++side) {
            // The target's response: sum of a_m w_m / ((sigma_m + jw)^2 + w_m^2) (a decaying sine per mode).
            std::vector<double> tr(F, 0.0), ti(F, 0.0);
            for (const Mode& m : modes) {
                const double wm = 2.0 * kPi * m.f, a = side == 0 ? m.aL : m.aR;
                for (int i = 0; i < F; ++i) {
                    const double re = m.sigma * m.sigma - w[i] * w[i] + wm * wm, im = 2.0 * m.sigma * w[i];
                    const double d = re * re + im * im;
                    tr[i] += a * wm * re / d, ti[i] -= a * wm * im / d;
                }
            }
            std::vector<double> rhs(n, 0.0);
            for (int i = 0; i < F; ++i)
                for (int a = 0; a < n; ++a)
                    rhs[a] += br[static_cast<size_t>(i) * n + a] * tr[i] + bi[static_cast<size_t>(i) * n + a] * ti[i];
            std::vector<double> A = AtA;
            if (!cholesky(A, rhs, n)) {
                std::fprintf(stderr, "the soundboard fit is singular\n");
                std::exit(2);
            }
            sol[side] = rhs;
            // The fitted response's mean power over 100 Hz..8 kHz (log grid): both sides are scaled to 1 together.
            for (int i = 0; i < F; ++i) {
                const double f = w[i] / (2.0 * kPi);
                if (f < 100.0 || f > 8000.0) continue;
                double hr = 0, hi2 = 0;
                for (int a = 0; a < n; ++a) hr += br[static_cast<size_t>(i) * n + a] * rhs[a], hi2 += bi[static_cast<size_t>(i) * n + a] * rhs[a];
                gain += hr * hr + hi2 * hi2;
            }
        }
        int count = 0;
        for (int i = 0; i < F; ++i) {
            const double f = w[i] / (2.0 * kPi);
            if (f >= 100.0 && f <= 8000.0) ++count;
        }
        const double scale = 1.0 / std::sqrt(gain / (2.0 * count));
        for (int k = 0; k < K; ++k) {
            fit.c[board][0].push_back(sol[0][2 * k] * scale);
            fit.c[board][1].push_back(sol[0][2 * k + 1] * scale);
            fit.c[board][2].push_back(sol[1][2 * k] * scale);
            fit.c[board][3].push_back(sol[1][2 * k + 1] * scale);
        }
    }
    return fit;
}

void floats(std::ostringstream& o, const std::vector<double>& v) {
    char buf[40];
    for (size_t i = 0; i < v.size(); ++i) {
        std::snprintf(buf, sizeof buf, "%.7g", v[i]);
        const bool plain = std::strpbrk(buf, ".eEn") == nullptr;  // "40" needs a point to take the f suffix
        o << buf << (plain ? ".0f" : "f") << (i + 1 < v.size() ? (i % 8 == 7 ? ",\n    " : ", ") : "");
    }
}

std::string generate() {
    std::ostringstream o;
    o << "// Timber's Simulated piano tables, generated by engine/tools/timber_piano_gen.cpp (do not edit; CI regenerates and compares).\n";
    o << "// Hammer force pulses (Chaigne-Askenfelt finite-difference strikes) per key zone and hammer speed, and the soundboards'\n";
    o << "// parallel second-order sections (Bank's fixed-pole fit) at three sizes.\n";
    o << "// clang-format off\n";
    std::vector<double> peaks, contact;
    std::vector<std::vector<double>> pulses;
    for (int z = 0; z < pc::kZones; ++z)
        for (int l = 0; l < pc::kLayers; ++l) {
            const Strike s = strike(pc::zoneKey(z), pc::kLayerSpeed[l]);
            peaks.push_back(s.peak);
            contact.push_back(s.contactMs);
            pulses.push_back(s.force);
        }
    o << "inline constexpr float kHammerPeak[" << pc::kZones * pc::kLayers << "] = {\n    ";
    floats(o, peaks);
    o << "};\n";
    o << "inline constexpr float kHammerContactMs[" << pc::kZones * pc::kLayers << "] = {\n    ";
    floats(o, contact);
    o << "};\n";
    o << "inline constexpr int16_t kHammerPulse[" << pc::kZones * pc::kLayers << "][" << pc::kPulseFrames << "] = {\n";
    for (size_t k = 0; k < pulses.size(); ++k) {
        o << "    {";
        for (int i = 0; i < pc::kPulseFrames; ++i) {
            const double v = peaks[k] > 0 ? pulses[k][i] / peaks[k] : 0.0;
            o << static_cast<int>(std::lround(v * 32767.0)) << (i + 1 < pc::kPulseFrames ? "," : "");
        }
        o << "},\n";
    }
    o << "};\n";
    static constexpr int kSizes[3] = {24, 48, 96};
    for (int s = 0; s < 3; ++s) {
        const Fit f = fitBoards(kSizes[s]);
        const int K = kSizes[s];
        o << "inline constexpr float kBoardHz" << K << "[" << K << "] = {\n    ";
        floats(o, f.hz);
        o << "};\n";
        o << "inline constexpr float kBoardSigma" << K << "[" << K << "] = {\n    ";
        floats(o, f.sigma);
        o << "};\n";
        o << "inline constexpr float kBoardC" << K << "[3][4][" << K << "] = {\n";
        for (int b = 0; b < 3; ++b) {
            o << "  {\n";
            for (int c = 0; c < 4; ++c) {
                o << "    {";
                floats(o, f.c[b][c]);
                o << "},\n";
            }
            o << "  },\n";
        }
        o << "};\n";
    }
    o << "// clang-format on\n";
    return o.str();
}

// The numbers of a generated file, in order (integers and floats alike).
struct Number {
    double value;
    bool integer;
};
std::vector<Number> numbers(const std::string& text) {
    std::vector<Number> v;
    std::istringstream lines(text);
    std::string line;
    while (std::getline(lines, line)) {
        if (line.rfind("//", 0) == 0) continue;
        const char* p = line.c_str();
        while (*p) {
            const bool sign = (*p == '-' && (p[1] >= '0' && p[1] <= '9'));
            if ((*p >= '0' && *p <= '9') || sign) {
                // Skip digits that are part of a name (kBoardHz24).
                if (p > line.c_str() && ((p[-1] >= 'A' && p[-1] <= 'Z') || (p[-1] >= 'a' && p[-1] <= 'z') || p[-1] == '_')) {
                    while ((*p >= '0' && *p <= '9')) ++p;
                    continue;
                }
                char* end = nullptr;
                const double x = std::strtod(p, &end);
                bool integer = true;
                for (const char* q = p; q < end; ++q) integer = integer && *q != '.' && *q != 'e' && *q != 'E';
                v.push_back({x, integer});
                p = end;
            } else {
                ++p;
            }
        }
    }
    return v;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 3 || (std::strcmp(argv[1], "--write") != 0 && std::strcmp(argv[1], "--check") != 0)) {
        std::fprintf(stderr, "usage: timber_piano_gen --write|--check <timber_piano_tables.inc>\n");
        return 2;
    }
    const std::string text = generate();
    if (std::strcmp(argv[1], "--write") == 0) {
        std::ofstream out(argv[2], std::ios::binary);
        out << text;
        return out ? 0 : 1;
    }
    std::ifstream in(argv[2], std::ios::binary);
    std::stringstream ss;
    ss << in.rdbuf();
    const std::vector<Number> want = numbers(ss.str()), got = numbers(text);
    if (want.size() != got.size()) {
        std::fprintf(stderr, "%s holds %zu numbers, the generator makes %zu: regenerate it (--write)\n", argv[2], want.size(), got.size());
        return 1;
    }
    // Another compiler's or library's last bits may move a 16-bit sample by one step or a float in its 7th digit.
    size_t bad = 0;
    for (size_t i = 0; i < want.size(); ++i) {
        const double d = std::fabs(want[i].value - got[i].value);
        const bool off = want[i].integer ? d > 1.0 : d > 2e-5 * std::fabs(want[i].value) + 1e-12;
        if (off) {
            if (bad < 5) std::fprintf(stderr, "number %zu: the file has %.9g, the generator %.9g\n", i, want[i].value, got[i].value);
            ++bad;
        }
    }
    if (bad) {
        std::fprintf(stderr, "%zu numbers differ: %s is out of date (timber_piano_gen --write)\n", bad, argv[2]);
        return 1;
    }
    std::printf("%s matches the generator (%zu numbers)\n", argv[2], want.size());
    return 0;
}
