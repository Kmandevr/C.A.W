// C.A.W. Library: a band-limited, mipmapped wavetable (user-filled frames, frame morph) and its oscillator; header-only.
#pragma once

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "../detmath.hpp"

namespace caw::lib {

// How the anti-aliasing works (read this once; it is the whole trick):
//
// A single-cycle wave played at f0 Hz contains harmonics at f0, 2*f0, 3*f0, ... Any harmonic above half
// the sample rate (Nyquist) cannot be represented and folds back as an inharmonic tone: aliasing. So each
// frame is stored as several "mip levels", one per octave: level 0 keeps harmonics 1..frameSize/2, level 1
// keeps half as many, level k keeps (frameSize/2) >> k. The oscillator picks the first level whose highest
// harmonic stays at or below Nyquist for the note being played, so nothing it plays can alias. The cost of
// this guarantee is that in the worst case (a note just above a level's threshold) the top octave of the
// spectrum, between a quarter and half the sample rate, is left out.
//
// Levels are built additively (no FFT): a frame is described by its harmonics' sine and cosine amounts, and
// each level is the sum of the harmonics it keeps, evaluated from one exact integer-indexed sine table.
// A frame given as a function is first measured with a direct DFT (frameSize^2 / 2 multiply-adds). Both
// run at load time, off the audio thread: building one 2048-sample frame takes a few million flops.
//
// Higher levels hold fewer harmonics, so they are stored in shorter tables: 16 samples per cycle of the
// highest harmonic (at least 128, at most frameSize). Reading between table samples is linear
// interpolation (2 loads and a multiply-add), whose error shows up as weak images of each harmonic h near
// tableSize - h and tableSize + h; at 16 samples per cycle they stay about 60 dB below a saw's level (the
// test measures it). The whole mip chain costs about 5 * frameSize floats per frame instead of
// levels * frameSize. The lowest levels (fundamentals under about 90 Hz at 48 kHz) keep more harmonics
// than 16 samples per cycle allows for; their top harmonics are above 10 kHz and very quiet in practice.

// The table data: frames x mip levels. One Wavetable can feed any number of WavetableOscillator voices.
// prepare() allocates; the set*() builders do not allocate but are expensive (not for the audio thread).
// Do not rebuild a frame while an oscillator is reading it: fill a second Wavetable and swap the pointer
// (WavetableOscillator::setTable) at a block boundary.
class Wavetable {
public:
    // Room for up to `maxFrames` frames of `frameSize` samples (a power of two, 64..65536; others round up).
    void prepare(int maxFrames, int frameSize = 2048) {
        int n = 64;
        while (n < frameSize && n < 65536) n <<= 1;
        size_ = n;
        maxFrames_ = maxFrames < 1 ? 1 : maxFrames;
        frameCount_ = 1;
        levels_ = 0;
        size_t offset = 0;
        for (int h = size_ / 2; h >= 1; h >>= 1) {
            int m = 16 * h;
            m = m < 128 ? 128 : (m > size_ ? size_ : m);
            levelSize_[levels_] = m;
            levelOffset_[levels_] = offset;
            offset += static_cast<size_t>(m) + 1;  // + 1 guard sample (a copy of sample 0) for interpolation
            ++levels_;
        }
        frameStride_ = offset;
        data_.assign(frameStride_ * static_cast<size_t>(maxFrames_), 0.0f);
        sine_.resize(static_cast<size_t>(size_));
        for (int i = 0; i < size_; ++i) sine_[static_cast<size_t>(i)] = detSin(kTwoPi * i / size_);
        sinAmt_.assign(static_cast<size_t>(size_ / 2 + 1), 0.0);
        cosAmt_.assign(static_cast<size_t>(size_ / 2 + 1), 0.0);
        samples_.assign(static_cast<size_t>(size_), 0.0);
    }

    int frameSize() const noexcept { return size_; }
    int maxFrames() const noexcept { return maxFrames_; }
    int levels() const noexcept { return levels_; }
    // How many frames the morph position spans (1..maxFrames). The builders raise it to cover what they fill.
    int frameCount() const noexcept { return frameCount_; }
    void setFrameCount(int n) noexcept { frameCount_ = n < 1 ? 1 : (n > maxFrames_ ? maxFrames_ : n); }
    // The table length of mip level k (samples per cycle).
    int levelSize(int level) const noexcept { return level < 0 || level >= levels_ ? 0 : levelSize_[level]; }
    // The highest harmonic mip level k keeps.
    int harmonicsAt(int level) const noexcept { return level < 0 || level >= levels_ ? 0 : (size_ / 2) >> level; }

    // Build frame `frame` from harmonic amplitudes: amplitudes[h - 1] is harmonic h's peak (1 = full
    // scale); phases[h - 1] (optional) its start phase in cycles (0: a sine starting at 0, 0.25: a cosine).
    // Harmonics above frameSize/2 are ignored. Returns false if the table is not prepared or `frame` is out
    // of range.
    bool setFrameHarmonics(int frame, const double* amplitudes, int count, const double* phases = nullptr) noexcept {
        if (!ready(frame) || amplitudes == nullptr) return false;
        const int top = size_ / 2;
        for (int h = 0; h <= top; ++h) sinAmt_[h] = cosAmt_[h] = 0.0;
        for (int h = 1; h <= top && h <= count; ++h) {
            const double a = finiteOr0(amplitudes[h - 1]);
            const double p = phases ? kTwoPi * finiteOr0(phases[h - 1]) : 0.0;
            // a * sin(x + p) = a cos(p) sin(x) + a sin(p) cos(x)
            sinAmt_[h] = a * detCos(p);
            cosAmt_[h] = a * detSin(p);
        }
        buildLevels(frame);
        return true;
    }

    // Build frame `frame` from one cycle of a function: fn(phase) for phase 0..1 gives the sample. It is
    // sampled at frameSize points, measured into harmonics with a direct DFT (DC is dropped: an offset is
    // not useful in an oscillator) and band-limited per level like any other frame. A naive saw
    // [](double p) { return 2 * p - 1; } becomes a clean, alias-free saw.
    template <class Fn>
    bool setFrameFunction(int frame, Fn&& fn) {
        if (!ready(frame)) return false;
        for (int i = 0; i < size_; ++i) samples_[i] = finiteOr0(static_cast<double>(fn(static_cast<double>(i) / size_)));
        const int top = size_ / 2, mask = size_ - 1, quarter = size_ / 4;
        const double scale = 2.0 / size_;
        for (int h = 1; h <= top; ++h) {
            double s = 0.0, c = 0.0;
            for (int i = 0, idx = 0; i < size_; ++i, idx = (idx + h) & mask) {
                s += samples_[i] * sine_[idx];
                c += samples_[i] * sine_[(idx + quarter) & mask];  // cos(x) = sin(x + quarter cycle)
            }
            // At h = size/2 the sine part is identically 0 and the cosine part counts twice.
            sinAmt_[h] = s * scale;
            cosAmt_[h] = c * (h == top ? scale * 0.5 : scale);
        }
        buildLevels(frame);
        return true;
    }

    // The first level whose harmonics all stay at or below Nyquist for a step of `dt` cycles per sample
    // (f0 / sampleRate). Above Nyquist (dt >= 0.5) it returns -1: the oscillator then plays silence.
    int levelFor(double dt) const noexcept {
        if (!(dt < 0.5)) return -1;
        for (int k = 0; k < levels_; ++k)
            if (static_cast<double>((size_ / 2) >> k) * dt <= 0.5) return k;
        return levels_ - 1;
    }

    // One sample of frame `frame`, level `level`, at `phase` 0..1 (linear interpolation between samples).
    float read(int frame, int level, double phase) const noexcept {
        const float* t = &data_[frameStride_ * static_cast<size_t>(frame) + levelOffset_[level]];
        const double x = phase * levelSize_[level];
        const int i = static_cast<int>(x);
        const float f = static_cast<float>(x - i);
        return t[i] + (t[i + 1] - t[i]) * f;
    }
    // The samples of frame `frame`, mip level `level`: levelSize(level) + 1 floats (the last repeats the first,
    // so reading sample i and i + 1 for any i below levelSize needs no wrap). For a renderer that reads many
    // copies at once (a unison stack) without read()'s per-sample offset sums. Null if out of range.
    const float* levelData(int frame, int level) const noexcept {
        if (data_.empty() || frame < 0 || frame >= maxFrames_ || level < 0 || level >= levels_) return nullptr;
        return &data_[frameStride_ * static_cast<size_t>(frame) + levelOffset_[level]];
    }
    // Morph: `position` 0..1 across frameCount() frames, linearly between the two nearest.
    double readMorph(double position, int level, double phase) const noexcept {
        if (level < 0 || data_.empty()) return 0.0;
        const double pos = (position < 0.0 ? 0.0 : (position > 1.0 ? 1.0 : position)) * (frameCount_ - 1);
        const int f0 = static_cast<int>(pos);
        const double mix = pos - f0;
        const double a = read(f0, level, phase);
        return mix > 0.0 ? a + (read(f0 + 1, level, phase) - a) * mix : a;
    }

private:
    static constexpr int kMaxLevels = 16;

    bool ready(int frame) noexcept {
        if (data_.empty() || frame < 0 || frame >= maxFrames_) return false;
        if (frame >= frameCount_) frameCount_ = frame + 1;
        return true;
    }

    // Each level: the sum of the harmonics it keeps, from the integer-indexed sine table, so harmonic h at
    // sample m reads sine_[(h * m * size / levelSize) mod size] exactly, with no accumulated phase error.
    void buildLevels(int frame) noexcept {
        const int mask = size_ - 1, quarter = size_ / 4;
        for (int k = 0; k < levels_; ++k) {
            float* t = &data_[frameStride_ * static_cast<size_t>(frame) + levelOffset_[k]];
            const int m = levelSize_[k], stride = size_ / m, top = harmonicsAt(k);
            for (int i = 0; i < m; ++i) {
                double v = 0.0;
                const int base = i * stride;
                for (int h = 1, idx = base & mask; h <= top; ++h, idx = (idx + base) & mask) {
                    if (sinAmt_[h] != 0.0) v += sinAmt_[h] * sine_[idx];
                    if (cosAmt_[h] != 0.0) v += cosAmt_[h] * sine_[(idx + quarter) & mask];
                }
                t[i] = static_cast<float>(v);
            }
            t[m] = t[0];
        }
    }

    std::vector<float> data_;
    std::vector<double> sine_, sinAmt_, cosAmt_, samples_;
    size_t frameStride_ = 0, levelOffset_[kMaxLevels] = {};
    int levelSize_[kMaxLevels] = {};
    int size_ = 0, maxFrames_ = 0, frameCount_ = 1, levels_ = 0;
};

// One voice reading a Wavetable: setFrequency() picks the mip level (do it when the pitch changes; a
// vibrato that moves every sample can call it every 16 frames), next() reads, morphs and advances.
// Allocation-free; holds only a pointer to the shared table.
class WavetableOscillator {
public:
    void setTable(const Wavetable* table) noexcept {
        table_ = table;
        level_ = table_ ? table_->levelFor(dt_) : -1;
    }
    void setFrequency(double hz, double sampleRate) noexcept {
        const double d = sampleRate > 0.0 ? finiteOr0(hz) / sampleRate : 0.0;
        dt_ = d < 0.0 ? -d : d;  // a negative frequency plays at its magnitude
        level_ = table_ ? table_->levelFor(dt_) : -1;
    }
    // Morph position 0..1 across the table's frames.
    void setPosition(double position) noexcept { position_ = finiteOr0(position); }
    void reset(double phase = 0.0) noexcept {
        const double p = finiteOr0(phase);
        phase_ = p - std::floor(p);
    }
    double next() noexcept {
        if (table_ == nullptr || level_ < 0) return 0.0;
        const double v = table_->readMorph(position_, level_, phase_);
        phase_ += dt_;
        if (phase_ >= 1.0) phase_ -= 1.0;
        return v;
    }
    void process(float* out, int frames) noexcept {
        for (int i = 0; i < frames; ++i) out[i] = static_cast<float>(next());
    }
    int level() const noexcept { return level_; }
    double phase() const noexcept { return phase_; }

private:
    const Wavetable* table_ = nullptr;
    double phase_ = 0.0, dt_ = 0.0, position_ = 0.0;
    int level_ = -1;
};

// Harmonic amplitude helpers for setFrameHarmonics (fill `out[0..count)`, harmonic h at out[h - 1]).
// Sawtooth: harmonic h at (2/pi)/h with alternating sign, the Fourier series of a saw from -1 to +1 that
// matches the naive 2p - 1 rising ramp shifted half a cycle (it starts at 0, as sineWave does).
inline void sawHarmonics(double* out, int count) noexcept {
    for (int h = 1; h <= count; ++h) out[h - 1] = (h & 1 ? 2.0 : -2.0) / (kPi * h);
}
// Square: odd harmonics at (4/pi)/h.
inline void squareHarmonics(double* out, int count) noexcept {
    for (int h = 1; h <= count; ++h) out[h - 1] = h & 1 ? 4.0 / (kPi * h) : 0.0;
}
// Triangle: odd harmonics at (8/pi^2)/h^2 with alternating sign.
inline void triangleHarmonics(double* out, int count) noexcept {
    for (int h = 1; h <= count; ++h) out[h - 1] = h & 1 ? ((h & 3) == 1 ? 8.0 : -8.0) / (kPi * kPi * h * h) : 0.0;
}

}  // namespace caw::lib
