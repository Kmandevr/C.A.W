// What a CawEngine handle holds, shared by the core C API and the platform audio output.
#pragma once

#include <condition_variable>
#include <memory>
#include <mutex>

#include "engine.h"

struct CawEngine {
    std::unique_ptr<caw::Engine> engine;
    void* audio = nullptr;  // owned by engine/platform

    // Async control jobs retain the handle until their worker callback has finished.
    bool retainAsync() {
        std::lock_guard<std::mutex> lock(asyncMutex);
        if (destroying) return false;
        ++asyncJobs;
        return true;
    }
    void releaseAsync() {
        std::lock_guard<std::mutex> lock(asyncMutex);
        if (asyncJobs > 0 && --asyncJobs == 0) asyncDone.notify_all();
    }
    void waitAsync() {
        std::unique_lock<std::mutex> lock(asyncMutex);
        destroying = true;
        asyncDone.wait(lock, [this] { return asyncJobs == 0; });
    }

private:
    std::mutex asyncMutex;
    std::condition_variable asyncDone;
    uint32_t asyncJobs = 0;
    bool destroying = false;
};

namespace caw {
// Bundled starter templates, generated from examples/*.caw at build time.
extern const int kTemplateCount;
extern const char* const kTemplateFiles[];
extern const char* const kTemplateSources[];
}  // namespace caw
