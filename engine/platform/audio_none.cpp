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

}  // extern "C"
