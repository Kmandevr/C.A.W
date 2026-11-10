// The flagship synth (#171): three wavetable oscillators with unison, two filters, a mod matrix and an effects rack.
#include "builtin_flagship.h"
#include "quality.h"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <new>
#include <string>
#include <string_view>
#include <utility>

#include "caw/detmath.hpp"
#include "caw/instrument.hpp"
#include "caw/library/comb.hpp"
#include "caw/library/delay.hpp"
#include "caw/library/distortion.hpp"
#include "caw/library/envelope.hpp"
#include "caw/library/eq.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/formant.hpp"
#include "caw/library/lfo.hpp"
#include "caw/library/oscillator.hpp"
#include "caw/library/reverb.hpp"
#include "caw/library/stereo.hpp"
#include "caw/library/unison.hpp"
#include "caw/library/wavetable.hpp"

// Original code (C.A.W. is Apache-2.0). The controls follow what a modern wavetable synth offers, reproduced from
// general synthesis knowledge and public descriptions of what such controls do; no other synth's code, presets
// or wavetables were used (docs/decisions.md, "A flagship synth that can do everything").
//
// How it runs (the costs the phone budget cares about):
// - Everything that is not audio runs once per control period of 16 frames (0.33 ms at 48 kHz): the knobs,
//   the mod matrix, each voice's oscillator steps, mip levels, unison gains and filter coefficients. The grid
//   runs on from block to block and restarts on a note-on, so any block size renders the same bits.
// - An oscillator copy (one unison voice) costs one interpolated read of a band-limited mip level per sample
//   (two when the frame position sits between frames), plus its warp: no trig, no branches on data.
// - Only sounding voices are visited (caw::VoicePool), only oscillators that are on, only filters and effects
//   that are on. With no voice and the effects' tails below -94 dB the synth clears its effects and is quiet()
//   (the host skips it) until the next note.

#if defined(_MSC_VER) && !defined(__clang__)
#define CAW_FORCE_INLINE __forceinline
#define CAW_NO_INLINE __declspec(noinline)
#else
#define CAW_FORCE_INLINE inline __attribute__((always_inline))
#define CAW_NO_INLINE __attribute__((noinline))
#endif

namespace caw {

namespace {

constexpr uint32_t kControlFrames = 16;
constexpr uint32_t kVoices = 64;  // a voice can be 48 oscillator copies: 64 is plenty; the oldest is stolen past it
constexpr uint32_t kOscs = 3, kFilters = 2, kEnvs = 3, kLfos = 3, kSlots = 16;
constexpr int kTableCount = 5;
constexpr int kFrameSize = 1024;  // 512 harmonics: a full spectrum down to about 30 Hz at 48 kHz
constexpr int kMaxCopies = lib::kMaxUnisonVoices;
constexpr int kEcoCopies = 4;  // the unison cap at Eco quality
constexpr double kLn2 = 0.69314718055994530942;

// ---------- Parameters ----------

enum OscParam : uint32_t {
    kOscOn, kOscTable, kOscFrame, kOscLevel, kOscPan, kOscOctave, kOscSemi, kOscFine, kOscPhase, kOscPhaseRand, kOscWarp,
    kOscWarpAmount, kOscUnison, kOscDetune, kOscPower, kOscSpread, kOscBlend, kOscStack, kOscDest, kOscCount
};
enum FilterParam : uint32_t { kFltOn, kFltType, kFltCutoff, kFltResonance, kFltDrive, kFltKeytrack, kFltMorph, kFltMix, kFltCount };
enum EnvParam : uint32_t { kEnvAttack, kEnvDecay, kEnvSustain, kEnvRelease, kEnvCount };
enum LfoParam : uint32_t { kLfoShape, kLfoRate, kLfoSync, kLfoMode, kLfoCount };
enum ModParam : uint32_t { kModSource, kModTarget, kModAmount, kModPolarity, kModCount };

constexpr uint32_t oscParam(uint32_t o, uint32_t p) { return o * kOscCount + p; }
constexpr uint32_t kFltBase = kOscs * kOscCount;
constexpr uint32_t fltParam(uint32_t f, uint32_t p) { return kFltBase + f * kFltCount + p; }
constexpr uint32_t kFltRouting = kFltBase + kFilters * kFltCount;
constexpr uint32_t kEnvBase = kFltRouting + 1;
constexpr uint32_t envParam(uint32_t e, uint32_t p) { return kEnvBase + e * kEnvCount + p; }
constexpr uint32_t kLfoBase = kEnvBase + kEnvs * kEnvCount;
constexpr uint32_t lfoParam(uint32_t l, uint32_t p) { return kLfoBase + l * kLfoCount + p; }
constexpr uint32_t kRndRate = kLfoBase + kLfos * kLfoCount, kRndMode = kRndRate + 1;
// From here on the parameters belong to the whole instrument, not a voice: a voice source modulates them
// from the newest voice sounding.
constexpr uint32_t kVolume = kRndMode + 1, kVelocity = kVolume + 1, kBendRange = kVelocity + 1;
enum FxParam : uint32_t {
    kDistOn = kBendRange + 1, kDistType, kDistDrive, kDistMix,
    kEqOn, kEqLow, kEqMid, kEqMidFreq, kEqHigh, kEqMix,
    kChorusOn, kChorusRate, kChorusDepth, kChorusMix,
    kDelayOn, kDelaySync, kDelayTime, kDelayFeedback, kDelayMix,
    kReverbOn, kReverbSize, kReverbDecay, kReverbDamping, kReverbMix,
    kFxEnd
};
constexpr uint32_t kModBase = kFxEnd;
constexpr uint32_t kModTargets = kModBase;  // a slot can move any parameter before the slots themselves
constexpr uint32_t modParam(uint32_t s, uint32_t p) { return kModBase + s * kModCount + p; }
// Added after the slots (2026-11-10, one synth): appended so the slots' destination numbers (parameter k + 1)
// stay what saved projects hold. They are not mod destinations.
constexpr uint32_t kVoiceMode = kModBase + kSlots * kModCount, kGlide = kVoiceMode + 1;
constexpr uint32_t kViaBase = kGlide + 1;  // modN_via: a second source the slot's amount is multiplied by
constexpr uint32_t viaParam(uint32_t s) { return kViaBase + s; }
constexpr uint32_t kParamCount = kViaBase + kSlots;
static_assert(kParamCount == 209, "the parameter list's size is part of the documented layout");

enum Source : int {
    kSrcNone, kSrcEnv1, kSrcEnv2, kSrcEnv3, kSrcLfo1, kSrcLfo2, kSrcLfo3, kSrcRandom, kSrcVelocity, kSrcNote,
    kSrcBend, kSrcPressure, kSrcTimbre, kSrcModWheel, kSrcAccent, kSourceCount
};
enum FilterType : int { kLadderLp, kLadderHp, kLadderBp, kSvfLp, kSvfHp, kSvfBp, kSvfNotch, kComb, kFormant, kFilterTypeCount };
enum Warp : int { kWarpNone, kWarpBend, kWarpSync, kWarpMirror, kWarpQuantize };
enum Dest : int { kToFilter1, kToFilter2, kToBoth, kToBypass };
enum VoiceMode : int { kPoly, kMono, kLegato };

constexpr std::string_view kOffOn[] = {"Off", "On"};
constexpr std::string_view kTables[] = {"Basic", "Analog", "Vocal", "Harmonic", "Classic"};
constexpr std::string_view kWarps[] = {"None", "Bend", "Sync", "Mirror", "Quantize"};
constexpr std::string_view kStacks[] = {"Off", "Octave", "2 octaves", "Fifth", "Major chord", "Minor chord", "Harmonics"};
constexpr std::string_view kDests[] = {"Filter 1", "Filter 2", "Both", "Bypass"};
constexpr std::string_view kFilterTypes[] = {"Ladder LP", "Ladder HP", "Ladder BP", "SVF LP", "SVF HP",
                                             "SVF BP",    "SVF notch", "Comb",     "Formant"};
constexpr std::string_view kRoutings[] = {"Series", "Parallel"};
constexpr std::string_view kLfoShapes[] = {"Sine", "Triangle", "Saw up", "Saw down", "Square", "Sample & hold", "Smooth random"};
constexpr std::string_view kLfoSyncs[] = {"Off", "1/32", "1/16", "1/8", "1/4", "1/2", "1 bar", "2 bars", "4 bars", "8 bars"};
constexpr double kLfoSyncBeats[] = {0.0, 0.125, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0};
// Free: one for the instrument, a synced one locked to the song's position while it plays. Retrigger: per voice,
// from each note. Running: one for the instrument at the synced rate, running on from Play rather than following
// the song's position (a slow sweep longer than the loop keeps going across loop restarts; the Morph synth's drift).
constexpr std::string_view kLfoModes[] = {"Free", "Retrigger", "Running"};
enum LfoMode : int { kLfoFree, kLfoRetrigger, kLfoRunning };
constexpr std::string_view kRndModes[] = {"Sample & hold", "Smooth"};
constexpr std::string_view kDistTypes[] = {"Drive", "Hard clip", "Fold", "Crush"};
constexpr std::string_view kDelaySyncs[] = {"Off", "1/16", "1/8", "1/8 dotted", "1/4", "1/4 dotted", "1/2", "1 bar"};
constexpr double kDelaySyncWholes[] = {0.0, 0.0625, 0.125, 0.1875, 0.25, 0.375, 0.5, 1.0};
constexpr std::string_view kSources[] = {"None",     "Env 1", "Env 2",      "Env 3",    "LFO 1",  "LFO 2",    "LFO 3",
                                         "Random",   "Velocity", "Note",    "Pitch bend", "Pressure", "Timbre", "Mod wheel",
                                         "Accent"};
constexpr std::string_view kVoiceModes[] = {"Poly", "Mono", "Legato"};
constexpr std::string_view kPolarities[] = {"Unipolar", "Bipolar"};
static_assert(sizeof(kSources) / sizeof(kSources[0]) == kSourceCount);

template <size_t N>
constexpr uint32_t count(const std::string_view (&)[N]) { return static_cast<uint32_t>(N); }

// The parameter table, built once (ids such as "osc1_level" are made from a section prefix and a name).
class Params {
public:
    ParameterDescriptor d[kParamCount];
    double logRange[kParamCount] = {};  // ln(maximum / minimum) of an exponential parameter

    Params() {
        for (uint32_t o = 0; o < kOscs; ++o) {
            const std::string p = "osc" + std::to_string(o + 1) + "_", n = "Osc " + std::to_string(o + 1) + " ";
            pick(p + "on", n + "on", o == 0 ? 1.0 : 0.0, kOffOn, count(kOffOn));
            pick(p + "table", n + "table", 0.0, kTables, count(kTables));
            num(p + "frame", n + "frame", 1.0 / 3.0, 0.0, 1.0);  // the Basic table's saw
            num(p + "level", n + "level", 0.7, 0.0, 1.0);
            num(p + "pan", n + "pan", 0.0, -1.0, 1.0);
            whole(p + "octave", n + "octave", 0.0, -4.0, 4.0);
            whole(p + "semi", n + "semitones", 0.0, -12.0, 12.0, "st");
            num(p + "fine", n + "fine", 0.0, -100.0, 100.0, "ct");
            num(p + "phase", n + "phase", 0.0, 0.0, 1.0);
            num(p + "phase_rand", n + "phase randomness", 1.0, 0.0, 1.0);
            pick(p + "warp", n + "warp", 0.0, kWarps, count(kWarps));
            num(p + "warp_amt", n + "warp amount", 0.0, 0.0, 1.0);
            whole(p + "unison", n + "unison", o == 0 ? 7.0 : 1.0, 1.0, kMaxCopies);
            num(p + "detune", n + "detune", 25.0, 0.0, 100.0, "ct");
            num(p + "detune_power", n + "detune power", 0.0, -1.0, 1.0);
            num(p + "spread", n + "stereo spread", 0.8, 0.0, 1.0);
            num(p + "blend", n + "blend", 0.5, 0.0, 1.0);
            pick(p + "stack", n + "stack", 0.0, kStacks, count(kStacks));
            pick(p + "dest", n + "filter", 0.0, kDests, count(kDests));
        }
        for (uint32_t f = 0; f < kFilters; ++f) {
            const std::string p = "flt" + std::to_string(f + 1) + "_", n = "Filter " + std::to_string(f + 1) + " ";
            pick(p + "on", n + "on", f == 0 ? 1.0 : 0.0, kOffOn, count(kOffOn));
            pick(p + "type", n + "type", f == 0 ? kLadderLp : kSvfLp, kFilterTypes, count(kFilterTypes));
            expo(p + "cutoff", n + "cutoff", f == 0 ? 2400.0 : 1200.0, 20.0, 20000.0, "Hz");
            num(p + "resonance", n + "resonance", 0.15, 0.0, 1.0);
            expo(p + "drive", n + "drive", 1.0, 1.0, 10.0);
            num(p + "keytrack", n + "key tracking", 0.0, 0.0, 1.0);
            num(p + "morph", n + "vowel / damping", 0.0, 0.0, 1.0);
            num(p + "mix", n + "mix", 1.0, 0.0, 1.0);
        }
        pick("flt_routing", "Filter routing", 0.0, kRoutings, count(kRoutings));
        const double envDefaults[kEnvs][kEnvCount] = {{0.01, 0.6, 0.75, 0.35}, {0.001, 0.5, 0.25, 0.4}, {0.001, 0.3, 0.0, 0.3}};
        for (uint32_t e = 0; e < kEnvs; ++e) {
            const std::string p = "env" + std::to_string(e + 1) + "_", n = "Env " + std::to_string(e + 1) + " ";
            expo(p + "attack", n + "attack", envDefaults[e][0], 0.001, 10.0, "s");
            expo(p + "decay", n + "decay", envDefaults[e][1], 0.001, 10.0, "s");
            num(p + "sustain", n + "sustain", envDefaults[e][2], 0.0, 1.0);
            expo(p + "release", n + "release", envDefaults[e][3], 0.001, 10.0, "s");
        }
        for (uint32_t l = 0; l < kLfos; ++l) {
            const std::string p = "lfo" + std::to_string(l + 1) + "_", n = "LFO " + std::to_string(l + 1) + " ";
            pick(p + "shape", n + "shape", 0.0, kLfoShapes, count(kLfoShapes));
            expo(p + "rate", n + "rate", 2.0, 0.01, 40.0, "Hz");
            pick(p + "sync", n + "sync", 0.0, kLfoSyncs, count(kLfoSyncs));
            pick(p + "mode", n + "mode", 0.0, kLfoModes, count(kLfoModes));
        }
        expo("rnd_rate", "Random rate", 4.0, 0.01, 40.0, "Hz");
        pick("rnd_mode", "Random mode", 0.0, kRndModes, count(kRndModes));
        num("volume", "Volume", 0.7, 0.0, 1.0);
        num("velocity", "Velocity to level", 0.5, 0.0, 1.0);
        whole("bend_range", "Pitch bend range", 2.0, 1.0, 48.0, "st");
        pick("fx_dist_on", "Distortion", 0.0, kOffOn, count(kOffOn));
        pick("fx_dist_type", "Distortion type", 0.0, kDistTypes, count(kDistTypes));
        expo("fx_dist_drive", "Distortion drive", 2.0, 1.0, 20.0);
        num("fx_dist_mix", "Distortion mix", 1.0, 0.0, 1.0);
        pick("fx_eq_on", "EQ", 0.0, kOffOn, count(kOffOn));
        num("fx_eq_low", "EQ low", 0.0, -18.0, 18.0, "dB");
        num("fx_eq_mid", "EQ mid", 0.0, -18.0, 18.0, "dB");
        expo("fx_eq_mid_freq", "EQ mid frequency", 1000.0, 100.0, 8000.0, "Hz");
        num("fx_eq_high", "EQ high", 0.0, -18.0, 18.0, "dB");
        num("fx_eq_mix", "EQ mix", 1.0, 0.0, 1.0);
        pick("fx_chorus_on", "Chorus", 0.0, kOffOn, count(kOffOn));
        expo("fx_chorus_rate", "Chorus rate", 0.6, 0.05, 5.0, "Hz");
        num("fx_chorus_depth", "Chorus depth", 0.5, 0.0, 1.0);
        num("fx_chorus_mix", "Chorus mix", 0.35, 0.0, 1.0);
        pick("fx_delay_on", "Delay", 0.0, kOffOn, count(kOffOn));
        pick("fx_delay_sync", "Delay sync", 3.0, kDelaySyncs, count(kDelaySyncs));
        expo("fx_delay_time", "Delay time", 0.3, 0.01, 4.0, "s");
        num("fx_delay_feedback", "Delay feedback", 0.35, 0.0, 0.95);
        num("fx_delay_mix", "Delay mix", 0.25, 0.0, 1.0);
        pick("fx_reverb_on", "Reverb", 0.0, kOffOn, count(kOffOn));  // off: a track's own reverb costs CPU
        num("fx_reverb_size", "Reverb size", 0.6, 0.0, 1.0);
        expo("fx_reverb_decay", "Reverb decay", 2.2, 0.1, 20.0, "s");
        num("fx_reverb_damping", "Reverb damping", 0.45, 0.0, 1.0);
        num("fx_reverb_mix", "Reverb mix", 0.18, 0.0, 1.0);
        targets_[0] = "None";
        for (uint32_t k = 0; k < kModTargets; ++k) targets_[k + 1] = names_[k];
        for (uint32_t s = 0; s < kSlots; ++s) {
            const std::string p = "mod" + std::to_string(s + 1) + "_", n = "Mod " + std::to_string(s + 1) + " ";
            // Slot 1 starts as a gentle filter envelope: env 2 opens filter 1 by 1.5 octaves.
            pick(p + "src", n + "source", s == 0 ? kSrcEnv2 : kSrcNone, kSources, count(kSources));
            pick(p + "dst", n + "destination", s == 0 ? fltParam(0, kFltCutoff) + 1.0 : 0.0, targets_, kModTargets + 1);
            num(p + "amt", n + "amount", s == 0 ? 0.15 : 0.0, -1.0, 1.0);
            pick(p + "bipolar", n + "polarity", 0.0, kPolarities, count(kPolarities));
        }
        // Poly: a voice per note. Mono: one voice, last-note priority, every note restarts the envelopes. Legato: one
        // voice, and a note played while another is held glides there without restarting them (a 303's slide).
        pick("voice_mode", "Voice mode", kPoly, kVoiceModes, count(kVoiceModes));
        expo("glide", "Glide", 0.05, 0.001, 2.0, "s");  // mono and legato: the time to the new note's pitch
        for (uint32_t s = 0; s < kSlots; ++s)
            pick("mod" + std::to_string(s + 1) + "_via", "Mod " + std::to_string(s + 1) + " scaled by", kSrcNone, kSources,
                 count(kSources));
    }

private:
    ParameterDescriptor& add(std::string id, std::string name, double def, double lo, double hi, std::string_view unit) {
        ids_[at_] = std::move(id);
        names_[at_] = std::move(name);
        ParameterDescriptor& p = d[at_++];
        p.id = ids_[at_ - 1];
        p.name = names_[at_ - 1];
        p.defaultValue = def;
        p.minimum = lo;
        p.maximum = hi;
        p.unit = unit;
        p.smoothingFrames = 480;  // 10 ms at 48 kHz: a knob move doesn't click
        return p;
    }
    void num(std::string id, std::string name, double def, double lo, double hi, std::string_view unit = {}) {
        add(std::move(id), std::move(name), def, lo, hi, unit);
    }
    // Times, frequencies, rates and gains: the knob tapers, so it turns finely near the bottom of a wide range.
    void expo(std::string id, std::string name, double def, double lo, double hi, std::string_view unit = {}) {
        ParameterDescriptor& p = add(std::move(id), std::move(name), def, lo, hi, unit);
        p.curve = ParameterCurve::Exponential;
        logRange[at_ - 1] = detLog(hi / lo);
    }
    void whole(std::string id, std::string name, double def, double lo, double hi, std::string_view unit = {}) {
        ParameterDescriptor& p = add(std::move(id), std::move(name), def, lo, hi, unit);
        p.step = 1.0;
        p.smoothingFrames = 0;
    }
    void pick(std::string id, std::string name, double def, const std::string_view* labels, uint32_t n) {
        ParameterDescriptor& p = add(std::move(id), std::move(name), def, 0.0, static_cast<double>(n - 1), {});
        p.step = 1.0;
        p.choices = labels;
        p.choiceCount = n;
        p.smoothingFrames = 0;  // a choice jumps
    }
    std::string ids_[kParamCount], names_[kParamCount];
    std::string_view targets_[kModTargets + 1];
    uint32_t at_ = 0;
};

const Params& params() {
    static const Params p;
    return p;
}

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

const ModuleDescriptor& flagshipDescriptor() {
    static const ModuleDescriptor d = [] {
        ModuleDescriptor m;
        m.id = "org.caw.synth.flagship";
        m.name = "Flagship";
        m.role = ModuleRole::Instrument;
        m.ports = kPorts;
        m.portCount = 2;
        m.parameters = params().d;
        m.parameterCount = kParamCount;
        m.tailFrames = 7680000;  // 40 s at 192 kHz: a 10 s release into a 20 s reverb; it says quiet() sooner
        return m;
    }();
    return d;
}

double clampd(double v, double lo, double hi) noexcept {
    v = finiteOr0(v);
    return v < lo ? lo : (v > hi ? hi : v);
}
int clampi(double v, int lo, int hi) noexcept { return static_cast<int>(clampd(v, lo, hi)); }
// 2^x for the control rate (fastExp: IEEE basic operations only, so the same bits everywhere).
double exp2(double x) noexcept { return lib::fastExp(x * kLn2); }

// ---------- Wavetables ----------

// The built-in tables, generated by code the first time a flagship activates (about 30 frames of 1024
// samples, additively: a few tens of milliseconds, off the audio thread) and shared by every instance.
struct Tables {
    lib::Wavetable table[kTableCount];
};

// Scales harmonic amplitudes so the frame's RMS is that of a saw at full scale (1/sqrt(3)): every frame of a
// table plays at about the same loudness.
void normalize(double* a, int n) {
    double sum = 0.0;
    for (int h = 0; h < n; ++h) sum += a[h] * a[h];
    const double rms = std::sqrt(0.5 * sum);
    if (rms > 0.0)
        for (int h = 0; h < n; ++h) a[h] *= 0.57735026918962576 / rms;
}

const Tables& tables() {
    static const Tables t = [] {
        Tables x;
        constexpr int kH = kFrameSize / 2;
        double a[kH], phase[kH];
        // Schroeder's phases (h (h - 1) / 2N cycles) keep a dense spectrum's peaks low; one set per table, so
        // the frames line up and morph without cancelling.
        for (int h = 1; h <= kH; ++h) {
            const double c = static_cast<double>(h) * (h - 1) / (2.0 * kH);
            phase[h - 1] = c - std::floor(c);
        }
        // A second-order roll-off around harmonic `corner`: the softer "analog" shapes.
        auto rolloff = [](int h, double corner) {
            const double r = h / corner, r2 = r * r;
            return 1.0 / std::sqrt(1.0 + r2 * r2);
        };
        // Basic: sine, saw, square, a 25 % pulse.
        lib::Wavetable& basic = x.table[0];
        basic.prepare(4, kFrameSize);
        a[0] = 1.0;
        basic.setFrameHarmonics(0, a, 1);
        lib::sawHarmonics(a, kH);
        basic.setFrameHarmonics(1, a, kH);
        lib::squareHarmonics(a, kH);
        basic.setFrameHarmonics(2, a, kH);
        for (int h = 1; h <= kH; ++h) a[h - 1] = 4.0 / (kPi * h) * detSin(kPi * h * 0.25);
        double cosine[kH];
        for (double& c : cosine) c = 0.25;
        basic.setFrameHarmonics(3, a, kH, cosine);
        // Analog: triangle, a warm (rolled-off) saw, a shark fin, a soft square, a soft 10 % pulse.
        lib::Wavetable& analog = x.table[1];
        analog.prepare(5, kFrameSize);
        lib::triangleHarmonics(a, kH);
        analog.setFrameHarmonics(0, a, kH);
        lib::sawHarmonics(a, kH);
        for (int h = 1; h <= kH; ++h) a[h - 1] *= rolloff(h, 14.0);
        analog.setFrameHarmonics(1, a, kH);
        analog.setFrameFunction(2, [](double p) {  // a capacitor charging, then discharging
            const double k = 5.0, full = 1.0 - detExp(-k);
            return p < 0.5 ? 2.0 * (1.0 - detExp(-k * 2.0 * p)) / full - 1.0
                           : 2.0 * detExp(-k * 2.0 * (p - 0.5)) - 1.0;
        });
        lib::squareHarmonics(a, kH);
        for (int h = 1; h <= kH; ++h) a[h - 1] *= rolloff(h, 9.0);
        analog.setFrameHarmonics(3, a, kH);
        for (int h = 1; h <= kH; ++h) a[h - 1] = 4.0 / (kPi * h) * detSin(kPi * h * 0.1) * rolloff(h, 20.0);
        analog.setFrameHarmonics(4, a, kH, cosine);
        // Vocal: a bright source through the formants of A, E, I, O and U, as if sung at 120 Hz (so the
        // vowels sit right around the middle of the keyboard and move with the pitch, as a table's must).
        lib::Wavetable& vocal = x.table[2];
        vocal.prepare(5, kFrameSize);
        for (int v = 0; v < 5; ++v) {
            for (int h = 1; h <= kH; ++h) {
                const double hz = 120.0 * h;
                double e = 0.01;
                const double width[3] = {90.0, 120.0, 160.0}, gain[3] = {1.0, 0.6, 0.35};
                for (int f = 0; f < 3; ++f) {
                    const double d = (hz - lib::kVowelFormantsHz[v][f]) / width[f];
                    e += gain[f] / (1.0 + d * d);
                }
                a[h - 1] = e / std::sqrt(static_cast<double>(h)) * (hz < 12000.0 ? 1.0 : 0.0);
            }
            normalize(a, kH);
            vocal.setFrameHarmonics(v, a, kH, phase);
        }
        // Harmonic: a band of harmonics sweeping from the fundamental up to the 256th over 16 frames, over a
        // steady fundamental (the pitch stays clear).
        lib::Wavetable& sweep = x.table[3];
        sweep.prepare(16, kFrameSize);
        for (int f = 0; f < 16; ++f) {
            const double centre = 8.0 * f / 15.0;  // log2 of the band's centre harmonic
            for (int h = 1; h <= kH; ++h) {
                const double d = (detLog(static_cast<double>(h)) / kLn2 - centre) / 0.7;
                a[h - 1] = detExp(-0.5 * d * d) / (0.5 + 0.1 * h) * 0.6;
            }
            a[0] += 0.6;
            normalize(a, kH);
            sweep.setFrameHarmonics(f, a, kH, phase);
        }
        // Classic: sine, triangle, saw and square, the Morph synth's shapes in its order and phases (sine and
        // triangle rising from 0, saw from -1, square at +1), so a frame sweep is its `shape` knob.
        lib::Wavetable& classic = x.table[4];
        classic.prepare(4, kFrameSize);
        classic.setFrameFunction(0, [](double p) { return lib::sineWave(p); });
        classic.setFrameFunction(1, [](double p) { return lib::triangleWave(p); });
        classic.setFrameFunction(2, [](double p) { return 2.0 * p - 1.0; });
        classic.setFrameFunction(3, [](double p) { return p < 0.5 ? 1.0 : -1.0; });
        return x;
    }();
    return t;
}

// ---------- One oscillator's unison stack, per voice ----------

inline float whole(float t) noexcept { return static_cast<float>(static_cast<int32_t>(t)); }  // floor, for t >= 0

// The phase t (0..1) after the warp. w1, w2 are worked out at the control rate.
template <int W>
inline float warp(float t, float w1, float w2, float w3) noexcept {
    if constexpr (W == kWarpBend) {
        const float y = t * (1.0f + w1 * (1.0f - t));  // pulls the cycle's start forward: 0 and 1 stay put
        return y < 0.99999994f ? y : 0.99999994f;
    } else if constexpr (W == kWarpSync) {
        const float s = t * w1;  // hard sync: the table runs w1 times per cycle, restarting with it
        return s - whole(s);
    } else if constexpr (W == kWarpMirror) {
        const float y = t < w1 ? t * w2 : (1.0f - t) * w3;  // forward to the turn w1, then back
        return y < 0.99999994f ? y : 0.99999994f;
    } else if constexpr (W == kWarpQuantize) {
        return whole(t * w1) * w2;  // w1 steps per cycle
    } else {
        return t;
    }
}

// What an oscillator's copies are worked out from: when none of it moves, a control skips them.
struct OscKey {
    int table = -1;
    double position = 0, level = 0, pan = 0, pitch = 0, amount = 0;
    int warp = 0;
    lib::UnisonSettings unison{-1};
    bool operator==(const OscKey&) const = default;
};

struct OscVoice {
    bool on = false;
    int dest = kToFilter1;
    int count = 0;  // copies in the stack
    int warpMode = kWarpNone;
    float w1 = 0.0f, w2 = 0.0f, w3 = 0.0f, mix = 0.0f;  // the warp's constants; the morph between frames a and b
    int f0 = -1, f1 = -1;                              // the frames a and b read
    double faster = 1.0;                               // how much faster than the note the warp reads the table
    double pitchOffset[3] = {};                        // octave, semitones and fine, in semitones
    double phase[kMaxCopies] = {};
    double dt[kMaxCopies] = {};  // cycles per sample; 0 for a copy above Nyquist (silent)
    const float* a[kMaxCopies] = {};
    const float* b[kMaxCopies] = {};
    float size[kMaxCopies] = {};
    uint32_t step[kMaxCopies] = {};  // dt in 32-bit fixed point (2^32 a cycle), for the unwarped read
    int shift[kMaxCopies] = {};      // 32 - log2(the mip level's size): a fixed-point phase's index bits
    int level[kMaxCopies] = {};      // the mip level each copy reads
    bool centred = false;            // every copy plays the same on both sides (no pan, no spread)
    float gainL[kMaxCopies] = {}, gainR[kMaxCopies] = {};
    // The layout and pan gains, worked out again only when their settings change.
    lib::UnisonSettings layoutKey{-1};
    double panKey = 2.0;
    lib::UnisonVoice layout[kMaxCopies];
    double ratio[kMaxCopies] = {};
    double panL[kMaxCopies] = {}, panR[kMaxCopies] = {};
    double hz = 0.0;
    OscKey key;
};

// One unwarped copy over N (or n) frames, added to L and R with its gains. The phase is 32-bit fixed point
// (2^32 a cycle), so it wraps by itself and its top bits are the table index: no floor, no float-to-int per
// sample. Three passes, so the compiler vectorizes two of them (NEON on Arm64, SSE on x86): the indices and
// fractions, then the table reads (a gather, which NEON does not have: scalar loads), then the interpolation,
// the morph between frames and the mix into L and R. Each sample's arithmetic is the one-pass loop's, in its
// order, so the bits are the same (2026-11-10 second performance pass: about 40 % fewer instructions a copy).
template <bool Morph, uint32_t N>
CAW_FORCE_INLINE void addCopy(const float* A, const float* B, uint32_t p, uint32_t step, int sh, float gl, float gr,
                              float mix, float* L, float* R, uint32_t n) noexcept {
    const uint32_t count = N ? N : n;
    const uint32_t mask = (1u << sh) - 1u;
    const float scale = 1.0f / static_cast<float>(1u << sh);
    int32_t index[kControlFrames];
    float fr[kControlFrames], a[2 * kControlFrames], b[2 * kControlFrames];  // a: A[k], A[k + 1] for each sample
    for (uint32_t i = 0; i < count; ++i) {  // sh <= 31, so both fit an int32 (a signed conversion vectorizes)
        index[i] = static_cast<int32_t>(p >> sh);
        fr[i] = static_cast<float>(static_cast<int32_t>(p & mask)) * scale;
        p += step;
    }
    for (uint32_t i = 0; i < count; ++i) {  // each pair of neighbours in one 8-byte load and store
        const int32_t k = index[i];
        std::memcpy(a + 2 * i, A + k, 2 * sizeof(float));
        if constexpr (Morph) std::memcpy(b + 2 * i, B + k, 2 * sizeof(float));
    }
    for (uint32_t i = 0; i < count; ++i) {  // the pairs split apart again (NEON's ld2)
        float v = a[2 * i] + (a[2 * i + 1] - a[2 * i]) * fr[i];
        if constexpr (Morph) {
            const float u = b[2 * i] + (b[2 * i + 1] - b[2 * i]) * fr[i];
            v += (u - v) * mix;
        }
        L[i] += v * gl;
        R[i] += v * gr;
    }
}

// Adds `n` frames of the stack, `first` frames into the control period, to L and R.
template <int W, bool Morph>
void addStack(const OscVoice& o, float* L, float* R, uint32_t n, uint32_t first) noexcept {
    if constexpr (W == kWarpNone) {
        for (int c = 0; c < o.count; ++c) {
            if (!o.a[c]) continue;
            const uint32_t step = o.step[c];
            const uint32_t p0 = static_cast<uint32_t>(static_cast<uint64_t>(o.phase[c] * 4294967296.0)) + first * step;
            addCopy<Morph, 0>(o.a[c], o.b[c], p0, step, o.shift[c], o.gainL[c], o.gainR[c], o.mix, L, R, n);
        }
        return;
    }
    for (int c = 0; c < o.count; ++c) {
        if (!o.a[c]) continue;
        const float* A = o.a[c];
        const float* B = o.b[c];
        const float m = o.size[c], t0 = static_cast<float>(o.phase[c]), dt = static_cast<float>(o.dt[c]);
        const float gl = o.gainL[c], gr = o.gainR[c], mix = o.mix, w1 = o.w1, w2 = o.w2, w3 = o.w3;
        for (uint32_t i = 0; i < n; ++i) {
            float t = t0 + static_cast<float>(static_cast<int32_t>(first + i)) * dt;
            t -= whole(t);
            const float x = warp<W>(t, w1, w2, w3) * m;
            const int32_t k = static_cast<int32_t>(x);
            const float fr = x - static_cast<float>(k);
            float v = A[k] + (A[k + 1] - A[k]) * fr;
            if constexpr (Morph) {
                const float u = B[k] + (B[k + 1] - B[k]) * fr;
                v += (u - v) * mix;
            }
            L[i] += v * gl;
            R[i] += v * gr;
        }
    }
}

template <int W>
void addStackWarp(const OscVoice& o, float* L, float* R, uint32_t n, uint32_t first) noexcept {
    if (o.mix != 0.0f) addStack<W, true>(o, L, R, n, first);
    else addStack<W, false>(o, L, R, n, first);
}

void addOscillator(const OscVoice& o, float* L, float* R, uint32_t n, uint32_t first) noexcept {
    switch (o.warpMode) {
        case kWarpBend: addStackWarp<kWarpBend>(o, L, R, n, first); break;
        case kWarpSync: addStackWarp<kWarpSync>(o, L, R, n, first); break;
        case kWarpMirror: addStackWarp<kWarpMirror>(o, L, R, n, first); break;
        case kWarpQuantize: addStackWarp<kWarpQuantize>(o, L, R, n, first); break;
        default: addStackWarp<kWarpNone>(o, L, R, n, first); break;
    }
}

// The mip level whose harmonics all stay at or below Nyquist at `dt` cycles per sample (Wavetable::levelFor
// without its loop: the first k with frameSize * dt <= 2^k).
int mipLevel(double dt, int levels) noexcept {
    const double x = kFrameSize * dt;
    if (!(x > 1.0)) return 0;
    // x = 1.f * 2^e from its bits (x > 1 is normal): the smallest k with x <= 2^k is e, or e + 1 if f > 0.
    const uint64_t bits = std::bit_cast<uint64_t>(x);
    const int e = static_cast<int>((bits >> 52) & 0x7FF) - 1023;
    const int k = (bits & 0xFFFFFFFFFFFFFull) ? e + 1 : e;
    return k < levels ? k : levels - 1;
}

// ---------- A voice's filter ----------

struct VoiceFilter {
    bool on = false, drive = false;
    int type = -1;
    float mix = 1.0f;
    lib::MultiLadder ladder[2];
    lib::Svf svf[2];
    lib::FormantFilter formant[2];
    lib::CombFilter* comb[2] = {nullptr, nullptr};  // the instrument's, one pair per voice (they hold memory)
    lib::Saturator saturator;
    double qFor = -1.0, q = 0.70710678118654752;  // the SVF's q, for the resonance it was worked out from

    void configure(bool enabled, int t, double cutoff, double resonance, double amount, double morph, double wet,
                   double sampleRate, bool fresh) noexcept {
        on = enabled;
        if (fresh) type = -1;  // a new note starts every filter from rest
        if (!on) return;
        if (t != type) {  // a new type starts from rest
            for (int c = 0; c < 2; ++c) {
                ladder[c].clear();
                svf[c].clear();
                formant[c].clear();
                if (comb[c] && t == kComb) comb[c]->clear();
            }
            type = t;
        }
        mix = static_cast<float>(wet);
        drive = amount > 1.0001;
        saturator.set(amount);
        for (int c = 0; c < 2; ++c) {
            switch (type) {
                case kLadderLp:
                case kLadderHp:
                case kLadderBp:
                    if (c == 0) ladder[0].set(cutoff, resonance, sampleRate);
                    else ladder[1].setLike(ladder[0]);  // one tan for the pair
                    break;
                case kComb:
                    if (comb[c]) comb[c]->set(cutoff, 0.4 + 0.595 * resonance, morph);
                    break;
                case kFormant: formant[c].set(morph, cutoff / 1000.0, 4.0 + 16.0 * resonance, sampleRate); break;
                default:
                    if (resonance != qFor) qFor = resonance, q = lib::resonanceQ(resonance);  // a pow: only on a change
                    if (c == 0) svf[0].set(cutoff, q, sampleRate);
                    else svf[1].setLike(svf[0]);  // one tan for the pair
                    break;
            }
        }
    }
    template <class F>
    void each(float* x, uint32_t n, F&& f) noexcept {
        for (uint32_t i = 0; i < n; ++i) x[i] = static_cast<float>(f(static_cast<double>(x[i])));
    }
    // In place: drive (when above 1) into the filter, then the dry/wet mix.
    // A centred voice (both sides the same): only the left side is filtered, and stands for both. Ladder and SVF
    // low-pass only; the right side's state takes the left's when it is filtered again (it was the same).
    bool monoCapable() const noexcept { return !on || type <= kLadderBp || type == kSvfLp; }
    void processMono(float* L, uint32_t n) noexcept {
        if (!on) return;
        monoUsed = true;
        float dry[kControlFrames];
        const bool wet = mix >= 1.0f;
        if (!wet) std::copy(L, L + n, dry);
        if (drive) each(L, n, [&](double v) noexcept { return saturator.process(v); });
        if (type == kLadderLp || type == kLadderHp || type == kLadderBp) {
            ladder[0].flushDenormals();
            if (type == kLadderLp) ladder[0].process<lib::LadderMode::LowPass>(L, n);
            else if (type == kLadderHp) ladder[0].process<lib::LadderMode::HighPass>(L, n);
            else ladder[0].process<lib::LadderMode::BandPass>(L, n);
        } else {
            for (uint32_t i = 0; i < n; ++i) L[i] = static_cast<float>(svf[0].lowpass(static_cast<double>(L[i])));
        }
        if (!wet)
            for (uint32_t i = 0; i < n; ++i) L[i] = dry[i] + (L[i] - dry[i]) * mix;
    }
    bool monoUsed = false;  // the left side ran alone: the right's state is behind

    void process(float* L, float* R, uint32_t n) noexcept {
        if (!on) return;
        if (monoUsed) {  // back to stereo: the right side continues from the left's state, which both had
            monoUsed = false;
            ladder[1] = ladder[0];
            svf[1] = svf[0];
        }
        float dryL[kControlFrames], dryR[kControlFrames];
        const bool wet = mix >= 1.0f;
        if (!wet) std::copy(L, L + n, dryL), std::copy(R, R + n, dryR);
        if (drive) {
            each(L, n, [&](double v) noexcept { return saturator.process(v); });
            each(R, n, [&](double v) noexcept { return saturator.process(v); });
        }
        if (type <= kLadderBp) {  // both sides in one loop
            ladder[0].flushDenormals();
            ladder[1].flushDenormals();
            if (type == kLadderLp) ladder[0].processPair<lib::LadderMode::LowPass>(ladder[1], L, R, n);
            else if (type == kLadderHp) ladder[0].processPair<lib::LadderMode::HighPass>(ladder[1], L, R, n);
            else ladder[0].processPair<lib::LadderMode::BandPass>(ladder[1], L, R, n);
        }
        if (type == kSvfLp) svf[0].lowpassPair(svf[1], L, R, n);  // both sides in one loop, as a two-wide vector
        for (int c = 0; c < 2 && type > kSvfLp; ++c) {
            float* x = c ? R : L;
            switch (type) {
                case kSvfHp: each(x, n, [&](double v) noexcept { return svf[c].process(v).high; }); break;
                case kSvfBp: each(x, n, [&](double v) noexcept { return svf[c].process(v).band; }); break;
                case kSvfNotch: each(x, n, [&](double v) noexcept { return svf[c].process(v).notch; }); break;
                case kComb:
                    if (comb[c]) each(x, n, [&](double v) noexcept { return comb[c]->process(v); });
                    break;
                case kFormant: each(x, n, [&](double v) noexcept { return formant[c].process(v); }); break;
                default: break;
            }
        }
        if (!wet)
            for (uint32_t i = 0; i < n; ++i) {
                L[i] = dryL[i] + (L[i] - dryL[i]) * mix;
                R[i] = dryR[i] + (R[i] - dryR[i]) * mix;
            }
    }
};

// ---------- The instrument ----------

struct Voice {
    bool active = false, held = false;
    uint32_t noteId = 0;
    uint64_t age = 0;
    bool starting = false, fresh = false;  // the next control sets the note's start (and, fresh, its phases)
    uint32_t seed = 0;
    double notePitch = 60.0, pitch = 60.0, velocity = 1.0, pressure = 0.0, timbre = 0.0;
    lib::Adsr env[kEnvs];
    lib::Lfo lfo[kLfos];  // the retriggered LFOs (a free one is the instrument's)
    lib::Lfo random;
    OscVoice osc[kOscs];
    VoiceFilter filter[kFilters];
    bool parallel = false;
    double gain0 = 0.0, gain1 = 0.0;  // the level ramps from gain0 to gain1 over the control period
    bool mono = false;  // the mono or legato voice: its pitch follows `glide` at each control
    double configuredPitch = -1.0;  // the pitch its oscillators and filters were last worked out for
    double moving[kSlots] = {};     // the values the slots moved, as its sections were last worked out
    lib::Glide glide;   // in semitones, stepped once per control period
};

// The notes held in mono and legato, newest last (last-note priority: ending the newest returns to the one held
// before it). Holds 16; a 17th forgets the oldest.
class HeldNotes {
public:
    struct Held {
        uint32_t id = 0;
        double pitch = 60.0;
    };
    void push(uint32_t id, double pitch) noexcept {
        remove(id);
        if (count_ == kSize) {
            std::copy(notes_ + 1, notes_ + kSize, notes_);
            --count_;
        }
        notes_[count_++] = {id, pitch};
    }
    bool remove(uint32_t id) noexcept {
        for (uint32_t i = 0; i < count_; ++i)
            if (notes_[i].id == id) {
                std::copy(notes_ + i + 1, notes_ + count_, notes_ + i);
                --count_;
                return true;
            }
        return false;
    }
    Held* find(uint32_t id) noexcept {
        for (uint32_t i = 0; i < count_; ++i)
            if (notes_[i].id == id) return &notes_[i];
        return nullptr;
    }
    const Held* top() const noexcept { return count_ ? &notes_[count_ - 1] : nullptr; }
    bool empty() const noexcept { return count_ == 0; }
    void clear() noexcept { count_ = 0; }

private:
    static constexpr uint32_t kSize = 16;
    Held notes_[kSize];
    uint32_t count_ = 0;
};

class FlagshipInstrument final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return flagshipDescriptor(); }

    bool activate(double sampleRate, uint32_t maxBlock) noexcept override {
        try {
            sr_ = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
            quality_ = buildingQuality();
            tables_ = &tables();
            for (auto& pair : combs_)
                for (lib::CombFilter& c : pair) c.prepare(sr_, 20.0);
            chorus_.prepare(sr_);
            delay_.prepare(sr_, 4.0);  // a bar at 60 bpm
            reverb_.prepare(sr_, static_cast<int>(maxBlock), 0.1);
        } catch (...) {
            return false;
        }
        const Params& p = params();
        for (uint32_t k = 0; k < kParamCount; ++k) base_[k] = p.d[k].defaultValue;
        lastGiven_ = ~0u;  // the next block reads every value
        reset();
        return true;
    }

    void reset() noexcept override {
        voices_.clear();
        held_.clear();
        knobsChanged_ = true;
        for (lib::Lfo& l : lfo_) {
            l = lib::Lfo{};
            l.prepare(sr_);
        }
        clearEffects();
        distOn_ = eqOn_ = chorusOn_ = delayOn_ = reverbOn_ = false;
        clock_.restart();
        sinceControl_ = 0;
        started_ = 0;
        modWheel_ = 0.0;
        idle_ = true;
        quietRun_ = 0;
        periodPeak_ = 0.0f;
        volume0_ = volume1_ = 0.0;
        delayTime0_ = delayTime1_ = 0.0;
    }

    // No voice and the effects cleared: silence until the next note (whose note-on restarts the control grid;
    // the free LFOs and every other clock stood still while idle, so a skipped stretch changes nothing).
    bool quiet() const noexcept override { return idle_; }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        switch (m.type) {
            case NoteMessageType::On: {
                settle();  // the sounding voices move on to this frame first
                if (voiceMode(m.frame) != kPoly) {
                    monoOn(m);
                    break;
                }
                Voice& v = voices_.start(m.noteId);
                v.fresh = !v.env[0].active();  // a stolen voice continues from where it is (no click)
                v.starting = true;
                v.mono = false;
                v.seed = hash32(++started_ * 0x9E3779B9U);
                v.notePitch = v.pitch = m.pitch;
                v.velocity = m.velocity;
                v.pressure = v.timbre = 0.0;
                for (lib::Adsr& e : v.env) e.gateOn();
                idle_ = false;
                clock_.restart();  // the voice's settings from this frame
                break;
            }
            case NoteMessageType::Off:
                if (held_.find(m.noteId)) {
                    settle();
                    monoOff(m);
                    break;
                }
                if (Voice* v = voices_.find(m.noteId); v && v->held) {
                    settle();  // the modulation envelopes release from this frame
                    v->held = false;
                    for (lib::Adsr& e : v->env) e.gateOff();
                }
                break;
            case NoteMessageType::Pitch:
                if (HeldNotes::Held* h = held_.find(m.noteId)) {  // mono: a held note's slide or bend
                    h->pitch = m.pitch;
                    if (Voice* v = voices_.find(m.noteId); v && v->mono)  // the note sounding: followed within ~3 ms
                        v->glide.glideTo(m.pitch, 0.003, sr_ / kControlFrames);
                } else if (Voice* v = voices_.find(m.noteId)) {
                    v->pitch = m.pitch;
                }
                break;
            case NoteMessageType::Pressure:
                if (Voice* v = voices_.find(m.noteId)) v->pressure = m.value;
                break;
            case NoteMessageType::Timbre:
                if (Voice* v = voices_.find(m.noteId)) v->timbre = m.value;
                break;
            case NoteMessageType::Other: break;
        }
    }

    // Mono and legato: one voice. A note while it sounds moves it there (gliding), restarting its envelopes
    // unless legato and another note is held; a note while it is silent starts it afresh.
    void monoOn(const NoteMessage& m) noexcept {
        const bool overlap = !held_.empty();
        const bool legato = voiceMode(m.frame) == kLegato;
        held_.push(m.noteId, m.pitch);
        Voice* sounding = nullptr;
        voices_.forEachActive([&](Voice& v) noexcept {
            if (v.env[0].active() && (!sounding || v.age > sounding->age)) sounding = &v;
        });
        clock_.restart();
        idle_ = false;
        if (sounding && sounding->mono) {
            Voice& v = *sounding;
            v.noteId = m.noteId;
            v.held = true;
            v.notePitch = m.pitch;
            v.glide.glideTo(m.pitch, glideAt(m.frame), sr_ / kControlFrames);
            if (overlap && legato) return;  // a slide: the envelopes run on
            v.velocity = m.velocity;
            v.starting = true;  // the LFOs and the random source restart; the phases run on (no click)
            v.fresh = false;
            for (lib::Adsr& e : v.env) e.gateOn();
            return;
        }
        Voice& v = voices_.start(m.noteId);
        v.fresh = !v.env[0].active();
        v.starting = true;
        v.mono = true;
        v.seed = hash32(++started_ * 0x9E3779B9U);
        v.notePitch = v.pitch = m.pitch;
        v.glide.jump(m.pitch);
        v.velocity = m.velocity;
        v.pressure = v.timbre = 0.0;
        for (lib::Adsr& e : v.env) e.gateOn();
    }
    // A knob at a note's frame: its value in this block (or where it is ramping, there).
    double knobAt(uint32_t k, uint32_t frame) const noexcept {
        if (block_ && k < block_->parameterCount && block_->parameters && block_->parameters[k].samples)
            return block_->parameters[k].samples[frame];
        return base_[k];
    }
    int voiceMode(uint32_t frame) const noexcept { return clampi(knobAt(kVoiceMode, frame), 0, 2); }
    double glideAt(uint32_t frame) const noexcept { return clampd(knobAt(kGlide, frame), 0.001, 2.0); }

    void monoOff(const NoteMessage& m) noexcept {
        const HeldNotes::Held* top = held_.top();
        const bool wasTop = top && top->id == m.noteId;
        held_.remove(m.noteId);
        Voice* v = wasTop ? voices_.find(m.noteId) : nullptr;
        if (!v || !v->mono) return;
        if (held_.empty()) {
            v->held = false;
            for (lib::Adsr& e : v->env) e.gateOff();
            return;
        }
        const HeldNotes::Held& back = *held_.top();  // back to the note held before, gliding, envelopes running on
        v->noteId = back.id;
        v->glide.glideTo(back.pitch, glideAt(m.frame), sr_ / kControlFrames);
        clock_.restart();
    }

    // The mod wheel (controller 1), from a MIDI 1.0 or MIDI 2.0 channel voice message, when the host sends one.
    void onEvent(const Event& e) noexcept override {
        const uint32_t w0 = e.data[0], type = w0 >> 28, status = (w0 >> 20) & 0xF, index = (w0 >> 8) & 0x7F;
        if (status != 0xB || index != 1) return;
        if (type == 0x2) modWheel_ = static_cast<double>(w0 & 0x7F) / 127.0;
        else if (type == 0x4) modWheel_ = static_cast<double>(e.data[1]) / 4294967295.0;
    }

    // The knobs that hold still over this block are read once here, before its notes (whose voice mode and glide
    // they set); the ramping ones at each control.
    void beginBlock(const ProcessBlock& b) noexcept override {
        transport_ = b.transport;
        block_ = &b;
        const Params& p = params();
        const uint32_t given = b.parameters ? std::min(b.parameterCount, kParamCount) : 0;
        // The same values as last block, none ramping (a steady chain hands over the same array): nothing to read.
        // A ramp's samples pointer can stay while its values move, so a block after one with ramps reads them all.
        if (given == lastGiven_ && rampCount_ == 0 && given > 0 &&
            std::memcmp(b.parameters, lastValues_, given * sizeof(ParameterValue)) == 0)
            return;
        lastGiven_ = given;
        if (given > 0) std::memcpy(lastValues_, b.parameters, given * sizeof(ParameterValue));
        rampCount_ = 0;
        bool changed = false;
        for (uint32_t k = 0; k < given; ++k) {  // the host's values (the usual case: every one, none ramping)
            const ParameterValue& pv = b.parameters[k];
            if (pv.samples) {
                ramp_[rampCount_++] = static_cast<uint16_t>(k);
                continue;
            }
            changed |= pv.value != base_[k];
            base_[k] = pv.value;
        }
        for (uint32_t k = given; k < kParamCount; ++k) {
            changed |= p.d[k].defaultValue != base_[k];
            base_[k] = p.d[k].defaultValue;
        }
        knobsChanged_ = knobsChanged_ || changed;  // until the next control has used them
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        if (idle_) {
            std::memset(left, 0, frames * sizeof(float));
            std::memset(right, 0, frames * sizeof(float));
            return;
        }
        clock_.run(frames, offset,
                   [&](uint32_t at) noexcept {
                       settle();
                       control(b, at);
                   },
                   [&](uint32_t start, uint32_t n) noexcept {
                       renderPeriod(left + start, right + start, n);
                       if (!idle_) sinceControl_ += n;  // gone idle: every clock stands still
                   });
    }

private:
    // The grid of controls, carried across render calls (as the other built-in synths' ControlClock).
    class Clock {
    public:
        template <class Control, class Run>
        void run(uint32_t frames, uint32_t offset, Control&& control, Run&& run) noexcept {
            for (uint32_t i = 0; i < frames;) {
                if (left_ == 0) {
                    control(offset + i);
                    left_ = kControlFrames;
                }
                const uint32_t n = std::min(left_, frames - i);
                run(i, n);
                i += n;
                left_ -= n;
            }
        }
        void restart() noexcept { left_ = 0; }

    private:
        uint32_t left_ = 0;
    };

    // Moves every clock on by the frames rendered since the last settle, at once: the same sums however
    // blocks split the time between (a note event settles them before it changes anything).
    void settle() noexcept {
        const uint32_t n = sinceControl_;
        if (n == 0) return;
        const double frames = static_cast<double>(n);
        const double done = n >= kControlFrames ? 1.0 : frames / kControlFrames;
        uint32_t voiceLfos = 0;  // the retriggered LFOs a slot listens to: a voice's own (a free one is the instrument's)
        for (uint32_t l = 0; l < kLfos; ++l)
            if (uses(kSrcLfo1 + l) && retriggered(l)) voiceLfos |= 1u << l;
        voices_.forEachActive([&](Voice& v) noexcept {
            for (OscVoice& o : v.osc)
                for (int c = 0; c < o.count; ++c)
                    if (o.a[c]) o.phase[c] = lib::wrap01(o.phase[c] + frames * o.dt[c]);
            if (uses(kSrcEnv2)) v.env[1].skip(n);
            if (uses(kSrcEnv3)) v.env[2].skip(n);
            for (uint32_t l = 0; l < kLfos; ++l)
                if (voiceLfos & (1u << l)) v.lfo[l].advance(static_cast<int>(n));
            if (uses(kSrcRandom)) v.random.advance(static_cast<int>(n));
            v.gain0 += (v.gain1 - v.gain0) * done;
        });
        for (lib::Lfo& l : lfo_) l.advance(static_cast<int>(n));
        volume0_ += (volume1_ - volume0_) * done;
        delayTime0_ += (delayTime1_ - delayTime0_) * done;
        // The effects' tail: frames since the output was last above -94 dB.
        quietRun_ = periodPeak_ > 2e-5f ? 0 : quietRun_ + n;
        periodPeak_ = 0.0f;
        sinceControl_ = 0;
    }

    // A parameter's value as a fraction 0..1 of its knob's travel (the curve's), and back.
    double toNorm(uint32_t k, double v) const noexcept {
        const ParameterDescriptor& d = params().d[k];
        if (d.curve == ParameterCurve::Exponential) {
            const double r = params().logRange[k];
            return v <= d.minimum || r <= 0.0 ? 0.0 : detLog(v / d.minimum) / r;
        }
        return d.maximum > d.minimum ? (v - d.minimum) / (d.maximum - d.minimum) : 0.0;
    }
    double fromNorm(uint32_t k, double n) const noexcept {
        const ParameterDescriptor& d = params().d[k];
        n = clampd(n, 0.0, 1.0);
        double v = d.curve == ParameterCurve::Exponential ? d.minimum * lib::fastExp(n * params().logRange[k])
                                                          : d.minimum + n * (d.maximum - d.minimum);
        if (d.step > 0.0) v = d.minimum + std::floor((v - d.minimum) / d.step + 0.5) * d.step;
        return clampd(v, d.minimum, d.maximum);
    }

    bool uses(uint32_t source) const noexcept { return (used_ >> source) & 1u; }
    bool retriggered(uint32_t lfo) const noexcept { return clampi(base_[lfoParam(lfo, kLfoMode)], 0, 2) == kLfoRetrigger; }

    // A source's value for a voice, 0..1 (a bipolar source such as an LFO is centred on 0.5).
    double sourceValue(const Voice& v, int source, double bendRange) const noexcept {
        switch (source) {
            case kSrcEnv1:
            case kSrcEnv2:
            case kSrcEnv3: return v.env[source - kSrcEnv1].level();
            case kSrcLfo1:
            case kSrcLfo2:
            case kSrcLfo3: {
                const uint32_t l = static_cast<uint32_t>(source - kSrcLfo1);
                return 0.5 * ((retriggered(l) ? v.lfo[l].value() : freeLfo_[l]) + 1.0);
            }
            case kSrcRandom: return 0.5 * (v.random.value() + 1.0);
            case kSrcVelocity: return v.velocity;
            case kSrcNote: return clampd(v.pitch / 127.0, 0.0, 1.0);
            case kSrcBend: return 0.5 * (clampd((v.pitch - v.notePitch) / bendRange, -1.0, 1.0) + 1.0);
            case kSrcPressure: return v.pressure;
            case kSrcTimbre: return v.timbre;
            case kSrcModWheel: return modWheel_;
            case kSrcAccent: return clampd((v.velocity - 0.7) / 0.3, 0.0, 1.0);  // a 303's: above 0.7, fully at 1
            default: return 0.0;
        }
    }

    // The value of parameter k for a voice whose slot offsets are `offsets`.
    // (k is below kModTargets: the slots' own parameters are read from base_.) The unmodulated case, by far the
    // most common, is a load and a branch.
    CAW_FORCE_INLINE double value(uint32_t k, const double* offsets) const noexcept {
        const int t = targetOf_[k];
        // A slot whose source is at 0 (an envelope at rest, no timbre) leaves the knob as it is: no exp, and the
        // filter that reads it keeps its coefficients.
        return t && offsets[t - 1] != 0.0 ? modulated(k, t - 1, offsets) : base_[k];
    }
    CAW_NO_INLINE double modulated(uint32_t k, int t, const double* offsets) const noexcept { return fromNorm(k, targetNorm_[t] + offsets[t]); }

    // Once per control period: the knobs, the matrix, every sounding voice's settings and the effects.
    void control(const ProcessBlock& b, uint32_t at) noexcept {
        for (uint32_t r = 0; r < rampCount_; ++r) base_[ramp_[r]] = b.parameters[ramp_[r]].samples[at];
        tempo_ = transport_ && transport_->tempo > 0.0 ? transport_->tempo : 120.0;
        // What a voice must work out again this control: everything when a knob, the tempo or the quality moved;
        // otherwise only the sections a slot modulates, and what follows the pitch (2026-11-10 performance pass).
        const int quality = qualityNow(quality_);
        if (rampCount_ > 0 || tempo_ != lastTempo_ || quality != lastQuality_) knobsChanged_ = true;
        lastTempo_ = tempo_;
        lastQuality_ = quality;
        const bool beatLocked = transport_ && transport_->playing;
        const double beat = beatLocked ? transport_->beat + at * tempo_ / (60.0 * sr_) : 0.0;

        // The matrix: the slots that move something, and the parameters they move (each once, in slot order).
        // It is read from the knobs alone, so it stands while none moved.
        if (knobsChanged_) buildMatrix();

        // The free LFOs run once for the instrument, on their knobs' own values; synced to a playing song,
        // they follow its position.
        for (uint32_t l = 0; l < kLfos; ++l) {
            if (!uses(kSrcLfo1 + l)) continue;
            const int sync = clampi(base_[lfoParam(l, kLfoSync)], 0, 9);
            if (knobsChanged_) {
                lfo_[l].setShape(static_cast<lib::LfoShape>(clampi(base_[lfoParam(l, kLfoShape)], 0, 6)));
                if (sync > 0) lfo_[l].setRateBeats(kLfoSyncBeats[sync], tempo_);
                else lfo_[l].setRateHz(base_[lfoParam(l, kLfoRate)]);
            }
            if (sync > 0 && beatLocked && clampi(base_[lfoParam(l, kLfoMode)], 0, 2) != kLfoRunning)
                lfo_[l].syncToBeat(beat, kLfoSyncBeats[sync]);
            freeLfo_[l] = lfo_[l].value();
        }

        // Each voice: its sources, its slot offsets, then its settings.
        uint64_t newest = 0;
        std::fill(globalOffsets_, globalOffsets_ + kSlots, 0.0);
        const double bendRange = clampd(base_[kBendRange], 1.0, 48.0);
        voices_.forEachActive([&](Voice& v) noexcept {
            if (v.starting) startVoice(v);
            if (v.mono) v.pitch = v.glide.next();
            double offsets[kSlots] = {};
            for (uint32_t s = 0; s < slotCount_; ++s) {
                const Slot& slot = slots_[s];
                const double u = sourceValue(v, slot.source, bendRange);
                const double scale = slot.via != kSrcNone ? sourceValue(v, slot.via, bendRange) : 1.0;
                offsets[slot.target] += slot.amount * (slot.bipolar ? 2.0 * u - 1.0 : u) * scale;
            }
            configureVoice(v, offsets);
            if (v.age > newest) {
                newest = v.age;
                std::copy(offsets, offsets + kSlots, globalOffsets_);
            }
        });

        // The instrument's own parameters, moved by the newest voice.
        const auto g = [&](uint32_t k) noexcept { return value(k, globalOffsets_); };
        const double velocityAmount = clampd(g(kVelocity), 0.0, 1.0);
        voices_.forEachActive([&](Voice& v) noexcept {
            v.gain1 = 1.0 - velocityAmount * (1.0 - v.velocity);
            if (v.starting) {
                v.gain0 = v.gain1;
                v.starting = false;
            }
        });
        volume1_ = clampd(g(kVolume), 0.0, 1.0);
        // The effects read the knobs, the tempo, the quality and the slots moving the instrument's parameters.
        if (knobsChanged_ || (moved_ & kMovedGlobal)) configureEffects(g);

        knobsChanged_ = false;
        // Nothing sounding and the tails below -94 dB for long enough: clear the effects and rest.
        if (voices_.activeCount() == 0) {
            const bool fx = distOn_ || eqOn_ || chorusOn_ || delayOn_ || reverbOn_;
            const double window = fx ? 0.1 * sr_ + (delayOn_ ? delayTime1_ : 0.0) : 0.0;
            if (static_cast<double>(quietRun_) >= window) {
                clearEffects();
                idle_ = true;
            }
        } else {
            quietRun_ = 0;
        }
    }

    void buildMatrix() noexcept {
        std::memset(targetOf_, 0, sizeof targetOf_);
        slotCount_ = targetCount_ = 0;
        used_ = 0;
        moved_ = 0;
        for (uint32_t s = 0; s < kSlots; ++s) {
            const int src = clampi(base_[modParam(s, kModSource)], 0, kSourceCount - 1);
            const int dst = clampi(base_[modParam(s, kModTarget)], 0, kModTargets) - 1;
            const double amount = clampd(base_[modParam(s, kModAmount)], -1.0, 1.0);
            if (src == kSrcNone || dst < 0 || amount == 0.0) continue;
            if (!targetOf_[dst]) {
                targetParam_[targetCount_] = static_cast<uint32_t>(dst);
                targetNorm_[targetCount_] = toNorm(static_cast<uint32_t>(dst), base_[dst]);
                targetOf_[dst] = static_cast<uint8_t>(++targetCount_);
            }
            const int via = clampi(base_[viaParam(s)], 0, kSourceCount - 1);
            slots_[slotCount_++] = {src, targetOf_[dst] - 1, amount, base_[modParam(s, kModPolarity)] >= 0.5, via};
            moved_ |= sectionOf(static_cast<uint32_t>(dst));
            used_ |= (1u << src) | (via != kSrcNone ? 1u << via : 0u);
        }
    }

    // A note's start, with the knobs (unmodulated) at its frame: the retriggered LFOs and the random source
    // restart, and a fresh voice (not a stolen one) takes its copies' start phases and its comb lines.
    void startVoice(Voice& v) noexcept {
        for (uint32_t l = 0; l < kLfos; ++l) {
            v.lfo[l].prepare(sr_);
            v.lfo[l].setSeed(v.seed + l);
            v.lfo[l].retrigger();
        }
        v.random.prepare(sr_);
        v.random.setSeed(v.seed ^ 0xA511E9B3U);
        v.random.retrigger();
        if (!v.fresh) return;
        for (uint32_t o = 0; o < kOscs; ++o) {
            const double start = base_[oscParam(o, kOscPhase)], randomness = base_[oscParam(o, kOscPhaseRand)];
            for (int c = 0; c < kMaxCopies; ++c) {
                const double r = static_cast<double>(hash32(v.seed ^ ((o * 16U + c + 1U) * 0x85EBCA6BU))) / 4294967296.0;
                v.osc[o].phase[c] = lib::wrap01(start + randomness * r);
            }
        }
        const uint32_t index = static_cast<uint32_t>(&v - voices_.begin());
        for (uint32_t f = 0; f < kFilters; ++f)
            for (int c = 0; c < 2; ++c) v.filter[f].comb[c] = &combs_[index][f * 2 + c];
    }

    // The voice section a parameter belongs to (a bit of moved_), kMovedGlobal for the instrument-wide ones.
    static uint32_t sectionOf(uint32_t k) noexcept {
        if (k < kFltBase) return 1u << (k / kOscCount);                    // osc 1..3: bits 0..2
        if (k < kFltRouting) return 1u << (3 + (k - kFltBase) / kFltCount);  // filter 1, 2: bits 3, 4
        if (k == kFltRouting) return kMovedRouting;
        if (k < kLfoBase) return kMovedEnvs;
        if (k < kVolume) return kMovedLfos;
        return kMovedGlobal;
    }
    static constexpr uint32_t kMovedRouting = 1u << 5, kMovedEnvs = 1u << 6, kMovedLfos = 1u << 7, kMovedGlobal = 1u << 8;

    void configureVoice(Voice& v, const double* offsets) noexcept {
        // The values the slots move, once each (an exp for each one away from its knob).
        double moving[kSlots];
        for (uint32_t t = 0; t < targetCount_; ++t)
            moving[t] = offsets[t] != 0.0 ? modulated(targetParam_[t], static_cast<int>(t), offsets) : base_[targetParam_[t]];
        const auto P = [&](uint32_t k) noexcept {
            const int t = targetOf_[k];
            return t ? moving[t - 1] : base_[k];
        };
        // Only what changed: every section at a note's start or after a knob moved; else the sections where a value
        // a slot moves is not what it was at the last control (a slot whose source rests changes nothing), and what
        // follows the pitch (it glides, bends). An oscillator whose frame alone moved (an LFO sweeping the table)
        // only re-reads its frames (2026-11-10 second performance pass).
        const bool all = v.starting || knobsChanged_;
        const bool pitch = v.pitch != v.configuredPitch;
        v.configuredPitch = v.pitch;
        uint32_t changed = 0, frameOnly = 0;
        if (!all) {
            uint32_t frame = 0, other = 0;
            for (uint32_t t = 0; t < targetCount_; ++t) {
                if (moving[t] == v.moving[t]) continue;
                const uint32_t k = targetParam_[t], section = sectionOf(k);
                changed |= section;
                (k < kFltBase && k % kOscCount == kOscFrame ? frame : other) |= section;
            }
            frameOnly = pitch ? 0u : frame & ~other;
        }
        std::copy(moving, moving + targetCount_, v.moving);
        const auto moved = [&](uint32_t bits) noexcept { return all || (changed & bits) != 0; };
        // Only what a slot listens to runs (env 1 always: it is the level).
        for (uint32_t e = 0; e < kEnvs && moved(kMovedEnvs); ++e)
            if (e == 0 || uses(kSrcEnv1 + e))
                v.env[e].set(P(envParam(e, kEnvAttack)), P(envParam(e, kEnvDecay)), P(envParam(e, kEnvSustain)),
                             P(envParam(e, kEnvRelease)), sr_);
        for (uint32_t l = 0; l < kLfos && moved(kMovedLfos); ++l) {
            if (!uses(kSrcLfo1 + l) || !retriggered(l)) continue;  // unused, or the instrument's
            const int sync = clampi(P(lfoParam(l, kLfoSync)), 0, 9);
            v.lfo[l].setShape(static_cast<lib::LfoShape>(clampi(P(lfoParam(l, kLfoShape)), 0, 6)));
            if (sync > 0) v.lfo[l].setRateBeats(kLfoSyncBeats[sync], tempo_);
            else v.lfo[l].setRateHz(P(lfoParam(l, kLfoRate)));
        }
        if (uses(kSrcRandom) && moved(kMovedLfos)) {
            v.random.setShape(P(kRndMode) >= 0.5 ? lib::LfoShape::SmoothRandom : lib::LfoShape::SampleHold);
            v.random.setRateHz(P(kRndRate));
        }
        for (uint32_t o = 0; o < kOscs; ++o) {
            if (frameOnly & (1u << o)) moveFrame(v.osc[o], P(oscParam(o, kOscFrame)));
            else if (moved(1u << o)) configureOscillator(v, o, P);
            else if (pitch) retune(v.osc[o], v.pitch);
        }
        if (moved(kMovedRouting)) v.parallel = P(kFltRouting) >= 0.5;
        for (uint32_t f = 0; f < kFilters; ++f) {
            // The pitch moves a filter only through its key tracking.
            if (!moved(1u << (3 + f)) && !(pitch && P(fltParam(f, kFltKeytrack)) != 0.0)) continue;
            if (P(fltParam(f, kFltOn)) < 0.5) {
                v.filter[f].configure(false, 0, 0, 0, 1, 0, 1, sr_, v.starting && v.fresh);
                continue;
            }
            const double keytrack = P(fltParam(f, kFltKeytrack));
            const double cutoff = P(fltParam(f, kFltCutoff)) * (keytrack != 0.0 ? exp2(keytrack * (v.pitch - 60.0) / 12.0) : 1.0);
            v.filter[f].configure(true, clampi(P(fltParam(f, kFltType)), 0, kFilterTypeCount - 1),
                                  cutoff, clampd(P(fltParam(f, kFltResonance)), 0.0, 1.0), P(fltParam(f, kFltDrive)),
                                  P(fltParam(f, kFltMorph)), P(fltParam(f, kFltMix)), sr_, v.starting && v.fresh);
        }
        v.fresh = false;
    }

    // Only the frame position moved: the copies keep their steps, mip levels and gains, and read the new pair of
    // frames (the same frames and morph as configureOscillator works out).
    void moveFrame(OscVoice& o, double frame) noexcept {
        if (!o.on || o.key.table < 0) return;
        const double position = clampd(frame, 0.0, 1.0);
        if (position == o.key.position) return;
        o.key.position = position;
        const lib::Wavetable& table = tables_->table[o.key.table];
        const double at = position * (table.frameCount() - 1);
        const int f0 = static_cast<int>(at), f1 = f0 + 1 < table.frameCount() ? f0 + 1 : f0;
        o.mix = static_cast<float>(at - f0);
        if (f0 == o.f0 && f1 == o.f1) return;
        for (int c = 0; c < o.count; ++c)
            if (o.a[c]) o.a[c] = table.levelData(f0, o.level[c]), o.b[c] = table.levelData(f1, o.level[c]);
        o.f0 = f0;
        o.f1 = f1;
    }

    template <class Get>
    void configureOscillator(Voice& v, uint32_t index, const Get& P) noexcept {
        OscVoice& o = v.osc[index];
        const auto at = [&](uint32_t p) noexcept { return P(oscParam(index, p)); };
        o.on = at(kOscOn) >= 0.5;
        if (!o.on) {
            o.count = 0;
            o.key.table = -1;  // on again: everything is worked out afresh
            o.layoutKey.voices = -1;
            return;
        }
        o.dest = clampi(at(kOscDest), 0, 3);
        OscKey key;
        key.table = clampi(at(kOscTable), 0, kTableCount - 1);
        key.position = clampd(at(kOscFrame), 0.0, 1.0);
        key.level = clampd(at(kOscLevel), 0.0, 1.0);
        key.pan = clampd(at(kOscPan), -1.0, 1.0);
        o.pitchOffset[0] = 12.0 * clampi(at(kOscOctave), -4, 4);
        o.pitchOffset[1] = clampi(at(kOscSemi), -12, 12);
        o.pitchOffset[2] = clampd(at(kOscFine), -100.0, 100.0) / 100.0;
        key.pitch = v.pitch + o.pitchOffset[0] + o.pitchOffset[1] + o.pitchOffset[2];
        key.amount = clampd(at(kOscWarpAmount), 0.0, 1.0);
        key.warp = key.amount > 0.0 ? clampi(at(kOscWarp), 0, 4) : kWarpNone;
        lib::UnisonSettings& u = key.unison;
        // Eco quality caps each oscillator at 4 copies (the outermost and the centre kept: the stack is laid out
        // again for 4, so its detune and spread stay as wide).
        u.voices = clampi(at(kOscUnison), 1, qualityNow(quality_) == kQualityEco ? kEcoCopies : kMaxCopies);
        u.detune = clampd(at(kOscDetune), 0.0, 100.0) / 100.0;
        u.power = at(kOscPower);
        u.spread = at(kOscSpread);
        u.blend = at(kOscBlend);
        u.stack = static_cast<lib::UnisonStack>(clampi(at(kOscStack), 0, lib::kUnisonStackCount - 1));
        if (key == o.key) return;  // nothing moved: the copies keep their steps, levels and gains

        const lib::Wavetable& table = tables_->table[key.table];
        const double position = key.position * (table.frameCount() - 1);
        const int f0 = static_cast<int>(position), f1 = f0 + 1 < table.frameCount() ? f0 + 1 : f0;
        o.mix = static_cast<float>(position - f0);
        o.f0 = f0;
        o.f1 = f1;
        {
            // Only the frame position moved (an LFO sweeping the table): the copies keep their steps, mip levels
            // and gains, and just read the new pair of frames.
            OscKey moved = key;
            moved.position = o.key.position;
            if (moved == o.key) {
                o.key = key;
                for (int c = 0; c < o.count; ++c)
                    if (o.a[c]) o.a[c] = table.levelData(f0, o.level[c]), o.b[c] = table.levelData(f1, o.level[c]);
                return;
            }
        }
        if (!(u == o.layoutKey)) {
            o.layoutKey = u;
            o.count = lib::unisonLayout(u, o.layout);
            for (int c = 0; c < o.count; ++c) o.ratio[c] = exp2(o.layout[c].semitones / 12.0);
            o.panKey = 2.0;  // the pans follow the layout
        }
        if (key.pan != o.panKey) {
            o.panKey = key.pan;
            for (int c = 0; c < o.count; ++c) {
                const double q = clampd(key.pan + o.layout[c].pan, -1.0, 1.0);
                double l = 1.0, r = 1.0;  // the centre at unity on both sides, exactly
                if (q != 0.0) {  // mirror pans get mirror gains, bit for bit
                    const lib::PanGains g = lib::constantPowerPan(q < 0.0 ? -q : q);
                    l = g.left * 1.41421356237309505;
                    r = g.right * 1.41421356237309505;
                    if (q < 0.0) std::swap(l, r);
                }
                o.panL[c] = l * o.layout[c].gain;
                o.panR[c] = r * o.layout[c].gain;
            }
        }
        if (key.pitch != o.key.pitch || o.key.table < 0) o.hz = 440.0 * exp2((key.pitch - 69.0) / 12.0);
        // The warp's constants, and how much faster than the note it reads the table (for the mip level).
        const double amount = key.amount;
        double faster = 1.0;
        switch (key.warp) {
            case kWarpBend:
                o.w1 = static_cast<float>(amount);
                faster = 1.0 + amount;
                break;
            case kWarpSync:
                o.w1 = static_cast<float>(1.0 + 7.0 * amount);
                faster = o.w1;
                break;
            case kWarpMirror:
                o.w1 = static_cast<float>(1.0 - 0.5 * amount);  // the turn
                o.w2 = static_cast<float>(1.0 / (1.0 - 0.5 * amount));
                o.w3 = static_cast<float>(1.0 / (0.5 * amount));
                faster = 1.0 / (1.0 - 0.5 * amount);
                break;
            case kWarpQuantize: {
                const double steps = std::floor(exp2(8.0 - 7.0 * amount));  // 256 .. 2 steps a cycle
                o.w1 = static_cast<float>(steps);
                o.w2 = static_cast<float>(1.0 / steps);
                break;
            }
            default: break;
        }
        o.warpMode = key.warp;
        o.key = key;
        o.faster = faster;
        tuneCopies(o, table);
    }

    // The pitch alone moved (a glide, a bend): the copies' steps and mip levels follow it; nothing else changed.
    void retune(OscVoice& o, double notePitch) noexcept {
        if (!o.on || o.key.table < 0) return;
        const double pitch = notePitch + o.pitchOffset[0] + o.pitchOffset[1] + o.pitchOffset[2];  // configureOscillator's sum
        if (pitch == o.key.pitch) return;
        o.key.pitch = pitch;
        o.hz = 440.0 * exp2((pitch - 69.0) / 12.0);
        tuneCopies(o, tables_->table[o.key.table]);
    }

    // Each copy's step, mip level, frames and gains, from the oscillator's pitch, frames and layout.
    void tuneCopies(OscVoice& o, const lib::Wavetable& table) noexcept {
        const int f0 = o.f0, f1 = o.f1;
        const double faster = o.faster;
        const OscKey& key = o.key;
        const double perSample = o.hz / sr_;
        for (int c = 0; c < o.count; ++c) {
            const double dt = perSample * o.ratio[c];
            if (!(dt > 0.0 && dt < 0.5)) {  // above Nyquist: silent
                o.a[c] = o.b[c] = nullptr;
                o.dt[c] = 0.0;
                continue;
            }
            const int k = mipLevel(dt * faster, table.levels());
            o.dt[c] = dt;
            o.a[c] = table.levelData(f0, k);
            o.b[c] = table.levelData(f1, k);
            o.size[c] = static_cast<float>(table.levelSize(k));
            o.level[c] = k;
            o.step[c] = static_cast<uint32_t>(dt * 4294967296.0 + 0.5);
            o.shift[c] = 32 - std::countr_zero(static_cast<uint32_t>(table.levelSize(k)));
            o.gainL[c] = static_cast<float>(o.panL[c] * key.level);
            o.gainR[c] = static_cast<float>(o.panR[c] * key.level);
        }
        o.centred = true;
        for (int c = 0; c < o.count; ++c) o.centred = o.centred && (!o.a[c] || o.gainL[c] == o.gainR[c]);
    }

    template <class Get>
    void configureEffects(const Get& g) noexcept {
        const bool dist = g(kDistOn) >= 0.5, eq = g(kEqOn) >= 0.5, chorus = g(kChorusOn) >= 0.5,
                   delay = g(kDelayOn) >= 0.5, reverb = g(kReverbOn) >= 0.5;
        // An effect switched on starts from silence (not from a tail it held when it was switched off).
        // (Only one that ran since its last clear holds anything: the delay and reverb hold seconds of memory.)
        if (eq && !eqOn_ && (fxDirty_ & kFxEq)) eqL_.clear(), eqR_.clear();
        if (chorus && !chorusOn_ && (fxDirty_ & kFxChorus)) chorus_.clear();
        if (delay && !delayOn_ && (fxDirty_ & kFxDelay)) delay_.clear();
        if (reverb && !reverbOn_ && (fxDirty_ & kFxReverb)) reverb_.clear();
        const bool delayWasOn = delayOn_;
        fxDirty_ |= (eq ? kFxEq : 0u) | (chorus ? kFxChorus : 0u) | (delay ? kFxDelay : 0u) | (reverb ? kFxReverb : 0u);
        distOn_ = dist;
        eqOn_ = eq;
        chorusOn_ = chorus;
        delayOn_ = delay;
        reverbOn_ = reverb;
        if (dist) {
            distType_ = clampi(g(kDistType), 0, 3);
            distDrive_ = clampd(g(kDistDrive), 1.0, 20.0);
            distMix_ = clampd(g(kDistMix), 0.0, 1.0);
            saturator_.set(distDrive_);
            // Crush: 24 bits at drive 1 down to 2 at drive 20.
            crushSteps_ = std::floor(exp2(std::floor(24.0 - 22.0 * (distDrive_ - 1.0) / 19.0) - 1.0));
        }
        if (eq) {
            const double low = g(kEqLow), mid = g(kEqMid), high = g(kEqHigh), freq = g(kEqMidFreq);
            eqL_.set(low, mid, high, freq, sr_);
            eqR_.set(low, mid, high, freq, sr_);
            eqMix_ = clampd(g(kEqMix), 0.0, 1.0);
        }
        if (chorus) {
            chorus_.control(g(kChorusRate), clampd(g(kChorusDepth), 0.0, 1.0), kControlFrames);
            chorusMix_ = clampd(g(kChorusMix), 0.0, 1.0);
        }
        if (delay) {
            const int sync = clampi(g(kDelaySync), 0, 7);
            const double seconds = sync > 0 ? lib::noteSeconds(tempo_, kDelaySyncWholes[sync]) : g(kDelayTime);
            delayTime1_ = clampd(seconds, 0.001, 4.0) * sr_;  // in frames
            if (!delayWasOn) delayTime0_ = delayTime1_;  // switched on: no glide from an old time
            delayFeedback_ = clampd(g(kDelayFeedback), 0.0, 0.95);
            delayMix_ = clampd(g(kDelayMix), 0.0, 1.0);
        }
        if (reverb) {
            reverb_.setLight(qualityNow(quality_) == kQualityEco);
            lib::ReverbSettings s;
            s.size = g(kReverbSize);
            s.decay = g(kReverbDecay);
            s.damping = g(kReverbDamping);
            s.mix = g(kReverbMix);
            const lib::ReverbSettings& was = reverb_.settings();
            if (s.size != was.size || s.decay != was.decay || s.damping != was.damping || s.mix != was.mix) reverb_.set(s);
        }
    }

    // The delay and reverb hold seconds of memory (a 4 s delay line is 1.5 MB): a clear (every Play, every rest)
    // touches them only when they ran since the last one.
    void clearEffects() noexcept {
        quietRun_ = 0;
        if (fxDirty_ & kFxEq) eqL_.clear(), eqR_.clear();
        if (fxDirty_ & kFxChorus) chorus_.clear();
        if (fxDirty_ & kFxDelay) delay_.clear();
        if (fxDirty_ & kFxReverb) reverb_.clear();
        fxDirty_ = 0;
    }

    // A constant-size memset the compiler writes as a few vector stores (a plain loop can become a memset call).
    static void zero(float* x) noexcept { std::memset(x, 0, kControlFrames * sizeof(float)); }

    // One voice's piece of the period: its oscillators into their filters, the filters, the level.
    void renderVoice(Voice& v, float* outL, float* outR, uint32_t n, uint32_t first) noexcept {
        float f1L[kControlFrames], f1R[kControlFrames], f2L[kControlFrames], f2R[kControlFrames];
        float byL[kControlFrames], byR[kControlFrames];
        bool bypass = false, second = v.filter[1].on;  // second: filter 2's path carries anything
        for (const OscVoice& o : v.osc) {
            if (!o.on || o.count == 0) continue;
            bypass = bypass || o.dest == kToBypass;
            second = second || o.dest == kToFilter2 || (v.parallel && o.dest == kToBoth);
        }
        // Whole periods cleared (a fixed count: inline stores, no memset call).
        zero(f1L), zero(f1R);
        if (second) zero(f2L), zero(f2R);
        if (bypass) zero(byL), zero(byR);
        for (const OscVoice& o : v.osc) {
            if (!o.on || o.count == 0) continue;
            switch (o.dest) {
                case kToFilter2: addOscillator(o, f2L, f2R, n, first); break;
                case kToBypass: addOscillator(o, byL, byR, n, first); break;
                case kToBoth:
                    if (v.parallel) {
                        float tL[kControlFrames] = {}, tR[kControlFrames] = {};
                        addOscillator(o, tL, tR, n, first);
                        for (uint32_t i = 0; i < n; ++i) {
                            f1L[i] += tL[i];
                            f1R[i] += tR[i];
                            f2L[i] += tL[i];
                            f2R[i] += tR[i];
                        }
                        break;
                    }
                    [[fallthrough]];  // in series, filter 1 feeds filter 2 anyway
                default: addOscillator(o, f1L, f1R, n, first); break;
            }
        }
        // A centred voice through filter 1 alone (the bass, the acid line, Basic): one side filtered, both sides
        // the same bits as before at half the filter's cost (2026-11-10 performance pass).
        if (!second && !bypass && v.filter[0].monoCapable()) {
            bool centred = true;
            for (const OscVoice& o : v.osc)
                if (o.on && o.count > 0) centred = centred && o.centred;
            if (centred) {
                v.filter[0].processMono(f1L, n);
                float amp[kControlFrames];
                const double step = (v.gain1 - v.gain0) / kControlFrames;
                for (uint32_t i = 0; i < n; ++i)
                    amp[i] = static_cast<float>(v.env[0].next() * (v.gain0 + step * static_cast<double>(first + i)));
                for (uint32_t i = 0; i < n; ++i) {
                    const float y = f1L[i] * amp[i];
                    outL[i] += y;
                    outR[i] += y;
                }
                if (!v.env[0].active()) v.active = false;
                return;
            }
        }
        v.filter[0].process(f1L, f1R, n);
        // The voice's output: filter 1's, through or beside filter 2's, plus the bypass.
        float* yL = f1L;
        float* yR = f1R;
        if (second) {
            if (v.parallel) {
                v.filter[1].process(f2L, f2R, n);
                for (uint32_t i = 0; i < n; ++i) f1L[i] += f2L[i], f1R[i] += f2R[i];
            } else {
                for (uint32_t i = 0; i < n; ++i) f2L[i] += f1L[i], f2R[i] += f1R[i];
                v.filter[1].process(f2L, f2R, n);
                yL = f2L;
                yR = f2R;
            }
        }
        if (bypass)
            for (uint32_t i = 0; i < n; ++i) yL[i] += byL[i], yR[i] += byR[i];
        float amp[kControlFrames];
        const double step = (v.gain1 - v.gain0) / kControlFrames;
        for (uint32_t i = 0; i < n; ++i) amp[i] = static_cast<float>(v.env[0].next() * (v.gain0 + step * static_cast<double>(first + i)));
        for (uint32_t i = 0; i < n; ++i) {
            outL[i] += yL[i] * amp[i];
            outR[i] += yR[i] * amp[i];
        }
        if (!v.env[0].active()) v.active = false;
    }

    // One piece (n <= kControlFrames frames) of the control period, sinceControl_ frames into it.
    void renderPeriod(float* left, float* right, uint32_t n) noexcept {
        if (idle_) {
            std::memset(left, 0, n * sizeof(float));
            std::memset(right, 0, n * sizeof(float));
            return;
        }
        const uint32_t first = sinceControl_;
        float L[kControlFrames] = {}, R[kControlFrames] = {};
        voices_.forEachActive([&](Voice& v) noexcept { renderVoice(v, L, R, n, first); });
        const double volumeStep = (volume1_ - volume0_) / kControlFrames;
        const double delayStep = (delayTime1_ - delayTime0_) / kControlFrames;
        float peak = periodPeak_;
        if (!(distOn_ || eqOn_ || chorusOn_ || delayOn_ || reverbOn_)) {  // dry: one plain loop the compiler vectorizes
            for (uint32_t i = 0; i < n; ++i) {
                const double volume = volume0_ + volumeStep * static_cast<double>(first + i);
                const float ol = static_cast<float>(finiteOr0(L[i] * volume)), orr = static_cast<float>(finiteOr0(R[i] * volume));
                left[i] = ol;
                right[i] = orr;
                peak = std::max(peak, std::max(std::fabs(ol), std::fabs(orr)));
            }
            periodPeak_ = peak;
            return;
        }
        // Both sides the same (every voice centred: the bass, the acid line): the distortion, which holds no state,
        // runs on one and gives the other the same bits.
        // Silence (between notes) stays silence through every type (what the sum below gives for a 0 in: +0).
        const bool same = distOn_ && std::memcmp(L, R, n * sizeof(float)) == 0;
        const auto dist = [&](double x) noexcept { return x == 0.0 ? 0.0 : x + (distort(x) - x) * distMix_; };
        for (uint32_t i = 0; i < n; ++i) {
            const double at = static_cast<double>(first + i);
            double l = L[i], r = R[i];
            if (distOn_) {
                l = dist(l);
                r = same ? l : dist(r);
            }
            if (eqOn_) {
                l += (eqL_.process(l) - l) * eqMix_;
                r += (eqR_.process(r) - r) * eqMix_;
            }
            float fl = static_cast<float>(l), fr = static_cast<float>(r);
            if (chorusOn_) chorus_.step(chorusMix_, fl, fr);
            if (delayOn_) delay_.process((delayTime0_ + delayStep * at) / sr_, delayFeedback_, 1.0, delayMix_, fl, fr);
            if (reverbOn_) reverb_.process(fl, fr);
            const double volume = volume0_ + volumeStep * at;
            const float ol = static_cast<float>(finiteOr0(fl * volume)), orr = static_cast<float>(finiteOr0(fr * volume));
            left[i] = ol;
            right[i] = orr;
            peak = std::max(peak, std::max(std::fabs(ol), std::fabs(orr)));
        }
        periodPeak_ = peak;
    }

    double distort(double x) const noexcept {
        switch (distType_) {
            case 1: return lib::hardClip(x, distDrive_);
            case 2: return lib::fastSinCycles(finiteOr0(x) * distDrive_ * 0.25);  // lib::fold: sin(x d pi / 2)
            case 3: return std::floor(finiteOr0(x) * crushSteps_ + 0.5) / crushSteps_;
            default: return saturator_.process(x);
        }
    }

    struct Slot {
        int source = kSrcNone;
        int target = 0;  // into targetParam_
        double amount = 0.0;
        bool bipolar = false;
        int via = kSrcNone;  // the source the amount is scaled by (None: 1)
    };

    VoicePool<Voice, kVoices> voices_;
    HeldNotes held_;  // mono and legato
    lib::CombFilter combs_[kVoices][kFilters * 2];
    const Tables* tables_ = nullptr;
    const std::atomic<int>* quality_ = nullptr;  // the building Engine's (quality.h)
    Clock clock_;
    const Transport* transport_ = nullptr;
    const ProcessBlock* block_ = nullptr;  // the block being processed (beginBlock), for knobs at a note's frame
    double sr_ = 48000.0, tempo_ = 120.0, modWheel_ = 0.0;
    uint32_t sinceControl_ = 0, started_ = 0;
    bool idle_ = true;
    uint64_t quietRun_ = 0;
    float periodPeak_ = 0.0f;

    double base_[kParamCount] = {};
    uint16_t ramp_[kParamCount] = {};  // the parameters ramping in this block
    uint32_t rampCount_ = 0;
    ParameterValue lastValues_[kParamCount] = {};  // the block's values as last handed over (beginBlock)
    uint32_t lastGiven_ = ~0u;
    lib::Lfo lfo_[kLfos];
    double freeLfo_[kLfos] = {};
    Slot slots_[kSlots];
    uint32_t slotCount_ = 0, targetCount_ = 0, used_ = 0;
    uint32_t moved_ = 0;          // the voice sections (sectionOf) a slot moves this control
    bool knobsChanged_ = true;    // a knob, the tempo or the quality moved since the last control
    double lastTempo_ = 0.0;
    int lastQuality_ = -1;  // used_: bit s set when a slot listens to source s
    uint32_t targetParam_[kSlots] = {};
    double targetNorm_[kSlots] = {};
    uint8_t targetOf_[kModTargets] = {};  // 1 + the parameter's index into targetParam_, 0 if no slot moves it
    double globalOffsets_[kSlots] = {};

    double volume0_ = 0.0, volume1_ = 0.0;
    bool distOn_ = false, eqOn_ = false, chorusOn_ = false, delayOn_ = false, reverbOn_ = false;
    int distType_ = 0;
    double distDrive_ = 2.0, distMix_ = 1.0, crushSteps_ = 8.0;
    lib::Saturator saturator_;
    lib::ThreeBandEq eqL_, eqR_;
    double eqMix_ = 1.0;
    lib::Chorus chorus_;
    double chorusMix_ = 0.35;
    lib::PingPongDelay delay_;
    double delayTime0_ = 0.0, delayTime1_ = 0.0, delayFeedback_ = 0.35, delayMix_ = 0.25;
    lib::Reverb reverb_;
    static constexpr uint32_t kFxEq = 1, kFxChorus = 2, kFxDelay = 4, kFxReverb = 8;
    uint32_t fxDirty_ = kFxEq | kFxChorus | kFxDelay | kFxReverb;  // the effects that were on since their last clear
};

ModuleProcessor* makeFlagship() noexcept { return new (std::nothrow) FlagshipInstrument(); }

}  // namespace

void registerFlagshipSynth(ModuleRegistry& registry) { registry.add(flagshipDescriptor(), &makeFlagship); }

int flagshipParameterIndex(std::string_view id) noexcept {
    const Params& p = params();
    for (uint32_t k = 0; k < kParamCount; ++k)
        if (p.d[k].id == id) return static_cast<int>(k);
    return -1;
}

}  // namespace caw
