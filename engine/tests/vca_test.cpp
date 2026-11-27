// VCA groups (vca.h): a group's fader, mute and solo over its members' levels, its volume lane, and the parser's limits.
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "engine.h"
#include "project.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;
using cawtest::Shape;

namespace {

const double kCentre = std::cos(3.14159265358979323846 / 4.0);  // a mono track's pan law at centre

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

LayerSpec track(const std::string& id, double level) { return cawtest::testSignalLayer(id, Shape::Dc, {{"level", level}}); }

LayerSpec bus(const std::string& id) {
    LayerSpec l;
    l.id = l.name = id;
    l.folder = true;
    l.busEnabled = true;
    l.volume = 1.0;
    return l;
}

VcaGroupSpec group(const std::string& id, double volume, std::vector<std::string> members) {
    VcaGroupSpec g;
    g.id = g.name = id;
    g.volume = volume;
    g.members = std::move(members);
    return g;
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

std::vector<float> render(const ProjectSpec& p, int64_t frames, int block = 64) {
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    std::vector<float> right;
    std::vector<float> out = run(e, frames, block, &right);
    out.insert(out.end(), right.begin(), right.end());
    return out;
}

bool sameBits(const std::vector<float>& a, const std::vector<float>& b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}

// The largest frame-to-frame change of the left output across a project update while playing (a DC signal: any step
// is the gain jumping), and the output's last frame.
double worstStep(const ProjectSpec& from, const ProjectSpec& to, double* last = nullptr, int block = 64) {
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(from)));
    e.play();
    const auto before = run(e, 9600, block);
    CHECK(ok(e.setProject(to)));
    const auto after = run(e, 19200, block);
    double worst = std::fabs(static_cast<double>(after[0]) - before.back());
    for (size_t i = 1; i < after.size(); ++i) worst = std::max(worst, std::fabs(static_cast<double>(after[i]) - after[i - 1]));
    if (last) *last = after.back();
    return worst;
}

std::string parseError(const std::string& json) {
    ProjectSpec p;
    std::string error;
    return parseProject(json, p, error) ? std::string() : error;
}

}  // namespace

TEST(a_vca_scales_its_members_and_not_the_others) {
    ProjectSpec p = cawtest::testSignalProject({track("a", 0.5), track("b", 0.25)});
    p.layers[1].outputId = kMasterOutput;
    p.vcaGroups = {group("v", 0.5, {"a"})};
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    auto out = run(e, 4096);
    CHECK_NEAR(out[4000], (0.5 * 0.5 + 0.25) * kCentre, 1e-5);
    CHECK(e.setVca("v", 0.25, false, false));
    CHECK(!e.setVca("nope", 0.25, false, false));
    out = run(e, 8192);
    CHECK_NEAR(out[8000], (0.5 * 0.25 + 0.25) * kCentre, 1e-5);
    // The member's own fader still counts: the VCA multiplies it.
    e.setLayerMix("a", 0.5, 0.0, false, false);
    out = run(e, 8192);
    CHECK_NEAR(out[8000], (0.5 * 0.5 * 0.25 + 0.25) * kCentre, 1e-5);
    // A project without the group drops it: back to the track's own level.
    p.vcaGroups.clear();
    CHECK(ok(e.setProject(p)));
    CHECK(!e.setVca("v", 0.25, false, false));
    out = run(e, 8192);
    CHECK_NEAR(out[8000], (0.5 + 0.25) * kCentre, 1e-5);
}

TEST(a_vca_multiplies_after_a_members_volume_lane) {
    ProjectSpec p = cawtest::testSignalProject({track("a", 0.5)});
    p.layers[0].automation = {AutomationLaneSpec{"volume", {{0, 0.5}, {64, 0.5}}}};
    p.vcaGroups = {group("v", 0.5, {"a"})};
    const auto out = render(p, 4096);
    CHECK_NEAR(out[4000], 0.5 * 0.5 * 0.5 * kCentre, 1e-5);
}

TEST(a_vca_mute_silences_members_without_their_own_mute) {
    ProjectSpec p = cawtest::testSignalProject({track("a", 0.5)});
    p.vcaGroups = {group("v", 1.0, {"a"})};
    p.vcaGroups[0].mute = true;
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    auto out = run(e, 4096);
    CHECK_NEAR(out[4000], 0.0, 1e-9);
    e.setLayerMix("a", 1.0, 0.0, false, false);  // the track's own mute is off: the group's still holds it
    out = run(e, 4096);
    CHECK_NEAR(out[4000], 0.0, 1e-9);
    CHECK(e.setVca("v", 1.0, false, false));
    out = run(e, 4096);
    CHECK_NEAR(out[4000], 0.5 * kCentre, 1e-5);
    e.setLayerMix("a", 1.0, 0.0, true, false);  // its own mute still works under the group
    out = run(e, 4096);
    CHECK_NEAR(out[4000], 0.0, 1e-9);
}

TEST(a_vca_solo_solos_its_members) {
    ProjectSpec p = cawtest::testSignalProject({track("a", 0.5), track("b", 0.25), track("c", 0.125)});
    p.vcaGroups = {group("v", 1.0, {"a", "b"})};
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(p)));
    e.play();
    auto out = run(e, 4096);
    CHECK_NEAR(out[4000], 0.875 * kCentre, 1e-5);
    CHECK(e.setVca("v", 1.0, false, true));
    out = run(e, 4096);
    CHECK_NEAR(out[4000], 0.75 * kCentre, 1e-5);  // c is soloed out
    e.setLayerMix("c", 1.0, 0.0, false, true);  // c's own solo joins the group's
    out = run(e, 4096);
    CHECK_NEAR(out[4000], 0.875 * kCentre, 1e-5);
    CHECK(e.setVca("v", 1.0, false, false));
    out = run(e, 4096);
    CHECK_NEAR(out[4000], 0.125 * kCentre, 1e-5);  // only c's own solo is left
}

TEST(a_vca_solo_keeps_open_the_buses_its_members_play_through) {
    // a plays in bus f, which sends to return r; b is outside. Soloing the group of a alone keeps f and r open.
    LayerSpec f = bus("f");
    LayerSpec r = bus("r");
    SendSpec s;
    s.to = "r";
    f.sends = {s};
    LayerSpec a = track("a", 0.5);
    a.parentId = "f";
    ProjectSpec p = cawtest::testSignalProject({f, r, a, track("b", 0.125)});
    p.vcaGroups = {group("v", 1.0, {"a"})};
    p.vcaGroups[0].solo = true;
    auto out = render(p, 4096);
    CHECK_NEAR(out[4000], 2 * 0.5 * kCentre, 1e-5);  // a through f, and f's send through r; b soloed out
    p.vcaGroups = {group("v", 1.0, {"f"})};  // a folder's solo solos what is in it
    p.vcaGroups[0].solo = true;
    out = render(p, 4096);
    CHECK_NEAR(out[4000], 2 * 0.5 * kCentre, 1e-5);
}

TEST(a_folder_bus_member_scales_its_fader_and_a_child_member_twice) {
    LayerSpec f = bus("f");
    LayerSpec a = track("a", 0.5);
    a.parentId = "f";
    ProjectSpec p = cawtest::testSignalProject({f, a});
    p.vcaGroups = {group("v", 0.5, {"f"})};
    auto out = render(p, 4096);
    CHECK_NEAR(out[4000], 0.5 * 0.5 * kCentre, 1e-5);
    p.vcaGroups = {group("v", 0.5, {"f", "a"})};  // as REAPER: the child is scaled by its own and its bus's membership
    out = render(p, 4096);
    CHECK_NEAR(out[4000], 0.5 * 0.25 * kCentre, 1e-5);
}

TEST(a_post_fader_send_follows_the_vca) {
    LayerSpec r = bus("r");
    LayerSpec a = track("a", 0.5);
    SendSpec s;
    s.to = "r";
    s.level = 1.0;
    a.sends = {s};
    ProjectSpec p = cawtest::testSignalProject({r, a});
    auto out = render(p, 4096);
    const double plain = out[4000];
    CHECK_NEAR(plain, 2 * 0.5 * kCentre, 1e-5);  // the track and its post send
    p.vcaGroups = {group("v", 0.5, {"a"})};
    out = render(p, 4096);
    CHECK_NEAR(out[4000], plain * 0.5, 1e-5);
    p.layers[1].sends[0].pre = true;  // a pre-fader send does not: only the track's own output halves
    out = render(p, 4096);
    p.vcaGroups.clear();
    const double prePlain = render(p, 4096)[4000];
    CHECK_NEAR(out[4000], prePlain - 0.5 * 0.5 * kCentre, 1e-5);
}

TEST(a_vca_lane_and_fader_moves_ramp_without_steps) {
    // 120 bpm at 48 kHz: 6000 frames a step. The lane falls from 1 to 0 over 16 steps.
    ProjectSpec p = cawtest::testSignalProject({track("a", 0.5)});
    p.vcaGroups = {group("v", 1.0, {"a"})};
    p.vcaGroups[0].volumeLane = {{0, 1.0}, {16, 0.0}};
    const auto out = render(p, 96000, 37);
    double worst = 0;
    for (size_t i = 1; i < 96000; ++i) {
        CHECK(out[i] <= out[i - 1] + 1e-7f);
        worst = std::max(worst, std::fabs(static_cast<double>(out[i]) - out[i - 1]));
    }
    CHECK(worst < 1e-5);  // a straight fall of 0.35 over 96000 frames: about 4e-6 a frame, with no chunk steps
    CHECK_NEAR(out[48000], 0.5 * 0.5 * kCentre, 1e-4);
    // A jump of the fader is smoothed as a track fader's is (about 5 ms).
    Engine e(48000);
    e.setMasterBypass(true);
    p.vcaGroups[0].volumeLane.clear();
    CHECK(ok(e.setProject(p)));
    e.play();
    auto before = run(e, 4096);
    CHECK(e.setVca("v", 0.0, false, false));
    auto after = run(e, 9600);
    double step = std::fabs(static_cast<double>(after[0]) - before.back());
    for (size_t i = 1; i < after.size(); ++i) step = std::max(step, std::fabs(static_cast<double>(after[i]) - after[i - 1]));
    CHECK(step < 0.01);
    CHECK_NEAR(after.back(), 0.0, 1e-6);
}

TEST(projects_without_vca_members_render_the_same_bits) {
    ProjectSpec p = cawtest::testSignalProject({track("a", 0.5), cawtest::testSignalLayer("b", Shape::Saw, {{"level", 0.3}})});
    const auto plain = render(p, 8192, 100);
    p.vcaGroups = {group("v", 0.5, {})};  // a group with no members changes nothing
    CHECK(sameBits(render(p, 8192, 100), plain));
}

TEST(vca_groups_are_parsed_with_limits) {
    const std::string head = R"({"caw_project":1,"layers":[{"id":"a"},{"id":"b"}],"vca_groups":)";
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(head + R"([{"id":"v","name":"Drums","volume":9,"mute":true,"members":["a","zz","a","b"],
        "automation":[{"target":"volume","points":[{"step":8,"value":0.25},{"step":0,"value":0.5}]}]}]})", p, error));
    CHECK_EQ(p.vcaGroups.size(), 1u);
    const VcaGroupSpec& g = p.vcaGroups[0];
    CHECK(g.name == "Drums");
    CHECK_NEAR(g.volume, kMaxMixGain, 1e-12);
    CHECK(g.mute && !g.solo);
    CHECK_EQ(g.members.size(), 2u);  // the unknown id and the repeat are left out
    CHECK(g.members[0] == "a" && g.members[1] == "b");
    CHECK_EQ(g.volumeLane.size(), 2u);
    CHECK_NEAR(g.volumeLane[0].value, 0.5, 1e-12);  // sorted by step
    CHECK(parseProject(R"({"caw_project":1,"layers":[{"id":"a"}]})", p, error));
    CHECK(p.vcaGroups.empty());
    CHECK(parseError(head + R"({"id":"v"}})").find("vca_groups must be a list") != std::string::npos);
    CHECK(parseError(head + R"([{"id":"v"},{"id":"v"}]})").find("used twice") != std::string::npos);
    CHECK(parseError(head + R"([{"name":"x"}]})").find("needs an id") != std::string::npos);
    CHECK(parseError(head + R"([3]})").find("must be an object") != std::string::npos);
    CHECK(parseError(head + R"([{"id":"v","members":[1]}]})").find("must be layer ids") != std::string::npos);
    CHECK(parseError(head + R"([{"id":"v","members":"a"}]})").find("members must be a list") != std::string::npos);
    CHECK(parseError(head + R"([{"id":"v","automation":{}}]})").find("automation must be a list") != std::string::npos);
    CHECK(parseError(head + R"([{"id":"v","automation":[{"points":[{"step":-1,"value":1}]}]}]})").find("steps must be") !=
          std::string::npos);
    std::string many = "[";
    for (int i = 0; i <= kMaxVcaGroups; ++i) many += std::string(i ? "," : "") + R"({"id":"g)" + std::to_string(i) + "\"}";
    CHECK(parseError(head + many + "]}").find("at most 32 VCA groups") != std::string::npos);
    std::string members = "[";
    for (int i = 0; i <= kMaxVcaMembers; ++i) members += std::string(i ? "," : "") + "\"a\"";
    CHECK(parseError(head + R"([{"id":"v","members":)" + members + "]}]}").find("at most 256") != std::string::npos);
    // The engine takes the JSON too, and refuses a bad one by name.
    Engine e(48000);
    CHECK(e.setProjectJson(head + R"([{"id":"v"},{"id":"v"}]})").find("used twice") != std::string::npos);
}

TEST(joining_leaving_creating_and_deleting_a_group_while_playing_never_jumps) {
    // a DC of 0.5: a jump of a gain by 0.5 would step the output by 0.18; the faders' 5 ms pole moves it at most
    // 0.5 * 0.5 * 0.707 * 0.0042 = 7e-4 a frame.
    const double bound = 1.5e-3;
    ProjectSpec none = cawtest::testSignalProject({track("a", 0.5), track("b", 0.25)});
    ProjectSpec in = none;
    in.vcaGroups = {group("v", 0.25, {"a"})};
    ProjectSpec out = none;
    out.vcaGroups = {group("v", 0.25, {})};
    double last = 0;
    CHECK(worstStep(none, in, &last) < bound);  // a new group at a level not 1
    CHECK_NEAR(last, (0.5 * 0.25 + 0.25) * kCentre, 1e-5);
    CHECK(worstStep(in, out, &last) < bound);  // a member leaves
    CHECK_NEAR(last, 0.75 * kCentre, 1e-5);
    CHECK(worstStep(out, in) < bound);  // and joins
    CHECK(worstStep(in, none, &last) < bound);  // the group is deleted
    CHECK_NEAR(last, 0.75 * kCentre, 1e-5);
    ProjectSpec two = in;  // a second group joins the first
    two.vcaGroups.push_back(group("w", 3.0, {"a", "b"}));
    CHECK(worstStep(in, two, &last) < 3 * bound);
    CHECK_NEAR(last, (0.5 * 0.25 * 3.0 + 0.25 * 3.0) * kCentre, 1e-5);
}

TEST(a_lane_added_or_taken_away_while_playing_never_jumps) {
    ProjectSpec fader = cawtest::testSignalProject({track("a", 0.5)});
    fader.vcaGroups = {group("v", 1.0, {"a"})};
    ProjectSpec lane = fader;
    lane.vcaGroups[0].volumeLane = {{0, 0.25}, {64, 0.25}};
    double last = 0;
    CHECK(worstStep(fader, lane, &last) < 1.5e-3);
    CHECK_NEAR(last, 0.5 * 0.25 * kCentre, 1e-5);
    CHECK(worstStep(lane, fader, &last) < 1.5e-3);
    CHECK_NEAR(last, 0.5 * kCentre, 1e-5);
}

TEST(a_vca_lane_renders_the_same_bits_at_any_buffer_size) {
    // Curved and held segments, as a track's lane: read at every frame, so the chunks don't show.
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("a", Shape::Saw, {{"level", 0.4}})});
    p.vcaGroups = {group("v", 1.0, {"a"})};
    p.vcaGroups[0].volumeLane = {{0, 1.0, 1, 0.6}, {4, 0.2, 4, 0}, {6, 0.9, 3, -0.4}, {12, 0.1}};
    const auto small = render(p, 96000, 37);
    CHECK(sameBits(render(p, 96000, 512), small));
    CHECK(sameBits(render(p, 96000, 64), small));
}

TEST(a_folder_without_a_bus_moves_its_tracks) {
    LayerSpec f;
    f.id = f.name = "f";
    f.folder = true;
    f.busEnabled = false;
    LayerSpec a = track("a", 0.5);
    a.parentId = "f";
    LayerSpec g = bus("g");  // a bus inside it takes the level once, for what plays through it
    g.parentId = "f";
    LayerSpec b = track("b", 0.25);
    b.parentId = "g";
    ProjectSpec p = cawtest::testSignalProject({f, a, g, b, track("c", 0.125)});
    p.vcaGroups = {group("v", 0.5, {"f"})};
    auto out = render(p, 4096);
    CHECK_NEAR(out[4000], ((0.5 + 0.25) * 0.5 + 0.125) * kCentre, 1e-5);
    p.vcaGroups[0].mute = true;
    out = render(p, 4096);
    CHECK_NEAR(out[4000], 0.125 * kCentre, 1e-5);
}

TEST(a_slots_vca_gain_is_held_to_plus_12_db) {
    ProjectSpec p = cawtest::testSignalProject({track("a", 0.125)});
    for (int g = 0; g < kMaxVcaGroups; ++g) p.vcaGroups.push_back(group("g" + std::to_string(g), kMaxMixGain, {"a"}));
    const auto out = render(p, 4096);
    CHECK_NEAR(out[4000], 0.125 * kMaxMixGain * kCentre, 1e-5);
}

TEST(members_at_unity_render_the_same_bits_as_no_group) {
    LayerSpec f = bus("f");
    LayerSpec a = cawtest::testSignalLayer("a", Shape::Saw, {{"level", 0.3}});
    a.parentId = "f";
    ProjectSpec p = cawtest::testSignalProject({f, a, cawtest::testSignalLayer("b", Shape::Sine, {{"level", 0.2}})});
    const auto plain = render(p, 8192, 100);
    p.vcaGroups = {group("v", 1.0, {"f", "a", "b"})};  // the members take their plain paths: exactly 1 throughout
    CHECK(sameBits(render(p, 8192, 100), plain));
}

TEST(a_layer_new_in_a_slot_never_runs_under_its_last_owners_groups) {
    ProjectSpec first = cawtest::testSignalProject({track("a", 0.5)});
    first.vcaGroups = {group("v", 0.25, {"a"})};
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(ok(e.setProject(first)));
    e.play();
    run(e, 4096);
    ProjectSpec gone = cawtest::testSignalProject({});
    gone.vcaGroups = {group("v", 0.25, {})};
    CHECK(ok(e.setProject(gone)));
    run(e, 48000);  // a's slot fades out and is free again
    ProjectSpec next = cawtest::testSignalProject({track("b", 0.5)});  // b takes a's slot, in no group
    next.vcaGroups = {group("v", 0.25, {})};
    CHECK(ok(e.setProject(next)));
    const auto out = run(e, 4096);
    for (size_t i = 0; i < out.size(); ++i)
        if (out[i] > 1e-6f) CHECK(out[i] > 0.4 * kCentre);  // b at its own level from its first sound, no VCA ramp
    CHECK_NEAR(out[4000], 0.5 * kCentre, 1e-5);
}

