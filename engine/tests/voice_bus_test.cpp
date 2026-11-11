// The voice bus (#127 steps 1-3): lanes, ENDED, the sum before the shared stage, and bit-identical output without it.
#include <algorithm>
#include <cmath>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "builtin_test_signal.h"
#include "caw/instrument.hpp"
#include "engine.h"
#include "test.h"

using namespace caw;

namespace {

using Values = std::vector<std::pair<std::string, double>>;

// A stand-in for the per-note FX host (step 4's NoteFxHost): fixed lanes with their own buffers, and a run()
// that applies one gain per lane in place. It checks that every frame of a block goes through exactly one run(),
// in order, and records each block's lane flags.
struct LaneHost {
    static constexpr uint32_t kFrames = 512;
    struct Slot {
        uint32_t noteId = 0;  // 0: not assigned
        float gain = 1.0f;
        std::vector<float> l = std::vector<float>(kFrames), r = std::vector<float>(kFrames);
    };
    std::vector<Slot> slots;
    std::vector<VoiceLane> lanes;
    VoiceBus bus;
    uint32_t covered = 0;  // frames run() has seen this block
    bool inOrder = true;
    std::vector<uint32_t> ended, written;  // note ids, every block, in order

    explicit LaneHost(uint32_t count) : slots(count), lanes(count) {
        bus.laneCount = count;
        bus.lanes = lanes.data();
        bus.hostData = this;
        bus.run = &run;
    }
    void assign(uint32_t slot, uint32_t noteId, float gain = 1.0f) {
        slots[slot].noteId = noteId;
        slots[slot].gain = gain;
    }
    void beginBlock() {
        covered = 0;
        for (size_t k = 0; k < slots.size(); ++k) {
            VoiceLane& lane = lanes[k];
            lane = VoiceLane{};
            lane.noteId = slots[k].noteId;
            lane.flags = slots[k].noteId ? kLaneAssigned : 0u;
            lane.channels[0] = slots[k].l.data();
            lane.channels[1] = slots[k].r.data();
        }
    }
    void endBlock(uint32_t frames) {
        if (covered != frames) inOrder = false;
        for (const VoiceLane& lane : lanes) {
            if (lane.flags & kLaneEnded) ended.push_back(lane.noteId);
            if (lane.flags & kLaneWritten) written.push_back(lane.noteId);
        }
    }
    static void run(void* data, uint32_t offset, uint32_t frames) {
        LaneHost& h = *static_cast<LaneHost*>(data);
        if (offset != h.covered) h.inOrder = false;
        h.covered = offset + frames;
        for (const Slot& s : h.slots) {
            if (!s.noteId) continue;
            float* l = const_cast<float*>(s.l.data());
            float* r = const_cast<float*>(s.r.data());
            for (uint32_t i = offset; i < offset + frames; ++i) l[i] *= s.gain, r[i] *= s.gain;
        }
    }
    bool saw(const std::vector<uint32_t>& list, uint32_t id) const {
        return std::find(list.begin(), list.end(), id) != list.end();
    }
};

struct Stereo {
    std::vector<float> left, right;
};

std::unique_ptr<ModuleProcessor> make(std::string_view id) {
    static Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(std::string(id));
    CHECK(p != nullptr);
    if (p) CHECK(p->activate(48000, LaneHost::kFrames));
    return p;
}

// Plays `events` in `block`-frame blocks with `values` (by id) over the defaults, through `host`'s lanes when set.
Stereo play(ModuleProcessor& p, const std::vector<Event>& events, uint32_t frames, const Values& values,
            LaneHost* host = nullptr, uint32_t block = 128) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    for (const auto& [id, v] : values) {
        bool found = false;
        for (uint32_t k = 0; k < d.parameterCount; ++k)
            if (d.parameters[k].id == id) params[k].value = v, found = true;
        CHECK(found);
    }
    Stereo out{std::vector<float>(frames), std::vector<float>(frames)};
    std::vector<float> l(block), r(block);
    float* channels[2] = {l.data(), r.data()};
    const ChannelBufferView audio{channels, 2, block};
    size_t next = 0;
    for (uint32_t start = 0; start < frames; start += block) {
        const uint32_t n = std::min(block, frames - start);
        std::vector<Event> in;
        while (next < events.size() && events[next].frame < start + n) {
            Event e = events[next++];
            e.frame -= start;
            in.push_back(e);
        }
        const EventInput ev{in.data(), static_cast<uint32_t>(in.size())};
        ProcessBlock b;
        b.frames = n;
        b.audioOut = &audio;
        b.audioOutCount = 1;
        b.eventIn = &ev;
        b.eventInCount = 1;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        if (host) {
            host->beginBlock();
            b.voices = &host->bus;
        }
        CHECK(p.processPorts(b));
        if (host) host->endBlock(n);
        for (uint32_t i = 0; i < n; ++i) out.left[start + i] = l[i], out.right[start + i] = r[i];
    }
    return out;
}

bool same(const Stereo& a, const Stereo& b) { return a.left == b.left && a.right == b.right; }
double maxDiff(const Stereo& a, const Stereo& b) {
    double m = 0;
    for (size_t i = 0; i < a.left.size(); ++i)
        m = std::max({m, std::fabs(double(a.left[i]) - b.left[i]), std::fabs(double(a.right[i]) - b.right[i])});
    return m;
}
double peak(const Stereo& a) {
    double m = 0;
    for (size_t i = 0; i < a.left.size(); ++i) m = std::max({m, std::fabs(double(a.left[i])), std::fabs(double(a.right[i]))});
    return m;
}

const Values kTestNotes = {{"mode", 1}, {"shape", 1}};  // the test signal's Notes mode, a saw

}  // namespace

TEST(voice_bus_test_signal_lanes_carry_each_note_through_the_host) {
    auto p = make(kTestSignalId);
    if (!p) return;
    const std::vector<Event> two = {notes::noteOn(0, 1, 60, 1.0), notes::noteOn(40, 2, 67, 0.5)};
    const Stereo plain = play(*p, two, 1024, kTestNotes);
    p->reset();
    const Stereo solo1 = play(*p, {two[0]}, 1024, kTestNotes);
    p->reset();
    const Stereo solo2 = play(*p, {two[1]}, 1024, kTestNotes);
    p->reset();
    // Lanes for notes that do not play change nothing; no bus at all is the same output.
    LaneHost others(2);
    others.assign(0, 7);
    others.assign(1, 8);
    CHECK(same(play(*p, two, 1024, kTestNotes, &others), plain));
    CHECK(others.inOrder);
    CHECK(others.saw(others.ended, 7) && !others.saw(others.written, 7));
    p->reset();
    // A gain per lane: the mix is each note's solo render times its lane's gain, summed in lane order.
    LaneHost host(2);
    host.assign(0, 1, 0.5f);
    host.assign(1, 2, 2.0f);
    const Stereo laned = play(*p, two, 1024, kTestNotes, &host);
    CHECK(host.inOrder);
    for (size_t i = 0; i < 1024; ++i) {
        CHECK_EQ(laned.left[i], (0.0f + solo1.left[i] * 0.5f) + solo2.left[i] * 2.0f);
        CHECK_EQ(laned.right[i], (0.0f + solo1.right[i] * 0.5f) + solo2.right[i] * 2.0f);
    }
    CHECK(host.saw(host.written, 1) && host.saw(host.written, 2));
    CHECK(host.ended.empty());  // both notes still sound
    // One lane: the other note plays in the mix as before.
    p->reset();
    LaneHost one(1);
    one.assign(0, 2, 0.0f);
    const Stereo muted = play(*p, two, 1024, kTestNotes, &one);
    CHECK(same(muted, solo1));
}

TEST(voice_bus_ends_a_lane_when_its_note_stops) {
    auto p = make(kTestSignalId);
    if (!p) return;
    LaneHost host(1);
    host.assign(0, 5);
    // The test signal cuts a note on its off (frame 300, in the third 128-frame block).
    play(*p, {notes::noteOn(0, 5, 60, 1.0), notes::noteOff(300, 5, 60)}, 512, kTestNotes, &host);
    CHECK_EQ(host.ended.size(), 2u);  // the blocks at 256 and 384: no voice plays note 5 at their end
    CHECK(host.saw(host.written, 5));
    CHECK(host.inOrder);
}

namespace {
struct PoolVoice {
    bool active = false, held = false;
    uint32_t noteId = 0;
    uint64_t age = 0;
};
}  // namespace

TEST(voice_bus_voice_pool_steal_ends_the_old_notes_lane) {
    LaneHost host(3);
    host.assign(0, 1);
    host.assign(1, 2);
    host.assign(2, 3);
    host.beginBlock();
    ProcessBlock b;
    b.voices = &host.bus;
    VoiceLanes lanes;
    lanes.bind(b);
    CHECK_EQ(lanes.count(), 3u);
    VoicePool<PoolVoice, 2> pool;
    pool.start(1, &lanes);
    pool.start(2, &lanes);
    CHECK((host.lanes[0].flags & kLaneEnded) == 0);
    pool.start(3, &lanes);  // the pool is full: note 1's voice (the oldest held) is stolen
    CHECK((host.lanes[0].flags & kLaneEnded) != 0);
    CHECK((host.lanes[1].flags & kLaneEnded) == 0);
    // Without lanes the pool steals as before.
    pool.start(4);
    CHECK(pool.find(4) != nullptr && pool.find(2) == nullptr);
    // A lane the host did not assign, or with too few channels, is skipped.
    host.slots[1].noteId = 0;
    host.beginBlock();
    host.lanes[2].channelCount = 1;
    lanes.bind(b);
    CHECK_EQ(lanes.count(), 1u);
    CHECK(lanes.laneFor(2) == nullptr && lanes.laneFor(3) == nullptr && lanes.laneFor(1) != nullptr);
    // A bus without run() is no bus.
    host.bus.run = nullptr;
    lanes.bind(b);
    CHECK(!lanes.any());
}

TEST(voice_bus_flagship_sums_lanes_before_its_shared_stage) {
    auto p = make("org.caw.synth.flagship");
    if (!p) return;
    const std::vector<Event> chord = {notes::noteOn(0, 1, 57, 1.0), notes::noteOn(0, 2, 64, 0.8),
                                      notes::noteOff(6000, 1, 57), notes::noteOff(6000, 2, 64)};
    const uint32_t frames = 96000;
    const Stereo plain = play(*p, chord, frames, {});
    CHECK(peak(plain) > 1e-3);
    p->reset();
    // Lanes for other notes: the same bits (the lane path adds +0 to the voices' sum).
    LaneHost others(2);
    others.assign(0, 90);
    others.assign(1, 91);
    CHECK(same(play(*p, chord, frames, {}, &others), plain));
    CHECK(others.inOrder);
    p->reset();
    // Both notes in lanes at unity: the same sound (a laned voice runs its own filter 1, not the shared one, and the
    // sum's order changes, so equal to rounding), through the instrument's effects and volume as before.
    LaneHost unity(2);
    unity.assign(0, 1);
    unity.assign(1, 2);
    const Stereo laned = play(*p, chord, frames, {}, &unity);
    CHECK(unity.inOrder);
    CHECK(maxDiff(laned, plain) < 1e-4 * std::max(1.0, peak(plain)));
    CHECK(unity.saw(unity.written, 1) && unity.saw(unity.written, 2));
    CHECK(unity.saw(unity.ended, 1) && unity.saw(unity.ended, 2));  // released, then silent
    p->reset();
    // Note 1's lane at gain 0: what is left is note 2 alone, through the shared stage (reverb and all). The start
    // phases are not random here, so note 2 starts the same as the first note of a render or the second.
    const Values fixed = {{"osc1_phase_rand", 0}, {"osc2_phase_rand", 0}, {"osc3_phase_rand", 0}};
    const Stereo solo2 = play(*p, {chord[1], chord[3]}, frames, fixed);
    p->reset();
    LaneHost mute(2);
    mute.assign(0, 1, 0.0f);
    mute.assign(1, 2);
    const Stereo onlyTwo = play(*p, chord, frames, fixed, &mute);
    CHECK(maxDiff(onlyTwo, solo2) < 1e-4 * std::max(1.0, peak(solo2)));
    // The lanes run on through the tail and the instrument stays awake while the host has one assigned.
    CHECK(!p->quiet());
}

TEST(voice_bus_flagship_mono_lane_follows_the_newest_note) {
    auto p = make("org.caw.synth.flagship");
    if (!p) return;
    LaneHost host(2);
    host.assign(0, 1);
    host.assign(1, 2);
    // Legato: note 2 takes over the one voice at frame 2000; note 1's lane ends while note 2's is written.
    play(*p, {notes::noteOn(0, 1, 57, 1.0), notes::noteOn(2000, 2, 60, 1.0)}, 4096, {{"voice_mode", 2}}, &host);
    CHECK(host.saw(host.written, 1) && host.saw(host.written, 2));
    // Note 2's lane ends only in the 15 blocks before its note starts (frames 0-1919); note 1's from frame 2048 on.
    CHECK_EQ(std::count(host.ended.begin(), host.ended.end(), 2u), 15);
    CHECK(host.saw(host.ended, 1) && host.ended.back() == 1u);
}

TEST(voice_bus_drums_one_lane_per_hit) {
    auto p = make("org.caw.drums");
    if (!p) return;
    const std::vector<Event> hits = {notes::noteOn(0, 1, 36, 1.0), notes::noteOn(1000, 2, 38, 1.0)};
    const uint32_t frames = 144000;
    const Stereo plain = play(*p, hits, frames, {});
    CHECK(peak(plain) > 1e-3);
    p->reset();
    LaneHost others(2);
    others.assign(0, 50);
    others.assign(1, 51);
    CHECK(same(play(*p, hits, frames, {}, &others), plain));
    CHECK(others.inOrder);
    p->reset();
    // Each hit in its own lane at unity: the same sound to rounding.
    LaneHost unity(2);
    unity.assign(0, 1);
    unity.assign(1, 2);
    const Stereo laned = play(*p, hits, frames, {}, &unity);
    CHECK(maxDiff(laned, plain) < 1e-5 * std::max(1.0, peak(plain)));
    CHECK(unity.saw(unity.written, 1) && unity.saw(unity.written, 2));
    CHECK(unity.saw(unity.ended, 1) && unity.saw(unity.ended, 2));  // each hit dies away within the second
    p->reset();
    // The first hit's lane at gain 0: its sound is gone from the output, the second hit's left.
    LaneHost mute(2);
    mute.assign(0, 1, 0.0f);
    const Stereo second = play(*p, hits, frames, {}, &mute);
    for (uint32_t i = 0; i < 1000; ++i) CHECK_EQ(second.left[i], 0.0f);
    p->reset();
    const Stereo alone = play(*p, {hits[1]}, frames, {});
    CHECK(maxDiff(second, alone) < 1e-5 * std::max(1.0, peak(alone)));
}

TEST(builtin_descriptors_declare_domains_capabilities_and_cost) {
    ModuleRegistry r;
    registerBuiltinComponents(r);
    Engine e(48000);
    auto domains = [&](std::string_view id) {
        const ModuleDescriptor* d = r.find(id);
        CHECK(d != nullptr);
        return d ? d->domains : 0u;
    };
    const uint32_t perNote = kDomainWhole | kDomainPerNote;
    for (const char* id : {"org.caw.eq", "org.caw.reverb.pro", "org.caw.utility", "org.caw.stereo.width", "org.caw.delay.pingpong",
                           "org.caw.filter", "org.caw.chorus", "org.caw.bitcrush"})
        CHECK_EQ(domains(id), perNote);
    for (const char* id : {"org.caw.limiter", "org.caw.compressor", "org.caw.gate", "org.caw.ducker", "org.caw.ringmod",
                           "org.caw.downmix"})
        CHECK_EQ(domains(id), kDomainWhole);
    for (std::string_view id : {std::string_view("org.caw.synth.flagship"), std::string_view("org.caw.drums"), kTestSignalId}) {
        CHECK_EQ(domains(id), perNote);
        CHECK((r.find(id)->capabilities & kCapabilityNotesIn) != 0);
    }
    CHECK(r.find("org.caw.reverb.pro")->cpuClass == CpuClass::Heavy);
    CHECK(r.find("org.caw.utility")->cpuClass == CpuClass::Light);
    // Every built-in is valid with its declarations (the registry refuses one that is not), and the listing names them.
    for (const ModuleDescriptor* d : r.builtinComponents()) CHECK(validateModuleDescriptor(*d) == ModuleValidation::Ok);
    const std::string json = e.nativeComponentsJson();
    CHECK(json.find("\"id\":\"org.caw.limiter\"") != std::string::npos);
    CHECK(json.find("\"domains\":[\"whole\",\"per_note\"],\"capabilities\":[],\"cpu_class\":\"heavy\"") != std::string::npos);
    CHECK(json.find("\"domains\":[\"whole\",\"per_note\"],\"capabilities\":[\"notes_in\",\"midi_in\"],\"cpu_class\":\"heavy\"") !=
          std::string::npos);  // the flagship
}

#ifdef CAW_TEST_V30_COMPONENT_PATH
TEST(voice_bus_c_components_old_and_new_abi_revisions) {
    ModuleRegistry registry;
    // Built against 3.0: its descriptor ends at custom_ui_id, so it loads whole-only (the junk past its struct is
    // never read), and processes as before.
    const ModuleLoadResult old = registry.loadSharedLibrary(CAW_TEST_V30_COMPONENT_PATH, "org.caw.test.v30", NativeModuleTrust::Trusted);
    CHECK(old.success);
    const ModuleDescriptor* d = registry.find("org.caw.test.v30");
    CHECK(d != nullptr);
    if (d) CHECK(d->domains == kDomainWhole && d->capabilities == 0 && d->cpuClass == CpuClass::Unspecified);
    std::unique_ptr<ModuleProcessor> half = registry.create("org.caw.test.v30");
    CHECK(half != nullptr);
    if (half) {
        CHECK(half->activate(48000, 64));
        float l[64], r[64], ol[64], orr[64];
        for (int i = 0; i < 64; ++i) l[i] = r[i] = 1.0f;
        const float* in[2] = {l, r};
        float* out[2] = {ol, orr};
        AudioProcessBlock b;
        b.input = {in, 2, 64};
        b.output = {out, 2, 64};
        b.frames = 64;
        CHECK(half->process(b));
        CHECK(ol[10] == 0.5f && orr[63] == 0.5f);
    }
    // Built against 3.1: it reads the domains and the voice bus through ComponentProcessor.
    CHECK(registry.loadSharedLibrary(CAW_TEST_V30_COMPONENT_PATH, "org.caw.test.lanes", NativeModuleTrust::Trusted).success);
    const ModuleDescriptor* lanes = registry.find("org.caw.test.lanes");
    CHECK(lanes != nullptr);
    if (!lanes) return;
    CHECK(lanes->domains == (kDomainWhole | kDomainPerNote) && lanes->capabilities == kCapabilityNotesIn &&
          lanes->cpuClass == CpuClass::Light);
    std::unique_ptr<ModuleProcessor> p = registry.create("org.caw.test.lanes");
    CHECK(p != nullptr);
    if (!p) return;
    CHECK(p->activate(48000, LaneHost::kFrames));
    const Stereo dry = play(*p, {}, 256, {});
    CHECK(dry.left[0] == 0.25f && dry.right[255] == 0.25f);
    LaneHost host(2);
    host.assign(0, 3, 2.0f);
    host.assign(1, 4, 4.0f);
    const Stereo wet = play(*p, {}, 256, {}, &host);
    CHECK(wet.left[0] == 1.5f && wet.right[255] == 1.5f);  // 0.25 x 2 + 0.25 x 4
    CHECK(host.inOrder && host.saw(host.written, 3) && host.saw(host.written, 4));
}
#endif
