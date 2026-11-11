// The FX rack (fx-racks, "org.caw.rack.fx"): up to 8 built-in effects in series, with LFOs, followers, envelopes, random and macros routed to their knobs.
#include <algorithm>
#include <cmath>

#include "builtin_fx_racks_internal.h"
#include "caw/library/dynamics.hpp"
#include "caw/library/envelope.hpp"
#include "mod_route.h"

namespace caw {
namespace fx {

namespace {

constexpr uint32_t kSlots = 8, kMacros = 8, kLfos = 4, kFollowers = 2, kEnvs = 2, kPoints = 16;
constexpr std::string_view kLfoShapes[] = {"Sine",   "Triangle",      "Saw up",        "Saw down",
                                           "Square", "Sample & hold", "Smooth random", "Custom"};
enum Shape : int { kSine, kTriangle, kSawUp, kSawDown, kSquare, kSampleHold, kSmoothRandom, kCustom };
// Free: runs on its own (a synced rate follows the tempo). Retrigger: restarts on each key note. Song: locked to the
// song position while it plays (synced rates only).
constexpr std::string_view kLfoModes[] = {"Free", "Retrigger", "Song"};
enum LfoMode : int { kFree, kRetrigger, kSong };
constexpr std::string_view kFollowSources[] = {"Input", "Sidechain"};
// Source numbers (kRackSources).
enum : uint32_t { kSrcNone, kSrcLfo1, kSrcFollow1 = kSrcLfo1 + kLfos, kSrcEnv1 = kSrcFollow1 + kFollowers,
                  kSrcRandom = kSrcEnv1 + kEnvs, kSrcMacro1 = kSrcRandom + 1 };
static_assert(kSrcMacro1 + kMacros == kRackSourceCount);

struct Indices {
    uint32_t macro[kMacros];
    struct Lfo { uint32_t shape, rate, sync, phase, mode, points[kPoints]; } lfo[kLfos];
    struct Follow { uint32_t src, attack, release, gain; } follow[kFollowers];
    struct Env { uint32_t attack, decay, sustain, release; } env[kEnvs];
    uint32_t rndRate, rndSync, rndSmooth, mix, output;
};

struct FxLayout {
    RackLayout layout;
    Indices k{};
    FxLayout() {
        ParamTable& p = layout.own;
        for (uint32_t s = 0; s < kSlots; ++s) layout.addSlot("s" + std::to_string(s + 1), "S" + std::to_string(s + 1), 0);
        for (uint32_t m = 0; m < kMacros; ++m)
            p.num("macro" + std::to_string(m + 1), "Macro " + std::to_string(m + 1), 0.0, 0.0, 1.0);
        for (uint32_t l = 0; l < kLfos; ++l) {
            const std::string i = "lfo" + std::to_string(l + 1) + "_", n = "LFO " + std::to_string(l + 1) + " ";
            p.pick(i + "shape", n + "shape", kSine, kLfoShapes);
            p.expo(i + "rate", n + "rate", 1.0, 0.01, 40.0, "Hz");
            p.pick(i + "sync", n + "sync", 0.0, kSyncDivisions);
            p.num(i + "phase", n + "phase", 0.0, 0.0, 1.0);
            p.pick(i + "mode", n + "mode", kFree, kLfoModes);
            for (uint32_t q = 0; q < kPoints; ++q)  // the Custom shape: a sine to start from
                p.num(i + "p" + std::to_string(q + 1), n + "point " + std::to_string(q + 1),
                      0.5 + 0.5 * std::sin(2.0 * 3.14159265358979323846 * q / kPoints), 0.0, 1.0)
                    .smoothingFrames = 0;
        }
        for (uint32_t f = 0; f < kFollowers; ++f) {
            const std::string i = "fol" + std::to_string(f + 1) + "_", n = "Follower " + std::to_string(f + 1) + " ";
            p.pick(i + "src", n + "input", 0.0, kFollowSources);
            p.expo(i + "attack", n + "attack", 10.0, 0.1, 500.0, "ms");
            p.expo(i + "release", n + "release", 150.0, 5.0, 5000.0, "ms");
            p.num(i + "gain", n + "gain", 0.0, -24.0, 24.0, "dB");
        }
        for (uint32_t e = 0; e < kEnvs; ++e) {
            const std::string i = "env" + std::to_string(e + 1) + "_", n = "Env " + std::to_string(e + 1) + " ";
            p.expo(i + "attack", n + "attack", 0.005, 0.001, 10.0, "s");
            p.expo(i + "decay", n + "decay", 0.3, 0.001, 10.0, "s");
            p.num(i + "sustain", n + "sustain", 0.5, 0.0, 1.0);
            p.expo(i + "release", n + "release", 0.3, 0.001, 10.0, "s");
        }
        p.expo("rnd_rate", "Random rate", 4.0, 0.05, 40.0, "Hz");
        p.pick("rnd_sync", "Random sync", 0.0, kSyncDivisions);
        p.num("rnd_smooth", "Random smooth", 0.0, 0.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        auto at = [&](const std::string& id) { return static_cast<uint32_t>(p.index(id)); };
        for (uint32_t m = 0; m < kMacros; ++m) k.macro[m] = at("macro" + std::to_string(m + 1));
        for (uint32_t l = 0; l < kLfos; ++l) {
            const std::string i = "lfo" + std::to_string(l + 1) + "_";
            k.lfo[l] = {at(i + "shape"), at(i + "rate"), at(i + "sync"), at(i + "phase"), at(i + "mode"), {}};
            for (uint32_t q = 0; q < kPoints; ++q) k.lfo[l].points[q] = at(i + "p" + std::to_string(q + 1));
        }
        for (uint32_t f = 0; f < kFollowers; ++f) {
            const std::string i = "fol" + std::to_string(f + 1) + "_";
            k.follow[f] = {at(i + "src"), at(i + "attack"), at(i + "release"), at(i + "gain")};
        }
        for (uint32_t e = 0; e < kEnvs; ++e) {
            const std::string i = "env" + std::to_string(e + 1) + "_";
            k.env[e] = {at(i + "attack"), at(i + "decay"), at(i + "sustain"), at(i + "release")};
        }
        k.rndRate = at("rnd_rate"), k.rndSync = at("rnd_sync"), k.rndSmooth = at("rnd_smooth");
        k.mix = at("mix"), k.output = at("output");
        layout.finish(kFxRackId, "FX rack", true, true);
    }
};

const FxLayout& fxLayout() {
    static const FxLayout l;
    return l;
}

double unitHash(uint32_t seed, uint64_t cycle) noexcept { return modUnitHash(seed, cycle); }
double frac(double x) noexcept { return x - std::floor(x); }

bool noteOn(const Event& e) noexcept { return ((e.data[0] >> 28) & 0xFu) == 0x4u && ((e.data[0] >> 20) & 0xFu) == 0x9u; }
bool noteOff(const Event& e) noexcept { return ((e.data[0] >> 28) & 0xFu) == 0x4u && ((e.data[0] >> 20) & 0xFu) == 0x8u; }

class FxRack final : public RackBase {
public:
    const RackLayout& layout() const noexcept override { return fxLayout().layout; }

protected:
    bool prepare(double sampleRate) override {
        uint32_t cap = 0;
        for (const Slot& s : slots_) cap += s.latencyCap;
        dry_.prepare(cap);
        latencyCap_ = cap;
        for (lib::Adsr& e : env_) e.clear();
        (void)sampleRate;
        return true;
    }

    void clearState() noexcept override {
        for (lib::EnvelopeFollower& f : follow_) f.clear();
        for (lib::Adsr& e : env_) e.clear();
        dry_.clear();
        mix_.reset();
        gain_.reset();
        pendingOn_ = false;
        held_ = 0;
        wasHeld_ = false;
        for (double& u : src_) u = 0.0;
        tCount_ = 0;
    }

    bool canSleep() const noexcept override {
        if (held_ > 0) return false;
        for (const lib::Adsr& e : env_)
            if (e.active()) return false;
        return true;
    }

    void countNotes(uint32_t at, uint32_t n) noexcept {
        uint32_t count = 0;
        const Event* ev = chunkEvents(at, n, count);
        for (uint32_t k = 0; k < count; ++k) {
            if (noteOn(ev[k])) ++held_, pendingOn_ = true;
            else if (noteOff(ev[k]) && held_ > 0) --held_;
        }
    }
    void idleEvents(uint32_t at, uint32_t n) noexcept override { countNotes(at, n); }

    double lfoShape(uint32_t l, int shape, double p, uint64_t cycle, uint32_t at) const noexcept {
        switch (shape) {
            case kSine: case kTriangle: case kSawUp: case kSawDown: case kSquare: case kSampleHold: case kSmoothRandom:
                return modLfoShape(shape, p, cycle, 0x1000u + l);  // the shapes the project LFO shares (mod_route.h)
            default: {  // Custom: the 16 points, joined by straight lines, around the cycle
                const Indices::Lfo& k = fxLayout().k.lfo[l];
                const double x = p * kPoints;
                const uint32_t i = std::min<uint32_t>(static_cast<uint32_t>(x), kPoints - 1);
                const double a = paramAt(k.points[i], at), b = paramAt(k.points[(i + 1) % kPoints], at);
                return 2.0 * (a + (b - a) * (x - i)) - 1.0;
            }
        }
    }

    void control(uint32_t at) noexcept override {
        const Indices& k = fxLayout().k;
        const double sr = rate();
        const double step = static_cast<double>(kRackControlFrames);
        bool playing = false;
        double beat = 0.0;
        if (const Transport* t = transport(); t && t->playing) {
            playing = true;
            beat = t->beat + static_cast<double>(at) * tempo() / (60.0 * sr);
        }
        const bool retrigger = pendingOn_;
        // LFOs: their value here, then on 16 frames.
        for (uint32_t l = 0; l < kLfos; ++l) {
            const int sync = std::clamp(choiceAt(k.lfo[l].sync, at), 0, kSyncCount - 1);
            const int mode = std::clamp(choiceAt(k.lfo[l].mode, at), 0, 2);
            const double cycleBeats = kSyncWholeNotes[sync] * 4.0;
            const double hz = sync > 0 ? tempo() / (60.0 * cycleBeats) : paramAt(k.lfo[l].rate, at);
            if (mode == kRetrigger && retrigger) lfoPhase_[l] = 0.0, lfoCycle_[l] = 0;
            if (mode == kSong && sync > 0 && playing) {
                const double c = beat / cycleBeats;
                lfoCycle_[l] = static_cast<uint64_t>(std::max(0.0, std::floor(c)));
                lfoPhase_[l] = frac(c);
            }
            const double p = frac(lfoPhase_[l] + paramAt(k.lfo[l].phase, at));
            const double v = lfoShape(l, std::clamp(choiceAt(k.lfo[l].shape, at), 0, 7), p, lfoCycle_[l], at);
            src_[kSrcLfo1 + l] = 0.5 * (std::clamp(v, -1.0, 1.0) + 1.0);
            lfoPhase_[l] += hz * step / sr;
            if (lfoPhase_[l] >= 1.0) {
                const double whole = std::floor(lfoPhase_[l]);
                lfoCycle_[l] += static_cast<uint64_t>(whole);
                lfoPhase_[l] -= whole;
            }
        }
        // Followers: their level so far (chunk() runs them per sample).
        for (uint32_t f = 0; f < kFollowers; ++f) {
            follow_[f].setCoefficients(lib::timeCoefficient(paramAt(k.follow[f].attack, at) * 0.001, sr),
                                       lib::timeCoefficient(paramAt(k.follow[f].release, at) * 0.001, sr));
            followKey_[f] = choiceAt(k.follow[f].src, at) == 1;
            src_[kSrcFollow1 + f] = std::clamp(follow_[f].value() * lib::dbToGain(paramAt(k.follow[f].gain, at)), 0.0, 1.0);
        }
        // Envelopes: gated by the key's notes (a new note restarts them from where they are).
        const bool held = held_ > 0;
        for (uint32_t e = 0; e < kEnvs; ++e) {
            env_[e].set(paramAt(k.env[e].attack, at), paramAt(k.env[e].decay, at), paramAt(k.env[e].sustain, at),
                        paramAt(k.env[e].release, at), sr);
            if (retrigger) env_[e].gateOn();
            else if (!held && wasHeld_) env_[e].gateOff();
            src_[kSrcEnv1 + e] = env_[e].level();
            env_[e].skip(kRackControlFrames);
        }
        if (retrigger && !held) {
            for (lib::Adsr& e : env_) e.gateOff();  // a note on and off within one grid step
        }
        wasHeld_ = held;
        pendingOn_ = false;
        // Random: a new value each cycle, glided into by `smooth`.
        {
            const int sync = std::clamp(choiceAt(k.rndSync, at), 0, kSyncCount - 1);
            const double hz = sync > 0 ? tempo() / (60.0 * kSyncWholeNotes[sync] * 4.0) : paramAt(k.rndRate, at);
            const double a = unitHash(0x2000u, rndCycle_), b = unitHash(0x2000u, rndCycle_ + 1);
            const double t = rndPhase_ * rndPhase_ * (3.0 - 2.0 * rndPhase_);
            const double smooth = std::clamp(paramAt(k.rndSmooth, at), 0.0, 1.0);
            src_[kSrcRandom] = a + (b - a) * t * smooth;
            rndPhase_ += hz * step / sr;
            if (rndPhase_ >= 1.0) {
                const double whole = std::floor(rndPhase_);
                rndCycle_ += static_cast<uint64_t>(whole);
                rndPhase_ -= whole;
            }
        }
        for (uint32_t m = 0; m < kMacros; ++m) src_[kSrcMacro1 + m] = std::clamp(paramAt(k.macro[m], at), 0.0, 1.0);
        // The routes: each target's summed offset, in normalized travel.
        const ModuleDescriptor& d = descriptor();
        const uint32_t modBase = built_.modBase;
        const uint32_t childBase = layout().own.size();
        tCount_ = 0;
        for (uint32_t r = 0; r < kRackRoutes; ++r) {
            routeOffset_[r] = 0.0;
            const uint32_t base = modBase + r * 4;
            if (base + 3 >= d.parameterCount) break;
            const int src = std::clamp(choiceAt(base, at), 0, static_cast<int>(kRackSourceCount) - 1);
            const int dst = choiceAt(base + 1, at) - 1;
            const double amount = std::clamp(paramAt(base + 2, at), -1.0, 1.0);
            if (src == kSrcNone || dst < static_cast<int>(childBase) || dst >= static_cast<int>(modBase) || amount == 0.0)
                continue;
            if (!d.parameters[dst].modulatable) continue;
            const double u = src_[src];
            const double offset = modRouteOffset(u, amount, on(base + 3, at));  // the one route rule (mod_route.h)
            routeOffset_[r] = offset;
            uint32_t t = 0;
            while (t < tCount_ && tParam_[t] != static_cast<uint32_t>(dst)) ++t;
            if (t == tCount_) tParam_[tCount_] = static_cast<uint32_t>(dst), tOff_[tCount_++] = 0.0;
            tOff_[t] += offset;
        }
        // Latency: the switched-on children's, summed (the dry path waits as long).
        uint32_t latency = 0;
        for (size_t s = 0; s < slots_.size(); ++s) {
            const Slot& slot = slots_[s];
            if (!slot.processor || !on(static_cast<uint32_t>(layout().slots[s].on), at)) continue;
            if (slot.variable) {
                for (uint32_t q = 0; q < slot.count; ++q) latencyValues_[slot.first + q] = paramAt(slot.first + q, at);
                latency += childLatency(slot, latencyValues_.data(), static_cast<uint32_t>(latencyValues_.size()));
            } else {
                latency += childLatency(slot, nullptr, 0);
            }
        }
        latency_ = std::min(latency, latencyCap_);
        mix_.set(std::clamp(paramAt(k.mix, at), 0.0, 1.0), kRackControlFrames);
        gain_.set(lib::dbToGain(paramAt(k.output, at)), kRackControlFrames);
    }

    double modulated(const ParameterDescriptor& p, double base, double offset) const noexcept {
        return modulatedValue(p, base, offset);
    }

    void chunk(const float* inL, const float* inR, float* outL, float* outR, uint32_t n, uint32_t at) noexcept override {
        std::copy_n(inL, n, in_[0]);
        std::copy_n(inR, n, in_[1]);
        countNotes(at, n);
        sliceChildValues(at);
        const ModuleDescriptor& d = descriptor();
        for (uint32_t t = 0; t < tCount_; ++t) {
            const uint32_t p = tParam_[t];
            const ParameterValue v = childValues_[p];
            if (v.samples) {
                for (uint32_t i = 0; i < n; ++i) modBuf_[t][i] = modulated(d.parameters[p], v.samples[i], tOff_[t]);
                childValues_[p] = ParameterValue{modBuf_[t], modBuf_[t][0]};
            } else {
                childValues_[p] = ParameterValue{nullptr, modulated(d.parameters[p], v.value, tOff_[t])};
            }
        }
        float* cur[2] = {a_[0], a_[1]};
        float* other[2] = {b_[0], b_[1]};
        std::copy_n(in_[0], n, cur[0]);
        std::copy_n(in_[1], n, cur[1]);
        for (Slot& s : slots_) {
            if (!s.processor) continue;
            runChild(s, cur[0], cur[1], other[0], other[1], n, at);
            std::swap(cur[0], other[0]);
            std::swap(cur[1], other[1]);
        }
        const float* keyL = keyLeft();
        const float* keyR = keyRight();
        for (uint32_t i = 0; i < n; ++i) {
            const double x = std::max(std::fabs(in_[0][i]), std::fabs(in_[1][i]));
            const double key = keyL && keyR ? std::max(std::fabs(keyL[at + i]), std::fabs(keyR[at + i])) : 0.0;
            for (uint32_t f = 0; f < kFollowers; ++f) follow_[f].process(followKey_[f] ? key : x);
            float dl = in_[0][i], dr = in_[1][i];
            dry_.tick(dl, dr, latency_);
            const double m = mix_.next(), g = gain_.next();
            outL[i] = static_cast<float>((dl + (cur[0][i] - dl) * m) * g);
            outR[i] = static_cast<float>((dr + (cur[1][i] - dr) * m) * g);
        }
    }

    // 0 input peak, 1 output peak, 2 sources (17); 3..19 each source now (0..1, kRackSources from LFO 1);
    // 20..35 each route's offset now (normalized travel; 0 for an unused route).
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(kRackSourceCount - 1);
        for (uint32_t s = 1; s < kRackSourceCount; ++s) out[2 + s] = static_cast<float>(src_[s]);
        for (uint32_t r = 0; r < kRackRoutes; ++r) out[2 + kRackSourceCount + r] = static_cast<float>(routeOffset_[r]);
        return 2 + kRackSourceCount + kRackRoutes;
    }

    uint32_t latencyOf(const double* values, uint32_t count) const noexcept override {
        uint32_t latency = 0;
        for (size_t s = 0; s < slots_.size(); ++s) {
            const int onIndex = layout().slots[s].on;
            if (!slots_[s].processor || static_cast<uint32_t>(onIndex) >= count || values[onIndex] < 0.5) continue;
            latency += childLatency(slots_[s], values, count);
        }
        return std::min(latency, latencyCap_);
    }

private:
    float in_[2][kRackControlFrames] = {}, a_[2][kRackControlFrames] = {}, b_[2][kRackControlFrames] = {};
    double modBuf_[kRackRoutes][kRackControlFrames] = {};
    uint32_t tParam_[kRackRoutes] = {};
    double tOff_[kRackRoutes] = {}, routeOffset_[kRackRoutes] = {};
    uint32_t tCount_ = 0;
    double src_[kRackSourceCount] = {};
    double lfoPhase_[kLfos] = {};
    uint64_t lfoCycle_[kLfos] = {};
    double rndPhase_ = 0.0;
    uint64_t rndCycle_ = 0;
    lib::EnvelopeFollower follow_[kFollowers];
    bool followKey_[kFollowers] = {};
    lib::Adsr env_[kEnvs];
    uint32_t held_ = 0;
    bool pendingOn_ = false, wasHeld_ = false;
    Ramp mix_, gain_;
    RackDelay dry_;
    uint32_t latency_ = 0, latencyCap_ = 0;
};

ModuleProcessor* makeFxRack() noexcept { return new (std::nothrow) FxRack(); }

}  // namespace

void registerFxRack(ModuleRegistry& registry) { registry.add(fxLayout().layout.staticBuild.desc, &makeFxRack); }

}  // namespace fx
}  // namespace caw
