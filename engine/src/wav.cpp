// WAV encoding (RIFF chunks written byte by byte, little-endian on every platform).
#include "wav.h"

#include <cmath>
#include <cstdio>
#include <cstring>

namespace caw {

namespace {

void u16(std::vector<uint8_t>& b, uint32_t v) {
    b.push_back(static_cast<uint8_t>(v));
    b.push_back(static_cast<uint8_t>(v >> 8));
}

void u32(std::vector<uint8_t>& b, uint32_t v) {
    for (int i = 0; i < 4; ++i) b.push_back(static_cast<uint8_t>(v >> (8 * i)));
}

void tag(std::vector<uint8_t>& b, const char* t) { b.insert(b.end(), t, t + 4); }

}  // namespace

std::vector<uint8_t> encodeWav(const WavSpec& spec, const float* x, int64_t frames) {
    const uint32_t bytesPer = spec.float32 ? 4 : 3;
    const uint32_t blockAlign = bytesPer * static_cast<uint32_t>(spec.channels);
    const uint32_t dataBytes = static_cast<uint32_t>(frames) * blockAlign;
    std::vector<uint8_t> b;
    b.reserve(dataBytes + 128);
    tag(b, "RIFF");
    u32(b, 0);  // patched below
    tag(b, "WAVE");
    tag(b, "fmt ");
    u32(b, 16);
    u16(b, spec.float32 ? 3 : 1);  // IEEE float or PCM
    u16(b, static_cast<uint32_t>(spec.channels));
    u32(b, static_cast<uint32_t>(spec.sampleRate));
    u32(b, static_cast<uint32_t>(spec.sampleRate) * blockAlign);
    u16(b, blockAlign);
    u16(b, bytesPer * 8);
    if (spec.float32) {
        tag(b, "fact");
        u32(b, 4);
        u32(b, static_cast<uint32_t>(frames));
    }
    if (spec.loop && frames > 0) {
        tag(b, "smpl");
        u32(b, 36 + 24);
        u32(b, 0);                                                                    // manufacturer
        u32(b, 0);                                                                    // product
        u32(b, static_cast<uint32_t>(1000000000.0 / spec.sampleRate + 0.5));          // sample period (ns)
        u32(b, 60);                                                                   // unity note
        u32(b, 0);                                                                    // pitch fraction
        u32(b, 0);                                                                    // SMPTE format
        u32(b, 0);                                                                    // SMPTE offset
        u32(b, 1);                                                                    // one loop
        u32(b, 0);                                                                    // sampler data
        u32(b, 0);                                                                    // cue id
        u32(b, 0);                                                                    // forward loop
        u32(b, 0);                                                                    // start
        u32(b, static_cast<uint32_t>(frames - 1));                                    // end (last sample)
        u32(b, 0);                                                                    // fraction
        u32(b, 0);                                                                    // play forever
    }
    tag(b, "data");
    u32(b, dataBytes);
    const int64_t n = frames * spec.channels;
    for (int64_t i = 0; i < n; ++i) {
        float v = std::isfinite(x[i]) ? x[i] : 0.0f;
        if (spec.float32) {
            uint32_t bits;
            std::memcpy(&bits, &v, 4);
            u32(b, bits);
        } else {
            double d = v < -1.0f ? -1.0 : (v > 1.0f ? 1.0 : static_cast<double>(v));
            int32_t s = static_cast<int32_t>(std::floor(d * 8388607.0 + 0.5));
            if (s > 8388607) s = 8388607;
            if (s < -8388608) s = -8388608;
            const uint32_t u = static_cast<uint32_t>(s);
            b.push_back(static_cast<uint8_t>(u));
            b.push_back(static_cast<uint8_t>(u >> 8));
            b.push_back(static_cast<uint8_t>(u >> 16));
        }
    }
    if (dataBytes & 1) b.push_back(0);  // chunks are padded to an even size
    const uint32_t riff = static_cast<uint32_t>(b.size() - 8);
    for (int i = 0; i < 4; ++i) b[4 + i] = static_cast<uint8_t>(riff >> (8 * i));
    return b;
}

bool writeFile(const std::string& path, const std::vector<uint8_t>& bytes, std::string& error) {
    std::FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) {
        error = "can't open " + path + " for writing";
        return false;
    }
    const size_t n = std::fwrite(bytes.data(), 1, bytes.size(), f);
    const bool ok = std::fclose(f) == 0 && n == bytes.size();
    if (!ok) error = "couldn't write all of " + path;
    return ok;
}

}  // namespace caw
