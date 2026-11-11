// Audio file decoding (WAV, FLAC, MP3) with miniaudio's bundled decoders, compiled privately (static) into the core.
// miniaudio 0.11.25 carries dr_wav, dr_flac and dr_mp3 (public domain or MIT-0, like the rest of the file). Every
// miniaudio function here is static (MA_API), so this copy never clashes with the device copy in miniaudio_impl.c;
// only caw_decode_audio and caw_decode_free leave this file. Control thread only (it allocates).
#define MA_API static
#define MA_NO_DEVICE_IO
#define MA_NO_THREADING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
// The globals miniaudio defines without MA_API, renamed so they cannot meet the device copy's
// (ma_android_sdk_version is defined on Android only; the Android link failed on it as a duplicate).
#define ma_atomic_global_lock caw_decode_ma_atomic_global_lock
#define ma_android_sdk_version caw_decode_ma_android_sdk_version
#define MINIAUDIO_IMPLEMENTATION
#if defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-function"
#pragma GCC diagnostic ignored "-Wunused-variable"
#pragma GCC diagnostic ignored "-Wunused-parameter"
#endif
#include "miniaudio.h"
#if defined(__GNUC__)
#pragma GCC diagnostic pop
#endif

#include <stdlib.h>
#include <string.h>

#include "decode_audio.h"

static void caw_decode_error(char* error, size_t len, const char* msg) {
    if (!error || len == 0) return;
    size_t n = strlen(msg);
    if (n >= len) n = len - 1;
    memcpy(error, msg, n);
    error[n] = '\0';
}

int caw_decode_audio(const void* data, size_t size, double max_seconds, uint64_t max_bytes, CawDecodedAudio* out,
                     char* error, size_t error_len) {
    ma_decoder_config config;
    ma_decoder decoder;
    float* pcm = NULL;   /* the kept channels, interleaved */
    float* read = NULL;  /* one chunk of every channel the file has */
    uint64_t capacity = 0, frames = 0, max_frames, budget_frames;
    uint32_t channels, keep;
    const uint64_t chunk = 4096;
    int over_budget = 0;
    if (!out) return 0;
    memset(out, 0, sizeof *out);
    if (!data || size == 0) {
        caw_decode_error(error, error_len, "the file is empty");
        return 0;
    }
    config = ma_decoder_config_init(ma_format_f32, 0, 0);  // the file's own channels and rate
    if (ma_decoder_init_memory(data, size, &config, &decoder) != MA_SUCCESS) {
        caw_decode_error(error, error_len, "not a WAV, FLAC or MP3 file miniaudio can read");
        return 0;
    }
    if (decoder.outputChannels < 1 || decoder.outputChannels > 32 || decoder.outputSampleRate < 1000 ||
        decoder.outputSampleRate > 768000) {
        ma_decoder_uninit(&decoder);
        caw_decode_error(error, error_len, "the file has an unsupported channel count or sample rate");
        return 0;
    }
    channels = decoder.outputChannels;
    keep = channels < 2 ? channels : 2;
    /* The limits at the file's real rate and channel count, before anything is decoded. */
    max_frames = max_seconds > 0 ? (uint64_t)(max_seconds * (double)decoder.outputSampleRate) : 0;
    budget_frames = max_bytes / (sizeof(float) * keep);
    if (budget_frames < max_frames) {
        max_frames = budget_frames;
        over_budget = 1;
    }
    if (max_frames > (uint64_t)SIZE_MAX / (sizeof(float) * channels)) max_frames = (uint64_t)SIZE_MAX / (sizeof(float) * channels);
    read = (float*)malloc((size_t)chunk * sizeof(float) * channels);
    if (!read) {
        ma_decoder_uninit(&decoder);
        caw_decode_error(error, error_len, "out of memory decoding the file");
        return 0;
    }
    for (;;) {
        ma_uint64 got = 0;
        uint64_t i;
        uint32_t c;
        if (ma_decoder_read_pcm_frames(&decoder, read, chunk, &got) != MA_SUCCESS || got == 0) break;
        if (frames + got > max_frames) {
            free(read);
            free(pcm);
            ma_decoder_uninit(&decoder);
            caw_decode_error(error, error_len,
                             over_budget ? "the file needs more memory than the audio budget has left"
                                         : "the file is longer than the asset limit");
            return 0;
        }
        if (frames + got > capacity) {
            uint64_t next = capacity ? capacity * 2 : 65536;
            float* grown;
            if (next < frames + got) next = frames + got;
            if (next > max_frames) next = max_frames;
            grown = (float*)realloc(pcm, (size_t)next * sizeof(float) * keep);
            if (!grown) {
                free(read);
                free(pcm);
                ma_decoder_uninit(&decoder);
                caw_decode_error(error, error_len, "out of memory decoding the file");
                return 0;
            }
            pcm = grown;
            capacity = next;
        }
        for (i = 0; i < got; ++i)
            for (c = 0; c < keep; ++c) pcm[(frames + i) * keep + c] = read[i * channels + c];
        frames += got;
    }
    free(read);
    out->channels = keep;
    out->source_channels = channels;
    out->sample_rate = decoder.outputSampleRate;
    ma_decoder_uninit(&decoder);
    if (frames == 0) {
        free(pcm);
        caw_decode_error(error, error_len, "the file holds no audio");
        return 0;
    }
    out->frames = frames;
    out->interleaved = pcm;
    return 1;
}

void caw_decode_free(CawDecodedAudio* audio) {
    if (!audio) return;
    free(audio->interleaved);
    audio->interleaved = NULL;
    audio->frames = 0;
}
