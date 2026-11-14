// Reading an audio asset for a clip voice: direct, varispeed (cubic Hermite), WSOLA plus a pitch stage, or Signalsmith Stretch.
#pragma once

#include <algorithm>
#include <cstdint>
#include <memory>

#include "asset_store.h"
#include "clip_stretch.h"

namespace caw {

// An asset as a clip reads it: optionally reversed (index i reads frame frames-1-i), then optionally looped
// (an index at or past loopEnd wraps into [loopStart, loopEnd)); anything outside the asset reads silence.
// A loop seam is crossfaded over `seam` frames (at most half the loop), so the wrap is no hard splice, and the
// loop's period stays exact: with audio before loopStart, the loop's last frames fade into that lead-in (which
// runs on into loopStart); else, with audio after loopEnd, the first frames after a wrap fade in over what
// would have followed the end; else (the whole file looped) the seam dips: half the seam fading out to the end
// and half fading in from the start.
struct ClipSource {
    const AudioAsset* asset = nullptr;
    bool reverse = false;
    bool loop = false;
    int64_t loopStart = 0, loopEnd = 0;  // frames at the asset's rate, in reversed order when reverse
    int64_t seam = 0;                    // frames; 0 splices hard
    int64_t wrap(int64_t i) const noexcept {
        if (loop && i >= loopEnd && loopEnd > loopStart) i = loopStart + (i - loopStart) % (loopEnd - loopStart);
        return i;
    }
    void raw(int64_t i, float& l, float& r) const noexcept {
        if (!asset || i < 0 || i >= asset->frames) {
            l = r = 0.0f;
            return;
        }
        const int64_t p = reverse ? asset->frames - 1 - i : i;
        l = asset->data[0][static_cast<size_t>(p)];
        r = asset->channels > 1 ? asset->data[1][static_cast<size_t>(p)] : l;
    }
    void frame(int64_t i, float& l, float& r) const noexcept {
        const bool looping = loop && loopEnd > loopStart;
        const bool wrapped = looping && i >= loopEnd;
        i = wrap(i);
        raw(i, l, r);
        if (!looping || seam <= 0 || !asset) return;
        const int64_t len = loopEnd - loopStart, x = std::min(seam, len / 2);
        if (x <= 0) return;
        float a, b;
        if (loopStart >= x) {
            if (i < loopEnd - x) return;
            const float w = static_cast<float>((static_cast<double>(i - (loopEnd - x)) + 0.5) / static_cast<double>(x));
            raw(i - len, a, b);
            l = l * (1.0f - w) + a * w;
            r = r * (1.0f - w) + b * w;
        } else if (loopEnd + x <= asset->frames) {
            if (!wrapped || i >= loopStart + x) return;
            const float w = static_cast<float>((static_cast<double>(i - loopStart) + 0.5) / static_cast<double>(x));
            raw(loopEnd + (i - loopStart), a, b);
            l = l * w + a * (1.0f - w);
            r = r * w + b * (1.0f - w);
        } else {
            const int64_t h = std::max<int64_t>(1, x / 2);
            float g = 1.0f;
            if (i >= loopEnd - h) g = static_cast<float>((static_cast<double>(loopEnd - i) - 0.5) / static_cast<double>(h));
            else if (wrapped && i < loopStart + h) g = static_cast<float>((static_cast<double>(i - loopStart) + 0.5) / static_cast<double>(h));
            l *= g;
            r *= g;
        }
    }
};

enum class ReadMode : uint8_t {
    Direct,     // the source position moves one frame per output frame: samples copied exactly
    Varispeed,  // resampled (cubic Hermite): pitch moves with speed
    Stretch,    // WSOLA time-scale modification, then a pitch stage resampling by `pitch`
    Hq,         // Signalsmith Stretch (clip_stretch.h): time and pitch in one phase-vocoder pass
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
//
// Hq feeds an HqStretcher (Signalsmith Stretch) the source ahead of the output: by output frame t it has been given the
// source up to s(t + L) + I (L its output latency, I its input latency), so its output at t is the source at s(t),
// rate changes (a tempo ramp) included. It renders in 64-frame chunks aligned to the voice's start, so the result does
// not depend on the host's block size. Source frames before `floor` (the clip's offset) read as silence. Its output is
// valid L frames after start(): the player starts a voice that early when it can (a clip start ahead of the
// playhead); otherwise (a seek, a loop wrap, a voice joining mid-clip) WSOLA plays those L frames and then crossfades
// into it over kHqCrossfade frames. Without a stretcher Hq falls back to WSOLA (Stretch).
class ClipReader {
public:
    static constexpr int kHqCrossfade = 512;
    bool prepare(double sampleRate);  // control thread
    // Starts the voice at output frame t (seek, a clip start, a mode change). Hq takes a stretcher (else it plays as
    // Stretch), the source floor, and the first output frame that is heard (from then on its output must be valid).
    void start(const ClipSource& src, ReadMode mode, double pitch, int64_t t, double anchorSource, double slope,
               HqStretcher* hq = nullptr, int64_t floor = 0, int64_t heardFrom = 0) noexcept;
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
    void startWsola(int64_t t) noexcept;
    void renderWsola(int n, const float* gain, float* l, float* r) noexcept;
    void hqChunk() noexcept;  // the next 64 output frames into hqL_/hqR_

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
    // Hq
    HqStretcher* hq_ = nullptr;
    int64_t floor_ = 0;
    int64_t fed_ = 0;         // the next source frame to feed
    int64_t chunkAt_ = 0;     // output frame of hqL_[0]
    int64_t bridgeEnd_ = 0;   // WSOLA alone before this, crossfading into Signalsmith over kHqCrossfade after it
    float hqL_[HqStretcher::kChunk] = {}, hqR_[HqStretcher::kChunk] = {};
};

}  // namespace caw
