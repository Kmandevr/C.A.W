// Component samples: a bounds-checked WAV decoder (untrusted files) and loading samples into a processor's slots off the audio thread.
#include "component_samples.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <new>

#include "builtin_drums.h"
#include "caw/module.hpp"

namespace caw {

namespace {

uint32_t le32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24); }
uint16_t le16(const uint8_t* p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }

// Cubic (Catmull-Rom) resampling of a mono signal from `from` Hz to `to` Hz; a one-pole-pair low-pass first when it
// goes down, so what lay above the new Nyquist doesn't fold back much. [Assumption] good enough for one-shots.
std::vector<float> resample(const std::vector<float>& in, double from, double to) {
    if (in.empty() || from == to) return in;
    std::vector<float> src = in;
    if (to < from) {
        const double k = 1.0 - std::exp(-2.0 * 3.14159265358979 * 0.45 * to / from);
        for (int pass = 0; pass < 2; ++pass) {
            double y = 0.0;
            for (float& v : src) v = static_cast<float>(y += (v - y) * k);
        }
    }
    const double step = from / to;
    const size_t n = static_cast<size_t>(static_cast<double>(src.size() - 1) / step) + 1;
    std::vector<float> out(n);
    auto at = [&](long i) { return i < 0 ? src[0] : (static_cast<size_t>(i) >= src.size() ? src.back() : src[static_cast<size_t>(i)]); };
    for (size_t i = 0; i < n; ++i) {
        const double pos = static_cast<double>(i) * step;
        const long j = static_cast<long>(pos);
        const double t = pos - static_cast<double>(j);
        const double a = at(j - 1), b = at(j), c = at(j + 1), d = at(j + 2);
        out[i] = static_cast<float>(b + 0.5 * t * (c - a + t * (2.0 * a - 5.0 * b + 4.0 * c - d + t * (3.0 * (b - c) + d - a))));
    }
    return out;
}

}  // namespace

bool decodeWavBytes(const uint8_t* b, size_t size, double rate, std::vector<float>& out, std::string& error) {
    out.clear();
    if (!b || size < 12 || std::memcmp(b, "RIFF", 4) != 0 || std::memcmp(b + 8, "WAVE", 4) != 0) {
        error = "not a WAV file (RIFF/WAVE)";
        return false;
    }
    if (!(rate >= 8000.0 && rate <= 384000.0)) {
        error = "bad engine sample rate";
        return false;
    }
    uint16_t format = 0, channels = 0, bits = 0, align = 0;
    uint32_t srcRate = 0;
    const uint8_t* data = nullptr;
    size_t dataSize = 0;
    // Walk the chunks; every size is checked against what is left, so a lying header can't read past the end.
    size_t at = 12;
    while (at + 8 <= size) {
        const uint32_t len = le32(b + at + 4);
        const size_t body = at + 8;
        if (len > size - body) {
            if (std::memcmp(b + at, "data", 4) == 0) {  // a truncated data chunk: use what is there
                data = b + body;
                dataSize = size - body;
            }
            break;
        }
        if (std::memcmp(b + at, "fmt ", 4) == 0 && len >= 16) {
            format = le16(b + body);
            channels = le16(b + body + 2);
            srcRate = le32(b + body + 4);
            align = le16(b + body + 12);
            bits = le16(b + body + 14);
            if (format == 0xFFFE && len >= 40) format = le16(b + body + 24);  // extensible: the sub-format's first word
        } else if (std::memcmp(b + at, "data", 4) == 0) {
            data = b + body;
            dataSize = len;
        }
        at = body + len + (len & 1u);
        if (at < body) break;  // overflow guard
    }
    if (!format || !data) {
        error = "the WAV file has no fmt or data chunk";
        return false;
    }
    if (format != 1 && format != 3) {
        error = "unsupported WAV encoding (only PCM and IEEE float)";
        return false;
    }
    if (channels < 1 || channels > 8 || srcRate < 8000 || srcRate > 384000) {
        error = "unsupported WAV channels or sample rate";
        return false;
    }
    const bool okBits = format == 1 ? (bits == 8 || bits == 16 || bits == 24 || bits == 32) : (bits == 32 || bits == 64);
    const uint32_t bytes = bits / 8u;
    if (!okBits || align != channels * bytes) {
        error = "unsupported WAV sample size";
        return false;
    }
    size_t frames = dataSize / align;
    const size_t most = static_cast<size_t>(kMaxSampleSeconds * srcRate);
    if (frames > most) frames = most;  // longer than a slot holds: the start is kept
    if (frames == 0) {
        error = "the WAV file has no samples";
        return false;
    }
    std::vector<float> mono;
    try {
        mono.resize(frames);
    } catch (...) {
        error = "out of memory";
        return false;
    }
    for (size_t f = 0; f < frames; ++f) {
        double sum = 0.0;
        for (uint16_t c = 0; c < channels; ++c) {
            const uint8_t* s = data + f * align + c * bytes;
            double v = 0.0;
            if (format == 3) {
                if (bits == 32) {
                    float x;
                    uint32_t u = le32(s);
                    std::memcpy(&x, &u, 4);
                    v = x;
                } else {
                    uint64_t u = le32(s) | (static_cast<uint64_t>(le32(s + 4)) << 32);
                    double x;
                    std::memcpy(&x, &u, 8);
                    v = x;
                }
                if (!std::isfinite(v)) v = 0.0;
                v = v > 4.0 ? 4.0 : (v < -4.0 ? -4.0 : v);
            } else if (bits == 8) {
                v = (static_cast<int>(s[0]) - 128) / 128.0;
            } else if (bits == 16) {
                v = static_cast<int16_t>(le16(s)) / 32768.0;
            } else if (bits == 24) {
                int32_t x = s[0] | (s[1] << 8) | (s[2] << 16);
                if (x & 0x800000) x -= 0x1000000;
                v = x / 8388608.0;
            } else {
                v = static_cast<int32_t>(le32(s)) / 2147483648.0;
            }
            sum += v;
        }
        mono[f] = static_cast<float>(sum / channels);
    }
    try {
        out = resample(mono, srcRate, rate);
    } catch (...) {
        error = "out of memory";
        return false;
    }
    const size_t keep = static_cast<size_t>(kMaxSampleSeconds * rate);
    if (out.size() > keep) out.resize(keep);
    return true;
}

bool decodeWavFile(const std::string& path, double rate, std::vector<float>& out, std::string& error) {
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (!f) {
        error = "can't open " + path;
        return false;
    }
    std::vector<uint8_t> bytes;
    bool ok = std::fseek(f, 0, SEEK_END) == 0;
    const long size = ok ? std::ftell(f) : -1;
    ok = ok && size > 0 && static_cast<uint64_t>(size) <= kMaxSampleFileBytes && std::fseek(f, 0, SEEK_SET) == 0;
    if (ok) {
        try {
            bytes.resize(static_cast<size_t>(size));
        } catch (...) {
            ok = false;
        }
    }
    ok = ok && std::fread(bytes.data(), 1, bytes.size(), f) == bytes.size();
    std::fclose(f);
    if (!ok) {
        error = size > 0 && static_cast<uint64_t>(size) > kMaxSampleFileBytes ? path + " is larger than 256 MB"
                                                                               : "can't read " + path;
        return false;
    }
    return decodeWavBytes(bytes.data(), bytes.size(), rate, out, error);
}

bool applyComponentSamples(ModuleProcessor& processor, const std::vector<SampleRefSpec>& samples, double rate,
                           std::string& error, std::string* warnings) {
    SampleSlots* slots = dynamic_cast<SampleSlots*>(&processor);
    if (!slots) {
        if (samples.empty()) return true;
        error = "component '" + std::string(processor.descriptor().id) + "' takes no samples";
        return false;
    }
    const uint32_t count = slots->sampleSlotCount();
    std::vector<const SampleRefSpec*> want(count, nullptr);
    for (const SampleRefSpec& s : samples) {
        if (s.slot >= count) {
            error = "sample slot " + std::to_string(s.slot) + " is out of range (0.." + std::to_string(count - 1) + ")";
            return false;
        }
        if (s.path.empty() == s.builtin.empty()) {
            error = "a sample needs exactly one of \"path\" and \"builtin\"";
            return false;
        }
        want[s.slot] = &s;
    }
    uint64_t budget = 0;
    for (uint32_t slot = 0; slot < count; ++slot) {
        const SampleRefSpec* s = want[slot];
        const std::string source = !s ? std::string() : (s->path.empty() ? "builtin:" + s->builtin : "path:" + s->path);
        if (source == slots->sampleSource(slot)) continue;  // unchanged: kept as it is
        std::unique_ptr<SampleBuffer> buffer(new (std::nothrow) SampleBuffer());
        if (!buffer) {
            error = "out of memory";
            return false;
        }
        buffer->source = source;
        if (s) {
            std::string why;
            bool ok;
            if (!s->builtin.empty()) {
                ok = renderBuiltinDrumSample(s->builtin, rate, buffer->data);
                if (!ok) why = "no built-in sample '" + s->builtin + "'";
            } else {
                ok = decodeWavFile(s->path, rate, buffer->data, why);
            }
            budget += buffer->data.size() * sizeof(float);
            if (ok && budget > kMaxSampleBytesPerComponent) {
                ok = false;
                why = "the samples together exceed 64 MB";
            }
            if (!ok) {
                buffer->data.clear();
                if (warnings) *warnings += "sample slot " + std::to_string(slot) + ": " + why + "\n";
            }
        }
        slots->setSample(slot, std::move(buffer));
    }
    return true;
}

}  // namespace caw
