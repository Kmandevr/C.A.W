// WAV file writer: 24-bit PCM or 32-bit float, with an optional `smpl` loop chunk.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace caw {

struct WavSpec {
    int sampleRate = 48000;
    int channels = 2;
    bool float32 = false;  // false writes 24-bit PCM
    bool loop = false;     // adds a smpl chunk looping the whole file
};

std::vector<uint8_t> encodeWav(const WavSpec& spec, const float* interleaved, int64_t frames);
bool writeFile(const std::string& path, const std::vector<uint8_t>& bytes, std::string& error);

}  // namespace caw
