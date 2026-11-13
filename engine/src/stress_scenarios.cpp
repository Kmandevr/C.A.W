// The benchmark's projects (builders moved from caw_bench.cpp), the suite's scenarios and their statistics.
#include "stress_scenarios.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>

#include "audio_clips.h"
#include "builtin_flagship.h"
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
    // The path escaped for JSON (a Windows folder has backslashes).
    const std::string zones = "{\"zones\":[{\"path\":\"" + jsonEscape(tone) + "\",\"pitch_keycenter\":57,\"loop_mode\":\"loop_sustain\","
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

// One Flagship patch at its heaviest: Init with all three oscillators at 16 copies (osc 1 through the fold warp,
// Flagship's 2x oversampled path), both filters on with drive (ladder, then SVF in series), every effect on and
// three LFO slots. `voices` notes are held for the whole run (64: Flagship's full polyphony).
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
    // Tiers: docs/beta-readiness-plan.md C1. memoryMiB: what each measured on Linux x64 (peak RSS growth while set
    // up and played, 2026-11-12) rounded up generously; see docs/engine-performance.md.
    return {
        {"first_loop", "First loop (6 tracks)", [](const std::string&) { return firstLoop(); }, false, Tier::Normal, false, 32},
        {"three_tracks", "Three tracks", [](const std::string&) { return threeTracks(); }, false, Tier::Normal, false, 32},
        {"song8", "Typical song (8 tracks)", [](const std::string&) { return typicalSong(false); }, false, Tier::Normal, false, 64},
        {"song8_extras", "Typical song + extras", [](const std::string& d) { return typicalSong(true, d); }, false, Tier::Normal, false, 96},
        {"flagship_heavy", "Flagship heavy, 64 voices held", [](const std::string&) { return flagshipHeavy(64); }, false, Tier::Extreme, false, 64},
        {"flagship_heavy16", "Flagship heavy, 16 voices held", [](const std::string&) { return flagshipHeavy(16); }, false, Tier::Heavy, false, 32},
        {"drums_kit", "Drums kit, 16 pads busy", [](const std::string&) { return drumsBusy(); }, false, Tier::Heavy, false, 32},
        {"song16", "Song, 16 tracks", [](const std::string&) { return bigSong(16, false); }, false, Tier::Heavy, false, 128},
        {"song32_heavy", "Song, 32 tracks + heavy FX", [](const std::string&) { return bigSong(32, true); }, false, Tier::Extreme, false, 256},
        {"tail", "Tail", [](const std::string&) { return tailSong(true); }, true, Tier::Idle, true, 64},
        {"tail_floor", "Tail project, no notes", [](const std::string&) { return tailSong(false); }, false, Tier::Idle, false, 64},
    };
}

std::vector<SuiteScenario> benchmarkScenarios() {
    std::vector<SuiteScenario> out;
    for (SuiteScenario& s : suiteScenarios())
        if (!s.benchOnly) out.push_back(std::move(s));
    return out;
}

const SuiteScenario* findScenario(const std::vector<SuiteScenario>& all, const std::string& id) {
    for (const SuiteScenario& s : all)
        if (id == s.id) return &s;
    return nullptr;
}

}  // namespace caw::stress
