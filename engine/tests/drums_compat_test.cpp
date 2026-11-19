// org.caw.drums' 1.1.0 additions are append-only: every kit and sound that existed before renders bit-identically.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "builtin_drums.h"
#include "engine.h"
#include "presets.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

// The same busy bar drums_test.cpp plays (every bank-A pad), at 120 BPM.
const char* kBar =
    "0 C2 1 1\n0 F#2 1 0.8\n1 F#2 1 0.5\n2 F#2 1 0.7\n2 C#2 1 0.6\n3 F#2 1 0.5\n4 D2 1 1\n4 D#2 1 0.8\n4 F#2 1 0.8\n"
    "5 F#2 1 0.5\n6 A#2 1 0.7\n7 G#2 1 0.6\n8 C2 1 1\n8 C#3 1 0.9\n9 E2 1 0.5\n10 F2 1 0.8\n10 G2 1 0.8\n11 A2 1 0.7\n"
    "12 D2 1 1\n12 B2 1 0.8\n13 C3 1 0.7\n14 D3 1 0.8\n14 D#3 1 0.7\n15 F#2 1 0.6\n";

uint64_t renderHash(const std::vector<std::pair<std::string, double>>& params) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.seed = 7;
    p.master = 0.8;
    p.modules.push_back({"pat", std::string("---\nkind: pattern\nname: P\nlength: 16\n---\n") + kBar});
    LayerSpec l;
    l.id = "t";
    l.name = "t";
    l.pattern = "pat";
    l.volume = 1.0;
    l.hasInstrument = true;
    l.instrument.id = "org.caw.drums";
    l.instrument.params = params;
    p.layers.push_back(l);
    Engine e(48000);
    const std::string r = e.setProjectOffline(p);
    if (r.find("\"ok\":true") == std::string::npos) return 0;
    e.play();
    uint64_t h = 1469598103934665603ull;
    float lb[64], rb[64];
    for (int done = 0; done < 48000 * 2; done += 64) {
        e.process(lb, rb, 64);
        for (int i = 0; i < 64; ++i)
            for (float x : {lb[i], rb[i]}) {
                uint32_t bits = 0;
                std::memcpy(&bits, &x, 4);
                for (int k = 0; k < 4; ++k) h = (h ^ ((bits >> (8 * k)) & 0xFF)) * 1099511628211ull;
            }
    }
    return h;
}

// Recorded from the drums before 1.1.0 (20bcb8b), every preset on the busy bar for 2 s (CAW_PRINT_DRUM_HASHES=1
// prints this table).
struct Known {
    const char* preset;
    uint64_t hash;
};
#include "drums_compat_hashes.inc"

}  // namespace

TEST(drums_presets_from_before_1_1_render_bit_identically) {
    const bool print = true;  // throwaway branch: print the old code's hashes on every platform
    std::vector<std::string> names;
    if (print) {
        for (const BuiltinPreset& b : drumsPresets()) names.emplace_back(b.name);
    } else {
        for (const Known& k : kKnown) names.emplace_back(k.preset);
    }
    size_t i = 0;
    for (const std::string& name : names) {
        std::vector<std::pair<std::string, double>> values;
        CHECK(applyBuiltinPreset("org.caw.drums", name, values));
        const uint64_t h = renderHash(values);
        if (print) {
            std::printf("    {\"%s\", 0x%016llxull},\n", name.c_str(), static_cast<unsigned long long>(h));
        } else if (h != kKnown[i].hash) {
            cawtest::fail(__FILE__, __LINE__, name + " renders differently from before 1.1.0");
        }
        ++i;
    }
    if (!print) CHECK(i >= 60);
    cawtest::fail(__FILE__, __LINE__, "printed the hashes (throwaway branch)");
}
