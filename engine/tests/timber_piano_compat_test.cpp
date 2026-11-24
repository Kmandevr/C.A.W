// Timber's piano (org.caw.timber, model 0) after 1.1.2's Simulated mode: every 1.1.0 piano preset renders bit-identically (hashed per build), and Classic ignores every appended knob.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "builtin_timber.h"
#include "engine.h"
#include "presets.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

// A bar across the keyboard at 120 BPM: low, middle and top notes (the top ones have no dampers), soft to hard,
// overlapping, short and long; the loop starts again at 2 s, so each key is struck again while it still sounds.
const char* kBar =
    "0 A0 8 0.9\n0 C2 3 0.6\n0 E3 2 0.3\n1 G3 1 0.8\n2 C4 4 1.0\n3 E4 2 0.5\n4 A#1 6 0.7\n4 G4 1 0.2\n5 C5 2 0.9\n"
    "6 F#5 3 0.6\n7 D6 1 0.8\n8 C7 4 1.0\n8 A2 4 0.45\n9 E5 1 0.7\n10 G6 2 0.4\n11 B3 3 0.95\n12 C8 2 0.6\n12 D3 4 0.8\n"
    "13 F4 1 0.35\n14 A4 2 0.75\n15 C#6 1 0.55\n";

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
    l.instrument.id = "org.caw.timber";
    l.instrument.params = params;
    p.layers.push_back(l);
    Engine e(48000);
    const std::string r = e.setProjectOffline(p);
    if (r.find("\"ok\":true") == std::string::npos) return 0;
    e.play();
    uint64_t h = 1469598103934665603ull;
    float lb[64], rb[64];
    for (int done = 0; done < 48000 * 3; done += 64) {
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

bool isPiano(const BuiltinPreset& b) {
    for (const auto& [id, v] : b.values)
        if (id == "variant") return v == 0.0;
    return false;
}

// Recorded from the piano before 1.1.2 (1.1.1, 2a9934c), every piano preset (and the default) on the bar for 3 s
// (CAW_PRINT_PIANO_HASHES=1 prints this table). Bits are promised per platform only (docs/engine.md
// "Determinism"), so each build has the old code's own table: x86-64 Release, x86-64 Debug (the sanitizer job) and
// Arm64 (cross-built, run under qemu), each from 2a9934c with this test (2026-11-20). Windows (clang-cl) has no
// table yet: there, the second test below still holds Classic to its knobs.
struct Known {
    const char* preset;
    uint64_t hash;
};
#if defined(__aarch64__) || defined(_M_ARM64)
#include "timber_piano_compat_hashes_arm64.inc"
#define CAW_PIANO_HASHES 1
#elif defined(_WIN32)
#define CAW_PIANO_HASHES 0
#elif !defined(__OPTIMIZE__)
#include "timber_piano_compat_hashes_x64_debug.inc"
#define CAW_PIANO_HASHES 1
#else
#include "timber_piano_compat_hashes.inc"
#define CAW_PIANO_HASHES 1
#endif

std::vector<std::pair<std::string, double>> presetValues(const std::string& name) {
    std::vector<std::pair<std::string, double>> values;
    if (name == "(default)") values = {{"variant", 0}};
    else if (!applyBuiltinPreset("org.caw.timber", name, values)) values.clear();
    return values;
}

}  // namespace

TEST(timber_piano_presets_from_before_1_1_2_render_bit_identically) {
    const bool print = std::getenv("CAW_PRINT_PIANO_HASHES") != nullptr;
    std::vector<std::string> names;
    if (print) {
        names.emplace_back("(default)");
        for (const BuiltinPreset& b : builtinPresets("org.caw.timber"))
            if (isPiano(b)) names.emplace_back(b.name);
    }
#if CAW_PIANO_HASHES
    if (!print)
        for (const Known& k : kKnown) names.emplace_back(k.preset);
#endif
    size_t i = 0;
    for (const std::string& name : names) {
        const auto values = presetValues(name);
        CHECK(!values.empty());
        const uint64_t h = renderHash(values);
        CHECK(h != 0);
        if (print) {
            std::printf("    {\"%s\", 0x%016llxull},\n", name.c_str(), static_cast<unsigned long long>(h));
        } else {
#if CAW_PIANO_HASHES
            if (h != kKnown[i].hash) cawtest::fail(__FILE__, __LINE__, name + " renders differently from before 1.1.2");
#endif
        }
        ++i;
    }
#if CAW_PIANO_HASHES
    if (!print) CHECK(i >= 9);
#endif
}
