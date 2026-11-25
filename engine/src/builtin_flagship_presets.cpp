// Flagship's 1.1.0 presets (Kestrel's synthesis): sync, ring and noise FM, spectral and additive warps, the new filters, LFO 4 and the macros.
#include <deque>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "builtin_flagship.h"
#include "presets.h"

// Original presets (C.A.W. is Apache-2.0), named for the job they do; no other synth's presets were used.

namespace caw {

namespace {

using Values = std::vector<std::pair<std::string_view, double>>;

// builtin_flagship.cpp's numbers.
enum : int { kBasic = 0, kAnalog = 1, kVocal = 2, kHarmonic = 3, kAdditive = 6 };  // tables
enum : int {
    kWarpFm = 5, kWarpFmOsc = 7, kWarpRm = 8, kWarpAm = 9, kWarpSync = 10, kStretch = 11, kOddEven = 13, kFormant = 14,
    kSmear = 15, kDisperse = 16, kComb = 18
};
enum : int { kSvfLp = 3, kDiode = 9, kSallenKey = 10, kPhaser = 11, kCombNeg = 12, kVowel = 13 };  // filters
enum : int { kSrcEnv2 = 2, kSrcEnv3 = 3, kSrcLfo1 = 4, kSrcVelocity = 8, kSrcModWheel = 13, kSrcAccent = 14, kSrcLfo4 = 15, kSrcMacro1 = 16 };
enum : int { kPrev = 0, kFromOsc1 = 1, kFromOsc2 = 2, kNoise = 4 };  // mod sources
constexpr double kSaw = 1.0 / 3.0;  // the Basic table's saw

double dst(std::string_view param) { return flagshipParameterIndex(param) + 1.0; }

// Every preset sets the oscillators, filters, slots 1-6 and effects it relies on, over Flagship's defaults.
Values base() {
    return {{"osc1_on", 1}, {"osc1_table", kBasic}, {"osc1_frame", kSaw}, {"osc1_unison", 1}, {"osc1_level", 0.7},
            {"osc1_phase_rand", 1}, {"osc2_on", 0}, {"osc3_on", 0}, {"flt1_on", 1}, {"flt1_type", 0}, {"flt1_cutoff", 4000},
            {"flt1_resonance", 0.15}, {"flt1_drive", 1}, {"flt2_on", 0}, {"mod1_src", 0}, {"mod1_amt", 0}, {"mod2_src", 0},
            {"mod3_src", 0}, {"mod4_src", 0}, {"mod5_src", 0}, {"mod6_src", 0}, {"fx_reverb_on", 0}, {"fx_chorus_on", 0},
            {"fx_delay_on", 0}, {"fx_dist_on", 0}, {"voice_mode", 0}, {"volume", 0.6}};
}
Values with(Values v, const Values& more) {
    for (const auto& m : more) {
        bool found = false;
        for (auto& x : v)
            if (x.first == m.first) x.second = m.second, found = true;
        if (!found) v.push_back(m);
    }
    return v;
}
// Slot n (1..6): source, destination, amount, bipolar.
Values slot(int n, int source, std::string_view target, double amount, bool bipolar = false) {
    static std::deque<std::string> ids;  // the ids live for the program (a deque never moves its elements)
    const auto id = [&](const char* suffix) -> std::string_view {
        ids.push_back("mod" + std::to_string(n) + suffix);
        return ids.back();
    };
    return {{id("_src"), static_cast<double>(source)}, {id("_dst"), dst(target)}, {id("_amt"), amount},
            {id("_bipolar"), bipolar ? 1.0 : 0.0}};
}
Values all(std::initializer_list<Values> parts) {
    Values v = base();
    for (const Values& p : parts) v = with(v, p);
    return v;
}

}  // namespace

void appendRavenPresets(std::vector<BuiltinPreset>& out) {
    const Values reverb = {{"fx_reverb_on", 1}, {"fx_reverb_mix", 0.25}, {"fx_reverb_decay", 3.0}};
    const Values chorus = {{"fx_chorus_on", 1}, {"fx_chorus_mix", 0.35}};
    const Values pad = {{"env1_attack", 0.6}, {"env1_decay", 1.5}, {"env1_sustain", 0.8}, {"env1_release", 1.8}};
    const Values pluck = {{"env1_attack", 0.002}, {"env1_decay", 0.6}, {"env1_sustain", 0.0}, {"env1_release", 0.5}};
    const Values mono = {{"voice_mode", 2}, {"glide", 0.06}};
    out.push_back({"Sync lead", "Osc 2 hard-synced to osc 1, the sync sweep riding envelope 2: the classic tearing lead",
                   all({{{"osc1_level", 0.35}, {"osc2_on", 1}, {"osc2_frame", kSaw}, {"osc2_unison", 3}, {"osc2_detune", 12},
                         {"osc2_semi", 7}, {"osc2_warp", kWarpSync}, {"osc2_warp_amt", 0.25}, {"osc2_mod_src", kFromOsc1},
                         {"flt1_cutoff", 5000}, {"env2_decay", 0.7}, {"env2_sustain", 0.2}, {"fx_delay_on", 1}, {"fx_delay_mix", 0.18}},
                        slot(1, kSrcEnv2, "osc2_warp_amt", 0.45)})});
    out.push_back({"Ring bell", "A sine ring-modulated by an inharmonic sine: a metallic bell that rings out",
                   all({{{"osc1_frame", 0}, {"osc1_warp", kWarpRm}, {"osc1_warp_amt", 1}, {"osc1_mod_src", kFromOsc2}, {"osc2_on", 1},
                         {"osc2_frame", 0}, {"osc2_level", 0}, {"osc2_octave", 1}, {"osc2_semi", 6}, {"osc2_fine", 31},
                         {"flt1_on", 0}, {"env1_attack", 0.001}, {"env1_decay", 2.5}, {"env1_sustain", 0}, {"env1_release", 2.0}},
                        reverb})});
    out.push_back({"AM sub bass", "A saw amplitude-modulated by a sine an octave down: a bass with a hollow, growling sub",
                   all({{{"osc1_warp", kWarpAm}, {"osc1_warp_amt", 0.8}, {"osc1_mod_src", kFromOsc2}, {"osc2_on", 1}, {"osc2_frame", 0},
                         {"osc2_octave", -1}, {"osc2_level", 0.4}, {"flt1_cutoff", 900}, {"flt1_resonance", 0.3}},
                        mono, {{"osc1_octave", -1}}})});
    out.push_back({"Noise breath pad", "A vocal wavetable phase-modulated by noise: a breathy, airy pad",
                   all({{{"osc1_table", kVocal}, {"osc1_frame", 0.3}, {"osc1_unison", 5}, {"osc1_detune", 18}, {"osc1_spread", 0.8},
                         {"osc1_warp", kWarpFmOsc}, {"osc1_warp_amt", 0.06}, {"osc1_mod_src", kNoise}, {"flt1_type", kSvfLp},
                         {"flt1_cutoff", 3500}},
                        pad, chorus, reverb, slot(1, kSrcLfo1, "osc1_frame", 0.3, true), {{"lfo1_rate", 0.15}}})});
    out.push_back({"FM wobble bass", "Osc 1 phase-modulated by osc 2 an octave up, LFO 4 wobbling the index in eighths",
                   all({{{"osc1_frame", 0}, {"osc1_octave", -1}, {"osc1_warp", kWarpFmOsc}, {"osc1_warp_amt", 0.4},
                         {"osc1_mod_src", kFromOsc2}, {"osc2_on", 1}, {"osc2_frame", 0}, {"osc2_level", 0}, {"osc2_octave", 0},
                         {"flt1_cutoff", 1500}, {"lfo4_shape", 0}, {"lfo4_sync", 3}, {"lfo4_mode", 1}},
                        mono, slot(1, kSrcLfo4, "osc1_warp_amt", 0.5, true)})});
    out.push_back({"Stretched bell", "A saw with its partials stretched apart: an inharmonic bell or glass mallet",
                   all({{{"osc1_warp", kStretch}, {"osc1_warp_amt", 0.55}, {"flt1_on", 0}, {"env1_attack", 0.001},
                         {"env1_decay", 1.8}, {"env1_sustain", 0}, {"env1_release", 1.5}},
                        reverb})});
    out.push_back({"Odd/even morph pad", "A wide saw stack sweeping slowly from full to hollow and back (LFO 4)",
                   all({{{"osc1_unison", 7}, {"osc1_detune", 20}, {"osc1_spread", 0.9}, {"osc1_warp", kOddEven}, {"osc1_warp_amt", 0.5},
                         {"flt1_type", kSvfLp}, {"flt1_cutoff", 5000}, {"lfo4_shape", 1}, {"lfo4_rate", 0.12}},
                        pad, reverb, slot(1, kSrcLfo4, "osc1_warp_amt", 0.4, true)})});
    out.push_back({"Formant vox lead", "A saw whose formants rise with the mod wheel: a singing, talking lead",
                   all({{{"osc1_unison", 3}, {"osc1_detune", 10}, {"osc1_warp", kFormant}, {"osc1_warp_amt", 0.2},
                         {"flt1_cutoff", 6000}, {"fx_delay_on", 1}, {"fx_delay_mix", 0.2}},
                        mono, slot(1, kSrcModWheel, "osc1_warp_amt", 0.7), slot(2, kSrcLfo1, "osc1_fine", 0.04, true),
                        {{"lfo1_rate", 5.5}}})});
    out.push_back({"Smeared air pad", "The harmonic wavetable with its spectrum smeared: a soft, shimmering wash",
                   all({{{"osc1_table", kHarmonic}, {"osc1_frame", 0.4}, {"osc1_unison", 9}, {"osc1_detune", 25},
                         {"osc1_spread", 1}, {"osc1_warp", kSmear}, {"osc1_warp_amt", 0.7}, {"flt1_type", kSvfLp},
                         {"flt1_cutoff", 7000}},
                        pad, chorus, reverb, slot(1, kSrcLfo1, "osc1_frame", 0.35, true), {{"lfo1_rate", 0.08}}})});
    out.push_back({"Disperse zap pluck", "A pluck whose partials disperse in time as it strikes: a laser-like zap",
                   all({{{"osc1_warp", kDisperse}, {"osc1_warp_amt", 0.1}, {"flt1_cutoff", 6000}, {"env2_attack", 0.001},
                         {"env2_decay", 0.12}, {"env2_sustain", 0}},
                        pluck, slot(1, kSrcEnv2, "osc1_warp_amt", 0.8)})});
    out.push_back({"Comb choir", "The additive table through a moving harmonic comb, chorused: an airy choir",
                   all({{{"osc1_table", kAdditive}, {"osc1_frame", 0.5}, {"osc1_unison", 5}, {"osc1_detune", 15},
                         {"osc1_spread", 0.7}, {"osc1_warp", kComb}, {"osc1_warp_amt", 0.4}, {"flt1_type", kSvfLp},
                         {"flt1_cutoff", 5000}, {"lfo4_shape", 0}, {"lfo4_rate", 0.2}},
                        pad, chorus, reverb, slot(1, kSrcLfo4, "osc1_warp_amt", 0.3, true)})});
    out.push_back({"Additive organ", "The additive table's drawbar frame: a clean organ with a slow chorus",
                   all({{{"osc1_table", kAdditive}, {"osc1_frame", 5.0 / 7.0}, {"osc1_phase_rand", 0}, {"flt1_on", 0},
                         {"env1_attack", 0.005}, {"env1_decay", 0.1}, {"env1_sustain", 1}, {"env1_release", 0.08}},
                        chorus})});
    out.push_back({"Diode acid", "A saw into the resonant diode low-pass, accents and slides: an acid line with bite",
                   all({{{"flt1_type", kDiode}, {"flt1_cutoff", 450}, {"flt1_resonance", 0.75}, {"flt1_drive", 2},
                         {"env2_decay", 0.25}, {"env2_sustain", 0}, {"env1_decay", 0.3}, {"env1_sustain", 0.6}},
                        mono, slot(1, kSrcEnv2, "flt1_cutoff", 0.35), slot(2, kSrcAccent, "flt1_cutoff", 0.2)})});
    out.push_back({"Sallen-Key scream", "A detuned saw pair into a driven Sallen-Key low-pass: a lead that screams",
                   all({{{"osc1_unison", 3}, {"osc1_detune", 14}, {"flt1_type", kSallenKey}, {"flt1_cutoff", 1600},
                         {"flt1_resonance", 0.85}, {"flt1_drive", 3}, {"fx_dist_on", 1}, {"fx_dist_drive", 1.5}},
                        mono, slot(1, kSrcVelocity, "flt1_cutoff", 0.15)})});
    out.push_back({"Phaser strings", "A wide analog string stack through an 8-stage phaser swept by LFO 4",
                   all({{{"osc1_table", kAnalog}, {"osc1_frame", 0.25}, {"osc1_unison", 7}, {"osc1_detune", 22},
                         {"osc1_spread", 1}, {"flt1_type", kSvfLp}, {"flt1_cutoff", 5000}, {"flt2_on", 1}, {"flt2_type", kPhaser},
                         {"flt2_cutoff", 900}, {"flt2_resonance", 0.5}, {"flt2_morph", 1}, {"lfo4_shape", 1}, {"lfo4_rate", 0.18}},
                        pad, reverb, slot(1, kSrcLfo4, "flt2_cutoff", 0.25, true)})});
    out.push_back({"Vowel talk bass", "A saw bass through the vowel filter, LFO 4 talking it from A to U in quarter notes",
                   all({{{"osc1_octave", -1}, {"osc2_on", 1}, {"osc2_frame", 0}, {"osc2_octave", -2}, {"osc2_level", 0.4},
                         {"flt1_type", kVowel}, {"flt1_cutoff", 1000}, {"flt1_resonance", 0.5}, {"flt1_morph", 0.5},
                         {"lfo4_shape", 1}, {"lfo4_sync", 4}, {"lfo4_mode", 1}},
                        mono, slot(1, kSrcLfo4, "flt1_morph", 0.5, true)})});
    out.push_back({"Hollow comb pluck", "A pluck through the negative comb: a hollow, clarinet-like ring an octave down",
                   all({{{"flt1_type", kCombNeg}, {"flt1_cutoff", 600}, {"flt1_resonance", 0.85}, {"flt1_morph", 0.3},
                         {"flt1_keytrack", 1}},
                        pluck, reverb})});
    out.push_back({"Macro sweep keys", "Macro 1 opens the filter and brightens the spectrum at once; Macro 2 adds the sync bite",
                   all({{{"osc1_unison", 3}, {"osc1_detune", 10}, {"osc1_warp", kStretch}, {"osc1_warp_amt", 0.01},
                         {"osc2_on", 1}, {"osc2_frame", kSaw}, {"osc2_semi", 12}, {"osc2_level", 0.35}, {"osc2_warp", kWarpSync},
                         {"osc2_warp_amt", 0.01}, {"osc2_mod_src", kFromOsc1}, {"flt1_type", kSvfLp}, {"flt1_cutoff", 800},
                         {"macro1", 0.3}, {"macro2", 0.0}, {"env1_decay", 0.8}, {"env1_sustain", 0.5}},
                        slot(1, kSrcMacro1, "flt1_cutoff", 0.5), slot(2, kSrcMacro1, "osc1_warp_amt", 0.4),
                        slot(3, kSrcMacro1 + 1, "osc2_warp_amt", 0.6), chorus})});
    // 1.1.3: the electric pianos and the tonewheel organ, Timber's keys as Kestrel presets (Timber's projects load as
    // these: timber_migrate.cpp). FM for the pianos: a sine phase-modulated at its own pitch, the index falling from
    // the strike (Env 2) and rising with velocity (the bark), and a short inharmonic partial for the tine's bell (Env
    // 3); LFO 1 pans it (Tine's stereo tremolo, depth 0 here) or moves its level (Reed's). The organ: three sines
    // at the 16', 8' and 5 1/3' drawbars' footages, no velocity, the chorus for the scanner and the slow rotary.
    const Values ep = {{"osc1_frame", 0}, {"osc1_warp", kWarpFm}, {"osc1_fm_ratio", 1}, {"osc1_phase_rand", 0},
                       {"osc2_on", 1}, {"osc2_frame", 0}, {"osc2_level", 0}, {"osc2_unison", 1}, {"osc2_phase_rand", 0},
                       {"flt1_on", 0}, {"env1_attack", 0.002}, {"env1_sustain", 0}, {"env1_release", 0.12},
                       {"env2_attack", 0.001}, {"env2_sustain", 0}, {"env3_attack", 0.001}, {"env3_sustain", 0},
                       {"velocity", 0.8}, {"lfo1_rate", 4.0}};
    out.push_back({"Electric piano (tine)", "A struck tine through its pickup: FM bark with velocity and a glassy bell, for soul and ballads",
                   all({ep,
                        {{"osc1_warp_amt", 0.1}, {"osc2_octave", 3}, {"osc2_semi", 10}, {"env1_decay", 3.0}, {"env2_decay", 0.5},
                         {"env3_decay", 0.2}},
                        slot(1, kSrcEnv2, "osc1_warp_amt", 0.25), slot(2, kSrcVelocity, "osc1_warp_amt", 0.2),
                        slot(3, kSrcEnv3, "osc2_level", 0.2), slot(4, kSrcLfo1, "osc1_pan", 0.0, true)})});
    out.push_back({"Electric piano (reed)", "A struck steel reed: a reedier, shorter FM tone that growls when played hard, for soul and rock",
                   all({ep,
                        {{"osc1_warp_amt", 0.22}, {"osc2_octave", 2}, {"osc2_semi", 0}, {"env1_decay", 2.0}, {"env2_decay", 0.3},
                         {"env3_decay", 0.08}, {"fx_dist_on", 1}, {"fx_dist_type", 0}, {"fx_dist_drive", 1.3}},
                        slot(1, kSrcEnv2, "osc1_warp_amt", 0.2), slot(2, kSrcVelocity, "osc1_warp_amt", 0.3),
                        slot(3, kSrcEnv3, "osc2_level", 0.12), slot(4, kSrcLfo1, "osc1_level", 0.0, true)})});
    out.push_back({"Tonewheel organ", "Sines at the 16', 8' and 5 1/3' drawbars (888), no velocity, a slow rotary-like chorus",
                   all({{{"osc1_frame", 0}, {"osc1_level", 0.45}, {"osc1_phase_rand", 0}, {"osc2_on", 1}, {"osc2_frame", 0},
                         {"osc2_octave", -1}, {"osc2_level", 0.45}, {"osc2_unison", 1}, {"osc2_phase_rand", 0}, {"osc3_on", 1},
                         {"osc3_frame", 0}, {"osc3_semi", 7}, {"osc3_level", 0.45}, {"osc3_unison", 1}, {"osc3_phase_rand", 0},
                         {"flt1_on", 0}, {"env1_attack", 0.004}, {"env1_decay", 0.1}, {"env1_sustain", 1}, {"env1_release", 0.02},
                         {"velocity", 0}, {"fx_chorus_on", 1}, {"fx_chorus_rate", 0.8}, {"fx_chorus_depth", 0.5},
                         {"fx_chorus_mix", 0.45}}})});
}

}  // namespace caw
