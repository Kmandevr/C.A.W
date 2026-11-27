// Flagship's limits, parameter layout, choice names, Params table and descriptor (hand-written; included by builtin_flagship.cpp, not compiled alone).
constexpr uint32_t kControlFrames = 16;
constexpr uint32_t kVoices = 64;  // a voice can be 48 oscillator copies: 64 is plenty; the oldest is stolen past it
constexpr uint32_t kOscs = 3, kFilters = 2, kEnvs = 3, kLfos = 4, kSlots = 16;
constexpr uint32_t kLayoutLfos = 3;  // the LFOs in the 1.0 layout; LFO 4's parameters are appended (1.1.0)
constexpr uint32_t kMacros = 8;      // 1.1.0: the instrument's macro knobs, mod sources
constexpr int kTableCount = 5;  // the built-in tables
constexpr int kUserTable = kTableCount;              // then "User": the imported one
constexpr int kAdditiveTable = kTableCount + 1;      // 1.1.0, appended: frames made by additive rules
constexpr int kTableChoices = kTableCount + 2;
// The user wavetable's state (see "The user wavetable" below).
constexpr uint32_t kWtMagic = 0x31545743u;        // "CWT1"
constexpr uint32_t kWtImportMagic = 0x49545743u;  // "CWTI"
constexpr uint32_t kUserFrameSize = 2048, kMaxUserFrames = 256, kWtHeader = 12, kWtImportHeader = 8;
constexpr uint32_t kMaxWtWavBytes = 8u << 20;  // the import's WAV (a project keeps the decoded form)
constexpr uint32_t kMaxWtStateBytes = kWtImportHeader + kMaxWtWavBytes;
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
constexpr uint32_t layoutLfoParam(uint32_t l, uint32_t p) { return kLfoBase + l * kLfoCount + p; }
constexpr uint32_t kRndRate = kLfoBase + kLayoutLfos * kLfoCount, kRndMode = kRndRate + 1;
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
// Added after the via sources (2026-11-11, #171 FM warp): each oscillator's FM ratio, the modulator's speed as a
// whole multiple of the note (the FM warp only). Appended for the same reason; not mod destinations.
constexpr uint32_t kFmRatioBase = kViaBase + kSlots;
constexpr uint32_t fmRatioParam(uint32_t o) { return kFmRatioBase + o; }
// Added after the FM ratios (2026-11-13, #197): each oscillator's fold mode (the fold warp only): Per copy folds
// each unison copy, Whole stack the stack's sum. Appended for the same reason (a project or preset saved without
// it loads Per copy, the default); not mod destinations.
constexpr uint32_t kFoldModeBase = kFmRatioBase + kOscs;
constexpr uint32_t foldModeParam(uint32_t o) { return kFoldModeBase + o; }
static_assert(kFoldModeBase + kOscs == 215, "the 1.0 parameter list's size is part of the documented layout");
// 1.1.0 (Kestrel's synthesis), appended after the 215 so every saved index keeps its meaning; none is a mod destination.
// Each oscillator's modulation source, for the warps that hear another oscillator (Osc FM, Osc RM, Osc AM, Osc sync):
// Prev (round the ring, as Osc FM always did: the default), Osc 1..3 (itself counts as Prev) or Noise.
constexpr uint32_t kModSrcBase = kFoldModeBase + kOscs;
constexpr uint32_t modSrcParam(uint32_t o) { return kModSrcBase + o; }
// LFO 4 (shape, rate, sync, mode, as the others), then the macros.
constexpr uint32_t kLfo4Base = kModSrcBase + kOscs;
constexpr uint32_t lfoParam(uint32_t l, uint32_t p) { return l < kLayoutLfos ? layoutLfoParam(l, p) : kLfo4Base + p; }
constexpr uint32_t kMacroBase = kLfo4Base + kLfoCount;
constexpr uint32_t macroParam(uint32_t m) { return kMacroBase + m; }
constexpr uint32_t kParamCount = kMacroBase + kMacros;

enum Source : int {
    kSrcNone, kSrcEnv1, kSrcEnv2, kSrcEnv3, kSrcLfo1, kSrcLfo2, kSrcLfo3, kSrcRandom, kSrcVelocity, kSrcNote,
    kSrcBend, kSrcPressure, kSrcTimbre, kSrcModWheel, kSrcAccent,
    kSrcLfo4, kSrcMacro1,  // 1.1.0, appended: LFO 4, then Macro 1..8
    kSourceCount = kSrcMacro1 + kMacros
};
constexpr int lfoSource(uint32_t l) { return l < kLayoutLfos ? kSrcLfo1 + static_cast<int>(l) : kSrcLfo4; }
enum FilterType : int {
    kLadderLp, kLadderHp, kLadderBp, kSvfLp, kSvfHp, kSvfBp, kSvfNotch, kComb, kFormant,
    kDiodeLp, kSallenKeyLp, kPhaser, kCombNeg, kVowel,  // 1.1.0, appended (flagship_filters.h)
    kFilterTypeCount
};
enum Warp : int {
    kWarpNone, kWarpBend, kWarpSync, kWarpMirror, kWarpQuantize, kWarpFm, kWarpFold, kWarpFmOsc,
    // 1.1.0, appended: another oscillator (or noise) multiplying this one (ring and amplitude modulation) or
    // restarting its phase (hard sync).
    kWarpOscRm, kWarpOscAm, kWarpOscSync,
    // 1.1.0, appended: spectral and additive warps, read from precomputed banks (flagship_banks.h), in its order.
    kWarpStretch, kWarpShift, kWarpOddEven, kWarpFormant, kWarpSmear, kWarpDisperse, kWarpCut, kWarpComb,
    kWarpCount
};
enum Dest : int { kToFilter1, kToFilter2, kToBoth, kToBypass };
// Osc FM's modulator: the oscillator before it, round the ring (osc 1 hears osc 3, 2 hears 1, 3 hears 2).
constexpr uint32_t fmSource(uint32_t o) { return (o + kOscs - 1) % kOscs; }
enum VoiceMode : int { kPoly, kMono, kLegato };

constexpr std::string_view kOffOn[] = {"Off", "On"};
constexpr std::string_view kTables[] = {"Basic", "Analog", "Vocal", "Harmonic", "Classic", "User", "Additive"};
static_assert(sizeof(kTables) / sizeof(kTables[0]) == kTableChoices);
constexpr std::string_view kWarps[] = {"None", "Bend", "Sync", "Mirror", "Quantize", "FM", "Fold", "Osc FM",
                                       "Osc RM", "Osc AM", "Osc sync", "Stretch", "Shift", "Odd/even", "Formant",
                                       "Smear", "Disperse", "Low/high cut", "Comb"};
static_assert(kWarpComb - kWarpStretch + 1 == flagship::kSpectralModes);
constexpr bool spectral(int w) { return w >= kWarpStretch; }
constexpr std::string_view kModSources[] = {"Prev", "Osc 1", "Osc 2", "Osc 3", "Noise"};
constexpr uint32_t kNoiseRow = kOscs;  // the voice's noise, after the oscillators' copies in Voice::fmBuf
// The warps that hear the source's mono copy (rendered for them into Voice::fmBuf).
constexpr bool hearsSource(int w) { return w == kWarpFmOsc || w == kWarpOscRm || w == kWarpOscAm; }
static_assert(sizeof(kWarps) / sizeof(kWarps[0]) == kWarpCount);
constexpr std::string_view kFoldModes[] = {"Per copy", "Whole stack"};
constexpr std::string_view kStacks[] = {"Off", "Octave", "2 octaves", "Fifth", "Major chord", "Minor chord", "Harmonics"};
constexpr std::string_view kDests[] = {"Filter 1", "Filter 2", "Both", "Bypass"};
constexpr std::string_view kFilterTypes[] = {"Ladder LP", "Ladder HP", "Ladder BP", "SVF LP", "SVF HP",
                                             "SVF BP",    "SVF notch", "Comb",     "Formant",
                                             "Diode LP",  "Sallen-Key", "Phaser", "Neg comb", "Vowel"};
static_assert(sizeof(kFilterTypes) / sizeof(kFilterTypes[0]) == kFilterTypeCount);
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
                                         "Accent",   "LFO 4",    "Macro 1", "Macro 2",    "Macro 3",  "Macro 4",
                                         "Macro 5",  "Macro 6",  "Macro 7", "Macro 8"};
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
            pick(p + "table", n + "table", 0.0, kTables, count(kTables)).legacyChoiceCount = kUserTable + 1;  // 1.0's list
            num(p + "frame", n + "frame", 1.0 / 3.0, 0.0, 1.0);  // the Basic table's saw
            num(p + "level", n + "level", 0.7, 0.0, 1.0);
            num(p + "pan", n + "pan", 0.0, -1.0, 1.0);
            whole(p + "octave", n + "octave", 0.0, -4.0, 4.0);
            whole(p + "semi", n + "semitones", 0.0, -12.0, 12.0, "st");
            num(p + "fine", n + "fine", 0.0, -100.0, 100.0, "ct");
            num(p + "phase", n + "phase", 0.0, 0.0, 1.0);
            num(p + "phase_rand", n + "phase randomness", 1.0, 0.0, 1.0);
            pick(p + "warp", n + "warp", 0.0, kWarps, count(kWarps)).legacyChoiceCount = kWarpFmOsc + 1;
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
            pick(p + "type", n + "type", f == 0 ? kLadderLp : kSvfLp, kFilterTypes, count(kFilterTypes)).legacyChoiceCount =
                kFormant + 1;
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
        for (uint32_t l = 0; l < kLayoutLfos; ++l) {
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
        for (uint32_t o = 0; o < kOscs; ++o)
            whole("osc" + std::to_string(o + 1) + "_fm_ratio", "Osc " + std::to_string(o + 1) + " FM ratio", 1.0, 1.0, 16.0);
        for (uint32_t o = 0; o < kOscs; ++o)
            pick("osc" + std::to_string(o + 1) + "_fold_mode", "Osc " + std::to_string(o + 1) + " fold mode", 0.0, kFoldModes,
                 count(kFoldModes));
        for (uint32_t o = 0; o < kOscs; ++o)
            pick("osc" + std::to_string(o + 1) + "_mod_src", "Osc " + std::to_string(o + 1) + " mod source", 0.0, kModSources,
                 count(kModSources));
        pick("lfo4_shape", "LFO 4 shape", 0.0, kLfoShapes, count(kLfoShapes));
        expo("lfo4_rate", "LFO 4 rate", 2.0, 0.01, 40.0, "Hz");
        pick("lfo4_sync", "LFO 4 sync", 0.0, kLfoSyncs, count(kLfoSyncs));
        pick("lfo4_mode", "LFO 4 mode", 0.0, kLfoModes, count(kLfoModes));
        for (uint32_t m = 0; m < kMacros; ++m)
            num("macro" + std::to_string(m + 1), "Macro " + std::to_string(m + 1), 0.0, 0.0, 1.0);
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
    ParameterDescriptor& pick(std::string id, std::string name, double def, const std::string_view* labels, uint32_t n) {
        ParameterDescriptor& p = add(std::move(id), std::move(name), def, 0.0, static_cast<double>(n - 1), {});
        p.step = 1.0;
        p.choices = labels;
        p.choiceCount = n;
        p.smoothingFrames = 0;  // a choice jumps
        return p;
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
        m.domains = kDomainWhole | kDomainPerNote;  // #127: it renders into a voice bus (VoiceLanes)
        m.capabilities = kCapabilityNotesIn | kCapabilityMidiIn;  // the mod wheel
        m.cpuClass = CpuClass::Heavy;
        m.maxStateBytes = kMaxWtStateBytes;  // the user wavetable (an import's WAV is the largest form)
        return m;
    }();
    return d;
}
