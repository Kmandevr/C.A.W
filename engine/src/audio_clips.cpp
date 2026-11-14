// Audio clips: parsing "assets", "audio_clips" and "input", and the org.caw.audio-track player built-in.
#include "audio_clips.h"

#include <algorithm>
#include "caw/detmath.hpp"
#include <cmath>
#include <cstdio>

#include "asset_store.h"
#include "audio_input.h"
#include "builtin_sampler.h"
#include "clip_stretch.h"
#include "handover.h"
#include "json.h"
#include "project.h"
#include "sample_time.h"
#include "tempo_map.h"
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
             "," + num(c.sourceBpm) + std::to_string(c.mute);
        // API 32's fields, only when set (a clip without them describes itself as before).
        if (c.loopStartFrames >= 0 || c.loopEndFrames >= 0 || c.pitchCents != 0 || c.stretchRatio != 1 || c.hq)
            s += "," + std::to_string(c.loopStartFrames) + "," + std::to_string(c.loopEndFrames) + "," +
                 num(c.pitchCents) + "," + num(c.stretchRatio) + std::to_string(c.hq);
        s += "\x1e";
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
            const Json* modeJ = j.get("mode");
            const Json* stretchJ = j.get("stretch");
            const Json* followsJ = j.get("follows_tempo");
            if ((modeJ && modeJ->type != Json::Type::Null && modeJ->type != Json::Type::String) ||
                (stretchJ && stretchJ->type != Json::Type::Null && stretchJ->type != Json::Type::String) ||
                (followsJ && followsJ->type != Json::Type::Null && followsJ->type != Json::Type::Bool)) {
                error = name + ": mode and stretch are names, follows_tempo true or false";
                return false;
            }
            std::string mode = j.string("mode", "fixed"), stretch = j.string("stretch", "wsola");
            if (mode != "fixed" && mode != "musical") {
                error = name + ": mode must be \"fixed\" or \"musical\"";
                return false;
            }
            if (stretch != "wsola" && stretch != "varispeed" && stretch != "signalsmith") {
                error = name + ": stretch must be \"wsola\", \"varispeed\" or \"signalsmith\"";
                return false;
            }
            const bool follows = followsJ && followsJ->type == Json::Type::Bool && followsJ->b;
            if (follows && modeJ && modeJ->type == Json::Type::String && mode == "fixed") {
                error = name + ": follows_tempo and mode \"fixed\" disagree (give one)";
                return false;
            }
            c.musical = mode == "musical" || follows;
            c.varispeed = stretch == "varispeed";
            c.hq = stretch == "signalsmith";
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
            double gainDb = 0;
            if (!finiteIn(j, "stretch_ratio", 1, 0.25, 4, c.stretchRatio) ||
                !finiteIn(j, "pitch_cents", 0, -2400, 2400, c.pitchCents) ||
                !finiteIn(j, "gain_db", 0, -96, 36, gainDb) || std::fabs(c.pitch + c.pitchCents / 100.0) > 48) {
                error = name + ": stretch_ratio is 0.25..4, pitch_cents -2400..2400 (pitch plus cents within 48 "
                               "semitones), gain_db -96..36";
                return false;
            }
            if (gainDb != 0) c.gain *= detPow(10.0, gainDb / 20.0);
            for (auto [key, out] : {std::pair<const char*, int64_t*>{"loop_start_frames", &c.loopStartFrames},
                                    std::pair<const char*, int64_t*>{"loop_end_frames", &c.loopEndFrames}}) {
                double v = -1;
                if (!finiteIn(j, key, -1, 0, 1099511627776.0, v) || (v >= 0 && v != std::floor(v))) {
                    error = name + ": " + key + " is a whole frame count 0..2^40";
                    return false;
                }
                *out = static_cast<int64_t>(v);
            }
            if (c.loopEndFrames > 0 && c.loopStartFrames >= 0 && c.loopEndFrames <= c.loopStartFrames) {
                error = name + ": loop_end_frames must be after loop_start_frames";
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
    // Signalsmith stretchers for this timeline's clips (made or kept on the control thread; the audio thread only uses
    // them). Those a newer timeline doesn't keep are freed with this one, on the control thread.
    std::vector<std::shared_ptr<HqStretcher>> pool;
    int hqLatency = 0;           // the stretchers' output latency (the pre-roll), 0 with none
};

// Signalsmith voices one track plays at once; more play WSOLA (each costs about 1.1% of a desktop core; the phone's
// figure is to measure). [Assumption] 8 covers a track's overlapping loops and one-shots.
constexpr int kMaxHqVoices = 8;

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
                // Loop points in the file's own frames (API 32), at the engine's rate.
                const double toRate = cc.asset->sourceRate > 0 ? rate / cc.asset->sourceRate : 1.0;
                if (c.loopStartFrames >= 0)
                    cc.src.loopStart = static_cast<int64_t>(
                        std::llround(std::min(frames, static_cast<double>(c.loopStartFrames) * toRate)));
                if (c.loopEndFrames >= 0)
                    cc.src.loopEnd = c.loopEndFrames > 0
                        ? static_cast<int64_t>(std::llround(std::min(frames, static_cast<double>(c.loopEndFrames) * toRate)))
                        : static_cast<int64_t>(frames);
                if (cc.src.loopEnd <= cc.src.loopStart) cc.src.loop = false;
                cc.src.seam = std::llround(kClipDeclickSeconds * rate);
            }
            cc.offsetFrames = sampletime::roundFrames(c.offsetSeconds, rate);
            cc.pitchRatio = detPow(2.0, (c.pitch + c.pitchCents / 100.0) / 12.0);
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
        buildPool(*t, rate);
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
        const double stepLen = sampletime::stepFrames(sr_, tempo);
        // With a tempo map of more than one tempo (1.0.3), clip positions come from the map; with one tempo, from the
        // transport's tempo, as before the map. A musical clip follows the map chunk by chunk (API 32, below); a
        // fixed one plays at the file's speed (over its stretch_ratio).
        const SongTime* song = live_ ? live_->songTime() : nullptr;
        const TempoMap* tm = song && !song->tempo.constant() ? &song->tempo : nullptr;
        auto frameOf = [&](double step) {
            return static_cast<int64_t>(tm ? tm->roundFrame(step) : sampletime::roundFrames(step, stepLen));
        };
        const int64_t pos = tm ? std::llround(tm->frameAt(b.transport->beat * 4.0)) : std::llround(b.transport->beat * 4.0 * stepLen);
        const uint64_t serial = tm ? song->serial : 0;
        const bool retimed = tm || lastMapped_ ? serial != lastSongSerial_ : tempo != lastTempo_;
        if (pos != expected_) {
            // A seek or a loop wrap: every voice starts again, except the spares pre-rolled for exactly this wrap,
            // which take over (their clips need no bridge).
            const bool wrapped = expected_ >= 0 && spareLands_ >= 0 && std::llabs(pos - spareLands_) <= 1;
            for (Voice& v : voices_) {
                if (v.spare && v.active && wrapped) {
                    v.spare = false;
                    v.inAt = 0;
                    v.inLen = v.spareMidClip ? declick_ : 0;
                    continue;
                }
                if (v.spare) v.active = false;
                else fadeOut(v);
            }
        } else if (retimed) {
            // A tempo change: musical clips follow the new grid (they start again, declicked); fixed clips keep
            // the source position they are at (their voice's mapping moves by what the clip's start moved).
            for (Voice& v : voices_) {
                if (!v.active || v.clip < 0) continue;
                if (v.spare) {
                    v.active = false;
                    continue;
                }
                const CompiledClip& c = tl->clips[static_cast<size_t>(v.clip)];
                if (c.spec.musical) {
                    fadeOut(v);
                    continue;
                }
                const int64_t cs = frameOf(c.spec.startSteps);
                const double here = v.anchorS + v.slope * static_cast<double>(t0 - v.anchorT);
                v.drift = here - (c.offsetFrames + v.slope * static_cast<double>(pos - cs));
            }
        }
        spareLands_ = -1;
        if (expected_ < 0 && !anyActive()) clock_ = pos;  // a fresh start: the player's time is the song's
        const int64_t shift = clock_ - pos;
        expected_ = pos + m;
        lastTempo_ = tempo;
        lastSongSerial_ = serial;
        lastMapped_ = tm != nullptr;
        const int64_t end = pos + m;
        Ctx ctx{tl, tm, tempo, stepLen};
        // Clips are sorted by start, and none is longer than maxLength: the first that can reach pos.
        const size_t first = firstClip(ctx, pos);
        for (Voice& v : voices_) v.seen = false;
        // Signalsmith voices start this many frames before their clip, silent, so their output is good when heard.
        const int64_t preroll = tl->hqLatency;
        for (size_t ci = first; ci < tl->clips.size(); ++ci) {
            const CompiledClip& c = tl->clips[ci];
            const int64_t cs = frameOf(c.spec.startSteps);
            if (cs >= end + preroll) break;  // sorted by start
            const bool hqClip = c.spec.hq && preroll > 0;
            const int64_t as = hqClip ? cs - preroll : cs;  // where its voice starts
            if (as >= end) continue;
            const int64_t ce = frameOf(c.spec.startSteps + c.spec.lengthSteps);
            if (ce <= pos) continue;
            Voice* v = voiceFor(static_cast<int>(ci));
            if (v) v->seen = true;
            if (c.spec.mute || !c.asset) {
                if (v) fadeOut(*v);
                continue;
            }
            const Plan pl = plan(ctx, c, pos);
            const int64_t lead = pl.mode == ReadMode::Hq ? as : cs;
            const int64_t a = std::max(pos, lead), z = std::min(end, ce);
            if (a >= z) continue;  // a Direct clip not reached yet
            if (v && (v->want != pl.mode || v->reader.pitch() != pl.pitch)) {
                fadeOut(*v);
                v = nullptr;
            }
            if (!v) {
                if (playingVoices() >= kAudioClipVoices) continue;  // more clips at once than that: this one is skipped
                v = freeVoice();
                if (!v) continue;
                startVoice(*v, ctx, static_cast<int>(ci), pl, a, shift, std::max(a, cs));
                v->inLen = a > cs ? declick_ : 0;  // started mid-clip: faded in
            }
            follow(*v, ctx, c, pl, shift, a + shift);
            const float g = static_cast<float>(c.spec.gain);
            for (int64_t t = a; t < z; ++t) {
                if (t < cs) {  // a Signalsmith voice's pre-roll: silent
                    gain_[t - pos] = 0.0f;
                    continue;
                }
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
            v->lastGain = gain_[z - 1 - pos];
            v->reader.render(a + shift, static_cast<int>(z - a), gain_ + (a - pos), L + (a - pos), R + (a - pos));
            if (z >= ce) v->active = false;  // the clip ended in this block (its own fade-out shapes that)
        }
        prerollWrap(ctx, pos, end, shift, preroll);
        // Voices whose clip is gone from under the playhead.
        for (Voice& v : voices_)
            if (!v.seen && v.clip >= 0 && !v.spare) fadeOut(v);
        finish(t0, m, L, R);
        return true;
    }

    ~AudioTrackPlayer() override { delete held_; }

    AudioTrackStats stats() const noexcept {
        AudioTrackStats st;
        for (const Voice& v : voices_) {
            if (!v.active) continue;
            ++st.voices;
            st.spares += v.spare;
            if (v.reader.mode() == ReadMode::Hq) ++st.hqVoices;
            else if (v.reader.mode() == ReadMode::Stretch) ++st.wsolaVoices;
        }
        if (const Timeline* t = timeline_.current()) {
            st.stretchers = static_cast<int>(t->pool.size());
            st.stretcherRate = t->pool.empty() ? 0 : t->pool.front()->sampleRate();
        }
        return st;
    }

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
        ReadMode want = ReadMode::Direct;  // the mode the clip asked for (Hq may play as Stretch without a stretcher)
        bool spare = false;          // pre-rolled, silent, for its clip at the loop's start after a wrap
        bool spareMidClip = false;   // that clip is already sounding where the loop lands (fade in when adopted)
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
            if (v.active && !v.spare && v.clip == clip) return &v;
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
    // ---- the voices' plans (audio thread)
    struct Ctx {
        const Timeline* tl;
        const TempoMap* tm;  // a map of more than one tempo, else null
        double tempo, stepLen;
        int64_t frameOfStep(double step) const noexcept {
            return static_cast<int64_t>(tm ? tm->roundFrame(step) : sampletime::roundFrames(step, stepLen));
        }
    };
    struct Plan {
        ReadMode mode = ReadMode::Direct;
        double pitch = 1, anchorT = 0, anchorS = 0, slope = 1;
        bool follows = false;
        double fps = 0;  // source frames per step (following a map)
    };
    size_t firstClip(const Ctx& x, int64_t at) const noexcept {
        const double from = (x.tm ? x.tm->stepAt(static_cast<double>(at)) : static_cast<double>(at) / x.stepLen) -
                            x.tl->maxLength - 1.0;
        return static_cast<size_t>(std::partition_point(x.tl->clips.begin(), x.tl->clips.end(),
                                                        [&](const CompiledClip& c) { return c.spec.startSteps < from; }) -
                                   x.tl->clips.begin());
    }
    // How fast the source moves at song frame `at`: s(f) = anchorS + slope * (f - anchorT). A clip following the
    // tempo under a map of more than one tempo (API 32) is placed by song step (offset + (step - start) source frames
    // per step at source_bpm), read through the map at each frame (ClipReader::SongMap); otherwise as before the map
    // (fixed: the file's speed over stretch_ratio).
    Plan plan(const Ctx& x, const CompiledClip& c, int64_t at) const noexcept {
        Plan p;
        p.follows = c.spec.musical && x.tm;
        p.anchorT = static_cast<double>(x.frameOfStep(c.spec.startSteps));
        p.anchorS = c.offsetFrames;
        if (p.follows) {
            p.fps = 15.0 * sr_ / c.spec.sourceBpm;
            p.anchorT = static_cast<double>(at);
            p.anchorS = c.offsetFrames + (x.tm->stepAt(static_cast<double>(at)) - c.spec.startSteps) * p.fps;
            p.slope = x.tm->bpmAtFrame(static_cast<double>(at)) / c.spec.sourceBpm;
        } else if (c.spec.musical) {
            p.slope = x.tempo / c.spec.sourceBpm;
        } else {
            p.slope = (c.spec.varispeed ? c.pitchRatio : 1.0) / c.spec.stretchRatio;
        }
        if (c.spec.varispeed) {
            p.mode = p.slope == 1.0 && !p.follows ? ReadMode::Direct : ReadMode::Varispeed;
        } else {
            p.pitch = c.pitchRatio;
            const bool direct = p.slope == 1.0 && p.pitch == 1.0 && !p.follows;
            p.mode = direct ? ReadMode::Direct : (c.spec.hq ? ReadMode::Hq : ReadMode::Stretch);
        }
        return p;
    }
    void songMap(Voice& v, const Ctx& x, const CompiledClip& c, const Plan& p, int64_t shift) noexcept {
        ClipReader::SongMap sm;
        if (p.follows) {
            sm.map = x.tm;
            sm.shift = shift;
            sm.offset = c.offsetFrames;
            sm.start = c.spec.startSteps;
            sm.framesPerStep = p.fps;
        }
        v.reader.setSongMap(sm);
    }
    // A voice for clip `ci` from song frame a (player time a + shift), heard from `heard`.
    void startVoice(Voice& v, const Ctx& x, int ci, const Plan& p, int64_t a, int64_t shift, int64_t heard) noexcept {
        const CompiledClip& c = x.tl->clips[static_cast<size_t>(ci)];
        v.active = v.seen = true;
        v.spare = v.spareMidClip = false;
        v.clip = ci;
        v.drift = 0;
        v.fadeLeft = 0;
        v.inAt = v.inLen = 0;
        v.lastGain = 0;
        v.want = p.mode;
        songMap(v, x, c, p, shift);
        HqStretcher* h = p.mode == ReadMode::Hq ? claimStretcher(v) : nullptr;
        v.reader.start(c.src, p.mode, p.pitch, a + shift, p.anchorS + p.slope * (static_cast<double>(a) - p.anchorT),
                       p.slope, h, static_cast<int64_t>(c.offsetFrames), heard + shift);
    }
    // Each block: the voice's mapping, and a stretcher for one that wanted Signalsmith and had to start on WSOLA
    // (from player time `at`, bridged by the WSOLA it plays).
    void follow(Voice& v, const Ctx& x, const CompiledClip& c, const Plan& p, int64_t shift, int64_t at) noexcept {
        v.anchorT = static_cast<int64_t>(p.anchorT) + shift;
        v.anchorS = p.anchorS + (p.follows ? 0.0 : v.drift);
        v.slope = p.slope;
        v.reader.setSource(c.src);
        v.reader.setMapping(v.anchorT, v.anchorS, v.slope);
        songMap(v, x, c, p, shift);
        if (v.want == ReadMode::Hq && v.reader.mode() == ReadMode::Stretch)
            if (HqStretcher* h = claimStretcher(v)) v.reader.upgrade(h, at, static_cast<int64_t>(c.offsetFrames));
    }
    // Before a wrap, the clips that sound where the loop lands get silent Signalsmith voices started a pre-roll ahead
    // of it (in the time they will have after the wrap), so the wrap needs no WSOLA bridge for them.
    void prerollWrap(const Ctx& x, int64_t pos, int64_t end, int64_t shift, int64_t preroll) noexcept {
        if (!live_ || preroll <= 0) return;
        const int64_t wrap = live_->loopWrapAt(), lands = live_->loopLandsAt();
        // From a pre-roll and a block before the wrap, so each spare starts a whole pre-roll ahead of the loop's start.
        if (wrap <= lands || wrap - lands < 2 * preroll || end > wrap || end + preroll + 64 < wrap) {
            for (Voice& v : voices_)
                if (v.spare) v.active = false;  // no longer before this wrap
            return;
        }
        spareLands_ = lands;
        const int64_t after = shift + (wrap - lands);  // player time minus song frame, after the wrap
        const int64_t va = lands - (wrap - pos), vz = lands - (wrap - end);  // this block, in song frames after the wrap
        const size_t first = firstClip(x, lands);
        for (size_t ci = first; ci < x.tl->clips.size(); ++ci) {
            const CompiledClip& c = x.tl->clips[ci];
            const int64_t cs = x.frameOfStep(c.spec.startSteps);
            if (cs >= lands + preroll) break;
            const int64_t ce = x.frameOfStep(c.spec.startSteps + c.spec.lengthSteps);
            // Clips sounding in the loop's first pre-roll and starting at or before its start (later ones pre-roll
            // as usual after the wrap).
            if (!c.spec.hq || c.spec.mute || !c.asset || ce <= lands || cs > lands) continue;
            const Plan p = plan(x, c, lands);
            if (p.mode != ReadMode::Hq) continue;
            Voice* v = spareFor(static_cast<int>(ci));
            int64_t from = va;
            if (!v) {
                // Started exactly a pre-roll ahead (as a clip ahead of the playhead is), so it plays as that would.
                const int64_t vs = lands - preroll;
                if (vs >= vz) continue;
                from = std::max(va, vs);
                if (hqVoices() >= kMaxHqVoices || playingVoices() >= kAudioClipVoices) continue;
                v = freeVoice();
                if (!v) continue;
                startVoice(*v, x, static_cast<int>(ci), p, from, after, lands);
                if (v->reader.mode() != ReadMode::Hq) {  // no stretcher free: the wrap bridges as before
                    v->active = false;
                    continue;
                }
                v->spare = true;
                v->spareMidClip = lands > cs;
            }
            v->seen = true;
            follow(*v, x, c, p, after, from + after);
            for (int64_t i = 0; i < vz - from; ++i) gain_[i] = 0.0f;
            v->reader.render(from + after, static_cast<int>(vz - from), gain_, scratchL_, scratchR_);
        }
    }
    Voice* spareFor(int clip) noexcept {
        for (Voice& v : voices_)
            if (v.active && v.spare && v.clip == clip) return &v;
        return nullptr;
    }
    int hqVoices() const noexcept {
        int n = 0;
        for (const Voice& v : voices_) n += v.active && v.reader.mode() == ReadMode::Hq && v.reader.stretcher();
        return n;
    }
    // A stretcher of the current timeline no other active voice holds, within the cap (audio thread).
    HqStretcher* claimStretcher(Voice& self) noexcept {
        const Timeline* tl = timeline_.current();
        if (!tl) return nullptr;
        int busy = 0;
        for (const Voice& v : voices_)
            busy += &v != &self && v.active && v.clip >= 0 && v.reader.mode() == ReadMode::Hq && v.reader.stretcher();
        if (busy >= kMaxHqVoices) return nullptr;
        for (const std::shared_ptr<HqStretcher>& sp : tl->pool) {
            HqStretcher* h = sp.get();
            bool used = false;
            for (const Voice& v : voices_)
                used |= &v != &self && v.active && v.reader.mode() == ReadMode::Hq && v.reader.stretcher() == h;
            if (!used && h->sampleRate() == sr_) return h;
        }
        return nullptr;
    }
    // Control thread: the new timeline's stretchers, as many as its Signalsmith clips can play at once (their most
    // overlapping, a step of pre-roll each, at most the cap) plus two (a voice fading out, a spare for the loop's
    // start), kept from the last timeline where they are at this rate and made where not.
    void buildPool(Timeline& t, double rate) {
        std::vector<std::pair<double, int>> edges;
        for (const CompiledClip& c : t.clips)
            if (c.spec.hq && !c.spec.mute) {
                edges.push_back({c.spec.startSteps - 1.0, 1});
                edges.push_back({c.spec.startSteps + c.spec.lengthSteps, -1});
            }
        std::sort(edges.begin(), edges.end());
        int now = 0, most = 0;
        for (const auto& e : edges) most = std::max(most, now += e.second);
        const int want = most > 0 ? std::min(most, kMaxHqVoices) + 2 : 0;
        for (const std::shared_ptr<HqStretcher>& h : pool_)
            if (static_cast<int>(t.pool.size()) < want && h->sampleRate() == rate) t.pool.push_back(h);
        while (static_cast<int>(t.pool.size()) < want) {
            auto h = std::make_shared<HqStretcher>();
            if (!h->prepare(rate)) break;
            t.pool.push_back(std::move(h));
        }
        t.hqLatency = t.pool.empty() ? 0 : t.pool.front()->outputLatency();
        pool_ = t.pool;  // the stretchers a timeline drops are freed with it, here on the control thread
    }
    static bool inPool(const Timeline& t, const HqStretcher* h) noexcept {
        for (const std::shared_ptr<HqStretcher>& sp : t.pool)
            if (sp.get() == h) return true;
        return false;
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
            if (found < 0 || (v.reader.stretcher() && !inPool(*t, v.reader.stretcher()))) {
                if (v.spare) v.active = false;
                else fadeOut(v);
            } else {
                v.clip = found;
            }
        }
    }

    double sr_ = 48000;
    LiveAudio* live_ = nullptr;
    Voice voices_[2 * kAudioClipVoices];  // the playing ones, and room for as many fading out
    float scratchL_[64] = {}, scratchR_[64] = {};  // a spare's silent output
    int64_t spareLands_ = -1;  // the song frame the spares were pre-rolled for (-1: none)
    float gain_[64] = {};
    int64_t expected_ = -1;
    int64_t clock_ = 0;      // the player's own time: one frame per frame rendered, whatever the transport does
    int64_t declick_ = 192;  // frames
    double lastTempo_ = 0;
    uint64_t lastSongSerial_ = 0;  // the tempo map last played by (its SongTime::serial; 0: one tempo)
    bool lastMapped_ = false;
    Handover<Timeline> timeline_;
    Timeline* held_ = nullptr;  // a replaced timeline whose assets fading voices still read
    std::atomic<bool> monitorStopped_{false};
    // control thread
    std::string signature_;
    double compiledRate_ = 0;
    uint64_t serial_ = 0, lastSerial_ = 0;
    std::vector<std::pair<std::string, const AudioAsset*>> lastClips_;
    std::vector<std::shared_ptr<HqStretcher>> pool_;  // the last timeline's stretchers
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

AudioTrackStats audioTrackStats(const ModuleProcessor& processor) noexcept {
    const auto* p = dynamic_cast<const AudioTrackPlayer*>(&processor);
    return p ? p->stats() : AudioTrackStats{};
}

bool monitorsStopped(const ModuleProcessor& processor) noexcept {
    const auto* p = dynamic_cast<const LiveInputUser*>(&processor);
    return p && p->monitoringStopped();
}

// Internal: never listed among the instruments (a layer becomes an audio track through "audio_clips"/"input").
void registerAudioTrack(ModuleRegistry& registry) { registry.addInternal(playerDescriptor(), &makePlayer); }

}  // namespace caw
