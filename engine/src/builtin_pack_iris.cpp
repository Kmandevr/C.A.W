// Iris (org.caw.pack.spectral, the AutoStacc beta pack): spectral effects on a streaming STFT: freeze (its frozen spectrum painted through the display and the state), blur, shift and gate.
#include "builtin_effects.h"
#include "builtin_pack.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <new>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/fastmath.hpp"
#include "component_chain.h"
#include "fx_clean_dsp.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0). Preen's streaming STFT (fx_clean_dsp.h: both sides in one FFT, sqrt-Hann,
// a quarter-window hop): `quality` Eco 1,024, Normal 2,048, High 4,096 points at 44.1/48 kHz (scaled with the rate),
// and the latency is exactly that window, reported per setting (VariableLatency). Each frame, per side and bin:
// - Gate: a bin under `gate` (dB of a full-scale sine's bin; at -100 off) drops by `gate_range`.
// - Blur: each bin's magnitude follows a one-pole over up to 3 s (`blur` 0..1, exponential; 0 off), its phase kept.
// - Freeze: turning `freeze` on captures the next frame's magnitudes (after gate and blur); the frozen layer is
//   that spectrum times the painted curve (64 log bands 20 Hz-20 kHz, -60..+12 dB, interpolated across bins, scaled
//   by `paint`) with each bin's phase advanced as its centre frequency's and dithered by `drift`, faded in over
//   `fade` (and out again when it turns off). The painted curve and the captured spectrum are the component's state
//   (saveState/loadState): a UI paints by writing the state; a state loaded while frozen plays without a new capture.
// - Shift: every bin moved by `shift` Hz (rounded to whole bins), its phase advanced to match the new bin.
// - `mix` (in the bin domain, so the dry sound is aligned) and `output`.
// Each stage at its neutral value costs nothing. The phase dither uses a shared 256-entry table (built at
// registration) and a seeded generator, so the same project gives the same bits.

namespace caw::fx {

namespace {

using clean::Bins;
using clean::clampd;

constexpr uint32_t kBands = 64;
constexpr uint32_t kMagic = 0x53495249u;  // "IRIS"
constexpr std::string_view kTiers[] = {"Eco", "Normal", "High"};

enum IrParam : uint32_t {
    irQuality, irFreeze, irFade, irDrift, irPaint, irBlur, irShift, irGate, irGateRange, irMix, irOutput, irCount
};

ParameterDescriptor& byHand(ParameterDescriptor& p) {
    p.automatable = p.modulatable = p.midiMappable = false;
    return p;
}

const ParamTable& irisParams() {
    static const ParamTable t = [] {
        ParamTable p;
        byHand(p.pick("quality", "Quality", 1.0, kTiers));
        p.pick("freeze", "Freeze", 0.0, kOffOn);
        p.expo("fade", "Fade", 200.0, 10.0, 4000.0, "ms");
        p.num("drift", "Drift", 0.3, 0.0, 1.0);
        p.num("paint", "Paint", 1.0, 0.0, 1.0);
        p.num("blur", "Blur", 0.0, 0.0, 1.0);
        p.num("shift", "Shift", 0.0, -2000.0, 2000.0, "Hz");
        p.num("gate", "Gate", -100.0, -100.0, 0.0, "dB");
        p.num("gate_range", "Gate range", 60.0, 0.0, 80.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}

// The largest state: the header, the paint and both sides' bins (magnitude and frequency in bins) at the largest
// window (16,384 above 140 kHz).
constexpr uint32_t kMaxStateBins = 16384 / 2 + 1;
constexpr uint32_t kHeader = 20;
constexpr uint32_t stateBytes(uint32_t bins) { return kHeader + 4 * kBands + 16 * bins; }

const ModuleDescriptor& irisDescriptor() {
    static const ModuleDescriptor d = [] {
        ModuleDescriptor x = withCpu(effectDescriptor("org.caw.pack.spectral", "Iris", irisParams(),
                                                      clean::tierWindow(1, false, 48000), 4096),
                                     CpuClass::Heavy);
        x.maxStateBytes = stateBytes(kMaxStateBins);
        return x;
    }();
    return d;
}

// 256 unit phasors around the circle (the drift's dither), shared and read only.
struct Phasors {
    float c[256], s[256];
};
const Phasors& phasors() noexcept {
    static const Phasors t = [] {
        Phasors x{};
        for (int k = 0; k < 256; ++k) {
            x.c[k] = static_cast<float>(detCos(kTwoPi * (k - 128) / 256.0));
            x.s[k] = static_cast<float>(detSin(kTwoPi * (k - 128) / 256.0));
        }
        return x;
    }();
    return t;
}

class Iris final : public EffectBase, public VariableLatency {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return irisDescriptor(); }
    uint32_t latencyFor(const double* values, uint32_t count) const noexcept override {
        const int q = count > irQuality ? static_cast<int>(values[irQuality] + 0.5) : 1;
        return clean::tierWindow(q, false, rate());
    }
    uint64_t idleFrames() const noexcept override {
        if (captured_ && (freeze_ || fz_ > 0.0)) return ~0ull >> 2;  // a frozen spectrum plays on over silence
        return stft_.size() + static_cast<uint64_t>((7.0 * blurTime_ + 0.05) * rate());
    }

    uint32_t stateVersion() const noexcept override { return 1; }
    bool saveState(uint8_t* dst, uint32_t capacity, uint32_t& written) const noexcept override {
        written = 0;
        for (int attempt = 0; attempt < 4; ++attempt) {  // a seqlock: the audio thread writes on a capture
            const uint32_t g0 = agen_.load(std::memory_order_acquire);
            if (g0 & 1u) continue;
            const bool captured = savedCaptured_.load(std::memory_order_relaxed);
            const uint32_t bins = captured ? savedBins_ : 0;
            bool flat = true;
            for (float p : paint_) flat = flat && p == 0.0f;
            if (flat && !captured) return true;  // nothing painted or captured: no state
            const uint32_t need = stateBytes(bins);
            if (!dst || capacity < need) return false;
            const float hz = static_cast<float>(rate());
            const uint32_t head[5] = {kMagic, kBands, bins, savedN_, 0};
            std::memcpy(dst, head, kHeader);
            std::memcpy(dst + 16, &hz, 4);
            std::memcpy(dst + kHeader, paint_, 4 * kBands);
            if (bins) {
                std::memcpy(dst + kHeader + 4 * kBands, frozen_[0].data(), 4ull * bins);
                std::memcpy(dst + kHeader + 4 * kBands + 4ull * bins, frozen_[1].data(), 4ull * bins);
                std::memcpy(dst + kHeader + 4 * kBands + 8ull * bins, freq_[0].data(), 4ull * bins);
                std::memcpy(dst + kHeader + 4 * kBands + 12ull * bins, freq_[1].data(), 4ull * bins);
            }
            std::atomic_thread_fence(std::memory_order_acquire);
            if (agen_.load(std::memory_order_relaxed) == g0) {
                written = need;
                return true;
            }
        }
        return false;
    }
    // Checked before anything is taken: the header, the band count, a window that is a power of two from 256 to
    // 65,536 whose bins it holds, the exact size, and finite values (paint held to -60..+12 dB, magnitudes to
    // 0..1e7, frequencies to -1..bins). The audio thread takes it at its next frame (resampled to its window if that differs).
    bool loadState(const uint8_t* src, uint32_t size, uint32_t version) noexcept override {
        if (version != 1) return false;
        if (size == 0) return true;
        if (!src || size < kHeader + 4 * kBands) return false;
        uint32_t head[5];
        std::memcpy(head, src, kHeader);
        const uint32_t bins = head[2], n = head[3];
        if (head[0] != kMagic || head[1] != kBands || bins > maxBins_) return false;
        if (bins && (n < 256 || n > 65536 || (n & (n - 1)) != 0 || bins != n / 2 + 1)) return false;
        if (size != stateBytes(bins)) return false;
        float paint[kBands];
        std::memcpy(paint, src + kHeader, 4 * kBands);
        for (float& p : paint) p = p == p ? std::clamp(p, -60.0f, 12.0f) : 0.0f;
        gen_.fetch_add(1, std::memory_order_acq_rel);  // odd: being written
        std::memcpy(pendingPaint_, paint, sizeof paint);
        for (int c = 0; c < 2 && bins; ++c) {
            std::memcpy(pending_[c].data(), src + kHeader + 4 * kBands + 4ull * bins * c, 4ull * bins);
            std::memcpy(pendingFreq_[c].data(), src + kHeader + 4 * kBands + 4ull * bins * (2 + c), 4ull * bins);
            for (uint32_t k = 0; k < bins; ++k) {
                float& m = pending_[c][k];
                m = m == m ? std::clamp(m, 0.0f, 1e7f) : 0.0f;
                float& f = pendingFreq_[c][k];
                f = f == f ? std::clamp(f, -1.0f, static_cast<float>(bins)) : static_cast<float>(k);
            }
        }
        pendingBins_ = bins, pendingN_ = n;
        gen_.fetch_add(1, std::memory_order_acq_rel);  // even: ready
        return true;
    }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        maxN_ = clean::maxWindow(sr);
        maxBins_ = maxN_ / 2 + 1;
        if (!stft_.prepare(maxN_)) return false;
        try {
            for (int c = 0; c < 2; ++c) {
                frozen_[c].assign(maxBins_, 0.0f);
                pending_[c].assign(maxBins_, 0.0f);
                blur_[c].assign(maxBins_, 0.0f);
                for (auto* v : {&pc_[c], &rc_[c], &bc_[c]}) v->assign(maxBins_, 1.0f);
                for (auto* v : {&ps_[c], &rs_[c], &bs_[c]}) v->assign(maxBins_, 0.0f);
                freq_[c].assign(maxBins_, 0.0f);
                pendingFreq_[c].assign(maxBins_, 0.0f);
            }
            paintGain_.assign(maxBins_, 1.0f);
            for (auto& d : dry_) d.assign(maxBins_, 0.0);
            for (auto& d : prev_) d.assign(maxBins_, 0.0);
            dryR_[0] = dry_[0].data(), dryI_[0] = dry_[1].data(), dryR_[1] = dry_[2].data(), dryI_[1] = dry_[3].data();
            tmp_.assign(4 * static_cast<size_t>(maxBins_), 0.0);  // the shift's scratch, or resampling's (2 x 2 float arrays)
            // Each tier's bins: the band (0..63) and the position between band centres (for the paint).
            for (int t = 0; t < 3; ++t) {
                const uint32_t n = clean::tierWindow(t, false, sr), bins = n / 2 + 1;
                band_[t].assign(bins, 0);
                pos_[t].assign(bins, 0.0f);
                for (uint32_t k = 0; k < bins; ++k) {
                    const double hz = std::max(1.0, k * sr / n);
                    const double b = kBands * std::log(hz / 20.0) / std::log(1000.0);
                    band_[t][k] = static_cast<uint8_t>(std::clamp(b, 0.0, kBands - 1.0));
                    pos_[t][k] = static_cast<float>(std::clamp(b - 0.5, 0.0, kBands - 1.0));
                }
            }
        } catch (...) {
            return false;
        }
        n_ = 0;
        return true;
    }
    void clearState() noexcept override {
        stft_.clear();
        for (auto& b : blur_) std::fill(b.begin(), b.end(), 0.0f);
        for (int c = 0; c < 2; ++c) std::fill(bc_[c].begin(), bc_[c].end(), 1.0f), std::fill(bs_[c].begin(), bs_[c].end(), 0.0f);
        for (auto& d : prev_) std::fill(d.begin(), d.end(), 0.0);
        for (float& l : live_) l = -120.0f;
        fz_ = 0.0;
        wasFrozen_ = false;
        skipCapture_ = captured_;  // a reset keeps a frozen spectrum (it is state): the freeze plays it again
        capture_ = false;
        quarter_ = 0;
        rng_ = 0x2545F491u;
        first_ = true;
    }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const uint32_t n = clean::tierWindow(std::clamp(choice(irQuality, at), 0, 2), false, sr);
        if (n != n_) {
            const uint32_t old = n_;
            n_ = n;
            tier_ = std::clamp(choice(irQuality, at), 0, 2);
            stft_.setSize(n);
            for (auto& b : blur_) std::fill(b.begin(), b.end(), 0.0f);
            if (captured_ && old) resampleFrozen(old, n), frozenBandsFrom(n / 2 + 1, n / kPi);
            paintFor_ = -1.0;
        }
        if (first_ || !knobsUnchanged(knobs_, irCount, at)) {
            const double hop = (n_ / 4) / sr;
            freeze_ = on(irFreeze, at);
            fadeStep_ = hop / (clampd(param(irFade, at), 10.0, 4000.0) * 0.001);
            drift_ = static_cast<float>(clampd(param(irDrift, at), 0.0, 1.0));
            paintAmt_ = clampd(param(irPaint, at), 0.0, 1.0);
            const double blur = clampd(param(irBlur, at), 0.0, 1.0);
            blurTime_ = blur > 0.0 ? 0.02 * detExp(blur * std::log(150.0)) : 0.0;
            blurA_ = blur > 0.0 ? static_cast<float>(detExp(-hop / blurTime_)) : 0.0f;
            shiftBins_ = static_cast<int>(std::lround(clampd(param(irShift, at), -2000.0, 2000.0) * n_ / sr));
            gateDb_ = clampd(param(irGate, at), -100.0, 0.0);
            const double ref = n_ / kPi;  // a full-scale sine's bin with the sqrt-Hann window
            const double thr = gateDb_ <= -100.0 ? 0.0 : ref * lib::dbToGain(gateDb_);
            gate2_ = thr * thr;
            gateFloor_ = lib::dbToGain(-clampd(param(irGateRange, at), 0.0, 80.0));
            mix_ = clampd(param(irMix, at), 0.0, 1.0);
            out_ = lib::dbToGain(param(irOutput, at));
        }
        first_ = false;
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        stft_.process(inL, inR, outL, outR, n, [this](Bins& b) { frame(b); });
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(fz_);
        out[3] = captured_ ? 1.0f : 0.0f;
        out[4] = static_cast<float>(n_);
        out[5] = static_cast<float>(1000.0 * n_ / rate());
        out[6] = static_cast<float>(shiftBins_ * rate() / std::max<uint32_t>(1, n_));
        out[7] = static_cast<float>(gateDb_);
        out[8] = static_cast<float>(kBands);
        for (uint32_t b = 0; b < kBands; ++b) {
            out[9 + b] = live_[b];
            out[9 + kBands + b] = frozenBands_[b];
            out[9 + 2 * kBands + b] = paint_[b];
        }
        return 9 + 3 * kBands;
    }

private:
    // One frame: take a loaded state, then gate, blur, freeze, shift and mix, per side.
    void frame(Bins& b) noexcept {
        const uint32_t count = b.count;
        takeLoaded();
        // The dry bins, for the mix and the display (and the last frame's, for a capture's frequencies).
        for (int k = 0; k < 4; ++k) dry_[k].swap(prev_[k]);
        dryR_[0] = dry_[0].data(), dryI_[0] = dry_[1].data(), dryR_[1] = dry_[2].data(), dryI_[1] = dry_[3].data();
        std::memcpy(dryR_[0], b.lr, 8ull * count), std::memcpy(dryI_[0], b.li, 8ull * count);
        std::memcpy(dryR_[1], b.rr, 8ull * count), std::memcpy(dryI_[1], b.ri, 8ull * count);
        if (paintFor_ != paintAmt_ || paintDirty_) updatePaint(count);
        // Freeze: a capture on the rising edge (unless a loaded or kept spectrum waits), then the fade.
        if (freeze_ && !wasFrozen_) {
            if (skipCapture_ && captured_) skipCapture_ = false;
            else capture_ = true;
        }
        wasFrozen_ = freeze_;
        double* re[2] = {b.lr, b.rr};
        double* im[2] = {b.li, b.ri};
        const double ref = static_cast<double>(b.n) / kPi;
        const float a = blurA_;
        for (int c = 0; c < 2; ++c) {
            double* x = re[c];
            double* y = im[c];
            if (gate2_ > 0.0)
                for (uint32_t k = 0; k < count; ++k)
                    if (x[k] * x[k] + y[k] * y[k] < gate2_) x[k] *= gateFloor_, y[k] *= gateFloor_;
            if (a > 0.0f) {
                // Each bin's magnitude follows, its phase the input's; where the input has gone quiet the phase
                // runs on at the bin's centre frequency, so a tail keeps sounding.
                float* m = blur_[c].data();
                float* pc = bc_[c].data();
                float* ps = bs_[c].data();
                const double quiet = ref * 1e-6;
                for (uint32_t k = 0; k < count; ++k) {
                    const double mag = std::sqrt(x[k] * x[k] + y[k] * y[k]);
                    m[k] = a * m[k] + (1.0f - a) * static_cast<float>(mag);
                    if (mag > quiet) {
                        pc[k] = static_cast<float>(x[k] / mag), ps[k] = static_cast<float>(y[k] / mag);
                    } else {
                        quarterTurns(pc[k], ps[k], k);
                    }
                    x[k] = m[k] * pc[k], y[k] = m[k] * ps[k];
                }
            }
        }
        // A capture waits for a frame over -80 dB after another (silence, a start), so each bin's frequency is
        // measured from two frames of sound.
        double loudest = 0.0, before = 0.0;
        if (capture_)
            for (int c = 0; c < 2; ++c)
                for (uint32_t k = 0; k < count; ++k) {
                    loudest = std::max(loudest, re[c][k] * re[c][k] + im[c][k] * im[c][k]);
                    before = std::max(before, prev_[2 * c][k] * prev_[2 * c][k] + prev_[2 * c + 1][k] * prev_[2 * c + 1][k]);
                }
        if (capture_ && std::min(loudest, before) > ref * ref * 1e-8) {
            capture_ = false;
            agen_.fetch_add(1, std::memory_order_acq_rel);
            for (int c = 0; c < 2; ++c)
                for (uint32_t k = 0; k < count; ++k) {
                    const double mag = std::sqrt(re[c][k] * re[c][k] + im[c][k] * im[c][k]);
                    frozen_[c][k] = static_cast<float>(mag);
                    pc_[c][k] = mag > 0.0 ? static_cast<float>(re[c][k] / mag) : 1.0f;
                    ps_[c][k] = mag > 0.0 ? static_cast<float>(im[c][k] / mag) : 0.0f;
                    // The bin's frequency from its phase advance over the hop (a phase vocoder's), in bins.
                    const double* pr = prev_[2 * c].data();
                    const double* pi = prev_[2 * c + 1].data();
                    const double* dr = dry_[2 * c].data();
                    const double* di = dry_[2 * c + 1].data();
                    const double ar = dr[k] * pr[k] + di[k] * pi[k], ai = di[k] * pr[k] - dr[k] * pi[k];
                    double dev = 0.0;  // no frame before (a start): the bin's centre
                    if (ar != 0.0 || ai != 0.0) {
                        dev = std::atan2(ai, ar) - 0.5 * kPi * (k & 3u);
                        dev -= kTwoPi * std::floor((dev + kPi) / kTwoPi);
                    }
                    freq_[c][k] = static_cast<float>(k + dev * 2.0 / kPi);
                }
            updateRotation(count);
            captured_ = true;
            savedBins_ = count, savedN_ = b.n;
            savedCaptured_.store(true, std::memory_order_relaxed);
            agen_.fetch_add(1, std::memory_order_acq_rel);
            frozenBandsFrom(count, ref);
        }
        fz_ = std::clamp(fz_ + (freeze_ && captured_ ? fadeStep_ : -fadeStep_), 0.0, 1.0);
        if (fz_ > 0.0 && captured_) freezeLayer(re, im, count);
        // Shift: bins move by s; each moved bin's phase turns a further s quarter turns a frame.
        const int s = shiftBins_;
        if (s != 0) {
            quarter_ = (quarter_ + s) & 3;
            for (int c = 0; c < 2; ++c) shift(re[c], im[c], count, s);
        }
        // The live levels (the input, before the freeze) for the display: each band's strongest bin.
        for (uint32_t k = 0; k < kBands; ++k) liveMax_[k] = 0.0;
        // Mix with the dry bins (the STFT kept them aligned) and the output gain.
        const double w = mix_ * out_, d = (1.0 - mix_) * out_;
        for (int c = 0; c < 2; ++c)
            for (uint32_t k = 0; k < count; ++k) {
                re[c][k] = w * re[c][k] + d * dryR_[c][k];
                im[c][k] = w * im[c][k] + d * dryI_[c][k];
            }
        for (uint32_t k = 0; k < count; ++k) {
            const uint32_t band = band_[tier_][k];
            liveMax_[band] = std::max(liveMax_[band], std::max(dryR_[0][k] * dryR_[0][k] + dryI_[0][k] * dryI_[0][k],
                                                               dryR_[1][k] * dryR_[1][k] + dryI_[1][k] * dryI_[1][k]));
        }
        for (uint32_t k = 0; k < kBands; ++k) {
            const float db = static_cast<float>(10.0 * std::log10(liveMax_[k] / (ref * ref) + 1e-12));
            live_[k] = std::max(-120.0f, db > live_[k] ? db : live_[k] - 1.5f);
        }
        // DC and Nyquist stay real on each side (the two sides share one FFT).
        b.li[0] = b.ri[0] = b.li[count - 1] = b.ri[count - 1] = 0.0;
    }
    void freezeLayer(double* re[2], double* im[2], uint32_t count) noexcept {
        const Phasors& t = phasors();
        const float g = static_cast<float>(fz_), keep = 1.0f - g, drift = drift_ * 127.0f;
        for (int c = 0; c < 2; ++c) {
            float* pc = pc_[c].data();
            float* ps = ps_[c].data();
            const float* rc = rc_[c].data();
            const float* rs = rs_[c].data();
            const float* m = frozen_[c].data();
            for (uint32_t k = 0; k < count; ++k) {
                // The bin's frequency's advance over a quarter-window hop.
                float x = pc[k] * rc[k] - ps[k] * rs[k], y = pc[k] * rs[k] + ps[k] * rc[k];
                if (drift > 0.0f) {
                    rng_ = rng_ * 1664525u + 1013904223u;
                    const int j = 128 + static_cast<int>(drift * (static_cast<float>(rng_ >> 9) / 4194304.0f - 1.0f));
                    const float u = x * t.c[j] - y * t.s[j];
                    y = x * t.s[j] + y * t.c[j];
                    x = u;
                }
                const float r = 1.5f - 0.5f * (x * x + y * y);  // back onto the unit circle
                x *= r, y *= r;
                pc[k] = x, ps[k] = y;
                const double mag = m[k] * paintGain_[k];
                re[c][k] = keep * re[c][k] + g * mag * x;
                im[c][k] = keep * im[c][k] + g * mag * y;
            }
        }
    }
    void shift(double* x, double* y, uint32_t count, int s) noexcept {
        double* tr = tmp_.data();
        double* ti = tmp_.data() + count;
        for (uint32_t k = 0; k < count; ++k) {
            const int from = static_cast<int>(k) - s;
            double a = 0.0, c = 0.0;
            if (from >= 1 && from < static_cast<int>(count) - 1) a = x[from], c = y[from];
            switch (quarter_) {
                case 1: { const double u = a; a = -c, c = u; break; }
                case 2: a = -a, c = -c; break;
                case 3: { const double u = a; a = c, c = -u; break; }
                default: break;
            }
            tr[k] = a, ti[k] = c;
        }
        std::memcpy(x, tr, 8ull * count);
        std::memcpy(y, ti, 8ull * count);
    }
    void updatePaint(uint32_t count) noexcept {
        paintFor_ = paintAmt_;
        paintDirty_ = false;
        const float* pos = pos_[tier_].data();
        for (uint32_t k = 0; k < count; ++k) {
            const uint32_t b0 = std::min<uint32_t>(static_cast<uint32_t>(pos[k]), kBands - 1);
            const uint32_t b1 = std::min<uint32_t>(b0 + 1, kBands - 1);
            const double f = pos[k] - b0;
            const double db = paint_[b0] + f * (paint_[b1] - paint_[b0]);
            paintGain_[k] = static_cast<float>(lib::dbToGain(db * paintAmt_));
        }
    }
    void frozenBandsFrom(uint32_t count, double ref) noexcept {
        double most[kBands] = {};
        for (uint32_t k = 0; k < count; ++k) {
            const uint32_t band = band_[tier_][k];
            most[band] = std::max(most[band], static_cast<double>(std::max(frozen_[0][k], frozen_[1][k])));
        }
        for (uint32_t b = 0; b < kBands; ++b)
            frozenBands_[b] = static_cast<float>(std::max(-120.0, 20.0 * std::log10(most[b] / ref + 1e-12)));
    }
    // A loaded state (loadState): its paint and spectrum, at this window.
    void takeLoaded() noexcept {
        const uint32_t g = gen_.load(std::memory_order_acquire);
        if (g == seen_ || (g & 1u)) return;
        float paint[kBands];
        std::memcpy(paint, pendingPaint_, sizeof paint);
        const uint32_t bins = pendingBins_, n = pendingN_;
        agen_.fetch_add(1, std::memory_order_acq_rel);
        if (bins) {
            for (int c = 0; c < 2; ++c) {
                std::memcpy(frozen_[c].data(), pending_[c].data(), 4ull * bins);
                std::memcpy(freq_[c].data(), pendingFreq_[c].data(), 4ull * bins);
            }
            captured_ = true;
            savedBins_ = bins, savedN_ = n;
            if (n != n_) resampleFrozen(n, n_);
            else updateRotation(bins);
            for (int c = 0; c < 2; ++c) {
                std::fill(pc_[c].begin(), pc_[c].end(), 1.0f);
                std::fill(ps_[c].begin(), ps_[c].end(), 0.0f);
            }
            skipCapture_ = true;  // a freeze turned on (or on already) plays it
            if (freeze_) wasFrozen_ = true;
        }
        std::memcpy(paint_, paint, sizeof paint);
        savedCaptured_.store(captured_, std::memory_order_relaxed);
        agen_.fetch_add(1, std::memory_order_acq_rel);
        std::atomic_thread_fence(std::memory_order_acquire);
        if (gen_.load(std::memory_order_relaxed) != g) return;  // written again meanwhile: taken next frame
        seen_ = g;
        paintDirty_ = true;
        if (captured_) frozenBandsFrom(n_ / 2 + 1, n_ / kPi);
    }
    // The frozen spectrum from a window of `from` points to `to` (by frequency; magnitudes scaled with the window).
    void resampleFrozen(uint32_t from, uint32_t to) noexcept {
        const uint32_t a = from / 2 + 1, bTo = to / 2 + 1;
        if (a > maxBins_ || bTo > maxBins_) return;
        const double scale = static_cast<double>(to) / from;
        for (int c = 0; c < 2; ++c) {
            std::memcpy(tmpF(c), frozen_[c].data(), 4ull * a);
            std::memcpy(tmpF(c) + a, freq_[c].data(), 4ull * a);
            const float* old = tmpF(c);
            const float* hz = tmpF(c) + a;
            for (uint32_t k = 0; k < bTo; ++k) {
                const double at = k / scale;
                const uint32_t i = std::min<uint32_t>(static_cast<uint32_t>(at), a - 1);
                const uint32_t j = std::min<uint32_t>(i + 1, a - 1);
                const double f = at - i;
                frozen_[c][k] = static_cast<float>(scale * (old[i] + f * (old[j] - old[i])));
                freq_[c][k] = static_cast<float>(scale * (hz[i] + f * (hz[j] - hz[i])));
            }
        }
        savedBins_ = bTo, savedN_ = to;
        updateRotation(bTo);
    }
    float* tmpF(int c) noexcept { return reinterpret_cast<float*>(tmp_.data()) + 2 * static_cast<size_t>(c) * maxBins_; }
    // Each frozen bin's turn per hop from its frequency (a quarter turn per bin).
    void updateRotation(uint32_t count) noexcept {
        for (int c = 0; c < 2; ++c)
            for (uint32_t k = 0; k < count; ++k) {
                const double a = 0.5 * kPi * freq_[c][k];
                rc_[c][k] = static_cast<float>(detCos(a)), rs_[c][k] = static_cast<float>(detSin(a));
            }
    }
    static void quarterTurns(float& x, float& y, uint32_t k) noexcept {
        switch (k & 3u) {
            case 1: { const float u = x; x = -y, y = u; break; }
            case 2: x = -x, y = -y; break;
            case 3: { const float u = x; x = y, y = -u; break; }
            default: break;
        }
    }

    clean::Stft stft_;
    std::vector<float> frozen_[2], pending_[2], freq_[2], pendingFreq_[2], blur_[2], pc_[2], ps_[2], rc_[2], rs_[2];
    std::vector<float> bc_[2], bs_[2], paintGain_, pos_[3];
    std::vector<uint8_t> band_[3];
    std::vector<double> tmp_;
    std::vector<double> dry_[4], prev_[4];
    double* dryR_[2] = {};
    double* dryI_[2] = {};
    double knobs_[irCount] = {};
    float paint_[kBands] = {}, pendingPaint_[kBands] = {}, live_[kBands] = {}, frozenBands_[kBands] = {};
    double liveMax_[kBands] = {};
    std::atomic<uint32_t> gen_{0}, agen_{0};
    std::atomic<bool> savedCaptured_{false};
    uint32_t seen_ = 0, pendingBins_ = 0, pendingN_ = 0, savedBins_ = 0, savedN_ = 0;
    uint32_t maxN_ = 4096, maxBins_ = 2049, n_ = 0, rng_ = 0x2545F491u;
    int tier_ = 1, shiftBins_ = 0, quarter_ = 0;
    double fz_ = 0, fadeStep_ = 0.05, paintAmt_ = 1, paintFor_ = -1, blurTime_ = 0, gateDb_ = -100, gate2_ = 0;
    double gateFloor_ = 0.001, mix_ = 1, out_ = 1;
    float drift_ = 0.3f, blurA_ = 0.0f;
    bool freeze_ = false, wasFrozen_ = false, captured_ = false, capture_ = false, skipCapture_ = false;
    bool paintDirty_ = true, first_ = true;
};

ModuleProcessor* makeIris() noexcept { return new (std::nothrow) Iris(); }

using V = std::vector<std::pair<std::string_view, double>>;

}  // namespace

void registerIris(ModuleRegistry& registry) {
    (void)phasors();
    registry.add(irisDescriptor(), &makeIris);
}
size_t irisBytes(double sr) noexcept {
    const size_t n = clean::maxWindow(sr), bins = n / 2 + 1;
    // The STFT (4 float rings, 2 double frames, 4 double half-spectra), 10 float bin arrays, the bin tables (3
    // tiers) and the shift's scratch.
    return sizeof(Iris) + 16 * n + 16 * n + 32 * bins + 40 * bins + 5 * (bins / 4 + bins / 2 + bins) + 16 * bins;
}

const std::vector<BuiltinPreset>& irisPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Freeze pad", "Sound design: freeze a moment into an endless pad", V{{"freeze", 1}, {"fade", 400}, {"drift", 0.4}}},
        {"Instant freeze", "Sound design: a hard, quick freeze", V{{"freeze", 1}, {"fade", 20}, {"drift", 0.1}}},
        {"Spectral smear", "Sound design: a long blur of the sound", V{{"blur", 0.7}}},
        {"Soft blur", "Mixing: a little spectral blur under the dry sound", V{{"blur", 0.35}, {"mix", 0.5}}},
        {"Metallic shift", "Sound design: everything moved up 300 Hz (inharmonic)", V{{"shift", 300}}},
        {"Sub drop shift", "Bass: moved down 60 Hz, half wet", V{{"shift", -60}, {"mix", 0.5}}},
        {"Spectral gate", "Mixing: only the strongest partials pass", V{{"gate", -40}, {"gate_range", 60}}},
        {"Whisper gate", "Sound design: a high gate leaves a thin, ghostly sound", V{{"gate", -25}, {"gate_range", 40}, {"blur", 0.2}}},
        {"Frozen shimmer", "Sound design: a frozen pad shifted up and blurred", V{{"freeze", 1}, {"shift", 500}, {"drift", 0.6}, {"mix", 0.7}}},
        {"Lo-fi spectrum", "Lo-fi: the Eco window, gated and smeared", V{{"quality", 0}, {"gate", -45}, {"blur", 0.3}}},
        {"Hi-def freeze", "Sound design: the High window: a finer, purer freeze", V{{"quality", 2}, {"freeze", 1}, {"drift", 0.2}}},
    };
    return p;
}

}  // namespace caw::fx
