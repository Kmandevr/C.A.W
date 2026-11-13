// Per-note FX (#127 steps 4-6): slots equal solo renders, deterministic overflow and steals, tails, quality caps, refusals, JSON, parity.
#include <algorithm>
#include <cmath>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "builtin_components.h"
#include "builtin_test_signal.h"
#include "caw.h"
#include "caw/instrument.hpp"
#include "engine.h"
#include "note_fx_host.h"
#include "project.h"
#include "quality.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;
using cawtest::Shape;

namespace {

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

ComponentSpec component(const std::string& id, std::vector<std::pair<std::string, double>> params = {}) {
    ComponentSpec c;
    c.id = id;
    c.params = std::move(params);
    return c;
}

ModLinkSpec noteLink(uint32_t id, const std::string& source, const std::string& layer, int index, const std::string& param,
                     double amount) {
    ModLinkSpec l;
    l.id = id;
    l.source = source;
    l.target = {"noteComponent", layer, param, index};
    l.amount = amount;
    return l;
}

// A layer "t" playing the test signal (Notes mode) through the given per-note components.
ProjectSpec perNote(std::vector<ComponentSpec> noteComponents, int voices = 8, Shape shape = Shape::Saw,
                    const std::string& pattern = "") {
    LayerSpec l = cawtest::testSignalNotesLayer("t", shape, pattern, {{"level", 0.5}});
    l.noteComponents = std::move(noteComponents);
    l.noteVoices = voices;
    return cawtest::testSignalProject({l});
}

// The host driven directly: the manager's plan for slot 0, the test signal (or another instrument) as a processor,
// blocks of 64 frames. Each block's lanes are kept per note id (what that note's slot put out).
struct Harness {
    ModuleRegistry reg;
    NoteFxManager mgr;
    NoteFxHost* host = nullptr;
    std::unique_ptr<ModuleProcessor> inst;
    std::vector<ParameterValue> params;
    int quality = kQualityNormal;

    explicit Harness(const ProjectSpec& p, const std::string& instrument = std::string(kTestSignalId),
                     std::vector<std::pair<std::string, double>> values = {{"mode", 1.0}, {"shape", 1.0}, {"level", 0.5}}) {
        registerBuiltinComponents(reg);
        CHECK_EQ(mgr.prepare(reg, p, 48000.0), std::string());
        std::vector<std::string> warnings;
        mgr.commit(p, [](const std::string&) { return 0; }, nullptr, warnings);
        mgr.beginChunk();
        host = mgr.forSlot(0);
        CHECK(host != nullptr);
        inst = reg.create(instrument);
        CHECK(inst != nullptr);
        CHECK(inst->activate(48000.0, 64));
        const ModuleDescriptor& d = inst->descriptor();
        params.resize(d.parameterCount);
        for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            for (uint32_t k = 0; k < d.parameterCount; ++k)
                if (d.parameters[k].id == id) params[k].value = v;
    }

    struct Out {
        std::vector<float> mixL;
        std::map<uint32_t, std::vector<float>> lane;  // note id: its slot's left channel, frame by frame
        std::vector<std::vector<uint32_t>> laneIds;    // per block: the note id of each assigned slot lane (0 none)
        std::vector<uint32_t> restFlags;               // per block: the overflow lane's flags
    };

    std::vector<uint32_t> sizes = {64};
    Out render(const std::vector<Event>& events, uint32_t frames) {
        Out out;
        out.mixL.assign(frames, 0.0f);
        std::vector<float> l(64), r(64);
        float* ch[2] = {l.data(), r.data()};
        const ChannelBufferView audio{ch, 2, 64};
        size_t next = 0;
        size_t blockNo = 0;
        for (uint32_t start = 0, n = 0; start < frames; start += n) {
            n = std::min<uint32_t>(sizes[blockNo++ % sizes.size()], frames - start);
            std::vector<Event> in;
            while (next < events.size() && events[next].frame < start + n) {
                Event e = events[next++];
                e.frame -= start;
                in.push_back(e);
            }
            ChainTime time{start, 6000.0, 1, 120.0, 4, true};
            const VoiceBus* bus = host->begin(in.data(), static_cast<uint32_t>(in.size()), n, &time, nullptr, quality);
            const EventInput ev{in.data(), static_cast<uint32_t>(in.size())};
            ProcessBlock b;
            b.frames = n;
            b.audioOut = &audio;
            b.audioOutCount = 1;
            b.eventIn = &ev;
            b.eventInCount = 1;
            b.parameters = params.data();
            b.parameterCount = static_cast<uint32_t>(params.size());
            b.voices = bus;
            CHECK(inst->processPorts(b));
            std::vector<uint32_t> ids;
            if (bus) {
                for (uint32_t k = 0; k + 1 < bus->laneCount; ++k) {
                    const VoiceLane& lane = bus->lanes[k];
                    ids.push_back(lane.flags & kLaneAssigned ? lane.noteId : 0);
                    if (!(lane.flags & kLaneAssigned)) continue;
                    std::vector<float>& v = out.lane[lane.noteId];
                    v.resize(frames, 0.0f);
                    for (uint32_t i = 0; i < n; ++i) v[start + i] = lane.channels[0][i];
                }
                {
                    const VoiceLane& lane = bus->lanes[bus->laneCount - 1];
                    std::vector<float>& v = out.lane[0xFFFFFFFFu];
                    v.resize(frames, 0.0f);
                    if (lane.flags & kLaneAssigned) for (uint32_t i = 0; i < n; ++i) v[start + i] = lane.channels[0][i];
                }
                out.restFlags.push_back(bus->lanes[bus->laneCount - 1].flags);
            }
            out.laneIds.push_back(ids);
            host->end(n);
            for (uint32_t i = 0; i < n; ++i) out.mixL[start + i] = l[i];
        }
        return out;
    }
};

float peak(const std::vector<float>& v) {
    float p = 0;
    for (float x : v) p = std::max(p, std::fabs(x));
    return p;
}

}  // namespace

TEST(per_note_fx_each_slot_equals_a_solo_render_of_its_note) {
    // A low-pass per note, its cutoff following the note's pitch (bend included) and pressure.
    ProjectSpec p = perNote({component("org.caw.filter", {{"cutoff", 200.0}, {"resonance", 0.5}})});
    p.modulation = {noteLink(1, "note.pitch", "t", 0, "cutoff", 0.6), noteLink(2, "note.pressure", "t", 0, "cutoff", 0.3)};
    const std::vector<Event> a = {notes::noteOn(0, 1, 48.0, 0.9), notes::notePitch(700, 1, 48, 50.0),
                                  notes::notePitch(1500, 1, 48, 47.5), notes::noteOff(4000, 1, 48)};
    const std::vector<Event> b = {notes::noteOn(130, 2, 67.0, 0.6), notes::notePressure(300, 2, 67, 0.8),
                                  notes::notePitch(900, 2, 67, 66.0), notes::notePressure(2000, 2, 67, 0.1),
                                  notes::noteOff(3500, 2, 67)};
    std::vector<Event> both = a;
    both.insert(both.end(), b.begin(), b.end());
    std::stable_sort(both.begin(), both.end(), [](const Event& x, const Event& y) { return x.frame < y.frame; });
    Harness h(p), ha(p), hb(p);
    Harness::Out together = h.render(both, 4800);
    Harness::Out soloA = ha.render(a, 4800);
    Harness::Out soloB = hb.render(b, 4800);
    CHECK(together.lane.count(1) && together.lane.count(2));
    CHECK(together.lane[1] == soloA.lane[1]);
    CHECK(together.lane[2] == soloB.lane[2]);
    CHECK(peak(soloA.lane[1]) > 0.01f);
    CHECK(peak(soloB.lane[2]) > 0.01f);
    // Different notes, different filters: the two slots' outputs differ from each other.
    CHECK(together.lane[1] != together.lane[2]);
    // And the mix is the two slots summed (the instrument adds its lanes).
    double worst = 0;
    for (size_t i = 0; i < together.mixL.size(); ++i)
        worst = std::max(worst, std::fabs(static_cast<double>(together.mixL[i]) - soloA.mixL[i] - soloB.mixL[i]));
    CHECK(worst < 1e-6);
    // The pitch link moved the cutoff: without links the slot sounds different.
    ProjectSpec still = p;
    still.modulation.clear();
    Harness hs(still);
    CHECK(hs.render(a, 4800).lane[1] != soloA.lane[1]);
}

TEST(per_note_fx_overflow_and_steals_are_deterministic) {
    ProjectSpec p = perNote({component("org.caw.delay.pro", {{"mix", 0.4}})}, 2);
    // Three held notes for two voices: the third goes to overflow (held notes are never stolen). Then note 1 ends
    // (its slot rings on: a delay), and note 4 steals that ringing slot: it fades out while note 4 takes a spare.
    const std::vector<Event> ev = {notes::noteOn(0, 1, 60, 1), notes::noteOn(10, 2, 64, 1), notes::noteOn(20, 3, 67, 1),
                                   notes::noteOff(200, 1, 60), notes::noteOn(400, 4, 72, 1), notes::noteOff(1500, 2, 64),
                                   notes::noteOff(1500, 3, 67), notes::noteOff(1500, 4, 72)};
    Harness h(p);
    Harness::Out first = h.render(ev, 4800);
    CHECK_EQ(first.laneIds[0][0], 1u);
    CHECK_EQ(first.laneIds[0][1], 2u);
    CHECK_EQ(first.laneIds[0][2], 0u);
    CHECK(first.restFlags[0] & kLaneRest);  // note 3 plays in the overflow lane
    CHECK(first.restFlags[0] & kLaneAssigned);
    // Block 6 (frames 384..447) holds note 4: slot 0 (note 1, ended) is leaving, note 4 takes slot 2.
    CHECK_EQ(first.laneIds[6][0], 1u);
    CHECK_EQ(first.laneIds[6][2], 4u);
    const NoteFxStats s = h.host->stats();
    CHECK_EQ(s.overflowed, 1u);
    CHECK_EQ(s.stolen, 1u);
    CHECK_EQ(s.budget, 2u);
    // The same notes again give the same slots and the same sound.
    Harness again(p);
    const Harness::Out second = again.render(ev, 4800);
    CHECK(second.laneIds == first.laneIds);
    CHECK(second.mixL == first.mixL);
    CHECK(peak(first.lane[3]) == 0.0f);  // note 3 never had a slot
}

TEST(per_note_fx_a_released_note_crossfades_into_overflow_when_stolen) {
    // The Flagship lets a note ring through its release, so a new note over budget takes that released note's slot.
    ProjectSpec p = perNote({component("org.caw.utility")}, 1);
    p.layers[0].instrument = component("org.caw.synth.flagship");
    const std::vector<Event> ev = {notes::noteOn(0, 1, 60, 1), notes::noteOff(100, 1, 60), notes::noteOn(200, 2, 64, 1)};
    Harness h(p, "org.caw.synth.flagship", {{"env1_release", 2.0}});
    const Harness::Out out = h.render(ev, 2400);
    CHECK_EQ(out.laneIds[3][0], 1u);  // note 1 still in slot 0, fading out
    CHECK_EQ(out.laneIds[3][1], 2u);  // note 2 on a spare chain
    CHECK(out.restFlags[3] & kLaneAssigned);  // note 1's sound moves into the overflow chain
    CHECK_EQ(h.host->stats().stolen, 1u);
    CHECK(peak(out.mixL) > 0.0f);
}

TEST(per_note_fx_slots_ring_out_their_tails_then_free) {
    ProjectSpec p = perNote({component("org.caw.delay.pro")}, 4);
    Harness h(p);
    const std::vector<Event> ev = {notes::noteOn(0, 1, 60, 1), notes::noteOff(480, 1, 60)};
    Harness::Out out = h.render(ev, 4800);
    CHECK_EQ(h.host->stats().active, 1u);  // ended, ringing (an endless tail is capped at 2 s)
    out = h.render({}, 48000 * 2 + 4800);
    CHECK_EQ(h.host->stats().active, 0u);
    CHECK_EQ(h.host->stats().activeMask, 0u);
}

TEST(per_note_fx_quality_caps_the_live_budget) {
    CHECK_EQ(noteFxBudget(8, kQualityEco), 4);
    CHECK_EQ(noteFxBudget(8, kQualityNormal), 8);
    CHECK_EQ(noteFxBudget(16, kQualityHigh), 16);
    CHECK_EQ(noteFxBudget(2, kQualityEco), 2);
    CHECK_EQ(noteFxBudget(40, kQualityHigh), 16);
    CHECK_EQ(noteFxSlots(8), 10);
    ProjectSpec p = perNote({component("org.caw.utility")}, 8);
    Harness h(p);
    h.quality = kQualityEco;
    std::vector<Event> ev;
    for (uint32_t k = 1; k <= 6; ++k) ev.push_back(notes::noteOn(k, k, 50.0 + k, 1));
    h.render(ev, 256);
    const NoteFxStats s = h.host->stats();
    CHECK_EQ(s.budget, 4u);
    CHECK_EQ(s.active, 4u);
    CHECK_EQ(s.overflowed, 2u);
    CHECK_EQ(s.voices, 8u);
}

TEST(per_note_fx_refuses_an_instrument_without_a_voice_bus_and_effects_that_cant_run_per_note) {
    Engine e(48000);
    ProjectSpec p = perNote({component("org.caw.utility")});
    p.layers[0].instrument = component("org.caw.sampler");
    std::string r = e.setProject(p);
    CHECK(!ok(r));
    CHECK(r.find("voice bus") != std::string::npos);
    ProjectSpec q = perNote({component("org.caw.limiter")});
    r = e.setProject(q);
    CHECK(!ok(r));
    CHECK(r.find("can't run per note") != std::string::npos);
    ProjectSpec noInstrument = perNote({component("org.caw.utility")});
    noInstrument.layers[0].hasInstrument = false;
    r = e.setProject(noInstrument);
    CHECK(!ok(r));
    ModuleRegistry reg;
    registerBuiltinComponents(reg);
    std::string why;
    CHECK(!ComponentChain::runsPerNote(*reg.find("org.caw.ducker"), &why));
    CHECK(!why.empty());
    CHECK(ComponentChain::runsPerNote(*reg.find("org.caw.filter")));
    CHECK(ok(e.setProject(perNote({component("org.caw.filter")}))));
}

TEST(project_json_reads_note_components_voices_and_note_links) {
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"layers":[{"id":"t","instrument":"org.caw.synth.flagship",
        "noteComponents":[{"id":"org.caw.filter","params":{"cutoff":800}}],"noteVoices":5,"components":["org.caw.utility"]}],
        "automation":[{"target_type":"noteComponent","layer":"t","component":0,"target":"cutoff","points":[{"step":0,"value":300}]}],
        "modulation":[{"id":1,"source":"note.pitch","target":{"type":"noteComponent","layer":"t","index":0,"param":"cutoff"},"amount":0.5}]})",
                       p, error));
    CHECK_EQ(error, std::string());
    CHECK_EQ(p.layers.size(), 1u);
    CHECK_EQ(p.layers[0].noteComponents.size(), 1u);
    CHECK_EQ(p.layers[0].noteVoices, 5);
    CHECK_EQ(p.automation.size(), 1u);
    CHECK_EQ(p.automation[0].targetType, std::string("noteComponent"));
    CHECK_EQ(p.modulation.size(), 1u);
    for (const char* bad : {R"("noteVoices":0)", R"("noteVoices":17)", R"("noteVoices":2.5)"}) {
        ProjectSpec q;
        CHECK(!parseProject(std::string(R"({"caw_project":1,"layers":[{"id":"t",)") + bad + "}]}", q, error));
    }
    // A note source only moves a per-note component.
    ProjectSpec q;
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t"}],"modulation":[{"id":1,"source":"note.velocity",
        "target":{"type":"component","layer":"t","index":0,"param":"gain"},"amount":0.5}]})", q, error));
    CHECK(error.find("noteComponent") != std::string::npos);
}

namespace {
std::vector<float> renderEngine(Engine& e, int64_t frames, bool uneven) {
    static const int sizes[] = {37, 64, 1, 100, 13, 256, 7, 512};
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int64_t i = 0, k = 0; i < frames; ++k) {
        const int n = static_cast<int>(std::min<int64_t>(uneven ? sizes[k % 8] : 64, frames - i));
        e.process(l.data() + i, r.data() + i, n);
        i += n;
    }
    return l;
}

ProjectSpec expressiveProject(bool perNoteOn) {
    ProjectSpec p = perNote({component("org.caw.filter", {{"cutoff", 300.0}, {"resonance", 0.6}}),
                             component("org.caw.delay.pro", {{"mix", 0.3}})},
                            2, Shape::Saw, "pat");
    p.modules.push_back({"pat", "---\nkind: pattern\n---\n0 C3 3 1 bend 0:0 1:2\n1 G3 2 0.7 press 0:0 1:1\n"
                                "2 E4 2 0.8\n4 C4 4 0.6 bend 0:0 0.5:-1 1:1\n"});
    p.modulation = {noteLink(1, "note.pitch", "t", 0, "cutoff", 0.5), noteLink(2, "note.pressure", "t", 0, "resonance", 0.3),
                    noteLink(3, "note.age", "t", 0, "cutoff", -0.2)};
    if (!perNoteOn) {
        p.layers[0].noteComponents.clear();
        p.modulation.clear();
    }
    return p;
}
}  // namespace

TEST(per_note_fx_live_and_offline_renders_are_bit_identical) {
    const int64_t frames = 48000;
    auto live = [&](bool uneven) {
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(ok(e.setProject(expressiveProject(true))));
        e.play();
        return renderEngine(e, frames, uneven);
    };
    const std::vector<float> a = live(false);
    const std::vector<float> b = live(true);
    Engine off(48000);
    off.setMasterBypass(true);
    CHECK(ok(off.setProjectOffline(expressiveProject(true))));
    off.play();
    const std::vector<float> c = renderEngine(off, frames, false);
    CHECK(peak(a) > 0.01f);
    CHECK(a == b);
    CHECK(a == c);
    // Per-note FX change the sound (the same project without them differs).
    Engine plain(48000);
    plain.setMasterBypass(true);
    CHECK(ok(plain.setProject(expressiveProject(false))));
    plain.play();
    CHECK(renderEngine(plain, frames, false) != a);
}

TEST(per_note_fx_knobs_fan_out_and_the_stats_and_latency_report) {
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(expressiveProject(true))));
    e.play();
    renderEngine(e, 4800, false);
    CHECK(e.setComponentParam("t", Engine::kNoteComponentFlag | 0u, "cutoff", 5000.0));
    CHECK(!e.setComponentParam("t", Engine::kNoteComponentFlag | 5u, "cutoff", 5000.0));
    CHECK(e.setComponentBypass("t", Engine::kNoteComponentFlag | 1u, true));
    renderEngine(e, 4800, false);
    NoteFxStats s;
    CHECK(e.noteFxStats("t", s));
    CHECK_EQ(s.voices, 2u);
    CHECK_EQ(s.budget, 2u);
    CHECK(!e.noteFxStats("nope", s));
    // A project update that keeps the components keeps the rack (and takes the new values).
    ProjectSpec p = expressiveProject(true);
    p.layers[0].noteComponents[0].params = {{"cutoff", 900.0}};
    CHECK(ok(e.setProject(p)));
    renderEngine(e, 4800, false);
    // Turning per-note FX off crossfades back to the plain instrument.
    CHECK(ok(e.setProject(expressiveProject(false))));
    const std::vector<float> after = renderEngine(e, 4800, false);
    for (float x : after) CHECK(std::isfinite(x));
}

TEST(per_note_fx_host_gives_the_same_bits_at_any_block_split) {
    // Notes over budget, ends, a steal and an overflowed note, in 64-frame blocks and in uneven ones.
    ProjectSpec p = perNote({component("org.caw.filter", {{"cutoff", 300.0}, {"resonance", 0.6}}),
                             component("org.caw.delay.pro", {{"mix", 0.3}})}, 2);
    p.modulation = {noteLink(1, "note.age", "t", 0, "cutoff", 0.4)};
    const std::vector<Event> ev = {notes::noteOn(0, 1, 48, 1), notes::noteOn(6000, 2, 55, 0.7), notes::noteOn(12000, 3, 64, 0.8),
        notes::noteOff(18000, 1, 48), notes::noteOff(18000, 2, 55), notes::noteOn(24000, 4, 60, 0.6), notes::noteOff(24000, 3, 64),
        notes::noteOff(27000, 4, 60)};
    Harness a(p), b(p);
    b.sizes = {37, 64, 1, 63, 13, 64, 7, 50};
    Harness::Out x = a.render(ev, 30000), y = b.render(ev, 30000);
    CHECK(x.mixL == y.mixL);
    for (auto& [id, v] : x.lane) CHECK(v == y.lane[id]);
    CHECK(peak(x.mixL) > 0.01f);
}

TEST(per_note_fx_c_api_reports_stats_size_tagged) {
    CHECK_EQ(caw_api_version(), 28);
    CawEngine* engine = caw_engine_create(48000);
    char* r = caw_engine_set_project(engine, R"({"caw_project":1,"layers":[{"id":"t","instrument":{"id":"org.caw.test.osc",
        "params":{"mode":1}},"noteComponents":["org.caw.filter"],"noteVoices":3}]})");
    CHECK(ok(r));
    caw_free(r);
    CawNoteFxStats s{};
    s.struct_size = sizeof s;
    CHECK_EQ(caw_engine_note_fx_stats(engine, "t", &s), 1);
    CHECK_EQ(s.voices, 3u);
    CHECK_EQ(s.active, 0u);
    // An older, shorter struct gets only the fields it has.
    uint32_t small[3] = {3 * sizeof(uint32_t), 99, 99};
    CHECK_EQ(caw_engine_note_fx_stats(engine, "t", reinterpret_cast<CawNoteFxStats*>(small)), 1);
    CHECK_EQ(small[1], 3u);
    CHECK_EQ(small[2], 3u);
    CHECK_EQ(caw_engine_note_fx_stats(engine, "none", &s), 0);
    CHECK_EQ(caw_engine_set_component_param(engine, "t", CAW_NOTE_COMPONENT | 0u, "cutoff", 800.0), 1);
    caw_engine_destroy(engine);
}
