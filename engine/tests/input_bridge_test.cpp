// The input bridge (input_bridge.h): the output keeps playing, unchanged, when the separate input stops, starves or
// sends garbage, and the input comes back cleanly when it reopens.
#include <cmath>
#include <string>
#include <vector>

#include "engine.h"
#include "input_bridge.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

namespace {

constexpr int kTestRate = 48000;
constexpr int kOutBlock = 256;  // the output callback's size in these tests
constexpr int kCapPeriod = 192;  // the fake capture device's period

// The output callback as engine/platform/audio_miniaudio.cpp runs it: one chunk at a time, its input pulled from
// the bridge (or none: `bridge` null, the engine without an input device).
void outputCallback(Engine& e, InputBridge* bridge, float* l, float* r, int frames) {
    int ch = 0;
    const float* in = bridge ? bridge->pull(frames, ch) : nullptr;
    e.liveAudio().beginCallback(in, ch, frames);
    e.process(l, r, frames);
    e.liveAudio().afterCallback(l, r, frames);
}

// A capture device: periods of `kCapPeriod` stereo frames, channel 1 a steady `value`, channel 0 a ramp.
struct FakeCapture {
    std::vector<float> buf = std::vector<float>(static_cast<size_t>(kCapPeriod) * 2);
    int64_t t = 0;
    void period(InputBridge& b, float value) {
        for (int i = 0; i < kCapPeriod; ++i) {
            buf[static_cast<size_t>(i) * 2] = static_cast<float>((t + i) % 100) / 100.0f;
            buf[static_cast<size_t>(i) * 2 + 1] = value;
        }
        t += kCapPeriod;
        b.push(buf.data(), kCapPeriod);
    }
};

// Keeps the capture's clock with the output's: pushes whole periods until `due` frames have been captured.
void captureUntil(FakeCapture& c, InputBridge& b, int64_t due, float value) {
    while (c.t < due) c.period(b, value);
}

std::string monitorProject() {
    return "{\"caw_project\":1,\"bpm\":120,\"loop_bars\":1,\"master\":1,\"layers\":[{\"id\":\"t\",\"name\":\"T\","
           "\"volume\":1,\"input\":{\"channel\":1,\"channels\":1,\"monitor\":\"on\",\"armed\":false}}]}";
}

void openBridge(InputBridge& b) { b.open(2, 2 * kCapPeriod + kOutBlock, 4 * kCapPeriod, kTestRate / 4); }

}  // namespace

TEST(input_disconnect_while_playing_leaves_the_output_unchanged) {
    using cawtest::Shape;
    const ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("s", Shape::Sine, {{"freq", 440.0}})});
    Engine ref(kTestRate), live(kTestRate);
    CHECK(ref.setProject(p).find("\"ok\":true") != std::string::npos);
    CHECK(live.setProject(p).find("\"ok\":true") != std::string::npos);
    ref.play();
    live.play();
    InputBridge bridge;
    openBridge(bridge);
    FakeCapture cap;
    std::vector<float> l0(kOutBlock), r0(kOutBlock), l1(kOutBlock), r1(kOutBlock);
    bool same = true;
    for (int k = 0; k < 400; ++k) {
        const int64_t at = static_cast<int64_t>(k) * kOutBlock;
        // The input runs for 100 blocks, is disconnected (another app took the microphone) for 200, then returns.
        if (k < 100 || k >= 300) captureUntil(cap, bridge, at + kOutBlock + 2 * kCapPeriod, 0.5f);
        else cap.t = at + kOutBlock + 2 * kCapPeriod;  // no frames arrive
        outputCallback(ref, nullptr, l0.data(), r0.data(), kOutBlock);
        outputCallback(live, &bridge, l1.data(), r1.data(), kOutBlock);
        for (int i = 0; i < kOutBlock; ++i) same = same && l0[i] == l1[i] && r0[i] == r1[i];
        if (k == 299) CHECK(bridge.stalled());       // the app is told the input stopped delivering
        if (k == 399) CHECK(!bridge.stalled());      // and that it delivers again
    }
    CHECK(same);  // bit for bit: the output's sound never depended on the input
    CHECK(bridge.underruns() >= 1);
}

TEST(input_reopen_after_a_disconnect_delivers_again_and_fades_in) {
    InputBridge bridge;
    openBridge(bridge);
    FakeCapture cap;
    int ch = 0;
    for (int k = 0; k < 20; ++k) {
        captureUntil(cap, bridge, static_cast<int64_t>(k + 1) * kOutBlock + 2 * kCapPeriod, 0.5f);
        bridge.pull(kOutBlock, ch);
    }
    // The capture device is closed (disconnected) and reopened, as caw_audio_configure_input does.
    bridge.close();
    CHECK(bridge.pull(kOutBlock, ch) == nullptr);
    CHECK_EQ(ch, 0);
    openBridge(bridge);
    CHECK_EQ(bridge.pushed(), static_cast<int64_t>(0));
    // Until the starting fill is there, the input is silence (two channels, all zero).
    const float* in = bridge.pull(kOutBlock, ch);
    CHECK_EQ(ch, 2);
    bool silent = true;
    for (int i = 0; i < kOutBlock * 2; ++i) silent = silent && in[i] == 0.0f;
    CHECK(silent);
    FakeCapture again;
    captureUntil(again, bridge, bridge.prime(), 0.5f);
    in = bridge.pull(kOutBlock, ch);
    CHECK_EQ(ch, 2);
    // It fades in over kFade frames from 0, then passes the input unchanged.
    CHECK_EQ(in[1], 0.0f);
    for (int i = 1; i < InputBridge::kFade; ++i) CHECK(in[i * 2 + 1] >= in[(i - 1) * 2 + 1]);
    CHECK_EQ(in[(InputBridge::kFade + 10) * 2 + 1], 0.5f);
    CHECK(!bridge.stalled());
}

TEST(a_dead_or_garbage_input_gives_no_nans_and_no_clicks_in_the_output) {
    Engine e(kTestRate);
    e.setMasterBypass(true);
    CHECK(e.setProjectJson(monitorProject()).find("\"ok\":true") != std::string::npos);
    e.play();
    InputBridge bridge;
    openBridge(bridge);
    FakeCapture cap;
    std::vector<float> l(kOutBlock), r(kOutBlock), garbage(static_cast<size_t>(kCapPeriod) * 2);
    for (size_t i = 0; i < garbage.size(); ++i)
        garbage[i] = i % 3 == 0 ? NAN : (i % 3 == 1 ? INFINITY : -INFINITY);
    bool finite = true;
    float prev = 0.0f, maxStep = 0.0f, heard = 0.0f;
    for (int k = 0; k < 300; ++k) {
        const int64_t due = static_cast<int64_t>(k + 1) * kOutBlock + 2 * kCapPeriod;
        if (k < 100 || (k >= 200 && k < 250)) {
            captureUntil(cap, bridge, due, 0.5f);  // live: a steady 0.5 monitored, then back after a gap
        } else if (k < 200) {
            cap.t = due;  // dead: nothing arrives
        } else {
            while (cap.t < due) {  // a broken stream: NaN and infinities
                bridge.push(garbage.data(), kCapPeriod);
                cap.t += kCapPeriod;
            }
        }
        outputCallback(e, &bridge, l.data(), r.data(), kOutBlock);
        for (int i = 0; i < kOutBlock; ++i) {
            finite = finite && std::isfinite(l[i]) && std::isfinite(r[i]);
            if (k < 250) maxStep = std::max(maxStep, std::fabs(l[i] - prev));
            prev = l[i];
            heard = std::max(heard, std::fabs(l[i]));
        }
    }
    CHECK(finite);
    CHECK(heard > 0.3f);  // the input was monitored
    // A steady 0.5 (about 0.35 after the centre pan) starts, stops and restarts without a jump: every edge is a
    // kFade-frame ramp, so no step is larger than the level over that ramp (and a bit for the track's smoothing).
    // The garbage after it only has to stay finite (it becomes 0).
    CHECK(maxStep < 0.5f / InputBridge::kFade * 1.5f);
}

TEST(input_bridge_bounds_its_latency_when_the_clocks_drift) {
    InputBridge bridge;
    openBridge(bridge);
    FakeCapture cap;
    int ch = 0;
    // The input's clock runs 1% fast: the queue would grow without bound, so it skips back to the starting fill.
    for (int k = 0; k < 2000; ++k) {
        captureUntil(cap, bridge, static_cast<int64_t>((k + 1) * kOutBlock * 1.01) + 2 * kCapPeriod, 0.25f);
        bridge.pull(kOutBlock, ch);
    }
    CHECK(bridge.skipped() > 0);
    CHECK_EQ(bridge.dropped(), static_cast<int64_t>(0));  // never full
    // A slow input (1% late) underruns now and then and refills, each time faded.
    InputBridge slow;
    openBridge(slow);
    FakeCapture c2;
    for (int k = 0; k < 2000; ++k) {
        captureUntil(c2, slow, static_cast<int64_t>((k + 1) * kOutBlock * 0.99) + 2 * kCapPeriod, 0.25f);
        slow.pull(kOutBlock, ch);
    }
    CHECK(slow.underruns() > 0);
    CHECK(!slow.stalled());  // starved for a moment, not stopped
}

TEST(input_bridge_closed_gives_no_input_and_refuses_oversized_pulls) {
    InputBridge b;
    int ch = 5;
    CHECK(b.pull(kOutBlock, ch) == nullptr);
    CHECK_EQ(ch, 0);
    CHECK(!b.stalled());
    float x[4] = {1, 1, 1, 1};
    b.push(x, 2);  // closed: ignored
    CHECK_EQ(b.pushed(), static_cast<int64_t>(0));
    b.open(2, 64, 64, 1000);
    CHECK(b.pull(InputBridge::kMaxFrames + 1, ch) == nullptr);
    CHECK_EQ(ch, 0);
    // A full ring drops the newest frames and counts them.
    std::vector<float> big(static_cast<size_t>(InputBridge::kRingSamples), 0.1f);
    b.push(big.data(), InputBridge::kRingSamples / 2);
    b.push(big.data(), 16);
    CHECK(b.dropped() >= 16);
}
