// Mixer tests: block-size independence, loops, hot swap, mute/solo, faders, stop, play from a position, previews, count-in and live controls.
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

TEST(output_does_not_depend_on_block_size) {
    // Noise free-running, and a saw played by a pattern (notes off the block grid) through a filter.
    ProjectSpec p = project({{Shape::Noise, {{"level", 0.3}}}});
    p.modules.push_back({"pat", "---\nkind: pattern\nlength: 16\n---\n0 A2 1.3 1\n1.7 C3 2.1 0.7\n5 E3 3 0.9\n"});
    p.layers.push_back(cawtest::testSignalNotesLayer("b", Shape::Saw, "pat", {{"level", 0.4}},
                                                     {{"org.caw.filter", {}}}));
    std::vector<std::vector<float>> outs;
    for (int block : {64, 37, 512, 1}) {
        Engine e(48000);
        e.setProject(p);
        e.play();
        outs.push_back(run(e, 50000, block));
    }
    for (size_t i = 1; i < outs.size(); ++i) CHECK(outs[i] == outs[0]);
}

TEST(layers_loop_at_their_own_length) {
    // A 12-step pattern in a 16-step project restarts every 12 steps: its one-step note at 0 sounds again there,
    // and again when the project loop restarts every layer.
    ProjectSpec p = project({});
    p.modules.push_back({"pat", "---\nkind: pattern\nlength: 12\n---\n0 C4 1 1\n"});
    p.layers.push_back(cawtest::testSignalNotesLayer("l0", Shape::Dc, "pat", {{"level", 0.5}}));
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    // 120 BPM at 48 kHz: 6000 samples per 16th, so the layer loop is 72000 and the project loop 96000.
    std::vector<float> out = run(e, 200000);
    const double g = 0.5 * std::cos(kPi / 4.0);
    CHECK_EQ(e.loopLength(), int64_t{96000});
    CHECK_NEAR(out[0], g, 1e-6);
    CHECK_NEAR(out[5999], g, 1e-6);
    CHECK_NEAR(out[6000], 0.0, 1e-7);
    CHECK_NEAR(out[71999], 0.0, 1e-7);
    CHECK_NEAR(out[72000], g, 1e-6);    // layer restarts
    CHECK_NEAR(out[78000], 0.0, 1e-7);
    CHECK_NEAR(out[95999], 0.0, 1e-7);
    CHECK_NEAR(out[96000], g, 1e-6);    // project loop restarts every layer
    CHECK_NEAR(out[168000], g, 1e-6);
}

TEST(a_loop_range_loops_playback_inside_the_song) {
    // 120 BPM at 48 kHz: 6000 samples a step. The range is steps 4 to 8 (24000 to 48000) of a 16-step song.
    ProjectSpec p = project({dc(0.1)});
    p.loopRange = true;
    p.loopStartSteps = 4;
    p.loopEndSteps = 8;
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    run(e, 47999);
    CHECK_EQ(e.meters().position, int64_t{47999});
    run(e, 2);
    CHECK_EQ(e.meters().position, int64_t{24001});  // back to the range's start, not the song's
    run(e, 3 * 24000);
    CHECK_EQ(e.meters().position, int64_t{24001});  // and round again, never past its end
    // Played from after the range, the song plays to its end, then goes back to the range.
    e.play(12);
    run(e, 24000 + 10);
    CHECK_EQ(e.meters().position, int64_t{24010});
    // Off: the whole song loops, as projects without a range always have.
    p.loopRange = false;
    e.setProject(p);
    e.play(4);
    run(e, 96000);
    CHECK_EQ(e.meters().position, int64_t{24000});
}

TEST(project_file_loop_range_is_checked_and_reaches_the_song) {
    ProjectSpec p;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"loop_bars":1,"loop_range":true,"loop_start_steps":16,"loop_end_steps":40})",
        p, error));
    CHECK(p.loopRange);
    CHECK_EQ(p.loopStartSteps, 16);
    CHECK_EQ(p.loopEndSteps, 40);
    CHECK_EQ(p.loopBars, 3);  // the song reaches the range's end
    CHECK(!parseProject(R"({"caw_project":1,"loop_range":true,"loop_start_steps":8,"loop_end_steps":8})", p, error));
    CHECK(error.find("loop_start_steps") != std::string::npos);
    // Off, the range's numbers are not read: older projects have none.
    CHECK(parseProject(R"({"caw_project":1,"loop_start_steps":8})", p, error));
    CHECK(!p.loopRange);
    CHECK_EQ(p.loopBars, 4);
}

TEST(an_instrument_swap_crossfades_without_a_click) {
    Engine e(48000);
    e.setMasterBypass(true);
    ProjectSpec p = project({sine(220, 0.5)});
    e.setProject(p);
    e.play();
    std::vector<float> before = run(e, 10000);
    // Another instrument (with no notes to play): the sine crossfades out over 20 ms.
    p.layers[0].instrument = {"org.caw.synth.flagship", {}};
    std::string res = e.setProject(p);
    CHECK(res.find("\"ok\":true") != std::string::npos);
    std::vector<float> after = run(e, 10000);
    std::vector<float> all = before;
    all.insert(all.end(), after.begin(), after.end());
    CHECK(maxStep(all, 9990, 10010) < 0.05f);
    CHECK(maxStep(all, 9990, 11000) < 0.05f);
    // After the fade only the new instrument plays: silence.
    CHECK(maxStep(after, 2000, 9000) < 1e-6f);
}

TEST(a_broken_pattern_keeps_the_old_notes) {
    ProjectSpec p = project({});
    p.modules.push_back({"pat", "---\nkind: pattern\nlength: 16\n---\n0 A4 2 1\n4 C5 2 0.5\n"});
    p.layers.push_back(cawtest::testSignalNotesLayer("l0", Shape::Sine, "pat", {{"level", 0.5}}));
    Engine a(48000), b(48000);
    a.setProject(p);
    b.setProject(p);
    a.play();
    b.play();
    std::vector<float> a1 = run(a, 5000), b1 = run(b, 5000);
    ProjectSpec broken = p;
    broken.modules[0].source = "---\nkind: pattern\nlength: 16\n---\n0 A4 2 1\n4 Q9 2 0.5\n";
    std::string res = a.setProject(broken);
    CHECK(res.find("\"ok\":false") != std::string::npos);
    CHECK(res.find("\"line\":6") != std::string::npos);
    std::vector<float> a2 = run(a, 40000), b2 = run(b, 40000);
    CHECK(a1 == b1);
    CHECK(a2 == b2);
}

TEST(mute_and_solo) {
    ProjectSpec p = project({dc(0.25), dc(0.5)});
    Engine e(48000);
    e.setMasterBypass(true);
    p.layers[1].solo = true;
    e.setProject(p);
    e.play();
    const double g = std::cos(kPi / 4.0);
    std::vector<float> out = run(e, 1000);
    CHECK_NEAR(out[999], 0.5 * g, 1e-6);
    e.setLayerMix("l1", 1.0, 0.0, true, false);  // mute b, unsolo
    out = run(e, 5000);
    CHECK_NEAR(out[4999], 0.25 * g, 1e-5);
    e.setLayerMix("l0", 1.0, -1.0, false, false);  // pan a hard left
    std::vector<float> right;
    out = run(e, 5000, 64, &right);
    CHECK_NEAR(out[4999], 0.25, 1e-5);
    CHECK_NEAR(right[4999], 0.0, 1e-5);
}

TEST(track_and_master_faders_reach_plus_12_db) {
    // Owner, 2026-11-10 (feel pass): faders like REAPER's, up to +12 dB (a gain of 3.981) on tracks and the
    // master; the safety limiter stays last. They were clamped at 0 dB (gain 1).
    const double kPlus12 = std::pow(10.0, 12.0 / 20.0);
    ProjectSpec p = project({dc(0.05)});
    p.master = 1.0;
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const double g = std::cos(kPi / 4.0);
    e.setLayerMix("l0", 2.0, 0.0, false, false);
    std::vector<float> out = run(e, 5000);
    CHECK_NEAR(out[4999], 0.1 * g, 1e-5);
    e.setLayerMix("l0", 10.0, 0.0, false, false);  // past +12 dB: held there
    out = run(e, 5000);
    CHECK_NEAR(out[4999], 0.05 * kPlus12 * g, 1e-5);
    e.setLayerMix("l0", 1.0, 0.0, false, false);
    e.setMaster(2.0);
    out = run(e, 5000);
    CHECK_NEAR(out[4999], 0.1 * g, 1e-5);
    e.setMaster(10.0);
    out = run(e, 5000);
    CHECK_NEAR(out[4999], 0.05 * kPlus12 * g, 1e-5);
    // The project's own values too.
    ProjectSpec q;
    std::string error;
    CHECK(parseProject(R"({"caw_project":1,"master":3,"layers":[{"id":"t","volume":2.5},{"id":"u","volume":9}]})", q, error));
    CHECK_NEAR(q.master, 3.0, 1e-12);
    CHECK_EQ(q.layers.size(), 2u);
    if (q.layers.size() == 2) {
        CHECK_NEAR(q.layers[0].volume, 2.5, 1e-12);
        CHECK_NEAR(q.layers[1].volume, kPlus12, 1e-12);
    }
}

TEST(the_test_tone_goes_through_the_safety_limiter) {
    // A song already at the limiter's ceiling: the tone on top must not push the output past it (it used to be
    // added after the limiter and hard-clipped at 1).
    ProjectSpec p = heldProject({Shape::Sine, {}});
    p.master = 3.0;  // +9.5 dB: well into the limiter
    Engine e(48000);
    e.setProject(p);
    e.play();
    run(e, 4800);
    e.testTone(0.5);
    std::vector<float> right;
    const std::vector<float> left = run(e, 9600, 64, &right);
    float peak = 0;
    for (size_t i = 0; i < left.size(); ++i) peak = std::max({peak, std::fabs(left[i]), std::fabs(right[i])});
    CHECK(peak <= 0.9771f);
    CHECK(peak > 0.9f);
    // The tone carries on through the stop's fade and after it, at its own level.
    e.stop();
    const std::vector<float> after = run(e, 4800);
    float tail = 0;
    for (size_t i = 2400; i < after.size(); ++i) tail = std::max(tail, std::fabs(after[i]));
    CHECK(std::fabs(tail - 0.25f) < 0.02f);
}

TEST(stop_fades_to_silence_and_layers_can_be_removed) {
    ProjectSpec p = heldProject(dc(0.5));
    Engine e(48000);
    e.setMasterBypass(true);  // the master's DC blocker would ring on after the DC ends
    e.setProject(p);
    e.play();
    run(e, 2000);
    CHECK(e.meters().playing);
    e.stop();
    std::vector<float> out = run(e, 2000);
    CHECK_EQ(out[1999], 0.0f);
    CHECK(!e.meters().playing);
    // Removing every layer frees their slots for new ones.
    e.play();
    ProjectSpec empty = p;
    empty.layers.clear();
    e.setProject(empty);
    run(e, 5000);
    e.meters();
    ProjectSpec many;
    for (int i = 0; i < kInitialLayerCapacity; ++i)
        many.layers.push_back(cawtest::testSignalLayer("x" + std::to_string(i), Shape::Dc, {{"level", 0.001}}));
    e.setProject(many);
    run(e, 100);
    LayerMeter lm;
    CHECK(e.layerMeter(kInitialLayerCapacity - 1, lm) && lm.active);
}

TEST(effects_process_their_layer_only) {
    ProjectSpec p = project({dc(0.3), dc(0.3)});
    p.layers[0].components = {{"org.caw.utility", {{"gain", 20.0 * std::log10(2.0)}}}};
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    std::vector<float> out = run(e, 4000);
    CHECK_NEAR(out[3999], 0.9 * std::cos(kPi / 4.0), 1e-5);
}

TEST(a_track_runs_as_one_graph_node_with_its_inserts) {
    ProjectSpec p = project({dc(0.3)});
    p.layers[0].components = {{"org.caw.utility", {{"gain", 20.0 * std::log10(2.0)}}}, {"org.caw.utility", {}}};
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    std::vector<float> out = run(e, 4000);
    CHECK_NEAR(out[3999], 0.6 * std::cos(kPi / 4.0), 1e-5);
    CHECK_EQ(e.mixGraphNodesRun(), 2u);  // the track node (instrument and inserts) and master; idle slots never run
    CHECK_EQ(e.routingRejections(), 0u);
}

TEST(limiter_keeps_output_below_full_scale) {
    ProjectSpec p = project({{Shape::Saw, {{"freq", 110}}}, {Shape::Square, {{"freq", 170}}}, {Shape::Saw, {{"freq", 33}}}});
    Engine e(48000);
    e.setProject(p);
    e.play();
    std::vector<float> out = run(e, 48000);
    float peak = 0;
    for (float v : out) peak = std::max(peak, std::fabs(v));
    CHECK(peak <= 0.978f);
    CHECK(peak > 0.5f);
}

TEST(a_value_change_keeps_the_instrument_playing) {
    // Only the level changes: the same instrument takes the value and the sine keeps its phase, so the output is
    // exactly the new level times the same running sine, with no restart.
    ProjectSpec p = project({sine(220, 0.5)});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    run(e, 9000);
    p.layers[0].instrument.params = {{"shape", 0}, {"freq", 220}, {"level", 0.25}};
    e.setProject(p);
    std::vector<float> y = run(e, 4000);
    const double g = std::cos(kPi / 4.0);
    for (int i = 2000; i < 4000; i += 37) {
        const double n = 9000.0 + i;
        CHECK_NEAR(y[static_cast<size_t>(i)] / g, 0.25 * detSin(kTwoPi * 220.0 * n / 48000.0), 1e-4);
    }
}

TEST(master_gain_updates_without_recompiling_and_ramps_smoothly) {
    ProjectSpec p = project({dc(0.5)});
    p.master = 1.0;
    Engine e(48000);
    e.setMasterBypass(true);
    const std::string projectResult = e.setProject(p);
    CHECK(projectResult.find("\"ok\":true") != std::string::npos);
    e.play();
    run(e, 256);

    e.setMaster(0.0);
    const auto faded = run(e, 512);
    CHECK_NEAR(faded.back(), 0.0, 1e-7);
    CHECK(maxStep(faded, 0, faded.size()) < 0.01f);

    e.setMaster(2.0); // up to +12 dB: louder than before the fade
    const auto restored = run(e, 512);
    CHECK(restored.back() > 0.34f);
}

TEST(play_from_a_position_resumes_mid_loop) {
    // As in layers_loop_at_their_own_length: a 12-step pattern (72000 samples) in a 96000-sample project loop, here
    // with a one-step note on every step, each louder than the one before (velocity (k + 1) / 12).
    std::string notes = "---\nkind: pattern\nlength: 12\n---\n";
    for (int k = 0; k < 12; ++k) notes += std::to_string(k) + " C4 1 " + std::to_string((k + 1) / 12.0) + "\n";
    ProjectSpec p = project({});
    p.modules.push_back({"pat", notes});
    p.layers.push_back(cawtest::testSignalNotesLayer("l0", Shape::Dc, "pat", {{"level", 0.5}}));
    const double g = 0.5 * std::cos(kPi / 4.0);
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play(80000.0 / 6000.0);  // step 13.33 (6000 samples a step): 1.33 steps into the layer's second pass
    std::vector<float> out = run(e, 20000);
    // The note under the playhead began before it and sounds from the playhead (chased, #226), then the next one, at
    // layer step 2 (4000 on).
    CHECK_NEAR(out[1000], 2.0 / 12.0 * g, 1e-4);
    CHECK_NEAR(out[5000], 3.0 / 12.0 * g, 1e-4);
    CHECK_NEAR(out[15999], 4.0 / 12.0 * g, 1e-4);
    CHECK_NEAR(out[16000], 1.0 / 12.0 * g, 1e-4);  // the project loop wraps as usual
    Meters m = e.meters();
    CHECK_EQ(m.position, int64_t{4000});
    for (double bad : {-5.0, 16.0, 1e30, std::nan(""), static_cast<double>(INFINITY)}) {
        e.play(bad);  // outside the loop: from the start
        run(e, 64);
        CHECK_EQ(e.meters().position, int64_t{64});
    }
    // A tempo change before the play: the step lands on the same beat at the new tempo (12000 samples a step).
    p.bpm = 60;
    e.setProject(p);
    e.play(13.0);
    out = run(e, 2000);
    CHECK_NEAR(out[1000], 2.0 / 12.0 * g, 1e-4);  // it fades in over 10 ms (480 samples), so the jump doesn't click
    CHECK(std::fabs(out[100]) < std::fabs(out[1000]));
}

TEST(play_during_a_stop_fade_fades_back_in) {
    ProjectSpec p = project({dc(0.5)});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    run(e, 4800);
    e.stop();
    std::vector<float> out = run(e, 240);  // halfway through the 480-sample stop fade
    const float half = out.back();
    e.play();
    out = run(e, 1000);
    CHECK(std::fabs(out[0]) <= std::fabs(half) + 1e-6f);  // no jump back to full level
    CHECK(maxStep(out, 0, 1000) < 0.01f);
    CHECK_NEAR(out[999], 0.5 * std::cos(kPi / 4.0), 1e-5);
}

TEST(play_from_a_position_reaches_a_later_clip_on_time) {
    ProjectSpec p;
    p.bpm = 400;
    p.loopBars = 80;
    p.master = 1.0;
    p.modules.push_back({"hit", "---\nkind: pattern\nlength: 4\n---\n0 A4 4 1\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("track", Shape::Dc, "", {{"level", 0.5}});
    layer.volume = 1.0;
    layer.clips.push_back({"late", "hit", 70 * 16, 4, 0, false});  // bar 71: sample 336000 at 8 kHz
    p.layers.push_back(std::move(layer));
    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play(330000.0 / 300.0);  // 300 samples a step
    const auto out = run(e, 6400);
    CHECK_NEAR(out[5900], 0.0, 1e-7);
    CHECK(out[6000 + 300] > 0.1f);
}

// ---- Note previews (#103) ----

namespace {
// A layer playing an empty pattern on the test signal in Notes mode at level 1: each held note outputs its
// velocity, so the level shows which notes are held (and a sum of two voices shows as a jump).
ProjectSpec previewProject() {
    ProjectSpec p = project({});
    p.modules.push_back({"phrase", "---\nkind: pattern\nlength: 16\n---\n"});
    p.layers.push_back(cawtest::testSignalNotesLayer("track", Shape::Dc, "phrase"));
    return p;
}
}  // namespace

TEST(a_preview_sounds_while_stopped_and_stops_at_its_note_off_without_moving_the_transport) {
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(previewProject()).find("\"ok\":true") != std::string::npos);
    const double pan = std::cos(kPi / 4.0);
    CHECK_NEAR(run(e, 2000).back(), 0.0, 1e-9);  // stopped and silent
    e.noteOn("track", 7, 64, 0.5);
    const std::vector<float> held = run(e, 4800);
    CHECK_NEAR(held.back(), 0.5 * pan, 1e-4);
    CHECK_EQ(e.meters().position, 0);  // the transport stays where it was
    e.noteOff(7);
    const std::vector<float> after = run(e, 4800);
    CHECK_NEAR(after.back(), 0.0, 1e-6);
    CHECK_EQ(e.meters().playing, false);
}

TEST(a_held_preview_glides_to_a_new_pitch_and_the_same_id_retriggers_instead_of_stacking) {
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(previewProject());
    const double pan = std::cos(kPi / 4.0);
    e.noteOn("track", 1, 60, 0.5);
    CHECK_NEAR(run(e, 2400).back(), 0.5 * pan, 1e-4);
    e.notePitch(1, 72);  // a bend being drawn: the same voice, a 5 ms glide
    CHECK_NEAR(run(e, 2400).back(), 0.5 * pan, 1e-4);
    e.noteOn("track", 1, 48, 0.25);  // the same id again: the old note ends, one voice sounds
    CHECK_NEAR(run(e, 4800).back(), 0.25 * pan, 1e-4);
    e.noteOn("track", 2, 50, 0.125);  // another id: a chord
    CHECK_NEAR(run(e, 2400).back(), 0.375 * pan, 1e-4);
    e.notesOff();
    CHECK_NEAR(run(e, 4800).back(), 0.0, 1e-6);
}

TEST(after_stop_a_preview_hears_neither_the_chord_that_was_playing_nor_a_jump_back_to_full_level) {
    Engine e(48000);
    e.setMasterBypass(true);
    ProjectSpec p = previewProject();
    p.modules[0].source = "---\nkind: pattern\nlength: 16\n---\n0 C4 16\n";  // a note held through the loop
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    const double pan = std::cos(kPi / 4.0);
    e.play();
    CHECK_NEAR(run(e, 2400).back(), 1.0 * pan, 1e-4);
    // A preview held across Stop: the stop fades out, then the preview alone fades back in, with no step.
    e.noteOn("track", 1, 72, 0.5);
    run(e, 2400);
    e.stop();
    const std::vector<float> across = run(e, 4800);
    float step = 0;
    for (size_t i = 1; i < across.size(); ++i) step = std::max(step, std::fabs(across[i] - across[i - 1]));
    CHECK(step < 0.01f);
    CHECK_NEAR(across.back(), 0.5 * pan, 1e-4);  // the pattern's C4 doesn't come back
    e.noteOff(1);
    CHECK_NEAR(run(e, 4800).back(), 0.0, 1e-6);
    e.noteOn("track", 2, 48, 0.25);  // a fresh preview while stopped: only its own note
    CHECK_NEAR(run(e, 2400).back(), 0.25 * pan, 1e-4);
    e.notesOff();
}

TEST(a_preview_held_across_play_keeps_its_instrument_running) {
    Engine e(48000);
    e.setMasterBypass(true);
    ProjectSpec p = previewProject();  // a reset at Play would end the held note: a drop to 0
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.noteOn("track", 1, 60, 1);
    std::vector<float> out = run(e, 4801);
    e.play();
    const std::vector<float> playing = run(e, 4800);
    out.insert(out.end(), playing.begin(), playing.end());
    float step = 0;
    for (size_t i = 2400; i < out.size(); ++i) step = std::max(step, std::fabs(out[i] - out[i - 1]));
    CHECK(step < 0.001f);
    CHECK(out.back() > 0.5f);
    e.notesOff();
}

TEST(previews_follow_the_layer_mix_and_play_on_top_of_playback) {
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(previewProject());
    const double pan = std::cos(kPi / 4.0);
    e.setLayerMix("track", 1.0, 0.0, true, false);  // muted: silent
    e.noteOn("track", 1, 64, 1);
    CHECK_NEAR(run(e, 4800).back(), 0.0, 1e-6);
    e.setLayerMix("track", 0.5, 0.0, false, false);  // a preview on a muted track ended: unmuting doesn't bring it back
    CHECK_NEAR(run(e, 4800).back(), 0.0, 1e-6);
    e.noteOn("track", 1, 64, 1);
    CHECK_NEAR(run(e, 9600).back(), 0.5 * pan, 1e-3);
    e.noteOff(1);
    e.play();
    run(e, 2400);
    e.noteOn("track", 2, 32, 0.5);  // while playing: heard, and the empty pattern adds nothing
    CHECK_NEAR(run(e, 4800).back(), 0.5 * 0.5 * pan, 1e-3);
    CHECK(e.meters().position > 0);
}

// ---- Metronome, count-in and released touches (the app's recording flow and automation Touch mode) ----

namespace {
float peakIn(const std::vector<float>& v, size_t from, size_t to) {
    float m = 0;
    for (size_t i = from; i < to && i < v.size(); ++i) m = std::max(m, std::fabs(v[i]));
    return m;
}
}  // namespace

TEST(count_in_clicks_each_beat_then_plays_on_the_sample_after_the_last) {
    // 120 BPM at 48 kHz: a sixteenth is 6000 samples, a beat 24000.
    ProjectSpec p = heldProject(dc(0.25));
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.playCountIn(0, 4);
    const auto out = run(e, 4 * 24000 + 4800);
    for (int beat = 0; beat < 4; ++beat) {
        const size_t at = static_cast<size_t>(beat) * 24000;
        CHECK(peakIn(out, at, at + 600) > 0.1f);              // a click on the beat
        CHECK(peakIn(out, at + 2000, at + 23990) == 0.0f);    // and silence until the next: the song waits
    }
    CHECK(peakIn(out, 0, 600) > peakIn(out, 24000, 24600));   // the bar's first beat is accented
    const double pan = std::cos(kPi / 4.0);
    CHECK_NEAR(out[4 * 24000 + 2000], 0.25 * pan, 1e-4);      // then the song, from step 0
    CHECK(e.meters().playing);
    // A stop during a count-in cancels it.
    e.stop();
    run(e, 4800);
    e.playCountIn(0, 2);
    run(e, 1000);
    e.stop();
    const auto after = run(e, 3 * 24000);
    CHECK(!e.meters().playing);
    CHECK(peakIn(after, 0, after.size()) == 0.0f);
}

TEST(metronome_clicks_on_every_beat_while_playing_and_not_when_off) {
    ProjectSpec p = project({dc(0)});
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    CHECK(peakIn(run(e, 2 * 24000), 0, 2 * 24000) == 0.0f);  // off by default
    e.stop();
    run(e, 4800);
    e.setMetronome(true);
    e.play();
    const auto out = run(e, 2 * 24000 + 1200);
    CHECK(peakIn(out, 0, 600) > 0.1f);
    CHECK(peakIn(out, 24000, 24600) > 0.1f);
    CHECK(peakIn(out, 4000, 23990) == 0.0f);
}

TEST(released_touches_let_the_lanes_rule_again_while_playing) {
    // The test signal's level, automated by a flat lane at 0.3: a knob move is a touch over it until released.
    ProjectSpec p = project({dc(0.5)});
    ProjectAutomationLaneSpec lane;
    lane.targetType = "instrument";
    lane.moduleId = "l0";
    lane.component = 0;
    lane.target = "level";
    lane.points = {{0.0, 0.3}};
    p.automation.push_back(lane);
    Engine e(8000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const double level = run(e, 512).back();
    CHECK(level > 0.05);
    CHECK(e.setComponentParam("l0", Engine::kInstrumentIndex, "level", 0.9));  // a touch overrides the lane
    CHECK_NEAR(run(e, 512).back() / level, 3.0, 1e-4);
    e.releaseTouches();  // let go: the lane again, without a restart
    CHECK_NEAR(run(e, 512).back() / level, 1.0, 1e-4);
    CHECK(e.meters().playing);
}

TEST(track_volume_lanes_reach_plus_12_db_as_the_faders) {
    const std::string json = R"({"caw_project":1,"bpm":120,"loop_bars":1,"master":1,
      "layers":[{"id":"track","volume":1,"automation":[
        {"target":"volume","points":[{"step":0,"value":3.0},{"step":16,"value":9.0}]}]}]})";
    ProjectSpec parsed;
    std::string error;
    CHECK(parseProject(json, parsed, error));
    CHECK_NEAR(parsed.layers[0].automation[0].points[0].value, 3.0, 1e-9);
    CHECK_NEAR(parsed.layers[0].automation[0].points[1].value, kMaxMixGain, 1e-9);  // held at +12 dB
}

TEST(play_and_stop_report_whether_they_reached_the_audio_thread) {
    // API 40: 1 when the command is queued for the audio thread, 0 when its queue stayed full (audio stalled).
    CHECK_EQ(caw_engine_play(nullptr), 0);
    CHECK_EQ(caw_engine_stop(nullptr), 0);
    CawEngine* ce = caw_engine_create(48000);
    CHECK(ce != nullptr);
    CHECK_EQ(caw_engine_play(ce), 1);
    CHECK_EQ(caw_engine_play_at(ce, 4), 1);
    CHECK_EQ(caw_engine_play_count_in(ce, 0, 4), 1);
    CHECK_EQ(caw_engine_play_count_in_bars(ce, 0, 1), 1);
    CHECK_EQ(caw_engine_stop(ce), 1);
    caw_engine_destroy(ce);
    // No callback runs: the command queue fills, and a stop past it reports the failure instead of vanishing.
    Engine e(48000);
    int queued = 0;
    while (queued < 2048 && e.play()) ++queued;
    CHECK(queued >= 1000 && queued < 2048);
    CHECK(!e.stop());
    std::vector<float> l(128), r(128);
    e.process(l.data(), r.data(), 128);  // the audio thread empties the queue
    CHECK(e.stop());
}

TEST(every_live_control_reports_a_full_command_queue) {
    // Engine::send gives up on a queue that stays full; every caller says so (API 40) instead of losing it silently.
    CHECK_EQ(caw_engine_note_on(nullptr, "a", 1, 60, 1), 0);
    CHECK_EQ(caw_engine_set_master(nullptr, 1), 0);
    Engine e(48000);
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("a", cawtest::Shape::Dc, {{"level", 0.1}})});
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    std::vector<float> l(128), r(128);
    e.process(l.data(), r.data(), 128);
    CHECK_EQ(e.noteOn("a", 1, 60, 1), 1);
    CHECK_EQ(e.noteOn("missing", 2, 60, 1), -1);  // nothing to send
    CHECK_EQ(e.notePitch(9, 62), -1);
    e.setCommandRetriesForTest(2);  // a full queue gives up at once
    while (e.setMaster(1.0)) {}
    CHECK_EQ(e.noteOn("a", 3, 60, 1), 0);
    CHECK_EQ(e.notePitch(1, 62), 0);
    CHECK_EQ(e.noteOff(1), 0);
    CHECK_EQ(e.notesOff(), 0);
    CHECK(!e.setMetronome(true));
    CHECK(!e.releaseTouches());
    CHECK(!e.clearOverload());
    CHECK(!e.play());
    CHECK(!e.stop());
    e.process(l.data(), r.data(), 128);
    CHECK_EQ(e.noteOff(1), 1);  // the entry was kept, so the off still reaches the note
    CHECK_EQ(e.notesOff(), 1);
    CHECK(e.setMetronome(false));
    CHECK(e.releaseTouches());
    CHECK(e.clearOverload());
    CHECK(e.setMaster(1.0));
}
