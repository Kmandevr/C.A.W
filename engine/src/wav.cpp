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

// Everything before the samples, with the RIFF size already set for the data and its pad byte.
std::vector<uint8_t> wavHeader(const WavSpec& spec, int64_t frames) {
    const uint32_t bytesPer = spec.float32 ? 4 : 3;
    const uint32_t blockAlign = bytesPer * static_cast<uint32_t>(spec.channels);
    const uint32_t dataBytes = static_cast<uint32_t>(frames) * blockAlign;
    std::vector<uint8_t> b;
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
    const uint32_t riff = static_cast<uint32_t>(b.size() - 8) + dataBytes + (dataBytes & 1);
    for (int i = 0; i < 4; ++i) b[4 + i] = static_cast<uint8_t>(riff >> (8 * i));
    return b;
}

void appendSamples(std::vector<uint8_t>& b, const WavSpec& spec, const float* x, int64_t frames) {
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
}

}  // namespace

std::vector<uint8_t> encodeWav(const WavSpec& spec, const float* x, int64_t frames) {
    std::vector<uint8_t> b = wavHeader(spec, frames);
    const uint32_t dataBytes = static_cast<uint32_t>(frames) * (spec.float32 ? 4u : 3u) * static_cast<uint32_t>(spec.channels);
    b.reserve(b.size() + dataBytes + 1);
    appendSamples(b, spec, x, frames);
    if (dataBytes & 1) b.push_back(0);  // chunks are padded to an even size
    return b;
}

WavFileWriter::~WavFileWriter() { abandon(); }

bool WavFileWriter::open(const std::string& path, const WavSpec& spec, int64_t frames, std::string& error) {
    abandon();
    path_ = path;
    part_ = path + ".part";
    file_ = std::fopen(part_.c_str(), "wb");
    if (!file_) {
        error = "can't open " + part_ + " for writing";
        return false;
    }
    spec_ = spec;
    frames_ = frames;
    written_ = 0;
    failed_ = false;
    buffer_ = wavHeader(spec, frames);
    if (std::fwrite(buffer_.data(), 1, buffer_.size(), file_) != buffer_.size()) {
        error = "couldn't write all of " + path;
        abandon();
        return false;
    }
    return true;
}

bool WavFileWriter::write(const float* x, int64_t frames) {
    if (!file_ || failed_) return false;
    if (frames > frames_ - written_) frames = frames_ - written_;
    buffer_.clear();
    appendSamples(buffer_, spec_, x, frames);
    failed_ = std::fwrite(buffer_.data(), 1, buffer_.size(), file_) != buffer_.size();
    written_ += frames;
    return !failed_;
}

bool WavFileWriter::finish(std::string& error) {
    if (!file_) {
        error = "no WAV file is open";
        return false;
    }
    const uint64_t dataBytes = static_cast<uint64_t>(frames_) * (spec_.float32 ? 4u : 3u) * static_cast<uint32_t>(spec_.channels);
    if (!failed_ && (dataBytes & 1)) failed_ = std::fputc(0, file_) == EOF;
    const bool complete = written_ == frames_;
    const bool closed = std::fclose(file_) == 0;
    file_ = nullptr;
    if (failed_ || !closed || !complete) {
        error = complete ? "couldn't write all of " + path_ : "the render ended before the WAV was complete";
        std::remove(part_.c_str());
        return false;
    }
    std::remove(path_.c_str());  // rename doesn't replace an existing file on Windows
    if (std::rename(part_.c_str(), path_.c_str()) != 0) {
        error = "couldn't move " + part_ + " to " + path_;
        std::remove(part_.c_str());
        return false;
    }
    return true;
}

void WavFileWriter::abandon() {
    if (!file_) return;
    std::fclose(file_);
    file_ = nullptr;
    std::remove(part_.c_str());
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
