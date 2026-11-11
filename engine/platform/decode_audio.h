// The core's audio file decoder (decode_miniaudio.c): WAV, FLAC and MP3 bytes to interleaved floats at the file's rate.
#ifndef CAW_DECODE_AUDIO_H
#define CAW_DECODE_AUDIO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CawDecodedAudio {
    float* interleaved;  /* frames * channels floats, malloc'd; free with caw_decode_free */
    uint64_t frames;
    uint32_t channels;
    uint32_t sample_rate;
} CawDecodedAudio;

/* Decodes a whole file held in memory. Returns 1, or 0 with a message in error (refused beyond max_frames). */
int caw_decode_audio(const void* data, size_t size, uint64_t max_frames, CawDecodedAudio* out, char* error,
                     size_t error_len);
void caw_decode_free(CawDecodedAudio* audio);

#ifdef __cplusplus
}
#endif
#endif
