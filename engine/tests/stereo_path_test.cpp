// Stereo end to end (#17, #121): left and right kept apart through track inserts, folder buses and a WAV export.
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "engine.h"
#include "project.h"
#include "render.h"
#include "test.h"

using namespace caw;

namespace {

std::string tempWavPath(const char* name) {
    const auto dir = std::filesystem::temp_directory_path() /
                     ("caw_stereo_test_" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(dir);
    return (dir / name).string();
}

// A 32-bit float stereo WAV's samples, de-interleaved (the data chunk found by its tag).
bool readFloatWav(const std::string& path, std::vector<float>& left, std::vector<float>& right) {
    std::ifstream in(path, std::ios::binary);
    const std::vector<char> b((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    for (size_t at = 12; at + 8 <= b.size();) {
        uint32_t size = 0;
        std::memcpy(&size, b.data() + at + 4, 4);
        if (std::memcmp(b.data() + at, "data", 4) == 0) {
            const size_t frames = std::min<size_t>(size, b.size() - at - 8) / 8;
            left.resize(frames);
            right.resize(frames);
            for (size_t i = 0; i < frames; ++i) {
                std::memcpy(&left[i], b.data() + at + 8 + i * 8, 4);
                std::memcpy(&right[i], b.data() + at + 12 + i * 8, 4);
            }
            return frames > 0;
        }
        at += 8 + size + (size & 1);
    }
    return false;
}

double energy(const std::vector<float>& x) {
    double s = 0;
    for (float v : x) s += static_cast<double>(v) * v;
    return s;
}

// The share of the signal that is side, (L - R) / 2, by energy: 0 for mono.
double sideShare(const std::vector<float>& l, const std::vector<float>& r) {
    double mid = 0, side = 0;
    for (size_t i = 0; i < l.size(); ++i) {
        const double m = 0.5 * (l[i] + r[i]), s = 0.5 * (l[i] - r[i]);
        mid += m * m;
        side += s * s;
    }
    return side / std::max(1e-30, mid + side);
}

ComponentSpec component(const std::string& id, std::vector<std::pair<std::string, double>> params = {}) {
    ComponentSpec c;
    c.id = id;
    c.params = std::move(params);
    return c;
}

// A track of the built-in Flagship synth (stereo: its first oscillator's unison is spread across the sides)
// playing a chord, with `inserts` after it.
ProjectSpec flagshipTrack(std::vector<ComponentSpec> inserts) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.seed = 5;
    p.master = 0.8;
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n0 A3 4 0.9\n0 C4 4 0.8\n0 E4 4 0.8\n8 G3 2 0.9\n", {}});
    LayerSpec l;
    l.id = "synth";
    l.name = "synth";
    l.pattern = "pat";
    l.volume = 1.0;
    l.hasInstrument = true;
    l.instrument.id = "org.caw.synth.flagship";
    l.components = std::move(inserts);
    p.layers.push_back(l);
    return p;
}

}  // namespace

TEST(a_stereo_synth_through_width_and_ping_pong_on_a_track_exports_with_left_and_right_apart) {
    // #121's demo: a stereo generator, then width, then the ping-pong delay, on a track; the WAV keeps the sides.
    const ProjectSpec wide = flagshipTrack({component("org.caw.stereo.width", {{"width", 1.8}}),
                                            component("org.caw.delay.pingpong", {{"sync", 2}, {"feedback", 0.5}, {"mix", 0.4}})});
    const std::string path = tempWavPath("demo.wav");
    std::string error;
    ExportOptions o;
    CHECK(renderExportToWav(wide, o, path, true, error));
    std::vector<float> l, r;
    CHECK(readFloatWav(path, l, r));
    CHECK_EQ(l.size(), size_t{96000});  // one bar at 120 BPM, 48 kHz
    CHECK(energy(l) > 1.0 && energy(r) > 1.0);
    const double side = sideShare(l, r);
    CHECK(side > 0.05);  // clearly stereo
    // Width 0 instead: the same chain sums to mono before the delay; the delay's ping-pong alone widens it again,
    // so it must be narrower than the wide chain but not mono.
    ProjectSpec narrow = wide;
    narrow.layers[0].components[0].params = {{"width", 0.0}};
    narrow.layers[0].components[1].params = {{"sync", 2}, {"feedback", 0.5}, {"mix", 0.0}};  // and the delay dry
    RenderResult mono;
    CHECK(renderExport(narrow, o, mono));
    double differ = 0;
    for (int64_t i = 0; i < mono.frames; ++i)
        differ = std::max(differ, std::fabs(static_cast<double>(mono.samples[2 * i] - mono.samples[2 * i + 1])));
    CHECK(differ < 1e-6);  // width 0 and a dry delay: exactly mono (the mixer pans a stereo track as balance)
    std::filesystem::remove_all(std::filesystem::path(path).parent_path());
}
