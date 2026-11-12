// Measures the engine like a phone's audio callback does: time per callback, real-time load, compile and memory.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "audio_clips.h"
#include "builtin_flagship.h"
#include "caw/instrument.hpp"
#include "component_chain.h"
#include "engine.h"
#include "graph.h"
#include "mix_pool.h"
#include "project.h"
#include "render.h"
#include "wav.h"

using namespace caw;
using Clock = std::chrono::steady_clock;

namespace {

constexpr int kRate = 48000;
constexpr int kCallback = 192;  // a common Android burst (AAudio low latency); the budget is 4 ms at 48 kHz

long rssKb() {
    std::ifstream f("/proc/self/status");
    std::string line;
    while (std::getline(f, line))
        if (line.rfind("VmRSS:", 0) == 0) return std::atol(line.c_str() + 6);
    return -1;
}

// ---------- The app's starter project ("First loop", AppState.starterProject) on the built-in C++ instruments ----------

std::string patternSource(const std::string& name, const std::string& length, const std::string& notes) {
    return "---\ncaw: 1\nkind: pattern\nname: " + name + "\nlength: " + length + "\n---\n" + notes;
}

// One track of First loop: a native instrument (with its values) playing a pattern, then native effects.
void addInstrumentLayer(ProjectSpec& p, const std::string& id, const std::string& instrument,
                        std::vector<std::pair<std::string, double>> params, const std::string& pattern, double volume,
                        std::vector<ComponentSpec> effects = {}) {
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

ComponentSpec component(const std::string& id, std::vector<std::pair<std::string, double>> params = {}) {
    ComponentSpec c;
    c.id = id;
    c.params = std::move(params);
    return c;
}

// First loop with every track playing (the app starts with Acid and Pad muted; here they are unmuted). `only`
// keeps one track (by id); empty keeps all.
ProjectSpec firstLoop(const std::string& only = "") {
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
                 std::vector<ComponentSpec> effects = {}, bool notes_ = true) {
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

std::string writeBenchWav(const std::string& path, int rate, int channels, int64_t frames,
                          const std::function<float(int64_t, int)>& f) {
    std::vector<float> x(static_cast<size_t>(frames * channels));
    for (int64_t i = 0; i < frames; ++i)
        for (int c = 0; c < channels; ++c) x[static_cast<size_t>(i * channels + c)] = f(i, c);
    WavSpec w;
    w.sampleRate = rate;
    w.channels = channels;
    w.float32 = true;
    std::string error;
    if (!writeFile(path, encodeWav(w, x.data(), frames), error)) { std::fprintf(stderr, "%s\n", error.c_str()); std::exit(3); }
    return path;
}

ProjectSpec typicalSong(bool extras, const std::string& dir = "") {
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
    const std::string loop = writeBenchWav(dir + "/loop.wav", 44100, 2, 44100 * 48 / 10, [](int64_t i, int c) {
        const double t = static_cast<double>(i % 26460) / 44100.0;  // a hit every 0.6 s
        uint32_t x = static_cast<uint32_t>(i * 2654435761u + c * 40503u + 1u);
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        return static_cast<float>(0.5 * std::exp(-t * 30) * ((x >> 8) / 8388608.0 - 1.0) + 0.3 * std::sin(2 * 3.14159265 * 55 * t) * std::exp(-t * 8));
    });
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
    const std::string tone = writeBenchWav(dir + "/tone.wav", 48000, 1, 96000, [](int64_t i, int) {
        const double t = static_cast<double>(i) / 48000.0;
        return static_cast<float>(0.4 * std::sin(2 * 3.14159265 * 220 * t) + 0.15 * std::sin(2 * 3.14159265 * 661 * t));
    });
    const std::string zones = "{\"zones\":[{\"path\":\"" + tone + "\",\"pitch_keycenter\":57,\"loop_mode\":\"loop_sustain\","
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

// The song scenarios (`caw_bench SECONDS 400 K`: K 0 First loop, 1 the typical song, 2 with per-note FX, an audio
// clip and a sampler) and the profile mode (`caw_bench SECONDS 401 K`): the time each component takes per
// kProfileCallback-frame callback, over the whole run, and the host's own share (everything else Engine::process
// does: notes, the mix graph, sends, buses, meters, the safety limiter).
constexpr int kProfileCallback = 256;

// The compiler that built this bench, for the JSON report (MSVC has no __VERSION__).
std::string compilerName() {
#if defined(__VERSION__)
    return __VERSION__;
#elif defined(_MSC_FULL_VER)
    return "MSVC " + std::to_string(_MSC_FULL_VER);
#else
    return "unknown";
#endif
}

const char* scenarioName(int k) {
    return k == 0 ? "first loop" : k == 1 ? "typical song" : k == 2 ? "typical song + extras" : "three tracks";
}

ProjectSpec songScenario(int k, const std::string& dir) {
    if (k == 0) return firstLoop();
    if (k == 3) return threeTracks();
    return typicalSong(k == 2, dir);
}

struct Result {
    double meanUs = 0, p99Us = 0, maxUs = 0, load = 0;
};

// The flagship synth's cost per held voice and per unison copy (`caw_bench SECONDS 200`): 8 notes held for
// `seconds` straight through the instrument (no engine around it) in kCallback-frame blocks, the best of 3 runs
// per setting; the differences between settings give each part's share.
double heldNotes(const std::vector<std::pair<std::string, double>>& values, int count, double seconds) {
    Engine e(kRate);
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent("org.caw.synth.flagship");
    if (!p || !p->activate(kRate, kCallback)) return 0.0;
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    std::vector<float> l(kCallback), r(kCallback);
    float* channels[2] = {l.data(), r.data()};
    const ChannelBufferView audio{channels, 2, kCallback};
    std::vector<Event> on;
    for (int i = 0; i < count; ++i) on.push_back(notes::noteOn(0, static_cast<uint32_t>(i + 1), 48 + 3 * i, 0.9));
    double best = 1e30;
    for (int run = 0; run < 3; ++run) {
        p->reset();
        const int calls = static_cast<int>(seconds * kRate / kCallback);
        const auto t0 = Clock::now();
        for (int c = 0; c < calls; ++c) {
            const EventInput in{c == 0 ? on.data() : nullptr, c == 0 ? static_cast<uint32_t>(on.size()) : 0u};
            ProcessBlock b;
            b.frames = kCallback;
            b.audioOut = &audio;
            b.audioOutCount = 1;
            b.eventIn = &in;
            b.eventInCount = 1;
            b.parameters = params.data();
            b.parameterCount = d.parameterCount;
            p->processPorts(b);
        }
        best = std::min(best, std::chrono::duration<double, std::micro>(Clock::now() - t0).count() / seconds);
    }
    return best;  // microseconds of CPU per second of audio
}

// The effects suite's cost (`caw_bench SECONDS 300`): each effect alone on a busy stereo signal (noise bursts
// and tones, never silent, so nothing sleeps) in the engine's 64-frame chain blocks, at its defaults and with its
// heavier options, the best of 3 runs; microseconds of CPU per second of audio (10000 = 1% of a core).
double effectCost(const char* id, const std::vector<std::pair<std::string, double>>& values, double seconds) {
    Engine e(kRate);
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(id);
    if (!p || !p->activate(kRate, 64)) return 0.0;
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [name, v] : values)
            if (d.parameters[k].id == name) params[k].value = v;
    }
    const int frames = kRate;  // a second of input, looped
    std::vector<float> inL(frames), inR(frames), outL(64), outR(64);
    uint32_t seed = 1;
    for (int i = 0; i < frames; ++i) {
        seed = seed * 1664525u + 1013904223u;
        const double noise = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * (0.05 + 0.3 * ((i / 6000) % 2));
        inL[i] = static_cast<float>(noise + 0.3 * std::sin(2 * 3.14159265358979 * 220 * i / kRate));
        inR[i] = static_cast<float>(0.8 * noise + 0.3 * std::sin(2 * 3.14159265358979 * 330 * i / kRate));
    }
    double best = 1e30;
    for (int run = 0; run < 3; ++run) {
        p->reset();
        const int blocks = static_cast<int>(seconds * kRate / 64);
        const auto t0 = Clock::now();
        for (int b = 0; b < blocks; ++b) {
            const int at = (b * 64) % (frames - 64);
            const float* in[2] = {inL.data() + at, inR.data() + at};
            float* out[2] = {outL.data(), outR.data()};
            AudioProcessBlock block;
            block.input = {in, 2, 64};
            block.output = {out, 2, 64};
            block.frames = 64;
            block.sampleRate = kRate;
            block.parameters = params.data();
            block.parameterCount = d.parameterCount;
            p->process(block);
        }
        best = std::min(best, std::chrono::duration<double, std::micro>(Clock::now() - t0).count() / seconds);
    }
    return best;
}

void effectsCost(double seconds) {
    using Values = std::vector<std::pair<std::string, double>>;
    struct Case {
        const char* name;
        const char* id;
        Values values;
    };
    const Case cases[] = {
        {"eq (default: 6 bands at 0 dB)", "org.caw.eq", {}},
        {"eq, 8 bands with gain, 2 cuts at 48 dB", "org.caw.eq",
         {{"b1_on", 1}, {"b1_type", 5}, {"b8_on", 1}, {"b8_type", 8}, {"b2_gain", 3}, {"b3_gain", -3}, {"b4_gain", 4},
          {"b5_gain", 2}, {"b6_gain", -2}, {"b7_gain", 3}}},
        {"compressor (default: peak, linked)", "org.caw.compressor", {}},
        {"compressor, RMS, unlinked, sidechain HPF", "org.caw.compressor", {{"detect", 1}, {"link", 0}, {"sc_hpf", 120}}},
        {"limiter (default: true peak)", "org.caw.limiter", {{"gain", 12}}},
        {"limiter, sample peak", "org.caw.limiter", {{"gain", 12}, {"true_peak", 0}}},
        {"reverb (default: modulated)", "org.caw.reverb.pro", {}},
        {"reverb, no modulation", "org.caw.reverb.pro", {{"mod", 0}}},
        {"reverb, ducking", "org.caw.reverb.pro", {{"duck", 0.5}}},
        {"delay (default)", "org.caw.delay.pro", {}},
        {"delay, ping-pong, ducking", "org.caw.delay.pro", {{"mode", 1}, {"duck", 0.5}}},
        {"saturator (default: tape, 2x)", "org.caw.saturator", {}},
        {"saturator, tape, no oversampling", "org.caw.saturator", {{"oversample", 0}}},
        {"saturator, tube, 2x, tone", "org.caw.saturator", {{"mode", 1}, {"tone", 0.5}}},
        {"gate", "org.caw.gate", {}},
        {"transient shaper", "org.caw.transient", {{"attack", 0.5}, {"sustain", 0.3}}},
        {"filter (default: 24 dB SVF)", "org.caw.filter", {}},
        {"filter, ladder, LFO, envelope", "org.caw.filter", {{"type", 6}, {"lfo_amount", 0.5}, {"env_amount", 0.3}}},
        {"phaser (default: 6 stages)", "org.caw.phaser", {}},
        {"phaser, 12 stages", "org.caw.phaser", {{"stages", 5}}},
        {"flanger", "org.caw.flanger", {}},
        {"utility, bass mono, DC block", "org.caw.utility", {{"bass_mono", 1}, {"dc_block", 1}, {"width", 1.3}}},
        {"chorus (existing, for scale)", "org.caw.chorus", {}},
        {"ping-pong delay (existing)", "org.caw.delay.pingpong", {}},
    };
    std::printf("effects: microseconds of CPU per second of stereo audio, 64-frame blocks (10000 = 1%% of a core)\n");
    for (const Case& c : cases) std::printf("  %-44s %8.0f\n", c.name, effectCost(c.id, c.values, seconds));
}

void flagshipVoiceCost(double seconds) {
    using Values = std::vector<std::pair<std::string, double>>;
    const Values dry = {{"flt1_on", 0}, {"fx_reverb_on", 0}, {"env1_sustain", 1}, {"mod1_src", 0}};
    auto with = [&](Values v) {
        Values x = dry;
        x.insert(x.end(), v.begin(), v.end());
        return x;
    };
    const double idle = heldNotes(dry, 0, seconds);
    const double x1 = heldNotes(with({{"osc1_unison", 1}}), 8, seconds);
    const double x7 = heldNotes(with({{"osc1_unison", 7}}), 8, seconds);
    const double x16 = heldNotes(with({{"osc1_unison", 16}}), 8, seconds);
    const double ladder = heldNotes(with({{"osc1_unison", 1}, {"flt1_on", 1}}), 8, seconds);
    const double svf = heldNotes(with({{"osc1_unison", 1}, {"flt1_on", 1}, {"flt1_type", 3}}), 8, seconds);
    const double matrix = heldNotes(with({{"osc1_unison", 1}, {"mod1_src", 4}, {"mod1_dst", 3}, {"mod1_amt", 0.3}}), 8, seconds);
    const double reverb = heldNotes(with({{"osc1_unison", 1}, {"fx_reverb_on", 1}}), 8, seconds);
    const double def = heldNotes({}, 8, seconds);
    std::printf("flagship, 8 held notes: microseconds of CPU per second of audio (10000 = 1%% of a core)\n");
    std::printf("  no notes                         %8.0f\n", idle);
    std::printf("  one copy each, no filter         %8.0f   a voice: %5.0f\n", x1, (x1 - idle) / 8);
    std::printf("  seven copies                     %8.0f   a copy:  %5.0f\n", x7, (x7 - x1) / (8 * 6));
    std::printf("  sixteen copies                   %8.0f   a copy:  %5.0f\n", x16, (x16 - x1) / (8 * 15));
    std::printf("  one copy + ladder                %8.0f   a ladder pair: %5.0f\n", ladder, (ladder - x1) / 8);
    std::printf("  one copy + SVF                   %8.0f   an SVF pair:   %5.0f\n", svf, (svf - x1) / 8);
    std::printf("  one copy + an LFO slot           %8.0f   a slot per voice: %5.0f\n", matrix, (matrix - x1) / 8);
    std::printf("  one copy + reverb                %8.0f   the reverb: %5.0f\n", reverb, reverb - x1);
    std::printf("  the default patch                %8.0f   a voice: %5.0f\n", def, (def - idle) / 8);
}


// Plays `seconds` of audio in kCallback-frame callbacks; `each` runs between callbacks (control-thread work).
Result play(Engine& e, double seconds, const std::function<void(int)>& each = nullptr) {
    const int calls = static_cast<int>(seconds * kRate / kCallback);
    std::vector<float> l(kCallback), r(kCallback);
    std::vector<double> us;
    us.reserve(static_cast<size_t>(calls));
    for (int c = 0; c < calls; ++c) {
        if (each) each(c);
        const auto t0 = Clock::now();
        e.process(l.data(), r.data(), kCallback);
        us.push_back(std::chrono::duration<double, std::micro>(Clock::now() - t0).count());
    }
    Result res;
    for (double v : us) res.meanUs += v;
    res.meanUs /= static_cast<double>(us.size());
    std::sort(us.begin(), us.end());
    res.p99Us = us[us.size() * 99 / 100];
    res.maxUs = us.back();
    res.load = res.meanUs / (1e6 * kCallback / kRate);
    return res;
}

void report(const char* name, const Result& r) {
    std::printf("%-34s mean %8.1f us  p99 %8.1f us  max %8.1f us  load %6.2f%%\n", name, r.meanUs, r.p99Us,
                r.maxUs, 100.0 * r.load);
}

double ms(Clock::time_point a) { return std::chrono::duration<double, std::milli>(Clock::now() - a).count(); }

// Times `seconds` of kCallback-frame calls of `call`, the same way play() times Engine::process.
Result timeCalls(double seconds, const std::function<bool()>& call) {
    const int calls = static_cast<int>(seconds * kRate / kCallback);
    std::vector<double> us;
    us.reserve(static_cast<size_t>(calls));
    for (int c = 0; c < calls; ++c) {
        const auto t0 = Clock::now();
        if (!call()) { std::fprintf(stderr, "graph process failed\n"); std::exit(3); }
        us.push_back(std::chrono::duration<double, std::micro>(Clock::now() - t0).count());
    }
    Result res;
    for (double v : us) res.meanUs += v;
    res.meanUs /= static_cast<double>(us.size());
    std::sort(us.begin(), us.end());
    res.p99Us = us[us.size() * 99 / 100];
    res.maxUs = us.back();
    res.load = res.meanUs / (1e6 * kCallback / kRate);
    return res;
}

void profileSong(int k, double seconds) {
    const std::string dir = (std::filesystem::temp_directory_path() / "caw_bench_song").string();
    std::filesystem::create_directories(dir);
    Engine e(kRate);
    if (const char* q = std::getenv("CAW_BENCH_QUALITY")) e.setQuality(std::atoi(q));
    const std::string warn = e.setProject(songScenario(k, dir));
    e.play();
    const int calls = static_cast<int>(seconds * kRate / kProfileCallback);
    std::vector<float> l(kProfileCallback), r(kProfileCallback);
    for (int c = 0; c < kRate / kProfileCallback; ++c) e.process(l.data(), r.data(), kProfileCallback);  // warm up 1 s
    static ChainProfile profile;  // large: not on the stack
    profile = ChainProfile{};
    ChainProfile::set(&profile);
    uint64_t total = 0;
    float peak = 0;
    for (int c = 0; c < calls; ++c) {
        const auto t0 = Clock::now();
        e.process(l.data(), r.data(), kProfileCallback);
        total += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - t0).count());
        for (int i = 0; i < kProfileCallback; ++i) peak = std::max(peak, std::fabs(l[i]));
    }
    ChainProfile::set(nullptr);
    std::printf("%s: %d callbacks of %d frames, peak %.2f; ns per callback (budget %.0f)\n", scenarioName(k),
                calls, kProfileCallback, peak, 1e9 * kProfileCallback / kRate);
    struct Row { std::string id; uint64_t ns, ran, calls; int n; };
    std::map<std::string, Row> byId;
    uint64_t inComponents = 0;
    std::vector<Row> rows;
    for (uint32_t s = 0; s < profile.used; ++s) {
        const ChainProfile::Slot& x = profile.slots[s];
        const std::string id = (x.id ? *x.id : std::string("?")) + (x.modulator ? " (modulator)" : "");
        rows.push_back({id, x.ns, x.ran, x.calls, 1});
        Row& g = byId[id];
        g.id = id;
        g.ns += x.ns;
        g.ran += x.ran;
        g.calls += x.calls;
        g.n += 1;
        inComponents += x.ns;
    }
    std::vector<Row> grouped;
    for (auto& [id, g] : byId) grouped.push_back(g);
    std::sort(grouped.begin(), grouped.end(), [](const Row& a, const Row& b) { return a.ns > b.ns; });
    const double per = 1.0 / calls;
    std::printf("  %-40s %10.0f ns  100.0%%\n", "Engine::process (all)", total * per);
    std::printf("  %-40s %10.0f ns  %5.1f%%\n", "host (everything but components)", (total - std::min(total, inComponents)) * per,
                100.0 * (total - std::min(total, inComponents)) / total);
    for (const Row& g : grouped)
        std::printf("  %-40s %10.0f ns  %5.1f%%  x%d, ran %3.0f%% of blocks\n", g.id.c_str(), g.ns * per, 100.0 * g.ns / total, g.n,
                    g.calls ? 100.0 * g.ran / g.calls : 0.0);
    if (std::getenv("CAW_BENCH_EACH")) {  // every instance, in chain-build order
        for (const Row& x : rows) std::printf("    %-38s %10.0f ns\n", x.id.c_str(), x.ns * per);
    }
    if (warn.find("\"ok\":true") == std::string::npos || std::getenv("CAW_BENCH_WARN")) std::printf("setProject: %s\n", warn.c_str());
}

// Graph scenarios are sub-microsecond, so they report nanoseconds.
void reportNs(const char* name, const Result& r) {
    std::printf("%-34s mean %8.0f ns  p99 %8.0f ns  max %8.0f ns  load %7.3f%%\n", name, 1e3 * r.meanUs,
                1e3 * r.p99Us, 1e3 * r.maxUs, 100.0 * r.load);
}

constexpr uint32_t kGraphNodes = 8;
const char* const kGraphIds[kGraphNodes] = {"n0", "n1", "n2", "n3", "n4", "n5", "n6", "n7"};

GraphResourceBudget graphBudget() {
    GraphResourceBudget budget;
    budget.maxWorkingBytes = 64u * 1024u * 1024u;
    return budget;
}

const PortDescriptor kStereoEffectPorts[] = {
    {"in", PortType::Audio, ChannelLayout::Stereo, true},
    {"out", PortType::Audio, ChannelLayout::Stereo, false},
};
const ModuleDescriptor kStereoEffect{"bench.stereo.gain", 1, kStereoEffectPorts, 2, nullptr, 0, nullptr, 0, {}};

// A legacy stereo-only processor, as existing native modules are written.
class StereoGain final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kStereoEffect; }
    void process(const StereoProcessBlock& b) noexcept override {
        for (uint32_t i = 0; i < b.frames; ++i) {
            b.outputLeft[i] = b.inputLeft[i] * 0.999f;
            b.outputRight[i] = b.inputRight[i] * 0.999f;
        }
    }
};

// An 8-node stereo chain through the stereo wrapper: the cost existing callers see.
void graphStereoBench(double secs) {
    std::vector<StereoGain> gains(kGraphNodes);
    std::vector<GraphNode> nodes;
    std::vector<GraphConnection> edges;
    std::vector<ModuleProcessor*> processors;
    for (uint32_t n = 0; n < kGraphNodes; ++n) {
        nodes.push_back({kGraphIds[n], &kStereoEffect});
        processors.push_back(&gains[n]);
        if (n) edges.push_back({n - 1, 1, n, 0});
    }
    GraphExecutor executor;
    if (executor.prepare(nodes, edges, processors, kGraphNodes - 1, kCallback, kRate, graphBudget()) !=
        GraphError::Ok) { std::fprintf(stderr, "graph prepare failed\n"); std::exit(3); }
    std::vector<float> inL(kCallback, 0.5f), inR(kCallback, -0.5f), outL(kCallback), outR(kCallback);
    reportNs("graph: 8 stereo nodes (wrapper)", timeCalls(secs, [&] {
        return executor.process(inL.data(), inR.data(), outL.data(), outR.data(), kCallback);
    }));
}

// A generic planar processor for any channel count.
class PlanarGain final : public ModuleProcessor {
public:
    explicit PlanarGain(const ModuleDescriptor& d) : d_(&d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return *d_; }
    bool process(const AudioProcessBlock& b) noexcept override {
        for (uint32_t c = 0; c < b.output.channelCount; ++c)
            for (uint32_t i = 0; i < b.frames; ++i) b.output.channels[c][i] = b.input.channels[c][i] * 0.999f;
        return true;
    }
private:
    const ModuleDescriptor* d_;
};

// 8-node planar chains at 1, 2, 6 and 8 channels through process(AudioProcessBlock).
void graphPlanarBench(double secs) {
    struct Shape { const char* name; ChannelLayout layout; uint32_t channels; };
    const Shape shapes[] = {{"graph: 8 mono nodes (planar)", ChannelLayout::Mono, 1},
                            {"graph: 8 stereo nodes (planar)", ChannelLayout::Stereo, 2},
                            {"graph: 8 5.1 nodes (planar)", ChannelLayout::Surround51, 6},
                            {"graph: 8 7.1 nodes (planar)", ChannelLayout::Surround71, 8}};
    for (const Shape& shape : shapes) {
        const PortDescriptor ports[] = {{"in", PortType::Audio, shape.layout, true},
                                        {"out", PortType::Audio, shape.layout, false}};
        const ModuleDescriptor effect{"bench.planar.gain", 1, ports, 2, nullptr, 0, nullptr, 0, {}};
        std::vector<PlanarGain> gains(kGraphNodes, PlanarGain(effect));
        std::vector<GraphNode> nodes;
        std::vector<GraphConnection> edges;
        std::vector<ModuleProcessor*> processors;
        for (uint32_t n = 0; n < kGraphNodes; ++n) {
            nodes.push_back({kGraphIds[n], &effect});
            processors.push_back(&gains[n]);
            if (n) edges.push_back({n - 1, 1, n, 0});
        }
        GraphExecutor executor;
        if (executor.prepare(nodes, edges, processors, kGraphNodes - 1, kCallback, kRate, graphBudget()) !=
            GraphError::Ok) { std::fprintf(stderr, "graph prepare failed\n"); std::exit(3); }
        std::vector<std::vector<float>> in(shape.channels, std::vector<float>(kCallback, 0.5f));
        std::vector<std::vector<float>> out(shape.channels, std::vector<float>(kCallback));
        std::vector<const float*> inPtr;
        std::vector<float*> outPtr;
        for (uint32_t c = 0; c < shape.channels; ++c) { inPtr.push_back(in[c].data()); outPtr.push_back(out[c].data()); }
        const ConstChannelBufferView inView{inPtr.data(), shape.channels, kCallback};
        const ChannelBufferView outView{outPtr.data(), shape.channels, kCallback};
        reportNs(shape.name, timeCalls(secs, [&] { return executor.process(inView, outView, kCallback); }));
    }
}

// ---------- The suite (`caw_bench SECONDS 500 [options]`): fixed scenarios at a stated callback, repeated, for CI ----------
// Options: --frames N (callback size, default 256), --runs N (default 3), --only ID[,ID] (scenario ids), --label TEXT,
// --threads N (the mix pool's workers, speed phase 5c: 0, the default, runs the mix graph on one thread; N > 0 runs
// every level of two or more nodes on the pool, whatever the load, as Engine::MixParallel::Always; `auto` takes
// MixPool::defaultWorkers(), the count a live device gets on this machine, speed phase 5d),
// --json PATH and --md PATH (machine-readable results and a markdown table). Each run plays every scenario in turn
// (a fresh Engine each: set up, 0.25 s stopped to apply the project, then Play); a scenario's result is the median
// of its runs' means and p99s and the largest worst case of any run. docs/engine-performance.md has the numbers.

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

struct SuiteScenario {
    const char* id;
    const char* name;
    std::function<ProjectSpec(const std::string&)> make;
    bool tail = false;  // played for kTailSeconds and reported as three phases (notes, ringing, silence)
};

constexpr double kTailSeconds = 30.0;
constexpr double kTailNotesSeconds = 2.0;   // the bar the notes play in (at 120 BPM)
constexpr float kSilence = 1e-5f;           // -100 dBFS: below this the output counts as silent

std::vector<SuiteScenario> suiteScenarios() {
    return {
        {"first_loop", "First loop (6 tracks)", [](const std::string&) { return firstLoop(); }},
        {"three_tracks", "Three tracks", [](const std::string&) { return threeTracks(); }},
        {"song8", "Typical song (8 tracks)", [](const std::string&) { return typicalSong(false); }},
        {"song8_extras", "Typical song + extras", [](const std::string& d) { return typicalSong(true, d); }},
        {"flagship_heavy", "Flagship heavy, 64 voices held", [](const std::string&) { return flagshipHeavy(64); }},
        {"flagship_heavy16", "Flagship heavy, 16 voices held", [](const std::string&) { return flagshipHeavy(16); }},
        {"drums_kit", "Drums kit, 16 pads busy", [](const std::string&) { return drumsBusy(); }},
        {"song16", "Song, 16 tracks", [](const std::string&) { return bigSong(16, false); }},
        {"song32_heavy", "Song, 32 tracks + heavy FX", [](const std::string&) { return bigSong(32, true); }},
        {"tail", "Tail", [](const std::string&) { return tailSong(true); }, true},
        {"tail_floor", "Tail project, no notes", [](const std::string&) { return tailSong(false); }},
    };
}

struct SuiteStats {
    double meanUs = 0, p99Us = 0, maxUs = 0;
    size_t callbacks = 0;
    size_t maxAt = 0;  // the callback the worst case was, counted from Play
};

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

struct SuiteRow {
    std::string id, name;
    std::vector<SuiteStats> runs;
    double seconds = -1;  // tail phases: the length of the phase in audio seconds
};

double median(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    const size_t n = v.size();
    return n == 0 ? 0.0 : n % 2 ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2]);
}

std::string jsonEscape(const std::string& s) {
    std::string o;
    for (char c : s) {
        if (c == '"' || c == '\\') o += '\\';
        if (static_cast<unsigned char>(c) >= 0x20) o += c;
    }
    return o;
}

const char* targetName() {
#if defined(__ANDROID__) && defined(__aarch64__)
    return "android-arm64";
#elif defined(__ANDROID__)
    return "android";
#elif defined(__linux__) && defined(__aarch64__)
    return "linux-arm64";
#elif defined(__linux__) && defined(__x86_64__)
    return "linux-x64";
#elif defined(_WIN32)
    return "windows";
#else
    return "other";
#endif
}

int runSuite(double secs, int argc, char** argv) {
    int frames = 256, runs = 3, threads = 0;
    std::string only, label = targetName(), jsonPath, mdPath;
    for (int a = 3; a < argc; ++a) {
        const std::string k = argv[a];
        const char* v = a + 1 < argc ? argv[a + 1] : nullptr;
        if (!v) { std::fprintf(stderr, "%s needs a value\n", k.c_str()); return 2; }
        if (k == "--frames") frames = std::atoi(v);
        else if (k == "--runs") runs = std::atoi(v);
        else if (k == "--threads") threads = std::string(v) == "auto" ? static_cast<int>(MixPool::defaultWorkers()) : std::atoi(v);
        else if (k == "--only") only = std::string(",") + v + ",";
        else if (k == "--label") label = v;
        else if (k == "--json") jsonPath = v;
        else if (k == "--md") mdPath = v;
        else { std::fprintf(stderr, "unknown option %s\n", k.c_str()); return 2; }
        ++a;
    }
    if (frames < 16 || frames > 8192 || runs < 1 || runs > 50 || secs <= 0 || threads < 0 ||
        threads > static_cast<int>(MixPool::kMaxWorkers)) {
        std::fprintf(stderr, "bad --frames, --runs, --threads (0..%u) or SECONDS\n", MixPool::kMaxWorkers);
        return 2;
    }
    const double budgetUs = 1e6 * frames / kRate;
    const std::string dir = (std::filesystem::temp_directory_path() / "caw_bench_suite").string();
    std::filesystem::create_directories(dir);
    std::vector<SuiteScenario> all = suiteScenarios();
    std::vector<SuiteRow> rows;
    std::map<std::string, size_t> rowOf;
    auto row = [&](const std::string& id, const std::string& name) -> SuiteRow& {
        auto it = rowOf.find(id);
        if (it != rowOf.end()) return rows[it->second];
        rowOf[id] = rows.size();
        rows.push_back({id, name, {}, -1});
        return rows.back();
    };
    std::printf("caw_bench suite: %s, callback %d frames at %d Hz (budget %.1f us), %.0f s per scenario, %d runs, "
                "--threads %d\n", label.c_str(), frames, kRate, budgetUs, secs, runs, threads);
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int run = 0; run < runs; ++run) {
        for (const SuiteScenario& sc : all) {
            if (!only.empty() && only.find(std::string(",") + sc.id + ",") == std::string::npos) continue;
            Engine e(kRate);
            if (threads > 0) {
                if (!e.startMixPool(static_cast<uint32_t>(threads))) {
                    std::fprintf(stderr, "could not start %d mix workers\n", threads);
                    return 3;
                }
                e.setMixParallel(Engine::MixParallel::Always);
            } else {
                e.setMixParallel(Engine::MixParallel::Never);
            }
            const std::string warn = e.setProject(sc.make(dir));
            if (warn.find("\"ok\":true") == std::string::npos) {
                std::fprintf(stderr, "%s: setProject: %s\n", sc.id, warn.c_str());
                return 3;
            }
            for (int c = 0; c < kRate / 4 / frames; ++c) e.process(l.data(), r.data(), frames);  // apply the project
            e.play();
            const int calls = static_cast<int>((sc.tail ? kTailSeconds : secs) * kRate / frames);
            std::vector<double> us(static_cast<size_t>(calls));
            std::vector<float> peak(static_cast<size_t>(calls));
            for (int c = 0; c < calls; ++c) {
                const auto t0 = Clock::now();
                e.process(l.data(), r.data(), frames);
                us[static_cast<size_t>(c)] = std::chrono::duration<double, std::micro>(Clock::now() - t0).count();
                float m = 0;
                for (int i = 0; i < frames; ++i) m = std::max(m, std::max(std::fabs(l[static_cast<size_t>(i)]), std::fabs(r[static_cast<size_t>(i)])));
                peak[static_cast<size_t>(c)] = m;
            }
            const size_t n = us.size();
            if (!sc.tail) {
                row(sc.id, sc.name).runs.push_back(stats(us, 0, n));
                continue;
            }
            // Phases: the notes' bar; the tail, until the last callback louder than kSilence; the silence after it.
            const size_t notesEnd = std::min(n, static_cast<size_t>(kTailNotesSeconds * kRate / frames));
            size_t loud = notesEnd;
            for (size_t c = notesEnd; c < n; ++c)
                if (peak[c] > kSilence) loud = c + 1;
            const double perCall = static_cast<double>(frames) / kRate;
            SuiteRow& a = row(std::string(sc.id) + "_notes", std::string(sc.name) + ": notes (2 s)");
            a.runs.push_back(stats(us, 0, notesEnd));
            a.seconds = notesEnd * perCall;
            SuiteRow& b = row(std::string(sc.id) + "_ringing", std::string(sc.name) + ": ringing out");
            b.runs.push_back(stats(us, notesEnd, loud));
            b.seconds = (loud - notesEnd) * perCall;
            SuiteRow& s = row(std::string(sc.id) + "_silence", std::string(sc.name) + ": silence after");
            s.runs.push_back(stats(us, loud, n));
            s.seconds = (n - loud) * perCall;
        }
    }
    struct Out { const SuiteRow* row; double mean, p99, worst, worstAtS; size_t callbacks; };
    std::vector<Out> out;
    for (const SuiteRow& x : rows) {
        std::vector<double> means, p99s;
        double worst = 0, worstAt = 0;
        for (const SuiteStats& s : x.runs) {
            means.push_back(s.meanUs), p99s.push_back(s.p99Us);
            if (s.maxUs > worst) worst = s.maxUs, worstAt = static_cast<double>(s.maxAt) * frames / kRate;
        }
        out.push_back({&x, median(means), median(p99s), worst, worstAt, x.runs.empty() ? 0 : x.runs.front().callbacks});
    }
    std::printf("%-40s %10s %10s %10s %8s %8s %8s\n", "scenario", "mean us", "p99 us", "worst us", "mean %", "worst %", "worst at");
    for (const Out& o : out)
        std::printf("%-40s %10.1f %10.1f %10.1f %7.2f%% %7.1f%% %7.2fs%s\n", o.row->name.c_str(), o.mean, o.p99, o.worst,
                    100 * o.mean / budgetUs, 100 * o.worst / budgetUs, o.worstAtS,
                    o.row->seconds >= 0 ? (" (" + std::to_string(o.row->seconds).substr(0, 5) + " s)").c_str() : "");
    if (!jsonPath.empty()) {
        std::string j = "{\"tool\":\"caw_bench\",\"format\":1,\"label\":\"" + jsonEscape(label) + "\",\"target\":\"" + targetName() +
                        "\",\"compiler\":\"" + jsonEscape(compilerName()) + "\",\"rate\":" + std::to_string(kRate) +
                        ",\"frames\":" + std::to_string(frames) + ",\"budget_us\":" + std::to_string(budgetUs) +
                        ",\"runs\":" + std::to_string(runs) + ",\"seconds\":" + std::to_string(secs) +
                        ",\"threads\":" + std::to_string(threads) + ",\"scenarios\":[";
        for (size_t k = 0; k < out.size(); ++k) {
            const Out& o = out[k];
            j += std::string(k ? "," : "") + "{\"id\":\"" + o.row->id + "\",\"name\":\"" + jsonEscape(o.row->name) +
                 "\",\"callbacks\":" + std::to_string(o.callbacks) + ",\"mean_us\":" + std::to_string(o.mean) +
                 ",\"p99_us\":" + std::to_string(o.p99) + ",\"worst_us\":" + std::to_string(o.worst) +
                 ",\"mean_load_pct\":" + std::to_string(100 * o.mean / budgetUs) +
                 ",\"worst_load_pct\":" + std::to_string(100 * o.worst / budgetUs) +
                 ",\"worst_at_s\":" + std::to_string(o.worstAtS);
            if (o.row->seconds >= 0) j += ",\"phase_s\":" + std::to_string(o.row->seconds);
            j += ",\"run_means_us\":[";
            for (size_t q = 0; q < o.row->runs.size(); ++q) j += (q ? "," : "") + std::to_string(o.row->runs[q].meanUs);
            j += "],\"run_worst_us\":[";
            for (size_t q = 0; q < o.row->runs.size(); ++q) j += (q ? "," : "") + std::to_string(o.row->runs[q].maxUs);
            j += "]}";
        }
        j += "]}\n";
        std::ofstream(jsonPath) << j;
    }
    if (!mdPath.empty()) {
        std::ofstream md(mdPath);
        char line[512];
        std::snprintf(line, sizeof line, "### %s: %d frames at %d Hz (budget %.0f us), %.0f s x %d runs, --threads %d\n\n",
                      label.c_str(), frames, kRate, budgetUs, secs, runs, threads);
        md << line << "| Scenario | Mean us | p99 us | Worst us | Mean load | Worst load | Worst at |\n|---|---:|---:|---:|---:|---:|---:|\n";
        for (const Out& o : out) {
            std::snprintf(line, sizeof line, "| %s | %.1f | %.1f | %.1f | %.2f%% | %.1f%% | %.2f s |\n", o.row->name.c_str(), o.mean,
                          o.p99, o.worst, 100 * o.mean / budgetUs, 100 * o.worst / budgetUs, o.worstAtS);
            md << line;
        }
    }
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    const double secs = argc > 1 ? std::atof(argv[1]) : 10.0;
    // `caw_bench SECONDS N` plays only playback scenario N (1-5), for exact instruction counts under callgrind;
    // N = 100 plays First loop (the app's starter project on the built-in instruments) and each built-in alone
    // (`caw_bench SECONDS 100 K`: only the K-th of those, from 0); N = 200 times the flagship synth's voices; N = 300
    // times each built-in effect.
    const int only = argc > 2 ? std::atoi(argv[2]) : 0;
    if (only == 500) return runSuite(secs, argc, argv);  // `caw_bench SECONDS 500 [options]`: the CI suite (runSuite)
    std::printf("callback %d frames at %d Hz (budget %.0f us); %.0f s per scenario\n", kCallback, kRate,
                1e6 * kCallback / kRate, secs);
    {
        Engine e(kRate);
        e.setProject(firstLoop());
        report("stopped (first loop)", play(e, secs));
    }
    struct Case {
        const char* name;
        ProjectSpec p;
    };
    std::vector<Case> cases = {{"1 track (bass)", firstLoop("Bass")},
                               {"first loop (6 tracks)", firstLoop()},
                               {"16 tracks", manyTracks(16)},
                               {"64 tracks", manyTracks(64)},
                               {"first loop + delay + reverb each", withSpace()}};
    if (only == 400 || only == 401) {  // the song scenarios: timed (400) or profiled per component (401)
        const int k = argc > 3 ? std::atoi(argv[3]) : 1;
        if (only == 401) {
            profileSong(k, secs);
            return 0;
        }
        const std::string dir = (std::filesystem::temp_directory_path() / "caw_bench_song").string();
        std::filesystem::create_directories(dir);
        Engine e(kRate);
        if (const char* q = std::getenv("CAW_BENCH_QUALITY")) e.setQuality(std::atoi(q));
        e.setProject(songScenario(k, dir));
        e.play();
        report(scenarioName(k), play(e, secs));
        return 0;
    }
    if (only == 300) {  // `caw_bench SECONDS 300`: each built-in effect's cost
        effectsCost(secs);
        return 0;
    }
    if (only == 200) {  // `caw_bench SECONDS 200`: the flagship synth's cost per voice and per unison copy
        flagshipVoiceCost(secs);
        return 0;
    }
    if (only < 0) {  // `caw_bench SECONDS -1`: graph executor scenarios only
        graphStereoBench(secs);
        graphPlanarBench(secs);
        return 0;
    }
    if (only == 100 || only == 0) {  // `caw_bench SECONDS 100`: First loop, its tracks and each built-in alone
        std::vector<Case> native = {
            {"first loop (6 tracks, all unmuted)", firstLoop()},
            {"  track Kick", firstLoop("Kick")},
            {"  track Hats", firstLoop("Hats")},
            {"  track Bass", firstLoop("Bass")},
            {"  track Lead (morph x3 + delay)", firstLoop("Lead")},
            {"  track Acid (+ distortion)", firstLoop("Acid")},
            {"  track Pad (morph x7 + chorus)", firstLoop("Pad")},
            {"idle track (instrument, no notes)", busy("org.caw.drum.kick", {}, {}, false)},
            {"busy kick", busy("org.caw.drum.kick", {})},
            {"busy snare", busy("org.caw.drum.snare", {})},
            {"busy hats", busy("org.caw.drum.hats", {})},
            {"busy kit", busy("org.caw.drum.kit", {})},
            {"busy bass", busy("org.caw.bass", {})},
            {"busy acid", busy("org.caw.synth.acid", {})},
            {"busy morph (unison 7)", busy("org.caw.synth.morph", {})},
            {"busy morph (unison 1)", busy("org.caw.synth.morph", {{"unison", 1}})},
            {"busy morph (unison 16)", busy("org.caw.synth.morph", {{"unison", 16}})},
            {"busy basic synth", busy("org.caw.synth.basic", {})},
            {"busy morph x1 + chorus", busy("org.caw.synth.morph", {{"unison", 1}}, {component("org.caw.chorus")})},
            {"busy morph x1 + ping-pong", busy("org.caw.synth.morph", {{"unison", 1}}, {component("org.caw.delay.pingpong")})},
            {"busy morph x1 + distortion", busy("org.caw.synth.morph", {{"unison", 1}}, {component("org.caw.distortion")})},
            {"busy flagship (default: x7, ladder, reverb)", busy("org.caw.synth.flagship", {})},
            {"busy flagship x1, no filter, no fx", busy("org.caw.synth.flagship", {{"osc1_unison", 1}, {"flt1_on", 0}, {"fx_reverb_on", 0}})},
            {"busy flagship x7, no filter, no fx", busy("org.caw.synth.flagship", {{"flt1_on", 0}, {"fx_reverb_on", 0}})},
            {"busy flagship x16, no filter, no fx", busy("org.caw.synth.flagship", {{"osc1_unison", 16}, {"flt1_on", 0}, {"fx_reverb_on", 0}})},
            {"busy flagship x7, ladder, no fx", busy("org.caw.synth.flagship", {{"fx_reverb_on", 0}})},
            {"busy flagship 3 osc x16, 2 filters, all fx",
             busy("org.caw.synth.flagship", {{"osc1_unison", 16}, {"osc2_on", 1}, {"osc2_unison", 16}, {"osc3_on", 1}, {"osc3_unison", 16},
                                             {"osc2_frame", 0.5}, {"flt2_on", 1}, {"fx_dist_on", 1}, {"fx_eq_on", 1}, {"fx_chorus_on", 1},
                                             {"fx_delay_on", 1}, {"mod2_src", 4}, {"mod2_dst", 3}, {"mod2_amt", 0.3}})},
        };
        const int pick = only == 100 && argc > 3 ? std::atoi(argv[3]) : -1;  // `caw_bench S 100 K`: case K only
        for (size_t k = 0; k < native.size(); ++k) {
            if (pick >= 0 && static_cast<size_t>(pick) != k) continue;
            Case& c = native[k];
            Engine e(kRate);
            // CAW_BENCH_QUALITY=0|1|2: the quality setting (Eco, Normal, High) to measure at.
            if (const char* q = std::getenv("CAW_BENCH_QUALITY")) e.setQuality(std::atoi(q));
            e.setProject(c.p);
            e.play();
            report(c.name, play(e, secs));
        }
        if (only == 100) return 0;
    }
    if (only > 0) {
        Case& c = cases[static_cast<size_t>(std::min<int>(only, static_cast<int>(cases.size())) - 1)];
        Engine e(kRate);
        e.setProject(c.p);
        e.play();
        report(c.name, play(e, secs));
        return 0;
    }
    for (Case& c : cases) {
        Engine e(kRate);
        const auto t0 = Clock::now();
        e.setProject(c.p);
        const double setMs = ms(t0);
        e.play();
        Result r = play(e, secs);
        report(c.name, r);
        std::printf("%-34s setProject %.1f ms\n", "", setMs);
    }
    {
        // Live editing: a pattern edit every quarter second while 16 tracks play; parsing is control-thread.
        Engine e(kRate);
        ProjectSpec p = manyTracks(16);
        const std::string bass = p.modules[2].source;
        e.setProject(p);
        e.play();
        double editMs = 0;
        int edits = 0;
        Result r = play(e, secs, [&](int c) {
            if (c % 62 != 0) return;
            p.modules[2].source = bass + (edits % 2 ? "" : "13 E2 1/2 0.8\n");
            const auto t0 = Clock::now();
            e.setProject(p);
            editMs += ms(t0);
            ++edits;
        });
        report("16 tracks, pattern edit every 0.25 s", r);
        std::printf("%-34s %d edits, setProject mean %.2f ms\n", "", edits, editMs / edits);
    }
    {
        // The cost of a project re-sent unchanged.
        Engine e(kRate);
        ProjectSpec p = manyTracks(16);
        e.setProject(p);
        const auto t0 = Clock::now();
        for (int i = 0; i < 20; ++i) e.setProject(p);
        std::printf("setProject unchanged (16 tracks)  %.3f ms\n", ms(t0) / 20);
    }
    {
        // Offline export speed, and memory with many layers.
        ProjectSpec p = manyTracks(16);
        ExportOptions o;
        RenderResult out;
        const auto t0 = Clock::now();
        renderExport(p, o, out);
        const double took = ms(t0);
        const double audio = 2.0 * out.frames / static_cast<double>(out.sampleRate);  // loop export renders 2 loops
        std::printf("loop export 16 tracks: %.0f ms for %.2f s of audio (%.0fx real time)\n", took, audio,
                    audio * 1000.0 / took);
        const long before = rssKb();
        Engine e(kRate);
        e.setProject(manyTracks(64));
        std::printf("RSS: %ld kB before, %ld kB with 64 tracks set up\n", before, rssKb());
    }
    graphStereoBench(secs);
    graphPlanarBench(secs);
    return 0;
}
