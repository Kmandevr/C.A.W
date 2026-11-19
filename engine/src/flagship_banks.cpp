// Flagship's (Raven's) spectral and additive warp banks: the resynthesis, the shared cache and its builder thread.
#include "flagship_banks.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <utility>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/convolver.hpp"

// Original code (C.A.W. is Apache-2.0). The idea of warping a wavetable's spectrum and morphing between precomputed
// versions is general synthesis knowledge (spectral warps are offered by several wavetable synths); no other synth's
// code, tables or presets were used (docs/decisions.md).
//
// Why banks: resynthesising a table per voice as its warp amount moves would cost an FFT a control period per
// copy. Instead each (table, mode) pair is resynthesised once, at 8 amounts, into an ordinary mipmapped
// lib::Wavetable; an oscillator then reads it as it reads any table, morphing between the two nearest amounts
// (and frames). The memory: 8 x frames (at most 16) x about 21.5 KB, so 0.7 MB for a 4-frame table and 2.75 MB for
// a 16-frame one, shared by every instance that plays the same table and mode, and freed 10 s after the last one
// lets go.

namespace caw::flagship {

namespace {

constexpr int kH = 512;  // the harmonics a 1024-sample frame holds

// One frame's harmonics as sine and cosine amounts, h = 1..512 at [h].
struct Spectrum {
    double s[kH + 1] = {}, c[kH + 1] = {};
};

// sinAmt sin(x) + cosAmt cos(x) = m sin(x + p), with s = m cos p and c = m sin p.
void splitInto(Spectrum& out, double at, double s, double c) noexcept {
    if (!(at >= 1.0)) return;
    const int lo = static_cast<int>(at);
    const double w = at - lo;
    if (lo <= kH) out.s[lo] += (1.0 - w) * s, out.c[lo] += (1.0 - w) * c;
    if (lo + 1 <= kH && w > 0.0) out.s[lo + 1] += w * s, out.c[lo + 1] += w * c;
}

double hashUnit(uint32_t x) noexcept {
    x ^= x >> 16;
    x *= 0x7FEB352Du;
    x ^= x >> 15;
    x *= 0x846CA68Bu;
    x ^= x >> 16;
    return static_cast<double>(x) / 4294967296.0;
}

// The warp `mode` at amount u (0..1) of spectrum `in`, into `out`; 0 is `in` itself.
void warpSpectrum(const Spectrum& in, int mode, double u, Spectrum& out) {
    out = Spectrum{};
    if (u <= 0.0) {
        out = in;
        return;
    }
    switch (mode) {
        case kStretch: {  // the partials' spacing widened up to 3x (each between the two nearest harmonics)
            const double k = 1.0 + 2.0 * u;
            for (int h = 1; h <= kH; ++h) splitInto(out, 1.0 + (h - 1) * k, in.s[h], in.c[h]);
            break;
        }
        case kShift:  // every partial moved up by up to 8 harmonics
            for (int h = 1; h <= kH; ++h) splitInto(out, h + 8.0 * u, in.s[h], in.c[h]);
            break;
        case kOddEven: {  // to 0.5 the even harmonics fade out (hollow), from there the odd ones (the fundamental stays)
            const double even = 1.0 - std::min(1.0, 2.0 * u), odd = 1.0 - std::max(0.0, 2.0 * u - 1.0);
            for (int h = 1; h <= kH; ++h) {
                const double g = h == 1 ? 1.0 : (h % 2 ? odd : even);
                out.s[h] = in.s[h] * g, out.c[h] = in.c[h] * g;
            }
            break;
        }
        case kFormant: {  // the spectral envelope moved up by up to 1.5 octaves, the harmonics staying where they are
            const double f = detExp(1.5 * u * 0.69314718055994530942);
            for (int h = 1; h <= kH; ++h) {
                const double x = h / f;
                double m;
                if (x <= 1.0) {
                    m = std::hypot(in.s[1], in.c[1]);
                } else {
                    const int lo = static_cast<int>(x);
                    const double w = x - lo;
                    const double a = std::hypot(in.s[lo], in.c[lo]), b = lo + 1 <= kH ? std::hypot(in.s[lo + 1], in.c[lo + 1]) : 0.0;
                    m = a + (b - a) * w;
                }
                const double own = std::hypot(in.s[h], in.c[h]);
                const double p = own > 0.0 ? std::atan2(in.c[h], in.s[h]) : 0.0;
                out.s[h] = m * std::cos(p), out.c[h] = m * std::sin(p);
            }
            break;
        }
        case kSmear: {  // the magnitudes blurred over up to 16 harmonics, the phases scattered as far
            const int w = 1 + static_cast<int>(15.0 * u);
            for (int h = 1; h <= kH; ++h) {
                double sum = 0.0, weights = 0.0;
                for (int d = -w; d <= w; ++d) {
                    const int k = h + d;
                    if (k < 1 || k > kH) continue;
                    const double t = 1.0 - std::abs(d) / (w + 1.0);
                    sum += t * std::hypot(in.s[k], in.c[k]);
                    weights += t;
                }
                const double m = sum / weights;
                const double p = std::atan2(in.c[h], in.s[h]) + u * kTwoPi * hashUnit(static_cast<uint32_t>(h) * 2654435761u);
                out.s[h] = m * std::cos(p), out.c[h] = m * std::sin(p);
            }
            break;
        }
        case kDisperse:  // a phase that grows with the square of the harmonic: the wave's partials drift apart in time
            for (int h = 1; h <= kH; ++h) {
                const double m = std::hypot(in.s[h], in.c[h]);
                const double p = std::atan2(in.c[h], in.s[h]) + u * kPi * h * h / 64.0;
                out.s[h] = m * std::cos(p), out.c[h] = m * std::sin(p);
            }
            break;
        case kCut: {  // a low cut rising to harmonic 16 and a high cut falling from 512 to 16, 12 dB an octave each
            const double lo = detExp(4.0 * u * 0.69314718055994530942), hi = kH * detExp(-5.0 * u * 0.69314718055994530942);
            for (int h = 1; h <= kH; ++h) {
                double g = 1.0;
                if (h < lo) g *= (h / lo) * (h / lo);
                if (h > hi) g *= (hi / h) * (hi / h);
                out.s[h] = in.s[h] * g, out.c[h] = in.c[h] * g;
            }
            break;
        }
        case kComb: {  // notches every P harmonics, P narrowing from 8 to 2 (deep from amount 0.25)
            const double depth = std::min(1.0, 4.0 * u), period = 8.0 - 6.0 * u;
            for (int h = 1; h <= kH; ++h) {
                const double g = 1.0 - depth * 0.5 * (1.0 - std::cos(kTwoPi * (h - 1) / period));
                out.s[h] = in.s[h] * g, out.c[h] = in.c[h] * g;
            }
            break;
        }
        default: out = in; break;
    }
}

double rmsOf(const Spectrum& x) noexcept {
    double sum = 0.0;
    for (int h = 1; h <= kH; ++h) sum += x.s[h] * x.s[h] + x.c[h] * x.c[h];
    return std::sqrt(0.5 * sum);
}

// ---------- The shared cache ----------

constexpr int kSlots = 32;
constexpr int kIdleTicks = 200;  // about 10 s of the worker's 50 ms waits
enum SlotState : int { kEmpty, kRequested, kBuilding, kReady, kFailed };

struct Slot {
    std::atomic<uint64_t> key{0};
    std::atomic<int> state{kEmpty};
    std::atomic<Bank*> bank{nullptr};
    std::atomic<int> users{0};
    int idle = 0;  // the worker's
};

struct Cache {
    Slot slots[kSlots];
    std::mutex lock;  // the sources and the worker's wait (never the audio thread's)
    std::condition_variable wake;
    std::vector<std::pair<SourceId, std::weak_ptr<const lib::Wavetable>>> sources;
    const lib::Wavetable* builtin[16] = {};
    SourceId next = 100;
    std::thread worker;
    bool stop = false, started = false;
    std::atomic<int> built{0}, ever{0};

    ~Cache() {
        {
            std::lock_guard<std::mutex> hold(lock);
            stop = true;
        }
        wake.notify_all();
        if (worker.joinable()) worker.join();
        for (Slot& s : slots) delete s.bank.load();
    }

    // The source's table, kept alive while it is built from (a built-in one: never freed).
    std::shared_ptr<const lib::Wavetable> source(SourceId id) {
        if (id >= 1 && id <= 16) {
            const lib::Wavetable* t = builtin[id - 1];
            return t ? std::shared_ptr<const lib::Wavetable>(t, [](const lib::Wavetable*) {}) : nullptr;
        }
        std::lock_guard<std::mutex> hold(lock);
        for (auto it = sources.begin(); it != sources.end();) {
            if (it->second.expired()) {
                it = sources.erase(it);
                continue;
            }
            if (it->first == id) return it->second.lock();
            ++it;
        }
        return nullptr;
    }

    // Builds the slot's bank on this thread (it holds kBuilding): ready or failed.
    void build(Slot& s) {
        const uint64_t key = s.key.load();
        Bank* made = nullptr;
        try {
            if (auto src = source(static_cast<SourceId>(key >> 8))) made = buildBankNow(*src, static_cast<int>(key & 0xFF) - 1).release();
        } catch (...) {
            made = nullptr;
        }
        if (made) {
            s.bank.store(made);
            built.fetch_add(1);
            ever.fetch_add(1);
            s.state.store(kReady);
        } else {
            s.state.store(kFailed);
        }
        s.idle = 0;
    }

    void run() {
        std::unique_lock<std::mutex> hold(lock);
        while (!stop) {
            wake.wait_for(hold, std::chrono::milliseconds(50));
            if (stop) break;
            hold.unlock();
            for (Slot& s : slots) {
                int want = kRequested;
                if (s.state.load() == kRequested && s.state.compare_exchange_strong(want, kBuilding)) build(s);
            }
            for (Slot& s : slots) {  // free what nobody held for a while
                const int state = s.state.load();
                if ((state != kReady && state != kFailed) || s.users.load() != 0) {
                    s.idle = 0;
                    continue;
                }
                if (++s.idle < kIdleTicks) continue;
                Bank* b = s.bank.exchange(nullptr);
                if (s.users.load() != 0) {  // taken meanwhile (a user adds itself, then reads the bank)
                    s.bank.store(b);
                    s.idle = 0;
                    continue;
                }
                if (b) built.fetch_sub(1);
                delete b;
                s.state.store(kEmpty);
                s.key.store(0);
                s.idle = 0;
            }
            hold.lock();
        }
    }
};

Cache& cache() {
    static Cache c;
    return c;
}

}  // namespace

std::unique_ptr<Bank> buildBankNow(const lib::Wavetable& source, int mode) {
    auto bank = std::make_unique<Bank>();
    const int size = source.frameSize();
    if (size != 2 * kH || mode < 0 || mode >= kSpectralModes) return nullptr;
    const int frames = source.frameCount(), count = std::min(frames, kBankMaxFrames);
    std::vector<Spectrum> spectra(static_cast<size_t>(frames));
    std::vector<double> re(static_cast<size_t>(size)), im(static_cast<size_t>(size));
    lib::Fft fft;
    fft.prepare(static_cast<uint32_t>(size));
    for (int f = 0; f < frames; ++f) {  // level 0 holds every harmonic exactly: its FFT gives them back
        const float* x = source.levelData(f, 0);
        for (int i = 0; i < size; ++i) re[i] = x[i], im[i] = 0.0;
        fft.forward(re.data(), im.data());
        for (int h = 1; h <= kH; ++h) {
            spectra[f].s[h] = -2.0 * im[h] / size;
            spectra[f].c[h] = (h == kH ? 1.0 : 2.0) * re[h] / size;
        }
    }
    bank->frames = count;
    bank->table.prepare(count * kBankLevels, size);
    double sinAmt[kH], cosAmt[kH];
    Spectrum at, warped;
    for (int j = 0; j < count; ++j) {
        const double pos = count > 1 ? static_cast<double>(j) * (frames - 1) / (count - 1) : 0.0;
        const int f0 = static_cast<int>(pos), f1 = f0 + 1 < frames ? f0 + 1 : f0;
        const double w = pos - f0;
        for (int h = 1; h <= kH; ++h) {
            at.s[h] = spectra[f0].s[h] + (spectra[f1].s[h] - spectra[f0].s[h]) * w;
            at.c[h] = spectra[f0].c[h] + (spectra[f1].c[h] - spectra[f0].c[h]) * w;
        }
        const double rms = rmsOf(at);
        for (int l = 0; l < kBankLevels; ++l) {
            warpSpectrum(at, mode, static_cast<double>(l) / (kBankLevels - 1), warped);
            const double now = rmsOf(warped);
            const double scale = now > 1e-12 ? rms / now : 0.0;  // every amount at the frame's loudness
            for (int h = 1; h <= kH; ++h) sinAmt[h - 1] = warped.s[h] * scale, cosAmt[h - 1] = warped.c[h] * scale;
            bank->table.setFrameSinCos(l * count + j, sinAmt, cosAmt, kH);
        }
    }
    bank->table.setFrameCount(count * kBankLevels);
    return bank;
}

int cachedBanks() noexcept { return cache().built.load(); }
int banksBuilt() noexcept { return cache().ever.load(); }

SourceId builtinSource(int index, const lib::Wavetable* table) {
    Cache& c = cache();
    if (index < 0 || index >= 16) return 0;
    std::lock_guard<std::mutex> hold(c.lock);
    c.builtin[index] = table;
    return static_cast<SourceId>(index + 1);
}

SourceId registerSource(std::shared_ptr<const lib::Wavetable> table) {
    Cache& c = cache();
    std::lock_guard<std::mutex> hold(c.lock);
    for (const auto& [id, t] : c.sources)
        if (!t.expired() && t.lock() == table) return id;
    const SourceId id = c.next++;
    c.sources.emplace_back(id, table);
    return id;
}

void startBankWorker() {
    Cache& c = cache();
    std::lock_guard<std::mutex> hold(c.lock);
    if (c.started) return;
    c.started = true;
    try {
        c.worker = std::thread([&c] { c.run(); });
    } catch (...) {
        c.started = false;  // no thread: banks are built only offline
    }
}

BankUser::BankUser() noexcept = default;
BankUser::~BankUser() { releaseAll(); }

void BankUser::releaseAll() noexcept {
    Cache& c = cache();
    for (int i = 0; i < count_; ++i) c.slots[held_[i].slot].users.fetch_sub(1);
    count_ = 0;
}

const Bank* BankUser::find(SourceId source, int mode) noexcept {
    if (source == 0 || mode < 0 || mode >= kSpectralModes) return nullptr;
    const uint64_t key = (static_cast<uint64_t>(source) << 8) | static_cast<uint64_t>(mode + 1);
    for (int i = 0; i < count_; ++i)
        if (held_[i].key == key) {
            held_[i].unused = 0;
            return held_[i].bank;
        }
    if (count_ == kHeld) return nullptr;  // eight banks at once: the rest play unwarped
    Cache& c = cache();
    int at = -1;
    for (int i = 0; i < kSlots && at < 0; ++i)
        if (c.slots[i].key.load() == key) at = i;
    if (at < 0) {  // ask for it
        for (int i = 0; i < kSlots && at < 0; ++i) {
            uint64_t empty = 0;
            if (c.slots[i].key.load() == 0 && c.slots[i].key.compare_exchange_strong(empty, key)) {
                c.slots[i].state.store(kRequested);
                at = i;
            }
        }
        if (at < 0) return nullptr;  // the cache is full until the worker frees one
    }
    Slot& s = c.slots[at];
    if (offline_) {  // an offline render builds it now (this thread may allocate and wait)
        int want = kRequested;
        if (s.state.compare_exchange_strong(want, kBuilding)) {
            c.build(s);
        } else {
            for (int spins = 0; s.state.load() == kBuilding && spins < 200000; ++spins) std::this_thread::yield();
        }
    }
    if (s.state.load() != kReady) return nullptr;
    s.users.fetch_add(1);
    const Bank* b = s.bank.load();
    if (!b || s.key.load() != key) {  // freed or reused meanwhile
        s.users.fetch_sub(1);
        return nullptr;
    }
    held_[count_++] = {at, key, b, 0};
    return b;
}

void BankUser::mark(const Bank* bank) noexcept {
    if (!bank) return;
    for (int i = 0; i < count_; ++i)
        if (held_[i].bank == bank) held_[i].unused = 0;
}

void BankUser::idle() noexcept {
    Cache& c = cache();
    for (int i = 0; i < count_;) {
        if (++held_[i].unused < kIdleControls) {
            ++i;
            continue;
        }
        c.slots[held_[i].slot].users.fetch_sub(1);
        held_[i] = held_[--count_];
    }
}

}  // namespace caw::flagship
