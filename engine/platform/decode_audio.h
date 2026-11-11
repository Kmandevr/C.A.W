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
    uint32_t channels;         /* the channels kept: the file's first one or two */
    uint32_t sample_rate;
    uint32_t source_channels;  /* the file's own channel count */
} CawDecodedAudio;

/* Decodes a whole file held in memory, keeping its first one or two channels. Returns 1, or 0 with a message in
   error. The limits are set from the file's real rate and channels as soon as the decoder has read its header, and
   decoding stops as soon as one is passed: max_seconds at the file's rate, and max_bytes for the kept frames
   (4 bytes a sample, at most two channels). */
int caw_decode_audio(const void* data, size_t size, double max_seconds, uint64_t max_bytes, CawDecodedAudio* out,
                     char* error, size_t error_len);
void caw_decode_free(CawDecodedAudio* audio);

#ifdef __cplusplus
}
#endif
#endif
