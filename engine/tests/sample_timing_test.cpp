// Note timing is exact to the sample on every platform: ratchets and fractional starts land where strict maths puts them.
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "engine.h"
#include "project.h"
#include "sample_time.h"
#include "test.h"
#include "test_signal.h"
#include "timing_oracle.h"

using namespace caw;

namespace {

// One awkward note: a sample rate and tempo whose step is not a whole number of samples, and a ratchet whose
// repeats fall on half samples, where a fused multiply-add (Arm64) and separate roundings (x86-64, MSVC) part ways.
struct RatchetCase {
    int rate;
    double bpm, at, len;
    int ratchet;
};

// The frames where the test signal's impulses (one on each note-on) sound.
std::vector<int64_t> onsets(const RatchetCase& c, int64_t frames) {
    ProjectSpec p = cawtest::testSignalProject({}, c.bpm, 2);
    char line[96];
    std::snprintf(line, sizeof line, "%.17g C4 %.17g 1 ratchet %d\n", c.at, c.len, c.ratchet);
    p.modules.push_back({"pat", std::string("---\nkind: pattern\nlength: 32\n---\n") + line});
    p.layers.push_back(cawtest::testSignalNotesLayer("l0", cawtest::Shape::Impulse, "pat"));
    Engine e(c.rate);
    e.setMasterBypass(true);
    std::vector<int64_t> at;
    if (e.setProject(p).find("\"ok\":true") == std::string::npos) return at;
    e.play();
    std::vector<float> l(256), r(256);
    for (int64_t i = 0; i < frames; i += 256) {
        e.process(l.data(), r.data(), 256);
        for (int k = 0; k < 256; ++k)
            if (std::fabs(l[static_cast<size_t>(k)]) > 0.1f) at.push_back(i + k);
    }
    return at;
}

}  // namespace

TEST(ratchet_repeats_land_on_the_strict_sample_at_awkward_tempos_and_rates) {
    // Each case has a repeat that a fused multiply-add moves by one sample (found by sweeping rates, tempos,
    // quarter-step starts and lengths, and ratchets 2 to 8).
    const RatchetCase cases[] = {
        {44100, 60, 2, 1, 6},      // repeat 5: 31237 strict, 31238 fused
        {44100, 77, 1.25, 1.25, 6},  // repeat 5: 19688 strict, 19687 fused
        {44100, 140, 2, 1.25, 7},  // repeat 6
        {22050, 77, 5.25, 0.75, 7},  // repeat 6
        {22050, 60, 0.75, 1.25, 7},  // a fractional start; repeat 3
    };
    for (const RatchetCase& c : cases) {
        std::vector<int64_t> want;
        for (int sub = 0; sub < c.ratchet; ++sub)
            want.push_back(cawtest::strictRatchetStart(c.rate, c.bpm, c.at, c.len, c.ratchet, sub));
        const std::vector<int64_t> got = onsets(c, want.back() + 512);
        CHECK_EQ(got.size(), want.size());
        for (size_t i = 0; i < got.size() && i < want.size(); ++i) CHECK_EQ(got[i], want[i]);
    }
}

TEST(sample_time_helpers_match_strict_maths_across_a_sweep) {
    // The helpers every event, clip and loop position goes through (sample_time.h), against the strict reference, over
    // rates, tempos, quarter-step starts and lengths, and ratchets: a fused or reassociated build would miss some.
    int checked = 0, mismatches = 0;
    for (const int rate : {22050, 44100, 48000, 96000})
        for (const double bpm : {60.0, 77.0, 93.0, 100.0, 133.0, 140.0, 174.0, 87.5}) {
            const double frames = sampletime::stepFrames(rate, bpm);
            if (frames != cawtest::strictStepFrames(rate, bpm)) ++mismatches;
            for (int at4 = 0; at4 < 64; ++at4)
                for (int len4 = 1; len4 <= 8; ++len4)
                    for (int ratchet = 2; ratchet <= 8; ++ratchet)
                        for (int sub = 1; sub <= ratchet; ++sub) {
                            const double at = at4 / 4.0, len = len4 / 4.0;
                            const auto got = static_cast<int64_t>(
                                sampletime::roundFrames(sampletime::ratchetStep(at, len, ratchet, sub), frames));
                            if (got != cawtest::strictRatchetStart(rate, bpm, at, len, ratchet, sub)) ++mismatches;
                            ++checked;
                        }
        }
    CHECK(checked > 100000);
    CHECK_EQ(mismatches, 0);
}
