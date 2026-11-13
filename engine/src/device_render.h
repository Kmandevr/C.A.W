// The output device callback's rendering: whole engine blocks through a BlockFifo (or straight, for a small odd period), interleaved out, the input pulled per block.
#pragma once

#include "audio_input.h"
#include "block_fifo.h"
#include "engine.h"

namespace caw {

// What engine/platform/audio_miniaudio.cpp's output callback (always a playback-only device) does with the engine, here so tests drive the
// same code. One thread (the device's callback) uses it after open(); nothing here allocates or locks.
//
// The FIFO is not flushed on a Play, Stop or seek (2026-11-12 audio review): the engine has already rendered the
// frames it holds and moved on, so dropping them would jump the waveform. They are at most 63 frames (1.3 ms at
// 48 kHz); a Stop's fade and a Play's own start cover them.
//
// A small period that isn't whole blocks bypasses the FIFO (suits()): at 96 frames the FIFO would render 128 and
// 64 frames by turns, a peak of 1.33 times the callback's budget, for no gain the device can hear.
class DeviceRender {
public:
    static constexpr int kChunk = 512;  // frames rendered at most at once (the scratch buffers' size)
    // The FIFO is used from this many frames a callback, or at any period that is whole blocks. At 4 blocks and
    // over, a callback renders at most (period + 63) / period of its frames: 1.25 times at 257, 1.14 at 441.
    static constexpr int kFifoFrom = 4 * kBlock;
    static constexpr bool suits(int period) noexcept { return period > 0 && (period % kBlock == 0 || period >= kFifoFrom); }

    // Before the callback first runs (a device open): the callback's fixed size. Starts empty.
    void open(int period) noexcept {
        fifo_.flush();
        useFifo_ = suits(period);
        latency_ = useFifo_ ? BlockFifo<kBlock>::maxLatency(period) : 0;
    }
    bool usesFifo() const noexcept { return useFifo_; }
    int latency() const noexcept { return latency_; }  // the most frames held back, for the output latency
    int held() const noexcept { return fifo_.held(); }

    // Fills `frames` interleaved stereo frames of `out` from the engine. Returns the frames the engine rendered
    // (more or fewer than `frames` through the FIFO), for Engine::reportLoad. `input(m, channels)` gives the
    // input for the next m frames rendered (at most kChunk; interleaved, `channels` set; null for none): it is
    // asked once per render, so the input stays in step with the frames rendered, not the frames played.
    template <class Input>
    int render(Engine& e, float* out, int frames, Input&& input) noexcept {
        LiveAudio& live = e.liveAudio();
        int done = 0, rendered = 0;
        auto engineRender = [&](float* l, float* r, int m) {
            int ch = 0;
            const float* in = input(m, ch);
            live.beginCallback(in, in ? ch : 0, m);  // monitoring and recording
            e.process(l, r, m);
            live.afterCallback(l, r, m);  // the latency ping
            rendered += m;
        };
        while (done < frames) {
            const int n = frames - done < kChunk ? frames - done : kChunk;
            if (useFifo_) fifo_.pull(l_, r_, n, kChunk, engineRender);
            else engineRender(l_, r_, n);
            for (int i = 0; i < n; ++i) {
                out[(done + i) * 2] = l_[i];
                out[(done + i) * 2 + 1] = r_[i];
            }
            done += n;
        }
        return rendered;
    }
    // With no input.
    int render(Engine& e, float* out, int frames) noexcept {
        return render(e, out, frames, [](int, int& ch) -> const float* {
            ch = 0;
            return nullptr;
        });
    }

private:
    BlockFifo<kBlock> fifo_;
    bool useFifo_ = true;
    int latency_ = 0;
    float l_[kChunk] = {}, r_[kChunk] = {};
};

}  // namespace caw
