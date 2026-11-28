// Play-ahead (play_ahead.h, engine_ahead.cpp): ahead renders match live bit for bit at any buffer, underruns fade and
// stay live, a drain mid-note, a seek's drop and a parked edit at the ring's end each equal the live render; the app's
// intent (API 50) brings a track live before its edit.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "caw.h"
#include "engine.h"
#include "engine_test_harness.h"
#include "project.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;
using namespace engine_test;

namespace {

// `caw_tests --play-ahead N` (test_main.cpp): every Engine made from then on renders its untouched tracks ahead, its
// rings filled on the callback N frames past each chunk (caw_play_ahead_identity compares every reference render).
const bool kHookSet = (cawtest::playAheadHook = [](int extra) { Engine::setPlayAheadForTest(extra); }, true);

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

// Sets the test play-ahead for the Engines made in its scope, and puts back what the run had.
struct AheadScope {
    int was;
    explicit AheadScope(int extra) : was(Engine::playAheadForTest()) { Engine::setPlayAheadForTest(extra); }
    ~AheadScope() { Engine::setPlayAheadForTest(was); }
};

ComponentSpec comp(const std::string& id, std::vector<std::pair<std::string, double>> params = {}) {
    ComponentSpec c;
    c.id = id;
    c.params = std::move(params);
    return c;
}

// The owner's case in small: a Flagship (Kestrel) pad with six inserts, its cutoff automated, beside a drum track
// (live) and a plain test-signal track; patterns of different lengths, so chunks are cut at both.
ProjectSpec heavyProject() {
    ProjectSpec p = cawtest::testSignalProject({}, 128, 2);
    p.modules.push_back({"pad", "---\nkind: pattern\nlength: 12\n---\n0 C3 3.5 0.9\n0 G3 3.5 0.8\n4.3 D#3 2 0.7\n7.1 A#3 4.4 1\n"});
    p.modules.push_back({"beat", "---\nkind: pattern\nlength: 16\n---\n0 C2 1 1\n4 D2 1 0.8\n8 C2 1 1\n12 D2 1 0.8\n"});
    LayerSpec pad;
    pad.id = pad.name = "pad";
    pad.hasInstrument = true;
    pad.pattern = "pad";
    pad.volume = 0.8;
    pad.instrument = comp("org.caw.synth.flagship", {{"osc1_unison", 3}, {"env1_release", 0.6}});
    pad.components = {comp("org.caw.drive"), comp("org.caw.eq"), comp("org.caw.compressor"), comp("org.caw.tremolo"),
                      comp("org.caw.delay.pingpong"), comp("org.caw.limiter")};
    p.layers.push_back(pad);
    LayerSpec drums;
    drums.id = drums.name = "drums";
    drums.hasInstrument = true;
    drums.pattern = "beat";
    drums.instrument = comp("org.caw.drums");
    p.layers.push_back(drums);
    p.layers.push_back(cawtest::testSignalNotesLayer("sig", cawtest::Shape::Saw, "beat", {{"level", 0.3}}));
    ProjectAutomationLaneSpec lane;
    lane.targetType = "instrument";
    lane.target = "flt1_cutoff";
    lane.moduleId = "pad";
    lane.points = {{0.0, 400.0}, {20.0, 6000.0}, {32.0, 900.0}};
    p.automation.push_back(lane);
    return p;
}

std::vector<float> render(const ProjectSpec& p, int extra, int64_t frames, int block, Engine::AheadStats* stats = nullptr,
                          std::vector<float>* right = nullptr) {
    AheadScope scope(extra);
    Engine e(48000);
    if (!ok(e.setProject(p))) {
        cawtest::fail(__FILE__, __LINE__, "setProject failed");
        return {};
    }
    e.play();
    std::vector<float> out = run(e, frames, block, right);
    if (stats) *stats = e.aheadStats();
    return out;
}

size_t firstDiff(const std::vector<float>& a, const std::vector<float>& b) {
    for (size_t i = 0; i < std::min(a.size(), b.size()); ++i)
        if (std::memcmp(&a[i], &b[i], sizeof(float)) != 0) return i;
    return a.size() == b.size() ? SIZE_MAX : std::min(a.size(), b.size());
}

}  // namespace

// (a) Identity: the heavy track rendered ahead (its ring filled in chunks of its own) has the bits of the live render,
// at 1024- and 441-frame buffers and with a ring that runs 0 or 3000 frames past each chunk.
TEST(play_ahead_renders_the_live_bits_at_any_buffer) {
    const ProjectSpec p = heavyProject();
    const int64_t frames = 48000 * 6;
    for (int block : {1024, 441}) {
        std::vector<float> liveR, aheadR;
        const std::vector<float> live = render(p, -1, frames, block, nullptr, &liveR);
        for (int extra : {0, 3000}) {
            Engine::AheadStats st;
            const std::vector<float> ahead = render(p, extra, frames, block, &st, &aheadR);
            const size_t d = firstDiff(live, ahead), dr = firstDiff(liveR, aheadR);
            if (d != SIZE_MAX || dr != SIZE_MAX)
                std::printf("     block %d extra %d: first differing frame %zu (left) %zu (right)\n", block, extra, d, dr);
            CHECK(d == SIZE_MAX && dr == SIZE_MAX);
            CHECK(st.tracks >= 1);  // the pad (at least) played ahead
            CHECK_EQ(st.underruns, uint64_t{0});
        }
    }
}

namespace {

// One held DC note on the test signal (master bypassed): the output is a constant while it sounds.
ProjectSpec dcProject() { return heldProject(dc(0.5)); }

}  // namespace

// (b) An underrun (the producer stalled): what the ring held fades out over 5 ms, the track fades back in live over
// 5 ms, the counter counts it, and the track stays live from then on.
TEST(play_ahead_underrun_fades_out_and_stays_live) {
    AheadScope scope(3000);
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(dcProject())));
    e.play();
    std::vector<float> l(512), r(512);
    for (int i = 0; i < 20; ++i) e.process(l.data(), r.data(), 512);
    CHECK_EQ(e.aheadStats().tracks, 1);
    const float level = l[100];
    CHECK(level > 0.1f);
    e.stallPlayAheadForTest(true);
    std::vector<float> out;
    for (int i = 0; i < 40; ++i) {
        e.process(l.data(), r.data(), 512);
        out.insert(out.end(), l.begin(), l.end());
    }
    e.stallPlayAheadForTest(false);
    for (int i = 0; i < 40; ++i) {
        e.process(l.data(), r.data(), 512);
        out.insert(out.end(), l.begin(), l.end());
        CHECK_EQ(e.aheadStats().tracks, 0);  // live for good
    }
    const Engine::AheadStats st = e.aheadStats();
    CHECK_EQ(st.underruns, uint64_t{1});
    // The dip: down to (almost) silence and back, in 240-frame linear ramps, never a step larger than a ramp's.
    size_t low = 0;
    for (size_t i = 0; i < out.size(); ++i)
        if (out[i] < out[low]) low = i;
    CHECK(out[low] < level * 0.01f);
    CHECK(maxStep(out, 0, out.size()) <= level / 240.0f * 1.01f);
    size_t first = 0, last = 0;  // the dip's extent
    for (size_t i = 0; i < out.size(); ++i)
        if (out[i] < level * 0.999f) {
            if (!first) first = i;
            last = i;
        }
    // At most a chunk of silence between the two fades: the fade starts with less than a chunk past it in the ring.
    std::printf("     dip from %zu to %zu, lowest %g at %zu\n", first, last, out[low], low);
    CHECK(last - first + 1 <= 2 * 240 + 64 + 2);
    CHECK(out.back() == level);  // live again, at the held level
}

// (c) A drain while a note is held across the ring's end: an edit (to the value it has) sends the track live; the
// render has the bits of one that never went ahead, with the same edit at the same callback.
TEST(play_ahead_drain_mid_note_matches_a_live_render) {
    const ProjectSpec p = heavyProject();
    auto renderWith = [&](int extra) {
        AheadScope scope(extra);
        Engine e(48000);
        CHECK(ok(e.setProject(p)));
        e.play();
        std::vector<float> out, l(1000), r(1000);
        for (int i = 0; i < 160; ++i) {
            // 0.27 s in: the pad's first chord rings across the ring's end (3000 frames on).
            if (i == 13 && !e.setComponentParam("pad", 2, "threshold", -18.0)) {
                std::printf("%s\n", e.componentStatesJson("pad").substr(0, 600).c_str());
                CHECK(false);
            }
            if (i == 20 && extra >= 0) CHECK(e.aheadStats().tracks >= 1);
            e.process(l.data(), r.data(), 1000);
            out.insert(out.end(), l.begin(), l.end());
        }
        return out;
    };
    const std::vector<float> live = renderWith(-1), ahead = renderWith(3000);
    CHECK(firstDiff(live, ahead) == SIZE_MAX);
}

// (e) A parameter edit parked for an ahead track lands at the ring's end: the render equals a live one with the edit
// made there (3000 frames after the callback it was made in).
TEST(play_ahead_parked_edit_lands_at_the_rings_end) {
    const ProjectSpec p = heavyProject();
    auto renderWith = [&](int extra, int at) {
        AheadScope scope(extra);
        Engine e(48000);
        CHECK(ok(e.setProject(p)));
        e.play();
        std::vector<float> out, l(1000), r(1000);
        for (int i = 0; i < 120; ++i) {
            if (i == at) CHECK(e.setComponentParam("pad", 2, "threshold", -36.0));
            if (i == at) CHECK(e.setComponentParam("pad", Engine::kInstrumentIndex, "osc1_unison", 1));
            e.process(l.data(), r.data(), 1000);
            out.insert(out.end(), l.begin(), l.end());
        }
        return out;
    };
    const std::vector<float> ahead = renderWith(3000, 40), live = renderWith(-1, 43), early = renderWith(-1, 40);
    CHECK(firstDiff(live, ahead) == SIZE_MAX);
    CHECK(firstDiff(early, ahead) != SIZE_MAX);  // the edit made a difference
}

// (d) A seek while tracks are ahead drops their rings: nothing rendered before it is heard after it, and after
// Play's 5 ms tail of the old pass (rendered from where the instrument had got to) the bits are the live render's.
TEST(play_ahead_seek_drops_the_rings) {
    ProjectSpec p = heavyProject();
    p.layers[0].components.clear();  // inserts would carry their (rendered ahead) tails into the new pass
    auto renderWith = [&](int extra, Engine::AheadStats* st) {
        AheadScope scope(extra);
        Engine e(48000);
        e.setMasterBypass(true);  // the master's limiter would carry the play tail's difference on
        CHECK(ok(e.setProject(p)));
        e.play();
        std::vector<float> out, l(1000), r(1000);
        for (int i = 0; i < 100; ++i) {
            if (i == 30) CHECK(e.play(9.5));  // a seek, mid-loop
            e.process(l.data(), r.data(), 1000);
            out.insert(out.end(), l.begin(), l.end());
        }
        if (st) *st = e.aheadStats();
        return out;
    };
    Engine::AheadStats st;
    const std::vector<float> live = renderWith(-1, nullptr), ahead = renderWith(3000, &st);
    CHECK(st.drops >= 1);
    const size_t seek = 30 * 1000, tail = 512;
    const size_t d = firstDiff(std::vector<float>(live.begin() + seek + tail, live.end()),
                               std::vector<float>(ahead.begin() + seek + tail, ahead.end()));
    if (d != SIZE_MAX) {
        size_t lastDiff = 0;
        double worst = 0;
        for (size_t i = seek; i < live.size(); ++i)
            if (live[i] != ahead[i]) {
                lastDiff = i;
                worst = std::max(worst, std::fabs(static_cast<double>(live[i]) - ahead[i]));
            }
        std::printf("     first differing frame %zu after the seek's tail, last %zu, worst %g\n", d, lastDiff - seek, worst);
    }
    CHECK(d == SIZE_MAX);
    CHECK(firstDiff(live, ahead) >= seek);  // the same up to the seek too
}

// The ahead thread for real (the ThreadSanitizer job's): callbacks paced near real time, edits from another thread
// while the tracks are ahead, a seek. With no underrun the render is the live one's up to the first edit.
TEST(play_ahead_thread_renders_beside_the_callback) {
    const ProjectSpec p = heavyProject();
    const int block = 1024, calls = 48000 * 7 / block;
    std::vector<float> live;
    {
        AheadScope off(-1);
        Engine e(48000);
        CHECK(ok(e.setProject(p)));
        e.play();
        live = run(e, static_cast<int64_t>(calls) * block, block);
    }
    AheadScope off(-1);
    Engine e(48000);
    e.setPlayAhead(true);
    CHECK(e.playAhead());
    CHECK(ok(e.setProject(p)));
    e.play();
    std::vector<float> out, l(block), r(block);
    int aheadSeen = 0;
    for (int i = 0; i < calls; ++i) {
        e.process(l.data(), r.data(), block);
        out.insert(out.end(), l.begin(), l.end());
        aheadSeen = std::max(aheadSeen, e.aheadStats().tracks);
        std::this_thread::sleep_for(std::chrono::milliseconds(4));  // the ahead thread gets the core meanwhile
    }
    const Engine::AheadStats st = e.aheadStats();
    CHECK(aheadSeen >= 1);  // after 3 s untouched and the lead
    CHECK(st.workFrames > 0);
    if (st.underruns == 0) CHECK(firstDiff(live, out) == SIZE_MAX);
    else std::printf("     %llu underruns on this machine: bits not compared\n", static_cast<unsigned long long>(st.underruns));
    // Edits from another thread while ahead, then a seek: nothing crashes or races, and the tracks come back.
    std::atomic<bool> done{false};
    std::thread editor([&] {
        for (int k = 0; !done.load(); ++k) {
            e.setComponentParam("pad", 2, "threshold", -20.0 - (k % 10));
            std::this_thread::sleep_for(std::chrono::milliseconds(7));
        }
    });
    int aheadAtSeek = 0;
    uint64_t underrunsAtSeek = 0;
    for (int i = 0; i < 60; ++i) {
        if (i == 30) {
            aheadAtSeek = e.aheadStats().tracks;  // the drums and the signal, unless they underran (a slow build)
            underrunsAtSeek = e.aheadStats().underruns;
            CHECK(e.play(4));
        }
        e.process(l.data(), r.data(), block);
        std::this_thread::sleep_for(std::chrono::milliseconds(4));
    }
    done.store(true);
    editor.join();
    // (An underrun around the seek may have brought the track back first.)
    if (aheadAtSeek > 0 && e.aheadStats().underruns == underrunsAtSeek) CHECK(e.aheadStats().drops >= 1);
    std::printf("     %d ahead at the seek, %llu underruns, %llu drops\n", aheadAtSeek,
                static_cast<unsigned long long>(e.aheadStats().underruns), static_cast<unsigned long long>(e.aheadStats().drops));
}

// A seek and a Stop while the ahead thread holds the track: what its ring holds fades out over 5 ms before the
// command lands (never a cut to silence), and the track comes back with a fade in.
TEST(play_ahead_thread_drop_fades_instead_of_cutting) {
    AheadScope off(-1);
    Engine e(48000);
    e.setMasterBypass(true);
    e.setPlayAhead(true);
    CHECK(ok(e.setProject(dcProject())));
    e.play();
    std::vector<float> out, l(256), r(256);
    auto play = [&](int calls) {
        for (int i = 0; i < calls; ++i) {
            e.process(l.data(), r.data(), 256);
            out.insert(out.end(), l.begin(), l.end());
            std::this_thread::sleep_for(std::chrono::microseconds(500));
        }
    };
    play(48000 * 4 / 256);  // 3 s untouched, then the lead
    CHECK_EQ(e.aheadStats().tracks, 1);
    const float level = out.back();
    const size_t from = out.size();
    CHECK(e.play(4));  // a seek
    play(100);
    CHECK(e.aheadStats().drops >= 1);
    {
        size_t at = from;
        for (size_t i = from; i < out.size(); ++i)
            if (std::fabs(out[i] - out[i - 1]) > std::fabs(out[at] - out[at - 1])) at = i;
        std::printf("     seek: level %g, largest step %g at %zu frames after it (%g -> %g)\n", level,
                    std::fabs(out[at] - out[at - 1]), at - from, out[at - 1], out[at]);
    }
    CHECK(maxStep(out, from - 1, out.size()) <= level / 240.0f * 1.05f);
    play(48000 * 4 / 256);  // ahead again
    const size_t stopAt = out.size();
    CHECK(e.stop());
    play(100);
    CHECK(maxStep(out, stopAt - 1, out.size()) <= level / 240.0f * 1.05f);
    CHECK(out.back() == 0.0f);
}

// (10) A mute while ahead, then an unmute: the track comes back live as the live path does once its fader reached
// silence (Silent: its instrument idles, the unmute starts it afresh and chases), so the bits are the live render's.
TEST(play_ahead_mute_and_unmute_match_a_live_render) {
    const ProjectSpec p = heavyProject();
    auto renderWith = [&](int extra) {
        AheadScope scope(extra);
        Engine e(48000);
        CHECK(ok(e.setProject(p)));
        e.play();
        std::vector<float> out, l(1000), r(1000);
        for (int i = 0; i < 150; ++i) {
            if (i == 40) e.setLayerMix("pad", 0.8, 0.0, true, false);
            if (i == 75) e.setLayerMix("pad", 0.8, 0.0, false, false);
            e.process(l.data(), r.data(), 1000);
            out.insert(out.end(), l.begin(), l.end());
        }
        return out;
    };
    const std::vector<float> live = renderWith(-1), ahead = renderWith(3000);
    CHECK(firstDiff(live, ahead) == SIZE_MAX);
}

// The lead (as with the thread: the callback renders a track's first 4096 frames itself, a little more each
// callback) has the live bits too.
TEST(play_ahead_lead_renders_the_live_bits) {
    const ProjectSpec p = heavyProject();
    const int64_t frames = 48000 * 4;
    for (int block : {1024, 441}) {
        const std::vector<float> live = render(p, -1, frames, block);
        Engine::setPlayAheadLeadForTest(true);
        for (int extra : {0, 3000}) {
            Engine::AheadStats st;
            const std::vector<float> ahead = render(p, extra, frames, block, &st);
            CHECK(firstDiff(live, ahead) == SIZE_MAX);
            CHECK(st.tracks >= 1);
        }
        Engine::setPlayAheadLeadForTest(false);
    }
}

// (h) The app's intent (API 50): a hold before an edit brings the track back live by the drain, so the edit lands on
// time with the live render's bits; without it the edit waits for the ring's end. Holds are counted, keep the track
// live while held, and an unknown layer is refused.
TEST(play_ahead_intent_brings_the_track_live_before_an_edit) {
    const ProjectSpec p = heavyProject();
    auto renderWith = [&](int extra, bool intent) {
        AheadScope scope(extra);
        Engine e(48000);
        CHECK(ok(e.setProject(p)));
        CHECK(!e.playAheadIntent("nope", Engine::AheadIntent::Hold));
        e.play();
        std::vector<float> out, l(1000), r(1000);
        for (int i = 0; i < 120; ++i) {
            if (intent && i == 30) {
                CHECK(e.playAheadIntent("pad", Engine::AheadIntent::Hold));  // the device page opens
                CHECK(e.playAheadIntent("pad", Engine::AheadIntent::Hold));  // a finger down on a knob
            }
            if (extra >= 0 && i == 29) CHECK(e.aheadStats().tracks >= 1);  // the pad was ahead
            if (intent && extra >= 0 && i == 38) CHECK(e.aheadStats().tracks == 2);  // drums, sig; the pad is held live
            if (i == 40) {
                if (intent) CHECK(e.playAheadIntent("pad", Engine::AheadIntent::Edit));
                CHECK(e.setComponentParam("pad", 2, "threshold", -36.0));
                CHECK(e.setComponentParam("pad", Engine::kInstrumentIndex, "osc1_unison", 1));
            }
            if (intent && i == 50) CHECK(e.playAheadIntent("pad", Engine::AheadIntent::Release));  // the finger lifts
            if (intent && extra >= 0 && i == 60) CHECK(e.aheadStats().tracks == 2);  // still held by the page
            if (intent && i == 70) CHECK(e.playAheadIntent("pad", Engine::AheadIntent::Release));  // the page closes
            e.process(l.data(), r.data(), 1000);
            out.insert(out.end(), l.begin(), l.end());
        }
        if (intent && extra >= 0) CHECK(e.aheadStats().tracks == 3);  // released: it goes ahead again (tests: no quiet)
        return out;
    };
    const std::vector<float> live = renderWith(-1, false), ahead = renderWith(3000, true), late = renderWith(3000, false);
    CHECK(firstDiff(live, ahead) == SIZE_MAX);  // on time, with the live bits
    CHECK(firstDiff(live, late) != SIZE_MAX);   // without the intent it lands at the ring's end
}

// The C call (API 50): known layers only, the three intents, nothing for a null engine, layer or unknown intent.
TEST(play_ahead_intent_c_api) {
    CHECK_EQ(caw_engine_play_ahead_intent(nullptr, "t", CAW_AHEAD_HOLD), 0);
    CawEngine* e = caw_engine_create(48000);
    CHECK(e != nullptr);
    if (!e) return;
    char* r = caw_engine_set_project(
        e, R"({"caw_project":1,"bpm":120,"layers":[{"id":"t","instrument":{"id":"org.caw.test.osc","params":{"level":0.5}}}]})");
    CHECK(r && std::string(r).find("\"ok\":true") != std::string::npos);
    caw_free(r);
    CHECK_EQ(caw_engine_play_ahead_intent(e, "t", CAW_AHEAD_HOLD), 1);
    CHECK_EQ(caw_engine_play_ahead_intent(e, "t", CAW_AHEAD_EDIT), 1);
    CHECK_EQ(caw_engine_play_ahead_intent(e, "t", CAW_AHEAD_RELEASE), 1);
    CHECK_EQ(caw_engine_play_ahead_intent(e, "t", CAW_AHEAD_RELEASE), 1);  // one too many: nothing held, still a touch
    CHECK_EQ(caw_engine_play_ahead_intent(e, "x", CAW_AHEAD_HOLD), 0);
    CHECK_EQ(caw_engine_play_ahead_intent(e, nullptr, CAW_AHEAD_HOLD), 0);
    CHECK_EQ(caw_engine_play_ahead_intent(e, "t", 3), 0);
    caw_engine_destroy(e);
}

// (i) A preview (an on-screen key or pad) aimed at an ahead track brings it back fast, as a device note does: the
// ring fades out over 5 ms and the note plays from the next callback, not a ring's depth later.
TEST(play_ahead_preview_brings_the_track_back_fast) {
    AheadScope scope(30000);
    Engine e(48000);
    CHECK(ok(e.setProject(heavyProject())));
    e.play();
    std::vector<float> l(1000), r(1000);
    for (int i = 0; i < 30; ++i) e.process(l.data(), r.data(), 1000);
    CHECK_EQ(e.aheadStats().tracks, 3);
    CHECK_EQ(e.noteOn("pad", 7, 64, 0.8), 1);
    for (int i = 0; i < 2; ++i) e.process(l.data(), r.data(), 1000);
    CHECK_EQ(e.aheadStats().tracks, 2);  // the pad is live after 2 callbacks, though its ring held 30000 frames more
    CHECK_EQ(e.noteOff(7), 1);
}
