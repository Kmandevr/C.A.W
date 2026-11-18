// General mixer routing: output overrides, sends into tracks, returns, keys from tracks that receive sends, feedback.
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "engine.h"
#include "mix_pool.h"
#include "project.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;
using cawtest::Shape;

namespace {

const double kCentre = std::cos(3.14159265358979323846 / 4.0);  // a mono track's pan law at centre

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

LayerSpec track(const std::string& id, double level) {
    return cawtest::testSignalLayer(id, Shape::Dc, {{"level", level}});
}

LayerSpec bus(const std::string& id) {
    LayerSpec l;
    l.id = id;
    l.name = id;
    l.folder = true;
    l.busEnabled = true;
    l.volume = 1.0;
    return l;
}

ComponentSpec leftOnly() {  // a balance fully left: the right side goes silent, the left stays at unity
    ComponentSpec c;
    c.id = "org.caw.stereo.balance";
    c.params = {{"pan", -1.0}};
    return c;
}

SendSpec sendTo(const std::string& to, double level = 1.0, bool pre = false, bool feedback = false, bool limiter = true) {
    SendSpec s;
    s.to = to;
    s.level = level;
    s.pre = pre;
    s.feedback = feedback;
    s.limiter = limiter;
    return s;
}

ProjectSpec project(std::vector<LayerSpec> layers) {
    ProjectSpec p = cawtest::testSignalProject(std::move(layers));
    return p;
}

std::vector<float> run(Engine& e, int64_t frames, int block = 64, std::vector<float>* right = nullptr) {
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; i += block) {
        const int n = static_cast<int>(std::min<int64_t>(block, frames - i));
        e.process(l.data() + i, r.data() + i, n);
    }
    if (right) *right = r;
    return l;
}

// Both sides, interleaved per block, rendered at `block` frames a callback.
std::vector<float> render(const ProjectSpec& p, int64_t frames, int block) {
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    std::vector<float> right;
    std::vector<float> out = run(e, frames, block, &right);
    out.insert(out.end(), right.begin(), right.end());
    CHECK_EQ(e.routingRejections(), 0u);
    return out;
}

bool sameBits(const std::vector<float>& a, const std::vector<float>& b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}

ComponentSpec keyedCompressor(const std::string& key, bool pre) {
    ComponentSpec comp;
    comp.id = "org.caw.compressor";
    comp.params = {{"sidechain", 1.0}, {"threshold", -30.0}, {"ratio", 20.0}, {"knee", 0.0},
                   {"auto_makeup", 0.0}, {"attack", 0.05}};
    comp.hasKey = true;
    comp.key.layer = key;
    comp.key.pre = pre;
    return comp;
}

}  // namespace

TEST(an_output_sends_a_track_to_a_bus_outside_its_folder) {
    // a sits in folder f (whose bus pans fully left) but its output is bus g (volume 0.5): it skips f.
    LayerSpec f = bus("f");
    f.components = {leftOnly()};
    LayerSpec g = bus("g");
    g.volume = 0.5;
    LayerSpec a = track("a", 0.5);
    a.parentId = "f";
    ProjectSpec p = project({f, g, a});
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    std::vector<float> right;
    auto left = run(e, 4096, 64, &right);
    CHECK_NEAR(left[4000], 0.5 * kCentre, 1e-5);  // through f: left only
    CHECK_NEAR(right[4000], 0.0, 1e-6);
    p.layers[2].outputId = "g";
    CHECK(ok(e.setProject(p)));
    left = run(e, 8192, 64, &right);
    CHECK_NEAR(left[8000], 0.5 * kCentre * 0.5, 1e-5);  // through g, both sides
    CHECK_NEAR(right[8000], 0.5 * kCentre * 0.5, 1e-5);
    // "@master": straight to the master from inside the folder.
    p.layers[2].outputId = kMasterOutput;
    CHECK(ok(e.setProject(p)));
    left = run(e, 8192, 64, &right);
    CHECK_NEAR(left[8000], 0.5 * kCentre, 1e-5);
    CHECK_NEAR(right[8000], 0.5 * kCentre, 1e-5);
    p.layers[2].outputId = "g";
    // An output with latency on its bus stays in time with what meets it at the master.
    ComponentSpec latent;
    latent.id = "org.caw.compressor";
    latent.params = {{"ratio", 1.0}, {"auto_makeup", 0.0}, {"makeup", 0.0}, {"threshold", 0.0}};
    p.layers[1].components = {latent};
    p.layers.push_back(track("b", 0.25));
    Engine h(48000);
    h.setMasterBypass(true);
    CHECK(ok(h.setProject(p)));
    h.play();
    left = run(h, 1024);
    CHECK_NEAR(left[200], 0.0, 1e-6);  // b waits for g's latency
    CHECK_NEAR(left[700], 0.5 * kCentre * 0.5 + 0.25 * kCentre, 2e-3);
}

TEST(outputs_are_read_and_checked) {
    std::string error;
    ProjectSpec p;
    CHECK(parseProject(R"({"caw_project":1,"layers":[
        {"id":"f","folder":true,"bus":true},{"id":"g","folder":true,"bus":true},
        {"id":"t","parent":"f","output":"g"},{"id":"u","output":""}]})", p, error));
    CHECK_EQ(p.layers[2].outputId, std::string("g"));
    CHECK_EQ(p.layers[2].parentId, std::string("f"));
    CHECK_EQ(routeTarget(p, p.layers[2]), std::string("g"));
    CHECK(p.layers[3].outputId.empty());
    CHECK(parseProject(R"({"caw_project":1,"layers":[{"id":"f","folder":true,"bus":true},{"id":"t","parent":"f","output":"@master"}]})", p, error));
    CHECK_EQ(p.layers[1].outputId, std::string("@master"));
    CHECK(routeTarget(p, p.layers[1]).empty());
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"@master"}]})", p, error));
    CHECK(error.find("reserved") != std::string::npos);
    // Only an enabled bus folder in the project, never itself, never a loop.
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","output":"u"},{"id":"u"}]})", p, error));
    CHECK(error.find("not a bus") != std::string::npos);
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","output":"f"},{"id":"f","folder":true,"bus":false}]})", p, error));
    CHECK(error.find("not a bus") != std::string::npos);
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","output":"nowhere"}]})", p, error));
    CHECK(error.find("not in the project") != std::string::npos);
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"f","folder":true,"bus":true,"output":"f"}]})", p, error));
    CHECK(error.find("itself") != std::string::npos);
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","output":3}]})", p, error));
    CHECK(error.find("output") != std::string::npos);
    CHECK(!parseProject(R"({"caw_project":1,"layers":[
        {"id":"f","folder":true,"bus":true,"output":"g"},{"id":"g","folder":true,"bus":true,"output":"f"}]})", p, error));
    CHECK(error.find("loop") != std::string::npos);
    // A bus whose output is its own child bus loops too.
    CHECK(!parseProject(R"({"caw_project":1,"layers":[
        {"id":"f","folder":true,"bus":true,"output":"g"},{"id":"g","folder":true,"bus":true,"parent":"f"}]})", p, error));
    CHECK(error.find("loop") != std::string::npos);
}

TEST(a_send_into_a_track_sums_before_its_inserts) {
    // a (0.5) sends post-fader into track b (0.25), whose insert keeps only the left side: the send goes through it.
    LayerSpec a = track("a", 0.5);
    a.sends = {sendTo("b", 0.5)};
    LayerSpec b = track("b", 0.25);
    b.components = {leftOnly()};
    ProjectSpec p = project({a, b});
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    std::vector<float> right;
    auto left = run(e, 4096, 64, &right);
    const double direct = 0.5 * kCentre;
    CHECK_NEAR(left[4000], direct + (0.25 + 0.5 * direct) * kCentre, 1e-5);
    CHECK_NEAR(right[4000], direct, 1e-5);  // b's insert silenced the send's right side too
    // Live: the level, then mute, then pre-fader (a's volume no longer matters).
    CHECK(e.setSend("a", 0, 1.0, false, false));
    left = run(e, 4096);
    CHECK_NEAR(left[4000], direct + (0.25 + direct) * kCentre, 1e-5);
    CHECK(e.setSend("a", 0, 1.0, false, true));
    left = run(e, 4096);
    CHECK_NEAR(left[4000], direct + 0.25 * kCentre, 1e-5);
    p.layers[0].volume = 0.5;
    p.layers[0].sends[0].pre = true;
    p.layers[0].sends[0].level = 1.0;
    CHECK(ok(e.setProject(p)));
    left = run(e, 8192);
    CHECK_NEAR(left[8000], 0.5 * direct + (0.25 + 0.5) * kCentre, 1e-5);
    // A muted source sends nothing.
    p.layers[0].mute = true;
    CHECK(ok(e.setProject(p)));
    left = run(e, 8192);
    CHECK_NEAR(left[8000], 0.25 * kCentre, 1e-5);
}

TEST(a_return_bus_fed_by_several_sends_sums_each_once) {
    // a and b send into "ret" (left only), c sends into track a: every route sums once.
    LayerSpec ret = bus("ret");
    ret.components = {leftOnly()};
    LayerSpec a = track("a", 0.5), b = track("b", 0.25), c = track("c", 0.125);
    a.sends = {sendTo("ret", 1.0)};
    b.sends = {sendTo("ret", 0.5, true)};
    c.sends = {sendTo("a", 1.0)};
    ProjectSpec p = project({ret, a, b, c});
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    std::vector<float> right;
    auto left = run(e, 4096, 64, &right);
    const double cOut = 0.125 * kCentre;
    const double aOut = (0.5 + cOut) * kCentre, bOut = 0.25 * kCentre;
    CHECK_NEAR(left[4000], aOut + bOut + cOut + aOut + 0.5 * 0.25, 1e-5);
    CHECK_NEAR(right[4000], aOut + bOut + cOut, 1e-5);
}

TEST(a_key_may_come_from_a_track_that_only_hears_sends) {
    // k plays silence and is muted; a sends into it, and k keys b's compressor: b ducks only through that send.
    for (const bool pre : {true, false}) {
        LayerSpec a = track("a", 0.5);
        LayerSpec k = track("k", 0.0);
        k.mute = true;
        LayerSpec b = track("b", 0.25);
        b.components = {keyedCompressor("k", pre)};
        ProjectSpec p = project({a, k, b});
        Engine plain(48000);
        plain.setMasterBypass(true);
        CHECK(ok(plain.setProject(p)));
        plain.play();
        auto out = run(plain, 9600);
        CHECK_NEAR(out[9000], 0.5 * kCentre + 0.25 * kCentre, 1e-4);  // no key: no reduction
        p.layers[0].sends = {sendTo("k", 1.0)};
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(ok(e.setProject(p)));
        e.play();
        out = run(e, 9600);
        CHECK(out[9000] - 0.5 * kCentre < 0.25 * kCentre * 0.2);
        CHECK(out[9000] - 0.5 * kCentre > 0.0);
    }
}

TEST(a_feedback_send_is_exactly_one_chunk_late) {
    // Impulses from a (every 0.1 s), direct and through a feedback send into bus x (limiter off): once the send's
    // gain has glided in from silence, each copy is kBlock frames later at the same level.
    LayerSpec a = cawtest::testSignalLayer("a", Shape::Impulse, {{"level", 0.5}, {"period", 0.1}});
    a.sends = {sendTo("x", 1.0, false, true, false)};
    ProjectSpec p = project({a, bus("x")});
    for (const int block : {64, 128, 480, 1024}) {
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(ok(e.setProject(p)));
        e.play();
        const auto out = run(e, 8192, block);
        int first = -1, second = -1;
        for (int i = 4000; i < 8192; ++i)
            if (out[static_cast<size_t>(i)] != 0.0f) {
                if (first < 0) first = i;
                else if (second < 0) second = i;
            }
        CHECK(first >= 0);
        CHECK_EQ(second - first, kBlock);
        if (second >= 0) CHECK_EQ(out[static_cast<size_t>(second)], out[static_cast<size_t>(first)]);
    }
}

TEST(a_feedback_loop_renders_finite_and_its_limiter_bounds_it) {
    // Bus x feeds itself back at +6 dB, with a square into it: the limiter holds the return under 0 dBFS.
    auto loop = [](bool limiter) {
        LayerSpec x = bus("x");
        x.sends = {sendTo("x", 2.0, false, true, limiter)};
        LayerSpec a = cawtest::testSignalLayer("a", Shape::Square, {{"level", 0.5}, {"freq", 220}});
        a.parentId = "x";
        return project({x, a});
    };
    const auto on = render(loop(true), 48000, 256);
    float peak = 0;
    bool finite = true;
    for (float v : on) {
        finite = finite && std::isfinite(v);
        peak = std::max(peak, std::fabs(v));
    }
    CHECK(finite);
    CHECK(peak > 0.6f);       // it does feed back
    CHECK(peak < 0.5f + 1.0f);  // the input (0.5 x the pan law) plus a return held under 1
    const auto off = render(loop(false), 48000, 256);
    float peakOff = 0;
    for (float v : off) peakOff = std::max(peakOff, std::isfinite(v) ? std::fabs(v) : 1e30f);
    CHECK(peakOff > 10.0f);  // without its limiter a +6 dB loop runs away...
    CHECK(peakOff < 16.0f + 0.5f);  // ...but its return stops at +/-16 (plus the input), never near FLT_MAX
}

TEST(a_feedback_mix_renders_the_same_bits_at_any_buffer_size) {
    // Buses x -> y, y feeding back into x and into track t; tracks with odd loop lengths cut the chunks.
    LayerSpec x = bus("x"), y = bus("y");
    x.sends = {sendTo("y", 0.8)};
    x.outputId = "";
    y.sends = {sendTo("x", 0.6, false, true), sendTo("t", 0.5, true, true)};
    y.components = {leftOnly()};
    LayerSpec a = cawtest::testSignalLayer("a", Shape::Saw, {{"level", 0.4}, {"freq", 97}});
    a.parentId = "x";
    a.lengthSteps = 3;
    LayerSpec t = cawtest::testSignalLayer("t", Shape::Sine, {{"level", 0.2}, {"freq", 330}});
    t.lengthSteps = 5;
    t.outputId = "y";
    ProjectSpec p = project({x, y, a, t});
    p.modules.push_back({"n", "---\nkind: pattern\n---\n0 C4 1\n2 E4 1\n"});
    p.layers[2].pattern = "n";
    const auto base = render(p, 30000, 64);
    for (const int block : {128, 480, 1024, 37}) CHECK(sameBits(base, render(p, 30000, block)));
    float peak = 0;
    for (float v : base) peak = std::max(peak, std::fabs(v));
    CHECK(peak > 0.1f);
}

TEST(only_feedback_sends_may_close_a_loop_and_keys_never_do) {
    std::string error;
    ProjectSpec p;
    CHECK(!parseProject(R"({"caw_project":1,"layers":[
        {"id":"x","name":"Verb","folder":true,"bus":true,"sends":[{"to":"y"}]},
        {"id":"y","name":"Delay","folder":true,"bus":true,"sends":[{"to":"x"}]}]})", p, error));
    CHECK(error.find("loop") != std::string::npos && error.find("feedback") != std::string::npos);
    CHECK(parseProject(R"({"caw_project":1,"layers":[
        {"id":"x","folder":true,"bus":true,"sends":[{"to":"y"}]},
        {"id":"y","folder":true,"bus":true,"sends":[{"to":"x","feedback":true,"limiter":false}]}]})", p, error));
    CHECK(p.layers[1].sends[0].feedback && !p.layers[1].sends[0].limiter);
    CHECK(!p.layers[0].sends[0].feedback && p.layers[0].sends[0].limiter);
    // Tracks sending into each other.
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","sends":[{"to":"u"}]},{"id":"u","sends":[{"to":"t"}]}]})", p, error));
    CHECK(error.find("loop") != std::string::npos);
    CHECK(parseProject(R"({"caw_project":1,"layers":[{"id":"t","sends":[{"to":"u"}]},{"id":"u","sends":[{"to":"t","feedback":true}]}]})", p, error));
    // Itself: only through feedback.
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"x","folder":true,"bus":true,"sends":[{"to":"x"}]}]})", p, error));
    CHECK(error.find("itself") != std::string::npos);
    CHECK(parseProject(R"({"caw_project":1,"layers":[{"id":"x","folder":true,"bus":true,"sends":[{"to":"x","feedback":true}]}]})", p, error));
    // A key closing a loop is refused even when a feedback send is on the way back.
    CHECK(!parseProject(R"({"caw_project":1,"layers":[
        {"id":"t","sends":[{"to":"u"}]},
        {"id":"u","components":[{"id":"org.caw.ducker","key":{"layer":"v"}}]},
        {"id":"v","sends":[{"to":"t","feedback":true}],"components":[{"id":"org.caw.ducker","key":{"layer":"u"}}]}]})", p, error));
    CHECK(error.find("loop") != std::string::npos);
    // A send into an organization-only folder carries nothing.
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","sends":[{"to":"f"}]},{"id":"f","folder":true,"bus":false}]})", p, error));
    CHECK(error.find("no bus") != std::string::npos);
    // The engine refuses a loop built in code too.
    LayerSpec a = track("a", 0.5), b = track("b", 0.25);
    a.sends = {sendTo("b")};
    b.sends = {sendTo("a")};
    Engine e(48000);
    const std::string result = e.setProject(project({a, b}));
    CHECK(!ok(result));
    CHECK(result.find("loop") != std::string::npos);
}

TEST(an_older_project_reads_and_renders_as_it_did) {
    // Without the new fields, and with them at their defaults: the same project, the same bits.
    const char* old = R"({"caw_project":1,"bpm":128,"layers":[
        {"id":"f","folder":true,"bus":true,"volume":0.9,"components":[{"id":"org.caw.compressor","params":{"ratio":1,"auto_makeup":0,"threshold":0}}]},
        {"id":"r","folder":true,"bus":true,"volume":0.7},
        {"id":"a","parent":"f","instrument":{"id":"org.caw.test.osc","params":{"shape":1,"level":0.4,"freq":110}},
         "sends":[{"to":"r","level":0.5,"pre":true}]},
        {"id":"b","instrument":{"id":"org.caw.test.osc","params":{"shape":0,"level":0.3,"freq":440}},
         "sends":[{"to":"r","level":0.8}]}]})";
    const char* explicitDefaults = R"({"caw_project":1,"bpm":128,"layers":[
        {"id":"f","folder":true,"bus":true,"volume":0.9,"output":"","components":[{"id":"org.caw.compressor","params":{"ratio":1,"auto_makeup":0,"threshold":0}}]},
        {"id":"r","folder":true,"bus":true,"volume":0.7,"output":null},
        {"id":"a","parent":"f","output":"","instrument":{"id":"org.caw.test.osc","params":{"shape":1,"level":0.4,"freq":110}},
         "sends":[{"to":"r","level":0.5,"pre":true,"feedback":false,"limiter":true}]},
        {"id":"b","instrument":{"id":"org.caw.test.osc","params":{"shape":0,"level":0.3,"freq":440}},
         "sends":[{"to":"r","level":0.8,"feedback":false}]}]})";
    std::string error;
    ProjectSpec p, q;
    CHECK(parseProject(old, p, error));
    CHECK(parseProject(explicitDefaults, q, error));
    for (const LayerSpec& l : p.layers) {
        CHECK(l.outputId.empty());
        for (const SendSpec& s : l.sends) CHECK(!s.feedback && s.limiter);
    }
    const auto x = render(p, 20000, 64);
    CHECK(sameBits(x, render(q, 20000, 64)));
    CHECK(sameBits(x, render(p, 20000, 480)));
    float peak = 0;
    for (float v : x) peak = std::max(peak, std::fabs(v));
    CHECK(peak > 0.1f);
}

namespace {

struct Rng {
    uint64_t s;
    explicit Rng(uint64_t seed) : s(seed * 0x9E3779B97F4A7C15ull + 1) {}
    uint64_t next() {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        return s;
    }
    int below(int n) { return static_cast<int>(next() % static_cast<uint64_t>(n)); }
    double unit() { return static_cast<double>(next() >> 11) / 9007199254740992.0; }
};

// A random mix with the general routing: buses with outputs anywhere below them, tracks with outputs, sends into
// buses and tracks (forward only), feedback sends anywhere (to any layer, itself included), keys from tracks.
ProjectSpec randomRouting(uint64_t seed) {
    Rng rng(seed);
    ProjectSpec p;
    p.bpm = 100 + rng.below(60);
    p.loopBars = 1;
    p.master = 0.8;
    p.modules.push_back({"beats", "---\nkind: pattern\n---\n0 C4 1\n3 E4 0.8\n4 G4 1\n8 C4 1\n12 C5 1\n"});
    const int buses = 1 + rng.below(4), tracks = 2 + rng.below(7);
    // Layers in a fixed order: buses b0..bn then tracks t0..tm; a non-feedback route only goes to a lower bus or an
    // earlier track (tracks never send into buses' children here), so there is no loop.
    for (int j = 0; j < buses; ++j) {
        LayerSpec b = bus("b" + std::to_string(j));
        b.volume = 0.4 + 0.6 * rng.unit();
        if (j > 0 && rng.below(2)) b.outputId = "b" + std::to_string(rng.below(j));
        if (rng.below(3) == 0) b.components.push_back(leftOnly());
        if (j > 0 && rng.below(2)) b.sends.push_back(sendTo("b" + std::to_string(rng.below(j)), 0.3 + rng.unit()));
        if (rng.below(2)) b.sends.push_back(sendTo("b" + std::to_string(rng.below(buses)), 0.2 + 0.9 * rng.unit(),
                                                   rng.below(2) == 0, true, rng.below(4) != 0));
        p.layers.push_back(b);
    }
    const Shape shapes[] = {Shape::Sine, Shape::Saw, Shape::Square, Shape::Noise};
    for (int i = 0; i < tracks; ++i) {
        const std::string id = "t" + std::to_string(i);
        const cawtest::Params params = {{"level", 0.1 + 0.3 * rng.unit()}, {"freq", 60.0 + 600.0 * rng.unit()}};
        LayerSpec t = rng.below(2) ? cawtest::testSignalNotesLayer(id, shapes[rng.below(4)], "beats", params)
                                   : cawtest::testSignalLayer(id, shapes[rng.below(4)], params);
        t.volume = 0.3 + 0.7 * rng.unit();
        t.pan = rng.unit() * 2.0 - 1.0;
        t.mute = rng.below(7) == 0;
        if (rng.below(2)) t.parentId = "b" + std::to_string(rng.below(buses));
        if (rng.below(3) == 0) t.outputId = "b" + std::to_string(rng.below(buses));
        if (i > 0 && rng.below(3) == 0) t.components.push_back(keyedCompressor("t" + std::to_string(rng.below(i)), rng.below(2) == 0));
        if (rng.below(3) == 0) t.components.push_back(leftOnly());
        for (int k = rng.below(3); k > 0; --k) t.sends.push_back(sendTo("b" + std::to_string(rng.below(buses)), 0.2 + rng.unit(), rng.below(2) == 0));
        if (i > 0 && rng.below(2)) t.sends.push_back(sendTo("t" + std::to_string(rng.below(i)), 0.2 + rng.unit(), rng.below(2) == 0));
        if (rng.below(3) == 0)
            t.sends.push_back(sendTo("t" + std::to_string(rng.below(tracks)), 0.3 + rng.unit(), false, true));
        p.layers.push_back(t);
    }
    // Tracks later in the list send into earlier ones; buses come first, so a track's send into an earlier track
    // whose output is a bus that the later track also reaches is fine (no route goes back up a chain).
    return p;
}

std::vector<float> renderMix(const ProjectSpec& p, int workers, int calls) {
    Engine e(48000);
    if (workers >= 0) {
        CHECK(e.startMixPool(static_cast<uint32_t>(workers)));
        e.setMixParallel(Engine::MixParallel::Always);
    } else {
        e.setMixParallel(Engine::MixParallel::Never);
    }
    CHECK(ok(e.setProject(p)));
    e.play();
    static const int sizes[] = {64, 37, 1, 64, 13, 100, 7, 256};
    std::vector<float> out;
    float l[256], r[256];
    for (int k = 0; k < calls; ++k) {
        const int n = sizes[k % 8];
        e.process(l, r, n);
        out.insert(out.end(), l, l + n);
        out.insert(out.end(), r, r + n);
        if (k == 50)
            for (const LayerSpec& layer : p.layers)
                if (!layer.sends.empty()) { e.setSend(layer.id, 0, 0.3, !layer.sends[0].pre, false); break; }
        if (k == 150) e.stop();
        if (k == 200) e.play();
    }
    CHECK_EQ(e.routingRejections(), 0u);
    return out;
}

}  // namespace

TEST(general_routing_on_the_mix_pool_is_bit_identical_to_one_thread) {
    int played = 0;
    for (uint64_t seed = 1; seed <= 16; ++seed) {
        const ProjectSpec p = randomRouting(seed);
        std::string error;
        if (!validateRouting(p, error)) continue;  // a random pick that loops: not this test's subject
        ++played;
        const std::vector<float> serial = renderMix(p, -1, 260);
        CHECK(sameBits(serial, renderMix(p, -1, 260)));  // repeatable
        CHECK(sameBits(serial, renderMix(p, 1 + static_cast<int>(seed % 4), 260)));
    }
    CHECK(played >= 8);
}

TEST(a_stopped_preview_never_brings_back_a_feedback_loop_from_before_the_stop) {
    // Bus x feeds itself back; a plays into it. After Stop, a preview on b (outside the loop) runs the mix again: x
    // stays silent, because its loop stopped with the song.
    LayerSpec x = bus("x");
    x.sends = {sendTo("x", 0.95, false, true)};
    // a plays notes (a free-running test signal would go on sounding while stopped, as a monitored input does).
    LayerSpec a = cawtest::testSignalNotesLayer("a", Shape::Saw, "n", {{"level", 0.5}});
    a.parentId = "x";
    LayerSpec b = cawtest::testSignalNotesLayer("b", Shape::Sine, "", {{"level", 0.3}});
    ProjectSpec p = project({x, a, b});
    p.modules.push_back({"n", "---\nkind: pattern\n---\n0 A2 4 1\n8 C3 4 1\n"});
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    run(e, 48000);
    LayerMeter m;
    CHECK(e.layerMeter(0, m));
    CHECK(m.peak > 0.1f);  // the loop sounds while playing
    e.stop();
    run(e, 24000);  // the stop's fade, and quiet
    CHECK(e.layerMeter(0, m));  // (reading takes the peak)
    e.noteOn("b", 1, 69, 1.0);
    const auto out = run(e, 4800);
    float peak = 0;
    for (float v : out) peak = std::max(peak, std::fabs(v));
    CHECK(peak > 0.05f);  // b sounds
    CHECK(e.layerMeter(0, m));
    CHECK_EQ(m.peak, 0.0f);  // and x, the loop, doesn't
}

TEST(a_send_turned_into_a_feedback_send_fades_in_instead_of_jumping) {
    // a (0.5) sends into bus x at unity; the send becomes a feedback send while it plays. Its old signal stops, and
    // the new one starts a chunk later from silence, gliding up (no step back to full gain).
    LayerSpec a = track("a", 0.5);
    a.sends = {sendTo("x", 1.0, false, false, false)};  // no limiter: its DC block would take the DC away
    ProjectSpec p = project({a, bus("x")});
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    run(e, 9600);
    p.layers[0].sends[0].feedback = true;
    CHECK(ok(e.setProject(p)));
    const auto out = run(e, 4800);
    float step = 0;
    for (size_t i = 16; i < out.size(); ++i) step = std::max(step, std::fabs(out[i] - out[i - 1]));
    CHECK(step < 0.01f);
    CHECK_NEAR(out[4700], 2 * 0.5 * kCentre, 1e-4);  // back at full gain
}
