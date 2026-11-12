// Fixed-block rendering for a device callback of any size: whole engine blocks, the frames left over kept for the next callback.
#pragma once

#include <algorithm>
#include <cstdint>

namespace caw {

// The device side of the owner's fixed-block idea (2026-11-12, docs/decisions.md): a device callback of any size
// (441, 960, 1920 frames: Bluetooth, a background route) takes its frames from here, and the engine only ever
// renders whole blocks of kFrames, so it renders the same blocks on every route as in an export. The storage is
// inside the object (no allocation), and nothing here locks; one thread (the device's callback) uses it.
//
// A callback that is a whole number of blocks while nothing is held over passes straight through, so a device
// whose period is a multiple of the block adds no latency. Otherwise at most kFrames - 1 frames wait here between
// callbacks: maxLatency() is what the device's reported output latency adds.
template <int kFrames>
class BlockFifo {
public:
    static_assert(kFrames > 0, "a block has frames");
    static constexpr int kBlockFrames = kFrames;

    // Frames rendered and not yet played (0 .. kFrames - 1).
    int held() const noexcept { return held_; }
    // The most a device with callbacks of `period` frames waits here: 0 when every callback is whole blocks.
    static int maxLatency(int period) noexcept { return period > 0 && period % kFrames == 0 ? 0 : kFrames - 1; }
    // Drops what is held (a device open, a Play or a seek: the new position starts on the next callback's
    // first frame instead of after old audio).
    void flush() noexcept { held_ = at_ = 0; }

    // Fills `frames` frames of left and right. `render(l, r, n)` renders n frames, a whole number of blocks (at
    // most `most` at once), into the given buffers: straight into the output where whole blocks fit, into the
    // held block for the last part.
    template <class Render>
    void pull(float* left, float* right, int frames, int most, Render&& render) noexcept {
        if (frames <= 0) return;
        int done = 0;
        // What the last callback left.
        const int fromHeld = std::min(held_, frames);
        std::copy_n(heldL_ + at_, fromHeld, left);
        std::copy_n(heldR_ + at_, fromHeld, right);
        held_ -= fromHeld;
        at_ = held_ ? at_ + fromHeld : 0;
        done += fromHeld;
        // Whole blocks, straight into the output.
        const int chunk = std::max(kFrames, most - most % kFrames);
        while (frames - done >= kFrames) {
            const int n = std::min(chunk, (frames - done) - (frames - done) % kFrames);
            render(left + done, right + done, n);
            done += n;
        }
        // The tail: one more block, the rest of it held for the next callback.
        if (done < frames) {
            render(heldL_, heldR_, kFrames);
            const int n = frames - done;
            std::copy_n(heldL_, n, left + done);
            std::copy_n(heldR_, n, right + done);
            at_ = n;
            held_ = kFrames - n;
        }
    }

private:
    float heldL_[kFrames] = {}, heldR_[kFrames] = {};
    int held_ = 0, at_ = 0;
};

}  // namespace caw
