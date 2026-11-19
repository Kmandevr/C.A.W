// 1.1.0's job-named presets appended to the effects (and the sampler) that had fewer than 8: each list only grows, so saved preset names keep their meaning.
#include <span>
#include <string_view>
#include <vector>

#include "fx_merged.h"
#include "presets.h"

// Original values (C.A.W. is Apache-2.0). Each description starts with its purpose (Guitar, Vocals, Drums, Bass,
// Mixing, Mastering, Sound design, Lo-fi); each device's last new preset has a playful name (the sound plan's
// "hidden preset" at the end of the list, as Mimic's "Talking crow"). A merged device's name their `variant`
// (fx::mergedPresets appends them after its other presets; the Compressor's get talon_layout there).

namespace caw {

namespace {

using V = std::vector<std::pair<std::string_view, double>>;

// The trance gate's 16 steps from a string of digits: '0' off, '9' full, others in between.
V gateSteps(V v, std::string_view steps) {
    static constexpr std::string_view kStep[] = {"s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8",
                                                 "s9", "s10", "s11", "s12", "s13", "s14", "s15", "s16"};
    for (size_t i = 0; i < 16 && i < steps.size(); ++i) v.emplace_back(kStep[i], (steps[i] - '0') / 9.0);
    return v;
}

const std::vector<BuiltinPreset>& deesser() {
    static const std::vector<BuiltinPreset> p = {
        {"Podcast esses", "Vocals: a spoken voice's esses softened, slow enough to sound natural",
         {{"freq", 5500}, {"threshold", -32}, {"range", 8}, {"release", 80}}},
        {"Backing vocal hiss", "Vocals: stacked backing vocals' sibilance pulled down as one, wideband",
         {{"freq", 7000}, {"threshold", -36}, {"range", 12}, {"release", 60}, {"mode", 1}}},
        {"Guitar fret squeak", "Guitar: an acoustic's string squeaks and pick clicks tamed",
         {{"freq", 3200}, {"threshold", -34}, {"range", 8}, {"release", 50}}},
        {"Hush, little crow", "Mastering: a light de-ess of a whole mix's top, a few dB at most",
         {{"freq", 7500}, {"threshold", -28}, {"range", 4}, {"release", 100}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& multiband() {
    static const std::vector<BuiltinPreset> p = {
        {"Vocal control", "Vocals: body, presence and esses each held in their own band",
         {{"mode", 0}, {"depth", 1}, {"upward", 0}, {"xover_low", 250}, {"xover_high", 5000},
          {"b1_down_thr", -26}, {"b1_down_ratio", 3}, {"b2_down_thr", -22}, {"b2_down_ratio", 2},
          {"b3_down_thr", -28}, {"b3_down_ratio", 4}, {"b3_attack", 2}, {"b3_release", 60}}},
        {"Squawk box", "Sound design: OTT at full depth with very fast times: every tail and hiss shouts",
         {{"mode", 1}, {"depth", 1}, {"time", 0.1}, {"in_gain", 3}, {"out_gain", -4}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& reverser() {
    static const std::vector<BuiltinPreset> p = {
        {"Reverse vocal swell", "Vocals: half notes backwards under the dry, each word swelling in",
         {{"sync", 12}, {"crossfade", 40}, {"mix", 0.5}}},
        {"Backwards guitar", "Guitar: every beat flipped, the classic backwards solo",
         {{"sync", 9}, {"crossfade", 25}, {"mix", 1}}},
        {"Crow in reverse", "Sound design: sixteenth flips: a stuttering, backwards chatter",
         {{"sync", 3}, {"crossfade", 5}, {"mix", 0.7}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& stutter() {
    static const std::vector<BuiltinPreset> p = {
        {"Vocal chop", "Vocals: now and then a word repeats in gated sixteenths",
         {{"interval", 2}, {"offset", 8}, {"division", 3}, {"length", 2}, {"chance", 0.5}, {"decay", 0},
          {"pitch", 0}, {"gate", 0.7}, {"mix", 1}}},
        {"Snare roll build", "Drums: the second bar's last half rolls in thirty-seconds",
         {{"interval", 3}, {"offset", 8}, {"division", 1}, {"length", 3}, {"chance", 1}, {"decay", 0},
          {"pitch", 0}, {"gate", 0.8}, {"mix", 1}}},
        {"Woodpecker", "Sound design: tiny rising bursts tapping on the off-beats",
         {{"interval", 1}, {"offset", 4}, {"division", 0}, {"length", 0}, {"chance", 0.8}, {"decay", 0.1},
          {"pitch", 2}, {"gate", 0.5}, {"mix", 1}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& tapestop() {
    static const std::vector<BuiltinPreset> p = {
        {"Drum break stop", "Drums: the beat brakes over a half note and kicks back in on a sixteenth",
         {{"stop", 0}, {"stop_sync", 12}, {"start_sync", 3}, {"curve", 0.2}}},
        {"Battery dying", "Lo-fi: a six-second sag and a slow, struggling restart",
         {{"stop", 0}, {"stop_time", 6000}, {"stop_sync", 0}, {"start_time", 3000}, {"start_sync", 0}, {"curve", -0.6}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& trancegate() {
    static const std::vector<BuiltinPreset> p = {
        {"Vocal gate", "Vocals: a soft sixteenth chop on a held vocal, the dry under it",
         gateSteps({{"steps", 1}, {"rate", 2}, {"attack", 2}, {"decay", 250}, {"sustain", 0.8}, {"release", 50},
                    {"length", 0.6}, {"swing", 0}, {"legato", 0}, {"mix", 0.7}},
                   "9090990990909909")},
        {"Morse caw", "Sound design: sixteenths spelling C in Morse code, over and over",
         gateSteps({{"steps", 1}, {"rate", 2}, {"attack", 1}, {"decay", 120}, {"sustain", 1}, {"release", 15},
                    {"length", 0.9}, {"swing", 0}, {"legato", 1}, {"mix", 1}},
                   "9990909990900000")},
    };
    return p;
}

const std::vector<BuiltinPreset>& ringmod() {
    static const std::vector<BuiltinPreset> p = {
        {"Crow's radio", "Lo-fi: a square carrier half mixed in: a broken AM radio",
         {{"source", 2}, {"freq", 900}, {"spread", 0}, {"bias", 0.7}, {"rectify", 0}, {"mix", 0.5}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& comb() {
    static const std::vector<BuiltinPreset> p = {
        {"Snare ring", "Drums: a short ring at 180 Hz under the snare, like a loose head",
         {{"tune", 0}, {"freq", 180}, {"feedback", 0.75}, {"damping", 0.4}, {"mix", 0.4}}},
        {"Vocal robot tube", "Vocals: a tuned metal tube for a robotic voice",
         {{"tune", 1}, {"note", 50}, {"feedback", 0.8}, {"damping", 0.25}, {"mix", 0.6}}},
        {"Crow in a drainpipe", "Sound design: a low, hollow pipe that everything echoes down",
         {{"tune", 0}, {"freq", 95}, {"feedback", -0.9}, {"damping", 0.3}, {"mix", 0.8}, {"output", -3}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& disperser() {
    static const std::vector<BuiltinPreset> p = {
        {"Snare zap", "Drums: the snare's crack bent into a short zap around 900 Hz",
         {{"amount", 0.5}, {"freq", 900}, {"pinch", 0.6}, {"mix", 1}}},
        {"Guitar smear", "Guitar: a soft phase smear of the pick, wide and under the dry",
         {{"amount", 0.3}, {"freq", 2000}, {"pinch", 0.3}, {"spread", 0.3}, {"mix", 0.6}}},
        {"Pew pew", "Sound design: every stage, pinched high: each transient a laser shot",
         {{"amount", 1}, {"freq", 5000}, {"pinch", 0.9}, {"mix", 1}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& resonator() {
    static const std::vector<BuiltinPreset> p = {
        {"Kick tuner", "Drums: a short, dark string at C2 under a kick gives it a pitch",
         {{"mode", 0}, {"note", 36}, {"decay", 0.4}, {"brightness", 0.3}, {"spread", 0}, {"mix", 0.3}}},
        {"Murder of crows", "Sound design: a dark minor 7th chord rings out of drums and noise",
         {{"mode", 3}, {"chord", 4}, {"note", 50}, {"decay", 5}, {"brightness", 0.4}, {"spread", 0.7}, {"mix", 0.5}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& formant() {
    static const std::vector<BuiltinPreset> p = {
        {"Guitar talk wah", "Guitar: a narrow, vocal 'oh' between the vowels, some dry under it",
         {{"vowel_x", 0.3}, {"vowel_y", 0.6}, {"q", 12}, {"mix", 0.8}}},
        {"Caw", "Sound design: a narrow, high 'aw': the crow's own vowel",
         {{"vowel_x", 0.5}, {"vowel_y", 0.85}, {"shift", 5}, {"q", 16}, {"highs", 0.1}}},
    };
    return p;
}

// The sampler: playback, envelope and filter only (no sample paths: the zones are the user's).
const std::vector<BuiltinPreset>& sampler() {
    static const std::vector<BuiltinPreset> p = {
        {"One-shot drums", "Drums: no fade in, full velocity range, a short release for drum hits",
         {{"attack", 0}, {"decay", 0.3}, {"sustain", 1}, {"release", 0.3}, {"velocity", 0.8}, {"filter", 0}, {"polyphony", 16}}},
        {"Soft pad", "Sound design: a slow swell and long release through a gentle low-pass",
         {{"attack", 0.6}, {"decay", 1}, {"sustain", 0.8}, {"release", 1.5}, {"velocity", 0.4}, {"filter", 1},
          {"cutoff", 3000}, {"resonance", 0.8}, {"polyphony", 32}}},
        {"Plucky keys", "Mixing: a short decay and a filter that snaps shut, so any sample plucks",
         {{"attack", 0.002}, {"decay", 0.4}, {"sustain", 0.3}, {"release", 0.2}, {"filter", 1}, {"cutoff", 800},
          {"resonance", 1.2}, {"filter_env", 4}, {"filter_attack", 0.001}, {"filter_decay", 0.25},
          {"filter_sustain", 0}, {"filter_release", 0.2}}},
        {"Mono sample bass", "Bass: one voice, quick edges, a low-pass that follows the key",
         {{"attack", 0.002}, {"decay", 0.3}, {"sustain", 1}, {"release", 0.05}, {"filter", 1}, {"cutoff", 1200},
          {"resonance", 0.9}, {"filter_key", 0.5}, {"polyphony", 1}}},
        {"Vocal chops", "Vocals: chopped phrases with tight edges, the low rumble cut",
         {{"attack", 0.005}, {"decay", 0.2}, {"sustain", 0.7}, {"release", 0.05}, {"filter", 2}, {"cutoff", 150},
          {"resonance", 0.707}, {"polyphony", 4}}},
        {"Guitar strum", "Guitar: soft velocity, a natural ring-out and the harsh top rolled off",
         {{"attack", 0.003}, {"decay", 0.5}, {"sustain", 1}, {"release", 0.4}, {"velocity", 0.7}, {"filter", 1},
          {"cutoff", 6000}, {"resonance", 0.707}}},
        {"Dusty sampler", "Lo-fi: a little flat and dark, like an old 12-bit sampler's filter",
         {{"gain", -2}, {"tune", -15}, {"attack", 0.001}, {"release", 0.15}, {"filter", 1}, {"cutoff", 3500},
          {"resonance", 1}, {"filter_key", 0}}},
        {"Big bird", "Sound design: an octave down through a band-pass that blinks open: a giant's caw",
         {{"transpose", -12}, {"attack", 0.01}, {"decay", 0.5}, {"sustain", 0.7}, {"release", 0.8}, {"filter", 3},
          {"cutoff", 900}, {"resonance", 3}, {"filter_env", 2}, {"filter_attack", 0.001}, {"filter_decay", 0.5},
          {"filter_sustain", 0}, {"filter_release", 0.5}}},
    };
    return p;
}

}  // namespace

// The presets appended to a plain built-in's own list (presets.cpp's ownBuiltinPresets), or null.
const std::vector<BuiltinPreset>* appendedPresets(std::string_view id) {
    if (id == "org.caw.deesser") return &deesser();
    if (id == "org.caw.multiband") return &multiband();
    if (id == "org.caw.reverser") return &reverser();
    if (id == "org.caw.stutter") return &stutter();
    if (id == "org.caw.tapestop") return &tapestop();
    if (id == "org.caw.trancegate") return &trancegate();
    if (id == "org.caw.ringmod") return &ringmod();
    if (id == "org.caw.comb") return &comb();
    if (id == "org.caw.disperser") return &disperser();
    if (id == "org.caw.resonator") return &resonator();
    if (id == "org.caw.formant") return &formant();
    if (id == "org.caw.sampler") return &sampler();
    return nullptr;
}

// The ids appendedPresets answers for.
std::span<const std::string_view> appendedPresetIds() {
    static constexpr std::string_view ids[] = {"org.caw.deesser", "org.caw.multiband", "org.caw.reverser", "org.caw.stutter",
                                               "org.caw.tapestop", "org.caw.trancegate", "org.caw.ringmod", "org.caw.comb",
                                               "org.caw.disperser", "org.caw.resonator", "org.caw.formant", "org.caw.sampler"};
    return ids;
}

namespace fx {

namespace {

const std::vector<BuiltinPreset>& compressorDown() {
    static const std::vector<BuiltinPreset> p = {
        {"Vocal glue", "Vocals: 3:1 on the RMS level, a soft knee: the lead sits steady in the mix",
         {{"variant", 0}, {"threshold", -20}, {"ratio", 3}, {"knee", 6}, {"attack", 5}, {"release", 100}, {"auto_makeup", 1}, {"detect", 1}}},
        {"Vocal peak catcher", "Vocals: 6:1 with a fast attack, only the loud words touched",
         {{"variant", 0}, {"threshold", -14}, {"ratio", 6}, {"knee", 3}, {"attack", 1}, {"release", 60}, {"auto_makeup", 1}}},
        {"Kick punch", "Drums: 4:1 with a 20 ms attack: the beater passes, the boom is held",
         {{"variant", 0}, {"threshold", -16}, {"ratio", 4}, {"knee", 2}, {"attack", 20}, {"release", 80}, {"auto_makeup", 1}}},
        {"Parallel drum smash", "Drums: 10:1, fast and hard, mixed under the dry for weight",
         {{"variant", 0}, {"threshold", -30}, {"ratio", 10}, {"knee", 0}, {"attack", 1}, {"release", 60}, {"auto_makeup", 1}, {"mix", 0.4}}},
        {"Bass steady", "Bass: 4:1 on the RMS level, every note at one loudness",
         {{"variant", 0}, {"threshold", -22}, {"ratio", 4}, {"knee", 6}, {"attack", 10}, {"release", 150}, {"auto_makeup", 1}, {"detect", 1}}},
        {"Guitar sustainer", "Guitar: 5:1, slow release: a clean note holds up as it dies",
         {{"variant", 0}, {"threshold", -28}, {"ratio", 5}, {"knee", 6}, {"attack", 15}, {"release", 300}, {"auto_makeup", 1}}},
        {"Gentle master", "Mastering: 2:1 with a wide knee, auto release and look-ahead, the lows left out of the key",
         {{"variant", 0}, {"threshold", -12}, {"ratio", 2}, {"knee", 9}, {"attack", 30}, {"auto_release", 1}, {"auto_makeup", 1},
          {"lookahead", 2}, {"sc_hpf", 80}}},
        {"Crow's squeeze", "Lo-fi: crushed at 20:1, warm and breathing",
         {{"variant", 0}, {"threshold", -36}, {"ratio", 20}, {"knee", 0}, {"attack", 0.05}, {"release", 30}, {"auto_makeup", 1},
          {"character", 1}, {"mix", 0.8}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& limiter() {
    static const std::vector<BuiltinPreset> p = {
        {"Master ceiling", "Mastering: a transparent true-peak ceiling at -1 dB, no gain",
         {{"variant", 0}, {"gain", 0}, {"ceiling", -1}, {"release", 80}, {"lookahead", 1.5}, {"true_peak", 1}}},
        {"Streaming master", "Mastering: 4 dB louder under a -1 dB true peak, read against -14 LUFS",
         {{"variant", 0}, {"gain", 4}, {"ceiling", -1}, {"release", 100}, {"lookahead", 1.5}, {"true_peak", 1}, {"target_on", 1}, {"target", -14}}},
        {"Loud club master", "Mastering: 8 dB into a -0.3 dB ceiling, read against -9 LUFS",
         {{"variant", 0}, {"gain", 8}, {"ceiling", -0.3}, {"release", 40}, {"lookahead", 2}, {"true_peak", 1}, {"target_on", 1}, {"target", -9}}},
        {"Drum bus clamp", "Drums: fast and hard, the loudest hits flattened 3 dB down",
         {{"variant", 0}, {"gain", 6}, {"ceiling", -3}, {"release", 20}, {"lookahead", 0.5}, {"true_peak", 0}}},
        {"Vocal peak catcher", "Vocals: the odd shouted word stopped at -6 dB",
         {{"variant", 0}, {"gain", 2}, {"ceiling", -6}, {"release", 60}, {"lookahead", 1}, {"true_peak", 0}}},
        {"Bass peak control", "Bass: a long look-ahead and slow release, so low notes don't distort",
         {{"variant", 0}, {"gain", 3}, {"ceiling", -4}, {"release", 150}, {"lookahead", 4.9}, {"true_peak", 0}}},
        {"Mix safety", "Mixing: no gain, a slow release: only stray overs are caught",
         {{"variant", 0}, {"gain", 0}, {"ceiling", -0.5}, {"release", 200}, {"lookahead", 1.5}, {"true_peak", 1}}},
        {"Brick crow", "Lo-fi: 18 dB into a fast limiter: flat, crunchy and pumping",
         {{"variant", 0}, {"gain", 18}, {"ceiling", -6}, {"release", 5}, {"lookahead", 0.1}, {"true_peak", 0}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& transient() {
    static const std::vector<BuiltinPreset> p = {
        {"Kick snap", "Drums: more beater, a little less boom",
         {{"variant", 0}, {"attack", 0.6}, {"sustain", -0.2}}},
        {"Snare crack", "Drums: the stick's crack forward, the level kept",
         {{"variant", 0}, {"attack", 0.5}, {"sustain", 0}, {"output", -4}}},
        {"Room tightener", "Drums: the room and ring between hits pulled right down",
         {{"variant", 0}, {"attack", 0}, {"sustain", -0.7}}},
        {"Acoustic pick", "Guitar: the pick's attack a touch clearer on a strummed acoustic",
         {{"variant", 0}, {"attack", 0.4}, {"sustain", -0.1}}},
        {"Bass pluck", "Bass: a firmer pluck, shorter notes",
         {{"variant", 0}, {"attack", 0.5}, {"sustain", -0.3}}},
        {"Soft vocal edges", "Vocals: hard consonants rounded, the tail lifted a little",
         {{"variant", 0}, {"attack", -0.4}, {"sustain", 0.1}}},
        {"Mix punch", "Mixing: half a transient lift on a bus, mixed with the dry",
         {{"variant", 0}, {"attack", 0.3}, {"sustain", 0}, {"mix", 0.5}}},
        {"Beak attack", "Sound design: all attack and no tail: every hit becomes a click",
         {{"variant", 0}, {"attack", 0.6}, {"sustain", -1}, {"output", -6}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& phaser() {
    static const std::vector<BuiltinPreset> p = {
        {"Guitar swirl", "Guitar: four stages at half a hertz, the classic pedal",
         {{"variant", 0}, {"stages", 1}, {"rate", 0.5}, {"sync", 0}, {"depth", 0.7}, {"center", 800}, {"feedback", 0.5}, {"stereo", 0.5}, {"mix", 0.5}}},
        {"Vintage guitar phase", "Guitar: no feedback, a gentle seventies sweep on clean chords",
         {{"variant", 0}, {"stages", 1}, {"rate", 0.8}, {"sync", 0}, {"depth", 0.6}, {"center", 600}, {"feedback", 0}, {"stereo", 0.3}, {"mix", 0.5}}},
        {"Vocal shimmer", "Vocals: two light stages up high, wide: movement without a sweep",
         {{"variant", 0}, {"stages", 0}, {"rate", 0.3}, {"sync", 0}, {"depth", 0.4}, {"center", 2000}, {"feedback", 0.2}, {"stereo", 0.8}, {"mix", 0.3}}},
        {"Drum loop jet", "Drums: ten stages a bar long with heavy feedback: a jet over the loop",
         {{"variant", 0}, {"stages", 4}, {"sync", 5}, {"depth", 1}, {"center", 1500}, {"feedback", 0.8}, {"stereo", 0.5}, {"mix", 0.5}}},
        {"Bass phase", "Bass: a slow, mono, low sweep that keeps the bottom steady",
         {{"variant", 0}, {"stages", 1}, {"rate", 0.2}, {"sync", 0}, {"depth", 0.5}, {"center", 300}, {"feedback", 0.3}, {"stereo", 0}, {"mix", 0.4}}},
        {"Slow pad sweep", "Sound design: eight stages over four bars, for pads and drones",
         {{"variant", 0}, {"stages", 3}, {"sync", 7}, {"depth", 0.9}, {"center", 1000}, {"feedback", 0.6}, {"stereo", 0.7}, {"mix", 0.5}}},
        {"Lo-fi wobble", "Lo-fi: a fast, shallow, negative-feedback warble",
         {{"variant", 0}, {"stages", 2}, {"rate", 4}, {"sync", 0}, {"depth", 0.5}, {"center", 1200}, {"feedback", -0.5}, {"stereo", 0.4}, {"mix", 0.5}}},
        {"Crow flyby", "Sound design: twelve stages at high feedback: a jet that circles your head",
         {{"variant", 0}, {"stages", 5}, {"rate", 0.1}, {"sync", 0}, {"depth", 1}, {"center", 3000}, {"feedback", 0.9}, {"stereo", 1}, {"mix", 0.6}}},
    };
    return p;
}

}  // namespace

std::span<const BuiltinPreset> appendedVariantPresets(std::string_view id) {
    if (id == "org.caw.compressor") return compressorDown();
    if (id == "org.caw.limiter") return limiter();
    if (id == "org.caw.transient") return transient();
    if (id == "org.caw.phaser") return phaser();
    return {};
}

}  // namespace fx

}  // namespace caw
