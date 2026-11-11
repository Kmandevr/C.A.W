// Audio clips: parsing "assets", "audio_clips" and "input", and the org.caw.audio-track player built-in.
#include "audio_clips.h"

#include <algorithm>
#include "caw/detmath.hpp"
#include <cmath>
#include <cstdio>

#include "asset_store.h"
#include "audio_input.h"
#include "builtin_sampler.h"
#include "handover.h"
#include "json.h"
#include "project.h"
#include "time_stretch.h"
#include "caw/instrument.hpp"

namespace caw {

namespace {

bool finiteIn(const Json& j, const char* key, double fallback, double lo, double hi, double& out) {
    const Json* v = j.get(key);
    if (!v || v->type == Json::Type::Null) {
        out = fallback;
        return true;
    }
    if (v->type != Json::Type::Number || !std::isfinite(v->num) || v->num < lo || v->num > hi) return false;
    out = v->num;
    return true;
}

bool curveOf(const std::string& s, FadeCurve& out) {
    if (s.empty() || s == "linear") out = FadeCurve::Linear;
    else if (s == "equal_power") out = FadeCurve::EqualPower;
    else if (s == "s_curve") out = FadeCurve::SCurve;
    else if (s == "fast") out = FadeCurve::Fast;
    else if (s == "slow") out = FadeCurve::Slow;
    else return false;
    return true;
}

std::string num(double v) {
    char b[40];
    std::snprintf(b, sizeof b, "%.17g", v);
    return b;
}

}  // namespace

std::string AudioTrackSpec::signature() const {
    std::string s = "in" + std::to_string(input.present) + "," + std::to_string(input.channel) + "," +
                    std::to_string(input.channels) + "," + std::to_string(input.monitor) + "," +
                    std::to_string(input.armed) + ";";
    for (const AudioClipSpec& c : clips) {
        s += c.id + "\x1f" + c.path + "\x1f" + num(c.startSteps) + "," + num(c.lengthSteps) + "," + num(c.offsetSeconds) +
             "," + num(c.gain) + "," + num(c.fadeInSeconds) + "," + num(c.fadeOutSeconds) + "," +
             std::to_string(static_cast<int>(c.fadeInCurve)) + std::to_string(static_cast<int>(c.fadeOutCurve)) +
             std::to_string(c.reverse) + std::to_string(c.loop) + "," + num(c.loopStartSeconds) + "," +
             num(c.loopEndSeconds) + "," + num(c.pitch) + std::to_string(c.musical) + std::to_string(c.varispeed) +
             "," + num(c.sourceBpm) + std::to_string(c.mute) + "\x1e";
    }
    return s;
}

bool parseAssetTable(const Json& root, std::map<std::string, AssetRef>& out, std::string& error) {
    const Json* a = root.get("assets");
    if (!a || a->type == Json::Type::Null) return true;
    if (a->type != Json::Type::Array) {
        error = "assets must be a list of {\"id\", \"path\", \"bpm\"}";
        return false;
    }
    for (const Json& j : a->arr) {
        if (j.type != Json::Type::Object) continue;
        const std::string id = j.string("id");
        AssetRef ref;
        ref.path = j.string("path");
        if (id.empty() || ref.path.empty()) {
            error = "every asset needs an \"id\" and a \"path\"";
            return false;
        }
        if (!finiteIn(j, "bpm", 0, 0, 1000, ref.bpm)) {
            error = "asset '" + id + "': bpm must be 0..1000";
            return false;
        }
        out[id] = ref;
    }
    return true;
}

bool parseAudioTrack(const Json& l, const std::map<std::string, AssetRef>& assets, const std::string& where,
                     double maxSteps, LayerSpec& spec, double& endSteps, std::string& error) {
    const Json* clips = l.get("audio_clips");
    const Json* input = l.get("input");
    const bool hasClips = clips && clips->type != Json::Type::Null;
    const bool hasInput = input && input->type != Json::Type::Null;
    if (!hasClips && !hasInput) return true;
    if (spec.folder) {
        error = where + ": a folder can't hold audio clips or an input";
        return false;
    }
    if (spec.hasInstrument) {
        error = where + " plays either an instrument or audio clips, not both";
        return false;
    }
    auto track = std::make_shared<AudioTrackSpec>();
    if (hasClips) {
        if (clips->type != Json::Type::Array || clips->arr.size() > static_cast<size_t>(kMaxAudioClipsPerTrack)) {
            error = where + ": audio_clips must be a list of at most " + std::to_string(kMaxAudioClipsPerTrack);
            return false;
        }
        for (const Json& j : clips->arr) {
            if (j.type != Json::Type::Object) continue;
            AudioClipSpec c;
            c.id = j.string("id");
            const std::string name = "audio clip '" + c.id + "' of " + where;
            c.path = j.string("path");
            double assetBpm = 0;
            if (const std::string asset = j.string("asset"); !asset.empty()) {
                auto it = assets.find(asset);
                if (it == assets.end()) {
                    error = name + " names an asset that isn't in \"assets\": '" + asset + "'";
                    return false;
                }
                c.path = it->second.path;
                assetBpm = it->second.bpm;
            }
            if (c.path.empty()) {
                error = name + " needs an \"asset\" or a \"path\"";
                return false;
            }
            std::string mode = j.string("mode", "fixed"), stretch = j.string("stretch", "wsola");
            if (mode != "fixed" && mode != "musical") {
                error = name + ": mode must be \"fixed\" or \"musical\"";
                return false;
            }
            if (stretch != "wsola" && stretch != "varispeed") {
                error = name + ": stretch must be \"wsola\" or \"varispeed\"";
                return false;
            }
            c.musical = mode == "musical";
            c.varispeed = stretch == "varispeed";
            const double hour = 24 * 3600.0;
            if (!finiteIn(j, "start_steps", 0, 0, maxSteps, c.startSteps) ||
                !finiteIn(j, "length_steps", 16, 1e-6, maxSteps, c.lengthSteps) || c.startSteps + c.lengthSteps > maxSteps) {
                error = name + ": start_steps and length_steps must be a song position (0 to " + num(maxSteps) +
                        " steps, the length above 0)";
                return false;
            }
            if (!finiteIn(j, "offset_seconds", 0, 0, hour, c.offsetSeconds) ||
                !finiteIn(j, "gain", 1, 0, kMaxMixGain, c.gain) ||
                !finiteIn(j, "fade_in_seconds", 0, 0, hour, c.fadeInSeconds) ||
                !finiteIn(j, "fade_out_seconds", 0, 0, hour, c.fadeOutSeconds) ||
                !finiteIn(j, "loop_start_seconds", 0, 0, hour, c.loopStartSeconds) ||
                !finiteIn(j, "loop_end_seconds", 0, 0, hour, c.loopEndSeconds) ||
                !finiteIn(j, "pitch", 0, -48, 48, c.pitch) ||
                !finiteIn(j, "source_bpm", assetBpm, 0, 1000, c.sourceBpm)) {
                error = name + ": offset, fades and loop points are seconds (0 or more), gain 0..3.98, pitch -48..48 "
                               "semitones, source_bpm 0..1000";
                return false;
            }
            if (!curveOf(j.string("fade_in_curve"), c.fadeInCurve) || !curveOf(j.string("fade_out_curve"), c.fadeOutCurve)) {
                error = name + ": a fade curve is linear, equal_power, s_curve, fast or slow";
                return false;
            }
            if (c.musical && !(c.sourceBpm > 0)) {
                error = name + " is musical, so it needs a source_bpm (or its asset's bpm)";
                return false;
            }
            if (c.loopEndSeconds > 0 && c.loopEndSeconds <= c.loopStartSeconds) {
                error = name + ": loop_end_seconds must be after loop_start_seconds";
                return false;
            }
            c.reverse = j.boolean("reverse", false);
            c.loop = j.boolean("loop", false);
            c.mute = j.boolean("mute", false);
            endSteps = std::max(endSteps, c.startSteps + c.lengthSteps);
            track->clips.push_back(std::move(c));
        }
        std::stable_sort(track->clips.begin(), track->clips.end(),
                         [](const AudioClipSpec& a, const AudioClipSpec& b) { return a.startSteps < b.startSteps; });
    }
    if (hasInput) {
        if (input->type != Json::Type::Object) {
            error = where + ": input must be {\"channel\", \"channels\", \"monitor\", \"armed\"}";
            return false;
        }
        TrackInputSpec& in = track->input;
        in.present = true;
        double ch = 0, chs = 1;
        if (!finiteIn(*input, "channel", 0, 0, kMaxInputChannels - 1, ch) || ch != std::floor(ch) ||
            !finiteIn(*input, "channels", 1, 1, 2, chs) || chs != std::floor(chs)) {
            error = where + ": input channel is 0.." + std::to_string(kMaxInputChannels - 1) + " and channels 1 or 2";
            return false;
        }
        in.channel = static_cast<int>(ch);
        in.channels = static_cast<int>(chs);
        const std::string m = input->string("monitor", "auto");
        if (m != "off" && m != "on" && m != "auto") {
            error = where + ": input monitor must be off, on or auto";
            return false;
        }
        in.monitor = m == "off" ? 0 : (m == "on" ? 1 : 2);
        in.armed = input->boolean("armed", false);
    }
    spec.hasInstrument = true;
    spec.instrument = ComponentSpec{};
    spec.instrument.id = kAudioTrackId;
    spec.instrument.audioTrack = std::move(track);
    return true;
}

// ---------------------------------------------------------------- the player

namespace {

// Clip voice declick: a voice cut by a seek, a loop wrap, stop, a mode change or an edit fades out over this while
// whatever replaces it fades in (a voice starting mid-clip; one starting at its clip's start is left as authored),
// and a clip's loop seam crossfades over it too (docs/decisions.md: the default is to confirm).
constexpr double kClipDeclickSeconds = 0.004;

struct CompiledClip {
    AudioClipSpec spec;
    std::shared_ptr<const AudioAsset> asset;
    ClipSource src;
    double offsetFrames = 0;
    double pitchRatio = 1;
    int64_t fadeIn = 0, fadeOut = 0;
};

struct Timeline {
    std::vector<CompiledClip> clips;
    TrackInputSpec input;
    uint64_t serial = 0, baseSerial = 0;
    std::vector<int> prevIndex;  // for each clip, its index in timeline baseSerial (-1: new)
    double maxLength = 0;        // the longest clip, in steps
};

double curve(FadeCurve c, double u) noexcept {
    u = u < 0 ? 0 : (u > 1 ? 1 : u);
    switch (c) {
        case FadeCurve::Linear: return u;
        case FadeCurve::EqualPower: return detSin(u * 1.5707963267948966);
        case FadeCurve::SCurve: return 0.5 - 0.5 * detCos(u * 3.14159265358979323846);
        case FadeCurve::Fast: return 1.0 - (1.0 - u) * (1.0 - u);
        case FadeCurve::Slow: return u * u;
    }
    return u;
}

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

const ModuleDescriptor& playerDescriptor() {
    static const ModuleDescriptor d = [] {
        ModuleDescriptor m;
        m.id = kAudioTrackId;
        m.name = "Audio track";
        m.role = ModuleRole::Instrument;
        m.ports = kPorts;
        m.portCount = 2;
        return m;
    }();
    return d;
}

class AudioTrackPlayer final : public ModuleProcessor, public LiveInputUser {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return playerDescriptor(); }
    bool usesProcessPorts() const noexcept override { return true; }
    bool activate(double sampleRate, uint32_t) noexcept override {
        sr_ = sampleRate;
        declick_ = std::max<int64_t>(1, std::llround(kClipDeclickSeconds * sampleRate));
        live_ = buildingLiveAudio();
        for (Voice& v : voices_)
            if (!v.reader.prepare(sampleRate)) return false;
        return true;
    }
    void reset() noexcept override {
        for (Voice& v : voices_) v.active = false;
        expected_ = -1;
    }
    bool monitoringStopped() const noexcept override { return monitorStopped_.load(std::memory_order_relaxed); }

    // Control thread.
    void setTrack(const AudioTrackSpec& spec, double rate, std::string* warnings) {
        std::string sig = spec.signature();
        if (sig == signature_ && rate == compiledRate_) return;
        auto t = std::make_unique<Timeline>();
        t->input = spec.input;
        t->serial = ++serial_;
        t->baseSerial = lastSerial_;
        for (const AudioClipSpec& c : spec.clips) {
            CompiledClip cc;
            cc.spec = c;
            std::string error;
            cc.asset = AssetStore::global().load(c.path, rate, error);
            if (!cc.asset && warnings) *warnings += "audio clip '" + c.id + "': " + error + "\n";
            cc.src.asset = cc.asset.get();
            cc.src.reverse = c.reverse;
            if (cc.asset) {
                const double frames = static_cast<double>(cc.asset->frames);
                cc.src.loop = c.loop;
                cc.src.loopStart = static_cast<int64_t>(std::llround(std::min(frames, c.loopStartSeconds * rate)));
                cc.src.loopEnd = c.loopEndSeconds > 0
                    ? static_cast<int64_t>(std::llround(std::min(frames, c.loopEndSeconds * rate)))
                    : static_cast<int64_t>(frames);
                if (cc.src.loopEnd <= cc.src.loopStart) cc.src.loop = false;
                cc.src.seam = std::llround(kClipDeclickSeconds * rate);
            }
            cc.offsetFrames = std::floor(c.offsetSeconds * rate + 0.5);
            cc.pitchRatio = detPow(2.0, c.pitch / 12.0);
            cc.fadeIn = static_cast<int64_t>(std::llround(c.fadeInSeconds * rate));
            cc.fadeOut = static_cast<int64_t>(std::llround(c.fadeOutSeconds * rate));
            t->maxLength = std::max(t->maxLength, c.lengthSteps);
            t->clips.push_back(std::move(cc));
        }
        // Clips that carry on (same id and the same sound) keep their voices across the update.
        t->prevIndex.assign(t->clips.size(), -1);
        for (size_t i = 0; i < t->clips.size(); ++i)
            for (size_t k = 0; k < lastClips_.size(); ++k)
                if (lastClips_[k].first == t->clips[i].spec.id && lastClips_[k].second == t->clips[i].asset.get()) {
                    t->prevIndex[i] = static_cast<int>(k);
                    break;
                }
        lastClips_.clear();
        for (const CompiledClip& c : t->clips) lastClips_.push_back({c.spec.id, c.asset.get()});
        lastSerial_ = t->serial;
        signature_ = std::move(sig);
        compiledRate_ = rate;
        monitorStopped_.store(t->input.present && t->input.monitor != 0 && (t->input.monitor == 1 || t->input.armed),
                              std::memory_order_relaxed);
        timeline_.offer(t.release());
    }

    bool processPorts(const ProcessBlock& b) noexcept override {
        if (b.frames == 0 || b.audioOutCount != 1 || !b.audioOut || b.audioOut[0].channelCount != 2 ||
            b.audioOut[0].frames < b.frames)
            return false;
        float* L = b.audioOut[0].channels[0];
        float* R = b.audioOut[0].channels[1];
        const int m = static_cast<int>(b.frames);
        if (m > 64) return false;
        std::fill_n(L, m, 0.0f);
        std::fill_n(R, m, 0.0f);
        const uint64_t was = timeline_.current() ? timeline_.current()->serial : 0;
        Timeline* previous = nullptr;
        if (!held_ && timeline_.take(previous)) {
            remap(was);
            // Voices fading out still read the old timeline's assets: it stays here until they are done.
            if (previous && (anyFading() || !timeline_.retire(previous))) held_ = previous;
        }
        const Timeline* tl = timeline_.current();
        const int64_t t0 = clock_;  // this block's first frame in the player's own, continuous time
        if (!tl) {
            clock_ += m;
            return true;
        }
        const bool playing = b.transport && b.transport->playing;
        // Monitoring: the device input through the track (on, or auto while armed and stopped or recording).
        const TrackInputSpec& in = tl->input;
        if (in.present && live_ && in.monitor != 0 &&
            (in.monitor == 1 || (in.armed && (!playing || live_->recordingNow())))) {
            for (int i = 0; i < m; ++i) {
                const float a = live_->input(in.channel, i);
                L[i] += a;
                R[i] += in.channels == 2 ? live_->input(in.channel + 1, i) : a;
            }
        }
        if (!playing) {
            for (Voice& v : voices_) fadeOut(v);
            expected_ = -1;
            finish(t0, m, L, R);
            return true;
        }
        const double tempo = b.transport->tempo > 0 ? b.transport->tempo : 120.0;
        const double stepLen = 60.0 * sr_ / (tempo * 4.0);
        const int64_t pos = std::llround(b.transport->beat * 4.0 * stepLen);
        if (pos != expected_) {
            for (Voice& v : voices_) fadeOut(v);  // a seek or a loop wrap: every voice starts again
        } else if (tempo != lastTempo_) {
            // A tempo change: musical clips follow the new grid (they start again, declicked); fixed clips keep
            // the source position they are at (their voice's mapping moves by what the clip's start moved).
            for (Voice& v : voices_) {
                if (!v.active || v.clip < 0) continue;
                const CompiledClip& c = tl->clips[static_cast<size_t>(v.clip)];
                if (c.spec.musical) {
                    fadeOut(v);
                    continue;
                }
                const int64_t cs = static_cast<int64_t>(std::floor(c.spec.startSteps * stepLen + 0.5));
                const double here = v.anchorS + v.slope * static_cast<double>(t0 - v.anchorT);
                v.drift = here - (c.offsetFrames + v.slope * static_cast<double>(pos - cs));
            }
        }
        if (expected_ < 0 && !anyActive()) clock_ = pos;  // a fresh start: the player's time is the song's
        const int64_t shift = clock_ - pos;
        expected_ = pos + m;
        lastTempo_ = tempo;
        const int64_t end = pos + m;
        // Clips are sorted by start, and none is longer than maxLength: the first that can reach pos.
        const double from = static_cast<double>(pos) / stepLen - tl->maxLength - 1.0;
        const size_t first = static_cast<size_t>(
            std::partition_point(tl->clips.begin(), tl->clips.end(),
                                 [&](const CompiledClip& c) { return c.spec.startSteps < from; }) - tl->clips.begin());
        for (Voice& v : voices_) v.seen = false;
        for (size_t ci = first; ci < tl->clips.size(); ++ci) {
            const CompiledClip& c = tl->clips[ci];
            const int64_t cs = static_cast<int64_t>(std::floor(c.spec.startSteps * stepLen + 0.5));
            if (cs >= end) break;  // sorted by start
            const int64_t ce = static_cast<int64_t>(std::floor((c.spec.startSteps + c.spec.lengthSteps) * stepLen + 0.5));
            if (ce <= pos) continue;
            Voice* v = voiceFor(static_cast<int>(ci));
            if (v) v->seen = true;
            if (c.spec.mute || !c.asset) {
                if (v) fadeOut(*v);
                continue;
            }
            // How fast the source moves and which reader plays it.
            const double slope = c.spec.musical ? tempo / c.spec.sourceBpm : (c.spec.varispeed ? c.pitchRatio : 1.0);
            ReadMode mode;
            double pitch = 1;
            if (c.spec.varispeed) {
                mode = slope == 1.0 ? ReadMode::Direct : ReadMode::Varispeed;
            } else {
                pitch = c.pitchRatio;
                mode = slope == 1.0 && pitch == 1.0 ? ReadMode::Direct : ReadMode::Stretch;
            }
            const int64_t a = std::max(pos, cs), z = std::min(end, ce);
            if (v && (v->reader.mode() != mode || v->reader.pitch() != pitch)) {
                fadeOut(*v);
                v = nullptr;
            }
            if (!v) {
                if (playingVoices() >= kAudioClipVoices) continue;  // more clips at once than that: this one is skipped
                v = freeVoice();
                if (!v) continue;
                v->active = v->seen = true;
                v->clip = static_cast<int>(ci);
                v->drift = 0;
                v->fadeLeft = 0;
                v->inAt = 0;
                v->inLen = a > cs ? declick_ : 0;  // started mid-clip: faded in
                v->reader.start(c.src, mode, pitch, a + shift, c.offsetFrames + slope * static_cast<double>(a - cs), slope);
            }
            v->anchorT = cs + shift;
            v->anchorS = c.offsetFrames + v->drift;
            v->slope = slope;
            v->reader.setSource(c.src);
            v->reader.setMapping(v->anchorT, v->anchorS, v->slope);
            const float g = static_cast<float>(c.spec.gain);
            for (int64_t t = a; t < z; ++t) {
                double w = g;
                if (c.fadeIn > 0 && t - cs < c.fadeIn)
                    w *= curve(c.spec.fadeInCurve, static_cast<double>(t - cs) / static_cast<double>(c.fadeIn));
                if (c.fadeOut > 0 && ce - t <= c.fadeOut)
                    w *= curve(c.spec.fadeOutCurve, static_cast<double>(ce - t) / static_cast<double>(c.fadeOut));
                if (v->inAt < v->inLen) {
                    w *= static_cast<double>(v->inAt + 1) / static_cast<double>(v->inLen + 1);
                    ++v->inAt;
                }
                gain_[t - pos] = static_cast<float>(w);
            }
            if (z > a) v->lastGain = gain_[z - 1 - pos];
            v->reader.render(a + shift, static_cast<int>(z - a), gain_ + (a - pos), L + (a - pos), R + (a - pos));
            if (z >= ce) v->active = false;  // the clip ended in this block (its own fade-out shapes that)
        }
        // Voices whose clip is gone from under the playhead.
        for (Voice& v : voices_)
            if (!v.seen && v.clip >= 0) fadeOut(v);
        finish(t0, m, L, R);
        return true;
    }

    ~AudioTrackPlayer() override { delete held_; }

private:
    struct Voice {
        bool active = false, seen = false;
        int clip = -1;               // -1: fading out, no longer any clip's
        int64_t fadeLeft = 0;        // fading out: frames left
        float fadeFrom = 0;          // the gain the fade out starts from
        float lastGain = 0;          // the gain of the last frame played
        int64_t inAt = 0, inLen = 0; // the fade in of a voice started mid-clip
        int64_t anchorT = 0;         // the reader's mapping, in the player's time
        double anchorS = 0, slope = 1;
        double drift = 0;            // source frames added to a fixed clip's mapping since a tempo change
        ClipReader reader;
    };
    // Fades a sounding voice out over the declick (it keeps reading where it was) instead of cutting it.
    void fadeOut(Voice& v) noexcept {
        if (!v.active || v.clip < 0) return;
        v.clip = -1;
        if (v.lastGain == 0.0f) {
            v.active = false;
            return;
        }
        v.fadeLeft = declick_;
        v.fadeFrom = v.lastGain;
    }
    // The fading voices' last frames, and the player's time moves on.
    void finish(int64_t t0, int m, float* L, float* R) noexcept {
        for (Voice& v : voices_) {
            if (!v.active || v.clip >= 0) continue;
            const int n = static_cast<int>(std::min<int64_t>(m, v.fadeLeft));
            for (int i = 0; i < n; ++i)
                gain_[i] = v.fadeFrom * static_cast<float>(v.fadeLeft - i) / static_cast<float>(declick_ + 1);
            v.reader.render(t0, n, gain_, L, R);
            v.fadeLeft -= n;
            if (v.fadeLeft <= 0) v.active = false;
        }
        if (held_ && !anyFading() && timeline_.retire(held_)) held_ = nullptr;
        clock_ += m;
    }
    bool anyFading() const noexcept {
        for (const Voice& v : voices_)
            if (v.active && v.clip < 0) return true;
        return false;
    }
    bool anyActive() const noexcept {
        for (const Voice& v : voices_)
            if (v.active) return true;
        return false;
    }
    int playingVoices() const noexcept {
        int n = 0;
        for (const Voice& v : voices_) n += v.active && v.clip >= 0;
        return n;
    }
    Voice* voiceFor(int clip) noexcept {
        for (Voice& v : voices_)
            if (v.active && v.clip == clip) return &v;
        return nullptr;
    }
    // A free voice, else the fading one closest to silence (cut).
    Voice* freeVoice() noexcept {
        Voice* best = nullptr;
        for (Voice& v : voices_) {
            if (!v.active) return &v;
            if (v.clip < 0 && (!best || v.fadeLeft < best->fadeLeft)) best = &v;
        }
        if (best) best->active = false;
        return best;
    }
    void remap(uint64_t was) noexcept {
        const Timeline* t = timeline_.current();
        if (!t || t->baseSerial != was) {
            for (Voice& v : voices_) fadeOut(v);
            return;
        }
        for (Voice& v : voices_) {
            if (!v.active || v.clip < 0) continue;
            int found = -1;
            for (size_t i = 0; i < t->prevIndex.size() && found < 0; ++i)
                if (t->prevIndex[i] == v.clip) found = static_cast<int>(i);
            if (found < 0) fadeOut(v);
            else v.clip = found;
        }
    }

    double sr_ = 48000;
    LiveAudio* live_ = nullptr;
    Voice voices_[2 * kAudioClipVoices];  // the playing ones, and room for as many fading out
    float gain_[64] = {};
    int64_t expected_ = -1;
    int64_t clock_ = 0;      // the player's own time: one frame per frame rendered, whatever the transport does
    int64_t declick_ = 192;  // frames
    double lastTempo_ = 0;
    Handover<Timeline> timeline_;
    Timeline* held_ = nullptr;  // a replaced timeline whose assets fading voices still read
    std::atomic<bool> monitorStopped_{false};
    // control thread
    std::string signature_;
    double compiledRate_ = 0;
    uint64_t serial_ = 0, lastSerial_ = 0;
    std::vector<std::pair<std::string, const AudioAsset*>> lastClips_;
};

ModuleProcessor* makePlayer() noexcept { return new (std::nothrow) AudioTrackPlayer(); }

}  // namespace

void applyAudioTrack(ModuleProcessor& processor, const ComponentSpec& spec, double sampleRate, std::string* warnings) {
    auto* p = dynamic_cast<AudioTrackPlayer*>(&processor);
    if (!p) return;
    static const AudioTrackSpec empty;
    p->setTrack(spec.audioTrack ? *spec.audioTrack : empty, sampleRate, warnings);
}

void applyComponentHostData(ModuleProcessor& processor, const ComponentSpec& spec, double sampleRate) {
    try {
        applyAudioTrack(processor, spec, sampleRate);
        applySamplerProjectState(processor, spec);
    } catch (...) {  // out of memory: the component keeps what it had
    }
}

bool monitorsStopped(const ModuleProcessor& processor) noexcept {
    const auto* p = dynamic_cast<const LiveInputUser*>(&processor);
    return p && p->monitoringStopped();
}

// Internal: never listed among the instruments (a layer becomes an audio track through "audio_clips"/"input").
void registerAudioTrack(ModuleRegistry& registry) { registry.addInternal(playerDescriptor(), &makePlayer); }

}  // namespace caw
