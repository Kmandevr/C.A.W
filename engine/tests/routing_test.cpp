// Routing: sends to buses (pre/post, mute, live level), bus inserts, loops refused, latency compensation, keys.
#include <cmath>
#include <string>
#include <vector>

#include "engine.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

const char* kFloat = "---\nmode: float\n---\n";
const double kCentre = std::cos(3.14159265358979323846 / 4.0);  // a mono track's pan law at centre

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

LayerSpec track(const std::string& id, const std::string& module) {
    LayerSpec l;
    l.id = id;
    l.name = id;
    l.chain = {module};
    l.volume = 1.0;
    return l;
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

// Tracks "a" (a constant 0.5) and "b" (0.25), at the top level, volume 1, plus a bus "fx" fed only by sends.
ProjectSpec twoTracksAndABus() {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 4;
    p.master = 1.0;
    p.modules.push_back({"half", std::string(kFloat) + "0.5", {}});
    p.modules.push_back({"quarter", std::string(kFloat) + "0.25", {}});
    p.layers.push_back(track("a", "half"));
    p.layers.push_back(track("b", "quarter"));
    p.layers.push_back(bus("fx"));
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

// Uneven blocks: a send must sound the same however the device splits its buffer.
std::vector<float> runUneven(Engine& e, int64_t frames) {
    static const int sizes[] = {37, 64, 1, 100, 13, 256, 7};
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int64_t i = 0, k = 0; i < frames; ++k) {
        const int n = static_cast<int>(std::min<int64_t>(sizes[k % 7], frames - i));
        e.process(l.data() + i, r.data() + i, n);
        i += n;
    }
    return l;
}

ComponentSpec transparentCompressor() {
    // Ratio 1 and no makeup: it passes its input on, 240 frames (its declared latency) late.
    ComponentSpec c;
    c.id = "org.caw.compressor";
    c.params = {{"ratio", 1.0}, {"auto_makeup", 0.0}, {"makeup", 0.0}, {"threshold", 0.0}};
    return c;
}

}  // namespace

TEST(a_folder_bus_runs_its_own_components) {
    // A bus folder's effects run on its summed children (a reverb bus, a drum bus's compressor).
    ProjectSpec p = twoTracksAndABus();
    p.layers[0].parentId = "fx";
    p.layers.erase(p.layers.begin() + 1);
    ComponentSpec width;
    width.id = "org.caw.stereo.balance";  // fully left: the right side goes silent, the left stays at unity
    width.params = {{"pan", -1.0}};
    p.layers[1].components = {width};
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    std::vector<float> right;
    const auto left = run(e, 4096, 64, &right);
    CHECK_NEAR(left[4000], 0.5 * kCentre, 1e-5);
    CHECK_NEAR(right[4000], 0.0, 1e-6);
}

TEST(a_post_fader_send_adds_the_track_after_its_volume_and_pan) {
    ProjectSpec p = twoTracksAndABus();
    p.layers[0].volume = 0.5;
    p.layers[0].sends = {{"fx", 0.5, false, false}};
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    const auto out = run(e, 4096);
    // a direct (0.5 x 0.5) + b (0.25) + the send: a's post-fader signal x 0.5, through the bus at unity.
    const double a = 0.5 * 0.5 * kCentre;
    CHECK_NEAR(out[4000], a + 0.25 * kCentre + a * 0.5, 1e-5);
}

TEST(a_pre_fader_send_ignores_the_fader_but_a_muted_track_sends_nothing) {
    ProjectSpec p = twoTracksAndABus();
    p.layers[0].volume = 0.25;
    p.layers[0].sends = {{"fx", 1.0, true, false}};
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    auto out = run(e, 4096);
    // Pre-fader: the track's signal before volume and pan (a mono track gives both sides the same).
    CHECK_NEAR(out[4000], 0.5 * 0.25 * kCentre + 0.25 * kCentre + 0.5, 1e-5);

    p.layers[0].mute = true;  // mute silences the track and every send it has
    CHECK(ok(e.setProject(p)));
    out = run(e, 4096);
    CHECK_NEAR(out[4000], 0.25 * kCentre, 1e-5);

    p.layers[0].mute = false;
    p.layers[0].sends[0].mute = true;  // a muted send alone
    CHECK(ok(e.setProject(p)));
    out = run(e, 4096);
    CHECK_NEAR(out[4000], 0.5 * 0.25 * kCentre + 0.25 * kCentre, 1e-5);
}

TEST(a_send_level_changes_live_and_soloing_a_track_keeps_its_send_bus_open) {
    ProjectSpec p = twoTracksAndABus();
    p.layers[0].sends = {{"fx", 1.0, false, false}};
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    auto out = run(e, 4096);
    const double a = 0.5 * kCentre;
    CHECK_NEAR(out[4000], a + 0.25 * kCentre + a, 1e-5);
    CHECK(e.setSend("a", 0, 0.5, false, false));
    CHECK(!e.setSend("a", 1, 0.5, false, false));  // no second send
    CHECK(!e.setSend("b", 0, 0.5, false, false));
    out = run(e, 4096);
    CHECK_NEAR(out[4000], a + 0.25 * kCentre + 0.5 * a, 1e-5);

    // Solo a: b goes quiet, and the bus a sends to stays open.
    p.layers[0].sends[0].level = 0.5;
    p.layers[0].solo = true;
    CHECK(ok(e.setProject(p)));
    out = run(e, 8192);
    CHECK_NEAR(out[8000], a + 0.5 * a, 1e-5);
}

TEST(a_send_into_a_bus_with_effects_and_a_bus_sending_on) {
    // a sends into "verb" (a bus with an effect), which sends on into "fx": every route sums once.
    ProjectSpec p = twoTracksAndABus();
    LayerSpec verb = bus("verb");
    ComponentSpec left;
    left.id = "org.caw.stereo.balance";
    left.params = {{"pan", -1.0}};
    verb.components = {left};
    verb.sends = {{"fx", 1.0, false, false}};
    p.layers.push_back(verb);
    p.layers[0].sends = {{"verb", 1.0, false, false}};
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    std::vector<float> right;
    const auto out = run(e, 4096, 64, &right);
    const double a = 0.5 * kCentre;
    // Left: a + b direct, verb's left (a), and fx (verb again). Right: a + b direct; verb's right is silent.
    CHECK_NEAR(out[4000], a + 0.25 * kCentre + a + a, 1e-5);
    CHECK_NEAR(right[4000], a + 0.25 * kCentre, 1e-5);
}

TEST(sends_render_the_same_at_any_block_size) {
    ProjectSpec p = twoTracksAndABus();
    p.modules[0].source = std::string(kFloat) + "sine(110) * 0.5";
    p.layers[0].sends = {{"fx", 0.7, false, false}};
    p.layers[1].sends = {{"fx", 0.3, true, false}};
    p.layers[2].components = {transparentCompressor()};
    Engine a(48000), b(48000);
    a.setMasterBypass(true);
    b.setMasterBypass(true);
    CHECK(ok(a.setProject(p)));
    CHECK(ok(b.setProject(p)));
    a.play();
    b.play();
    const auto x = run(a, 20000, 64);
    const auto y = runUneven(b, 20000);
    bool same = true;
    for (size_t i = 0; i < x.size(); ++i) same = same && x[i] == y[i];
    CHECK(same);
}

TEST(routing_loops_are_refused_with_the_layers_named) {
    std::string error;
    ProjectSpec p;
    // Two buses sending to each other.
    CHECK(!parseProject(R"({"caw_project":1,"layers":[
        {"id":"x","name":"Verb","folder":true,"bus":true,"sends":[{"to":"y"}]},
        {"id":"y","name":"Delay","folder":true,"bus":true,"sends":[{"to":"x"}]}]})", p, error));
    CHECK(error.find("loop") != std::string::npos);
    CHECK(error.find("'Verb'") != std::string::npos && error.find("'Delay'") != std::string::npos);
    // A folder sending into a bus inside it: the bus already plays into the folder.
    CHECK(!parseProject(R"({"caw_project":1,"layers":[
        {"id":"f","folder":true,"bus":true,"sends":[{"to":"g"}]},
        {"id":"g","folder":true,"bus":true,"parent":"f"}]})", p, error));
    CHECK(error.find("loop") != std::string::npos);
    // A track keyed by its own bus.
    CHECK(!parseProject(R"({"caw_project":1,"layers":[
        {"id":"f","folder":true,"bus":true},
        {"id":"t","parent":"f","components":[{"id":"org.caw.ducker","key":{"layer":"f"}}]}]})", p, error));
    CHECK(error.find("loop") != std::string::npos);
    // Sends go to bus folders only, and to ones that exist.
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","sends":[{"to":"u"}]},{"id":"u"}]})", p, error));
    CHECK(error.find("not a bus") != std::string::npos);
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","sends":[{"to":"nowhere"}]}]})", p, error));
    CHECK(error.find("not in the project") != std::string::npos);
    // A send to the track's own folder is fine (it hears the track twice), and the fields read back.
    CHECK(parseProject(R"({"caw_project":1,"layers":[
        {"id":"f","folder":true,"bus":true},
        {"id":"t","parent":"f","sends":[{"to":"f","level":0.5,"pre":true,"mute":true}],
         "components":[{"id":"org.caw.ducker","key":{"layer":"f2","tap":"post","level":2}}]},
        {"id":"f2","folder":true,"bus":true}]})", p, error));
    CHECK_EQ(p.layers[1].sends.size(), 1u);
    CHECK_NEAR(p.layers[1].sends[0].level, 0.5, 1e-12);
    CHECK(p.layers[1].sends[0].pre && p.layers[1].sends[0].mute);
    CHECK(p.layers[1].components[0].hasKey);
    CHECK_EQ(p.layers[1].components[0].key.layer, std::string("f2"));
    CHECK(!p.layers[1].components[0].key.pre);
    CHECK_NEAR(p.layers[1].components[0].key.level, 2.0, 1e-12);
    // The engine refuses a loop built in code too, and keeps playing what it had.
    ProjectSpec q = twoTracksAndABus();
    LayerSpec other = bus("other");
    other.sends = {{"fx", 1.0, false, false}};
    q.layers.push_back(other);
    q.layers[2].sends = {{"other", 1.0, false, false}};
    Engine e(48000);
    const std::string result = e.setProject(q);
    CHECK(!ok(result));
    CHECK(result.find("loop") != std::string::npos);
}

TEST(sends_are_kept_in_time_with_latency_on_the_track_and_on_the_bus) {
    // a has a 240-frame effect and sends into fx; b has none. Everything meets in time at the master.
    ProjectSpec p = twoTracksAndABus();
    p.layers[0].components = {transparentCompressor()};
    p.layers[0].sends = {{"fx", 1.0, false, false}};
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    auto out = run(e, 1024);
    const double a = 0.5 * kCentre, bb = 0.25 * kCentre;
    CHECK_NEAR(out[200], 0.0, 1e-6);  // nothing before the latency: b waits for a
    CHECK_NEAR(out[700], a + bb + a, 2e-3);

    // The effect on the bus instead: a's direct sound and b wait for the bus.
    p.layers[0].components.clear();
    p.layers[2].components = {transparentCompressor()};
    Engine f(48000);
    f.setMasterBypass(true);
    CHECK(ok(f.setProject(p)));
    f.play();
    out = run(f, 1024);
    CHECK_NEAR(out[200], 0.0, 1e-6);
    CHECK_NEAR(out[700], a + bb + a, 2e-3);
}

TEST(a_bus_reverb_rings_on_after_stop) {
    ProjectSpec p = twoTracksAndABus();
    p.modules[0].source = std::string(kFloat) + "sine(220) * 0.5";
    p.layers.erase(p.layers.begin() + 1);
    p.layers[0].sends = {{"fx", 1.0, false, false}};
    ComponentSpec verb;
    verb.id = "org.caw.reverb.pro";
    p.layers[1].components = {verb};
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    run(e, 24000);
    e.stop();
    const auto out = run(e, 12000);
    float tail = 0;
    for (size_t i = 6000; i < out.size(); ++i) tail = std::max(tail, std::fabs(out[i]));
    CHECK(tail > 1e-4f);  // the bus's reverb tail, after the track itself has stopped
}

TEST(a_compressor_keyed_by_another_track_ducks_it_even_while_that_track_is_muted) {
    ProjectSpec p = twoTracksAndABus();
    p.layers.pop_back();  // a (the key) and b (the keyed one)
    ComponentSpec comp;
    comp.id = "org.caw.compressor";
    comp.params = {{"sidechain", 1.0}, {"threshold", -30.0}, {"ratio", 20.0}, {"knee", 0.0},
                   {"auto_makeup", 0.0}, {"attack", 0.05}};
    comp.hasKey = true;
    comp.key.layer = "a";
    p.layers[1].components = {comp};
    p.layers[0].mute = true;  // the kick is muted: it still keys the compressor
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    auto out = run(e, 9600);
    // b alone sounds, held down by about 20 dB: the key is 6 dB over the -30 dB threshold at 20:1.
    CHECK(out[9000] < 0.25 * kCentre * 0.2);
    CHECK(out[9000] > 0.0f);

    // Without the key the detector hears silence: no reduction at all.
    p.layers[1].components[0].hasKey = false;
    Engine f(48000);
    f.setMasterBypass(true);
    CHECK(ok(f.setProject(p)));
    f.play();
    out = run(f, 9600);
    CHECK_NEAR(out[9000], 0.25 * kCentre, 1e-4);

    // A key on a component without a sidechain input is ignored, with a warning.
    ProjectSpec q = p;
    q.layers[1].components[0].id = "org.caw.utility";
    q.layers[1].components[0].params.clear();
    q.layers[1].components[0].hasKey = true;
    const std::string result = f.setProject(q);
    CHECK(result.find("no sidechain input") != std::string::npos);
}

namespace {

// Track b (0.25) through a ducker; a (0.5) is its key when `keyed`. Master bypassed, a muted (it only keys).
ProjectSpec duckedB(std::vector<std::pair<std::string, double>> params, bool keyed) {
    ProjectSpec p = twoTracksAndABus();
    p.layers.pop_back();
    ComponentSpec d;
    d.id = "org.caw.ducker";
    d.params = std::move(params);
    d.hasKey = keyed;
    d.key.layer = "a";
    p.layers[1].components = {d};
    p.layers[0].mute = true;
    return p;
}

const double kQuarterOut = 0.25 * kCentre;  // b undisturbed

}  // namespace

TEST(the_ducker_in_tempo_mode_ducks_on_every_beat_with_no_input) {
    // 120 bpm at 48 kHz: a beat is 24000 frames. Attack 1 ms, hold 10 ms, release 220 ms, full depth.
    ProjectSpec p = duckedB({{"mode", 2.0}, {"rate", 5.0}, {"depth", 1.0}, {"attack", 1.0}, {"hold", 10.0},
                             {"release", 220.0}}, false);
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    const auto out = run(e, 72000);
    for (int beat = 0; beat < 3; ++beat) {
        const size_t at = static_cast<size_t>(beat) * 24000;
        CHECK(std::fabs(out[at + 300]) < 1e-3);                    // in the hold: silent
        CHECK_NEAR(out[at + 20000], kQuarterOut, 1e-4);            // recovered before the next beat
        CHECK(out[at + 3000] > 0.0f && out[at + 3000] < kQuarterOut);  // on the way back up
    }
    // Any block size, the same duck.
    Engine f(48000);
    f.setMasterBypass(true);
    CHECK(ok(f.setProject(p)));
    f.play();
    const auto uneven = runUneven(f, 72000);
    for (size_t i = 0; i < out.size(); i += 97) CHECK_NEAR(uneven[i], out[i], 1e-5);
}

TEST(the_ducker_in_audio_mode_ducks_once_per_hit_and_its_look_ahead_is_compensated) {
    // The key (a constant 0.5, -6 dB) crosses the -24 dB threshold once: one duck, then b is back.
    ProjectSpec p = duckedB({{"mode", 0.0}, {"depth", 1.0}, {"attack", 1.0}, {"hold", 10.0}, {"release", 100.0}}, true);
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    auto out = run(e, 24000);
    CHECK(std::fabs(out[400]) < 1e-3);
    CHECK_NEAR(out[20000], kQuarterOut, 1e-4);
    float display[32] = {};
    CHECK(e.componentDisplay("b", 0, display, 32) >= 18);
    CHECK(display[7] == 0.0f);  // the mode: Audio

    // Without a key there is nothing to duck to.
    Engine f(48000);
    f.setMasterBypass(true);
    CHECK(ok(f.setProject(duckedB({{"mode", 0.0}, {"depth", 1.0}}, false))));
    f.play();
    out = run(f, 4800);
    CHECK_NEAR(out[400], kQuarterOut, 1e-4);

    // A 10 ms look-ahead delays b by 480 frames (reported as latency) and the duck still leads it.
    ProjectSpec q = duckedB({{"mode", 0.0}, {"depth", 1.0}, {"attack", 1.0}, {"hold", 10.0}, {"release", 100.0},
                             {"lookahead", 4.0}}, true);
    Engine g(48000);
    g.setMasterBypass(true);
    CHECK(ok(g.setProject(q)));
    g.play();
    out = run(g, 24000);
    for (int i = 0; i < 470; ++i) CHECK(std::fabs(out[static_cast<size_t>(i)]) < 1e-6f);  // the line filling
    CHECK(std::fabs(out[600]) < 1e-3);
    CHECK(g.componentDisplay("b", 0, display, 32) >= 18);
    CHECK_NEAR(display[10], 10.0, 1e-3);
    // Turned off live, the latency goes away.
    CHECK(g.setComponentParam("b", 0, "lookahead", 0.0));
}

TEST(the_ducker_in_notes_mode_ducks_on_each_note_of_the_key_track) {
    ProjectSpec p = duckedB({{"mode", 1.0}, {"depth", 1.0}, {"attack", 0.5}, {"hold", 5.0}, {"release", 60.0}}, true);
    p.modules.push_back({"beats", "---\nkind: pattern\n---\n0 C4 1\n4 C4 1\n", {}});
    p.layers[0].pattern = "beats";  // notes on beats 1 and 2 (16th-note steps)
    p.loopBars = 1;
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    const auto out = run(e, 48000);
    CHECK(std::fabs(out[200]) < 1e-3);
    CHECK_NEAR(out[12000], kQuarterOut, 1e-4);
    CHECK(std::fabs(out[24200]) < 1e-3);
    CHECK_NEAR(out[36000], kQuarterOut, 1e-4);
}

TEST(the_ducker_ducks_only_the_lows_or_only_the_highs) {
    // b is DC: all lows. Lows ducks it; Highs leaves it alone.
    auto at = [](double bands) {
        ProjectSpec p = duckedB({{"mode", 2.0}, {"depth", 1.0}, {"attack", 1.0}, {"hold", 200.0}, {"release", 50.0},
                                 {"bands", bands}}, false);
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(ok(e.setProject(p)));
        e.play();
        return run(e, 24000);
    };
    const auto lows = at(1.0), highs = at(2.0);
    CHECK(std::fabs(lows[6000]) < 1e-3);
    CHECK_NEAR(highs[6000], kQuarterOut, 1e-3);
}
