// The sample preview on the audio thread (API 33, #229): starts, seeks, stops, volume changes and a track's route never allocate there.
#include <cmath>
#include <memory>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "asset_store.h"
#include "engine.h"
#include "sample_preview.h"
#include "test.h"

using namespace caw;

TEST(the_sample_preview_never_allocates_on_the_audio_thread) {
    auto a = std::make_shared<AudioAsset>();
    a->rate = a->sourceRate = 48000;
    a->channels = a->sourceChannels = 2;
    a->frames = a->sourceFrames = 24000;
    for (int c = 0; c < 2; ++c) {
        a->data[c].resize(24000);
        for (int i = 0; i < 24000; ++i) a->data[c][static_cast<size_t>(i)] = static_cast<float>(0.3 * std::sin(0.05 * i));
    }
    Engine e(48000);
    CHECK(e.setProjectJson(R"({"caw_project":1,"bpm":120,"master":1,"layers":[{"id":"t","volume":0.7,
        "input":{"channel":0,"channels":1,"monitor":"off"}}]})").find("\"ok\":true") != std::string::npos);
    std::vector<float> l(192), r(192);
    std::string error;
    PreviewOptions loop;
    loop.loop = true;
    PreviewOptions stretched;
    stretched.ratio = 1.5;
    stretched.sync = 1;
    std::size_t operations = 0;
    float peak = 0;
    PreviewOptions through = loop;
    through.slot = e.previewSlot("t");
    CHECK(through.slot >= 0);
    for (int round = 0; round < 8; ++round) {
        // Commands come from the control side between callbacks; only the callbacks are counted.
        if (round == 0) CHECK(e.samplePreview().start(a, loop, error));
        if (round == 1) e.samplePreview().seek(0.2);
        if (round == 2) e.samplePreview().setVolume(0.3);
        if (round == 3) CHECK(e.samplePreview().start(a, stretched, error));
        if (round == 4) e.samplePreview().stop();
        if (round == 5) {
            CHECK(e.samplePreview().start(a, loop, error));
            e.play();
        }
        if (round == 6) CHECK(e.samplePreview().start(a, through, error));  // through the track, playing
        if (round == 7) {
            e.stop();
            CHECK(e.samplePreview().start(a, through, error));  // and stopped (the track is woken)
        }
        cawtest::AllocationScope scope;
        for (int k = 0; k < 100; ++k) {
            e.process(l.data(), r.data(), 192);
            for (float v : l) peak = std::fabs(v) > peak ? std::fabs(v) : peak;
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.05f);
}
