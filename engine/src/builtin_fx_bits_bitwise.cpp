// Bit distortion's "Bitwise" variant (1.1.0, glitch ops 1.1.1): each sample as a signed integer word, shifted, masked, rotated, reversed, frozen, flipped and combined with a key or its own echo, with its bit lanes for the display.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <span>
#include <vector>

#include "fx_merged.h"
#include "fx_sidechain.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0), C.A.W's own design (sound plan 2026-11-19: "Bitwise (shift, XOR, AND masks;
// lanes drawn flipping)"; owner 2026-11-20: masks, rotate, reverse, freeze, flips, combination with the sidechain;
// "glitchy and interesting, never just destroyed or static"). Variant 1 of org.caw.bits: its own table, `variant`,
// then the 1.1.1 parameters appended (so 1.1.0's indices and `variant`'s place hold).
//
// 1.1.0's word: each sample (held to -1..1) is rounded to a signed word of `bits` bits (2..16), shifted (left: louder,
// wrapping round past full scale; right: coarser), wrapped back to its bits, XORed with `xor` and ANDed with `and`
// (16-bit masks, their top `bits` bits used, so a mask means the same at every word size), and read back; a word
// that rounds to 0 stays 0 (silence stays silence). All of it integer arithmetic, the same on every platform.
//
// 1.1.1's glitch ops, after the shift, in this order (all on the word's own lanes, the masks' top `bits` bits):
// - freeze: the `freeze` lanes loop the step's first `grain` ms for `hold` of each step (a stutter in those lanes);
// - combine: the word XOR/AND/OR (`combine_op`) the key's word (`combine` Key: the sidechain, quantised the same
//   way) or its own word `echo` ms ago (Echo: a comb, a metallic ring), on the `combine_mask` lanes;
// - rotate (`rotate` lanes round the word) and reverse (its lowest `reverse` lanes in reverse order);
// - the masks: XOR, then OR (`or`), then AND;
// - flips: each lane flips for a whole step with probability `flips`, drawn from `seed` and the step's number (so a
//   render repeats, and a song position always flips the same lanes).
// A step is `rate` (a note division of the song's tempo; its position while the song plays, a free clock from
// silence while stopped); `pattern`'s 8 bits say on which of 8 steps the ops act (bit 0 the first). The bits and the
// shift always act. The wet then goes through `tone` (a one-pole low-pass, 20 kHz: off), `gate` (the wet only
// while the input is above it; its bottom: off) and `level` (Auto: the wet never louder than the input, in RMS
// RMS over about 10 ms, with its offset taken out below 8 Hz), then Output and Mix. With every 1.1.1 op at its default the 1.1.0 loop runs, unchanged, so
// 1.1.0's presets and projects play bit for bit as before; Auto acts only while an op does.
// The display counts how often each of the left side's 16 lanes flipped since the last publish (0..1) and shows the
// latest word's bits, then the step, the frozen and flipped lanes, the combined word, the gate and the level.

namespace caw::fx {

namespace {

constexpr std::string_view kBitsId = "org.caw.bits";
constexpr std::string_view kBitsName = "Bit distortion";
enum BitwiseParam : uint32_t {
    kWBits, kWShift, kWXor, kWAnd, kWOutput, kWMix, kWVariant,
    // 1.1.1, after `variant`
    kWRotate, kWReverse, kWOr, kWCombine, kWCombineOp, kWCombineMask, kWEcho, kWRate, kWPattern, kWFreeze, kWGrain,
    kWHold, kWFlips, kWSeed, kWTone, kWGate, kWLevel, kWCount
};

constexpr std::string_view kCombine[] = {"Off", "Key", "Echo"};
constexpr std::string_view kCombineOps[] = {"XOR", "AND", "OR"};
constexpr std::string_view kRates[] = {"1/32", "1/16 T", "1/16", "1/8 T", "1/8", "1/4", "1/2", "1 bar"};
constexpr double kRateBeats[] = {0.125, 1.0 / 6.0, 0.25, 1.0 / 3.0, 0.5, 1.0, 2.0, 4.0};  // quarter notes a step
constexpr std::string_view kLevels[] = {"Off", "Auto"};
constexpr double kEchoMaxMs = 50.0, kGrainMaxMs = 80.0, kGateOff = -80.0, kToneOff = 20000.0;

const ParamTable& bitwiseParams() {
    static const ParamTable t = [] {
        ParamTable p;
        auto whole = [&](const char* id, const char* name, double def, double lo, double hi) {
            ParameterDescriptor& d = p.num(id, name, def, lo, hi);
            d.step = 1.0;
            d.smoothingFrames = 0;  // whole numbers jump
        };
        whole("bits", "Bits", 12.0, 2.0, 16.0);
        whole("shift", "Shift", 0.0, -8.0, 8.0);
        whole("xor", "XOR mask", 0.0, 0.0, 65535.0);
        whole("and", "AND mask", 65535.0, 0.0, 65535.0);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}

// 1.1.1's parameters, after `variant`; each off (or neutral) by default.
std::span<const ParameterDescriptor> glitchParams() {
    static const ParamTable t = [] {
        ParamTable p;
        auto whole = [&](const char* id, const char* name, double def, double lo, double hi) {
            ParameterDescriptor& d = p.num(id, name, def, lo, hi);
            d.step = 1.0;
            d.smoothingFrames = 0;
        };
        whole("rotate", "Rotate", 0.0, -15.0, 15.0);
        whole("reverse", "Reverse", 0.0, 0.0, 16.0);
        whole("or", "OR mask", 0.0, 0.0, 65535.0);
        p.pick("combine", "Combine", 0.0, kCombine);
        p.pick("combine_op", "Combine op", 0.0, kCombineOps);
        whole("combine_mask", "Combine lanes", 65535.0, 0.0, 65535.0);
        p.expo("echo", "Echo", 4.0, 0.1, kEchoMaxMs, "ms").smoothingFrames = 0;
        p.pick("rate", "Step", 2.0, kRates);
        whole("pattern", "Pattern", 255.0, 0.0, 255.0);
        whole("freeze", "Freeze lanes", 0.0, 0.0, 65535.0);
        p.expo("grain", "Grain", 12.0, 1.0, kGrainMaxMs, "ms").smoothingFrames = 0;
        p.num("hold", "Hold", 0.5, 0.0, 1.0).smoothingFrames = 0;
        p.num("flips", "Flips", 0.0, 0.0, 1.0).smoothingFrames = 0;
        whole("seed", "Seed", 1.0, 0.0, 9999.0);
        p.expo("tone", "Tone", kToneOff, 500.0, kToneOff, "Hz");
        p.num("gate", "Gate", kGateOff, kGateOff, -10.0, "dB");
        p.pick("level", "Level", 1.0, kLevels);
        addSidechainParams(p);
        return p;
    }();
    return {t.data(), t.size()};
}

// A 64-bit mix (splitmix64's finaliser): the flips' draw from the seed and the step's number.
constexpr uint64_t mix64(uint64_t z) noexcept {
    z += 0x9e3779b97f4a7c15ull;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return z ^ (z >> 31);
}
// Each 16-bit group of v with its bits in reverse order.
constexpr uint64_t rev16x4(uint64_t v) noexcept {
    v = ((v >> 1) & 0x5555555555555555ull) | ((v & 0x5555555555555555ull) << 1);
    v = ((v >> 2) & 0x3333333333333333ull) | ((v & 0x3333333333333333ull) << 2);
    v = ((v >> 4) & 0x0f0f0f0f0f0f0f0full) | ((v & 0x0f0f0f0f0f0f0f0full) << 4);
    return ((v >> 8) & 0x00ff00ff00ff00ffull) | ((v & 0x00ff00ff00ff00ffull) << 8);
}

class Bitwise : public EffectBase {
public:
    explicit Bitwise(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        sc_.bind(d_);
        // The echo's and the grain's words, sized to this rate's real need (50 and 80 ms), a power of two each.
        auto pow2 = [](double frames) {
            uint32_t n = 16;
            while (n < frames + 2.0) n <<= 1;
            return n;
        };
        echoSize_ = pow2(kEchoMaxMs * 0.001 * sr);
        gateA_ = 1.0 - std::exp(-static_cast<double>(kControlFrames) / (0.003 * sr));
        for (uint32_t f = 0; f <= kControlFrames; ++f) {  // a one-pole's step over f frames at once
            levelA_[f] = 1.0 - std::exp(-static_cast<double>(f) / (0.01 * sr));
            downA_[f] = 1.0 - std::exp(-static_cast<double>(f) / (0.08 * sr));
        }
        aDcOn_ = 1.0 - std::exp(-2.0 * 3.14159265358979323846 * 8.0 / sr);
        toneFor_ = -1.0;  // its coefficient again at this rate
        grainCap_ = static_cast<uint32_t>(kGrainMaxMs * 0.001 * sr) + 1;
        try {
            for (int c = 0; c < 2; ++c) {
                echo_[c].assign(echoSize_, 0);
                grain_[c].assign(grainCap_, 0);
            }
        } catch (...) {
            return false;
        }
        return true;
    }
    void clearState() noexcept override {
        outRamp_.reset();
        mixRamp_.reset();
        for (uint32_t& f : flips_) f = 0;
        counts_ = 0;
        counted_ = 0;
        frames_ = 0;
        prev_ = last_ = 0;
        for (int c = 0; c < 2; ++c) {
            std::fill(echo_[c].begin(), echo_[c].end(), int16_t{0});
            std::fill(grain_[c].begin(), grain_[c].end(), int16_t{0});
            tone_[c] = dc_[c] = 0.0;
        }
        echoAt_ = 0;
        sc_.clear();
        for (double& v : knobs_) v = std::nan("");  // decoded again at the first control
        freeBeat_ = 0.0;
        step_ = -1;
        stepFrame_ = gpos_ = toEdge_ = 0;
        envIn_ = envWet_ = gateEnv_ = 0.0;
        sumIn_ = sumWet_ = peak_ = 0.0;
        heard_ = 0;
        levelRamp_.reset();
        gateRamp_.reset();
        gateSmooth_ = 1.0;
        shownLevel_ = 1.0;
        glitch_ = false;
        shownFrozen_ = shownFlip_ = shownOther_ = 0;
    }
    void control(uint32_t at) noexcept override {
        bits_ = std::clamp(static_cast<int>(param(kWBits, at) + 0.5), 2, 16);
        shift_ = std::clamp(static_cast<int>(std::lround(param(kWShift, at))), -8, 8);
        xor16_ = mask16(param(kWXor, at));
        and16_ = mask16(param(kWAnd, at));
        drop_ = 16 - bits_;
        mask_ = (1u << bits_) - 1u;
        sign_ = 1u << (bits_ - 1);
        xor_ = (xor16_ >> drop_) & mask_;
        and_ = (and16_ >> drop_) & mask_;
        left_ = shift_ > 0 ? shift_ : 0;
        right_ = shift_ < 0 ? -shift_ : 0;
        scale_ = static_cast<double>(sign_ - 1u);
        inv_ = 1.0 / scale_;  // full scale back to 1
        outRamp_.set(lib::dbToGain(param(kWOutput, at)), kControlFrames);
        mixRamp_.set(std::clamp(param(kWMix, at), 0.0, 1.0), kControlFrames);
        glitchControl(at);
    }
    // One sample through the word: its integer value after the shift and masks, as a signed bits_-bit number.
    int32_t word(double x) const noexcept {
        x = x == x ? std::clamp(x, -1.0, 1.0) : 0.0;
        const double t = x * scale_;
        const int32_t q = static_cast<int32_t>(t + (t >= 0.0 ? 0.5 : -0.5));
        uint32_t u = (static_cast<uint32_t>(q) << left_);
        u = static_cast<uint32_t>(static_cast<int32_t>(u) >> right_);  // arithmetic (C++20)
        u = ((u & mask_) ^ xor_) & and_;
        u = q == 0 ? 0u : u;  // silence stays silence (a XOR mask would make it a constant): it sleeps
        return static_cast<int32_t>((u ^ sign_) - sign_);  // sign-extended from bits_
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        if (glitch_) {
            runGlitch(inL, inR, outL, outR, n);
            return;
        }
        const int up = 16 - bits_;  // the lanes are counted on the 16-bit word (a coarser word's top lanes)
        for (uint32_t i = 0; i < n; ++i) {
            const int32_t wl = word(inL[i]), wr = word(inR[i]);
            const uint32_t lanes = (static_cast<uint32_t>(wl) << up) & 0xffffu;
            countFlips(lanes ^ prev_);
            prev_ = lanes;
            const double o = outRamp_.next(), m = mixRamp_.next();
            const double yl = wl * inv_ * o, yr = wr * inv_ * o;
            outL[i] = static_cast<float>(inL[i] + (yl - inL[i]) * m);
            outR[i] = static_cast<float>(inR[i] + (yr - inR[i]) * m);
        }
        last_ = prev_;
        frames_ += n;
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(bits_);
        out[3] = static_cast<float>(shift_);
        out[4] = static_cast<float>(xor16_);
        out[5] = static_cast<float>(and16_);
        flushFlips();
        const double per = frames_ ? 1.0 / static_cast<double>(frames_) : 0.0;
        for (int b = 0; b < 16; ++b) {  // lane 0 the least significant
            out[6 + b] = static_cast<float>(flips_[b] * per);   // how often it flipped (0..1 a frame)
            out[22 + b] = static_cast<float>((last_ >> b) & 1u);  // the latest word's bit
            flips_[b] = 0;
        }
        frames_ = 0;
        // 1.1.1: the step (0..7 in the pattern; -1 while no op acts) and whether the ops act on it, the lanes frozen
        // and flipped now and the combined word's latest bits (each 16-bit, as the lanes), the gate (0..1) and the
        // level's gain (dB).
        out[38] = glitch_ ? static_cast<float>(step_ & 7) : -1.0f;
        out[39] = glitch_ && active_ ? 1.0f : 0.0f;
        out[40] = static_cast<float>(glitch_ ? shownFrozen_ : 0u);
        out[41] = static_cast<float>(glitch_ ? shownFlip_ : 0u);
        out[42] = static_cast<float>(glitch_ ? shownOther_ : 0u);
        out[43] = static_cast<float>(glitch_ ? gateRamp_.value : 1.0);
        out[44] = glitch_ ? static_cast<float>(20.0 * std::log10(std::max(shownLevel_, 1e-6))) : 0.0f;
        return 45;
    }
    uint64_t idleFrames() const noexcept override {  // the tone's tail past the echo's longest
        return static_cast<uint64_t>((0.05 + kEchoMaxMs * 0.001) * rate());
    }

private:
    // The lanes that changed this frame, counted 4 bits a lane in one word (each lane's bit spread to its nibble),
    // emptied into flips_ before a nibble can overflow.
    static uint64_t spread(uint32_t changed) noexcept {
        uint64_t x = changed & 0xffffu;
        x = (x | (x << 24)) & 0x000000ff000000ffull;
        x = (x | (x << 12)) & 0x000f000f000f000full;
        x = (x | (x << 6)) & 0x0303030303030303ull;
        return (x | (x << 3)) & 0x1111111111111111ull;
    }
    void countFlips(uint32_t changed) noexcept {
        counts_ += spread(changed);
        if (++counted_ == 15) flushFlips();
    }
    void flushFlips() noexcept {
        for (int b = 0; b < 16; ++b) flips_[b] += static_cast<uint32_t>((counts_ >> (4 * b)) & 15u);
        counts_ = 0;
        counted_ = 0;
    }
    static uint32_t mask16(double v) noexcept { return static_cast<uint32_t>(std::clamp(v, 0.0, 65535.0) + 0.5); }

    // The 1.1.1 knobs at control rate; glitch_ when any op acts (the 1.1.0 loop runs otherwise).
    void glitchControl(uint32_t at) noexcept {
        // The knobs decoded only when one moved (or the tempo did); the clock and the followers every period.
        if (!knobsUnchanged(knobs_, kSc0 + 3, at) || tempo() != tempoFor_) {
            tempoFor_ = tempo();
            decode(at);
            if (step_ >= 0) setStep(step_);  // a knob moved: the step's masks again
        }
        double beat;  // the song's position while it plays, a free clock otherwise (from the last wake)
        if (beatAt(at, beat)) freeBeat_ = beat;
        toEdge_ = 0;  // the step looked up again at this period's start
        if (glitch_) followers();
    }
    void decode(uint32_t at) noexcept {
        rotate_ = std::clamp(static_cast<int>(std::lround(param(kWRotate, at))), -15, 15);
        reverse_ = std::clamp(static_cast<int>(std::lround(param(kWReverse, at))), 0, 16);
        or16_ = mask16(param(kWOr, at));
        combine_ = std::clamp(choice(kWCombine, at), 0, 2);
        combineOp_ = std::clamp(choice(kWCombineOp, at), 0, 2);
        combine16_ = mask16(param(kWCombineMask, at));
        echoFrames_ = std::clamp(static_cast<uint32_t>(std::clamp(param(kWEcho, at), 0.1, kEchoMaxMs) * 0.001 * rate() + 0.5),
                                 1u, echoSize_ - 1u);
        const double stepBeats = kRateBeats[std::clamp(choice(kWRate, at), 0, 7)];
        pattern_ = static_cast<uint32_t>(std::clamp(param(kWPattern, at), 0.0, 255.0) + 0.5);
        freeze16_ = mask16(param(kWFreeze, at));
        const double spb = 60.0 / tempo();  // seconds a beat
        const double stepFrames = stepBeats * spb * rate();
        grainFrames_ = std::clamp(static_cast<uint32_t>(std::clamp(param(kWGrain, at), 1.0, kGrainMaxMs) * 0.001 * rate()), 1u, grainCap_);
        holdFrames_ = static_cast<uint32_t>(std::clamp(param(kWHold, at), 0.0, 1.0) * stepFrames);
        const double p = std::clamp(param(kWFlips, at), 0.0, 1.0);
        flipLimit_ = static_cast<uint32_t>(p * 256.0 + 0.5);
        seed_ = static_cast<uint64_t>(std::clamp(param(kWSeed, at), 0.0, 9999.0) + 0.5);
        const double tone = std::clamp(param(kWTone, at), 500.0, kToneOff);
        if (tone != toneFor_)  // only when it moves
            toneFor_ = tone, toneA_ = tone >= kToneOff ? 1.0 : 1.0 - std::exp(-2.0 * 3.14159265358979323846 * tone / rate());
        const double gateDb = param(kWGate, at);
        if (gateDb != gateFor_) gateFor_ = gateDb, gateThr_ = gateDb <= kGateOff ? -1.0 : lib::dbToGain(gateDb);
        level_ = on(kWLevel, at);
        sc_.set(param(kSc0 + 0, at), param(kSc0 + 1, at), on(kSc0 + 2, at), rate());
        const bool ops = rotate_ != 0 || reverse_ != 0 || or16_ != 0 || combine_ != 0 || freeze16_ != 0 ||
                         flipLimit_ != 0 || (pattern_ != 255u && (xor16_ != 0 || and16_ != 65535u));
        const bool was = glitch_;
        glitch_ = ops || toneA_ < 1.0 || gateThr_ >= 0.0 || sc_.listen;
        opsOn_ = ops;
        if (glitch_ && !was) {  // fresh followers: the level starts at unity
            envIn_ = envWet_ = sumIn_ = sumWet_ = peak_ = 0.0;
            heard_ = 0;
            levelRamp_.reset();
            gateRamp_.reset();
            for (double& y : tone_) y = 0.0;
            for (double& y : dc_) y = 0.0;
        }
        beatStep_ = 1.0 / (spb * rate());
        stepsPerBeat_ = 1.0 / stepBeats;
        autoLevel_ = level_ && opsOn_;
    }

    // A step's ops, in the word's own bits (all neutral where an op is off or the pattern skips the step).
    // Both sides' words are worked on at once, packed in one 64-bit word (left in bits 0..31, right in 32..63), so
    // each mask here is the word's own repeated in both halves.
    struct StepOps {
        uint64_t freeze = 0, comb = 0, opXor = ~0ull, opAnd = 0, opOr = 0, mask = 4095, xr = 0, orr = 0, an = 4095,
                 flip = 0, low = 0;
        uint32_t rot = 0, rotBack = 12, revShift = 16;
    };
    static constexpr uint64_t both(uint32_t m) noexcept { return m | (static_cast<uint64_t>(m) << 32); }

    // A new step: which ops act and their masks.
    void setStep(int64_t step) noexcept {
        step_ = step;
        active_ = (pattern_ >> static_cast<uint32_t>(step & 7)) & 1u;
        const uint32_t on = active_ ? ~0u : 0u;
        StepOps& k = so_;
        k.mask = both(mask_);
        k.opXor = combineOp_ == 0 ? ~0ull : 0ull;
        k.opAnd = combineOp_ == 1 ? ~0ull : 0ull;
        k.opOr = combineOp_ == 2 ? ~0ull : 0ull;
        k.xr = both(xor_ & on);
        k.orr = both(((or16_ >> drop_) & mask_) & on);
        k.an = both(active_ ? and_ : mask_);
        k.comb = both(combine_ ? ((combine16_ >> drop_) & mask_) & on : 0u);
        const int r = active_ ? ((rotate_ % bits_) + bits_) % bits_ : 0;
        k.rot = static_cast<uint32_t>(r);
        k.rotBack = static_cast<uint32_t>(bits_ - r);  // r 0: u >> bits_ is 0
        const int rev = active_ ? std::min(reverse_, bits_) : 0;
        k.low = both(rev ? (1u << rev) - 1u : 0u);
        k.revShift = static_cast<uint32_t>(16 - rev);
        k.freeze = both(((freeze16_ >> drop_) & mask_) & on);
        uint32_t flip = 0;
        if (active_ && flipLimit_) {
            const uint64_t x = mix64(seed_ * 0x100000001b3ull ^ static_cast<uint64_t>(step));
            const uint64_t y = mix64(x);
            for (int lane = 0; lane < 16; ++lane) {
                const uint32_t r8 = static_cast<uint32_t>(((lane < 8 ? x : y) >> (8 * (lane & 7))) & 0xffu);
                flip |= static_cast<uint32_t>(r8 < flipLimit_) << lane;
            }
        }
        k.flip = both((flip >> drop_) & mask_);
    }

    // The words through the 1.1.1 ops, both sides at once (u: after the shift, in the word's bits; other: the key's
    // or echo's words; cm: the combined lanes, 0 while a Key combine has no key routed, so the word passes). No
    // branch: an op that is off has neutral masks. A shift never carries a lane into the other half's word: what
    // crosses lands outside the word's bits, which the mask clears.
    template <bool Lanes>
    static uint64_t ops(const StepOps& k, uint64_t u, uint64_t frozen, uint64_t other, uint64_t cm) noexcept {
        if constexpr (Lanes) u = (u & ~k.freeze) | (frozen & k.freeze);
        const uint64_t c = other & cm;
        u ^= c & k.opXor;               // XOR
        u &= ~(cm & ~other & k.opAnd);  // AND: a lane the other word has clear is cleared
        u = (u | (c & k.opOr)) & k.mask;  // OR
        if constexpr (Lanes) {
            u = ((u << k.rot) | (u >> k.rotBack)) & k.mask;
            u = (u & ~k.low) | ((rev16x4(u & k.low) >> k.revShift) & k.low);
        }
        u = (((u ^ k.xr) | k.orr) & k.an) ^ k.flip;
        return u & k.mask;
    }
    // The followers, at control rate on the frames since the last call (grid-aligned, so any block size gives the
    // same): the level's RMS over about 10 ms and the gate's peak (instant up, 80 ms down), each turned into a gain
    // ramped over the next control period.
    void followers() noexcept {
        const uint32_t f = std::min(heard_, kControlFrames);
        if (f) {
            const double a = levelA_[f], down = downA_[f];
            envIn_ += (sumIn_ / f - envIn_) * a;
            envWet_ += (sumWet_ / f - envWet_) * a;
            gateEnv_ = peak_ > gateEnv_ ? peak_ : gateEnv_ * (1.0 - down) + peak_ * down;
            envIn_ = envIn_ < 1e-20 ? 0.0 : envIn_;  // no denormals in the followers
            envWet_ = envWet_ < 1e-20 ? 0.0 : envWet_;
            gateEnv_ = gateEnv_ < 1e-20 ? 0.0 : gateEnv_;
        }
        sumIn_ = sumWet_ = peak_ = 0.0;
        heard_ = 0;
        const double lv = autoLevel_ ? std::min(1.0, std::sqrt((envIn_ + 1e-12) / (envWet_ + 1e-12))) : 1.0;
        levelRamp_.set(lv, kControlFrames);
        // The gate: open or shut, smoothed (about 3 ms), ramped over the period; exactly 1 while off.
        const double open = gateThr_ < 0.0 || gateEnv_ > gateThr_ ? 1.0 : 0.0;
        gateSmooth_ = gateThr_ < 0.0 ? 1.0 : gateSmooth_ + (open - gateSmooth_) * gateA_;
        gateRamp_.set(gateSmooth_, kControlFrames);
        shownLevel_ = lv;
    }

    void runGlitch(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept {
        const float* kl = keyLeft();
        const float* kr = keyRight();
        if (combine_ == 1 || sc_.listen) sc_.apply(kl, kr, n);
        if (sc_.listen) {  // what the combine hears
            sc_.listenTo(kl, kr, outL, outR, n);
            frames_ += n;
            return;
        }
        double wet[2][kControlFrames];
        const bool filter = toneA_ < 1.0 || autoLevel_;
        const uint64_t keyed = combine_ == 1 && !kl ? 0ull : ~0ull;  // no key routed: the Key combine waits
        // Only the chosen path's loop runs: with or without the tone and offset filters, by the combine's source.
        using Words = void (*)(Bitwise&, const float*, const float*, const float*, const float*, uint64_t,
                               double (&)[2][kControlFrames], uint32_t) noexcept;
        static constexpr Words kWords[12] = {
            &wordsOf<false, 0, false>, &wordsOf<false, 1, false>, &wordsOf<false, 2, false>,
            &wordsOf<true, 0, false>,  &wordsOf<true, 1, false>,  &wordsOf<true, 2, false>,
            &wordsOf<false, 0, true>,  &wordsOf<false, 1, true>,  &wordsOf<false, 2, true>,
            &wordsOf<true, 0, true>,   &wordsOf<true, 1, true>,   &wordsOf<true, 2, true>};
        const bool lanes = rotate_ != 0 || reverse_ != 0 || freeze16_ != 0;  // rotate, reverse or freeze
        const int path = (lanes ? 6 : 0) + (filter ? 3 : 0) + std::clamp(combine_, 0, 2);
        kWords[path](*this, inL, inR, kl, kr, keyed, wet, n);
        mixOut(inL, inR, outL, outR, wet, n);
        frames_ += n;
    }

    template <bool Filter, int Combine, bool Lanes>
    static void wordsOf(Bitwise& b, const float* inL, const float* inR, const float* kl, const float* kr, uint64_t keyed,
                        double (&wet)[2][kControlFrames], uint32_t n) noexcept {
        b.words<Filter, Combine, Lanes>(inL, inR, kl, kr, keyed, wet, n);
    }
    // The words of n frames into wet (the word's value after the ops, the tone and the offset filter).
    template <bool Filter, int Combine, bool Lanes>
    void words(const float* inL, const float* inR, const float* kl, const float* kr, uint64_t keyed,
               double (&wet)[2][kControlFrames], uint32_t n) noexcept {
        // The state in locals (the outputs could alias members otherwise), written back at the end.
        const int up = 16 - bits_;
        const uint32_t emask = echoSize_ - 1u, sign = sign_, grainFrames = grainFrames_, holdFrames = holdFrames_;
        const uint32_t echoFrames = echoFrames_;
        const double toneA = toneA_, inv = inv_;
        const double aDc = autoLevel_ ? aDcOn_ : 0.0;  // 8 Hz
        int16_t* echo[2] = {echo_[0].data(), echo_[1].data()};
        int16_t* grain[2] = {grain_[0].data(), grain_[1].data()};
        const float* key[2] = {kl, kr};
        double tone[2] = {tone_[0], tone_[1]}, dc[2] = {dc_[0], dc_[1]};
        uint32_t echoAt = echoAt_, stepFrame = stepFrame_, gpos = gpos_, prev = prev_, other0 = shownOther_;
        bool holding = false;
        StepOps k = so_;
        const double beat0 = freeBeat_, beatStep = beatStep_, stepsPerBeat = stepsPerBeat_;
        uint32_t toEdge = toEdge_;
        uint64_t counts = counts_;
        uint32_t counted = counted_;
        const double scale = scale_;
        const int shl = left_, shr = right_;
        const uint32_t mask = mask_;
        auto quantise = [&](double x, int32_t& q) {  // the same rounding as word(), without a branch
            x = caw::finiteOr0(x);
            x = x > 1.0 ? 1.0 : (x < -1.0 ? -1.0 : x);
            const double t = x * scale;
            q = static_cast<int32_t>(t + std::copysign(0.5, t));
            const uint32_t u = static_cast<uint32_t>(static_cast<int32_t>(static_cast<uint32_t>(q) << shl) >> shr);
            return u & mask;
        };
        for (uint32_t i = 0; i < n; ++i) {
            // The step's edge counted down in frames, checked against the clock there (and at each control period).
            if (toEdge == 0) {
                // From the run's start (no sum of rounding errors); the edge a hair early, never a frame late.
                const double phase = (beat0 + static_cast<double>(i) * beatStep) * stepsPerBeat + 1e-9;
                const int64_t step = static_cast<int64_t>(std::floor(phase));
                if (step != step_) {
                    setStep(step);
                    k = so_;
                    stepFrame = gpos = 0;
                }
                const double left = (static_cast<double>(step + 1) - phase) / (beatStep * stepsPerBeat) - 1e-6;
                toEdge = left < 1.0 ? 1u : (left > 1e9 ? 1000000000u : static_cast<uint32_t>(std::ceil(left)));
            }
            --toEdge;
            bool record = false;
            uint32_t g = 0;
            if constexpr (Lanes) {
                record = stepFrame < grainFrames;
                holding = !record && stepFrame < holdFrames;
                g = gpos;
                gpos = gpos + 1u >= grainFrames ? 0u : gpos + 1u;  // the grain loops
            }
            ++stepFrame;
            int32_t ql, qr;
            const uint32_t ul = quantise(inL[i], ql), ur = quantise(inR[i], qr);
            echo[0][echoAt] = static_cast<int16_t>(ul);  // always: a switch to Echo hears the last 50 ms
            echo[1][echoAt] = static_cast<int16_t>(ur);
            const uint64_t u = ul | (static_cast<uint64_t>(ur) << 32);
            uint64_t frozen = u;
            if constexpr (Lanes) {
                if (record) grain[0][g] = static_cast<int16_t>(ul), grain[1][g] = static_cast<int16_t>(ur);
                const uint64_t held = static_cast<uint16_t>(grain[0][g]) | (static_cast<uint64_t>(static_cast<uint16_t>(grain[1][g])) << 32);
                frozen = holding ? held : u;
            }
            uint64_t other = 0;
            if constexpr (Combine == 1) {
                int32_t kq;
                other = (key[0] ? quantise(key[0][i], kq) : 0u) | (static_cast<uint64_t>(key[1] ? quantise(key[1][i], kq) : 0u) << 32);
            } else if constexpr (Combine == 2) {
                const uint32_t at = (echoAt - echoFrames) & emask;
                other = static_cast<uint16_t>(echo[0][at]) | (static_cast<uint64_t>(static_cast<uint16_t>(echo[1][at])) << 32);
            }
            other0 = static_cast<uint32_t>(other);
            const uint64_t w = ops<Lanes>(k, u, frozen, other, k.comb & keyed);
            const uint32_t words[2] = {ql == 0 ? 0u : static_cast<uint32_t>(w), qr == 0 ? 0u : static_cast<uint32_t>(w >> 32)};  // silence stays silence
            for (int c = 0; c < 2; ++c) {
                const int32_t sv = static_cast<int32_t>((words[c] ^ sign) - sign);
                if constexpr (Filter) {
                    tone[c] += (sv * inv - tone[c]) * toneA;
                    dc[c] += (tone[c] - dc[c]) * aDc;  // Auto: a mask's offset taken out (aDc 0 while Off)
                    wet[c][i] = tone[c] - dc[c];
                } else {
                    wet[c][i] = sv * inv;
                }
            }
            echoAt = (echoAt + 1u) & emask;
            const uint32_t lanes = (words[0] << up) & 0xffffu;
            counts += spread(lanes ^ prev);
            prev = lanes;
            if (++counted == 15) {  // before a nibble can overflow
                counts_ = counts, counted_ = counted;
                flushFlips();
                counts = 0, counted = 0;
            }
        }
        freeBeat_ = beat0 + static_cast<double>(n) * beatStep;
        toEdge_ = toEdge;
        counts_ = counts, counted_ = counted;
        for (int c = 0; c < 2; ++c) tone_[c] = std::fabs(tone[c]) < 1e-20 ? 0.0 : tone[c], dc_[c] = std::fabs(dc[c]) < 1e-20 ? 0.0 : dc[c];
        echoAt_ = echoAt, stepFrame_ = stepFrame, gpos_ = gpos, prev_ = prev;
        shownOther_ = (other0 << up) & 0xffffu;
        shownFrozen_ = holding ? (static_cast<uint32_t>(k.freeze) << up) & 0xffffu : 0u;
        shownFlip_ = (static_cast<uint32_t>(k.flip) << up) & 0xffffu;
        last_ = prev_;
    }

    // The followers' sums (no carried branch: these vectorize), then the gains and the mix.
    void mixOut(const float* inL, const float* inR, float* outL, float* outR, const double (&wet)[2][kControlFrames],
                uint32_t n) noexcept {
        double sumIn = 0.0, sumWet = 0.0, peak = peak_;
        Ramp outRamp = outRamp_, mixRamp = mixRamp_, levelRamp = levelRamp_, gateRamp = gateRamp_;
        for (uint32_t i = 0; i < n; ++i) {
            const double x0 = caw::finiteOr0(inL[i]), x1 = caw::finiteOr0(inR[i]);
            sumIn += 0.5 * (x0 * x0 + x1 * x1);
            const double a = std::max(std::fabs(x0), std::fabs(x1));
            peak = a > peak ? a : peak;
            const double o = outRamp.next(), m = mixRamp.next(), lv = levelRamp.next(), gt = gateRamp.next();
            const double yl = wet[0][i] * gt, yr = wet[1][i] * gt;
            sumWet += 0.5 * (yl * yl + yr * yr);
            const double gain = o * lv;
            outL[i] = static_cast<float>(x0 + (yl * gain - x0) * m);
            outR[i] = static_cast<float>(x1 + (yr * gain - x1) * m);
        }
        outRamp_ = outRamp, mixRamp_ = mixRamp, levelRamp_ = levelRamp, gateRamp_ = gateRamp;
        sumIn_ += sumIn, sumWet_ += sumWet, peak_ = peak, heard_ += n;
    }

    static constexpr uint32_t kSc0 = kWCount;  // sc_hpf, sc_lpf, sc_listen follow the 1.1.1 table
    const ModuleDescriptor& d_;
    int bits_ = 12, shift_ = 0, left_ = 0, right_ = 0, drop_ = 4;
    uint32_t xor16_ = 0, and16_ = 65535, mask_ = 4095, sign_ = 2048, xor_ = 0, and_ = 4095;
    double scale_ = 2047, inv_ = 1.0 / 2047;
    Ramp outRamp_, mixRamp_;
    double shownLevel_ = 1.0;
    uint32_t flips_[16] = {}, frames_ = 0, prev_ = 0, last_ = 0, counted_ = 0;
    uint64_t counts_ = 0;
    // 1.1.1
    SidechainFilter sc_;
    bool glitch_ = false, opsOn_ = false, level_ = true, autoLevel_ = false, active_ = true;
    int rotate_ = 0, reverse_ = 0, combine_ = 0, combineOp_ = 0;
    uint32_t or16_ = 0, combine16_ = 65535, freeze16_ = 0, pattern_ = 255, flipLimit_ = 0;
    uint32_t echoSize_ = 16, echoAt_ = 0, echoFrames_ = 1, grainCap_ = 1, grainFrames_ = 1, holdFrames_ = 0, stepFrame_ = 0;
    uint64_t seed_ = 1;
    int64_t step_ = -1;
    StepOps so_;
    double knobs_[kSc0 + 3] = {}, tempoFor_ = 0.0;
    double toneFor_ = -1.0, gateFor_ = 1.0;
    double levelA_[kControlFrames + 1] = {}, downA_[kControlFrames + 1] = {}, aDcOn_ = 0.0;
    uint32_t toEdge_ = 0;  // frames to the step's edge (0: look at the clock)
    double sumIn_ = 0.0, sumWet_ = 0.0, peak_ = 0.0, gateSmooth_ = 1.0, gateA_ = 1.0;
    uint32_t heard_ = 0;
    Ramp levelRamp_, gateRamp_;
    uint32_t gpos_ = 0;
    double freeBeat_ = 0.0, beatStep_ = 0.0, stepsPerBeat_ = 4.0, toneA_ = 1.0, gateThr_ = -1.0;
    double tone_[2] = {}, dc_[2] = {}, envIn_ = 0.0, envWet_ = 0.0, gateEnv_ = 0.0;
    uint32_t shownFrozen_ = 0, shownFlip_ = 0, shownOther_ = 0;
    std::vector<int16_t> echo_[2], grain_[2];
};

using V = std::vector<std::pair<std::string_view, double>>;
BuiltinPreset preset(const char* name, const char* description, V values) {
    values.emplace_back("variant", 1.0);
    return {name, description, std::move(values)};
}

const std::vector<BuiltinPreset>& presets() {
    static const std::vector<BuiltinPreset> p = {
        preset("Sign flip grit", "Lo-fi: the low bits inverted, a buzzy fizz under the sound", {{"bits", 12}, {"xor", 0x000f << 4}}),
        preset("Wrap around", "Sound design: shifted up past full scale, folding round", {{"bits", 16}, {"shift", 2}, {"output", -6}}),
        preset("Coarse steps", "Lo-fi: shifted down into a few big steps", {{"bits", 10}, {"shift", -4}}),
        preset("Top bits only", "Drums: only the top six bits kept, a gated crunch", {{"bits", 16}, {"and", 0xfc00}}),
        preset("Bit mangle bass", "Bass: the middle bits flipped, blended under the clean", {{"bits", 14}, {"xor", 0x0ff0}, {"mix", 0.35}}),
        preset("Broken radio", "Vocals: a narrow word with odd lanes masked", {{"bits", 8}, {"and", 0xaaff}, {"mix", 0.6}}),
        preset("Glitch lead", "Sound design: XOR on the upper lanes, a squealing edge", {{"bits", 12}, {"xor", 0x3000}, {"output", -6}}),
        preset("Mix bus 8-bit", "Mixing: a faint 8-bit layer under the mix", {{"bits", 8}, {"mix", 0.15}}),
        preset("Square maker", "Guitar: two bits, nearly a square, blended", {{"bits", 2}, {"mix", 0.3}, {"output", -12}}),
        // 1.1.1's glitch ops (Auto level on: none louder than the input).
        preset("Metal ring", "Sound design: XORed with its own word 3 ms ago, a ringing metallic comb",
               {{"bits", 12}, {"combine", 2}, {"echo", 3}, {"combine_mask", 0xff00}, {"tone", 9000}}),
        preset("Tin can echo", "Vocals: ANDed with a 9 ms echo on the top lanes, hollow and boxy, blended",
               {{"bits", 14}, {"combine", 2}, {"combine_op", 1}, {"echo", 9}, {"combine_mask", 0xf000}, {"mix", 0.5}}),
        preset("Key XOR", "Sound design: the key track XORed into the top lanes, bit by bit (route a key to it)",
               {{"bits", 12}, {"combine", 1}, {"combine_mask", 0xe000}, {"tone", 8000}, {"gate", -50}}),
        preset("Key carve", "Drums: the key's word ANDs the beat, it only sounds where both lanes are lit",
               {{"bits", 10}, {"combine", 1}, {"combine_op", 1}, {"combine_mask", 0xffc0}}),
        preset("Beat masks", "Drums: XOR and OR masks on the off-beat sixteenths only",
               {{"bits", 12}, {"xor", 0x0f00}, {"or", 0x0030}, {"rate", 2}, {"pattern", 0xaa}, {"tone", 12000}}),
        preset("Stutter freeze", "Drums: every other eighth, the top lanes loop a 15 ms grain, a stutter in time",
               {{"bits", 14}, {"freeze", 0xff00}, {"grain", 15}, {"hold", 0.8}, {"rate", 4}, {"pattern", 0x55}}),
        preset("Full freeze", "Sound design: the whole word loops a 30 ms grain on the beat's last sixteenth",
               {{"bits", 16}, {"freeze", 0xffff}, {"grain", 30}, {"hold", 1}, {"rate", 2}, {"pattern", 0x88}}),
        preset("Dice flips", "Lo-fi: lanes flip at random each sixteenth, seeded, so the render repeats",
               {{"bits", 10}, {"flips", 0.12}, {"seed", 7}, {"tone", 7000}, {"gate", -55}}),
        preset("Bit rotor", "Sound design: the word rotated one lane on alternate eighths, a gated chirp",
               {{"bits", 8}, {"rotate", 1}, {"rate", 4}, {"pattern", 0x66}, {"tone", 6000}, {"mix", 0.7}}),
        preset("Mirror grit", "Guitar: the lowest five lanes reversed, a fizzy edge under the clean",
               {{"bits", 12}, {"reverse", 5}, {"tone", 10000}, {"mix", 0.4}}),
        preset("Glitch bass", "Bass: OR on the low lanes and a 6 ms ring, smoothed to keep the low end",
               {{"bits", 12}, {"or", 0x00f0}, {"combine", 2}, {"echo", 6}, {"combine_mask", 0x0ff0}, {"tone", 2500}, {"mix", 0.6}}),
    };
    return p;
}

const ModuleDescriptor& bitwiseBase() {
    // Keyed (1.1.1): the sidechain is the Combine's key; unconnected it is silence and costs nothing.
    static const ModuleDescriptor d =
        withCpu(keyedEffectDescriptor(kBitsId, kBitsName, bitwiseParams(), 0, 0, false), CpuClass::Light);
    return d;
}

}  // namespace

const ModuleDescriptor& bitwiseDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = extendedVariantDescriptor(bitwiseBase(), kBitsId, kBitsName, labels, index, glitchParams());
    return d;
}
ModuleProcessor* makeBitwiseAs(const ModuleDescriptor& v) noexcept { return new (std::nothrow) Bitwise(v); }
std::span<const BuiltinPreset> bitwisePresets() { return presets(); }

}  // namespace caw::fx
