// Export tests: exact loop lengths, export matching playback, one-shots, wavetables and the WAV encoding.
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "engine.h"
#include "render.h"
#include "test.h"
#include "wav.h"

using namespace caw;

namespace {

ProjectSpec groove() {
    ProjectSpec p;
    p.bpm = 140;
    p.loopBars = 4;
    p.modules.push_back({"kick", "---\nmode: float\n---\nsine(50 + 200 * ad(step%4==0, 0.0005, 0.05)) * ad(step%4==0, 0.001, 0.3)", {}});
    p.modules.push_back({"byte", "t*(t>>5|t>>8)", {}});
    LayerSpec a;
    a.id = "k";
    a.name = "Kick";
    a.chain = {"kick"};
    a.lengthSteps = 4;
    LayerSpec b;
    b.id = "b";
    b.name = "Byte";
    b.chain = {"byte"};
    b.lengthSteps = 48;  // 3 bars against the 4-bar project
    b.volume = 0.3;
    p.layers = {a, b};
    return p;
}

std::string testTempDir() {
    const auto dir = std::filesystem::temp_directory_path() / ("caw_export_test_" + std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(dir);
    return dir.string();
}

std::vector<uint8_t> readBytes(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

uint32_t le32(const std::vector<uint8_t>& b, size_t at) {
    return b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (static_cast<uint32_t>(b[at + 3]) << 24);
}

}  // namespace

TEST(loop_export_has_the_exact_length) {
    RenderResult r;
    ExportOptions o;
    CHECK(renderExport(groove(), o, r));
    // 4 bars at 140 BPM = 16 beats = 6.857142857 s = 329142.857 samples at 48 kHz, rounded.
    CHECK_EQ(r.frames, int64_t{329143});
    CHECK(r.loop);
    o.sampleRate = 44100;
    CHECK(renderExport(groove(), o, r));
    CHECK_EQ(r.frames, int64_t{302400});
}

TEST(loop_export_matches_playback_bit_for_bit) {
    ProjectSpec p = groove();
    RenderResult r;
    ExportOptions o;
    CHECK(renderExport(p, o, r));
    // Live playback with odd device buffer sizes; its second loop must equal the exported file.
    Engine e(48000);
    e.setProject(p);
    e.play();
    const int64_t len = r.frames;
    std::vector<float> l(static_cast<size_t>(2 * len)), rr(static_cast<size_t>(2 * len));
    for (int64_t i = 0; i < 2 * len; i += 441) {
        const int n = static_cast<int>(std::min<int64_t>(441, 2 * len - i));
        e.process(l.data() + i, rr.data() + i, n);
    }
    bool same = true;
    for (int64_t i = 0; i < len && same; ++i)
        same = r.samples[static_cast<size_t>(i) * 2] == l[static_cast<size_t>(len + i)] &&
               r.samples[static_cast<size_t>(i) * 2 + 1] == rr[static_cast<size_t>(len + i)];
    CHECK(same);
}

TEST(free_length_and_cancel) {
    RenderResult r;
    ExportOptions o;
    o.kind = ExportKind::Free;
    o.seconds = 2.5;
    CHECK(renderExport(groove(), o, r));
    CHECK_EQ(r.frames, int64_t{120000});
    CHECK(!r.loop);
    int32_t progress = 0, cancel = 1;
    CHECK(!renderExport(groove(), o, r, &progress, &cancel));
    CHECK_EQ(r.error, std::string("cancelled"));
    cancel = 0;
    CHECK(renderExport(groove(), o, r, &progress, &cancel));
    CHECK_EQ(progress, 1000);
}

TEST(one_shot_is_one_trimmed_pass) {
    RenderResult r;
    ExportOptions o;
    o.kind = ExportKind::OneShot;
    o.target = "k";
    CHECK(renderExport(groove(), o, r));
    // One 4-step pass is 20571 samples; the kick decays well before the end, so the tail is trimmed.
    CHECK(r.frames > 4800);
    CHECK(r.frames < 20571);
    CHECK(std::fabs(r.samples[static_cast<size_t>(r.frames - 1) * 2]) < 0.01f);
    o.target = "nope";
    CHECK(!renderExport(groove(), o, r));
}

TEST(wavetable_frames_sweep_a_param) {
    ProjectSpec p;
    p.modules.push_back({"w", "---\nmode: float\n---\nparam fold = 1 in 1..8\nsin(sine(1) * fold)", {}});
    RenderResult r;
    ExportOptions o;
    o.kind = ExportKind::Wavetable;
    o.target = "w";
    o.param = "fold";
    o.frames = 16;
    CHECK(renderExport(p, o, r));
    CHECK_EQ(r.channels, 1);
    CHECK_EQ(r.frames, int64_t{16 * kWavetableFrame});
    float peak = 0;
    for (float v : r.samples) peak = std::max(peak, std::fabs(v));
    CHECK_NEAR(peak, 1.0, 1e-6);
    // The first frame is one plain cycle, the last is folded: they differ.
    bool differ = false;
    for (int i = 0; i < kWavetableFrame; ++i)
        differ = differ || std::fabs(r.samples[i] - r.samples[15 * kWavetableFrame + i]) > 0.1f;
    CHECK(differ);
    // Each frame is one cycle: it starts and ends near zero.
    CHECK(std::fabs(r.samples[0]) < 0.01f);
    o.param = "missing";
    CHECK(!renderExport(p, o, r));
}

TEST(export_refuses_broken_modules) {
    ProjectSpec p = groove();
    p.modules[1].source = "t>>";
    RenderResult r;
    CHECK(!renderExport(p, ExportOptions{}, r));
    CHECK(r.error.find("module 'byte'") != std::string::npos);
}

TEST(loop_export_longer_than_a_wav_file_holds_is_refused_before_rendering) {
    // F7.2 lets a song run to the 32-bit step count; a 4-GiB WAV header can't describe two loops of it.
    ProjectSpec p = groove();
    p.loopBars = maxLoopBars(p.beatsPerBar);
    ExportOptions o;
    RenderResult r;
    CHECK(!renderExport(p, o, r));
    CHECK(r.error.find("longer than a WAV file holds") != std::string::npos);
    CHECK(r.samples.empty());
}

TEST(streamed_wav_exports_match_the_in_memory_encoding_byte_for_byte) {
    // Loop and free exports stream to the file in chunks, so memory doesn't grow with the song (F7.2).
    const std::string dir = testTempDir();
    for (const ExportKind kind : {ExportKind::Loop, ExportKind::Free, ExportKind::OneShot}) {
        for (const bool float32 : {false, true}) {
            ExportOptions o;
            o.kind = kind;
            o.seconds = 1.3;
            o.target = "k";
            RenderResult r;
            CHECK(renderExport(groove(), o, r));
            WavSpec spec;
            spec.sampleRate = r.sampleRate;
            spec.channels = r.channels;
            spec.float32 = float32;
            spec.loop = r.loop;
            const std::vector<uint8_t> expected = encodeWav(spec, r.samples.data(), r.frames);
            const std::string path = dir + "/stream.wav";
            std::string error;
            CHECK(renderExportToWav(groove(), o, path, float32, error));
            CHECK(error.empty());
            CHECK(readBytes(path) == expected);
        }
    }
    // A cancelled stream leaves no partial file behind.
    int32_t progress = 0, cancel = 1;
    std::string error;
    const std::string cancelled = dir + "/cancelled.wav";
    CHECK(!renderExportToWav(groove(), ExportOptions{}, cancelled, false, error, &progress, &cancel));
    CHECK(error == "cancelled");
    CHECK(readBytes(cancelled).empty());
    // A cancelled export over an existing file keeps the old file, and nothing half-written is left beside it.
    const std::string kept = dir + "/kept.wav";
    CHECK(writeFile(kept, {1, 2, 3}, error));
    CHECK(!renderExportToWav(groove(), ExportOptions{}, kept, false, error, &progress, &cancel));
    CHECK(readBytes(kept) == std::vector<uint8_t>({1, 2, 3}));
    CHECK(readBytes(kept + ".part").empty());
    // A song longer than a WAV file holds is refused before any file is opened.
    ProjectSpec huge = groove();
    huge.loopBars = maxLoopBars(huge.beatsPerBar);
    const std::string hugePath = dir + "/huge.wav";
    CHECK(!renderExportToWav(huge, ExportOptions{}, hugePath, false, error));
    CHECK(error.find("longer than a WAV file holds") != std::string::npos);
    CHECK(readBytes(hugePath).empty());
}

TEST(offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback) {
    ProjectSpec p;
    p.bpm = 400;
    p.loopBars = 1;
    p.modules.push_back({"tone", "---\nmode: float\n---\n0.5", {}});
    for (int i = 0; i < 1025; ++i) {
        LayerSpec layer;
        layer.id = "layer-" + std::to_string(i);
        layer.name = layer.id;
        layer.chain = {"tone"};
        layer.volume = i == 1024 ? 1.0 : 0.0;
        p.layers.push_back(std::move(layer));
    }

    ExportOptions options;
    options.kind = ExportKind::Free;
    options.seconds = 512.0 / 48000.0;
    RenderResult rendered;
    CHECK(renderExport(p, options, rendered));
    CHECK_EQ(rendered.frames, int64_t{512});

    // No audio callback is attached: install synchronously, then drive process as the playback reference.
    Engine playback(48000);
    CHECK(playback.setProjectOffline(p).find(R"("ok":true)") != std::string::npos);
    playback.play();
    float left[512], right[512];
    playback.process(left, right, 512);
    bool same = true;
    for (int i = 0; i < 512 && same; ++i)
        same = rendered.samples[static_cast<size_t>(i) * 2] == left[i] &&
               rendered.samples[static_cast<size_t>(i) * 2 + 1] == right[i];
    CHECK(same);
    CHECK_NEAR(left[256], static_cast<float>(0.5 * 0.7071067811865476), 1e-5);
}
TEST(wav_encoding) {
    const float x[6] = {0.0f, 1.0f, -1.0f, 0.5f, 2.0f, -0.25f};
    WavSpec s;
    s.loop = true;
    std::vector<uint8_t> b = encodeWav(s, x, 3);
    CHECK(std::memcmp(b.data(), "RIFF", 4) == 0);
    CHECK(std::memcmp(b.data() + 8, "WAVE", 4) == 0);
    CHECK_EQ(le32(b, 4), static_cast<uint32_t>(b.size() - 8));
    CHECK_EQ(b[20] | (b[21] << 8), 1);   // PCM
    CHECK_EQ(b[34] | (b[35] << 8), 24);  // bits
    // smpl chunk follows fmt and loops the whole file.
    CHECK(std::memcmp(b.data() + 36, "smpl", 4) == 0);
    CHECK_EQ(le32(b, 36 + 8 + 44), 0u);  // loop start
    CHECK_EQ(le32(b, 36 + 8 + 48), 2u);  // loop end = last frame
    const size_t data = 36 + 8 + 60;
    CHECK(std::memcmp(b.data() + data, "data", 4) == 0);
    CHECK_EQ(le32(b, data + 4), 18u);
    const uint8_t* d = b.data() + data + 8;
    CHECK(d[3] == 0xFF && d[4] == 0xFF && d[5] == 0x7F);  // 1.0 -> 8388607
    CHECK(d[12] == 0xFF && d[13] == 0xFF && d[14] == 0x7F);  // 2.0 is clamped
    s.float32 = true;
    s.loop = false;
    b = encodeWav(s, x, 3);
    CHECK_EQ(b[20] | (b[21] << 8), 3);  // IEEE float
}
