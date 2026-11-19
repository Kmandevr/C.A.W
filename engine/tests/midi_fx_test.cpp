// MIDI effects (1.1.0): each effect's notes, block-size independence, seeded randomness, bad values, presets, the chain stage and the project file.
#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "caw/instrument.hpp"
#include "engine.h"
#include "midi_fx.h"
#include "presets.h"
#include "project.h"
#include "test.h"
#include "test_signal.h"
#include "tolerance.h"

using namespace caw;

namespace {

using Values = std::vector<std::pair<std::string, double>>;

const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        return x;
    }();
    return r;
}

// An input event at an absolute frame.
struct In {
    int64_t at;
    Event e;
};
In on(int64_t at, uint32_t id, double pitch, double vel = 0.8) { return {at, notes::noteOn(0, id, pitch, vel)}; }
In off(int64_t at, uint32_t id, double pitch) { return {at, notes::noteOff(0, id, notes::keyOf(pitch))}; }

// What came out, at absolute frames.
struct Out {
    int64_t at;
    NoteMessage m;
};
bool same(const std::vector<Out>& a, const std::vector<Out>& b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i)
        if (a[i].at != b[i].at || a[i].m.type != b[i].m.type || a[i].m.noteId != b[i].m.noteId ||
            a[i].m.pitch != b[i].m.pitch || a[i].m.velocity != b[i].m.velocity || a[i].m.key != b[i].m.key)
            return false;
    return true;
}

// Runs a MIDI effect over `frames` in blocks of `block` (the transport playing from `beat` when `playing`).
std::vector<Out> run(const char* id, const Values& values, const std::vector<In>& input, int64_t frames, uint32_t block,
                     bool playing = false, double beat = 0.0, double bpm = 120.0, double nanParam = -1) {
    std::unique_ptr<ModuleProcessor> p(registry().create(id));
    CHECK(p != nullptr);
    if (!p) return {};
    CHECK(p->activate(48000.0, 512));
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [name, v] : values)
            if (d.parameters[k].id == name) params[k].value = v;
        if (nanParam >= 0) params[k].value = std::numeric_limits<double>::quiet_NaN();
    }
    std::vector<Out> out;
    std::vector<Event> inBuf(4096), outBuf(4096);
    size_t next = 0;
    for (int64_t t = 0; t < frames; t += block) {
        const uint32_t n = static_cast<uint32_t>(std::min<int64_t>(block, frames - t));
        uint32_t count = 0;
        while (next < input.size() && input[next].at < t + n) {
            inBuf[count] = input[next].e;
            inBuf[count++].frame = static_cast<uint32_t>(input[next].at - t);
            ++next;
        }
        const EventInput ein{inBuf.data(), count};
        EventOutput eout{outBuf.data(), 4096, 0};
        Transport tr;
        tr.tempo = bpm;
        tr.playing = playing;
        tr.beat = beat + static_cast<double>(t) * bpm / (60.0 * 48000.0);
        ProcessBlock b;
        b.frames = n;
        b.sampleRate = 48000.0;
        b.eventIn = &ein;
        b.eventInCount = 1;
        b.eventOut = &eout;
        b.eventOutCount = 1;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        b.transport = &tr;
        CHECK(p->processPorts(b));
        for (uint32_t i = 0; i < eout.count; ++i) {
            CHECK(eout.events[i].frame < n);
            if (i) CHECK(eout.events[i - 1].frame <= eout.events[i].frame);
            NoteMessage m;
            readNote(eout.events[i], m);
            out.push_back({t + eout.events[i].frame, m});
        }
    }
    return out;
}

std::vector<Out> ons(const std::vector<Out>& v) {
    std::vector<Out> r;
    for (const Out& o : v)
        if (o.m.type == NoteMessageType::On) r.push_back(o);
    return r;
}
size_t count(const std::vector<Out>& v, NoteMessageType t) {
    return static_cast<size_t>(std::count_if(v.begin(), v.end(), [&](const Out& o) { return o.m.type == t; }));
}

const char* const kIds[] = {"org.caw.midi.arp", "org.caw.midi.chords", "org.caw.midi.scale", "org.caw.midi.echo",
                            "org.caw.midi.humanize"};

}  // namespace

TEST(midi_fx_are_registered_event_processors_with_presets) {
    for (const char* id : kIds) {
        const ModuleDescriptor* d = registry().find(id);
        CHECK(d != nullptr);
        if (!d) continue;
        CHECK(midifx::isMidiEffect(*d));
        CHECK(d->role == ModuleRole::EventProcessor);
        CHECK(builtinPresets(id).size() >= 8);
        for (const BuiltinPreset& pr : builtinPresets(id))
            for (const auto& [k, v] : pr.values) {
                bool found = false;
                for (uint32_t i = 0; i < d->parameterCount; ++i) found = found || d->parameters[i].id == k;
                CHECK(found);
            }
    }
}

TEST(midi_scale_snaps_filters_and_transposes_in_key) {
    // C# (61) in C major: nearest (a tie goes down) C, down C, up D; filter leaves it out; E (64) stays.
    const std::vector<In> in = {on(0, 1, 61), on(10, 2, 64), off(100, 1, 61), off(100, 2, 64)};
    auto first = [](const std::vector<Out>& v) { return ons(v).at(0).m.pitch; };
    CHECK_EQ(first(run("org.caw.midi.scale", {}, in, 200, 64)), 60.0);
    CHECK_EQ(first(run("org.caw.midi.scale", {{"mode", 2}}, in, 200, 64)), 62.0);
    const std::vector<Out> filtered = run("org.caw.midi.scale", {{"mode", 3}}, in, 200, 64);
    CHECK_EQ(ons(filtered).size(), 1u);
    CHECK_EQ(ons(filtered)[0].m.pitch, 64.0);
    CHECK_EQ(count(filtered, NoteMessageType::Off), 1u);  // the left-out note's off is left out too
    // Two degrees up in A minor: E (64) becomes G (67); the off carries the new key.
    const std::vector<Out> up = run("org.caw.midi.scale", {{"root", 9}, {"scale", 1}, {"transpose", 2}}, {on(0, 1, 64), off(50, 1, 64)}, 100, 64);
    CHECK_EQ(up.size(), 2u);
    CHECK_EQ(up[0].m.pitch, 67.0);
    CHECK_EQ(static_cast<int>(up[1].m.key), 67);
}

TEST(midi_chords_build_the_keys_chords_and_strum) {
    auto pitches = [](const std::vector<Out>& v) {
        std::vector<double> p;
        for (const Out& o : ons(v)) p.push_back(o.m.pitch);
        return p;
    };
    // C major: C gives C E G, D gives D F A, B gives B D F; the played note keeps its id.
    CHECK(pitches(run("org.caw.midi.chords", {}, {on(0, 1, 60)}, 64, 64)) == (std::vector<double>{60, 64, 67}));
    CHECK(pitches(run("org.caw.midi.chords", {}, {on(0, 1, 62)}, 64, 64)) == (std::vector<double>{62, 65, 69}));
    CHECK(pitches(run("org.caw.midi.chords", {{"type", 1}}, {on(0, 1, 71)}, 64, 64)) == (std::vector<double>{71, 74, 77, 81}));
    const std::vector<Out> c = run("org.caw.midi.chords", {}, {on(0, 7, 60), off(100, 7, 60)}, 200, 64);
    CHECK_EQ(c[0].m.noteId, 7u);
    CHECK_EQ(count(c, NoteMessageType::Off), 3u);
    // Strum 10 ms: tones 480 frames apart; released before the last starts, that one never sounds.
    const std::vector<Out> s = run("org.caw.midi.chords", {{"strum", 10}}, {on(0, 1, 60), off(700, 1, 60)}, 2000, 37);
    CHECK_EQ(ons(s).size(), 2u);
    CHECK_EQ(ons(s)[1].at, 480);
    CHECK_EQ(count(s, NoteMessageType::Off), 2u);
}

TEST(midi_arp_plays_up_on_a_grid_with_gate) {
    // Stopped, 120 BPM, 1/16 = 6000 frames: C E G from frame 0, up, half gate.
    const std::vector<In> in = {on(0, 1, 60), on(0, 2, 64), on(0, 3, 67)};
    const std::vector<Out> out = run("org.caw.midi.arp", {}, in, 24001, 64);
    const std::vector<Out> o = ons(out);
    CHECK_EQ(o.size(), 5u);
    const double want[] = {60, 64, 67, 60, 64};
    for (size_t i = 0; i < o.size() && i < 5; ++i) {
        CHECK_EQ(o[i].at, static_cast<int64_t>(i) * 6000);
        CHECK_EQ(o[i].m.pitch, want[i]);
    }
    CHECK(out[1].m.type == NoteMessageType::Off);
    CHECK_EQ(out[1].at, 3000);
    // Playing from beat 0.1: the steps land on the song's 16th grid (beat 0.25 = frame 7200 of the block's clock).
    const std::vector<Out> g = ons(run("org.caw.midi.arp", {}, {on(0, 1, 60)}, 12000, 64, true, 0.1));
    CHECK(!g.empty());
    if (!g.empty()) CHECK_EQ(g[0].at, 3600);  // (0.25 - 0.1) beats x 24000 frames a beat
    // Swing moves odd steps later; down and up-down orders.
    const std::vector<Out> sw = ons(run("org.caw.midi.arp", {{"swing", 0.5}}, in, 12001, 64));
    CHECK_EQ(sw.at(1).at, 9000);
    const std::vector<Out> dn = ons(run("org.caw.midi.arp", {{"pattern", 1}}, in, 6001, 64));
    CHECK_EQ(dn.at(0).m.pitch, 67.0);
    // Two octaves up: 60 64 67 72 76 79.
    const std::vector<Out> oc = ons(run("org.caw.midi.arp", {{"octaves", 2}}, in, 36001, 64));
    CHECK_EQ(oc.at(5).m.pitch, 79.0);
    // Releasing every key stops it; Hold keeps the chord going.
    const std::vector<In> tap = {on(0, 1, 60), off(100, 1, 60)};
    CHECK_EQ(ons(run("org.caw.midi.arp", {}, tap, 30000, 64)).size(), 1u);
    CHECK_EQ(ons(run("org.caw.midi.arp", {{"hold", 1}}, tap, 30000, 64)).size(), 5u);
}

TEST(midi_echo_repeats_quieter_and_shifted) {
    // 1/8 at 120 BPM = 12000 frames; three repeats, each 0.6 of the last, an octave up each.
    const std::vector<Out> out = run("org.caw.midi.echo", {{"pitch", 12}}, {on(0, 1, 48, 1.0), off(1000, 1, 48)}, 40000, 64);
    const std::vector<Out> o = ons(out);
    CHECK_EQ(o.size(), 4u);
    for (size_t k = 0; k < o.size(); ++k) {
        CHECK_EQ(o[k].at, static_cast<int64_t>(k) * 12000);
        CHECK_EQ(o[k].m.pitch, 48.0 + 12.0 * static_cast<double>(k));
        CHECK(std::fabs(o[k].m.velocity - std::pow(0.6, static_cast<double>(k))) < 1e-4);
    }
    CHECK_EQ(count(out, NoteMessageType::Off), 4u);
    CHECK_EQ(out.back().at, 1000 + 3 * 12000);
    // Dry off: only the repeats.
    CHECK_EQ(ons(run("org.caw.midi.echo", {{"dry", 0}}, {on(0, 1, 48, 1.0), off(1000, 1, 48)}, 40000, 64)).size(), 3u);
}

TEST(midi_humanize_is_late_bounded_and_seeded_by_song_position) {
    std::vector<In> in;
    for (int k = 0; k < 32; ++k) in.push_back(on(k * 3000, static_cast<uint32_t>(k + 1), 60)), in.push_back(off(k * 3000 + 1000, static_cast<uint32_t>(k + 1), 60));
    const std::vector<Out> a = run("org.caw.midi.humanize", {{"timing", 20}, {"velocity", 0.2}}, in, 100000, 64, true);
    const std::vector<Out> o = ons(a);
    CHECK_EQ(o.size(), 32u);
    bool moved = false;
    for (size_t k = 0; k < o.size(); ++k) {
        const int64_t late = o[k].at - static_cast<int64_t>(k) * 3000;
        CHECK(late >= 0 && late <= 960);
        moved = moved || late > 0;
        CHECK(std::fabs(o[k].m.velocity - 0.8) <= 0.2 + 1e-4);
    }
    CHECK(moved);
    // The same song position gives the same feel; another seed another.
    CHECK(same(a, run("org.caw.midi.humanize", {{"timing", 20}, {"velocity", 0.2}}, in, 100000, 512, true)));
    CHECK(!same(a, run("org.caw.midi.humanize", {{"timing", 20}, {"velocity", 0.2}, {"seed", 2}}, in, 100000, 64, true)));
}

TEST(midi_fx_are_block_size_independent_and_survive_bad_values) {
    std::vector<In> in;
    for (int k = 0; k < 24; ++k) {
        const double pitch = 48 + (k * 7) % 24;
        in.push_back(on(k * 2500 + (k % 3) * 17, static_cast<uint32_t>(k + 1), pitch, 0.5 + 0.02 * k));
        in.push_back(off(k * 2500 + 4000, static_cast<uint32_t>(k + 1), pitch));
    }
    std::sort(in.begin(), in.end(), [](const In& x, const In& y) { return x.at < y.at; });
    const Values busy[] = {{{"pattern", 5}, {"octaves", 3}, {"swing", 0.3}}, {{"type", 2}, {"strum", 15}, {"voicing", 2}},
                           {{"mode", 1}, {"transpose", 3}}, {{"repeats", 6}, {"pitch", -5}}, {{"timing", 30}}};
    for (int k = 0; k < 5; ++k)
        for (bool playing : {false, true}) {
            const std::vector<Out> ref = run(kIds[k], busy[k], in, 80000, 64, playing, 0.3);
            CHECK(!ref.empty());
            for (uint32_t block : {1u, 37u, 512u}) CHECK(same(ref, run(kIds[k], busy[k], in, 80000, block, playing, 0.3)));
            // Every on is matched by an off (nothing sticks).
            const std::vector<Out> longer = run(kIds[k], busy[k], in, 400000, 64, playing, 0.3);
            CHECK_EQ(count(longer, NoteMessageType::On), count(longer, NoteMessageType::Off));
            // NaN knobs read as their defaults: the output stays well formed (checked inside run).
            run(kIds[k], busy[k], in, 20000, 64, playing, 0.3, 1);
        }
}

namespace {
ProjectSpec midiProject(std::vector<ComponentSpec> midi) {
    LayerSpec l = cawtest::testSignalNotesLayer("t", cawtest::Shape::Saw, "pat", {{"level", 0.4}});
    l.midiComponents = std::move(midi);
    ProjectSpec p = cawtest::testSignalProject({l});
    p.modules.push_back({"pat", "---\nkind: pattern\n---\n0 C3 8 0.9\n0 E3 8 0.8\n8 A2 8 0.9\n"});
    return p;
}
ComponentSpec spec(const char* id, Values v = {}) {
    ComponentSpec c;
    c.id = id;
    c.params = std::move(v);
    return c;
}
std::vector<float> render(Engine& e, int64_t frames, bool uneven) {
    static const int sizes[] = {37, 64, 1, 100, 13, 256, 7, 512};
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int64_t i = 0, k = 0; i < frames; ++k) {
        const int n = static_cast<int>(std::min<int64_t>(uneven ? sizes[k % 8] : 64, frames - i));
        e.process(l.data() + i, r.data() + i, n);
        i += n;
    }
    return l;
}
bool ok(const std::string& s) { return s.find("\"ok\":true") != std::string::npos; }
std::vector<ComponentSpec> arpChain() {
    return {spec("org.caw.midi.chords", {{"type", 1}}), spec("org.caw.midi.arp", {{"pattern", 2}, {"octaves", 2}}),
            spec("org.caw.midi.humanize", {{"timing", 8}})};
}
}  // namespace

TEST(midi_fx_chain_runs_before_the_instrument_live_and_offline_alike) {
    const int64_t frames = 96000;
    auto live = [&](bool uneven) {
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(ok(e.setProject(midiProject(arpChain()))));
        e.play();
        return render(e, frames, uneven);
    };
    const std::vector<float> a = live(false), b = live(true);
    Engine off(48000);
    off.setMasterBypass(true);
    CHECK(ok(off.setProjectOffline(midiProject(arpChain()))));
    off.play();
    CHECK(a == b);
    CHECK(a == render(off, frames, false));
    Engine plain(48000);
    plain.setMasterBypass(true);
    CHECK(ok(plain.setProject(midiProject({}))));
    plain.play();
    CHECK(render(plain, frames, false) != a);
    // A second Play sounds the same (seeded from the song, reset at Play).
    off.stop();
    render(off, 48000, false);  // stopped long enough that nothing rings into the next Play
    off.play();
    CHECK(a == render(off, frames, false));
    cawtest::References refs("midi_fx");
    CHECK_REFERENCE(refs, "chords_arp_humanize_saw", (cawtest::Audio{a, a}), cawtest::Class::Stable);
}

TEST(midi_fx_knobs_bypass_display_and_states_are_addressed_by_the_midi_flag) {
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(midiProject(arpChain()))));
    e.play();
    render(e, 4800, false);
    const uint32_t arp = Engine::kMidiComponentFlag | 1;
    CHECK(e.setComponentParam("t", arp, "rate", 5));
    CHECK(!e.setComponentParam("t", Engine::kMidiComponentFlag | 3, "rate", 5));  // no fourth MIDI effect
    CHECK(e.setComponentBypass("t", Engine::kMidiComponentFlag | 2, true));
    render(e, 4800, false);
    float d[64];
    CHECK(e.componentDisplay("t", arp, d, 64) > 3);
    const std::string states = e.componentStatesJson("t");
    CHECK(states.find(std::to_string(Engine::kMidiComponentFlag | 2)) != std::string::npos);
    // A MIDI effect is refused as an insert, and an effect as a MIDI effect.
    ProjectSpec bad = midiProject({spec("org.caw.utility")});
    CHECK(!ok(e.setProject(bad)));
    ProjectSpec bad2 = midiProject({});
    bad2.layers[0].components = {spec("org.caw.midi.arp")};
    CHECK(!ok(e.setProject(bad2)));
}

TEST(project_json_reads_midi_components_and_their_lanes) {
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"layers":[{"id":"t","instrument":"org.caw.synth.flagship",
        "midiComponents":[{"id":"org.caw.midi.scale"},{"id":"org.caw.midi.arp","params":{"rate":5}}]}],
        "automation":[{"target_type":"midiComponent","layer":"t","component":1,"target":"gate","points":[{"step":0,"value":0.2}]}]})",
                       p, error));
    CHECK_EQ(error, std::string());
    CHECK_EQ(p.layers.at(0).midiComponents.size(), 2u);
    CHECK_EQ(p.automation.at(0).targetType, std::string("instrument"));
    CHECK_EQ(p.automation.at(0).component, 2);
    // Older projects (no midiComponents) read as before.
    ProjectSpec q;
    CHECK(parseProject(R"({"caw_project":1,"layers":[{"id":"t","instrument":"org.caw.synth.flagship"}]})", q, error));
    CHECK(q.layers.at(0).midiComponents.empty());
}
