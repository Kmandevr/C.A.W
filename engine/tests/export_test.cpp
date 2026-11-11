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
#include "test_signal.h"
#include "wav.h"

using namespace caw;

namespace {

ProjectSpec groove() {
    ProjectSpec p;
    p.bpm = 140;
    p.loopBars = 4;
    // A one-step note every 4 steps, and a 3-bar riff against the 4-bar project.
    p.modules.push_back({"kick", "---\nkind: pattern\nlength: 4\n---\n0 C2 1 1\n"});
    p.modules.push_back({"riff", "---\nkind: pattern\nlength: 48\n---\n0 A2 3 1\n5 C3 2 0.7\n17 E3 5 0.9\n30 G2 1/2 0.6\n"});
    LayerSpec a = cawtest::testSignalNotesLayer("k", cawtest::Shape::Sine, "kick", {{"level", 0.8}});
    a.name = "Kick";
    LayerSpec b = cawtest::testSignalNotesLayer("b", cawtest::Shape::Saw, "riff", {{"level", 0.5}});
    b.name = "Riff";
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

TEST(loop_export_uses_the_loop_range_and_matches_playback_bit_for_bit) {
    ProjectSpec p = groove();
    p.loopRange = true;
    p.loopStartSteps = 8;
    p.loopEndSteps = 40;
    RenderResult r;
    ExportOptions o;
    CHECK(renderExport(p, o, r));
    const double stepLen = 60.0 * 48000 / (140 * 4.0);
    const auto at = [&](int steps) { return static_cast<int64_t>(std::floor(steps * stepLen + 0.5)); };
    CHECK_EQ(r.frames, at(40) - at(8));
    // Playback goes from the start to the range's end, back to its start, and on: the second pass is the file.
    Engine e(48000);
    e.setProject(p);
    e.play();
    const int64_t total = at(40) + r.frames;
    std::vector<float> l(static_cast<size_t>(total)), rr(static_cast<size_t>(total));
    for (int64_t i = 0; i < total; i += 441) {
        const int n = static_cast<int>(std::min<int64_t>(441, total - i));
        e.process(l.data() + i, rr.data() + i, n);
    }
    bool same = true;
    for (int64_t i = 0; i < r.frames && same; ++i)
        same = r.samples[static_cast<size_t>(i) * 2] == l[static_cast<size_t>(at(40) + i)] &&
               r.samples[static_cast<size_t>(i) * 2 + 1] == rr[static_cast<size_t>(at(40) + i)];
    CHECK(same);
    // Off, the loop export is the whole song again.
    p.loopRange = false;
    CHECK(renderExport(p, o, r));
    CHECK_EQ(r.frames, int64_t{329143});
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

TEST(one_shot_of_a_cpp_instrument_plays_one_note_to_its_tail) {
    // A track with only a C++ instrument and its effects plays one note: here the test signal's 1 kHz sine at
    // velocity 0.5 for 0.1 s (4800 frames), cut on its off, so the file is the note and what the master's DC block rings on.
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalNotesLayer("t", cawtest::Shape::Sine, "")});
    p.layers[0].pattern.clear();
    RenderResult r;
    ExportOptions o;
    o.kind = ExportKind::OneShot;
    o.target = "t";
    o.note = 83.2131;  // about 1 kHz
    o.velocity = 0.5;
    o.noteSeconds = 0.1;
    CHECK(renderExport(p, o, r));
    // The master's DC block rings out the cut's offset below 0.002, and the file ends once it is under -80 dB.
    CHECK(r.frames > 4800 && r.frames < 12000);
    for (int64_t f = 4810; f < r.frames; ++f) CHECK(std::fabs(r.samples[static_cast<size_t>(f) * 2]) < 0.002f);
    float peak = 0;
    for (int64_t f = 0; f < 4800; ++f) peak = std::max(peak, std::fabs(r.samples[static_cast<size_t>(f) * 2]));
    CHECK_NEAR(peak, 0.5 * std::cos(3.14159265358979323846 / 4), 0.01);  // velocity times the centre pan
    // The note's pitch: the test signal's sine at A4 for 0.5 s crosses up about 220 times.
    p.layers[0].instrument = cawtest::testSignal(cawtest::Shape::Sine, {{"mode", 1}});
    o.note = 69;
    o.velocity = 1;
    o.noteSeconds = 0.5;
    CHECK(renderExport(p, o, r));
    int ups = 0;
    for (int64_t f = 1; f < r.frames; ++f) ups += r.samples[(f - 1) * 2] < 0 && r.samples[f * 2] >= 0;
    CHECK(ups >= 219 && ups <= 220);
    // Flagship rings on after its note (its release), and the file ends on the trimmed tail, well before 30 s.
    p.layers[0].instrument = ComponentSpec{};
    p.layers[0].instrument.id = "org.caw.synth.flagship";
    CHECK(renderExport(p, o, r));
    CHECK(r.frames > 24000);
    CHECK(r.frames < 30 * 48000);
    CHECK(std::fabs(r.samples[static_cast<size_t>(r.frames - 1) * 2]) < 0.01f);
    // Clips set the length: one clip of 8 steps from step 4 (12 steps, 72000 frames at 120 BPM) plays its note.
    p.layers[0].instrument = cawtest::testSignal(cawtest::Shape::Sine, {{"mode", 1}});
    p.modules.push_back({"pat", "---\nkind: pattern\nlength: 8\n---\n0 C4 8 1\n"});
    p.layers[0].clips = {ClipSpec{"c", "pat", 4, 8, 0, false, false}};
    CHECK(renderExport(p, o, r));
    CHECK(r.frames > 71900 && r.frames <= 72000);
    float before = 0, during = 0;
    for (int64_t f = 0; f < 24000; ++f) before = std::max(before, std::fabs(r.samples[static_cast<size_t>(f) * 2]));
    for (int64_t f = 24000; f < 71000; ++f) during = std::max(during, std::fabs(r.samples[static_cast<size_t>(f) * 2]));
    CHECK_EQ(before, 0.0f);
    CHECK(during > 0.5f);
}

TEST(wavetable_frames_sweep_a_cpp_instruments_parameter) {
    // The test signal in Notes mode on a layer: frame f is one cycle of A0 with shape f (sine, saw, square, ...).
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalNotesLayer("osc", cawtest::Shape::Sine, "")});
    RenderResult r;
    ExportOptions o;
    o.kind = ExportKind::Wavetable;
    o.target = "osc";
    o.param = "shape";
    o.frames = 3;  // shape 0, 3 (noise), 6 (sweep): min + (max - min) * f / (frames - 1)
    CHECK(renderExport(p, o, r));
    CHECK_EQ(r.channels, 1);
    CHECK_EQ(r.frames, int64_t{3 * kWavetableFrame});
    // Frame 0 is one sine cycle: 0 at the start, the peak a quarter in, the trough three quarters in.
    CHECK(std::fabs(r.samples[0]) < 1e-3f);
    CHECK(r.samples[512] > 0.3f);
    CHECK_NEAR(r.samples[1536], -r.samples[512], 1e-3);
    float peak = 0;
    for (float v : r.samples) peak = std::max(peak, std::fabs(v));
    CHECK_NEAR(peak, 1.0, 1e-6);
    // Seven frames, one per shape: each differs from the sine.
    o.frames = 7;
    CHECK(renderExport(p, o, r));
    for (int f = 1; f < 7; ++f) {
        bool differ = false;
        for (int i = 0; i < kWavetableFrame; ++i)
            differ = differ || std::fabs(r.samples[i] - r.samples[static_cast<size_t>(f) * kWavetableFrame + i]) > 0.05f;
        CHECK(differ);
    }
    // A square frame (shape 2) is flat on each half: its samples a quarter in and an eighth in match.
    const float* square = r.samples.data() + 2 * kWavetableFrame;
    CHECK_NEAR(square[256], square[512], 1e-6);
    CHECK_NEAR(square[1280], square[1536], 1e-6);
    CHECK(square[512] > 0 && square[1536] < 0);
    // A built-in by id, with its defaults; no sweep gives the same frame each time.
    o.target = "org.caw.synth.flagship";
    o.param.clear();
    o.frames = 2;
    CHECK(renderExport(p, o, r));
    CHECK(r.samples[100] == r.samples[kWavetableFrame + 100]);
    // Refusals: an effect, a missing parameter, a missing target.
    o.target = "org.caw.stereo.width";
    CHECK(!renderExport(p, o, r));
    CHECK(r.error.find("takes no notes") != std::string::npos);
    o.target = "osc";
    o.param = "missing";
    CHECK(!renderExport(p, o, r));
    CHECK(r.error.find("no parameter 'missing'") != std::string::npos);
    o.target = "nothing";
    o.param.clear();
    CHECK(!renderExport(p, o, r));
}

TEST(export_refuses_broken_patterns) {
    ProjectSpec p = groove();
    p.modules[1].source = "---\nkind: pattern\nlength: 48\n---\n0 Q2 3 1\n";
    RenderResult r;
    CHECK(!renderExport(p, ExportOptions{}, r));
    CHECK(r.error.find("pattern 'riff'") != std::string::npos);
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
    p.master = 1.0;  // The sample assertion below is for unity master gain.
    // 1024 bus folders (a project runs at most 256 native components), then one track, all sent as commands.
    for (int i = 0; i < 1024; ++i) {
        LayerSpec bus;
        bus.id = "layer-" + std::to_string(i);
        bus.name = bus.id;
        bus.folder = true;
        bus.busEnabled = true;
        bus.volume = 0.0;
        p.layers.push_back(std::move(bus));
    }
    p.layers.push_back(cawtest::testSignalLayer("layer-1024", cawtest::Shape::Sine, {{"freq", 220}, {"level", 0.5}}));

    ExportOptions options;
    options.kind = ExportKind::Free;
    // Free exports have a 100 ms minimum duration; compare that complete render with playback.
    options.seconds = 0.1;
    RenderResult rendered;
    CHECK(renderExport(p, options, rendered));
    CHECK_EQ(rendered.frames, int64_t{4800});

    // No audio callback is attached: install synchronously, then drive process as the playback reference.
    Engine playback(48000);
    CHECK(playback.setProjectOffline(p).find(R"("ok":true)") != std::string::npos);
    playback.play();
    std::vector<float> left(4800), right(4800);
    playback.process(left.data(), right.data(), 4800);
    bool same = true;
    for (int i = 0; i < 4800 && same; ++i)
        same = rendered.samples[static_cast<size_t>(i) * 2] == left[i] &&
               rendered.samples[static_cast<size_t>(i) * 2 + 1] == right[i];
    CHECK(same);
    // The final layer must contribute audible output; avoid assuming a particular waveform phase.
    float peak = 0.0f;
    for (float sample : left) {
        const float magnitude = std::abs(sample);
        if (magnitude > peak) peak = magnitude;
    }
    CHECK(peak > 0.25f);
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
