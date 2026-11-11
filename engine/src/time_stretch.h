// Reading an audio asset for a clip voice: direct, varispeed (cubic Hermite) or time-stretched with WSOLA plus a pitch stage.
#pragma once

#include <cstdint>
#include <memory>

#include "asset_store.h"

namespace caw {

// An asset as a clip reads it: optionally reversed (index i reads frame frames-1-i), then optionally looped
// (an index at or past loopEnd wraps into [loopStart, loopEnd)); anything outside the asset reads silence.
struct ClipSource {
    const AudioAsset* asset = nullptr;
    bool reverse = false;
    bool loop = false;
    int64_t loopStart = 0, loopEnd = 0;  // frames at the asset's rate, in reversed order when reverse
    int64_t wrap(int64_t i) const noexcept {
        if (loop && i >= loopEnd && loopEnd > loopStart) i = loopStart + (i - loopStart) % (loopEnd - loopStart);
        return i;
    }
    void frame(int64_t i, float& l, float& r) const noexcept {
        i = wrap(i);
        if (!asset || i < 0 || i >= asset->frames) {
            l = r = 0.0f;
            return;
        }
        const int64_t p = reverse ? asset->frames - 1 - i : i;
        l = asset->data[0][static_cast<size_t>(p)];
        r = asset->channels > 1 ? asset->data[1][static_cast<size_t>(p)] : l;
    }
};

enum class ReadMode : uint8_t {
    Direct,     // the source position moves one frame per output frame: samples copied exactly
    Varispeed,  // resampled (cubic Hermite): pitch moves with speed
    Stretch,    // WSOLA time-scale modification, then a pitch stage resampling by `pitch`
};

// One voice's reader. prepare() allocates on the control thread; everything else is real-time safe.
//
// The source position the voice should be at, at output frame t, is s(t) = anchorSource + slope * (t - anchorTime)
// (setMapping, refreshed each block, so a tempo change only bends it). Direct and Varispeed read s(t) itself,
// so they hold no state and any frame renders the same whatever came before. Stretch runs WSOLA (W. Verhelst and
// M. Roelands, "An overlap-add technique based on waveform similarity (WSOLA) for high quality time-scale
// modification of speech", ICASSP 1993; the music form as in J. Driedger and M. Mueller, "A Review of Time-Scale
// Modification of Music Signals", Applied Sciences 6(2), 2016): 30 ms Hann frames at 50% overlap whose analysis
// positions follow s(t), each moved by up to half a hop to best continue the previous frame (the cross-correlation
// of the mono sum, searched every 4th lag on every 4th sample, then refined to the sample). The result is read
// `pitch` times faster (cubic Hermite), so pitch moves by `pitch` and duration still follows s(t).
class ClipReader {
public:
    bool prepare(double sampleRate);  // control thread
    // Starts the voice at output frame t (seek, a clip start, a mode change).
    void start(const ClipSource& src, ReadMode mode, double pitch, int64_t t, double anchorSource, double slope) noexcept;
    void setMapping(int64_t anchorTime, double anchorSource, double slope) noexcept {
        anchorT_ = anchorTime;
        anchorS_ = anchorSource;
        slope_ = slope;
    }
    void setSource(const ClipSource& src) noexcept { src_ = src; }
    // Adds gain[i] * the next n frames (from output frame `t`) into l and r.
    void render(int64_t t, int n, const float* gain, float* l, float* r) noexcept;
    ReadMode mode() const noexcept { return mode_; }
    double pitch() const noexcept { return pitch_; }

private:
    double sourceAt(double t) const noexcept { return anchorS_ + slope_ * (t - static_cast<double>(anchorT_)); }
    void hop() noexcept;  // one WSOLA frame into the y ring
    void hermite(double pos, float& l, float& r) const noexcept;

    ClipSource src_;
    ReadMode mode_ = ReadMode::Direct;
    double pitch_ = 1;
    int64_t anchorT_ = 0;
    double anchorS_ = 0, slope_ = 1;
    // WSOLA
    int hs_ = 0, n_ = 0, delta_ = 0;
    std::unique_ptr<float[]> window_, accL_, accR_, scratch_, natural_, yl_, yr_;
    int yMask_ = 0;
    int64_t t0_ = 0;          // output frame the voice started at
    int64_t frameIndex_ = 0;  // the next WSOLA frame m
    int64_t prevStart_ = 0;   // the last frame's analysis start
    int64_t yWritten_ = 0;    // y samples complete
    double u_ = 0;            // where the next output frame reads y (pitch stage)
};

}  // namespace caw
