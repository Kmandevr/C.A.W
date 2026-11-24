// org.caw.timber's 1.1.2 additions are append-only: every 1.1.0 preset of the electric piano, organ, plucked, bowed, mallets and winds renders bit-identically.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "presets.h"
#include "test.h"
#include "timber_harness.h"

using namespace caw;
using namespace timber_test;

namespace {

// A phrase that reaches every path a 1.1.0 preset has: chords, a held note, the pedal, the mod wheel and a bend-free
// legato line, 2 s at 48 kHz in 64-frame blocks, hashed over both channels' bits (FNV-1a).
uint64_t renderHash(const Values& v) {
    auto p = make(v);
    if (!p) return 0;
    const std::vector<Note> n = {{0.0, 0.6, 48, 0.9}, {0.0, 0.6, 55, 0.7}, {0.0, 0.6, 64, 0.8}, {0.5, 1.4, 67, 0.5},
                                 {0.7, 0.9, 72, 1.0}, {0.9, 1.1, 74, 0.6}, {1.1, 1.3, 76, 0.4}, {1.2, -1, 41, 0.85}};
    const Stereo s = play(*p, v, n, 2.0, 48000, 64, {{0.3, 64, 1.0}, {0.8, 64, 0.0}, {0.4, 1, 0.6}, {1.5, 1, 0.0}});
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < s.size(); ++i)
        for (float x : {s.l[i], s.r[i]}) {
            uint32_t bits = 0;
            std::memcpy(&bits, &x, 4);
            for (int k = 0; k < 4; ++k) h = (h ^ ((bits >> (8 * k)) & 0xFF)) * 1099511628211ull;
        }
    return h;
}

// Recorded from Timber as 1.1.0 shipped it (Main 2a9934c, before the 1.1.2 models), every non-piano preset
// (CAW_PRINT_TIMBER_HASHES=1 prints this table). Bits are only promised per platform (docs/engine.md
// "Determinism"), so each build kind has its own table; one not yet recorded is printed, not checked.
struct Known {
    const char* preset;
    uint64_t hash;
};
#if defined(__x86_64__) && defined(__OPTIMIZE__) && !defined(_WIN32)
#define CAW_TIMBER_HASHES 1
#include "timber_compat_hashes.inc"
#else
#define CAW_TIMBER_HASHES 0
const Known kKnown[] = {{"", 0}};
#endif

}  // namespace

TEST(timber_presets_from_1_1_0_render_bit_identically) {
    const bool print = std::getenv("CAW_PRINT_TIMBER_HASHES") != nullptr || !CAW_TIMBER_HASHES;
    std::vector<std::string> names;
    if (print) {
        for (const BuiltinPreset& b : builtinPresets(kTimber)) {
            bool piano = false;
            for (const auto& [id, x] : b.values) piano = piano || (id == "variant" && x == 0.0);
            if (!piano) names.emplace_back(b.name);
        }
    } else {
        for (const Known& k : kKnown) names.emplace_back(k.preset);
    }
    size_t i = 0;
    for (const std::string& name : names) {
        std::vector<std::pair<std::string, double>> values;
        CHECK(applyBuiltinPreset(kTimber, name, values));
        const uint64_t h = renderHash(Values(values.begin(), values.end()));
        if (print) std::printf("    {\"%s\", 0x%016llxull},\n", name.c_str(), static_cast<unsigned long long>(h));
        else if (h != kKnown[i].hash) cawtest::fail(__FILE__, __LINE__, name + " renders differently from 1.1.0");
        ++i;
    }
    if (!print) CHECK(i == 36);
}
