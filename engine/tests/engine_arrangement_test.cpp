// Mixer tests: arrangement clips on the project timeline and the project parser's arrangement limits.
#include <algorithm>
#include <functional>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "caw.h"
#include "detmath.h"
#include "device_render.h"
#include "buffer_tuner.h"
#include "device_choice.h"
#include "device_period.h"
#include "engine.h"
#include "native_component_test_path.h"
#include "test.h"
#include "test_signal.h"
#include "engine_test_harness.h"

using namespace caw;
using namespace engine_test;

TEST(arrangement_clips_schedule_reusable_patterns_on_the_project_timeline) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.modules.push_back({"phrase",
        "---\nkind: pattern\nlength: 4\n---\n0 A4 2 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
    layer.name = "Track";
    layer.volume = 1.0;
    layer.clips.push_back({"clip-a", "phrase", 2, 8, 0, true});
    p.layers.push_back(layer);

    Engine e(48000);
    e.setMasterBypass(true);
    const std::string result = e.setProject(p);
    CHECK(result.find("\"ok\":true") != std::string::npos);
    e.play();
    const std::vector<float> out = run(e, 70000);
    const double panGain = std::cos(kPi / 4.0);
    CHECK_NEAR(out[1000], 0.0, 1e-7);             // before the clip
    CHECK_NEAR(out[15000], 0.5 * panGain, 1e-5);  // first source pass
    CHECK_NEAR(out[27000], 0.0, 1e-5);            // source note has ended
    CHECK_NEAR(out[39000], 0.5 * panGain, 1e-5);  // clip loops its source
}

TEST(a_muted_arrangement_clip_plays_nothing_and_the_rest_still_play) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.master = 1.0;
    p.modules.push_back({"phrase", "---\nkind: pattern\nlength: 4\n---\n0 A4 2 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
    layer.volume = 1.0;
    layer.clips.push_back({"heard", "phrase", 0, 4, 0, false});
    layer.clips.push_back({"muted", "phrase", 8, 4, 0, false, true});
    p.layers.push_back(layer);

    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 70000);
    CHECK_NEAR(out[3000], 0.5 * std::cos(kPi / 4.0), 1e-5);  // the first clip's note
    CHECK_NEAR(out[51000], 0.0, 1e-7);                         // the muted clip's note is silent

    // The project file carries it.
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"modules":[{"id":"p","source":"---\nkind: pattern\n---\n"}],
        "layers":[{"id":"t","clips":[{"id":"c","pattern":"p","mute":true},{"id":"d","pattern":"p"}]}]})", parsed, error));
    CHECK(parsed.layers.at(0).clips.at(0).mute);
    CHECK(!parsed.layers.at(0).clips.at(1).mute);
}

TEST(arrangement_clip_source_offset_trims_the_source_and_honors_non_looping) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 2;
    p.master = 1.0;
    p.modules.push_back({"phrase",
        "---\nkind: pattern\nlength: 4\n---\n0 A4 1 1\n2 C4 1 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
    layer.volume = 1.0;
    layer.clips.push_back({"trimmed", "phrase", 4, 2, 2, false});
    p.layers.push_back(layer);

    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("true") != std::string::npos);
    e.play();
    const auto out = run(e, 40000);
    const float expected = static_cast<float>(0.5 * std::cos(kPi / 4.0));
    CHECK_NEAR(out[18000], 0.0, 1e-7);            // before the trimmed clip
    CHECK_NEAR(out[27000], expected, 1e-5);       // source note at offset 2 starts at timeline step 4
    CHECK_NEAR(out[33000], 0.0, 1e-5);            // non-looping clip stops after its one source segment
}

TEST(arrangement_clip_source_offset_preserves_the_tail_of_a_sustained_note) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 2;
    p.master = 1.0;
    p.modules.push_back({"phrase",
        "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
    layer.volume = 1.0;
    layer.clips.push_back({"trimmed-sustain", "phrase", 4, 2, 2, false});
    p.layers.push_back(layer);

    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("true") != std::string::npos);
    e.play();
    const auto out = run(e, 40000);
    const float expected = static_cast<float>(0.5 * std::cos(kPi / 4.0));
    CHECK_NEAR(out[27000], expected, 1e-5); // source note began before the trim, but its tail remains
    CHECK_NEAR(out[39000], 0.0, 1e-5);      // the clip still ends at its arranged boundary
}

TEST(arrangement_clip_source_offset_preserves_remaining_ratchets) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 2;
    p.master = 1.0;
    p.modules.push_back({"phrase",
        "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1 ratchet 4\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Impulse, "", {});
    layer.volume = 1.0;
    layer.clips.push_back({"trimmed-ratchet", "phrase", 4, 2, 2, false});
    p.layers.push_back(layer);

    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("true") != std::string::npos);
    e.play();
    const auto out = run(e, 40000);
    CHECK(out[24000] > 0.5f); // third ratchet begins at the clip start
    CHECK(out[30000] > 0.5f); // fourth ratchet keeps its original spacing
    CHECK_NEAR(out[36000], 0.0, 1e-5); // clip boundary releases the final ratchet
}

TEST(arrangement_clips_can_overlap_on_one_track) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 2;
    p.master = 1.0;
    p.modules.push_back({"phrase", "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.25}});
    layer.volume = 1.0;
    layer.clips.push_back({"looping", "phrase", 0, 8, 0, true});
    layer.clips.push_back({"overlap", "phrase", 4, 4, 0, false});
    p.layers.push_back(layer);

    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("true") != std::string::npos);
    e.play();
    const auto out = run(e, 60000);
    const float oneVoice = static_cast<float>(0.25 * std::cos(kPi / 4.0));
    const float twoVoices = static_cast<float>(0.5 * std::cos(kPi / 4.0));
    CHECK_NEAR(out[18000], oneVoice, 1e-5);
    CHECK_NEAR(out[27000], twoVoices, 1e-5);       // both clips sound from step 4 to step 8
    CHECK_NEAR(out[51000], 0.0, 1e-5);             // both clips have ended
}

// A clip's own loop point (REAPER-like, owner 2026-11-11): the clip repeats its source from the offset every
// loop_steps, exactly as a pattern of that length would loop; 0 (the default) loops at the pattern's length.
TEST(arrangement_clip_loop_steps_repeat_the_source_at_the_clip_loop_point) {
    const auto render = [](const std::string& source, int loopSteps, int offset) {
        ProjectSpec p;
        p.bpm = 120;
        p.loopBars = 2;
        p.master = 1.0;
        p.modules.push_back({"phrase", source});
        LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
        layer.volume = 1.0;
        ClipSpec clip{"c", "phrase", 2, 24, offset, true};
        clip.loopSteps = loopSteps;
        layer.clips.push_back(clip);
        p.layers.push_back(layer);
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
        e.play();
        return run(e, 6000 * 30);
    };
    // An 8-step pattern looped at 4: the note at step 5 never plays, the one at 0 every 4 steps.
    const auto looped = render("---\nkind: pattern\nlength: 8\n---\n0 A4 1 1\n5 C4 2 1\n", 4, 0);
    const auto four = render("---\nkind: pattern\nlength: 4\n---\n0 A4 1 1\n", 0, 0);
    CHECK(looped == four);
    const float on = static_cast<float>(0.5 * std::cos(kPi / 4.0));
    CHECK_NEAR(looped[6000 * 6 + 3000], on, 1e-5);   // step 6: the second pass's note
    CHECK_NEAR(looped[6000 * 7 + 3000], 0.0, 1e-5);  // step 7 (source step 5): cut by the loop point

    // A loop point past the pattern's end plays silence up to it, as a longer pattern would.
    const auto longer = render("---\nkind: pattern\nlength: 4\n---\n0 A4 1 1\n", 6, 0);
    const auto six = render("---\nkind: pattern\nlength: 6\n---\n0 A4 1 1\n", 0, 0);
    CHECK(longer == six);

    // The offset counts inside the clip's loop, as it does inside a pattern.
    CHECK(render("---\nkind: pattern\nlength: 8\n---\n0 A4 1 1\n3 C4 1 1\n6 E4 1 1\n", 4, 3) ==
          render("---\nkind: pattern\nlength: 4\n---\n0 A4 1 1\n3 C4 1 1\n", 0, 3));

    // 0 and the pattern's own length play the same; existing projects (no loop_steps) are unchanged.
    CHECK(render("---\nkind: pattern\nlength: 4\n---\n0 A4 1 1\n", 4, 0) == four);

    // The project file carries it, and refuses what it can't be.
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"modules":[{"id":"p","source":"---\nkind: pattern\n---\n"}],
        "layers":[{"id":"t","clips":[{"id":"c","pattern":"p","loop_steps":12},{"id":"d","pattern":"p"}]}]})", parsed, error));
    CHECK_EQ(parsed.layers.at(0).clips.at(0).loopSteps, 12);
    CHECK_EQ(parsed.layers.at(0).clips.at(1).loopSteps, 0);
    CHECK(!parseProject(R"({"caw_project":1,"layers":[{"id":"t","clips":[{"id":"c","pattern":"p","loop_steps":-1}]}]})",
        parsed, error));
    CHECK(error.find("clip 'c' of layer 't': loop_steps must be") != std::string::npos);
}

TEST(project_parser_keeps_arrangements_past_64_bars) {
    // F7.2 (owner, 2026-11-04): nothing is moved or shortened; the old 64-bar song limit is gone.
    const std::string json = R"({"caw_project":1,"beats_per_bar":3,"loop_bars":1000,"layers":[
      {"id":"t","length_steps":200000,
       "clips":[{"id":"c","pattern":"p","start_steps":100000,"length_steps":50000,"source_offset_steps":900}],
       "automation":[{"target":"volume","points":[{"step":250000,"value":0.5}]}]}
    ],"automation":[{"target_type":"global","target":"swing","points":[{"step":300000,"value":1}]}],
    "audition":{"length_steps":400000}})";
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(json, p, error));
    CHECK_EQ(p.layers[0].lengthSteps, 200000);
    CHECK_EQ(p.layers[0].clips[0].startSteps, 100000);
    CHECK_EQ(p.layers[0].clips[0].lengthSteps, 50000);
    CHECK_EQ(p.layers[0].clips[0].sourceOffsetSteps, 900);
    CHECK_NEAR(p.layers[0].automation[0].points[0].step, 250000, 1e-9);
    CHECK_NEAR(p.automation[0].points[0].step, 300000, 1e-9);
    CHECK_EQ(p.auditionSteps, 400000);
    CHECK_EQ(p.loopBars, 25000);  // project automation lengthens the loop to reach its last point (300000 / 12)
}

TEST(project_parser_refuses_arrangement_values_it_cannot_represent) {
    // The step position is a 32-bit int, so a song holds whole bars up to 2^31 - 1 steps.
    const int maxBars3 = 2147483647 / 12;
    const int maxSteps3 = maxBars3 * 12;
    CHECK_EQ(maxLoopBars(3), maxBars3);
    CHECK_EQ(maxArrangementSteps(3), maxSteps3);
    const auto refused = [](const std::string& body, const std::string& message) {
        ProjectSpec p;
        std::string error;
        const bool ok = parseProject(R"({"caw_project":1,"beats_per_bar":3,)" + body + "}", p, error);
        CHECK(!ok);
        CHECK(error.find(message) != std::string::npos);
        if (ok || error.find(message) == std::string::npos) std::printf("    got: %s\n", error.c_str());
    };
    refused(R"("loop_bars":0)", "loop_bars must be a whole number from 1 to");
    refused(R"("loop_bars":)" + std::to_string(maxBars3 + 1), "loop_bars must be a whole number from 1 to");
    refused(R"("loop_bars":2.5)", "loop_bars must be a whole number from 1 to");
    refused(R"("layers":[{"id":"t","length_steps":-1}])", "layer 't': length_steps must be");
    refused(R"("layers":[{"id":"t","clips":[{"id":"c","pattern":"p","start_steps":-1}]}])",
        "clip 'c' of layer 't': start_steps must be");
    refused(R"("layers":[{"id":"t","clips":[{"id":"c","pattern":"p","length_steps":0}]}])",
        "clip 'c' of layer 't': length_steps must be");
    refused(R"("layers":[{"id":"t","clips":[{"id":"c","pattern":"p","start_steps":)" + std::to_string(maxSteps3 - 10) +
        R"(,"length_steps":11}]}])", "clip 'c' of layer 't' ends after step");
    refused(R"("layers":[{"id":"t","clips":[{"id":"c","pattern":"p","source_offset_steps":-3}]}])",
        "clip 'c' of layer 't': source_offset_steps must be");
    refused(R"("layers":[{"id":"t","automation":[{"target":"pan","points":[{"step":-1,"value":0}]}]}])",
        "layer 't': automation point steps must be");
    refused(R"("automation":[{"target_type":"global","target":"g","points":[{"step":)" + std::to_string(maxSteps3 + 1) +
        R"(,"value":0}]}])", "automation point steps must be");
    refused(R"("audition":{"length_steps":-5})", "audition length_steps must be");

    // The largest values are accepted, and the loop reaches the last automation point without overflowing.
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"beats_per_bar":3,"layers":[{"id":"t","clips":[{"id":"c","pattern":"p","start_steps":)" +
        std::to_string(maxSteps3 - 10) + R"(,"length_steps":10}]}],"automation":[{"target_type":"global","target":"g","points":[{"step":)" +
        std::to_string(maxSteps3) + R"(,"value":0}]}]})", p, error));
    CHECK_EQ(p.loopBars, maxBars3);
    CHECK_EQ(p.loopSteps(), maxSteps3);
}

TEST(arrangement_plays_clips_past_bar_64) {
    ProjectSpec p;
    p.bpm = 400;  // a step is 0.0375 s
    p.loopBars = 80;
    p.master = 1.0;
    p.modules.push_back({"hit", "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
    layer.volume = 1.0;
    layer.clips.push_back({"late", "hit", 70 * 16, 4, 0, false});  // bar 71
    p.layers.push_back(std::move(layer));
    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 336000 + 400);  // 1120 steps * 0.0375 s * 8000 Hz
    CHECK_NEAR(out[330000], 0.0, 1e-7);
    CHECK(out[336000 + 300] > 0.1f);
}

TEST(arrangement_expansion_is_refused_above_the_project_state_budget) {
    // A looping clip of a one-step pattern over most of the int range would expand to billions of notes.
    HardwareProfile hardware;
    hardware.memoryBudgetMiB = 2;
    Engine e(8000, makeEngineResourceBudget(hardware));
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"tick", "---\nkind: pattern\nlength: 1\n---\n0 C4 1 1\n"});
    p.modules.push_back({"rest", "---\nkind: pattern\nlength: 1\n---\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {});
    layer.clips.push_back({"huge", "tick", 0, 2000000000, 0, true});
    p.layers.push_back(layer);
    const std::string result = e.setProject(p);
    CHECK(result.find("\"ok\":false") != std::string::npos);
    CHECK(result.find("arrangement") != std::string::npos);
    CHECK(result.find("project-state budget") != std::string::npos);

    // The check leaves room for building: growing vectors and the sort's buffer take about three times the result.
    const uint64_t perRepeat = sizeof(PatternNote) + 2 * sizeof(PatternEvent);
    p.layers[0].clips = {{"half", "tick", 0, static_cast<int>(e.resourceBudget().projectStateBytes / 2 / perRepeat), 0, true}};
    const std::string half = e.setProject(p);
    CHECK(half.find("\"ok\":false") != std::string::npos);
    CHECK(half.find("arrangement") != std::string::npos);
    p.layers[0].clips = {{"small", "tick", 0, static_cast<int>(e.resourceBudget().projectStateBytes / 8 / perRepeat), 0, true}};
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);

    // A looping clip of an empty pattern expands to nothing, and compiling it doesn't walk every repeat.
    p.layers[0].clips = {{"silent", "rest", 0, 2000000000, 0, true}};
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
}

TEST(project_parser_preserves_large_module_and_clip_lists) {
    std::string json = R"({"caw_project":1,"modules":[)";
    for (int i = 0; i < 300; ++i) {
        if (i) json += ",";
        json += R"({"id":"module_)" + std::to_string(i) + R"(","source":"0"})";
    }
    json += R"(],"layers":[{"id":"track","clips":[)";
    for (int i = 0; i < 520; ++i) {
        if (i) json += ",";
        json += R"({"id":"clip_)" + std::to_string(i) + R"(","pattern":"pattern","start_steps":0,"length_steps":1})";
    }
    json += R"(]}]})";
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(json, parsed, error));
    CHECK_EQ(parsed.modules.size(), size_t{300});
    CHECK_EQ(parsed.layers.size(), size_t{1});
    CHECK_EQ(parsed.layers[0].clips.size(), size_t{520});
    CHECK_EQ(parsed.layers[0].clips.back().id, std::string("clip_519"));
}

TEST(arrangement_compilation_keeps_notes_beyond_4096) {
    ProjectSpec p;
    p.bpm = 400;
    p.loopBars = 64;
    p.master = 1.0;
    p.modules.push_back({"chord",
        "---\nkind: pattern\nlength: 1\n---\n0 C3,D3,E3,F3,G3,A3,B3,C4,D4 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.1}});
    layer.volume = 1.0;
    for (int i = 0; i < 520; ++i)
        layer.clips.push_back({"clip_" + std::to_string(i), "chord", i, 1, 0, false});
    p.layers.push_back(std::move(layer));

    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 150100);
    CHECK(out[150000] > 0.05f); // clip 500 starts after the former 4096-note truncation point
}

TEST(project_parser_preserves_large_project_automation) {
    std::string json = R"({"caw_project":1,"automation":[)";
    for (int lane = 0; lane < 257; ++lane) {
        if (lane) json += ",";
        json += R"({"target_type":"global","target":"g)" + std::to_string(lane) + R"(","points":[)";
        for (int point = 0; point < 129; ++point) {
            if (point) json += ",";
            json += R"({"step":)" + std::to_string(point) + R"(,"value":0.5})";
        }
        json += "]}";
    }
    json += "]}";
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(json, parsed, error));
    CHECK_EQ(parsed.automation.size(), size_t{257});
    CHECK_EQ(parsed.automation.back().points.size(), size_t{129});
    CHECK_NEAR(parsed.automation.back().points.back().step, 128.0, 1e-9);
}
