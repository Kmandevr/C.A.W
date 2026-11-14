// Signalsmith Stretch for clip voices: the only file that includes the vendored library (engine/third_party).
#include "clip_stretch.h"

#include <algorithm>
#include <new>
#include <random>

#include "signalsmith-stretch/signalsmith-stretch.h"

namespace caw {

namespace {
// std::minstd_rand is fully specified by the standard, so the random phases the library uses past a 2x stretch
// come from the same sequence on every platform (std::default_random_engine differs between standard libraries).
using Stretch = signalsmith::stretch::SignalsmithStretch<float, std::minstd_rand>;
constexpr long kSeed = 0x00c0ffee;

struct Planar {
    float* l;
    float* r;
    float* operator[](int c) const noexcept { return c ? r : l; }
};
}  // namespace

struct HqStretcher::Impl {
    Stretch s{kSeed};
};

HqStretcher::HqStretcher() = default;
HqStretcher::~HqStretcher() = default;

bool HqStretcher::prepare(double sampleRate) {
    try {
        auto impl = std::make_unique<Impl>();
        impl->s.presetDefault(2, static_cast<float>(sampleRate), true);
        const int seek = impl->s.seekLength();
        const size_t n = static_cast<size_t>(std::max(kMaxFeed, seek));
        std::unique_ptr<float[]> l(new float[n]()), r(new float[n]());
        // A first start and run at a stretch and a pitch shift, so every buffer the library grows on first use
        // (its peak list, the output map) has its working size before the audio thread sees it.
        // Noise, so the library's silence shortcut does not skip the work.
        std::minstd_rand noise(1);
        for (size_t i = 0; i < n; ++i) {
            l[i] = static_cast<float>(noise() % 2001) / 4000.0f - 0.25f;
            r[i] = static_cast<float>(noise() % 2001) / 4000.0f - 0.25f;
        }
        impl->s.setTransposeFactor(1.5f, static_cast<float>(8000.0 / sampleRate));
        impl->s.seek(Planar{l.get(), r.get()}, seek, 1.0);
        float ol[kChunk], orr[kChunk];
        for (int i = 0; i < 2 * impl->s.blockSamples() / kChunk; ++i)
            impl->s.process(Planar{l.get(), r.get()}, kChunk / 2, Planar{ol, orr}, kChunk);
        impl->s.reset();
        std::fill_n(l.get(), n, 0.0f);
        std::fill_n(r.get(), n, 0.0f);
        inLat_ = impl->s.inputLatency();
        outLat_ = impl->s.outputLatency();
        seekLen_ = seek;
        inL_ = std::move(l);
        inR_ = std::move(r);
        impl_ = std::move(impl);
        rate_ = sampleRate;
        return true;
    } catch (...) {
        return false;
    }
}

void HqStretcher::reset(double pitchRatio) noexcept {
    if (!impl_) return;
    impl_->s.reset();
    impl_->s.setTransposeFactor(static_cast<float>(pitchRatio), static_cast<float>(8000.0 / rate_));
}

void HqStretcher::seek(int frames, double rate) noexcept {
    if (!impl_) return;
    impl_->s.seek(Planar{inL_.get(), inR_.get()}, std::clamp(frames, 0, seekLen_), rate);
}

void HqStretcher::process(int inFrames, float* outL, float* outR) noexcept {
    if (!impl_) {
        std::fill_n(outL, kChunk, 0.0f);
        std::fill_n(outR, kChunk, 0.0f);
        return;
    }
    impl_->s.process(Planar{inL_.get(), inR_.get()}, std::clamp(inFrames, 0, kMaxFeed), Planar{outL, outR}, kChunk);
}

}  // namespace caw
