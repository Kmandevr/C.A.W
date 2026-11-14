// The output device callback's rendering: whole engine blocks through a BlockFifo (or straight, for a small odd period), interleaved out, the input pulled per block.
#pragma once

#include <chrono>
#include <cstdint>

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
        varying_ = false;
        useFifo_ = suits(period);
        latency_ = useFifo_ ? BlockFifo<kBlock>::maxLatency(period) : 0;
        meanHold_ = useFifo_ ? meanHold(period) : 0;
    }
    // Before the callback first runs, for a device that calls back with its own, varying sizes (AAudio given no
    // size): `typical` its usual size (the burst). The path is chosen per callback: the FIFO for a size that suits
    // it (whole blocks, or kFifoFrom and over) or while it still holds frames; straight only once it is empty, so a
    // switch never drops or repeats a frame. The most frames held back is then a block short of one, whatever the
    // sizes; the mean hold is the typical size's.
    void openVarying(int typical) noexcept {
        fifo_.flush();
        varying_ = true;
        useFifo_ = suits(typical);
        latency_ = kBlock - 1;
        meanHold_ = useFifo_ ? meanHold(typical) : 0;
    }
    bool usesFifo() const noexcept { return useFifo_; }  // varying sizes: the last callback's path
    // The most frames held back (at most kBlock - 1): what the input bridge's fill must cover, since a callback
    // renders, and pulls the input for, up to that many frames more than it plays.
    int latency() const noexcept { return latency_; }
    // The frames held back on average, rounded: how far the engine runs ahead of what plays, for the latency
    // figures that align recordings (the hold steps through multiples of gcd(period, kBlock) from 0 to
    // kBlock - gcd, evenly, so the mean is (kBlock - gcd) / 2).
    int meanHold() const noexcept { return meanHold_; }
    static constexpr int meanHold(int period) noexcept {
        int a = period > 0 ? period : kBlock, b = kBlock;
        while (b) {
            const int t = a % b;
            a = b;
            b = t;
        }
        return (kBlock - a + 1) / 2;
    }
    int held() const noexcept { return fifo_.held(); }
    // The Benchmark's live run: time Engine::process apart (the rest of a callback is the FIFO and the input
    // bridge: its "device_io" part). takeProcessNs returns the time since the last take and starts again.
    void timeProcess(bool on) noexcept { timeProcess_ = on; }
    int64_t takeProcessNs() noexcept {
        const int64_t v = processNs_;
        processNs_ = 0;
        return v;
    }

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
            if (timeProcess_) [[unlikely]] {  // the Benchmark's live run: process() apart from the device I/O
                const auto t0 = std::chrono::steady_clock::now();
                e.process(l, r, m);
                processNs_ += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count();
            } else {
                e.process(l, r, m);
            }
            live.afterCallback(l, r, m);  // the latency ping
            rendered += m;
        };
        if (varying_) useFifo_ = suits(frames) || fifo_.held() > 0;
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
    bool useFifo_ = true, varying_ = false, timeProcess_ = false;
    int64_t processNs_ = 0;
    int latency_ = 0, meanHold_ = 0;
    float l_[kChunk] = {}, r_[kChunk] = {};
};

}  // namespace caw
