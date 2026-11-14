// WP-J on the audio thread: audio clips (direct, WSOLA, varispeed), the sampler, monitoring and recording never allocate.
#include <cmath>
#include <filesystem>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "input_bridge.h"
#include "json.h"
#include "test.h"
#include "wav.h"

using namespace caw;

namespace {
std::string noiseWav(const std::string& path, int64_t frames) {
    std::vector<float> x(static_cast<size_t>(frames * 2));
    uint32_t s = 1;
    for (float& v : x) {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        v = static_cast<float>((s >> 8) / 8388608.0 - 1.0) * 0.3f;
    }
    WavSpec w;
    w.channels = 2;
    w.float32 = true;
    std::string error;
    writeFile(path, encodeWav(w, x.data(), frames), error);
    return path;
}
std::string b64(const std::string& s) { return base64Encode(reinterpret_cast<const uint8_t*>(s.data()), s.size()); }
}  // namespace

TEST(audio_clips_sampler_monitoring_and_recording_never_allocate_on_the_audio_thread) {
    const auto dir = std::filesystem::temp_directory_path() / "caw_wpj_rt";
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    const std::string p = noiseWav((dir / "n.wav").generic_string(), 48000);
    const std::string zones = "{\"zones\":[{\"path\":\"" + jsonEscape(p) +
                              "\",\"loop_mode\":\"loop_sustain\",\"loop_start\":1000,\"loop_end\":20000,\"loop_crossfade\":0.01}]}";
    const std::string json =
        "{\"caw_project\":1,\"bpm\":120,\"loop_bars\":1,\"master\":0.5,\"assets\":[{\"id\":\"a\",\"path\":\"" + jsonEscape(p) +
        "\",\"bpm\":100}],\"modules\":[{\"id\":\"pt\",\"source\":\"---\\nkind: pattern\\nlength: 16\\n---\\n0 C4,E4,G4 3 1\\n4 A3 6 0.7\\n\"}],"
        "\"layers\":["
        "{\"id\":\"d\",\"name\":\"D\",\"input\":{\"channel\":0,\"channels\":2,\"monitor\":\"on\",\"armed\":true},\"audio_clips\":["
        "{\"id\":\"1\",\"asset\":\"a\",\"start_steps\":0,\"length_steps\":5,\"fade_in_seconds\":0.01},"
        "{\"id\":\"2\",\"asset\":\"a\",\"start_steps\":3.3,\"length_steps\":6,\"mode\":\"musical\",\"pitch\":2,\"loop\":true},"
        "{\"id\":\"3\",\"asset\":\"a\",\"start_steps\":7,\"length_steps\":9,\"stretch\":\"varispeed\",\"pitch\":-7,\"reverse\":true}]},"
        "{\"id\":\"s\",\"name\":\"S\",\"pattern\":\"pt\",\"instrument\":{\"id\":\"org.caw.sampler\",\"params\":{\"filter\":1,\"cutoff\":800},"
        "\"state\":\"" + b64(zones) + "\"}}]}";
    Engine e(48000);
    CHECK(e.setProjectJson(json).find("\"ok\":true") != std::string::npos);
    e.liveAudio().setDeviceChannels(2);
    CHECK(e.liveAudio().startRecording("{\"dir\":\"" + jsonEscape(dir.generic_string()) +
                                       "\",\"bpm\":120,\"tracks\":[{\"layer\":\"d\",\"channel\":0,\"channels\":2}]}")
              .find("\"ok\":true") != std::string::npos);
    std::vector<float> in(192 * 2, 0.1f), l(192), r(192);
    e.liveAudio().beginCallback(in.data(), 2, 192);
    e.process(l.data(), r.data(), 192);  // stopped: monitoring wakes the track
    e.play();
    for (int k = 0; k < 100; ++k) {
        e.liveAudio().beginCallback(in.data(), 2, 192);
        e.process(l.data(), r.data(), 192);
    }
    std::size_t operations = 0;
    float peak = 0;
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 600; ++k) {  // 2.4 s: a loop wrap, every clip, notes on and off, recording
            e.liveAudio().beginCallback(in.data(), 2, 192);
            e.process(l.data(), r.data(), 192);
            e.liveAudio().afterCallback(l.data(), r.data(), 192);
            for (float v : l) peak = std::fabs(v) > peak ? std::fabs(v) : peak;
        }
        operations = scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
    CHECK(e.liveAudio().stopRecording().find("\"ok\":true") != std::string::npos);
    std::filesystem::remove_all(dir);
}

TEST(the_input_bridge_never_allocates_on_the_capture_or_output_thread) {
    caw::InputBridge bridge;
    bridge.open(2, 640, 768, 12000);
    std::vector<float> in(192 * 2, 0.1f);
    std::size_t operations = 0;
    int ch = 0;
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 2000; ++k) {  // live, starved, back: priming, fades, underruns, drift skips
            if (k < 800 || k > 1200) bridge.push(in.data(), 192);
            if (k % 3 == 0 && k < 800) bridge.push(in.data(), 192);
            bridge.pull(256, ch);
        }
        operations = scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK_EQ(ch, 2);
}

TEST(signalsmith_clip_voices_never_allocate_on_the_audio_thread) {
    // API 32: Signalsmith Stretch voices pre-rolled before their clip, joined mid-clip (the WSOLA bridge and its
    // crossfade), following a ramped tempo map chunk by chunk, pitched, reversed and looped, through a seek and a loop
    // wrap. Every stretcher is prepared on the control thread (setProjectJson); the audio thread only processes.
    const auto dir = std::filesystem::temp_directory_path() / "caw_stretch_rt";
    std::filesystem::remove_all(dir);
    std::filesystem::create_directories(dir);
    const std::string p = noiseWav((dir / "n.wav").generic_string(), 96000);
    const std::string json =
        "{\"caw_project\":1,\"bpm\":120,\"loop_bars\":2,\"master\":0.5,\"tempo_map\":[{\"beat\":0,\"bpm\":120},"
        "{\"beat\":6,\"bpm\":90,\"ramp\":true}],\"assets\":[{\"id\":\"a\",\"path\":\"" + jsonEscape(p) + "\",\"bpm\":100}],"
        "\"layers\":[{\"id\":\"d\",\"name\":\"D\",\"audio_clips\":["
        "{\"id\":\"1\",\"asset\":\"a\",\"start_steps\":4,\"length_steps\":8,\"stretch\":\"signalsmith\",\"stretch_ratio\":1.3,"
        "\"pitch_cents\":300,\"fade_in_seconds\":0.01},"
        "{\"id\":\"2\",\"asset\":\"a\",\"start_steps\":0,\"length_steps\":32,\"stretch\":\"signalsmith\",\"follows_tempo\":true,"
        "\"pitch\":-2},"
        "{\"id\":\"3\",\"asset\":\"a\",\"start_steps\":10,\"length_steps\":12,\"stretch\":\"signalsmith\",\"stretch_ratio\":0.7,"
        "\"reverse\":true,\"loop\":true,\"loop_start_frames\":1000,\"loop_end_frames\":20000}]}]}";
    Engine e(48000);
    CHECK(e.setProjectJson(json).find("\"ok\":true") != std::string::npos);
    std::vector<float> l(192), r(192);
    e.play();
    for (int k = 0; k < 20; ++k) e.process(l.data(), r.data(), 192);
    std::size_t operations = 0;
    float peak = 0;
    for (int part = 0; part < 2; ++part) {  // 1.2 s, then a seek mid-clip (play() is the control thread's) and 3.6 s
        if (part == 1) e.play(6.5);
        cawtest::AllocationScope scope;
        for (int k = 0; k < (part ? 900 : 300); ++k) {  // through two loop wraps of the 4 s loop
            e.process(l.data(), r.data(), 192);
            for (float v : l) peak = std::fabs(v) > peak ? std::fabs(v) : peak;
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
    std::filesystem::remove_all(dir);
}
