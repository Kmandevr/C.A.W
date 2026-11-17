// The sample browser's preview voice (API 33): prepared and stretched on a control thread, played lock-free on the audio thread.
#include "sample_preview.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <new>

#include "clip_stretch.h"
#include "json.h"
#include "time_stretch.h"

namespace caw {

namespace {

bool numberIn(const Json& j, const char* key, double lo, double hi, double& out, std::string& error) {
    const Json* v = j.type == Json::Type::Object ? j.get(key) : nullptr;
    if (!v || v->type == Json::Type::Null) return true;
    if (v->type != Json::Type::Number || !std::isfinite(v->num) || v->num < lo || v->num > hi) {
        char b[160];
        std::snprintf(b, sizeof b, "%s must be a number %g..%g", key, lo, hi);
        error = b;
        return false;
    }
    out = v->num;
    return true;
}

}  // namespace

bool parsePreviewOptions(const char* json, PreviewOptions& o, std::string& error) {
    if (!json || !*json) return true;
    const size_t n = std::strlen(json);
    if (n > 4096) {
        error = "options are longer than 4096 bytes";
        return false;
    }
    Json j;
    if (!parseJson(std::string_view(json, n), j, error)) {
        error = "options: " + error;
        return false;
    }
    if (j.type == Json::Type::Null) return true;
    if (j.type != Json::Type::Object) {
        error = "options must be an object";
        return false;
    }
    if (!numberIn(j, "start_seconds", 0, 3.0 * 3600.0, o.startSeconds, error) ||
        !numberIn(j, "stretch_ratio", kPreviewMinRatio, kPreviewMaxRatio, o.ratio, error) ||
        !numberIn(j, "volume", 0, 1, o.volume, error))
        return false;
    if (const Json* s = j.get("sync"); s && s->type != Json::Type::Null) {
        if (s->type != Json::Type::String || (s->str != "now" && s->str != "beat" && s->str != "bar")) {
            error = "sync must be \"now\", \"beat\" or \"bar\"";
            return false;
        }
        o.sync = s->str == "beat" ? 1 : s->str == "bar" ? 2 : 0;
    }
    if (const Json* l = j.get("loop"); l && l->type != Json::Type::Null) {
        if (l->type != Json::Type::Bool) {
            error = "loop must be true or false";
            return false;
        }
        o.loop = l->b;
    }
    return true;
}

SamplePreview::SamplePreview(double sampleRate) : sr_(sampleRate > 0 ? sampleRate : 48000.0) {}

SamplePreview::~SamplePreview() = default;

void SamplePreview::prune() {
    const uint64_t done = consumed_.load(std::memory_order_acquire);
    const PreviewSound* a = inUse_[0].load(std::memory_order_acquire);
    const PreviewSound* b = inUse_[1].load(std::memory_order_acquire);
    held_.erase(std::remove_if(held_.begin(), held_.end(),
                               [&](const std::shared_ptr<PreviewSound>& s) {
                                   return s->seq <= done && s.get() != a && s.get() != b;
                               }),
                held_.end());
}

bool SamplePreview::post(const Cmd& c) { return queue_.push(c); }

bool SamplePreview::start(std::shared_ptr<const AudioAsset> asset, const PreviewOptions& o, std::string& error,
                          double* effectiveRatio) {
    if (!asset || asset->frames <= 0) {
        error = "the file has no audio";
        return false;
    }
    auto sound = std::make_shared<PreviewSound>();
    sound->asset = asset;
    sound->loop = o.loop;
    double ratio = std::clamp(o.ratio, kPreviewMinRatio, kPreviewMaxRatio);
    if (std::fabs(ratio - 1.0) < 1e-6 || asset->seconds() > kPreviewStretchSeconds) ratio = 1.0;
    sound->ratio = ratio;
    if (ratio == 1.0) {
        sound->frames = asset->frames;
    } else {
        // The clip voice's own Signalsmith path, rendered once here: the preview sounds as the clip will.
        const int64_t out = static_cast<int64_t>(std::ceil(static_cast<double>(asset->frames) * ratio));
        sound->l.assign(static_cast<size_t>(out), 0.0f);
        sound->r.assign(static_cast<size_t>(out), 0.0f);
        auto reader = std::make_unique<ClipReader>();
        auto hq = std::make_unique<HqStretcher>();
        if (!reader->prepare(asset->rate) || !hq->prepare(asset->rate)) {
            error = "out of memory";
            return false;
        }
        ClipSource src;
        src.asset = asset.get();
        reader->start(src, ReadMode::Hq, 1.0, 0, 0.0, 1.0 / ratio, hq.get(), 0, 0);
        constexpr int kChunk = 256;
        float ones[kChunk];
        std::fill_n(ones, kChunk, 1.0f);
        for (int64_t t = 0; t < out; t += kChunk) {
            const int n = static_cast<int>(std::min<int64_t>(kChunk, out - t));
            reader->render(t, n, ones, sound->l.data() + t, sound->r.data() + t);
        }
        for (size_t i = 0; i < sound->l.size(); ++i) {  // sanitised: a preview never carries NaN or Inf
            if (!std::isfinite(sound->l[i])) sound->l[i] = 0.0f;
            if (!std::isfinite(sound->r[i])) sound->r[i] = 0.0f;
        }
        sound->frames = out;
    }
    if (effectiveRatio) *effectiveRatio = ratio;
    if (o.volume >= 0) setVolume(o.volume);
    std::lock_guard<std::mutex> g(lock_);
    prune();
    sound->seq = ++seq_;
    sound->start = starts_ + 1;
    Cmd c;
    c.type = Cmd::Start;
    c.sound = sound.get();
    c.seq = sound->seq;
    c.wait = o.sync;
    c.frame = static_cast<int64_t>(std::floor(std::clamp(o.startSeconds * asset->rate * ratio, 0.0,
                                                         static_cast<double>(sound->frames))));
    held_.push_back(sound);
    if (!post(c)) {
        held_.pop_back();
        --seq_;
        error = "the preview is busy: try again";
        return false;
    }
    ++starts_;
    lastPosted_ = sound.get();
    lastLength_ = asset->seconds();
    lastRatio_ = ratio;
    return true;
}

void SamplePreview::stop() {
    std::lock_guard<std::mutex> g(lock_);
    prune();
    Cmd c;
    c.type = Cmd::Stop;
    c.seq = ++seq_;
    if (!post(c)) --seq_;
}

void SamplePreview::seek(double sourceSeconds) {
    if (!std::isfinite(sourceSeconds)) return;
    std::lock_guard<std::mutex> g(lock_);
    if (!lastPosted_) return;
    prune();
    Cmd c;
    c.type = Cmd::Seek;
    c.seq = ++seq_;
    c.frame = static_cast<int64_t>(std::floor(std::clamp(sourceSeconds, 0.0, lastLength_) * sr_ * lastRatio_));
    if (!post(c)) --seq_;
}

void SamplePreview::setVolume(double volume) noexcept {
    volume_.store(static_cast<float>(std::isfinite(volume) ? std::clamp(volume, 0.0, 1.0) : 0.8),
                  std::memory_order_relaxed);
}

SamplePreview::State SamplePreview::state() const noexcept {
    State s;
    const int f = flags_.load(std::memory_order_acquire);
    s.playing = (f & 1) != 0;
    s.waiting = (f & 2) != 0;
    s.seconds = posSeconds_.load(std::memory_order_relaxed);
    s.length = lengthSeconds_.load(std::memory_order_relaxed);
    s.seq = playingSeq_.load(std::memory_order_relaxed);
    return s;
}

void SamplePreview::take(const SongClock& clock) noexcept {
    gainTarget_ = volume_.load(std::memory_order_relaxed);
    Cmd c;
    bool any = false;
    uint64_t last = 0;
    while (queue_.pop(c)) {
        any = true;
        last = c.seq;
        switch (c.type) {
            case Cmd::Start: {
                if (cur_.sound && cur_.wait == 0) old_ = {cur_.sound, cur_.pos, 0, kFade};
                const int64_t wait = c.wait == 1 ? clock.toBeat : c.wait == 2 ? clock.toBar : 0;
                cur_ = {c.sound, std::min(c.frame, c.sound->frames), wait > 0 ? wait : 0, 0};
                break;
            }
            case Cmd::Stop:
                if (cur_.sound && cur_.wait == 0) old_ = {cur_.sound, cur_.pos, 0, kFade};
                cur_ = {};
                break;
            case Cmd::Seek:
                if (cur_.sound) {
                    if (cur_.wait == 0) old_ = {cur_.sound, cur_.pos, 0, kFade};
                    cur_.pos = std::min(c.frame, cur_.sound->frames);
                    cur_.ramp = 0;
                }
                break;
        }
    }
    if (any) {
        inUse_[0].store(cur_.sound, std::memory_order_release);
        inUse_[1].store(old_.sound, std::memory_order_release);
        consumed_.store(last, std::memory_order_release);
    }
}

void SamplePreview::next(double& left, double& right) noexcept {
    gain_ += (gainTarget_ - gain_) * 0.002;
    if (cur_.sound) {
        if (cur_.wait > 0) {
            --cur_.wait;
        } else {
            float a, b;
            cur_.sound->frame(cur_.pos, a, b);
            double g = gain_;
            if (cur_.ramp < kFade) g *= (cur_.ramp++ + 1.0) / kFade;
            left += a * g;
            right += b * g;
            if (++cur_.pos >= cur_.sound->frames) {
                if (cur_.sound->loop) cur_.pos = 0;
                else cur_.sound = nullptr;
            }
        }
    }
    if (old_.sound) {
        if (old_.ramp > 0 && old_.pos < old_.sound->frames) {
            float a, b;
            old_.sound->frame(old_.pos++, a, b);
            const double g = gain_ * (old_.ramp-- - 0.5) / kFade;
            left += a * g;
            right += b * g;
        } else {
            old_.sound = nullptr;
        }
    }
}

void SamplePreview::publish() noexcept {
    const PreviewSound* s = cur_.sound;
    flags_.store(s ? (cur_.wait > 0 ? 3 : 1) : 0, std::memory_order_release);
    if (s) {
        const double perSecond = sr_ * s->ratio;
        posSeconds_.store(static_cast<double>(cur_.pos) / perSecond, std::memory_order_relaxed);
        lengthSeconds_.store(static_cast<double>(s->frames) / perSecond, std::memory_order_relaxed);
        playingSeq_.store(s->start, std::memory_order_relaxed);
    }
}

}  // namespace caw
