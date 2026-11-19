// Flock (org.caw.flock, 1.1.0): a granular instrument on the shared grain engine, playing a sample from the asset store or a built-in tone, with voices, envelopes, a filter and display data.
#include "builtin_flock.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <new>
#include <string>

#include "asset_store.h"
#include "builtin_effects.h"
#include "caw/detmath.hpp"
#include "caw/display.hpp"
#include "caw/instrument.hpp"
#include "caw/library/envelope.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/grain.hpp"
#include "flock_source.h"
#include "handover.h"
#include "json.h"
#include "project.h"
#include "quality.h"

// Original code (C.A.W. is Apache-2.0). Each voice (a note, up to 16) runs its own grain scheduler into one grain
// pool shared by every voice (64 grains at Eco, 128 at Normal and High: caw/library/grain.hpp), reading the same
// source: a sample from the asset store, read in place and shared as the sampler reads its zones, or with no sample
// one of four built-in tones (synthesised once per process: flock_source.cpp). A voice's grains start `position` of
// the way into the source (plus its scan since the note started, at `scan` times real time, held by `freeze`), moved
// by up to `spray`; each is `size` long, one every 1/`density` (or `sync`), at `pitch` + `keytrack` x (key - `root`)
// semitones plus up to `spread` (quantised to `scale`), backwards by `reverse` chance, panned up to `pan` either way.
// A grain more than an octave up reads the source's half-band mip copy that brings its rate to at most 2 (built off
// the audio thread). Each voice's grains are summed into its own buffer, then through its ADSR, its state-variable
// filter (cutoff moved by its own decaying envelope and by key) and its velocity gain; `glide` slides a new note from
// the last one; `width` scales the side. Everything is decided on a 16-frame grid from the first note, so any block
// size gives the same bits. Seeded by `seed` each time it wakes. No latency.

namespace caw::flock {

namespace {

namespace grain = lib::grain;
constexpr uint32_t kGrid = 16;
constexpr uint32_t kSlots = kVoiceCap + 4;  // spare slots for stolen voices fading out
constexpr uint32_t kDisplayHead = 12, kPerGrain = 5;
// Then (1.1.0) one direction flag per grain shown, in the same order: 1 backwards, 0 forwards.
constexpr uint32_t kDisplayFloats = kDisplayHead + kOverview + (kPerGrain + 1) * grain::kMaxGrains;

constexpr std::string_view kWindows[] = {"Hann", "Tukey", "Gaussian", "Expodec", "Rexpodec"};
constexpr std::string_view kScales[] = {"Off", "Chromatic", "Major", "Minor", "Pentatonic", "Octaves", "Fifths"};
constexpr std::string_view kFilters[] = {"Off", "Low-pass", "High-pass", "Band-pass"};
constexpr std::string_view kBuiltins[] = {"Strings", "Glass", "Breath", "Choir"};

enum P : uint32_t {
    pPosition, pSpray, pSize, pDensity, pSync, pJitter, pPitch, pSpread, pScale, pReverse, pWindow, pPan, pGlide,
    pWidth, pFreeze, pScan, pSeed, pAttack, pDecay, pSustain, pRelease, pFilter, pCutoff, pResonance, pFilterEnv,
    pFilterDecay, pFilterKey, pKeytrack, pRoot, pVelocity, pVoices, pBuiltin, pLevel, pCount
};

const fx::ParamTable& table() {
    static const fx::ParamTable t = [] {
        fx::ParamTable p;
        auto grp = [](ParameterDescriptor& d, const char* g) -> ParameterDescriptor& { d.group = g; return d; };
        grp(p.num("position", "Position", 0.3, 0.0, 1.0), "grains");
        grp(p.num("spray", "Spray", 20.0, 0.0, 500.0, "ms"), "grains");
        grp(p.expo("size", "Size", 90.0, 1.0, 500.0, "ms"), "grains");
        grp(p.expo("density", "Density", 25.0, 0.5, 200.0, "Hz"), "grains");
        grp(p.pick("sync", "Sync", 0.0, fx::kSyncDivisions), "grains");
        grp(p.num("jitter", "Jitter", 0.2, 0.0, 1.0), "grains");
        grp(p.num("pitch", "Pitch", 0.0, -24.0, 24.0, "st"), "grains");
        grp(p.num("spread", "Pitch spread", 0.0, 0.0, 24.0, "st"), "grains");
        grp(p.pick("scale", "Scale", 0.0, kScales), "grains");
        grp(p.num("reverse", "Reverse", 0.0, 0.0, 1.0), "grains");
        grp(p.pick("window", "Window", 0.0, kWindows), "grains");
        grp(p.num("pan", "Pan spread", 0.4, 0.0, 1.0), "grains");
        grp(p.num("glide", "Glide", 0.0, 0.0, 2000.0, "ms"), "grains");
        grp(p.num("width", "Width", 1.0, 0.0, 2.0), "grains");
        grp(p.pick("freeze", "Freeze", 0.0, fx::kOffOn), "grains");
        grp(p.num("scan", "Scan", 0.0, -2.0, 2.0), "grains");
        ParameterDescriptor& seed = grp(p.num("seed", "Seed", 1.0, 0.0, 9999.0), "grains");
        seed.step = 1.0, seed.smoothingFrames = 0;
        grp(p.expo("attack", "Attack", 0.05, 0.001, 10.0, "s"), "amp");
        grp(p.expo("decay", "Decay", 0.5, 0.001, 20.0, "s"), "amp");
        grp(p.num("sustain", "Sustain", 0.8, 0.0, 1.0), "amp");
        grp(p.expo("release", "Release", 0.6, 0.001, 20.0, "s"), "amp");
        grp(p.pick("filter", "Filter", 0.0, kFilters), "filter");
        grp(p.expo("cutoff", "Cutoff", 12000.0, 20.0, 20000.0, "Hz"), "filter");
        grp(p.num("resonance", "Resonance", 0.707, 0.5, 20.0), "filter");
        grp(p.num("filter_env", "Filter env", 0.0, -8.0, 8.0, "oct"), "filter");
        grp(p.expo("filter_decay", "Filter decay", 0.5, 0.01, 20.0, "s"), "filter");
        grp(p.num("filter_key", "Filter key track", 0.0, 0.0, 1.0), "filter");
        grp(p.num("keytrack", "Key track", 1.0, -1.0, 1.0), "voice");
        ParameterDescriptor& root = grp(p.num("root", "Root key", 60.0, 0.0, 127.0), "voice");
        root.step = 1.0, root.smoothingFrames = 0;
        grp(p.num("velocity", "Velocity", 0.7, 0.0, 1.0), "voice");
        ParameterDescriptor& voices = grp(p.num("voices", "Voices", 8.0, 1.0, kVoiceCap), "voice");
        voices.step = 1.0, voices.smoothingFrames = 0;
        ParameterDescriptor& b = grp(p.pick("builtin", "Built-in tone", 0.0, kBuiltins), "voice");
        b.automatable = b.modulatable = b.midiMappable = false;  // which tone the grains read: chosen by hand
        grp(p.num("level", "Level", 0.0, -48.0, 12.0, "dB"), "voice");
        return p;
    }();
    return t;
}

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

const ModuleDescriptor& descriptorOf() {
    static const ModuleDescriptor d = [] {
        static_assert(pCount == 33);
        ModuleDescriptor m;
        m.id = kFlockId;
        m.name = "Flock";
        m.role = ModuleRole::Instrument;
        m.ports = kPorts;
        m.portCount = 2;
        m.parameters = table().data();
        m.parameterCount = static_cast<uint32_t>(table().size());
        m.tailFrames = 192000 * 21;  // a 20 s release and a last grain
        m.maxStateBytes = kMaxStateBytes;
        m.cpuClass = CpuClass::Medium;
        return m;
    }();
    return d;
}

// The sample the project names, as the audio thread takes it (null source: the built-in tone).
struct Loaded {
    std::shared_ptr<const Source> source;
    bool missing = false;  // a sample was named but could not be loaded
};

// The state: {"path": "<sample file>"} (empty or absent: none). False with `error` for anything else.
bool parseState(std::string_view text, std::string& path, std::string& error) {
    path.clear();
    if (text.empty()) return true;
    if (text.size() > kMaxStateBytes) {
        error = "Flock's state is too large";
        return false;
    }
    Json j;
    if (!parseJson(text, j, error)) return false;
    if (j.type != Json::Type::Object) {
        error = "Flock's state must be {\"path\": ...}";
        return false;
    }
    if (const Json* p = j.get("path"); p && p->type != Json::Type::Null) {
        if (p->type != Json::Type::String || p->str.size() > 4096) {
            error = "Flock's path must be a string of at most 4096 bytes";
            return false;
        }
        path = p->str;
    }
    return true;
}
std::string stateJson(const std::string& path) { return path.empty() ? std::string("{}") : "{\"path\":\"" + jsonEscape(path) + "\"}"; }

inline double clampd(double x, double lo, double hi) noexcept { return x >= lo ? (x <= hi ? x : hi) : lo; }  // NaN: lo

struct Voice {
    bool active = false, held = false, off = false;
    uint32_t noteId = 0;
    uint64_t age = 0;
    double pitch = 60;      // the note (with bend)
    double semis = 0;       // the grains' centre pitch now (gliding)
    double next = 0;        // frames to this voice's next grain
    double scan = 0;        // how far its position has scanned, 0..1 of the source
    double gain = 1;        // velocity
    double fenv = 1;        // the filter's envelope (1 at the note, decaying)
    double kill = 1, killStep = 0;
    lib::Adsr amp;
    lib::Svf fl, fr;
};

class Flock final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return descriptorOf(); }

    bool activate(double sampleRate, uint32_t) noexcept override {
        sr_ = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
        quality_ = buildingQuality();
        try {
            for (uint32_t k = 0; k < kBuiltinCount; ++k) {
                builtin_[k] = builtinSource(static_cast<int>(k), sr_);
                if (!builtin_[k]) return false;
            }
            if (!path_.empty() || stateLoaded_) build();
        } catch (...) {
            return false;
        }
        displayClock_.prepare(sr_);
        reset();
        return true;
    }
    void reset() noexcept override {
        for (Voice& v : voices_) v = Voice{};
        eng_.clear();
        settled_ = true;
        left_ = 0;
        silent_ = 0;
        peak_ = 0;
        levelFresh_ = true;
        lastPitch_ = -1;
        clock_ = 0;
        display_.clear();
    }
    bool quiet() const noexcept override { return settled_; }
    uint32_t readDisplay(float* out, uint32_t max) const noexcept override { return display_.read(out, max); }

    uint32_t stateVersion() const noexcept override { return 1; }
    bool saveState(uint8_t* dst, uint32_t capacity, uint32_t& written) const noexcept override {
        written = 0;
        if (!stateLoaded_) return true;
        try {
            const std::string s = stateJson(path_);
            if (s.size() > capacity) return false;
            std::memcpy(dst, s.data(), s.size());
            written = static_cast<uint32_t>(s.size());
            return true;
        } catch (...) {
            return false;
        }
    }
    bool loadState(const uint8_t* src, uint32_t size, uint32_t version) noexcept override {
        if (version != 1) return false;
        try {
            std::string path, error;
            if (!parseState(std::string_view(reinterpret_cast<const char*>(src), size), path, error)) return false;
            path_ = path;
            stateLoaded_ = true;
            if (sr_ > 0) build();
            return true;
        } catch (...) {
            return false;
        }
    }
    // Control thread: the project's state, when it names another sample than what plays.
    void projectState(const std::vector<uint8_t>& state, uint32_t version) noexcept {
        try {
            std::string path, error;
            if (!parseState(std::string_view(reinterpret_cast<const char*>(state.data()), state.size()), path, error)) return;
            if (path != path_ || !stateLoaded_) loadState(state.data(), static_cast<uint32_t>(state.size()), version);
        } catch (...) {
        }
    }

protected:
    void beginBlock(const ProcessBlock& b) noexcept override {
        block_ = &b;
        if (loaded_.poll()) {  // a new sample: the grains reading the old source end (it is freed off this thread)
            eng_.clear();
            source_ = source();
        }
        tempo_ = b.transport && b.transport->tempo > 0 && std::isfinite(b.transport->tempo) ? b.transport->tempo : 120.0;
    }

    void onNote(const NoteMessage& m) noexcept override {
        switch (m.type) {
            case NoteMessageType::On: {
                if (settled_) {  // waking: the grid starts at this note, the knobs are read here and the cloud reseeded
                    settled_ = false;
                    control(m.frame, true);
                    left_ = kGrid;
                }
                start(m);
                break;
            }
            case NoteMessageType::Off:
                for (Voice& v : voices_)
                    if (v.active && v.held && v.noteId == m.noteId) {
                        v.held = false, v.off = true;
                        v.amp.gateOff();
                    }
                break;
            case NoteMessageType::Pitch:
                for (Voice& v : voices_)
                    if (v.active && v.noteId == m.noteId && std::isfinite(m.pitch)) v.pitch = m.pitch;
                break;
            default:
                break;
        }
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock&) noexcept override {
        uint32_t done = 0;
        while (done < frames) {
            if (settled_) {
                std::fill(left + done, left + frames, 0.0f);
                std::fill(right + done, right + frames, 0.0f);
                left_ = 0;
                break;
            }
            if (left_ == 0) {
                control(offset + done, false);
                left_ = kGrid;
            }
            const uint32_t n = std::min(left_, frames - done);
            chunk(left + done, right + done, n);
            left_ -= n;
            clock_ += n;
            if (left_ == 0) endPeriod();
            done += n;
        }
        if (displayClock_.tick(frames)) publish();
    }

private:
    double param(uint32_t k, uint32_t at) const noexcept {
        return block_ ? parameterAt(*block_, k, at, table().data()[k].defaultValue) : table().data()[k].defaultValue;
    }

    // Control thread: the named sample's source, handed to the audio thread.
    void build() {
        auto l = std::make_unique<Loaded>();
        if (!path_.empty()) {
            std::string why;
            std::shared_ptr<const AudioAsset> a = AssetStore::global().load(path_, sr_, why);
            l->source = a ? sampleSource(a) : nullptr;
            l->missing = !l->source;
        }
        loaded_.offer(l.release());
    }

    const Source* source() const noexcept {
        const Loaded* l = loaded_.current();
        if (l && l->source) return l->source.get();
        return builtin_[builtinKind_].get();
    }

    void control(uint32_t at, bool waking) noexcept {
        const int q = qualityNow(quality_);
        eng_.setCap(grain::flockCap(q));
        hermite_ = q > 0;
        const int kind = static_cast<int>(clampd(std::floor(param(pBuiltin, at) + 0.5), 0, kBuiltinCount - 1));
        builtinKind_ = kind;
        const Source* src = source();
        if (src != source_) {
            if (source_) eng_.clear();  // the old source's grains end (positions are its frames)
            source_ = src;
        }
        const double len = source_->levels[0].length;
        st_.levels = source_->mips;
        st_.fit = true;
        position_ = clampd(param(pPosition, at), 0.0, 1.0);
        st_.sprayFrames = clampd(param(pSpray, at), 0.0, 500.0) * 0.001 * sr_;
        st_.sizeFrames = clampd(param(pSize, at), 1.0, 500.0) * 0.001 * sr_;
        const int sync = static_cast<int>(clampd(std::floor(param(pSync, at) + 0.5), 0, fx::kSyncCount - 1));
        st_.interval = sync == 0 ? sr_ / clampd(param(pDensity, at), 0.5, 200.0)
                                 : std::max(1.0, fx::kSyncWholeNotes[sync] * 240.0 / tempo_ * sr_);
        st_.jitter = clampd(param(pJitter, at), 0.0, 1.0);
        pitchKnob_ = clampd(param(pPitch, at), -24.0, 24.0);
        st_.pitchSpread = clampd(param(pSpread, at), 0.0, 24.0);
        st_.scale = static_cast<uint32_t>(clampd(std::floor(param(pScale, at) + 0.5), 0, 6));
        st_.reverse = clampd(param(pReverse, at), 0.0, 1.0);
        st_.window = static_cast<uint32_t>(clampd(std::floor(param(pWindow, at) + 0.5), 0, 4));
        st_.panSpread = clampd(param(pPan, at), 0.0, 1.0);
        const double glide = clampd(param(pGlide, at), 0.0, 2000.0) * 0.001;
        glideK_ = glide <= 0.0 ? 1.0 : 1.0 - detExp(-static_cast<double>(kGrid) / (glide * sr_));
        width_ = static_cast<float>(clampd(param(pWidth, at), 0.0, 2.0));
        freeze_ = param(pFreeze, at) >= 0.5;
        scanRate_ = clampd(param(pScan, at), -2.0, 2.0);
        attack_ = clampd(param(pAttack, at), 0.001, 10.0);
        decay_ = clampd(param(pDecay, at), 0.001, 20.0);
        sustain_ = clampd(param(pSustain, at), 0.0, 1.0);
        release_ = clampd(param(pRelease, at), 0.001, 20.0);
        filter_ = static_cast<int>(clampd(std::floor(param(pFilter, at) + 0.5), 0, 3));
        cutoff_ = clampd(param(pCutoff, at), 20.0, 20000.0);
        resonance_ = clampd(param(pResonance, at), 0.5, 20.0);
        filterEnv_ = clampd(param(pFilterEnv, at), -8.0, 8.0);
        fenvK_ = detExp(-static_cast<double>(kGrid) / (clampd(param(pFilterDecay, at), 0.01, 20.0) * sr_));
        filterKey_ = clampd(param(pFilterKey, at), 0.0, 1.0);
        keytrack_ = clampd(param(pKeytrack, at), -1.0, 1.0);
        root_ = clampd(std::floor(param(pRoot, at) + 0.5), 0.0, 127.0);
        velocity_ = clampd(param(pVelocity, at), 0.0, 1.0);
        cap_ = static_cast<uint32_t>(clampd(std::floor(param(pVoices, at) + 0.5), 1, kVoiceCap));
        const double g = lib::dbToGain(clampd(param(pLevel, at), -48.0, 12.0));
        if (levelFresh_) level_ = g, levelFresh_ = false;
        levelStep_ = (g - level_) / kGrid;
        // Each grain's level (as Murmur's): grains that line up add as amplitudes, decorrelated ones as powers.
        const double overlap = std::max(1.0, grain::windows().mean[st_.window] * st_.sizeFrames / st_.interval);
        const double decor = clampd(2.0 * st_.sprayFrames / st_.sizeFrames + st_.pitchSpread / 6.0 + 0.5 * st_.jitter, 0.0, 1.0);
        st_.gain = static_cast<float>(detPow(overlap, -(1.0 - 0.5 * decor)));
        if (waking) eng_.seed(static_cast<uint32_t>(clampd(std::floor(param(pSeed, at) + 0.5), 0.0, 9999.0)));
        // Each voice: its pitch glides, its scan moves, its filter follows, and it schedules its next grains.
        const double scanStep = freeze_ ? 0.0 : scanRate_ * kGrid / std::max(1.0, len - 1.0);  // scan 1: real time
        for (uint32_t s = 0; s < kSlots; ++s) {
            Voice& v = voices_[s];
            if (!v.active) continue;
            v.amp.set(attack_, decay_, sustain_, release_, sr_);
            v.semis += (target(v) - v.semis) * glideK_;
            v.scan += scanStep;
            v.scan -= std::floor(v.scan);
            if (filter_ > 0) {
                const double fc = cutoff_ * detPow(2.0, filterEnv_ * v.fenv + filterKey_ * (v.pitch - 60.0) / 12.0);
                v.fl.set(clampd(fc, 20.0, 0.45 * sr_), resonance_, sr_);
                v.fr.set(clampd(fc, 20.0, 0.45 * sr_), resonance_, sr_);
            }
            v.fenv *= fenvK_;
            if (v.killStep == 0) schedule(v, s, kGrid);
        }
    }

    double target(const Voice& v) const noexcept { return pitchKnob_ + keytrack_ * (v.pitch - root_); }

    void schedule(Voice& v, uint32_t slot, uint32_t frames) noexcept {
        grain::Settings st = st_;
        double pos = position_ + v.scan;
        pos -= std::floor(pos);
        st.position = pos;
        st.pitch = clampd(v.semis, -48.0, 48.0);
        eng_.schedule(source_->levels[0], st, frames, v.next, static_cast<uint8_t>(slot));
    }

    void fadeOut(Voice& v) noexcept {
        v.held = false;
        if (v.killStep == 0) v.killStep = 1.0 / std::max(1.0, 0.005 * sr_);
    }

    void start(const NoteMessage& m) noexcept {
        if (!std::isfinite(m.pitch)) return;
        // Over the voice cap: the oldest released voice fades out, else the oldest.
        uint32_t sounding = 0;
        Voice *oldest = nullptr, *oldestOff = nullptr, *spare = nullptr, *oldestFading = nullptr;
        for (Voice& v : voices_) {
            if (!v.active) {
                if (!spare) spare = &v;
            } else if (v.killStep > 0) {
                if (!oldestFading || v.age < oldestFading->age) oldestFading = &v;
            } else {
                ++sounding;
                if (v.off) {
                    if (!oldestOff || v.age < oldestOff->age) oldestOff = &v;
                } else if (!oldest || v.age < oldest->age) {
                    oldest = &v;
                }
            }
        }
        Voice* victim = nullptr;
        if (sounding >= cap_) {
            victim = oldestOff ? oldestOff : oldest;
            if (victim) fadeOut(*victim);
        }
        Voice* pick = spare ? spare : (oldestFading ? oldestFading : victim);
        if (!pick) return;
        const uint32_t slot = static_cast<uint32_t>(pick - voices_);
        eng_.endVoice(static_cast<uint8_t>(slot));
        Voice& v = *pick;
        v = Voice{};
        v.active = v.held = true;
        v.noteId = m.noteId;
        v.age = ++age_;
        v.pitch = m.pitch;
        const double vel = clampd(m.velocity, 0.0, 1.0);
        v.gain = (1.0 - velocity_) + velocity_ * vel * vel;
        const double from = lastPitch_ >= 0 && glideK_ < 1.0 ? lastPitch_ : m.pitch;
        lastPitch_ = m.pitch;
        v.semis = pitchKnob_ + keytrack_ * (from - root_);
        v.amp.set(attack_, decay_, sustain_, release_, sr_);
        v.amp.gateOn();
        if (filter_ > 0) {
            const double fc = cutoff_ * detPow(2.0, filterEnv_ + filterKey_ * (v.pitch - 60.0) / 12.0);
            v.fl.set(clampd(fc, 20.0, 0.45 * sr_), resonance_, sr_);
            v.fr.set(clampd(fc, 20.0, 0.45 * sr_), resonance_, sr_);
        }
        // Its first grains start now, in what is left of this control period (at the period's end, the next
        // control point schedules them).
        if (left_ > 0) schedule(v, slot, left_);
    }

    void chunk(float* left, float* right, uint32_t n) noexcept {
        float bl[kSlots][kGrid], br[kSlots][kGrid];
        float* pl[kSlots];
        float* pr[kSlots];
        for (uint32_t s = 0; s < kSlots; ++s) {
            if (voices_[s].active) std::fill_n(bl[s], n, 0.0f), std::fill_n(br[s], n, 0.0f);  // grains: active voices'
            pl[s] = bl[s], pr[s] = br[s];
        }
        if (hermite_) eng_.renderVoices<true>(source_->levels, pl, pr, n);
        else eng_.renderVoices<false>(source_->levels, pl, pr, n);
        float ml[kGrid] = {}, mr[kGrid] = {};
        for (uint32_t s = 0; s < kSlots; ++s) {
            Voice& v = voices_[s];
            if (!v.active) continue;
            double env[kGrid];
            v.amp.run(env, n);
            if (v.killStep > 0)
                for (uint32_t i = 0; i < n; ++i) {
                    v.kill = std::max(0.0, v.kill - v.killStep);
                    env[i] *= v.kill;
                }
            if (filter_ == 0) {
                for (uint32_t i = 0; i < n; ++i) {
                    const double e = env[i] * v.gain;
                    ml[i] += static_cast<float>(bl[s][i] * e);
                    mr[i] += static_cast<float>(br[s][i] * e);
                }
                continue;
            }
            for (uint32_t i = 0; i < n; ++i) {
                const double e = env[i] * v.gain;
                const SvfOutputSel o = sel(v.fl.process(bl[s][i] * e), v.fr.process(br[s][i] * e));
                ml[i] += static_cast<float>(o.l);
                mr[i] += static_cast<float>(o.r);
            }
        }
        float peak = 0;
        const float side = width_;
        for (uint32_t i = 0; i < n; ++i) {
            const float m = 0.5f * (ml[i] + mr[i]), s = 0.5f * side * (ml[i] - mr[i]);
            level_ += levelStep_;
            const float g = static_cast<float>(level_);
            float l = (m + s) * g, r = (m - s) * g;
            if (!std::isfinite(l)) l = 0;
            if (!std::isfinite(r)) r = 0;
            left[i] = l, right[i] = r;
            peak = std::max(peak, std::max(std::fabs(l), std::fabs(r)));
        }
        peak_ = std::max(peak_, peak);
    }

    struct SvfOutputSel {
        double l, r;
    };
    SvfOutputSel sel(const lib::SvfOutput& a, const lib::SvfOutput& b) const noexcept {
        if (filter_ == 1) return {a.low, b.low};
        if (filter_ == 2) return {a.high, b.high};
        return {a.band, b.band};
    }

    // At the end of each control period: voices that faded or released to silence end (with their grains); with
    // nothing sounding, every state goes back to rest.
    void endPeriod() noexcept {
        eng_.retire();
        bool any = false;
        for (uint32_t s = 0; s < kSlots; ++s) {
            Voice& v = voices_[s];
            if (!v.active) continue;
            const bool done = (v.killStep > 0 && v.kill <= 0.0) || (v.off && v.amp.level() < 1e-5) || !std::isfinite(v.amp.level());
            if (done) {
                v.active = false;
                eng_.endVoice(static_cast<uint8_t>(s));
            } else {
                any = true;
            }
        }
        if (any) {
            silent_ = 0;
            return;
        }
        eng_.clear();
        if ((silent_ += kGrid) >= 0.05 * sr_) {
            settled_ = true;
            silent_ = 0;
            clock_ = 0;
            lastPitch_ = -1;
        }
    }

    void publish() noexcept {
        float out[kDisplayFloats];
        const Source* src = source_ ? source_ : source();
        const Loaded* l = loaded_.current();
        uint32_t sounding = 0;
        for (const Voice& v : voices_) sounding += v.active && v.killStep == 0 ? 1 : 0;
        out[0] = 1;  // layout version
        uint32_t shown = 0;
        for (uint32_t g = 0; g < eng_.alive(); ++g) shown += eng_.grain(g).left > 0 ? 1 : 0;
        out[1] = static_cast<float>(shown);
        out[2] = static_cast<float>(eng_.cap());
        out[3] = static_cast<float>(eng_.takeDropped());
        out[4] = static_cast<float>(sounding);
        out[5] = src && src->builtin >= 0 ? static_cast<float>(src->builtin + 1) : 0.0f;
        out[6] = l && l->missing ? 1.0f : 0.0f;
        out[7] = src ? static_cast<float>(src->seconds) : 0.0f;
        out[8] = static_cast<float>(position_);
        out[9] = static_cast<float>(1000.0 * st_.sizeFrames / sr_);
        out[10] = static_cast<float>(lib::gainToDb(peak_));
        peak_ = 0;
        out[11] = static_cast<float>(shown);
        for (uint32_t b = 0; b < kOverview; ++b) out[kDisplayHead + b] = src ? src->overview[b] : 0.0f;
        const double len = src ? std::max<double>(1.0, src->levels[0].length) : 1.0;
        for (uint32_t g = 0, k = 0; g < eng_.alive(); ++g) {
            const grain::Grain& x = eng_.grain(g);
            if (x.left == 0) continue;
            float* o = out + kDisplayHead + kOverview + kPerGrain * k++;
            o[0] = static_cast<float>(clampd(x.pos * static_cast<double>(1u << x.level) / len, 0.0, 1.0));
            o[1] = static_cast<float>(x.phase);
            o[2] = x.pan;
            o[3] = x.semitones;
            o[4] = static_cast<float>(x.voice);
        }
        // The direction block after the grains (appended, so the grains' indices keep their meaning).
        float* dir = out + kDisplayHead + kOverview + kPerGrain * shown;
        for (uint32_t g = 0, k = 0; g < eng_.alive(); ++g) {
            const grain::Grain& x = eng_.grain(g);
            if (x.left == 0) continue;
            dir[k++] = (x.fstep != 0 ? x.fstep < 0 : x.rate < 0.0) ? 1.0f : 0.0f;
        }
        display_.publish(out, kDisplayHead + kOverview + (kPerGrain + 1) * shown);
    }

    const ProcessBlock* block_ = nullptr;
    const std::atomic<int>* quality_ = nullptr;
    double sr_ = 0;
    std::shared_ptr<const Source> builtin_[kBuiltinCount];
    Handover<Loaded> loaded_;
    const Source* source_ = nullptr;
    int builtinKind_ = 0;
    std::string path_;          // control thread: the sample the state names
    bool stateLoaded_ = false;  // a state was loaded (saved back as it came)
    grain::Engine eng_;
    grain::Settings st_;
    Voice voices_[kSlots];
    uint64_t age_ = 0, clock_ = 0;
    double tempo_ = 120, position_ = 0.3, pitchKnob_ = 0, glideK_ = 1, scanRate_ = 0;
    double attack_ = 0.05, decay_ = 0.5, sustain_ = 0.8, release_ = 0.6;
    int filter_ = 0;
    double cutoff_ = 12000, resonance_ = 0.707, filterEnv_ = 0, fenvK_ = 1, filterKey_ = 0;
    double keytrack_ = 1, root_ = 60, velocity_ = 0.7, lastPitch_ = -1;
    uint32_t cap_ = 8;
    double level_ = 1, levelStep_ = 0;
    bool levelFresh_ = true, freeze_ = false, hermite_ = true, settled_ = true;
    float width_ = 1.0f, peak_ = 0;
    uint32_t left_ = 0;
    uint64_t silent_ = 0;
    DisplayClock displayClock_;
    DisplayBuffer<kDisplayFloats> display_;
};

ModuleProcessor* make() noexcept { return new (std::nothrow) Flock(); }

}  // namespace

void registerFlock(ModuleRegistry& registry) {
    (void)grain::windows();
    registry.add(descriptorOf(), &make);
}

size_t instanceBytes() noexcept { return sizeof(Flock); }

void applyProjectState(ModuleProcessor& processor, const ComponentSpec& spec) {
    auto* f = dynamic_cast<Flock*>(&processor);
    if (f && spec.hasState) f->projectState(spec.state, spec.stateVersion);
}

}  // namespace caw::flock
