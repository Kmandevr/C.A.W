// Control thread: params, modulation, notes, Device MIDI, transport, tempo and signatures, meters, taps and scope.
#include "engine_impl.h"

namespace caw {

// ===================== control thread =====================

bool Engine::setSend(const std::string& layerId, uint32_t index, double level, bool pre, bool mute) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = layers_.find(layerId);
    if (it == layers_.end() || it->second.slot < 0 || index >= static_cast<uint32_t>(it->second.userSends)) return false;
    LayerState& ls = it->second;
    LayerState::Route& r = ls.routes[index];
    r.level = std::isfinite(level) ? std::clamp(level, 0.0, kMaxMixGain) : 0.0;
    r.pre = pre;
    r.mute = mute;
    if (index >= ls.routesSent.size()) return false;
    Cmd c;
    c.type = Cmd::SetSendLevel;
    c.slot = ls.slot;
    c.order = static_cast<int>(index);
    c.master = r.level;
    c.flag = r.pre;
    c.sendMute = r.mute;
    if (!send(c)) return false;
    ls.routesSent[index] = r;
    return true;
}

bool Engine::setComponentParam(const std::string& layerId, uint32_t index, const std::string& param, double value) {
    std::lock_guard<std::mutex> lock(ctl_);
    if (index != kInstrumentIndex && (index & kNoteComponentFlag))  // per-note FX (#127): every slot
        return noteFx_->setParam(layerId, index & ~kNoteComponentFlag, param, value);
    ComponentChain* chain = ctlComponentChain(layerId, index);
    if (!chain) return false;
    const uint64_t before = chain->latencyFrames();
    if (!chain->setValue(index, param, value)) return false;
    if (chain->latencyFrames() != before) {  // a look-ahead turned on or off: everything else moves to stay in time
        std::map<std::string, std::vector<std::string>> warnings;
        updateCompensation(warnings);
    }
    return true;
}

bool Engine::setComponentBypass(const std::string& layerId, uint32_t index, bool bypass) {
    std::lock_guard<std::mutex> lock(ctl_);
    if (index != kInstrumentIndex && (index & kNoteComponentFlag)) {  // per-note FX (#127): every slot
        if (!noteFx_->setBypass(layerId, index & ~kNoteComponentFlag, bypass)) return false;
        std::map<std::string, std::vector<std::string>> warnings;
        updateCompensation(warnings);
        return true;
    }
    ComponentChain* chain = ctlComponentChain(layerId, index);
    if (!chain || !chain->setBypass(index, bypass)) return false;
    std::map<std::string, std::vector<std::string>> warnings;
    updateCompensation(warnings);  // a bypassed effect adds no latency
    return true;
}

std::string Engine::componentStatesJson(const std::string& layerId) {
    std::lock_guard<std::mutex> lock(ctl_);
    uint32_t insertsIndex = 0, instrumentIndex = kInstrumentIndex;
    ComponentChain* chain = ctlComponentChain(layerId, insertsIndex);
    ComponentChain* instrument = ctlComponentChain(layerId, instrumentIndex);
    if (!chain && !instrument) return R"({"ok":false,"error":"no native components run there","components":[]})";
    std::string j = R"({"ok":true,"components":[)";
    bool first = true;
    auto add = [&](const ComponentChain::SavedState& state, uint64_t index) {
        j += std::string(first ? "" : ",") + "{\"index\":" + std::to_string(index) + ",\"ok\":" + (state.ok ? "true" : "false") +
             ",\"version\":" + std::to_string(state.version) + ",\"state\":\"" +
             base64Encode(state.data.data(), state.data.size()) + "\"}";
        first = false;
    };
    if (chain) {
        const std::vector<ComponentChain::SavedState> states = chain->saveStates();
        for (size_t i = 0; i < states.size(); ++i) add(states[i], i);
    }
    if (instrument)
        for (const ComponentChain::SavedState& state : instrument->saveStates()) {
            add(state, instrumentIndex == 0 ? kInstrumentIndex : kMidiComponentFlag | (instrumentIndex - 1));
            ++instrumentIndex;  // the instrument, then its MIDI effects
        }
    return j + "]}";
}

bool Engine::setComponentState(const std::string& layerId, uint32_t index, const uint8_t* data, size_t size,
                               uint32_t version) {
    if (size > 0 && !data) return false;
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    const bool instrument = index == kInstrumentIndex || (!(index & kNoteComponentFlag) && (index & kMidiComponentFlag));
    uint32_t at = index;
    ComponentChain* old = ctlComponentChain(layerId, at);
    if (!old) return false;
    LayerState* ls = nullptr;
    if (!layerId.empty()) {
        auto it = layers_.find(layerId);
        if (it == layers_.end() || it->second.slot < 0) return false;
        ls = &it->second;
    }
    std::vector<ComponentSpec> specs = old->currentSpecs();
    if (at >= specs.size()) return false;
    ComponentSpec& spec = specs[at];
    spec.lenient = false;  // this one must take the new state; the others keep theirs as a rebuild does
    spec.hasState = true;
    spec.stateVersion = version;
    spec.state.assign(data, data + size);
    std::string error;
    const BuildingQuality building(&quality_);
    const BuildingLiveAudio buildingInput(audioIn_.get());
    auto chain = instrument
                     ? ComponentChain::buildInstrument(nativeModules_, specs.front(), sr_, error, {specs.begin() + 1, specs.end()})
                     : ComponentChain::build(nativeModules_, specs, sr_, error);
    if (!chain) return false;
    delete chain->swapAutomation(chain->automationFor(ctlAutomation_, layerId).release());
    Cmd c;
    c.type = !ls ? Cmd::SetMasterChain : instrument ? Cmd::SetInstrument : Cmd::SetInserts;
    c.slot = ls ? ls->slot : -1;
    ComponentChain* sent = chain.release();
    c.masterChain = sent;
    if (!send(c)) return false;  // send() freed it; the old chain plays on
    if (ls) (instrument ? ls->instrument : ls->inserts) = sent;
    else ctlMasterChain_ = sent;
    std::map<std::string, std::vector<std::string>> warnings;
    updateCompensation(warnings);
    return true;
}

int32_t Engine::componentDisplay(const std::string& layerId, uint32_t index, float* out, uint32_t max) {
    // Never waits: a UI polls this every frame, and a project update can hold ctl_ for a while (it then shows
    // its last picture). The chains themselves are read without locks (DisplayBuffer).
    std::unique_lock<std::mutex> lock(ctl_, std::try_to_lock);
    if (!lock.owns_lock()) return 0;
    if (index != kInstrumentIndex && (index & kNoteComponentFlag))  // per-note FX (#127): the newest note's slot
        return noteFx_->readDisplay(layerId, index & ~kNoteComponentFlag, out, max);
    ComponentChain* chain = ctlComponentChain(layerId, index);
    if (!chain) return -1;
    return chain->readDisplay(index, out, max);
}

bool Engine::setComponentAutoGain(const std::string& layerId, uint32_t index, bool on) {
    std::lock_guard<std::mutex> lock(ctl_);
    if (index == kInstrumentIndex || (index & kNoteComponentFlag)) return false;
    ComponentChain* chain = ctlComponentChain(layerId, index);
    return chain && chain->setAutoGain(index, on);
}

int32_t Engine::componentAutoGain(const std::string& layerId, uint32_t index, float& db) {
    std::unique_lock<std::mutex> lock(ctl_, std::try_to_lock);  // a UI polls it: never waits
    if (!lock.owns_lock()) return 0;
    if (index == kInstrumentIndex || (index & kNoteComponentFlag)) return -1;
    ComponentChain* chain = ctlComponentChain(layerId, index);
    return chain && chain->autoGainDb(index, db) ? 1 : -1;
}

int32_t Engine::componentMeter(const std::string& layerId, uint32_t index, float& peakL, float& peakR, bool& clipped) {
    std::unique_lock<std::mutex> lock(ctl_, std::try_to_lock);  // a UI polls it: never waits
    if (!lock.owns_lock()) return 0;
    if (index != kInstrumentIndex && (index & kNoteComponentFlag)) return -1;
    ComponentChain* chain = ctlComponentChain(layerId, index);
    return chain && chain->readSlotMeter(index, peakL, peakR, clipped) ? 1 : -1;
}

int32_t Engine::componentCost(const std::string& layerId, uint32_t index, double& share, uint32_t& latency, bool& armed) {
    std::unique_lock<std::mutex> lock(ctl_, std::try_to_lock);  // a UI polls it: never waits
    if (!lock.owns_lock()) return 0;
    if (index != kInstrumentIndex && (index & kNoteComponentFlag)) return -1;
    ComponentChain* chain = ctlComponentChain(layerId, index);
    if (!chain || !chain->readSlotCost(index, share, latency)) return -1;
    armed = chain->slotArmed(index);
    return 1;
}

bool Engine::setModulatorParam(const std::string& modulatorId, const std::string& param, double value) {
    std::lock_guard<std::mutex> lock(ctl_);
    return modulation_->setModulatorParam(modulatorId, param, value);
}

bool Engine::setModulatorBypass(const std::string& modulatorId, bool bypass) {
    std::lock_guard<std::mutex> lock(ctl_);
    return modulation_->setModulatorBypass(modulatorId, bypass);
}

bool Engine::setModulationAmount(uint32_t linkId, double amount) {
    std::lock_guard<std::mutex> lock(ctl_);
    const bool perNote = noteFx_->setLinkAmount(linkId, amount);  // a note-source link (#127)
    return modulation_->setLinkAmount(linkId, amount) || perNote;
}

bool Engine::noteFxStats(const std::string& layerId, NoteFxStats& out) {
    std::unique_lock<std::mutex> lock(ctl_, std::try_to_lock);  // a UI polls it: never waits
    return lock.owns_lock() && noteFx_->stats(layerId, out);
}

int32_t Engine::modulatorOutputs(const std::string& modulatorId, float* out, int32_t max) {
    std::unique_lock<std::mutex> lock(ctl_, std::try_to_lock);  // a UI polls it: never waits
    if (!lock.owns_lock()) return 0;
    return modulation_->outputs(modulatorId, out, max);
}

bool Engine::modulationOffset(uint32_t linkId, float& out) {
    std::unique_lock<std::mutex> lock(ctl_, std::try_to_lock);
    return lock.owns_lock() && modulation_->linkOffset(linkId, out);
}

void Engine::setLayerMix(const std::string& layerId, double volume, double pan, bool mute, bool solo) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = layers_.find(layerId);
    if (it == layers_.end() || it->second.slot < 0) return;
    LayerState& ls = it->second;
    ls.volume = std::isfinite(volume) ? std::clamp(volume, 0.0, kMaxMixGain) : 0.0;
    ls.pan = std::min(1.0, std::max(-1.0, pan));
    ls.mute = mute;
    ls.solo = solo;
    writeMix(ls.slot, ls.volume, ls.pan, mute, solo);
}

int Engine::noteOn(const std::string& layerId, int32_t id, double pitch, double velocity) {
    std::lock_guard<std::mutex> lock(ctl_);
    if (!layerId.empty() && layerId[0] == '\x01') return -1;  // the audition's internal layer: its slot moves on a grow
    auto it = layers_.find(layerId);
    if (it == layers_.end() || it->second.slot < 0) return -1;
    Cmd c;
    c.type = Cmd::Preview;
    c.previewOp = 0;
    c.slot = it->second.slot;
    c.previewId = id;
    c.pitch = std::isfinite(pitch) ? std::clamp(pitch, 0.0, 127.0) : 60.0;
    c.vel = std::isfinite(velocity) ? std::clamp(velocity, 0.0, 1.0) : 1.0;
    // A new note on the same id elsewhere ends the old one there first.
    auto old = previewSlots_.find(id);
    if (old != previewSlots_.end() && old->second != c.slot) {
        Cmd off = c;
        off.previewOp = 2;
        off.slot = old->second;
        if (!send(off)) return 0;  // the queue is full: keep the old note's entry, so its off can still reach it
    }
    if (!send(c)) return 0;
    previewSlots_[id] = c.slot;
    return 1;
}

int Engine::notePitch(int32_t id, double pitch) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = previewSlots_.find(id);
    if (it == previewSlots_.end() || !std::isfinite(pitch)) return -1;
    Cmd c;
    c.type = Cmd::Preview;
    c.previewOp = 1;
    c.slot = it->second;
    c.previewId = id;
    c.pitch = std::clamp(pitch, 0.0, 127.0);
    return send(c) ? 1 : 0;
}

int Engine::noteOff(int32_t id) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = previewSlots_.find(id);
    if (it == previewSlots_.end()) return -1;
    Cmd c;
    c.type = Cmd::Preview;
    c.previewOp = 2;
    c.slot = it->second;
    c.previewId = id;
    if (!send(c)) return 0;  // a full queue keeps the entry, so a later off still ends the note
    previewSlots_.erase(it);
    return 1;
}

int Engine::notesOff() {
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::Preview;
    c.previewOp = 3;
    if (!send(c)) return 0;
    previewSlots_.clear();
    return 1;
}

// ---- Device MIDI (API 15) ----

bool Engine::queueDeviceMidi(int slot, Midi2Event e, int64_t timeNs) noexcept {
    e.target = slot;
    e.timeNs = timeNs;
    return midiIn_.push(e);
}

// The layer's slot, or -1. Briefly under ctl_, as a preview's note on.
int Engine::deviceSlot(const std::string& id) {
    std::lock_guard<std::mutex> lock(ctl_);
    if (id.empty() || id[0] == '\x01') return -1;
    auto it = layers_.find(id);
    return it == layers_.end() ? -1 : it->second.slot;
}

int Engine::midiUmp(const std::string& layerId, const uint32_t* words, int count, int64_t timeNs) {
    if (!words || count <= 0) return 0;
    const int slot = deviceSlot(layerId);
    if (slot < 0) return 0;
    if (timeNs <= 0) timeNs = midiClockNs();
    std::lock_guard<std::mutex> lock(midiPush_);
    int queued = 0;
    for (int i = 0; i < count;) {
        const int n = umpWordCount(words[i]);
        if (i + n > count) break;  // a message cut short
        uint32_t w[2] = {words[i], n > 1 ? words[i + 1] : 0u};
        i += n;
        if ((w[0] >> 28) == 0x2 && !ump1ToUmp2(w[0], w)) continue;
        Midi2Event e;
        if (!decodeMidi2ChannelVoice(w[0], w[1], e)) continue;  // utility, system, SysEx, flex data: not for notes
        e.ump[0] = w[0];
        e.ump[1] = w[1];
        if (queueDeviceMidi(slot, e, timeNs)) ++queued;
    }
    return queued;
}

int Engine::midiBytes(const std::string& layerId, const uint8_t* bytes, int count, int64_t timeNs) {
    if (!bytes || count <= 0) return 0;
    const int slot = deviceSlot(layerId);
    if (slot < 0) return 0;
    if (timeNs <= 0) timeNs = midiClockNs();
    std::lock_guard<std::mutex> lock(midiPush_);
    int queued = 0;
    uint8_t status = 0;  // running status within this call
    for (int i = 0; i < count;) {
        const uint8_t b = bytes[i];
        if (b >= 0xF8) { ++i; continue; }  // real-time bytes may come anywhere
        if (b >= 0xF0) {  // system common and SysEx: skipped up to the next status byte
            status = 0;
            ++i;
            while (i < count && bytes[i] < 0x80) ++i;
            continue;
        }
        if (b >= 0x80) {
            status = b;
            ++i;
        } else if (status == 0) {
            ++i;
            continue;
        }
        const int need = midi1DataBytes(status);
        if (i + need > count) break;
        const uint8_t d1 = need > 0 ? bytes[i] : 0, d2 = need > 1 ? bytes[i + 1] : 0;
        if (d1 >= 0x80 || d2 >= 0x80) continue;  // a status byte arrived early: start again from it
        i += need;
        uint32_t w[2];
        Midi2Event e;
        if (!midi1ToUmp2(status, d1, d2, 0, w) || !decodeMidi2ChannelVoice(w[0], w[1], e)) continue;
        e.ump[0] = w[0];
        e.ump[1] = w[1];
        if (queueDeviceMidi(slot, e, timeNs)) ++queued;
    }
    return queued;
}

void Engine::midiRelease(const std::string& layerId) {
    int slot = -1;
    if (!layerId.empty()) {
        slot = deviceSlot(layerId);
        if (slot < 0) return;
    }
    Midi2Event e;
    e.type = Midi2EventType::AllOff;
    std::lock_guard<std::mutex> lock(midiPush_);
    queueDeviceMidi(slot, e, midiClockNs());  // slot -1: every slot
}

void Engine::setMidiOptions(bool mpe, double bendRange, double noteBendRange, double delayMs) noexcept {
    auto clampD = [](double v, double lo, double hi, double fallback) {
        return std::isfinite(v) ? std::clamp(v, lo, hi) : fallback;
    };
    midiMpe_.store(mpe, std::memory_order_relaxed);
    midiBendRange_.store(clampD(bendRange, 0, 96, 2), std::memory_order_relaxed);
    midiNoteBendRange_.store(clampD(noteBendRange, 0, 96, 48), std::memory_order_relaxed);
    midiDelayNs_.store(static_cast<int64_t>(clampD(delayMs, 0, 200, 0) * 1e6), std::memory_order_relaxed);
}

uint64_t Engine::midiDropped() const noexcept {
    return midiIn_.dropped();
}

int64_t Engine::positionAt(int64_t timeNs) const noexcept {
    const int64_t pos = cbPos_.load(std::memory_order_acquire);
    if (pos < 0) return -1;
    const int64_t at = cbTimeNs_.load(std::memory_order_acquire);
    return pos + static_cast<int64_t>(std::floor(static_cast<double>(timeNs - at) * sr_ / 1e9));
}

bool Engine::setMaster(double volume) {
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::SetMaster;
    c.master = std::isfinite(volume) ? std::clamp(volume, 0.0, kMaxMixGain) : 0.0;
    return send(c);
}

bool Engine::play(double fromStep) {
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    Cmd c;
    c.type = Cmd::Play;
    c.fromStep = fromStep;
    c.playCount = playCount_ + 1;
    c.touchStamp = touchCounter_;
    if (!send(c)) return false;  // nothing changed on the audio side, so keep the control side as it was
    playCount_ = c.playCount;
    loudness_->requestReset();  // the integrated loudness measures this play
    return true;
}

bool Engine::playCountIn(double fromStep, int beats, bool bars) {
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    Cmd c;
    c.type = Cmd::Play;
    c.fromStep = fromStep;
    c.countInBeats = std::clamp(beats, 0, bars ? 16 : 64);
    c.countInBars = bars;
    c.playCount = playCount_ + 1;
    c.touchStamp = touchCounter_;
    if (!send(c)) return false;
    playCount_ = c.playCount;
    loudness_->requestReset();
    return true;
}

bool Engine::setMetronome(bool on) {
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::Metronome;
    c.flag = on;
    return send(c);
}

void Engine::setMetronomeSound(double volume, int sound) noexcept {
    clickVolume_.store(static_cast<float>(std::isfinite(volume) ? std::clamp(volume, 0.0, 1.0) : 1.0),
                       std::memory_order_relaxed);
    clickSound_.store(sound >= 0 && sound <= 2 ? sound : 0, std::memory_order_relaxed);
}

void Engine::testTone(double seconds) noexcept {
    const double s = std::isfinite(seconds) ? std::clamp(seconds, 0.0, 10.0) : 0.0;
    toneRequest_.store(static_cast<int64_t>(s * sr_), std::memory_order_release);
}

void Engine::resetTestTone() noexcept {
    toneRequest_.store(-1, std::memory_order_release);
    toneLeft_ = toneLen_ = 0;
    toneActive_.store(false, std::memory_order_release);
}

bool Engine::releaseTouches() {
    // The same bookkeeping as a Play, without moving the transport: chains drop their touches at their next chunk.
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::ReleaseTouches;
    c.playCount = playCount_ + 1;
    c.touchStamp = touchCounter_;
    if (!send(c)) return false;
    playCount_ = c.playCount;
    return true;
}

bool Engine::stop() {
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::Stop;
    return send(c);
}

bool Engine::clearOverload() {
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::ClearOverload;
    return send(c);
}

int64_t Engine::loopLength() {
    std::lock_guard<std::mutex> lock(ctl_);
    return ctlLoopLen_;
}

// ctl_ held: sends a new tempo map and signatures to the audio thread (SetSong).
std::string Engine::sendSong(SongTime next) {
    next.serial = ++songSerial_;
    Cmd c;
    c.type = Cmd::SetSong;
    c.song = new SongTime(next);
    if (!send(c)) return "audio command queue is not accepting updates";
    ctlSong_ = std::move(next);
    audioIn_->setTempoPoints(ctlSong_.tempo.points());
    ctlLoopLen_ = std::max<int64_t>(1, static_cast<int64_t>(ctlSong_.tempo.roundFrame(ctlLoopSteps_)));
    return "";
}

std::string Engine::setTempoMap(std::vector<TempoPointSpec> points) {
    std::string error;
    if (!checkTempoPoints(points, error)) return error;
    if (audioIn_->recordingNow()) return "the tempo map can't change while recording";
    std::lock_guard<std::mutex> lock(ctl_);
    SongTime next = ctlSong_;
    next.tempo.build(points, ctlSr_);
    return sendSong(std::move(next));
}

std::string Engine::setTimeSignatures(std::vector<TimeSigSpec> sigs) {
    std::string error;
    if (!checkTimeSigs(sigs, error)) return error;
    std::lock_guard<std::mutex> lock(ctl_);
    SongTime next = ctlSong_;
    next.sigs.build(sigs);
    return sendSong(std::move(next));
}

Engine::SongPosition Engine::position() {
    SongPosition p;
    p.playing = playingFlag_.load(std::memory_order_relaxed);
    for (int tries = 0;; ++tries) {
        const uint32_t a = posSeq_.load(std::memory_order_acquire);
        p.frame = pos_.frame.load(std::memory_order_relaxed);
        p.beat = pos_.beat.load(std::memory_order_relaxed);
        p.bpm = pos_.bpm.load(std::memory_order_relaxed);
        p.bar = pos_.bar.load(std::memory_order_relaxed);
        p.beatInBar = pos_.inBar.load(std::memory_order_relaxed);
        const int sig = pos_.sig.load(std::memory_order_relaxed);
        p.num = sig / 64;
        p.den = sig % 64;
        std::atomic_thread_fence(std::memory_order_acquire);
        if ((a & 1) == 0 && posSeq_.load(std::memory_order_relaxed) == a) break;
        if (tries > 1000) std::this_thread::yield();
    }
    p.seconds = static_cast<double>(p.frame) / ctlSr_;
    return p;
}

SongTime Engine::songTime() {
    std::lock_guard<std::mutex> lock(ctl_);
    return ctlSong_;
}

Meters Engine::meters() {
    {  // the UI reads meters often: values merged under pressure go into the MIDI queue as space returns
        std::unique_lock<std::mutex> midi(midiPush_, std::try_to_lock);
        if (midi) midiIn_.flush();
    }
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    Meters m;
    m.cpu = cpu_.load(std::memory_order_relaxed);
    m.peakL = peakL_.exchange(0, std::memory_order_relaxed);
    m.peakR = peakR_.exchange(0, std::memory_order_relaxed);
    m.playing = playingFlag_.load(std::memory_order_relaxed);
    m.position = posFlag_.load(std::memory_order_relaxed);
    m.loopLength = loopLenFlag_.load(std::memory_order_relaxed);
    m.overloaded = overloadedFlag_.load(std::memory_order_relaxed);
    return m;
}

bool Engine::layerMeter(int index, LayerMeter& out) {
    std::lock_guard<std::mutex> lock(ctl_);
    out = LayerMeter{};
    if (index < 0 || index >= static_cast<int>(order_.size())) return false;
    readLayerMeter(index, out);
    return true;
}

int Engine::layerMeters(int capacity, void (*sink)(void* ctx, int index, const LayerMeter& meter), void* ctx) {
    std::lock_guard<std::mutex> lock(ctl_);
    const int count = static_cast<int>(order_.size());
    const int n = sink ? std::min(count, std::max(capacity, 0)) : 0;
    for (int i = 0; i < n; ++i) {
        LayerMeter m;
        readLayerMeter(i, m);
        sink(ctx, i, m);
    }
    return count;
}

// One layer's meter, reset as it is read; ctl_ is held and index is a project layer.
void Engine::readLayerMeter(int index, LayerMeter& out) {
    auto it = layers_.find(order_[index]);
    if (it == layers_.end() || it->second.slot < 0) return;
    Slot& s = ctlSlot(it->second.slot);
    out.active = true;
    out.peakL = s.peakL.exchange(0, std::memory_order_relaxed);
    out.peakR = s.peakR.exchange(0, std::memory_order_relaxed);
    out.peak = std::max(out.peakL, out.peakR);
    out.progress = s.progress.load(std::memory_order_relaxed);
    out.overloaded = s.overloadFlag.load(std::memory_order_relaxed);
}

LoudnessMeter::Reading Engine::loudness() {
    std::lock_guard<std::mutex> lock(ctl_);  // one reader at a time
    return loudness_->read();
}

void Engine::resetLoudness() { loudness_->requestReset(); }

bool Engine::layerCorrelation(int index, float& out) {
    std::lock_guard<std::mutex> lock(ctl_);
    out = 0.0f;
    if (index < 0 || index >= static_cast<int>(order_.size())) return false;
    auto it = layers_.find(order_[index]);
    if (it == layers_.end() || it->second.slot < 0) return true;
    out = ctlSlot(it->second.slot).correlation.read();
    return true;
}

bool Engine::setOutputTap(const std::string& layerId, float* left, float* right, bool preFader) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = layers_.find(layerId);
    if (!left || !right || it == layers_.end() || it->second.slot < 0) return false;
    Slot& s = ctlSlot(it->second.slot);
    s.tapL = left;
    s.tapR = right;
    s.tapPre = preFader;
    return true;
}

void Engine::clearOutputTaps() {
    std::lock_guard<std::mutex> lock(ctl_);
    for (int i = 0; i < ctlTable_->capacity; ++i) {
        ctlSlot(i).tapL = ctlSlot(i).tapR = nullptr;
        ctlSlot(i).tapPre = false;
    }
}

int64_t Engine::layerLatency(const std::string& layerId) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = layers_.find(layerId);
    if (it == layers_.end() || it->second.slot < 0) return 0;
    const LayerState& ls = it->second;
    uint64_t frames = 0;  // as updateCompensation counts a slot's own
    if (ls.inserts) frames += ls.inserts->latencyFrames();
    if (ls.instrument && !ls.bus) frames += ls.instrument->latencyFrames() + noteFx_->latencyFrames(layerId);
    return static_cast<int64_t>(std::min<uint64_t>(frames, 1u << 30));
}

int Engine::scope(int index, float* out, int n) {
    std::lock_guard<std::mutex> lock(ctl_);
    n = std::min(n, kScopeSize);
    const std::atomic<float>* ring = masterScope_.get();
    int pos = masterScopePos_.load(std::memory_order_acquire);
    if (index != kScopeMaster) {
        int slot = -1;
        if (index == kScopeAudition) {
            slot = ctlTable_->capacity;  // auditionSlot()
        } else if (index >= 0 && index < static_cast<int>(order_.size())) {
            auto it = layers_.find(order_[index]);
            if (it != layers_.end()) slot = it->second.slot;
        }
        if (slot < 0) {
            std::fill_n(out, n, 0.0f);
            return n;
        }
        ring = ctlSlot(slot).scope;
        pos = ctlSlot(slot).scopePos.load(std::memory_order_acquire);
    }
    for (int i = 0; i < n; ++i) out[i] = ring[(pos - n + i + kScopeSize) % kScopeSize].load(std::memory_order_relaxed);
    return n;
}

}  // namespace caw
