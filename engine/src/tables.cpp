// Wavetable storage and band-limiting: our own FFT on deterministic sines, and the built-in shapes.
#include "tables.h"

#include <cmath>

#include "detmath.h"

namespace caw {

int Table::levelSize(int level) {
    const int n = 4096 >> level;  // 4 samples per kept harmonic
    return n > kTableSize ? kTableSize : (n < 64 ? 64 : n);
}

int Table::levelFor(double dt) {
    if (!(dt > 0.0)) return 0;
    // Harmonic h sounds at h * dt cycles per sample; keep every one below 0.5.
    const double maxHarm = 0.5 / dt;
    int level = 0;
    while (level < kTableLevels - 1 && static_cast<double>(1024 >> level) >= maxHarm) ++level;
    return level;
}

namespace {

// In-place radix-2 FFT over n = 2^k complex values; sign -1 forward, +1 inverse (unscaled). Twiddles come from
// detSin/detCos and the order of operations is fixed, so the result is the same on every platform.
void fft(std::vector<double>& re, std::vector<double>& im, int sign) {
    const size_t n = re.size();
    for (size_t i = 1, j = 0; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            std::swap(re[i], re[j]);
            std::swap(im[i], im[j]);
        }
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        const double ang = sign * kTwoPi / static_cast<double>(len);
        const size_t half = len / 2;
        for (size_t k = 0; k < half; ++k) {
            const double wr = detCos(ang * static_cast<double>(k)), wi = detSin(ang * static_cast<double>(k));
            for (size_t i = k; i < n; i += len) {
                const size_t j = i + half;
                const double xr = re[j] * wr - im[j] * wi, xi = re[j] * wi + im[j] * wr;
                re[j] = re[i] - xr;
                im[j] = im[i] - xi;
                re[i] += xr;
                im[i] += xi;
            }
        }
    }
}

// One cycle of a classic shape at phase p in 0..1 (before band-limiting).
double shape(int kind, double p, double width = 0.5) {
    switch (kind) {
        case 0: return detSin(kTwoPi * p);
        case 1: return p < 0.25 ? 4 * p : (p < 0.75 ? 2 - 4 * p : 4 * p - 4);  // triangle
        case 2: return 2 * p - 1;                                               // saw
        default: return p < width ? 1.0 : -1.0;                                 // square / pulse
    }
}

std::shared_ptr<const Table> shapeTable(int id) {
    std::vector<double> c;
    int frames = 1;
    auto add = [&](auto f) {
        for (int i = 0; i < kTableSize; ++i) c.push_back(f(static_cast<double>(i) / kTableSize));
    };
    switch (id) {
        case 0: add([](double p) { return shape(0, p); }); break;
        case 1: add([](double p) { return shape(1, p); }); break;
        case 2: add([](double p) { return shape(2, p); }); break;
        case 3: add([](double p) { return shape(3, p); }); break;
        case 4:  // basic: sine, triangle, saw, square, to morph through with pos
            frames = 4;
            for (int k = 0; k < 4; ++k) add([k](double p) { return shape(k, p); });
            break;
        default:  // pwm: a pulse narrowing from 50% to 5% over 32 frames
            frames = 32;
            for (int k = 0; k < frames; ++k) {
                const double w = 0.5 - 0.45 * k / (frames - 1);
                add([w](double p) { return shape(3, p, w); });
            }
            break;
    }
    return buildTable(c, frames);
}

const char* const kNames[] = {"sine", "tri", "saw", "square", "basic", "pwm"};
constexpr int kCount = sizeof(kNames) / sizeof(kNames[0]);

const std::vector<std::shared_ptr<const Table>>& builtins() {
    static const std::vector<std::shared_ptr<const Table>> all = [] {
        std::vector<std::shared_ptr<const Table>> v;
        for (int i = 0; i < kCount; ++i) v.push_back(shapeTable(i));
        return v;
    }();
    return all;
}

}  // namespace

std::shared_ptr<const Table> buildTable(const std::vector<double>& cycles, int frames) {
    if (frames < 1) frames = 1;
    if (frames > kTableMaxFrames) frames = kTableMaxFrames;
    auto t = std::make_shared<Table>();
    t->frames = frames;
    size_t total = 0;
    for (int l = 0; l < kTableLevels; ++l) {
        t->levelOffset[l] = total;
        total += static_cast<size_t>(frames) * static_cast<size_t>(Table::levelSize(l) + 1);
    }
    t->data.assign(total, 0.0f);
    std::vector<double> re(kTableSize), im(kTableSize), lre, lim;
    for (int f = 0; f < frames; ++f) {
        for (int i = 0; i < kTableSize; ++i) {
            const size_t at = static_cast<size_t>(f) * kTableSize + static_cast<size_t>(i);
            const double x = at < cycles.size() ? cycles[at] : 0.0;
            re[static_cast<size_t>(i)] = std::isfinite(x) ? x : 0.0;
            im[static_cast<size_t>(i)] = 0.0;
        }
        fft(re, im, -1);
        for (int l = 0; l < kTableLevels; ++l) {
            // Keep harmonics 1..1024 >> l (DC removed) and resynthesize at this level's size.
            const int n = Table::levelSize(l), keep = 1024 >> l;
            lre.assign(static_cast<size_t>(n), 0.0);
            lim.assign(static_cast<size_t>(n), 0.0);
            for (int h = 1; h <= keep && h < n / 2; ++h) {
                const double s = 1.0 / kTableSize;
                lre[static_cast<size_t>(h)] = re[static_cast<size_t>(h)] * s;
                lim[static_cast<size_t>(h)] = im[static_cast<size_t>(h)] * s;
                lre[static_cast<size_t>(n - h)] = re[static_cast<size_t>(kTableSize - h)] * s;
                lim[static_cast<size_t>(n - h)] = im[static_cast<size_t>(kTableSize - h)] * s;
            }
            fft(lre, lim, 1);
            float* out = t->data.data() + t->levelOffset[l] + static_cast<size_t>(f) * static_cast<size_t>(n + 1);
            for (int i = 0; i < n; ++i) out[i] = static_cast<float>(lre[static_cast<size_t>(i)]);
            out[n] = out[0];
        }
    }
    return t;
}

const Table* builtinTable(int id) {
    const auto& all = builtins();
    if (id < 0 || id >= static_cast<int>(all.size())) id = 0;
    return all[static_cast<size_t>(id)].get();
}

int builtinTableCount() { return kCount; }
const char* const* builtinTableNames() { return kNames; }
void warmTables() { (void)builtins(); }

}  // namespace caw
