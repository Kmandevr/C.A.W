// C.A.W. Library: the grain engine (a padded source or ring, a control-rate scheduler and a fixed grain pool) that Murmur and the Flock instrument share; header-only.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "../detmath.hpp"

namespace caw::lib::grain {

// Original code (C.A.W. is Apache-2.0); granular synthesis after Roads ("Microsound", 2001): many short windowed
// reads of a source, each with its own position, length, pitch, direction and pan, overlapped and added.
//
// Three parts, none of which allocates once prepared:
// - Source: what the grains read. A Ring (Murmur's recorded input; positions wrap) or a sample (Flock: read only,
//   padded so frames -1, length and length + 1 can be read; positions are held inside it).
// - Pool: a fixed array of kMaxGrains grains; at most `cap` sound at once (the quality tier's), a grain spawned
//   while it is full is dropped and counted.
// - The scheduler (schedule()) runs at control rate: it spawns the grains whose start falls in the next frames, by
//   the interval (1/density) with jitter, each starting on its own frame, so a grain's timing never depends on the
//   host's block size.
// A grain reads only the past, so there is no latency. Each grain-sample costs one interpolated stereo read
// (Hermite at Normal and High, linear at Eco: render<true/false>) and one window-table lookup.

constexpr uint32_t kMaxGrains = 128;
constexpr uint32_t kWindowPoints = 1024;

enum Window : uint32_t { kHann, kTukey, kGaussian, kExpodec, kRexpodec, kWindowCount };

// The grains alive at once per quality tier (0 Eco, 1 Normal, 2 High): Murmur 16/32/64, Flock (shared by all its
// voices) 64/128/128.
inline uint32_t murmurCap(int tier) noexcept { return tier <= 0 ? 16u : (tier == 1 ? 32u : 64u); }
inline uint32_t flockCap(int tier) noexcept { return tier <= 0 ? 64u : 128u; }

// The windows, kWindowPoints + 1 points over a grain (the last one 0, for interpolation), and each one's mean
// (what an overlap of k grains sums to on average: k x mean). Built once, read only, shared by every instance:
// call windows() at registration so the first grain never builds it.
struct WindowTables {
    float w[kWindowCount][kWindowPoints + 1];
    double mean[kWindowCount];
};
inline const WindowTables& windows() noexcept {
    static const WindowTables t = [] {
        WindowTables x{};
        const double n = kWindowPoints;
        const double g0 = detExp(-0.5 * (0.5 / 0.16) * (0.5 / 0.16));
        const double e0 = detExp(-6.0);
        for (uint32_t j = 0; j <= kWindowPoints; ++j) {
            const double p = j / n;  // 0..1 through the grain
            // Hann (periodic: two grains half a grain apart sum to exactly 1).
            x.w[kHann][j] = static_cast<float>(0.5 - 0.5 * detCos(kTwoPi * p));
            // Tukey, half its length tapered (a quarter at each end), flat in the middle.
            const double edge = p < 0.25 ? p / 0.25 : (p > 0.75 ? (1.0 - p) / 0.25 : 1.0);
            x.w[kTukey][j] = static_cast<float>(0.5 - 0.5 * detCos(kPi * edge));
            // Gaussian (sigma 0.16 of the grain), lowered and rescaled so it ends at 0.
            const double z = (p - 0.5) / 0.16;
            x.w[kGaussian][j] = static_cast<float>((detExp(-0.5 * z * z) - g0) / (1.0 - g0));
            // Expodec: a 2 % rise, then an exponential fall to 0 (a percussive grain); Rexpodec is it reversed.
            auto expodec = [&](double q) {
                if (q < 0.02) return q / 0.02;
                return (detExp(-6.0 * (q - 0.02) / 0.98) - e0) / (1.0 - e0);
            };
            x.w[kExpodec][j] = static_cast<float>(expodec(p));
            x.w[kRexpodec][j] = static_cast<float>(expodec(1.0 - p));
        }
        for (uint32_t k = 0; k < kWindowCount; ++k) {
            x.w[k][kWindowPoints] = 0.0f;
            double s = 0.0;
            for (uint32_t j = 0; j < kWindowPoints; ++j) s += x.w[k][j];
            x.mean[k] = s / n;
        }
        x.w[kRexpodec][0] = 0.0f;
        return x;
    }();
    return t;
}

// Scales for a quantised pitch spread (semitones above the centre pitch): Off is continuous.
enum Scale : uint32_t { kScaleOff, kChromatic, kMajor, kMinor, kPentatonic, kOctaves, kFifths, kScaleCount };
inline double quantise(double semitones, uint32_t scale) noexcept {
    if (scale == kScaleOff || scale >= kScaleCount) return semitones;
    static constexpr int kMajorDeg[] = {0, 2, 4, 5, 7, 9, 11, 12};
    static constexpr int kMinorDeg[] = {0, 2, 3, 5, 7, 8, 10, 12};
    static constexpr int kPentaDeg[] = {0, 2, 4, 7, 9, 12};
    static constexpr int kOctDeg[] = {0, 12};
    static constexpr int kFifthDeg[] = {0, 7, 12};
    if (scale == kChromatic) return std::floor(semitones + 0.5);
    const int* deg = kMajorDeg;
    int count = 8;
    if (scale == kMinor) deg = kMinorDeg;
    if (scale == kPentatonic) deg = kPentaDeg, count = 6;
    if (scale == kOctaves) deg = kOctDeg, count = 2;
    if (scale == kFifths) deg = kFifthDeg, count = 3;
    const double oct = std::floor(semitones / 12.0);
    const double r = semitones - 12.0 * oct;
    double best = 0.0, dist = 1e9;
    for (int k = 0; k < count; ++k)
        if (std::fabs(r - deg[k]) < dist) dist = std::fabs(r - deg[k]), best = deg[k];
    return 12.0 * oct + best;
}

// What the grains read. `l` and `r` point at frame 0 and frames -1 .. length + 1 are readable. A ring wraps; its
// `head` is the frame it writes next, `moving` while it records (one frame on per frame: Murmur not frozen).
struct Source {
    const float* l = nullptr;
    const float* r = nullptr;
    uint32_t length = 0;
    bool ring = false;
    uint32_t head = 0;
    bool moving = false;
};

// A stereo recording ring of up to `capacity` frames (prepare, on the control thread), its length set to any
// size up to that on the audio thread (setLength: it starts silent again). Stored one frame in, with the last frame
// copied before the first and the first two after the last, so a cubic read never wraps an index.
class Ring {
public:
    bool prepare(uint32_t capacity) {
        try {
            l_.assign(static_cast<size_t>(capacity) + 3, 0.0f);
            r_.assign(static_cast<size_t>(capacity) + 3, 0.0f);
        } catch (...) {
            return false;
        }
        cap_ = capacity, len_ = capacity, head_ = 0;
        return capacity >= 8;
    }
    void clear() noexcept {
        std::fill(l_.begin(), l_.end(), 0.0f);
        std::fill(r_.begin(), r_.end(), 0.0f);
        head_ = 0;
    }
    void setLength(uint32_t n) noexcept {
        n = std::clamp<uint32_t>(n, 8u, cap_);
        if (n == len_) return;
        len_ = n;
        clear();
    }
    void write(float l, float r) noexcept {
        const uint32_t j = head_;
        l_[j + 1] = l, r_[j + 1] = r;
        if (j == len_ - 1) l_[0] = l, r_[0] = r;
        if (j < 2) l_[len_ + 1 + j] = l, r_[len_ + 1 + j] = r;
        head_ = j + 1 == len_ ? 0 : j + 1;
    }
    Source source(bool moving) const noexcept { return {l_.data() + 1, r_.data() + 1, len_, true, head_, moving}; }
    uint32_t length() const noexcept { return len_; }
    uint32_t head() const noexcept { return head_; }
    // The frame `age` frames before the head (1: the last written), left and right.
    float back(uint32_t age, int channel) const noexcept {
        const uint32_t a = age % len_;
        const uint32_t j = head_ >= a ? head_ - a : head_ + len_ - a;
        return (channel ? r_ : l_)[j + 1];
    }

private:
    std::vector<float> l_, r_;
    uint32_t cap_ = 0, len_ = 0, head_ = 0;
};

// The settings a scheduler reads (the device's knobs, worked out at control rate).
struct Settings {
    double position = 0.0;     // 0..1: how far back in a ring (0 the newest), where in a sample (0 its start)
    double sprayFrames = 0.0;  // the start moves up to this many frames either way, at random
    double sizeFrames = 4800;  // each grain's length
    double interval = 2400;    // frames from one grain's start to the next (1 / density)
    double jitter = 0.0;       // 0..1: each interval moves up to this share either way, at random
    double pitch = 0.0;        // semitones (the centre)
    double pitchSpread = 0.0;  // semitones: each grain up to this far above or below, at random
    uint32_t scale = kScaleOff;
    double reverse = 0.0;      // 0..1: the chance a grain plays backwards
    double panSpread = 0.0;    // 0..1: each grain's pan up to this far left or right, at random
    uint32_t window = kHann;
    float gain = 1.0f;         // each grain's level
    // Flock (a sample, read through renderVoices): the half-band mip copies the source has above its own frames
    // (a grain more than an octave up reads the copy that brings its rate to at most 2), and `fit`: each grain
    // starts where its whole read lies inside the sample when it can. Murmur leaves both off.
    uint32_t levels = 0;
    bool fit = false;
};

struct Grain {
    double pos = 0.0;      // read position, frames into the source
    double rate = 1.0;     // frames read per frame (negative: backwards)
    double phase = 0.0;    // through the window, 0..1
    double dphase = 0.0;
    uint32_t left = 0;     // frames left to sound
    uint32_t wait = 0;     // frames before it starts (spawned inside a control period)
    float gl = 1.0f, gr = 1.0f;
    uint32_t window = kHann;
    float pan = 0.0f;
    float semitones = 0.0f;
    uint8_t voice = 0;     // Flock: the voice that spawned it (renderVoices adds it into that voice's buffer)
    uint8_t level = 0;     // Flock: the mip copy it reads (its pos and rate are in that copy's frames)
    // Flock's reads step these (exact integer sums, so any split into chunks gives the same frames): the position
    // and rate in 32.32 fixed point, the window phase in 0.32; pos and phase follow them for the display.
    int64_t fpos = 0, fstep = 0;
    uint32_t wph = 0, wstep = 0;
};

class Engine {
public:
    // At most kMaxGrains; grains already sounding above a lowered cap finish.
    void setCap(uint32_t cap) noexcept { cap_ = std::clamp<uint32_t>(cap, 1u, kMaxGrains); }
    uint32_t cap() const noexcept { return cap_; }
    // The random numbers from here on (a device seeds at reset and when the song starts playing).
    void seed(uint32_t s) noexcept { rng_ = hash32(s * 2654435761u + 0x9e3779b9u) | 1u; }
    void clear() noexcept {
        alive_ = 0;
        next_ = 0.0;
        dropped_ = 0;
        spawned_ = 0;
    }
    // Control rate: spawns the grains whose start falls in the next `frames` frames.
    void schedule(const Source& s, const Settings& st, uint32_t frames) noexcept { schedule(s, st, frames, next_, 0); }
    // The same with the scheduler's own clock `next` (frames to its next grain) and its grains tagged `voice`:
    // Flock's voices each schedule into the one shared pool.
    void schedule(const Source& s, const Settings& st, uint32_t frames, double& next, uint8_t voice) noexcept {
        if (s.length < 8) return;
        const double interval = std::max(1.0, st.interval);
        for (uint32_t guard = 0; next < frames && guard < frames + 1; ++guard) {
            spawn(s, st, static_cast<uint32_t>(next < 0.0 ? 0.0 : next), voice);
            next += interval * (1.0 + std::clamp(st.jitter, 0.0, 1.0) * bipolar());
            if (next < 0.0) next = 0.0;
        }
        next -= frames;
    }
    // Flock: adds each grain's next n frames into its voice's buffers (outL[voice], outR[voice], n frames each),
    // reading the source copy its level names (levels[level]: a sample and its mip copies). A grain that runs off
    // either end of its copy ends there (spawn shortens it). Finished grains stay in the pool, silent, until retire()
    // (at the end of a control period), so the order grains are summed in never depends on how a period is split.
    template <bool Hermite>
    void renderVoices(const Source* levels, float* const* outL, float* const* outR, uint32_t n) noexcept {
        for (uint32_t g = 0; g < alive_; ++g) {
            Grain& gr = pool_[g];
            if (gr.left == 0) continue;
            const uint32_t start = std::min(gr.wait, n);
            gr.wait -= start;
            const uint32_t stop = std::min<uint32_t>(n, start + gr.left);
            if (stop == start) continue;
            const Source& s = levels[gr.level];
            if (s.r == s.l) readGrain<Hermite, true>(gr, s, outL[gr.voice], outR[gr.voice], start, stop);
            else readGrain<Hermite, false>(gr, s, outL[gr.voice], outR[gr.voice], start, stop);
            gr.left -= stop - start;
        }
    }
    // Flock: drops the finished grains (renderVoices leaves them in place).
    void retire() noexcept {
        for (uint32_t g = 0; g < alive_;) {
            if (pool_[g].left == 0) pool_[g] = pool_[--alive_];
            else ++g;
        }
    }
    // Flock: ends every grain of `voice` now (its voice ended, or its slot is taken by a new note).
    void endVoice(uint8_t voice) noexcept {
        for (uint32_t g = 0; g < alive_;) {
            if (pool_[g].voice == voice) pool_[g] = pool_[--alive_];
            else ++g;
        }
    }
    // Adds every grain's next n frames into outL/outR (which hold n frames), and retires the finished ones.
    // Hermite: a cubic read (Normal, High); else linear (Eco).
    template <bool Hermite>
    void render(const Source& s, float* outL, float* outR, uint32_t n) noexcept {
        const WindowTables& wt = windows();
        const double len = s.length;
        for (uint32_t g = 0; g < alive_;) {
            Grain& gr = pool_[g];
            const uint32_t start = std::min(gr.wait, n);
            gr.wait -= start;
            const uint32_t stop = std::min<uint32_t>(n, start + gr.left);
            const float* w = wt.w[gr.window];
            double pos = gr.pos, ph = gr.phase;
            const double rate = gr.rate, dph = gr.dphase;
            const float gl = gr.gl, gR = gr.gr;
            for (uint32_t i = start; i < stop; ++i) {
                const double x = ph * kWindowPoints;
                const uint32_t j = std::min<uint32_t>(static_cast<uint32_t>(x), kWindowPoints - 1);
                const float f = static_cast<float>(x - j);
                const float win = w[j] + f * (w[j + 1] - w[j]);
                const uint32_t k = static_cast<uint32_t>(pos);
                const float t = static_cast<float>(pos - k);
                float l, r;
                if constexpr (Hermite) {
                    l = cubic(s.l + k, t), r = cubic(s.r + k, t);
                } else {
                    l = s.l[k] + t * (s.l[k + 1] - s.l[k]);
                    r = s.r[k] + t * (s.r[k + 1] - s.r[k]);
                }
                outL[i] += win * gl * l;
                outR[i] += win * gR * r;
                ph += dph;
                pos += rate;
                if (s.ring) {
                    if (pos >= len) pos -= len;
                    if (pos < 0.0) pos += len;
                } else {
                    pos = std::clamp(pos, 0.0, len - 1.0);
                }
            }
            gr.pos = pos, gr.phase = ph;
            gr.left -= stop - start;
            if (gr.left == 0 && gr.wait == 0) pool_[g] = pool_[--alive_];  // finished: the last one takes its place
            else ++g;
        }
    }

    uint32_t alive() const noexcept { return alive_; }
    const Grain& grain(uint32_t k) const noexcept { return pool_[k]; }
    // Grains not started because the pool was full, and grains started, since the last call.
    uint32_t takeDropped() noexcept {
        const uint32_t d = dropped_;
        dropped_ = 0;
        return d;
    }
    uint32_t takeSpawned() noexcept {
        const uint32_t d = spawned_;
        spawned_ = 0;
        return d;
    }

private:
    double uniform() noexcept {
        rng_ = rng_ * 1664525u + 1013904223u;
        return static_cast<double>(hash32(rng_) >> 8) / 16777216.0;
    }
    double bipolar() noexcept { return 2.0 * uniform() - 1.0; }
    // Flock: frames [start, stop) of one grain into oL/oR (its frames all lie inside the source: spawn's fit).
    template <bool Hermite, bool Mono>
    static void readGrain(Grain& gr, const Source& s, float* oL, float* oR, uint32_t start, uint32_t stop) noexcept {
        static_assert(kWindowPoints == 1024, "the window index is the phase's top 10 bits");
        const float* w = windows().w[gr.window];
        const float* xl = s.l;
        const float* xr = s.r;
        int64_t pos = gr.fpos;
        uint32_t ph = gr.wph;
        const int64_t rate = gr.fstep;
        const uint32_t dph = gr.wstep;
        const float gl = gr.gl, gR = gr.gr;
        constexpr float kFrac22 = 1.0f / 4194304.0f, kFrac32 = 1.0f / 4294967296.0f;
        for (uint32_t i = start; i < stop; ++i) {
            const uint32_t j = ph >> 22;
            const float f = static_cast<float>(ph & 0x3FFFFFu) * kFrac22;
            const float win = w[j] + f * (w[j + 1] - w[j]);
            const uint32_t k = static_cast<uint32_t>(pos >> 32);
            const float t = static_cast<float>(static_cast<uint32_t>(pos)) * kFrac32;
            float l, r;
            if constexpr (Hermite) {
                l = cubic(xl + k, t);
                r = Mono ? l : cubic(xr + k, t);
            } else {
                l = xl[k] + t * (xl[k + 1] - xl[k]);
                r = Mono ? l : xr[k] + t * (xr[k + 1] - xr[k]);
            }
            oL[i] += win * gl * l;
            oR[i] += win * gR * r;
            ph += dph;
            pos += rate;
        }
        gr.fpos = pos, gr.wph = ph;
        gr.pos = static_cast<double>(pos) * (1.0 / 4294967296.0);
        gr.phase = static_cast<double>(ph) * (1.0 / 4294967296.0);
    }
    // Catmull-Rom through x[-1], x[0], x[1], x[2] at t.
    static float cubic(const float* x, float t) noexcept {
        const float a = x[-1], b = x[0], c = x[1], d = x[2];
        const float c1 = 0.5f * (c - a);
        const float c2 = a - 2.5f * b + 2.0f * c - 0.5f * d;
        const float c3 = 0.5f * (d - a) + 1.5f * (b - c);
        return ((c3 * t + c2) * t + c1) * t + b;
    }
    void spawn(const Source& s, const Settings& st, uint32_t wait, uint8_t voice) noexcept {
        // The random choices are made whether or not the grain fits, so a full pool doesn't shift later grains'.
        const double u1 = bipolar(), u2 = bipolar(), u3 = uniform(), u4 = bipolar();
        if (alive_ >= cap_) {
            ++dropped_;
            return;
        }
        double semis = st.pitch;
        if (st.pitchSpread > 0.0) semis += quantise(st.pitchSpread * u2, st.scale);
        semis = std::clamp(semis, -48.0, 48.0);
        double rate = detPow(2.0, semis / 12.0);
        if (u3 < st.reverse) rate = -rate;
        double size = std::max(2.0, std::floor(st.sizeFrames + 0.5));
        const double len = s.length;
        double pos;
        if (s.ring) {
            // The age (frames behind the head) the grain starts at, kept so every frame it reads is recorded and
            // not yet overwritten: its age moves by k a frame (the head moves 1 while recording; the read `rate`).
            const double k = (s.moving ? 1.0 : 0.0) - rate;
            const double margin = 24.0;  // a control period's writes ahead, and the cubic read's reach
            const double room = len - 2.0 * margin;
            if (std::fabs(k) * size > room) size = std::max(2.0, std::floor(room / std::fabs(k)));
            const double lo = std::max(margin, margin - k * size), hi = std::min(len - margin, len - margin - k * size);
            double age = st.position * (len - 1.0) + st.sprayFrames * u1;
            age = std::clamp(age, lo, std::max(lo, hi));
            const double headAtStart = static_cast<double>(s.head) + (s.moving ? wait : 0.0);
            pos = headAtStart - age;
            pos -= len * std::floor(pos / len);
        } else {
            pos = std::clamp(st.position * (len - 1.0) + st.sprayFrames * u1, 0.0, len - 1.0);
        }
        uint8_t level = 0;
        if (!s.ring) {
            // More than an octave up: the mip copy that brings the rate to at most 1 of its frames a frame (none
            // of its content can then fold over), or the highest there is.
            if (std::fabs(rate) > 2.0)
                for (; level < st.levels && std::fabs(rate) > 1.0; ++level) rate *= 0.5, pos *= 0.5;
        }
        uint32_t frames = static_cast<uint32_t>(size);
        if (!s.ring && st.fit) {
            const double last = std::floor((len - 1.0) / static_cast<double>(1u << level));
            const double reach = size * std::fabs(rate);
            pos = rate > 0.0 ? std::min(pos, std::max(0.0, last - reach)) : std::max(pos, std::min(last, reach));
            // A read that would still run off an end (a long grain far up) sounds only while inside, half a frame
            // in, so a cubic read never leaves the copy's padding.
            const double room = rate > 0.0 ? (last - 0.5 - pos) / rate : (pos - 0.5) / -rate;
            frames = static_cast<uint32_t>(std::clamp(std::floor(room) + 1.0, 0.0, size));
        }
        Grain& g = pool_[alive_++];
        g.pos = pos;
        g.rate = rate;
        g.phase = 0.0;
        g.dphase = 1.0 / size;
        g.left = frames;
        g.wait = wait;
        const double pan = std::clamp(st.panSpread, 0.0, 1.0) * u4;
        g.gl = static_cast<float>(st.gain * std::min(1.0, 1.0 - pan));  // balance: unity in the centre
        g.gr = static_cast<float>(st.gain * std::min(1.0, 1.0 + pan));
        g.window = st.window < kWindowCount ? st.window : kHann;
        g.pan = static_cast<float>(pan);
        g.semitones = static_cast<float>(rate < 0 ? -semis : semis);
        g.voice = voice;
        g.level = level;
        if (!s.ring) {
            g.fpos = static_cast<int64_t>(std::llround(pos * 4294967296.0));
            g.fstep = static_cast<int64_t>(std::llround(rate * 4294967296.0));
            g.wph = 0;
            g.wstep = static_cast<uint32_t>(std::floor(4294967296.0 / size));  // never wraps within the grain
        }
        ++spawned_;
    }

    Grain pool_[kMaxGrains];
    uint32_t alive_ = 0, cap_ = 32, dropped_ = 0, spawned_ = 0;
    uint32_t rng_ = 1;
    double next_ = 0.0;
};

}  // namespace caw::lib::grain
