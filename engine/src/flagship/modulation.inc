// FlagshipInstrument's control grid, mod sources and matrix, and starting a voice (hand-written; included by builtin_flagship.cpp, not compiled alone).
    // The grid of controls, carried across render calls (as the other built-in synths' ControlClock).
    class Clock {
    public:
        template <class Control, class Run>
        void run(uint32_t frames, uint32_t offset, Control&& control, Run&& run) noexcept {
            for (uint32_t i = 0; i < frames;) {
                if (left_ == 0) {
                    control(offset + i);
                    left_ = kControlFrames;
                }
                const uint32_t n = std::min(left_, frames - i);
                run(i, n);
                i += n;
                left_ -= n;
            }
        }
        void restart() noexcept { left_ = 0; }

    private:
        uint32_t left_ = 0;
    };

    // Moves every clock on by the frames rendered since the last settle, at once: the same sums however
    // blocks split the time between (a note event settles them before it changes anything).
    void settle() noexcept {
        const uint32_t n = sinceControl_;
        if (n == 0) return;
        const double frames = static_cast<double>(n);
        const double done = n >= kControlFrames ? 1.0 : frames / kControlFrames;
        uint32_t voiceLfos = 0;  // the retriggered LFOs a slot listens to: a voice's own (a free one is the instrument's)
        for (uint32_t l = 0; l < kLfos; ++l)
            if (uses(lfoSource(l)) && retriggered(l)) voiceLfos |= 1u << l;
        voices_.forEachActive([&](Voice& v) noexcept {
            for (OscVoice& o : v.osc)
                for (int c = 0; c < o.count; ++c)
                    if (o.a[c]) o.phase[c] += n * o.step[c];
            if (uses(kSrcEnv2)) v.env[1].skip(n);
            if (uses(kSrcEnv3)) v.env[2].skip(n);
            for (uint32_t l = 0; l < kLfos; ++l)
                if (voiceLfos & (1u << l)) v.lfo[l].advance(static_cast<int>(n));
            if (uses(kSrcRandom)) v.random.advance(static_cast<int>(n));
            v.gain0 += (v.gain1 - v.gain0) * done;
        });
        for (lib::Lfo& l : lfo_) l.advance(static_cast<int>(n));
        volume0_ += (volume1_ - volume0_) * done;
        delayTime0_ += (delayTime1_ - delayTime0_) * done;
        // The effects' tail: frames since the output was last above -94 dB.
        quietRun_ = periodPeak_ > 2e-5f ? 0 : quietRun_ + n;
        periodPeak_ = 0.0f;
        sinceControl_ = 0;
    }

    // A parameter's value as a fraction 0..1 of its knob's travel (the curve's, up to `top`: modulationTop), and back.
    double toNorm(uint32_t k, double v, double top) const noexcept {
        const ParameterDescriptor& d = params().d[k];
        if (d.curve == ParameterCurve::Exponential) {
            const double r = params().logRange[k];
            return v <= d.minimum || r <= 0.0 ? 0.0 : detLog(v / d.minimum) / r;
        }
        return top > d.minimum ? (v - d.minimum) / (top - d.minimum) : 0.0;
    }
    double fromNorm(uint32_t k, double n, double top) const noexcept {
        const ParameterDescriptor& d = params().d[k];
        n = clampd(n, 0.0, 1.0);
        double v = d.curve == ParameterCurve::Exponential ? d.minimum * lib::fastExp(n * params().logRange[k])
                                                          : d.minimum + n * (top - d.minimum);
        if (d.step > 0.0) v = d.minimum + std::floor((v - d.minimum) / d.step + 0.5) * d.step;
        return clampd(v, d.minimum, top);
    }

    bool uses(uint32_t source) const noexcept { return (used_ >> source) & 1u; }
    bool retriggered(uint32_t lfo) const noexcept { return clampi(base_[lfoParam(lfo, kLfoMode)], 0, 2) == kLfoRetrigger; }

    // A source's value for a voice, 0..1 (a bipolar source such as an LFO is centred on 0.5).
    double sourceValue(const Voice& v, int source, double bendRange) const noexcept {
        switch (source) {
            case kSrcEnv1:
            case kSrcEnv2:
            case kSrcEnv3: return v.env[source - kSrcEnv1].level();
            case kSrcLfo1:
            case kSrcLfo2:
            case kSrcLfo3:
            case kSrcLfo4: {
                const uint32_t l = source == kSrcLfo4 ? 3u : static_cast<uint32_t>(source - kSrcLfo1);
                return 0.5 * ((retriggered(l) ? v.lfo[l].value() : freeLfo_[l]) + 1.0);
            }
            case kSrcRandom: return 0.5 * (v.random.value() + 1.0);
            case kSrcVelocity: return v.velocity;
            case kSrcNote: return clampd(v.pitch / 127.0, 0.0, 1.0);
            case kSrcBend: return 0.5 * (clampd((v.pitch - v.notePitch) / bendRange, -1.0, 1.0) + 1.0);
            case kSrcPressure: return v.pressure;
            case kSrcTimbre: return v.timbre;
            case kSrcModWheel: return modWheel_;
            case kSrcAccent: return clampd((v.velocity - 0.7) / 0.3, 0.0, 1.0);  // a 303's: above 0.7, fully at 1
            default:  // the macros: the instrument's knobs, the same for every voice
                if (source >= kSrcMacro1 && source < kSourceCount)
                    return clampd(base_[macroParam(static_cast<uint32_t>(source - kSrcMacro1))], 0.0, 1.0);
                return 0.0;
        }
    }

    // The value of parameter k for a voice whose slot offsets are `offsets`.
    // (k is below kModTargets: the slots' own parameters are read from base_.) The unmodulated case, by far the
    // most common, is a load and a branch.
    CAW_FORCE_INLINE double value(uint32_t k, const double* offsets) const noexcept {
        const int t = k < kModTargets ? targetOf_[k] : 0;
        // A slot whose source is at 0 (an envelope at rest, no timbre) leaves the knob as it is: no exp, and the
        // filter that reads it keeps its coefficients.
        return t && offsets[t - 1] != 0.0 ? modulated(k, t - 1, offsets) : base_[k];
    }
    CAW_NO_INLINE double modulated(uint32_t k, int t, const double* offsets) const noexcept {
        return fromNorm(k, targetNorm_[t] + offsets[t], targetTop_[t]);
    }

    // Once per control period: the knobs, the matrix, every sounding voice's settings and the effects.
    void control(const ProcessBlock& b, uint32_t at) noexcept {
        restShared();
        // A ramping knob (automation) of an oscillator, a filter, the routing or an envelope that no slot moves
        // marks only its voice section (rampMoved_): the voices work that section out again, as a slot's would be
        // (2026-11-27: Medusa's automated cutoff had every voice redo everything every period). The sections left
        // alone would have been worked out to the same values, so the bits are the same. Any other ramping knob
        // that moved this control moves everything, as before.
        rampMoved_ = 0;
        bool rampAll = false;
        for (uint32_t r = 0; r < rampCount_; ++r) {
            const uint32_t k = ramp_[r];
            const double v = b.parameters[k].samples[at];
            if (v != base_[k]) {
                const uint32_t section = k < kModTargets ? sectionOf(k) : kMovedGlobal;
                if (k < kModTargets && targetOf_[k] == 0 && (section & kRampSections)) rampMoved_ |= section;
                else rampAll = true;
            }
            base_[k] = v;
        }
        tempo_ = transport_ && transport_->tempo > 0.0 ? transport_->tempo : 120.0;
        // What a voice must work out again this control: everything when a knob, the tempo or the quality moved;
        // otherwise only the sections a slot modulates or a ramp moved, and what follows the pitch (2026-11-10
        // performance pass).
        const int quality = qualityNow(quality_);
        if (rampAll || tempo_ != lastTempo_ || quality != lastQuality_) knobsChanged_ = true;
        if (knobsChanged_) rampMoved_ = 0;  // everything is worked out anyway
        lastTempo_ = tempo_;
        lastQuality_ = quality;
        const bool beatLocked = transport_ && transport_->playing;
        const double beat = beatLocked ? transport_->beat + at * tempo_ / (60.0 * sr_) : 0.0;

        // The matrix: the slots that move something, and the parameters they move (each once, in slot order).
        // It is read from the knobs alone, so it stands while none moved.
        if (rampMoved_ & (kMovedFilter1 | kMovedFilter2)) configureShared();  // it reads filter 1's and 2's knobs
        if (knobsChanged_) {
            buildMatrix();
            configureShared();
            noiseUsed_ = false;
            for (uint32_t o = 0; o < kOscs; ++o) noiseUsed_ = noiseUsed_ || clampi(base_[modSrcParam(o)], 0, 4) == 4;
        }

        // The free LFOs run once for the instrument, on their knobs' own values; synced to a playing song,
        // they follow its position.
        for (uint32_t l = 0; l < kLfos; ++l) {
            if (!uses(lfoSource(l))) continue;
            const int sync = clampi(base_[lfoParam(l, kLfoSync)], 0, 9);
            if (knobsChanged_) {
                lfo_[l].setShape(static_cast<lib::LfoShape>(clampi(base_[lfoParam(l, kLfoShape)], 0, 6)));
                if (sync > 0) lfo_[l].setRateBeats(kLfoSyncBeats[sync], tempo_);
                else lfo_[l].setRateHz(base_[lfoParam(l, kLfoRate)]);
            }
            if (sync > 0 && beatLocked && clampi(base_[lfoParam(l, kLfoMode)], 0, 2) != kLfoRunning)
                lfo_[l].syncToBeat(beat, kLfoSyncBeats[sync]);
            freeLfo_[l] = lfo_[l].value();
        }

        // Each voice: its sources, its slot offsets, then its settings.
        uint64_t newest = 0;
        std::fill(globalOffsets_, globalOffsets_ + kSlots, 0.0);
        const double bendRange = clampd(base_[kBendRange], 1.0, 48.0);
        voices_.forEachActive([&](Voice& v) noexcept {
            if (v.starting) startVoice(v);
            if (noiseUsed_) drawNoise(v);
            if (v.mono) v.pitch = v.glide.next();
            double offsets[kSlots] = {};
            for (uint32_t s = 0; s < slotCount_; ++s) {
                const Slot& slot = slots_[s];
                const double u = sourceValue(v, slot.source, bendRange);
                const double scale = slot.via != kSrcNone ? sourceValue(v, slot.via, bendRange) : 1.0;
                offsets[slot.target] += slot.amount * (slot.bipolar ? 2.0 * u - 1.0 : u) * scale;
            }
            configureVoice(v, offsets);
            if (v.age > newest) {
                newest = v.age;
                std::copy(offsets, offsets + kSlots, globalOffsets_);
            }
        });

        // The banks the sounding voices read stay held; one none read for a second is let go (flagship_banks.h).
        if (banks_.holding()) {
            voices_.forEachActive([&](Voice& v) noexcept {
                for (const OscVoice& o : v.osc) banks_.mark(o.bank);
            });
            banks_.idle();
        }

        // The instrument's own parameters, moved by the newest voice.
        const auto g = [&](uint32_t k) noexcept { return value(k, globalOffsets_); };
        const double velocityAmount = clampd(g(kVelocity), 0.0, 1.0);
        voices_.forEachActive([&](Voice& v) noexcept {
            v.gain1 = 1.0 - velocityAmount * (1.0 - v.velocity);
            if (v.starting) {
                v.gain0 = v.gain1;
                v.starting = false;
            }
        });
        volume1_ = clampd(g(kVolume), 0.0, 1.0);
        // The effects read the knobs, the tempo, the quality and the slots moving the instrument's parameters.
        // (Every control while a knob ramps, as before: the chorus's sweep moves on at each of its controls.)
        if (knobsChanged_ || rampCount_ > 0 || (moved_ & kMovedGlobal)) configureEffects(g);

        knobsChanged_ = false;
        // Nothing sounding and the tails below -94 dB for long enough: clear the effects and rest (not while the
        // host has voice-bus lanes: their FX tails run through this instrument's periods).
        if (voices_.activeCount() == 0 && !lanes_.any()) {
            const bool fx = distOn_ || eqOn_ || chorusOn_ || delayOn_ || reverbOn_;
            const double window = fx ? 0.1 * sr_ + (delayOn_ ? delayTime1_ : 0.0) : 0.0;
            if (static_cast<double>(quietRun_) >= window) {
                clearEffects();
                shared_.clear();
                sharedQuiet_ = true;
                sharedRan_ = false;
                sharedPeak_ = 0.0f;
                idle_ = true;
            }
        } else {
            quietRun_ = 0;
        }
    }

    // The shared filter 1 from the knobs (unmodulated): used when it is linear, filter 2 is off and nothing
    // follows the pitch (a voice compares its own settings with it each period).
    void configureShared() noexcept {
        const auto K = [&](uint32_t f, uint32_t p) noexcept { return base_[fltParam(f, p)]; };
        const bool on = K(0, kFltOn) >= 0.5;
        shared_.configure(on, clampi(K(0, kFltType), 0, kFilterTypeCount - 1), K(0, kFltCutoff),
                          clampd(K(0, kFltResonance), 0.0, 1.0), K(0, kFltDrive), K(0, kFltMorph), K(0, kFltMix), sr_, false);
        // Poly only: mono and legato play one voice (nothing to share), and keep their level after the filter.
        sharedOn_ = on && shared_.linear() && K(0, kFltKeytrack) == 0.0 && K(1, kFltOn) < 0.5 &&
                    clampi(base_[kVoiceMode], 0, 2) == kPoly;
    }

    // A control period of white noise (-1..1, xorshift) for the oscillators whose mod source is Noise: drawn on the
    // control grid, so every block size hears the same.
    static void drawNoise(Voice& v) noexcept {
        uint32_t x = v.noise;
        for (float& y : v.fmBuf[kNoiseRow]) {
            x ^= x << 13, x ^= x >> 17, x ^= x << 5;
            y = static_cast<float>(static_cast<int32_t>(x)) * 4.656612873077393e-10f;
        }
        v.noise = x;
    }

    void buildMatrix() noexcept {
        std::memset(targetOf_, 0, sizeof targetOf_);
        slotCount_ = targetCount_ = 0;
        used_ = 0;
        moved_ = 0;
        for (uint32_t s = 0; s < kSlots; ++s) {
            const int src = clampi(base_[modParam(s, kModSource)], 0, kSourceCount - 1);
            const int dst = clampi(base_[modParam(s, kModTarget)], 0, kModTargets) - 1;
            const double amount = clampd(base_[modParam(s, kModAmount)], -1.0, 1.0);
            if (src == kSrcNone || dst < 0 || amount == 0.0) continue;
            if (!targetOf_[dst]) {
                targetParam_[targetCount_] = static_cast<uint32_t>(dst);
                // A choice list 1.1.0 appended to (tables, warps, filter types) moves a 1.0 choice within 1.0's list, as
                // 1.0.9 did (legacyChoiceCount, params.h's modulationTop; 1.1.1).
                const double top = modulationTop(params().d[dst], base_[dst]);
                targetTop_[targetCount_] = top;
                targetNorm_[targetCount_] = toNorm(static_cast<uint32_t>(dst), base_[dst], top);
                targetOf_[dst] = static_cast<uint8_t>(++targetCount_);
            }
            const int via = clampi(base_[viaParam(s)], 0, kSourceCount - 1);
            slots_[slotCount_++] = {src, targetOf_[dst] - 1, amount, base_[modParam(s, kModPolarity)] >= 0.5, via};
            moved_ |= sectionOf(static_cast<uint32_t>(dst));
            used_ |= (1u << src) | (via != kSrcNone ? 1u << via : 0u);
        }
    }

    // A note's start, with the knobs (unmodulated) at its frame: the retriggered LFOs and the random source
    // restart, and a fresh voice (not a stolen one) takes its copies' start phases and its comb lines.
    void startVoice(Voice& v) noexcept {
        for (uint32_t l = 0; l < kLfos; ++l) {
            v.lfo[l].prepare(sr_);
            v.lfo[l].setSeed(v.seed + l);
            v.lfo[l].retrigger();
        }
        v.random.prepare(sr_);
        v.random.setSeed(v.seed ^ 0xA511E9B3U);
        v.random.retrigger();
        std::memset(v.fmBuf, 0, sizeof v.fmBuf);
        v.noise = (v.seed ^ 0x6C8E9CF5U) | 1U;
        if (!v.fresh) return;
        for (OscVoice& o : v.osc) o.foldL.clear(), o.foldR.clear(), o.foldM.clear(), o.clearFold();
        v.shared = true;  // until its filter 1 is set unlike the shared one (then its own, to the note's end)
        for (uint32_t o = 0; o < kOscs; ++o) {
            const double start = base_[oscParam(o, kOscPhase)], randomness = base_[oscParam(o, kOscPhaseRand)];
            for (int c = 0; c < kMaxCopies; ++c) {
                const double r = static_cast<double>(hash32(v.seed ^ ((o * 16U + c + 1U) * 0x85EBCA6BU))) / 4294967296.0;
                v.osc[o].phase[c] = static_cast<uint32_t>(static_cast<uint64_t>(lib::wrap01(start + randomness * r) * 4294967296.0));
            }
        }
        const uint32_t index = static_cast<uint32_t>(&v - voices_.begin());
        for (uint32_t f = 0; f < kFilters; ++f)
            for (int c = 0; c < 2; ++c) v.filter[f].comb[c] = &combs_[index][f * 2 + c];
    }

    // The voice section a parameter belongs to (a bit of moved_), kMovedGlobal for the instrument-wide ones.
    static uint32_t sectionOf(uint32_t k) noexcept {
        if (k < kFltBase) return 1u << (k / kOscCount);                    // osc 1..3: bits 0..2
        if (k < kFltRouting) return 1u << (3 + (k - kFltBase) / kFltCount);  // filter 1, 2: bits 3, 4
        if (k == kFltRouting) return kMovedRouting;
        if (k < kLfoBase) return kMovedEnvs;
        if (k < kVolume) return kMovedLfos;
        return kMovedGlobal;
    }
    static constexpr uint32_t kMovedRouting = 1u << 5, kMovedEnvs = 1u << 6, kMovedLfos = 1u << 7, kMovedGlobal = 1u << 8;
    static constexpr uint32_t kMovedFilter1 = 1u << 3, kMovedFilter2 = 1u << 4;
    // The sections a ramping knob may move alone (rampMoved_): the oscillators, the filters, the routing, the envelopes.
    static constexpr uint32_t kRampSections = 7u | kMovedFilter1 | kMovedFilter2 | kMovedRouting | kMovedEnvs;
