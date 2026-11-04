// WAV file writer: 24-bit PCM or 32-bit float, with an optional `smpl` loop chunk.
#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace caw {

struct WavSpec {
    int sampleRate = 48000;
    int channels = 2;
    bool float32 = false;  // false writes 24-bit PCM
    bool loop = false;     // adds a smpl chunk looping the whole file
};

// frames must be at most kMaxWavFrames (render.h), so the header's 32-bit sizes hold.
std::vector<uint8_t> encodeWav(const WavSpec& spec, const float* interleaved, int64_t frames);
bool writeFile(const std::string& path, const std::vector<uint8_t>& bytes, std::string& error);

// Writes the same bytes as encodeWav to a file, a chunk at a time, so memory doesn't grow with the length.
// The frame count is fixed when the file opens; a writer dropped before finish() removes its partial file.
class WavFileWriter {
public:
    WavFileWriter() = default;
    WavFileWriter(const WavFileWriter&) = delete;
    WavFileWriter& operator=(const WavFileWriter&) = delete;
    ~WavFileWriter();
    bool open(const std::string& path, const WavSpec& spec, int64_t frames, std::string& error);
    bool write(const float* interleaved, int64_t frames);  // false once a write fails
    bool finish(std::string& error);                       // pads, closes, and checks every frame was written
    void abandon();                                        // closes and removes the partial file

private:
    std::FILE* file_ = nullptr;
    std::string path_;
    WavSpec spec_;
    int64_t frames_ = 0, written_ = 0;
    bool failed_ = false;
    std::vector<uint8_t> buffer_;
};

}  // namespace caw
