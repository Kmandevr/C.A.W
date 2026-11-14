// The benchmark's projects (builders moved from caw_bench.cpp), the suite's scenarios and their statistics.
#include "stress_scenarios.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <memory>

#include "audio_clips.h"
#include "builtin_flagship.h"
#include "caw/detmath.hpp"
#include "json.h"
#include "wav.h"

namespace caw::stress {

// ---------- The app's starter project ("First loop", AppState.starterProject) on the built-in C++ instruments ----------

std::string patternSource(const std::string& name, const std::string& length, const std::string& notes) {
    return "---\ncaw: 1\nkind: pattern\nname: " + name + "\nlength: " + length + "\n---\n" + notes;
}

// One track of First loop: a native instrument (with its values) playing a pattern, then native effects.
void addInstrumentLayer(ProjectSpec& p, const std::string& id, const std::string& instrument,
                        std::vector<std::pair<std::string, double>> params, const std::string& pattern, double volume,
                        std::vector<ComponentSpec> effects) {
    LayerSpec l;
    l.id = id;
    l.name = id;
    l.hasInstrument = true;
    l.instrument.id = instrument;
    l.instrument.params = std::move(params);
    l.components = std::move(effects);
    l.clips.push_back({id + "-clip", pattern, 0, p.loopSteps(), 0, true});
    l.volume = volume;
    p.layers.push_back(l);
}

ComponentSpec component(const std::string& id, std::vector<std::pair<std::string, double>> params) {
    ComponentSpec c;
    c.id = id;
    c.params = std::move(params);
    return c;
}

// First loop with every track playing (the app starts with Acid and Pad muted; here they are unmuted). `only`
// keeps one track (by id); empty keeps all.
ProjectSpec firstLoop(const std::string& only) {
    ProjectSpec p;
    p.name = "First loop";
    p.bpm = 120;
    p.loopBars = 4;
    std::string hats;
    for (int at = 0; at < 16; ++at) hats += std::to_string(at) + (at % 8 == 6 ? " A#2 1 1\n" : " F#2 1 1\n");
    p.modules = {
        {"kick", patternSource("Kick", "16", "0 C2 1 1\n4 C2 1 1\n8 C2 1 1\n12 C2 1 1\n")},
        {"hats", patternSource("Hats", "16", hats)},
        {"bass", patternSource("Bass line", "16",
                               "0 A1 1/2 1\n2 A1 1/2 1\n3 C2 1/2 1\n4 A2 1/2 1\n6 G1 1/2 1\n8 E2 1/2 1\n9 C2 1/2 1\n"
                               "11 G1 1/2 1\n12 A1 1/2 1\n15 A1 1/2 1\n")},
        {"lead", patternSource("Lead", "2 bars",
                               "0 E4 2 0.9\n2 A4 2 0.8\n4 C5 3 0.9\n8 B4 2 0.8\n10 A4 2 0.7\n12 G4 4 0.8\n"
                               "16 E4 2 0.9\n18 A4 2 0.8\n20 C5 2 0.9\n22 D5 1 0.8 slide\n23 E5 5 0.9\n28 D5 2 0.7\n"
                               "30 C5 2 0.6\n")},
        {"acid", patternSource("Acid line", "16",
                               "0 A1 2 1\n2 A2 1 0.7\n3 A1 1 0.8 slide\n4 C2 2 0.9\n6 A1 1 0.6 prob 0.5\n"
                               "8 E2 2 1 ratchet 2\n10 G1 1 0.7\n11 A1 1 0.8 slide\n12 A2 2 0.9\n14 G2 1 0.6\n"
                               "15 E2 1 0.8\n")},
        {"chords", patternSource("Chords", "4 bars",
                                 "0 A3,C4,E4 16 0.8\n16 F3,A3,C4 16 0.75\n32 C3,E3,G3 16 0.8\n48 G3,B3,D4 14 0.7\n"
                                 "62 G3,B3,D4 1/2 0.5 ratchet 2\n")},
    };
    addInstrumentLayer(p, "Kick", "org.caw.drum.kick", {}, "kick", 0.9);
    addInstrumentLayer(p, "Hats", "org.caw.drum.hats", {}, "hats", 0.55);
    addInstrumentLayer(p, "Bass", "org.caw.bass",
                       {{"cutoff", 270}, {"resonance", 0.45}, {"env", 0.6}, {"decay", 0.18}, {"sustain", 0.2}}, "bass", 0.75);
    addInstrumentLayer(p, "Lead", "org.caw.synth.morph",
                       {{"shape", 0.66}, {"drift", 0.15}, {"unison", 3}, {"detune", 0.1}, {"cutoff", 2600},
                        {"attack", 0.005}, {"decay", 0.25}, {"sustain", 0.5}, {"release", 0.3}},
                       "lead", 0.45, {component("org.caw.delay.pingpong", {{"sync", 3}, {"mix", 0.3}})});
    addInstrumentLayer(p, "Acid", "org.caw.synth.acid", {{"resonance", 0.8}}, "acid", 0.6,
                       {component("org.caw.distortion", {{"drive", 3}, {"mix", 0.5}})});
    addInstrumentLayer(p, "Pad", "org.caw.synth.morph", {}, "chords", 0.5, {component("org.caw.chorus")});
    if (!only.empty()) {
        std::vector<LayerSpec> keep;
        for (const LayerSpec& l : p.layers)
            if (l.id == only) keep.push_back(l);
        p.layers = keep;
    }
    return p;
}

// First loop's tracks repeated until there are n (ids made unique), all into the master.
ProjectSpec manyTracks(int n) {
    ProjectSpec p = firstLoop();
    const std::vector<LayerSpec> six = p.layers;
    p.layers.clear();
    for (int i = 0; i < n; ++i) {
        LayerSpec l = six[static_cast<size_t>(i) % six.size()];
        l.id += std::to_string(i);
        l.name = l.id;
        p.layers.push_back(l);
    }
    return p;
}

// First loop with a delay and a reverb after each track's own effects.
ProjectSpec withSpace() {
    ProjectSpec p = firstLoop();
    for (LayerSpec& l : p.layers)
        l.components.insert(l.components.end(), {component("org.caw.delay.pro"), component("org.caw.reverb.pro")});
    return p;
}

// One native instrument (and effects) under a busy pattern: 16th-note hits for drums, overlapping 4-note
// chords every beat (8 voices sounding) for the poly synths, a 16th line for the mono ones.
ProjectSpec busy(const std::string& instrument, std::vector<std::pair<std::string, double>> params,
                 std::vector<ComponentSpec> effects, bool notes_) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    std::string notes;
    if (instrument.find("drum") != std::string::npos) {
        for (int at = 0; at < 16; ++at) notes += std::to_string(at) + (at % 4 == 0 ? " C2,F#2" : at % 4 == 2 ? " D2,A#2" : " F#2") + " 1 1\n";
    } else if (instrument == "org.caw.bass" || instrument == "org.caw.synth.acid") {
        const char* keys[] = {"A1", "A2", "C2", "E2"};
        for (int at = 0; at < 16; ++at) notes += std::to_string(at) + " " + keys[at % 4] + " 1/2 1\n";
    } else {
        const char* chords[] = {"A3,C4,E4,G4", "F3,A3,C4,E4", "C3,E3,G3,B3", "G3,B3,D4,F4"};
        for (int at = 0; at < 4; ++at) notes += std::to_string(at * 4) + " " + chords[at] + " 4 0.8\n";
    }
    if (!notes_) notes.clear();  // the engine's own cost of a track
    p.modules = {{"busy", patternSource("Busy", "16", notes)}};
    addInstrumentLayer(p, "t", instrument, std::move(params), "busy", 0.6, std::move(effects));
    return p;
}

// ---------- A typical song (the owner's "project without crazy effects", 2026-11-11), built to measure ----------
// Eight tracks: a drum kit, Flagship bass, lead, pad, keys, pluck and stab (unison 3-7), percussion; each with two or
// three common effects; a reverb bus and a delay bus fed by sends; a master EQ, glue compressor and limiter; two
// LFOs on cutoffs; the bass ducked by the kit. `extras` adds per-note FX on the keys, an audio-clip track and a
// sampler track (the WAVs are written to `dir`).

ComponentSpec keyed(const std::string& id, std::vector<std::pair<std::string, double>> params, const std::string& from) {
    ComponentSpec c = component(id, std::move(params));
    c.hasKey = true;
    c.key.layer = from;
    return c;
}

void addSends(LayerSpec& l, double reverb, double delay) {
    if (reverb > 0) l.sends.push_back({"RevBus", reverb, false, false});
    if (delay > 0) l.sends.push_back({"DlyBus", delay, false, false});
}

namespace {
// Writes a float WAV of f(frame, channel) to path; false (and `error`) if it can't.
bool writeBenchWav(const std::string& path, int rate, int channels, int64_t frames,
                   const std::function<float(int64_t, int)>& f, std::string& error) {
    std::vector<float> x(static_cast<size_t>(frames * channels));
    for (int64_t i = 0; i < frames; ++i)
        for (int c = 0; c < channels; ++c) x[static_cast<size_t>(i * channels + c)] = f(i, c);
    WavSpec w;
    w.sampleRate = rate;
    w.channels = channels;
    w.float32 = true;
    return writeFile(path, encodeWav(w, x.data(), frames), error);
}
}  // namespace

ProjectSpec typicalSong(bool extras, const std::string& dir, std::string* error) {
    ProjectSpec p;
    p.name = extras ? "Typical song + extras" : "Typical song";
    p.bpm = 124;
    p.loopBars = 4;
    std::string drums, perc, bass, lead, pad, keys, pluck, stab;
    for (int at = 0; at < 64; ++at) {
        if (at % 4 == 0) drums += std::to_string(at) + " C2 1 1\n";
        if (at % 8 == 4) drums += std::to_string(at) + " D2 1 0.9\n";
        drums += std::to_string(at) + (at % 4 == 2 ? " A#2 1 0.7\n" : " F#2 1 0.6\n");
        if (at % 16 == 10 || at % 16 == 15) perc += std::to_string(at) + " D#2 1 0.8\n";
        const char* bk[] = {"A1", "A1", "C2", "G1"};
        if (at % 2 == 0) bass += std::to_string(at) + " " + bk[(at / 16) % 4] + " 1 0.9\n";
        const char* pl[] = {"A4", "C5", "E5", "G5", "E5", "C5"};
        pluck += std::to_string(at) + " " + pl[at % 6] + " 1/2 0.7\n";
        if (at % 8 == 3) stab += std::to_string(at) + " A4,C5,E5 1 0.8\n";
    }
    const char* chords[] = {"A3,C4,E4,G4", "F3,A3,C4,E4", "C3,E3,G3,B3", "G3,B3,D4,F4"};
    for (int b = 0; b < 4; ++b) {
        pad += std::to_string(b * 16) + " " + chords[b] + " 16 0.7\n";
        for (int k = 0; k < 4; ++k) keys += std::to_string(b * 16 + k * 4 + 2) + " " + chords[b] + " 2 0.6\n";
    }
    lead = "0 E5 2 0.9\n2 A5 2 0.8\n4 C6 3 0.9\n8 B5 2 0.8\n10 A5 2 0.7\n12 G5 4 0.8\n"
           "32 E5 2 0.9\n34 A5 2 0.8\n36 C6 2 0.9\n38 D6 1 0.8 slide\n39 E6 5 0.9\n44 D6 2 0.7\n46 C6 2 0.6\n";
    p.modules = {{"drums", patternSource("Drums", "4 bars", drums)}, {"perc", patternSource("Perc", "4 bars", perc)},
                 {"bass", patternSource("Bass", "4 bars", bass)},    {"lead", patternSource("Lead", "4 bars", lead)},
                 {"pad", patternSource("Pad", "4 bars", pad)},       {"keys", patternSource("Keys", "4 bars", keys)},
                 {"pluck", patternSource("Pluck", "4 bars", pluck)}, {"stab", patternSource("Stab", "4 bars", stab)}};
    using V = std::vector<std::pair<std::string, double>>;
    auto flagship = [](V v) { return v; };
    addInstrumentLayer(p, "Drums", "org.caw.drums", {}, "drums", 0.8,
                       {component("org.caw.eq", {{"b2_gain", 2}, {"b6_gain", 1.5}}), component("org.caw.compressor", {{"threshold", -14}, {"ratio", 3}})});
    addInstrumentLayer(p, "Bass", "org.caw.synth.flagship",
                       flagship({{"osc1_unison", 3}, {"osc1_detune", 12}, {"flt1_cutoff", 500}, {"flt1_resonance", 0.3},
                                 {"env1_sustain", 0.6}, {"env1_release", 0.1}, {"voice_mode", 1}}),
                       "bass", 0.7,
                       {component("org.caw.saturator", {{"drive", 4}}), keyed("org.caw.ducker", {}, "Drums"),
                        component("org.caw.eq", {{"b2_gain", 2}})});
    addInstrumentLayer(p, "Lead", "org.caw.synth.flagship", flagship({{"osc1_unison", 5}, {"flt1_cutoff", 3200}}), "lead", 0.45,
                       {component("org.caw.eq", {{"b5_gain", 2}}), component("org.caw.chorus"), component("org.caw.delay.pro", {{"mix", 0.15}})});
    addInstrumentLayer(p, "Pad", "org.caw.synth.flagship",
                       flagship({{"osc1_unison", 7}, {"flt1_type", 3}, {"env1_attack", 0.4}, {"env1_release", 1.2}}), "pad", 0.4,
                       {component("org.caw.ensemble"), component("org.caw.filter", {{"cutoff", 3000}}), component("org.caw.eq", {{"b3_gain", -2}})});
    addInstrumentLayer(p, "Keys", "org.caw.synth.flagship",
                       flagship({{"osc1_unison", 3}, {"osc1_table", 2}, {"env1_decay", 0.4}, {"env1_sustain", 0.3}}), "keys", 0.5,
                       {component("org.caw.phaser"), component("org.caw.compressor"), component("org.caw.reverb.pro", {{"mix", 0.15}})});
    addInstrumentLayer(p, "Pluck", "org.caw.synth.flagship",
                       flagship({{"osc1_unison", 4}, {"env1_decay", 0.2}, {"env1_sustain", 0}, {"flt1_cutoff", 1800}}), "pluck", 0.4,
                       {component("org.caw.delay.pro", {{"mode", 1}, {"mix", 0.25}}), component("org.caw.saturator", {{"mode", 1}, {"drive", 3}})});
    addInstrumentLayer(p, "Stab", "org.caw.synth.flagship", flagship({{"osc1_unison", 6}, {"env1_decay", 0.3}, {"env1_sustain", 0.2}}), "stab", 0.35,
                       {component("org.caw.flanger"), component("org.caw.imager", {{"high_width", 1.4}}), component("org.caw.eq", {{"b7_gain", 2}})});
    addInstrumentLayer(p, "Perc", "org.caw.drums", {}, "perc", 0.5,
                       {component("org.caw.transient", {{"attack", 0.4}}), component("org.caw.saturator", {{"drive", 3}})});
    for (LayerSpec& l : p.layers) {
        if (l.id == "Drums") addSends(l, 0.1, 0);
        if (l.id == "Lead") addSends(l, 0.3, 0.25);
        if (l.id == "Pad") addSends(l, 0.4, 0);
        if (l.id == "Keys") addSends(l, 0.2, 0.1);
        if (l.id == "Pluck") addSends(l, 0.25, 0.3);
        if (l.id == "Stab") addSends(l, 0.3, 0.2);
        if (l.id == "Perc") addSends(l, 0.2, 0);
    }
    LayerSpec rev;
    rev.id = rev.name = "RevBus";
    rev.folder = true;
    rev.volume = 0.8;
    rev.components = {component("org.caw.reverb.pro", {{"mix", 1}, {"decay", 3}}), component("org.caw.eq", {{"b2_gain", -3}})};
    LayerSpec dly = rev;
    dly.id = dly.name = "DlyBus";
    dly.components = {component("org.caw.delay.pro", {{"mix", 1}, {"mode", 1}}), component("org.caw.eq", {{"b7_gain", -3}})};
    p.layers.push_back(rev);
    p.layers.push_back(dly);
    p.masterComponents = {component("org.caw.eq", {{"b2_gain", 1}, {"b7_gain", 1}}),
                          component("org.caw.compressor", {{"threshold", -10}, {"ratio", 2}}), component("org.caw.limiter")};
    // Two LFOs on cutoffs: the pad's filter effect and the bass's Flagship filter.
    ModulatorSpec lfo1;
    lfo1.id = lfo1.name = "lfo1";
    lfo1.component = component("org.caw.mod.lfo", {{"rate", 0.25}});
    ModulatorSpec lfo2 = lfo1;
    lfo2.id = lfo2.name = "lfo2";
    lfo2.component = component("org.caw.mod.lfo", {{"rate", 2}, {"shape", 1}});
    p.modulators = {lfo1, lfo2};
    ModLinkSpec a;
    a.id = 1;
    a.source = "lfo1";
    a.target = {"component", "Pad", "cutoff", 1};
    a.amount = 0.3;
    a.bipolar = true;
    ModLinkSpec b = a;
    b.id = 2;
    b.source = "lfo2";
    b.target = {"instrument", "Bass", "flt1_cutoff", -1};
    b.amount = 0.2;
    p.modulation = {a, b};
    if (!extras) return p;
    // Per-note FX on the keys: a filter and a saturator per note, 8 slots.
    for (LayerSpec& l : p.layers)
        if (l.id == "Keys") {
            l.noteComponents = {component("org.caw.filter", {{"cutoff", 2000}}), component("org.caw.saturator", {{"oversample", 0}})};
            l.noteVoices = 8;
        }
    // An audio clip: a 2-bar drum-ish loop at 100 BPM stretched to the song (WSOLA), looped over 4 bars.
    std::string wavError;
    const std::string loop = dir + "/loop.wav";
    if (!writeBenchWav(loop, 44100, 2, 44100 * 48 / 10, [](int64_t i, int c) {
        const double t = static_cast<double>(i % 26460) / 44100.0;  // a hit every 0.6 s
        uint32_t x = static_cast<uint32_t>(i * 2654435761u + c * 40503u + 1u);
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        return static_cast<float>(0.5 * std::exp(-t * 30) * ((x >> 8) / 8388608.0 - 1.0) + 0.3 * std::sin(2 * 3.14159265 * 55 * t) * std::exp(-t * 8));
    }, wavError) && error && error->empty()) *error = wavError;
    auto track = std::make_shared<AudioTrackSpec>();
    AudioClipSpec clip;
    clip.id = "loop";
    clip.path = loop;
    clip.startSteps = 0;
    clip.lengthSteps = 64;
    clip.loop = true;
    clip.musical = true;
    clip.sourceBpm = 100;
    track->clips.push_back(clip);
    LayerSpec audio;
    audio.id = audio.name = "Loop";
    audio.hasInstrument = true;
    audio.instrument.id = kAudioTrackId;
    audio.instrument.audioTrack = track;
    audio.volume = 0.6;
    audio.components = {component("org.caw.eq", {{"b2_gain", -2}}), component("org.caw.compressor")};
    p.layers.push_back(audio);
    // A sampler: one looped zone over the keyboard, playing the pad's chords an octave up.
    const std::string tone = dir + "/tone.wav";
    if (!writeBenchWav(tone, 48000, 1, 96000, [](int64_t i, int) {
        const double t = static_cast<double>(i) / 48000.0;
        return static_cast<float>(0.4 * std::sin(2 * 3.14159265 * 220 * t) + 0.15 * std::sin(2 * 3.14159265 * 661 * t));
    }, wavError) && error && error->empty()) *error = wavError;
    // Forward slashes (as caw_bench had them, engine-a345), escaped for JSON all the same.
    const std::string zones = "{\"zones\":[{\"path\":\"" + jsonEscape(std::filesystem::path(tone).generic_string()) + "\",\"pitch_keycenter\":57,\"loop_mode\":\"loop_sustain\","
                              "\"loop_start\":2000,\"loop_end\":90000,\"loop_crossfade\":0.01}]}";
    std::string samp;
    for (int b = 0; b < 4; ++b)
        for (int k = 0; k < 2; ++k) samp += std::to_string(b * 16 + k * 8) + " " + chords[b] + " 6 0.7\n";
    p.modules.push_back({"samp", patternSource("Samp", "4 bars", samp)});
    addInstrumentLayer(p, "Sampler", "org.caw.sampler", {{"filter", 1}, {"cutoff", 4000}, {"release", 0.4}}, "samp", 0.4,
                       {component("org.caw.chorus"), component("org.caw.eq", {{"b6_gain", 2}})});
    p.layers.back().instrument.hasState = true;
    p.layers.back().instrument.state.assign(zones.begin(), zones.end());
    addSends(p.layers.back(), 0.2, 0);
    return p;
}

// The owner's 3-track project (2026-11-11 screenshot: 49% CPU on the S22+): 90 BPM, a drum kit (4 bars, eight pads),
// a Flagship bass (4 bars, the bass preset) and a Flagship "Track 3" (1 bar, the default patch: unison 7, ladder),
// with a few effects. Its instruments weren't visible; these are the likely ones.
ProjectSpec threeTracks() {
    ProjectSpec p;
    p.name = "Three tracks";
    p.bpm = 90;
    p.loopBars = 4;
    std::string drums, bass, t3;
    for (int at = 0; at < 64; ++at) {
        if (at % 8 == 0 || at % 16 == 10) drums += std::to_string(at) + " C2 1 1\n";      // kick
        if (at % 8 == 4) drums += std::to_string(at) + " D2 1 0.9\n";                    // snare
        if (at % 16 == 12) drums += std::to_string(at) + " D#2 1 0.7\n";                 // clap
        drums += std::to_string(at) + (at % 4 == 2 ? " A#2 1 0.6\n" : " F#2 1 0.5\n");   // hats
        if (at % 16 == 14) drums += std::to_string(at) + " G2 1 0.6\n";                  // tom
        if (at % 32 == 0) drums += std::to_string(at) + " C#3 1 0.6\n";                  // crash
        if (at % 4 == 3) drums += std::to_string(at) + " G#2 1 0.4\n";                   // pedal hat
        const char* bk[] = {"A1", "A1", "F1", "G1"};
        if (at % 4 != 3) bass += std::to_string(at) + " " + bk[(at / 16) % 4] + " 1 0.9\n";
    }
    t3 = "0 A3,C4,E4 3 0.8\n4 A3,C4,E4 2 0.7\n8 G3,C4,E4 3 0.8\n12 G3,B3,D4 4 0.7\n";
    p.modules = {{"drums", patternSource("Drums", "4 bars", drums)}, {"bass", patternSource("Bass", "4 bars", bass)},
                 {"t3", patternSource("Track 3", "16", t3)}};
    addInstrumentLayer(p, "Drums", "org.caw.drums", {}, "drums", 0.8,
                       {component("org.caw.compressor", {{"threshold", -14}}), component("org.caw.eq", {{"b2_gain", 2}})});
    addInstrumentLayer(p, "Bass", "org.caw.bass", {}, "bass", 0.7, {component("org.caw.saturator", {{"drive", 4}})});
    addInstrumentLayer(p, "Track 3", "org.caw.synth.flagship", {}, "t3", 0.5,
                       {component("org.caw.delay.pro", {{"mix", 0.2}}), component("org.caw.reverb.pro", {{"mix", 0.2}})});
    return p;
}


// A MIDI note's name in the pattern language (36: C2).
std::string noteName(int midi) {
    static const char* const names[] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
    return std::string(names[midi % 12]) + std::to_string(midi / 12 - 1);
}

// One Flagship patch at its heaviest: Init with all three oscillators at 16 copies (osc 1 through the fold warp at
// drive 3.8, the hybrid fold of #197: ADAA at the sample rate for most notes, 2x oversampled for the 64 voices'
// top three, G6 to A6), both filters on with drive (ladder, then SVF in series), every effect on and three LFO
// slots. `voices` notes are held for the whole run (64: Flagship's full polyphony).
ProjectSpec flagshipHeavy(int voices) {
    ProjectSpec p;
    p.name = "Flagship heavy";
    p.bpm = 120;
    p.loopBars = 64;  // 128 s: the notes never end or restart within a run
    std::string notes;
    for (int i = 0; i < voices; ++i) notes += "0 " + noteName(30 + i) + " 1024 0.8\n";
    p.modules = {{"held", patternSource("Held", "64 bars", notes)}};
    std::vector<std::pair<std::string, double>> v = {
        {"osc1_unison", 16}, {"osc1_warp", 6 /* Fold */}, {"osc1_warp_amt", 0.4},
        {"osc2_on", 1}, {"osc2_unison", 16}, {"osc2_table", 1}, {"osc2_frame", 0.5},
        {"osc3_on", 1}, {"osc3_unison", 16}, {"osc3_octave", -1}, {"osc3_dest", 2 /* both filters */},
        {"flt1_drive", 4}, {"flt1_resonance", 0.4}, {"flt2_on", 1}, {"flt2_drive", 3},
        {"fx_dist_on", 1}, {"fx_eq_on", 1}, {"fx_chorus_on", 1}, {"fx_delay_on", 1}, {"fx_reverb_on", 1},
        {"mod2_src", 4}, {"mod2_amt", 0.3}, {"mod3_src", 5}, {"mod3_amt", 0.2}, {"mod4_src", 1},
        {"env1_sustain", 1}, {"volume", 0.3}};
    // Slot destinations are a parameter's index + 1: filter 1's and filter 2's cutoffs, osc 2's frame.
    v.push_back({"mod2_dst", flagshipParameterIndex("flt1_cutoff") + 1.0});
    v.push_back({"mod3_dst", flagshipParameterIndex("flt2_cutoff") + 1.0});
    v.push_back({"mod4_dst", flagshipParameterIndex("osc2_frame") + 1.0});
    v.push_back({"mod4_amt", 0.2});
    addInstrumentLayer(p, "Flagship", "org.caw.synth.flagship", v, "held", 0.5);
    p.layers.back().clips.back().lengthSteps = p.loopSteps();
    return p;
}

// org.caw.drums' default kit with its kit-wide glue, drive, room and clipper on, all 16 pads of bank A (MIDI 36..51)
// in a busy 16th-note pattern with flams and rolls: 3-4 hits on every step, every pad at least twice a bar.
ProjectSpec drumsBusy() {
    ProjectSpec p;
    p.name = "Drums kit";
    p.bpm = 128;
    p.loopBars = 1;
    std::string notes;
    for (int at = 0; at < 16; ++at) {
        std::string hits = noteName(36 + at % 16);                        // each pad once, in turn
        hits += "," + noteName(36 + (at * 5 + 3) % 16);                   // and again, out of step
        hits += "," + noteName(at % 2 ? 42 : 44);                         // the hats every step
        if (at % 4 == 2) hits += "," + noteName(38);                         // the snare
        notes += std::to_string(at) + " " + hits + " 1 " + (at % 4 == 0 ? "1" : "0.7") + (at % 8 == 7 ? " ratchet 3" : "") + "\n";
    }
    p.modules = {{"kit", patternSource("Kit", "16", notes)}};
    addInstrumentLayer(p, "Drums", "org.caw.drums",
                       {{"glue", 0.6}, {"kit_drive_type", 2}, {"kit_drive", 3}, {"room", 0.3}, {"kit_clip", 1}, {"kit_clip_gain", 3},
                        {"kit_low", 2}, {"kit_high", 1}},
                       "kit", 0.8);
    return p;
}

// The typical song's eight instrument tracks repeated to `n` (ids made unique), with its buses, master and LFOs.
// `heavy` adds to every track an EQ, a compressor and a saturator, a reverb on every fourth and a delay on every
// third; puts the tracks in two group buses (EQ, compressor, saturator each) and sends each to a third bus (a short
// plate reverb with a chorus and EQ) as well.
ProjectSpec bigSong(int n, bool heavy) {
    const ProjectSpec base = typicalSong(false);
    std::vector<LayerSpec> tracks, buses;
    for (const LayerSpec& l : base.layers) (l.folder ? buses : tracks).push_back(l);
    ProjectSpec p = base;
    p.name = std::to_string(n) + " tracks" + (heavy ? ", heavy FX" : "");
    p.layers.clear();
    if (heavy) {
        for (const char* g : {"GroupA", "GroupB"}) {
            LayerSpec f;
            f.id = f.name = g;
            f.folder = true;
            f.components = {component("org.caw.eq", {{"b2_gain", 1.5}, {"b7_gain", 1}}),
                            component("org.caw.compressor", {{"threshold", -16}, {"ratio", 3}}),
                            component("org.caw.saturator", {{"drive", 2}})};
            p.layers.push_back(f);
        }
        LayerSpec plate = buses.front();
        plate.id = plate.name = "PlateBus";
        plate.components = {component("org.caw.reverb.pro", {{"mix", 1}, {"decay", 1.2}, {"size", 0.3}}),
                            component("org.caw.chorus"), component("org.caw.eq", {{"b2_gain", -4}})};
        buses.push_back(plate);
    }
    for (int i = 0; i < n; ++i) {
        LayerSpec l = tracks[static_cast<size_t>(i) % tracks.size()];
        if (i >= static_cast<int>(tracks.size())) l.id = l.name = l.id + " " + std::to_string(i + 1);
        if (heavy) {
            l.parentId = i % 2 ? "GroupA" : "GroupB";
            l.components.push_back(component("org.caw.eq", {{"b3_gain", -2}, {"b6_gain", 2}}));
            l.components.push_back(component("org.caw.compressor", {{"threshold", -18}, {"ratio", 4}}));
            l.components.push_back(component(i % 2 ? "org.caw.saturator" : "org.caw.distortion", {{"drive", 3}}));
            if (i % 4 == 0) l.components.push_back(component("org.caw.reverb.pro", {{"mix", 0.2}}));
            if (i % 3 == 0) l.components.push_back(component("org.caw.delay.pro", {{"mix", 0.2}}));
            l.sends.push_back({"PlateBus", 0.15, false, false});
            if (l.sends.size() < 2) l.sends.push_back({"RevBus", 0.1, false, false});
        }
        p.layers.push_back(l);
    }
    for (const LayerSpec& b : buses) p.layers.push_back(b);
    return p;
}

// A reverb and delay tail fading to silence: one bar (2 s) of chords on a Flagship pad (release 1.5 s) and a pluck,
// through a long reverb (8 s), a feedback delay and a filter, and sent to a reverb bus; then nothing for the rest
// of a 32 s loop. With `notes` false the same project plays no notes at all: the floor a sleeping project costs.
ProjectSpec tailSong(bool notes) {
    ProjectSpec p;
    p.name = notes ? "Tail" : "Tail, no notes";
    p.bpm = 120;
    p.loopBars = 16;
    const std::string pad = notes ? "0 A3,C4,E4,G4 8 0.8\n8 F3,A3,C4,E4 8 0.8\n" : "";
    std::string pluck;
    if (notes)
        for (int at = 0; at < 16; at += 2) pluck += std::to_string(at) + (at % 4 ? " E5" : " A5") + " 1/2 0.7\n";
    p.modules = {{"pad", patternSource("Pad", "16 bars", pad)}, {"pluck", patternSource("Pluck", "16 bars", pluck)}};
    addInstrumentLayer(p, "Pad", "org.caw.synth.flagship", {{"env1_release", 1.5}, {"flt1_type", 3}}, "pad", 0.5,
                       {component("org.caw.filter", {{"cutoff", 3000}}), component("org.caw.reverb.pro", {{"mix", 0.35}, {"decay", 8}})});
    addInstrumentLayer(p, "Pluck", "org.caw.synth.flagship",
                       {{"osc1_unison", 3}, {"env1_decay", 0.2}, {"env1_sustain", 0}, {"env1_release", 0.2}}, "pluck", 0.4,
                       {component("org.caw.delay.pro", {{"feedback", 0.6}, {"mix", 0.3}}), component("org.caw.eq", {{"b6_gain", 2}})});
    for (LayerSpec& l : p.layers) l.sends.push_back({"RevBus", 0.3, false, false});
    LayerSpec rev;
    rev.id = rev.name = "RevBus";
    rev.folder = true;
    rev.components = {component("org.caw.reverb.pro", {{"mix", 1}, {"decay", 6}})};
    p.layers.push_back(rev);
    p.masterComponents = {component("org.caw.compressor", {{"threshold", -10}}), component("org.caw.limiter")};
    return p;
}

SuiteStats stats(const std::vector<double>& us, size_t from, size_t to) {
    SuiteStats s;
    if (to <= from) return s;
    s.maxAt = static_cast<size_t>(std::max_element(us.begin() + static_cast<std::ptrdiff_t>(from), us.begin() + static_cast<std::ptrdiff_t>(to)) - us.begin());
    std::vector<double> x(us.begin() + static_cast<std::ptrdiff_t>(from), us.begin() + static_cast<std::ptrdiff_t>(to));
    for (double v : x) s.meanUs += v;
    s.meanUs /= static_cast<double>(x.size());
    std::sort(x.begin(), x.end());
    s.p99Us = x[std::min(x.size() - 1, x.size() * 99 / 100)];
    s.maxUs = x.back();
    s.callbacks = x.size();
    return s;
}

double median(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    const size_t n = v.size();
    return n == 0 ? 0.0 : n % 2 ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2]);
}


ProjectSpec flagshipVoices(int voices) {
    voices = std::clamp(voices, 1, 64);
    ProjectSpec p;
    p.name = "Flagship voices";
    p.bpm = 120;
    p.loopBars = 64;  // 128 s: the notes never end or restart within a run
    std::string notes;
    for (int i = 0; i < voices; ++i) notes += "0 " + noteName(36 + i) + " 1024 0.7\n";
    p.modules = {{"held", patternSource("Held", "64 bars", notes)}};
    addInstrumentLayer(p, "Flagship", "org.caw.synth.flagship", {{"env1_sustain", 1}, {"volume", 0.3}}, "held", 0.5);
    p.layers.back().clips.back().lengthSteps = p.loopSteps();
    return p;
}

ProjectSpec effectsChain(int effects) {
    effects = std::clamp(effects, 0, 128);
    // Common effects at settings a mix uses; each pass of the list adds one of each.
    const std::vector<ComponentSpec> pool = {
        component("org.caw.eq", {{"b2_gain", 2}, {"b6_gain", -1.5}}),
        component("org.caw.compressor", {{"threshold", -16}, {"ratio", 3}}),
        component("org.caw.saturator", {{"drive", 3}}),
        component("org.caw.chorus"),
        component("org.caw.delay.pro", {{"mix", 0.2}}),
        component("org.caw.filter", {{"cutoff", 4000}}),
        component("org.caw.phaser"),
        component("org.caw.reverb.pro", {{"mix", 0.2}}),
    };
    ProjectSpec p;
    p.name = "Effects on one track";
    p.bpm = 120;
    p.loopBars = 1;
    const char* chords[] = {"A3,C4,E4,G4", "F3,A3,C4,E4", "C3,E3,G3,B3", "G3,B3,D4,F4"};
    std::string notes;
    for (int at = 0; at < 4; ++at) notes += std::to_string(at * 4) + " " + chords[at] + " 4 0.8\n";
    p.modules = {{"busy", patternSource("Busy", "16", notes)}};
    std::vector<ComponentSpec> chain;
    for (int k = 0; k < effects; ++k) chain.push_back(pool[static_cast<size_t>(k) % pool.size()]);
    addInstrumentLayer(p, "t", "org.caw.synth.flagship", {}, "busy", 0.5, std::move(chain));
    return p;
}

// ---------- The feature scenarios (batch 1.0.2, #197): each feature from its best case to its worst ----------

namespace {

// A track whose instrument costs next to nothing (the engine's internal test signal, a free-running saw at
// `level`), so what is measured is the feature around it. An empty pattern clip makes it a playing track.
void addToneTrack(ProjectSpec& p, const std::string& id, const std::string& parent, double level = 0.1,
                  std::vector<ComponentSpec> effects = {}) {
    if (std::none_of(p.modules.begin(), p.modules.end(), [](const ModuleSpec& m) { return m.id == "none"; }))
        p.modules.push_back({"none", patternSource("None", "16", "")});
    addInstrumentLayer(p, id, "org.caw.test.osc", {{"shape", 1}, {"freq", 110 + 7.0 * static_cast<double>(p.layers.size())}, {"level", level}},
                       "none", 0.7, std::move(effects));
    p.layers.back().parentId = parent;
}

LayerSpec folderLayer(const std::string& id, const std::string& parent) {
    LayerSpec f;
    f.id = f.name = id;
    f.folder = true;
    f.parentId = parent;
    f.volume = 0.9;
    return f;
}

// Four chords a bar, each four notes held a beat (the busy() pattern).
std::string chordBar() {
    const char* chords[] = {"A3,C4,E4,G4", "F3,A3,C4,E4", "C3,E3,G3,B3", "G3,B3,D4,F4"};
    std::string notes;
    for (int at = 0; at < 4; ++at) notes += std::to_string(at * 4) + " " + chords[at] + " 4 0.8\n";
    return notes;
}

std::string wavPath(const std::string& dir, const std::string& name) {
    return std::filesystem::path(dir).generic_string() + "/" + name;
}

// A clip-ish loop: a decaying noise hit every `hit` seconds over a low sine, stereo.
float loopSample(int64_t i, int c, int rate, double hit) {
    const double t = std::fmod(static_cast<double>(i) / rate, hit);
    uint32_t x = static_cast<uint32_t>(i * 2654435761u + c * 40503u + 1u);
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return static_cast<float>(0.4 * std::exp(-t * 25) * ((x >> 8) / 8388608.0 - 1.0) +
                              0.25 * std::sin(2 * 3.14159265 * 65 * static_cast<double>(i) / rate));
}

// An audio-clip track of one WAV (written into dir), the clip `lengthSteps` long from `startSteps`, looped.
bool addClipTrack(ProjectSpec& p, const std::string& dir, const std::string& id, const std::string& file, int rate,
                  double seconds, double startSteps, double lengthSteps, bool musical, double pitch, std::string* error) {
    std::string wavError;
    const std::string path = wavPath(dir, file);
    const bool wrote = writeBenchWav(path, rate, 2, static_cast<int64_t>(seconds * rate),
                                     [rate](int64_t i, int c) { return loopSample(i, c, rate, 0.5); }, wavError);
    if (!wrote && error && error->empty()) *error = wavError;
    auto track = std::make_shared<AudioTrackSpec>();
    AudioClipSpec clip;
    clip.id = id + "-clip";
    clip.path = path;
    clip.startSteps = startSteps;
    clip.lengthSteps = lengthSteps;
    clip.loop = true;
    clip.musical = musical;
    clip.sourceBpm = musical ? 100 : 0;
    clip.pitch = pitch;
    clip.varispeed = pitch != 0;
    track->clips.push_back(clip);
    LayerSpec audio;
    audio.id = audio.name = id;
    audio.hasInstrument = true;
    audio.instrument.id = kAudioTrackId;
    audio.instrument.audioTrack = track;
    audio.volume = 0.5;
    p.layers.push_back(audio);
    return wrote;
}

// The sampler's one looped zone over the keyboard (tone.wav in dir) as its state.
void samplerState(ComponentSpec& c, const std::string& dir, std::string* error) {
    std::string wavError;
    const std::string tone = wavPath(dir, "sampler_tone.wav");
    if (!writeBenchWav(tone, 48000, 1, 96000, [](int64_t i, int) {
            const double t = static_cast<double>(i) / 48000.0;
            return static_cast<float>(0.4 * std::sin(2 * 3.14159265 * 220 * t) + 0.15 * std::sin(2 * 3.14159265 * 661 * t));
        }, wavError) && error && error->empty())
        *error = wavError;
    const std::string zones = "{\"zones\":[{\"path\":\"" + jsonEscape(tone) + "\",\"pitch_keycenter\":57,\"loop_mode\":\"loop_sustain\","
                              "\"loop_start\":2000,\"loop_end\":90000,\"loop_crossfade\":0.01}]}";
    c.hasState = true;
    c.state.assign(zones.begin(), zones.end());
}

// Every id in `from` prefixed (layers, parents, sends, keys, patterns, modulators, links, lanes), then added to `into`.
void mergeProject(ProjectSpec& into, ProjectSpec from, const std::string& prefix) {
    auto id = [&](const std::string& v) { return v.empty() ? v : prefix + v; };
    for (ModuleSpec& m : from.modules) into.modules.push_back({id(m.id), m.source});
    auto keyed = [&](std::vector<ComponentSpec>& cs) {
        for (ComponentSpec& c : cs)
            if (c.hasKey) c.key.layer = id(c.key.layer);
    };
    for (LayerSpec& l : from.layers) {
        l.id = id(l.id);
        l.name = l.id;
        l.parentId = id(l.parentId);
        l.pattern = id(l.pattern);
        for (ClipSpec& c : l.clips) c.id = id(c.id), c.pattern = id(c.pattern);
        for (SendSpec& sd : l.sends) sd.to = id(sd.to);
        keyed(l.components);
        into.layers.push_back(std::move(l));
    }
    for (ProjectAutomationLaneSpec& a : from.automation) {
        a.moduleId = id(a.moduleId);
        into.automation.push_back(std::move(a));
    }
    uint32_t nextLink = 1;
    for (const ModLinkSpec& k : into.modulation) nextLink = std::max(nextLink, k.id + 1);
    for (ModulatorSpec& m : from.modulators) {
        m.id = id(m.id);
        m.name = m.id;
        m.layer = id(m.layer);
        m.input = id(m.input);
        into.modulators.push_back(std::move(m));
    }
    for (ModLinkSpec& k : from.modulation) {
        k.id = nextLink++;
        k.source = id(k.source);
        if (k.target.type == "modulator" || !k.target.layer.empty()) k.target.layer = id(k.target.layer);
        into.modulation.push_back(std::move(k));
    }
}

}  // namespace

ProjectSpec emptyProject() {
    ProjectSpec p;
    p.name = "Empty";
    p.bpm = 120;
    p.loopBars = 1;
    return p;
}

ProjectSpec singleSynth() { return busy("org.caw.synth.flagship", {}); }

ProjectSpec singleSampler(const std::string& dir, std::string* error) {
    ProjectSpec p = busy("org.caw.sampler", {{"release", 0.3}});
    p.name = "One sampler";
    samplerState(p.layers.back().instrument, dir, error);
    return p;
}

ProjectSpec singleDrums() {
    ProjectSpec p = busy("org.caw.drums", {});
    p.name = "One drum kit";
    return p;
}

ProjectSpec singleAudio(const std::string& dir, std::string* error) {
    ProjectSpec p;
    p.name = "One audio clip";
    p.bpm = 120;
    p.loopBars = 4;
    addClipTrack(p, dir, "Audio", "single_audio.wav", 48000, 4.0, 0, 64, false, 0, error);
    return p;
}

ProjectSpec folders(int levels, int width) {
    ProjectSpec p;
    p.name = std::to_string(levels) + "-level folders";
    p.bpm = 120;
    p.loopBars = 1;
    for (int w = 0; w < width; ++w) {
        std::string parent;
        for (int k = 1; k <= levels; ++k) {
            const std::string f = "F" + std::to_string(w + 1) + "." + std::to_string(k);
            p.layers.push_back(folderLayer(f, parent));
            parent = f;
        }
        addToneTrack(p, "T" + std::to_string(w + 1), parent);  // at the bottom: every folder above it carries it
    }
    return p;
}

ProjectSpec sends(int tracks, int buses, bool chained) {
    ProjectSpec p;
    p.name = chained ? "Chained sends" : std::to_string(tracks * buses) + " sends";
    p.bpm = 120;
    p.loopBars = 1;
    for (int b = 0; b < buses; ++b) {
        LayerSpec bus = folderLayer("Bus" + std::to_string(b + 1), "");
        bus.volume = 0.3;
        // Chained: each bus sends on to the next, pre and post in turn.
        if (chained && b + 1 < buses) bus.sends.push_back({"Bus" + std::to_string(b + 2), 0.7, b % 2 == 0, false});
        p.layers.push_back(bus);
    }
    for (int t = 0; t < tracks; ++t) {
        addToneTrack(p, "Src" + std::to_string(t + 1), "");
        LayerSpec& l = p.layers.back();
        if (chained) {
            l.sends.push_back({"Bus1", 0.5, t % 2 == 0, false});
        } else {
            // Every bus twice, pre and post fader, up to the 8 sends a track has.
            for (int k = 0; k < 2 * buses && k < kMaxSends; ++k)
                l.sends.push_back({"Bus" + std::to_string(k % buses + 1), 0.2 + 0.05 * k, k >= buses, false});
        }
    }
    return p;
}

ProjectSpec automation(int tracks, int lanes, int points) {
    ProjectSpec p;
    p.name = std::to_string(tracks * lanes) + " automation lanes";
    p.bpm = 120;
    p.loopBars = 2;
    const int steps = p.loopSteps();
    // The component lanes' targets: the filter's cutoff and resonance, the EQ's two gains.
    const std::pair<int, const char*> params[] = {{0, "cutoff"}, {0, "resonance"}, {1, "b2_gain"}, {1, "b6_gain"}};
    const double lo[] = {300, 0.1, -6, -6}, hi[] = {6000, 0.6, 6, 6};
    for (int t = 0; t < tracks; ++t) {
        const std::string id = "Lane" + std::to_string(t + 1);
        addToneTrack(p, id, "", 0.1, {component("org.caw.filter", {{"cutoff", 2000}}), component("org.caw.eq")});
        LayerSpec& l = p.layers.back();
        const int n = std::max(2, points * p.loopBars);
        for (int lane = 0; lane < lanes; ++lane) {
            std::vector<AutomationPointSpec> pts;
            for (int k = 0; k < n; ++k) {
                // detSin: the same bits on every platform, so the project (and its pinned hash) is too.
                const double u = 0.5 + 0.5 * detSin(6.2831853 * (k + lane + t) / n * 3);
                pts.push_back({static_cast<double>(steps) * k / n, u});
            }
            if (lane < 2) {  // the fader's lanes: volume (a gain) and pan
                for (AutomationPointSpec& x : pts) x.value = lane == 0 ? 0.3 + 0.6 * x.value : 2 * x.value - 1;
                l.automation.push_back({lane == 0 ? "volume" : "pan", pts});
                continue;
            }
            const auto& [index, name] = params[(lane - 2) % 4];
            for (AutomationPointSpec& x : pts) x.value = lo[(lane - 2) % 4] + (hi[(lane - 2) % 4] - lo[(lane - 2) % 4]) * x.value;
            p.automation.push_back({"component", id, index, name, pts});
        }
    }
    return p;
}

ProjectSpec modulationDense(int tracks, int modulators) {
    ProjectSpec p;
    p.name = "Dense modulation";
    p.bpm = 120;
    p.loopBars = 1;
    for (int t = 0; t < tracks; ++t)
        addToneTrack(p, "Mod" + std::to_string(t + 1), "", 0.1, {component("org.caw.filter", {{"cutoff", 2000}}), component("org.caw.eq")});
    const char* kinds[] = {"org.caw.mod.lfo", "org.caw.mod.steps", "org.caw.mod.random"};
    uint32_t link = 1;
    for (int m = 0; m < modulators; ++m) {
        ModulatorSpec mod;
        mod.id = mod.name = "m" + std::to_string(m + 1);
        mod.component = component(kinds[m % 3], {{"rate", 0.5 + 0.75 * m}});
        p.modulators.push_back(mod);
        for (int t = 0; t < tracks; ++t) {
            const std::string layer = "Mod" + std::to_string(t + 1);
            ModLinkSpec cut;
            cut.id = link++;
            cut.source = mod.id;
            cut.target = {"component", layer, "cutoff", 0};
            cut.amount = 0.05;
            cut.bipolar = true;
            p.modulation.push_back(cut);
            ModLinkSpec vol = cut;
            vol.id = link++;
            vol.target = {"volume", layer, "", -1};
            vol.amount = 0.02;
            p.modulation.push_back(vol);
        }
    }
    return p;
}

ProjectSpec voiceStorm() {
    ProjectSpec p;
    p.name = "Voice storm";
    p.bpm = 140;
    p.loopBars = 1;
    // A 12-note chord on every 16th, each held two beats: 96 notes would sound, past Flagship's 64, so voices are
    // started, stolen and released on every step.
    std::string notes;
    for (int at = 0; at < 16; ++at) {
        std::string chord;
        for (int k = 0; k < 12; ++k) chord += (k ? "," : "") + noteName(40 + (at * 5 + k * 3) % 36);
        notes += std::to_string(at) + " " + chord + " 8 " + (at % 2 ? "0.6" : "0.9") + "\n";
    }
    p.modules = {{"storm", patternSource("Storm", "16", notes)}};
    addInstrumentLayer(p, "Storm", "org.caw.synth.flagship",
                       {{"osc1_unison", 2}, {"env1_attack", 0.002}, {"env1_release", 0.4}, {"volume", 0.2}}, "storm", 0.5);
    return p;
}

ProjectSpec sampleStream(const std::string& dir, int tracks, bool mixedRates, std::string* error) {
    ProjectSpec p;
    p.name = mixedRates ? "Mixed-rate audio" : "Long audio clips";
    p.bpm = 120;
    p.loopBars = 8;  // 16 s
    const int rates[] = {22050, 44100, 88200, 96000};
    for (int t = 0; t < tracks; ++t) {
        const int rate = mixedRates ? rates[t % 4] : 48000;
        const std::string id = (mixedRates ? "Rate" : "Stream") + std::to_string(t + 1);
        // Long clips (12 s, so the loop never repeats the start within a run), staggered; musical (stretched) on
        // every other one; mixed rates: fixed speed, resampled, the odd ones also re-pitched (varispeed).
        addClipTrack(p, dir, id, id + ".wav", rate, mixedRates ? 6.0 : 12.0, 2.0 * t, 128 - 2.0 * t,
                     !mixedRates && t % 2 == 1, mixedRates && t % 2 == 1 ? 3.0 : 0.0, error);
    }
    return p;
}

ProjectSpec everyInstrument(const std::string& dir, std::string* error) {
    ProjectSpec p;
    p.name = "Every instrument";
    p.bpm = 120;
    p.loopBars = 1;
    std::string drums;
    for (int at = 0; at < 16; ++at) drums += std::to_string(at) + (at % 4 == 0 ? " C2,F#2" : at % 4 == 2 ? " D2,A#2" : " F#2") + " 1 1\n";
    std::string line;
    const char* keys[] = {"A1", "A2", "C2", "E2"};
    for (int at = 0; at < 16; ++at) line += std::to_string(at) + " " + keys[at % 4] + " 1/2 1\n";
    p.modules = {{"chords", patternSource("Chords", "16", chordBar())}, {"drums", patternSource("Drums", "16", drums)},
                 {"line", patternSource("Line", "16", line)}};
    // The built-ins, then the retired synths' ids (Flagship patches now) and drum voices.
    addInstrumentLayer(p, "Flagship", "org.caw.synth.flagship", {}, "chords", 0.4);
    addInstrumentLayer(p, "Drums", "org.caw.drums", {}, "drums", 0.5);
    addInstrumentLayer(p, "Sampler", "org.caw.sampler", {{"release", 0.3}}, "chords", 0.4);
    samplerState(p.layers.back().instrument, dir, error);
    addInstrumentLayer(p, "Morph", "org.caw.synth.morph", {}, "chords", 0.3);
    addInstrumentLayer(p, "Basic", "org.caw.synth.basic", {}, "chords", 0.3);
    addInstrumentLayer(p, "Bass", "org.caw.bass", {}, "line", 0.4);
    addInstrumentLayer(p, "Acid", "org.caw.synth.acid", {}, "line", 0.3);
    addInstrumentLayer(p, "Kick", "org.caw.drum.kick", {}, "drums", 0.4);
    addInstrumentLayer(p, "Snare", "org.caw.drum.snare", {}, "drums", 0.3);
    addInstrumentLayer(p, "Hats", "org.caw.drum.hats", {}, "drums", 0.3);
    addClipTrack(p, dir, "Audio", "every_audio.wav", 44100, 4.0, 0, 16, false, 0, error);
    return p;
}

ProjectSpec everyEffect() {
    // Every built-in effect (as registered on 2026-11-13, keyed ones keyed by the first track), a dozen or so on
    // each of five Flagship chord tracks, in registration order.
    const char* const ids[] = {
        "org.caw.stereo.balance", "org.caw.stereo.width", "org.caw.distortion", "org.caw.delay.pingpong", "org.caw.chorus",
        "org.caw.autopan", "org.caw.bitcrush", "org.caw.channelmixer", "org.caw.clipper", "org.caw.comb",
        "org.caw.convolver", "org.caw.deesser", "org.caw.delay.pro", "org.caw.disperser", "org.caw.doubler",
        "org.caw.dynamics", "org.caw.ensemble", "org.caw.eq", "org.caw.eq.dj", "org.caw.filter", "org.caw.flanger",
        "org.caw.formant", "org.caw.freqshift", "org.caw.geq", "org.caw.haas", "org.caw.imager", "org.caw.ladder",
        "org.caw.limiter", "org.caw.multiband", "org.caw.nlfilter", "org.caw.phasedist", "org.caw.phaser",
        "org.caw.pitchshift", "org.caw.rack.multiband", "org.caw.resonator", "org.caw.reverb.pro", "org.caw.reverser",
        "org.caw.rotary", "org.caw.saturator", "org.caw.shimmer", "org.caw.stutter", "org.caw.tapestop", "org.caw.tilt",
        "org.caw.trancegate", "org.caw.transient", "org.caw.tremolo", "org.caw.utility", "org.caw.vibrato",
        "org.caw.compressor", "org.caw.ducker", "org.caw.gate", "org.caw.rack.fx", "org.caw.ringmod"};
    const char* const keyedIds[] = {"org.caw.compressor", "org.caw.ducker", "org.caw.gate", "org.caw.ringmod"};
    constexpr int kTracks = 5;
    ProjectSpec p;
    p.name = "Every effect";
    p.bpm = 120;
    p.loopBars = 1;
    p.modules = {{"chords", patternSource("Chords", "16", chordBar())}};
    std::vector<std::vector<ComponentSpec>> chains(kTracks);
    int k = 0;
    for (const char* id : ids) {
        const bool key = std::find_if(std::begin(keyedIds), std::end(keyedIds), [&](const char* x) { return std::string(x) == id; }) != std::end(keyedIds);
        const int t = k++ % kTracks;
        chains[static_cast<size_t>(t)].push_back(key && t != 0 ? keyed(id, {}, "FX1") : component(id));
    }
    for (int t = 0; t < kTracks; ++t)
        addInstrumentLayer(p, "FX" + std::to_string(t + 1), "org.caw.synth.flagship", {{"osc1_unison", 2}}, "chords", 0.3,
                           std::move(chains[static_cast<size_t>(t)]));
    return p;
}

ProjectSpec meteringHeavy() {
    ProjectSpec p;
    p.name = "Many meters";
    p.bpm = 120;
    p.loopBars = 1;
    for (int b = 0; b < 8; ++b) p.layers.push_back(folderLayer("Group" + std::to_string(b + 1), ""));
    for (int t = 0; t < 48; ++t) addToneTrack(p, "Meter" + std::to_string(t + 1), "Group" + std::to_string(t % 8 + 1), 0.05);
    return p;
}

ProjectSpec worstAll(const std::string& dir, std::string* error) {
    ProjectSpec p = bigSong(20, true);  // with the rest, about 230 components (at most 256 run)
    p.name = "Worst case, everything";
    mergeProject(p, folders(8, 2), "f.");
    mergeProject(p, sends(4, 8, false), "s.");
    mergeProject(p, automation(8, 6, 32), "a.");
    mergeProject(p, modulationDense(4, 8), "m.");
    mergeProject(p, voiceStorm(), "v.");
    mergeProject(p, sampleStream(dir, 4, true, error), "r.");
    for (LayerSpec& l : p.layers)
        for (ClipSpec& c : l.clips) c.lengthSteps = p.loopSteps();  // every pattern track plays the whole song
    return p;
}

bool makeScenario(const SuiteScenario& s, const std::string& dir, ProjectSpec& out, std::string& error) {
    if (!s.makeChecked) {
        out = s.make(dir);
        return true;
    }
    if (dir.empty()) {
        error = std::string(s.id) + " needs a work folder";
        return false;
    }
    error.clear();
    out = s.makeChecked(dir, &error);
    return error.empty();
}

const char* tierName(Tier t) {
    switch (t) {
        case Tier::Normal: return "normal";
        case Tier::Heavy: return "heavy";
        case Tier::Extreme: return "extreme";
        case Tier::Idle: return "idle";
    }
    return "normal";
}

std::vector<SuiteScenario> suiteScenarios() {
    // Tiers: docs/beta-readiness-plan.md C1. memoryMiB: the peak RSS growth of setting each up and playing 2 s on
    // Linux x64 (2026-11-13: 54, 34, 73, 82, 15, 15, 19, 132, 287 and 24 MiB in this order), with about a third more
    // on top; [Assumption] a phone's use is alike (docs/engine-performance.md).
    return {
        {"first_loop", "First loop (6 tracks)", [](const std::string&) { return firstLoop(); }, false, Tier::Normal, false, 64, "all"},
        {"three_tracks", "Three tracks", [](const std::string&) { return threeTracks(); }, false, Tier::Normal, false, 48, "all"},
        {"song8", "Typical song (8 tracks)", [](const std::string&) { return typicalSong(false); }, false, Tier::Normal, false, 96, "all"},
        {"song8_extras", "Typical song + extras", [](const std::string& d) { return typicalSong(true, d); }, false, Tier::Normal, false, 112, "all",
         [](const std::string& d, std::string* e) { return typicalSong(true, d, e); }},
        {"flagship_heavy", "Flagship heavy, 64 voices held", [](const std::string&) { return flagshipHeavy(64); }, false, Tier::Extreme, false, 32, "instrument"},
        {"flagship_heavy16", "Flagship heavy, 16 voices held", [](const std::string&) { return flagshipHeavy(16); }, false, Tier::Heavy, false, 32, "instrument"},
        {"drums_kit", "Drums kit, 16 pads busy", [](const std::string&) { return drumsBusy(); }, false, Tier::Heavy, false, 32, "instrument"},
        {"song16", "Song, 16 tracks", [](const std::string&) { return bigSong(16, false); }, false, Tier::Heavy, false, 176, "all"},
        {"song32_heavy", "Song, 32 tracks + heavy FX", [](const std::string&) { return bigSong(32, true); }, false, Tier::Extreme, false, 384, "all"},
        {"tail", "Tail", [](const std::string&) { return tailSong(true); }, true, Tier::Idle, true, 64, "baseline"},
        {"tail_floor", "Tail project, no notes", [](const std::string&) { return tailSong(false); }, false, Tier::Idle, false, 32, "baseline"},
    };
}

std::vector<SuiteScenario> featureScenarios() {
    // memoryMiB: as suiteScenarios' (peak RSS growth set up and playing 2 s on Linux x64, 2026-11-13, a third on
    // top). The WAV-writing ones need the work folder (makeChecked).
    using D = const std::string&;
    using E = std::string*;
    return {
        {"empty", "Empty project", [](D) { return emptyProject(); }, false, Tier::Idle, false, 8, "baseline"},
        {"single_synth", "One Flagship", [](D) { return singleSynth(); }, false, Tier::Normal, false, 24, "instrument"},
        {"single_sampler", "One sampler", [](D d) { return singleSampler(d, nullptr); }, false, Tier::Normal, false, 24, "instrument",
         [](D d, E e) { return singleSampler(d, e); }},
        {"single_drums", "One drum kit", [](D) { return singleDrums(); }, false, Tier::Normal, false, 32, "instrument"},
        {"single_audio", "One audio clip", [](D d) { return singleAudio(d, nullptr); }, false, Tier::Normal, false, 24, "audio",
         [](D d, E e) { return singleAudio(d, e); }},
        {"folders_shallow", "Folders, one level", [](D) { return folders(1, 4); }, false, Tier::Normal, false, 16, "routing"},
        {"folders_deep", "Folders, 8 levels deep", [](D) { return folders(8, 4); }, false, Tier::Heavy, false, 24, "routing"},
        {"sends_few", "4 sends", [](D) { return sends(1, 2, false); }, false, Tier::Normal, false, 16, "sends"},
        {"sends_many", "32 sends", [](D) { return sends(4, 4, false); }, false, Tier::Heavy, false, 24, "sends"},
        {"sends_chained", "Sends chained through 16 buses", [](D) { return sends(8, 16, true); }, false, Tier::Heavy, false, 24, "sends"},
        {"automation_light", "Light automation", [](D) { return automation(4, 2, 4); }, false, Tier::Normal, false, 24, "automation"},
        {"automation_dense", "Dense automation", [](D) { return automation(16, 6, 64); }, false, Tier::Heavy, false, 48, "automation"},
        {"modulation_dense", "Dense modulation", [](D) { return modulationDense(8, 16); }, false, Tier::Heavy, false, 32, "modulation"},
        {"voice_storm", "Voice storm (chords, stealing)", [](D) { return voiceStorm(); }, false, Tier::Extreme, false, 24, "voices"},
        {"sample_stream", "Long audio clips", [](D d) { return sampleStream(d, 8, false, nullptr); }, false, Tier::Heavy, false, 128, "samples",
         [](D d, E e) { return sampleStream(d, 8, false, e); }},
        {"resample", "Mixed-rate audio", [](D d) { return sampleStream(d, 8, true, nullptr); }, false, Tier::Heavy, false, 64, "samples",
         [](D d, E e) { return sampleStream(d, 8, true, e); }},
        {"every_instrument", "Every instrument", [](D d) { return everyInstrument(d, nullptr); }, false, Tier::Heavy, false, 96, "instrument",
         [](D d, E e) { return everyInstrument(d, e); }},
        {"every_effect", "Every effect", [](D) { return everyEffect(); }, false, Tier::Heavy, false, 160, "effect"},
        {"metering_heavy", "Many meters", [](D) { return meteringHeavy(); }, false, Tier::Normal, false, 32, "metering"},
        {"worst_all", "Worst case, everything", [](D d) { return worstAll(d, nullptr); }, false, Tier::Extreme, false, 512, "all",
         [](D d, E e) { return worstAll(d, e); }},
    };
}

std::vector<SuiteScenario> benchmarkScenarios() {
    std::vector<SuiteScenario> out;
    for (SuiteScenario& s : suiteScenarios())
        if (!s.benchOnly) out.push_back(std::move(s));
    for (SuiteScenario& s : featureScenarios()) out.push_back(std::move(s));
    return out;
}

const SuiteScenario* findScenario(const std::vector<SuiteScenario>& all, const std::string& id) {
    for (const SuiteScenario& s : all)
        if (id == s.id) return &s;
    return nullptr;
}

}  // namespace caw::stress
