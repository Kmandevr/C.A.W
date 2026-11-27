// MIDI out and the MIDI clock (API 47): a MIDI-out layer's bytes and times, notes ended on stop and mute, the queue's
// limits, clock out across a tempo change and its transport messages, and following an incoming clock.
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include "caw.h"
#include "engine.h"
#include "midi_clock.h"
#include "midi_out.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

constexpr int64_t kT0 = 5'000'000'000;  // the test's MIDI clock at the first callback
constexpr int kCb = 480;                 // 10 ms callbacks at 48 kHz: the clock moves 10 ms a callback

std::string project(const std::string& layers, const std::string& extra = "", int bars = 1) {
    return std::string("{\"bpm\":120,\"beats_per_bar\":4,\"loop_bars\":") + std::to_string(bars) + extra +
           ",\"modules\":[{\"id\":\"p\",\"source\":\"---\\nkind: pattern\\nname: p\\nlength: 16\\n---\\n"
           "0 C4 2 1\\n4 E4 8 0.5\\n\"}],\"layers\":[" + layers + "]}";
}
const std::string kMidiLayer = "{\"id\":\"m\",\"pattern\":\"p\",\"midiOut\":{\"port\":2,\"channel\":3,\"program\":5}}";

struct Run {
    Run() { e.setMidiOutActive(true); }  // a sender is attached
    Engine e{48000};
    std::vector<float> l = std::vector<float>(kCb), r = std::vector<float>(kCb);
    int callbacks = 0;
    std::vector<MidiOutMessage> got;
    void cb(int n = 1) {
        for (int k = 0; k < n; ++k) {
            e.setMidiClockForTest(kT0 + static_cast<int64_t>(callbacks) * 10'000'000);
            e.process(l.data(), r.data(), kCb);
            ++callbacks;
            MidiOutMessage buf[256];
            for (int32_t c; (c = e.midiOutDrain(buf, 256)) > 0;) got.insert(got.end(), buf, buf + c);
        }
    }
    std::vector<MidiOutMessage> with(uint8_t status) const {
        std::vector<MidiOutMessage> out;
        for (const MidiOutMessage& m : got)
            if (m.data[0] == status) out.push_back(m);
        return out;
    }
};

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

// A deterministic jitter source: uniform in [-1, 1).
struct Lcg {
    uint32_t s = 12345;
    double next() {
        s = s * 1664525u + 1013904223u;
        return static_cast<double>(s >> 8) / 8388608.0 - 1.0;
    }
};

}  // namespace

TEST(midi_out_layer_sends_its_notes_at_their_times) {
    Run t;
    CHECK(ok(t.e.setProjectJson(project(kMidiLayer))));
    t.e.setOutputLatencyNs(5'000'000);
    t.e.setMidiOutPortOffset(2, 1'000'000);
    CHECK(t.e.play());
    t.cb(60);  // 600 ms: steps 0..4.8 at 120 BPM (a step is 125 ms)
    const auto prog = t.with(0xC2), on = t.with(0x92), off = t.with(0x82);
    CHECK_EQ(prog.size(), 1u);  // the program, at Play
    if (!prog.empty()) {
        CHECK_EQ(prog[0].data[1], 5);
        CHECK_EQ(prog[0].size, 2);
        CHECK_EQ(prog[0].port, 2);
    }
    CHECK_EQ(on.size(), 2u);
    CHECK_EQ(off.size(), 1u);
    if (on.size() == 2 && off.size() == 1) {
        // Time: the callback's start + frame / rate + the output latency (5 ms) + the port's offset (1 ms).
        CHECK_EQ(on[0].timeNs, kT0 + 6'000'000);
        CHECK_EQ(on[0].data[1], 60);
        CHECK_EQ(on[0].data[2], 127);
        CHECK_EQ(off[0].timeNs, kT0 + 250'000'000 + 6'000'000);  // step 2
        CHECK_EQ(off[0].data[1], 60);
        CHECK_EQ(on[1].timeNs, kT0 + 500'000'000 + 6'000'000);   // step 4
        CHECK_EQ(on[1].data[1], 64);
        CHECK_EQ(on[1].data[2], 64);  // velocity 0.5: the top 7 bits of 32768
    }
    // No pitch bend was needed (whole keys from the centre), and the layer itself is silent.
    CHECK(t.with(0xE2).empty());
    float peak = 0;
    for (float v : t.l) peak = std::max(peak, std::fabs(v));
    CHECK_EQ(peak, 0.0f);
    CHECK_EQ(t.e.midiOutDropped(), 0u);
}

TEST(midi_out_times_add_the_mix_latency_compensation) {
    Run t;
    const std::string layers = kMidiLayer +
        ",{\"id\":\"a\",\"instrument\":\"org.caw.test.osc\",\"components\":[{\"id\":\"org.caw.limiter\"}]}";
    CHECK(ok(t.e.setProjectJson(project(layers))));
    CHECK_EQ(t.e.midiOutDelayFrames(), 240);  // the limiter's look-ahead on the other track
    CHECK(t.e.play());
    t.cb(2);
    const auto on = t.with(0x92);
    CHECK_EQ(on.size(), 1u);
    if (!on.empty()) CHECK_EQ(on[0].timeNs, kT0 + 5'000'000);  // 240 frames at 48 kHz
}

TEST(midi_out_ends_every_sounding_note_on_stop_mute_and_locate) {
    Run t;
    CHECK(ok(t.e.setProjectJson(project(kMidiLayer))));
    CHECK(t.e.play(4));  // inside E4's 8 steps
    t.cb(3);
    CHECK_EQ(t.with(0x92).size(), 1u);
    CHECK(t.e.stop());
    t.cb(30);  // through the stop fade and after
    const auto off = t.with(0x82);
    CHECK_EQ(off.size(), 1u);
    if (!off.empty()) {
        CHECK_EQ(off[0].data[1], 64);
        CHECK_EQ(off[0].timeNs, kT0 + 30'000'000);  // at the Stop's callback, frame 0
    }
    CHECK_EQ(t.with(0x92).size(), 1u);  // nothing new during the fade
    // Mute: the note ends at once.
    t.got.clear();
    CHECK(t.e.play(4));
    t.cb(2);
    CHECK_EQ(t.with(0x92).size(), 1u);
    t.e.setLayerMix("m", 0.8, 0, true, false);
    t.cb(3);
    CHECK_EQ(t.with(0x82).size(), 1u);
    t.e.setLayerMix("m", 0.8, 0, false, false);
    t.cb(2);
    // Play elsewhere (a locate) ends it too, then the pattern goes on from there.
    t.got.clear();
    CHECK(t.e.play(5));
    t.cb(2);
    CHECK_EQ(t.with(0x82).size(), 1u);
    CHECK(t.e.stop());
    t.cb(30);
    // Removing the layer ends what it holds.
    t.got.clear();
    CHECK(t.e.play(4));
    t.cb(2);
    CHECK(ok(t.e.setProjectJson(project(""))));
    t.cb(2);
    CHECK_EQ(t.with(0x82).size(), 1u);
}

TEST(midi_out_bend_follows_a_notes_own_pitch) {
    MidiOutLane lane;
    MidiOutSpec spec;
    spec.channel = 1;
    spec.bendRange = 2;
    lane.configure(spec);
    const Event evs[] = {notes::noteOn(3, 1, 60.25, 1.0), notes::notePitch(9, 1, 60, 61.0), notes::noteOff(20, 1, 60)};
    lane.convert(evs, 3, true);
    CHECK_EQ(lane.stagedCount(), 4u);
    if (lane.stagedCount() == 4) {
        const MidiOutStaged* s = lane.staged();
        CHECK_EQ(s[0].data[0], 0xE0);  // a quarter semitone up, an eighth of the range: 8192 + 1024
        CHECK_EQ(s[0].data[1] | s[0].data[2] << 7, 9216);
        CHECK_EQ(s[0].frame, 3u);
        CHECK_EQ(s[1].data[0], 0x90);
        CHECK_EQ(s[2].data[1] | s[2].data[2] << 7, 12288);  // a semitone: half the range
        CHECK_EQ(s[2].frame, 9u);
        CHECK_EQ(s[3].data[0], 0x80);
    }
    lane.clearStaged();
    lane.allOff(0);  // nothing sounds: only the bend goes back to the centre
    CHECK_EQ(lane.stagedCount(), 1u);
    CHECK_EQ(lane.staged()[0].data[1] | lane.staged()[0].data[2] << 7, 8192);
}

TEST(midi_out_retriggered_key_and_controllers) {
    MidiOutLane lane;
    MidiOutSpec spec;
    spec.channel = 16;
    lane.configure(spec);
    Event cc;
    cc.kind = EventKind::Midi;
    cc.frame = 1;
    cc.data[0] = 0x40B00700u | 0x00010000u;  // CC 7 on channel 2 (it goes out on the lane's channel)
    cc.data[1] = 0x80000000u;
    Event prog;
    prog.kind = EventKind::Midi;
    prog.frame = 2;
    prog.data[0] = 0x40C00001u;  // program change with bank valid
    prog.data[1] = (9u << 24) | (3u << 8) | 4u;
    const Event evs[] = {cc, prog, notes::noteOn(4, 1, 60, 1.0), notes::noteOn(5, 2, 60, 1.0),
                         notes::noteOff(6, 1, 60), notes::noteOff(7, 2, 60)};
    lane.convert(evs, 6, true);
    std::vector<std::vector<int>> got;
    for (uint32_t k = 0; k < lane.stagedCount(); ++k) {
        const MidiOutStaged& s = lane.staged()[k];
        got.push_back({s.data[0], s.data[1], s.size == 3 ? s.data[2] : -1});
    }
    const std::vector<std::vector<int>> want = {
        {0xBF, 7, 64}, {0xBF, 0, 3}, {0xBF, 32, 4}, {0xCF, 9, -1},
        {0x9F, 60, 127}, {0x8F, 60, 0}, {0x9F, 60, 127},  // the second on ends the first first
        {0x8F, 60, 0},                                    // and the key's off goes with the last off only
    };
    CHECK(got == want);
    CHECK(!lane.sounding());
}

TEST(midi_out_queue_keeps_room_for_ending_messages_and_drops_stale_starts) {
    MidiOutQueue q;
    MidiOutMessage tick;
    tick.size = 1;
    tick.data[0] = 0xF8;
    tick.timeNs = 1'000'000'000;
    MidiOutMessage off = tick;
    off.size = 3;
    off.data[0] = 0x80;
    off.reserved[0] = kMidiEssential;
    q.beginCallback();
    int pushed = 0;
    for (uint32_t k = 0; k < MidiOutQueue::kPerCallback + 10; ++k) pushed += q.push(tick);
    CHECK_EQ(pushed, static_cast<int>(MidiOutQueue::kPerCallback));  // a callback's share of starting messages
    CHECK_EQ(q.dropped(), 10u);
    CHECK(q.push(off));  // an ending one goes past the share
    for (int c = 0; c < 10; ++c) {  // nobody drains: starting messages stop short of the reserve
        q.beginCallback();
        for (uint32_t k = 0; k < MidiOutQueue::kPerCallback; ++k) q.push(tick);
    }
    int offs = 0;
    for (size_t k = 0; k < MidiOutQueue::kReserve; ++k) offs += q.push(off);  // the reserve is for ending ones
    CHECK_EQ(offs, static_cast<int>(MidiOutQueue::kReserve));
    // Drained 250 ms past their time, the starting ones are left out and counted; every ending one comes.
    std::vector<MidiOutMessage> out(MidiOutQueue::kCapacity);
    const int32_t n = q.drain(out.data(), static_cast<int32_t>(out.size()), tick.timeNs + MidiOutQueue::kMaxAgeNs + 1);
    CHECK_EQ(n, offs + 1);
    for (int32_t k = 0; k < n; ++k) CHECK_EQ(out[k].data[0], 0x80);
    CHECK(q.dropped() > MidiOutQueue::kCapacity - MidiOutQueue::kReserve);
}

TEST(midi_out_lane_never_drops_a_note_off_past_its_room) {
    MidiOutLane lane;
    std::vector<Event> evs;
    for (int k = 0; k < 128; ++k) evs.push_back(notes::noteOn(0, static_cast<uint32_t>(k + 1), k, 1.0));
    for (uint32_t k = 0; k < MidiOutLane::kStaged; ++k) {  // a flood of controllers after them
        Event e;
        e.kind = EventKind::Midi;
        e.frame = 1;
        e.data[0] = 0x40D00000u;  // channel pressure
        evs.push_back(e);
    }
    lane.convert(evs.data(), static_cast<uint32_t>(evs.size()), true);
    CHECK(lane.takeOverflow() > 0);
    lane.allOff(2);  // in the same chunk: every key that sounds gets its off
    int ons = 0, offs = 0;
    for (uint32_t k = 0; k < lane.stagedCount(); ++k) {
        ons += lane.staged()[k].data[0] == 0x90;
        offs += lane.staged()[k].data[0] == 0x80;
    }
    CHECK_EQ(ons, 128);
    CHECK_EQ(offs, ons);
    CHECK_EQ(lane.takeOverflow(), 0u);
    CHECK(!lane.sounding());
}

TEST(midi_out_port_change_ends_notes_on_the_old_port) {
    MidiOutLane lane;
    MidiOutSpec spec;
    spec.port = 3;
    lane.configure(spec);
    const Event on = notes::noteOn(0, 1, 60, 1.0);
    lane.convert(&on, 1, true);
    spec.port = 7;
    lane.configure(spec);  // before the chunk is flushed
    CHECK_EQ(lane.stagedCount(), 2u);
    if (lane.stagedCount() == 2) {
        CHECK_EQ(lane.staged()[0].port, 3);
        CHECK_EQ(lane.staged()[1].data[0], 0x80);
        CHECK_EQ(lane.staged()[1].port, 3);  // the off goes where the note is
        CHECK(lane.staged()[1].essential);
    }
    // Through the engine: the off is queued for the old port.
    Run t;
    CHECK(ok(t.e.setProjectJson(project(kMidiLayer))));
    CHECK(t.e.play(4));
    t.cb(2);
    std::string moved = kMidiLayer;
    moved.replace(moved.find("\"port\":2"), 8, "\"port\":9");
    CHECK(ok(t.e.setProjectJson(project(moved))));
    t.cb(1);
    const auto off = t.with(0x82);
    CHECK_EQ(off.size(), 1u);
    if (!off.empty()) CHECK_EQ(off[0].port, 2);
}

TEST(midi_out_queues_nothing_until_a_sender_attaches) {
    Run t;
    t.e.setMidiOutActive(false);
    CHECK(ok(t.e.setProjectJson(project(kMidiLayer))));
    t.e.setMidiClockOut(1);
    CHECK(t.e.play());
    t.cb(20);
    CHECK(t.got.empty());
    CHECK_EQ(t.e.midiOutDropped(), 0u);
    t.e.setMidiOutActive(true);  // attached mid-song: from now on, nothing from before
    t.cb(1);
    CHECK(!t.with(0xF8).empty());
    for (const MidiOutMessage& m : t.got) CHECK(m.timeNs >= kT0 + 200'000'000);
}

TEST(midi_out_callback_clock_smooths_jittered_wakeups) {
    CallbackClock c;
    Lcg rng;
    const double period = 480.0 / 48000.0 * 1e9;
    double worst = 0, worstLate = 0, square = 0;
    for (int k = 0; k < 3000; ++k) {  // 30 s of 10 ms callbacks woken up to 2 ms late or early
        const double ideal = 1e9 + k * period;
        const int64_t wake = static_cast<int64_t>(ideal + rng.next() * 2e6);
        const double err = std::fabs(static_cast<double>(c.anchor(wake, 480, 48000)) - ideal);
        worst = std::max(worst, err);
        if (k >= 1000) {  // after it settles
            worstLate = std::max(worstLate, err);
            square += err * err;
        }
    }
    CHECK(worst < 2.5e6);
    CHECK(worstLate < 0.5e6);                     // a quarter of the jitter at worst
    CHECK(std::sqrt(square / 2000) < 0.2e6);     // the jitter's own spread is 1.15 ms
    // A device restart (a wake-up far from the prediction) starts it again there.
    CHECK_EQ(c.anchor(9'000'000'000, 480, 48000), 9'000'000'000);
    // Steady wake-ups come out as they are.
    CallbackClock d;
    for (int k = 0; k < 100; ++k) CHECK(std::llabs(d.anchor(kT0 + k * 10'000'000LL, 480, 48000) - (kT0 + k * 10'000'000LL)) <= 1);
}

TEST(midi_clock_out_ticks_follow_the_tempo_map) {
    Run t;
    CHECK(ok(t.e.setProjectJson(project("", ",\"tempo_map\":[{\"beat\":0,\"bpm\":120},{\"beat\":2,\"bpm\":60}]", 2))));
    t.e.setMidiClockOut(1u << 1);
    CHECK(t.e.play());
    t.cb(300);  // 3 s: two beats at 120 (1 s), then two at 60 (2 s)
    const auto start = t.with(0xFA), ticks = t.with(0xF8);
    CHECK_EQ(start.size(), 1u);
    CHECK(ticks.size() >= 96u);
    if (start.size() == 1 && ticks.size() >= 96u) {
        CHECK_EQ(start[0].timeNs, kT0);
        CHECK_EQ(start[0].port, 1);
        CHECK_EQ(ticks[0].timeNs, kT0);  // the first tick is the song's start
        int64_t worst = 0;
        for (size_t k = 1; k < 96; ++k) {
            const int64_t want = k <= 48 ? 20'833'333 : 41'666'667;  // 24 a beat at 120, then at 60
            worst = std::max<int64_t>(worst, std::llabs((ticks[k].timeNs - ticks[k - 1].timeNs) - want));
        }
        CHECK(worst <= 1);
        CHECK_EQ(ticks[48].timeNs, kT0 + 1'000'000'000);  // beat 2, exactly
    }
    CHECK(t.e.stop());
    t.cb(1);
    CHECK_EQ(t.with(0xFC).size(), 1u);
    const size_t n = t.with(0xF8).size();
    t.cb(20);
    CHECK_EQ(t.with(0xF8).size(), n);  // no ticks once stopped
}

TEST(midi_clock_out_sequences_start_continue_position_and_stop) {
    Run t;
    CHECK(ok(t.e.setProjectJson(project(""))));
    t.e.setMidiClockOut(1);
    CHECK(t.e.play(10.5));  // from inside step 10: the position is step 11, and its tick the first
    t.cb(10);
    CHECK(t.got.size() >= 3u);
    if (t.got.size() >= 3u) {
        CHECK_EQ(t.got[0].data[0], 0xF2);
        CHECK_EQ(t.got[0].data[1], 11);
        CHECK_EQ(t.got[0].data[2], 0);
        CHECK_EQ(t.got[1].data[0], 0xFB);
        CHECK_EQ(t.got[2].data[0], 0xF8);
        CHECK_EQ(t.got[2].timeNs, kT0 + 62'500'000);  // half a step (62.5 ms) after the Play
    }
    t.got.clear();
    CHECK(t.e.play(0));  // a locate while running: Stop, then Start
    t.cb(1);
    CHECK(t.got.size() >= 2u);
    if (t.got.size() >= 2u) {
        CHECK_EQ(t.got[0].data[0], 0xFC);
        CHECK_EQ(t.got[1].data[0], 0xFA);
    }
    t.got.clear();
    t.cb(205);  // past the end of the one-bar song (2 s): it wraps
    const auto stops = t.with(0xFC), starts = t.with(0xFA);
    CHECK_EQ(stops.size(), 1u);
    CHECK_EQ(starts.size(), 1u);
    if (!stops.empty() && !starts.empty()) {
        CHECK_EQ(stops[0].timeNs, kT0 + 2'100'000'000);  // Play(0) at 100 ms, then the 2 s bar
        CHECK_EQ(starts[0].timeNs, stops[0].timeNs);
    }
    t.got.clear();
    t.e.setMidiClockOut(0);  // off while running: Stop at once
    t.cb(1);
    CHECK_EQ(t.with(0xFC).size(), 1u);
    CHECK(t.with(0xF8).empty());
}

TEST(midi_clock_follower_tempo_rides_over_jitter_drift_and_dropped_ticks) {
    ClockFollower f;
    Lcg rng;
    double t = 1e9;
    auto run = [&](double bpm, int ticks, double jitterNs, int dropEvery = 0) {
        for (int k = 0; k < ticks; ++k) {
            t += 60e9 / (24.0 * bpm);
            if (dropEvery > 0 && k % dropEvery == dropEvery - 1) continue;
            f.feed(0xF8, static_cast<int64_t>(t + rng.next() * jitterNs));
        }
    };
    run(120, 11, 0);
    CHECK(!f.locked());  // fewer than 12 ticks: no estimate yet
    run(120, 100, 1e6);  // +-1 ms of jitter on 20.8 ms ticks
    CHECK(f.locked());
    CHECK_NEAR(f.bpm(), 120.0, 0.2);
    // A ramp to 130 over eight beats, then two steady beats: the estimate has followed.
    for (int k = 0; k < 8 * 24; ++k) run(120 + 10.0 * k / (8 * 24), 1, 1e6);
    run(130, 48, 1e6);
    CHECK_NEAR(f.bpm(), 130.0, 0.3);
    run(130, 96, 1e6, 20);  // every twentieth tick lost
    CHECK_NEAR(f.bpm(), 130.0, 0.3);
    t += 2e9;  // a gap: the fit starts again
    run(90, 5, 0);
    CHECK(!f.locked());
    run(90, 60, 0);
    CHECK_NEAR(f.bpm(), 90.0, 1e-6);
}

TEST(midi_clock_follower_transport_messages) {
    ClockFollower f;
    using A = ClockFollower::Action;
    CHECK(f.feed(0xFA, 0) == A::Start);
    CHECK(f.running());
    CHECK_EQ(f.songPosition(), 0);
    for (int k = 0; k < 7; ++k) CHECK(f.feed(0xF8, 1000 * (k + 1)) == A::Tick);
    CHECK_NEAR(f.positionSteps(), 1.0, 1e-12);  // the first tick is 0, six more make a step
    CHECK(f.feed(0xFC, 9000) == A::Stop);
    CHECK(!f.running());
    // A Song Position Pointer with a tick between its data bytes (real time may come anywhere).
    CHECK(f.feed(0xF2, 10000) == A::None);
    CHECK(f.feed(0x05, 10000) == A::None);
    CHECK(f.feed(0xF8, 10000) == A::Tick);
    CHECK(f.feed(0x01, 10000) == A::Locate);
    CHECK_EQ(f.songPosition(), 5 + 128);
    CHECK(f.feed(0xFB, 11000) == A::Continue);
    CHECK(f.running());
    CHECK_NEAR(f.positionSteps(), 133.0, 1e-12);
    // Another status byte cancels a pointer half read.
    CHECK(f.feed(0xF2, 0) == A::None);
    CHECK(f.feed(0x90, 0) == A::None);
    CHECK(f.feed(0x10, 0) == A::None);
    CHECK(f.feed(0x10, 0) == A::None);
    CHECK_EQ(f.songPosition(), 133);
}

namespace {
// A master clock at `bpm` (24 ticks a beat, each up to `jitterNs` early or late) started at `startNs`, fed to the
// engine in time with its callbacks (Run's 10 ms), whose first starts `lateNs` after the master's Start.
struct Master {
    Run& t;
    double bpm;
    double jitterNs;
    int64_t startNs;
    Lcg rng;
    int64_t tick = 0;
    double tickTime(int64_t k) const { return static_cast<double>(startNs) + k * 60e9 / (24.0 * bpm); }
    void until(int64_t ns) {
        const uint8_t f8 = 0xF8;
        while (tickTime(tick) < static_cast<double>(ns)) {
            t.e.midiClockIn(&f8, 1, static_cast<int64_t>(tickTime(tick) + rng.next() * jitterNs));
            ++tick;
        }
    }
    // Where the master is at `ns`, in steps (tick 0 is step 0).
    double stepsAt(int64_t ns) const { return (static_cast<double>(ns) - startNs) * bpm / 15e9; }
};
}  // namespace

TEST(midi_clock_follow_drives_the_transport_and_the_live_tempo_only) {
    Run t;
    CHECK(ok(t.e.setProjectJson(project(kMidiLayer))));
    t.e.setMidiClockFollow(true);
    const uint8_t start = 0xFA, stop = 0xFC;
    CHECK_EQ(t.e.midiClockIn(&start, 1, kT0), 1);
    Master m{t, 100, 0, kT0};
    for (int k = 0; k < 600; ++k) {  // 6 s at 100 BPM, in time with the callbacks
        m.until(kT0 + (k + 1) * 10'000'000LL);
        t.cb(1);
    }
    CHECK(t.e.position().playing);
    CHECK_NEAR(t.e.midiClockInBpm(), 100.0, 1e-6);
    // The tempo, give or take the position's nudge (the engine ran at the project's 120 until the estimate locked).
    CHECK_NEAR(t.e.position().bpm, 100.0, 0.5);
    // A project update while following keeps the followed tempo.
    CHECK(ok(t.e.setProjectJson(project(kMidiLayer))));
    t.cb(1);
    CHECK_NEAR(t.e.position().bpm, 100.0, 0.5);
    CHECK_EQ(t.e.midiClockIn(&stop, 1, kT0 + 6'020'000'000), 1);
    t.cb(30);
    CHECK(!t.e.position().playing);
    CHECK_EQ(t.with(0x92).size(), t.with(0x82).size());  // every note sent was ended
    // Following off: the project's tempo is back, and a late estimate doesn't bring the follower's back.
    t.e.setMidiClockFollow(false);
    t.cb(1);
    CHECK_NEAR(t.e.position().bpm, 120.0, 1e-9);
    m.until(kT0 + 7'000'000'000);
    t.cb(1);
    CHECK_NEAR(t.e.position().bpm, 120.0, 1e-9);
    CHECK_EQ(caw_engine_midi_clock_in_bpm(nullptr), 0.0);
}

TEST(midi_clock_follow_keeps_the_playhead_continuous_and_locked_to_the_master) {
    Run t;
    CHECK(ok(t.e.setProjectJson(project(kMidiLayer, "", 64))));  // 128 s: no wrap
    t.e.setMidiClockFollow(true);
    const uint8_t start = 0xFA;
    // The master starts 50 ms before the engine's next callback (2.5 ticks at 125 BPM): the nudge takes it out.
    const int64_t masterStart = kT0 - 50'000'000;
    t.e.midiClockIn(&start, 1, masterStart);
    Master m{t, 125, 1e6, masterStart};  // +-1 ms of jitter on every tick
    int64_t last = -1;
    int jumps = 0;
    double worstLate = 0;
    for (int k = 0; k < 6000; ++k) {  // 60 s
        const int64_t now = kT0 + k * 10'000'000LL;
        m.until(now);
        t.cb(1);
        const int64_t frame = t.e.position().frame;
        if (last >= 0 && frame - last != kCb) ++jumps;  // each callback moves the playhead by its frames, exactly
        last = frame;
        if (k >= 1000) {  // after 10 s: within a tick of the master (a tick is a sixth of a step)
            const int64_t heardAt = now + 10'000'000;  // the callback's end, where position() is
            const double engineSteps = t.e.songTime().tempo.stepAt(static_cast<double>(t.e.positionAt(heardAt)));
            worstLate = std::max(worstLate, std::fabs(engineSteps - m.stepsAt(heardAt)));
        }
    }
    CHECK_EQ(jumps, 0);
    CHECK(worstLate < 1.0 / 6.0);
    CHECK_NEAR(t.e.position().bpm, 125.0, 125 * 0.031);
}

TEST(midi_clock_follower_follows_sudden_tempo_steps) {
    for (const auto& [from, to] : {std::pair{140.0, 90.0}, std::pair{90.0, 140.0}, std::pair{120.0, 60.0}}) {
        ClockFollower f;
        double t = 1e9;
        for (int k = 0; k < 96; ++k) f.feed(0xF8, static_cast<int64_t>(t += 60e9 / (24 * from)));
        CHECK_NEAR(f.bpm(), from, 1e-6);
        for (int k = 0; k < 72; ++k) f.feed(0xF8, static_cast<int64_t>(t += 60e9 / (24 * to)));  // three beats
        CHECK_NEAR(f.bpm(), to, 1e-6);
    }
}

TEST(midi_out_project_fields_are_checked) {
    auto parse = [](const std::string& midiOut, std::string extra = "") {
        ProjectSpec p;
        std::string error;
        const bool good = parseProject("{\"layers\":[{\"id\":\"m\"" + extra + ",\"midiOut\":" + midiOut + "}]}", p, error);
        return good ? std::string("ok") : error;
    };
    CHECK_EQ(parse("{\"port\":15,\"channel\":16,\"program\":127,\"bend_range\":48}"), std::string("ok"));
    CHECK(parse("{\"port\":16}").find("port must be") != std::string::npos);
    CHECK(parse("{\"port\":-1}").find("port must be") != std::string::npos);
    CHECK(parse("{\"channel\":0}").find("channel must be") != std::string::npos);
    CHECK(parse("{\"channel\":1.5}").find("channel must be") != std::string::npos);
    CHECK(parse("{\"program\":128}").find("program must be") != std::string::npos);
    CHECK(parse("{\"bend_range\":0.5}").find("bend_range") != std::string::npos);
    CHECK(parse("5").find("must be {") != std::string::npos);
    CHECK(parse("{\"port\":\"2\"}").find("port must be a number") != std::string::npos);
    CHECK(parse("{\"channel\":[1]}").find("channel must be a number") != std::string::npos);
    CHECK(parse("{\"program\":true}").find("program must be a number") != std::string::npos);
    CHECK(parse("{\"bend_range\":{}}").find("bend_range must be a number") != std::string::npos);
    CHECK(parse("{}", ",\"instrument\":\"org.caw.test.osc\"").find("can't also have an instrument") != std::string::npos);
    CHECK(parse("{}", ",\"sends\":[{\"to\":\"x\"}]").find("can't also have sends") != std::string::npos);
    CHECK(parse("{}", ",\"midiComponents\":[\"org.caw.midi.arp\"]").find("midiComponents") != std::string::npos);
    ProjectSpec p;
    std::string error;
    CHECK(parseProject("{\"layers\":[{\"id\":\"m\",\"midiOut\":{\"port\":3,\"channel\":10}}]}", p, error));
    CHECK(p.layers.size() == 1 && p.layers[0].hasMidiOut && p.layers[0].midiOut.port == 3 &&
          p.layers[0].midiOut.channel == 10 && p.layers[0].midiOut.program == -1 && p.layers[0].midiOut.bendRange == 2.0);
    CHECK(parseProject("{\"layers\":[{\"id\":\"m\",\"midiOut\":null}]}", p, error) && !p.layers[0].hasMidiOut);
}

TEST(midi_out_layer_leaves_the_mix_bit_identical) {
    auto render = [](const std::string& layers) {
        Engine e(48000);
        e.setProjectJson(project(layers));
        e.setMidiClockOut(0xFFFF);
        e.play();
        std::vector<float> l(kCb), r(kCb), all;
        for (int k = 0; k < 40; ++k) {
            e.process(l.data(), r.data(), kCb);
            all.insert(all.end(), l.begin(), l.end());
            all.insert(all.end(), r.begin(), r.end());
        }
        return all;
    };
    const std::string osc = "{\"id\":\"a\",\"pattern\":\"p\",\"instrument\":\"org.caw.test.osc\"}";
    const std::vector<float> plain = render(osc), with = render(osc + "," + kMidiLayer);
    CHECK(plain == with);
    float peak = 0;
    for (float v : plain) peak = std::max(peak, std::fabs(v));
    CHECK(peak > 0.01f);
}

TEST(midi_out_c_api_drains_the_queue) {
    CawEngine* e = caw_engine_create(48000);
    CHECK(e != nullptr);
    if (!e) return;
    CHECK_EQ(caw_engine_midi_out_drain(e, nullptr, 4), 0);
    caw_engine_set_midi_clock_out(e, 1);
    caw_engine_set_midi_out_active(e, 1);
    CHECK_EQ(caw_engine_play(e), 1);
    std::vector<float> l(kCb), r(kCb);
    caw_engine_process(e, l.data(), r.data(), kCb);
    CawMidiOutEvent ev[8] = {};
    const int32_t n = caw_engine_midi_out_drain(e, ev, 8);
    CHECK(n >= 2);
    if (n >= 2) {
        CHECK_EQ(ev[0].data[0], 0xFA);
        CHECK_EQ(ev[0].size, 1);
        CHECK_EQ(ev[1].data[0], 0xF8);
    }
    CHECK_EQ(caw_engine_midi_out_dropped(e), 0);
    caw_engine_set_midi_out_port(e, 99, 5);  // out of range: ignored
    CHECK_EQ(caw_engine_midi_clock_in(e, nullptr, 3, 0), 0);
    caw_engine_destroy(e);
}
