// DrumsProcessor's notes, groove, scheduling and voice allocation (hand-written; included by builtin_drums.cpp, not compiled alone).
    // ---------- Notes ----------

    // Whether a note on MIDI channel `ch` (0..15) reaches pad settings with channel choice `chan`.
    bool channelMatches(int chan, int ch) const noexcept {
        if (chan == 0) return channel_ == 0 || channel_ == ch + 1;  // Kit: the instrument's channel
        if (chan == 1) return true;                                // Any
        return chan - 2 == ch;
    }

    void noteOn(const NoteMessage& m, uint32_t at) noexcept {
        const ProcessBlock& b = *block_;
        lastKey_ = m.key;
        lastChannel_ = m.channel + 1;
        lastVelocity_ = static_cast<float>(clampd(m.velocity, 0, 1));
        ++notesSeen_;
        if (mode_ == kModeSingle) {
            if (channel_ == 0 || channel_ == m.channel + 1) trigger(0, m, at);
            return;
        }
        bool any = false;
        // Pads playing chromatically on their own channel take every note there; the others their note.
        for (uint32_t p = 0; p < kPads; ++p) {
            const Voice& def = defaultVoice(p);
            const int note = clampi(parameterAt(b, padParam(p, kNote), at, def[kNote]), 0, kNoteFirst + 127);
            if (note == kNoteOff) continue;
            const int chan = clampi(parameterAt(b, padParam(p, kChan), at, def[kChan]), 0, 17);
            if (!channelMatches(chan, m.channel)) continue;
            const bool track = parameterAt(b, padParam(p, kTrack), at, def[kTrack]) >= 0.5;
            const bool chromatic = track && chan >= 2;
            const int key = note == kNoteAuto ? autoNote(p, base_) : note - kNoteFirst;
            if (chromatic || (note != kNoteAny && key == m.key)) any = trigger(p, m, at) || any;
        }
        if (any) return;
        for (uint32_t p = 0; p < kPads; ++p) {
            const Voice& def = defaultVoice(p);
            if (clampi(parameterAt(b, padParam(p, kNote), at, def[kNote]), 0, kNoteFirst + 127) != kNoteAny) continue;
            if (!channelMatches(clampi(parameterAt(b, padParam(p, kChan), at, def[kChan]), 0, 17), m.channel)) continue;
            trigger(p, m, at);
        }
    }

    void noteOff(const NoteMessage& m, uint32_t at) noexcept {
        if (acoustic_.awake()) acoustic_.release(m.noteId);  // a roll ends with its note (1.1.2)
        for (uint32_t i = 0; i < pending_; ++i)  // a held-back hit of this note: it ends as soon as it starts
            if (pendingHits_[i].m.noteId == m.noteId) pendingHits_[i].released = true;
        for (uint32_t i = 0; i < live_; ++i) {
            DrumVoice& v = voices_[list_[i]];
            if (!v.active || v.noteId != m.noteId) continue;
            const PadSettings& s = settings_[v.pad];
            removeHeld(static_cast<uint32_t>(v.pad), m.noteId);
            if (s.mono && s.track && heldCount_[v.pad] > 0) {  // back to the newest note still held, gliding
                const auto& top = held_[v.pad][heldCount_[v.pad] - 1];
                v.noteId = top.first;
                v.note = top.second;
                v.glideTarget = v.note - s.root;
                continue;
            }
            v.held = false;
            if (s.gate && !v.releasing) {
                v.releasing = true;
                v.relCoef = fall(s.release, sr_);
            }
        }
        (void)at;
    }

    void addHeld(uint32_t pad, uint32_t id, double note) noexcept {
        auto& h = held_[pad];
        uint32_t& n = heldCount_[pad];
        if (n == kHeldMax) {  // full: the oldest goes
            for (uint32_t i = 1; i < n; ++i) h[i - 1] = h[i];
            --n;
        }
        h[n++] = {id, note};
    }
    void removeHeld(uint32_t pad, uint32_t id) noexcept {
        auto& h = held_[pad];
        uint32_t& n = heldCount_[pad];
        uint32_t keep = 0;
        for (uint32_t i = 0; i < n; ++i)
            if (h[i].first != id) h[keep++] = h[i];
        n = keep;
    }

    // A deterministic number in -1..1: the variation seed, the pad, its hit count and which value.
    double random(uint32_t pad, uint32_t which) const noexcept {
        const uint32_t x = hash32(seed_ * 0x9E3779B1u ^ hash32(pad * 0x85EBCA77u ^ hash32(hits_[pad] * 0xC2B2AE3Du ^ which)));
        return static_cast<double>(x) * (2.0 / 4294967295.0) - 1.0;
    }

    // ---------- Groove (1.1.0; docs/engine.md, "Drums", Groove) ----------

    // Each groove's 16 steps (a bar of 16ths): how late a hit on the step comes (in 16ths) and its velocity's scale.
    struct GrooveStep {
        double late, vel;
    };
    static const GrooveStep* grooveSteps(int g) noexcept {
        static constexpr GrooveStep kSteps[kGrooveCount][16] = {
            {},
            // Shuffle: every off 16th a third late and softer.
            {{0, 1}, {0.33, 0.78}, {0, 0.92}, {0.33, 0.78}, {0, 1}, {0.33, 0.78}, {0, 0.92}, {0.33, 0.78},
             {0, 1}, {0.33, 0.78}, {0, 0.92}, {0.33, 0.78}, {0, 1}, {0.33, 0.78}, {0, 0.92}, {0.33, 0.78}},
            // Laid back: the backbeats (steps 5 and 13) a quarter late, the off 16ths a little.
            {{0, 1}, {0.08, 0.85}, {0.04, 0.9}, {0.08, 0.85}, {0.25, 1}, {0.08, 0.85}, {0.04, 0.9}, {0.08, 0.85},
             {0, 1}, {0.08, 0.85}, {0.04, 0.9}, {0.08, 0.85}, {0.25, 1}, {0.08, 0.85}, {0.04, 0.9}, {0.08, 0.85}},
            // Gallop: each beat's second and third 16ths pulled toward its end, the beat strong.
            {{0, 1}, {0.33, 0.7}, {0.15, 0.85}, {0, 0.75}, {0, 1}, {0.33, 0.7}, {0.15, 0.85}, {0, 0.75},
             {0, 1}, {0.33, 0.7}, {0.15, 0.85}, {0, 0.75}, {0, 1}, {0.33, 0.7}, {0.15, 0.85}, {0, 0.75}},
            // Broken: an uneven bar, its timing and weight off the grid in places.
            {{0, 1}, {0.1, 0.7}, {0, 0.9}, {0.3, 0.8}, {0, 0.95}, {0.05, 0.65}, {0.2, 0.85}, {0, 0.7},
             {0, 1}, {0.25, 0.75}, {0, 0.85}, {0.1, 0.7}, {0, 0.95}, {0, 0.6}, {0.3, 0.9}, {0.1, 0.7}},
            // Half-time: beat 3 the strong one, beats 2 and 4 soft, the 16ths lighter.
            {{0, 1}, {0.05, 0.7}, {0, 0.8}, {0.05, 0.7}, {0, 0.75}, {0.05, 0.7}, {0, 0.8}, {0.05, 0.7},
             {0, 1.15}, {0.05, 0.7}, {0, 0.8}, {0.05, 0.7}, {0, 0.75}, {0.05, 0.7}, {0, 0.8}, {0.05, 0.7}},
        };
        return kSteps[g < 0 || g >= kGrooveCount ? 0 : g];
    }

    // A note for `pad`: played now, or (its pad's groove moving it) held back and played later, with a flam's grace
    // hit before it. False when the pad is unused. Without groove settings it is the plain hit.
    bool trigger(uint32_t pad, const NoteMessage& m, uint32_t at) noexcept {
        PadSettings& s = settings_[pad];
        readPad(*block_, pad, at, s, blockCount_);
        if (!s.used) return false;
        if (!s.groovy) return hit(pad, m, at);
        NoteMessage n = m;
        double late = 0.0, accent = 0.0;  // late: seconds
        // Where the note sits: in 16ths of the song, when a transport plays (preview notes have none).
        const Transport* tr = block_->transport;
        const bool grid = tr && tr->playing && tr->tempo > 0.0;
        double sixteenth = 0.125;
        long step = -1;
        if (grid) {
            sixteenth = 15.0 / tr->tempo;
            const double pos = (tr->beat + at / sr_ * tr->tempo / 60.0) * 4.0;
            const double nearest = std::floor(pos + 0.5);
            if (std::fabs(pos - nearest) < 0.15) step = static_cast<long>(nearest);
        }
        if (step >= 0) {
            const long inBar = step % (4L * static_cast<long>(tr->beatsPerBar ? tr->beatsPerBar : 4));
            // Swing: the off 16ths (or 8ths) late, up to half their length (75 % swing).
            if (s.swing > 0.0) {
                if (s.swingGrid == kGrid16 && (step & 1)) late += s.swing * 0.5 * sixteenth;
                if (s.swingGrid == kGrid8 && (step & 3) == 2) late += s.swing * sixteenth;
            }
            if (s.groove != kGrooveOff && s.grooveAmt > 0.0) {
                const GrooveStep& g = grooveSteps(s.groove)[step & 15];
                late += s.grooveAmt * g.late * sixteenth;
                n.velocity = clampd(n.velocity * (1.0 + s.grooveAmt * (g.vel - 1.0)), 0.0, 1.0);
            }
            if (s.accent > 0.0) {
                const bool on = (s.accentOn == kAccentBeats && (step & 3) == 0) || (s.accentOn == kAccentBars && inBar == 0) ||
                                (s.accentOn == kAccentOffbeats && (step & 3) == 2);
                if (on) accent = s.accent;
            }
        }
        if (s.accent > 0.0 && s.accentOn == kAccentLoud && m.velocity >= 0.85) accent = s.accent;
        // Humanize: up to 12 ms late and ±15 % of the velocity, from the variation seed and the pad's hit count.
        if (s.humanize > 0.0) {
            late += s.humanize * 0.012 * 0.5 * (1.0 + random(pad, 8));
            n.velocity = clampd(n.velocity * (1.0 + 0.15 * s.humanize * random(pad, 9)), 0.0, 1.0);
        }
        const uint64_t now = clock_;  // render() has played up to this note's frame
        const uint64_t due = now + static_cast<uint64_t>(late * sr_);
        if (s.flam > 0.0) {  // the grace hit first (softer), the hit itself flam_time later
            NoteMessage g = n;
            g.velocity = clampd(n.velocity * (0.25 + 0.5 * s.flam), 0.0, 1.0);
            schedule(pad, g, due, 0.0, true, at);
            schedule(pad, n, due + static_cast<uint64_t>(s.flamTime * sr_), accent, false, at);
            return true;
        }
        schedule(pad, n, due, accent, false, at);
        return true;
    }

    void schedule(uint32_t pad, const NoteMessage& m, uint64_t due, double accent, bool grace, uint32_t at) noexcept {
        if (due <= clock_ || pending_ >= kPendingMax) {  // now (or no room left: now rather than never)
            hit(pad, m, at, accent, grace);
            return;
        }
        Pending& p = pendingHits_[pending_++];
        p.due = due;
        p.pad = pad;
        p.m = m;
        p.accent = accent;
        p.grace = grace;
        p.released = false;
    }

    // Plays the held-back hits due by now (frame `at` of the block); the frames until the next one (or `most`).
    uint32_t firePending(uint32_t at, uint32_t most) noexcept {
        uint32_t keep = 0;
        uint64_t next = ~0ull;
        for (uint32_t i = 0; i < pending_; ++i) {
            Pending p = pendingHits_[i];
            if (p.due <= clock_) {
                p.m.frame = at;
                hit(p.pad, p.m, at, p.accent, p.grace);
                if (p.released) {
                    NoteMessage off = p.m;
                    off.type = NoteMessageType::Off;
                    noteOff(off, at);
                }
            } else {
                next = std::min(next, p.due);
                pendingHits_[keep++] = p;
            }
        }
        pending_ = keep;
        if (next == ~0ull) return most;
        return static_cast<uint32_t>(std::min<uint64_t>(most, next - clock_));
    }

    // A hit on `pad`; false (nothing happens) when the pad is unused.
    bool hit(uint32_t pad, const NoteMessage& m, uint32_t at, double accent = 0.0, bool grace = false) noexcept {
        PadSettings& s = settings_[pad];
        readPad(*block_, pad, at, s, blockCount_);
        if (!s.used) return false;
        // 1.1.2: an Acoustic pad strikes its piece (and a Layers pad its acoustic layer, then plays its layers).
        if (s.engine == kEngineAcoustic || s.acouLayer > 0) {
            strikePiece(pad, s, m, at, accent);
            if (s.engine == kEngineAcoustic || !s.layers) {
                ++hits_[pad];
                lastPad_ = static_cast<int>(pad);
                return true;
            }
        }
        const double note = m.pitch;
        if (s.track && !grace) addHeld(pad, m.noteId, note);
        // Mono with pitch tracking: an overlapping note glides the sounding voice there (an 808 slide).
        if (s.mono && s.track && !grace && heldCount_[pad] > 1) {
            for (uint32_t i = 0; i < live_; ++i) {
                DrumVoice& v = voices_[list_[i]];
                if (v.active && v.pad == static_cast<int>(pad) && v.held && !v.fading) {
                    v.noteId = m.noteId;
                    v.note = note;
                    v.glideTarget = note - s.root;
                    return true;
                }
            }
        }
        // Choke group: every other pad in it fades out.
        if (s.choke > 0)
            for (uint32_t i = 0; i < live_; ++i) {
                DrumVoice& v = voices_[list_[i]];
                if (v.active && v.pad != static_cast<int>(pad) && settings_[v.pad].choke == s.choke) fade(v);
            }
        // The pad's own polyphony: the oldest past it fades (mono: every one).
        const int poly = s.mono ? 1 : s.poly;
        for (;;) {
            int count = 0;
            DrumVoice* oldest = nullptr;
            for (uint32_t i = 0; i < live_; ++i) {
                DrumVoice& v = voices_[list_[i]];
                if (!v.active || v.fading || v.pad != static_cast<int>(pad)) continue;
                ++count;
                if (!oldest || v.age < oldest->age) oldest = &v;
            }
            if (count < poly || !oldest) break;
            fade(*oldest);
        }
        if (settled_) {
            left_ = 0;  // from silence the grid starts at this hit, so a skipped (quiet) stretch changes nothing
            settled_ = false;
        }
        roomQuiet_ = 0;
        DrumVoice& v = allocate();
        const uint32_t index = static_cast<uint32_t>(&v - voices_);
        const SampleBuffer* sample = playing_[pad];
        const int quality = qualityNow(quality_);
        v = DrumVoice{};
        v.active = true;
        v.held = true;
        v.pad = static_cast<int>(pad);
        v.noteId = m.noteId;
        v.note = note;
        v.age = ++age_;
        v.velocity = clampd(m.velocity, 0, 1);
        v.quality = quality;
        v.sample = sample;
        v.rng = lib::Noise(0x5eed0000u + pad * 977u + hits_[pad] * 31u);
        // Velocity and the per-hit variation (docs/engine.md, "Drums", Variation).
        const double x = v.velocity - 1.0;
        v.var.gain = (1.0 + s.velLevel * x) * dbGain(s.rndLevel * 6.0 * random(pad, 5));
        v.var.pitch = s.velPitch * x + s.rndPitch * 0.01 * random(pad, 1);
        v.var.decayMul = exp2d(s.velDecay * x + 0.5 * s.rndDecay * random(pad, 2));
        v.var.toneOct = 2.0 * s.velTone * x + s.rndTone * random(pad, 3);
        v.var.click = 1.0 + s.velClick * x;
        v.var.pan = clampd(s.pan + s.rndPan * random(pad, 4), -1, 1);
        v.var.punch = 1.0 + s.velPunch * x;  // a softer hit drops less far
        v.var.pos = s.rndPos * 0.3 * random(pad, 6);
        v.accent = accent;
        if (accent > 0.0) {  // an accented hit: up to 6 dB louder, brighter, with more click
            v.var.gain *= 1.0 + accent;
            v.var.toneOct += 0.7 * accent;
            v.var.click *= 1.0 + accent;
        }
        double smpOffset = 0.0;  // the sample's start, moved by velocity and per hit (frames)
        if (s.smpOn && (s.smpVelStart > 0.0 || s.smpRndStart > 0.0))
            smpOffset = (s.smpVelStart * (1.0 - v.velocity) * 0.05 + s.smpRndStart * 0.03 * std::fabs(random(pad, 7))) * sr_;
        ++hits_[pad];
        v.glideSt = v.glideTarget = s.track ? note - s.root : 0.0;
        if (s.physOn && !physPool_.empty()) {
            v.physMax = physMax_;
            v.physLine = physPool_.data() + static_cast<size_t>(index) * physMax_;
        }
        start(v, s, smpOffset);
        list_[live_++] = static_cast<uint16_t>(index);
        // Display: this pad's picture starts over with this hit, while a UI reads the display (the audio doesn't
        // depend on it; unwatched, the per-sample capture is skipped).
        v.capture = watched_;
        for (uint32_t i = 0; i + 1 < live_; ++i)
            if (voices_[list_[i]].pad == static_cast<int>(pad)) voices_[list_[i]].capture = false;
        if (watched_) startCapture(pad, s, v);
        lastPad_ = static_cast<int>(pad);
        return true;
    }

    void fade(DrumVoice& v) noexcept {
        if (v.fading) return;
        v.fading = true;
        v.fadeCoef = fall(0.00375, sr_);  // -80 dB in 5 ms
    }

    DrumVoice& allocate() noexcept {
        prune();
        if (live_ < kVoices)
            for (DrumVoice& v : voices_)
                if (!v.active) return v;
        // Full: the oldest fading voice, else the oldest; it leaves the list (and is restarted by the caller).
        DrumVoice* pick = nullptr;
        for (int pass = 0; pass < 2 && !pick; ++pass)
            for (DrumVoice& v : voices_)
                if ((pass == 1 || v.fading) && (!pick || v.age < pick->age)) pick = &v;
        lanes_.end(pick->noteId);  // stolen: its lane (#127) ends here
        pick->active = false;
        prune();
        return *pick;
    }

    void prune() noexcept {
        uint32_t keep = 0;
        for (uint32_t i = 0; i < live_; ++i)
            if (voices_[list_[i]].active) list_[keep++] = list_[i];
        live_ = keep;
    }
