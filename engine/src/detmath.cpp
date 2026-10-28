// Deterministic sin, exp, log and pow built from IEEE basic operations only (no platform maths library).
#include "detmath.h"

namespace caw {

namespace {

// sin(r) for |r| <= pi/2 by its Taylor series to r^19 (error below 1e-15).
double sinPoly(double r) {
    const double r2 = r * r;
    double p = -1.0 / 121645100408832000.0;  // -1/19!
    p = p * r2 + 1.0 / 355687428096000.0;     // 1/17!
    p = p * r2 - 1.0 / 1307674368000.0;       // -1/15!
    p = p * r2 + 1.0 / 6227020800.0;          // 1/13!
    p = p * r2 - 1.0 / 39916800.0;            // -1/11!
    p = p * r2 + 1.0 / 362880.0;              // 1/9!
    p = p * r2 - 1.0 / 5040.0;                // -1/7!
    p = p * r2 + 1.0 / 120.0;                 // 1/5!
    p = p * r2 - 1.0 / 6.0;                   // -1/3!
    return r + r * r2 * p;
}

constexpr double kTwoPiHi = 6.28318530717958623200;  // 2*pi split for exact range reduction
constexpr double kTwoPiLo = 2.44929359829470635e-16;
constexpr double kLn2Hi = 6.93147180369123816490e-01;
constexpr double kLn2Lo = 1.90821492927058770002e-10;
constexpr double kLn2 = 0.69314718055994530942;
constexpr double kHalfPi = 1.57079632679489661923;

}  // namespace

double detSin(double x) {
    if (!std::isfinite(x)) return 0.0;
    const double k = std::floor(x / kTwoPi + 0.5);
    double r = (x - k * kTwoPiHi) - k * kTwoPiLo;  // now in [-pi, pi]
    if (r > kHalfPi) r = kPi - r;
    else if (r < -kHalfPi) r = -kPi - r;
    return sinPoly(r);
}

double detCos(double x) { return detSin(x + kHalfPi); }

double detTan(double x) {
    const double c = detCos(x);
    return c == 0.0 ? 0.0 : detSin(x) / c;
}

double detExp(double x) {
    if (std::isnan(x)) return 0.0;
    if (x > 709.0) x = 709.0;
    if (x < -745.0) return 0.0;
    const double k = std::floor(x / kLn2 + 0.5);
    const double r = (x - k * kLn2Hi) - k * kLn2Lo;  // |r| <= 0.35
    double p = 1.0 / 6227020800.0;                    // 1/13!
    p = p * r + 1.0 / 479001600.0;
    p = p * r + 1.0 / 39916800.0;
    p = p * r + 1.0 / 3628800.0;
    p = p * r + 1.0 / 362880.0;
    p = p * r + 1.0 / 40320.0;
    p = p * r + 1.0 / 5040.0;
    p = p * r + 1.0 / 720.0;
    p = p * r + 1.0 / 120.0;
    p = p * r + 1.0 / 24.0;
    p = p * r + 1.0 / 6.0;
    p = p * r + 0.5;
    p = p * r + 1.0;
    p = p * r + 1.0;
    return std::ldexp(p, static_cast<int>(k));
}

// log(x) for x > 0; 0 for x <= 0 (the language's NaN-free rule).
double detLog(double x) {
    if (!(x > 0.0) || !std::isfinite(x)) return 0.0;
    int e = 0;
    double m = std::frexp(x, &e);  // m in [0.5, 1)
    if (m < 0.70710678118654752440) {
        m *= 2.0;
        e -= 1;
    }
    const double s = (m - 1.0) / (m + 1.0);  // |s| <= 0.172
    const double s2 = s * s;
    double p = 1.0 / 23.0;
    for (int d = 21; d >= 3; d -= 2) p = p * s2 + 1.0 / d;
    p = p * s2 + 1.0;
    return static_cast<double>(e) * kLn2 + 2.0 * s * p;
}

double detPow(double x, double y) {
    if (std::isnan(x) || std::isnan(y)) return 0.0;
    if (y == 0.0) return 1.0;
    if (y == std::trunc(y) && std::fabs(y) <= 1024.0) {
        // Exact square-and-multiply for whole exponents.
        long n = static_cast<long>(std::fabs(y));
        double base = x, acc = 1.0;
        while (n > 0) {
            if (n & 1) acc *= base;
            base *= base;
            n >>= 1;
        }
        if (y < 0.0) return acc == 0.0 ? 0.0 : 1.0 / acc;
        return acc;
    }
    if (x <= 0.0) return 0.0;
    return detExp(y * detLog(x));
}

double detTanh(double x) {
    if (std::isnan(x)) return 0.0;
    if (x > 20.0) return 1.0;
    if (x < -20.0) return -1.0;
    const double e = detExp(2.0 * x);
    return (e - 1.0) / (e + 1.0);
}

}  // namespace caw
