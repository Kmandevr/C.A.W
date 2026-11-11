// The reverser (fx-creative): "org.caw.reverser", each chunk of the input played backwards as the next one is recorded, crossfaded.
#include <cmath>

#include "builtin_fx_creative.h"

// Original code (C.A.W. is Apache-2.0). The technique is the "reverse delay" of time-segment processing (DAFX,
// 2nd ed., ch. 6): the input is cut into chunks, and while one is being recorded the one before it is read
// backwards. Each backwards read is a grain with an equal-power fade in and out (the overlap-add crossfade of
// granular processing, Roads, "Microsound", 2001), so the seams between chunks don't click.

namespace caw::fx {

namespace {

using creative::clampTo;

enum RevParam : uint32_t { kSync, kTime, kCrossfade, kMix, kRevCount };
constexpr double kMaxChunk = 2.0;  // seconds (a synced chunk longer than this is held here)

const ParamTable& revParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("sync", "Sync", 9.0, kSyncDivisions);  // a quarter note
        p.expo("time", "Time", 250.0, 20.0, 2000.0, "ms");
        p.num("crossfade", "Crossfade", 10.0, 0.0, 50.0, "%");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}

const ModuleDescriptor& revDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.reverser", "Reverser", revParams(), 0, 0);
    return d;
}

// One backwards read: started at a chunk boundary, it reads the chunk before it from its end to its start, then
// keeps going for its fade-out.
struct Grain {
    double elapsed = 0.0, length = 0.0, fade = 1.0;
    bool live = false;
    // Its gain at `elapsed` (fade in over `fade`, out over `fade` after `length`); 0 once past both.
    double gain() const noexcept {
        if (!live) return 0.0;
        if (elapsed < fade) return lib::fastSinCycles(0.25 * elapsed / fade);
        if (elapsed < length) return 1.0;
        const double e = elapsed - length;
        return e < fade ? lib::fastSinCycles(0.25 + 0.25 * e / fade) : 0.0;
    }
};

class Reverser final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return revDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        // A grain reads up to 2 x (chunk + fade) + 1 back: a chunk is at most kMaxChunk, its fade half that.
        return ring_.allocate(static_cast<size_t>(std::ceil(2.0 * 1.5 * kMaxChunk * sr)) + 8);
    }
    void clearState() noexcept override {
        ring_.clear();
        cur_ = prev_ = Grain{};
        sinceBoundary_ = 0.0;
        clock_.reset();
        lastChunk_ = -1;
        mix_.reset();
    }
    uint64_t idleFrames() const noexcept override {
        return static_cast<uint64_t>(2.0 * (chunkFrames_ * 1.5) + 0.05 * rate());
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const int sync = choice(kSync, at);
        synced_ = sync > 0;
        const double seconds = synced_ ? syncSeconds(sync) : param(kTime, at) * 0.001;
        chunkFrames_ = std::floor(clampTo(seconds, 0.005, kMaxChunk) * sr);
        fadeShare_ = clampTo(param(kCrossfade, at), 0.0, 50.0) * 0.01;
        double beat = 0.0;
        const bool playing = synced_ && beatAt(at, beat);
        clock_.control(playing, beat, kSyncWholeNotes[synced_ ? sync : 0] * 4.0, tempo(), sr);
        playing_ = playing;
        mix_.set(clampTo(param(kMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double dl = inL[i], dr = inR[i];
            ring_.write(dl, dr);
            // A boundary: the chunk number of the song changed (synced and playing), or a free chunk is full.
            bool boundary;
            if (playing_) {
                const auto chunk = static_cast<int64_t>(std::floor(clock_.pos));
                boundary = chunk != lastChunk_ && lastChunk_ >= 0;
                lastChunk_ = chunk;
                clock_.advance();
            } else {
                lastChunk_ = -1;
                boundary = sinceBoundary_ >= chunkFrames_;
            }
            if (boundary || sinceBoundary_ >= kMaxChunk * rate()) startGrain();
            sinceBoundary_ += 1.0;
            double wl = 0.0, wr = 0.0;
            for (Grain* g : {&cur_, &prev_}) {
                if (!g->live) continue;
                const double a = g->gain();
                if (a > 0.0) {
                    const double back = 2.0 * g->elapsed + 1.0;  // the grain's start frame minus 1 + elapsed
                    wl += a * ring_.readLinear(0, back);
                    wr += a * ring_.readLinear(1, back);
                }
                g->elapsed += 1.0;
                if (g->elapsed >= g->length + g->fade) g->live = false;
            }
            const double m = mix_.next();
            outL[i] = static_cast<float>(dl + (wl - dl) * m);
            outR[i] = static_cast<float>(dr + (wr - dr) * m);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(chunkFrames_ / rate() * 1000.0);
        out[3] = static_cast<float>(clampTo(sinceBoundary_ / std::max(1.0, chunkFrames_), 0.0, 1.0));
        out[4] = static_cast<float>(fadeShare_);
        out[5] = static_cast<float>(cur_.live ? clampTo(cur_.elapsed / std::max(1.0, cur_.length), 0.0, 1.0) : 0.0);
        return 6;
    }

private:
    // A boundary: the grain playing goes to its fade-out now, and a new one reads the chunk just recorded.
    void startGrain() noexcept {
        if (cur_.live) {
            prev_ = cur_;
            if (prev_.elapsed < prev_.length) prev_.length = prev_.elapsed;  // cut short: fade out from here
        }
        cur_.live = sinceBoundary_ >= 1.0;
        cur_.elapsed = 0.0;
        cur_.length = std::floor(std::min(sinceBoundary_, kMaxChunk * rate()));
        cur_.fade = std::max(1.0, std::floor(fadeShare_ * cur_.length));
        prev_.fade = std::max(1.0, std::min(prev_.fade, cur_.fade));  // both seams at the same speed
        sinceBoundary_ = 0.0;
    }

    creative::Ring ring_;
    creative::StepClock clock_;
    Grain cur_, prev_;
    Ramp mix_;
    bool synced_ = true, playing_ = false;
    int64_t lastChunk_ = -1;
    double sinceBoundary_ = 0.0, chunkFrames_ = 12000.0, fadeShare_ = 0.1;
};

}  // namespace

void registerReverser(ModuleRegistry& registry) { registry.add(revDescriptor(), &creative::make<Reverser>); }

}  // namespace caw::fx
