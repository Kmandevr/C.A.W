// The tape stop (fx-creative): "org.caw.tapestop", the tape motor slowing to a halt and spinning back up, timed free or to the song.
#include <cmath>

#include "builtin_fx_creative.h"

// Original code (C.A.W. is Apache-2.0). The technique is a variable-speed read of a recording buffer (the
// "varispeed" playback of DAFX, 2nd ed., ch. 6, "Time-segment processing": a read pointer moving at a speed v
// through a delay line gives pitch v and a growing delay); the speed curve and the hand-back to the live input
// are this file's own.

namespace caw::fx {

namespace {

using creative::clampTo;

enum TapeParam : uint32_t { kStop, kStopTime, kStopSync, kStartTime, kStartSync, kCurve, kMix, kTapeCount };
constexpr double kMaxSeconds = 8.0;   // the longest stop or start (a synced one is held there)
constexpr double kHandBack = 0.012;   // the crossfade from the lagging tape back to the live input, seconds

const ParamTable& tapeParams() {
    static const ParamTable t = [] {
        ParamTable p;
        // The trigger: at or above 0.5 the tape stops, below it plays (a knob so an LFO or a lane can trigger it;
        // the UI's hold-to-stop button sets it while held).
        p.num("stop", "Stop", 0.0, 0.0, 1.0).smoothingFrames = 0;
        p.expo("stop_time", "Stop time", 600.0, 20.0, 8000.0, "ms");
        p.pick("stop_sync", "Stop sync", 0.0, kSyncDivisions);
        p.expo("start_time", "Start time", 200.0, 1.0, 8000.0, "ms");
        p.pick("start_sync", "Start sync", 0.0, kSyncDivisions);
        p.num("curve", "Curve", 0.0, -1.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}

const ModuleDescriptor& tapeDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.tapestop", "Tape stop", tapeParams(), 0, 0);
    return d;
}

// b^p for b in [0, 1] (0 at 0), per sample: fastExp and fastLog, about 1e-9 off.
double powerOf(double b, double p) noexcept { return b <= 0.0 ? 0.0 : (b >= 1.0 ? 1.0 : lib::fastExp(p * lib::fastLog(b))); }

enum State : int { kPlaying, kStopping, kStopped, kStarting };

class TapeStop final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return tapeDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        return ring_.allocate(static_cast<size_t>(std::ceil((kMaxSeconds + 0.5) * sr)));
    }
    void clearState() noexcept override {
        ring_.clear();
        // A stopped tape stays stopped through sleep (its output was silence anyway), so new input doesn't play
        // another slow-down; anything else is back at speed with no lag.
        const bool stopped = state_ == kStopped;
        state_ = stopped ? kStopped : kPlaying;
        x_ = stopped ? 1.0 : 0.0, speed_ = stopped ? 0.0 : 1.0, lag_ = 0.0, hand_ = 0.0;
        mix_.reset();
    }
    uint64_t idleFrames() const noexcept override {
        return static_cast<uint64_t>(lag_) + static_cast<uint64_t>(0.05 * rate());
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        auto seconds = [&](uint32_t time, uint32_t sync) {
            const int s = choice(sync, at);
            const double v = s > 0 ? syncSeconds(s) : param(time, at) * 0.001;
            return clampTo(v, 0.001, kMaxSeconds);
        };
        stopFrames_ = seconds(kStopTime, kStopSync) * sr;
        startFrames_ = seconds(kStartTime, kStartSync) * sr;
        // The curve's power: 0 a straight ramp of speed; above 0 the speed changes fast at first and drags at the
        // end, below 0 it holds on and then falls (or rises) late.
        power_ = detPow(4.0, clampTo(param(kCurve, at), -1.0, 1.0));
        const bool stop = param(kStop, at) >= 0.5;
        if (stop && (state_ == kPlaying || state_ == kStarting)) {
            // From the speed now: (1 - x)^p = speed.
            x_ = 1.0 - detPow(clampTo(speed_, 0.0, 1.0), 1.0 / power_);
            state_ = kStopping;
            hand_ = 0.0;
        } else if (!stop && (state_ == kStopping || state_ == kStopped)) {
            if (state_ == kStopped) lag_ = 0.0;  // the motor starts on the tape under the head now
            // From the speed now: 1 - (1 - x)^p = speed.
            x_ = 1.0 - detPow(clampTo(1.0 - speed_, 0.0, 1.0), 1.0 / power_);
            state_ = kStarting;
        }
        mix_.set(clampTo(param(kMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const double handStep = 1.0 / (kHandBack * rate());
        for (uint32_t i = 0; i < n; ++i) {
            const double dl = inL[i], dr = inR[i];
            ring_.write(dl, dr);
            switch (state_) {
                case kStopping:
                    x_ += 1.0 / stopFrames_;
                    if (x_ >= 1.0) x_ = 1.0, state_ = kStopped;
                    speed_ = powerOf(1.0 - x_, power_);
                    break;
                case kStarting:
                    x_ += 1.0 / startFrames_;
                    if (x_ >= 1.0) x_ = 1.0, state_ = kPlaying, hand_ = 1.0;  // at speed: hand back to the input
                    speed_ = 1.0 - powerOf(1.0 - x_, power_);
                    break;
                case kStopped: speed_ = 0.0; break;
                default: speed_ = 1.0; break;
            }
            lag_ = clampTo(lag_ + 1.0 - speed_, 0.0, ring_.reach());
            double wl = 0.0, wr = 0.0;
            if (state_ != kStopped) {
                // The level falls with the last 5 % of the speed, as the signal leaves the head.
                const double g = speed_ < 0.05 ? speed_ * 20.0 : 1.0;
                wl = ring_.read(0, lag_) * g;
                wr = ring_.read(1, lag_) * g;
            }
            if (state_ == kPlaying && lag_ > 0.0) {
                // Back at speed with the tape behind the input: crossfade to the live input, then drop the lag.
                hand_ -= handStep;
                if (hand_ <= 0.0) hand_ = 0.0, lag_ = 0.0;
                const double h = hand_ * hand_ * (3.0 - 2.0 * hand_);
                wl = dl + (wl - dl) * h;
                wr = dr + (wr - dr) * h;
            }
            const double m = mix_.next();
            outL[i] = static_cast<float>(dl + (wl - dl) * m);
            outR[i] = static_cast<float>(dr + (wr - dr) * m);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(speed_);
        out[3] = static_cast<float>(state_);
        out[4] = static_cast<float>(lag_ / rate() * 1000.0);
        out[5] = static_cast<float>(state_ == kStopping || state_ == kStarting ? x_ : (state_ == kStopped ? 1.0 : 0.0));
        out[6] = static_cast<float>(stopFrames_ / rate());
        out[7] = static_cast<float>(startFrames_ / rate());
        return 8;
    }

private:
    creative::Ring ring_;
    Ramp mix_;
    int state_ = kPlaying;
    double x_ = 0.0, speed_ = 1.0, lag_ = 0.0, hand_ = 0.0, power_ = 1.0;
    double stopFrames_ = 28800.0, startFrames_ = 9600.0;
};

}  // namespace

void registerTapeStop(ModuleRegistry& registry) { registry.add(tapeDescriptor(), &creative::make<TapeStop>); }

}  // namespace caw::fx
