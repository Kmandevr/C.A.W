// The synth's patch files (kind: synth): parses the readable one-line-per-part format and translates it to C.A.W code.
#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace caw {

// One step of the synth's effect chain, in line order: a generated effect module, or a project module by name.
struct SynthFx {
    bool user = false;
    std::string source;  // generated effect module (user == false)
    std::string module;  // the project module's name (user == true)
};

struct SynthResult {
    bool ok = false;
    std::string error;  // "line 12, col 1: …", positioned in the patch file
    int line = 0, col = 0;
    std::string name, summary;
    std::string generator;     // the voice: a generator module, one note per voice
    std::vector<SynthFx> fx;   // after the voices are summed
};

// A pure function of the text: the same patch always gives the same code. Every value the screen can move becomes a
// param, so a slider moves without recompiling; each part is its own fn so hot swap keeps the others playing.
SynthResult translateSynth(std::string_view source);

}  // namespace caw
