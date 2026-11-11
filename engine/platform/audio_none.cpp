// Stand-in audio output for builds without a sound device (tests and headless tools).
#include "caw.h"
#include "capi_internal.h"

#include <cstdlib>
#include <cstring>
#include <string>

namespace {

char* dup(const std::string& s) {
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (p) std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}

std::string quoted(const std::string& s) {
    std::string out = "\"";
    for (const char c : s) {
        if (c == '"' || c == '\\') out += '\\';
        if (static_cast<unsigned char>(c) >= 0x20) out += c;
    }
    return out + "\"";
}

}  // namespace

extern "C" {

int32_t caw_audio_start(CawEngine*, char* error, int32_t error_len) {
    const char msg[] = "this build has no audio output";
    if (error && error_len > 0) {
        std::strncpy(error, msg, static_cast<size_t>(error_len - 1));
        error[error_len - 1] = '\0';
    }
    return 1;
}

void caw_audio_stop(CawEngine*) {}

void caw_audio_set_buffer_mode(CawEngine* e, int32_t mode, int32_t recording) {
    if (!e) return;
    e->bufferMode = mode == CAW_BUFFER_LOW_LATENCY || mode == CAW_BUFFER_BATTERY ? mode : CAW_BUFFER_AUTO;
    e->recording = recording != 0;
}

int32_t caw_audio_buffer_frames(CawEngine*) { return 0; }

char* caw_audio_devices(void) { return dup("{\"backend\":\"none\",\"exclusive\":false,\"devices\":[]}"); }

int32_t caw_audio_configure(CawEngine* e, const char* device_id, const char* device_name, int32_t period_frames,
                            int32_t flags) {
    if (!e) return 1;
    e->deviceId = device_id ? std::string(device_id).substr(0, 511) : std::string();
    e->deviceName = device_name ? std::string(device_name).substr(0, 255) : std::string();
    e->periodFrames = period_frames <= 0 ? 0 : period_frames < 16 ? 16 : period_frames > 8192 ? 8192 : period_frames;
    e->audioFlags = flags & CAW_AUDIO_EXCLUSIVE;
    return 0;
}

char* caw_audio_status(CawEngine* e) {
    if (!e) return dup("{\"running\":false}");
    return dup("{\"running\":false,\"backend\":\"none\",\"requested_device\":" + quoted(e->deviceName) +
               ",\"requested_device_id\":" + quoted(e->deviceId) + ",\"requested_frames\":" + std::to_string(e->periodFrames) +
               ",\"exclusive_requested\":" + ((e->audioFlags & CAW_AUDIO_EXCLUSIVE) ? "true" : "false") + "}");
}

}  // extern "C"
