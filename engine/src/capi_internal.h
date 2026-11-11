// What a CawEngine handle holds, shared by the core C API and the platform audio output.
#pragma once

#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>

#include "engine.h"

struct CawEngine {
    std::unique_ptr<caw::Engine> engine;
    void* audio = nullptr;  // owned by engine/platform
    // The device buffer (caw_audio_set_buffer_mode): CAW_BUFFER_*, and whether the app is recording. Only the
    // control thread touches them, under engine/platform's device lock.
    int bufferMode = 0;
    bool recording = false;
    // The device's choice (caw_audio_configure): a playback device by the backend's id, else by name (both empty:
    // the default), a callback size (0: the buffer mode's) and CAW_AUDIO_* flags. Under the same lock.
    std::string deviceId;
    std::string deviceName;
    int periodFrames = 0;
    int audioFlags = 0;
    // The input (caw_audio_configure_input, API 18): duplex when enabled; a capture device by id, else by name
    // (both empty: the default), and how many channels. Under the same lock.
    bool inputEnabled = false;
    std::string inputId;
    std::string inputName;
    int inputChannels = 2;

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
