// Golden renders: every bundled template renders to a stored hash, so any platform or code change that alters a bit fails.
#include <cmath>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>

#include "capi_internal.h"
#include "compile.h"
#include "render.h"
#include "test.h"

using namespace caw;

namespace {

const std::string kGoldenPath = std::string(CAW_ROOT) + "/engine/tests/golden.txt";

uint64_t fnv1a(const std::vector<float>& v) {
    uint64_t h = 1469598103934665603ULL;
    for (float f : v) {
        uint32_t bits;
        std::memcpy(&bits, &f, 4);
        for (int i = 0; i < 4; ++i) {
            h ^= (bits >> (8 * i)) & 0xFF;
            h *= 1099511628211ULL;
        }
    }
    return h;
}

std::map<std::string, std::string> readGolden() {
    std::map<std::string, std::string> g;
    std::ifstream f(kGoldenPath);
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        std::string name, hash;
        ss >> name >> hash;
        g[name] = hash;
    }
    return g;
}

}  // namespace

TEST(templates_compile_and_match_golden_renders) {
    std::map<std::string, std::string> golden = readGolden();
    std::map<std::string, std::string> now;
    std::string generator;
    for (int i = 0; i < kTemplateCount; ++i)
        if (std::strcmp(kTemplateFiles[i], "bytebeat-loop.caw") == 0) generator = kTemplateSources[i];
    CHECK(!generator.empty());
    CHECK(kTemplateCount >= 7);
    for (int i = 0; i < kTemplateCount; ++i) {
        const std::string name = kTemplateFiles[i];
        if (moduleKindOf(kTemplateSources[i]) == ModuleKind::Pattern) continue;  // notes, checked in pattern_test
        CompileResult cr = compileModule(kTemplateSources[i]);
        if (!cr.program) {
            cawtest::fail(__FILE__, __LINE__, name + ": " + cr.error);
            continue;
        }
        // Effects are heard through the bytebeat template.
        ProjectSpec p;
        p.bpm = 140;
        p.loopBars = 1;
        p.seed = 7;
        LayerSpec l;
        l.id = "l";
        l.name = name;
        if (cr.program->kind == ModuleKind::Effect) {
            p.modules.push_back({"gen", generator, {}});
            l.chain.push_back("gen");
        }
        p.modules.push_back({"m", kTemplateSources[i], {}});
        l.chain.push_back("m");
        p.layers.push_back(l);
        RenderResult r;
        if (!renderExport(p, ExportOptions{}, r)) {
            cawtest::fail(__FILE__, __LINE__, name + ": " + r.error);
            continue;
        }
        float peak = 0;
        for (float v : r.samples) peak = std::fmax(peak, std::fabs(v));
        if (!(peak > 0.01f)) cawtest::fail(__FILE__, __LINE__, name + " renders silence");
        char hex[17];
        std::snprintf(hex, sizeof hex, "%016llx", static_cast<unsigned long long>(fnv1a(r.samples)));
        now[name] = hex;
        if (!cawtest::updateGolden) {
            auto it = golden.find(name);
            if (it == golden.end())
                cawtest::fail(__FILE__, __LINE__, name + " has no golden hash; run caw_tests --update-golden");
            else if (it->second != hex)
                cawtest::fail(__FILE__, __LINE__, name + " renders " + hex + ", golden is " + it->second);
        }
    }
    if (cawtest::updateGolden) {
        std::ofstream f(kGoldenPath);
        f << "# Hash of each template's 1-bar loop render at 140 BPM, 48 kHz, seed 7 (FNV-1a over float bits).\n"
             "# Regenerate only for an intended sound change: caw_tests --update-golden\n";
        for (auto& [name, hash] : now) f << name << " " << hash << "\n";
        std::printf("wrote %s\n", kGoldenPath.c_str());
    }
}
