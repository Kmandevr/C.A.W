// The audio asset store: files decoded and resampled off the audio thread, shared by clips and sampler zones, with peaks.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

namespace caw {

// Limits on one asset (untrusted input; docs/engine.md, "Audio assets").
inline constexpr uint64_t kMaxAssetFileBytes = 1ull << 30;       // a larger file is refused unread
inline constexpr double kMaxAssetSeconds = 3.0 * 3600.0;          // after decoding, at the file's rate
inline constexpr uint64_t kDefaultAssetBudget = 1ull << 30;       // every asset together (1 GiB)
inline constexpr uint32_t kPeakBlock = 256;                       // frames per finest peak entry

// Min/max overview of one channel: levels[0] has one (min, max) pair per kPeakBlock frames, each next level
// one per twice as many.
struct AssetPeaks {
    std::vector<std::vector<float>> levels[2];  // [channel][level] -> min, max, min, max, ...
};

// One decoded file at one engine rate. Immutable once made; shared (refcounted) by everything that plays it.
// The audio thread only reads `channel(c)[i]` through a pointer some timeline or zone map holds.
struct AudioAsset {
    std::string path;        // what it was loaded from ("mem:name" for bytes)
    double rate = 48000;     // the engine rate it was resampled to
    double sourceRate = 0;   // the file's own rate
    uint32_t channels = 1;   // 1 or 2 (more are taken as their first two)
    uint32_t sourceChannels = 1;
    int64_t frames = 0;      // at `rate`
    int64_t sourceFrames = 0;
    std::vector<float> data[2];  // planar; data[1] is empty for mono
    AssetPeaks peaks;
    uint64_t bytes() const noexcept;
    const float* channel(uint32_t c) const noexcept { return data[c < channels ? c : 0].data(); }
    double seconds() const noexcept { return rate > 0 ? static_cast<double>(frames) / rate : 0; }
};

// Bandlimited resampling of one channel (Kaiser-windowed sinc, 32 taps per side at the lower rate), after halfband
// decimation stages while the source is at least 4 x the target: the same bits on every device. Control thread.
std::vector<float> resampleChannel(const float* in, int64_t frames, double from, double to);
// Fills asset.peaks from asset.data.
void computePeaks(AudioAsset& asset);
// (min, max) pairs for `buckets` equal parts of [startFrame, endFrame) of channel `channel` (frames at the
// asset's rate); returns the buckets written. Any thread (the asset is immutable).
int32_t readPeaks(const AudioAsset& asset, int64_t startFrame, int64_t endFrame, int32_t buckets, uint32_t channel,
                  float* out) noexcept;

// Decodes bytes (WAV, FLAC, MP3) into an asset at `rate`. False with `error`, also as soon as the decoded or
// resampled samples would need more than `maxBytes` (the budget left; checked before they are allocated).
bool decodeAsset(const uint8_t* bytes, size_t size, double rate, const std::string& name, AudioAsset& out,
                 std::string& error, uint64_t maxBytes = kDefaultAssetBudget);

// The process-wide store. Every call is on a control thread (it decodes and allocates) and takes the store's
// lock; the audio thread never calls it. An asset stays while anything holds it; the store's own reference is
// dropped when the budget needs room (least recently used first) or on purge().
class AssetStore {
public:
    static AssetStore& global();
    // The asset for `path` at `rate`, decoding it once (again if the file's size or time changed). Null with
    // `error` for a file that is missing, too large, unreadable, or over the budget.
    std::shared_ptr<const AudioAsset> load(const std::string& path, double rate, std::string& error);
    // Bytes in memory (tests, hosts that read files themselves): addressed afterwards as "mem:" + name.
    std::shared_ptr<const AudioAsset> loadBytes(const std::string& name, const uint8_t* bytes, size_t size, double rate,
                                                std::string& error);
    // A cached asset, without loading; null when it isn't loaded at this rate.
    std::shared_ptr<const AudioAsset> find(const std::string& path, double rate);
    void setBudget(uint64_t bytes);
    uint64_t budget();
    uint64_t bytes();     // decoded bytes the store's assets hold
    size_t count();
    void purge();         // drops every asset nothing else holds
    std::string statusJson();

private:
    struct Entry {
        std::shared_ptr<const AudioAsset> asset;
        uint64_t fileSize = 0;
        int64_t fileTime = 0;
        uint64_t lastUse = 0;
    };
    std::shared_ptr<const AudioAsset> insert(const std::string& key, std::shared_ptr<AudioAsset> a, uint64_t size,
                                             int64_t time, std::string& error);
    bool makeRoom(uint64_t need);
    uint64_t roomLeft();  // the budget less what assets in use hold (the rest can be evicted)
    std::mutex lock_;
    std::map<std::string, Entry> entries_;
    uint64_t budget_ = kDefaultAssetBudget, clock_ = 0;
};

}  // namespace caw
