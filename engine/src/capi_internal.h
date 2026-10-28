// What a CawEngine handle holds, shared by the core C API and the platform audio output.
#pragma once

#include <memory>

#include "engine.h"

struct CawEngine {
    std::unique_ptr<caw::Engine> engine;
    void* audio = nullptr;  // owned by engine/platform
};

namespace caw {
// Bundled starter templates, generated from examples/*.caw at build time.
extern const int kTemplateCount;
extern const char* const kTemplateFiles[];
extern const char* const kTemplateSources[];
}  // namespace caw
