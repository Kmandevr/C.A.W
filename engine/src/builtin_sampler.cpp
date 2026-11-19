// The sampler instrument (org.caw.sampler): its zone state JSON, parameters and voices (Hermite reading, loops, ADSR, SVF).
#include "builtin_sampler.h"

#include <algorithm>
#include "caw/detmath.hpp"
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "asset_store.h"
#include "handover.h"
#include "json.h"
#include "project.h"
#include "caw/instrument.hpp"
#include "caw/library/envelope.hpp"
#include "caw/library/filter.hpp"
#include "clip_stretch.h"
#include "time_stretch.h"

namespace caw {
using lib::Adsr;
using lib::Svf;
using lib::SvfOutput;
}  // namespace caw

namespace caw {

// ---------------------------------------------------------------- the state JSON

namespace {

const char* loopName(LoopMode m) {
    switch (m) {
        case LoopMode::NoLoop: return "no_loop";
        case LoopMode::OneShot: return "one_shot";
        case LoopMode::Continuous: return "loop_continuous";
        case LoopMode::Sustain: return "loop_sustain";
    }
    return "no_loop";
}

std::string num(double v) {
    char b[40];
    std::snprintf(b, sizeof b, "%.10g", v);
    return b;
}

}  // namespace

bool parseSamplerState(std::string_view text, SamplerProgram& out, std::string& error) {
    out = SamplerProgram{};
    if (text.empty()) return true;  // a new sampler: no zones
    Json j;
    if (!parseJson(text, j, error)) return false;
    if (j.type != Json::Type::Object) {
        error = "the sampler state must be {\"zones\": [...]}";
        return false;
    }
    const Json* zones = j.get("zones");
    if (!zones || zones->type == Json::Type::Null) return true;
    if (zones->type != Json::Type::Array || zones->arr.size() > kMaxSamplerZones) {
        error = "zones must be a list of at most " + std::to_string(kMaxSamplerZones);
        return false;
    }
    for (size_t i = 0; i < zones->arr.size(); ++i) {
        const Json& z = zones->arr[i];
        const std::string where = "zone " + std::to_string(i);
        if (z.type != Json::Type::Object) {
            error = where + " must be an object";
            return false;
        }
        SamplerZone s;
        s.path = z.string("path");
        if (s.path.empty()) {
            error = where + " needs a \"path\"";
            return false;
        }
        bool ok = true;
        auto whole = [&](const char* key, int lo, int hi, int fallback) {
            const double v = z.number(key, fallback);
            if (!std::isfinite(v) || v != std::floor(v) || v < lo || v > hi) {
                if (ok) error = where + ": " + key + " must be a whole number " + std::to_string(lo) + ".." + std::to_string(hi);
                ok = false;
                return fallback;
            }
            return static_cast<int>(v);
        };
        auto real = [&](const char* key, double lo, double hi, double fallback) {
            const double v = z.number(key, fallback);
            if (!std::isfinite(v) || v < lo || v > hi) {
                if (ok) error = where + ": " + key + " must be " + num(lo) + ".." + num(hi);
                ok = false;
                return fallback;
            }
            return v;
        };
        auto frames = [&](const char* key) {
            const double v = z.number(key, 0);
            if (!std::isfinite(v) || v != std::floor(v) || v < 0 || v > 9.0e15) {
                if (ok) error = where + ": " + key + " must be a whole frame count";
                ok = false;
                return int64_t{0};
            }
            return static_cast<int64_t>(v);
        };
        s.lokey = whole("lokey", 0, 127, 0);
        s.hikey = whole("hikey", 0, 127, 127);
        s.root = whole("pitch_keycenter", 0, 127, 60);
        s.lovel = whole("lovel", 1, 127, 1);
        s.hivel = whole("hivel", 1, 127, 127);
        s.tune = real("tune", -9600, 9600, 0);
        s.transpose = whole("transpose", -127, 127, 0);
        s.volume = real("volume", -144, 24, 0);
        s.pan = real("pan", -100, 100, 0);
        s.keytrack = real("pitch_keytrack", -1200, 1200, 100);
        s.veltrack = real("amp_veltrack", -100, 100, 100);
        s.offset = frames("offset");
        s.end = frames("end");
        s.loopStart = frames("loop_start");
        s.loopEnd = frames("loop_end");
        s.loopCrossfade = real("loop_crossfade", 0, 10, 0);
        s.seqLength = whole("seq_length", 1, 100, 1);
        s.seqPosition = whole("seq_position", 1, 100, 1);
        s.lorand = real("lorand", 0, 1, 0);
        s.hirand = real("hirand", 0, 1, 1);
        s.group = whole("group", 0, 1000000, 0);
        s.offBy = whole("off_by", 0, 1000000, 0);
        s.ampAttack = real("ampeg_attack", -1, 100, -1);
        s.ampDecay = real("ampeg_decay", -1, 100, -1);
        s.ampSustain = real("ampeg_sustain", -1, 100, -1);
        s.ampRelease = real("ampeg_release", -1, 100, -1);
        s.stretch = z.boolean("stretch", false);
        s.stretchBpm = real("stretch_bpm", 0, 999, 0);
        if (ok && s.stretchBpm > 0 && s.stretchBpm < 20) {
            error = where + ": stretch_bpm must be 0 or 20..999";
            ok = false;
        }
        if (const Json* m = z.get("loop_mode"); m && m->type == Json::Type::String) {
            s.loopModeSet = true;
            if (m->str == "no_loop") s.loopMode = LoopMode::NoLoop;
            else if (m->str == "one_shot") s.loopMode = LoopMode::OneShot;
            else if (m->str == "loop_continuous") s.loopMode = LoopMode::Continuous;
            else if (m->str == "loop_sustain") s.loopMode = LoopMode::Sustain;
            else if (ok) {
                error = where + ": loop_mode is no_loop, one_shot, loop_continuous or loop_sustain";
                ok = false;
            }
        }
        if (!ok) return false;
        if (s.lokey > s.hikey || s.lovel > s.hivel || s.seqPosition > s.seqLength || s.lorand > s.hirand) {
            error = where + ": a low bound is above its high bound";
            return false;
        }
        if (!s.loopModeSet && s.loopEnd > s.loopStart) s.loopMode = LoopMode::Continuous;  // SFZ: loops in the file
        out.zones.push_back(std::move(s));
    }
    return true;
}

std::string samplerStateJson(const SamplerProgram& p) {
    std::string s = "{\"zones\":[";
    for (size_t i = 0; i < p.zones.size(); ++i) {
        const SamplerZone& z = p.zones[i];
        if (i) s += ",";
        s += "{\"path\":\"" + jsonEscape(z.path) + "\",\"lokey\":" + std::to_string(z.lokey) +
             ",\"hikey\":" + std::to_string(z.hikey) + ",\"pitch_keycenter\":" + std::to_string(z.root) +
             ",\"lovel\":" + std::to_string(z.lovel) + ",\"hivel\":" + std::to_string(z.hivel);
        if (z.tune != 0) s += ",\"tune\":" + num(z.tune);
        if (z.transpose != 0) s += ",\"transpose\":" + std::to_string(z.transpose);
        if (z.volume != 0) s += ",\"volume\":" + num(z.volume);
        if (z.pan != 0) s += ",\"pan\":" + num(z.pan);
        if (z.keytrack != 100) s += ",\"pitch_keytrack\":" + num(z.keytrack);
        if (z.veltrack != 100) s += ",\"amp_veltrack\":" + num(z.veltrack);
        if (z.offset) s += ",\"offset\":" + std::to_string(z.offset);
        if (z.end) s += ",\"end\":" + std::to_string(z.end);
        s += ",\"loop_mode\":\"" + std::string(loopName(z.loopMode)) + "\"";
        if (z.loopStart || z.loopEnd)
            s += ",\"loop_start\":" + std::to_string(z.loopStart) + ",\"loop_end\":" + std::to_string(z.loopEnd);
        if (z.loopCrossfade > 0) s += ",\"loop_crossfade\":" + num(z.loopCrossfade);
        if (z.seqLength > 1) s += ",\"seq_length\":" + std::to_string(z.seqLength) + ",\"seq_position\":" + std::to_string(z.seqPosition);
        if (z.lorand > 0 || z.hirand < 1) s += ",\"lorand\":" + num(z.lorand) + ",\"hirand\":" + num(z.hirand);
        if (z.group) s += ",\"group\":" + std::to_string(z.group);
        if (z.offBy) s += ",\"off_by\":" + std::to_string(z.offBy);
        if (z.ampAttack >= 0) s += ",\"ampeg_attack\":" + num(z.ampAttack);
        if (z.ampDecay >= 0) s += ",\"ampeg_decay\":" + num(z.ampDecay);
        if (z.ampSustain >= 0) s += ",\"ampeg_sustain\":" + num(z.ampSustain);
        if (z.ampRelease >= 0) s += ",\"ampeg_release\":" + num(z.ampRelease);
        if (z.stretch) s += ",\"stretch\":true";
        if (z.stretchBpm > 0) s += ",\"stretch_bpm\":" + num(z.stretchBpm);
        s += "}";
    }
    return s + "]}";
}

// ---------------------------------------------------------------- the instrument

namespace {

enum Param : uint32_t {
    kGain, kAttack, kDecay, kSustain, kRelease, kVelocity, kTune, kTranspose, kFilter, kCutoff, kResonance,
    kFilterEnv, kFilterKey, kFAttack, kFDecay, kFSustain, kFRelease, kPolyphony, kParamCount
};

constexpr std::string_view kFilterLabels[] = {"Off", "Low-pass", "High-pass", "Band-pass"};

const ParameterDescriptor* parameters() {
    static const auto table = [] {
        std::array<ParameterDescriptor, kParamCount> t{};
        auto set = [&](Param k, std::string_view id, std::string_view name, double lo, double hi, double def,
                       std::string_view unit, bool exp = false, double step = 0) {
            ParameterDescriptor& p = t[k];
            p.id = id;
            p.name = name;
            p.minimum = lo;
            p.maximum = hi;
            p.defaultValue = def;
            p.unit = unit;
            p.curve = exp ? ParameterCurve::Exponential : ParameterCurve::Linear;
            p.step = step;
            p.smoothingFrames = step > 0 ? 0 : 480;
        };
        set(kGain, "gain", "Gain", -60, 12, 0, "dB");
        set(kAttack, "attack", "Attack", 0, 10, 0.001, "s");
        set(kDecay, "decay", "Decay", 0, 20, 0.3, "s");
        set(kSustain, "sustain", "Sustain", 0, 1, 1, "");
        set(kRelease, "release", "Release", 0, 20, 0.15, "s");
        set(kVelocity, "velocity", "Velocity", 0, 1, 1, "");
        set(kTune, "tune", "Tune", -100, 100, 0, "cents");
        set(kTranspose, "transpose", "Transpose", -48, 48, 0, "st", false, 1);
        set(kFilter, "filter", "Filter", 0, 3, 0, "", false, 1);
        t[kFilter].choices = kFilterLabels;
        t[kFilter].choiceCount = 4;
        set(kCutoff, "cutoff", "Cutoff", 20, 20000, 20000, "Hz", true);
        set(kResonance, "resonance", "Resonance", 0.5, 20, 0.707, "");
        set(kFilterEnv, "filter_env", "Filter env", -8, 8, 0, "oct");
        set(kFilterKey, "filter_key", "Key track", 0, 1, 0, "");
        set(kFAttack, "filter_attack", "Filter attack", 0, 10, 0.001, "s");
        set(kFDecay, "filter_decay", "Filter decay", 0, 20, 0.3, "s");
        set(kFSustain, "filter_sustain", "Filter sustain", 0, 1, 0, "");
        set(kFRelease, "filter_release", "Filter release", 0, 20, 0.15, "s");
        set(kPolyphony, "polyphony", "Polyphony", 1, kSamplerVoices, 32, "", false, 1);
        for (auto& p : t) p.group = p.id.rfind("filter", 0) == 0 || p.id == "cutoff" || p.id == "resonance" ? "filter" : "amp";
        return t;
    }();
    return table.data();
}

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

const ModuleDescriptor& samplerDescriptor() {
    static const ModuleDescriptor d = [] {
        ModuleDescriptor m;
        m.id = kSamplerId;
        m.name = "Sampler";
        m.role = ModuleRole::Instrument;
        m.ports = kPorts;
        m.portCount = 2;
        m.parameters = parameters();
        m.parameterCount = kParamCount;
        m.tailFrames = 192000 * 30;
        m.maxStateBytes = kMaxSamplerStateBytes;
        return m;
    }();
    return d;
}

// A zone as it plays, at the engine's rate.
struct LoadedZone {
    SamplerZone z;
    std::shared_ptr<const AudioAsset> asset;
    double start = 0, last = 0;          // first and last frame played
    double loopStart = 0, loopEnd = 0;   // loopEnd: one past the loop's last frame
    double crossfade = 0;                // frames
    double gainL = 1, gainR = 1;
};

struct Program {
    std::vector<LoadedZone> zones;
    bool stretches = false;  // a zone is stretched: the processor keeps its readers and stretchers
};

constexpr uint32_t kStretchReaders = 16;  // stretched voices at once (WSOLA readers, about 110 KB each at 48 kHz)

inline float cubic(float a, float b, float c, float d, float t) noexcept {
    return b + 0.5f * t * (c - a + t * (2.0f * a - 5.0f * b + 4.0f * c - d + t * (3.0f * (b - c) + d - a)));
}

class SamplerProcessor final : public InstrumentProcessor {
public:
    ~SamplerProcessor() override { delete old_; }
    const ModuleDescriptor& descriptor() const noexcept override { return samplerDescriptor(); }
    bool activate(double sampleRate, uint32_t) noexcept override {
        if (sampleRate != sr_) {  // the stretch pools are built at the rate (not running: activate is off the audio thread)
            readers_.reset();
            hq_.reset();
        }
        sr_ = sampleRate;
        if (!loaded_.empty()) {  // a state loaded before activation: build it at this rate
            std::string e;
            try {
                build(loaded_, e);
            } catch (...) {
                return false;
            }
        }
        return true;
    }
    void reset() noexcept override {
        for (Voice& v : voices_) v.active = false;
        std::fill(std::begin(readerOwner_), std::end(readerOwner_), -1);
        std::fill(std::begin(hqOwner_), std::end(hqOwner_), -1);
        std::fill(std::begin(counters_), std::end(counters_), 0u);
        rng_ = 0x9E3779B9u;
    }
    bool quiet() const noexcept override {
        for (const Voice& v : voices_)
            if (v.active) return false;
        return true;
    }
    uint32_t stateVersion() const noexcept override { return 1; }
    bool saveState(uint8_t* dst, uint32_t capacity, uint32_t& written) const noexcept override {
        written = 0;
        if (loaded_.size() > capacity) return false;
        std::memcpy(dst, loaded_.data(), loaded_.size());
        written = static_cast<uint32_t>(loaded_.size());
        return true;
    }
    bool loadState(const uint8_t* src, uint32_t size, uint32_t version) noexcept override {
        if (version != 1) return false;
        try {
            const std::string text(reinterpret_cast<const char*>(src), size);
            SamplerProgram p;
            std::string error;
            if (!parseSamplerState(text, p, error)) return false;
            loaded_ = samplerStateJson(p);
            if (sr_ > 0) return build(loaded_, error);
            return true;
        } catch (...) {
            return false;
        }
    }
    // Control thread: the project's state, when it differs from what plays.
    void projectState(const std::vector<uint8_t>& state, uint32_t version) noexcept {
        try {
            SamplerProgram p;
            std::string error;
            if (!parseSamplerState(std::string_view(reinterpret_cast<const char*>(state.data()), state.size()), p, error))
                return;
            const std::string canon = samplerStateJson(p);
            if (canon != loaded_) loadState(state.data(), static_cast<uint32_t>(state.size()), version);
        } catch (...) {
        }
    }

protected:
    void beginBlock(const ProcessBlock& b) noexcept override {
        // New zones: the voices on the old ones fade out over kFadeSeconds, and the old program stays here
        // (not freed) until they are done.
        if (old_ && !plays(old_) && program_.retire(old_)) old_ = nullptr;
        Program* previous = nullptr;
        if (!old_ && program_.take(previous)) {
            for (Voice& v : voices_)
                if (v.active) fadeQuickly(v);
            std::fill(std::begin(counters_), std::end(counters_), 0u);
            if (previous && (plays(previous) || !program_.retire(previous))) old_ = previous;
        }
        for (uint32_t k = 0; k < kParamCount; ++k) p_[k] = parameterAt(b, k, 0, parameters()[k].defaultValue);
        tempo_ = b.transport && b.transport->tempo > 0 ? b.transport->tempo : 120.0;
        // Stretch readers and stretchers whose voice ended are free again.
        for (uint32_t k = 0; k < kStretchReaders; ++k)
            if (readerOwner_[k] >= 0 && (!voices_[readerOwner_[k]].active || voices_[readerOwner_[k]].reader != static_cast<int>(k)))
                readerOwner_[k] = -1;
        for (uint32_t k = 0; k < kSamplerStretchers; ++k)
            if (hqOwner_[k] >= 0 && (!voices_[hqOwner_[k]].active || voices_[hqOwner_[k]].hq != static_cast<int>(k)))
                hqOwner_[k] = -1;
    }
    void onNote(const NoteMessage& m) noexcept override {
        if (m.type == NoteMessageType::On) start(m);
        else if (m.type == NoteMessageType::Off) {
            for (Voice& v : voices_)
                if (v.active && v.noteId == m.noteId && v.held) release(v);
        } else if (m.type == NoteMessageType::Pitch) {
            for (Voice& v : voices_)
                if (v.active && v.noteId == m.noteId) v.pitch = m.pitch;
        }
    }
    void render(float* left, float* right, uint32_t frames, uint32_t, const ProcessBlock&) noexcept override {
        std::fill_n(left, frames, 0.0f);
        std::fill_n(right, frames, 0.0f);
        const double gain = detPow(10.0, p_[kGain] / 20.0);
        const int filter = static_cast<int>(p_[kFilter]);
        for (Voice& v : voices_) {
            if (!v.active) continue;
            if (!v.prog || v.zone >= v.prog->zones.size()) { v.active = false; continue; }
            const LoadedZone& z = v.prog->zones[v.zone];
            const AudioAsset& a = *z.asset;
            v.amp.set(v.attack, v.decay, v.sustain, v.releaseTime, sr_);
            v.fenv.set(p_[kFAttack], p_[kFDecay], p_[kFSustain], p_[kFRelease], sr_);
            const double tuneCents = (v.pitch - z.z.root) * z.z.keytrack + z.z.tune + 100.0 * z.z.transpose +
                                     p_[kTune] + 100.0 * p_[kTranspose];
            const double inc = detPow(2.0, tuneCents / 1200.0);
            const bool looping = z.loopEnd > z.loopStart &&
                (z.z.loopMode == LoopMode::Continuous || (z.z.loopMode == LoopMode::Sustain && v.held));
            if (v.reader >= 0) {
                renderStretched(v, z, looping, gain, filter, left, right, frames);
                continue;
            }
            const float* l = a.channel(0);
            const float* r = a.channel(1);
            const int64_t frameCount = a.frames;
            auto at = [&](const float* x, double pos) {
                const double f = std::floor(pos);
                const int64_t i = static_cast<int64_t>(f);
                auto s = [&](int64_t k) { return k < 0 || k >= frameCount ? 0.0f : x[k]; };
                return cubic(s(i - 1), s(i), s(i + 1), s(i + 2), static_cast<float>(pos - f));
            };
            for (uint32_t i = 0; i < frames; ++i) {
                if ((i & 15) == 0 && filter > 0) {  // the filter's cutoff, every 16 frames
                    const double env = v.fenv.level();
                    double fc = p_[kCutoff] * detPow(2.0, p_[kFilterEnv] * env + p_[kFilterKey] * (v.pitch - 60.0) / 12.0);
                    fc = std::clamp(fc, 20.0, 0.45 * sr_);
                    v.svfL.set(fc, p_[kResonance], sr_);
                    v.svfR.set(fc, p_[kResonance], sr_);
                }
                if (looping && v.pos >= z.loopEnd) v.pos -= z.loopEnd - z.loopStart;
                if (v.pos > z.last) { v.active = false; break; }
                float sl = at(l, v.pos), sr = r == l ? sl : at(r, v.pos);
                if (looping && z.crossfade > 0 && v.pos >= z.loopEnd - z.crossfade) {
                    // The loop's end fades into the audio before its start, so the wrap is seamless.
                    const double w = (v.pos - (z.loopEnd - z.crossfade)) / z.crossfade;
                    const double back = v.pos - (z.loopEnd - z.loopStart);
                    const float bl = at(l, back), br = r == l ? bl : at(r, back);
                    const float wa = static_cast<float>(std::sqrt(1.0 - w)), wb = static_cast<float>(std::sqrt(w));
                    sl = sl * wa + bl * wb;
                    sr = sr * wa + br * wb;
                }
                double env = v.amp.next();
                v.fenv.next();
                if (v.amp.done()) { v.active = false; break; }
                if (v.killStep > 0) {  // stolen, or its zones replaced: a short fade out
                    v.kill -= v.killStep;
                    if (v.kill <= 0) { v.active = false; break; }
                    env *= v.kill;
                }
                float ol = static_cast<float>(sl * env * v.gainL * gain), orr = static_cast<float>(sr * env * v.gainR * gain);
                if (filter > 0) {
                    const SvfOutput fl = v.svfL.process(ol), fr = v.svfR.process(orr);
                    ol = static_cast<float>(filter == 1 ? fl.low : filter == 2 ? fl.high : fl.band);
                    orr = static_cast<float>(filter == 1 ? fr.low : filter == 2 ? fr.high : fr.band);
                }
                left[i] += ol;
                right[i] += orr;
                v.pos += inc;
            }
        }
    }

private:
    struct Voice {
        bool active = false, held = false;
        int reader = -1, hq = -1;   // a stretched voice's reader and stretcher (indices into the pools; -1: none)
        int64_t t = 0;              // a stretched voice's output frames so far
        double src = 0, slope = 1;  // ... its source frame (unwrapped) and source frames per output frame
        uint32_t noteId = 0;
        const Program* prog = nullptr;  // the zones it plays (the current program, or the old one fading out)
        size_t zone = 0;
        double kill = 1, killStep = 0;  // a fade out over kFadeSeconds when killStep > 0
        uint64_t age = 0;
        double pos = 0, pitch = 60;
        double gainL = 1, gainR = 1;
        double attack = 0, decay = 0, sustain = 1, releaseTime = 0;
        struct Amp {
            Adsr e;
            bool off = false;
            void set(double a, double d, double s, double r, double sr) noexcept { e.set(a, d, s, r, sr); }
            double next() noexcept { return e.next(); }
            bool done() const noexcept { return off && e.level() == 0.0; }
        } amp;
        Adsr fenv;
        Svf svfL, svfR;
    };
    static constexpr double kFadeSeconds = 0.005;
    // A stretched voice: its reader gives the zone's audio at the voice's pitch and the zone's speed, 64 frames at a
    // time, then the same envelopes, fade and filter as a plain voice. The speed follows the song's tempo when the zone
    // has a stretch_bpm.
    void renderStretched(Voice& v, const LoadedZone& z, bool looping, double gain, int filter, float* left, float* right,
                         uint32_t frames) noexcept {
        ClipReader& rd = readers_[static_cast<size_t>(v.reader)];
        const double slope = z.z.stretchBpm > 0 ? tempo_ / z.z.stretchBpm : 1.0;
        if (slope != v.slope) {
            rd.setMapping(v.t, v.src, slope);
            v.slope = slope;
        }
        float bl[64], br[64];
        uint32_t i = 0;
        while (i < frames && v.active) {
            const int n = static_cast<int>(std::min<uint32_t>(64, frames - i));
            std::fill_n(bl, n, 0.0f);
            std::fill_n(br, n, 0.0f);
            rd.render(v.t, n, ones_, bl, br);
            v.t += n;
            for (int k = 0; k < n; ++k, ++i) {
                if ((i & 15) == 0 && filter > 0) {
                    const double env = v.fenv.level();
                    double fc = p_[kCutoff] * detPow(2.0, p_[kFilterEnv] * env + p_[kFilterKey] * (v.pitch - 60.0) / 12.0);
                    fc = std::clamp(fc, 20.0, 0.45 * sr_);
                    v.svfL.set(fc, p_[kResonance], sr_);
                    v.svfR.set(fc, p_[kResonance], sr_);
                }
                if (!looping && v.src > z.last) { v.active = false; return; }
                double env = v.amp.next();
                v.fenv.next();
                if (v.amp.done()) { v.active = false; return; }
                if (v.killStep > 0) {
                    v.kill -= v.killStep;
                    if (v.kill <= 0) { v.active = false; return; }
                    env *= v.kill;
                }
                float ol = static_cast<float>(bl[k] * env * v.gainL * gain), orr = static_cast<float>(br[k] * env * v.gainR * gain);
                if (filter > 0) {
                    const SvfOutput fl = v.svfL.process(ol), fr = v.svfR.process(orr);
                    ol = static_cast<float>(filter == 1 ? fl.low : filter == 2 ? fl.high : fl.band);
                    orr = static_cast<float>(filter == 1 ? fr.low : filter == 2 ? fr.high : fr.band);
                }
                left[i] += ol;
                right[i] += orr;
                v.src += v.slope;
            }
        }
    }
    // Starts voice v (slot vi) on a stretched zone, with a free reader (else it plays as a plain voice) and a free
    // Signalsmith stretcher (else WSOLA).
    void startStretched(Voice& v, int vi, const LoadedZone& lz, double cents) noexcept {
        if (!readers_) return;
        int r = -1, h = -1;
        for (uint32_t k = 0; k < kStretchReaders && r < 0; ++k)
            if (readerOwner_[k] < 0) r = static_cast<int>(k);
        if (r < 0) return;
        for (uint32_t k = 0; k < kSamplerStretchers && h < 0 && hq_; ++k)
            if (hqOwner_[k] < 0) h = static_cast<int>(k);
        readerOwner_[r] = vi;
        v.reader = r;
        if (h >= 0) {
            hqOwner_[h] = vi;
            v.hq = h;
        }
        ClipSource src;
        src.asset = lz.asset.get();
        src.loop = lz.loopEnd > lz.loopStart &&
                   (lz.z.loopMode == LoopMode::Continuous || lz.z.loopMode == LoopMode::Sustain);
        src.loopStart = static_cast<int64_t>(std::llround(lz.loopStart));
        src.loopEnd = static_cast<int64_t>(std::llround(lz.loopEnd));
        src.seam = static_cast<int64_t>(std::llround(lz.crossfade));
        v.slope = lz.z.stretchBpm > 0 ? tempo_ / lz.z.stretchBpm : 1.0;
        v.src = lz.start;
        v.t = 0;
        readers_[static_cast<size_t>(r)].start(src, h >= 0 ? ReadMode::Hq : ReadMode::Stretch, detPow(2.0, std::clamp(cents, -4800.0, 4800.0) / 1200.0), 0,
                                               lz.start, v.slope, h >= 0 ? &hq_[static_cast<size_t>(h)] : nullptr,
                                               static_cast<int64_t>(lz.start), 0);
    }
    // Control thread: the pools a program with stretched zones needs, built once (at the processor's rate).
    bool ensureStretchPools() {
        if (readers_) return true;
        std::unique_ptr<ClipReader[]> readers(new ClipReader[kStretchReaders]);
        for (uint32_t k = 0; k < kStretchReaders; ++k)
            if (!readers[k].prepare(sr_)) return false;
        std::unique_ptr<HqStretcher[]> hq(new HqStretcher[kSamplerStretchers]);
        for (uint32_t k = 0; k < kSamplerStretchers; ++k)
            if (!hq[k].prepare(sr_)) return false;
        hq_ = std::move(hq);
        readers_ = std::move(readers);
        return true;
    }
    void fadeQuickly(Voice& v) noexcept {
        v.held = false;
        if (v.killStep == 0) v.killStep = 1.0 / std::max(1.0, kFadeSeconds * sr_);
    }
    bool plays(const Program* p) const noexcept {
        for (const Voice& v : voices_)
            if (v.active && v.prog == p) return true;
        return false;
    }
    void release(Voice& v) noexcept {
        const Program* prog = v.prog;
        v.held = false;
        if (prog && v.zone < prog->zones.size() && prog->zones[v.zone].z.loopMode == LoopMode::OneShot) return;
        v.amp.off = true;
        v.amp.e.gateOff();
        v.fenv.gateOff();
    }
    uint32_t nextRandom() noexcept {
        rng_ ^= rng_ << 13;
        rng_ ^= rng_ >> 17;
        rng_ ^= rng_ << 5;
        return rng_;
    }
    void start(const NoteMessage& m) noexcept {
        const Program* prog = program_.current();
        if (!prog) return;
        const int key = m.key;
        const int vel = std::clamp(static_cast<int>(std::lround(m.velocity * 127.0)), 1, 127);
        const double rnd = static_cast<double>(nextRandom() >> 8) / 16777216.0;
        const uint32_t poly = static_cast<uint32_t>(std::clamp(p_[kPolyphony], 1.0, static_cast<double>(kSamplerVoices)));
        for (size_t zi = 0; zi < prog->zones.size(); ++zi) {
            const LoadedZone& lz = prog->zones[zi];
            const SamplerZone& z = lz.z;
            if (key < z.lokey || key > z.hikey || vel < z.lovel || vel > z.hivel) continue;
            const uint32_t count = zi < kMaxSamplerZones ? counters_[zi]++ : 0;
            if (static_cast<int>(count % static_cast<uint32_t>(z.seqLength)) != z.seqPosition - 1) continue;
            if (rnd < z.lorand || rnd >= z.hirand) continue;
            if (!lz.asset) continue;
            if (z.group)  // choke: zones this group cuts off
                for (Voice& v : voices_)
                    if (v.active && v.prog == prog && v.zone < prog->zones.size() && prog->zones[v.zone].z.offBy == z.group) {
                        v.releaseTime = 0.005;
                        v.amp.off = true;
                        v.amp.e.set(v.attack, v.decay, v.sustain, 0.005, sr_);
                        v.amp.e.gateOff();
                    }
            // A voice: a free slot. Polyphony counts the sounding voices (not those fading out); at the limit the
            // oldest releasing voice is stolen, else the oldest, and it fades out in its slot over kFadeSeconds
            // while the new one starts in a spare slot.
            uint32_t sounding = 0;
            Voice* pick = nullptr;
            Voice* oldest = nullptr;
            Voice* oldestReleasing = nullptr;
            Voice* oldestFading = nullptr;
            for (Voice& v : voices_) {
                if (!v.active) {
                    if (!pick) pick = &v;
                } else if (v.killStep > 0) {
                    if (!oldestFading || v.age < oldestFading->age) oldestFading = &v;
                } else {
                    ++sounding;
                    if (v.amp.off) {
                        if (!oldestReleasing || v.age < oldestReleasing->age) oldestReleasing = &v;
                    } else if (!oldest || v.age < oldest->age) {
                        oldest = &v;
                    }
                }
            }
            Voice* victim = nullptr;
            if (sounding >= poly) {
                victim = oldestReleasing ? oldestReleasing : oldest;
                if (victim) fadeQuickly(*victim);
            }
            if (!pick) pick = oldestFading ? oldestFading : victim;  // no slot left: one is cut
            if (!pick) return;
            Voice& v = *pick;
            const int vi = static_cast<int>(&v - voices_);
            if (v.reader >= 0) readerOwner_[v.reader] = -1;
            if (v.hq >= 0) hqOwner_[v.hq] = -1;
            v = Voice{};
            v.active = v.held = true;
            v.noteId = m.noteId;
            v.prog = prog;
            v.zone = zi;
            v.age = ++clock_;
            v.pos = lz.start;
            v.pitch = m.pitch;
            const double sens = std::clamp(p_[kVelocity], 0.0, 1.0) * z.veltrack / 100.0;
            const double v01 = vel / 127.0;
            const double velGain = sens >= 0 ? (1.0 - sens) + sens * v01 * v01 : 1.0 + sens * v01 * v01;
            v.gainL = lz.gainL * velGain;
            v.gainR = lz.gainR * velGain;
            v.attack = z.ampAttack >= 0 ? z.ampAttack : p_[kAttack];
            v.decay = z.ampDecay >= 0 ? z.ampDecay : p_[kDecay];
            v.sustain = z.ampSustain >= 0 ? z.ampSustain / 100.0 : p_[kSustain];
            v.releaseTime = z.ampRelease >= 0 ? z.ampRelease : p_[kRelease];
            v.amp.set(v.attack, v.decay, v.sustain, v.releaseTime, sr_);
            v.amp.e.gateOn();
            v.fenv.set(p_[kFAttack], p_[kFDecay], p_[kFSustain], p_[kFRelease], sr_);
            v.fenv.gateOn();
            if (z.stretch)
                startStretched(v, vi, lz, (m.pitch - z.root) * z.keytrack + z.tune + 100.0 * z.transpose + p_[kTune] +
                                              100.0 * p_[kTranspose]);
        }
    }
    // Control thread: loads every zone's sample and hands the program to the audio thread.
    bool build(const std::string& json, std::string& error) {
        SamplerProgram p;
        if (!parseSamplerState(json, p, error)) return false;
        auto prog = std::make_unique<Program>();
        for (const SamplerZone& z : p.zones) {
            LoadedZone lz;
            lz.z = z;
            std::string why;
            lz.asset = AssetStore::global().load(z.path, sr_, why);
            if (lz.asset) {
                const double k = lz.asset->sourceRate > 0 ? sr_ / lz.asset->sourceRate : 1.0;
                const double frames = static_cast<double>(lz.asset->frames);
                lz.start = std::min(frames - 1, static_cast<double>(z.offset) * k);
                lz.last = z.end > 0 ? std::min(frames - 1, static_cast<double>(z.end) * k) : frames - 1;
                if (z.loopEnd > z.loopStart && z.loopMode != LoopMode::NoLoop && z.loopMode != LoopMode::OneShot) {
                    lz.loopStart = static_cast<double>(z.loopStart) * k;
                    lz.loopEnd = std::min(frames, static_cast<double>(z.loopEnd + 1) * k);
                    lz.crossfade = std::min({z.loopCrossfade * sr_, lz.loopStart, lz.loopEnd - lz.loopStart});
                }
            }
            const double g = detPow(10.0, z.volume / 20.0);
            const double pan = z.pan / 100.0;
            lz.gainL = g * std::min(1.0, 1.0 - pan);
            lz.gainR = g * std::min(1.0, 1.0 + pan);
            prog->stretches = prog->stretches || z.stretch;
            prog->zones.push_back(std::move(lz));
        }
        if (prog->stretches && !ensureStretchPools()) {
            error = "out of memory for the stretched zones";
            return false;
        }
        program_.offer(prog.release());
        return true;
    }

    double sr_ = 0;
    double p_[kParamCount] = {};
    static constexpr uint32_t kSpareVoices = 8;  // slots for stolen voices fading out
    Voice voices_[kSamplerVoices + kSpareVoices];
    Program* old_ = nullptr;  // a replaced program whose voices are still fading out (audio thread)
    uint32_t counters_[kMaxSamplerZones] = {};
    uint32_t rng_ = 0x9E3779B9u;
    uint64_t clock_ = 0;
    Handover<Program> program_;
    // The stretch pools (control thread builds them once, before the first program that needs them is offered).
    std::unique_ptr<ClipReader[]> readers_;
    std::unique_ptr<HqStretcher[]> hq_;
    int readerOwner_[kStretchReaders] = {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1};
    int hqOwner_[kSamplerStretchers] = {-1, -1, -1, -1};
    double tempo_ = 120;
    static constexpr float kOnes[64] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                                        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
    const float* ones_ = kOnes;
    std::string loaded_;  // control thread: the canonical state JSON
};

ModuleProcessor* makeSampler() noexcept { return new (std::nothrow) SamplerProcessor(); }

}  // namespace

void registerSampler(ModuleRegistry& registry) { registry.add(samplerDescriptor(), &makeSampler); }

void applySamplerProjectState(ModuleProcessor& processor, const ComponentSpec& spec) {
    auto* s = dynamic_cast<SamplerProcessor*>(&processor);
    if (s && spec.hasState) s->projectState(spec.state, spec.stateVersion);
}

}  // namespace caw
