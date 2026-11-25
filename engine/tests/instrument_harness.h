// The modelled instruments' test harness (Timber's model library: Starling, Nightingale, Curlew, Woodpecker, Bittern): makes an instrument, plays timed notes and controllers in blocks, and measures pitch, partials, decay and brightness.
#pragma once

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "caw/instrument.hpp"
#include "fx_merged.h"
#include "module_registry.h"
#include "quality.h"

namespace timber_test {

using namespace caw;
using Values = std::vector<std::pair<std::string, double>>;
constexpr double kPi = 3.14159265358979323846;

inline const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        return x;
    }();
    return r;
}

struct Stereo {
    std::vector<float> l, r;
    size_t size() const { return l.size(); }
    std::vector<float> mono() const {
        std::vector<float> m(l.size());
        for (size_t i = 0; i < l.size(); ++i) m[i] = 0.5f * (l[i] + r[i]);
        return m;
    }
};

// A note: on at `on` seconds, off at `off` (negative: held), MIDI pitch and velocity.
struct Note {
    double on, off, pitch, velocity;
};
// A controller: CC `cc` to `value` 0..1 at `at` seconds.
struct Cc {
    double at;
    int cc;
    double value;
};

inline Values withModel(int model, Values v) {
    v.emplace_back("variant", model);
    return v;
}

// Built-in instrument `id` with values `v`, at a quality tier (0 Eco, 1 Normal, 2 High), activated.
inline std::unique_ptr<ModuleProcessor> makeInstrument(const char* id, const Values& v, double sr = 48000,
                                                       int tier = kQualityNormal) {
    static std::atomic<int> tiers[3] = {kQualityEco, kQualityNormal, kQualityHigh};
    const BuildingQuality building(&tiers[tier]);
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), id, v);
    if (p && !p->activate(sr, 512)) p.reset();
    return p;
}

// Plays `notes` (and `ccs`) for `seconds` in blocks of `block` frames; `quietAt` gets the first block end at which
// the instrument said quiet() after every note was off (-1: never).
inline Stereo play(ModuleProcessor& p, const Values& v, const std::vector<Note>& notes, double seconds, double sr = 48000,
                   uint32_t block = 64, const std::vector<Cc>& ccs = {}, double* quietAt = nullptr) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [name, x] : v)
            if (d.parameters[k].id == name) params[k].value = x;
    }
    struct Timed {
        uint64_t frame;
        Event e;
    };
    std::vector<Timed> events;
    for (size_t k = 0; k < notes.size(); ++k) {
        const Note& n = notes[k];
        events.push_back({static_cast<uint64_t>(n.on * sr), notes::noteOn(0, static_cast<uint32_t>(k + 1), n.pitch, n.velocity)});
        if (n.off >= 0)
            events.push_back({static_cast<uint64_t>(n.off * sr), notes::noteOff(0, static_cast<uint32_t>(k + 1), notes::keyOf(n.pitch))});
    }
    for (const Cc& c : ccs) {
        Event e;
        e.kind = EventKind::Midi;
        e.data[0] = (0x2u << 28) | (0xBu << 20) | (static_cast<uint32_t>(c.cc) << 8) |
                    static_cast<uint32_t>(std::lround(std::clamp(c.value, 0.0, 1.0) * 127));
        events.push_back({static_cast<uint64_t>(c.at * sr), e});
    }
    std::stable_sort(events.begin(), events.end(), [](const Timed& a, const Timed& b) { return a.frame < b.frame; });
    const size_t total = static_cast<size_t>(seconds * sr);
    Stereo out;
    out.l.assign(total, 0.0f);
    out.r.assign(total, 0.0f);
    size_t next = 0;
    double lastOff = 0;
    for (const Note& n : notes) lastOff = std::max(lastOff, n.off < 0 ? 1e30 : n.off);
    if (quietAt) *quietAt = -1;
    std::vector<Event> blockEvents;
    for (size_t at = 0; at < total; at += block) {
        const uint32_t frames = static_cast<uint32_t>(std::min<size_t>(block, total - at));
        blockEvents.clear();
        while (next < events.size() && events[next].frame < at + frames) {
            Event e = events[next].e;
            e.frame = static_cast<uint32_t>(events[next].frame - at);
            blockEvents.push_back(e);
            ++next;
        }
        float* ch[2] = {out.l.data() + at, out.r.data() + at};
        const ChannelBufferView audio{ch, 2, frames};
        const EventInput in{blockEvents.data(), static_cast<uint32_t>(blockEvents.size())};
        ProcessBlock b;
        b.frames = frames;
        b.sampleRate = sr;
        b.audioOut = &audio;
        b.audioOutCount = 1;
        b.eventIn = &in;
        b.eventInCount = 1;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        p.processPorts(b);
        if (quietAt && *quietAt < 0 && (at + frames) / sr > lastOff && p.quiet()) *quietAt = (at + frames) / sr;
    }
    return out;
}

// The power, in dB, of a Hann-windowed DFT of x[from, from + n) at `hz`.
inline double bandDb(const std::vector<float>& x, double hz, size_t from, size_t n, double sr) {
    double re = 0, im = 0, wsum = 0;
    for (size_t i = 0; i < n && from + i < x.size(); ++i) {
        const double w = 0.5 - 0.5 * std::cos(2 * kPi * i / (n - 1));
        const double ph = 2 * kPi * hz * i / sr;
        re += w * x[from + i] * std::cos(ph);
        im -= w * x[from + i] * std::sin(ph);
        wsum += w;
    }
    return 10 * std::log10((re * re + im * im) / (wsum * wsum) + 1e-30);
}
// The frequency of the strongest peak near `hz` (within `cents` either side), to about 0.01 cent.
inline double peakHz(const std::vector<float>& x, double hz, double cents, size_t from, size_t n, double sr) {
    double best = hz, bestDb = -1e9;
    for (double c = -cents; c <= cents; c += cents / 40) {
        const double f = hz * std::pow(2.0, c / 1200);
        const double db = bandDb(x, f, from, n, sr);
        if (db > bestDb) bestDb = db, best = f;
    }
    double lo = best * std::pow(2.0, -cents / 40 / 1200), hi = best * std::pow(2.0, cents / 40 / 1200);
    for (int it = 0; it < 40; ++it) {  // golden-section on the peak
        const double a = hi - (hi - lo) * 0.618, b = lo + (hi - lo) * 0.618;
        if (bandDb(x, a, from, n, sr) > bandDb(x, b, from, n, sr)) hi = b;
        else lo = a;
    }
    return 0.5 * (lo + hi);
}
inline double cents(double hz, double ref) { return 1200 * std::log2(hz / ref); }
// RMS in dB over [from, from + n).
inline double rmsDb(const std::vector<float>& x, size_t from, size_t n) {
    double e = 0;
    size_t k = 0;
    for (size_t i = from; i < from + n && i < x.size(); ++i, ++k) e += x[i] * x[i];
    return 10 * std::log10(e / std::max<size_t>(k, 1) + 1e-30);
}
// The spectral centroid (Hz) of x[from, from + n) from a direct DFT on a 50 Hz grid to `top` Hz.
inline double centroid(const std::vector<float>& x, size_t from, size_t n, double sr, double top = 12000) {
    double num = 0, den = 0;
    for (double f = 50; f < top; f += 50) {
        const double p = std::pow(10.0, bandDb(x, f, from, n, sr) / 10);
        num += f * p, den += p;
    }
    return den > 0 ? num / den : 0;
}
// The share, in dB, of x[from, from + n)'s power above `split` Hz (to `top`), on a 25 Hz grid.
inline double highShareDb(const std::vector<float>& x, size_t from, size_t n, double sr, double split, double top = 16000) {
    double hi = 0, all = 0;
    for (double f = 25; f < top; f += 25) {
        const double p = std::pow(10.0, bandDb(x, f, from, n, sr) / 10);
        all += p;
        if (f >= split) hi += p;
    }
    return 10 * std::log10((hi + 1e-30) / (all + 1e-30));
}
inline bool verbose() { return std::getenv("CAW_TIMBER_PRINT") != nullptr; }

}  // namespace timber_test
