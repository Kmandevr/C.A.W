// Chirp (org.caw.pitchfix, 1.1.0): live pitch correction: YIN detection, a correction law toward a key and scale (or the key track's MIDI notes), TD-PSOLA resynthesis with the formant kept.
#include "builtin_fx_lark.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <vector>

#include "builtin_effects.h"
#include "caw/detmath.hpp"
#include "component_chain.h"
#include "lark_dsp.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0); the methods are in lark_dsp.h.
// - Detection: lark::Detector on the input's mid, an analysis every hop (256 frames at 48 kHz, 5.3 ms).
// - The correction law, per hop: the detected pitch m (MIDI), its centre c (two one-poles at 2 Hz, reset when m
//   leaves it by 1.5 semitones: a new note), the reference ref = c with Keep vibrato (so the vibrato above it
//   passes untouched; our own simple filter, not a vibrato detector) or m without; the target note nearest ref in
//   the key's scale (0.2-semitone hysteresis) or, with Target MIDI, the held key-track note nearest it; the wanted
//   shift target - ref (at most 12 semitones). The shift applied moves toward it with the Speed time constant
//   (0: at once); Humanize lengthens it up to 4x as a note is held (over 300 ms). Unvoiced input passes unshifted
//   and the shift starts again from 0 at the next voiced hop. Each analysis is kept (32 of them) with the input
//   time it describes (1.5 periods before its newest sample), so a grain takes the period and shift of its own
//   moment, between the two analyses around it, not the newest: the correction lines up with the vibrato it fixes.
// - Resynthesis (TD-PSOLA): the output lags the input by the latency D. Synthesis marks s are laid one target
//   period apart; each takes the analysis mark nearest s - D (a train one period apart, its first on the
//   waveform's peak at each voiced onset, where the synthesis is aligned to it, so in-tune input comes back as it
//   went in), a Hann grain two input periods long resampled by the formant factor, read sample by sample (so a
//   grain may end after the input it reads arrives: D need only cover the detection). Gain target period over the
//   grain's half length keeps the level. Unvoiced: 256-frame grains (512 above 70 kHz) at s - D exactly, which
//   overlap-add back to the input.
// - Latency: Full 25 ms (the 60 Hz floor's analysis window), Monitor 10 ms (the floor raised to 100 Hz, a 10.7 ms
//   window); `monitor` is set by hand and reported per instance (VariableLatency), so the chain compensates.
// - Mix blends with the dry input delayed by D, so a partial mix doesn't comb.

namespace caw::fx {

namespace {

constexpr uint32_t kMaxGrains = 16;
constexpr uint32_t kHistory = 64;
constexpr uint32_t kMaxHeld = 8;

constexpr std::string_view kKeys[] = {"C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"};
constexpr std::string_view kTargets[] = {"Scale", "MIDI"};
constexpr std::string_view kNoteIds[] = {"note_c", "note_cs", "note_d", "note_eb", "note_e", "note_f",
                                         "note_fs", "note_g", "note_ab", "note_a", "note_bb", "note_b"};
constexpr std::string_view kScales[] = {"Chromatic",  "Major",      "Minor",      "Harmonic minor", "Melodic minor",
                                        "Dorian",     "Phrygian",   "Lydian",     "Mixolydian",     "Major pentatonic",
                                        "Minor pentatonic", "Blues", "Custom"};
static_assert(sizeof(kScales) / sizeof(kScales[0]) == lark::kScaleCount);

enum Param : uint32_t {
    pKey, pScale, pNote0, pTarget = pNote0 + 12, pSpeed, pHumanize, pVibrato, pFormantKeep, pFormant, pLow, pHigh,
    pSensitivity, pMix, pOutput, pMonitor, pCount
};

const ParamTable& larkParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("key", "Key", 0.0, kKeys);
        p.pick("scale", "Scale", 0.0, kScales);
        for (uint32_t k = 0; k < 12; ++k) p.pick(std::string(kNoteIds[k]), std::string(kKeys[k]), 1.0, kOffOn);
        p.pick("target", "Target", 0.0, kTargets);
        p.num("speed", "Speed", 40.0, 0.0, 400.0, "ms");
        p.num("humanize", "Humanize", 0.0, 0.0, 1.0);
        p.pick("keep_vibrato", "Keep vibrato", 1.0, kOffOn);
        p.pick("formant_keep", "Formant keep", 1.0, kOffOn);
        p.num("formant", "Formant shift", 0.0, -12.0, 12.0, "st");
        p.expo("low", "Lowest pitch", 60.0, 50.0, 400.0, "Hz");
        p.expo("high", "Highest pitch", 1000.0, 200.0, 1600.0, "Hz");
        p.num("sensitivity", "Sensitivity", 0.5, 0.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        ParameterDescriptor& m = p.pick("monitor", "Low-latency monitoring", 0.0, kOffOn);
        m.automatable = m.modulatable = m.midiMappable = false;  // it sets the latency: by hand only
        return p;
    }();
    return t;
}

uint32_t latencyAt(double sr, bool monitor) noexcept {
    return static_cast<uint32_t>((monitor ? 0.010 : 0.025) * sr + 0.5);
}

const ModuleDescriptor& larkDescriptor() {
    static const ModuleDescriptor d =
        withCpu(keyedEffectDescriptor("org.caw.pitchfix", "Pitch fix", larkParams(), latencyAt(48000, false), 0, true),
                CpuClass::Medium);
    return d;
}

inline float finite0(float x) noexcept { return x == x && x - x == 0.0f ? x : 0.0f; }

uint32_t ringFor(double sr) noexcept {
    // D (25 ms) + a grain's reach (two periods of 50 Hz at the widest formant factor) + slack.
    const double need = 0.025 * sr + 2.0 * sr / 50.0 + 64.0;
    uint32_t n = 1;
    while (n < need) n <<= 1;
    return n;
}

class PitchFix final : public EffectBase, public VariableLatency, public ArmedFlag {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return larkDescriptor(); }
    uint32_t latencyFor(const double* values, uint32_t count) const noexcept override {
        return latencyAt(rate(), armed() || (values && count > pMonitor && values[pMonitor] >= 0.5));
    }
    // Armed: the 10 ms monitoring mode, as `monitor` On.
    bool armedDiffers(const double* values, uint32_t count) const noexcept override {
        return !(values && count > pMonitor && values[pMonitor] >= 0.5);
    }
    uint64_t idleFrames() const noexcept override { return delay_ + static_cast<uint64_t>(0.1 * rate()); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        if (!det_.prepare(sr)) return false;
        const uint32_t n = ringFor(sr);
        try {
            ringL_.assign(n, 0.0f);
            ringR_.assign(n, 0.0f);
        } catch (...) {
            return false;
        }
        mask_ = n - 1;
        unvoicedHop_ = sr > 70000.0 ? 512.0 : 256.0;
        delay_ = latencyAt(sr, false);
        return true;
    }
    void clearState() noexcept override {
        std::fill(ringL_.begin(), ringL_.end(), 0.0f);
        std::fill(ringR_.begin(), ringR_.end(), 0.0f);
        det_.clear();
        grains_ = 0;
        n_ = 0;
        sNext_ = 0.0, markA_ = 0.0;
        gVoiced_ = voiced_ = false;
        c1_ = c2_ = midi_ = 0.0;
        target_ = -1000;
        noteAge_ = 0.0;
        want_ = corr_ = 0.0;
        recAt_ = recs_ = 0;
        pendingValid_ = false;
        held_ = 0;
        hops_ = 0;
        histAt_ = 0;
        confidence_ = 0.0;
        for (uint32_t k = 0; k < kHistory; ++k) histIn_[k] = histOut_[k] = -1.0f;
        dry_.reset(), wet_.reset();
    }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const bool armedNow = armed();
        if (!knobsUnchanged(knobs_, pCount, at) || first_ || armedNow != armedSeen_) {
            armedSeen_ = armedNow;
            key_ = std::clamp(choice(pKey, at), 0, 11);
            scale_ = std::clamp(choice(pScale, at), 0, lark::kScaleCount - 1);
            uint16_t custom = 0;
            for (uint32_t k = 0; k < 12; ++k)
                if (on(pNote0 + k, at)) custom = static_cast<uint16_t>(custom | (1u << k));
            classes_ = lark::pitchClasses(scale_, key_, custom);
            midiTarget_ = choice(pTarget, at) == 1;
            speed_ = std::clamp(param(pSpeed, at), 0.0, 400.0) * 0.001;
            humanize_ = std::clamp(param(pHumanize, at), 0.0, 1.0);
            keepVibrato_ = on(pVibrato, at);
            formantKeep_ = on(pFormantKeep, at);
            formant_ = detPow(2.0, std::clamp(param(pFormant, at), -12.0, 12.0) / 12.0);
            const bool monitor = on(pMonitor, at) || armedNow;
            const double low = std::max(std::clamp(param(pLow, at), 50.0, 400.0), monitor ? 100.0 : 0.0);
            const double high = std::max(std::clamp(param(pHigh, at), 200.0, 1600.0), low * 2.0);
            const double sens = std::clamp(param(pSensitivity, at), 0.0, 1.0);
            det_.configure(low, high, monitor, 0.05 + 0.2 * sens);
            const uint32_t d = latencyAt(sr, monitor);
            if (d != delay_ || monitor != monitor_) {  // a new latency: start again from silence
                delay_ = d, monitor_ = monitor;
                clearState();
            }
            const double mix = std::clamp(param(pMix, at), 0.0, 1.0), out = lib::dbToGain(param(pOutput, at));
            dryTarget_ = (1.0 - mix) * out, wetTarget_ = mix * out;
            first_ = false;
            pendingValid_ = false;
        }
        dry_.set(dryTarget_, kControlFrames), wet_.set(wetTarget_, kControlFrames);
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const EventInput& notes = keyNotes();
        const uint32_t first = runStart();
        const float* L = ringL_.data();
        const float* R = ringR_.data();
        const int64_t mask = mask_;
        for (uint32_t i = 0; i < n; ++i) {
            if (notes.count) takeNotes(notes, first + i);
            const float l = finite0(inL[i]), r = finite0(inR[i]);
            ringL_[n_ & mask] = l;
            ringR_[n_ & mask] = r;
            if (det_.push(0.5f * (l + r))) hop();
            for (int k = 0; k < 4; ++k) {  // a grain starts where its window does
                if (!pendingValid_) plan();
                if (static_cast<double>(n_) < pending_.s - pending_.h) break;
                spawn();
            }
            double wl = 0.0, wr = 0.0;
            const double now = static_cast<double>(n_);
            for (uint32_t g = 0; g < grains_;) {
                Grain& gr = grain_[g];
                const double off = now - gr.s;
                const double x = off * gr.invH;
                if (x >= 1.0) {  // done: the last one takes its place
                    grain_[g] = grain_[--grains_];
                    continue;
                }
                const double w = lark::hann(x) * gr.g;
                double pos = gr.ac + off * gr.fs;
                pos = std::min(pos, now - 1.0);
                const double fl = std::floor(pos);
                const int64_t j = static_cast<int64_t>(fl);
                const double f = pos - fl;
                const float l0 = L[j & mask], l1 = L[(j + 1) & mask], r0 = R[j & mask], r1 = R[(j + 1) & mask];
                wl += w * (l0 + f * (l1 - l0));
                wr += w * (r0 + f * (r1 - r0));
                ++g;
            }
            const int64_t back = n_ - static_cast<int64_t>(delay_);
            const double d = dry_.next(), w = wet_.next();
            outL[i] = static_cast<float>(d * L[back & mask] + w * wl);
            outR[i] = static_cast<float>(d * R[back & mask] + w * wr);
            ++n_;
        }
    }

    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = voiced_ ? 1.0f : 0.0f;
        out[3] = voiced_ ? static_cast<float>(midi_) : -1.0f;
        out[4] = voiced_ && target_ > -1000 ? static_cast<float>(target_) : -1.0f;
        out[5] = static_cast<float>(corr_);
        out[6] = static_cast<float>(confidence_);
        out[7] = static_cast<float>(1000.0 * delay_ / rate());
        out[8] = monitor_ ? 1.0f : 0.0f;
        out[9] = static_cast<float>(key_);
        out[10] = static_cast<float>(scale_);
        out[11] = midiTarget_ ? 1.0f : 0.0f;
        for (uint32_t k = 0; k < 12; ++k) out[12 + k] = (classes_ >> k) & 1u ? 1.0f : 0.0f;
        out[24] = static_cast<float>(hops_ & 0xFFFFFFu);
        out[25] = static_cast<float>(kHistory);
        for (uint32_t k = 0; k < kHistory; ++k) {
            const uint32_t at = (histAt_ + k) % kHistory;
            out[26 + k] = histIn_[at];
            out[26 + kHistory + k] = histOut_[at];
        }
        return 26 + 2 * kHistory;
    }

private:
    struct Grain {
        double ac = 0, s = 0, h = 1, invH = 1, fs = 1, g = 0;
    };
    struct Rec {  // one analysis: the input time it describes, its period (0: unvoiced) and the shift then
        double t = 0, period = 0, corr = 0;
        bool voiced = false;
    };
    static constexpr uint32_t kRecs = 32;

    // One analysis: the correction law (see the file's comment), kept with the time it describes.
    void hop() noexcept {
        const lark::Detector::Result& res = det_.result();
        ++hops_;
        const double hopSec = det_.hopSeconds();
        Rec rec;
        if (res.voiced) {
            const double m = lark::hzToMidi(res.hz);
            const double a = 1.0 - detExp(-2.0 * lark::kPi * 2.0 * hopSec);
            if (!voiced_ || std::fabs(m - c2_) > 1.5) c1_ = c2_ = m;
            else c1_ += a * (m - c1_), c2_ += a * (c1_ - c2_);
            const double ref = keepVibrato_ ? c2_ : m;
            int target;
            if (midiTarget_ && held_) {
                target = notes_[0];
                for (uint32_t k = 1; k < held_; ++k)
                    if (std::fabs(ref - notes_[k]) < std::fabs(ref - target)) target = notes_[k];
            } else {
                target = lark::chooseTarget(ref, classes_, target_);
            }
            noteAge_ = target == target_ ? noteAge_ + hopSec : 0.0;
            target_ = target;
            want_ = std::clamp(target - ref, -12.0, 12.0);
            // The shift moves toward the wanted one with the Speed constant (Humanize lengthens it on held notes);
            // a new voiced run starts from 0.
            const double tau = speed_ * (1.0 + 3.0 * humanize_ * std::min(1.0, noteAge_ / 0.3));
            const double k = tau <= 1e-4 ? 1.0 : 1.0 - detExp(-hopSec / tau);
            if (!voiced_) corr_ = 0.0;
            corr_ += k * (want_ - corr_);
            midi_ = m;
            confidence_ = res.confidence;
            voiced_ = true;
            rec.t = static_cast<double>(n_) - 1.5 * res.lag;
            rec.period = res.lag;
            rec.corr = corr_;
            rec.voiced = true;
        } else {
            voiced_ = false;
            want_ = corr_ = 0.0;
            confidence_ = 0.0;
            rec.t = static_cast<double>(n_) - 0.5 * det_.hopFrames();
        }
        if (recs_) rec.t = std::max(rec.t, rec_[(recAt_ + kRecs - 1) % kRecs].t + 1.0);
        rec_[recAt_] = rec;
        recAt_ = (recAt_ + 1) % kRecs;
        recs_ = std::min(recs_ + 1, kRecs);
        pendingValid_ = false;
        histIn_[histAt_] = voiced_ ? static_cast<float>(midi_) : -1.0f;
        histOut_[histAt_] = voiced_ ? static_cast<float>(midi_ + corr_) : -1.0f;
        histAt_ = (histAt_ + 1) % kHistory;
    }

    // What the analyses say about input time x: voiced, its period and the shift (between the two analyses around
    // it, in a straight line; before the oldest or after the newest, that one).
    void lookup(double x, bool& voiced, double& period, double& corr) const noexcept {
        voiced = false, period = 0.0, corr = 0.0;
        if (!recs_) return;
        const uint32_t first = (recAt_ + kRecs - recs_) % kRecs;
        uint32_t i = 0;  // the newest analysis at or before x (0: the oldest when none is)
        for (uint32_t k = 0; k < recs_; ++k)
            if (rec_[(first + k) % kRecs].t <= x) i = k;
        const Rec& a = rec_[(first + i) % kRecs];
        if (i + 1 >= recs_ || x <= a.t) {
            voiced = a.voiced, period = a.period, corr = a.corr;
            return;
        }
        const Rec& b = rec_[(first + i + 1) % kRecs];
        const double f = (x - a.t) / (b.t - a.t);
        if (a.voiced && b.voiced) {
            voiced = true;
            period = a.period + f * (b.period - a.period);
            corr = a.corr + f * (b.corr - a.corr);
        } else {
            const Rec& n = f < 0.5 ? a : b;
            voiced = n.voiced, period = n.period, corr = n.corr;
        }
    }

    // The next grain, for synthesis mark sNext_: what the analyses say about its input time.
    void plan() noexcept {
        Grain& g = pending_;
        g.s = sNext_;
        const double mapped = sNext_ - static_cast<double>(delay_);
        bool voiced;
        double period, corr;
        lookup(mapped, voiced, period, corr);
        pendVoiced_ = voiced && period > 1.0;
        if (pendVoiced_) {
            const double ratio = corr == 0.0 ? 1.0 : detPow(2.0, corr / 12.0);
            g.fs = std::clamp((formantKeep_ ? 1.0 : ratio) * formant_, 0.5, 2.0);
            g.h = period / g.fs;
            pendPeriod_ = period;
            pendSpacing_ = period / ratio;
            g.g = pendSpacing_ / g.h;
        } else {
            g.fs = 1.0, g.h = unvoicedHop_, g.g = 1.0;
        }
        g.invH = 1.0 / g.h;
        pendingValid_ = true;
    }

    // Starts the planned grain: its analysis mark, then the next synthesis mark.
    void spawn() noexcept {
        Grain g = pending_;
        const double mapped = sNext_ - static_cast<double>(delay_);
        if (pendVoiced_) {
            // The mark nearest the input time, a period after the last; a run's first on the waveform's peak.
            const double p = pendPeriod_;
            if (!gVoiced_) {  // a voiced run starts: its first mark, and the synthesis aligned to it (in tune: the input)
                markA_ = epoch(mapped - 0.25 * p, mapped + 0.25 * p), gVoiced_ = true;
                sNext_ = g.s = markA_ + static_cast<double>(delay_);
            }
            for (int k = 0; k < 4 && markA_ + 0.5 * p < mapped; ++k) markA_ += p;
            if (markA_ + 0.5 * p < mapped || markA_ > mapped + p) markA_ = epoch(mapped - 0.25 * p, mapped + 0.25 * p);  // lost: again
            g.ac = markA_;
            sNext_ += pendSpacing_;
        } else {
            if (gVoiced_) sNext_ = std::ceil(sNext_), g.s = sNext_, gVoiced_ = false;
            g.ac = sNext_ - static_cast<double>(delay_);
            markA_ = g.ac;
            sNext_ += unvoicedHop_;
        }
        if (grains_ < kMaxGrains) grain_[grains_++] = g;
        pendingValid_ = false;
    }

    // The frame of the mid's largest sample in [from, to] (no later than the newest input).
    double epoch(double from, double to) const noexcept {
        const int64_t mask = mask_;
        int64_t i = static_cast<int64_t>(std::ceil(from));
        const int64_t end = std::min<int64_t>(static_cast<int64_t>(std::floor(to)), n_ - 1);
        int64_t best = std::min(i, end);
        float most = -1e30f;
        for (; i <= end; ++i) {
            const float v = ringL_[i & mask] + ringR_[i & mask];
            if (v > most) most = v, best = i;
        }
        return static_cast<double>(best);
    }

    // The key track's note events at frame `frame` of the block: ons are held, offs let go.
    void takeNotes(const EventInput& notes, uint32_t frame) noexcept {
        for (uint32_t e = 0; e < notes.count; ++e) {
            const Event& ev = notes.events[e];
            if (ev.frame != frame || ev.kind != EventKind::Note || ((ev.data[0] >> 28) & 0xFu) != 0x4u) continue;
            const uint32_t status = (ev.data[0] >> 20) & 0xFu;
            const int key = static_cast<int>((ev.data[0] >> 8) & 0x7Fu);
            const bool onNote = status == 0x9u && (ev.data[1] >> 16) != 0;
            uint32_t at = held_;
            for (uint32_t k = 0; k < held_; ++k)
                if (notes_[k] == key) at = k;
            if (onNote) {
                if (at == held_ && held_ < kMaxHeld) notes_[held_++] = key;
            } else if ((status == 0x8u || status == 0x9u) && at < held_) {
                for (uint32_t j = at + 1; j < held_; ++j) notes_[j - 1] = notes_[j];
                --held_;
            }
        }
    }

    lark::Detector det_;
    std::vector<float> ringL_, ringR_;
    uint32_t mask_ = 0;
    Grain grain_[kMaxGrains];
    uint32_t grains_ = 0;
    int64_t n_ = 0;
    double sNext_ = 0, markA_ = 0, unvoicedHop_ = 256;
    bool gVoiced_ = false, voiced_ = false;
    double c1_ = 0, c2_ = 0, midi_ = 0, noteAge_ = 0, want_ = 0, corr_ = 0;
    Rec rec_[kRecs];
    uint32_t recAt_ = 0, recs_ = 0;
    Grain pending_;
    bool pendingValid_ = false, pendVoiced_ = false;
    double pendPeriod_ = 0, pendSpacing_ = 0;
    double confidence_ = 0;
    int target_ = -1000;
    int notes_[kMaxHeld] = {};
    uint32_t held_ = 0;
    double knobs_[pCount] = {};
    int key_ = 0, scale_ = 0;
    uint16_t classes_ = 0xFFF;
    bool midiTarget_ = false, keepVibrato_ = true, formantKeep_ = true, monitor_ = false, first_ = true, armedSeen_ = false;
    double speed_ = 0.04, humanize_ = 0, formant_ = 1;
    double dryTarget_ = 0, wetTarget_ = 1;
    uint32_t delay_ = 1200;
    uint32_t hops_ = 0, histAt_ = 0;
    float histIn_[kHistory] = {}, histOut_[kHistory] = {};
    Ramp dry_, wet_;
};

ModuleProcessor* makePitchFix() noexcept { return new (std::nothrow) PitchFix(); }

using V = std::vector<std::pair<std::string_view, double>>;

}  // namespace

void registerLark(ModuleRegistry& registry) {
    lark::warmTables();
    registry.add(larkDescriptor(), &makePitchFix);
}

size_t larkBytes(double sr) noexcept {
    const size_t det = (1536 + static_cast<size_t>(sr / 50.0) + 16) * sizeof(float);
    uint32_t full = 1;
    while (full < 1536 + static_cast<uint32_t>(sr / 50.0) + 16) full <<= 1;
    return sizeof(PitchFix) + 2 * ringFor(sr) * sizeof(float) + full * sizeof(float) + det;
}

const std::vector<BuiltinPreset>* larkPresets(std::string_view id) {
    static const std::vector<BuiltinPreset> p = {
        {"Natural vocal", "Vocals: a gentle pull to the key, the vibrato and slides kept", V{{"speed", 60}, {"humanize", 0.4}}},
        {"Hard tune", "Vocals: instant snaps between notes, the robotic pop effect", V{{"speed", 0}, {"keep_vibrato", 0}, {"humanize", 0}}},
        {"Gentle polish", "Vocals: slow and light, for a nearly in-tune take", V{{"speed", 150}, {"humanize", 0.7}}},
        {"Pop lead (C major)", "Vocals: a quick lead correction in C major", V{{"scale", 1}, {"speed", 25}, {"humanize", 0.2}}},
        {"Minor ballad", "Vocals: A minor, slow with long notes left to breathe", V{{"key", 9}, {"scale", 2}, {"speed", 90}, {"humanize", 0.6}}},
        {"Blues bends", "Vocals: the blues scale, the bends kept", V{{"scale", 11}, {"speed", 80}, {"humanize", 0.5}}},
        {"Pentatonic hook", "Vocals: major pentatonic, so no note lands between the cracks", V{{"scale", 9}, {"speed", 30}}},
        {"Follow MIDI", "Vocals: the key track's notes set the target (route a MIDI track to the key)", V{{"target", 1}, {"speed", 20}}},
        {"Live monitor", "Vocals: the 10 ms low-latency mode while a track is armed", V{{"monitor", 1}, {"speed", 40}}},
        {"Bass voice", "Vocals: a low range (50-400 Hz) for bass and baritone", V{{"low", 50}, {"high", 400}, {"speed", 60}}},
        {"Deeper voice", "Sound design: the formants lowered 4 semitones, the pitch kept in tune", V{{"formant", -4}, {"speed", 40}}},
        {"Cartoon", "Sound design: the formants follow the shift and rise 5 semitones", V{{"formant_keep", 0}, {"formant", 5}, {"speed", 0}}},
        {"Parallel tune", "Mixing: half corrected under the dry voice, a doubled thickness", V{{"mix", 0.5}, {"speed", 10}}},
    };
    return id == "org.caw.pitchfix" ? &p : nullptr;
}

}  // namespace caw::fx
