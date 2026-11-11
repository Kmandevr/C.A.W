// C.A.W. Library: a modal resonator bank (membranes, plates, bars, tubes, bells, cymbals) for struck and excited sounds.
#pragma once

#include <cmath>
#include <cstdint>

#include "../detmath.hpp"
#include "fastmath.hpp"

namespace caw::lib {

// A struck object rings as a sum of decaying sines, its modes, each at its own frequency, decay and loudness: modal
// synthesis. Each mode here is one complex one-pole, z <- p z + a x with p = r e^(i w): an impulse sets it ringing as
// a sine at w that falls by r a sample (its output is Im z, so a mode starts at zero and never clicks). That is four
// multiplies and three adds a mode a sample, and no trig while it plays.
//
// The models set the modes' frequency ratios and how much each one sounds for a strike at `position`
// (0 the centre .. 1 the edge). Original code; the ratios come from textbook vibration physics, worked out for this
// file (docs/engine.md, "Drums", has the sources):
// - Membrane (a drum head clamped at its rim): mode (m, n) sits at j(m, n) / j(0, 1), the zeros of the Bessel function
//   J_m; a strike at radius r excites it by |J_m(j(m, n) r)|, so the centre plays only the round modes (m = 0).
// - Plate (a rectangular plate, 1 : 1.3, simply supported): (m^2 + n^2 / 1.69) over its lowest; strike weight
//   |sin(m pi x) sin(n pi y)|.
// - Bar (a free bar: a marimba key, a clave, a woodblock): (beta_k / beta_1)^2, beta 4.730, 7.853, 10.996, ...
// - Tube (a pipe closed at one end: a slit drum, a tube bell's body): the odd harmonics 1, 3, 5, ...
// - Bell: the partials of a tuned church bell (hum 0.5, prime 1, tierce 1.2, quint 1.5, nominal 2, ...).
//   [Assumption] typical values, not measured here.
// - Cymbal: a dense inharmonic spread (made up here, not measured), so a long decay shimmers.
enum class ModalModel : int { Membrane, Plate, Bar, Tube, Bell, Cymbal };
inline constexpr int kModalModelCount = 6;
inline constexpr int kMaxModes = 32;

struct ModalSettings {
    ModalModel model = ModalModel::Membrane;
    double frequency = 200.0;     // the lowest mode, Hz
    double decay = 0.5;           // seconds the lowest mode takes to fall 60 dB
    double damping = 0.3;         // 0..1: higher modes die sooner (0 all as long as the lowest)
    double brightness = 0.5;      // 0..1: tilts the modes' loudness toward the low (0) or the high (1) ones
    double inharmonicity = 0.0;   // -1..1: stretches (+) or squeezes (-) the ratios, ratio^(1 + inharmonicity / 2)
    double position = 0.3;        // 0 centre .. 1 edge
    int modes = 16;               // how many modes to run, 1..kMaxModes (quality)
};

namespace modal_detail {

// The membrane's modes: j(m, n) / j(0, 1) and m, ascending (computed from the Bessel series by bisection).
constexpr double kMembraneRatio[kMaxModes] = {
    1.0000, 1.5933, 2.1355, 2.2954, 2.6531, 2.9173, 3.1555, 3.5001, 3.5985, 3.6475, 4.0589,
    4.1317, 4.2304, 4.6010, 4.6101, 4.8319, 4.9033, 5.0836, 5.1308, 5.4121, 5.5404, 5.5531,
    5.6508, 5.9765, 6.0194, 6.1526, 6.1631, 6.2087, 6.4827, 6.5286, 6.6690, 6.7462};
constexpr double kMembraneZero[kMaxModes] = {
    2.4048, 3.8317, 5.1356, 5.5201, 6.3802, 7.0156, 7.5883, 8.4172, 8.6537, 8.7715, 9.7610,
    9.9361, 10.1735, 11.0647, 11.0864, 11.6198, 11.7915, 12.2251, 12.3386, 13.0152, 13.3237, 13.3543,
    13.5893, 14.3725, 14.4755, 14.7960, 14.8213, 14.9309, 15.5898, 15.7002, 16.0378, 16.2235};
constexpr int kMembraneOrder[kMaxModes] = {0, 1, 2, 0, 3, 1, 4, 2, 0, 5, 3, 6, 1, 4, 7, 2,
                                           0, 8, 5, 3, 1, 9, 6, 4, 10, 2, 7, 0, 11, 5, 8, 3};
constexpr double kPlateRatio[kMaxModes] = {
    1.0000, 2.1152, 2.8848, 3.9740, 4.0000, 5.8587, 6.0260, 6.5762, 7.1413, 8.4610, 9.0000,
    9.9219, 10.4238, 11.5390, 11.6022, 11.8067, 13.3978, 14.0112, 14.9480, 15.8959, 16.0000, 16.0781,
    17.1933, 18.8439, 19.0372, 19.0520, 19.3457, 20.7286, 21.6543, 22.9888, 23.4349, 23.8699};
constexpr int kPlateM[kMaxModes] = {1, 1, 2, 1, 2, 2, 3, 1, 3, 2, 3, 1, 4, 4, 3, 2, 4, 1, 3, 2, 4, 5, 5, 1, 3, 5, 4, 2, 5, 6, 4, 3};
constexpr int kPlateN[kMaxModes] = {1, 2, 1, 3, 2, 3, 1, 4, 2, 4, 3, 5, 1, 2, 4, 5, 3, 6, 5, 6, 4, 1, 2, 7, 6, 3, 5, 7, 4, 1, 6, 7};
constexpr double kBarRatio[kMaxModes] = {
    1.000, 2.757, 5.404, 8.933, 13.344, 18.638, 24.814, 31.872, 39.812, 48.635, 58.340,
    68.927, 80.397, 92.748, 105.982, 120.099, 135.097, 150.978, 167.741, 185.386, 203.914, 223.324,
    243.616, 264.790, 286.847, 309.786, 333.607, 358.311, 383.896, 410.365, 437.715, 465.947};
constexpr double kBellRatio[12] = {0.5, 1.0, 1.183, 1.506, 2.0, 2.514, 2.662, 3.011, 4.166, 5.433, 6.796, 8.215};
constexpr double kBellWeight[12] = {0.6, 1.0, 0.8, 0.45, 0.9, 0.35, 0.3, 0.4, 0.25, 0.2, 0.12, 0.08};

// J_m(x) by its power series (exact basic operations, so the same bits everywhere; |x| <= 17 here).
inline double besselJ(int m, double x) noexcept {
    double t = 1.0;
    for (int k = 1; k <= m; ++k) t *= x * 0.5 / k;
    double sum = 0.0;
    const double q = x * x * 0.25;
    for (int k = 0; k < 60; ++k) {
        sum += t;
        t *= -q / ((k + 1.0) * (k + 1.0 + m));
    }
    return sum;
}
inline double absd(double v) noexcept { return v < 0.0 ? -v : v; }
inline double clamp(double v, double lo, double hi) noexcept {
    v = finiteOr0(v);
    return v < lo ? lo : (v > hi ? hi : v);
}

}  // namespace modal_detail

// The bank. set() works out every mode (a sine, a cosine and two exps each: call it at a strike and when the
// pitch moves, not every sample), process() rings them. Allocation-free; clear() silences it.
class ModalBank {
public:
    // The ratio and strike weight of mode k of `model` (exposed for tests and displays).
    static void mode(ModalModel model, int k, double position, double& ratio, double& weight) noexcept {
        using namespace modal_detail;
        const double pos = clamp(position, 0.0, 1.0);
        switch (model) {
            case ModalModel::Membrane:
                ratio = kMembraneRatio[k];
                weight = absd(besselJ(kMembraneOrder[k], kMembraneZero[k] * (0.02 + 0.9 * pos)));
                break;
            case ModalModel::Plate: {
                ratio = kPlateRatio[k];
                const double x = 0.5 - 0.42 * pos, y = 0.5 - 0.28 * pos;
                weight = absd(detSin(kPi * kPlateM[k] * x) * detSin(kPi * kPlateN[k] * y));
                break;
            }
            case ModalModel::Bar:
                ratio = kBarRatio[k];
                weight = 0.25 + 0.75 * absd(detSin((k + 1) * kPi * (0.08 + 0.42 * (1.0 - pos))));
                break;
            case ModalModel::Tube:
                ratio = 2.0 * k + 1.0;
                weight = (0.2 + 0.8 * absd(detSin((2 * k + 1) * kPi * 0.5 * (0.1 + 0.9 * pos)))) / (k + 1.0);
                break;
            case ModalModel::Bell:
                if (k < 12) {
                    ratio = kBellRatio[k];
                    weight = kBellWeight[k] * (k >= 4 ? 0.6 + 0.8 * pos : 1.0);
                } else {
                    ratio = kBellRatio[11] * (1.0 + 0.19 * (k - 11));
                    weight = 0.06 / (k - 10);
                }
                break;
            case ModalModel::Cymbal:
            default: {
                const double kk = static_cast<double>(k);
                ratio = 1.0 + 0.61 * kk + 0.047 * kk * kk + 0.09 * detSin(2.3 * kk);
                weight = 0.55 + 0.45 * absd(detSin(1.7 * kk + 3.0 * pos));
                break;
            }
        }
    }

    void set(const ModalSettings& s, double sampleRate) noexcept {
        using namespace modal_detail;
        const int model = static_cast<int>(s.model);
        const ModalModel m = model >= 0 && model < kModalModelCount ? s.model : ModalModel::Membrane;
        int n = s.modes < 1 ? 1 : (s.modes > kMaxModes ? kMaxModes : s.modes);
        const double f0 = clamp(s.frequency, 10.0, 20000.0);
        const double decay = clamp(s.decay, 0.005, 60.0);
        const double damp = clamp(s.damping, 0.0, 1.0);
        const double tilt = (clamp(s.brightness, 0.0, 1.0) - 0.5) * 3.0;
        const double stretch = 1.0 + 0.5 * clamp(s.inharmonicity, -1.0, 1.0);
        const double top = 0.45 * sampleRate;
        double sum = 0.0;
        count_ = 0;
        for (int k = 0; k < n; ++k) {
            double ratio = 1.0, weight = 1.0;
            mode(m, k, s.position, ratio, weight);
            const double r = detPow(ratio, stretch);
            const double hz = f0 * r;
            if (hz >= top) {
                amp_[k] = 0.0;
                c_[k] = s_[k] = 0.0;
                continue;
            }
            const double t60 = decay * detPow(r < 1.0 ? 1.0 : r, -2.0 * damp);
            const double radius = fastExp(-6.907755278982137 / (t60 * sampleRate));
            const double w = kTwoPi * hz / sampleRate;
            c_[k] = radius * detCos(w);
            s_[k] = radius * detSin(w);
            amp_[k] = weight * detPow(r, tilt * 0.5);
            drive_[k] = 4.0 * (1.0 - radius);  // times amp_ below
            sum += amp_[k] * amp_[k];
            count_ = k + 1;
        }
        const double norm = sum > 0.0 ? 1.0 / std::sqrt(sum) : 0.0;
        for (int k = 0; k < count_; ++k) {
            amp_[k] *= norm;
            drive_[k] *= amp_[k];
        }
        for (int k = count_; k < kMaxModes; ++k) zr_[k] = zi_[k] = 0.0;
    }

    // One sample: `strike` excites every mode as a blow does (a unit impulse sets mode k ringing at its loudness,
    // whatever its decay), `drive` as a sound played into it does (scaled by 1 - r, so a steady sine on a mode's
    // frequency rings it at about 4 times its loudness, however long it rings: sympathetic resonance that can't
    // run away). Returns the modes' sum.
    double process(double strike, double drive = 0.0) noexcept {
        const double in = finiteOr0(strike), d = finiteOr0(drive);
        double y = 0.0;
        for (int k = 0; k < count_; ++k) {
            const double zr = c_[k] * zr_[k] - s_[k] * zi_[k] + amp_[k] * in + drive_[k] * d;
            const double zi = s_[k] * zr_[k] + c_[k] * zi_[k];
            zr_[k] = zr;
            zi_[k] = zi;
            y += zi;
        }
        return y;
    }

    // Whether any mode still rings above about -110 dB; a silent bank is flushed to exact zeros (no subnormals).
    bool ringing() noexcept {
        double e = 0.0;
        for (int k = 0; k < count_; ++k) e += zr_[k] * zr_[k] + zi_[k] * zi_[k];
        if (e > 1e-11) return true;
        clear();
        return false;
    }
    int modes() const noexcept { return count_; }
    void clear() noexcept {
        for (int k = 0; k < kMaxModes; ++k) zr_[k] = zi_[k] = 0.0;
    }

private:
    double c_[kMaxModes] = {}, s_[kMaxModes] = {}, amp_[kMaxModes] = {}, drive_[kMaxModes] = {};
    double zr_[kMaxModes] = {}, zi_[kMaxModes] = {};
    int count_ = 0;
};

}  // namespace caw::lib
