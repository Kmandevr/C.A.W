// WAV file writer: 16-bit or 24-bit PCM (with optional TPDF dither) or 32-bit float, with an optional `smpl` loop chunk.
#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace caw {

struct WavSpec {
    int sampleRate = 48000;
    int channels = 2;
    bool float32 = false;  // false writes PCM of pcmBits
    int pcmBits = 24;      // 16 or 24 (PCM only)
    // TPDF dither (PCM only): +-1 LSB triangular noise added before rounding, from a seeded xorshift32, so the same
    // spec and samples give the same bytes. Exact digital silence stays silent.
    bool dither = false;
    uint32_t ditherSeed = 1;
    bool loop = false;     // adds a smpl chunk looping the whole file
    int bytesPerSample() const noexcept { return float32 ? 4 : (pcmBits == 16 ? 2 : 3); }
};

// frames must be at most kMaxWavFrames (render.h), so the header's 32-bit sizes hold.
std::vector<uint8_t> encodeWav(const WavSpec& spec, const float* interleaved, int64_t frames);
bool writeFile(const std::string& path, const std::vector<uint8_t>& bytes, std::string& error);

// Writes the same bytes as encodeWav to a file, a chunk at a time, so memory doesn't grow with the length.
// The frame count is fixed when the file opens. It writes `path.part` and renames it over `path` in finish(), so a
// cancelled or failed export leaves an existing file untouched and never shows a half-written one.
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
    std::string path_, part_;
    WavSpec spec_;
    int64_t frames_ = 0, written_ = 0;
    bool failed_ = false;
    std::vector<uint8_t> buffer_;
    uint32_t ditherState_ = 1;
};

}  // namespace caw
