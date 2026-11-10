// Stand-in audio output for builds without a sound device (tests and headless tools).
#include "caw.h"
#include "capi_internal.h"

#include <cstring>

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

}  // extern "C"
