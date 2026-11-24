// Mimic (org.caw.vocoder, 1.1.0): a channel vocoder on the shared band filterbank, its carrier built in (played by the key track's notes) or the key track itself.
#include "builtin_effects.h"
#include "builtin_fx_voice.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/eq.hpp"
#include "caw/library/oscillator.hpp"
#include "fx_bandbank.h"
#include "fx_sidechain.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0); the channel vocoder is Dudley's (1939), its band design the shared
// filterbank's (fx_bandbank.h, the same as Swoop's Carve). No latency, so it is safe on an armed track.
// - The modulator is the input's mid: Bands log-spaced 4th-order band-passes from Low to High (12, 20 or 32; Auto
//   follows the quality, Eco 12, Normal 20, High 32), each followed with Attack and Release.
// - The carrier runs through the same bands; each band is weighted by the modulator's level in the band Formant
//   semitones lower (interpolated between bands, held at the ends; positive moves the formants up), divided by the
//   carrier's own level there (followed over 2 ms and 30 ms; at most +40 dB), so any carrier speaks at the
//   modulator's spectrum and level ("carrier flattening"). The weights move at control rate (16 frames), ramped.
// - Carrier Built-in: a saw, pulse (35 %) or white noise, with Unison 1-3 copies Detune cents apart, Octave and
//   Glide. It plays the notes the key track plays (its sidechain's key_notes: note-ons within 10 ms of each other
//   make a chord of up to 8, a later one starts a new chord; a note-off, if one comes, lets its note go) and, with
//   none held, `note`, so it always speaks. Carrier Sidechain: the key track's audio (its mid) is the carrier.
// - Sibilance: the modulator high-passed at 5 kHz (24 dB/octave) is added, so consonants stay clear.
// - Width spreads the bands: even bands lean left, odd bands right. Freeze holds the band levels.

namespace caw::fx {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr uint32_t kMaxBands = 32;
constexpr uint32_t kMaxNotes = 8;
constexpr uint32_t kMaxUnison = 3;

constexpr std::string_view kCarriers[] = {"Built-in", "Sidechain"};
constexpr std::string_view kWaves[] = {"Saw", "Pulse", "Noise"};
constexpr std::string_view kBandChoices[] = {"Auto", "12", "20", "32"};
constexpr uint32_t kBandCounts[] = {12, 20, 32};

enum VoParam : uint32_t {
    voCarrier, voWave, voNote, voOctave, voUnison, voDetune, voGlide, voBands, voLow, voHigh, voSharp, voAttack,
    voRelease, voFormant, voSibilance, voWidth, voFreeze, voMix, voOutput, voCount
};

const ParamTable& vocoderParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("carrier", "Carrier", 0.0, kCarriers);
        p.pick("wave", "Wave", 0.0, kWaves);
        p.num("note", "Note", 48.0, 24.0, 96.0).step = 1.0;
        p.num("octave", "Octave", 0.0, -2.0, 2.0).step = 1.0;
        p.num("unison", "Unison", 1.0, 1.0, 3.0).step = 1.0;
        p.num("detune", "Detune", 12.0, 0.0, 50.0, "ct");
        p.expo("glide", "Glide", 1.0, 1.0, 500.0, "ms");
        p.pick("bands", "Bands", 0.0, kBandChoices);
        p.expo("low", "Low", 80.0, 50.0, 400.0, "Hz");
        p.expo("high", "High", 12000.0, 3000.0, 16000.0, "Hz");
        p.num("sharpness", "Sharpness", 1.0, 0.5, 2.0);
        p.expo("attack", "Attack", 4.0, 0.5, 50.0, "ms");
        p.expo("release", "Release", 40.0, 5.0, 500.0, "ms");
        p.num("formant", "Formant", 0.0, -12.0, 12.0, "st");
        p.num("sibilance", "Sibilance", 0.3, 0.0, 1.0);
        p.num("width", "Width", 0.3, 0.0, 1.0);
        p.pick("freeze", "Freeze", 0.0, kOffOn);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        addSidechainParams(p);  // 1.1.0: the key carrier's filter and Listen, appended off
        return p;
    }();
    return t;
}

const ModuleDescriptor& vocoderDescriptor() {
    static const ModuleDescriptor d = keyedEffectDescriptor("org.caw.vocoder", "Vocoder", vocoderParams(), 0, 0, true);
    return d;
}

inline float finite0(float x) noexcept { return x == x && x - x == 0.0f ? x : 0.0f; }

class Vocoder final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return vocoderDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        lib::SvfMix hp;
        const double g = detTan(kPi * std::min(5000.0, 0.4 * sr) / sr), k = 1.4142135623730951;  // below Nyquist at 8 kHz
        hp.set(g, k, 1.0, -k, -1.0);
        sib_ = hp;
        sc_.bind(descriptor());
        return true;
    }
    void clearState() noexcept override {
        an_.clear(), syn_.clear();
        sibA_.clear(), sibB_.clear();
        sc_.clear();
        count_ = 0;
        held_ = 0;
        t_ = 0;
        lastOn_ = -1000000;
        noise_ = 0x2545F491u;
        for (auto& v : osc_) {
            for (double& p : v.phase) p = 0.0;
            v.hz = 0.0;
        }
        for (float& f : frozen_) f = 0.0f;
        first_ = true;
        dry_.reset(), wet_.reset(), sibGain_.reset();
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>((release_ + 0.1) * rate()); }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const int q = quality();
        const int pick = std::clamp(choice(voBands, at), 0, 3);
        const uint32_t bands = pick == 0 ? kBandCounts[std::clamp(q, 0, 2)] : kBandCounts[pick - 1];
        const bool changed = !knobsUnchanged(knobs_, voCount, at);
        if (sc_.bound()) sc_.set(param(sc_.hp, at), param(sc_.lp, at), on(sc_.li, at), sr);
        if (changed || first_ || bands != count_) {
            carrier_ = std::clamp(choice(voCarrier, at), 0, 1);
            wave_ = std::clamp(choice(voWave, at), 0, 2);
            drone_ = std::clamp(std::floor(param(voNote, at) + 0.5), 24.0, 96.0);
            octave_ = std::clamp(std::floor(param(voOctave, at) + 0.5), -2.0, 2.0);
            unison_ = static_cast<uint32_t>(std::clamp(static_cast<int>(param(voUnison, at) + 0.5), 1, static_cast<int>(kMaxUnison)));
            detune_ = std::clamp(param(voDetune, at), 0.0, 50.0);
            glide_ = 1.0 - detExp(-static_cast<double>(kControlFrames) / (std::max(1.0, param(voGlide, at)) * 0.001 * sr));
            const double low = std::clamp(param(voLow, at), 50.0, 400.0);
            const double highLo = std::min(3000.0, 0.4 * sr), highHi = std::max(std::min(16000.0, 0.45 * sr), highLo);
            const double high = std::clamp(param(voHigh, at), highLo, highHi);
            const double sharp = std::clamp(param(voSharp, at), 0.5, 2.0);
            const double attack = std::clamp(param(voAttack, at), 0.5, 50.0) * 0.001;
            release_ = std::clamp(param(voRelease, at), 5.0, 500.0) * 0.001;
            formant_ = std::clamp(param(voFormant, at), -12.0, 12.0);
            sibTarget_ = std::clamp(param(voSibilance, at), 0.0, 1.0);
            width_ = std::clamp(param(voWidth, at), 0.0, 1.0);
            freeze_ = on(voFreeze, at);
            const double mix = std::clamp(param(voMix, at), 0.0, 1.0), out = lib::dbToGain(param(voOutput, at));
            dryTarget_ = (1.0 - mix) * out, wetTarget_ = mix * out;
            if (bands != count_ || low != low_ || high != high_ || sharp != sharp_ || first_) {
                // Each stage's Q from the band spacing: two stages cross near -6 dB at Sharpness 1.
                const double spacing = std::log2(high / low) / static_cast<double>(bands - 1);
                const double qq = sharp * 0.7 / (spacing * 0.6931471805599453);
                if (bands != count_) an_.clear(), syn_.clear();
                an_.setup(bands, low, high, qq, sr);
                syn_.setup(bands, low, high, qq, sr);
                count_ = bands, low_ = low, high_ = high, sharp_ = sharp;
                spacing_ = spacing;
            }
            an_.setTimes(attack, release_, sr);
            syn_.setTimes(0.002, 0.030, sr);
            const float side = static_cast<float>(width_);
            for (uint32_t b = 0; b < count_; ++b) {
                const bool odd = (b & 1u) != 0;
                syn_.setPan(b, odd ? 1.0f - side : 1.0f, odd ? 1.0f : 1.0f - side);
            }
        }
        // Each carrier band's weight: the modulator's level Formant semitones lower, over the carrier's own.
        const double offset = formant_ / 12.0 / spacing_;
        float target[kMaxBands];
        for (uint32_t c = 0; c < count_; ++c) {
            const double pos = std::clamp(static_cast<double>(c) - offset, 0.0, static_cast<double>(count_ - 1));
            const uint32_t i0 = static_cast<uint32_t>(pos);
            const uint32_t i1 = std::min(i0 + 1, count_ - 1);
            const float f = static_cast<float>(pos - i0);
            float m = an_.env(0, i0) + f * (an_.env(0, i1) - an_.env(0, i0));
            if (freeze_) m = frozen_[c];
            else frozen_[c] = m;
            target[c] = std::min(100.0f * m, m / std::max(syn_.env(c), 1e-4f));
            levels_[c] = m;
        }
        syn_.setGains(target, kControlFrames);
        an_.flush();
        syn_.flush();
        // The carrier's notes: the held chord, else the drone note; each voice glides to its pitch.
        const uint32_t voices = carrier_ == 0 ? std::max<uint32_t>(1, held_) : 0;
        for (uint32_t v = 0; v < voices; ++v) {
            const double note = (held_ ? static_cast<double>(notes_[v]) : drone_) + 12.0 * octave_;
            const double hz = 440.0 * detPow(2.0, (note - 69.0) / 12.0);
            Osc& o = osc_[v];
            o.hz = (o.hz <= 0.0 || first_) ? hz : o.hz + (hz - o.hz) * glide_;
            for (uint32_t u = 0; u < unison_; ++u) {
                const double cents = unison_ == 1 ? 0.0 : detune_ * (static_cast<double>(u) - 0.5 * (unison_ - 1)) / (0.5 * (unison_ - 1));
                o.dt[u] = std::min(0.45, o.hz * detPow(2.0, cents / 1200.0) / sr);
            }
        }
        voices_ = voices;
        carrierGain_ = voices ? static_cast<float>(1.0 / std::sqrt(static_cast<double>(voices * unison_))) : 0.0f;
        dry_.set(dryTarget_, kControlFrames), wet_.set(wetTarget_, kControlFrames);
        sibGain_.set(sibTarget_ * wetTarget_, kControlFrames);
        first_ = false;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const float* keyL = keyLeft();
        const float* keyR = keyRight();
        sc_.apply(keyL, keyR, n);  // the key (the Sidechain carrier) through the sidechain filter (nothing while off)
        const EventInput& notes = keyNotes();
        const uint32_t first = runStart();
        double peak = keyPeak_;
        for (uint32_t i = 0; i < n; ++i) {
            if (notes.count) takeNotes(notes, first + i);
            const float l = finite0(inL[i]), r = finite0(inR[i]);
            const float mod = 0.5f * (l + r);
            an_.side(0, mod);
            float carrier;
            if (carrier_ == 1) {
                const float kl = keyL ? finite0(keyL[i]) : 0.0f, kr = keyR ? finite0(keyR[i]) : 0.0f;
                carrier = 0.5f * (kl + kr);
                peak = std::max(peak, static_cast<double>(std::fabs(carrier)));
            } else {
                carrier = builtIn();
            }
            float wl, wr;
            syn_.process(carrier, wl, wr);
            const double s = sibB_.process(sib_, sibA_.process(sib_, mod));
            const double d = dry_.next(), w = wet_.next(), sg = sibGain_.next();
            outL[i] = static_cast<float>(d * l + w * wl + sg * s);
            outR[i] = static_cast<float>(d * r + w * wr + sg * s);
            ++t_;
        }
        keyPeak_ = peak;
        if (sc_.listen) sc_.listenTo(keyL, keyR, outL, outR, n);
    }

    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(count_);
        out[3] = static_cast<float>(carrier_);
        out[4] = static_cast<float>(carrier_ == 0 ? held_ : 0);
        out[5] = static_cast<float>(formant_);
        out[6] = freeze_ ? 1.0f : 0.0f;
        out[7] = static_cast<float>(lib::gainToDb(carrier_ == 1 ? keyPeak_ : 0.0));
        for (uint32_t b = 0; b < count_; ++b) {
            out[8 + 3 * b] = static_cast<float>(bands::centre(b, count_, low_, high_));
            out[9 + 3 * b] = static_cast<float>(lib::gainToDb(levels_[b]));
            out[10 + 3 * b] = static_cast<float>(lib::gainToDb(syn_.env(b)));
        }
        keyPeak_ = 0.0;
        return 8 + 3 * count_;
    }

private:
    struct Osc {
        double phase[kMaxUnison] = {};
        double dt[kMaxUnison] = {};
        double hz = 0;
    };
    // The key's note events at frame `frame` of the block: ons build the chord, offs release their note.
    void takeNotes(const EventInput& notes, uint32_t frame) noexcept {
        for (uint32_t e = 0; e < notes.count; ++e) {
            const Event& ev = notes.events[e];
            if (ev.frame != frame || ev.kind != EventKind::Note || ((ev.data[0] >> 28) & 0xFu) != 0x4u) continue;
            const uint32_t status = (ev.data[0] >> 20) & 0xFu;
            const int key = static_cast<int>((ev.data[0] >> 8) & 0x7Fu);
            const bool onNote = status == 0x9u && (ev.data[1] >> 16) != 0;
            if (onNote) {
                if (t_ - lastOn_ > static_cast<int64_t>(0.010 * rate())) held_ = 0;  // a new chord
                lastOn_ = t_;
                bool there = false;
                for (uint32_t k = 0; k < held_; ++k) there = there || notes_[k] == key;
                if (!there && held_ < kMaxNotes) notes_[held_++] = key;
            } else if (status == 0x8u || status == 0x9u) {
                for (uint32_t k = 0; k < held_; ++k)
                    if (notes_[k] == key) {
                        for (uint32_t j = k + 1; j < held_; ++j) notes_[j - 1] = notes_[j];
                        --held_;
                        break;
                    }
            }
        }
    }
    float builtIn() noexcept {
        double sum = 0.0;
        if (wave_ == 2) {
            noise_ = noise_ * 1664525u + 1013904223u;
            sum = (static_cast<double>(noise_ >> 8) / 8388608.0 - 1.0) * 0.6;
            return static_cast<float>(sum * (voices_ ? 1.0 : 0.0));
        }
        for (uint32_t v = 0; v < voices_; ++v) {
            Osc& o = osc_[v];
            for (uint32_t u = 0; u < unison_; ++u) {
                const double t = o.phase[u], dt = o.dt[u];
                sum += wave_ == 0 ? lib::sawWave(t, dt) : lib::pulseWave(t, dt, 0.35);
                double p = t + dt;
                o.phase[u] = p >= 1.0 ? p - 1.0 : p;
            }
        }
        return static_cast<float>(sum * carrierGain_);
    }

    double knobs_[voCount] = {};
    bands::Analyzer<kMaxBands> an_;
    bands::Synthesis<kMaxBands> syn_;
    lib::SvfMix sib_;
    lib::SvfState sibA_, sibB_;
    Osc osc_[kMaxNotes];
    int notes_[kMaxNotes] = {};
    float frozen_[kMaxBands] = {}, levels_[kMaxBands] = {};
    uint32_t count_ = 0, held_ = 0, unison_ = 1, voices_ = 0;
    int carrier_ = 0, wave_ = 0;
    int64_t t_ = 0, lastOn_ = -1000000;
    uint32_t noise_ = 0x2545F491u;
    double drone_ = 48, octave_ = 0, detune_ = 0, glide_ = 1, release_ = 0.04, formant_ = 0, width_ = 0.3;
    double low_ = 80, high_ = 12000, sharp_ = 1, spacing_ = 0.38, sibTarget_ = 0, dryTarget_ = 0, wetTarget_ = 1;
    double keyPeak_ = 0;
    float carrierGain_ = 1.0f;
    bool freeze_ = false, first_ = true;
    SidechainFilter sc_;
    Ramp dry_, wet_, sibGain_;
};

ModuleProcessor* makeVocoder() noexcept { return new (std::nothrow) Vocoder(); }

using V = std::vector<std::pair<std::string_view, double>>;

}  // namespace

void registerVocoder(ModuleRegistry& registry) { registry.add(vocoderDescriptor(), &makeVocoder); }
size_t vocoderBytes() noexcept { return sizeof(Vocoder); }

const std::vector<BuiltinPreset>& vocoderPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Classic robot", "Vocals: the saw-carrier robot voice, played by your notes", V{{"carrier", 0}, {"wave", 0}}},
        {"Talking pad", "Sound design: key it from a pad track: the pad sings your words", V{{"carrier", 1}, {"release", 80}, {"width", 0.6}}},
        {"Choir chords", "Vocals: a wide, three-copy saw chord", V{{"carrier", 0}, {"unison", 3}, {"detune", 15}, {"width", 0.7}, {"release", 60}}},
        {"Daft-style lead", "Vocals: a bright pulse lead, quick bands", V{{"carrier", 0}, {"wave", 1}, {"attack", 2}, {"release", 25}, {"sharpness", 1.3}}},
        {"Whisper", "Vocals: noise carrier, a breathy whisper of the words", V{{"carrier", 0}, {"wave", 2}, {"sibilance", 0.5}}},
        {"Deep monster", "Sound design: an octave down, the formants lowered", V{{"carrier", 0}, {"octave", -1}, {"formant", -5}}},
        {"Chipmunk talk", "Sound design: the formants raised a fifth", V{{"carrier", 0}, {"formant", 7}, {"octave", 1}}},
        {"Lo-fi radio voice", "Lo-fi: 12 bands, narrow range, like an old radio", V{{"bands", 1}, {"low", 300}, {"high", 4000}, {"sibilance", 0}}},
        {"Hi-def vocoder", "Vocals: 32 bands for clear words", V{{"bands", 3}, {"sibilance", 0.4}}},
        {"Drum vocoder", "Drums: key a synth into the drums: rhythmic, tonal hits", V{{"carrier", 1}, {"attack", 1}, {"release", 15}, {"sibilance", 0}}},
        {"Frozen vowel", "Sound design: freeze a vowel and play it with notes", V{{"carrier", 0}, {"freeze", 1}, {"unison", 2}}},
        {"Gliding robot", "Vocals: slides between notes", V{{"carrier", 0}, {"glide", 120}}},
        {"Half wet", "Mixing: the vocoder under the dry voice", V{{"carrier", 0}, {"mix", 0.5}, {"unison", 2}}},
        // Scroll past the end: a hidden one (the plan's personality list names it).
        {"Talking crow", "Sound design: a raspy, high, narrow-band caw", V{{"carrier", 0}, {"wave", 1}, {"octave", 1}, {"formant", 4}, {"bands", 1}, {"low", 400}, {"high", 6000}, {"sharpness", 1.6}}},
    };
    return p;
}

}  // namespace caw::fx
