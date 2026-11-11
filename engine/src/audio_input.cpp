// Audio input: monitoring frames, the recorder (lock-free ring, background WAV writer, takes), latency ping, recovery.
#include "audio_input.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>

#include "json.h"
#include "sample_pack.h"

namespace caw {

namespace {
thread_local LiveAudio* gBuilding = nullptr;
}

LiveAudio* buildingLiveAudio() noexcept { return gBuilding; }
BuildingLiveAudio::BuildingLiveAudio(LiveAudio* a) noexcept : was_(gBuilding) { gBuilding = a; }
BuildingLiveAudio::~BuildingLiveAudio() { gBuilding = was_; }

// ---------------------------------------------------------------- FloatRing

bool FloatRing::allocate(size_t capacity) {
    size_t n = 1;
    while (n < capacity) n <<= 1;
    buf_.reset(new (std::nothrow) float[n]);
    if (!buf_) return false;
    mask_ = n - 1;
    write_.store(0);
    read_.store(0);
    return true;
}
size_t FloatRing::writable() const noexcept {
    if (!buf_) return 0;
    return mask_ + 1 - (write_.load(std::memory_order_relaxed) - read_.load(std::memory_order_acquire));
}
size_t FloatRing::readable() const noexcept {
    return write_.load(std::memory_order_acquire) - read_.load(std::memory_order_relaxed);
}
bool FloatRing::push(const float* v, size_t n) noexcept {
    if (writable() < n) return false;
    const size_t w = write_.load(std::memory_order_relaxed);
    for (size_t i = 0; i < n; ++i) buf_[(w + i) & mask_] = v[i];
    write_.store(w + n, std::memory_order_release);
    return true;
}
size_t FloatRing::pop(float* out, size_t n) noexcept {
    n = std::min(n, readable());
    const size_t r = read_.load(std::memory_order_relaxed);
    for (size_t i = 0; i < n; ++i) out[i] = buf_[(r + i) & mask_];
    read_.store(r + n, std::memory_order_release);
    return n;
}

// ---------------------------------------------------------------- WAV takes

namespace {

void le16(uint8_t* p, uint32_t v) { p[0] = v & 255; p[1] = (v >> 8) & 255; }
void le32(uint8_t* p, uint32_t v) { for (int i = 0; i < 4; ++i) p[i] = (v >> (8 * i)) & 255; }

// A 44-byte RIFF header: PCM (format 1, 24-bit) or IEEE float (format 3, 32-bit).
void wavHeader(uint8_t* h, int rate, int channels, bool float32, uint64_t dataBytes) {
    const uint32_t bytes = float32 ? 4 : 3;
    const uint32_t data = static_cast<uint32_t>(std::min<uint64_t>(dataBytes, 0xFFFFFFFFull - 36));
    std::memcpy(h, "RIFF", 4);
    le32(h + 4, 36 + data);
    std::memcpy(h + 8, "WAVEfmt ", 8);
    le32(h + 16, 16);
    le16(h + 20, float32 ? 3 : 1);
    le16(h + 22, static_cast<uint32_t>(channels));
    le32(h + 24, static_cast<uint32_t>(rate));
    le32(h + 28, static_cast<uint32_t>(rate) * channels * bytes);
    le16(h + 32, channels * bytes);
    le16(h + 34, bytes * 8);
    std::memcpy(h + 36, "data", 4);
    le32(h + 40, data);
}

std::string jnum(double v) {
    char b[40];
    std::snprintf(b, sizeof b, "%.10g", v);
    return b;
}

}  // namespace

struct LiveAudio::Session {
    struct Track {
        std::string layer, part, path;
        int channel = 0, channels = 1;
        std::FILE* f = nullptr;
        int64_t frames = 0, sinceHeader = 0;
        bool failed = false;
        std::vector<uint8_t> buf;
    };
    struct Take {
        std::string layer, path;
        int take = 0, channels = 1;
        int64_t startFrame = 0, frames = 0;
        bool complete = false;
        std::string error;
    };
    struct Hist {
        int64_t linear = 0, pos = 0;
        int32_t frames = 0;
    };
    std::string dir;
    double bpm = 120, stepLen = 1500;
    bool float32 = true;
    bool punch = false;
    int64_t punchIn = 0, punchOut = 0;
    int64_t latency = 0;
    int rate = 48000;
    std::vector<Track> tracks;
    std::mutex m;  // guards takes, error and the counters below (status reads them)
    std::vector<Take> takes;
    std::string error;
    int64_t linear = 0;  // input frames seen (with gaps)
    int takeIndex = 0;
    bool inTake = false;
    int64_t lastPos = 0, takeStart = 0;
    std::deque<Hist> hist;

    std::string takeJson(const Take& t) const {
        return "{\"layer\":\"" + jsonEscape(t.layer) + "\",\"path\":\"" + jsonEscape(t.path) + "\",\"take\":" +
               std::to_string(t.take) + ",\"start_frame\":" + std::to_string(t.startFrame) + ",\"start_steps\":" +
               jnum(static_cast<double>(t.startFrame) / stepLen) + ",\"frames\":" + std::to_string(t.frames) +
               ",\"seconds\":" + jnum(static_cast<double>(t.frames) / rate) + ",\"channels\":" +
               std::to_string(t.channels) + ",\"sample_rate\":" + std::to_string(rate) + ",\"bpm\":" + jnum(bpm) +
               ",\"complete\":" + (t.complete ? "true" : "false") + ",\"error\":\"" + jsonEscape(t.error) + "\"}";
    }
    void sidecar(const Take& t) const {
        std::ofstream f(t.path + ".json", std::ios::binary | std::ios::trunc);
        f << takeJson(t);
    }
    void header(Track& tr) {
        if (!tr.f) return;
        uint8_t h[44];
        wavHeader(h, rate, tr.channels, float32, static_cast<uint64_t>(tr.frames) * tr.channels * (float32 ? 4 : 3));
        const long end = std::ftell(tr.f);
        if (std::fseek(tr.f, 0, SEEK_SET) != 0 || std::fwrite(h, 1, 44, tr.f) != 44 || std::fseek(tr.f, end, SEEK_SET) != 0)
            tr.failed = true;
        std::fflush(tr.f);
    }
    void flush(Track& tr) {
        if (!tr.f || tr.buf.empty()) return;
        if (!tr.failed && std::fwrite(tr.buf.data(), 1, tr.buf.size(), tr.f) != tr.buf.size()) {
            tr.failed = true;
            std::lock_guard<std::mutex> g(m);
            error = "can't write " + tr.part + " (is the storage full?)";
        }
        tr.buf.clear();
        if (tr.sinceHeader >= rate) {  // about every second the header counts what is written, for recovery
            tr.sinceHeader = 0;
            header(tr);
        }
    }
    void begin(int64_t pos) {
        inTake = true;
        takeStart = pos;
        ++takeIndex;
        for (Track& tr : tracks) {
            const std::string name = sanitizeFileName(tr.layer) + "-take" + std::to_string(takeIndex) + ".wav";
            tr.path = (std::filesystem::path(dir) / name).generic_string();
            tr.part = tr.path + ".part";
            tr.frames = tr.sinceHeader = 0;
            tr.failed = false;
            tr.f = std::fopen(tr.part.c_str(), "wb");
            if (!tr.f) {
                tr.failed = true;
                std::lock_guard<std::mutex> g(m);
                error = "can't create " + tr.part;
                continue;
            }
            uint8_t h[44];
            wavHeader(h, rate, tr.channels, float32, 0);
            if (std::fwrite(h, 1, 44, tr.f) != 44) tr.failed = true;
            Take t;
            t.layer = tr.layer;
            t.path = tr.path;
            t.take = takeIndex;
            t.channels = tr.channels;
            t.startFrame = pos;
            sidecar(t);
        }
    }
    void end() {
        if (!inTake) return;
        inTake = false;
        for (Track& tr : tracks) {
            if (!tr.f) continue;
            flush(tr);
            header(tr);
            const bool ok = !tr.failed;
            std::fclose(tr.f);
            tr.f = nullptr;
            std::error_code ec;
            std::filesystem::rename(tr.part, tr.path, ec);
            Take t;
            t.layer = tr.layer;
            t.path = tr.path;
            t.take = takeIndex;
            t.channels = tr.channels;
            t.startFrame = takeStart;
            t.frames = tr.frames;
            t.complete = ok && !ec;
            if (!ok) t.error = "the take was cut short: the file could not be written";
            sidecar(t);
            std::lock_guard<std::mutex> g(m);
            takes.push_back(std::move(t));
        }
    }
    // The song position heard when input frame `l` (linear) was played: the chunk history, latency frames back.
    int64_t positionOf(int64_t l) const {
        for (auto it = hist.rbegin(); it != hist.rend(); ++it)
            if (l >= it->linear) return it->pos + (l - it->linear);
        return hist.empty() ? l : hist.front().pos - (hist.front().linear - l);
    }
    void chunk(int64_t songPos, int frames, const float* x, int ringChannels) {
        hist.push_back({linear, songPos, frames});
        while (hist.size() > 2 && hist[1].linear + hist[1].frames <= linear - latency - 1) hist.pop_front();
        for (int j = 0; j < frames; ++j) {
            const int64_t pos = positionOf(linear + j - latency);
            const bool inRange = !punch || (pos >= punchIn && pos < punchOut);
            if (inTake && (!inRange || pos != lastPos + 1)) end();
            if (inRange && !inTake) begin(pos);
            if (!inTake) continue;
            lastPos = pos;
            for (Track& tr : tracks) {
                for (int c = 0; c < tr.channels; ++c) {
                    const int ch = tr.channel + c;
                    float v = x && ch < ringChannels ? x[static_cast<size_t>(j) * ringChannels + ch] : 0.0f;
                    if (!std::isfinite(v)) v = 0;
                    if (float32) {
                        uint8_t b[4];
                        std::memcpy(b, &v, 4);
                        tr.buf.insert(tr.buf.end(), b, b + 4);
                    } else {
                        const double s = std::clamp(static_cast<double>(v), -1.0, 1.0) * 8388607.0;
                        const int32_t q = static_cast<int32_t>(std::lround(s));
                        tr.buf.push_back(static_cast<uint8_t>(q & 255));
                        tr.buf.push_back(static_cast<uint8_t>((q >> 8) & 255));
                        tr.buf.push_back(static_cast<uint8_t>((q >> 16) & 255));
                    }
                }
                ++tr.frames;
                ++tr.sinceHeader;
                if (tr.buf.size() >= (1u << 16)) flush(tr);
            }
        }
        linear += frames;
    }
};

// ---------------------------------------------------------------- LiveAudio

LiveAudio::LiveAudio(double sampleRate) : sr_(sampleRate) {
    for (auto& p : peaks_) p.store(0.0f, std::memory_order_relaxed);
}

LiveAudio::~LiveAudio() {
    if (writer_.joinable()) {
        armed_.store(false);
        stopWriter_.store(true);
        writer_.join();
    }
}

void LiveAudio::beginCallback(const float* in, int channels, int frames) noexcept {
    in_ = in;
    inChannels_ = in ? std::clamp(channels, 0, kMaxInputChannels) : 0;
    inFrames_ = in ? frames : 0;
    chunkAt_ = 0;
    for (int c = 0; c < inChannels_; ++c) {
        float peak = peaks_[c].load(std::memory_order_relaxed);
        for (int i = 0; i < frames; ++i) peak = std::max(peak, std::fabs(in[static_cast<size_t>(i) * inChannels_ + c]));
        peaks_[c].store(peak, std::memory_order_relaxed);
    }
}

void LiveAudio::chunk(int at, int frames, int64_t songPos, bool playing) noexcept {
    chunkAt_ = at;
    if (!playing || !armed_.load(std::memory_order_acquire) || !headers_ || frames <= 0 || frames > 512) return;
    const size_t need = static_cast<size_t>(frames) * static_cast<size_t>(ringChannels_);
    if (samples_.writable() < need || headers_->writable() == 0) {
        gap_ += frames;
        dropped_.fetch_add(frames, std::memory_order_relaxed);
        return;
    }
    for (int i = 0; i < frames; ++i)
        for (int c = 0; c < ringChannels_; ++c) scratch_[static_cast<size_t>(i) * ringChannels_ + c] = input(c, i);
    samples_.push(scratch_.get(), need);
    headers_->push({songPos, frames, gap_});
    gap_ = 0;
}

int64_t LiveAudio::latency() const noexcept {
    const int64_t o = latencyOverride_.load(std::memory_order_relaxed);
    if (o >= 0) return o;
    const int64_t m = measured_.load(std::memory_order_relaxed);
    return m >= 0 ? m : deviceLatency_.load(std::memory_order_relaxed);
}

std::string LiveAudio::latencyJson() const {
    const int64_t o = latencyOverride_.load(), m = measured_.load(), d = deviceLatency_.load();
    const int64_t f = latency();
    return "{\"frames\":" + std::to_string(f) + ",\"ms\":" + jnum(1000.0 * f / sr_) + ",\"source\":\"" +
           (o >= 0 ? "override" : m >= 0 ? "measured" : "device") + "\",\"override\":" + std::to_string(o) +
           ",\"measured\":" + std::to_string(m) + ",\"device\":" + std::to_string(d) + "}";
}

int LiveAudio::peaks(float* out, int max) noexcept {
    const int n = std::min(max, deviceChannels_.load(std::memory_order_relaxed));
    for (int c = 0; c < n && c < kMaxInputChannels; ++c) out[c] = peaks_[c].exchange(0.0f, std::memory_order_relaxed);
    return std::max(0, std::min(n, kMaxInputChannels));
}

namespace {
std::string failJson(const std::string& e) { return "{\"ok\":false,\"error\":\"" + jsonEscape(e) + "\"}"; }
}

std::string LiveAudio::startRecording(std::string_view requestJson) {
    std::lock_guard<std::mutex> g(ctl_);
    if (writer_.joinable()) return failJson("already recording");
    Json j;
    std::string error;
    if (!parseJson(requestJson, j, error)) return failJson(error);
    auto s = std::make_unique<Session>();
    s->dir = j.string("dir");
    std::error_code ec;
    if (s->dir.empty() || !std::filesystem::is_directory(s->dir, ec)) return failJson("\"dir\" must be an existing folder");
    s->bpm = j.number("bpm", 120);
    if (!(s->bpm >= 20 && s->bpm <= 400)) return failJson("bpm must be 20..400");
    s->rate = static_cast<int>(std::lround(sr_));
    s->stepLen = 60.0 * sr_ / (s->bpm * 4.0);
    const double bits = j.number("bits", 32);
    if (bits != 24 && bits != 32) return failJson("bits must be 24 (PCM) or 32 (float)");
    s->float32 = bits == 32;
    const Json* in = j.get("punch_in_steps");
    const Json* out = j.get("punch_out_steps");
    if ((in && in->type == Json::Type::Number) || (out && out->type == Json::Type::Number)) {
        const double a = j.number("punch_in_steps", 0), b = j.number("punch_out_steps", 1e15);
        if (!(a >= 0 && b > a)) return failJson("punch_out_steps must be after punch_in_steps");
        s->punch = true;
        s->punchIn = static_cast<int64_t>(std::floor(a * s->stepLen + 0.5));
        s->punchOut = b >= 1e15 ? INT64_MAX : static_cast<int64_t>(std::floor(b * s->stepLen + 0.5));
    }
    s->latency = latency();
    int ringChannels = 0;
    const Json* tracks = j.get("tracks");
    if (!tracks || tracks->type != Json::Type::Array || tracks->arr.empty() || tracks->arr.size() > 64)
        return failJson("\"tracks\" must list 1..64 {\"layer\", \"channel\", \"channels\"}");
    for (const Json& t : tracks->arr) {
        Session::Track tr;
        tr.layer = t.string("layer");
        const double c = t.number("channel", 0), n = t.number("channels", 1);
        if (tr.layer.empty() || !(c >= 0 && c < kMaxInputChannels && c == std::floor(c)) || !(n == 1 || n == 2) ||
            c + n > kMaxInputChannels)
            return failJson("every track needs a \"layer\", a \"channel\" 0..31 and \"channels\" 1 or 2");
        tr.channel = static_cast<int>(c);
        tr.channels = static_cast<int>(n);
        ringChannels = std::max(ringChannels, tr.channel + tr.channels);
        s->tracks.push_back(std::move(tr));
    }
    // Two seconds of every channel in use, and a chunk's worth to fill.
    ringChannels_ = ringChannels;
    if (!samples_.allocate(static_cast<size_t>(2.0 * sr_) * static_cast<size_t>(ringChannels)))
        return failJson("out of memory");
    scratch_.reset(new (std::nothrow) float[512 * static_cast<size_t>(ringChannels)]);
    if (!headers_) headers_ = std::make_unique<Spsc<Header, 8192>>();
    Header drain;
    while (headers_->pop(drain)) {
    }
    if (!scratch_) return failJson("out of memory");
    session_ = std::move(s);
    gap_ = 0;
    dropped_.store(0);
    stopWriter_.store(false);
    writer_ = std::thread([this] { writerLoop(); });
    armed_.store(true, std::memory_order_release);
    return "{\"ok\":true,\"error\":\"\",\"latency_frames\":" + std::to_string(session_->latency) + "}";
}

void LiveAudio::writerLoop() {
    Session& s = *session_;
    std::vector<float> block;
    for (;;) {
        const bool stopping = stopWriter_.load(std::memory_order_acquire);
        Header h;
        bool any = false;
        while (headers_->pop(h)) {
            any = true;
            if (h.gapBefore > 0) {  // frames the ring had no room for: silence in their place, so the take stays in time
                block.assign(static_cast<size_t>(h.gapBefore) * ringChannels_, 0.0f);
                s.chunk(h.songPos - h.gapBefore, h.gapBefore, block.data(), ringChannels_);
            }
            block.resize(static_cast<size_t>(h.frames) * ringChannels_);
            samples_.pop(block.data(), block.size());
            s.chunk(h.songPos, h.frames, block.data(), ringChannels_);
        }
        if (stopping && !any) break;
        if (!any) std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    s.end();
}

std::string LiveAudio::recordingStatus() {
    std::lock_guard<std::mutex> g(ctl_);
    std::string out = std::string("{\"recording\":") + (writer_.joinable() ? "true" : "false") +
                      ",\"dropped_frames\":" + std::to_string(dropped_.load()) + ",\"latency\":" + latencyJson();
    if (session_) {
        std::lock_guard<std::mutex> m(session_->m);
        out += ",\"error\":\"" + jsonEscape(session_->error) + "\",\"takes\":[";
        for (size_t i = 0; i < session_->takes.size(); ++i) out += (i ? "," : "") + session_->takeJson(session_->takes[i]);
        out += "]";
    } else {
        out += ",\"error\":\"\",\"takes\":[]";
    }
    return out + "}";
}

std::string LiveAudio::stopRecording() {
    {
        std::lock_guard<std::mutex> g(ctl_);
        if (!writer_.joinable()) return "{\"ok\":false,\"error\":\"not recording\",\"takes\":[]}";
        armed_.store(false, std::memory_order_release);
        stopWriter_.store(true, std::memory_order_release);
        writer_.join();
    }
    std::string status = recordingStatus();
    return "{\"ok\":true," + status.substr(1);
}

std::string LiveAudio::recover(const std::string& dir) {
    namespace fs = std::filesystem;
    std::string list;
    std::error_code ec;
    if (!fs::is_directory(dir, ec)) return failJson(dir + " is not a folder");
    for (const auto& e : fs::directory_iterator(dir, ec)) {
        const std::string p = e.path().generic_string();
        if (p.size() < 9 || p.compare(p.size() - 9, 9, ".wav.part") != 0) continue;
        std::FILE* f = std::fopen(p.c_str(), "r+b");
        if (!f) continue;
        uint8_t h[44] = {};
        const bool read = std::fread(h, 1, 44, f) == 44 && std::memcmp(h, "RIFF", 4) == 0 && std::memcmp(h + 36, "data", 4) == 0;
        std::fseek(f, 0, SEEK_END);
        const long size = std::ftell(f);
        if (!read || size < 44) {
            std::fclose(f);
            continue;
        }
        const int channels = h[22] | (h[23] << 8);
        const int rate = h[24] | (h[25] << 8) | (h[26] << 16) | (h[27] << 24);
        const int align = h[32] | (h[33] << 8);
        const bool float32 = (h[20] | (h[21] << 8)) == 3;
        const uint64_t data = align > 0 ? (static_cast<uint64_t>(size) - 44) / align * align : 0;
        wavHeader(h, rate, channels, float32, data);
        std::fseek(f, 0, SEEK_SET);
        std::fwrite(h, 1, 44, f);
        std::fclose(f);
        if (static_cast<uint64_t>(size) > 44 + data) fs::resize_file(p, 44 + data, ec);
        std::string final = p.substr(0, p.size() - 5);
        if (fs::exists(final, ec)) final = final.substr(0, final.size() - 4) + "-recovered.wav";
        fs::rename(p, final, ec);
        if (ec) continue;
        const int64_t frames = align > 0 ? static_cast<int64_t>(data / align) : 0;
        // The sidecar written at the take's start says where it goes; the frames and the recovery are added.
        std::string side, layer;
        int64_t start = 0;
        double steps = 0;
        int take = 0;
        double bpm = 0;
        {
            std::ifstream sf(p.substr(0, p.size() - 5) + ".json", std::ios::binary);
            std::string text((std::istreambuf_iterator<char>(sf)), std::istreambuf_iterator<char>());
            Json j;
            std::string err;
            if (!text.empty() && parseJson(text, j, err) && j.type == Json::Type::Object) {
                layer = j.string("layer");
                start = static_cast<int64_t>(j.number("start_frame", 0));
                steps = j.number("start_steps", 0);
                take = static_cast<int>(j.number("take", 0));
                bpm = j.number("bpm", 0);
            }
        }
        side = "{\"layer\":\"" + jsonEscape(layer) + "\",\"path\":\"" + jsonEscape(final) + "\",\"take\":" +
               std::to_string(take) + ",\"start_frame\":" + std::to_string(start) + ",\"start_steps\":" + jnum(steps) +
               ",\"frames\":" + std::to_string(frames) + ",\"seconds\":" + jnum(rate > 0 ? double(frames) / rate : 0) +
               ",\"channels\":" + std::to_string(channels) + ",\"sample_rate\":" + std::to_string(rate) +
               ",\"bpm\":" + jnum(bpm) + ",\"complete\":false,\"recovered\":true,\"error\":\"\"}";
        {
            std::ofstream out(final + ".json", std::ios::binary | std::ios::trunc);
            out << side;
        }
        fs::remove(p.substr(0, p.size() - 5) + ".json", ec);
        list += (list.empty() ? "" : ",") + side;
    }
    return "{\"ok\":true,\"error\":\"\",\"takes\":[" + list + "]}";
}

// ---------------------------------------------------------------- latency ping

bool LiveAudio::startPing() {
    std::lock_guard<std::mutex> g(ctl_);
    const int s = pingState_.load();
    if (s == 1 || s == 2) return false;
    burst_.assign(4096, 0.0f);
    uint32_t x = 0x1234567u;
    for (size_t i = 0; i < burst_.size(); ++i) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        const double w = std::min({1.0, i / 64.0, (burst_.size() - 1 - i) / 64.0});
        burst_[i] = static_cast<float>(w * 0.25 * ((x >> 8) / 8388608.0 - 1.0));
    }
    capture_.assign(static_cast<size_t>(sr_) + burst_.size(), 0.0f);  // a second of input after the burst starts
    pingAt_ = 0;
    pingLast_.clear();
    pingState_.store(1, std::memory_order_release);
    return true;
}

void LiveAudio::afterCallback(float* left, float* right, int frames) noexcept {
    int s = pingState_.load(std::memory_order_acquire);
    if (s == 1) {
        pingState_.store(2, std::memory_order_relaxed);
        s = 2;
    }
    if (s != 2) return;
    for (int i = 0; i < frames; ++i) {
        const size_t k = pingAt_ + static_cast<size_t>(i);
        if (k < burst_.size()) {
            left[i] = std::clamp(left[i] + burst_[k], -1.0f, 1.0f);
            right[i] = std::clamp(right[i] + burst_[k], -1.0f, 1.0f);
        }
        if (k < capture_.size()) {
            float sum = 0;
            for (int c = 0; c < inChannels_; ++c) sum += in_[static_cast<size_t>(i) * inChannels_ + c];
            capture_[k] = in_ && i < inFrames_ ? sum : 0.0f;
        }
    }
    pingAt_ += static_cast<size_t>(frames);
    if (pingAt_ >= capture_.size()) pingState_.store(3, std::memory_order_release);
}

std::string LiveAudio::pingResult() {
    std::lock_guard<std::mutex> g(ctl_);
    const int s = pingState_.load(std::memory_order_acquire);
    if (s == 1 || s == 2) return "{\"state\":\"running\"}";
    if (s == 0) return pingLast_.empty() ? "{\"state\":\"idle\"}" : pingLast_;
    // Cross-correlation of the burst with what came back: the best lag is the round trip.
    const size_t lags = capture_.size() - burst_.size();
    double best = 0, sum = 0;
    size_t at = 0;
    for (size_t lag = 0; lag < lags; ++lag) {
        double c = 0;
        for (size_t i = 0; i < burst_.size(); ++i) c += static_cast<double>(burst_[i]) * capture_[lag + i];
        c = std::fabs(c);
        sum += c;
        if (c > best) {
            best = c;
            at = lag;
        }
    }
    const double mean = lags ? sum / static_cast<double>(lags) : 0;
    const double confidence = mean > 0 ? best / mean : 0;
    const bool ok = best > 1e-6 && confidence >= 8.0;
    if (ok) measured_.store(static_cast<int64_t>(at), std::memory_order_relaxed);
    pingLast_ = "{\"state\":\"done\",\"ok\":" + std::string(ok ? "true" : "false") + ",\"frames\":" + std::to_string(at) +
                ",\"ms\":" + jnum(1000.0 * at / sr_) + ",\"confidence\":" + jnum(confidence) + "}";
    pingState_.store(0, std::memory_order_release);
    return pingLast_;
}

}  // namespace caw
