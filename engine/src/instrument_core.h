// The modelled instruments' shared frame (namespace caw::timber, Timber's until 1.1.3; Starling, Nightingale, Curlew, Woodpecker and Bittern): one class per model on a common voice pool, voice cap and stealing, control grid, tone, room send and display.
#pragma once

#include <algorithm>
#include <cmath>
#include <concepts>
#include <cstdint>
#include <new>

#include "caw/display.hpp"
#include "caw/instrument.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/reverb.hpp"
#include "quality.h"
#include "instrument_dsp.h"

namespace caw::timber {

// The parameters every model shares, first in each model's descriptor (then the model's own, then `variant`).
enum SharedParam : uint32_t { kTone, kBody, kSpace, kVelocity, kRelease, kVoices, kLevel, kSharedCount };

inline constexpr uint32_t kControlFrames = 16;  // the control grid: every knob is read every 16 frames
inline constexpr uint32_t kDisplayFloats = 16;  // 9 shared + 7 a model's own

// What the frame hands a model at each control point.
struct Shared {
    double sr = 48000.0;
    double tone = 0, body = 0.5, space = 0, velocity = 0.8, release = 0.3, levelDb = 0;
    uint32_t cap = 16;
    int quality = kQualityNormal;
    double modWheel = 0;  // CC 1, 0..1
    double pedal = 0;     // CC 64, 0..1 (the piano also has a sustain knob)
    uint64_t clock = 0;   // frames played since the instrument last woke (start(): the note's own frame)
};

// The fields every model's voice has (VoicePool's and the frame's).
struct VoiceBase {
    bool active = false, held = false;
    uint32_t noteId = 0;
    uint64_t age = 0;
    uint8_t key = 60;
    double pitch = 60, velocity = 0.8, pressure = 0;
    float panL = 0.7071f, panR = 0.7071f;
    float fade = 1, fadeStep = 0;  // a stolen voice fades out over 5 ms
    bool fading = false;
    float level = 0;               // the last control block's peak (stealing takes the quietest released voice)
    float acc = 0;                 // this control block's peak so far
    uint32_t quiet = 0;            // control blocks in a row under -100 dB
    uint64_t frames = 0;           // frames since it started
};

// The frame. A model M supplies:
//   struct Voice : VoiceBase; kPool, kEcoCap, kNormalCap, kHighCap, kModelParams; kRestrike (a key struck again
//   fades its sounding voice, as a string or a bar struck again does); kHeldSilenceEnds (a held voice that falls
//   silent ends; not for an organ, whose drawbars may be pulled while a key is held); kMinLife (seconds before a
//   silent voice may end: a long string's first wave takes a period to arrive); kSpread (keyboard panning 0..1);
//   room() (its room's settings), bool prepare(sr, Voice*, n), reset(), control(p, shared) (p: its own knobs),
//   start(v, shared), release(v, shared), voiceControl(v, shared) (each sounding voice, each control point),
//   render(v, out, n) (one voice, mono, writes n <= 16 frames), post(l, r, n, shared) (after the voices' sum),
//   bool postQuiet(), clearPost(), display(out) (up to 7 floats).
// A model may also render its voices four at a time (GroupedModel): while grouped() is true the frame hands it up
// to four voices at once, renderGroup(voices, count, out, n), so their sample-to-sample chains (a friction's
// Newton step, a bore's filters) overlap instead of waiting on each other one voice at a time. Each voice is
// computed as if alone, so its bits never depend on which voices share its group.
template <class M>
concept GroupedModel = requires(M& m, typename M::Voice* const* v, float (*o)[kControlFrames]) {
    { m.grouped() } -> std::convertible_to<bool>;
    m.renderGroup(v, 1u, o, 1u);
};

template <class M>
class Instrument final : public InstrumentProcessor {
public:
    explicit Instrument(const ModuleDescriptor& d, int modelIndex) noexcept : d_(d), modelIndex_(modelIndex) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

    bool activate(double sampleRate, uint32_t) noexcept override {
        sr_ = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
        shared_.sr = sr_;
        toneK_ = static_cast<float>(1.0 - detExp(-kTwoPi * 700.0 / sr_));  // the tone's corner (control() reads it)
        quality_ = buildingQuality();
        try {
            room_.prepare(sr_, 64, 0.05);
        } catch (...) {
            return false;
        }
        if (!model_.prepare(sr_, pool_.begin(), M::kPool)) return false;
        room_.set(model_.room());
        // A model may keep its lows out of the room (roomLowCut(): Hz, 0 none): a one-pole high-pass on the send.
        roomCut_ = 0.0f;
        if constexpr (requires { M::roomLowCut(); }) {
            if (M::roomLowCut() > 0.0) roomCut_ = static_cast<float>(detExp(-kTwoPi * M::roomLowCut() / sr_));
        }
        displayClock_.prepare(sr_);
        reset();
        return true;
    }
    void reset() noexcept override {
        pool_.clear();
        model_.reset();
        room_.clear();
        cutXl_ = cutXr_ = cutYl_ = cutYr_ = 0;
        toneL_ = toneR_ = 0;
        levelGain_ = levelStep_ = 0;
        levelFresh_ = true;
        settled_ = true;
        left_ = 0;
        clock_ = 0;
        silentFrames_ = 0;
        peak_ = periodPeak_ = 0;
        shared_.modWheel = shared_.pedal = 0;
        lastKey_ = -1;
        lastVelocity_ = 0;
        notes_ = 0;
        legatoN_ = 0;
        display_.clear();
    }
    bool quiet() const noexcept override { return settled_; }
    uint32_t readDisplay(float* out, uint32_t max) const noexcept override { return display_.read(out, max); }

    M& model() noexcept { return model_; }
    // Bytes this instance holds: the class (its voices) and what activate() allocated.
    size_t bytes() const noexcept { return sizeof(*this) + model_.allocBytes() + room_.bytes(); }
    uint32_t sounding() noexcept { return pool_.activeCount(); }

protected:
    void beginBlock(const ProcessBlock& b) noexcept override { block_ = &b; }

    void onEvent(const Event& e) noexcept override {
        const uint32_t w0 = e.data[0], type = w0 >> 28, status = (w0 >> 20) & 0xF, index = (w0 >> 8) & 0x7F;
        if (status != 0xB || (index != 1 && index != 64)) return;
        double v = 0;
        if (type == 0x2) v = static_cast<double>(w0 & 0x7F) / 127.0;
        else if (type == 0x4) v = static_cast<double>(e.data[1]) / 4294967295.0;
        else return;
        (index == 1 ? shared_.modWheel : shared_.pedal) = v;
    }

    void onNote(const NoteMessage& m) noexcept override {
        switch (m.type) {
            case NoteMessageType::On: {
                if (settled_) {  // waking: the knobs are read at this note's frame, and the grid starts here
                    settled_ = false;
                    control(m.frame);
                    left_ = kControlFrames;
                }
                ++notes_;
                lastKey_ = m.key;
                const double sens = clampd(shared_.velocity, 0.0, 1.0);
                const double vel = clampd(0.75 + (clampd(m.velocity, 0.0, 1.0) - 0.75) * sens, 0.01, 1.0);
                lastVelocity_ = vel;
                const uint8_t key = notes::keyOf(m.pitch);
                // Mono legato (owner, 2026-11-25: a flute's note "restarts every time a note changes"): a note played
                // while one is held moves the sounding voice to it, breath and all, as a player slurs; the held one
                // waits underneath and sounds again when this one ends. A gap between notes still starts a new note.
                if constexpr (requires(M& mm, const Shared& sh) { mm.legato(sh); }) {
                    if (model_.legato(shared_)) {
                        typename M::Voice* cur = nullptr;
                        pool_.forEachActive([&](typename M::Voice& v) {
                            if (v.held && !v.fading) cur = &v;
                        });
                        if (cur) {
                            if (legatoN_ == 16) {  // a full stack drops its oldest
                                for (uint32_t i = 1; i < 16; ++i) legato_[i - 1] = legato_[i];
                                --legatoN_;
                            }
                            legato_[legatoN_++] = {cur->noteId, cur->pitch, cur->key};
                            cur->noteId = m.noteId, cur->pitch = m.pitch, cur->key = key;
                            break;
                        }
                        legatoN_ = 0;
                    }
                }
                // A key struck again: its sounding voice fades (one string, one bar).
                if (M::kRestrike)
                    pool_.forEachActive([&](typename M::Voice& v) {
                        if (v.key == key && !v.fading) fadeOut(v);
                    });
                // Over the cap: the quietest released voice fades out, else the oldest held one.
                uint32_t live = 0;
                pool_.forEachActive([&](typename M::Voice& v) { live += v.fading ? 0 : 1; });
                if (live >= shared_.cap) {
                    typename M::Voice* pick = nullptr;
                    pool_.forEachActive([&](typename M::Voice& v) {
                        if (v.fading || v.held) return;
                        if (!pick || v.level < pick->level) pick = &v;
                    });
                    if (!pick)
                        pool_.forEachActive([&](typename M::Voice& v) {
                            if (!v.fading && (!pick || v.age < pick->age)) pick = &v;
                        });
                    if (pick) fadeOut(*pick);
                }
                typename M::Voice& v = pool_.start(m.noteId);
                v.key = key;
                v.pitch = m.pitch;
                v.velocity = vel;
                v.pressure = 0;
                v.fade = 1, v.fadeStep = 0, v.fading = false;
                v.level = 1, v.acc = 0, v.quiet = 0, v.frames = 0;
                const double pan = clampd((m.pitch - 64.0) / 44.0, -1.0, 1.0) * M::kSpread;  // low keys left
                v.panL = static_cast<float>(std::cos((pan + 1.0) * 0.25 * kPi));
                v.panR = static_cast<float>(std::sin((pan + 1.0) * 0.25 * kPi));
                shared_.clock = clock_;
                model_.start(v, shared_);
                break;
            }
            case NoteMessageType::Off:
                if (legatoN_ > 0) {
                    if (typename M::Voice* v = pool_.find(m.noteId); v && v->held) {  // the sounding note ends:
                        const Held h = legato_[--legatoN_];                           // slur back to the last one held
                        v->noteId = h.id, v->pitch = h.pitch, v->key = h.key;
                        break;
                    }
                    for (uint32_t i = 0; i < legatoN_; ++i)  // a note held underneath ends: forget it
                        if (legato_[i].id == m.noteId) {
                            for (uint32_t j = i + 1; j < legatoN_; ++j) legato_[j - 1] = legato_[j];
                            --legatoN_;
                            break;
                        }
                }
                if (typename M::Voice* v = pool_.find(m.noteId); v && v->held) {
                    v->held = false;
                    model_.release(*v, shared_);
                }
                break;
            case NoteMessageType::Pitch:
                if (typename M::Voice* v = pool_.find(m.noteId)) v->pitch = m.pitch;
                break;
            case NoteMessageType::Pressure:
                if (typename M::Voice* v = pool_.find(m.noteId)) v->pressure = m.value;
                break;
            default:
                break;
        }
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock&) noexcept override {
        uint32_t done = 0;
        while (done < frames) {
            if (settled_) {  // asleep: silence, nothing moves (so a host skipping the block changes nothing)
                std::fill(left + done, left + frames, 0.0f);
                std::fill(right + done, right + frames, 0.0f);
                left_ = 0;
                break;
            }
            if (left_ == 0) {
                control(offset + done);
                left_ = kControlFrames;
            }
            const uint32_t n = std::min(left_, frames - done);
            chunk(left + done, right + done, n);
            clock_ += n;
            left_ -= n;
            if (left_ == 0) endPeriod();  // decisions only on the grid, so any block size gives the same bits
            done += n;
        }
        if (displayClock_.tick(frames)) publish();
    }

private:
    void fadeOut(typename M::Voice& v) noexcept {
        v.fading = true;
        v.held = false;
        v.fadeStep = static_cast<float>(1.0 / std::max(1.0, 0.005 * sr_));
    }

    double param(uint32_t k, uint32_t at) const noexcept {
        return parameterAt(*block_, k, at, d_.parameters[k].defaultValue);
    }

    void control(uint32_t at) noexcept {
        shared_.tone = clampd(param(kTone, at), -1.0, 1.0);
        shared_.body = clampd(param(kBody, at), 0.0, 1.0);
        shared_.space = clampd(param(kSpace, at), 0.0, 1.0);
        shared_.velocity = clampd(param(kVelocity, at), 0.0, 1.0);
        shared_.release = clampd(param(kRelease, at), 0.005, 10.0);
        shared_.levelDb = clampd(param(kLevel, at), -48.0, 12.0);
        shared_.quality = qualityNow(quality_);
        const uint32_t tier = shared_.quality == kQualityEco ? M::kEcoCap
                              : shared_.quality == kQualityHigh ? M::kHighCap : M::kNormalCap;
        shared_.cap = std::max<uint32_t>(1, std::min<uint32_t>(tier, static_cast<uint32_t>(clampd(param(kVoices, at), 1, 128) + 0.5)));
        for (uint32_t k = 0; k < M::kModelParams; ++k) p_[k] = param(kSharedCount + k, at);
        model_.control(p_, shared_);
        pool_.forEachActive([&](typename M::Voice& v) { model_.voiceControl(v, shared_); });
        // The tone: a tilt around 700 Hz (toneK_, from activate()), +-6 dB at each end. The gains are worked out
        // again only when their knob moved (the same values: a control point no longer pays three exponentials).
        if (!(shared_.tone == toneFor_)) {
            toneFor_ = shared_.tone;
            toneLo_ = static_cast<float>(lib::dbToGain(-6.0 * shared_.tone));
            toneHi_ = static_cast<float>(lib::dbToGain(6.0 * shared_.tone));
        }
        if (!(shared_.levelDb == levelFor_)) levelFor_ = shared_.levelDb, levelTarget_ = lib::dbToGain(shared_.levelDb);
        const double g = levelTarget_;
        if (levelFresh_) levelGain_ = g, levelFresh_ = false;
        levelStep_ = (g - levelGain_) / kControlFrames;
        toneL_ = flushf(toneL_), toneR_ = flushf(toneR_);
        cutYl_ = flushf(cutYl_), cutYr_ = flushf(cutYr_);
        room_.setLight(shared_.quality == kQualityEco);
    }

    void chunk(float* left, float* right, uint32_t n) noexcept {
        float mixL[kControlFrames] = {}, mixR[kControlFrames] = {};
        // A voice's output into the mix (its fade, peak and pan), in the pool's order either way.
        auto mix = [&](typename M::Voice& v, float* voice) {
            float peak = 0;
            if (v.fading) {
                for (uint32_t i = 0; i < n; ++i) {
                    v.fade = std::max(0.0f, v.fade - v.fadeStep);
                    voice[i] *= v.fade;
                }
            }
            for (uint32_t i = 0; i < n; ++i) {
                peak = std::max(peak, std::fabs(voice[i]));
                mixL[i] += voice[i] * v.panL;
                mixR[i] += voice[i] * v.panR;
            }
            v.acc = peak == peak ? std::max(v.acc, peak) : 1e30f;
            v.frames += n;
        };
        bool done = false;
        if constexpr (GroupedModel<M>) {
            if (model_.grouped()) {
                typename M::Voice* group[4];
                float out[4][kControlFrames];
                uint32_t g = 0;
                auto flush = [&] {
                    model_.renderGroup(group, g, out, n);
                    for (uint32_t j = 0; j < g; ++j) mix(*group[j], out[j]);
                    g = 0;
                };
                pool_.forEachActive([&](typename M::Voice& v) {
                    group[g++] = &v;
                    if (g == 4) flush();
                });
                if (g) flush();
                done = true;
            }
        }
        if (!done) {
            float voice[kControlFrames];
            pool_.forEachActive([&](typename M::Voice& v) {
                model_.render(v, voice, n);
                mix(v, voice);
            });
        }
        model_.post(mixL, mixR, n, shared_);
        const bool roomOn = shared_.space > 0.0;
        if (!roomOn) cutXl_ = cutXr_ = cutYl_ = cutYr_ = 0;  // the send off: its high-pass starts fresh when it returns
        float outPeak = 0;
        for (uint32_t i = 0; i < n; ++i) {
            float l = mixL[i], r = mixR[i];
            toneL_ += toneK_ * (l - toneL_);
            toneR_ += toneK_ * (r - toneR_);
            l = toneL_ * toneLo_ + (l - toneL_) * toneHi_;
            r = toneR_ * toneLo_ + (r - toneR_) * toneHi_;
            if (roomOn) {
                float wl = l * static_cast<float>(shared_.space), wr = r * static_cast<float>(shared_.space);
                if (roomCut_ > 0.0f) {
                    const float hl = roomCut_ * (cutYl_ + wl - cutXl_), hr = roomCut_ * (cutYr_ + wr - cutXr_);
                    cutXl_ = wl, cutXr_ = wr, cutYl_ = hl, cutYr_ = hr;
                    wl = hl, wr = hr;
                }
                room_.process(wl, wr);
                l += wl, r += wr;
            }
            levelGain_ += levelStep_;
            const float g = static_cast<float>(levelGain_);
            l *= g, r *= g;
            if (!std::isfinite(l)) l = 0;
            if (!std::isfinite(r)) r = 0;
            left[i] = l, right[i] = r;
            outPeak = std::max(outPeak, std::max(std::fabs(l), std::fabs(r)));
        }
        peak_ = std::max(peak_, outPeak);
        periodPeak_ = std::max(periodPeak_, outPeak);
    }

    // At the end of each control block: voices that faded out or fell silent end; then, nothing sounding, the
    // model's own tail and the room quiet for 0.5 s: every state to zero, asleep.
    void endPeriod() noexcept {
        const uint64_t minLife = static_cast<uint64_t>(M::kMinLife * sr_);
        pool_.forEachActive([&](typename M::Voice& v) {
            v.level = v.acc;
            v.acc = 0;
            v.quiet = v.level < 1e-5f ? v.quiet + 1 : 0;
            const bool mayEnd = (!v.held || M::kHeldSilenceEnds) && v.frames > minLife;
            if ((v.fading && v.fade <= 0.0f) || (mayEnd && v.quiet > 8) || v.level > 1e20f) v.active = false;
        });
        const float outPeak = periodPeak_;
        periodPeak_ = 0;
        const uint32_t n = kControlFrames;
        if (pool_.activeCount() == 0 && model_.postQuiet() && outPeak < 1e-6f) {
            silentFrames_ += n;
            if (silentFrames_ > 0.5 * sr_) {
                model_.clearPost();
                room_.clear();
                cutXl_ = cutXr_ = cutYl_ = cutYr_ = 0;
                toneL_ = toneR_ = 0;
                silentFrames_ = 0;
                settled_ = true;
                clock_ = 0;
            }
        } else {
            silentFrames_ = 0;
        }
    }

    void publish() noexcept {
        float out[kDisplayFloats] = {};
        out[0] = 1;  // layout version
        out[1] = static_cast<float>(modelIndex_);
        out[2] = static_cast<float>(pool_.activeCount());
        out[3] = static_cast<float>(shared_.cap);
        out[4] = static_cast<float>(lib::gainToDb(peak_));
        out[5] = static_cast<float>(shared_.pedal);
        out[6] = static_cast<float>(lastKey_);
        out[7] = static_cast<float>(lastVelocity_);
        out[8] = static_cast<float>(notes_);
        model_.display(out + 9);
        peak_ = 0;
        display_.publish(out, kDisplayFloats);
    }

    const ModuleDescriptor& d_;
    int modelIndex_ = 0;
    M model_;
    VoicePool<typename M::Voice, M::kPool> pool_;
    const ProcessBlock* block_ = nullptr;
    const std::atomic<int>* quality_ = nullptr;
    double sr_ = 48000.0;
    Shared shared_;
    // Mono legato (a model with legato(shared) true, e.g. Curlew): the notes held under the sounding one, newest last.
    struct Held { uint32_t id; double pitch; uint8_t key; };
    Held legato_[16] = {};
    uint32_t legatoN_ = 0;
    double p_[static_cast<uint32_t>(M::kModelParams)] = {};
    lib::Reverb room_;
    float roomCut_ = 0, cutXl_ = 0, cutXr_ = 0, cutYl_ = 0, cutYr_ = 0;  // the room send's high-pass (roomLowCut)
    float toneK_ = 0, toneLo_ = 1, toneHi_ = 1, toneL_ = 0, toneR_ = 0;
    double toneFor_ = std::nan(""), levelFor_ = std::nan(""), levelTarget_ = 1;  // what toneLo_/Hi_ and levelTarget_ are for
    double levelGain_ = 0, levelStep_ = 0;
    bool levelFresh_ = true;
    bool settled_ = true;
    uint32_t left_ = 0;
    uint64_t clock_ = 0;
    uint64_t silentFrames_ = 0;
    float peak_ = 0, periodPeak_ = 0;
    int lastKey_ = -1;
    double lastVelocity_ = 0;
    uint32_t notes_ = 0;
    DisplayClock displayClock_;
    DisplayBuffer<kDisplayFloats> display_;
};

}  // namespace caw::timber
