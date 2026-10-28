// Export tests: exact loop lengths, export matching playback, one-shots, wavetables and the WAV encoding.
#include <cmath>
#include <cstring>
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
