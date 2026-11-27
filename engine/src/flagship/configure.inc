// FlagshipInstrument's per-control configuration of voices, oscillators and effects (hand-written; included by builtin_flagship.cpp, not compiled alone).
    void configureVoice(Voice& v, const double* offsets) noexcept {
        // The values the slots move, once each (an exp for each one away from its knob).
        double moving[kSlots];
        for (uint32_t t = 0; t < targetCount_; ++t)
            moving[t] = offsets[t] != 0.0 ? modulated(targetParam_[t], static_cast<int>(t), offsets) : base_[targetParam_[t]];
        const auto P = [&](uint32_t k) noexcept {
            const int t = k < kModTargets ? targetOf_[k] : 0;  // parameters after the slots (FM ratios) aren't targets
            return t ? moving[t - 1] : base_[k];
        };
        // Only what changed: every section at a note's start or after a knob moved; else the sections where a value
        // a slot moves is not what it was at the last control (a slot whose source rests changes nothing), and what
        // follows the pitch (it glides, bends). An oscillator whose frame alone moved (an LFO sweeping the table)
        // only re-reads its frames (2026-11-10 second performance pass).
        const bool all = v.starting || knobsChanged_;
        const bool pitch = v.pitch != v.configuredPitch;
        v.configuredPitch = v.pitch;
        uint32_t changed = rampMoved_, frameOnly = 0;
        if (!all) {
            uint32_t frame = 0, other = rampMoved_;
            for (uint32_t t = 0; t < targetCount_; ++t) {
                if (moving[t] == v.moving[t]) continue;
                const uint32_t k = targetParam_[t], section = sectionOf(k);
                changed |= section;
                (k < kFltBase && k % kOscCount == kOscFrame ? frame : other) |= section;
            }
            frameOnly = pitch ? 0u : frame & ~other;
        }
        std::copy(moving, moving + targetCount_, v.moving);
        const auto moved = [&](uint32_t bits) noexcept { return all || (changed & bits) != 0; };
        // Only what a slot listens to runs (env 1 always: it is the level).
        for (uint32_t e = 0; e < kEnvs && moved(kMovedEnvs); ++e)
            if (e == 0 || uses(kSrcEnv1 + e))
                v.env[e].set(P(envParam(e, kEnvAttack)), P(envParam(e, kEnvDecay)), P(envParam(e, kEnvSustain)),
                             P(envParam(e, kEnvRelease)), sr_);
        for (uint32_t l = 0; l < kLfos && moved(kMovedLfos); ++l) {
            if (!uses(lfoSource(l)) || !retriggered(l)) continue;  // unused, or the instrument's
            const int sync = clampi(P(lfoParam(l, kLfoSync)), 0, 9);
            v.lfo[l].setShape(static_cast<lib::LfoShape>(clampi(P(lfoParam(l, kLfoShape)), 0, 6)));
            if (sync > 0) v.lfo[l].setRateBeats(kLfoSyncBeats[sync], tempo_);
            else v.lfo[l].setRateHz(P(lfoParam(l, kLfoRate)));
        }
        if (uses(kSrcRandom) && moved(kMovedLfos)) {
            v.random.setShape(P(kRndMode) >= 0.5 ? lib::LfoShape::SmoothRandom : lib::LfoShape::SampleHold);
            v.random.setRateHz(P(kRndRate));
        }
        for (uint32_t o = 0; o < kOscs; ++o) {
            if (v.osc[o].bankPending) configureOscillator(v, o, P);  // its bank may be ready now
            else if (frameOnly & (1u << o)) moveFrame(v.osc[o], P(oscParam(o, kOscFrame)));
            else if (moved(1u << o)) configureOscillator(v, o, P);
            else if (pitch) retune(v.osc[o], v.pitch);
        }
        if (moved(kMovedRouting)) v.parallel = P(kFltRouting) >= 0.5;
        for (uint32_t f = 0; f < kFilters; ++f) {
            // The pitch moves a filter only through its key tracking.
            if (!moved(1u << (3 + f)) && !(pitch && P(fltParam(f, kFltKeytrack)) != 0.0)) continue;
            if (P(fltParam(f, kFltOn)) < 0.5) {
                v.filter[f].configure(false, 0, 0, 0, 1, 0, 1, sr_, v.starting && v.fresh);
                continue;
            }
            const double keytrack = P(fltParam(f, kFltKeytrack));
            const double cutoff = P(fltParam(f, kFltCutoff)) * (keytrack != 0.0 ? exp2(keytrack * (v.pitch - 60.0) / 12.0) : 1.0);
            v.filter[f].configure(true, clampi(P(fltParam(f, kFltType)), 0, kFilterTypeCount - 1),
                                  cutoff, clampd(P(fltParam(f, kFltResonance)), 0.0, 1.0), P(fltParam(f, kFltDrive)),
                                  P(fltParam(f, kFltMorph)), P(fltParam(f, kFltMix)), sr_, v.starting && v.fresh);
        }
        v.fresh = false;
    }

    // Only the frame position moved: the copies keep their steps, mip levels and gains, and read the new pair of
    // frames (the same frames and morph as configureOscillator works out).
    void moveFrame(OscVoice& o, double frame) noexcept {
        if (!o.on || o.key.table < 0) return;
        const double position = clampd(frame, 0.0, 1.0);
        if (position == o.key.position) return;
        o.key.position = position;
        const double at = position * (o.frames - 1);
        const int f0 = static_cast<int>(at), f1 = f0 + 1 < o.frames ? f0 + 1 : f0;
        o.mix = static_cast<float>(at - f0);
        if (f0 == o.f0 && f1 == o.f1) return;
        o.f0 = f0;
        o.f1 = f1;
        for (int c = 0; c < o.count; ++c)
            if (o.a[c]) o.point(c, o.level[c]);
    }

    // Whether a fresh note's oscillator folds at twice the rate (foldTwiceFor), from the highest pitch it may
    // play: the note, the oscillator's tuning, its unison stack's top copy (its interval and detune), and the
    // bend range up. The drive is the most it can reach: the knob's, or the full 8 when a slot moves it.
    template <class Get>
    bool foldTwiceAtStart(const Voice& v, uint32_t index, const Get& P) const noexcept {
        const auto at = [&](uint32_t p) noexcept { return P(oscParam(index, p)); };
        const int copies = clampi(at(kOscUnison), 1, kMaxCopies);
        const auto stack = static_cast<lib::UnisonStack>(clampi(at(kOscStack), 0, lib::kUnisonStackCount - 1));
        double top = 0.0;
        for (int c = 0; c < copies; ++c) top = std::max(top, lib::unisonStackSemitones(stack, c));
        if (copies > 1) top += clampd(at(kOscDetune), 0.0, 100.0) / 100.0;
        const double pitch = v.notePitch + 12.0 * clampi(at(kOscOctave), -4, 4) + clampi(at(kOscSemi), -12, 12) +
                             clampd(at(kOscFine), -100.0, 100.0) / 100.0 + top + clampd(base_[kBendRange], 1.0, 48.0);
        const bool moved = targetOf_[oscParam(index, kOscWarpAmount)] != 0;
        const double drive = moved ? 8.0 : 1.0 + 7.0 * clampd(at(kOscWarpAmount), 0.0, 1.0);
        return foldTwiceFor(440.0 * exp2((pitch - 69.0) / 12.0) * 48000.0 / sr_, drive);
    }

    template <class Get>
    void configureOscillator(Voice& v, uint32_t index, const Get& P) noexcept {
        OscVoice& o = v.osc[index];
        const auto at = [&](uint32_t p) noexcept { return P(oscParam(index, p)); };
        if (v.starting && v.fresh) v.foldTwice[index] = foldTwiceAtStart(v, index, P);
        o.on = at(kOscOn) >= 0.5;
        if (!o.on) {
            o.count = 0;
            o.bank = nullptr;
            o.bankPending = false;
            o.key.table = -1;  // on again: everything is worked out afresh
            o.layoutKey.voices = -1;
            return;
        }
        o.dest = clampi(at(kOscDest), 0, 3);
        {
            const int src = clampi(P(modSrcParam(index)), 0, 4);  // Prev, Osc 1..3 (itself: Prev), Noise
            o.modSrc = src == 4 ? static_cast<int>(kNoiseRow)
                                : (src == 0 || src - 1 == static_cast<int>(index) ? static_cast<int>(fmSource(index)) : src - 1);
        }
        o.blep = !v.ecoWarps;
        OscKey key;
        key.table = clampi(at(kOscTable), 0, kTableChoices - 1);
        key.position = clampd(at(kOscFrame), 0.0, 1.0);
        key.level = clampd(at(kOscLevel), 0.0, 1.0);
        key.pan = clampd(at(kOscPan), -1.0, 1.0);
        o.pitchOffset[0] = 12.0 * clampi(at(kOscOctave), -4, 4);
        o.pitchOffset[1] = clampi(at(kOscSemi), -12, 12);
        o.pitchOffset[2] = clampd(at(kOscFine), -100.0, 100.0) / 100.0;
        key.pitch = v.pitch + o.pitchOffset[0] + o.pitchOffset[1] + o.pitchOffset[2];
        key.amount = clampd(at(kOscWarpAmount), 0.0, 1.0);
        key.warp = key.amount > 0.0 ? clampi(at(kOscWarp), 0, kWarpCount - 1) : kWarpNone;
        // A spectral warp reads its bank: until it is built (live: by the worker, a few tens of ms), unwarped.
        const flagship::Bank* bank = spectral(key.warp) ? banks_.find(source_[key.table], key.warp - kWarpStretch) : nullptr;
        o.bankPending = spectral(key.warp) && !bank;
        key.bank = bank;
        key.fmRatio = key.warp == kWarpFm ? clampi(P(fmRatioParam(index)), 1, 16) : 1;
        // Eco quality renders the FM warp at the sample rate (no 2x oversampling): it aliases more. The voice's
        // choice from its start holds while it sounds. (The fold runs at the sample rate at every quality: addFold.)
        key.once = key.warp == kWarpFm && v.ecoWarps;
        key.foldWhole = key.warp == kWarpFold && P(foldModeParam(index)) >= 0.5;
        // A high note's fold at twice the rate (the voice's choice from its start); Eco folds every note with ADAA.
        key.foldTwice = key.warp == kWarpFold && v.foldTwice[index] && !v.ecoWarps;
        if (key.warp == kWarpFmOsc && o.modSrc < static_cast<int>(kOscs)) {  // the modulator's tuning against this one's
            const uint32_t m = static_cast<uint32_t>(o.modSrc);
            const double offset = 12.0 * clampi(P(oscParam(m, kOscOctave)), -4, 4) + clampi(P(oscParam(m, kOscSemi)), -12, 12) +
                                  clampd(P(oscParam(m, kOscFine)), -100.0, 100.0) / 100.0;
            key.modRatio = exp2((offset - o.pitchOffset[0] - o.pitchOffset[1] - o.pitchOffset[2]) / 12.0);
        }
        lib::UnisonSettings& u = key.unison;
        // Eco quality caps each oscillator at 4 copies (the outermost and the centre kept: the stack is laid out
        // again for 4, so its detune and spread stay as wide).
        u.voices = clampi(at(kOscUnison), 1, qualityNow(quality_) == kQualityEco ? kEcoCopies : kMaxCopies);
        u.detune = clampd(at(kOscDetune), 0.0, 100.0) / 100.0;
        u.power = at(kOscPower);
        u.spread = at(kOscSpread);
        u.blend = at(kOscBlend);
        u.stack = static_cast<lib::UnisonStack>(clampi(at(kOscStack), 0, lib::kUnisonStackCount - 1));
        if (key == o.key) return;  // nothing moved: the copies keep their steps, levels and gains

        const lib::Wavetable& table = bank ? bank->table : *table_[key.table];
        o.reading = &table;
        o.bank = bank;
        o.frames = bank ? bank->frames : table.frameCount();
        if (bank) {  // the two of the bank's eight amounts the warp amount sits between
            const double level = key.amount * (flagship::kBankLevels - 1);
            const int l0 = std::min(static_cast<int>(level), flagship::kBankLevels - 1);
            const int l1 = std::min(l0 + 1, flagship::kBankLevels - 1);
            o.base0 = l0 * o.frames;
            o.base1 = l1 * o.frames;
            o.amix = static_cast<float>(level - l0);
        } else {
            o.base0 = o.base1 = 0;
            o.amix = 0.0f;
        }
        const double position = key.position * (o.frames - 1);
        const int f0 = static_cast<int>(position), f1 = f0 + 1 < o.frames ? f0 + 1 : f0;
        o.mix = static_cast<float>(position - f0);
        o.f0 = f0;
        o.f1 = f1;
        {
            // Only the frame position moved (an LFO sweeping the table): the copies keep their steps, mip levels
            // and gains, and just read the new pair of frames.
            OscKey moved = key;
            moved.position = o.key.position;
            if (moved == o.key) {
                o.key = key;
                for (int c = 0; c < o.count; ++c)
                    if (o.a[c]) o.point(c, o.level[c]);
                return;
            }
        }
        if (!(u == o.layoutKey)) {
            o.layoutKey = u;
            o.count = lib::unisonLayout(u, o.layout);
            for (int c = 0; c < o.count; ++c) o.ratio[c] = exp2(o.layout[c].semitones / 12.0);
            o.panKey = 2.0;  // the pans follow the layout
        }
        if (key.pan != o.panKey) {
            o.panKey = key.pan;
            for (int c = 0; c < o.count; ++c) {
                const double q = clampd(key.pan + o.layout[c].pan, -1.0, 1.0);
                double l = 1.0, r = 1.0;  // the centre at unity on both sides, exactly
                if (q != 0.0) {  // mirror pans get mirror gains, bit for bit
                    const lib::PanGains g = lib::constantPowerPan(q < 0.0 ? -q : q);
                    l = g.left * 1.41421356237309505;
                    r = g.right * 1.41421356237309505;
                    if (q < 0.0) std::swap(l, r);
                }
                o.panL[c] = l * o.layout[c].gain;
                o.panR[c] = r * o.layout[c].gain;
            }
        }
        if (key.pitch != o.key.pitch || o.key.table < 0) o.hz = 440.0 * exp2((key.pitch - 69.0) / 12.0);
        // The warp's constants, and how much faster than the note it reads the table (for the mip level).
        const double amount = key.amount;
        double faster = 1.0;
        switch (key.warp) {
            case kWarpBend:
                o.w1 = static_cast<float>(amount);
                faster = 1.0 + amount;
                break;
            case kWarpSync:
                o.w1 = static_cast<float>(1.0 + 7.0 * amount);
                faster = o.w1;
                break;
            case kWarpMirror:
                o.w1 = static_cast<float>(1.0 - 0.5 * amount);  // the turn
                o.w2 = static_cast<float>(1.0 / (1.0 - 0.5 * amount));
                o.w3 = static_cast<float>(1.0 / (0.5 * amount));
                faster = 1.0 / (1.0 - 0.5 * amount);
                break;
            case kWarpQuantize: {
                const double steps = std::floor(exp2(8.0 - 7.0 * amount));  // 256 .. 2 steps a cycle
                o.w1 = static_cast<float>(steps);
                o.w2 = static_cast<float>(1.0 / steps);
                break;
            }
            case kWarpFm:
                o.w1 = static_cast<float>(0.75 * amount);  // up to 0.75 cycles: an index of about 4.7 radians
                o.w2 = static_cast<float>(key.fmRatio);
                faster = 1.0 + kTwoPi * 0.75 * amount * key.fmRatio;  // the fastest the modulated phase runs
                break;
            case kWarpFold:
                o.w1 = static_cast<float>(1.0 + 7.0 * amount);  // drive 1..8
                o.w2 = static_cast<float>(amount < 0.25 ? 4.0 * amount : 1.0);
                // Folding spreads the table's harmonics about as far as the drive. The mip level is the one the 2x
                // oversampled fold read (half the drive: #197 kept the table's brightness; ADAA, not the mip
                // level, keeps the aliases down).
                faster = 0.5 * o.w1 > 1.0 ? 0.5 * o.w1 : 1.0;
                break;
            case kWarpOscRm:
            case kWarpOscAm: o.w1 = static_cast<float>(amount); break;
            case kWarpOscSync:
                o.w1 = static_cast<float>(1.0 + 7.0 * amount);  // the sync sweep: up to 8 times the copy's own speed
                faster = o.w1;
                break;
            case kWarpFmOsc:
                // Up to one cycle of phase per unit of the modulator (an index of 2 pi for a full-scale sine). The
                // fastest the modulated phase runs, for a sine modulator at its pitch: 1 + 2 pi depth ratio.
                o.w1 = static_cast<float>(amount);
                faster = 1.0 + kTwoPi * amount * key.modRatio;
                break;
            default: break;
        }
        const bool twice = (key.warp == kWarpFm && !key.once) || key.foldTwice;
        if (twice && (o.warpMode != key.warp || o.key.table < 0 || o.key.once || o.key.foldTwice != key.foldTwice)) {
            // into FM or the 2x fold: fresh decimators
            o.foldL.set(half_);
            o.foldR.set(half_);
            o.foldM.set(half_);
        }
        // Into the fold, or to its other mode: its anti-aliasing starts from 0, as a voice does.
        if (key.warp == kWarpFold && (o.warpMode != kWarpFold || o.key.table < 0 || o.key.foldWhole != key.foldWhole))
            o.clearFold();
        o.warpMode = spectral(key.warp) && !bank ? kWarpNone : key.warp;
        o.key = key;
        o.faster = faster;
        tuneCopies(o, table);
    }

    // The pitch alone moved (a glide, a bend): the copies' steps and mip levels follow it; nothing else changed.
    void retune(OscVoice& o, double notePitch) noexcept {
        if (!o.on || o.key.table < 0) return;
        const double pitch = notePitch + o.pitchOffset[0] + o.pitchOffset[1] + o.pitchOffset[2];  // configureOscillator's sum
        if (pitch == o.key.pitch) return;
        o.key.pitch = pitch;
        o.hz = 440.0 * exp2((pitch - 69.0) / 12.0);
        tuneCopies(o, *o.reading);
    }

    // Each copy's step, mip level, frames and gains, from the oscillator's pitch, frames and layout.
    void tuneCopies(OscVoice& o, const lib::Wavetable& table) noexcept {
        const double faster = o.faster;
        const OscKey& key = o.key;
        const double perSample = o.hz / sr_;
        for (int c = 0; c < o.count; ++c) {
            const double dt = perSample * o.ratio[c];
            if (!(dt > 0.0 && dt < 0.5)) {  // above Nyquist: silent
                o.a[c] = o.b[c] = nullptr;
                o.dt[c] = 0.0;
                continue;
            }
            const int k = mipLevel(dt * faster, table.levels());
            o.dt[c] = dt;
            o.point(c, k);
            o.size[c] = static_cast<float>(table.levelSize(k));
            o.level[c] = k;
            o.step[c] = static_cast<uint32_t>(dt * 4294967296.0 + 0.5);
            o.shift[c] = 32 - std::countr_zero(static_cast<uint32_t>(table.levelSize(k)));
            o.gainL[c] = static_cast<float>(o.panL[c] * key.level);
            o.gainR[c] = static_cast<float>(o.panR[c] * key.level);
            o.monoGain[c] = static_cast<float>(0.25 * (o.panL[c] + o.panR[c]));
            o.stackL[c] = static_cast<float>(o.panL[c]);
            o.stackR[c] = static_cast<float>(o.panR[c]);
        }
        o.levelGain = static_cast<float>(key.level);
        o.centred = true;
        o.stackCentred = true;
        for (int c = 0; c < o.count; ++c) {
            o.centred = o.centred && (!o.a[c] || o.gainL[c] == o.gainR[c]);
            o.stackCentred = o.stackCentred && (!o.a[c] || o.stackL[c] == o.stackR[c]);
        }
    }

    template <class Get>
    void configureEffects(const Get& g) noexcept {
        const bool dist = g(kDistOn) >= 0.5, eq = g(kEqOn) >= 0.5, chorus = g(kChorusOn) >= 0.5,
                   delay = g(kDelayOn) >= 0.5, reverb = g(kReverbOn) >= 0.5;
        // An effect switched on starts from silence (not from a tail it held when it was switched off).
        // (Only one that ran since its last clear holds anything: the delay and reverb hold seconds of memory.)
        if (eq && !eqOn_ && (fxDirty_ & kFxEq)) eqL_.clear(), eqR_.clear();
        if (chorus && !chorusOn_ && (fxDirty_ & kFxChorus)) chorus_.clear();
        if (delay && !delayOn_ && (fxDirty_ & kFxDelay)) delay_.clear();
        if (reverb && !reverbOn_ && (fxDirty_ & kFxReverb)) reverb_.clear();
        const bool delayWasOn = delayOn_;
        fxDirty_ |= (eq ? kFxEq : 0u) | (chorus ? kFxChorus : 0u) | (delay ? kFxDelay : 0u) | (reverb ? kFxReverb : 0u);
        distOn_ = dist;
        eqOn_ = eq;
        chorusOn_ = chorus;
        delayOn_ = delay;
        reverbOn_ = reverb;
        if (dist) {
            distType_ = clampi(g(kDistType), 0, 3);
            distDrive_ = clampd(g(kDistDrive), 1.0, 20.0);
            distMix_ = clampd(g(kDistMix), 0.0, 1.0);
            saturator_.set(distDrive_);
            // Crush: 24 bits at drive 1 down to 2 at drive 20.
            crushSteps_ = std::floor(exp2(std::floor(24.0 - 22.0 * (distDrive_ - 1.0) / 19.0) - 1.0));
        }
        if (eq) {
            const double low = g(kEqLow), mid = g(kEqMid), high = g(kEqHigh), freq = g(kEqMidFreq);
            eqL_.set(low, mid, high, freq, sr_);
            eqR_.set(low, mid, high, freq, sr_);
            eqMix_ = clampd(g(kEqMix), 0.0, 1.0);
        }
        if (chorus) {
            chorus_.control(g(kChorusRate), clampd(g(kChorusDepth), 0.0, 1.0), kControlFrames);
            chorusMix_ = clampd(g(kChorusMix), 0.0, 1.0);
        }
        if (delay) {
            const int sync = clampi(g(kDelaySync), 0, 7);
            const double seconds = sync > 0 ? lib::noteSeconds(tempo_, kDelaySyncWholes[sync]) : g(kDelayTime);
            delayTime1_ = clampd(seconds, 0.001, 4.0) * sr_;  // in frames
            if (!delayWasOn) delayTime0_ = delayTime1_;  // switched on: no glide from an old time
            delayFeedback_ = clampd(g(kDelayFeedback), 0.0, 0.95);
            delayMix_ = clampd(g(kDelayMix), 0.0, 1.0);
        }
        if (reverb) {
            reverb_.setLight(qualityNow(quality_) == kQualityEco);
            lib::ReverbSettings s;
            s.size = g(kReverbSize);
            s.decay = g(kReverbDecay);
            s.damping = g(kReverbDamping);
            s.mix = g(kReverbMix);
            const lib::ReverbSettings& was = reverb_.settings();
            if (s.size != was.size || s.decay != was.decay || s.damping != was.damping || s.mix != was.mix) reverb_.set(s);
        }
    }

    // The delay and reverb hold seconds of memory (a 4 s delay line is 1.5 MB): a clear (every Play, every rest)
    // touches them only when they ran since the last one.
    void clearEffects() noexcept {
        quietRun_ = 0;
        if (fxDirty_ & kFxEq) eqL_.clear(), eqR_.clear();
        if (fxDirty_ & kFxChorus) chorus_.clear();
        if (fxDirty_ & kFxDelay) delay_.clear();
        if (fxDirty_ & kFxReverb) reverb_.clear();
        fxDirty_ = 0;
    }

    // A constant-size memset the compiler writes as a few vector stores (a plain loop can become a memset call).
    static void zero(float* x) noexcept { std::memset(x, 0, kControlFrames * sizeof(float)); }
