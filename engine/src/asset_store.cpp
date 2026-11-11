// The audio asset store: decoding (miniaudio's WAV/FLAC/MP3), Kaiser-sinc resampling, peaks and the shared cache.
#include "asset_store.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <limits>

#include "../platform/decode_audio.h"
#include "json.h"

namespace caw {

uint64_t AudioAsset::bytes() const noexcept {
    uint64_t b = (data[0].capacity() + data[1].capacity()) * sizeof(float);
    for (const auto& ch : peaks.levels)
        for (const auto& l : ch) b += l.capacity() * sizeof(float);
    return b + sizeof(AudioAsset);
}

namespace {

double besselI0(double x) {
    double sum = 1, term = 1;
    for (int k = 1; k < 64; ++k) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
        if (term < sum * 1e-17) break;
    }
    return sum;
}

}  // namespace

std::vector<float> resampleChannel(const float* in, int64_t frames, double from, double to) {
    if (frames <= 0) return {};
    if (from == to) return std::vector<float>(in, in + frames);
    constexpr int kZeroCrossings = 32;
    constexpr int kPhases = 512;
    constexpr double kBeta = 9.0;
    const double ratio = to / from;
    const double fc = std::min(1.0, ratio) * 0.96;  // cutoff, as a share of the input's Nyquist
    const double half = kZeroCrossings / fc;        // the kernel's half width in input samples
    const int tableLen = static_cast<int>(std::ceil(half * kPhases)) + 2;
    std::vector<double> table(static_cast<size_t>(tableLen));
    const double i0b = besselI0(kBeta);
    for (int k = 0; k < tableLen; ++k) {
        const double t = static_cast<double>(k) / kPhases;
        if (t >= half) { table[static_cast<size_t>(k)] = 0; continue; }
        const double x = 3.14159265358979323846 * fc * t;
        const double sinc = t == 0 ? 1.0 : std::sin(x) / x;
        const double u = t / half;
        table[static_cast<size_t>(k)] = fc * sinc * besselI0(kBeta * std::sqrt(std::max(0.0, 1.0 - u * u))) / i0b;
    }
    auto kernel = [&](double t) {
        t = std::fabs(t) * kPhases;
        const int k = static_cast<int>(t);
        if (k + 1 >= tableLen) return 0.0;
        const double f = t - k;
        return table[static_cast<size_t>(k)] + (table[static_cast<size_t>(k) + 1] - table[static_cast<size_t>(k)]) * f;
    };
    const int64_t outFrames = std::max<int64_t>(1, static_cast<int64_t>(std::floor(static_cast<double>(frames) * ratio)));
    std::vector<float> out(static_cast<size_t>(outFrames));
    const int width = static_cast<int>(std::ceil(half));
    for (int64_t i = 0; i < outFrames; ++i) {
        const double x = static_cast<double>(i) / ratio;
        const int64_t c = static_cast<int64_t>(std::floor(x));
        double acc = 0;
        for (int64_t j = c - width + 1; j <= c + width; ++j) {
            if (j < 0 || j >= frames) continue;
            acc += in[j] * kernel(x - static_cast<double>(j));
        }
        out[static_cast<size_t>(i)] = static_cast<float>(acc);
    }
    return out;
}

void computePeaks(AudioAsset& a) {
    for (uint32_t c = 0; c < 2; ++c) {
        a.peaks.levels[c].clear();
        if (c >= a.channels) continue;
        const float* x = a.data[c].data();
        std::vector<float> level;
        const int64_t blocks = (a.frames + kPeakBlock - 1) / kPeakBlock;
        level.resize(static_cast<size_t>(blocks) * 2);
        for (int64_t b = 0; b < blocks; ++b) {
            float lo = 0, hi = 0;
            const int64_t end = std::min<int64_t>(a.frames, (b + 1) * kPeakBlock);
            for (int64_t i = b * kPeakBlock; i < end; ++i) {
                lo = std::min(lo, x[i]);
                hi = std::max(hi, x[i]);
            }
            level[static_cast<size_t>(b) * 2] = lo;
            level[static_cast<size_t>(b) * 2 + 1] = hi;
        }
        a.peaks.levels[c].push_back(std::move(level));
        while (a.peaks.levels[c].back().size() > 2) {
            const std::vector<float>& prev = a.peaks.levels[c].back();
            const size_t n = prev.size() / 2;
            std::vector<float> next(((n + 1) / 2) * 2);
            for (size_t k = 0; k < (n + 1) / 2; ++k) {
                const size_t i = 2 * k, j = std::min(n - 1, 2 * k + 1);
                next[k * 2] = std::min(prev[i * 2], prev[j * 2]);
                next[k * 2 + 1] = std::max(prev[i * 2 + 1], prev[j * 2 + 1]);
            }
            a.peaks.levels[c].push_back(std::move(next));
        }
    }
}

int32_t readPeaks(const AudioAsset& a, int64_t start, int64_t end, int32_t buckets, uint32_t channel,
                  float* out) noexcept {
    if (!out || buckets <= 0 || end <= start || a.frames <= 0) return 0;
    if (channel >= a.channels) channel = 0;
    const float* x = a.data[channel].data();
    const double span = static_cast<double>(end - start) / buckets;
    const auto& levels = a.peaks.levels[channel];
    // The coarsest level whose entries are no wider than a bucket.
    int level = -1;
    for (int l = 0; l < static_cast<int>(levels.size()); ++l)
        if (static_cast<double>(kPeakBlock) * static_cast<double>(1ull << l) <= span) level = l;
    for (int32_t b = 0; b < buckets; ++b) {
        int64_t s = start + static_cast<int64_t>(std::floor(b * span));
        int64_t e = start + static_cast<int64_t>(std::floor((b + 1) * span));
        if (e <= s) e = s + 1;
        s = std::clamp<int64_t>(s, 0, a.frames);
        e = std::clamp<int64_t>(e, 0, a.frames);
        float lo = 0, hi = 0;
        if (level < 0) {
            for (int64_t i = s; i < e; ++i) {
                lo = std::min(lo, x[i]);
                hi = std::max(hi, x[i]);
            }
        } else {
            const std::vector<float>& l = levels[static_cast<size_t>(level)];
            const int64_t w = static_cast<int64_t>(kPeakBlock) << level;
            const int64_t n = static_cast<int64_t>(l.size() / 2);
            for (int64_t k = s / w; k < n && k * w < e; ++k) {
                lo = std::min(lo, l[static_cast<size_t>(k) * 2]);
                hi = std::max(hi, l[static_cast<size_t>(k) * 2 + 1]);
            }
        }
        out[b * 2] = lo;
        out[b * 2 + 1] = hi;
    }
    return buckets;
}

bool decodeAsset(const uint8_t* bytes, size_t size, double rate, const std::string& name, AudioAsset& out,
                 std::string& error) {
    if (!(rate >= 8000 && rate <= 192000)) {
        error = "the engine rate must be 8000..192000 Hz";
        return false;
    }
    CawDecodedAudio d;
    char why[256] = {0};
    // The most frames any rate up to 768 kHz may hold in kMaxAssetSeconds, checked again below at the real rate.
    if (!caw_decode_audio(bytes, size, static_cast<uint64_t>(kMaxAssetSeconds * 768000.0), &d, why, sizeof why)) {
        error = name + ": " + why;
        return false;
    }
    struct Free {
        CawDecodedAudio* d;
        ~Free() { caw_decode_free(d); }
    } guard{&d};
    if (static_cast<double>(d.frames) > kMaxAssetSeconds * d.sample_rate) {
        error = name + " is longer than " + std::to_string(static_cast<int>(kMaxAssetSeconds / 3600)) + " hours";
        return false;
    }
    out.path = name;
    out.rate = rate;
    out.sourceRate = d.sample_rate;
    out.sourceChannels = d.channels;
    out.sourceFrames = static_cast<int64_t>(d.frames);
    out.channels = d.channels >= 2 ? 2 : 1;
    try {
        std::vector<float> plane(static_cast<size_t>(d.frames));
        for (uint32_t c = 0; c < out.channels; ++c) {
            for (uint64_t i = 0; i < d.frames; ++i) {
                const float v = d.interleaved[i * d.channels + c];
                plane[static_cast<size_t>(i)] = std::isfinite(v) ? std::clamp(v, -8.0f, 8.0f) : 0.0f;
            }
            out.data[c] = resampleChannel(plane.data(), static_cast<int64_t>(d.frames), d.sample_rate, rate);
        }
        out.frames = static_cast<int64_t>(out.data[0].size());
        computePeaks(out);
    } catch (const std::bad_alloc&) {
        error = name + ": out of memory";
        return false;
    }
    return true;
}

AssetStore& AssetStore::global() {
    static AssetStore store;
    return store;
}

namespace {
std::string keyOf(const std::string& path, double rate) {
    char r[32];
    std::snprintf(r, sizeof r, "|%.3f", rate);
    return path + r;
}
}  // namespace

bool AssetStore::makeRoom(uint64_t need) {
    uint64_t total = 0;
    for (const auto& [k, e] : entries_) total += e.asset->bytes();
    while (total + need > budget_) {
        auto victim = entries_.end();
        for (auto it = entries_.begin(); it != entries_.end(); ++it)
            if (it->second.asset.use_count() == 1 && (victim == entries_.end() || it->second.lastUse < victim->second.lastUse))
                victim = it;
        if (victim == entries_.end()) return false;  // everything left is in use
        total -= victim->second.asset->bytes();
        entries_.erase(victim);
    }
    return true;
}

std::shared_ptr<const AudioAsset> AssetStore::insert(const std::string& key, std::shared_ptr<AudioAsset> a,
                                                     uint64_t size, int64_t time, std::string& error) {
    entries_.erase(key);
    if (!makeRoom(a->bytes())) {
        error = a->path + " doesn't fit the audio memory budget (" + std::to_string(budget_ >> 20) + " MB)";
        return nullptr;
    }
    Entry& e = entries_[key];
    e.asset = std::move(a);
    e.fileSize = size;
    e.fileTime = time;
    e.lastUse = ++clock_;
    return e.asset;
}

std::shared_ptr<const AudioAsset> AssetStore::load(const std::string& path, double rate, std::string& error) {
    namespace fs = std::filesystem;
    if (path.empty()) {
        error = "no file named";
        return nullptr;
    }
    if (path.rfind("mem:", 0) == 0) {
        auto found = find(path, rate);
        if (!found) error = path + " is not loaded";
        return found;
    }
    std::error_code ec;
    const uint64_t size = fs::file_size(path, ec);
    if (ec) {
        error = path + " can't be read";
        return nullptr;
    }
    const auto when = fs::last_write_time(path, ec);
    const int64_t time = ec ? 0 : static_cast<int64_t>(when.time_since_epoch().count());
    const std::string key = keyOf(path, rate);
    {
        std::lock_guard<std::mutex> g(lock_);
        auto it = entries_.find(key);
        if (it != entries_.end() && it->second.fileSize == size && it->second.fileTime == time) {
            it->second.lastUse = ++clock_;
            return it->second.asset;
        }
    }
    if (size == 0 || size > kMaxAssetFileBytes) {
        error = size == 0 ? path + " is empty" : path + " is larger than 1 GB";
        return nullptr;
    }
    std::vector<uint8_t> bytes;
    try {
        bytes.resize(static_cast<size_t>(size));
    } catch (const std::bad_alloc&) {
        error = path + ": out of memory";
        return nullptr;
    }
    std::FILE* f = std::fopen(path.c_str(), "rb");
    const bool read = f && std::fread(bytes.data(), 1, bytes.size(), f) == bytes.size();
    if (f) std::fclose(f);
    if (!read) {
        error = path + " can't be read";
        return nullptr;
    }
    auto a = std::make_shared<AudioAsset>();
    if (!decodeAsset(bytes.data(), bytes.size(), rate, path, *a, error)) return nullptr;
    std::lock_guard<std::mutex> g(lock_);
    return insert(key, std::move(a), size, time, error);
}

std::shared_ptr<const AudioAsset> AssetStore::loadBytes(const std::string& name, const uint8_t* bytes, size_t size,
                                                        double rate, std::string& error) {
    auto a = std::make_shared<AudioAsset>();
    if (!decodeAsset(bytes, size, rate, "mem:" + name, *a, error)) return nullptr;
    std::lock_guard<std::mutex> g(lock_);
    return insert(keyOf("mem:" + name, rate), std::move(a), size, 0, error);
}

std::shared_ptr<const AudioAsset> AssetStore::find(const std::string& path, double rate) {
    std::lock_guard<std::mutex> g(lock_);
    auto it = entries_.find(keyOf(path, rate));
    if (it == entries_.end()) return nullptr;
    it->second.lastUse = ++clock_;
    return it->second.asset;
}

void AssetStore::setBudget(uint64_t bytes) {
    std::lock_guard<std::mutex> g(lock_);
    budget_ = std::max<uint64_t>(bytes, 1ull << 20);
    makeRoom(0);
}

uint64_t AssetStore::budget() {
    std::lock_guard<std::mutex> g(lock_);
    return budget_;
}

uint64_t AssetStore::bytes() {
    std::lock_guard<std::mutex> g(lock_);
    uint64_t total = 0;
    for (const auto& [k, e] : entries_) total += e.asset->bytes();
    return total;
}

size_t AssetStore::count() {
    std::lock_guard<std::mutex> g(lock_);
    return entries_.size();
}

void AssetStore::purge() {
    std::lock_guard<std::mutex> g(lock_);
    for (auto it = entries_.begin(); it != entries_.end();)
        it = it->second.asset.use_count() == 1 ? entries_.erase(it) : std::next(it);
}

std::string AssetStore::statusJson() {
    std::lock_guard<std::mutex> g(lock_);
    uint64_t total = 0;
    std::string list;
    for (const auto& [k, e] : entries_) {
        total += e.asset->bytes();
        if (!list.empty()) list += ",";
        list += "{\"path\":\"" + jsonEscape(e.asset->path) + "\",\"rate\":" + std::to_string(static_cast<int>(e.asset->rate)) +
                ",\"bytes\":" + std::to_string(e.asset->bytes()) + ",\"in_use\":" +
                (e.asset.use_count() > 1 ? "true" : "false") + "}";
    }
    return "{\"bytes\":" + std::to_string(total) + ",\"budget\":" + std::to_string(budget_) +
           ",\"count\":" + std::to_string(entries_.size()) + ",\"assets\":[" + list + "]}";
}

}  // namespace caw
